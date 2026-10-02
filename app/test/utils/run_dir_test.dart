import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The run directory's housekeeping.
///
/// Nothing swept it until now, and the litter is structural rather than
/// occasional: a daemon's key is a hash that *includes its own build*, so every
/// edit to the daemon leaves behind a socket, a lock and a log under a key
/// nothing will ever use again. One machine had 458 files after three days.
///
/// The interesting cases here are all the ones where deleting would be wrong —
/// a live daemon's log, a lock a client is holding right now, a socket that
/// still answers. [sweepRunDir] resolves those with two rules, and these tests
/// are those two rules.
///
/// The sweeper is pointed at a temp directory per test, so nothing here can
/// reach the developer's real `~/.flutterware/run` — and so a real listening
/// socket can be put in it. That directory is deliberately unnested: a unix
/// socket path is capped at 104 bytes and macOS temp paths start at ~50, which is
/// the same arithmetic that put the run dir under `$HOME` in the first place.
void main() {
  late Directory runDir;

  /// A file in the run dir, [age] old.
  File aged(String name, Duration age) {
    var file = File(p.join(runDir.path, name))..writeAsStringSync('x');
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  /// A run handle naming [launcherPid], [age] old. Only the pid and start
  /// time are read by the sweeper; the rest is there so the file is a real
  /// handle rather than a shape that happens to parse.
  File handle(String name, int launcherPid, Duration age, {DateTime? started}) {
    var file = File(p.join(runDir.path, name))
      ..writeAsStringSync(
        jsonEncode({
          'worktree': '/tmp/wt',
          'worktreeName': '~',
          'device': 'phone',
          'entrypoint': 'lib/main.dart',
          'launcherPid': launcherPid,
          'startedAt': (started ?? DateTime.now()).toUtc().toIso8601String(),
        }),
      );
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  setUp(() => runDir = Directory.systemTemp.createTempSync('fw-run-'));

  tearDown(() {
    if (runDir.existsSync()) runDir.deleteSync(recursive: true);
  });

  Future<int> sweep({Duration keepFor = const Duration(days: 1)}) =>
      sweepRunDir(keepFor: keepFor, directory: runDir.path);

  group('what it deletes', () {
    test('an orphaned lock and log from a key nothing serves', () async {
      var key = 'a' * 16;
      aged('$key.lock', const Duration(days: 3));
      aged('$key.log', const Duration(days: 3));

      expect(await sweep(), 2);
      expect(runDir.listSync(), isEmpty);
    });

    test('a failure marker nobody came back for', () async {
      // Normally the client waiting on the spawn reads it and deletes it. A
      // client that had already connected hears the failure over the socket
      // instead and never looks at the file — so it is orphaned exactly when a
      // daemon fails with somebody attached, and the key moves on every edit to
      // the daemon's own sources.
      var key = 'f' * 16;
      aged('$key.failed', const Duration(days: 3));

      expect(await sweep(), 1);
      expect(runDir.listSync(), isEmpty);
    });

    test('a socket file with nobody listening', () async {
      var key = 'b' * 16;
      // A daemon that died without unlinking leaves a plain file where a socket
      // was — connecting to it fails, which is the liveness test.
      aged('$key.sock', const Duration(days: 3));
      aged('$key.log', const Duration(days: 3));

      expect(await sweep(), 2);
      expect(runDir.listSync(), isEmpty);
    });

    test('a guest socket, without knocking on it', () async {
      // `g-*` and `shot-*` are guest IPC sockets. They are aged out rather than
      // probed, because a guest expects a protocol and not a knock — and
      // unlinking a unix socket does not disturb a connection already
      // established on it.
      aged('g-session-4.sock', const Duration(days: 3));
      aged('shot-deadbeef.sock', const Duration(days: 3));

      expect(await sweep(), 2);
    });

    test('a frame-scratch directory a crash left behind', () async {
      // A session that closes cleanly deletes its own `cap-*`; only a crash
      // leaves one, and a capture in progress keeps its directory's mtime
      // fresh by writing and deleting frames in it.
      var dir = Directory(p.join(runDir.path, 'cap-session-9-0'))..createSync();
      File(p.join(dir.path, 'screenshot.rawframe')).writeAsStringSync('x');
      // `Directory` has no setLastModifiedSync; this file already assumes a
      // unix machine by binding unix-domain sockets.
      var stamp = DateTime.now().subtract(const Duration(days: 3));
      String two(int n) => n.toString().padLeft(2, '0');
      var when =
          '${stamp.year}${two(stamp.month)}${two(stamp.day)}'
          '${two(stamp.hour)}${two(stamp.minute)}';
      Process.runSync('touch', ['-m', '-t', when, dir.path]);

      expect(await sweep(), 1);
      expect(dir.existsSync(), isFalse);
    });

    test("a dead server's socket, and its handle with it", () async {
      // `srv-*` is probed like a daemon, not aged like a guest — but this one
      // is a plain file where a socket was, so nothing answers, and the
      // handle would otherwise keep announcing a server that is gone.
      aged('srv-12ab34cd-api-4242.sock', const Duration(days: 3));
      aged('srv-12ab34cd-api-4242.json', const Duration(days: 3));

      expect(await sweep(), 2);
      expect(runDir.listSync(), isEmpty);
    });

    test('a run handle whose launcher is gone', () async {
      // A run announces itself in `app-*.json` and points at a VM service on a
      // device, so there is no socket here to knock on. The launcher's pid is
      // the one thing this sweeper can check cheaply, and a dead one on a
      // handle this old is what a crash leaves behind.
      var process = await Process.start('true', const []);
      await process.exitCode;
      handle(
        'app-deadbeef1234-${process.pid}.json',
        process.pid,
        const Duration(days: 3),
      );

      expect(await sweep(), 1);
      expect(runDir.listSync(), isEmpty);
    });

    test('a run handle nothing can parse', () async {
      aged('app-torn-1.json', const Duration(days: 3));

      expect(await sweep(), 1);
      expect(runDir.listSync(), isEmpty);
    });
  });

  group('what it spares', () {
    test("a living run's journal, however old", () async {
      // The handle is still in the ledger — its launcher is this very test's
      // process — so the run's story stays replayable in the Steps tab. Only
      // the handle's own death starts the journal's clock.
      handle('app-z-$pid.json', pid, const Duration(days: 3));
      aged('app-z-$pid.journal.jsonl', const Duration(days: 30));

      expect(await sweep(), 0);
      expect(runDir.listSync(), hasLength(2));
    });

    test('a run handle whose launcher is still alive, however old', () async {
      // A desktop session can legitimately be up since Monday. Sweeping its
      // handle would free a device that is very much in use — the same lie the
      // `srv-*` rule exists to avoid, arrived at from the other side.
      handle('app-abcdef123456-$pid.json', pid, const Duration(days: 30));

      expect(await sweep(), 0);
      expect(runDir.listSync(), hasLength(1));
    });

    test("a dead run's journal, its rotation and its artifacts", () async {
      // No handle named app-x-9 exists, so the story's run is gone and the
      // story ages out. Before this rule the journals matched no sweep rule
      // and grew forever.
      aged('app-x-9.journal.jsonl', const Duration(days: 3));
      aged('app-x-9.journal.jsonl.1', const Duration(days: 3));
      var artifacts = Directory(p.join(runDir.path, 'journal', 'app-x-9'))
        ..createSync(recursive: true);
      File(p.join(artifacts.path, '1-9.png')).writeAsStringSync('x');
      // `File.setLastModifiedSync` has no `Directory` counterpart.
      var old = DateTime.now().subtract(const Duration(days: 3));
      String two(int n) => n.toString().padLeft(2, '0');
      Process.runSync('touch', [
        '-mt',
        '${old.year}${two(old.month)}${two(old.day)}${two(old.hour)}${two(old.minute)}',
        artifacts.path,
      ]);

      expect(await sweep(), 3);
      expect(artifacts.existsSync(), isFalse);
    });

    test('a journal in the same pass as its dying handle', () async {
      // The handle is swept by loop three — dead launcher — and the journal
      // rule runs after it, so one pass takes the run and its story together
      // rather than leaving the story for tomorrow's sweep.
      var dead = await _deadPid();
      handle('app-y-$dead.json', dead, const Duration(days: 3));
      aged('app-y-$dead.journal.jsonl', const Duration(days: 3));

      expect(await sweep(), 2);
      expect(runDir.listSync(), isEmpty);
    });

    test('a run handle whose pid was recycled is swept anyway', () async {
      // The pid is alive — it is this very test's — but the handle claims a
      // launcher recorded two days ago, and this process is minutes old. A
      // number that young is somebody else wearing a dead launcher's pid;
      // without the age check the handle read as alive forever and pinned
      // its device as busy in every worktree.
      handle(
        'app-abcdef123456-$pid.json',
        pid,
        const Duration(days: 3),
        started: DateTime.now().subtract(const Duration(days: 2)),
      );

      expect(await sweep(), 1);
      expect(runDir.listSync(), isEmpty);
    });

    test('the device cache, which is bounded and self-refreshing', () async {
      // One file per machine, overwritten by the next daemon. Deleting it only
      // makes a cold `fw devices` answer "nobody has ever looked".
      aged('devices.json', const Duration(days: 30));

      expect(await sweep(), 0);
      expect(runDir.listSync(), hasLength(1));
    });

    test('a server socket that still answers, however old', () async {
      // The guest rule would be wrong here: a dev server legitimately runs
      // for days, and unlinking a live one's socket makes it unreachable for
      // new attachers — the next scan would then delete its handle as dead,
      // and the server would vanish from the list while still running. The
      // probe is free: an inspected server writes nothing to a connection
      // that has not sent `meta/attach`.
      var base = 'srv-12ab34cd-api-4242';
      var socketPath = p.join(runDir.path, '$base.sock');
      var server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(() async {
        await server.close();
        if (File(socketPath).existsSync()) File(socketPath).deleteSync();
      });
      File(
        socketPath,
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
      aged('$base.json', const Duration(days: 3));

      expect(await sweep(), 0);
      expect(File(socketPath).existsSync(), isTrue);
      expect(
        File(p.join(runDir.path, '$base.json')).existsSync(),
        isTrue,
        reason: "a live server's handle is what keeps it discoverable",
      );
    });

    test("a world owner's socket that still answers, however old", () async {
      // A world open in the studio for days is reached by every other
      // process through this socket: aged out like a guest's, it went on
      // listening, unlinked, and nobody could ask it anything.
      var socketPath = p.join(runDir.path, 'world-owner-61199-1.sock');
      var server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(() async {
        await server.close();
        if (File(socketPath).existsSync()) File(socketPath).deleteSync();
      });
      File(
        socketPath,
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
      aged('world-owner-4242-0.sock', const Duration(days: 3));

      // The dead one goes; the one listening stays.
      expect(await sweep(), 1);
      expect(File(socketPath).existsSync(), isTrue);
    });

    test('anything modified inside the window', () async {
      // The rule that protects everything in use: a live daemon appends to its
      // log, and a client deciding whether to spawn has just created its lock.
      var key = 'c' * 16;
      aged('$key.lock', const Duration(minutes: 1));
      aged('$key.log', const Duration(minutes: 1));
      aged('g-fresh.sock', const Duration(minutes: 1));
      Directory(p.join(runDir.path, 'cap-session-1-0')).createSync();

      expect(await sweep(), 0);
      expect(runDir.listSync(), hasLength(4));
    });

    test('a log old enough to delete, whose daemon still answers', () async {
      // The case that matters most. A daemon can legitimately run for days;
      // unlinking its socket would leave it running and unreachable, which is
      // worse than the litter it was cleaning up.
      var key = 'd' * 16;
      var socketPath = p.join(runDir.path, '$key.sock');
      var server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(() async {
        await server.close();
        if (File(socketPath).existsSync()) File(socketPath).deleteSync();
      });
      File(
        socketPath,
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
      aged('$key.log', const Duration(days: 3));

      expect(await sweep(), 0);
      expect(File(socketPath).existsSync(), isTrue);
      expect(
        File(p.join(runDir.path, '$key.log')).existsSync(),
        isTrue,
        reason: "a serving daemon's log is its own, however old",
      );
    });

    test(
      'a published live session, which is bounded and self-healing',
      () async {
        // One file per project ever, and `attachToLiveSession` already deletes one
        // that will not connect. Ageing these out would break attach for a GUI
        // that has simply been open a long time.
        aged('live-${'e' * 16}.json', const Duration(days: 30));

        expect(await sweep(), 0);
        expect(runDir.listSync(), hasLength(1));
      },
    );

    test('a file it does not recognise', () async {
      aged('something-a-person-put-here.txt', const Duration(days: 30));

      expect(await sweep(), 0);
      expect(runDir.listSync(), hasLength(1));
    });
  });

  test('a missing run directory is not an error', () async {
    runDir.deleteSync(recursive: true);
    expect(await sweep(), 0);
  });

  group('checkSocketPath', () {
    test('accepts a path the OS will take', () {
      expect(checkSocketPath('/tmp/short.sock'), '/tmp/short.sock');
    });

    test('names the limit and the offender', () {
      var tooLong = '/tmp/${'x' * 200}.sock';
      expect(
        () => checkSocketPath(tooLong),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('$maxSocketPathLength-byte'),
              contains('flutterwareRunDir'),
            ),
          ),
        ),
      );
    });
  });

  group('process age', () {
    // `etime` rather than `lstart` because elapsed prints the same way in
    // every locale. These pin the format: [[dd-]hh:]mm:ss.
    test('parses every etime shape ps produces', () {
      expect(parseElapsed('04:05'), const Duration(minutes: 4, seconds: 5));
      expect(
        parseElapsed(' 03:04:05\n'),
        const Duration(hours: 3, minutes: 4, seconds: 5),
      );
      expect(
        parseElapsed('12-03:04:05'),
        const Duration(days: 12, hours: 3, minutes: 4, seconds: 5),
      );
      expect(parseElapsed('nonsense'), isNull);
      expect(parseElapsed(''), isNull);
    });

    test('this process is current against a record from before it', () {
      expect(isProcessCurrent(pid, DateTime.now()), isTrue);
    });

    test('this process is not the launcher a day-old record names', () {
      expect(
        isProcessCurrent(pid, DateTime.now().subtract(const Duration(days: 1))),
        isFalse,
      );
    });
  });

  /// The launcher calls this on every launch — see `run/launch.dart` — so the
  /// guard is what keeps a long-lived GUI from re-walking the directory to find
  /// nothing, over and over, for the life of the session.
  group('once per process', () {
    setUp(debugResetRunDirSweep);
    tearDown(debugResetRunDirSweep);

    test('the first call sweeps and the second does not', () async {
      var key = 'a' * 16;
      aged('$key.lock', const Duration(days: 3));
      aged('$key.log', const Duration(days: 3));

      expect(await sweepRunDirOnce(runDir.path), 2);

      aged('${'b' * 16}.lock', const Duration(days: 3));
      expect(await sweepRunDirOnce(runDir.path), 0);
      expect(runDir.listSync(), hasLength(1));
    });

    test('a directory that cannot be read is not an error', () async {
      expect(await sweepRunDirOnce(p.join(runDir.path, 'nothing', 'here')), 0);
    });
  });

  /// A daemon's build directory is named by its address, and an address hashes
  /// the whole config — so every change to what the daemon is given orphans one
  /// whole, `out/` and `assets/` included. The Impeller flags did it to every
  /// project on every machine at once; one worktree measured 3.6 GB across 30
  /// directories, all but one dead.
  group('abandoned catalog build directories', () {
    late Directory catalog;

    /// A build directory for [key], whose newest content is [age] old.
    Directory built(String key, Duration age) {
      var dir = Directory(p.join(catalog.path, key))
        ..createSync(recursive: true);
      var file = File(p.join(dir.path, 'kernel_blob.bin'))
        ..writeAsStringSync('x');
      file.setLastModifiedSync(DateTime.now().subtract(age));
      return dir;
    }

    setUp(() => catalog = Directory.systemTemp.createTempSync('fw-catalog-'));
    tearDown(() {
      if (catalog.existsSync()) catalog.deleteSync(recursive: true);
    });

    int drop({String liveKey = 'live'}) => sweepCatalogBuildDirs(
      catalogDir: catalog.path,
      liveKey: liveKey,
      keepFor: const Duration(days: 1),
      runDir: runDir.path,
    );

    test('a key nothing serves, and everything under it', () async {
      var dead = built('a' * 16, const Duration(days: 3));
      expect(drop(), 1);
      expect(dead.existsSync(), isFalse);
    });

    test("never this daemon's own, however old it looks", () async {
      var mine = 'b' * 16;
      built(mine, const Duration(days: 30));
      expect(drop(liveKey: mine), 0);
    });

    test('never `kernels`, which is not a key', () async {
      // The warm kernel and the quarantine live there and outlive every
      // address — deleting it would turn a config change into a cold compile
      // for every worktree that had one.
      var kernels = Directory(p.join(catalog.path, 'kernels', 'deadbeef'))
        ..createSync(recursive: true);
      File(p.join(kernels.path, 'warm.dill')).writeAsStringSync('x');
      Process.runSync('touch', [
        '-m',
        '-t',
        '202001010000',
        kernels.parent.path,
      ]);

      expect(drop(), 0);
      expect(kernels.existsSync(), isTrue);
    });

    test('never one whose key still has a socket bound', () {
      // **Existence, never a knock.** `_answers` gives up after a second, and a
      // second is a duration a live daemon can miss under load — three
      // integration files at once and 3.7 GB being deleted was enough to make
      // it, and the daemon whose `out/` went with it died on its next write.
      // A socket file that is really dead is unlinked by [sweepRunDir] first,
      // so this only ever costs a directory one more start of patience.
      var key = 'e' * 16;
      built(key, const Duration(days: 30));
      File(p.join(runDir.path, '$key.sock')).writeAsStringSync('');

      expect(drop(), 0);
      expect(Directory(p.join(catalog.path, key)).existsSync(), isTrue);
    });

    test('never one still being written into', () async {
      built('c' * 16, const Duration(minutes: 5));
      expect(drop(), 0);
    });

    test(
      'the age is the newest thing inside, not the directory stamp',
      () async {
        // A directory's own mtime moves when an entry is added or removed, so a
        // daemon up for a week — rewriting files already in place — has an
        // ancient stamp and a very live directory.
        var dir = built('d' * 16, const Duration(minutes: 1));
        Process.runSync('touch', ['-m', '-t', '202001010000', dir.path]);
        expect(drop(), 0, reason: 'its kernel was written a minute ago');
        expect(dir.existsSync(), isTrue);
      },
    );
  });

  /// A `flutter_tester` guest is the one child flutterware spawns that outlives
  /// its owner. Measured on one machine: 19 with `ppid` 1, the oldest up 1 day
  /// 23 hours, against zero orphaned `frontend_server`s. `TesterHost.dispose`
  /// kills its guest and always did; what it cannot cover is the owner dying
  /// before it gets there, which no in-process hook can. So the rules below are
  /// about deciding, from a file, whether somebody is still coming back for it.
  group('orphaned guests', () {
    late List<Process> spawned;

    setUp(() {
      spawned = [];
      debugResetGuestSweep();
    });

    tearDown(() {
      for (var process in spawned) {
        process.kill(ProcessSignal.sigkill);
      }
      debugResetGuestSweep();
    });

    /// A process that will not exit on its own, so that "was it killed" is a
    /// question with only one answer.
    Future<Process> sleeper() async {
      var process = await Process.start('sleep', const ['60']);
      spawned.add(process);
      return process;
    }

    /// A guest handle written by hand, so a test can name an owner this
    /// process is not.
    void guestHandle({
      required int guestPid,
      required int ownerPid,
      DateTime? startedAt,
      DateTime? ownerRecordedAt,
    }) {
      File(p.join(runDir.path, 'guest-$guestPid.json')).writeAsStringSync(
        jsonEncode({
          'pid': guestPid,
          'startedAt': (startedAt ?? DateTime.now()).toIso8601String(),
          'ownerPid': ownerPid,
          'ownerRecordedAt': (ownerRecordedAt ?? DateTime.now())
              .toIso8601String(),
          'what': 'previews',
        }),
      );
    }

    int sweepGuests() => sweepOrphanedGuests(directory: runDir.path);

    bool handlesLeft() =>
        runDir.listSync().any((e) => p.basename(e.path).startsWith('guest-'));

    test('one whose owner is gone is killed', () async {
      var guest = await sleeper();
      guestHandle(guestPid: guest.pid, ownerPid: await _deadPid());

      expect(sweepGuests(), 1);
      await guest.exitCode.timeout(const Duration(seconds: 10));
      expect(handlesLeft(), isFalse, reason: 'the handle goes with it');
    });

    test('one whose owner is still there is left alone', () async {
      var owner = await sleeper();
      var guest = await sleeper();
      guestHandle(guestPid: guest.pid, ownerPid: owner.pid);

      expect(sweepGuests(), 0);
      expect(handlesLeft(), isTrue);
      expect(
        isProcessAlive(guest.pid),
        isTrue,
        reason: 'somebody is still coming back for it',
      );
    });

    test('one this process just spawned is left alone', () async {
      // The guard on the hot-restart rule below. Without it a second host
      // starting while the first sweeps has its brand-new guest read as
      // abandoned, and killed.
      var guest = await sleeper();
      recordSpawnedGuest(
        pid: guest.pid,
        what: 'previews',
        directory: runDir.path,
      );
      addTearDown(() => forgetSpawnedGuest(guest.pid, directory: runDir.path));

      expect(sweepGuests(), 0);
      expect(isProcessAlive(guest.pid), isTrue);
    });

    test(
      'one this process left behind before it restarted is killed',
      () async {
        // A Flutter hot restart replaces the isolate and keeps the process, so
        // `dispose` never runs and the new incarnation spawns beside the old
        // guests. The handle names a live owner — us — and is an orphan anyway.
        var guest = await sleeper();
        guestHandle(guestPid: guest.pid, ownerPid: pid);

        expect(sweepGuests(), 1);
        await guest.exitCode.timeout(const Duration(seconds: 10));
      },
    );

    test('a recycled owner pid does not shield it for ever', () async {
      // The reason the owner is checked with [isProcessCurrent] and not with
      // [isProcessAlive]: a handle can outlive a pid's recycling, and believing
      // the new occupant would keep an orphan alive until the disk was cleared
      // by hand.
      var occupant = await sleeper();
      var guest = await sleeper();
      guestHandle(
        guestPid: guest.pid,
        ownerPid: occupant.pid,
        ownerRecordedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );

      expect(
        sweepGuests(),
        1,
        reason: 'the owner it names started after the handle was written',
      );
      await guest.exitCode.timeout(const Duration(seconds: 10));
    });

    test('one that already exited leaves only its handle to remove', () async {
      guestHandle(guestPid: await _deadPid(), ownerPid: await _deadPid());
      expect(sweepGuests(), 0, reason: 'nothing was killed');
      expect(handlesLeft(), isFalse, reason: 'but nothing is left to read');
    });

    test('a handle nothing can parse is litter', () {
      File(p.join(runDir.path, 'guest-123.json')).writeAsStringSync('{oh no');
      expect(sweepGuests(), 0);
      expect(handlesLeft(), isFalse);
    });

    test('the first sweep runs and the second does not', () async {
      var first = await sleeper();
      guestHandle(guestPid: first.pid, ownerPid: await _deadPid());
      expect(sweepOrphanedGuestsOnce(directory: runDir.path), 1);
      await first.exitCode.timeout(const Duration(seconds: 10));

      var second = await sleeper();
      guestHandle(guestPid: second.pid, ownerPid: await _deadPid());
      expect(sweepOrphanedGuestsOnce(directory: runDir.path), 0);
      expect(isProcessAlive(second.pid), isTrue);
    });
  });
}

/// A pid that is certainly gone: a process started and waited for.
///
/// Better than a large constant, which is only *probably* free and would make
/// these tests flaky on whichever machine happened to be using it.
Future<int> _deadPid() async {
  var process = await Process.start('true', const []);
  await process.exitCode;
  return process.pid;
}
