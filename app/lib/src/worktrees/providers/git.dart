/// Everything the explorer asks git, and the parsers for what it answers.
///
/// Pure Dart, like the rest of the facts layer: `fw worktrees` links this and
/// must not drag in Flutter.
///
/// Batched where git allows it. One `for-each-ref` reports every branch's
/// tip, so fourteen worktrees cost one process rather than fourteen. What
/// cannot be batched is the working tree — each checkout has its own — so dirty
/// state is the one per-worktree call.
library;

import 'dart:io';

import '../../utils/run_git.dart';
import '../facts.dart';

/// Where a branch is, from the one call that reports every branch at once.
class BranchTip {
  const BranchTip({
    required this.branch,
    required this.sha,
    required this.committedAt,
  });

  final String branch;
  final String sha;
  final DateTime committedAt;
}

/// What `status --porcelain=v2` says about a working tree.
class StatusFacts {
  const StatusFacts({
    required this.dirty,
    this.head,
    this.branch,
    this.ahead,
    this.behind,
  });

  /// Modified, deleted, renamed, unmerged and untracked, counted together.
  /// The row asks "is there uncommitted work here", not "of what kind".
  final int dirty;

  final String? head;
  final String? branch;

  /// Only when the branch has an upstream, which on a stack of local feature
  /// branches it usually does not — see [parseRevListCounts], which is where
  /// the explorer actually gets these.
  final int? ahead;
  final int? behind;
}

/// Parses `git for-each-ref --format='%(refname:short)\t%(committerdate:unix)\t%(objectname)' refs/heads/ refs/remotes/origin/`.
///
/// Unknown or malformed lines are skipped rather than thrown on: this runs
/// against whatever git the user has, and one odd ref must not cost the whole
/// list.
Map<String, BranchTip> parseForEachRef(String output) {
  var tips = <String, BranchTip>{};
  for (var line in output.split('\n')) {
    if (line.trim().isEmpty) continue;
    var parts = line.split('\t');
    if (parts.length < 3) continue;
    var branch = parts[0];
    var seconds = int.tryParse(parts[1]);
    if (branch.isEmpty || seconds == null) continue;
    tips[branch] = BranchTip(
      branch: branch,
      sha: parts[2],
      committedAt: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    );
  }
  return tips;
}

/// Parses `git status --porcelain=v2 --branch`.
///
/// The five line kinds that mean "dirty" are `1` (ordinary change), `2`
/// (rename or copy), `u` (unmerged) and `?` (untracked). `!` (ignored) is not
/// dirt and is not counted — it is also not reported unless asked for.
StatusFacts parseStatusV2(String output) {
  var dirty = 0;
  String? head;
  String? branch;
  int? ahead;
  int? behind;

  for (var line in output.split('\n')) {
    if (line.isEmpty) continue;
    if (line.startsWith('# ')) {
      var parts = line.substring(2).split(' ');
      switch (parts.first) {
        case 'branch.oid':
          // `(initial)` on a repository with no commit yet.
          if (parts.length > 1 && parts[1] != '(initial)') head = parts[1];
        case 'branch.head':
          // `(detached)` when there is no branch.
          if (parts.length > 1 && parts[1] != '(detached)') branch = parts[1];
        case 'branch.ab':
          // `+3 -1`, and only present when an upstream is configured.
          for (var token in parts.skip(1)) {
            var value = int.tryParse(token.substring(1));
            if (value == null) continue;
            if (token.startsWith('+')) ahead = value;
            if (token.startsWith('-')) behind = value;
          }
      }
      continue;
    }
    if (line.startsWith('1 ') ||
        line.startsWith('2 ') ||
        line.startsWith('u ') ||
        line.startsWith('? ')) {
      dirty++;
    }
  }

  return StatusFacts(
    dirty: dirty,
    head: head,
    branch: branch,
    ahead: ahead,
    behind: behind,
  );
}

