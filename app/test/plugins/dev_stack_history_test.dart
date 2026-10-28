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
import 'package:flutterware_app/src/session/caller.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:flutterware_app/src/utils/terminal_environment.dart';
import 'package:path/path.dart' as p;

/// The history of starts and stops: what the person in the studio reads to see
/// what an agent did.
///
/// The file is real, because sharing it between processes is the point. Two
/// cores over one worktree and one run directory stand in for two processes —
/// the studio and an agent's MCP server.
void main() {
  late Directory runDir;
  late Directory project;
  late List<DevStackCore> cores;
  late List<String> ran;
  late Map<String, bool> up;
  late Map<String, String> failingUp;
  late Map<String, Completer<void>> slowUp;

  DevStackCore coreWith(StackService service) {
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
            config: DevStack(services: [service]).config,
          ),
        )..scriptProcess((command, {workingDirectory}) async {
          ran.add(command.join(' '));
          var [id, verb] = command;
          if (verb == 'status') {
            return ProcessResult(0, up[id]! ? 0 : 1, '', '');
          }
          if (slowUp[id] case var gate?) await gate.future;
          if (failingUp[id] case var said?) {
            return ProcessResult(0, 1, '', said);
          }
          up[id] = verb == 'up';
          return ProcessResult(0, 0, '', '');
        });
    cores.add(core);
    return core;
  }

  StackService scripted(String id) {
    up.putIfAbsent(id, () => false);
    return StackService.delegated(
      id,
      name: 'The $id',
      probe: Probe.exitCode(StackRun.command([id, 'status'])),
      start: StackRun.command([id, 'up']),
      stop: StackRun.command([id, 'down']),
    );
  }

  StackService owned(String script, {StackRun? start}) => StackService.owned(
    'server',
    name: 'The server',
    start: start ?? StackRun.command(['sh', '-c', script]),
    ready: const Ready.processAlive(),
    stopGrace: const Duration(seconds: 2),
    poll: const Duration(seconds: 30),
  );

  String historyPath() => stackHistoryPath(runDir.path, project.path);

  List<StackEvent> written() => FileStackHistory(historyPath).read();

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-history-run-');
    project = Directory.systemTemp.createTempSync('fw-history-project-');
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
    currentCaller = Caller.studio;
    debugTerminalEnvironment = null;
    DevStackCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, project]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('written down', () {
    test('a start and a stop, with who asked, newest first', () async {
      currentCaller = Caller.agent;
      var db = coreWith(scripted('db')).services.single;

      await db.start();
      await db.stop();

      var events = written();
      expect(
        [for (var e in events) (e.verb, e.outcome, e.by)],
        [
          ('stop', StackEventOutcome.down, 'agent'),
          ('start', StackEventOutcome.up, 'agent'),
        ],
      );
      expect(events.last.command, 'db up');
      expect(events.last.took, isNotNull);
      expect(eventHeadline(events.last), 'The db started');
      expect(eventCaller(events.last), 'An agent');
    });

    test('what a start brought up by ensure was for', () async {
      currentCaller = Caller.terminal;
      var core = coreWith(scripted('db'));

      await core.ensure(purpose: 'to open Pickup order');

      var start = written().single;
      expect(start.purpose, 'to open Pickup order');
      expect(eventCaller(start), 'fw, in a terminal, to open Pickup order');
      expect(
        StackEvent.fromJson(start.toJson()).purpose,
        'to open Pickup order',
      );
    });

    test('a start that failed, with why', () async {
      failingUp['db'] = 'port 5432 is already in use';
      var db = coreWith(scripted('db')).services.single;

      await db.start();

      var event = written().single;
      expect(event.outcome, StackEventOutcome.failed);
      expect(event.failure, 'Its start command exited with code 1.');
      expect(eventHeadline(event), 'The db did not start');
    });

    test('a start that was refused, with the refusal', () async {
      var server = coreWith(
        owned('', start: StackRun.tool('fw-definitely-not-a-real-binary')),
      ).services.single;

      await expectLater(server.start(), throwsA(isA<ActionRefusal>()));

      var event = written().single;
      expect(event.outcome, StackEventOutcome.refused);
      expect(event.failure, contains('fw-definitely-not-a-real-binary'));
    });

    test('not a second press while the first is still running', () async {
      // The second is refused for being a second, which is nothing that
      // happened to the service.
      var gate = slowUp['db'] = Completer<void>();
      var db = coreWith(scripted('db')).services.single;

      var first = db.start();
      await expectLater(db.start(), throwsA(isA<ActionRefusal>()));
      gate.complete();
      await first;

      expect(written(), hasLength(1));
    });
  });

  group('a process that went away', () {
    test('on its own is written once, by whoever notices', () async {
      var a = coreWith(owned('exec sleep 1')).services.single;
      var b = coreWith(owned('exec sleep 1')).services.single;

      await a.start();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await Future.wait([a.refresh(), b.refresh()]);

      var exits = [
        for (var e in written())
          if (e.verb == 'exit') e,
      ];
      expect(exits, hasLength(1));
      expect(exits.single.outcome, StackEventOutcome.exited);
      expect(exits.single.by, isNull);
      expect(eventCaller(exits.single), 'On its own');
    });

    test('while someone stops it is not taken for an exit', () async {
      // The gap this closes: the stopper's signal has landed and its handle
      // is not deleted yet when another process looks.
      var a = coreWith(owned('exec sleep 60')).services.single;
      var b = coreWith(owned('exec sleep 60')).services.single;
      await a.start();
      var file = runDir.listSync().whereType<File>().firstWhere(
        (f) =>
            p.basename(f.path).startsWith('svc-') && f.path.endsWith('.json'),
      );
      var handle = ServiceHandle.tryRead(file)!.markStopping();
      Process.killPid(handle.pid, ProcessSignal.sigkill);
      while (isProcessAlive(handle.pid)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      var reading = await b.refresh();

      expect(reading.state, StackState.down);
      expect([for (var e in written()) e.verb], isNot(contains('exit')));
    });
  });

  group('read back', () {
    test('by the studio, when another process writes it', () async {
      var core = coreWith(scripted('db'));
      core.watch();
      addTearDown(core.unwatch);
      expect(core.history, isEmpty);

      // What the MCP server's own core does, in its own process.
      FileStackHistory(historyPath).record(
        StackEvent(
          at: DateTime.now(),
          service: 'db',
          name: 'The db',
          verb: 'start',
          outcome: StackEventOutcome.up,
          by: 'agent',
        ),
      );
      var deadline = DateTime.now().add(const Duration(seconds: 5));
      while (core.history.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(core.history.single.by, 'agent');
    });

    test('by an agent, through the action and the status', () async {
      var core = coreWith(scripted('db'));
      await core.services.single.start();
      await core.services.single.stop();

      var result =
          (await core.invoke('history', arguments: {'limit': 1}))!
              as StackHistoryResult;
      expect(result.events.single.verb, 'stop');

      var view = jsonEncode(core.report.view.toJson());
      expect(view, contains('History'));
      expect(view, contains('The db started'));
    });
  });

  group('the file', () {
    test('skips a line cut short and reads the rest', () {
      var good = jsonEncode(
        StackEvent(
          at: DateTime(2026, 10, 27),
          service: 'db',
          name: 'The db',
          verb: 'start',
          outcome: StackEventOutcome.up,
        ).toJson(),
      );
      File(historyPath())
        ..createSync(recursive: true)
        ..writeAsStringSync('$good\n{"at": "2026-10-27T1\n$good\n');

      expect(written(), hasLength(2));
    });

    test('is trimmed to its last lines once it grows past the limit', () {
      var history = FileStackHistory(historyPath, keep: 3, trimAt: 1000);
      for (var i = 0; i < 20; i++) {
        history.record(
          StackEvent(
            at: DateTime(2026, 10, 27, 10, i),
            service: 'db',
            name: 'The db',
            verb: 'start',
            outcome: StackEventOutcome.up,
            detail: 'number $i',
          ),
        );
      }

      var events = history.read(limit: 100);
      expect(events.length, lessThan(20));
      expect(events.first.detail, 'number 19');
    });
  });
}
