import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_core.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// The panel's run-state machinery — transitions, kept outcomes, artifact
/// cleanup — over a fake runner, because the real one's behaviour is already
/// covered end-to-end by `runner_test.dart` and a second cold `flutter_tester`
/// here would prove nothing new about state handling.
void main() {
  late Directory root;

  ScenariosCore core({
    _FakeRunner? runner,
    double? captureScale,
    Map<String, _FakeRunner> others = const {},
  }) {
    var worktree = Worktree(path: root.path);
    var paths = ['.', ...others.keys];
    var subject = ScenariosCore(
      PluginHost(
        id: scenariosPluginId,
        label: 'Scenarios',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [for (var path in paths) Pkg(path)],
          discovered: paths,
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {
          'packages': [
            {'path': '.', 'captureScale': ?captureScale},
            for (var path in others.keys) {'path': path},
          ],
        },
      ),
    );
    if (runner != null) subject.debugInstallRunner('.', runner);
    for (var MapEntry(key: path, value: other) in others.entries) {
      subject.debugInstallRunner(path, other);
    }
    return subject;
  }

  Future<ScenarioPanelRun> settled(ScenariosCore subject) async {
    while (true) {
      var run = subject.panelRunFor(
        '.',
        file: 'test/scenarios/a_test.dart',
        scenario: 'A',
      );
      if (run != null && !run.running) return run;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void start(ScenariosCore subject) =>
      subject.startRun('.', file: 'test/scenarios/a_test.dart', scenario: 'A');

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_scenarios_core_test');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a run lands as the outcome, with its artifact directory', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    start(subject);
    expect(
      subject
          .panelRunFor('.', file: 'test/scenarios/a_test.dart', scenario: 'A')!
          .running,
      isTrue,
    );
    expect(subject.anyPanelRunning, isTrue);

    var run = await settled(subject);
    expect(run.error, isNull);
    expect(run.outcome!.ok, isTrue);
    expect(run.outcome!.steps.single.texts, ['hello']);
    expect(run.output, isNotNull);
    expect(runner.runs, 1);
    expect(subject.anyPanelRunning, isFalse);
  });

  test(
    'a step carries what the harness said about settling and failing',
    () async {
      var runner = _FakeRunner()
        ..extraStepFields = {
          'settled': false,
          'strayFrames': 3,
          'failure': 'in split branch "checkout": nothing matches "Pay"',
        };
      var subject = core(runner: runner);
      start(subject);

      var step = (await settled(subject)).outcome!.steps.single;
      expect(step.settled, isFalse);
      expect(step.strayFrames, 3);
      expect(step.failure, contains('nothing matches "Pay"'));
    },
  );

  test('a healthy step is settled without the harness saying so', () async {
    var subject = core(runner: _FakeRunner());
    start(subject);

    var step = (await settled(subject)).outcome!.steps.single;
    expect(step.settled, isTrue);
    expect(step.strayFrames, 0);
    expect(step.failure, isNull);
  });

  test('a re-run clears immediately; a failed one keeps its error and '
      'whatever it captured', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    start(subject);
    await settled(subject);

    runner.failure = 'the harness does not compile';
    runner.gate = Completer<void>();
    start(subject);
    // The immediate clear: the page never shows the previous run's pictures
    // under this run's spinner.
    var during = subject.panelRunFor(
      '.',
      file: 'test/scenarios/a_test.dart',
      scenario: 'A',
    )!;
    expect(during.running, isTrue);
    expect(during.steps, isEmpty);
    expect(during.outcome, isNull);

    runner.gate!.complete();
    var second = await settled(subject);
    expect(second.error, contains('does not compile'));
    expect(second.outcome, isNull);
  });

  test(
    'steps stream into the running state as the harness announces them',
    () async {
      var runner = _FakeRunner()
        ..gate = Completer<void>()
        ..emitSteps = true;
      var subject = core(runner: runner);
      start(subject);

      // The fake announced step 0 and is now gated mid-run: the state already
      // holds the step, before any response.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      var during = subject.panelRunFor(
        '.',
        file: 'test/scenarios/a_test.dart',
        scenario: 'A',
      )!;
      expect(during.running, isTrue);
      expect(during.steps, hasLength(1));
      expect(during.steps.single.texts, ['hello']);
      expect(during.steps.single.address, contains('/a_test.dart/A/0'));

      runner.gate!.complete();
      var final_ = await settled(subject);
      expect(final_.outcome, isNotNull);
      expect(final_.steps, hasLength(1));
    },
  );

  test('a superseding run deletes the previous artifacts', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    start(subject);
    var first = await settled(subject);
    var oldDir = Directory(first.output!)..createSync(recursive: true);

    // Same-millisecond runs would share the directory name; nudge past it.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    start(subject);
    var second = await settled(subject);
    expect(second.output, isNot(first.output));
    expect(oldDir.existsSync(), isFalse);
  });

  test('a failed run supersedes the previous one too, so nothing is '
      'stranded', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    start(subject);
    var first = await settled(subject);
    var firstDir = Directory(first.output!)..createSync(recursive: true);

    // The failure records its own directory — otherwise the next run has
    // nothing to supersede — and takes the previous one with it.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    runner.failure = 'the harness died';
    start(subject);
    var failed = await settled(subject);
    expect(failed.error, contains('the harness died'));
    expect(failed.output, isNotNull);
    expect(firstDir.existsSync(), isFalse);
    var failedDir = Directory(failed.output!)..createSync(recursive: true);

    await Future<void>.delayed(const Duration(milliseconds: 2));
    runner.failure = null;
    start(subject);
    await settled(subject);
    expect(failedDir.existsSync(), isFalse);
  });

  test('starting while running is a no-op', () async {
    var runner = _FakeRunner()..gate = Completer<void>();
    var subject = core(runner: runner);
    start(subject);
    start(subject);
    start(subject);
    runner.gate!.complete();
    await settled(subject);
    expect(runner.runs, 1);
  });

  test('the run action carries its axes into the runner, the result and '
      'every step address', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    var result =
        (await subject.invoke(
              'run',
              arguments: {
                'package': '.',
                'file': 'test/scenarios/a_test.dart',
                'scenario': 'A',
                'device': 'iphone-se',
                'language': 'fr-CA',
                'text-scale': '1.3',
                'brightness': 'dark',
                // The steps are what this is about, and a green scenario's
                // stay in the file by default.
                'steps': 'all',
              },
            ))!
            as ScenarioRunResult;

    expect(
      runner.seenAxes.single,
      const ScenarioAxes(
        device: 'iphone-se',
        language: 'fr-CA',
        textScale: 1.3,
        brightness: 'dark',
      ),
    );
    expect(result.axes, {
      'device': 'iphone-se',
      'language': 'fr-CA',
      'text-scale': '1.3',
      'brightness': 'dark',
    });
    var address = result.packages.single.scenarios.single.steps.single.address;
    expect(address, contains('device=iphone-se'));
    expect(address, contains('brightness=dark'));
  });

  test('the run action refuses axes it does not know', () async {
    var subject = core(runner: _FakeRunner());
    Future<Object?> run(Map<String, Object?> arguments) =>
        subject.invoke('run', arguments: {'package': '.', ...arguments});
    await expectLater(run({'device': 'iphone-99'}), throwsArgumentError);
    await expectLater(run({'brightness': 'dim'}), throwsArgumentError);
    await expectLater(run({'text-scale': 'big'}), throwsArgumentError);
    await expectLater(run({'language': 'not a tag'}), throwsArgumentError);
    await expectLater(run({'bold-text': 'maybe'}), throwsArgumentError);
  });

  test('an unnamed device travels unresolved, with the phone as the fallback; '
      'fit is the bare surface', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    Future<void> run(Map<String, Object?> arguments) async {
      await subject.invoke(
        'run',
        arguments: {
          'package': '.',
          'file': 'test/scenarios/a_test.dart',
          'scenario': 'A',
          ...arguments,
        },
      );
    }

    // Unspecified stays unspecified all the way to the harness, where the
    // scenario's folder profile gets first refusal — with the phone form
    // factor behind it for a folder that declares none.
    await run({});
    expect(runner.seenAxes.last.device, isNull);
    expect(runner.seenUnspecified.last, 'iphone-13');
    expect(
      runner.seenAxes.last.harnessArgs(unspecifiedDevice: 'iphone-13'),
      allOf(
        containsPair('deviceUnspecified', 'true'),
        containsPair('device', 'iphone-13'),
      ),
    );

    // Chosen is chosen: no flag, and the folder does not get to override it.
    await run({'device': 'iphone-se'});
    expect(runner.seenAxes.last.device, 'iphone-se');
    expect(
      runner.seenAxes.last.harnessArgs(unspecifiedDevice: 'iphone-13'),
      allOf(
        isNot(contains('deviceUnspecified')),
        containsPair('device', 'iphone-se'),
      ),
    );

    // And `fit` is the third state — the bare test surface, asked for.
    await run({'device': 'fit'});
    expect(runner.seenAxes.last.device, 'fit');
    expect(
      runner.seenAxes.last.harnessArgs(unspecifiedDevice: 'iphone-13'),
      allOf(isNot(contains('deviceUnspecified')), isNot(contains('device'))),
    );
  });

  test('devices and languages fan out, each into its own directory, with an '
      'index beside them', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    var output = p.join(root.path, 'matrix');
    var result =
        (await subject.invoke(
              'run',
              arguments: {
                'package': '.',
                'file': 'test/scenarios/a_test.dart',
                'scenario': 'A',
                'output': output,
                'devices': 'iphone-se,iphone-16',
                'languages': 'en,fr',
              },
            ))!
            as ScenarioRunResult;

    expect(runner.runs, 4);
    expect(
      [for (var axes in runner.seenAxes) '${axes.device}/${axes.language}'],
      ['iphone-se/en', 'iphone-se/fr', 'iphone-16/en', 'iphone-16/fr'],
    );
    // A directory per point — without it the second assignment overwrites the
    // first, since the file, scenario and step names are identical.
    expect(
      [for (var dir in runner.seenOutDirs) p.basename(dir)],
      ['iphone-se-en', 'iphone-se-fr', 'iphone-16-en', 'iphone-16-fr'],
    );
    // The per-entry assignment is on each result, not once at the top: a
    // matrix has no single answer to "what did this run as".
    expect(result.axes, isNull);
    expect(result.packages, hasLength(4));
    expect(result.packages.first.axes, {
      'device': 'iphone-se',
      'language': 'en',
    });

    var index = jsonDecode(
      File(p.join(output, 'index.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    var runs = (index['runs']! as List).cast<Map<String, Object?>>();
    expect(runs, hasLength(4));
    expect(runs.first['axes'], {'device': 'iphone-se', 'language': 'en'});
    // Relative, so the whole directory can be moved or uploaded as it stands.
    expect(runs.first['output'], 'iphone-se-en');
    expect(runs.every((r) => r['ok'] == true), isTrue);
  });

  test('a single assignment keeps the flat output it always had', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    var output = p.join(root.path, 'flat');
    var result =
        (await subject.invoke(
              'run',
              arguments: {
                'package': '.',
                'file': 'test/scenarios/a_test.dart',
                'scenario': 'A',
                'output': output,
                'device': 'iphone-se',
              },
            ))!
            as ScenarioRunResult;
    expect(runner.seenOutDirs.single, output);
    expect(File(p.join(output, 'index.json')).existsSync(), isFalse);
    expect(result.packages.single.axes, isNull);
    expect(result.axes, {'device': 'iphone-se'});
  });

  test(
    'a tag reaches the harness, which is where the filtering happens',
    () async {
      var runner = _FakeRunner();
      var subject = core(runner: runner);
      await subject.invoke(
        'run',
        arguments: {
          'package': '.',
          'file': 'test/scenarios/a_test.dart',
          'scenario': 'A',
          'tag': 'smoke',
        },
      );
      expect(runner.seenTags.single, 'smoke');
    },
  );

  test(
    'shots keeps the named captures, by language and device, numbered',
    () async {
      var runner = _FakeRunner()..writeShots = true;
      var subject = core(runner: runner);
      var output = p.join(root.path, 'store');
      var result =
          (await subject.invoke(
                'shots',
                arguments: {
                  'package': '.',
                  'output': output,
                  'devices': 'iphone-16',
                  'languages': 'en,fr',
                },
              ))!
              as ScenarioShotsResult;

      // A true screenshot, resolved in the guest — the device may have come
      // from a folder profile the host never saw.
      expect(runner.seenNative, everyElement(isTrue));

      expect(result.count, 4);
      expect(
        [for (var set in result.packages.single.sets) set.directory],
        [p.join('en', 'iphone-16'), p.join('fr', 'iphone-16')],
      );
      // Named shots only, numbered in capture order — the automatic step
      // between them is a debugging artefact, not a screenshot.
      expect(result.packages.single.sets.first.images, [
        '01-welcome.png',
        '02-order-placed.png',
      ]);
      expect(
        File(p.join(output, 'en', 'iphone-16', '01-welcome.png')).existsSync(),
        isTrue,
      );
      // The run itself is scratch: what is left is the images and nothing else.
      expect(Directory(p.join(output, '.runs')).existsSync(), isFalse);

      // A tag narrows it to the shots that carry it.
      var tagged =
          (await subject.invoke(
                'shots',
                arguments: {
                  'package': '.',
                  'output': output,
                  'devices': 'iphone-16',
                  'tag': 'store',
                },
              ))!
              as ScenarioShotsResult;
      expect(tagged.packages.single.sets.single.images, ['01-welcome.png']);
      // Emptied first: yesterday's screenshot of a screen that no longer exists
      // must not ship beside today's.
      expect(
        File(p.join(output, 'en', 'iphone-16', '02-order-placed.png'))
            .existsSync(),
        isFalse,
      );
    },
  );

  test("shots over several packages keeps every package's tree", () async {
    // The output was emptied before each package, so the second deleted the
    // first's screenshots and the answer still counted them.
    var subject = core(
      runner: _FakeRunner()..writeShots = true,
      others: {'examples/shop': _FakeRunner()..writeShots = true},
    );
    var output = p.join(root.path, 'store');

    var result =
        (await subject.invoke(
              'shots',
              arguments: {
                'output': output,
                'devices': 'iphone-16',
                'languages': 'en',
              },
            ))!
            as ScenarioShotsResult;

    expect(result.packages, hasLength(2));
    for (var package in ['root', 'examples-shop']) {
      expect(
        File(p.join(output, package, 'en', 'iphone-16', '01-welcome.png'))
            .existsSync(),
        isTrue,
        reason: package,
      );
    }
  });

  test('the accessibility switches travel as axes', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner);
    var result =
        (await subject.invoke(
              'run',
              arguments: {
                'package': '.',
                'file': 'test/scenarios/a_test.dart',
                'scenario': 'A',
                'bold-text': 'true',
                'high-contrast': 'true',
              },
            ))!
            as ScenarioRunResult;
    expect(runner.seenAxes.last.boldText, isTrue);
    expect(runner.seenAxes.last.highContrast, isTrue);
    expect(runner.seenAxes.last.invertColors, isFalse);
    expect(result.axes!['bold-text'], 'true');
    expect(result.axes!['high-contrast'], 'true');
    expect(result.axes!.containsKey('invert-colors'), isFalse);
  });

  // The recording is the whole case for raw: it turns 31 pictures into 371 and
  // PNG charges ~7.5ms of encoder for each. Recording, raw measured 4.3×;
  // without one it is 31% for 160× the bytes, which is not worth it.
  test('raw follows the recorder', () async {
    var recording = _FakeRunner();
    var withMotion = core(runner: recording);
    start(withMotion);
    await settled(withMotion);
    expect(recording.seenRaw, [true]);

    var quiet = _FakeRunner();
    var withoutMotion = core(runner: quiet)..setRecordMotion(false);
    start(withoutMotion);
    await settled(withoutMotion);
    expect(quiet.seenRaw, [false]);
  });

  test("the configured captureScale is every run's default; an explicit "
      'capture-scale still wins', () async {
    var runner = _FakeRunner();
    var subject = core(runner: runner, captureScale: 3);

    // The panel's run.
    start(subject);
    await settled(subject);
    expect(runner.seenCaptureScales.last, 3);

    // The run action, defaulted…
    await subject.invoke(
      'run',
      arguments: {'package': '.', 'file': 'test/scenarios/a_test.dart'},
    );
    expect(runner.seenCaptureScales.last, 3);

    // …and overridden.
    await subject.invoke(
      'run',
      arguments: {
        'package': '.',
        'file': 'test/scenarios/a_test.dart',
        'capture-scale': '1',
      },
    );
    expect(runner.seenCaptureScales.last, 1);
  });
  test('a running point counts the scenarios that have reported', () async {
    File(p.join(root.path, 'test', 'scenarios', 'a_test.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
void main() {
  scenario('A', (s) async {});
  scenario('B', (s) async {});
}
''');
    var gate = Completer<void>();
    var runner = _FakeRunner()
      ..emitSteps = true
      ..stepScenarios = ['A', 'B']
      ..gate = gate;
    var subject = core(runner: runner);
    var running = subject.invoke(
      'run',
      arguments: {'package': '.', 'file': 'test/scenarios/a_test.dart'},
    );

    // The scan is kicked by the run and lands on its own, so the denominator
    // arrives a beat late — exactly as it does behind a real compile.
    while (subject.runProgressFor('.')?.total == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(subject.runProgressFor('.'), (done: 2, total: 2));
    // And the sidebar reads it off the status, where MCP forwards it too.
    expect(subject.report.status.message, contains('2 of 2 scenarios'));

    gate.complete();
    await running;
    expect(subject.runProgressFor('.'), isNull);
  });
}

class _FakeRunner extends ScenarioRunner {
  _FakeRunner()
    : super(packageRoot: '/none', directory: 'none', flutterSdkRoot: '/none');

  /// A fake spawns nothing, so it has no build lane — and reading the real
  /// [logPath] would take one, which means creating a directory under the
  /// `/none` this stands on.
  @override
  String get logPath => '/none/scenarios.log';

  var runs = 0;
  String? failure;
  final seenAxes = <ScenarioAxes>[];
  final seenUnspecified = <String?>[];
  final seenCaptureScales = <double?>[];
  final seenOutDirs = <String>[];
  final seenTags = <String?>[];
  final seenNative = <bool>[];

  /// When set, the fake writes real PNGs and reports the steps below —
  /// named, automatic and tagged — which is what the store lane sorts
  /// through.
  var writeShots = false;

  /// What the harness resolved the device to, echoed the way the real one
  /// does: the request's device, or the fallback the host offered.
  String? resolvedDevice;

  /// When set, [run] waits on it — so a test can observe the running state.
  Completer<void>? gate;

  /// Announce each step through [onStep] before returning, as the real
  /// runner's VM-service subscription does.
  var emitSteps = false;

  /// Which scenarios the announced steps come from, when the run was not
  /// narrowed to one — what the progress count is counting.
  List<String>? stepScenarios;

  final seenRaw = <bool>[];

  /// Merged into the emitted step — what the harness writes only when the news
  /// is bad: `settled: false`, `failure: …`.
  var extraStepFields = const <String, Object?>{};

  @override
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,
    double? captureScale,
    bool captureRaw = false,
    ScenarioPixels pixels = ScenarioPixels.all,
    int? expandTranslations,
    bool narrowestDevice = false,
    bool captureNative = false,
    FilmSettings? film,
    bool filmReel = false,
    Duration? recordInterval,
    double? recordScale,
    int recordMaxFrames = 90,
    DateTime? clock,
    ScenarioNetwork? network,
    ScenarioNetwork? projectNetwork,
    String? networkStore,
  }) async {
    runs++;
    seenAxes.add(axes);
    seenUnspecified.add(unspecifiedDevice);
    seenCaptureScales.add(captureScale);
    seenRaw.add(captureRaw);
    seenOutDirs.add(outDir);
    seenTags.add(tag);
    seenNative.add(captureNative);
    resolvedDevice = axes.device ?? unspecifiedDevice;
    if (writeShots) return _shotRun(outDir, file, scenario);
    var step = {
      'index': 0,
      'name': 'shot',
      'auto': false,
      'image': '$outDir/0-shot.png',
      'format': 'png',
      'width': 390,
      'height': 844,
      'tree': '$outDir/0-shot.tree.json',
      'texts': ['hello'],
      ...extraStepFields,
    };
    if (emitSteps) {
      for (var name in stepScenarios ?? [scenario]) {
        onStep?.call({'file': file, 'scenario': name, 'step': step});
      }
    }
    if (gate case var gate?) await gate.future;
    if (failure case var failure?) throw StateError(failure);
    return {
      'ms': 5,
      'scenarios': [
        {
          'file': file,
          'name': scenario,
          'ok': true,
          'ms': 3,
          'steps': [step],
        },
      ],
    };
  }

  /// A run with three steps: two named — one of them tagged `store` — and one
  /// automatic, each with a real file on disk to copy.
  Map<String, Object?> _shotRun(String outDir, String? file, String? scenario) {
    Directory(outDir).createSync(recursive: true);
    Map<String, Object?> step(int index, String? name, List<String> tags) {
      var image = '$outDir/$index-${name ?? 'auto'}.png';
      File(image).writeAsBytesSync([index]);
      return {
        'index': index,
        'name': ?name,
        'auto': name == null,
        if (tags.isNotEmpty) 'tags': tags,
        'image': image,
        'format': 'png',
        'width': 390,
        'height': 844,
        'tree': '$outDir/$index.tree.json',
        'texts': const <String>[],
      };
    }

    return {
      'ms': 5,
      'scenarios': [
        {
          'file': file ?? 'test/scenarios/a_test.dart',
          'name': scenario ?? 'A',
          'device': resolvedDevice,
          'ok': true,
          'ms': 3,
          'steps': [
            step(0, 'Welcome', ['store']),
            step(1, null, const []),
            step(2, 'Order placed', const []),
          ],
        },
      ],
    };
  }

  /// Nothing to list, and nothing spawned to find out: the panel asks for a
  /// listing the moment a scenario is open, and the base implementation would
  /// try to compile a harness against a Flutter SDK that is not there.
  @override
  Future<List<ScenarioListing>> list() async => const [];

  @override
  Future<void> dispose() async {}
}
