import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/clock.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The authoring API, asserted from inside the scenarios themselves: the
/// listener the runner installs is installed here instead, so every assertion
/// reads the same captures the panel would.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  scenario('a verb survives a screen that never settles', (s) async {
    await s.pumpWidget(const _SpinnerApp());
    // The measured trap: this threw `pumpAndSettle timed out` before the
    // settle policy, on nothing worse than a spinner being on screen.
    await s.tap('Add');

    expect(find.text('Count: 1'), findsOneWidget);
    expect(captures.last.settled, isFalse);
  });

  // The runner's axes, through the same seam it sets them: the assignment the
  // request named has to reach the body, because a consumer base class keys
  // its locale off `s.assignment?.language` — and under the runner that used
  // to be null, so every `--language=nl` run silently ran in the default
  // language while `FW_LANGUAGES=nl` under `flutter test` did not.
  group("with the runner's assignment", () {
    setUp(
      () => scenarioRunArgs = const ScenarioRunArgs(
        locale: Locale('nl'),
        assignment: ScenarioAssignment(language: 'nl'),
      ),
    );
    tearDown(() => scenarioRunArgs = null);

    scenario('the body reads the language the request named', (s) async {
      expect(s.assignment?.language, 'nl');
    });
  });

  // The clock knob, through the same seam the runner sets: pinned at the
  // origin, and still advancing with FakeAsync — a `wait` moves it.
  group('with a pinned clock', () {
    setUp(
      () => scenarioRunArgs = ScenarioRunArgs(
        clockOrigin: DateTime.utc(2026, 1, 1, 9),
      ),
    );
    tearDown(() => scenarioRunArgs = null);

    scenario('starts where the host said, and ticks from there', (s) async {
      var origin = DateTime.utc(2026, 1, 1, 9);
      expect(clock.now(), origin);

      await s.pumpWidget(const _StillApp());
      var mounted = clock.now();
      // Pumping moves it, because the clock is still FakeAsync's — pinning
      // the origin is not freezing time.
      expect(mounted.isAfter(origin), isTrue);

      await s.wait(const Duration(days: 1), settle: Settle.none);
      expect(clock.now().difference(mounted), const Duration(days: 1));
      // And it is not the wall clock, which no amount of FakeAsync moves.
      expect(DateTime.now().difference(clock.now()).abs().inDays, isNot(0));
    });
  });

  // The default, which is the whole of the policy: nobody asked for a clock
  // here, and the scenario still runs at a date rather than at whenever the
  // suite happened to run. A wall-clock default meant no two runs of a suite
  // were comparable, and every consumer that noticed pinned it again by hand.
  scenario('with nobody asking, the clock is the shared pin', (s) async {
    expect(clock.now(), pinnedClockOrigin);

    await s.pumpWidget(const _StillApp());
    await s.wait(const Duration(days: 1), settle: Settle.none);
    // Pinned is not frozen: FakeAsync still moves it, from a date that is the
    // same on every run.
    expect(
      clock.now().difference(pinnedClockOrigin),
      greaterThanOrEqualTo(const Duration(days: 1)),
    );
  });

  scenario('a still screen settles', (s) async {
    await s.pumpWidget(const _StillApp());
    await s.tap('Add');

    expect(captures.every((c) => c.settled), isTrue);
  });

  group("a per-call policy overrides the scenario's", () {
    scenario('on the verb that names one', (s) async {
      await s.pumpWidget(const _StillApp(), settle: Settle.none);
      await s.tap('Add', settle: const Settle.frames(1));
    }, settle: Settle.full);
    tearDown(() => expect(captures, hasLength(2)));
  });

  // `skip`, `tags` and `timeout` are `testWidgets`'s own, passed straight
  // through — the last dent in the superset. The flutterware runner honours
  // `skip` too: the walk answers it without loading the body
  // (`runner_test.dart` pins that), so this file reads the same on both
  // lanes.
  scenario('a skipped scenario never runs its body', (s) async {
    fail('the body of a skipped scenario ran');
  }, skip: true);

  scenario('an ambiguous target says how to narrow it', (s) async {
    await s.pumpWidget(const _TwiceApp());

    await expectLater(
      () => s.tap('Same'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('2 widgets match "Same"'),
            contains('`s.tap` needs one'),
            contains('Key'),
          ),
        ),
      ),
    );
  });

  scenario('a target that matches nothing lists what is on screen', (s) async {
    await s.pumpWidget(const _StillApp());

    await expectLater(
      () => s.tap('Subscribe'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('nothing matches "Subscribe"'),
            contains('Visible text: "Count: 0", "Add"'),
          ),
        ),
      ),
    );
  });

  scenario('a failing verb captures the frame it broke on', (s) async {
    await s.pumpWidget(const _StillApp());
    await expectLater(() => s.tap('Subscribe'), throwsA(anything));

    var failed = captures.last;
    expect(failed.failure, contains('nothing matches "Subscribe"'));
    expect(failed.name, isNull);
    expect(failed.bytes, isNotEmpty);
    // The frame is the state at the failure, not a blank: the app is still up.
    expect(failed.texts, contains('Count: 0'));
  });

  scenario('a failure names the split branch that reached it', (s) async {
    await s.pumpWidget(const _StillApp());

    await expectLater(
      () => s.split({
        'checkout': () async =>
            s.split({'by card': () async => throw StateError('boom')}),
      }),
      throwsA(
        isA<ScenarioFailure>()
            .having((e) => e.path, 'path', 'checkout › by card')
            .having((e) => '$e', 'message', contains('boom')),
      ),
    );
  });

  scenario('a failure inside a branch is captured once', (s) async {
    await s.pumpWidget(const _StillApp());
    await expectLater(
      () => s.split({'checkout': () async => s.tap('Subscribe')}),
      throwsA(isA<ScenarioFailure>()),
    );

    expect(captures.where((c) => c.failure != null), hasLength(1));
    expect(captures.last.failure, contains('in split branch "checkout"'));
  });

  // The replays of one scenario share a capture list, but only the test that
  // follows sees all of them — the last replay is still running when the body
  // ends for the last time.
  var branched = <ScenarioStepCapture>[];
  scenario('every branch runs, and the shared prefix is captured once', (
    s,
  ) async {
    await s.pumpWidget(const _StillApp(), shot: Shot('Start'));
    await s.split({
      'once': () async => s.screen('A'),
      'twice': () async => s.screen('B'),
    });
    branched = captures;
  });

  test('the split above captured its prefix once and both branches', () {
    expect(branched.map((c) => c.name), ['Start', 'A', 'B']);
    expect(branched[1].branch, 'once');
    expect(branched[2].branch, 'twice');
    // Both branches hang off the shared first step.
    expect(branched[1].parent, branched[0].index);
    expect(branched[2].parent, branched[0].index);
  });

  // A consumer's timeout while the next branch's replay re-mounted the app
  // was filed as a child of the previous branch's last step: that branch grew
  // a step its source does not contain, and the branch that never ran was
  // missing from both sides with no delta. A break on a later replay's shared
  // prefix belongs to the branch that replay was heading into.
  var broken = <ScenarioStepCapture>[];
  var replays = 0;
  scenario('a break on a later replay of the shared prefix wears the next '
      'branch', (s) async {
    replays++;
    await s.pumpWidget(const _StillApp(), shot: Shot('Start'));
    if (replays == 2) {
      await expectLater(() => s.tap('Subscribe'), throwsA(anything));
    }
    await s.split({
      'once': () async => s.screen('A'),
      'twice': () async => s.screen('B'),
    });
    broken = captures;
  });

  test('the break above hangs off the fork, as the second branch', () {
    var start = broken.firstWhere((c) => c.name == 'Start');
    var failed = broken.singleWhere((c) => c.failure != null);
    expect(failed.branch, 'twice');
    expect(failed.parent, start.index);
    expect(failed.position, '1#1');
    expect(broken.firstWhere((c) => c.name == 'A').branch, 'once');
  });
}

class _StillApp extends StatefulWidget {
  const _StillApp();

  @override
  State<_StillApp> createState() => _StillAppState();
}

class _StillAppState extends State<_StillApp> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Text('Count: $_count'),
          TextButton(
            onPressed: () => setState(() => _count++),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

/// The same app with a spinner parked on it — nothing about the button
/// changes, but every frame schedules the next one.
class _SpinnerApp extends StatefulWidget {
  const _SpinnerApp();

  @override
  State<_SpinnerApp> createState() => _SpinnerAppState();
}

class _SpinnerAppState extends State<_SpinnerApp> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Text('Count: $_count'),
          const CircularProgressIndicator(),
          TextButton(
            onPressed: () => setState(() => _count++),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

class _TwiceApp extends StatelessWidget {
  const _TwiceApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Column(children: [Text('Same'), Text('Same')])),
  );
}
