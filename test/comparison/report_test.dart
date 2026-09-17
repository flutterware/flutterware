import 'dart:convert';
import 'dart:io';

import 'package:flutterware/comparison_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The disk half — what a consumer's `tool/` script actually calls.
///
/// The round trip against the writer lives in `app/`, where the writer is.
/// This is the reader on its own: what it does with a directory that holds no
/// report, and the one distinction it exists to enforce — an exported page's
/// frames can be opened, and the comparison cache's cannot.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw_report'));
  tearDown(() => root.deleteSync(recursive: true));

  /// A page holding [json] as its `index.json`, and [frames] beside it.
  String page(
    String name,
    Map<String, Object?> json, {
    List<String> frames = const [],
  }) {
    var dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    File(p.join(dir.path, comparisonReportFile))
        .writeAsStringSync(jsonEncode(json));
    for (var frame in frames) {
      File(p.join(dir.path, frame.replaceAll('/', p.separator)))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [0x89, 0x50, 0x4e, 0x47]);
    }
    return dir.path;
  }

  Map<String, Object?> index({required String frames, String? shot}) => {
    'version': comparisonReportVersion,
    'base': 'abc123def456',
    'frames': frames,
    'counts': {'changed': 1},
    'previews': {
      'rendered': 2,
      'ms': 178,
      'items': [
        {
          'id': 'demo/card.dart#card',
          'state': 'changed',
          'shots': {'base': shot ?? 'k-base', 'head': shot ?? 'k-head'},
        },
      ],
    },
  };

  test('a directory with no report says what to run', () async {
    var empty = Directory(p.join(root.path, 'nothing'))..createSync();

    expect(
      () => ComparisonReport.read(empty.path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains(comparisonReportFile), contains('fw compare')),
        ),
      ),
    );
  });

  test('the host and the replay time of each side survive a round trip', () {
    var index = ComparisonIndex.fromJson({
      'version': comparisonReportVersion,
      'base': 'abc123def456',
      'host': {'os': 'linux', 'cpus': 8, 'rasterizer': 'impeller-vulkan'},
      'previews': {'rendered': 0, 'items': <Object?>[]},
      'scenarios': {
        'ran': 1,
        'items': [
          const ScenarioComparison(
            scenario: 'test/a_test.dart#one',
            items: [],
            branches: [],
            state: ComparedState.same,
            baseMs: 1200,
            headMs: 3400,
          ).toJson(),
        ],
      },
    });

    expect(index.host?.summary, 'linux · 8 CPUs · impeller-vulkan');
    expect(index.scenarios.single.baseMs, 1200);
    expect(index.scenarios.single.headMs, 3400);
    expect(
      ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc',
      }).host,
      isNull,
    );
  });

  test('where the time went survives a round trip', () {
    var written = const ComparisonTimings(
      phases: [
        ComparisonPhase(name: 'checkout', ms: 1800),
        ComparisonPhase(
          name: 'previews.compile',
          ms: 3200,
          package: 'app',
          side: 'base',
        ),
      ],
      unsettledSteps: {'test/a_test.dart#one': 4},
      pooledOnlyDifferences: ['test/a_test.dart#two'],
      stillTicking: {
        'test/a_test.dart#one': ['_PulseState.initState (lib/pulse.dart:18)'],
      },
    );
    var index = ComparisonIndex.fromJson({
      'version': comparisonReportVersion,
      'base': 'abc',
      'timings': jsonDecode(jsonEncode(written.toJson())),
    });

    var timings = index.timings!;
    expect(timings.phases, hasLength(2));
    expect(timings.named('previews.compile').single.side, 'base');
    expect(timings.named('previews.compile').single.package, 'app');
    expect(timings.named('checkout').single.ms, 1800);
    expect(timings.unsettledSteps, {'test/a_test.dart#one': 4});
    expect(timings.pooledOnlyDifferences, ['test/a_test.dart#two']);
    expect(timings.stillTicking, {
      'test/a_test.dart#one': ['_PulseState.initState (lib/pulse.dart:18)'],
    });
    expect(
      ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc',
      }).timings,
      isNull,
    );
  });

  test('a report from a newer flutterware is refused, not half-read', () {
    var future = page('future', {
      ...index(frames: 'relative'),
      'version': comparisonReportVersion + 1,
    });

    expect(
      () => ComparisonReport.read(future),
      throwsA(isA<FormatException>()),
    );
  });

  group('an exported page', () {
    test('resolves a frame beside its index', () async {
      var dir = page(
        'web',
        index(frames: 'relative', shot: 'shots/k-head.png'),
        frames: ['shots/k-head.png'],
      );
      var report = await ComparisonReport.read(dir);

      expect(report.index.frames, ComparisonFrames.relative);
      expect(
        report.frame('shots/k-head.png')!.path,
        p.join(dir, 'shots', 'k-head.png'),
      );
    });

    // An export encodes what the shot cache still held. A frame evicted
    // before it ran keeps its original reference — a bare cache key for a
    // preview, an absolute path to a raw frame for a scenario step — and the
    // page 404s on it. Composing a path anyway would hand a script a `File`
    // that is not there, which reads exactly like one it has not written yet.
    test(
      'a frame the export could not write is absent, not a bad path',
      () async {
        var report = await ComparisonReport.read(
          page('web', index(frames: 'relative', shot: 'k-head')),
        );

        expect(report.index.frames, ComparisonFrames.relative);
        expect(report.frame('k-head'), isNull);
      },
    );

    test('an absolute reference is never this page to open', () async {
      var stray = File(p.join(root.path, 'elsewhere.raw'))
        ..writeAsBytesSync(const [0, 1, 2, 3]);
      var report = await ComparisonReport.read(
        page('web', index(frames: 'relative', shot: stray.path)),
      );

      // It exists — this is the machine that produced it — and it is still
      // not the PNG beside the page that `frame` claims to hand back.
      expect(stray.existsSync(), isTrue);
      expect(report.frame(stray.path), isNull);
    });

    test('the findings carry their rows', () async {
      var report = await ComparisonReport.read(
        page('web', index(frames: 'relative')),
      );

      expect(report.index.ok, isFalse);
      expect(report.index.findings.single.id, 'demo/card.dart#card');
      expect(report.index.findings.single.half, ComparedHalfKind.previews);
      expect(report.index.previewsHalf.worked, 2);
    });
  });

  // The cache's own copy holds the same verdict and frames nothing outside
  // that machine can open: `ShotCache` keys, and headerless raw frames. It is
  // worth reading for the verdict; asking it for a picture is the mistake
  // this refuses.
  group('the comparison cache', () {
    test('gives up its verdict', () async {
      var report = await ComparisonReport.read(
        page('cache', index(frames: 'local')),
      );

      expect(report.index.frames, ComparisonFrames.local);
      expect(report.index.findings.single.state, ComparedState.changed);
    });

    test(
      'refuses a frame, and names the flag that would produce one',
      () async {
        var report = await ComparisonReport.read(
          page('cache', index(frames: 'local')),
        );

        expect(
          () => report.frame('k-head'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('k-head'), contains('--report=')),
            ),
          ),
        );
      },
    );
  });

  // The reader-side twin of `fw compare`'s exit code: a job gating on the
  // file has to reach the same conclusion the command did, from the same
  // rule — `ok` alone cannot separate "51 environmental failures, no
  // verdict" from "51 real regressions".
  group('the verdict gap', () {
    Map<String, Object?> allFailed({bool narrowed = false}) => {
      'version': comparisonReportVersion,
      'base': 'abc123def456',
      if (narrowed) 'narrowed': true,
      'previews': {'rendered': 0, 'items': <Object?>[]},
      'scenarios': {
        'ran': 2,
        'items': [
          {'scenario': 'test/a_test.dart#one', 'state': 'failed'},
          {'scenario': 'test/a_test.dart#two', 'state': 'failed'},
        ],
      },
    };

    test('a half of nothing but failures is named, and ok is false too', () {
      var index = ComparisonIndex.fromJson(allFailed());

      expect(index.ok, isFalse);
      expect(
        index.verdictGap,
        'the scenario half produced no verdict — '
        'all 2 scenarios failed on both sides',
      );
    });

    // A host that could run nothing to the end compared nothing, and a page
    // of "not compared" rows with a clean `ok` would otherwise read as a pass.
    test('a half where every replayed scenario had no result is a gap', () {
      var index = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'previews': {'rendered': 0, 'items': <Object?>[]},
        'scenarios': {
          'ran': 2,
          'items': [
            {
              'id': 'test/a_test.dart#one',
              'state': 'skipped',
              'inconclusive': 'This branch did not finish on either replay.',
            },
            {'id': 'test/a_test.dart#two', 'state': 'skipped'},
            {'id': 'test/a_test.dart#new', 'state': 'added'},
          ],
        },
      });

      expect(index.ok, isFalse, reason: 'the added row is a finding');
      expect(index.notCompared.single.scenario, 'test/a_test.dart#one');
      expect(
        index.verdictGap,
        'the scenario half produced no verdict — '
        'all 1 replayed scenarios were inconclusive',
      );
    });

    test('one scenario with no result beside compared ones is no gap', () {
      var index = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'previews': {'rendered': 0, 'items': <Object?>[]},
        'scenarios': {
          'ran': 2,
          'items': [
            {
              'id': 'test/a_test.dart#one',
              'state': 'skipped',
              'inconclusive': 'This branch did not finish on either replay.',
            },
            {'id': 'test/a_test.dart#two', 'state': 'same'},
          ],
        },
      });

      expect(index.ok, isTrue);
      expect(index.verdictGap, isNull);
    });

    test('a narrowed file switches the all-failed rule off', () {
      var index = ComparisonIndex.fromJson(allFailed(narrowed: true));

      expect(index.narrowed, isTrue);
      expect(index.verdictGap, isNull);
      expect(index.ok, isFalse, reason: 'the failed rows stay findings');
    });

    test('a note is a gap however the run was narrowed', () {
      var index = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'narrowed': true,
        'previews': {'rendered': 0, 'items': <Object?>[]},
        'scenarios': {
          'ran': 0,
          'note': 'The scenarios harness does not compile:\ndetails',
          'items': <Object?>[],
        },
      });

      expect(
        index.verdictGap,
        'the scenario half produced no verdict — '
        'The scenarios harness does not compile:',
      );
    });

    // The mirror: wasBroken means the base alone would not render, so a half
    // of nothing else compared no pair of pictures — and every row at once is
    // near-always one base-side cause (a cold base checkout whose native
    // assets did not build), which would otherwise read as "already broken
    // before this branch" and exit 0.
    test('a half that failed on the base side alone is the same gap', () {
      var index = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'previews': {'rendered': 0, 'items': <Object?>[]},
        'scenarios': {
          'ran': 2,
          'items': [
            {'scenario': 'test/a_test.dart#one', 'state': 'wasBroken'},
            {'scenario': 'test/a_test.dart#two', 'state': 'wasBroken'},
          ],
        },
      });

      expect(
        index.verdictGap,
        'the scenario half produced no verdict — '
        'all 2 scenarios failed on the base side alone',
      );

      // One row the branch genuinely repaired beside a compared one is a half
      // that did its job.
      var mixed = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'previews': {'rendered': 0, 'items': <Object?>[]},
        'scenarios': {
          'ran': 2,
          'items': [
            {'scenario': 'test/a_test.dart#one', 'state': 'wasBroken'},
            {'scenario': 'test/a_test.dart#two', 'state': 'same'},
          ],
        },
      });
      expect(mixed.verdictGap, isNull);
    });

    // Deliberate asymmetry: mass breakage on the *head* side is the branch's
    // problem either way — a dependency the branch added that will not build
    // is the branch's to fix — and a verdict full of `broke` findings is
    // already loud. No gap, so the red comment stands on its own.
    test('a half the branch broke entirely is a verdict, not a gap', () {
      var index = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'previews': {'rendered': 0, 'items': <Object?>[]},
        'scenarios': {
          'ran': 2,
          'items': [
            {'scenario': 'test/a_test.dart#one', 'state': 'broke'},
            {'scenario': 'test/a_test.dart#two', 'state': 'broke'},
          ],
        },
      });

      expect(index.verdictGap, isNull);
      expect(index.ok, isFalse);
    });

    test('a whole verdict has no gap, and neither does an old file', () {
      // `narrowed` absent — every file written before the key existed.
      var index = ComparisonIndex.fromJson({
        'version': comparisonReportVersion,
        'base': 'abc123def456',
        'previews': {
          'rendered': 2,
          'items': [
            {'id': 'a', 'state': 'changed'},
            {'id': 'b', 'state': 'failed'},
          ],
        },
      });

      expect(index.narrowed, isFalse);
      expect(index.verdictGap, isNull, reason: 'one compared row is a verdict');
    });
  });
}
