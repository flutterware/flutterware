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
import 'package:flutterware_app/src/world/open_world.dart' show WorldRefusal;
import 'package:flutterware_app/src/world/world_stack.dart';
import 'package:path/path.dart' as p;

/// `ensure`: several services brought up in the order their `needs` say.
///
/// The delegated services are scripted — a fake `db` whose `up` flips what its
/// `status` answers — and the owned ones are real processes, because what an
/// owned start is made of (a detached spawn, a pid, a socket) is what a fake
/// would leave out.
void main() {
  late Directory runDir;
  late Directory project;
  late List<DevStackCore> cores;

  /// What each scripted command was asked, in order.
  late List<String> ran;

  /// The scripted delegated services: id → whether its `status` says up.
  late Map<String, bool> up;

  /// Scripted `up` commands that fail, with what they print on stderr.
  late Map<String, String> failingUp;

  /// Scripted `up` commands that wait for this before they return.
  late Map<String, Completer<void>> slowUp;

  late String marker;

  DevStackCore coreWith(Map<String, Object?> config) {
    var core =
        DevStackCore(
          PluginHost(
            id: devStackPluginId,
            label: 'Dev stack',
            worktree: Worktree(path: project.path),
            workspace: Workspace(
              root: project.path,
              declared: [],
              discovered: [],
              appContext: AppContext(logger: LogClient.print()),
              flutterSdk: FlutterSdkPath(
                Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter',
              ),
            ),
            config: config,
          ),
        )..scriptProcess((command, {workingDirectory}) async {
          var line = command.join(' ');
          ran.add(line);
          var [id, verb] = command;
          if (verb == 'status') {
            return ProcessResult(0, up[id]! ? 0 : 1, '', '');
          }
          if (slowUp[id] case var gate?) await gate.future;
          if (failingUp[id] case var said?) {
            return ProcessResult(0, 1, '', said);
          }
          up[id] = true;
          File(marker).writeAsStringSync(id);
          return ProcessResult(0, 0, '$id is up', '');
        });
    cores.add(core);
    return core;
  }

  StackService scripted(String id, {List<String> needs = const []}) {
    up.putIfAbsent(id, () => false);
    return StackService.delegated(
      id,
      name: 'The $id',
      needs: needs,
      probe: Probe.exitCode(StackRun.command([id, 'status'])),
      start: StackRun.command([id, 'up']),
      stop: StackRun.command([id, 'down']),
    );
  }

  /// A real process that runs only once [marker] exists — so it dies on the
  /// spot if it was started before what it needs.
  StackService server({
    List<String> needs = const [],
    Ready ready = const Ready.processAlive(),
  }) => StackService.owned(
    'server',
    name: 'The server',
    needs: needs,
    start: StackRun.command(['sh', '-c', _runsOnlyOnceDbIsUp]),
    env: {'MARKER': marker},
    ready: ready,
    stopGrace: const Duration(seconds: 2),
    poll: const Duration(seconds: 30),
  );

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

  Future<int> freePort() async {
    var socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var port = socket.port;
    await socket.close();
    return port;
  }

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-ensure-run-');
    project = Directory.systemTemp.createTempSync('fw-ensure-project-');
    marker = p.join(project.path, 'db-is-up');
    cores = [];
    ran = [];
    up = {};
    failingUp = {};
    slowUp = {};
    DevStackCore.runDirProvider = () => runDir.path;
    debugTerminalEnvironment = Map.of(Platform.environment);
  });

  tearDown(() async {
    for (var core in cores) {
      for (var service in core.services) {
        if (service is OwnedServiceCore) {
          try {
            await service.stop();
          } on Object {
            // Never started.
          }
        }
      }
      core.dispose();
    }
    debugTerminalEnvironment = null;
    DevStackCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, project]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('starts what a service needs before the service', () async {
    var core = coreWith(
      DevStack(
        services: [
          server(needs: ['db']),
          scripted('db'),
        ],
      ).config,
    );

    var result = await core.ensure(ids: ['server']);

    expect([for (var s in result.services) s.id], ['db', 'server']);
    expect(result['db']!.outcome, EnsureOutcome.started);
    expect(result['server']!.outcome, EnsureOutcome.started);
    expect(result.ok, isTrue);
    expect(ran, contains('db up'));
  });

  test('leaves a service that is already up alone', () async {
    var core = coreWith(DevStack(services: [scripted('db')]).config);
    up['db'] = true;

    var result = await core.ensure();

    expect(result['db']!.outcome, EnsureOutcome.alreadyUp);
    expect(ran, ['db status']);
  });

  test('a service that fails holds back only what needs it', () async {
    var core = coreWith(
      DevStack(
        services: [
          scripted('db'),
          scripted('cache'),
          server(needs: ['db']),
        ],
      ).config,
    );
    up['cache'] = true;
    failingUp['db'] = 'port 5432 is already in use';

    var result = await core.ensure();

    expect(result.ok, isFalse);
    var db = result['db']!;
    expect(db.outcome, EnsureOutcome.failed);
    expect(db.failure, contains('exited with code 1'));
    expect(db.output, contains('port 5432 is already in use'));
    expect(result['cache']!.outcome, EnsureOutcome.alreadyUp);
    var skipped = result['server']!;
    expect(skipped.outcome, EnsureOutcome.skipped);
    expect(skipped.failure, contains('The db'));
    expect(handleOnDisk(), isNull, reason: 'the server was never spawned');
  });

  test('an owned service comes back with its port and URL', () async {
    var port = await freePort();
    var core = coreWith(
      DevStack(
        services: [
          server(
            ready: Ready.http(
              port,
              path: '/health',
              timeout: const Duration(seconds: 10),
            ),
          ),
        ],
      ).config,
    );
    File(marker).writeAsStringSync('');

    var ensuring = core.ensure();
    // Answered by the test, once the process is there — a port bound before
    // the start would be refused as someone else's.
    while (handleOnDisk() == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    var http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(http.close);
    http.listen((request) => request.response.close());
    var result = await ensuring;

    var ensured = result['server']!;
    expect(ensured.outcome, EnsureOutcome.started);
    expect(ensured.port, port);
    expect(ensured.url, 'http://localhost:$port');
    expect(ensured.toJson()['url'], 'http://localhost:$port');
  });

  test(
    'waits for a start already in flight rather than starting twice',
    () async {
      var core = coreWith(DevStack(services: [scripted('db')]).config);
      var gate = slowUp['db'] = Completer<void>();
      var db = core.services.single;

      var pressed = db.start();
      var ensuring = core.ensure();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      gate.complete();
      await pressed;
      var result = await ensuring;

      expect(result['db']!.outcome, EnsureOutcome.alreadyUp);
      expect(ran.where((line) => line == 'db up'), hasLength(1));
    },
  );

  test('a service with no start command is reported, not waited on', () async {
    var core = coreWith(
      DevStack(
        services: [
          StackService.delegated(
            'shared',
            probe: Probe.exitCode(StackRun.command(['shared', 'status'])),
          ),
        ],
      ).config,
    );
    up['shared'] = false;

    var result = await core.ensure();

    expect(result['shared']!.outcome, EnsureOutcome.failed);
    expect(result['shared']!.failure, contains('no start command'));
  });

  group('refuses, starting nothing,', () {
    // Written as raw config, because DevStack itself refuses both shapes:
    // these are configs from a flutterware that did not.
    Map<String, Object?> raw(Map<String, List<String>> needs) => {
      'services': [
        for (var MapEntry(:key, :value) in needs.entries)
          {...scripted(key).toJson(), 'needs': value},
      ],
    };

    test('a need that names no service', () async {
      var core = coreWith(
        raw({
          'server': ['database'],
        }),
      );

      await expectLater(
        core.ensure(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"server" needs "database"'),
              contains('Nothing was started'),
            ),
          ),
        ),
      );
      expect(ran, isEmpty);
    });

    test('an id that names no service', () async {
      var core = coreWith(raw({'db': []}));

      await expectLater(
        core.ensure(ids: ['dbb']),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('The services are: db'),
          ),
        ),
      );
    });

    test('needs that go round in a circle', () async {
      var core = coreWith(
        raw({
          'a': ['b'],
          'b': ['a'],
        }),
      );

      await expectLater(
        core.ensure(),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('a → b → a'),
          ),
        ),
      );
      expect(ran, isEmpty);
    });
  });

  test(
    'the action takes ids as a list or as one comma-joined string',
    () async {
      var core = coreWith(
        DevStack(services: [scripted('db'), scripted('cache')]).config,
      );
      expect(core.report.actions.map((a) => a.id), contains('ensure'));

      var joined =
          (await core.invoke('ensure', arguments: {'services': 'cache'}))!
              as StackEnsureResult;
      expect([for (var s in joined.services) s.id], ['cache']);

      var listed =
          (await core.invoke(
                'ensure',
                arguments: {
                  'services': ['db', 'cache'],
                },
              ))!
              as StackEnsureResult;
      expect([for (var s in listed.services) s.id], ['db', 'cache']);
    },
  );

  group('for a world', () {
    test('says what it starts and how each ended, then answers each '
        'one', () async {
      var core = coreWith(
        DevStack(
          services: [
            server(needs: ['db']),
            scripted('db'),
          ],
        ).config,
      );
      var said = <String>[];

      var services = await DevStackForWorlds(core)
          .bringUp(['server'], say: said.add, world: 'Pickup order');

      expect([for (var s in services) s.id], ['db', 'server']);
      expect([for (var s in services) s.name], ['The db', 'The server']);
      expect(said, [
        'Starting The db',
        'The db started',
        'Starting The server',
        'The server started',
      ]);

      said.clear();
      await DevStackForWorlds(core)
          .bringUp(['server'], say: said.add, world: 'Pickup order');
      expect(said, ['The db is up', 'The server is up']);
    });

    test('a service that does not come up fails the world with why', () async {
      failingUp['db'] = 'Cannot connect to the Docker daemon.';
      var core = coreWith(
        DevStack(
          services: [
            server(needs: ['db']),
            scripted('db'),
          ],
        ).config,
      );
      var said = <String>[];

      await expectLater(
        DevStackForWorlds(core)
            .bringUp(['server'], say: said.add, world: 'Pickup order'),
        throwsA(
          isA<WorldRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('The db did not come up, so the world did not start'),
              endsWith('The Dev stack panel has its log.'),
            ),
          ),
        ),
      );
      expect(said.first, 'Starting The db');
      expect(said, contains('  Cannot connect to the Docker daemon.'));
      expect(
        said.last,
        'The server: Not started, because it needs The db, which did not '
        'come up.',
      );
      expect(handleOnDisk(), isNull);
    });

    test('a need that names no service says where needs are written', () async {
      var core = coreWith(DevStack(services: [scripted('db')]).config);

      await expectLater(
        DevStackForWorlds(core)
            .bringUp(['api'], say: (_) {}, world: 'Pickup order'),
        throwsA(
          isA<WorldRefusal>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('There is no service "api"'),
              contains('`needs:` on its WorldScript'),
            ),
          ),
        ),
      );
      expect(DevStackForWorlds(core).nameOf('db'), 'The db');
      expect(DevStackForWorlds(core).nameOf('api'), 'api');
    });
  });
}

/// Dies on the spot, saying why, unless the scripted `db` has come up.
const _runsOnlyOnceDbIsUp =
    r'test -f "$MARKER" || { echo "nothing to connect to"; exit 1; }; '
    'exec sleep 60';
