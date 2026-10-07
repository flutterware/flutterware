import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';
import '../utils/run_git.dart';

/// The other side of a comparison, on disk.
///
/// A build fixture, not state. It is a `git worktree add --detach` at one
/// commit, shared by every worktree and every comparison on the machine, and
/// it may be deleted at any moment: what survives a comparison is the shot
/// cache, which is content-addressed and does not care where the pictures were
/// rendered from.
///
/// Shared per commit rather than per comparison, which is the whole
/// arithmetic: five agents branched off one master sha have one base between
/// them, it is checked out once, resolved once, and rendered once.
class BaseCheckout {
  const BaseCheckout({
    required this.path,
    required this.sha,
    required this.created,
  });

  /// The checkout's root.
  final String path;

  final String sha;

  /// Whether this call is what put it there. False means it was already on
  /// disk from an earlier comparison — the case worth optimising for, since it
  /// is every comparison after the first against a given base.
  final bool created;

  /// Where base checkouts live, and the reason they are all under one root:
  /// they are real git worktrees, so `git worktree list` reports them and the
  /// explorer would otherwise show a row for each. One known prefix is all it
  /// takes to filter them back out — see [isBasePath].
  static String get defaultRoot => p.join(flutterwareDir(), 'bases');

  /// Whether [path] is a base checkout rather than something a person made.
  ///
  /// Used by the worktree explorer, which lists every worktree git reports:
  /// without this, comparing against master puts a detached checkout named
  /// after a sha in a screen whose whole purpose is *which one was I in*.
  static bool isBasePath(String path, {String? root}) =>
      p.isWithin(root ?? defaultRoot, p.canonicalize(path));

  /// Whether [sha]'s checkout already exists resolved — the marker is written
  /// only after `pub get` succeeded, so this is "reusable", not merely "there".
  ///
  /// A stat, so a panel can say what a run will cost before anything is paid.
  static bool isReady(String sha, {String? cacheRoot}) =>
      File(p.join(cacheRoot ?? defaultRoot, sha, _marker)).existsSync();

  /// How long a base survives without a comparison asking for it.
  ///
  /// Age and a count ([keep]), with no size budget, and that is the one
  /// difference from the other two caches under `~/.flutterware`. A base is a
  /// whole checkout — measured on this repository at 553MB — so pricing the
  /// directory means walking half a gigabyte to decide whether to keep it, on
  /// every run. The shot cache can afford a budget because its entries are
  /// files it already has the size of; this one cannot, and does not need
  /// one: a base is disposable by construction, and what survives it is the
  /// shot cache.
  static const forget = Duration(days: 14);

  /// How many bases survive the sweep whatever their age: the most recently
  /// used, by the marker's mtime.
  ///
  /// Age alone was the whole policy, and it is the wrong unit on a CI runner.
  /// There the base is the merge base with trunk, which moves with every
  /// merge and every rebase, so a base serves about one job and then sits out
  /// the fortnight — measured on one runner, 70GB of them at ~550MB a
  /// checkout. A count is the unit a laptop and a runner have in common: five
  /// is a couple of agents off two trunk commits and a base somebody named by
  /// hand, and it costs the listing and the stat the age test already pays.
  static const keep = 5;

  /// How long a checkout that never got its marker is left alone before it
  /// is taken for abandoned.
  ///
  /// The marker is written after `pub get` succeeds, so a run killed between
  /// `worktree add` and then leaves a directory with none — a cancelled CI
  /// job does it routinely. [_ensureLocked] throws such a directory away when
  /// the same sha is asked for again, which on a runner it never is, and the
  /// sweep used to leave it alone for ever as somebody's half-built base.
  /// Nothing takes a day to check out and resolve, and a creator still inside
  /// its day holds the lock, which [_removeIfUnheld] respects.
  static const abandonAfter = Duration(days: 1);

