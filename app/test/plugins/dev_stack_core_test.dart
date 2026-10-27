import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_core.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:path/path.dart' as p;

/// The core against a scripted `runProcess`, which is the seam that keeps this
/// from needing docker. What is asserted is what `fw`, an agent and the sidebar
/// all read — [PluginReport] and `invoke` — because the panel draws the same
/// core and a test against the widget would only be testing the widget.
void main() {
  late Directory runDir;
  late Directory project;
  late List<List<String>> ran;
  late Map<String, ProcessResult> responses;

  /// The next result for a command, keyed by its first two words so a test can
  /// script `up` and `doctor` differently.
  ProcessResult resultFor(List<String> command) =>
      responses[command.take(2).join(' ')] ?? ProcessResult(0, 0, '', '');

  /// Every core gets the same scripted process, set per instance.
  DevStackCore coreWith(Map<String, Object?> config) =>
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
            flutterSdk: FlutterSdkPath('/tmp/flutter'),
          ),
          config: config,
        ),
      )..scriptProcess((command, {workingDirectory}) async {
        ran.add([
          ...command,
          if (workingDirectory != null) '@$workingDirectory',
        ]);
        return resultFor(command);
      });

  /// A stack delegated to a project's own CLI, as `DevStack.background(...)`
  /// emits it.
  Map<String, Object?> localEnvConfig() => DevStack.background(
    workingDirectory: 'packages/server',
    probe: Probe.exitCode(StackRun.command(['stack', 'doctor'])),
    start: StackRun.command(['stack', 'up']),
    stop: StackRun.command(['stack', 'down']),
    stopIsDestructive: true,
    commands: [
      StackCommand('logs', 'Logs', StackRun.command(['stack', 'logs'])),
      StackCommand(
        'restart',
        'Restart',
        StackRun.command(['stack', 'restart']),
        argument: 'service',
      ),
    ],
  ).config;

  /// [localEnvConfig] with the single service's `probe` replaced, or removed
  /// when [probe] is null — the two shapes a build that cannot read the
  /// declaration sees.
  Map<String, Object?> configWithProbe(Object? probe) {
    var config = localEnvConfig();
    var service = {
      ...(config['services']! as List).cast<Map<String, Object?>>().single,
    };
    if (probe == null) {
      service.remove('probe');
    } else {
      service['probe'] = probe;
    }
    return {
      ...config,
      'services': [service],
    };
  }

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-stack-run-');
    project = Directory.systemTemp.createTempSync('fw-stack-project-');
    ran = [];
    responses = {};
    DevStackCore.runDirProvider = () => runDir.path;
  });

  tearDown(() {
    DevStackCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, project]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('the config a project writes', () {
    test('survives the trip through the manifest', () {
      var core = coreWith(localEnvConfig());
      expect(core.service.declaredProbeCommand, 'stack doctor');
      expect(core.service.declaredDirectory, 'packages/server');
      expect(core.service.stopIsDestructive, isTrue);
      expect(core.service.canControl, isTrue);
      expect([for (var c in core.service.commands) c.id], ['logs', 'restart']);
      expect(core.service.pollInterval, const Duration(seconds: 10));
      core.dispose();
    });

    test('resolves the working directory against the worktree', () {
      var core = coreWith(localEnvConfig());
      expect(core.service.workingDirectory, '${project.path}/packages/server');
      core.dispose();
    });
  });

  group('computeAll', () {
    test('spawns nothing — the budget is a file read', () async {
      var core = coreWith(localEnvConfig());
      await core.computeAll();
      expect(ran, isEmpty);
      // And says nothing about it: unknown is silence, not "not checked".
      expect(core.report.status, Status.none);
      core.dispose();
    });

    /// Loading never probes and only the studio polls, so on a worktree
    /// nothing has probed `fw status` and the MCP server answered
    /// `State: unknown / Checked: never` indefinitely, with no way forward in
    /// the answer.
    test('a reading nobody has taken says how to take one', () async {
      var core = coreWith(localEnvConfig());
      await core.computeAll();
      expect(ran, isEmpty);
      var text = core.report.view.toText();
      expect(text, contains('State: unknown'));
      expect(text, contains('Run `fw run dev_stack status` to check it'));

      responses['stack doctor'] = ProcessResult(0, 0, 'All checks passed.', '');
      await core.invoke('status');
      expect(
        core.report.view.toText(),
        isNot(contains('fw run dev_stack status')),
        reason: 'once there is a reading, the hint is noise',
      );
      core.dispose();
    });

    test('reads back what a previous probe cached', () async {
      var first = coreWith(localEnvConfig());
      responses['stack doctor'] = ProcessResult(0, 0, 'All checks passed.', '');
      await first.service.refresh();
      first.dispose();

      var second = coreWith(localEnvConfig());
      await second.computeAll();
      expect(second.service.reading.state, StackState.up);
      expect(second.service.reading.detail, 'All checks passed.');
      // The point of the cache: a cold read says something true and spawns
      // nothing to do it.
      expect(ran.length, 1);
      second.dispose();
    });
  });

  group('a probe the core does not hold', () {
    test('the refusal is not written into the shared cache', () async {
      var blind = coreWith(configWithProbe(null));
      // It never becomes a lifecycle at all, which is what makes this
      // structural rather than a flag somebody has to remember to set: a
      // service with nothing to probe has no reading to write, so the cache
      // file — shared by every process on the worktree — cannot be poisoned
      // by a build that could not read the declaration.
      expect(blind.services, isEmpty);
      expect(blind.unreadable.single.reason, contains('No probe is declared'));
      blind.dispose();

      var sighted = coreWith(localEnvConfig());
      await sighted.computeAll();
      expect(sighted.service.reading.state, StackState.unknown);
      sighted.dispose();
    });

    test('a declared probe this build cannot read is named as such', () async {
      var core = coreWith(
        configWithProbe({
          'run': {'exec': 'a-shape-from-the-future'},
          'shape': 'exitCode',
        }),
      );
      expect(core.services, isEmpty);
      // Not "no probe is declared": one *is*, and the sentence saying
      // otherwise about a working config was the consumer-reported symptom.
      expect(
        core.unreadable.single.reason,
        contains('flutterware cannot read'),
      );
      // Still on the panel, named, with the reason — the row is the only
      // thing that says a service was declared at all.
      expect(core.report.status.tone, Tone.error);
      expect(core.report.view.toString(), contains('flutterware cannot read'));
      core.dispose();
    });

    test('a kind this build does not know is named too', () {
      var core = coreWith({
        'services': [
          {'id': 'mesh', 'kind': 'sidecar', 'name': 'Service mesh'},
        ],
      });
      expect(core.services, isEmpty);
      expect(core.unreadable.single.reason, contains('service kind "sidecar"'));
      core.dispose();
    });

    test('an owned service with nothing to run is named too', () {
      var core = coreWith({
        'services': [
          {'id': 'server', 'kind': 'owned', 'name': 'API server'},
        ],
      });
      expect(core.services, isEmpty);
      // Its own sentence, not the delegated one: the missing field is
      // different and so is the fix.
      expect(
        core.unreadable.single.reason,
        contains('No start command is declared'),
      );
      core.dispose();
    });

    test('an owned service whose readiness will not read is named too', () {
      var core = coreWith({
        'services': [
          {
            'id': 'server',
            'kind': 'owned',
            'start': {
              'command': ['sleep', '30'],
            },
            'ready': {'ready': 'logLine', 'pattern': 'listening on'},
          },
        ],
      });
      // **Not ready, and not silently ready either.** A check this build
      // cannot read has to make the whole service unreadable: adopting the
      // service and dropping the check would render "we could not read how to
      // tell" as "it is up".
      expect(core.services, isEmpty);
      expect(
        core.unreadable.single.reason,
        contains('flutterware cannot read'),
      );
      core.dispose();
    });
  });

  group('the exit-code probe', () {
    test('zero is up, and the last line becomes the detail', () async {
      var core = coreWith(localEnvConfig());
      responses['stack doctor'] = ProcessResult(
        0,
        0,
        'Doctor for the dev stack\n  docker … OK\nAll checks passed.',
        '',
      );
      var reading = await core.service.refresh();
      expect(reading.state, StackState.up);
      expect(reading.detail, 'All checks passed.');
      expect(core.report.status.tone, Tone.good);
      core.dispose();
    });

    test('non-zero is down', () async {
      var core = coreWith(localEnvConfig());
      responses['stack doctor'] = ProcessResult(0, 1, '2 check(s) failed.', '');
      expect((await core.service.refresh()).state, StackState.down);
      expect(core.report.status.message, 'down');
      core.dispose();
    });

    test(
      'strips the colour codes a health check writes for a terminal',
      () async {
        var core = coreWith(localEnvConfig());
        responses['stack doctor'] = ProcessResult(
          0,
          0,
          '\x1B[32mAll checks passed.\x1B[0m',
          '',
        );
        expect((await core.service.refresh()).detail, 'All checks passed.');
        core.dispose();
      },
    );

    test('a command that cannot be spawned is unavailable, not down', () async {
      var core = coreWith(localEnvConfig())
        ..scriptProcess(
          (command, {workingDirectory}) async =>
              throw const ProcessException('stack', [], 'No such file'),
        );
      var reading = await core.service.refresh();
      // The distinction the five-state design exists for: a probe that could
      // not run says nothing about whether the stack is up.
      expect(reading.state, StackState.unavailable);
      expect(reading.failure, contains('No such file'));
      expect(core.report.status.tone, Tone.error);
      core.dispose();
    });
  });

  group('the JSON probe', () {
    Map<String, Object?> jsonConfig() => DevStack.background(
      probe: Probe.json(StackRun.command(['stack', 'doctor'])),
      start: StackRun.command(['stack', 'up']),
      stop: StackRun.command(['stack', 'down']),
    ).config;

    test('carries services and their ports through', () async {
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(0, 0, '''
        {"state":"up","detail":"slot 8200-8208",
         "services":[{"name":"postgres","port":8200,"state":"up"},
                     {"name":"identity","port":8201,"state":"starting"}]}
      ''', '');
      var reading = await core.service.refresh();
      expect(reading.state, StackState.up);
      expect(reading.detail, 'slot 8200-8208');
      expect(reading.services.map((s) => s.name), ['postgres', 'identity']);
      expect(reading.services.first.port, 8200);
      expect(reading.services.last.state, StackState.starting);
      core.dispose();
    });

    test('a stack that is up but not all of it says so', () async {
      // The summary is derived from the rows rather than written beside them,
      // which is the only arrangement in which a green headline cannot end up
      // sitting above an amber service. The probe here says `up`; three of its
      // four services agree.
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(0, 0, '''
        {"state":"up",
         "services":[{"name":"postgres","port":8200,"state":"up"},
                     {"name":"identity","port":8201,"state":"up"},
                     {"name":"sync","port":8202,"state":"starting"},
                     {"name":"mail","port":8203,"state":"up"}]}
      ''', '');
      var reading = await core.service.refresh();
      expect(reading.state, StackState.up);
      expect(reading.isPartial, isTrue);
      expect(reading.serviceCount, (3, 4));
      expect(core.report.status.message, 'up 3/4');
      expect(core.report.status.tone, Tone.warn);
      core.dispose();
    });

    test('an unavailable state takes its detail as the reason', () async {
      // Caught on screen: the example project's script writes one explanatory
      // line and puts it in `detail`, like every other line it writes, and the
      // panel rendered "the check could not be run" over a probe that had said
      // exactly what was wrong. Two keys for one sentence is a distinction a
      // script author has no reason to make.
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(
        0,
        0,
        '{"state":"unavailable","detail":"Something else is on :8080."}',
        '',
      );
      var reading = await core.service.refresh();
      expect(reading.state, StackState.unavailable);
      expect(reading.failure, 'Something else is on :8080.');
      core.dispose();
    });

    test('a probe that names no service state counts nothing', () async {
      // A service list with no states is a list of names, and counting the ones
      // that are not `up` against it would report every such stack as 0 of N.
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(0, 0, '''
        {"state":"up","services":[{"name":"postgres"},{"name":"identity"}]}
      ''', '');
      var reading = await core.service.refresh();
      expect(reading.serviceCount, isNull);
      expect(reading.isPartial, isFalse);
      expect(core.report.status.message, 'up');
      core.dispose();
    });

    test('ignores whatever the command wrote to stderr', () async {
      // Found by pointing the example project's declaration at a Dart script:
      // `dart` announces `Running build hooks...` on stderr, and folding that
      // in made every probe unparseable. Almost nothing that prints structured
      // output has stderr to itself — docker writes deprecation warnings there,
      // a wrapper's `set -x` writes every line it runs — so a probe that reads
      // both is one that works until a tool starts mentioning something.
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(
        0,
        0,
        '{"state":"up","detail":"4 containers"}',
        'Running build hooks...\nnote: using cached layer',
      );
      var reading = await core.service.refresh();
      expect(reading.state, StackState.up);
      expect(reading.detail, '4 containers');
      core.dispose();
    });

    test("keeps the command's own words when it did not print JSON", () async {
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(
        0,
        1,
        '',
        'Cannot connect to the Docker daemon.',
      );
      var reading = await core.service.refresh();
      expect(reading.state, StackState.unavailable);
      // Not "printed something that is not JSON": that buries the sentence
      // explaining the problem under a complaint about the format.
      expect(reading.failure, 'Cannot connect to the Docker daemon.');
      core.dispose();
    });

    test('reports unavailable when it cannot say what it is up to', () async {
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(0, 0, 'not json at all', '');
      var reading = await core.service.refresh();
      expect(reading.state, StackState.unavailable);
      // Quoted rather than paraphrased — whatever it said is more use than a
      // complaint about the format.
      expect(reading.failure, 'not json at all');
      core.dispose();
    });

    test('falls back to naming the format when it said nothing', () async {
      var core = coreWith(jsonConfig());
      responses['stack doctor'] = ProcessResult(0, 1, '', '');
      var reading = await core.service.refresh();
      expect(reading.state, StackState.unavailable);
      expect(reading.failure, contains('not JSON'));
      core.dispose();
    });
  });

  group('start and stop', () {
    test('run the declared command and re-probe', () async {
      var core = coreWith(localEnvConfig());
      responses['stack doctor'] = ProcessResult(0, 0, 'All checks passed.', '');
      var result = await core.service.start();
      expect(result.ok, isTrue);
      expect(result.command, 'stack up');
      // Up, then the probe — the caller asked whether it came up, not whether
      // the command exited.
      expect(ran.map((c) => c.take(2).join(' ')), ['stack up', 'stack doctor']);
      expect(result.reading!.state, StackState.up);
      core.dispose();
    });

    test('run in the declared working directory', () async {
      var core = coreWith(localEnvConfig());
      await core.service.start();
      expect(ran.first.last, '@${project.path}/packages/server');
      core.dispose();
    });

    test('refuse to overlap', () async {
      var core = coreWith(localEnvConfig());
      var completer = Completer<ProcessResult>();
      core.service.runProcess = (command, {workingDirectory}) =>
          completer.future;
      var first = core.service.start();
      expect(core.service.busy, 'start');
      await expectLater(core.service.stop(), throwsA(isA<ActionRefusal>()));
      completer.complete(ProcessResult(0, 0, '', ''));
      await first;
      expect(core.service.busy, isNull);
      core.dispose();
    });

    test('a transition wins over the last reading while it is in flight', () async {
      var core = coreWith(localEnvConfig());
      var completer = Completer<ProcessResult>();
      core.service.runProcess = (command, {workingDirectory}) =>
          completer.future;
      var pending = core.service.start();
      // The probe cannot see a compose project that has not finished coming up,
      // so the status must not fall back to what it last said.
      expect(core.report.status.message, 'bringing up');
      completer.complete(ProcessResult(0, 0, '', ''));
      await pending;
      core.dispose();
    });

    test('a transition is clocked, so a second surface agrees', () async {
      // The elapsed number lives on the core rather than on the widget: opening
      // the panel eight seconds into a bring-up has to show eight seconds, not
      // start counting again. It is also the only progress a delegated command
      // can honestly report — nothing here knows what the project's script is
      // doing, only how long it has been doing it.
      var core = coreWith(localEnvConfig());
      var completer = Completer<ProcessResult>();
      core.service.runProcess = (command, {workingDirectory}) =>
          completer.future;
      expect(core.service.busyFor, isNull);
      var pending = core.service.start();
      expect(core.service.busyFor, isNotNull);
      expect(core.service.busyFor!.inSeconds, lessThan(2));
      completer.complete(ProcessResult(0, 0, '', ''));
      await pending;
      expect(core.service.busyFor, isNull);
      core.dispose();
    });

    test(
      'a stack with no start declared says so rather than doing nothing',
      () async {
        var core = coreWith(
          DevStack.background(
            probe: Probe.exitCode(StackRun.command(['check'])),
          ).config,
        );
        expect(core.service.canControl, isFalse);
        await expectLater(core.service.start(), throwsA(isA<ActionRefusal>()));
        expect([for (var a in core.report.actions) a.id], ['status']);
        core.dispose();
      },
    );
  });

  group('actions', () {
    test('are what fw and an agent see, with stop marked destructive', () {
      var core = coreWith(localEnvConfig());
      var actions = {for (var a in core.report.actions) a.id: a};
      expect(actions.keys, [
        'ensure',
        'history',
        'status',
        'start',
        'stop',
        'logs',
        'restart',
      ]);
      expect(actions['stop']!.danger, isTrue);
      expect(actions['stop']!.confirm, isTrue);
      expect(actions['start']!.danger, isFalse);
      // A command with an argument declares it, so `fw run … --service=x` and a
      // GUI form are the same declaration.
      expect(actions['restart']!.parameters.single.id, 'service');
      expect(actions['logs']!.parameters, isEmpty);
      core.dispose();
    });

    test('invoke routes a declared command and appends its argument', () async {
      var core = coreWith(localEnvConfig());
      var result =
          (await core.invoke('restart', arguments: {'service': 'sync'}))!
              as DevStackRunResult;
      expect(result.command, 'stack restart sync');
      core.dispose();
    });

    test('an unknown action names what is declared', () async {
      var core = coreWith(localEnvConfig());
      await expectLater(
        core.invoke('nope'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('status, start, stop, logs, restart'),
          ),
        ),
      );
      core.dispose();
    });
  });

  group('teardown', () {
    test('offers a step only when there is something to tear down', () async {
      var core = coreWith(localEnvConfig());
      responses['stack doctor'] = ProcessResult(0, 1, 'down', '');
      await core.service.refresh();
      expect(core.report.teardown, isEmpty);

      responses['stack doctor'] = ProcessResult(0, 0, '4 containers', '');
      await core.service.refresh();
      var step = core.report.teardown.single;
      expect(step.id, 'stop');
      expect(step.phase, TeardownPhase.infra);
      expect(step.checked, isTrue);
      expect(step.danger, isTrue);
      // The detail is what makes the checkbox decidable.
      expect(step.detail, '4 containers · destroys the database');
      core.dispose();
    });

    test('a stack with no stop never offers one', () async {
      var core = coreWith(
        DevStack.background(probe: Probe.exitCode(StackRun.command(['check'])))
            .config,
      );
      await core.service.refresh();
      expect(core.report.teardown, isEmpty);
      core.dispose();
    });
  });

  group('watching', () {
    test('polls only while something is watching', () async {
      var core = coreWith(
        DevStack.background(
          probe: Probe.exitCode(StackRun.command(['check'])),
          poll: const Duration(milliseconds: 30),
        ).config,
      );
      expect(core.isWatching, isFalse);

      core.watch();
      expect(core.isWatching, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      var whileWatching = ran.length;
      expect(whileWatching, greaterThan(1));

      core.unwatch();
      expect(core.isWatching, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(ran.length, whileWatching);
      core.dispose();
    });

    test(
      'two surfaces share one poll, and the second release stops it',
      () async {
        var core = coreWith(
          DevStack.background(
            probe: Probe.exitCode(StackRun.command(['check'])),
            poll: const Duration(milliseconds: 30),
          ).config,
        );
        // The home screen and the panel can be mounted across one navigation;
        // the first unwatch must not stop the surface still showing.
        core.watch();
        core.watch();
        core.unwatch();
        expect(core.isWatching, isTrue);
        core.unwatch();
        expect(core.isWatching, isFalse);
        core.dispose();
      },
    );
  });

  group('a script, rather than a command naming an interpreter', () {
    /// The stack behind a project's own Dart CLI — the shape a config used to
    /// have to write as `[Platform.resolvedExecutable, 'tool/local_env.dart', …]`,
    /// or worse as `['fvm', 'dart', 'run', …]`.
    Map<String, Object?> scriptConfig({Duration? poll}) => DevStack.background(
      workingDirectory: 'packages/server',
      probe: Probe.json(
        StackRun.script('tool/local_env.dart', args: ['status', '--json']),
      ),
      start: StackRun.script('tool/local_env.dart', args: ['up']),
      poll: poll ?? const Duration(seconds: 10),
      commands: [
        StackCommand(
          'logs',
          'Logs',
          StackRun.script('tool/local_env.dart', args: ['logs']),
        ),
      ],
    ).config;

    void writeScript() =>
        File(
            p.join(
              project.path,
              'packages',
              'server',
              'tool',
              'local_env.dart',
            ),
          )
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('void main() {}');

    test('is spawned with the SDK flutterware is running under', () async {
      // The whole point: the config named a file, and the interpreter came from
      // the tool. `/tmp/flutter` is what this harness declares as the SDK.
      writeScript();
      var core = coreWith(scriptConfig());
      responses['/tmp/flutter/bin/dart tool/local_env.dart'] = ProcessResult(
        0,
        0,
        '{"state": "up"}',
        '',
      );

      await core.service.refresh();

      expect(ran.single, [
        '/tmp/flutter/bin/dart',
        'tool/local_env.dart',
        'status',
        '--json',
        // Spawned in the declared directory, which is what makes the relative
        // script path mean what a person typing it would mean.
        '@${p.join(project.path, 'packages/server')}',
      ]);
      expect(core.service.reading.state, StackState.up);
      core.dispose();
    });

    test('is spawned without `run`, so no build hook fires', () async {
      // `dart run` re-resolves the graph and runs every build hook in it, on
      // every poll — 4.4s of it in a workspace with native assets. The direct
      // form is the whole reason a probe can be left polling.
      writeScript();
      var core = coreWith(scriptConfig());

      await core.service.refresh();

      expect(ran.single, isNot(contains('run')));
      core.dispose();
    });

    test('its start and its commands are run with `run`', () async {
      // Run once, not on a timer, so the hooks cost nothing worth saving — and
      // `run` is what builds the native assets a server may need.
      writeScript();
      var core = coreWith(scriptConfig());

      await core.service.start();
      await core.service.runCommand('logs');

      var withRun = [
        for (var command in ran)
          if (command.contains('run')) command[3],
      ];
      expect(withRun, ['up', 'logs']);
      expect(ran.first.take(3), [
        '/tmp/flutter/bin/dart',
        'run',
        'tool/local_env.dart',
      ]);
      core.dispose();
    });

    test('is described without the interpreter path', () {
      // 80 characters of `~/fvm/versions/…` answer a question nobody reading a
      // panel is asking.
      var core = coreWith(scriptConfig());
      expect(
        core.service.declaredProbeCommand,
        'dart tool/local_env.dart status --json',
      );
      core.dispose();
    });

    test('one that is not there is reported, and nothing is spawned', () async {
      // A missing file comes back from the VM as a page of compiler output with
      // the useful sentence buried in it. This is the sentence.
      var core = coreWith(scriptConfig());

      var reading = await core.service.refresh();

      expect(reading.state, StackState.unavailable);
      expect(reading.failure, contains('tool/local_env.dart does not exist'));
      expect(ran, isEmpty);
      core.dispose();
    });
  });

  group('a config written against an older flutterware', () {
    test('still reads, because a bare list is still a command', () {
      // `start`, `stop` and a command were bare argv before `StackRun` existed,
      // and the config imports the version the *project* pins — which can sit
      // behind the GUI reading its manifest. A probe that stops being read is a
      // panel that stops knowing anything.
      var core = coreWith({
        'probe': {
          'command': ['stack', 'doctor'],
          'shape': 'exitCode',
        },
        'start': ['stack', 'up'],
        'stop': ['stack', 'down'],
        'commands': [
          {
            'id': 'logs',
            'label': 'Logs',
            'command': ['stack', 'logs'],
          },
        ],
      });

      expect(core.service.declaredProbeCommand, 'stack doctor');
      expect(core.service.canStart, isTrue);
      expect(core.service.canStop, isTrue);
      expect([for (var c in core.service.commands) c.id], ['logs']);
      core.dispose();
    });
  });

  group('the interval a slow probe earns', () {
    test('a fast probe leaves the declaration alone', () async {
      // The common case, and it must stay free of any adjustment.
      var core = coreWith(
        DevStack.background(probe: Probe.exitCode(StackRun.command(['check'])))
            .config,
      );

      await core.service.refresh();

      expect(core.service.effectivePoll, const Duration(seconds: 10));
      core.dispose();
    });

    test('a slow one pushes the interval to four times its duration', () async {
      // A 4.6s probe on a 10s poll is a permanently busy core, and the project's
      // only recourse was to write a bigger number into `poll:` and explain the
      // tool's cost model in a comment.
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
              poll: const Duration(milliseconds: 10),
            ).config,
          )..scriptProcess((command, {workingDirectory}) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return ProcessResult(0, 0, '', '');
          });

      await core.service.refresh();

      expect(
        core.service.effectivePoll.inMilliseconds,
        greaterThanOrEqualTo(400),
        reason: 'a probe may not occupy more than a quarter of its interval',
      );
      core.dispose();
    });

    test('a second caller joins the probe in flight', () async {
      // The poll timer used to fire regardless, so two subprocesses raced to
      // write the reading and the panel showed whichever finished last.
      var completer = Completer<ProcessResult>();
      var spawns = 0;
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
            ).config,
          )..scriptProcess((command, {workingDirectory}) {
            spawns++;
            return completer.future;
          });

      var first = core.service.refresh();
      var second = core.service.refresh();
      // The same future, which is what "joins" means — the second caller gets
      // the look in flight rather than one of its own. Asserted on the future
      // rather than on the spawn count alone, because the spawn is now a turn
      // away: an argv can need resolving before there is anything to run.
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(spawns, 1);

      completer.complete(ProcessResult(0, 0, '', ''));
      expect((await first).state, StackState.up);
      // The joined caller gets that same look, not the cache it was refreshing.
      expect((await second).state, StackState.up);
      core.dispose();
    });

    test('a probe that never answers becomes an answer', () async {
      // With the in-flight guard, a hung probe would otherwise hand every later
      // caller the same dead future and the panel would sit on one reading for
      // the rest of the session.
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
            ).config,
          )..scriptProcess(
            (command, {workingDirectory}) => Completer<ProcessResult>().future,
          );
      core.service.probeTimeout = const Duration(milliseconds: 20);

      var reading = await core.service.refresh();

      expect(reading.state, StackState.unavailable);
      expect(reading.failure, contains('did not answer'));
      // And the guard is clear, so the next poll is not blocked by the dead one.
      expect(core.service.isProbing, isFalse);
      core.dispose();
    });
  });

  group('a command that does not come back', () {
    /// The wedge, which is the bug and not the hang. `_busy` is what makes
    /// the next transition refuse, so a command that never returns did not fail
    /// on its own — it took every later `start`, `stop` and command with it for
    /// the rest of the session. `logs --follow` declared as an ordinary command
    /// is exactly this shape.
    test('releases the stack instead of holding it forever', () async {
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
              start: StackRun.command(['up']),
              commandTimeout: const Duration(milliseconds: 20),
              commands: [
                StackCommand('logs', 'Logs', StackRun.command(['logs'])),
              ],
            ).config,
          )..scriptProcess(
            (command, {workingDirectory}) => command.first == 'logs'
                ? Completer<ProcessResult>().future
                : Future.value(ProcessResult(0, 0, 'ok', '')),
          );

      var result = await core.service.runCommand('logs');

      expect(result.timedOut, isTrue);
      expect(result.exitCode, isNull, reason: '0 would say it worked');
      expect(result.ok, isFalse);
      expect(result.stderr, contains('the command is still running'));
      expect(
        core.service.busy,
        isNull,
        reason: 'the claim on the stack is what has to end',
      );

      // The whole point: the next command is not refused by the dead one.
      var after = await core.service.start();
      expect(after.ok, isTrue);
      core.dispose();
    });

    test('a StackCommand timeout beats the stack default', () async {
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
              commandTimeout: const Duration(seconds: 30),
              commands: [
                StackCommand(
                  'logs',
                  'Logs',
                  StackRun.command(['logs']),
                  timeout: const Duration(milliseconds: 20),
                ),
              ],
            ).config,
          )..scriptProcess(
            (command, {workingDirectory}) => Completer<ProcessResult>().future,
          );

      // Resolves at all, rather than waiting the stack's 30s.
      var result = await core.service.runCommand('logs');
      expect(result.timedOut, isTrue);
      expect(result.stderr, contains('0s'));
      core.dispose();
    });
  });

  group('stdout and stderr', () {
    test('are reported apart as well as combined', () async {
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
              start: StackRun.command(['up']),
            ).config,
          )..scriptProcess(
            (command, {workingDirectory}) => Future.value(
              ProcessResult(
                0,
                0,
                'started 4 containers',
                'Pulling postgres:16...',
              ),
            ),
          );

      var result = await core.service.start();

      expect(result.stdout, 'started 4 containers');
      expect(
        result.stderr,
        'Pulling postgres:16...',
        reason: 'the half a renderer wants to put somewhere else',
      );
      expect(
        result.output,
        'started 4 containers\nPulling postgres:16...',
        reason: 'and the merged order is still what the panel draws',
      );
      expect(result.toJson()['stdout'], 'started 4 containers');
      core.dispose();
    });

    test('what `dart run` says about itself stays out of the output', () async {
      // A script's start is `dart run` now, and the CLI's progress arrives on
      // stderr with no newline — in front of whatever the script said.
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
              start: StackRun.command(['up']),
            ).config,
          )..scriptProcess(
            (command, {workingDirectory}) => Future.value(
              ProcessResult(
                0,
                0,
                'listening on 8080',
                'Running build hooks...Running build hooks...slot 3 in use',
              ),
            ),
          );

      var result = await core.service.start();

      expect(result.output, 'listening on 8080\nslot 3 in use');
      core.dispose();
    });

    test('a one-stream command does not carry its output twice', () async {
      var core =
          coreWith(
            DevStack.background(
              probe: Probe.exitCode(StackRun.command(['check'])),
              start: StackRun.command(['up']),
            ).config,
          )..scriptProcess(
            (command, {workingDirectory}) =>
                Future.value(ProcessResult(0, 0, 'quiet success', '')),
          );

      var json = (await core.service.start()).toJson();
      expect(json['output'], 'quiet success');
      expect(json.containsKey('stdout'), isFalse);
      expect(json.containsKey('stderr'), isFalse);
      core.dispose();
    });
  });

  group('several services', () {
    /// A stack and a server, which is the shape the plugin was pluralised for.
    Map<String, Object?> twoServices() => DevStack(
      services: [
        StackService.delegated(
          'stack',
          name: 'Local stack',
          probe: Probe.exitCode(StackRun.command(['stack', 'doctor'])),
          start: StackRun.command(['stack', 'up']),
          stop: StackRun.command(['stack', 'down']),
          commands: [
            StackCommand('logs', 'Logs', StackRun.command(['stack', 'logs'])),
          ],
        ),
        StackService.delegated(
          'server',
          name: 'API server',
          probe: Probe.exitCode(StackRun.command(['server', 'health'])),
          start: StackRun.command(['server', 'up']),
          commands: [
            StackCommand('logs', 'Logs', StackRun.command(['server', 'logs'])),
          ],
        ),
      ],
    ).config;

    test('a reading nobody has taken names the action that takes it', () async {
      var core = coreWith(twoServices());
      await core.computeAll();
      var text = core.report.view.toText();
      // The hint is only worth reading if the action it names exists, and
      // with two services the bare `status` does not.
      expect(text, contains('Run `fw run dev_stack stack.status` to check it'));
      expect(
        text,
        contains('Run `fw run dev_stack server.status` to check it'),
      );
      expect(text, isNot(contains('`fw run dev_stack status`')));
      core.dispose();
    });

    test('every action names the service it acts on', () {
      var core = coreWith(twoServices());
      expect(
        [for (var a in core.report.actions) a.id],
        [
          // The stack's own, so not prefixed: they span the services.
          'ensure',
          'history',
          'stack.status',
          'stack.start',
          'stack.stop',
          'stack.logs',
          'server.status',
          'server.start',
          'server.logs',
        ],
        reason:
            'the service is in the id, not in an argument — both configs in '
            'evidence declare a command whose own argument is called `service`',
      );
      // And `server` has no `stop`, so it is not offered one.
      expect([
        for (var a in core.report.actions) a.id,
      ], isNot(contains('server.stop')));
      core.dispose();
    });

    test('one service keeps the bare ids it always had', () {
      var core = coreWith(localEnvConfig());
      expect(
        [for (var a in core.report.actions) a.id],
        ['ensure', 'history', 'status', 'start', 'stop', 'logs', 'restart'],
      );
      core.dispose();
    });

    test('an unreadable service still forces the prefix', () {
      // Otherwise fixing the unreadable one — which is what the panel tells
      // you to do — would silently rename every action the other one offers.
      var config = twoServices();
      var services = (config['services']! as List).cast<Map<String, Object?>>();
      var core = coreWith({
        'services': [
          services.first,
          {'id': 'server', 'kind': 'from-the-future'},
        ],
      });
      expect(core.services.single.id, 'stack');
      expect([
        for (var a in core.report.actions) a.id,
      ], contains('stack.status'));
      core.dispose();
    });

    test('invoke reaches the service the id names', () async {
      var core = coreWith(twoServices());
      await core.invoke('server.start');
      // `start` re-probes when it returns, and it probes *that* service.
      expect(
        [for (var command in ran) command.take(2).join(' ')],
        ['server up', 'server health'],
      );

      ran.clear();
      await core.invoke('stack.logs');
      expect(ran.single.take(2), ['stack', 'logs']);

      ran.clear();
      await expectLater(
        core.invoke('server.recreate'),
        throwsA(isA<ArgumentError>()),
      );
      expect(ran, isEmpty);
      core.dispose();
    });

    test('the sidebar counts services the way it counts containers', () async {
      var core = coreWith(twoServices());
      responses['stack doctor'] = ProcessResult(0, 0, '', '');
      responses['server health'] = ProcessResult(0, 1, '', '');
      await core.refreshAll();
      expect(core.report.status.message, 'up 1/2');
      expect(core.report.status.tone, Tone.warn);

      responses['server health'] = ProcessResult(0, 0, '', '');
      await core.refreshAll();
      expect(core.report.status.message, 'up');
      expect(core.report.status.tone, Tone.good);
      core.dispose();
    });

    test('each service is a sidebar child, and one service is none', () async {
      var core = coreWith(twoServices());
      responses['stack doctor'] = ProcessResult(0, 0, '', '');
      responses['server health'] = ProcessResult(0, 1, '', '');
      await core.refreshAll();
      expect([for (var c in core.report.children) c.id], ['stack', 'server']);
      expect(
        [for (var c in core.report.children) c.label],
        ['Local stack', 'API server'],
      );
      expect(core.report.children.last.status.message, 'down');
      core.dispose();

      // A single child under a row that says the same thing is an expander
      // that expands to itself.
      var one = coreWith(localEnvConfig());
      expect(one.report.children, isEmpty);
      one.dispose();
    });

    test('teardown offers a step per service that is up', () async {
      var core = coreWith(twoServices());
      responses['stack doctor'] = ProcessResult(0, 0, '', '');
      responses['server health'] = ProcessResult(0, 0, '', '');
      await core.refreshAll();
      // `server` declares no `stop`, so it has no step rather than a dead one.
      expect([for (var s in core.report.teardown) s.id], ['stack.stop']);
      core.dispose();
    });

    test('the cache keeps a reading per service, in one file', () async {
      var first = coreWith(twoServices());
      responses['stack doctor'] = ProcessResult(0, 0, 'four containers', '');
      responses['server health'] = ProcessResult(0, 1, '', '');
      await first.refreshAll();
      first.dispose();

      expect(
        runDir.listSync().whereType<File>().where(
          (f) => p.basename(f.path).startsWith('stack-'),
        ),
        hasLength(1),
        reason: 'one file per worktree is what the explorer column reads',
      );

      ran.clear();
      var second = coreWith(twoServices());
      await second.computeAll();
      expect(second.services.first.reading.state, StackState.up);
      expect(second.services.first.reading.detail, 'four containers');
      expect(second.services.last.reading.state, StackState.down);
      expect(ran, isEmpty, reason: 'a cold read spawns nothing');
      second.dispose();
    });

    test('two services cannot share an id', () {
      expect(
        () => DevStack(
          services: [
            StackService.delegated(
              'stack',
              probe: Probe.exitCode(StackRun.command(['a'])),
            ),
            StackService.delegated(
              'stack',
              probe: Probe.exitCode(StackRun.command(['b'])),
            ),
          ],
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// The single service, for the configs above — every one of them declares one.
///
/// The container is what a shell talks to; the lifecycle is per service, so a
/// test asserting on a probe or a transition is asserting about one of these.
extension on DevStackCore {
  DelegatedServiceCore get service => only! as DelegatedServiceCore;
}
