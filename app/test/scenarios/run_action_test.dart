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

/// The `run` action's answers, over a fake runner.
///
/// Mostly about the case that used to be silent: a `file` or `scenario` that
/// matched nothing came back as an empty list and a zero exit, so a typo read
/// as a green run. The runner is faked because none of this is about running.
void main() {
  late Directory root;

  ScenariosCore core(
    _FakeRunner runner, {
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
            for (var path in paths) {'path': path},
          ],
        },
      ),
    );
    subject.debugInstallRunner('.', runner);
    for (var MapEntry(key: path, value: other) in others.entries) {
      subject.debugInstallRunner(path, other);
    }
    return subject;
  }

  void writeScenarios(String file, List<String> names) {
    var target = File(p.join(root.path, 'test', 'scenarios', file));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync('''
import 'package:flutterware/flutter_test.dart';

void main() {
${names.map((n) => "  scenario('$n', (s) async {});").join('\n')}
}
''');
  }

  Future<ScenarioRunResult> run(
    ScenariosCore subject, {
    String? file,
    String? scenario,
    String? steps,
  }) async =>
      (await subject.invoke(
            'run',
            arguments: {'file': ?file, 'scenario': ?scenario, 'steps': ?steps},
          ))!
          as ScenarioRunResult;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_scenarios_run_test');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a relative output resolves against the worktree, and run.json lands '
      'beside the artifacts', () async {
    // A relative path handed through verbatim reached two writers with two
    // working directories — `fw` put `run.json` under its own CWD while the
    // tester put the PNGs under the package — so the index and the images it
    // named ended up in different trees.
    writeScenarios('shop_test.dart', ['Around the shop']);
    var runner = _FakeRunner(steps: 2);
    var subject = core(runner);

    var result =
        (await subject.invoke(
              'run',
              arguments: {'output': p.join('build', 'doc_run')},
            ))!
            as ScenarioRunResult;

    var expected = p.join(root.path, 'build', 'doc_run');
    expect(runner.outDirsSeen.single, expected);
    var report = result.packages.single.report!;
    expect(p.dirname(report), expected);
    expect(File(report).existsSync(), isTrue);
  });

  test(
    'one output over several packages gives each its own directory',
    () async {
      // Every package wrote its run.json into the one directory, each over the
      // last, and every package's answer named the survivor.
      writeScenarios('shop_test.dart', ['Around the shop']);
      var subject = core(
        _FakeRunner(steps: 1),
        others: {'examples/shop': _FakeRunner(steps: 1)},
      );

      var result =
          (await subject.invoke('run', arguments: {'output': 'build/all'}))!
              as ScenarioRunResult;

      var reports = [for (var run in result.packages) run.report!];
      expect(reports.map(p.dirname), [
        p.join(root.path, 'build', 'all', 'root'),
        p.join(root.path, 'build', 'all', 'examples-shop'),
      ]);
      for (var (i, report) in reports.indexed) {
        var written = ScenarioRunResult.fromJson(
          jsonDecode(File(report).readAsStringSync()) as Map<String, Object?>,
        );
        expect(written.packages.single.path, result.packages[i].path);
      }
    },
  );

  group('a selector that matched nothing', () {
    test('names the scenarios the file does declare', () async {
      writeScenarios('shop_test.dart', ['Around the shop', 'Order a coffee']);

      var result = await run(
        core(_FakeRunner(matches: false)),
        file: 'test/scenarios/shop_test.dart',
        scenario: 'Arund the shop',
      );

      expect(result.ok, isFalse);
      var error = result.packages.single.error!;
      expect(error, contains('No scenario "Arund the shop"'));
      expect(error, contains('"Around the shop"'));
      expect(error, contains('"Order a coffee"'));
    });

    test('names the files, when the file itself is the typo', () async {
      writeScenarios('shop_test.dart', ['Around the shop']);

      var result = await run(
        core(_FakeRunner(matches: false)),
        file: 'test/scenarios/shopp_test.dart',
      );

      expect(result.ok, isFalse);
      expect(
        result.packages.single.error,
        allOf(
          contains('No scenarios in "test/scenarios/shopp_test.dart"'),
          contains('test/scenarios/shop_test.dart'),
        ),
      );
    });

    test('a directory that is there and declares nothing says that', () async {
      // The old message answered this with every declaring file in the
      // package — forty-odd paths on a real suite — which reads as "your
      // directory is invalid" when the directory is fine and simply empty.
      writeScenarios('desktop/order_test.dart', ['Place an order']);
      Directory(p.join(root.path, 'test', 'scenarios', 'checkout'))
          .createSync(recursive: true);

      var result = await run(
        core(_FakeRunner(matches: false)),
        file: 'test/scenarios/checkout',
      );

      expect(result.ok, isFalse);
      var error = result.packages.single.error!;
      expect(error, contains('No scenarios under "test/scenarios/checkout"'));
      expect(error, contains('declares none'));
      // Its siblings, so the reader can see which folder they meant — not
      // every file in the package.
      expect(error, contains('desktop'));
      expect(error, isNot(contains('case_test.dart')));
    });

    test(
      'a path that is not there says so, and teaches the directory form',
      () async {
        writeScenarios('shop_test.dart', ['Around the shop']);

        var result = await run(
          core(_FakeRunner(matches: false)),
          file: 'test/scenarios/checkout',
        );

        expect(result.ok, isFalse);
        expect(
          result.packages.single.error,
          allOf(
            contains('no such file or directory'),
            contains('test/scenarios/shop_test.dart'),
            contains('takes a directory too'),
          ),
        );
      },
    );

    test('hands back the authoring hint when there are none at all', () async {
      var result = await run(
        core(_FakeRunner(matches: false)),
        file: 'test/scenarios/shop_test.dart',
      );

      expect(result.ok, isFalse);
      expect(
        result.packages.single.error,
        allOf(
          contains('no scenarios at all'),
          contains('package:flutterware/flutter_test.dart'),
          contains('fw run scenarios new'),
        ),
      );
    });
  });

  test('an unselected run that finds nothing is not an error', () async {
    // No `file`, no `scenario`: "run everything" over an empty suite ran
    // everything there was. Nothing was asked for by name, so nothing is
    // missing.
    var result = await run(core(_FakeRunner(matches: false)));

    expect(result.packages.single.error, isNull);
    expect(result.ok, isTrue);
  });

  group('what the answer carries', () {
    // A full suite across a 2×2 matrix is 160 steps and 60k tokens of paths,
    // past what any client hands a model — and almost all of it describes
    // scenarios that passed. So the steps go to a file and the answer says
    // where, and what it keeps is the frame each failure was captured at.

    test('a green run carries counts, not rows', () async {
      var result = await run(core(_FakeRunner(steps: 5, alsoGreen: 2)));

      var package = result.packages.single;
      expect(package.scenarios, isEmpty);
      expect(package.passed, 3);
      expect(package.failed, 0);
      // Never silently: an empty list with no count reads as "ran nothing",
      // which is a different and much worse answer.
      expect(package.scenariosElided, 3);
      expect(package.toJson(), containsPair('passed', 3));
    });

    test('a red run lists the red one and counts the rest', () async {
      var result = await run(
        core(_FakeRunner(ok: false, steps: 5, alsoGreen: 2)),
      );

      var package = result.packages.single;
      expect([for (var s in package.scenarios) s.name], ['A']);
      expect(package.passed, 2);
      expect(package.failed, 1);
      expect(package.scenariosElided, 2);
      expect(result.ok, isFalse);
    });

    test('a green scenario whose walk stalled keeps its row', () async {
      var result = await run(
        core(_FakeRunner(steps: 3, unchangedSteps: {2, 3}, alsoGreen: 2)),
      );

      var package = result.packages.single;
      var stalled = package.scenarios.single;
      expect(stalled.name, 'A');
      expect(stalled.unchangedCount, 2);
      expect(stalled.stepsElided, 3);
      expect(package.passed, 3);
      expect(package.scenariosElided, 2);
    });

    test('unsettled steps are summed over the rows it folded', () async {
      var result = await run(
        core(_FakeRunner(steps: 3, unsettledSteps: {1, 3}, alsoGreen: 1)),
      );

      var package = result.packages.single;
      expect(package.scenarios, isEmpty);
      expect(package.unsettledCount, 2);
    });

    test('steps: all lists every scenario and elides none', () async {
      var result = await run(
        core(_FakeRunner(steps: 2, alsoGreen: 2)),
        steps: 'all',
      );

      var package = result.packages.single;
      expect(package.scenarios, hasLength(3));
      expect(package.passed, 3);
      expect(package.toJson().containsKey('scenariosElided'), isFalse);
    });

    test('a summarised answer reads back with its counts', () async {
      var result = await run(core(_FakeRunner(steps: 2, alsoGreen: 2)));

      var decoded = ScenarioRunResult.fromJson(
        jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
      ).packages.single;
      expect(decoded.passed, 3);
      expect(decoded.scenariosElided, 3);
    });

    test('a red one carries the frame it died on, and says so', () async {
      var result = await run(core(_FakeRunner(ok: false, steps: 5)));

      var outcome = result.packages.single.scenarios.single;
      expect(outcome.steps.single.index, 5);
      expect(outcome.stepCount, 5);
    });

    test('the whole run is on disk, and the package names the file', () async {
      var result = await run(core(_FakeRunner(steps: 5)));

      var report = result.packages.single.report!;
      expect(File(report).existsSync(), isTrue);
      // Readable back into the same shape — the property the web export
      // already depends on, now the other half of a summarised answer.
      var whole = ScenarioRunResult.fromJson(
        jsonDecode(File(report).readAsStringSync()) as Map<String, dynamic>,
      );
      expect(whole.packages.single.scenarios.single.steps, hasLength(5));
    });

    test('steps: all hands back every one of them', () async {
      var result = await run(core(_FakeRunner(steps: 5)), steps: 'all');

      expect(result.packages.single.scenarios.single.steps, hasLength(5));
    });

    test('steps: none keeps even a failure to the summary', () async {
      var result = await run(
        core(_FakeRunner(ok: false, steps: 5)),
        steps: 'none',
      );

      var outcome = result.packages.single.scenarios.single;
      expect(outcome.steps, isEmpty);
      expect(outcome.stepCount, 5);
      // The reason still travels: it is one line, and it is the answer.
      expect(outcome.errors.single.error, 'expected 2, found 1');
    });

    test('a word that is not one of the three is refused with them', () async {
      expect(
        () => run(core(_FakeRunner(steps: 1)), steps: 'some'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('failing, all, none'),
          ),
        ),
      );
    });

    test('the elided steps are counted, so no count stands alone', () async {
      // `stepCount: 5, steps: []` and nothing else reads as "this run
      // captured nothing", and an agent goes looking for a failure that is
      // not there — reported by a consumer who read exactly that. The
      // difference between the two numbers is stated rather than left to be
      // inferred.
      var stalled = await run(core(_FakeRunner(steps: 5, unchangedSteps: {5})));
      expect(stalled.packages.single.scenarios.single.stepsElided, 5);

      var red = await run(core(_FakeRunner(ok: false, steps: 5)));
      expect(red.packages.single.scenarios.single.stepsElided, 4);
    });

    test('nothing elided says nothing', () async {
      var whole = await run(core(_FakeRunner(steps: 5)), steps: 'all');
      var outcome = whole.packages.single.scenarios.single;
      expect(outcome.stepsElided, 0);
      expect(outcome.toJson().containsKey('stepsElided'), isFalse);
    });

    test('the translation reads stay in the file, not in the answer', () async {
      // The largest thing in a summarised answer on any suite with a catalog
      // registered, and read by nothing that summarises: the translations
      // plugin asks for every step, so it never comes through here. Red, so
      // the answer has a row to leave them off.
      var runner = _FakeRunner(
        ok: false,
        steps: 5,
        translations: const {
          'shop': {'title': 'Brewline', 'total': 'Total'},
        },
      );
      var result = await run(core(runner));

      var outcome = result.packages.single.scenarios.single;
      expect(outcome.translations, isNull);

      var whole = ScenarioRunResult.fromJson(
        jsonDecode(File(result.packages.single.report!).readAsStringSync())
            as Map<String, dynamic>,
      );
      expect(whole.packages.single.scenarios.single.translations, {
        'shop': {'title': 'Brewline', 'total': 'Total'},
      });
    });

    test('steps: all keeps them, which is what the survey reads', () async {
      var result = await run(
        core(
          _FakeRunner(
            steps: 2,
            translations: const {
              'shop': {'title': 'Brewline'},
            },
          ),
        ),
        steps: 'all',
      );

      expect(result.packages.single.scenarios.single.translations, {
        'shop': {'title': 'Brewline'},
      });
    });

    test('stalled steps are counted in the summary, and flagged', () async {
      var result = await run(
        core(_FakeRunner(steps: 3, unchangedSteps: {2, 3})),
        steps: 'all',
      );

      var outcome = result.packages.single.scenarios.single;
      // The count survives a trimmed answer the way `stepCount` does — a
      // green run whose walk stalled must say so in the copy a reader gets.
      expect(outcome.unchangedCount, 2);
      expect(
        [for (var step in outcome.steps) step.unchanged],
        [false, true, true],
      );
    });
  });

  group('read picks its run', () {
    // The default is "the newest run under the package", and a panel session
    // — which writes captures but no run.json — used to *always* win it:
    // `panel-` sorts after every millisecond stamp.

    Directory runsDir() =>
        Directory(p.join(root.path, 'build', 'flutterware', 'scenario_runs'))
          ..createSync(recursive: true);

    void writeReport(Directory dir) {
      dir.createSync(recursive: true);
      File(p.join(dir.path, scenarioRunReportFile)).writeAsStringSync(
        jsonEncode({
          'packages': [
            {
              'path': '.',
              'output': dir.path,
              'ms': 1,
              'scenarios': [
                {
                  'file': 'test/scenarios/a_test.dart',
                  'name': 'from-cli',
                  'ok': true,
                  'ms': 1,
                  'steps': <Object?>[],
                  'stepCount': 2,
                },
              ],
            },
          ],
        }),
      );
    }

    test('prefers the newest directory that holds a run.json', () async {
      var runs = runsDir();
      writeReport(Directory(p.join(runs.path, '1000')));
      // Newer by both name and clock, but not a completed run.
      Directory(p.join(runs.path, 'panel-9999')).createSync();

      // The refusal is about the *content* of the completed run — proof the
      // panel directory was never picked, which used to answer "no run.json
      // in that directory" instead.
      expect(
        () => core(_FakeRunner()).invoke('read'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(contains('nothing failed'), contains('from-cli')),
          ),
        ),
      );
    });

    test('says so when only panel captures exist', () async {
      Directory(p.join(runsDir().path, 'panel-9999')).createSync();

      expect(
        () => core(_FakeRunner()).invoke('read'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(
              contains('none holds a $scenarioRunReportFile'),
              contains('scenarios run'),
            ),
          ),
        ),
      );
    });
  });

  group('matrix=declared', () {
    test('runs every point the declaration offers', () async {
      writeScenarios('a_test.dart', ['A']);
      var runner = _FakeRunner()
        ..listings = [
          ScenarioListing(
            file: 'test/scenarios/a_test.dart',
            name: 'A',
            profile: 'phones',
            devices: ['iphone-se', 'android-tall'],
            languages: ['fr', 'en'],
          ),
        ];
      var subject = core(runner);

      var result =
          (await subject.invoke('run', arguments: {'matrix': 'declared'}))!
              as ScenarioRunResult;

      // The declaration, crossed exactly as explicit `devices=`/`languages=`
      // lists are — so CI stops restating what the config already says.
      expect(runner.axesSeen.map((a) => '${a.device}/${a.language}').toSet(), {
        'iphone-se/fr',
        'iphone-se/en',
        'android-tall/fr',
        'android-tall/en',
      });
      expect(result.packages, hasLength(4));
      expect(result.packages.map((run) => '${run.axes}').toSet(), hasLength(4));
    });

    test('a declaration with one point stays one quiet run', () async {
      writeScenarios('a_test.dart', ['A']);
      var runner = _FakeRunner()
        ..listings = [
          ScenarioListing(
            file: 'test/scenarios/a_test.dart',
            name: 'A',
            profile: 'phones',
            devices: ['iphone-se'],
          ),
        ];
      var subject = core(runner);

      var result =
          (await subject.invoke('run', arguments: {'matrix': 'declared'}))!
              as ScenarioRunResult;

      expect(runner.axesSeen.single.device, 'iphone-se');
      // No fan-out, no per-point directories, no recorded axes — the same
      // shape a plain run has.
      expect(result.packages.single.axes, isNull);
    });

    test('refuses to sit beside explicit axis lists', () async {
      writeScenarios('a_test.dart', ['A']);
      var subject = core(_FakeRunner());
      await expectLater(
        subject.invoke(
          'run',
          arguments: {'matrix': 'declared', 'devices': 'iphone-se'},
        ),
        throwsArgumentError,
      );
    });

    test('any other value is refused with the vocabulary', () async {
      writeScenarios('a_test.dart', ['A']);
      var subject = core(_FakeRunner());
      await expectLater(
        subject.invoke('run', arguments: {'matrix': 'all'}),
        throwsArgumentError,
      );
    });
  });

  group('ok', () {
    test('is false when a scenario came back red', () async {
      var result = await run(core(_FakeRunner(ok: false)));

      expect(result.ok, isFalse);
    });

    test('is false when the package could not run at all', () async {
      var result = await run(core(_FakeRunner(failure: 'does not compile')));

      expect(result.ok, isFalse);
      expect(result.packages.single.error, contains('does not compile'));
    });

    test('is true for a green run', () async {
      var result = await run(core(_FakeRunner()));

      expect(result.ok, isTrue);
    });
  });
}

