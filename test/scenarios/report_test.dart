import 'dart:convert';
import 'dart:io';

import 'package:flutterware/scenarios_report.dart';
import 'package:test/test.dart';

/// The published `run.json` reader: what a consumer's `tool/` script compiles
/// against. A field that stops round-tripping here breaks somebody's script,
/// which is the reason this suite exists.
void main() {
  ScenarioRunStep step({
    int index = 1,
    String? verb,
    String? target,
    bool unchanged = false,
    bool settled = true,
  }) => ScenarioRunStep(
    index: index,
    position: '#$index',
    auto: true,
    image: 'build/runs/1/f/s/$index-shot.png',
    format: 'png',
    width: 390,
    height: 844,
    tree: 'build/runs/1/f/s/$index-shot.tree.json',
    texts: const ['Pay', '€ 12'],
    verb: verb,
    target: target,
    unchanged: unchanged,
    settled: settled,
  );

  group('a step', () {
    test('round-trips whole', () {
      var full = ScenarioRunStep(
        index: 3,
        position: '0.1#2',
        parent: 2,
        branch: 'by card',
        name: 'Checkout',
        auto: false,
        tags: const ['store'],
        image: 'a.png',
        format: 'png',
        width: 390,
        height: 844,
        tree: 'a.tree.json',
        keys: 'a.keys.json',
        semantics: 'a.semantics.json',
        texts: const ['Pay'],
        address: 'fw://main/scenarios/f/s/3',
        statusBrightness: 'light',
        navBrightness: 'dark',
        verb: 'tap',
        target: '"Pay"',
        events: 'a.events.json',
        eventCount: 2,
        eventChannels: const {'network': 1, 'system': 1},
        eventTitles: const ['POST /login → 401'],
        eventsDropped: 5,
        frames: 'a.frames',
        frameCount: 4,
        frameWidth: 195,
        frameHeight: 422,
        frameIntervalMs: 33,
        framesDropped: 2,
        settled: false,
        landed: false,
        strayFrames: 1,
        unchanged: true,
        failure: 'boom',
      );

      var back = ScenarioRunStep.fromJson(
        (jsonDecode(jsonEncode(full.toJson())) as Map).cast<String, Object?>(),
      );

      expect(back.index, 3);
      expect(back.position, '0.1#2');
      expect(back.parent, 2);
      expect(back.branch, 'by card');
      expect(back.name, 'Checkout');
      expect(back.auto, isFalse);
      expect(back.tags, ['store']);
      expect(back.image, 'a.png');
      expect(back.keys, 'a.keys.json');
      expect(back.semantics, 'a.semantics.json');
      expect(back.texts, ['Pay']);
      expect(back.address, 'fw://main/scenarios/f/s/3');
      expect(back.statusBrightness, 'light');
      expect(back.navBrightness, 'dark');
      expect(back.action, 'tap "Pay"');
      expect(back.events, 'a.events.json');
      expect(back.eventCount, 2);
      expect(back.eventChannels, {'network': 1, 'system': 1});
      expect(back.notableEventCount, 1);
      expect(back.eventTitles, ['POST /login → 401']);
      expect(back.eventsDropped, 5);
      expect(back.frames, 'a.frames');
      expect(back.hasMotion, isTrue);
      expect(back.framePaths, [
        'a.frames/0000.png',
        'a.frames/0001.png',
        'a.frames/0002.png',
        'a.frames/0003.png',
      ]);
      expect(back.frameIntervalMs, 33);
      expect(back.framesDropped, 2);
      expect(back.settled, isFalse);
      expect(back.landed, isFalse);
      expect(back.strayFrames, 1);
      expect(back.unchanged, isTrue);
      expect(back.failure, 'boom');
      // A step that is not a screen: its kind rides the record, and the frame
      // fields it has no business carrying are absent rather than zeroed.
      var beat = ScenarioRunStep.fromJson(
        ScenarioRunStep(
          index: 2,
          position: '#2',
          auto: false,
          name: 'invoice',
          kind: ScenarioStepKind.document,
          file: 'a.invoice.pdf',
          mimeType: 'application/pdf',
          bytes: 12,
          verb: 'document',
        ).toJson(),
      );
      expect(beat.kind, ScenarioStepKind.document);
      expect(beat.file, 'a.invoice.pdf');
      expect(beat.mimeType, 'application/pdf');
      expect(beat.bytes, 12);
      expect(beat.image, isNull);
      expect(beat.tree, isNull);
    });

    test('a healthy record stays the size it was', () {
      var json = step().toJson();

      // The flags whose healthy value is the default ride only when they have
      // something to say — a fifty-step run must not pay for fifty "fine"s.
      expect(json.keys, isNot(contains('settled')));
      expect(json.keys, isNot(contains('landed')));
      expect(json.keys, isNot(contains('unchanged')));
      expect(json.keys, isNot(contains('strayFrames')));
      expect(json.keys, isNot(contains('eventCount')));
      // Omitted for a screen, so the overwhelmingly common step's record stays
      // the size it has always been — and a reader written before there was
      // anything but screens reads one correctly by ignoring the key.
      expect(json.keys, isNot(contains('kind')));
      expect(json.keys, isNot(contains('file')));
      expect(json.keys, isNot(contains('address')));
    });

    test('locate rewrites every path and only the paths', () {
      var located =
          ScenarioRunStep(
            index: 1,
            position: '#1',
            auto: true,
            image: '/abs/out/1-a.png',
            format: 'png',
            width: 1,
            height: 1,
            tree: '/abs/out/1-a.tree.json',
            keys: '/abs/out/1-a.keys.json',
            semantics: '/abs/out/1-a.semantics.json',
            events: '/abs/out/1-a.events.json',
            frames: '/abs/out/1-a.frames',
            frameCount: 2,
            texts: const ['x'],
            verb: 'tap',
          ).locate(
            root: '/worktree',
            address: 'fw://main/scenarios/f/s/1',
            path: (path) => path.replaceFirst('/abs/out/', 'out/'),
          );

      expect(located.image, 'out/1-a.png');
      expect(located.tree, 'out/1-a.tree.json');
      expect(located.keys, 'out/1-a.keys.json');
      expect(located.semantics, 'out/1-a.semantics.json');
      expect(located.events, 'out/1-a.events.json');
      expect(located.frames, 'out/1-a.frames');
      // A document beat's payload is rewritten like every other artifact path.
      expect(
        ScenarioRunStep(
              index: 2,
              position: '#2',
              auto: false,
              kind: ScenarioStepKind.document,
              file: '/abs/out/2-doc.pdf',
            )
            .locate(
              root: '/worktree',
              address: 'fw://main/scenarios/f/s/2',
              path: (path) => path.replaceFirst('/abs/out/', 'out/'),
            )
            .file,
        'out/2-doc.pdf',
      );
      expect(located.root, '/worktree');
      expect(located.address, 'fw://main/scenarios/f/s/1');
      expect(located.verb, 'tap');
      expect(located.texts, ['x']);
    });
  });

  group('an outcome', () {
    test('counts its own steps on the harness record', () {
      var wire =
          (jsonDecode(
              jsonEncode(
                ScenarioRunOutcome(
                  file: 'f',
                  name: 's',
                  ok: true,
                  steps: [
                    step(index: 1),
                    step(index: 2, unchanged: true),
                    step(index: 3, settled: false),
                  ],
                ),
              ),
            ) as Map).cast<String, Object?>()
            ..remove('stepCount')
            ..remove('unchangedCount')
            ..remove('unsettledCount');
      var back = ScenarioRunOutcome.fromJson(wire);

      expect(back.stepCount, 3);
      expect(back.unchangedCount, 1);
      expect(back.unsettledCount, 1);
    });

    test('trusts the counts on a trimmed copy', () {
      var trimmed = ScenarioRunOutcome(
        file: 'f',
        name: 's',
        ok: true,
        steps: [step(index: 1), step(index: 2)],
        stepCount: 2,
        unchangedCount: 1,
        unsettledCount: 2,
      ).withoutSteps();

      var back = ScenarioRunOutcome.fromJson(
        (jsonDecode(jsonEncode(trimmed)) as Map).cast<String, Object?>(),
      );

      expect(back.steps, isEmpty);
      expect(back.stepCount, 2);
      expect(back.unchangedCount, 1);
      // The number the summary exists to carry: with no steps to count, a
      // recount would read zero and say the run was still.
      expect(back.unsettledCount, 2);
    });

    test('carries its errors and translations', () {
      var back = ScenarioRunOutcome.fromJson(
        (jsonDecode(
          jsonEncode(
            ScenarioRunOutcome(
              file: 'f',
              name: 's',
              ok: false,
              errors: [ScenarioRunError(error: 'boom', stack: 'at main')],
              translations: const {
                'app': {'cart.title': 'Panier'},
              },
            ),
          ),
        ) as Map).cast<String, Object?>(),
      );

      expect(back.errors.single.error, 'boom');
      expect(back.errors.single.stack, 'at main');
      expect(back.translations, {
        'app': {'cart.title': 'Panier'},
      });
    });
  });

  group('a run report', () {
    ScenarioRunResult result() => ScenarioRunResult(
      axes: const {'language': 'fr'},
      packages: [
        ScenarioRunPackage(
          path: 'app',
          output: '/abs/out',
          ms: 1200,
          scenarios: [
            ScenarioRunOutcome(
              file: 'f',
              name: 's',
              ok: false,
              steps: [step(index: 1)],
              stepCount: 1,
              errors: [ScenarioRunError(error: 'boom')],
            ),
          ],
        ),
      ],
    );

    test('a setup beat round-trips its kind and its duration', () {
      var beat = ScenarioRunStep(
        index: 1,
        position: '#1',
        auto: false,
        name: 'fresh account',
        kind: ScenarioStepKind.setup,
        ms: 340,
      );
      var read = ScenarioRunStep.fromJson(beat.toJson());
      expect(read.kind, ScenarioStepKind.setup);
      expect(read.ms, 340);
      expect(read.image, isNull);
    });

    test('a package says its clock only when it is not the fake one', () {
      var fake = ScenarioRunPackage(path: 'app', output: '/abs/out');
      expect(fake.toJson().containsKey('time'), isFalse);
      expect(ScenarioRunPackage.fromJson(fake.toJson()).time, 'fake');
      expect(ScenarioRunPackage.fromJson(fake.toJson()).isRealTime, isFalse);

      var live = ScenarioRunPackage(
        path: 'app',
        output: '/abs/out',
        time: 'real',
        animations: 0.1,
      );
      var read = ScenarioRunPackage.fromJson(live.toJson());
      expect(read.time, 'real');
      expect(read.animations, 0.1);
      expect(read.isRealTime, isTrue);
      expect(read.carrying(const []).time, 'real');
    });

    test('is stamped with the version it was written by', () {
      expect(result().toJson()['version'], scenarioRunReportVersion);
    });

    test('a red run lists what failed, flat, and a green one does not', () {
      var red = result();
      expect(red.failed, [
        {'package': 'app', 'file': 'f', 'scenario': 's', 'error': 'boom'},
      ]);
      expect(red.toJson()['failed'], red.failed);

      var unrunnable = ScenarioRunResult(
        packages: [
          ScenarioRunPackage(
            path: 'lib',
            output: '/abs/out',
            error: 'the harness did not compile\n  lib/x.dart:1: oops',
          ),
        ],
      );
      expect(unrunnable.failed, [
        {'package': 'lib', 'error': 'the harness did not compile'},
      ]);

      var green = ScenarioRunResult(
        packages: [
          ScenarioRunPackage(
            path: 'app',
            output: '/abs/out',
            scenarios: [ScenarioRunOutcome(file: 'f', name: 's', ok: true)],
          ),
        ],
      );
      expect(green.failed, isEmpty);
      expect(green.toJson().containsKey('failed'), isFalse);
    });

    test('encodes whole through jsonEncode, nested objects and all', () {
      // The literals hand nested objects to `jsonEncode`'s `toEncodable`, as
      // the plugin contract documents — this is the round trip every writer
      // actually takes.
      var back = ScenarioRunResult.fromJson(
        (jsonDecode(jsonEncode(result())) as Map).cast<String, Object?>(),
      );

      expect(back.ok, isFalse);
      expect(back.axes, {'language': 'fr'});
      expect(back.packages.single.ms, 1200);
      expect(back.packages.single.scenarios.single.steps.single.index, 1);
    });

    test('a file with no version reads as the first version', () {
      var json = result().toJson()..remove('version');

      var back = ScenarioRunResult.fromJson(
        (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>(),
      );

      expect(back.version, 1);
    });

    test('refuses a version from the future, naming both sides', () {
      var json = (jsonDecode(jsonEncode(result())) as Map)
          .cast<String, Object?>();
      json['version'] = scenarioRunReportVersion + 1;

      expect(
        () => ScenarioRunResult.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('${scenarioRunReportVersion + 1}'),
              contains('Upgrade the flutterware dependency'),
            ),
          ),
        ),
      );
    });
  });

  group('reading a run off disk', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('report_test');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('finds run.json, resolves artifacts, types the events', () async {
      var out = Directory('${temp.path}/out')..createSync();
      var events = [
        AppEvent.request(method: 'POST', url: '/login', status: 401),
      ];
      File('${temp.path}/build/runs/1/f/s/1-shot.events.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(events));
      var run = ScenarioRunResult(
        packages: [
          ScenarioRunPackage(
            path: 'app',
            output: out.path,
            scenarios: [
              ScenarioRunOutcome(
                file: 'f',
                name: 's',
                ok: true,
                steps: [
                  ScenarioRunStep(
                    index: 1,
                    position: '#1',
                    auto: true,
                    image: 'build/runs/1/f/s/1-shot.png',
                    format: 'png',
                    width: 1,
                    height: 1,
                    tree: 'build/runs/1/f/s/1-shot.tree.json',
                    events: 'build/runs/1/f/s/1-shot.events.json',
                    eventCount: 1,
                    texts: const [],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      File('${out.path}/$scenarioRunReportFile')
          .writeAsStringSync(jsonEncode(run));

      var report = await ScenarioRunReport.read(out.path, root: temp.path);

      var read = report.run.packages.single.scenarios.single.steps.single;
      expect(report.file(read.events!).existsSync(), isTrue);
      var typed = report.events(read);
      expect(typed.single.channel, AppChannel.network);
      expect(typed.single.title, 'POST /login');
      expect(typed.single.detail, '401');
      expect(typed.single.error, isTrue);
    });

    test('a directory with no report says what to run', () {
      expect(
        () => ScenarioRunReport.read(temp.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(scenarioRunReportFile),
          ),
        ),
      );
    });
  });

  group('a matrix index', () {
    test('round-trips, version stamped', () async {
      var temp = Directory.systemTemp.createTempSync('index_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      var index = ScenarioRunIndex(
        runs: [
          ScenarioRunIndexEntry(
            package: 'app',
            axes: const {'device': 'iphone-se', 'language': 'fr'},
            output: 'device-iphone-se_language-fr',
            ok: false,
            scenarios: 12,
            failed: 2,
          ),
        ],
      );
      File('${temp.path}/$scenarioRunIndexFile')
          .writeAsStringSync(jsonEncode(index));

      var back = await readScenarioRunIndex(temp.path);

      expect(back.version, scenarioRunReportVersion);
      expect(back.runs.single.output, 'device-iphone-se_language-fr');
      expect(back.runs.single.axes, {'device': 'iphone-se', 'language': 'fr'});
      expect(back.runs.single.ok, isFalse);
      expect(back.runs.single.scenarios, 12);
      expect(back.runs.single.failed, 2);
    });

    test('refuses a version from the future', () {
      expect(
        () => ScenarioRunIndex.fromJson({
          'version': scenarioRunReportVersion + 1,
        }),
        throwsFormatException,
      );
    });
  });

  test('an event round-trips through its file spelling', () {
    var back = AppEvent.fromJson(
      (jsonDecode(
        jsonEncode(AppEvent.query(sql: 'SELECT 1\nFROM t', args: [1], rows: 3)),
      ) as Map).cast<String, Object?>(),
    );

    expect(back.channel, AppChannel.db);
    // Folded on the way out, so the title survives the wire as the whole
    // statement; the body still carries the formatting the app wrote.
    expect(back.title, 'SELECT 1 FROM t');
    expect(back.detail, '3 rows');
    expect(back.data, {
      'args': [1],
    });
    expect(back.body, 'SELECT 1\nFROM t');
    expect(back.error, isFalse);
  });
}
