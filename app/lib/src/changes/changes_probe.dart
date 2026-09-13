/// The git calls behind a [ChangeSet].
///
/// Pure Dart, injectable runner — the parsers deserve tests that need no
/// repository and the sequencing deserves one that needs no git, exactly as
/// `GitProbe` and `WorktreeDiscovery` already have.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/plugins.dart';

import '../utils/run_git.dart';
import '../worktrees/providers/git.dart';
import 'change_set.dart';
import 'changes_config_cache.dart';
import 'changes_files.dart';
import 'patch_index.dart';
import 'ranking.dart';

/// One git invocation's result, with **stdout as bytes**.
///
/// Bytes rather than a String because the patch is the payload and decoding
/// megabytes of it up front is the cost this whole design exists to avoid. Text
/// callers decode what they asked for and nothing else.
class GitOutput {
  const GitOutput({
    required this.exitCode,
    required this.stdout,
    this.stderr = '',
  });

  final int exitCode;
  final Uint8List stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  String get text =>
      const Utf8Decoder(allowMalformed: true).convert(stdout).trim();
}

/// Runs `git <arguments>` in `<directory>`.
typedef GitRunner = Future<GitOutput> Function(
  String directory,
  List<String> arguments,
);

/// Reads one worktree's delta.
class ChangesProbe {
  ChangesProbe({GitRunner? runGit, this.files = const LiveChangesFiles()})
    : _run = runGit ?? _defaultRunner;

  final GitRunner _run;

  /// The working tree, for the one thing here that is not a git call: the
  /// stat that stamps an untracked file. The disk unless a recording says
  /// otherwise.
  final ChangesFiles files;

  /// Neutralises the user's git configuration, because every one of these can
  /// otherwise change what we parse:
  ///
  /// - `core.quotePath=false` — stops non-ASCII paths arriving as
  ///   `"caf\303\251.txt"`. (Quoting still happens for `"` and `\`, which the
  ///   scanner handles; this just makes the common case plain.)
  /// - `color.ui=never` and `--no-color` — a user with `color.ui=always` would
  ///   otherwise hand us ANSI escapes inside every line.
  /// - `--no-ext-diff` — an external diff driver replaces the format entirely.
  /// - `--no-textconv` — a textconv filter turns binaries into text, which is
  ///   arguably nice and is certainly not predictable.
  /// - `--src-prefix`/`--dst-prefix` — `diff.noprefix` or a custom prefix would
  ///   break the `a/`…`b/` the scanner strips.
  static const _diffHardening = [
    '--no-ext-diff',
    '--no-textconv',
    '--no-color',
    '--src-prefix=a/',
    '--dst-prefix=b/',
  ];

  static const _configHardening = [
    '-c',
    'core.quotePath=false',
    '-c',
    'color.ui=never',
  ];

  /// `--no-optional-locks` on everything. It exists for tools that poll.
  /// Without it a refresh rewrites the worktree's index and flutterware fights
  /// the user's own git for the lock.
  Future<GitOutput> _git(String directory, List<String> arguments) => _run(
    directory,
    ['--no-optional-locks', ..._configHardening, ...arguments],
  );

  /// The checkout [directory] is in, or null when it is not in one.
  ///
  /// git resolves upward on its own, so every other call here would work from a
  /// subdirectory — but the path is what a report names and what a `--json`
  /// consumer keys on, so it is worth the 5 ms to say it exactly.
  Future<String?> worktreeRoot(String directory) async {
    var result = await _git(directory, ['rev-parse', '--show-toplevel']);
    return result.ok && result.text.isNotEmpty ? result.text : null;
  }

