import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_core.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:flutterware_app/src/utils/terminal_environment.dart';
import 'package:path/path.dart' as p;

/// Owned services, against **real processes**.
///
/// Nothing here is scripted, and that is deliberate: what this kind is made of
/// is a detached spawn, a pid that outlives the caller, a socket that either
/// accepts or does not, and a signal sent to a process group. A fake of any of
/// those would be a test of the fake. `sh` and `sleep` are what a POSIX host
/// has, and this feature is POSIX-only by construction — see
/// [OwnedServiceCore.start]'s refusal on Windows.
///
/// The one thing the tests *do* own is the port: readiness is pointed at a
/// socket the test binds and closes when it likes, which is what lets a single
/// `sleep` stand in for a server that is slow, a server that is broken and a
/// server that works.
void main() {
  late Directory runDir;
  late Directory project;
  late List<DevStackCore> cores;
  late List<int> spawned;

  DevStackCore coreWith(StackService service) {
    var core = DevStackCore(
      PluginHost(
        id: devStackPluginId,
        label: 'Dev stack',
        worktree: Worktree(path: project.path),
        workspace: Workspace(
          root: project.path,
          declared: [],
          discovered: [],
          appContext: AppContext(logger: LogClient.print()),
          // The real SDK, because the value sources are real `dart run`s.
          // `flutter test` puts the root it is running under in the
          // environment, which is the only honest way to reach the pinned one
          // from inside a test.
          flutterSdk: FlutterSdkPath(
            Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter',
          ),
        ),
        config: DevStack(services: [service]).config,
      ),
    );
    cores.add(core);
    return core;
  }

  OwnedServiceCore owned(StackService service) =>
      coreWith(service).only! as OwnedServiceCore;

  /// The handle the core wrote, or null. Read off disk rather than off the
  /// core, because the file *is* the contract: it is what a second GUI and a
  /// `fw` in another terminal see.
  Map<String, Object?>? handleOnDisk() {
    for (var entity in runDir.listSync()) {
      var name = entity.uri.pathSegments.last;
      if (entity is! File || !name.startsWith('svc-')) continue;
      if (!name.endsWith('.json')) continue;
      return (jsonDecode(entity.readAsStringSync()) as Map)
          .cast<String, Object?>();
    }
    return null;
  }

  /// A port nothing is listening on. Bound and released, so the number is real
  /// rather than hopeful.
  Future<int> freePort() async {
    var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var port = socket.port;
    await socket.close();
    return port;
  }

  /// A service that runs until it is stopped, recording its pid so the tear
  /// down can be sure it is gone.
  StackService sleeper(
    String id, {
    required Ready ready,
    String script = 'sleep 60',
    List<StackCommand> commands = const [],
  }) => StackService.owned(
    id,
    name: 'The $id',
    start: StackRun.command(['sh', '-c', script]),
    ready: ready,
    stopGrace: const Duration(seconds: 2),
    poll: const Duration(seconds: 30),
    commands: commands,
  );

  /// A Dart script in the project that prints [prints] and exits [exitCode].
  ///
  /// A real file run by the real `dart`, because what is being tested is
  /// whether a project's own tool can be asked a question and believed — and
  /// a fake of that is a fake of the whole feature.
  String valueScript(
    String name, {
    String? prints,
    String? says,
    int exitCode = 0,
  }) {
    File(p.join(project.path, name)).writeAsStringSync('''
import 'dart:io';
void main() {
  ${says == null ? '' : "stderr.writeln(r'$says');"}
  ${prints == null ? '' : "stdout.writeln(r'$prints');"}
  exit($exitCode);
}
''');
    return name;
  }

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-owned-run-');
    project = Directory.systemTemp.createTempSync('fw-owned-project-');
    cores = [];
    spawned = [];
    DevStackCore.runDirProvider = () => runDir.path;
  });

  tearDown(() async {
    // Every test that starts something must leave nothing behind. A leaked
    // `sleep 60` is invisible in a green suite and very visible in `ps` an
    // hour later.
    for (var core in cores) {
      for (var service in core.services) {
        if (service is OwnedServiceCore) {
          try {
            await service.stop();
          } on Object {
            // Already stopped, or never started.
          }
        }
      }
      core.dispose();
    }
    for (var pid in spawned) {
      if (isProcessAlive(pid)) {
        Process.runSync('/bin/sh', ['-c', 'kill -9 $pid']);
      }
    }
    DevStackCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, project]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('the lifecycle', () {
    test('a spawn is held by a handle, and a stop takes it away', () async {
      var service = owned(sleeper('worker', ready: const Ready.processAlive()));

      var started = await service.start();
      expect(started.ok, isTrue);
      expect(started.reading!.state, StackState.up);

      var handle = handleOnDisk()!;
      spawned.add(handle['pid']! as int);
      expect(isProcessAlive(handle['pid']! as int), isTrue);
      expect(handle['service'], 'worker');
      expect(handle['command'], 'sh -c sleep 60');
      expect(handle['worktree'], project.path);
      expect(service.status.message, 'up');

      var stopped = await service.stop();
      expect(stopped.ok, isTrue);
      expect(stopped.reading!.state, StackState.down);
      // The pid is gone and so is the claim on it — a handle outliving its
      // process is what makes the next start refuse a port that is free.
      expect(isProcessAlive(handle['pid']! as int), isFalse);
      expect(handleOnDisk(), isNull);
    });

    test('a command that falls over is down, with what it said', () async {
      var service = owned(
        sleeper(
          'worker',
          ready: const Ready.processAlive(),
          script: 'echo "no such database" >&2; exit 3',
        ),
      );

      var started = await service.start();
      // **The settle is what makes this answerable.** With nothing to poll,
      // "the pid is alive" is true for the two milliseconds between the fork
      // and the exit; reported then, a broken command reads as up and is
      // contradicted by the next poll.
      expect(started.ok, isFalse);
      expect(started.reading!.state, StackState.down);
      expect(started.output, contains('no such database'));
      expect(started.stderr, contains('exited'));
      expect(handleOnDisk(), isNull);
    });

    test('stopping what is not running is not an error', () async {
      var service = owned(sleeper('worker', ready: const Ready.processAlive()));

      var stopped = await service.stop();
      expect(stopped.ok, isTrue);
      expect(stopped.output, contains('Nothing to stop'));
      expect(service.reading.state, StackState.down);
    });

    test('a second start adopts the process the first one left', () async {
      var first = owned(sleeper('worker', ready: const Ready.processAlive()));
      await first.start();
      var pid = handleOnDisk()!['pid']! as int;
      spawned.add(pid);
      // The GUI goes away. The process does not — that is the whole point of
      // spawning detached, and the handle is the only thing that carries the
      // pid across.
      first.dispose();

      var second = owned(sleeper('worker', ready: const Ready.processAlive()));
      expect((await second.refresh()).state, StackState.up);

      var again = await second.start();
      expect(again.ok, isTrue);
      expect(again.output, contains('Already running as pid $pid'));
      // One process, not two: the handle count is the assertion, because two
      // servers on one port is exactly what this prevents.
      expect(
        runDir.listSync().where(
          (e) => e.path.contains('/svc-') && e.path.endsWith('.json'),
        ),
        hasLength(1),
      );
    });

    test('a stop takes the children with it', () async {
      var marker = File('${project.path}/child.pid');
      var service = owned(
        sleeper(
          'worker',
          ready: const Ready.processAlive(),
          script:
              r'sleep 60 & echo $! > '
              '${marker.path}; wait',
        ),
      );

      await service.start();
      var parent = handleOnDisk()!['pid']! as int;
      spawned.add(parent);
      var child = int.parse(marker.readAsStringSync().trim());
      spawned.add(child);
      expect(isProcessAlive(child), isTrue, reason: 'the grandchild is up');

      await service.stop();
      // **The group, not the pid.** A spawn is routinely a launcher wrapping
      // the thing that holds the port; signalling only the number we recorded
      // leaves that port held by a process nothing is tracking.
      expect(isProcessAlive(parent), isFalse);
      expect(isProcessAlive(child), isFalse);
    });
  });

  group('readiness', () {
    test('a port that never answers is running, not up', () async {
      var port = await freePort();
      var service = owned(
        sleeper(
          'server',
          ready: Ready.port(port, timeout: const Duration(milliseconds: 600)),
        ),
      );

      var started = await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      expect(started.ok, isFalse);
      expect(
        started.stderr,
        contains('nothing is accepting on localhost:$port'),
      );
      // Alive and silent is a state of its own. `down` would be false — the
      // process is there — and `up` would be the lister trap one level up.
      expect(service.reading.state, StackState.unavailable);
      expect(service.status.message, 'no answer');
      expect(service.badge, isNot(StatusBadge.none));
      // And it is exactly the state where someone most wants the stop button.
      expect(service.teardown(), hasLength(1));

      var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.close);
      expect((await service.refresh()).state, StackState.up);
      expect(service.reading.detail, contains('localhost:$port'));
    });

    test('a port held by something else is not down', () async {
      var port = await freePort();
      var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.close);
      var service = owned(
        sleeper(
          'server',
          ready: Ready.port(port, timeout: const Duration(seconds: 5)),
        ),
      );

      // **`down` would be the wrong answer and the expensive one.** It sends
      // someone to press Bring up and read a refusal, when one connect to a
      // local port — instant when nothing is there — answers it up front.
      expect((await service.refresh()).state, StackState.unavailable);
      expect(service.status.message, 'port taken');
      expect(service.reading.failure, contains('did not start it'));
      expect(service.reading.failure, contains('lsof'));
      // And no teardown step, because there is no pid here to signal: a
      // checkbox that could only report "nothing to stop" lies about what it
      // will do.
      expect(service.teardown(), isEmpty);
    });

    test('a port already held refuses the start by name', () async {
      var port = await freePort();
      var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.close);
      var service = owned(
        sleeper('server', ready: Ready.port(port, timeout: Duration.zero)),
      );

      await expectLater(
        service.start(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('already listening on localhost:$port'),
              // The sentence has to end somewhere useful. `EADDRINUSE` in a
              // log the reader has to go and find does not.
              contains('lsof'),
            ),
          ),
        ),
      );
      // Nothing was spawned, so nothing is claimed.
      expect(handleOnDisk(), isNull);
    });

    test('http wants an answer, not just a socket', () async {
      var port = await freePort();
      var service = owned(
        sleeper(
          'server',
          ready: Ready.http(
            port,
            path: '/health',
            timeout: const Duration(milliseconds: 400),
          ),
        ),
      );

      // The port is free at the spawn — anything else is refused before
      // anything is spawned, which is the test below this one. The stand-in
      // server arrives afterwards, exactly as a real one binds its socket some
      // way into its own startup.
      var started = await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      expect(started.ok, isFalse);
      expect(service.reading.failure, contains('did not answer'));

      var status = 503;
      var server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((request) {
          request.response.statusCode = status;
          unawaited(request.response.close());
        }),
      );
      // **A bound port is a promise about the socket, not about the service.**
      // This one is listening and saying no, which is precisely what a health
      // check that knows its database is down is for — and precisely what
      // `Ready.port` would have called success.
      expect((await service.refresh()).state, StackState.unavailable);
      expect(service.reading.failure, contains('answered 503'));

      status = 200;
      expect((await service.refresh()).state, StackState.up);
    });
  });

  group('a port the project computes', () {
    test('is asked once, used, and recorded in the handle', () async {
      var port = await freePort();
      var service = owned(
        sleeper(
          'server',
          ready: Ready.portFrom(
            ValueSource.script(valueScript('port.dart', prints: '$port')),
            timeout: const Duration(milliseconds: 300),
          ),
        ),
      );

      // Nothing is listening yet, so the start does not reach `up` — but the
      // number it went looking on is the one the script gave, which is what
      // this is about.
      await service.start();
      var handle = handleOnDisk()!;
      spawned.add(handle['pid']! as int);
      expect(handle['readyPort'], port);
      expect(service.readyDescription, contains('localhost:$port'));

      var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.close);
      expect((await service.refresh()).state, StackState.up);
    });

    test('is not asked again for a process already running', () async {
      var port = await freePort();
      var script = valueScript('port.dart', prints: '$port');
      Ready ready() => Ready.portFrom(
        ValueSource.script(script),
        timeout: const Duration(milliseconds: 300),
      );
      var first = owned(sleeper('server', ready: ready()));
      await first.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      first.dispose();

      // **The number this process was started against**, not the one the tool
      // would answer with now. The script is gone; the port is still known,
      // because it was written down at the start.
      File(p.join(project.path, script)).deleteSync();
      var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.close);
      var second = owned(sleeper('server', ready: ready()));
      expect((await second.refresh()).state, StackState.up);
      expect(second.reading.detail, contains('localhost:$port'));
    });

    test('refuses the start when the source cannot answer', () async {
      var service = owned(
        sleeper(
          'server',
          ready: Ready.portFrom(
            ValueSource.script(
              valueScript(
                'port.dart',
                says: 'no slot for this worktree',
                exitCode: 1,
              ),
            ),
            timeout: const Duration(milliseconds: 300),
          ),
        ),
      );

      // **Refused, not fallen back.** A service started against a port nobody
      // chose does not fail — it works, against whatever is on that port,
      // which in a monorepo is the checkout next door.
      await expectLater(
        service.start(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('could not be worked out'),
              contains('no slot for this worktree'),
              contains('nothing was spawned'),
            ),
          ),
        ),
      );
      expect(handleOnDisk(), isNull);
    });

    test('refuses a source that answers with something else', () async {
      var service = owned(
        sleeper(
          'server',
          ready: Ready.portFrom(
            ValueSource.script(valueScript('port.dart', prints: 'localhost')),
            timeout: const Duration(milliseconds: 300),
          ),
        ),
      );

      await expectLater(
        service.start(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('not a port number'),
          ),
        ),
      );
      expect(handleOnDisk(), isNull);
    });

    test('refuses a source that offers a list — a port is one', () async {
      var service = owned(
        sleeper(
          'server',
          ready: Ready.portFrom(
            ValueSource.script(
              valueScript('port.dart', prints: '["8080", "8081"]'),
            ),
            timeout: const Duration(milliseconds: 300),
          ),
        ),
      );

      await expectLater(
        service.start(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('a port is one value'),
          ),
        ),
      );
    });

    test('a port nobody can work out is its own state', () async {
      var service = owned(
        sleeper(
          'server',
          ready: Ready.portFrom(
            ValueSource.script(
              valueScript('port.dart', says: 'no .env here', exitCode: 1),
            ),
            timeout: const Duration(milliseconds: 300),
          ),
        ),
      );

      // Said before anyone presses anything. In a monorepo this *is* the
      // ordering problem — the stack that allocates the slot is not up — and
      // `down` would send someone to press Bring up to find that out.
      expect((await service.refresh()).state, StackState.unavailable);
      expect(service.status.message, 'no port');
      expect(service.reading.failure, contains('no .env here'));
      expect(service.teardown(), isEmpty);
      // And the readiness line names the tool rather than a number it has not
      // got.
      expect(service.readyDescription, contains('port.dart'));
    });
  });

  group('the environment', () {
    test("a service gets a new terminal's environment, not ours", () async {
      // Whichever way flutterware was started — the Dock, a terminal, an
      // agent's MCP server — the service sees the same variables, so a Dart
      // service's build hooks are not rebuilt for a PATH that merely moved.
      // A variable this process has that a shell would not set by itself.
      var ours = Platform.environment.keys.firstWhere(
        (key) =>
            RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(key) &&
            !const {
              'PATH',
              'HOME',
              'PWD',
              'OLDPWD',
              'SHLVL',
              'IFS',
              'PPID',
            }.contains(key) &&
            !key.startsWith('PS'),
      );
      debugTerminalEnvironment = {
        'PATH': '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'FROM_THE_TERMINAL': 'yes',
      };
      addTearDown(() => debugTerminalEnvironment = null);
      var service = owned(
        sleeper(
          'worker',
          ready: const Ready.processAlive(),
          script:
              r'echo "PATH=$PATH TERMINAL=$FROM_THE_TERMINAL OURS=${'
              '$ours'
              r':-unset}"; sleep 60',
        ),
      );

      await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      expect(service.lastOutput, contains('PATH=/usr/bin:/bin '));
      expect(service.lastOutput, contains('TERMINAL=yes'));
      expect(service.lastOutput, contains('OURS=unset'));
    });

    test('a computed one refuses the start when it cannot answer', () async {
      var core = coreWith(
        StackService.owned(
          'worker',
          start: StackRun.command(['sh', '-c', 'sleep 60']),
          ready: const Ready.processAlive(),
          envFrom: {
            'MODEL_TOOLS_DIR': ValueSource.script(
              valueScript(
                'model_tools.dart',
                says: 'the model tools are not installed',
                exitCode: 1,
              ),
            ),
          },
        ),
      );
      var service = core.only! as OwnedServiceCore;

      await expectLater(
        service.start(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('MODEL_TOOLS_DIR'),
              contains('the model tools are not installed'),
              contains('Nothing was spawned'),
            ),
          ),
        ),
      );
      expect(handleOnDisk(), isNull);
    });

    test('both kinds reach the spawned process', () async {
      var core = coreWith(
        StackService.owned(
          'worker',
          start: StackRun.command([
            'sh',
            '-c',
            r'echo "FF=$FFMPEG_BIN OM=$MODEL_TOOLS_DIR"; sleep 60',
          ]),
          ready: const Ready.processAlive(),
          env: {'FFMPEG_BIN': 'ffmpeg'},
          envFrom: {
            'MODEL_TOOLS_DIR': ValueSource.script(
              valueScript('model_tools.dart', prints: '/opt/model-tools/bin'),
            ),
          },
        ),
      );
      var service = core.only! as OwnedServiceCore;

      await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      expect(service.lastOutput, contains('FF=ffmpeg'));
      expect(service.lastOutput, contains('OM=/opt/model-tools/bin'));
    });
  });

  group('an executable the shell has to find', () {
    test('a tool that is not there refuses by name', () async {
      var core = coreWith(
        StackService.owned(
          'server',
          start: StackRun.tool('fw-definitely-not-a-real-binary'),
          ready: const Ready.processAlive(),
        ),
      );
      var service = core.only! as OwnedServiceCore;

      await expectLater(
        service.start(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('fw-definitely-not-a-real-binary'),
              contains('terminal'),
            ),
          ),
        ),
      );
      expect(handleOnDisk(), isNull);
    });

    test("a tool is looked up on the terminal's PATH, not ours", () async {
      var bin = Directory.systemTemp.createTempSync('fw_tool_');
      addTearDown(() => bin.deleteSync(recursive: true));
      var tool = File(p.join(bin.path, 'fw-only-in-the-terminal'))
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', tool.path]);
      debugTerminalEnvironment = {'PATH': bin.path};
      debugResetToolLookups();
      addTearDown(() {
        debugTerminalEnvironment = null;
        debugResetToolLookups();
      });

      expect(await lookUpTool('fw-only-in-the-terminal'), tool.path);
      // On this process's PATH, and not the terminal's.
      expect(await lookUpTool('sh'), isNull);
    });

    test('a tool that is there is spawned by absolute path', () async {
      var core = coreWith(
        StackService.owned(
          'sleeper',
          start: StackRun.tool('sleep', args: ['60']),
          ready: const Ready.processAlive(),
        ),
      );
      var service = core.only! as OwnedServiceCore;

      await service.start();
      var handle = handleOnDisk()!;
      spawned.add(handle['pid']! as int);
      expect(handle['command'], startsWith('/'));
      expect(handle['command'], endsWith('sleep 60'));
    });
  });

  group('what it offers', () {
    test('logs is there without being declared, and reads our file', () async {
      var service = owned(
        sleeper(
          'server',
          ready: const Ready.processAlive(),
          script: 'echo hello-from-the-service; sleep 60',
        ),
      );

      expect(service.actions().map((a) => a.id), contains('logs'));
      await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);

      var logs = (await service.invoke('logs')!)! as DevStackRunResult;
      expect(logs.output, contains('hello-from-the-service'));
      // The console shows the same thing without being asked, because the file
      // is ours and a poll is already reading it.
      expect(service.lastOutput, contains('hello-from-the-service'));
    });

    test('a declared logs wins, and there is only one of it', () async {
      var core = coreWith(
        sleeper(
          'server',
          ready: const Ready.processAlive(),
          commands: [
            StackCommand('logs', 'Logs', StackRun.command(['tail', '-n', '1'])),
          ],
        ),
      );
      core.scriptProcess(
        (command, {workingDirectory}) async =>
            ProcessResult(0, 0, 'the declared one', ''),
      );

      var ids = core.report.actions.map((a) => a.id).toList();
      expect(ids.where((id) => id == 'logs'), hasLength(1));
      var logs = (await core.invoke('logs'))! as DevStackRunResult;
      expect(logs.output, contains('the declared one'));
    });

    test('the console holds the log of a process we did not start', () async {
      var script = 'echo hello-again; sleep 60';
      var first = owned(
        sleeper('server', ready: const Ready.processAlive(), script: script),
      );
      await first.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      first.dispose();

      var second = owned(
        sleeper('server', ready: const Ready.processAlive(), script: script),
      );
      await second.refresh();
      // A restart used to leave the console empty, because it gated on a
      // command having been run in *this* session — while the file holding
      // everything the process had ever said was right there.
      expect(second.lastOutput, contains('hello-again'));
      expect(second.lastCommand, contains('sleep 60'));
    });

    test('a command holds the console against the next poll', () async {
      var core = coreWith(
        sleeper(
          'server',
          ready: const Ready.processAlive(),
          script: 'echo from-the-log; sleep 60',
          commands: [
            StackCommand('probe', 'Probe', StackRun.command(['echo', 'hi'])),
          ],
        ),
      );
      core.scriptProcess(
        (command, {workingDirectory}) async =>
            ProcessResult(0, 0, 'from-the-command', ''),
      );
      var service = core.only! as OwnedServiceCore;

      await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      expect(service.lastOutput, contains('from-the-log'));

      await service.runCommand('probe');
      expect(service.lastOutput, contains('from-the-command'));
      // **The poll must not take it back.** One console, two writers: the log
      // is continuous and the command output is the answer to a button
      // somebody just pressed, and three seconds later is not when to replace
      // it — least of all under a header still naming the command.
      await service.refresh();
      expect(service.lastOutput, contains('from-the-command'));

      await service.invoke('logs');
      expect(service.lastOutput, contains('from-the-log'));
    });

    test(
      'restart refuses to start again when the stop did not finish',
      () async {
        var service = owned(
          sleeper('worker', ready: const Ready.processAlive()),
        );
        await service.start();
        var pid = handleOnDisk()!['pid']! as int;
        spawned.add(pid);

        var restarted =
            (await service.invoke('restart')!)! as DevStackRunResult;
        expect(restarted.ok, isTrue);
        var second = handleOnDisk()!['pid']! as int;
        spawned.add(second);
        expect(second, isNot(pid), reason: 'a new process, not the old one');
        expect(isProcessAlive(pid), isFalse);
      },
    );

    test('a start that adopts something silent is not ok', () async {
      var port = await freePort();
      var service = owned(
        sleeper(
          'server',
          ready: Ready.port(port, timeout: const Duration(milliseconds: 300)),
        ),
      );
      await service.start();
      spawned.add(handleOnDisk()!['pid']! as int);
      expect(service.reading.state, StackState.unavailable);

      // **Adopted is not the same as up.** The caller asked for the service to
      // be usable, not for a pid to exist; reporting success here sends them
      // off to use a socket nothing is listening on.
      var again = await service.start();
      expect(again.ok, isFalse);
      expect(again.output, contains('Already running as pid'));
      expect(again.stderr, contains('nothing is accepting'));
    });

    test('the projection says what it starts even when it is down', () {
      var service = owned(sleeper('server', ready: const Ready.processAlive()));

      var starts = service.viewRows().whereType<ViewField>().firstWhere(
        (row) => row.label == 'Starts',
      );
      expect(starts.value, 'sh -c sleep 60');
    });

    test('the provenance says what was spawned and how ready is decided', () {
      var service = owned(
        sleeper(
          'server',
          ready: Ready.http(
            8100,
            path: '/health',
            timeout: const Duration(seconds: 5),
          ),
        ),
      );

      expect(service.provenance, [
        'start · sh -c sleep 60',
        'ready · GET localhost:8100/health answers',
      ]);
    });

    test('an owned service brings its own actions and nothing else', () {
      var core = coreWith(sleeper('server', ready: const Ready.processAlive()));

      expect(core.report.actions.map((a) => a.id), [
        // The stack's, not the service's: there whatever the stack holds, so a
        // caller has the same verbs however many services there are.
        'ensure',
        'history',
        'status',
        'start',
        'stop',
        'restart',
        'logs',
      ]);
      // Nothing is destructive: stopping a dev server destroys no data, and a
      // confirmation on every stop is a confirmation nobody reads.
      expect(core.report.actions.every((a) => !a.danger), isTrue);
    });
  });
}
