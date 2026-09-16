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

/// What a run says about the run before it, and the `diff` action that asks
/// the same question about two runs you name.
///
/// The distinction is the point: a run's own drift is measured against
/// whatever happened to run last in the same directory, which is not something
/// a CI gate can depend on; `diff` and `baseline=` are how a stored base gets
/// named instead.
void main() {
  late Directory root;

  ScenariosCore core(_FakeRunner runner) {
    var worktree = Worktree(path: root.path);
    var subject = ScenariosCore(
      PluginHost(
        id: scenariosPluginId,
        label: 'Scenarios',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {
          'packages': [
            {'path': '.'},
          ],
        },
      ),
    );
    subject.debugInstallRunner('.', runner);
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

  /// A run report on disk, as `run.json` — the shape both `diff` arguments and
  /// `baseline=` take.
  Directory writeRun(
    String at,
    List<Map<String, Object?>> steps, {
    Map<String, String>? axes,
  }) {
    var dir = Directory(p.join(root.path, at))..createSync(recursive: true);
    File(p.join(dir.path, scenarioRunReportFile)).writeAsStringSync(
      jsonEncode({
        'packages': [
          {
            'path': '.',
            'output': dir.path,
            // A point of a matrix records the axes it ran under, and they are
            // part of a scenario's cross-run identity: a baseline written
            // without them is a baseline no fanned-out run can match.
            'axes': ?axes,
            'ms': 1,
            'scenarios': [
              {
                'file': 'test/scenarios/shop_test.dart',
                'name': 'Around the shop',
                'ok': true,
                'ms': 1,
                'steps': [
                  for (var (i, step) in steps.indexed)
                    {'index': i + 1, 'position': '#${i + 1}', ...step},
                ],
              },
            ],
          },
        ],
      }),
    );
    return dir;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_scenarios_drift_test');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('a run against the one before it', () {
    Future<ScenarioRunResult> runInto(
      ScenariosCore subject,
      String output,
    ) async =>
        (await subject.invoke('run', arguments: {'output': output}))!
            as ScenarioRunResult;

    test('names the baseline it landed on and writes the whole of it to '
        'disk', () async {
      // The counts were always honest and the answer's lists were always
      // capped, which is the wrong end to cut for a reader who wants the
      // *names*. `drift.json` is where all of them are.
      writeScenarios('shop_test.dart', ['Around the shop']);
      var runner = _FakeRunner(digests: ['aaaa', 'bbbb']);
      var subject = core(runner);
      var output = p.join('build', 'fixed_run');

      await runInto(subject, output);
      runner.digests = ['aaaa', 'zzzz'];
      var second = await runInto(subject, output);

      var drift = second.packages.single.drift!;
      expect(drift.compared, 2);
      expect(drift.changed.single.position, '#2');
      // The directory it was read from, worktree-relative — not "the previous
      // run", which names nothing a reader could go and look at.
      expect(drift.baseline, output);

      var file = File(p.join(root.path, output, scenarioRunDriftFile));
      expect(file.existsSync(), isTrue);
      expect(drift.file, p.join(output, scenarioRunDriftFile));
      var written = ScenarioRunDrift.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
      );
      expect(written.changed.single.position, '#2');
      expect(written.baseline, output);
    });

    test('the run report itself stays a record of its own run', () async {
      // A report copied elsewhere would otherwise carry a baseline that means
      // nothing there. The drift has its own file for that reason.
      writeScenarios('shop_test.dart', ['Around the shop']);
      var runner = _FakeRunner(digests: ['aaaa']);
      var subject = core(runner);
      var output = p.join('build', 'fixed_run');

      await runInto(subject, output);
      runner.digests = ['zzzz'];
      await runInto(subject, output);

      var report = jsonDecode(
        File(p.join(root.path, output, scenarioRunReportFile))
            .readAsStringSync(),
      ) as Map<String, Object?>?;
      expect((report!['packages'] as List?)!.single, isNot(contains('drift')));
    });

    test(
      'a suite that did not move still writes the file it did not fill',
      () async {
        // "No baseline" and "a baseline, and nothing moved" are different
        // answers, and a gate reading the directory has to tell them apart. An
        // absent file for both would make an unverified run look like a
        // verified one.
        writeScenarios('shop_test.dart', ['Around the shop']);
        var subject = core(_FakeRunner(digests: ['aaaa']));
        var output = p.join('build', 'fixed_run');

        var first = await runInto(subject, output);
        // Nothing to compare against yet: no drift, and no file.
        expect(first.packages.single.drift, isNull);
        expect(
          File(p.join(root.path, output, scenarioRunDriftFile)).existsSync(),
          isFalse,
        );

        var second = await runInto(subject, output);

        expect(second.packages.single.drift!.isEmpty, isTrue);
        var file = File(p.join(root.path, output, scenarioRunDriftFile));
        expect(file.existsSync(), isTrue);
        var written = ScenarioRunDrift.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
        );
        expect(written.isEmpty, isTrue);
        expect(written.compared, 1);
        expect(written.baseline, output);
      },
    );

    test(
      'a refused baseline does not leave the plugin reading "running…"',
      () async {
        // The throw comes from before the run, and it used to escape between
        // `_setBusy` and the `finally` that clears it — leaving the panel and
        // every status reply saying the suite was running, forever.
        writeScenarios('shop_test.dart', ['Around the shop']);
        Directory(p.join(root.path, 'test', 'empty'))
            .createSync(recursive: true);
        var subject = core(_FakeRunner(digests: ['aaaa']));

        await expectLater(
          subject.invoke(
            'run',
            arguments: {'baseline': p.join('test', 'empty')},
          ),
          throwsA(isA<ArgumentError>()),
        );

        // `scanning…` is the scan this test never waited for; what must not be
        // there is the busy status the run set on its way to the refusal.
        expect(subject.report.status.message, isNot(contains('running')));
      },
    );

    test(
      'baseline= names a stored base instead of whatever ran last',
      () async {
        // The reason it exists: the default baseline is "the newest earlier run
        // in this directory", which a CI gate cannot depend on.
        writeScenarios('shop_test.dart', ['Around the shop']);
        var base = writeRun(p.join('test', 'base'), [
          {'auto': true, 'digest': 'aaaa'},
        ]);
        var subject = core(_FakeRunner(digests: ['zzzz']));

        var result =
            (await subject.invoke(
                  'run',
                  arguments: {
                    'output': p.join('build', 'fresh'),
                    'baseline': p.relative(base.path, from: root.path),
                  },
                ))!
                as ScenarioRunResult;

        var drift = result.packages.single.drift!;
        expect(drift.changed.single.position, '#1');
        expect(drift.baseline, p.join('test', 'base'));
      },
    );

    test('a fanned-out run takes the matching point of the baseline', () async {
      writeScenarios('shop_test.dart', ['Around the shop']);
      var base = p.join('test', 'base');
      // Unnamed, as the fake runner's steps are — this test is about which
      // baseline each point lands on, not about how steps pair inside one.
      writeRun(
        p.join(base, 'iphone-16'),
        [
          {'auto': true, 'digest': 'aaaa'},
        ],
        axes: {'device': 'iphone-16'},
      );
      writeRun(
        p.join(base, 'iphone-se'),
        [
          {'auto': true, 'digest': 'bbbb'},
        ],
        axes: {'device': 'iphone-se'},
      );

      var result =
          (await core(_FakeRunner(digests: ['aaaa'])).invoke(
                'run',
                arguments: {
                  'output': p.join('build', 'fresh'),
                  'baseline': base,
                  'devices': 'iphone-16,iphone-se',
                },
              ))!
              as ScenarioRunResult;

      // Each point against its own point: the iPhone matched its baseline and
      // the Pixel — whose baseline digest is different — did not.
      var byPoint = {
        for (var run in result.packages) axisSlugOf(run): run.drift!,
      };
      expect(byPoint['iphone-16']!.baseline, p.join(base, 'iphone-16'));
      expect(byPoint['iphone-16']!.isEmpty, isTrue);
      expect(byPoint['iphone-se']!.baseline, p.join(base, 'iphone-se'));
      expect(byPoint['iphone-se']!.changed, hasLength(1));
    });

    test('a fanned-out run refuses a baseline with no such point', () async {
      // It used to fall back to the directory itself, which looks forgiving
      // and is not: an axis slug is part of a scenario's cross-run identity,
      // so the comparison shared nothing and answered `compared: 0` — a
      // silence a reader cannot tell from a suite that did not move.
      writeScenarios('shop_test.dart', ['Around the shop']);
      var base = p.join('test', 'base');
      writeRun(
        p.join(base, 'iphone-16'),
        [
          {'auto': false, 'name': 'Cart', 'digest': 'aaaa'},
        ],
        axes: {'device': 'iphone-16'},
      );

      await expectLater(
        core(_FakeRunner(digests: ['aaaa'])).invoke(
          'run',
          arguments: {'baseline': base, 'devices': 'iphone-16,iphone-se'},
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'baseline')
              .having(
                (e) => '${e.message}',
                'message',
                allOf(
                  contains('the point `iphone-se`'),
                  // What it does hold, so the caller is not left guessing.
                  contains('iphone-16'),
                ),
              ),
        ),
      );
    });

    test(
      'a fanned-out run says so when the baseline never fanned out',
      () async {
        // The two shapes are not interchangeable and naming a subdirectory
        // cannot make them so, which is the thing to say rather than listing
        // points there are none of.
        writeScenarios('shop_test.dart', ['Around the shop']);
        var base = writeRun(p.join('test', 'base'), [
          {'auto': false, 'name': 'Cart', 'digest': 'aaaa'},
        ]);

        await expectLater(
          core(_FakeRunner(digests: ['aaaa'])).invoke(
            'run',
            arguments: {
              'baseline': p.relative(base.path, from: root.path),
              'devices': 'iphone-16,iphone-se',
            },
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '${e.message}',
              'message',
              allOf(contains('no points at all'), contains('did not fan out')),
            ),
          ),
        );
      },
    );

    test('a baseline holding no run refuses, and says what is there', () async {
      writeScenarios('shop_test.dart', ['Around the shop']);
      Directory(p.join(root.path, 'test', 'empty')).createSync(recursive: true);

      await expectLater(
        core(_FakeRunner(digests: ['aaaa']))
            .invoke('run', arguments: {'baseline': p.join('test', 'empty')}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('no $scenarioRunReportFile there'),
          ),
        ),
      );
    });
  });

  group('diff', () {
    test('compares two runs that are already on disk', () async {
      var before = writeRun(p.join('build', 'base'), [
        {'auto': false, 'name': 'Cart', 'digest': 'aaaa'},
        {'auto': false, 'name': 'Checkout', 'digest': 'bbbb'},
      ]);
      var after = writeRun(p.join('build', 'head'), [
        {'auto': false, 'name': 'Cart', 'digest': 'aaaa'},
        {'auto': false, 'name': 'Checkout', 'digest': 'zzzz'},
      ]);

      var result =
          (await core(_FakeRunner()).invoke(
                'diff',
                arguments: {'before': before.path, 'after': after.path},
              ))!
              as ScenarioDiffResult;

      expect(result.before, p.join('build', 'base'));
      expect(result.after, p.join('build', 'head'));
      expect(result.comparison.changed.single.name, 'Checkout');
      expect(result.comparison.nameMatched, 2);
      expect(result.comparison.unanchored, 0);
      // Nested under the key `run` reports it under, so a reader who knows
      // one knows the other.
      var drift = result.toJson()['drift']! as Map<String, Object?>;
      expect(drift['baseline'], p.join('build', 'base'));
    });

    test('reports a facet no screenshot could show', () async {
      // The capture is the app's own surface and the status bar is drawn
      // around it, so a digest cannot see this at all. A behaviour change
      // reading as "nothing moved" is the most dangerous answer here.
      var before = writeRun(p.join('build', 'base'), [
        {
          'auto': false,
          'name': 'Cart',
          'digest': 'aaaa',
          'statusBrightness': 'light',
        },
      ]);
      var after = writeRun(p.join('build', 'head'), [
        {
          'auto': false,
          'name': 'Cart',
          'digest': 'aaaa',
          'statusBrightness': 'dark',
        },
      ]);

      var result =
          (await core(_FakeRunner()).invoke(
                'diff',
                arguments: {'before': before.path, 'after': after.path},
              ))!
              as ScenarioDiffResult;

      expect(result.comparison.changed.single.what, [
        ScenarioDriftFacet.statusBrightness,
      ]);
    });

    test('steps=all lifts the cap the wire puts on the lists', () async {
      var steps = [
        for (var i = 0; i < 30; i++)
          {'auto': false, 'name': 'Shot $i', 'digest': 'a$i'},
      ];
      var before = writeRun(p.join('build', 'base'), steps);
      var after = writeRun(p.join('build', 'head'), [
        for (var i = 0; i < 30; i++)
          {'auto': false, 'name': 'Shot $i', 'digest': 'b$i'},
      ]);

      var subject = core(_FakeRunner());
      var capped =
          (await subject.invoke(
                'diff',
                arguments: {'before': before.path, 'after': after.path},
              ))!
              as ScenarioDiffResult;
      var whole =
          (await subject.invoke(
                'diff',
                arguments: {
                  'before': before.path,
                  'after': after.path,
                  'steps': 'all',
                },
              ))!
              as ScenarioDiffResult;

      Map<String, Object?> driftOf(ScenarioDiffResult it) =>
          it.toJson()['drift']! as Map<String, Object?>;

      expect(driftOf(capped)['changedSteps'] as List?, hasLength(20));
      expect(driftOf(capped)['changed'], 30);
      expect(driftOf(whole)['changedSteps'] as List?, hasLength(30));
    });

    test('a directory holding no run refuses, naming the parameter', () async {
      var before = writeRun(p.join('build', 'base'), [
        {'auto': true, 'digest': 'aaaa'},
      ]);
      Directory(p.join(root.path, 'build', 'empty'))
          .createSync(recursive: true);

      await expectLater(
        core(_FakeRunner()).invoke(
          'diff',
          arguments: {'before': before.path, 'after': p.join('build', 'empty')},
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'after')
              .having(
                (e) => '${e.message}',
                'message',
                contains('no $scenarioRunReportFile there'),
              ),
        ),
      );
    });

    test(
      'a steps= that take() would choke on is refused, not thrown',
      () async {
        // `int.tryParse` accepts a negative and `Iterable.take` does not, so a
        // digits-only check answered a typo with a RangeError from three frames
        // down — on a dirty comparison only, since an empty list never takes.
        var before = writeRun(p.join('build', 'base'), [
          {'auto': false, 'name': 'Cart', 'digest': 'aaaa'},
        ]);
        var after = writeRun(p.join('build', 'head'), [
          {'auto': false, 'name': 'Cart', 'digest': 'zzzz'},
        ]);

        await expectLater(
          core(_FakeRunner()).invoke(
            'diff',
            arguments: {
              'before': before.path,
              'after': after.path,
              'steps': '-1',
            },
          ),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.name, 'name', 'steps')
                .having(
                  (e) => '${e.message}',
                  'message',
                  contains('0 or more'),
                ),
          ),
        );
      },
    );

    test(
      'with no run on disk it names `after`, not a parameter it lacks',
      () async {
        // The helper behind the default answers `read` too, where the same
        // argument is called `output` — a refusal naming that sends the caller
        // to a flag `diff` does not declare.
        var before = writeRun(p.join('build', 'base'), [
          {'auto': true, 'digest': 'aaaa'},
        ]);

        await expectLater(
          core(_FakeRunner())
              .invoke('diff', arguments: {'before': before.path}),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.name, 'name', 'after')
                .having(
                  (e) => '${e.message}',
                  'message',
                  allOf(contains('`after`'), isNot(contains('`output`'))),
                ),
          ),
        );
      },
    );

    test('before is required, and the refusal says what it takes', () async {
      await expectLater(
        core(_FakeRunner()).invoke('diff'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            allOf(contains('required'), contains(scenarioRunReportFile)),
          ),
        ),
      );
    });
  });
}