  /// The whole delta for [worktreePath], ranked: merge-base to the files on
  /// disk.
  ///
  /// [config] is the project's own rules — its `base:` overrides inference, and
  /// its globs feed [rankChanges]. [configState] is only carried through to the
  /// header, which says something when the rules are stale.
  ///
  /// Reading the store is this method's job, not its caller's. It runs on
  /// an isolate that is already doing file and process work; resolving the
  /// config on the UI isolate to hand it in would put a synchronous JSON read
  /// on the frame that opens the screen.
  Future<ChangeSet> probe(
    String worktreePath, {
    String? base,
    ChangesConfig? config,
    ChangesConfigState configState = ChangesConfigState.none,
  }) async {
    var head = await _git(worktreePath, ['rev-parse', '--verify', 'HEAD']);
    var headSha = head.ok && head.text.isNotEmpty ? head.text : null;
    // Read once for the four `ChangeSet`s below, which differ in what they
    // could answer and not in what the project declared.
    var pinsDeclared = config?.attention.isNotEmpty ?? false;

    // Pinned here rather than in `rankChanges`: an untracked entry has no
    // diff, so it is not a `RankedFile` — but a new file an agent has not
    // staged yet is exactly what an attention rule is for.
    var pins = attentionGlobs(config);
    var untracked = [
      for (var entry in await _untracked(worktreePath))
        entry.withReason(attentionForUntracked(entry.path, pins)),
    ];

    // The caller's own override first, then the project's `base:`, then
    // inference. Both of the first two are somebody *naming* a base, which is
    // the distinction the header reports.
    var named = base ?? config?.base;
    var resolved = named ?? await _inferBase(worktreePath);
    var source = named != null
        ? BaseSource.configured
        : resolved != null
        ? BaseSource.inferred
        : BaseSource.none;

    // **No base is a state, not an error to paper over.** Nothing is diffed
    // against a guess. What is still answerable is the uncommitted work, and
    // showing that beats an empty screen — so the left side falls back to HEAD
    // and the caller is told which it got.
    String? mergeBase;
    if (resolved != null && headSha != null) {
      var found = await _git(worktreePath, ['merge-base', resolved, 'HEAD']);
      if (found.ok && found.text.isNotEmpty) mergeBase = found.text;
    }

    var left = mergeBase ?? headSha;
    if (left == null) {
      // A repository with no commit at all: everything is untracked.
      return ChangeSet(
        worktreePath: worktreePath,
        patch: PatchIndex.empty,
        base: resolved,
        baseSource: source,
        untracked: untracked,
        configState: configState,
        attentionConfigured: pinsDeclared,
      );
    }

    var uncommitted = await _uncommitted(worktreePath);

    var patch = await _git(worktreePath, [
      'diff',
      ..._diffHardening,
      '-M',
      left,
    ]);
    if (!patch.ok) {
      return ChangeSet(
        worktreePath: worktreePath,
        patch: PatchIndex.empty,
        base: resolved,
        baseSource: source,
        mergeBase: mergeBase,
        head: headSha,
        uncommitted: uncommitted,
        untracked: untracked,
        configState: configState,
        attentionConfigured: pinsDeclared,
      );
    }

    var index = indexPatch(patch.stdout);
    return ChangeSet(
      worktreePath: worktreePath,
      patch: index,
      base: resolved,
      baseSource: source,
      mergeBase: mergeBase,
      head: headSha,
      uncommitted: uncommitted,
      untracked: untracked,
      ranking: rankChanges(index.files, config: config),
      configState: configState,
      attentionConfigured: pinsDeclared,
    );
  }

  /// One file's patch, for `fw changes --file` and for MCP.
  ///
  /// A separate call rather than a slice, because a caller that named one file
  /// should not pay for the whole diff to reach it.
  ///
  /// A rename needs both of its paths named, or it is not a rename. git
  /// detects renames over the *filtered* set, so `diff -M <range> -- new.dart`
  /// cannot see `old.dart` and reports a brand new file whose every line was
  /// added — which is the single most misleading thing this command could say
  /// about a refactor. Verified against git: naming both paths restores it. So
  /// a cheap `--name-status` runs first to find the other end.
  Future<String?> patchFor(
    String worktreePath,
    String path, {
    String? range,
    String? base,
  }) async {
    var from = range ?? await _rangeFor(worktreePath, base: base);
    var source = await _renameSourceFor(worktreePath, path, from);
    var result = await _git(worktreePath, [
      'diff',
      ..._diffHardening,
      '-M',
      ?from,
      '--',
      path,
      ?source,
    ]);
    return result.ok ? result.text : null;
  }