/// Parses `git rev-list --left-right --count <base>...<head>`, whose output is
/// `<behind>\t<ahead>` — commits the base has and the head does not, then the
/// reverse.
///
/// This, and not `%(upstream:track)`, is where ahead/behind comes from. A
/// stack of local feature branches has no upstream at all, so the tracking
/// field is empty and `# branch.ab` is absent — measured on a real repo of
/// fourteen worktrees, where none of them had one. Against the base branch the
/// question is always answerable, and the answer is what the row means anyway:
/// how far this branch has moved from where it started.
(int behind, int ahead) parseRevListCounts(String output) {
  var parts = output.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return (0, 0);
  return (int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
}

/// Parses `git diff --numstat <base>...<head>` into the shape the row draws.
///
/// Binary files report `-` for both counts. They are counted as files —
/// deleting a 2 MB asset is a real change — and contribute no lines, because
/// they have none to contribute.
ChangeShape parseNumstat(String output) {
  var added = <String, int>{};
  var removed = <String, int>{};
  var files = 0;

  for (var line in output.split('\n')) {
    if (line.trim().isEmpty) continue;
    var parts = line.split('\t');
    if (parts.length < 3) continue;
    files++;
    var bucket = bucketFor(parts[2]);
    added[bucket] = (added[bucket] ?? 0) + (int.tryParse(parts[0]) ?? 0);
    removed[bucket] = (removed[bucket] ?? 0) + (int.tryParse(parts[1]) ?? 0);
  }

  return ChangeShape(
    files: files,
    buckets: [
      for (var name in added.keys)
        ChangeBucket(name, added: added[name]!, removed: removed[name] ?? 0),
    ],
  );
}

/// The top-level directory a path belongs to.
///
/// `--numstat` reports a rename in one of two forms, and both have to be
/// resolved to the path the file *landed* at:
///
/// - `lib/old.dart => app/new.dart` — two whole paths.
/// - `app/{lib => src}/thing.dart` — braces around the part that differs, with
///   the shared prefix and suffix outside them. Taking the text after the arrow
///   here yields `src`, which buckets a move *inside* `app` as though it left.
///
/// Files at the repository root have no directory, and get `·` — a bucket they
/// can be named by rather than an empty label in the row.
String bucketFor(String path) {
  // Braces first: they carry their own prefix, so resolving them leaves a whole
  // path that the bare-arrow rule below must then leave alone.
  var target = path.replaceAllMapped(
    RegExp(r'\{[^}]*? => ([^}]*?)\}'),
    (match) => match[1]!,
  );
  if (target.contains(' => ')) target = target.split(' => ').last;
  // `{ => app}/new.dart` resolves to `/new.dart`; a move to the root leaves a
  // leading slash that would otherwise become an empty bucket name.
  target = target.replaceAll('//', '/');
  if (target.startsWith('/')) target = target.substring(1);
  var slash = target.indexOf('/');
  return slash <= 0 ? '·' : target.substring(0, slash);
}

/// Runs the git commands behind the facts.
///
/// The process runner is injectable for the same reason `WorktreeDiscovery`'s
/// is: the parsers above deserve tests that need no repository, and the
/// sequencing deserves one that needs no git.
class GitProbe {
  GitProbe({
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    })?
    runProcess,
  }) : _run = runProcess ?? runGitTool;

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  })
  _run;

  /// `--no-optional-locks` on everything that could write.
  ///
  /// It exists for tools that poll. Without it a background refresh rewrites
  /// each worktree's index, which means flutterware fights the user's own git
  /// for the lock — and a `git status` in their terminal blocks on ours.
  Future<String?> _git(String directory, List<String> arguments) async {
    try {
      var result = await _run('git', [
        '--no-optional-locks',
        ...arguments,
      ], workingDirectory: directory);
      if (result.exitCode != 0) return null;
      return '${result.stdout}';
    } on ProcessException {
      return null;
    }
  }

  /// Every branch's tip, in one process.
  ///
  /// origin's branches too, keyed `origin/<name>`, because [defaultBranch] is
  /// one of them.
  Future<Map<String, BranchTip>> branchTips(String repoDirectory) async {
    var output = await _git(repoDirectory, [
      'for-each-ref',
      '--format=%(refname:short)%09%(committerdate:unix)%09%(objectname)',
      'refs/heads/',
      'refs/remotes/origin/',
    ]);
    return output == null ? {} : parseForEachRef(output);
  }

  /// The base every branch is measured against.
  ///
  /// `origin/HEAD` first, because it is what the remote says rather than what
  /// this machine happens to have checked out; then the conventional names.
  /// Null when none of them exist, which leaves branch size unanswerable and is
  /// reported as such rather than guessed at.
  ///
  /// The remote-tracking ref as git reports it, `origin/main` and not `main`.
  /// A worktree fetches `origin/main` and nothing fast-forwards the local
  /// `main`, so measured from the local one, everything merged since it was
  /// last pulled reads as this branch's work. It is also what `BaseRef` and a
  /// pull request measure from.
  Future<String?> defaultBranch(String repoDirectory) async {
    var symbolic = await _git(repoDirectory, [
      'symbolic-ref',
      '--short',
      'refs/remotes/origin/HEAD',
    ]);
    if (symbolic != null && symbolic.trim().isNotEmpty) return symbolic.trim();
    for (var candidate in const ['main', 'master']) {
      var exists = await _git(repoDirectory, [
        'rev-parse',
        '--verify',
        '--quiet',
        candidate,
      ]);
      if (exists != null && exists.trim().isNotEmpty) return candidate;
    }
    return null;
  }

  /// The working tree's own state. The one call that must run in the worktree,
  /// because the working tree is the one thing not shared.
  Future<StatusFacts?> status(String worktreeDirectory) async {
    var output = await _git(worktreeDirectory, [
      'status',
      '--porcelain=v2',
      '--branch',
    ]);
    return output == null ? null : parseStatusV2(output);
  }

  /// The branch diff, and how far it has moved.
  ///
  /// Runs against commits only, so it takes any directory in the repository
  /// rather than the worktree's — and is therefore keyed entirely by the two
  /// shas, which is what lets it be cached until one of them moves.
  Future<({ChangeShape shape, int ahead, int behind})?> branchDiff(
    String repoDirectory, {
    required String base,
    required String head,
  }) async {
    var range = '$base...$head';
    var counts = await _git(repoDirectory, [
      'rev-list',
      '--left-right',
      '--count',
      range,
    ]);
    var numstat = await _git(repoDirectory, ['diff', '--numstat', range]);
    if (counts == null || numstat == null) return null;
    var (behind, ahead) = parseRevListCounts(counts);
    return (shape: parseNumstat(numstat), ahead: ahead, behind: behind);
  }
}