/// Returns whatever the test needs it to: nothing, a green scenario, a red
/// one, or a failure to run at all.
class _FakeRunner extends ScenarioRunner {
  _FakeRunner({
    this.ok = true,
    this.failure,
    this.matches = true,
    this.steps = 0,
    this.unchangedSteps = const {},
    this.translations,
    this.alsoGreen = 0,
    this.unsettledSteps = const {},
  }) : super(packageRoot: '/none', directory: 'none', flutterSdkRoot: '/none');

  @override
  String get logPath => '/none/scenarios.log';

  final bool ok;
  final String? failure;

  /// How many steps each scenario captured — the thing the answer decides
  /// whether to carry.
  final int steps;

  /// The indices the harness flagged as `unchanged` — verbs that acted and
  /// changed nothing on screen.
  final Set<int> unchangedSteps;

  /// How many more scenarios ran beside the first, every one of them green
  /// with [steps] clean steps — the rows a summarised answer counts.
  final int alsoGreen;

  /// The indices of the first scenario's steps whose settle gave up.
  final Set<int> unsettledSteps;

  /// Every key the scenario's catalogs were asked for. Bounded by the catalog
  /// rather than by the run, which is what makes it the largest thing in a
  /// summarised answer on a real suite.
  final Map<String, Map<String, String>>? translations;