  /// The size of [path]'s blob at [revision], or null when there is no such
  /// object — a file that did not exist on that side, or a revision nothing
  /// resolves. Asked before [blobBytes], because it is the only way to refuse
  /// an oversized object without first receiving all of it.
  Future<int?> blobSize(
    String worktreePath,
    String revision,
    String path,
  ) async {
    var result = await _git(worktreePath, [
      'cat-file',
      '-s',
      '$revision:$path',
    ]);
    return result.ok ? int.tryParse(result.text) : null;
  }

  /// The bytes of [path] as they were at [revision] — the other side of an
  /// image diff, which the patch itself only says is binary.
  ///
  /// `cat-file blob` rather than `show`, so no textconv or diff driver ever
  /// rewrites what comes back.
  Future<Uint8List?> blobBytes(
    String worktreePath,
    String revision,
    String path,
  ) async {
    var result = await _git(worktreePath, [
      'cat-file',
      'blob',
      '$revision:$path',
    ]);
    return result.ok ? result.stdout : null;
  }

  Future<String?> _renameSourceFor(
    String worktreePath,
    String path,
    String? range,
  ) async {
    if (range == null) return null;
    var result = await _git(worktreePath, [
      'diff',
      '--name-status',
      '-M',
      '-z',
      range,
    ]);
    return result.ok ? renameSourceIn(_splitNul(result.stdout), path) : null;
  }

  Future<String?> _rangeFor(String worktreePath, {String? base}) async {
    var from = base ?? await _inferBase(worktreePath);
    if (from == null) return null;
    var found = await _git(worktreePath, ['merge-base', from, 'HEAD']);
    return found.ok && found.text.isNotEmpty ? found.text : null;
  }

  /// `origin/HEAD`, then `main`, then `master` — reusing the explorer's
  /// inference rather than growing a second one that could disagree with it.
  Future<String?> _inferBase(String worktreePath) => GitProbe(
    runProcess: (executable, arguments, {workingDirectory}) async {
      var result = await _run(workingDirectory ?? worktreePath, arguments);
      return ProcessResult(0, result.exitCode, result.text, result.stderr);
    },
  ).defaultBranch(worktreePath);

  /// Paths with staged or unstaged changes. Cheap, and the only thing that
  /// distinguishes "the agent committed this" from "the agent is mid-edit".
  Future<Set<String>> _uncommitted(String worktreePath) async {
    var result = await _git(worktreePath, [
      'diff',
      '--name-only',
      '-M',
      '-z',
      'HEAD',
    ]);
    if (!result.ok) return const {};
    return _splitNul(result.stdout).toSet();
  }

  /// `--untracked-files=normal`, which is git's default and is load-bearing.
  ///
  /// git reports the topmost wholly-untracked directory and does not descend.
  /// Measured against the case this is written for — a package built on one
  /// branch, then a switch to a branch whose `.gitignore` does not cover its
  /// `build/` — normal gives **1 row in 7 ms** where `-uall` gives **30,000
  /// rows**. Nothing below reads what is inside, either: a count is the walk
  /// being avoided.
  ///
  /// `-z` rather than the quoted default, so a path with a space or a quote in
  /// it arrives whole.
  ///
  /// Each **file** is then stat'ed — see [untrackedStamp] for what that buys
  /// and why it is a stat rather than a read. Concurrently, and never for a
  /// directory: a directory here stands for a subtree nobody has walked, and
  /// stat'ing into it would be that walk.
  Future<List<UntrackedEntry>> _untracked(String worktreePath) async {
    var result = await _git(worktreePath, [
      'status',
      '--porcelain=v2',
      '--untracked-files=normal',
      '-z',
    ]);
    if (!result.ok) return const [];
    var entries = parseUntrackedV2Z(_splitNul(result.stdout));
    return Future.wait([
      for (var entry in entries)
        if (entry.isDirectory)
          Future.value(entry)
        else
          _stamp(worktreePath, entry),
    ]);
  }

