import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/real_work/tracker.dart';
import 'package:flutterware/src/scenarios/progress.dart';
import 'package:flutterware/src/scenarios/stall.dart';

/// The sentence a scenario gets for running out its deadline: it names the
/// verb the body was inside and the line that called it, says which of the
/// two mechanisms it was from the fake zone's queue, and lists what went out
/// and never came back. Composed from facts, so the composition is tested
/// without wedging anything.
void main() {
  tearDown(resetStallFacts);

  test('app frames survive the filter and the framework does not', () {
    var trace = StackTrace.fromString('''
#0      ScenarioTester._step (package:flutterware/src/scenarios/scenario.dart:1740:5)
#1      ScenarioTester.tap (package:flutterware/src/scenarios/scenario.dart:1014:44)
#2      Scene._loadModel (package:scene_kit/src/scene.dart:88:12)
#3      Scene.initializeStaticResources (package:scene_kit/src/scene.dart:41:7)
#4      main.<anonymous closure> (file:///Users/someone/app/test/scenarios/shop_test.dart:20:9)
#5      _AsyncCompleter.complete (dart:async/future_impl.dart:50:3)
''');
    expect(appFrames(trace), [
      'Scene._loadModel (package:scene_kit/src/scene.dart:88)',
      'Scene.initializeStaticResources (package:scene_kit/src/scene.dart:41)',
      'main.<anonymous closure> (test/scenarios/shop_test.dart:20)',
    ]);
    expect(appFrames(trace, max: 1), hasLength(1));
  });

  test('a queued microtask names the pump nobody ran', () {
    var message = stallDiagnosis(
      deadline: const Duration(seconds: 30),
      microtasks: 2,
      inFlight: ScenarioVerbInFlight(
        'pumpWidget',
        'SceneApp',
        StackTrace.fromString(
          '#0      main.<anonymous closure> (file:///x/test/scenarios/a_test.dart:12:5)\n',
        ),
      ),
    );
    expect(message, contains('made no progress for 30s'));
    expect(message, contains('waiting rather than working'));
    expect(message, contains('inside `s.pumpWidget SceneApp`'));
    expect(message, contains('called from test/scenarios/a_test.dart:12'));
    expect(message, contains('2 microtasks are queued'));
    expect(message, contains('RealWork.track'));
    expect(message, contains('await s.tester.pump()'));
  });

  test('an empty queue blames a dead zone and names the previous scenario', () {
    var message = stallDiagnosis(
      deadline: const Duration(seconds: 30),
      microtasks: 0,
      lastVerb: ScenarioVerbInFlight('tap', '"Import"', StackTrace.empty),
      previousScenario: 'Splash',
    );
    expect(message, contains('between verbs: `s.tap "Import"`'));
    expect(message, contains('Nothing is queued in the fake zone'));
    expect(message, contains('`Splash` ran before this one'));
    expect(message, contains('--file=<earlier>,<this>'));
  });

  test("the runAsync watchdog's finding is quoted whole and nothing added", () {
    var message = stallDiagnosis(
      deadline: const Duration(seconds: 30),
      watchdog: 'the watchdog said so.',
      microtasks: 3,
    );
    expect(message, contains('the watchdog said so.'));
    expect(message, isNot(contains('microtask')));
  });

  test('unanswered sends and tracked work ride along with their frames', () {
    // What the harness does as a scenario begins, and what makes a tracked
    // future remember where and when it was announced.
    resetTrackedRealWork();
    var token = recordPendingSend('flutter/assets assets/model.glb');
    var answered = recordPendingSend('some/plugin ping');
    sendAnswered(answered);
    var completer = Completer<void>();
    RealWork.track(completer.future, label: 'scene model');
    var message = stallDiagnosis(
      deadline: const Duration(seconds: 30),
      microtasks: 0,
      sends: pendingSends,
      tracked: RealWork.pendingWork,
      pendingImages: 1,
      eventsOnFailedStep: true,
    );
    expect(
      message,
      contains('never seen answered: flutter/assets assets/model.glb'),
    );
    expect(message, isNot(contains('some/plugin ping')));
    expect(
      message,
      contains('Tracked real work still pending: `scene model` (for '),
    );
    expect(message, contains('1 image decode still pending'));
    expect(message, contains('on the failed step'));
    sendAnswered(token);
    resetTrackedRealWork();
    completer.complete();
  });

  // A consumer's GLB import on a CPU-starved host was called "not slowness"
  // and blamed on an earlier scenario's zone. Pending tracked work is a
  // landing polling the real clock, not a dead zone.
  test(
    'tracked work past its ceiling is named first, and not as a dead zone',
    () {
      var model = TrackedRealWork('3D model', null);
      var message = stallDiagnosis(
        deadline: const Duration(seconds: 30),
        kind: ScenarioStallKind.trackedWork,
        elapsed: const Duration(minutes: 2, seconds: 3),
        overdue: model,
        landingTracked: true,
        microtasks: 0,
        inFlight: ScenarioVerbInFlight('tap', '"3D"', StackTrace.empty),
        tracked: [model],
      );

      expect(
        message,
        startsWith(
          'tracked real work `3D model` was still pending after 2m 3s',
        ),
      );
      expect(message, contains('`s.tap "3D"` was waiting for it'));
      expect(message, contains('RealWork.run'));
      expect(message, isNot(contains('not slowness')));
      expect(message, isNot(contains('Nothing is queued in the fake zone')));
      expect(message, isNot(contains('give it longer')));
    },
  );

  test('a body looping without end is told so', () {
    var message = stallDiagnosis(
      deadline: const Duration(seconds: 30),
      kind: ScenarioStallKind.ceiling,
      elapsed: const Duration(minutes: 5),
      microtasks: 0,
    );

    expect(message, contains('still running after 5m'));
    expect(message, contains('never went 30s without progress'));
    expect(message, isNot(contains('Nothing is queued')));
  });

  test('a span reads as a sentence reads it', () {
    expect(spanOf(const Duration(milliseconds: 400)), '400ms');
    expect(spanOf(const Duration(seconds: 2)), '2s');
    expect(spanOf(const Duration(milliseconds: 27400)), '27.4s');
    expect(spanOf(const Duration(minutes: 2)), '2m');
  });

  test('the pending sends are bounded and forgotten per scenario', () {
    for (var i = 0; i < 100; i++) {
      recordPendingSend('channel $i');
    }
    expect(pendingSends.length, 64);
    expect(pendingSends.first.title, 'channel 36');
    resetStallFacts();
    expect(pendingSends, isEmpty);
  });
}
