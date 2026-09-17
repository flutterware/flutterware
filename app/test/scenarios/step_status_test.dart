import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_results.dart';
import 'package:flutterware_app/src/scenarios/step_status.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// What a step says about itself: the label the flow and the page share, and
/// the notice a step carries when it failed or never stopped animating.
void main() {
  ScenarioRunStep step({
    String? name,
    String? verb,
    String? target,
    bool settled = true,
    bool waited = true,
    int strayFrames = 0,
    String? failure,
    List<String> stillTicking = const [],
  }) => ScenarioRunStep(
    index: 1,
    position: '#1',
    auto: name == null,
    name: name,
    verb: verb,
    target: target,
    image: 'none.png',
    format: 'png',
    width: 1,
    height: 1,
    tree: 'none.json',
    root: '/none',
    texts: const [],
    address: 'fw://none',
    settled: settled,
    waited: waited,
    strayFrames: strayFrames,
    failure: failure,
    stillTicking: stillTicking,
  );

  Future<void> pump(WidgetTester tester, ScenarioRunStep subject) =>
      tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(body: ScenarioStepNotice(subject)),
        ),
      );

  test('the label names the shot, the automatic step, and the failure', () {
    expect(scenarioStepLabel(step(name: 'Cart')), 'Cart');
    expect(scenarioStepLabel(step(verb: 'tap', target: '#pay')), 'tap #pay');
    expect(scenarioStepLabel(step(name: 'Cart', failure: 'boom')), 'failed');
  });

  test('a shot outranks the verb that took it', () {
    expect(scenarioStepLabel(step(name: 'Cart', verb: 'tap')), 'Cart');
  });

  test('a step from before actions existed still names itself', () {
    expect(scenarioStepLabel(step()), 'step');
  });

  testWidgets('a healthy step says nothing at all', (tester) async {
    await pump(tester, step(name: 'Cart'));

    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('a failed step shows the error it broke on', (tester) async {
    await pump(
      tester,
      step(failure: 'in split branch "by card": nothing matches "Pay now"'),
    );

    expect(find.textContaining('nothing matches "Pay now"'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('an unsettled step explains the moving picture', (tester) async {
    await pump(tester, step(name: 'Loading', settled: false));

    expect(find.textContaining('Still animating'), findsOneWidget);
  });

  testWidgets('an unsettled step names what kept ticking', (tester) async {
    await pump(
      tester,
      step(
        name: 'Orders',
        settled: false,
        stillTicking: [
          'CircularProgressIndicator (lib/src/orders/status_cell.dart:42)',
          '_PulseState.initState (package:app/src/pulse.dart:18)',
        ],
      ),
    );

    expect(
      find.textContaining(
        'Still ticking:\n'
        '• CircularProgressIndicator (lib/src/orders/status_cell.dart:42)\n'
        '• _PulseState.initState (package:app/src/pulse.dart:18)',
      ),
      findsOneWidget,
    );
    // The generic guess is for a step that could not say.
    expect(find.textContaining('A spinner or a looping'), findsNothing);
    expect(find.textContaining('wrap it in `Ambient`'), findsOneWidget);
  });

  testWidgets('a picture parked on purpose is not a warning', (tester) async {
    await pump(tester, step(name: 'Loading', settled: false, waited: false));

    expect(find.textContaining('Parked mid-flight'), findsOneWidget);
    expect(find.textContaining('budget ran out'), findsNothing);
  });

  testWidgets('and it is the quietest note a step can carry', (tester) async {
    // A parked capture is what the author asked for, so anything else the
    // step has to say outranks it.
    await pump(
      tester,
      step(name: 'Loading', settled: false, waited: false, strayFrames: 2),
    );

    expect(find.textContaining('2 frames were drawn'), findsOneWidget);
    expect(find.textContaining('Parked mid-flight'), findsNothing);
  });

  testWidgets('a step says when the flow has a gap in it', (tester) async {
    await pump(tester, step(name: 'Cart', strayFrames: 3));

    expect(find.textContaining('3 frames were drawn'), findsOneWidget);
  });

  testWidgets('a failure outranks a settle note', (tester) async {
    await pump(tester, step(settled: false, failure: 'boom'));

    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.textContaining('Still animating'), findsNothing);
  });
}
