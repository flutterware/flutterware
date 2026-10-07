import 'dart:io';

import 'package:flutterware_app/src/comparison/base_checkout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/lock_holder.dart';

/// The other side of a comparison, on disk: checked out once per commit,
/// shared by every worktree on the machine, and disposable.
void main() {
  late Directory root;
  late String repo;
  late String cache;

  Future<String> git(List<String> args, {String? at}) async {
    var result = await Process.run('git', ['-C', at ?? repo, ...args]);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')}: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fw_base');
    repo = p.join(root.path, 'repo');
    cache = p.join(root.path, 'bases');
    Directory(repo).createSync();
    await git(['init', '-b', 'main']);
    await git(['config', 'user.email', 'test@example.com']);
    await git(['config', 'user.name', 'Test']);
    File(p.join(repo, 'card.dart')).writeAsStringSync('const card = 1;');
    await git(['add', '.']);
    await git(['commit', '-m', 'first']);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a base is the repo at that commit', () async {
    var sha = await git(['rev-parse', 'HEAD']);
    File(p.join(repo, 'card.dart')).writeAsStringSync('const card = 2;');

    var base = await BaseCheckout.ensure(
      repoRoot: repo,
      sha: sha,
      cacheRoot: cache,
    );

    expect(base.created, isTrue);
    expect(
      File(p.join(base.path, 'card.dart')).readAsStringSync(),
      'const card = 1;',
    );
  });

  // Every comparison after the first against a given base, which is the case
  // worth being fast at.
  test(
    'a second comparison against the same commit checks out nothing',
    () async {
      var sha = await git(['rev-parse', 'HEAD']);
      var resolves = 0;

      var first = await BaseCheckout.ensure(
        repoRoot: repo,
        sha: sha,
        cacheRoot: cache,
        resolve: (_) async => resolves++,
      );
      var second = await BaseCheckout.ensure(
        repoRoot: repo,
        sha: sha,
        cacheRoot: cache,
        resolve: (_) async => resolves++,
      );

      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(second.path, first.path);
      expect(resolves, 1);
    },
  );

  // The marker is written after `resolve`, so a run killed between the two
  // leaves a directory the next run throws away rather than trusts.
  test('two concurrent ensures share one checkout and one resolve', () async {
    // The race this guards: the second arrival used to see a directory with
    // no marker — the first's `pub get` still running — call it a corpse and
    // force-remove it out from under the first. Serialized, the loser waits,
    // finds the marker, and reuses.
    var sha = await git(['rev-parse', 'HEAD']);
    var resolves = 0;

    Future<BaseCheckout> ensure() => BaseCheckout.ensure(
      repoRoot: repo,
      sha: sha,
      cacheRoot: cache,
      resolve: (_) async {
        resolves++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
    );

    var results = await Future.wait([ensure(), ensure()]);

    expect(resolves, 1);
    expect(results.map((base) => base.created), containsAll([true, false]));
    expect(results.first.path, results.last.path);
  });

  test('a checkout that never finished resolving is not reused', () async {
    var sha = await git(['rev-parse', 'HEAD']);

    await expectLater(
      BaseCheckout.ensure(
        repoRoot: repo,
        sha: sha,
        cacheRoot: cache,
        resolve: (_) async => throw StateError('pub get failed'),
      ),
      throwsStateError,
    );
    expect(Directory(p.join(cache, sha)).existsSync(), isFalse);

    var retry = await BaseCheckout.ensure(
      repoRoot: repo,
      sha: sha,
      cacheRoot: cache,
    );

    expect(retry.created, isTrue);
  });

  // A registration left behind by a checkout somebody deleted by hand makes
  // git refuse a path it still believes in.
  test('a stale registration is pruned rather than fatal', () async {
    var sha = await git(['rev-parse', 'HEAD']);
    var base = await BaseCheckout.ensure(
      repoRoot: repo,
      sha: sha,
      cacheRoot: cache,
    );
    Directory(base.path).deleteSync(recursive: true);

    var again = await BaseCheckout.ensure(
      repoRoot: repo,
      sha: sha,
      cacheRoot: cache,
    );

    expect(again.created, isTrue);
    expect(File(p.join(again.path, 'card.dart')).existsSync(), isTrue);
  });

  test('disposing leaves neither directory nor registration', () async {
    var sha = await git(['rev-parse', 'HEAD']);
    var base = await BaseCheckout.ensure(
      repoRoot: repo,
      sha: sha,
      cacheRoot: cache,
    );

    await base.dispose(repoRoot: repo);

    expect(Directory(base.path).existsSync(), isFalse);
    expect(await git(['worktree', 'list']), isNot(contains(base.path)));
  });

  // Measured on one machine before this existed: `~/.flutterware/bases` was
  // **12GB across 45 checkouts**, several of them half a gigabyte, and
  // `dispose` carried a confession that nothing called it on a schedule.
  group('the sweep', () {
    /// Ages [base]'s marker by moving its mtime back.
    void age(String base, Duration by) {
      var marker = File(p.join(base, '.flutterware-base'));
      marker.setLastModifiedSync(DateTime.now().subtract(by));
    }

    Future<BaseCheckout> checkout(String sha) =>
        BaseCheckout.ensure(repoRoot: repo, sha: sha, cacheRoot: cache);

    test('drops a base nothing has asked for', () async {
      var sha = await git(['rev-parse', 'HEAD']);
      var base = await checkout(sha);
      age(base.path, const Duration(days: 30));

      var swept = await BaseCheckout.sweep(repoRoot: repo, cacheRoot: cache);

      expect(swept, 1);
      expect(Directory(base.path).existsSync(), isFalse);
      // And git no longer believes in it, which is the half a plain delete
      // would have left behind.
      expect(await git(['worktree', 'list']), isNot(contains(base.path)));
      // The lock file stays. Deleting one another process has open lets a
      // third create a fresh inode under the same name — two holders of "the"
      // lock — and an empty file costs nothing.
      expect(File('${base.path}.lock').existsSync(), isTrue);
    });

    // A comparison reusing an old base holds its lock while it renders; the
    // sweep used to `worktree remove --force` it regardless, on the strength
    // of an mtime it had read a moment before.
    test('leaves a base somebody holds, however old', () async {
      var sha = await git(['rev-parse', 'HEAD']);
      var base = await checkout(sha);
      age(base.path, const Duration(days: 30));
      await holdLock('${base.path}.lock');

      expect(await BaseCheckout.sweep(repoRoot: repo, cacheRoot: cache), 0);
      expect(Directory(base.path).existsSync(), isTrue);
    });

    test('keeps one inside the window', () async {
      var sha = await git(['rev-parse', 'HEAD']);
      var base = await checkout(sha);
      age(base.path, const Duration(days: 3));

      expect(await BaseCheckout.sweep(repoRoot: repo, cacheRoot: cache), 0);
      expect(Directory(base.path).existsSync(), isTrue);
    });

    // A base off master is written once and reused by every comparison
    // against it for weeks. On the mtime it was *created* at, that is exactly
    // what an age sweep would take first.
    test('reuse is what keeps a base alive, not creation', () async {
      var sha = await git(['rev-parse', 'HEAD']);
      var base = await checkout(sha);
      age(base.path, const Duration(days: 30));

      // Asking for it again is the touch.
      await checkout(sha);

      expect(await BaseCheckout.sweep(repoRoot: repo, cacheRoot: cache), 0);
      expect(Directory(base.path).existsSync(), isTrue);
    });

    test('never the base the run is about to use', () async {
      var sha = await git(['rev-parse', 'HEAD']);
      var base = await checkout(sha);
      age(base.path, const Duration(days: 30));

      var swept = await BaseCheckout.sweep(
        repoRoot: repo,
        cacheRoot: cache,
        spare: base.path,
      );

      expect(swept, 0);
      expect(Directory(base.path).existsSync(), isTrue);
    });

    // Age is the wrong unit on a CI runner: the base is the merge base with
    // trunk, which moves with every merge, so each base serves one job and
    // then sits out the fortnight — measured, 70GB of them.
    test(
      'beyond the most recently used few, a base goes however young',
      () async {
        var bases = <BaseCheckout>[];
        for (var i = 1; i <= 3; i++) {
          File(p.join(repo, 'card.dart'))
              .writeAsStringSync('const card = ${i + 1};');
          await git(['add', '.']);
          await git(['commit', '-m', 'commit $i']);
          var base = await checkout(await git(['rev-parse', 'HEAD']));
          age(base.path, Duration(days: 4 - i));
          bases.add(base);
        }

        var swept = await BaseCheckout.sweep(
          repoRoot: repo,
          cacheRoot: cache,
          keep: 2,
        );

        expect(swept, 1);
        expect(Directory(bases[0].path).existsSync(), isFalse);
        expect(Directory(bases[1].path).existsSync(), isTrue);
        expect(Directory(bases[2].path).existsSync(), isTrue);
      },
    );

    test('the base about to be used is one of the few', () async {
      var older = await checkout(await git(['rev-parse', 'HEAD']));
      age(older.path, const Duration(days: 2));
      File(p.join(repo, 'card.dart')).writeAsStringSync('const card = 2;');
      await git(['add', '.']);
      await git(['commit', '-m', 'second']);
      var newer = await checkout(await git(['rev-parse', 'HEAD']));
      age(newer.path, const Duration(days: 1));

      var swept = await BaseCheckout.sweep(
        repoRoot: repo,
        cacheRoot: cache,
        keep: 1,
        spare: older.path,
      );

      expect(swept, 1);
      expect(Directory(older.path).existsSync(), isTrue);
      expect(Directory(newer.path).existsSync(), isFalse);
    });

    // Half-built, and fresh: `_ensureLocked` throws these away when it meets
    // one under its own lock, which is the only place that knows whether a
    // run is still inside it.
    test('leaves a checkout that never finished resolving', () async {
      var half = Directory(p.join(cache, 'deadbeef'))
        ..createSync(recursive: true);

      expect(await BaseCheckout.sweep(repoRoot: repo, cacheRoot: cache), 0);
      expect(half.existsSync(), isTrue);
    });

    // The marker is written after `pub get` succeeds, so a run killed before
    // that — a cancelled CI job, routinely — leaves a directory with none,
    // which only an `ensure` of the same sha would ever replace.
    test('a half-built checkout nobody came back to is dropped', () async {
      var half = Directory(p.join(cache, 'deadbeef'))
        ..createSync(recursive: true);

      var swept = await BaseCheckout.sweep(
        repoRoot: repo,
        cacheRoot: cache,
        now: DateTime.now().add(const Duration(days: 2)),
      );

      expect(swept, 1);
      expect(half.existsSync(), isFalse);
    });

    test('a half-built checkout somebody holds is left, however old', () async {
      var half = Directory(p.join(cache, 'deadbeef'))
        ..createSync(recursive: true);
      await holdLock('${half.path}.lock');

      var swept = await BaseCheckout.sweep(
        repoRoot: repo,
        cacheRoot: cache,
        now: DateTime.now().add(const Duration(days: 2)),
      );

      expect(swept, 0);
      expect(half.existsSync(), isTrue);
    });

    // It cannot be forgotten, which is the whole argument for putting it
    // here rather than on a schedule.
    test('every checkout sweeps its siblings', () async {
      var first = await git(['rev-parse', 'HEAD']);
      var stale = await checkout(first);
      age(stale.path, const Duration(days: 30));

      File(p.join(repo, 'card.dart')).writeAsStringSync('const card = 3;');
      await git(['add', '.']);
      await git(['commit', '-m', 'second']);
      await checkout(await git(['rev-parse', 'HEAD']));

      expect(Directory(stale.path).existsSync(), isFalse);
    });
  });

  // Base checkouts are real git worktrees, so the explorer — whose whole
  // purpose is *which one was I in* — would otherwise grow a row named after a
  // sha every time somebody compares against master.
  test('a base is recognisable as one, so the explorer can hide it', () {
    expect(
      BaseCheckout.isBasePath(p.join(cache, 'abc123'), root: cache),
      isTrue,
    );
    expect(
      BaseCheckout.isBasePath(
        p.join(root.path, 'projects', 'app'),
        root: cache,
      ),
      isFalse,
    );
  });
}