  /// The checkout of [sha], creating it if nothing has yet.
  ///
  /// [resolve] is called once per fresh checkout and is where `pub get` goes.
  /// It is a callback rather than a step here because this file knows about
  /// git and nothing else — and because a test should not have to resolve a
  /// package graph to prove that a directory gets reused.
  ///
  /// A [resolve] that throws leaves nothing behind: the checkout is removed,
  /// so the next attempt starts clean rather than finding a directory that
  /// exists but has no `.dart_tool` in it.
  static Future<BaseCheckout> ensure({
    required String repoRoot,
    required String sha,
    required String cacheRoot,
    Future<void> Function(String checkout)? resolve,
  }) async {
    var path = p.join(cacheRoot, sha);
    Directory(cacheRoot).createSync(recursive: true);
    // Swept here rather than on a schedule, for the reason
    // `claimBuildDirectory` gives about its own siblings: a schedule needs a
    // caller wired up and remembered, and this one cannot be forgotten. It is
    // a listing and a stat per base — the directories are never opened, and
    // only an expired one costs a `git worktree remove`.
    //
    // Awaited, before the lock: a base old enough to sweep is one no
    // comparison has asked for in a fortnight, so nothing is waiting on it,
    // and doing it here rather than in the background keeps the disk claim
    // and its release in one order a test can drive.
    await sweep(repoRoot: repoRoot, cacheRoot: cacheRoot, spare: path);
    // One creator per sha at a time, across processes — the directory is
    // shared by every worktree on the machine by design, and without the
    // lock a second comparison arriving mid-`resolve` saw a directory with
    // no marker, called it a corpse, and force-removed it out from under the
    // first's `pub get`. The lock lives *beside* the checkout because the
    // recovery path deletes the checkout; blocking is the point: the loser
    // waits out the winner's resolve, then finds the marker and reuses.
    var gate = _inProcess[path] ?? Future<void>.value();
    var done = Completer<void>();
    var turn = gate.then((_) => done.future);
    _inProcess[path] = turn;
    try {
      // The OS lock is advisory *per process* — two ensures inside one GUI
      // would both acquire it — so the in-process queue above serializes
      // those, and the file lock serializes everybody else.
      await gate;
      var lock = File(p.join(cacheRoot, '$sha.lock'))
          .openSync(mode: FileMode.write);
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await _ensureLocked(
          repoRoot: repoRoot,
          sha: sha,
          path: path,
          resolve: resolve,
        );
      } finally {
        // Closing releases the lock.
        lock.closeSync();
      }
    } finally {
      done.complete();
      if (identical(_inProcess[path], turn)) {
        unawaited(_inProcess.remove(path));
      }
    }
  }

  static final _inProcess = <String, Future<void>>{};

  /// Removes the base at [path] under the same exclusion [ensure] takes, and
  /// only if nobody holds it.
  ///
  /// The sweep used to remove an expired base without asking, which reopened
  /// the race the lock exists to close: a comparison reusing a
  /// fortnight-old base takes the lock and finds the marker, while a sweep for
  /// some other sha has already statted that marker as old and runs `worktree
  /// remove --force` out from under it.
  ///
  /// Two layers, as in [ensure], and for the same reason. The file lock is
  /// advisory **per process**: a try-lock here would succeed against an
  /// [ensure] running in this very process, and closing it would drop that
  /// [ensure]'s lock too — so this process's own claim is taken first,
  /// through [_inProcess], which also makes any [ensure] arriving mid-sweep
  /// wait its turn and then rebuild the checkout rather than find it half
  /// gone. Only then is the file lock tried, *non*-blocking, for everybody
  /// else: a sweep is housekeeping, and a base somebody holds is not expired.
  ///
  /// The `.lock` file is left where it is. It is empty, and deleting one that
  /// another process has open would let a third create a fresh inode under
  /// the same name — two holders of "the" lock.
  static Future<bool> _removeIfUnheld({
    required String repoRoot,
    required String path,
  }) async {
    if (_inProcess.containsKey(path)) return false;
    var done = Completer<void>();
    _inProcess[path] = done.future;
    RandomAccessFile? lock;
    try {
      try {
        lock = File('$path.lock').openSync(mode: FileMode.append);
        lock.lockSync(FileLock.exclusive);
      } on FileSystemException {
        return false;
      }
      try {
        await _remove(repoRoot: repoRoot, path: path);
      } on FileSystemException {
        // A base another process is removing at the same moment. The sweep is
        // a courtesy, not a guarantee.
        return false;
      }
      return true;
    } finally {
      lock?.closeSync();
      done.complete();
      if (identical(_inProcess[path], done.future)) {
        unawaited(_inProcess.remove(path));
      }
    }
  }

  static Future<BaseCheckout> _ensureLocked({
    required String repoRoot,
    required String sha,
    required String path,
    required Future<void> Function(String checkout)? resolve,
  }) async {
    // Checked under the lock: the common case after losing the race is that
    // the winner just wrote it.
    var marker = File(p.join(path, _marker));
    if (marker.existsSync()) {
      // Touched on the way past, which is what makes [sweep] an LRU rather
      // than a first-in-first-out — the same move `ShotCache.read` makes, and
      // for the same reason. A base branched off master is written once and
      // then reused by every comparison against it for weeks; on the mtime it
      // was *created* at, that is exactly what an age sweep would take first.
      try {
        marker.setLastModifiedSync(DateTime.now());
      } on FileSystemException {
        // A read-only store, or one another process is sweeping. The checkout
        // is usable either way, and refreshing an age is not worth an
        // exception.
      }
      return BaseCheckout(path: path, sha: sha, created: false);
    }
    // A directory with no marker is a checkout that died between `worktree
    // add` and `resolve` — half-resolved, and worse than nothing, because
    // every later run would reuse it.
    if (Directory(path).existsSync()) {
      await _remove(repoRoot: repoRoot, path: path);
    }

    var added = await runGit([
      '-C',
      repoRoot,
      'worktree',
      'add',
      '--detach',
      path,
      sha,
    ]);
    if (added.exitCode != 0) {
      // The commonest failure is a registration left behind by a checkout
      // somebody deleted by hand, which makes git refuse a path it still
      // believes in. Pruning costs a stat per registered worktree.
      await runGit(['-C', repoRoot, 'worktree', 'prune']);
      added = await runGit([
        '-C',
        repoRoot,
        'worktree',
        'add',
        '--detach',
        path,
        sha,
      ]);
      if (added.exitCode != 0) {
        throw BaseCheckoutError(
          'could not check out $sha to compare against: ${added.stderr}',
        );
      }
    }

    try {
      await resolve?.call(path);
    } catch (_) {
      await _remove(repoRoot: repoRoot, path: path);
      rethrow;
    }
    // Written last, and that ordering is the whole reliability story: the
    // marker means "checked out *and* resolved", so a run killed anywhere
    // before this line leaves a directory that the next run throws away
    // rather than trusts.
    marker.writeAsStringSync(sha);
    return BaseCheckout(path: path, sha: sha, created: true);
  }

  /// Removes this checkout and its registration.
  Future<void> dispose({required String repoRoot}) =>
      _remove(repoRoot: repoRoot, path: path);

  /// Drops every base nothing has asked for in [forget], every one beyond
  /// the [keep] most recently used, and every half-built one older than
  /// [abandonAfter]; returns how many.
  ///
  /// **This directory is shared by every repository on the machine**, so a
  /// sweep run from one project will meet another's bases and take them if
  /// they are old enough. That is correct — a base is disposable and this is
  /// the one place that knows they exist — and the cost of it is a stale
  /// entry in the *other* repository's `.git/worktrees`, which that
  /// repository's own next `ensure` already recovers from: `worktree add`
  /// fails, it prunes, and it retries. Pruning here instead would mean
  /// knowing which repository each base came from, which nothing records.
  ///
  /// [spare] is the base this run is about to use, whatever its age. It is
  /// one of the [keep] whether or not it exists yet.
  ///
  /// Every failure is swallowed per checkout, as housekeeping should be.
  static Future<int> sweep({
    required String repoRoot,
    String? cacheRoot,
    String? spare,
    Duration forget = BaseCheckout.forget,
    int keep = BaseCheckout.keep,
    DateTime? now,
  }) async {
    var root = Directory(cacheRoot ?? defaultRoot);
    if (!root.existsSync()) return 0;
    var at = now ?? DateTime.now();
    var expiry = at.subtract(forget);
    var abandoned = at.subtract(abandonAfter);
    var stale = <String>[];
    var used = <(String, DateTime)>[];
    for (var entity in root.listSync()) {
      if (entity is! Directory) continue;
      var path = entity.path;
      if (spare != null && p.equals(path, spare)) continue;
      var marker = File(p.join(path, _marker));
      try {
        if (marker.existsSync()) {
          used.add((path, marker.statSync().modified));
        } else if (entity.statSync().modified.isBefore(abandoned)) {
          // No marker is a checkout that died between `worktree add` and
          // `resolve` — or one that is between them this moment. Its age
          // tells those apart, and for a creator slower than a day, the lock
          // [_removeIfUnheld] takes does.
          stale.add(path);
        }
      } on FileSystemException {
        continue;
      }
    }
    // The newest few by last use stay whatever their age; the rest go for
    // being old enough, or for being beyond the count.
    var room = spare == null ? keep : keep - 1;
    used.sort((a, b) => b.$2.compareTo(a.$2));
    for (var (i, (path, touched)) in used.indexed) {
      if (i < room && !touched.isBefore(expiry)) continue;
      stale.add(path);
    }
    var swept = 0;
    for (var path in stale) {
      if (await _removeIfUnheld(repoRoot: repoRoot, path: path)) swept++;
    }
    return swept;
  }

  static Future<void> _remove({
    required String repoRoot,
    required String path,
  }) async {
    var removed = await runGit([
      '-C',
      repoRoot,
      'worktree',
      'remove',
      '--force',
      path,
    ]);
    if (removed.exitCode == 0) return;
    // git refuses a path it never registered, which is exactly the state a
    // half-created checkout is in — and the state every base belonging to
    // *another* repository is in, as far as this one is concerned. The
    // directory still has to go.
    var directory = Directory(path);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    await runGit(['-C', repoRoot, 'worktree', 'prune']);
  }

  /// Named with a leading dot so it cannot be mistaken for the project's own
  /// file, and left out of `.gitignore` deliberately: this checkout is
  /// detached and nobody commits from it.
  static const _marker = '.flutterware-base';
}

class BaseCheckoutError implements Exception {
  BaseCheckoutError(this.message);

  final String message;

  @override
  String toString() => message;
}
