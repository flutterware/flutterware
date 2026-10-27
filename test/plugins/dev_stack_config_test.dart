import 'package:flutterware/plugins.dart';
import 'package:test/test.dart';

/// The declaration half of the dev stack, on its own.
///
/// This is the surface a project's `tool/flutterware.dart` compiles against and
/// the JSON the GUI reads back, and neither of those needs a Flutter binding to
/// exercise. The app-side lifecycle lives in `app/test/plugins/`.
///
/// The shape under test is a **monorepo's**, because that is the one the pieces
/// were added for: several services of both kinds, a port no committed file can
/// know, an executable that is not ours to supply, and an environment value the
/// project computes. A config like this that stops round-tripping is a panel
/// that silently loses a service, which is the failure `UnreadableStackService`
/// exists to make loud.
void main() {
  ValueSource localEnv(List<String> args) =>
      ValueSource.script('packages/server/tool/local_env.dart', args: args);

  var stack = DevStack(
    services: [
      StackService.delegated(
        'stack',
        name: 'Local stack',
        workingDirectory: 'packages/server',
        probe: Probe.json(
          StackRun.script('tool/local_env.dart', args: ['status', '--json']),
        ),
        start: StackRun.script('tool/local_env.dart', args: ['up']),
        stop: StackRun.script('tool/local_env.dart', args: ['down']),
        stopIsDestructive: true,
        commands: [
          StackCommand(
            'logs',
            'Logs',
            StackRun.script('tool/local_env.dart', args: ['logs']),
            argument: 'service',
          ),
        ],
      ),
      StackService.owned(
        'server',
        name: 'API server',
        workingDirectory: 'packages/server',
        start: StackRun.script('bin/server_local.dart'),
        ready: Ready.httpFrom(
          localEnv(['port', 'server']),
          path: '/healthz',
          timeout: Duration(seconds: 60),
        ),
      ),
      StackService.owned(
        'worker',
        name: 'Queue worker',
        workingDirectory: 'packages/worker',
        start: StackRun.script('bin/worker_local.dart'),
        ready: Ready.processAlive(),
        env: {'FFMPEG_BIN': 'ffmpeg', 'CONVERT_BIN': 'convert'},
      ),
      StackService.owned(
        'ml',
        name: 'ML backend',
        workingDirectory: 'packages/ml_backend',
        start: StackRun.tool(
          'uv',
          args: ['run', '--', 'python', '-m', 'uvicorn', 'app:api'],
        ),
        ready: Ready.port(8099, timeout: Duration(minutes: 2)),
        envFrom: {
          'MODEL_TOOLS_DIR': ValueSource.script('tool/model_tools_dir.dart'),
        },
      ),
    ],
  );

  /// What the GUI does with what the config wrote.
  List<StackService> readBack() => StackService.listFromConfig(stack.config);

  group('a monorepo-shaped declaration', () {
    test('round-trips every service, in order and by kind', () {
      var read = readBack();
      expect([for (var s in read) s.id], ['stack', 'server', 'worker', 'ml']);
      expect(read[0], isA<DelegatedStackService>());
      expect(read.skip(1), everyElement(isA<OwnedStackService>()));
      // Nothing landed in the unreadable bucket, which is the assertion that
      // actually matters: a shape the reader cannot parse does not throw, it
      // becomes a row saying so.
      expect(read.whereType<UnreadableStackService>(), isEmpty);
    });

    test('a computed port survives as a source, not as a number', () {
      var server = readBack()[1] as OwnedStackService;
      var ready = server.ready as HttpReady;
      expect(ready.port, isNull, reason: 'nothing may invent one');
      expect(ready.path, '/healthz');
      expect(ready.timeout, const Duration(seconds: 60));
      var from = ready.from! as ScriptSource;
      expect(from.path, 'packages/server/tool/local_env.dart');
      expect(from.args, ['port', 'server']);
    });

    test('a written-down port survives as a number', () {
      var ml = readBack()[3] as OwnedStackService;
      expect((ml.ready as PortReady).port, 8099);
      expect((ml.ready as PortReady).from, isNull);
    });

    test('an executable to look up is not confused with a command', () {
      var ml = readBack()[3] as OwnedStackService;
      var start = ml.start as ToolRun;
      expect(start.name, 'uv');
      expect(start.args.first, 'run');
    });

    test('both kinds of environment come back apart', () {
      var worker = readBack()[2] as OwnedStackService;
      expect(worker.env, {'FFMPEG_BIN': 'ffmpeg', 'CONVERT_BIN': 'convert'});
      expect(worker.envFrom, isEmpty);

      var ml = readBack()[3] as OwnedStackService;
      expect(ml.env, isEmpty);
      expect(
        (ml.envFrom['MODEL_TOOLS_DIR']! as ScriptSource).path,
        'tool/model_tools_dir.dart',
      );
    });

    test('a delegated service keeps its meaning beside owned ones', () {
      var local = readBack().first as DelegatedStackService;
      expect(local.stopIsDestructive, isTrue);
      expect(local.probe.shape, ProbeShape.json);
      expect(local.commands.single.argument, 'service');
      // The default it never declared, so a project that says nothing about
      // polling still gets the delegated timescale rather than the owned one.
      expect(local.poll, const Duration(seconds: 10));
      expect(
        (readBack()[1] as OwnedStackService).poll,
        const Duration(seconds: 3),
      );
    });
  });
}