  /// False stands for the harness running the suite and finding nothing the
  /// selector named — what a misspelling actually produces.
  final bool matches;

  /// What `list()` answers — the declaration `matrix=declared` fans out from.
  List<ScenarioListing> listings = const [];

  /// The axes every `run` call arrived with, in order.
  final axesSeen = <ScenarioAxes>[];

  /// The output directory every `run` call arrived with, in order.
  final outDirsSeen = <String>[];

  @override
  Future<List<ScenarioListing>> list() async => listings;

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
    axesSeen.add(axes);
    outDirsSeen.add(outDir);
    if (failure case var failure?) throw StateError(failure);
    if (!matches) return {'ms': 1, 'scenarios': <Object?>[]};
    return {
      'ms': 5,
      'scenarios': [
        {
          'file': file ?? 'test/scenarios/a_test.dart',
          'name': scenario ?? 'A',
          'ok': ok,
          'ms': 3,
          'steps': <Object?>[
            for (var i = 1; i <= steps; i++)
              {
                'index': i,
                'position': '#$i',
                'auto': true,
                'image': p.join(outDir, 'step$i.png'),
                'format': 'png',
                'width': 390,
                'height': 844,
                'tree': p.join(outDir, 'step$i.tree.json'),
                'texts': ['step $i'],
                if (unchangedSteps.contains(i)) 'unchanged': true,
                if (unsettledSteps.contains(i)) ...{
                  'settled': false,
                  'waited': true,
                },
              },
          ],
          'errors': [
            if (!ok) {'error': 'expected 2, found 1'},
          ],
          if (translations != null) 'translations': translations,
        },
        for (var n = 1; n <= alsoGreen; n++)
          {
            'file': 'test/scenarios/b_test.dart',
            'name': 'B$n',
            'ok': true,
            'ms': 2,
            'steps': <Object?>[
              for (var i = 1; i <= steps; i++)
                {
                  'index': i,
                  'position': '#$i',
                  'auto': true,
                  'image': p.join(outDir, 'b${n}_step$i.png'),
                  'format': 'png',
                  'width': 390,
                  'height': 844,
                  'tree': p.join(outDir, 'b${n}_step$i.tree.json'),
                  'texts': ['step $i'],
                },
            ],
          },
      ],
    };
  }

  @override
  Future<void> dispose() async {}
}
