/// What the explorer remembers between launches.
///
/// Deliberately not "every fact". Only two things are worth persisting: an
/// answer that can never change, and an answer that cost a network round trip.
/// Everything else is cheaper to recompute than to invalidate correctly — dirty
/// state is ~25 ms per worktree and an agent probe is a `stat` — and a cache
/// that stores it would spend its life being wrong about it.
///
/// - **Branch diffs** are keyed by `<base sha>..<head sha>`. Two commits have
///   exactly one diff between them, forever, so the entry never needs
///   invalidating — it needs *evicting*, which is a different and much easier
///   problem.
/// - **Pull requests** are keyed by branch and stamped, because there is no
///   cheap key for "has the PR changed" and 890 ms is too long to pay on every
///   glance.
/// - **Changes configs** are keyed by the mtime and size of the worktree's
///   `tool/flutterware.dart`. Running that file is what "opening a worktree"
///   costs, and the changes screen has to rank a worktree that is **not
///   open** — so the executed value is remembered rather than approximated.
///
/// Lives outside the repository: this is machine state, and a cache written
/// into the checkout would turn up in the dirty count it is there to report.
///
/// The file is shared by every process on this repository — it is
/// keyed by the repo root on purpose, and a Studio in one worktree plus a `fw`
/// in another are both writers. So a save is not "write my snapshot": it is
/// re-read, fold in what the others wrote since [open], overlay only what this
/// process itself learned, and rename into place — under a lock, so two saves
/// serialize instead of interleaving. Without that, whichever window touched
/// the file last silently reverted every other window's opened-clocks and
/// caches.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';
import 'facts.dart';

/// One remembered branch diff.
class CachedDiff {
  const CachedDiff({
    required this.shape,
    required this.ahead,
    required this.behind,
  });

  final ChangeShape shape;
  final int ahead;
  final int behind;

  Map<String, Object?> toJson() => {
    'shape': shape.toJson(),
    'ahead': ahead,
    'behind': behind,
  };

  static CachedDiff fromJson(Map<String, Object?> json) => CachedDiff(
    shape: ChangeShape.fromJson(
      (json['shape']! as Map).cast<String, Object?>(),
    ),
    ahead: json['ahead']! as int,
    behind: json['behind']! as int,
  );
}

/// A `ChangesConfig` as last executed, beside what it was executed from.
///
/// The key is [CachedChangesConfig.validityKey] — the config file's mtime and
/// size. A key that still matches means this **is** the executed value, not an
/// approximation of one; a key that has moved means the file was edited since,
/// and the screen flags it rather than ranking silently by yesterday's rules.
class CachedChangesConfig {
  const CachedChangesConfig({required this.config, required this.validityKey});

  final ChangesConfig config;
  final String validityKey;

  Map<String, Object?> toJson() => {
    'key': validityKey,
    'config': config.toJson(),
  };

