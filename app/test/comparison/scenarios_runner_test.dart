import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/artifact.dart';
import 'package:flutterware_app/src/comparison/phase_clock.dart';
import 'package:flutterware_app/src/comparison/scenario_diff.dart';
import 'package:flutterware_app/src/comparison/scenario_alignment.dart';
import 'package:flutterware_app/src/comparison/scenarios_runner.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:flutterware_app/src/comparison/skip.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The scenario half's orchestration — what is new, what nothing touched, and
/// what order it all ranks in.
///
/// Driven through a fake source, which is the whole reason the seam exists:
/// none of this needs a `flutter_tester` or a harness build to be wrong, and
/// while it lived inside `fw compare` none of it was tested at all.
void main() {
  late Directory root;
  late _FakeSource source;
  late ShotCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_scenarios_runner');
    source = _FakeSource();
    cache = ShotCache(p.join(root.path, 'shots'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  String checkout(String name, Map<String, String> files) {
    var dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    files.forEach((relative, content) {
      File(p.join(dir.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    });
    return dir.path;
  }

  ScenariosRunner runnerFor({
    required String base,
    required String head,
    String sdk = 'test-sdk',
    int jobs = 1,
  }) => ScenariosRunner(
    headRoot: head,
    baseRoot: base,
    source: source,
    cache: cache,
    locks: null,
    sdk: sdk,
    jobs: jobs,
  );

  group('the plan', () {
    test('a scenario nothing touched is skipped, and never replayed', () async {
      source.declared = ['test/shop.dart#Checkout'];
      var files = {'test/shop.dart': 'const flow = 1;'};

      var plan = await runnerFor(
        base: checkout('base', files),
        head: checkout('head', files),
      ).plan();

      expect(plan.toRun, isEmpty);
      expect(plan.total, 1);
      expect(plan.settled.single.state, ComparedState.skipped);
      expect(source.replayed, isEmpty);
    });

    test('a touched scenario is the one that has to run', () async {
      source.declared = ['test/shop.dart#Checkout', 'test/cart.dart#Cart'];

      var plan = await runnerFor(
        base: checkout('base', {
          'test/shop.dart': '1',
          'test/cart.dart': 'same',
        }),
        head: checkout('head', {
          'test/shop.dart': '2',
          'test/cart.dart': 'same',
        }),
      ).plan();

      expect(plan.toRun, ['test/shop.dart#Checkout']);
      expect(plan.total, 2);
    });

    test('a scenario one side has is settled without a replay', () async {
      source.onBase = ['test/gone.dart#Gone'];
      source.onHead = ['test/new.dart#Fresh'];

      var plan = await runnerFor(
        base: checkout('base', {'test/gone.dart': '1'}),
        head: checkout('head', {'test/new.dart': '1'}),
      ).plan();

      expect(plan.toRun, isEmpty);
      expect(plan.settled.map((s) => '${s.scenario}:${s.state.name}'), [
        'test/new.dart#Fresh:added',
        'test/gone.dart#Gone:removed',
      ]);
    });

    test('only the named scenarios are looked at', () async {
      source.declared = ['test/shop.dart#Checkout', 'test/cart.dart#Cart'];

      var plan = await ScenariosRunner(
        headRoot: checkout('head', {
          'test/shop.dart': '2',
          'test/cart.dart': '2',
        }),
        baseRoot: checkout('base', {
          'test/shop.dart': '1',
          'test/cart.dart': '1',
        }),
        source: source,
        cache: cache,
        locks: null,
        sdk: 'test-sdk',
        only: const ['test/cart.dart#Cart'],
      ).plan();

      expect(plan.total, 1);
      expect(plan.toRun, ['test/cart.dart#Cart']);
    });
  });

  // The review that found this: the lockfile left the pixel inputs to come in
  // through `locks`, which was optional, and neither caller passed it — so a
  // dependency bump replayed no scenario at all. `locks` is required now; these
  // pin what it is for.
  group('the lockfile', () {
    String lockOf(String version) =>
        'packages:\n'
        '  used:\n'
        '    dependency: "direct main"\n'
        '    source: hosted\n'
        '    version: "$version"\n';
    const graph =
        '{"roots":["pkg"],"packages":['
        '{"name":"pkg","dependencies":["used"]},'
        '{"name":"used","dependencies":[]}]}';

    Future<ScenariosPlan> planWith({
      required Map<String, String> base,
      required Map<String, String> head,
    }) {
      var baseRoot = checkout('base', base);
      var headRoot = checkout('head', head);
      return ScenariosRunner(
        headRoot: headRoot,
        baseRoot: baseRoot,
        source: source,
        cache: cache,
        locks: LockSides(packagePath: '.', roots: [headRoot, baseRoot]),
        sdk: 'test-sdk',
      ).plan();
    }

    test('a bump to a package the scenario imports replays it', () async {
      source.declared = ['test/shop.dart#Checkout'];
      var shop = "import 'package:used/used.dart';\n";

      var plan = await planWith(
        base: {
          'test/shop.dart': shop,
          'pubspec.lock': lockOf('1.0.0'),
          '.dart_tool/package_graph.json': graph,
        },
        head: {
          'test/shop.dart': shop,
          'pubspec.lock': lockOf('2.0.0'),
          '.dart_tool/package_graph.json': graph,
        },
      );

      expect(plan.toRun, ['test/shop.dart#Checkout']);
      expect(plan.because.keys.single, contains('pubspec.lock#used'));
    });

    // The harness wraps every scenario in its folder's config, and nothing
    // the scenario itself imports names it — so a package only the config
    // uses was invisible, and so was a change to the config's own source.
    test(
      'a bump to a package only the folder config imports replays it',
      () async {
        source.declared = ['test/shop.dart#Checkout'];
        source.config = 'test/flutter_test_config.dart';
        var config = "import 'package:used/used.dart';\n";

        var plan = await planWith(
          base: {
            'test/shop.dart': 'var a = 1;\n',
            'test/flutter_test_config.dart': config,
            'pubspec.lock': lockOf('1.0.0'),
            '.dart_tool/package_graph.json': graph,
          },
          head: {
            'test/shop.dart': 'var a = 1;\n',
            'test/flutter_test_config.dart': config,
            'pubspec.lock': lockOf('2.0.0'),
            '.dart_tool/package_graph.json': graph,
          },
        );

        expect(plan.toRun, ['test/shop.dart#Checkout']);
      },
    );

    test('a change to the folder config itself replays it', () async {
      source.declared = ['test/shop.dart#Checkout'];
      source.config = 'test/flutter_test_config.dart';

      var plan = await planWith(
        base: {
          'test/shop.dart': 'var a = 1;\n',
          'test/flutter_test_config.dart': 'var theme = 1;\n',
        },
        head: {
          'test/shop.dart': 'var a = 1;\n',
          'test/flutter_test_config.dart': 'var theme = 2;\n',
        },
      );

      expect(plan.toRun, ['test/shop.dart#Checkout']);
    });

    test('a bump nothing it reaches names still skips it', () async {
      source.declared = ['test/shop.dart#Checkout'];
      var shop = 'var a = 1;\n';

      var plan = await planWith(
        base: {
          'test/shop.dart': shop,
          'pubspec.lock': lockOf('1.0.0'),
          '.dart_tool/package_graph.json': graph,
        },
        head: {
          'test/shop.dart': shop,
          'pubspec.lock': lockOf('2.0.0'),
          '.dart_tool/package_graph.json': graph,
        },
      );

      expect(plan.toRun, isEmpty);
    });
  });

  // The fixed cost of this half is two harness builds and two boots, and it
  // used to be paid before a single closure had been hashed — so a branch that
  // touched no scenario paid all of it to be told there was nothing to do.
  // Measured 2026-09-09 on this repo: 60.5s of a 63s comparison.
  test('the run records its phases and the steps that never settled', () async {
    source.declared = ['test/a.dart#A', 'test/b.dart#B'];
    source.unsettled['test/a.dart#A:head'] = 3;
    var clock = PhaseClock();

    await ScenariosRunner(
      headRoot: checkout('head', {'test/a.dart': '2', 'test/b.dart': '2'}),
      baseRoot: checkout('base', {'test/a.dart': '1', 'test/b.dart': '1'}),
      source: source,
      cache: cache,
      locks: null,
      sdk: 'test-sdk',
      clock: clock.within('packages/notes', qualify: true),
    ).run(outDir: root.path);

    var timings = clock.timings;
    expect(timings.phases.map((phase) => phase.name), [
      'scenarios.plan',
      'scenarios.replay',
      'scenarios.compare',
      'scenarios.filing',
    ]);
    expect(timings.phases.map((phase) => phase.package).toSet(), {
      'packages/notes',
    });
    // Qualified the way the rows of a several-package comparison are, so the
    // count can be looked up by the id a reader has.
    expect(timings.unsettledSteps, {'packages/notes/test/a.dart#A': 3});
  });

  group('with jobs', () {
    Map<String, String> files(String value) => {
      for (var name in ['a', 'b', 'c', 'd']) 'test/$name.dart': value,
    };
    var declared = [
      for (var name in ['a', 'b', 'c', 'd'])
        'test/$name.dart#${name.toUpperCase()}',
    ];

    /// A replay that yields, so the ones beside it get to start.
    Future<void> yieldOnce(bool _) => Future<void>.delayed(Duration.zero);

    test('that many scenarios replay at once, both sides each', () async {
      source.declared = declared;
      source.gate = yieldOnce;

      await runnerFor(
        base: checkout('base', files('1')),
        head: checkout('head', files('2')),
        jobs: 2,
      ).run(outDir: root.path);

      var most = source.started.map((start) => start.$2).reduce(max);
      expect(most, 4);
      expect(source.replayed, hasLength(8));
    });

    // A failure beside other replays may be the machine being busy, which is
    // exactly what a confirmation rules out — so it is not asked there.
    test('a scenario that failed in the pool replays again alone', () async {
      source.declared = declared;
      source.gate = yieldOnce;
      source.flaky['test/b.dart#B:base'] = 1;

      var results = await runnerFor(
        base: checkout('base', files('1')),
        head: checkout('head', files('2')),
        jobs: 4,
      ).run(outDir: root.path);

      var tail = source.started.sublist(source.started.length - 2);
      expect(tail.map((start) => start.$1), [
        'test/b.dart#B:base',
        'test/b.dart#B:head',
      ]);
      expect(tail.map((start) => start.$2), everyElement(lessThanOrEqualTo(2)));
      expect(source.replayed, hasLength(10));
      // Judged from the replays taken alone, where it passed.
      var b = results.items.singleWhere((i) => i.scenario == 'test/b.dart#B');
      expect(b.compared, isTrue);
    });

    test('the verdict is the one a serial run reaches', () async {
      source.declared = declared;
      source.failOn = 'test/c.dart#C';
      source.pixels['test/a.dart#A:head'] = 7;
      source.gate = yieldOnce;
      var base = checkout('base', files('1'));
      var head = checkout('head', files('2'));

      List<(String, ComparedState)> verdict(ScenarioResults results) => [
        for (var item in results.items) (item.scenario, item.state),
      ];

      var serial = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);
      cache = ShotCache(p.join(root.path, 'pooled'));
      var pooled = await runnerFor(
        base: base,
        head: head,
        jobs: 3,
      ).run(outDir: root.path);

      expect(verdict(pooled), verdict(serial));
      // The scenario that failed and the one that changed are each replayed
      // again alone from the start.
      expect(pooled.replays, serial.replays + 4);
    });

    // Measured on a real suite: a watched query fed by real I/O fired earlier
    // on one side of a busy host, and the step's events changed order with
    // nothing else changing.
    test('a difference only the pool drew is replayed alone, and is not '
        'reported', () async {
      source.declared = declared;
      source.gate = yieldOnce;
      source.wobbly['test/b.dart#B:head'] = 1;

      var results = await runnerFor(
        base: checkout('base', files('1')),
        head: checkout('head', files('2')),
        jobs: 4,
      ).run(outDir: root.path);

      var tail = source.started.sublist(source.started.length - 2);
      expect(tail.map((start) => start.$1), [
        'test/b.dart#B:base',
        'test/b.dart#B:head',
      ]);
      expect(tail.map((start) => start.$2), everyElement(lessThanOrEqualTo(2)));
      expect(source.replayed, hasLength(10));
      expect(
        results.items.map((item) => item.state),
        everyElement(ComparedState.same),
      );
    });

    test('what differed only in the pool is recorded, and the alone replays '
        'are timed apart', () async {
      source.declared = declared;
      source.gate = yieldOnce;
      source.wobbly['test/b.dart#B:head'] = 1;
      source.pixels['test/c.dart#C:head'] = 7;
      source.flaky['test/d.dart#D:base'] = 1;
      var clock = PhaseClock();

      await ScenariosRunner(
        headRoot: checkout('head', files('2')),
        baseRoot: checkout('base', files('1')),
        source: source,
        cache: cache,
        locks: null,
        sdk: 'test-sdk',
        jobs: 4,
        clock: clock.within('packages/notes', qualify: true),
      ).run(outDir: root.path);

      var timings = clock.timings;
      // Not C, which changed alone too, nor D, which failed rather than
      // differed.
      expect(timings.pooledOnlyDifferences, ['packages/notes/test/b.dart#B']);
      expect(timings.phases.map((phase) => phase.name), [
        'scenarios.plan',
        'scenarios.replay',
        'scenarios.alone',
        'scenarios.compare',
        'scenarios.filing',
      ]);
    });

    test('a difference drawn in the pool is never filed', () async {
      source.declared = declared;
      source.gate = yieldOnce;
      source.wobbly['test/b.dart#B:head'] = 1;
      var base = checkout('base', files('1'));
      var head = checkout('head', files('2'));

      await runnerFor(base: base, head: head, jobs: 4).run(outDir: root.path);

      expect(
        source.replayed.where((side) => side.startsWith('test/b.dart#B')),
        hasLength(4),
        reason:
            'the alone replay replays both sides rather than reading the '
            "pool's back",
      );
    });
  });

  group('the scan gate', () {
    test('nothing to replay is answered without listing a harness', () async {
      source.scannedHead = ['test/shop.dart#Checkout'];
      source.scannedBase = ['test/shop.dart#Checkout'];
      var files = {'test/shop.dart': 'const flow = 1;'};

      var plan = await runnerFor(
        base: checkout('base', files),
        head: checkout('head', files),
      ).plan();

      expect(plan.toRun, isEmpty);
      expect(plan.settled.single.state, ComparedState.skipped);
      expect(source.listed, 0, reason: 'no harness should have been started');
    });

    test('something to replay falls through to the harness', () async {
      source.scannedHead = ['test/shop.dart#Checkout'];
      source.scannedBase = ['test/shop.dart#Checkout'];
      source.declared = ['test/shop.dart#Checkout'];

      var plan = await runnerFor(
        base: checkout('base', {'test/shop.dart': '1'}),
        head: checkout('head', {'test/shop.dart': '2'}),
      ).plan();

      expect(plan.toRun, ['test/shop.dart#Checkout']);
      expect(source.listed, 2, reason: 'both sides are listed live');
    });

    // The harness's listing is ground truth, and a fall-through takes it: the
    // scan cannot see `skip:` or a name that is built rather than written, and
    // by this point a harness is starting anyway.
    test('the fall-through plans from the listing, not the scan', () async {
      source.scannedHead = ['test/shop.dart#Checkout'];
      source.scannedBase = ['test/shop.dart#Checkout'];
      source.onHead = ['test/shop.dart#Checkout', 'test/late.dart#Generated'];
      source.onBase = ['test/shop.dart#Checkout'];

      var plan = await runnerFor(
        base: checkout('base', {'test/shop.dart': '1'}),
        head: checkout('head', {'test/shop.dart': '2', 'test/late.dart': '1'}),
      ).plan();

      expect(plan.toRun, ['test/shop.dart#Checkout']);
      expect(plan.settled.single.state, ComparedState.added);
    });

    test('a scan that cannot promise the whole set is not used', () async {
      source.scannedHead = null;
      source.scannedBase = ['test/shop.dart#Checkout'];
      source.declared = ['test/shop.dart#Checkout'];
      var files = {'test/shop.dart': 'const flow = 1;'};

      await runnerFor(
        base: checkout('base', files),
        head: checkout('head', files),
      ).plan();

      expect(source.listed, 2);
    });

    // Two empty listings are the absence of an answer, not an answer: a
    // package the scan sees no scenarios in is exactly where the harness's
    // refusal to build is the message the reader needs.
    test('two empty scans are not an answer', () async {
      source.scannedHead = const [];
      source.scannedBase = const [];

      await runnerFor(
        base: checkout('base', {'test/shop.dart': '1'}),
        head: checkout('head', {'test/shop.dart': '1'}),
      ).plan();

      expect(source.listed, 2);
    });
  });

  group('the run', () {
    test('a plan already made is not made again', () async {
      source.declared = ['test/shop.dart#Checkout'];
      var runner = runnerFor(
        base: checkout('base', {'test/shop.dart': '1'}),
        head: checkout('head', {'test/shop.dart': '2'}),
      );

      var plan = await runner.plan();
      source.listed = 0;
      var results = await runner.run(outDir: root.path, from: plan);

      expect(source.listed, 0);
      expect(results.ran, 1);
    });

    // A scenario is a process. Replaying the whole head side and then the
    // whole base side doubles the time before the first row can be answered.
    test('one scenario runs on both sides before the next starts', () async {
      source.declared = ['test/a.dart#A', 'test/b.dart#B'];

      await runnerFor(
        base: checkout('base', {'test/a.dart': '1', 'test/b.dart': '1'}),
        head: checkout('head', {'test/a.dart': '2', 'test/b.dart': '2'}),
      ).run(outDir: root.path);

      expect(source.replayed, [
        'test/a.dart#A:base',
        'test/a.dart#A:head',
        'test/b.dart#B:base',
        'test/b.dart#B:head',
      ]);
    });

    // Two harnesses on two checkouts, a build directory each, sharing nothing
    // but the machine — so there is nothing to serialize them for, and a
    // replay is where a comparison spends its time.
    test('the two sides of one scenario replay together', () async {
      source.declared = ['test/a.dart#A'];
      var bothIn = Completer<void>();
      // Neither side may answer until both have been asked. A sequential
      // replay never gets here: the second call is not made until the first
      // has returned, so this hangs rather than fails — which is why the
      // whole run is given a deadline.
      source.gate = (_) async {
        source.waiting++;
        if (source.waiting == 2) bothIn.complete();
        await bothIn.future;
      };

      await runnerFor(
        base: checkout('base', {'test/a.dart': '1'}),
        head: checkout('head', {'test/a.dart': '2'}),
      ).run(outDir: root.path).timeout(const Duration(seconds: 5));

      expect(source.waiting, 2);
    });

    test('rows arrive as they are decided, not all at the end', () async {
      source.declared = ['test/a.dart#A'];
      source.onHead = ['test/a.dart#A', 'test/new.dart#Fresh'];
      var seen = <String>[];

      await ScenariosRunner(
        headRoot: checkout('head', {'test/a.dart': '2'}),
        baseRoot: checkout('base', {'test/a.dart': '1'}),
        source: source,
        cache: cache,
        locks: null,
        sdk: 'test-sdk',
        onScenario: (s) => seen.add(s.scenario),
      ).run(outDir: root.path);

      expect(seen, ['test/new.dart#Fresh', 'test/a.dart#A']);
    });

    test('the results rank worst first and count what ran', () async {
      source.declared = ['test/a.dart#A', 'test/same.dart#Same'];
      source.failOn = 'test/a.dart#A';

      var results = await runnerFor(
        base: checkout('base', {'test/a.dart': '1', 'test/same.dart': 'x'}),
        head: checkout('head', {'test/a.dart': '2', 'test/same.dart': 'x'}),
      ).run(outDir: root.path);

      expect(results.items.first.state, ComparedState.broke);
      expect(results.ran, 1);
      expect(results.skipped, 1);
    });
  });

  // Measured on a consumer's second push with identical inputs: the previews
  // came from the store and every one of 135 scenarios replayed again on both
  // sides, 262s of a run with findings. A replay is a pure function of what
  // its key hashes, so it is filed like a picture.
  group('the store', () {
    late String base;
    late String head;

    setUp(() {
      source.scannedBase = ['test/shop.dart#Checkout'];
      source.scannedHead = ['test/shop.dart#Checkout'];
      source.declared = ['test/shop.dart#Checkout'];
      base = checkout('base', {'test/shop.dart': '1'});
      head = checkout('head', {'test/shop.dart': '2'});
    });

    test('a second run with the same inputs replays nothing', () async {
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source
        ..replayed.clear()
        ..listed = 0;

      var again = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      expect(source.replayed, isEmpty);
      expect(source.listed, 0, reason: 'no harness should have been started');
      expect(again.ran, 1);
      expect(again.replays, 0);
      expect(again.items.single.state, ComparedState.same);
    });

    test('a filed side is read back and only the other replays', () async {
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source.replayed.clear();
      File(p.join(head, 'test/shop.dart')).writeAsStringSync('3');

      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      expect(source.replayed, ['test/shop.dart#Checkout:head']);
      expect(results.replays, 1);
    });

    test('a filed frame points into the store', () async {
      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      var frames = results.items.single.frames.values.single;
      expect(p.isWithin(cache.root, frames.base!.path), isTrue);
      expect(File(frames.head!.path).existsSync(), isTrue);
    });

    test('a replay filed under another SDK is not served', () async {
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source.replayed.clear();

      await runnerFor(
        base: base,
        head: head,
        sdk: 'another-sdk',
      ).run(outDir: root.path);

      expect(source.replayed, hasLength(2));
    });

    test('a replay under other settings is not served', () async {
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source
        ..replayed.clear()
        ..settings = {'clock': '2030-01-01T00:00:00.000Z'};

      await runnerFor(base: base, head: head).run(outDir: root.path);

      expect(source.replayed, hasLength(2));
    });

    test('a replay whose requests went out is never filed', () async {
      source.events = [
        {
          'channel': 'network',
          'title': 'GET https://example.com/avatar.png',
          'data': {'answered': 'live'},
        },
      ];
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source.replayed.clear();

      await runnerFor(base: base, head: head).run(outDir: root.path);

      expect(source.replayed, hasLength(2));
    });

    test('a replay answered from the recording is filed', () async {
      source.events = [
        {
          'channel': 'network',
          'title': 'GET https://example.com/menu.json',
          'data': {'answered': 'replay'},
        },
      ];
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source.replayed.clear();

      await runnerFor(base: base, head: head).run(outDir: root.path);

      expect(source.replayed, isEmpty);
    });

    // Measured on this repository's own suite: two scenarios log their
    // requests through a fake client, and counting those as live kept them
    // replaying on every run.
    test("a request the app logged itself is not the network's", () async {
      source.events = [
        {
          'channel': 'network',
          'title': 'POST https://api.example.com/sessions',
          'detail': '200',
        },
      ];
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source.replayed.clear();

      await runnerFor(base: base, head: head).run(outDir: root.path);

      expect(source.replayed, isEmpty);
    });

    test('a replay the harness abandoned is never filed', () async {
      source.abandon = true;
      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);
      expect(
        results.items.single.state,
        ComparedState.failed,
        reason: 'both sides hang, twice each',
      );
      source.replayed.clear();

      await runnerFor(base: base, head: head).run(outDir: root.path);

      // Both sides, each replayed a second time to confirm.
      expect(source.replayed, hasLength(4));
    });

    // Measured on a consumer's merge request: a base replay that failed once
    // on a loaded host was filed, and the next comparison against the same
    // base served it again — the same "changed" row, byte-identical frames.
    test(
      'a failure that does not reproduce is not compared, nor filed',
      () async {
        source.flaky['test/shop.dart#Checkout:base'] = 1;

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        var scenario = results.items.single;
        expect(scenario.compared, isFalse);
        expect(scenario.state, ComparedState.skipped);
        expect(
          scenario.inconclusive,
          startsWith('The base failed once and passed when replayed again'),
        );
        expect(scenario.baseErrors, ['an error dialog was showing']);
        expect(source.replayed, [
          'test/shop.dart#Checkout:base',
          'test/shop.dart#Checkout:head',
          'test/shop.dart#Checkout:base',
        ]);
        expect(results.replays, 3);

        source.replayed.clear();
        await runnerFor(base: base, head: head).run(outDir: root.path);

        expect(source.replayed, ['test/shop.dart#Checkout:base']);
      },
    );

    test('a failure that reproduces is the verdict, and is filed', () async {
      source.failOn = 'test/shop.dart#Checkout';

      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      expect(results.items.single.state, ComparedState.broke);
      expect(source.replayed.last, 'test/shop.dart#Checkout:head');
      expect(source.replayed, hasLength(3));

      source.replayed.clear();
      var again = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      expect(source.replayed, isEmpty);
      expect(again.items.single.state, ComparedState.broke);
    });

    // A picture that depended on the real loop turning fast enough, and a
    // difference beside it: not believed until each side does it twice.
    test('a difference beside a guessed landing that does not reproduce is '
        'not compared, nor filed', () async {
      source
        ..guessed['test/shop.dart#Checkout:head'] = 9
        ..wobbly['test/shop.dart#Checkout:head'] = 1;

      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      var scenario = results.items.single;
      expect(scenario.compared, isFalse);
      expect(
        scenario.inconclusive,
        allOf(
          startsWith('This branch drew work nothing announced'),
          contains('`Open` (turn 9)'),
          contains('RealWork.run'),
        ),
      );
      expect(source.replayed, hasLength(4), reason: 'each side once more');

      source.replayed.clear();
      await runnerFor(base: base, head: head).run(outDir: root.path);
      expect(
        source.replayed,
        contains('test/shop.dart#Checkout:head'),
        reason: 'a replay with a guessed landing is never filed',
      );
    });

    test('a difference beside a guessed landing that reproduces is reported, '
        'and says so', () async {
      source
        ..guessed['test/shop.dart#Checkout:head'] = 9
        ..pixels['test/shop.dart#Checkout:head'] = 200;

      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      var scenario = results.items.single;
      expect(scenario.state, ComparedState.changed);
      expect(
        scenario.items.single.note,
        contains('drew work nothing announced on this branch (turn 9)'),
      );
    });

    // Two failing replays compared as steps say `failed` whatever they failed
    // on, so a reproduced regression never agreed with itself here and was
    // reported as not compared.
    test('a failure that reproduces beside a guessed landing is still the '
        'verdict', () async {
      source
        ..failOn = 'test/shop.dart#Checkout'
        ..guessed['test/shop.dart#Checkout:head'] = 9;

      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      expect(results.items.single.compared, isTrue);
      expect(results.items.single.state, ComparedState.broke);
    });

    group('events that only changed order', () {
      setUp(() {
        source.events = [
          {'channel': 'db', 'title': 'select count(*) from unread_messages'},
          {'channel': 'db', 'title': 'select * from orders'},
        ];
      });

      test('are the same when a side does not keep its order, and say '
          'so', () async {
        source.reversed['test/shop.dart#Checkout:head'] = 1;

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        var scenario = results.items.single;
        expect(scenario.state, ComparedState.same);
        expect(
          scenario.items.single.note,
          allOf(
            startsWith(
              'events changed order between two replays of this '
              'branch',
            ),
            contains('db select'),
          ),
        );
        expect(source.replayed, hasLength(4), reason: 'each side once more');
      });

      // An auth call now made after a data fetch, under FakeAsync: the code
      // moved it, and every replay says so.
      test('are a change when both sides keep their order', () async {
        source.reversed['test/shop.dart#Checkout:head'] = 99;

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        expect(results.items.single.state, ComparedState.changed);
        expect(results.items.single.items.single.note, isNull);
        expect(source.replayed, hasLength(4));
      });

      test('that hold are a change, beside ones that do not', () async {
        Map<String, Object?> event(String channel, String title) => {
          'channel': channel,
          'title': title,
        };
        var (auth, items) = (
          event('network', 'POST /auth'),
          event('network', 'GET /items'),
        );
        var (count, badge) = (
          event('db', 'select count(*) from unread_messages'),
          event('db', 'select * from badges'),
        );
        source
          ..events = [auth, items, count, badge]
          ..sequences['test/shop.dart#Checkout:head'] = [
            [items, auth, badge, count],
            [items, auth, count, badge],
          ];

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        expect(results.items.single.state, ComparedState.changed);
        expect(source.replayed, hasLength(4));
      });

      test('beside any other difference are a change, and replay nothing '
          'more', () async {
        source
          ..reversed['test/shop.dart#Checkout:head'] = 1
          ..pixels['test/shop.dart#Checkout:head'] = 7;

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        expect(results.items.single.state, ComparedState.changed);
        expect(source.replayed, hasLength(2));
      });

      test('are asked of a filed side too, whose order may be the load of the '
          'run that filed it', () async {
        source
          ..reversed['test/shop.dart#Checkout:base'] = 1
          ..reversed['test/shop.dart#Checkout:head'] = 1;
        await runnerFor(base: base, head: head).run(outDir: root.path);
        source.replayed.clear();
        File(p.join(head, 'test/shop.dart')).writeAsStringSync('3');

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        expect(results.items.single.state, ComparedState.same);
        expect(source.replayed, [
          'test/shop.dart#Checkout:head',
          'test/shop.dart#Checkout:base',
          'test/shop.dart#Checkout:head',
        ]);
      });
    });

    test('a guessed landing with nothing different costs nothing', () async {
      source.guessed['test/shop.dart#Checkout:head'] = 9;

      var results = await runnerFor(
        base: base,
        head: head,
      ).run(outDir: root.path);

      expect(results.items.single.state, ComparedState.same);
      expect(results.items.single.items.single.note, isNull);
      expect(source.replayed, hasLength(2));
    });

    test(
      'a replay abandoned once is compared from its second replay',
      () async {
        source.slow['test/shop.dart#Checkout:head'] = 1;

        var results = await runnerFor(
          base: base,
          head: head,
        ).run(outDir: root.path);

        expect(results.items.single.state, ComparedState.same);
        expect(source.replayed, hasLength(3));
      },
    );

    test('a filed replay whose frames were swept is replayed', () async {
      await runnerFor(base: base, head: head).run(outDir: root.path);
      source.replayed.clear();
      for (var file in Directory(cache.root).listSync(recursive: true)) {
        if (file is File && !file.path.endsWith('.json')) file.deleteSync();
      }

      await runnerFor(base: base, head: head).run(outDir: root.path);

      expect(source.replayed, hasLength(2));
    });

    // The recording is read at run time and imported by nothing, so it was
    // invisible to the skip rule: a re-recorded endpoint changed what the
    // scenario drew and the scenario was skipped.
    test('a changed network recording is not skipped', () async {
      var files = {'test/shop.dart': 'same'};
      var baseRoot = checkout('base_rec', {
        ...files,
        'test/scenarios/network/get_menu.json': '{"status": 200}',
      });
      var headRoot = checkout('head_rec', {
        ...files,
        'test/scenarios/network/get_menu.json': '{"status": 500}',
      });

      var plan = await ScenariosRunner(
        headRoot: headRoot,
        baseRoot: baseRoot,
        source: source,
        cache: cache,
        locks: null,
        sdk: 'test-sdk',
        pixels: PixelInputs.ofScenarios(
          packagePath: '.',
          roots: [headRoot, baseRoot],
        ),
      ).plan();

      expect(plan.toRun, ['test/shop.dart#Checkout']);
    });
  });
}

/// Two sides of scenarios with no processes behind them.
class _FakeSource implements ScenarioSource {
  /// What both sides declare, unless one of the two below overrides it.
  List<String> declared = const [];
  List<String>? onBase;
  List<String>? onHead;

  /// What the *sources* say, when they can say — null is a source the scan
  /// cannot promise the whole of, which is what every test that does not set
  /// this one gets, so the live listing stays the default path.
  List<String>? scannedBase;
  List<String>? scannedHead;
  var scanned = 0;

  /// The scenario whose head replay throws at its step.
  String? failOn;

  final replayed = <String>[];
  var listed = 0;

  /// Held open in the middle of a replay, so a test can prove two sides are
  /// in flight at once rather than infer it from an order.
  Future<void> Function(bool base)? gate;
  var waiting = 0;

  /// Replays under way right now, and how many were under way as each one
  /// started, in the order they started.
  var inFlight = 0;
  final started = <(String, int)>[];

  @override
  Future<List<String>> list({required bool base}) async {
    listed++;
    return (base ? onBase : onHead) ?? declared;
  }

  @override
  List<String>? scan({required bool base}) {
    scanned++;
    return base ? scannedBase : scannedHead;
  }

  @override
  String fileOf(String id) => id.split('#').first;

  /// The folder config every scenario is governed by, or null for none.
  String? config;

  @override
  String? configOf(String id, {required bool base}) => config;

  @override
  Map<String, String> settings = const {};

  /// The events every replayed step carries.
  List<Map<String, Object?>> events = const [];

  /// Whether the harness gives up on every scenario it replays.
  var abandon = false;

  /// Sides that fail this many more times and then pass, by `<id>:<side>` —
  /// a scenario whose outcome depends on the machine.
  final flaky = <String, int>{};

  /// Sides the harness gives up on this many more times, by `<id>:<side>`.
  final slow = <String, int>{};

  /// Sides whose step landed work by guessing, and on which turn, by
  /// `<id>:<side>`.
  final guessed = <String, int>{};

  /// Sides that draw a different picture this many more times, by
  /// `<id>:<side>` — a race a guessed landing sometimes loses.
  final wobbly = <String, int>{};

  /// Sides that log [events] in reverse this many more times, by
  /// `<id>:<side>` — a stream fed by real I/O firing earlier on a busy host.
  final reversed = <String, int>{};

  /// The events each successive replay of a side logs, by `<id>:<side>` —
  /// the last one for every replay after. Overrides [events].
  final sequences = <String, List<List<Map<String, Object?>>>>{};

  /// How many steps a side's replay says never settled, by `<id>:<side>`.
  final unsettled = <String, int>{};

  /// The pixel value a side draws, by `<id>:<side>`; 0 when not named.
  final pixels = <String, int>{};

  @override
  Future<ScenarioReplay> shots(
    String id, {
    required bool base,
    required String outDir,
  }) async {
    var side = '$id:${base ? 'base' : 'head'}';
    replayed.add(side);
    started.add((side, ++inFlight));
    try {
      await gate?.call(base);
    } finally {
      inFlight--;
    }
    bool spend(Map<String, int> counts) {
      var left = counts[side] ?? 0;
      if (left == 0) return false;
      counts[side] = left - 1;
      return true;
    }

    var flakes = spend(flaky);
    var abandoned = abandon || spend(slow);
    var value = spend(wobbly) ? 99 : pixels[side] ?? 0;
    var failure = !base && id == failOn
        ? 'nothing matches "Pay"'
        : flakes
        ? 'an error dialog was showing'
        : abandoned
        ? 'did not finish within 30s'
        : null;
    return ScenarioReplay(
      [
        ScenarioStepShot(
          step: const AlignableStep(index: 1, position: '#1', name: 'Open'),
          rgba: Uint8List(4 * 4 * 4)..fillRange(0, 4 * 4 * 4, value),
          width: 4,
          height: 4,
          events: switch (sequences[side]) {
            var sequence? when sequence.isNotEmpty =>
              sequence.length == 1 ? sequence.single : sequence.removeAt(0),
            _ => spend(reversed) ? events.reversed.toList() : events,
          },
          failure: failure,
          guessed: guessed[side],
        ),
      ],
      complete: !abandoned,
      unsettled: unsettled[side] ?? 0,
    );
  }

  @override
  Future<void> dispose() async {}
}