/// The axis slug a fanned-out package recorded, as the directory name the run
/// wrote it under.
String axisSlugOf(ScenarioRunPackage run) => p.basename(run.output);

/// A runner whose steps carry whatever digests the test hands it — which is
/// all a comparison looks at.
class _FakeRunner extends ScenarioRunner {
  _FakeRunner({this.digests = const []})
    : super(packageRoot: '/none', directory: 'none', flutterSdkRoot: '/none');

  @override
  String get logPath => '/none/scenarios.log';

  /// One digest per step of the single scenario this runs.
  List<String> digests;

  @override
  Future<List<ScenarioListing>> list() async => const [];

  @override
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,
    int? jobs,
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
  }) async => {
    'ms': 5,
    'scenarios': [
      {
        'file': file ?? 'test/scenarios/shop_test.dart',
        'name': scenario ?? 'Around the shop',
        'ok': true,
        'ms': 3,
        'steps': [
          for (var (i, digest) in digests.indexed)
            {
              'index': i + 1,
              'position': '#${i + 1}',
              'auto': true,
              'image': p.join(outDir, 'step${i + 1}.png'),
              'format': 'png',
              'tree': p.join(outDir, 'step${i + 1}.tree.json'),
              'texts': <String>[],
              'digest': digest,
            },
        ],
        'errors': <Object?>[],
      },
    ],
  };

  @override
  Future<void> dispose() async {}
}