  static CachedChangesConfig fromJson(Map<String, Object?> json) =>
      CachedChangesConfig(
        validityKey: json['key']! as String,
        config: ChangesConfig.fromJson(
          (json['config'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
      );
}

/// What one reading of the file said. Shared by [WorktreeFactsStore.open] and
/// the merge inside [WorktreeFactsStore.save], which are the same parse at two
/// different moments.
typedef _Snapshot = ({
  Map<String, CachedDiff> diffs,
  Map<String, DateTime> opened,
  Map<String, ForgeFacts> pullRequests,
  DateTime? pullRequestsAt,
  Map<String, CachedChangesConfig> changesConfigs,
});

class WorktreeFactsStore {
  WorktreeFactsStore._(this.file, _Snapshot snapshot)
    : _diffs = snapshot.diffs,
      _opened = snapshot.opened,
      _pullRequests = snapshot.pullRequests,
      _pullRequestsAt = snapshot.pullRequestsAt,
      _changesConfigs = snapshot.changesConfigs;

  /// Opens the store for the repository rooted at [repoRoot].
  ///
  /// Never throws. A corrupt or unreadable cache is an empty cache: this file
  /// exists to save time, and a startup that fails because
  /// its optional cache did not parse would be a strictly worse program than one
  /// with no cache at all.
  ///
  /// [at] overrides where the cache lives — for tests, which must not write into
  /// the developer's real `~/.flutterware` to check that a cache round-trips.
  static WorktreeFactsStore open(String repoRoot, {File? at}) {
    var file = at ?? File(fileFor(repoRoot));
    return WorktreeFactsStore._(file, _read(file));
  }

  static _Snapshot _read(File file) {
    var diffs = <String, CachedDiff>{};
    var opened = <String, DateTime>{};
    var pullRequests = <String, ForgeFacts>{};
    var changesConfigs = <String, CachedChangesConfig>{};
    DateTime? pullRequestsAt;
    try {
      if (file.existsSync()) {
        var json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        for (var entry in (json['diffs'] as Map? ?? {}).entries) {
          diffs['${entry.key}'] = CachedDiff.fromJson(
            (entry.value as Map).cast<String, Object?>(),
          );
        }
        for (var entry in (json['opened'] as Map? ?? {}).entries) {
          var at = DateTime.tryParse('${entry.value}');
          if (at != null) opened['${entry.key}'] = at;
        }
        for (var entry in (json['changesConfigs'] as Map? ?? {}).entries) {
          changesConfigs['${entry.key}'] = CachedChangesConfig.fromJson(
            (entry.value as Map).cast<String, Object?>(),
          );
        }
        if (json['pullRequests'] case Map<Object?, Object?> prs) {
          pullRequestsAt = DateTime.tryParse('${prs['at']}');
          for (var entry in (prs['byBranch'] as Map? ?? {}).entries) {
            pullRequests['${entry.key}'] = ForgeFacts.fromJson(
              (entry.value as Map).cast<String, Object?>(),
            );
          }
        }
      }
    } catch (_) {
      // Unreadable, half-written, or written by a future version.
    }
    return (
      diffs: diffs,
      opened: opened,
      // A stamp we could not read is a cache whose age we cannot judge, and an
      // undated pull request is worse than none — it would show as current
      // forever.
      pullRequests: pullRequestsAt == null ? {} : pullRequests,
      pullRequestsAt: pullRequestsAt,
      changesConfigs: changesConfigs,
    );
  }

  /// `~/.flutterware/<sha1 of the repo root>/worktrees.json`.
  ///
  /// Hashed rather than spelled out for the same reason the launcher's install
  /// directory is: a path is not a filename, and two checkouts of one project
  /// must not collide.
  static String fileFor(String repoRoot) => p.join(
    flutterwareDir(),
    sha1.convert(utf8.encode(p.canonicalize(repoRoot))).toString(),
    'worktrees.json',
  );

  final File file;
  final Map<String, CachedDiff> _diffs;
  final Map<String, DateTime> _opened;
  Map<String, ForgeFacts> _pullRequests;
  DateTime? _pullRequestsAt;
  final Map<String, CachedChangesConfig> _changesConfigs;

  /// What *this* process wrote since it last saved — the only keys a save is
  /// entitled to impose on the file. Everything else in memory is a reading of
  /// the file, and imposing a reading is how one window reverts another.
  final _dirtyDiffs = <String>{};
  final _dirtyChangesConfigs = <String>{};
  bool _pullRequestsDirty = false;

  static String diffKey(String baseSha, String headSha) => '$baseSha..$headSha';

  CachedDiff? diff(String baseSha, String headSha) =>
      _diffs[diffKey(baseSha, headSha)];

  void putDiff(String baseSha, String headSha, CachedDiff diff) {
    _diffs[diffKey(baseSha, headSha)] = diff;
    _dirtyDiffs.add(diffKey(baseSha, headSha));
  }

  /// When you last opened this worktree in flutterware — one of the clocks
  /// [ActivityFacts] takes the maximum of, and the only one nothing else knows.
  DateTime? openedAt(String worktreePath) => _opened[worktreePath];

  void markOpened(String worktreePath, DateTime at) =>
      _opened[worktreePath] = at;

  /// The last answer the forge gave, and when — **stamped rather than keyed**.
  ///
  /// Unlike a branch diff there is no cheap key for "has this changed": a pull
  /// request's checks move without a single sha moving. So this one is a
  /// genuine TTL cache, and the caller decides how old is too old.
  ({Map<String, ForgeFacts> byBranch, DateTime at})? pullRequests() =>
      _pullRequestsAt == null
      ? null
      : (byBranch: _pullRequests, at: _pullRequestsAt!);

  void putPullRequests(Map<String, ForgeFacts> byBranch, DateTime at) {
    _pullRequests = byBranch;
    _pullRequestsAt = at;
    _pullRequestsDirty = true;
  }

  /// The last `ChangesConfig` this worktree's config file produced.
  CachedChangesConfig? changesConfig(String worktreePath) =>
      _changesConfigs[worktreePath];

  void putChangesConfig(String worktreePath, CachedChangesConfig entry) {
    _changesConfigs[worktreePath] = entry;
    _dirtyChangesConfigs.add(worktreePath);
  }

  /// Drops diffs beyond [keep], oldest-inserted first.
  ///
  /// An entry is never *wrong* — a sha pair has one diff forever — so this is
  /// eviction, not invalidation. Without it the file grows by one entry per
  /// commit per branch and never shrinks.
  void evict({int keep = 500}) {
    if (_diffs.length <= keep) return;
    var excess = _diffs.length - keep;
    for (var key in _diffs.keys.take(excess).toList()) {
      _diffs.remove(key);
    }
  }

  /// Folds what other processes wrote since this store last read the file.
  ///
  /// Per section, the merge that matches its semantics:
  /// - **Diffs** are never wrong, so the disk's map is taken whole and only
  ///   this process's own writes are laid over it. A non-dirty entry the disk
  ///   no longer has was evicted by another process, and re-adding it would
  ///   undo that eviction.
  /// - **Opened** takes the later timestamp per worktree, whichever process
  ///   wrote it —
  ///   "when was this last opened" has exactly one right answer.
  /// - **Changes configs** overlay dirty keys only, like diffs; the validity
  ///   key makes a stale survivor self-correcting at read time.
  /// - **Pull requests** are one stamped block: the fresher stamp wins.
  void _mergeFromDisk() {
    var disk = _read(file);

    var diffs = {...disk.diffs, for (var key in _dirtyDiffs) key: ?_diffs[key]};
    _diffs
      ..clear()
      ..addAll(diffs);

    for (var entry in disk.opened.entries) {
      var ours = _opened[entry.key];
      if (ours == null || entry.value.isAfter(ours)) {
        _opened[entry.key] = entry.value;
      }
    }

    var configs = {
      ...disk.changesConfigs,
      for (var key in _dirtyChangesConfigs) key: ?_changesConfigs[key],
    };
    _changesConfigs
      ..clear()
      ..addAll(configs);

    if (disk.pullRequestsAt case var diskAt?) {
      var ours = _pullRequestsAt;
      var oursWin = _pullRequestsDirty && ours != null && !diskAt.isAfter(ours);
      if (!oursWin) {
        _pullRequests = disk.pullRequests;
        _pullRequestsAt = diskAt;
      }
    }
  }

  /// Never throws, for the same reason [open] does not: failing to write an
  /// optional cache must not fail the command that produced it.
  ///
  /// Read-merge-write under an exclusive lock, then rename into place: the
  /// lock is what makes the merge worth doing (two unserialized merges still
  /// lose one), and the rename is what keeps a concurrent reader from parsing
  /// half a file and starting over with an empty cache.
  void save() {
    try {
      file.parent.createSync(recursive: true);
      var lock = File('${file.path}.lock').openSync(mode: FileMode.write);
      try {
        lock.lockSync(FileLock.blockingExclusive);
        _mergeFromDisk();
        evict();
        var tmp = File('${file.path}.$pid.tmp');
        tmp.writeAsStringSync(
          jsonEncode({
            'diffs': {
              for (var entry in _diffs.entries) entry.key: entry.value.toJson(),
            },
            'opened': {
              for (var entry in _opened.entries)
                entry.key: entry.value.toIso8601String(),
            },
            if (_changesConfigs.isNotEmpty)
              'changesConfigs': {
                for (var entry in _changesConfigs.entries)
                  entry.key: entry.value.toJson(),
              },
            if (_pullRequestsAt case var at?)
              'pullRequests': {
                'at': at.toIso8601String(),
                'byBranch': {
                  for (var entry in _pullRequests.entries)
                    entry.key: entry.value.toJson(),
                },
              },
          }),
        );
        tmp.renameSync(file.path);
        _dirtyDiffs.clear();
        _dirtyChangesConfigs.clear();
        _pullRequestsDirty = false;
      } finally {
        // Closing releases the lock.
        lock.closeSync();
      }
    } catch (_) {
      // A read-only home, a full disk. The facts are still correct in memory,
      // and the dirty sets survive for the next attempt.
    }
  }
}
