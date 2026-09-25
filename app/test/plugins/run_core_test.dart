import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart' show AttachSession;
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/run_address.dart';
import 'package:flutterware_app/src/plugins/native/run_plugin.dart';
import 'package:flutterware_app/src/plugins/native/run_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/run/channel_client.dart';
import 'package:flutterware_app/src/run/entrypoints.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/inventory.dart';
import 'package:flutterware_app/src/run/launch.dart';
import 'package:flutterware_app/src/run/refusal.dart';
import 'package:flutterware_app/src/run/run_files.dart';
import 'package:flutterware_app/src/run/run_sources.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/daemon/device.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

import '../support/dart_executable.dart';

/// The devices-and-occupancy half of the run cockpit, against a temp run dir.
///
/// No `flutter daemon` is started anywhere here: the cache is a file, and this
/// exercises the path a cold `fw` takes — read the file, scan the ledger, probe
/// what it found, say how old the answer is.
void main() {
  late Directory runDir;
  late Directory worktree;
  late Directory otherWorktree;
  late RunCore core;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-run-');
    worktree = Directory.systemTemp.createTempSync('fw-run-wt-');
    otherWorktree = Directory.systemTemp.createTempSync('fw-run-other-');
    RunCore.runDirProvider = () => runDir.path;
    core = _coreFor(worktree);
  });

  tearDown(() {
    core.dispose();
    RunCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, worktree, otherWorktree]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('the device cache', () {
    test('round-trips through the file and carries its age', () {
      DeviceCache.write(runDir.path, [
        const DaemonDevice(
          id: 'RF8M12L8GHW',
          name: 'SM G970F',
          platform: 'android-arm64',
          platformType: 'android',
          sdk: 'Android 12 (API 31)',
          connectionInterface: 'attached',
        ),
      ]);

      var cache = DeviceCache.read(runDir.path)!;
      expect(cache.devices.single.displayName, 'SM G970F');
      expect(cache.devices.single.isWireless, isFalse);
      expect(cache.ageDescription, 'just now');
    });

    test('is null when nothing has ever written one', () {
      expect(DeviceCache.read(runDir.path), isNull);
    });

    test('drops a device with no id rather than the whole list', () {
      File(DeviceCache.pathIn(runDir.path)).writeAsStringSync(
        jsonEncode({
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'devices': [
            {'name': 'nameless'},
            {'id': 'good', 'name': 'Good'},
          ],
        }),
      );

      expect(DeviceCache.read(runDir.path)!.devices.single.id, 'good');
    });

    test('orders physical devices before emulators and desktops', () {
      var devices = [
        const DaemonDevice(id: 'macos', name: 'macOS', ephemeral: false),
        const DaemonDevice(id: 'sim', name: 'iPhone 16 sim', emulator: true),
        const DaemonDevice(id: 'phone', name: 'Xavier iPhone'),
      ]..sort(compareDevices);

      expect([for (var d in devices) d.id], ['phone', 'sim', 'macos']);
    });
  });

  group('the ledger', () {
    test("lists every worktree's runs, newest first", () {
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'a.dart',
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      _writeHandle(runDir, otherWorktree, device: 'sim', entrypoint: 'b.dart');

      var handles = scanRunHandles(runDir.path);
      expect([for (var h in handles) h.entrypoint], ['b.dart', 'a.dart']);
    });

    test('filters to one worktree when asked, including the root itself', () {
      _writeHandle(runDir, worktree, device: 'phone', entrypoint: 'a.dart');
      _writeHandle(runDir, otherWorktree, device: 'sim', entrypoint: 'b.dart');

      var handles = scanRunHandles(runDir.path, underRoot: worktree.path);
      expect(handles.single.entrypoint, 'a.dart');
    });

    test('ignores a handle it cannot read', () {
      File(p.join(runDir.path, 'app-torn-1.json')).writeAsStringSync('{"wor');
      expect(scanRunHandles(runDir.path), isEmpty);
    });
  });

  group('report', () {
    /// `screenshot` was dispatched and never declared, which made it
    /// invisible to `fw run run`, unanswerable by `--help`, and exempt from
    /// the argument check — that check is keyed on the declaration. A
    /// consumer's `screenshot --output=…` therefore wrote the default path and
    /// reported success for a flag that does not exist.
    ///
    /// Declaring it is half the fix; the other half is that an undeclared
    /// action is no longer invocable at all, so this cannot come back as a
    /// silent gap. See `session/undeclared_action_test.dart`.
    test('declares screenshot, with the parameters it actually reads', () {
      var action = core.report.actions
          .where((a) => a.id == 'screenshot')
          .singleOrNull;

      expect(action, isNotNull, reason: 'dispatched, so it must be declared');
      expect([
        for (var parameter in action!.parameters) parameter.id,
      ], containsAll(['out', 'maxSide', 'run']));
    });

    test('reads the cache and the ledger without probing anything', () async {
      DeviceCache.write(runDir.path, [
        const DaemonDevice(id: 'phone', name: 'Xavier iPhone'),
        const DaemonDevice(id: 'sim', name: 'iPhone 16 sim', emulator: true),
      ]);
      var dead = await _deadPid();
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: dead,
      );

      await core.computeAll();
      var report = core.report;

      // The rail says nothing at rest — the device count is the desk
      // button's business, not this worktree's.
      expect(report.status, Status.none);
      // **The children are runs, not devices.** A child's id becomes the first
      // address segment, and since the panel became run-centric those are the
      // only things it can be pointed at. Devices are listed in the desk.
      expect(
        [for (var c in report.children) c.id],
        [runHandleKey(worktree.path, 'phone', 'lib/main.dart')],
      );
      expect(report.children.single.label, contains('main.dart'));
      // Nothing has been probed, and computeAll may not open a socket to find
      // out — so the row says it does not know rather than guessing.
      expect(report.children.single.status.message, contains('not probed'));
      // The dead handle is still on disk, for the same reason.
      expect(scanRunHandles(runDir.path), hasLength(1));
    });

    test('says the list is only cached when no daemon is running', () async {
      DeviceCache.write(runDir.path, [const DaemonDevice(id: 'phone')]);
      await core.computeAll();
      expect(core.isLive, isFalse);
      // The age moved off the rail with the count; the panel still says it.
      expect(core.report.view.toText(), contains('just now'));
    });

    test("the rail lists this worktree's runs, not the machine's", () async {
      // The ledger stays every worktree's — that is what makes "who holds the
      // phone" answerable — but the rail's rows are subjects you can drive,
      // and another checkout's app is not one of yours. It reaches you through
      // the desk's worktree-jump instead.
      var mine = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'sim',
        entrypoint: 'lib/main.dart',
        worktreeName: 'feature-x',
        launcherPid: pid,
      );

      await core.computeAll();

      expect(core.handles, hasLength(2));
      expect(core.ownHandles.single.key, mine.key);
      expect([for (var c in core.report.children) c.id], [mine.key]);
      // The badge counts the rows, so it cannot claim runs the rail will not
      // show.
      expect(core.report.badge.count, 1);
    });

    test("another worktree's cold build does not hold this window", () async {
      // `isStarting` gates `busyWith`, and a capture of this worktree must
      // not wait out another checkout's ninety-second Android build.
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );

      await core.computeAll();
      expect(core.isStarting, isFalse);

      _writeHandle(
        runDir,
        worktree,
        device: 'sim',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );
      await core.computeAll();
      expect(core.isStarting, isTrue);
    });

    test('a failure is a row in the worktree that launched it', () async {
      // A `.failed` record carries its worktree since failures were scoped;
      // one written by another checkout must not appear in this rail — the
      // key would not even resolve here.
      var theirs = _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        logPath: p.join(runDir.path, 'app-theirs.log'),
        launcherPid: await _deadPid(),
      );
      File(theirs.logPath!).writeAsStringSync('Error: no code signing\n');
      var elsewhere = _coreFor(otherWorktree);
      addTearDown(elsewhere.dispose);
      await elsewhere.invoke('apps');

      await core.computeAll();
      expect(core.failures, hasLength(1), reason: 'the record itself is read');
      expect(core.ownFailures, isEmpty);
      expect(core.report.children, isEmpty);

      // A record from before failures carried a worktree shows everywhere
      // rather than nowhere.
      RunFailure(
        key: 'app-legacy',
        device: 'phone',
        entrypoint: 'lib/main.dart',
        at: DateTime.now(),
      ).write(runDir.path);
      await core.computeAll();
      expect(core.ownFailures.single.key, 'app-legacy');
    });
  });

  group('devices', () {
    test('reports occupancy with the holding worktree', () async {
      DeviceCache.write(runDir.path, [
        const DaemonDevice(
          id: 'phone',
          name: 'Xavier iPhone',
          platformType: 'ios',
          connectionInterface: 'wireless',
        ),
      ]);
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main_staging.dart',
        entrypointName: 'Staging',
        worktreeName: 'feature-x',
        launcherPid: pid,
      );

      var result = (await core.invoke('devices'))! as RunDevicesResult;

      expect(result.live, isFalse);
      expect(result.age, 'just now');
      var device = result.devices.single;
      expect(device.connection, 'wireless');
      expect(device.running.single.worktree, 'feature-x');
      expect(device.running.single.entrypointName, 'Staging');
    });

    test('explains an empty list rather than leaving an empty array', () async {
      var result = (await core.invoke('devices'))! as RunDevicesResult;
      expect(result.devices, isEmpty);
      expect(result.note, contains('No device list has been taken'));
    });
  });

  group('apps', () {
    test('keeps a run that is still building and says so', () async {
      // A live launcher and no VM service yet: this is a cold Android build,
      // which takes a minute and a half. Sweeping it would free a device that
      // is very much in use.
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );

      var result = (await core.invoke('apps'))! as RunAppsResult;

      expect(result.swept, 0);
      var app = result.apps.single;
      expect(app.launcher, isTrue);
      expect(app.app, isFalse);
      expect(app.mine, isTrue);
      expect(app.error, 'not started yet');
    });

    test('sweeps a handle nothing answers', () async {
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: await _deadPid(),
      );

      var result = (await core.invoke('apps'))! as RunAppsResult;

      expect(result.swept, 1);
      expect(result.apps, isEmpty);
      expect(scanRunHandles(runDir.path), isEmpty);
    });

    test('the rail row carries no command of its own', () {
      // It carried `+ New run`, which was the only way to start a second one
      // and appeared only while the mouse was over the row — reported as the
      // buttons being absent, which is what a hover-only affordance is. The
      // row itself now opens the page that starts a run, so a `+` beside it
      // would be a second door to the same place.
      expect(RunPlugin(core).rowCommands(), isEmpty);
      // The address it opened still parses: it is a real place, and one that
      // may be written down.
      expect(runPlace([newRunSegment]).isNew, isTrue);
    });

    test('a failed run is a rail row, not only a panel state', () async {
      // The rail is the list — the chip row that used to hold failures is
      // gone, so a launch that failed has to be a child here or it has
      // vanished a second time.
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        entrypointName: 'App',
        logPath: p.join(runDir.path, 'app-railed.log'),
        launcherPid: await _deadPid(),
      );
      File(handle.logPath!).writeAsStringSync('Error: could not code sign\n');

      await core.invoke('apps');
      await core.computeAll();

      var child = core.report.children.singleWhere((c) => c.id == handle.key);
      expect(child.label, 'App · phone');
      expect(child.status.tone, Tone.error);
      expect(child.status.message, 'Error: could not code sign');

      // And a *different process* sees it. This was memory first, which meant
      // a launch that failed under `fw` was missing from the GUI's rail — the
      // one list it had just been promoted into.
      var elsewhere = _coreFor(worktree);
      addTearDown(elsewhere.dispose);
      await elsewhere.computeAll();
      expect(elsewhere.failureFor(handle.key)?.headline, contains('code sign'));
    });

    test('a failure older than the window is history, and is left alone', () {
      var stale = RunFailure(
        key: 'app-stale',
        device: 'phone',
        entrypoint: 'lib/main.dart',
        at: DateTime.now().subtract(const Duration(days: 2)),
      );
      stale.write(runDir.path);

      expect(scanRunFailures(runDir.path), isEmpty);
      // Not deleted here. This scan runs inside `computeAll`, which reads and
      // does not write; the run dir's sweeper ages `.failed` out on the same
      // rule as the log beside it.
      expect(
        File(p.join(runDir.path, 'app-stale.failed')).existsSync(),
        isTrue,
      );
    });

    test('a long failure keeps its cause, not its summary', () {
      // A tool states the fault first and summarises last. Capping to the tail
      // would drop `Error (Xcode): …` and keep `App failed to start`, which is
      // the bug the block exists to fix.
      var path = p.join(runDir.path, 'app-long.log');
      File(path).writeAsStringSync(
        [
          'Error (Xcode): No Account for Team "B7V224LKE4".',
          for (var i = 0; i < 60; i++) 'noise $i',
          'App failed to start',
        ].join('\n'),
      );

      var failure = LaunchLog.read(path).failure(launcherAlive: false)!;

      expect(failure, startsWith('Error (Xcode): No Account'));
      expect(failure, contains('more lines in the log'));
      expect(failure, isNot(contains('App failed to start')));
      expect(
        LaunchLog.read(path).failureHeadline,
        'Error (Xcode): No Account for Team "B7V224LKE4".',
      );
    });

    test('sweeping a run that never started keeps why', () async {
      // The handle must go — a dead launcher is not holding the phone — but
      // deleting it was also deleting the only thing on screen, which is what
      // a failed launch closing "without explanation" actually was.
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        logPath: p.join(runDir.path, 'app-failed.log'),
        launcherPid: await _deadPid(),
      );
      File(handle.logPath!)
          .writeAsStringSync('Error: could not code sign the application\n');

      await core.invoke('apps');

      expect(scanRunHandles(runDir.path), isEmpty);
      var failure = core.failureFor(handle.key)!;
      expect(failure.headline, 'Error: could not code sign the application');
      expect(failure.deviceLabel, 'phone');
      expect(failure.logPath, handle.logPath);
      expect(core.failures, hasLength(1));
    });

    test('a run that started and was stopped leaves no obituary', () async {
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        logPath: p.join(runDir.path, 'app-ran.log'),
        launcherPid: await _deadPid(),
      );
      File(handle.logPath!)
          .writeAsStringSync('${_event('app.started', {'appId': 'a1'})}\n');

      await core.invoke('apps');

      expect(scanRunHandles(runDir.path), isEmpty);
      expect(core.failures, isEmpty);
    });

    test(
      'reports why an app did not answer while its launcher lives',
      () async {
        _writeHandle(
          runDir,
          worktree,
          device: 'phone',
          entrypoint: 'lib/main.dart',
          launcherPid: pid,
          // Nothing listens on port 1; the connect fails immediately.
          vmService: 'ws://127.0.0.1:1/ws',
        );

        var result = (await core.invoke('apps'))! as RunAppsResult;

        expect(result.swept, 0);
        expect(result.apps.single.app, isFalse);
        expect(result.apps.single.launcher, isTrue);
        expect(result.apps.single.error, isNotNull);
      },
    );

    test("marks another worktree's run as not mine", () async {
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        worktreeName: 'feature-x',
        launcherPid: pid,
      );

      var result = (await core.invoke('apps'))! as RunAppsResult;

      expect(result.apps.single.mine, isFalse);
      expect(result.apps.single.worktree, 'feature-x');
    });
  });

  group('entry points', () {
    test('a scan finds top-level mains and nothing below them', () {
      _writePackage(worktree, 'app', {
        'lib/main.dart': 'void main() {}',
        'lib/main_staging.dart': 'Future<void> main() async {}',
        'lib/widget.dart': 'class Widget {}',
        // A `main()` under `lib/src/` is somebody's helper or a generated
        // harness, and offering it in a launch menu is noise.
        'lib/src/tool.dart': 'void main() {}',
      });

      var found = scanEntrypoints(p.join(worktree.path, 'app'));

      expect(
        [for (var e in found) e.path],
        ['lib/main.dart', 'lib/main_staging.dart'],
      );
      expect(found.every((e) => !e.declared), isTrue);
    });

    test(
      'a source this build has no member for leaves the knob usable',
      () async {
        _writePackage(worktree, 'app', {
          'pubspec.yaml': 'name: app\n',
          'lib/main.dart': "void main({String api = 'x'}) {}",
        });
        core = _coreFor(
          worktree,
          config: {
            'packages': [
              {
                'path': 'app',
                'entrypoints': [
                  {
                    'path': 'lib/main.dart',
                    'knobs': [
                      // The config imports the flutterware the *project* pins,
                      // which can run ahead of the GUI reading its manifest. A
                      // source we cannot resolve has to mean a knob with fewer
                      // suggestions, never a knob that disappears.
                      {
                        'knob': 'api',
                        'from': {'source': 'somethingLater'},
                      },
                    ],
                  },
                ],
              },
            ],
          },
        );

        var result =
            (await core.invoke('entrypoints'))! as RunEntrypointsResult;

        var knob = result.packages.single.entrypoints.single.knobs.single;
        expect(knob.name, 'api');
        // Still the signature's own default: the source added nothing, and
        // took nothing away.
        expect(knob.defaultValue, 'x');
      },
    );

    test('a script source computes the value the launch will use', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 8086}) {}',
      });
      _writeScript(worktree, 'void main() { print(8186); }');
      core = _coreFor(
        worktree,
        sdk: _sdkWithRealDart(worktree),
        config: _configWithScript(),
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;

      var knob = result.packages.single.entrypoints.single.knobs.single;
      // Not 8086. The signature's default is what the app does when nobody
      // says anything, and the whole point of the script is that somebody
      // does — this worktree's stack came up on a port only the project can
      // work out.
      expect(knob.defaultValue, '8186');
      expect(knob.problem, isNull);
    });

    test('a script that cannot answer refuses the launch', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 8086}) {}',
      });
      _writeScript(worktree, """
import 'dart:io';

void main() {
  stderr.writeln('no .env — run local_env up first');
  exit(1);
}
""");
      core = _coreFor(
        worktree,
        sdk: _sdkWithRealDart(worktree),
        config: _configWithScript(),
      );

      // Falling back to 8086 would compile, install and run, and would be
      // indistinguishable from a correct build until the app was talking to
      // another worktree's database. This is the one thing here that may not
      // degrade quietly.
      await expectLater(
        core.invoke('launch', arguments: {'device': 'phone'}),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('serverPort'), contains('run local_env up first')),
          ),
        ),
      );
    });

    test('a value the caller gave launches past a script that failed', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 8086}) {}',
      });
      _writeScript(worktree, "import 'dart:io';\nvoid main() { exit(1); }");
      core = _coreFor(
        worktree,
        sdk: _sdkWithRealDart(worktree),
        config: _configWithScript(),
      );

      // The refusal is about not *guessing* a value nobody chose. Somebody who
      // typed one has chosen, and a broken dev stack should not stop them.
      //
      // Through `launch` rather than the action, because that is the method the
      // panel's Start button calls: both surfaces have to bake in the same set,
      // and a test that only went through `invoke` would not say so.
      await core.computeAll();
      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
        knobs: {'serverPort': '9000'},
      );
      addTearDown(() => _stopLauncher(handle));

      expect(handle.knobs, {'serverPort': '9000'});
    });

    /// One file declared several times under different names is the documented
    /// way to run one app against several configurations — so a path is not a
    /// unique handle on an entry point, and everything that selects one has to
    /// cope with that.
    group('when two entry points share a path', () {
      RunCore coreWithTwoNames() {
        _writePackage(worktree, 'app', {'lib/main.dart': 'void main() {}'});
        return _coreFor(
          worktree,
          config: {
            'packages': [
              {
                'path': 'app',
                'entrypoints': [
                  {'path': 'lib/main.dart', 'name': 'Stage'},
                  {'path': 'lib/main.dart', 'name': 'Local stack'},
                ],
              },
            ],
          },
        );
      }

      test('the refusal offers the names, not the identical paths', () async {
        core = coreWithTwoNames();

        // The bug this replaced answered `name one of: lib/main.dart,
        // lib/main.dart` — a choice between two identical strings, which no
        // caller can act on.
        await expectLater(
          core.invoke(
            'launch',
            arguments: {'device': 'phone', 'entrypoint': 'lib/main.dart'},
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '$e',
              'message',
              allOf(contains('"Stage"'), contains('"Local stack"')),
            ),
          ),
        );
      });

      test('the offered values are unique', () async {
        core = coreWithTwoNames();
        await core.invoke('entrypoints');

        var launch = core.report.actions.firstWhere((a) => a.id == 'launch');
        var options = launch.parameters
            .firstWhere((p) => p.id == 'entrypoint')
            .options;

        // Two options carrying one value is a picker whose rows do the same
        // thing — and an enum an MCP client cannot represent.
        expect(
          [for (var option in options) option.value],
          ['Stage', 'Local stack'],
        );
      });
    });
  });
  group('the platforms an entry point declares', () {
    test('a shorthand expands, and a bare platform does not', () {
      expect(RunPlatform.expandAll([RunPlatform.desktop]), {
        RunPlatform.macos,
        RunPlatform.linux,
        RunPlatform.windows,
      });
      expect(RunPlatform.expandAll([RunPlatform.mobile, RunPlatform.web]), {
        RunPlatform.ios,
        RunPlatform.android,
        RunPlatform.web,
      });
      expect(RunPlatform.expandAll(const []), isEmpty);
    });

    test('an undeclared entry point takes every device', () {
      var entry = EntrypointRef(
        path: 'lib/main.dart',
        name: 'App',
        declared: true,
      );

      expect(entry.allowsDevice(platformType: 'ios'), isTrue);
      expect(entry.allowsDevice(platformType: 'macos'), isTrue);
      // Empty is "no restriction", not "nothing allowed" — the difference
      // between an entry point that runs anywhere and one that runs nowhere.
      expect(entry.allowsDevice(platformType: null, category: null), isTrue);
    });

    test('a device saying nothing about itself is allowed', () {
      var entry = EntrypointRef(
        path: 'lib/main.dart',
        name: 'Kiosk',
        declared: true,
        platforms: const [RunPlatform.mobile],
      );

      // The daemon is a tool we do not version. Hiding a connected phone over
      // a field it happened not to send would be a restriction nobody wrote.
      expect(entry.allowsDevice(platformType: null, category: null), isTrue);
      // But it groups devices the way our shorthands do, so a category still
      // answers when the platform is missing.
      expect(entry.allowsDevice(category: 'mobile'), isTrue);
      expect(entry.allowsDevice(category: 'desktop'), isFalse);
    });

    test('the picker, the report and the guard agree', () async {
      _writePackage(worktree, 'app', {'lib/main_kiosk.dart': 'void main() {}'});
      DeviceCache.write(runDir.path, const [
        DaemonDevice(id: 'phone', name: 'Pixel', platformType: 'android'),
        DaemonDevice(
          id: 'macos',
          name: 'macOS',
          platformType: 'macos',
          ephemeral: false,
        ),
      ]);
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main_kiosk.dart',
                  'name': 'Kiosk',
                  'platforms': ['mobile'],
                },
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var entry = result.packages.single.entrypoints.single;
      // Reported as written — `mobile` stays `mobile` — with the expansion
      // against the desk done for the caller.
      expect(entry.platforms, ['mobile']);
      expect(entry.devices, ['phone']);
      expect(
        [
          for (var d in core.devicesFor(core.entrypointsFor('app').single))
            d.id,
        ],
        ['phone'],
      );

      await expectLater(
        core.invoke('launch', arguments: {'device': 'macos'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('macos'), contains('Kiosk')),
          ),
        ),
      );
    });

    test('declaring no platforms reports every device, not none', () async {
      // Empty means "anything" everywhere else — `allowsDevice` says so and
      // `devicesFor` says so — and `entrypoints` used to special-case it to an
      // empty list, on the reasoning that an unrestricted entry point has
      // nothing to report. It reads as the opposite: a picker filtering on this
      // field was offered nothing for the ordinary entry point and everything
      // for the one that restricted itself, which is exactly backwards.
      _writePackage(worktree, 'app', {'lib/main.dart': 'void main() {}'});
      DeviceCache.write(runDir.path, const [
        DaemonDevice(id: 'phone', name: 'Pixel', platformType: 'android'),
        DaemonDevice(
          id: 'macos',
          name: 'macOS',
          platformType: 'macos',
          ephemeral: false,
        ),
      ]);
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var entry = result.packages.single.entrypoints.single;
      expect(entry.platforms, isEmpty);
      expect(entry.devices, ['phone', 'macos']);
    });

    test('a platform this build has no name for lifts the restriction', () {
      // The config imports the flutterware version the *project* pins, which a
      // hosted install can carry ahead of the GUI reading its manifest. Too
      // many devices ends in a build failure that names the platform; too few
      // ends in a picker with nothing in it and no way to ask why.
      var entries = declaredEntrypoints({
        'entrypoints': [
          {
            'path': 'lib/main.dart',
            'platforms': ['fuchsia'],
          },
        ],
      });

      expect(entries.single.platforms, isEmpty);
      expect(entries.single.allowsDevice(platformType: 'macos'), isTrue);
    });
  });

  group('the dart-define passthrough', () {
    setUp(() {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main() {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );
    });

    test('forwards whatever it is given, unexamined', () async {
      // Deliberately unchecked. It exists for the three cases a knob cannot
      // reach — a define read by a package you do not own, one the native
      // build consumes, and anything needed before the Dart entry point runs —
      // and in none of them is there a signature to check against. Modelling a
      // standard Flutter flag was the mistake; refusing to forward it would be
      // a different one.
      await core.computeAll();
      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
        defines: {'SOME_SDK_KEY': 'abc', 'NOTHING_READS_THIS': 'x'},
      );
      addTearDown(() => _stopLauncher(handle));

      expect(handle.defines, {
        'SOME_SDK_KEY': 'abc',
        'NOTHING_READS_THIS': 'x',
      });
    });

    test('is not confused with knobs', () async {
      // Same launch, two mechanisms, two costs: a define is baked into the
      // build, a knob is an argument the wrapper writes.
      await expectLater(
        core.invoke(
          'launch',
          arguments: {'device': 'phone', 'knobs': 'anything=1'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('takes no knobs'),
          ),
        ),
      );
    });
  });

  group('the knobs an entry point takes', () {
    test('come off the signature, annotated by the config', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/src/backend.dart': 'enum Backend { dev, staging, prod }',
        'lib/main.dart': '''
import 'src/backend.dart';
void main({
  String apiHost = 'localhost',
  int serverPort = 8086,
  Backend backend = Backend.dev,
}) {}
''',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main.dart',
                  'name': 'App',
                  'knobs': [
                    {'knob': 'apiHost', 'label': 'Host'},
                  ],
                },
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var knobs = result.packages.single.entrypoints.single.knobs;

      // Signature order, and every parameter is offered whether or not the
      // config mentioned it.
      expect(knobs.map((k) => k.name), ['apiHost', 'serverPort', 'backend']);
      expect(knobs.map((k) => k.kind), ['string', 'integer', 'picker']);
      expect(knobs.first.label, 'Host');
      expect(knobs.first.defaultValue, 'localhost');
      expect(knobs[1].defaultValue, '8086');
      expect(knobs.last.options, ['dev', 'staging', 'prod']);
      expect(knobs.every((k) => k.problem == null), isTrue);
    });

    /// The shape a consumer's entry points actually have. The values knobs
    /// replace are usually already `String.fromEnvironment` constants, because
    /// that is what a `--dart-define` build reads — and the same file being
    /// compiled by their server is what forces it, since bare literals would
    /// make the served bundle ignore the defines. So the default is a `const`
    /// reference, and the form showed a blank for a parameter that plainly had
    /// one two lines away.
    ///
    /// Carried as the spelling, never evaluated: `default` stays empty and
    /// honest, `defaultSource` says what was written. A project that needs the
    /// value has `from:`, which is what computes one.
    test('a const default is reported as written, not as a blank', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/server_urls.dart': '''
class ServerUrls {
  static const localHost = String.fromEnvironment('LOCALDEV_HOST',
      defaultValue: 'localhost');
  static const localPort = int.fromEnvironment('LOCALDEV_SERVER_PORT',
      defaultValue: 8086);
}
''',
        'lib/main.dart': '''
import 'server_urls.dart';
void main({
  String serverHost = ServerUrls.localHost,
  int serverPort = ServerUrls.localPort,
}) {}
''',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var knobs = result.packages.single.entrypoints.single.knobs;

      expect(knobs.map((k) => k.name), ['serverHost', 'serverPort']);
      // The type still comes off the signature, so the control is right.
      expect(knobs.map((k) => k.kind), ['string', 'integer']);
      expect(knobs.map((k) => k.defaultSource), [
        'ServerUrls.localHost',
        'ServerUrls.localPort',
      ]);
      expect(knobs.map((k) => k.defaultValue), [
        null,
        null,
      ], reason: 'the value field may not carry source text');
      // Not a fault: the parameter is drawable and has a default. Reporting a
      // problem here would put a warning on the ordinary case.
      expect(knobs.every((k) => k.problem == null), isTrue);
    });

    test('an entry point taking none offers none', () async {
      // The `Studio (dev)` embarrassment, gone by construction: a package-level
      // scan offered four constants belonging to another entry point, and a
      // signature cannot.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main() {}',
        'lib/main_other.dart':
            "const x = String.fromEnvironment('SOMEBODY_ELSES');\n"
            'void main({int port = 1}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      expect(result.packages.single.entrypoints.single.knobs, isEmpty);
    });

    test('a declaration naming no parameter is reported', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 1}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main.dart',
                  'name': 'App',
                  'knobs': [
                    {'knob': 'serverPrt'},
                  ],
                },
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var knobs = result.packages.single.entrypoints.single.knobs;

      // The real one first, the typo last with its reason — which is what makes
      // the typo findable.
      expect(knobs.map((k) => k.name), ['serverPort', 'serverPrt']);
      expect(knobs.last.problem, contains('main takes no `serverPrt`'));
      expect(knobs.last.kind, isNull);
    });

    test('a parameter that cannot be drawn says so instead of vanishing', () async {
      // The reason was computed at the skip site and thrown away, so a control
      // simply went missing with nothing to explain it — which looks like a
      // broken tool rather than a type nothing can draw.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int port = 1, Uri? base}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var knobs = result.packages.single.entrypoints.single.knobs;

      expect(knobs.map((k) => k.name), ['port', 'base']);
      expect(knobs.last.kind, isNull);
      expect(knobs.last.problem, contains('main takes `base`'));
      expect(knobs.last.problem, contains('`Uri?`'));
    });

    test('a knob on such a parameter names the type, not a typo', () async {
      // The constraint: "main takes no `x` parameter" is right for a misspelled
      // name and wrong here, and the difference is the whole point — one sends
      // somebody to the signature, the other to the type.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({Uri? base}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main.dart',
                  'name': 'App',
                  'knobs': [
                    {'knob': 'base'},
                  ],
                },
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var knobs = result.packages.single.entrypoints.single.knobs;

      expect(knobs.single.name, 'base');
      expect(knobs.single.problem, contains('main takes `base`'));
      expect(knobs.single.problem, isNot(contains('takes no')));
    });

    test('launching such a knob is refused for the real reason', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({Uri? base}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      await expectLater(
        core.invoke(
          'launch',
          arguments: {'device': 'phone', 'knobs': 'base=x'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('main takes `base`'), contains('`Uri?`')),
          ),
        ),
      );
    });

    test('launching refuses a knob the signature does not have', () async {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 1}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      await expectLater(
        core.invoke(
          'launch',
          arguments: {'device': 'phone', 'knobs': 'serverPrt=2'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('no such knob'), contains('serverPort')),
          ),
        ),
      );
    });
  });

  test('an enum offers its own constants and says what it will not', () async {
    // The config used to be merged into a picker's list, so a value that could
    // never compile was offered as a chip and then refused by the very same
    // core the moment somebody picked it. The enum is the list; what the config
    // added is worth a sentence, because it is a line in `flutterware.dart`
    // that reads as working.
    _writePackage(worktree, 'app', {
      'pubspec.yaml': 'name: app\n',
      'lib/src/backend.dart': 'enum Backend { dev, prod }',
      'lib/main.dart':
          "import 'src/backend.dart';\n"
          'void main({Backend backend = Backend.dev}) {}',
    });
    core = _coreFor(
      worktree,
      config: {
        'packages': [
          {
            'path': 'app',
            'entrypoints': [
              {
                'path': 'lib/main.dart',
                'knobs': [
                  {
                    'knob': 'backend',
                    'options': ['prod', 'canary'],
                  },
                ],
              },
            ],
          },
        ],
      },
    );

    var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;

    var knob = result.packages.single.entrypoints.single.knobs.single;
    expect(knob.options, ['dev', 'prod'], reason: 'not canary');
    expect(knob.problem, allOf(contains('canary'), contains('dev, prod')));
    // `prod` is a constant, so it is not a complaint — it is merely the same
    // fact written twice.
    expect(knob.problem, isNot(contains('prod, canary')));
  });

  group('a main that requires a parameter', () {
    // Not a knob and not skippable: there is no default to leave it at, so
    // nothing can launch it. It used to be dropped silently, which made the
    // entry point look knob-less — `--knobs=apiHost=x` came back "takes no
    // knobs", and launching without it produced a wrapper whose
    // `entry.main as FutureOr<void> Function()` cast cannot hold a function
    // with a required parameter, so the app died at startup naming nothing.
    setUp(() {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({required String apiHost}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );
    });

    test('is refused by name rather than crashing on the cast', () async {
      await expectLater(
        core.invoke('launch', arguments: {'device': 'phone'}),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('apiHost'), contains('has to be optional')),
          ),
        ),
      );
    });

    test('and passing it does not talk the launch round', () async {
      // The old message was actively wrong here: "takes no knobs" about a main
      // that visibly takes one.
      await expectLater(
        core.invoke(
          'launch',
          arguments: {'device': 'phone', 'knobs': 'apiHost=x'},
        ),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            isNot(contains('takes no knobs')),
          ),
        ),
      );
    });

    test('and the cockpit shows the reason instead of nothing', () async {
      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;

      var knob = result.packages.single.entrypoints.single.knobs.single;
      expect(knob.name, 'apiHost');
      expect(knob.problem, contains('main requires this'));
      // No kind: there is no control, and drawing one would suggest there is
      // something to set.
      expect(knob.kind, isNull);
    });
  });

  /// The other half of the same problem, and the one a signature cannot state.
  /// `void main({required String x})` is not an entry point — Flutter's
  /// bootstrap calls `main()` — so an entry point that must also run under a
  /// plain `flutter run` carries a placeholder default and has no way to say
  /// the placeholder is not a value to run against. `Knob(required: true)` is
  /// where it says so.
  group('a knob the config declares required', () {
    Map<String, Object?> configWith(Map<String, Object?> knob) => {
      'packages': [
        {
          'path': 'app',
          'entrypoints': [
            {
              'path': 'lib/main.dart',
              'name': 'App',
              'knobs': [knob],
            },
          ],
        },
      ],
    };

    setUp(() {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': "void main({String apiToken = ''}) {}",
      });
    });

    test('refuses a launch that leaves it alone, before the build', () async {
      core = _coreFor(
        worktree,
        config: configWith({'knob': 'apiToken', 'required': true}),
      );

      // The cost of not doing this is the whole point: a compile, an install, a
      // boot, and then whatever the app makes of an empty string — minutes
      // after the mistake and naming neither the knob nor the launch.
      await expectLater(
        core.invoke('launch', arguments: {'device': 'phone'}),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('apiToken'), contains('needs')),
          ),
        ),
      );
    });

    test('and launches once it is passed', () async {
      core = _coreFor(
        worktree,
        config: configWith({'knob': 'apiToken', 'required': true}),
      );
      await core.computeAll();

      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
        knobs: {'apiToken': 'abc'},
      );
      addTearDown(() => _stopLauncher(handle));

      expect(handle.knobs, {'apiToken': 'abc'});
    });

    test('withholds the placeholder default it says not to trust', () async {
      core = _coreFor(
        worktree,
        config: configWith({'knob': 'apiToken', 'required': true}),
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;

      var knob = result.packages.single.entrypoints.single.knobs.single;
      expect(knob.required, isTrue);
      // Not `''`. The parameter has a default because it must — the file still
      // has to run under a plain `flutter run` — and reporting it would hand a
      // caller a fallback the config has just said does not exist.
      expect(knob.defaultValue, isNull);
      expect(knob.defaultSource, isNull);
      // Still a control, unlike a `required` *parameter*: there is a value to
      // set, and setting it is how the launch goes ahead.
      expect(knob.kind, 'string');
      expect(knob.problem, isNull);
    });

    test('withholds the source text of a const placeholder too', () async {
      // The likelier half of the same mistake. `_literal` reads a literal or
      // nothing, so a `const String.fromEnvironment(…)` default — which is what
      // a required knob's placeholder actually looks like — leaves
      // `defaultValue` null and lands in `defaultSource`, where the form takes
      // it as the field's hint. Suppressing only one of the two would put the
      // fallback straight back on screen.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart':
            'void main({String apiToken = '
            "const String.fromEnvironment('API_TOKEN')}) {}",
      });
      core = _coreFor(
        worktree,
        config: configWith({'knob': 'apiToken', 'required': true}),
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;

      var knob = result.packages.single.entrypoints.single.knobs.single;
      expect(knob.required, isTrue);
      expect(knob.defaultValue, isNull);
      expect(knob.defaultSource, isNull);
    });

    test('a source that answers satisfies it without anyone typing', () async {
      _writeScript(worktree, "void main() { print('from-the-script'); }");
      core = _coreFor(
        worktree,
        sdk: _sdkWithRealDart(worktree),
        config: configWith({
          'knob': 'apiToken',
          'required': true,
          'from': {'script': 'tool/env.dart'},
        }),
      );
      await core.computeAll();

      // `required` is about *some value having been chosen for this launch*,
      // not about a human having typed one — otherwise every computed knob
      // would have to be re-typed to satisfy the flag that protects it.
      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
      );
      addTearDown(() => _stopLauncher(handle));

      expect(handle.knobs, {'apiToken': 'from-the-script'});
    });

    test('a declaration naming no parameter is a typo, not a block', () async {
      core = _coreFor(
        worktree,
        config: configWith({'knob': 'apiTokn', 'required': true}),
      );

      // Refusing here would replace a precise diagnostic with a vague one, and
      // the launch could not be satisfied anyway: `_checkKnobNames` refuses the
      // misspelled name too, so there would be no way past it.
      await core.computeAll();
      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
      );
      addTearDown(() => _stopLauncher(handle));

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      // Two lines: the parameter `main` really takes, and the declaration that
      // meant to name it.
      var knobs = result.packages.single.entrypoints.single.knobs;
      expect(knobs.map((k) => k.name), ['apiToken', 'apiTokn']);
      expect(knobs.last.required, isFalse);
      expect(knobs.last.problem, contains('main takes no `apiTokn`'));
    });
  });

  /// The value flutterware is holding while the app it launches cannot see it:
  /// a `flutter run` hands its child a stripped environment, so nothing inside
  /// the process can tell which `flutter` started it.
  group('the Flutter SDK as a source', () {
    setUp(() {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': "void main({String flutterSdkRoot = ''}) {}",
      });
      core = _coreFor(
        worktree,
        sdk: FlutterSdkPath('/tmp/pinned-flutter'),
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main.dart',
                  'name': 'App',
                  'knobs': [
                    {
                      'knob': 'flutterSdkRoot',
                      'required': true,
                      'from': {'source': 'flutterSdk'},
                    },
                  ],
                },
              ],
            },
          ],
        },
      );
    });

    test('is passed to main without anyone naming it', () async {
      await core.computeAll();

      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
      );
      addTearDown(() => _stopLauncher(handle));

      // The SDK the *workspace* resolved against — never one found on PATH,
      // which in this repo is two versions behind what `.fvmrc` pins.
      expect(handle.knobs, {'flutterSdkRoot': '/tmp/pinned-flutter'});
    });

    test('and is the reported default, not an offered chip', () async {
      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;

      var knob = result.packages.single.entrypoints.single.knobs.single;
      expect(knob.defaultValue, '/tmp/pinned-flutter');
      // One SDK, already shown as the default. A chip beside it would be the
      // same value twice with the second dressed as a choice.
      expect(knob.options, isEmpty);
      expect(knob.problem, isNull);
    });

    test('a value the caller passed still wins', () async {
      await core.computeAll();

      var handle = await core.launch(
        device: 'phone',
        package: 'app',
        entry: core.entrypointsFor('app').single,
        knobs: {'flutterSdkRoot': '/opt/other'},
      );
      addTearDown(() => _stopLauncher(handle));

      expect(handle.knobs, {'flutterSdkRoot': '/opt/other'});
    });

    test('but the form is not primed with it, because nobody chose it', () async {
      // A handle records what the app was *built with*, which includes every
      // knob a `from:` worked out for a field nobody touched. The New run form
      // reads the other thing — what somebody typed — so priming it from the
      // resolved set freezes this SDK path into the field, and the next launch
      // builds against it instead of against whichever flutterware started us.
      await core.computeAll();
      var entry = core.entrypointsFor('app').single;

      expect(
        core.chosenKnobs('app', entry, {
          'flutterSdkRoot': '/tmp/pinned-flutter',
        }),
        isEmpty,
        reason: 'the source computed exactly this',
      );
      // An override *is* an instruction and survives.
      expect(core.chosenKnobs('app', entry, {'flutterSdkRoot': '/opt/other'}), {
        'flutterSdkRoot': '/opt/other',
      });
      // And a name this entry point does not declare is kept rather than
      // guessed about — there is no source to have computed it.
      expect(core.chosenKnobs('app', entry, {'marker': 'x'}), {'marker': 'x'});
    });
  });

  group('a knob value the signature cannot take', () {
    // Refused here rather than left to the compiler: the value becomes a
    // literal in generated source, so a bad one is a build failure pointing at
    // a file the user did not write.
    setUp(() {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/src/backend.dart': 'enum Backend { dev, prod }',
        'lib/main.dart': """
import 'src/backend.dart';
void main({int serverPort = 1, Backend backend = Backend.dev}) {}
""",
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );
    });

    Future<void> refuses(String knobs, Matcher message) => expectLater(
      core.invoke('launch', arguments: {'device': 'phone', 'knobs': knobs}),
      throwsA(isA<ArgumentError>().having((e) => '$e', 'message', message)),
    );

    test(
      'a word where a number goes',
      () => refuses('serverPort=eight', contains('takes a whole number')),
    );

    test(
      'a constant the enum does not have',
      () => refuses(
        'backend=nope',
        allOf(contains('dev, prod'), contains('nope')),
      ),
    );

    test('and the panel is refused too, not only the action', () async {
      // The check used to sit in the action, on the grounds that the panel
      // builds its fields from the same list and so cannot invent a name —
      // true of names, false of values. A text field for an `int` takes
      // `eight` from a desktop keyboard, and what followed was the failure
      // this design deleted `--dart-define` to escape: the generator declined
      // to write a literal it could not form, the argument vanished, the
      // wrapper came out in its no-knobs shape, the app ran on 1, and the
      // handle recorded `eight` for the cockpit to display.
      await core.computeAll();
      await expectLater(
        core.launch(
          device: 'phone',
          package: 'app',
          entry: core.entrypointsFor('app').single,
          knobs: {'serverPort': 'eight'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('takes a whole number'),
          ),
        ),
      );
    });
  });

  group('setKnobs', () {
    setUp(() {
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/src/backend.dart': 'enum Backend { dev, prod }',
        'lib/main.dart':
            "import 'src/backend.dart';\n"
            'void main({int serverPort = 1, Backend backend = Backend.dev}) {}',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );
    });

    test('checks the value before it touches anything', () async {
      // The bug this pins: the action did not run `computeAll`, so there were
      // no entry points to check against, the check silently passed, and the
      // restart failed on a wrapper that would not compile — surfacing as
      // `s1.hotRestart: (-32603)`, which says nothing to anybody.
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        package: 'app',
        launcherPid: pid,
      );

      var result =
          (await core.invoke(
                'setKnobs',
                arguments: {'device': 'phone', 'knobs': 'backend=nope'},
              ))!
              as RunControlResult;

      expect(result.ok, isFalse);
      expect(result.error, contains('dev, prod'));
      // Refused before the wrapper was written, so nothing on disk moved.
      expect(
        File(
          p.join(
            worktree.path,
            'app',
            '.dart_tool/flutterware/run/main_guest.dart',
          ),
        ).existsSync(),
        isFalse,
      );
    });

    test(
      "refuses another checkout's run rather than rewriting our own",
      () async {
        // `absolutePathOf` resolves in *this* worktree, so applying to another
        // checkout's run would rewrite this worktree's wrapper and restart that
        // app onto this worktree's code — a wrong file and a wrong app.
        core.debugRepoWorktrees = Future.value({
          p.canonicalize(worktree.path),
          p.canonicalize(otherWorktree.path),
        });
        _writeHandle(
          runDir,
          otherWorktree,
          device: 'phone',
          entrypoint: 'lib/main.dart',
          package: 'app',
          worktreeName: 'feature-x',
          launcherPid: pid,
        );

        var result =
            (await core.invoke(
                  'setKnobs',
                  arguments: {
                    'device': 'phone',
                    'worktree': 'feature-x',
                    'knobs': 'serverPort=2',
                  },
                ))!
                as RunControlResult;

        expect(result.ok, isFalse);
        expect(result.error, contains('belongs to feature-x'));
      },
    );

    test('a failed restart puts the wrapper and the handle both back', () async {
      // The two move together or the cockpit lies. Recording the handle *after*
      // the restart looked safer — say it is running only once it is — and it
      // lost the values outright when the app being restarted was flutterware
      // itself: a hot restart tears down the root isolate, so nothing queued
      // after `await control(…)` ran at all. The wrapper on disk carried the
      // value, the app came up on it, and the Knobs tab showed an empty field
      // for a value the app was plainly holding. Found by driving the real
      // cockpit; no unit test was looking in that direction.
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        package: 'app',
        launcherPid: pid,
        knobs: {'serverPort': '7'},
      );
      await core.computeAll();

      // No VM service, so the restart cannot land.
      await expectLater(
        core.applyKnobs(handle, {'serverPort': '9'}),
        throwsA(anything),
      );

      var wrapper = File(
        p.join(
          worktree.path,
          'app',
          '.dart_tool/flutterware/run/main_guest.dart',
        ),
      ).readAsStringSync();
      expect(wrapper, contains('serverPort: 7,'));
      expect(wrapper, isNot(contains('serverPort: 9')));
      expect(RunHandle.tryRead(File(handle.handlePath!))!.knobs, {
        'serverPort': '7',
      });
    });

    test('a knob left out is re-asked of its source, not dropped', () async {
      // "Replaces the set" is about what the *caller* chose. Saying nothing
      // about `serverPort` used to put it back to the signature's default — an
      // app quietly talking to another worktree's database, which is the one
      // failure a launch is refused over. Whatever the project can work out, it
      // works out again.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 8086}) {}',
      });
      _writeScript(worktree, 'void main() { print(8186); }');
      core = _coreFor(
        worktree,
        sdk: _sdkWithRealDart(worktree),
        config: _configWithScript(),
      );
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        package: 'app',
        launcherPid: pid,
        knobs: {'serverPort': '9999'},
      );
      await core.computeAll();
      core.debugControl = (action, handle) async {};

      var running = await core.applyKnobs(handle, const {});

      // Neither 8086 (the signature's default) nor 9999 (the value that was
      // being overridden). The script still knows the port this worktree got.
      expect(running, {'serverPort': '8186'});
      expect(_wrapperFor(worktree), contains('serverPort: 8186,'));
      expect(RunHandle.tryRead(File(handle.handlePath!))!.knobs, {
        'serverPort': '8186',
      }, reason: 'and the cockpit is told what it is actually running');
    });

    test('finds the declaration by name when a file has several', () async {
      // #119 made "declare one file several times under different names" the
      // documented way to run one app against several configurations. Their
      // signatures are identical — it is the same file — but their config
      // annotations are not, so matching on the path took the first
      // declaration and would have resolved the wrong `from:` script.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': "void main({String apiHost = 'localhost'}) {}",
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main.dart',
                  'name': 'Dev',
                  'knobs': [
                    {
                      'knob': 'apiHost',
                      'label': 'Dev host',
                      'options': ['dev.example.com'],
                    },
                  ],
                },
                {
                  'path': 'lib/main.dart',
                  'name': 'Staging',
                  'knobs': [
                    {
                      'knob': 'apiHost',
                      'label': 'Staging host',
                      'options': ['staging.example.com'],
                    },
                  ],
                },
              ],
            },
          ],
        },
      );
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        entrypointName: 'Staging',
        package: 'app',
        launcherPid: pid,
      );
      await core.computeAll();

      var knob = core.knobEntriesFor(handle).knobs.single;

      expect(knob.label, 'Staging host');
      expect(knob.options, ['staging.example.com']);
    });

    test('a rollback that cannot write still reports the restart', () async {
      // `previous` was valid when it was set; the signature can have moved
      // since, which is the loop this feature exists for. The rollback then
      // threw from inside the catch, so the `rethrow` never ran: the caller was
      // told the value was malformed instead of why the restart failed, and
      // because the generator throws before it writes, the wrapper was left on
      // the values being rolled back *from*.
      _writePackage(worktree, 'app', {
        'pubspec.yaml': 'name: app\n',
        'lib/main.dart': 'void main({int serverPort = 1}) {}',
      });
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        package: 'app',
        launcherPid: pid,
        // What the run was launched with, back when the parameter was a String.
        knobs: {'serverPort': 'localhost'},
      );
      await core.computeAll();
      core.debugControl = (action, handle) async =>
          throw StateError('the app went away mid-restart');

      await expectLater(
        core.applyKnobs(handle, {'serverPort': '9'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('went away mid-restart'),
          ),
        ),
      );

      // Not left on 9, which is the state the rollback exists to undo. `9` is
      // unwritable as the old `localhost`, so the fallback is no knobs at all —
      // a wrapper that compiles, on the signature's own default.
      var wrapper = _wrapperFor(worktree);
      expect(wrapper, isNot(contains('serverPort: 9')));
      expect(wrapper, isNot(contains('entry.main(')));
    });

    test('refuses an entry point this worktree does not declare', () async {
      // Without it there is nothing to validate against, and an unvalidated
      // value becomes a literal in generated source.
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/somebody_elses.dart',
        package: 'app',
        launcherPid: pid,
      );

      var result =
          (await core.invoke(
                'setKnobs',
                arguments: {'device': 'phone', 'knobs': 'serverPort=2'},
              ))!
              as RunControlResult;

      expect(result.ok, isFalse);
      expect(result.error, contains('not an entry point this worktree knows'));
    });
  });

  group('the flavor', () {
    test('falls back to the pubspec’s default-flavor', () async {
      _writePackage(worktree, 'app', {
        'lib/main.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\nflutter:\n  default-flavor: dev\n',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var entry = result.packages.single.entrypoints.single;
      expect(entry.flavor, 'dev');
      expect(entry.flavorSource, 'pubspec');
    });

    test('the entry point’s own declaration wins over it', () async {
      _writePackage(worktree, 'app', {
        'lib/main_staging.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\nflutter:\n  default-flavor: dev\n',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main_staging.dart',
                  'name': 'Staging',
                  'flavor': 'staging',
                },
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var entry = result.packages.single.entrypoints.single;
      expect(entry.flavor, 'staging');
      expect(entry.flavorSource, 'entrypoint');
    });

    test('a package with neither reports no flavor at all', () async {
      _writePackage(worktree, 'app', {
        'lib/main.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\n',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {'path': 'lib/main.dart'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var entry = result.packages.single.entrypoints.single;
      expect(entry.flavor, isNull);
      // Absent, not `none` — a caller reading the field should not have to know
      // one of the words is a sentinel.
      expect(entry.flavorSource, isNull);
    });

    test('varies by the platform of the target device', () async {
      _writePackage(worktree, 'app', {
        'lib/main_kiosk.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\n',
      });
      DeviceCache.write(runDir.path, [
        const DaemonDevice(id: 'phone', platformType: 'ios'),
        const DaemonDevice(id: 'mac', platformType: 'macos'),
        const DaemonDevice(id: 'shy'),
      ]);
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main_kiosk.dart',
                  'name': 'Kiosk',
                  'flavor': 'local',
                  'flavorByPlatform': {'mobile': 'kioskLocal'},
                },
              ],
            },
          ],
        },
      );
      await core.computeAll();

      var entry = core.entrypointsFor('app').single;
      // The shorthand covers the phone; the Mac falls back to the plain
      // declaration — the split-store case: same entry point, its own package
      // id on a phone, none of that on a desktop.
      expect(
        core.flavorFor('app', entry, device: 'phone').flavor,
        'kioskLocal',
      );
      expect(core.flavorFor('app', entry, device: 'mac').flavor, 'local');
      // A device the cache never described, and no device at all, resolve
      // without the pairing rather than guessing a platform.
      expect(core.flavorFor('app', entry, device: 'shy').flavor, 'local');
      expect(core.flavorFor('app', entry).flavor, 'local');
    });

    test('the pairing is echoed as written, unknown keys dropped', () async {
      _writePackage(worktree, 'app', {
        'lib/main_kiosk.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\n',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'entrypoints': [
                {
                  'path': 'lib/main_kiosk.dart',
                  'name': 'Kiosk',
                  'flavor': 'local',
                  // `fuchsia` is a platform this build has no member for — the
                  // config can come from a newer flutterware than the GUI.
                  'flavorByPlatform': {
                    'mobile': 'kioskLocal',
                    'fuchsia': 'kioskNext',
                  },
                },
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var entry = result.packages.single.entrypoints.single;
      expect(entry.flavorByPlatform, {'mobile': 'kioskLocal'});
      // The map rides beside the base, not instead of it.
      expect(entry.flavor, 'local');
    });

    test(
      'an entry point without the pairing does not carry the field',
      () async {
        _writePackage(worktree, 'app', {
          'lib/main.dart': 'void main() {}',
          'pubspec.yaml': 'name: app\n',
        });
        core = _coreFor(
          worktree,
          config: {
            'packages': [
              {
                'path': 'app',
                'entrypoints': [
                  {'path': 'lib/main.dart', 'flavor': 'dev'},
                ],
              },
            ],
          },
        );

        var result =
            (await core.invoke('entrypoints'))! as RunEntrypointsResult;
        var entry = result.packages.single.entrypoints.single;
        expect(entry.flavorByPlatform, isNull);
        expect(entry.toJson(), isNot(contains('flavorByPlatform')));
      },
    );

    test('a declared vocabulary refuses an unlisted flavor before '
        'building', () async {
      _writePackage(worktree, 'app', {
        'lib/main.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\n',
      });
      DeviceCache.write(runDir.path, [
        const DaemonDevice(id: 'phone', platformType: 'android'),
      ]);
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'flavors': {
                'mobile': ['local', 'staging'],
              },
              'entrypoints': [
                // The typo is in the declaration itself — the case the
                // vocabulary exists for, since without it this is a Gradle
                // failure minutes into the build.
                {'path': 'lib/main.dart', 'flavor': 'stagign'},
              ],
            },
          ],
        },
      );

      await expectLater(
        core.invoke('launch', arguments: {'device': 'phone'}),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('stagign'),
              contains('local, staging'),
              contains('android'),
            ),
          ),
        ),
      );

      // The caller's word is checked against the same list — a typo'd
      // override on Linux would otherwise run under a meaningless
      // FLUTTER_APP_FLAVOR with nothing gating the name.
      await expectLater(
        core.invoke('launch', arguments: {'device': 'phone', 'flavor': 'pord'}),
        throwsA(isA<RunRefusal>()),
      );
    });

    test('the vocabulary is echoed as written, empty lists and all', () async {
      _writePackage(worktree, 'app', {
        'lib/main.dart': 'void main() {}',
        'pubspec.yaml': 'name: app\n',
      });
      core = _coreFor(
        worktree,
        config: {
          'packages': [
            {
              'path': 'app',
              'flavors': {
                'mobile': ['local', 'staging'],
                'linux': <String>[],
              },
              'entrypoints': [
                {'path': 'lib/main.dart', 'flavor': 'local'},
              ],
            },
          ],
        },
      );

      var result = (await core.invoke('entrypoints'))! as RunEntrypointsResult;
      var package = result.packages.single;
      expect(package.flavors, {
        'mobile': ['local', 'staging'],
        'linux': <String>[],
      });
    });

    test(
      'a package declaring no vocabulary does not carry the field',
      () async {
        _writePackage(worktree, 'app', {
          'lib/main.dart': 'void main() {}',
          'pubspec.yaml': 'name: app\n',
        });
        core = _coreFor(
          worktree,
          config: {
            'packages': [
              {
                'path': 'app',
                'entrypoints': [
                  {'path': 'lib/main.dart'},
                ],
              },
            ],
          },
        );

        var result =
            (await core.invoke('entrypoints'))! as RunEntrypointsResult;
        var package = result.packages.single;
        expect(package.flavors, isNull);
        expect(package.toJson(), isNot(contains('flavors')));
      },
    );
  });

  group('the launcher log', () {
    test('reads the app id, the VM service and the outcome', () {
      var path = p.join(runDir.path, 'app-x.log');
      File(path).writeAsStringSync(
        [
          _event('app.start', {
            'appId': 'a1',
            'deviceId': 'phone',
            'directory': '/tmp/app',
            'supportsRestart': true,
            'launchMode': 'run',
          }),
          _event('app.progress', {
            'appId': 'a1',
            'id': '0',
            'progressId': 'launch',
            'message': 'Installing and launching…',
            'finished': false,
          }),
          _event('app.debugPort', {
            'appId': 'a1',
            'port': 4242,
            'wsUri': 'ws://127.0.0.1:4242/tok=/ws',
            'baseUri': 'http://127.0.0.1:4242/tok=/',
          }),
          _event('app.started', {'appId': 'a1'}),
        ].join('\n'),
      );

      var log = LaunchLog.read(path);

      expect(log.appId, 'a1');
      expect(log.vmService, 'ws://127.0.0.1:4242/tok=/ws');
      expect(log.progress, 'Installing and launching…');
      expect(log.started, isTrue);
      expect(log.summary, 'running');
    });

    test('a plain line is context, not a verdict', () {
      // `flutter run` opens with this, every time, before it has done anything
      // wrong. Treating it as a failure ended a wait on the first poll and
      // reported a launch as failed while it was still starting.
      var path = p.join(runDir.path, 'app-y.log');
      File(path).writeAsStringSync(
        'No devices found yet. Checking for wireless devices...\n',
      );

      var log = LaunchLog.read(path);

      expect(log.error, isNull);
      expect(log.output, startsWith('No devices found yet'));
      expect(log.failure(launcherAlive: true), isNull);
      // Once the launcher is gone it is the only account there is.
      expect(log.failure(launcherAlive: false), startsWith('No devices'));
    });

    test('a structured error is a verdict even while the launcher lives', () {
      var path = p.join(runDir.path, 'app-z.log');
      File(path).writeAsStringSync(
        _event('daemon.logMessage', {
          'level': 'error',
          'message': 'Gradle task assembleDebug failed',
        }),
      );

      var log = LaunchLog.read(path);

      expect(
        log.failure(launcherAlive: true),
        'Gradle task assembleDebug failed',
      );
    });

    group('the stage', () {
      String progressEvent(
        String id, {
        String? message,
        bool finished = false,
      }) => _event('app.progress', {
        'appId': 'a1',
        'id': id,
        'progressId': null,
        'message': message,
        'finished': finished,
      });

      test('a finished span stops being what the launcher is doing', () {
        // The measured bug: `app.progress` closes a span with `finished: true`
        // and a null message, so a reader that only assigned on the way in
        // held the last *started* message until the next one opened. On a
        // macOS launch that is the thirty-five seconds of Xcode build after
        // `Running pod install...`, narrated as pod install — and a stuck
        // build looked exactly the same as a build between spans.
        var path = p.join(runDir.path, 'app-spans.log');
        File(path).writeAsStringSync(
          [
            'Launching lib/main.dart on macOS in debug mode...',
            progressEvent('0', message: 'Running pod install...'),
            progressEvent('0', finished: true),
            '',
          ].join('\n'),
        );

        var log = LaunchLog.read(path);

        expect(log.progress, isNull, reason: 'nothing is open');
        expect(log.stage, 'building');
      });

      test('an open span is the stage, because it is the tool speaking', () {
        var path = p.join(runDir.path, 'app-open.log');
        File(path).writeAsStringSync(
          [
            'Launching lib/main.dart on macOS in debug mode...',
            progressEvent('0', message: 'Running pod install...'),
            progressEvent('0', finished: true),
            progressEvent('1', message: 'Building macOS application...'),
            '',
          ].join('\n'),
        );

        expect(LaunchLog.read(path).stage, 'Building macOS application...');
      });

      test('pub resolution is narrated, though nothing structured has been '
          'said yet', () {
        // Measured at 15s warm and minutes on a cold cache, and it happens
        // entirely before the daemon handshake — so `app.progress` covers none
        // of it and the panel said the literal word `starting` throughout.
        var path = p.join(runDir.path, 'app-pub.log');
        File(path).writeAsStringSync(
          'Resolving dependencies in `/repo`...\nDownloading packages...\n',
        );

        expect(LaunchLog.read(path).stage, 'resolving dependencies');
      });

      test('the artifact exists, so what is left is getting it onto the '
          'device', () {
        var path = p.join(runDir.path, 'app-built.log');
        File(path).writeAsStringSync(
          [
            'Launching lib/main.dart on macOS in debug mode...',
            '\u2713 Built build/macos/Build/Products/Debug/Example.app',
            '',
          ].join('\n'),
        );

        expect(LaunchLog.read(path).stage, 'installing on the device');
      });

      test('the ladder only climbs', () {
        // A log is read from the top on every poll. A rule that answered with
        // the *last* line to match would drop back to `resolving dependencies`
        // the moment a build printed a line about a package, and a phrase that
        // goes backwards reads as the build restarting.
        var path = p.join(runDir.path, 'app-ladder.log');
        File(path).writeAsStringSync(
          [
            'Launching lib/main.dart on macOS in debug mode...',
            'Resolving dependencies for a plugin...',
            '',
          ].join('\n'),
        );

        expect(LaunchLog.read(path).stage, 'building');
      });

      test('a run that is not launching any more has no stage at all', () {
        // `building` said about a dead run is the same lie in a new place. The
        // question there is *what happened*, which is `summary` and `failure`.
        var path = p.join(runDir.path, 'app-done.log');
        File(path).writeAsStringSync(
          [
            'Launching lib/main.dart on macOS in debug mode...',
            _event('app.started', {'appId': 'a1'}),
            '',
          ].join('\n'),
        );

        var log = LaunchLog.read(path);

        expect(log.stage, isNull);
        expect(log.summary, 'running');
      });
    });

    test('two flavors of one entry point are two runs', () {
      // Not cosmetic: `dev` and `prod` install as different bundle ids and sit
      // on the phone together. One key would give them one handle and one log,
      // which is the collision that already published a dead VM service once.
      var base = runHandleKey(worktree.path, 'phone', 'lib/main.dart');
      var dev = runHandleKey(worktree.path, 'phone', 'lib/main.dart', 'dev');
      var prod = runHandleKey(worktree.path, 'phone', 'lib/main.dart', 'prod');

      expect(dev, isNot(prod));
      expect(dev, isNot(base));
      // A run with no flavor keeps the key it always had, so nothing written
      // before flavors existed is orphaned.
      expect(runHandleKey(worktree.path, 'phone', 'lib/main.dart', null), base);
    });

    test('a flavor survives the handle file and the label says it', () {
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        entrypointName: 'App',
        flavor: 'staging',
      );

      var read = scanRunHandles(runDir.path).single;
      expect(read.flavor, 'staging');
      expect(read.key, handle.key);
      expect(read.runLabel, 'App (staging)');
      // And a run without one is unchanged.
      expect(
        _writeHandle(
          runDir,
          worktree,
          device: 'sim',
          entrypoint: 'lib/main.dart',
          entrypointName: 'App',
        ).runLabel,
        'App',
      );
    });

    test('an iOS build failure reports its reason, not its last line', () {
      // Trimmed from a real log: `fw run run launch` on a cabled iPhone 16
      // against a project whose signing team has no account on this machine.
      // The tool emits **nothing structured** for any of it — no
      // `daemon.logMessage`, no error on `app.stop` — so the reason is only in
      // the plain lines, and the last of them is the one that says nothing.
      var path = p.join(runDir.path, 'app-ios.log');
      File(path).writeAsStringSync(
        [
          _event('app.start', {
            'appId': 'a1',
            'deviceId': '00008140-0011296E1E60801C',
            'directory': '/tmp/app',
            'launchMode': 'run',
          }),
          _event('app.progress', {
            'appId': 'a1',
            'id': '0',
            'message': 'Running Xcode build...',
            'finished': false,
          }),
          _event('app.progress', {'appId': 'a1', 'id': '0', 'finished': true}),
          'Xcode build done.                                            3.1s',
          'Failed to build iOS app',
          'Could not build the precompiled application for the device.',
          'Error (Xcode): No Account for Team "B7V224LKE4".',
          '/tmp/app/ios/Runner.xcodeproj',
          '',
          'Error: could not code sign the application.',
          '',
          'To resolve this issue, try the following steps:',
          '  1. Open the project in Xcode:',
          '     open ios/Runner.xcworkspace',
          "Error launching application on Xavier's iPhone16.",
          _event('app.stop', {'appId': 'a1'}),
          'App failed to start',
        ].join('\n'),
      );

      var log = LaunchLog.read(path);

      // Nothing structured said a word about it.
      expect(log.error, isNull);
      expect(log.stopped, isTrue);
      expect(log.started, isFalse);

      var failure = log.failure(launcherAlive: false)!;
      // The cause, which used to be dropped entirely.
      expect(failure, contains('No Account for Team "B7V224LKE4"'));
      expect(failure, contains('could not code sign the application'));
      // And the fix, which is the reason a block beats a line.
      expect(failure, contains('open ios/Runner.xcworkspace'));
      // The summary line is still there, just no longer the whole answer.
      expect(failure, contains('App failed to start'));
      // A row gets one line, and it is not the useless one.
      expect(log.failureHeadline, 'Failed to build iOS app');
    });

    test('app.stop does not clear the words printed after it', () {
      // The ordering that made this subtle: `app.stop` arrives *before* the
      // tool explains itself, so a rule of "a structured event ends the block"
      // applied to it would throw away the whole reason.
      var path = p.join(runDir.path, 'app-order.log');
      File(path).writeAsStringSync(
        [
          _event('app.stop', {'appId': 'a1'}),
          'Error: something went wrong afterwards',
        ].join('\n'),
      );

      expect(
        LaunchLog.read(path).failure(launcherAlive: false),
        contains('something went wrong afterwards'),
      );
    });

    test('a started run that later stops is not a failure', () {
      var path = p.join(runDir.path, 'app-stopped.log');
      File(path).writeAsStringSync(
        [
          _event('app.started', {'appId': 'a1'}),
          _event('app.stop', {'appId': 'a1'}),
          'Application finished.',
        ].join('\n'),
      );

      var log = LaunchLog.read(path);

      expect(log.started, isTrue);
      expect(log.failure(launcherAlive: false), isNull);
    });

    test('a half-written event line is a log that says less, not a crash', () {
      // Read while another process appends to it, so a torn line is normal.
      var path = p.join(runDir.path, 'app-torn.log');
      File(path).writeAsStringSync('[{"event":"app.st}]\nstill building\n');

      expect(LaunchLog.read(path).output, 'still building');
    });

    test('tops a handle up from its log and rewrites the file', () {
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
        logPath: p.join(runDir.path, 'app-w.log'),
      );
      File(handle.logPath!).writeAsStringSync(
        [
          _event('app.debugPort', {
            'appId': 'a9',
            'port': 1,
            'wsUri': 'ws://127.0.0.1:9/t=/ws',
            'baseUri': 'http://127.0.0.1:9/t=/',
          }),
        ].join('\n'),
      );

      var updated = refreshFromLog(handle);

      expect(updated.vmService, 'ws://127.0.0.1:9/t=/ws');
      expect(updated.appId, 'a9');
      // Rewritten, so the next process to read the ledger does not have to
      // parse the log again — and a process that never watched the launch can
      // still drive the app.
      expect(
        scanRunHandles(runDir.path).single.vmService,
        'ws://127.0.0.1:9/t=/ws',
      );
    });

    test('corrects a handle whose service address is stale', () {
      // The regression that made a relaunch look dead. The key is stable across
      // relaunch by design, so two runs of the same entry point on the same
      // device share one log file — and a handle written during the window
      // before the new launcher truncated it carries the *previous* run's URI.
      // `refreshFromLog` used to return early once the handle had both fields,
      // which made that wrong value permanent.
      var handle = _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
        logPath: p.join(runDir.path, 'app-w.log'),
        vmService: 'ws://127.0.0.1:1111/old=/ws',
        appId: 'previous',
      );
      File(handle.logPath!).writeAsStringSync(
        _event('app.debugPort', {
          'appId': 'current',
          'port': 2222,
          'wsUri': 'ws://127.0.0.1:2222/new=/ws',
          'baseUri': 'http://127.0.0.1:2222/new=/',
        }),
      );

      var updated = refreshFromLog(handle);

      expect(updated.vmService, 'ws://127.0.0.1:2222/new=/ws');
      expect(updated.appId, 'current');
      expect(
        scanRunHandles(runDir.path).single.vmService,
        'ws://127.0.0.1:2222/new=/ws',
      );
    });
  });

  group('control', () {
    // "I cannot tell what you meant" throws, the way a bad argument does
    // anywhere else; "I tried and it did not work" comes back as ok: false.
    // The difference is whether anything was attempted.
    test('says what is running when nothing is', () async {
      await expectLater(
        core.invoke('reload'),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            contains('Nothing is running'),
          ),
        ),
      );
    });

    test('refuses to guess between two running apps', () async {
      for (var entrypoint in ['lib/a.dart', 'lib/b.dart']) {
        _writeHandle(
          runDir,
          worktree,
          device: 'phone',
          entrypoint: entrypoint,
          launcherPid: pid,
        );
      }

      await expectLater(
        core.invoke('restart'),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            contains('More than one app matches'),
          ),
        ),
      );
    });

    test('the ambiguity refusal names each worktree', () async {
      // Two Studios on one device/entrypoint pair used to refuse with two
      // identical strings — no argument could pick one. The worktree is the
      // discriminator, so the refusal has to say it.
      for (var entrypoint in ['lib/a.dart', 'lib/b.dart']) {
        _writeHandle(
          runDir,
          worktree,
          device: 'phone',
          entrypoint: entrypoint,
          worktreeName: 'mine',
          launcherPid: pid,
        );
      }

      await expectLater(
        core.invoke('restart'),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('Pass `run`'), contains('mine: phone/lib/a.dart')),
          ),
        ),
      );
    });

    test('two launchers of one run are told apart by their ids', () async {
      // What a worktree, a device and an entry point cannot answer: two
      // launchers up for the *same* run. Their descriptions are one string
      // twice, and the key they share is stable across relaunch by design —
      // so the pid-qualified id is the only thing that can pick either, and a
      // refusal naming an argument the caller cannot look up is a dead end.
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: await _livePid(),
      );

      var runs = scanRunHandles(runDir.path);
      expect(runs, hasLength(2));
      expect(runs.first.key, runs.last.key, reason: 'one run, two launchers');
      expect(runs.first.runId, isNot(runs.last.runId));

      await expectLater(
        core.invoke('restart'),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Pass `run`'),
              contains(runs.first.runId),
              contains(runs.last.runId),
            ),
          ),
        ),
      );
    });

    test('an id selects the one of them it names', () async {
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: await _livePid(),
      );
      var wanted = scanRunHandles(runDir.path).last;

      var result =
          (await core.invoke('restart', arguments: {'run': wanted.runId}))!
              as RunControlResult;

      // The answer names the run it moved — the other half of a refusal that
      // told the caller to name one.
      expect(result.run, wanted.runId);
    });

    test('an unknown id is refused as an id, not as a missing app', () async {
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );

      await expectLater(
        core.invoke('restart', arguments: {'run': 'app-nope-1'}),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('No run "app-nope-1"'), contains('apps')),
          ),
        ),
      );
    });

    test('apps reports the id the refusal asks for', () async {
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );

      var result = (await core.invoke('apps'))! as RunAppsResult;

      expect(result.apps.single.run, scanRunHandles(runDir.path).single.runId);
    });

    test("a named worktree reaches a sibling checkout's run", () async {
      // Same device and entry point as this worktree would use — the pair the
      // arguments cannot tell apart. Naming the worktree selects it; the
      // reload then genuinely fails because nothing answers, which is the
      // proof an attempt was made against *that* handle.
      core.debugRepoWorktrees = Future.value({
        p.canonicalize(worktree.path),
        p.canonicalize(otherWorktree.path),
      });
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        worktreeName: 'feature-x',
        launcherPid: pid,
        vmService: 'ws://127.0.0.1:1/ws',
      );

      var result =
          (await core.invoke('reload', arguments: {'worktree': 'feature-x'}))!
              as RunControlResult;

      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
    });

    test('a name never selects across repositories', () async {
      // `~` is every repository's main checkout, so a name matched against
      // the machine-wide ledger would drive an unrelated project's app the
      // moment exactly one matched. The pool is this repo's worktrees; a
      // handle from outside it is invisible even when its name fits.
      core.debugRepoWorktrees = Future.value({p.canonicalize(worktree.path)});
      _writeHandle(
        runDir,
        otherWorktree, // some other repository's checkout
        device: 'phone',
        entrypoint: 'lib/main.dart',
        worktreeName: '~',
        launcherPid: pid,
        vmService: 'ws://127.0.0.1:1/ws',
      );

      await expectLater(
        core.invoke('reload', arguments: {'worktree': '~'}),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            contains('Nothing is running from worktree "~"'),
          ),
        ),
      );
    });

    test('an empty own ledger points at the worktrees that do run', () async {
      core.debugRepoWorktrees = Future.value({
        p.canonicalize(worktree.path),
        p.canonicalize(otherWorktree.path),
      });
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        worktreeName: 'feature-x',
        launcherPid: pid,
      );

      await expectLater(
        core.invoke('reload'),
        throwsA(
          isA<RunRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Nothing is running from this worktree'),
              contains('feature-x (phone/lib/main.dart)'),
              contains('worktree'),
            ),
          ),
        ),
      );
    });

    test("the Running list says which runs are not this project's", () async {
      // The ledger is machine-wide, so this heading lists apps nobody here
      // launched. The worktree name was already on the row and said nothing on
      // its own: a reader who does not know every checkout on the machine reads
      // an unrelated repository's app as one of this project's.
      core.debugRepoWorktrees = Future.value({p.canonicalize(worktree.path)});
      _writeHandle(
        runDir,
        worktree,
        device: 'macos',
        entrypoint: 'lib/main.dart',
        worktreeName: 'ours',
        launcherPid: pid,
      );
      _writeHandle(
        runDir,
        otherWorktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        worktreeName: 'theirs',
        launcherPid: pid,
      );
      await core.computeAll();

      var text = core.report.toText();
      expect(text, contains('theirs · another checkout'));
      expect(
        text,
        isNot(contains('ours · another checkout')),
        reason: 'our own run carries no marker — it is the unremarkable case',
      );
    });

    test('reports a reload it could not do rather than throwing', () async {
      // The app is unreachable, so the attempt is real and it fails. That is
      // an outcome, not a mistake by the caller.
      _writeHandle(
        runDir,
        worktree,
        device: 'phone',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
        vmService: 'ws://127.0.0.1:1/ws',
      );

      var result = (await core.invoke('reload'))! as RunControlResult;

      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
    });
  });

  group('what the window is told to wait for', () {
    // `fw capture` waits for every plugin in the worktree session, not for the
    // one panel it was sent to photograph. So a branch here that reports busy
    // because data is *missing* rather than *coming* holds up every capture in
    // the app — measured at 300 of the 360 seconds a cold one took, waiting on
    // a device scan nobody had started, to photograph the previews panel.

    test('a core nobody has opened is not finding devices', () {
      expect(
        core.isFindingDevices,
        isFalse,
        reason: 'nothing is looking, so there is nothing to wait for',
      );
      expect(core.devices, isEmpty, reason: 'and it still has no list');
    });

    test('a core the panel opened is', () {
      RunCore.debugLive = false;
      addTearDown(() => RunCore.debugLive = true);

      core.track();

      expect(core.isFindingDevices, isTrue);
    });

    test('an empty cache does not mean a scan is under way', () {
      // The exact shape of the bug: no daemon and no devices read as "still
      // finding them", when in a capture process both are permanent.
      DeviceCache.write(runDir.path, const []);

      expect(core.isLive, isFalse);
      expect(core.devices, isEmpty);
      expect(core.isFindingDevices, isFalse);
    });
  });

  group('panels', () {
    // Every app the run guest wraps has the channel transport installed, but
    // the `panels` channel is registered only when something declares a panel
    // — so an app that mounts no `Devbar` attaches fine and then answers
    // `no handler for panels.list`, which was handed to the caller raw.
    late _GuestChannels channels;

    setUp(() {
      channels = _GuestChannels();
      core.dispose();
      core = _coreFor(
        worktree,
        sources: RunSources(
          files: const DiskRunFiles(),
          apps: const LiveRunApps(),
          channels: channels,
        ),
      );
      _writeHandle(
        runDir,
        worktree,
        device: 'macos',
        entrypoint: 'lib/main.dart',
        launcherPid: pid,
      );
    });

    const noPanels =
        'The app is reporting, but no plugin declared a panel. A devbar '
        'plugin joins by implementing `DevbarPanelSource`.';

    Matcher refusedWith(String message) =>
        throwsA(isA<RunRefusal>().having((e) => e.message, 'message', message));

    test('an app that declared none lists none, and says why', () async {
      var result = (await core.invoke('panels'))! as RunPanelsResult;

      expect(result.panels, isEmpty);
      expect(result.note, noPanels);
    });

    test('asking it for a panel refuses with the same sentence', () async {
      await expectLater(
        core.invoke(
          'panelInvoke',
          arguments: {'panel': 'flags', 'action': 'reset'},
        ),
        refusedWith(noPanels),
      );
      await expectLater(
        core.invoke(
          'panelKnob',
          arguments: {'panel': 'flags', 'knob': 'newCheckout', 'value': true},
        ),
        refusedWith(noPanels),
      );
      await expectLater(
        core.invoke(
          'panelState',
          arguments: {'panel': 'flags', 'state': 'info'},
        ),
        refusedWith(noPanels),
      );
      await expectLater(
        core.invoke('panels', arguments: {'panel': 'flags'}),
        refusedWith(noPanels),
      );
    });

    test(
      'a panel it does not declare is refused with the ones it does',
      () async {
        Panels(channels.core).add('flags', 'Flags');

        await expectLater(
          core.invoke(
            'panelState',
            arguments: {'panel': 'net', 'state': 'info'},
          ),
          refusedWith('This app declares no panel "net" — it has flags.'),
        );
        // A panel that is there keeps the channel's own answer: the method is
        // what is missing, and a refusal about panels would be wrong about it.
        await expectLater(
          core.invoke(
            'panelInvoke',
            arguments: {'panel': 'flags', 'action': 'nope'},
          ),
          throwsA(
            predicate(
              (e) => e is! RunRefusal && '$e' == 'no handler for flags.nope',
            ),
          ),
        );
      },
    );
  });
}

/// An app's channels as the run guest serves them — a real [InspectorCore] —
/// reached in memory rather than over a VM service.
class _GuestChannels extends RunChannels {
  final core = InspectorCore(identity: () => const {});

  @override
  Future<RunAttachment> attach(RunHandle handle, {required String peer}) async {
    var attachment = _InMemoryAttachment(core);
    await attachment.session.attach();
    return attachment;
  }
}

class _InMemoryAttachment implements RunAttachment, InspectorPeer {
  _InMemoryAttachment(this.core);

  final InspectorCore core;

  late final session = AttachSession(
    sendFrame: (frame) => core.handleFrame(this, frame),
  );

  @override
  void send(Map<String, Object?> frame) => session.receive(frame);

  @override
  List<InspectorEvent> get received => session.received;

  @override
  Stream<InspectorEvent> get events => session.events;

  @override
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) => session.request(channel, method, params);

  @override
  Future<Map<String, Object?>?> details(int eventId) =>
      session.details(eventId);

  @override
  Future<void> close() async {}
}

RunCore _coreFor(
  Directory worktree, {
  Map<String, Object?> config = const {},
  FlutterSdkPath? sdk,
  RunSources sources = const RunSources.live(),
}) {
  var tree = Worktree(path: worktree.path, isMain: true);
  return RunCore(
    PluginHost(
      id: runPluginId,
      label: 'Run',
      worktree: tree,
      config: config,
      workspace: Workspace(
        root: tree.path,
        declared: [],
        discovered: [],
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: sdk ?? FlutterSdkPath('/tmp/flutter'),
      ),
    ),
    sources: sources,
  );
}

/// An SDK root whose `bin/dart` is the real one running this test.
///
/// A script source is run with the SDK the *project* resolved against, never a
/// `dart` looked up on PATH — so exercising it means giving the workspace an
/// SDK root that has a working `dart` under it, rather than pointing the runner
/// somewhere else for the test.
FlutterSdkPath _sdkWithRealDart(Directory worktree) {
  var root = Directory(p.join(worktree.path, '.sdk'))
    ..createSync(recursive: true);
  Directory(p.join(root.path, 'bin')).createSync();
  Link(p.join(root.path, 'bin', 'dart')).createSync(resolveDartExecutable());
  return FlutterSdkPath(root.path);
}

void _writeScript(Directory worktree, String source) {
  File(p.join(worktree.path, 'tool', 'env.dart'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);
}

Map<String, Object?> _configWithScript() => {
  'packages': [
    {
      'path': 'app',
      'entrypoints': [
        {
          'path': 'lib/main.dart',
          'knobs': [
            {
              'knob': 'serverPort',
              'from': {'script': 'tool/env.dart'},
            },
          ],
        },
      ],
    },
  ],
};

/// A package directory with [files] in it, keyed by package-relative path.
void _writePackage(Directory worktree, String path, Map<String, String> files) {
  for (var file in files.entries) {
    File(p.join(worktree.path, path, file.key))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(file.value);
  }
}

/// One `--machine` line, as the launcher writes them.
String _event(String name, Map<String, Object?> params) => jsonEncode([
  {'event': name, 'params': params},
]);

/// The generated guest wrapper for `app`'s `lib/main.dart`.
String _wrapperFor(Directory worktree) => File(
  p.join(worktree.path, 'app', '.dart_tool/flutterware/run/main_guest.dart'),
).readAsStringSync();

RunHandle _writeHandle(
  Directory runDir,
  Directory worktree, {
  required String device,
  required String entrypoint,
  String? logPath,
  String? entrypointName,
  String? worktreeName,
  String? vmService,
  String? appId,
  String? flavor,
  String? package,
  int launcherPid = 1,
  DateTime? startedAt,
  Map<String, String> knobs = const {},
}) {
  return RunHandle(
    worktree: worktree.path,
    worktreeName: worktreeName ?? '~',
    device: device,
    deviceName: device,
    entrypoint: entrypoint,
    entrypointName: entrypointName,
    package: package,
    flavor: flavor,
    launcherPid: launcherPid,
    vmService: vmService,
    appId: appId,
    logPath: logPath,
    knobs: knobs,
    startedAt: startedAt ?? DateTime.now(),
  ).publish(runDir.path);
}

/// Ends the launcher a successful `launch` started, and does not come back
/// until it is gone.
///
/// A launch outlives the call that made it. `launchApp` starts a *detached*
/// shell whose redirect opens the run's log with `>`, so the log is created by
/// a process nothing waits for — and the `deleteSync(recursive: true)` in
/// `tearDown` running beside it emptied the run directory, watched the shell
/// recreate the log, and failed the `rmdir` that followed with `Directory not
/// empty`. Measured 2026-08-18: 2 failures in 300 launches on an idle machine,
/// and about one full-suite `flutter test` in ten, landing on whichever of the
/// launching tests lost the race.
///
/// Killed rather than waited out, because a real launcher is `flutter run` and
/// would never exit on its own. What makes the delete safe is the wait *after*
/// the kill — a process that is gone cannot create a file — so a launcher that
/// will not die fails the test loudly instead of falling through to the delete
/// that would flake.
Future<void> _stopLauncher(RunHandle handle) async {
  Process.killPid(handle.launcherPid);
  var deadline = DateTime.now().add(const Duration(seconds: 10));
  while (isProcessAlive(handle.launcherPid)) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'the launcher ${handle.launcherPid} outlived the test that started '
        'it, so the run directory cannot be deleted without racing it',
      );
    }
    await Future.delayed(const Duration(milliseconds: 5));
  }
}

/// A pid that is certainly *there*, and gone when the test ends.
///
/// Two launchers alive at once is the whole state the run id exists for: a
/// probe sweeps the handle of a launcher that has died, so a dead pid would
/// leave one match and no ambiguity to refuse.
Future<int> _livePid() async {
  var process = await Process.start('sleep', const ['30']);
  addTearDown(process.kill);
  return process.pid;
}

/// A pid that is certainly gone: a process started and waited for.
///
/// Better than a large constant, which is only *probably* free and would make
/// the sweep tests flaky on whichever machine happened to be using it.
Future<int> _deadPid() async {
  var process = await Process.start('true', const []);
  await process.exitCode;
  return process.pid;
}