  /// [entry] with what a stat says about it.
  ///
  /// A file that has gone between git's answer and this keeps a null stamp
  /// rather than failing the probe: the next read will not list it at all, and
  /// a delta that refuses to load because a scratch file was deleted mid-probe
  /// would be a worse program.
  Future<UntrackedEntry> _stamp(
    String worktreePath,
    UntrackedEntry entry,
  ) async {
    var stat = await files.stat('$worktreePath/${entry.path}');
    if (stat == null) return entry;
    return entry.withStamp(
      untrackedStamp(size: stat.size, modified: stat.modified),
    );
  }

  static Future<GitOutput> _defaultRunner(
    String directory,
    List<String> arguments,
  ) async {
    try {
      var result = await runGit(
        arguments,
        workingDirectory: directory,
        stdoutEncoding: null,
        stderrEncoding: systemEncoding,
      );
      return GitOutput(
        exitCode: result.exitCode,
        stdout: Uint8List.fromList(result.stdout as List<int>),
        stderr: '${result.stderr}',
      );
    } on ProcessException catch (e) {
      return GitOutput(exitCode: 127, stdout: Uint8List(0), stderr: e.message);
    }
  }
}

/// Splits NUL-terminated output into its records, dropping the empty tail.
List<String> _splitNul(Uint8List bytes) =>
    const Utf8Decoder(allowMalformed: true)
        .convert(bytes)
        .split('\u0000')
        .where((s) => s.isNotEmpty)
        .toList();

/// Where [path] was renamed from, per `git diff --name-status -M -z`.
///
/// Records are a status token followed by its path — except `R`/`C`, which are
/// followed by **two**: the old path and the new one. Walking the pairs rather
/// than scanning for a match is what keeps a file whose name happens to look
/// like a status token from shifting everything after it.
String? renameSourceIn(List<String> records, String path) {
  for (var i = 0; i < records.length; i++) {
    var status = records[i];
    if (status.startsWith('R') || status.startsWith('C')) {
      if (i + 2 >= records.length) return null;
      var from = records[++i];
      var to = records[++i];
      if (to == path) return from;
    } else {
      i++;
    }
  }
  return null;
}

/// Pulls the untracked entries out of `status --porcelain=v2 -z`.
///
/// The records are NUL-separated and a rename (`2 `) carries **an extra record**
/// holding its original path. That trailing path is a bare string, so a naive
/// filter would read a file named `? something` as an untracked entry. Tracking
/// the extra record is a few lines and removes the whole class of confusion.
///
/// A trailing `/` is git's way of saying *directory*, and it is the difference
/// between one row and thirty thousand.
List<UntrackedEntry> parseUntrackedV2Z(List<String> records) {
  var entries = <UntrackedEntry>[];
  var skipNext = false;

  for (var record in records) {
    if (skipNext) {
      skipNext = false;
      continue;
    }
    if (record.startsWith('2 ')) {
      skipNext = true;
      continue;
    }
    if (!record.startsWith('? ')) continue;
    var path = record.substring(2);
    entries.add(
      path.endsWith('/')
          ? UntrackedEntry.directory(path)
          : UntrackedEntry(path),
    );
  }
  return entries;
}

/// Parses `git diff --numstat -z`, whose records are
/// `<added>\t<removed>\t<path>` — except for a rename, where the path field is
/// empty and the **two following records** are the old and new paths.
///
/// Binary files report `-` for both counts. They are counted as files —
/// deleting a 2 MB asset is a real change — and contribute no lines, because
