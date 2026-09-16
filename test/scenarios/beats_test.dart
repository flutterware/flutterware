import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/app_events/events.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The beats of a flow that are not screens: what the run produced, and what
/// its backend pushed.
///
/// Both are steps — positioned, parented, carrying the events that led to
/// them — and neither has a frame, which is what makes them their own kind
/// rather than a file bolted onto somebody else's step.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
    appEventBuffer = AppEventBuffer();
  });
  tearDown(() {
    scenarioRunListener = null;
    appEventBuffer = null;
  });

  List<String> shape() => [
    for (var capture in captures)
      switch (capture.kind) {
        ScenarioCaptureKind.screen => capture.name ?? '${capture.verb}',
        ScenarioCaptureKind.document => 'document ${capture.name}',
        ScenarioCaptureKind.notification => 'notification',
        ScenarioCaptureKind.setup => 'setup ${capture.name}',
      },
  ];

  group('a document is a step of its own', () {
    scenario('in the place the flow produced it', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Export');
      await s.document(
        'receipt',
        [1, 2, 3],
        fileName: 'receipt.json',
        mimeType: 'application/json',
      );
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'tap', 'document receipt']);
      var beat = captures.last;
      // No frame at all: nothing rendered, so nothing was paid for a render.
      expect(beat.bytes, isNull);
      expect(beat.payload, hasLength(3));
      expect(beat.mimeType, 'application/json');
      // Its own index in the run, chained onto the step before it — which is
      // what lets a comparison align it by name like any other step.
      expect(beat.parent, captures[1].index);
    });
  });

  group('a notification is a step of its own', () {
    scenario('carrying the push rather than a picture of one', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Export');
      await s.notification('Receipt ready', title: 'Receipts');
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'tap', 'notification']);
      var beat = captures.last;
      expect(beat.bytes, isNull);
      expect(beat.notification?.body, 'Receipt ready');
      expect(beat.notification?.title, 'Receipts');
      // Deliberately unnamed: the words are the app's own user-facing text, so
      // they are translated and reworded, and a comparison keyed on them would
      // read one flow under two languages as two different flows.
      expect(beat.name, isNull);
    });
  });

  group('a beat draws nothing', () {
    scenario('so a screen after it still names the frame before it', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Export');
      await s.document('receipt', [1]);
      await s.screen('Exported');
    });
    // Three steps: the `screen` names the tap's picture rather than taking a
    // second one, because the document between them moved nothing.
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Exported', 'document receipt']);
      expect(captures[1].verb, 'tap');
    });
  });

  group('the chain stays linear across a beat', () {
    scenario('so nothing forks where the flow did not', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Export');
      await s.document('receipt', [1]);
      await s.screen('Exported');
      await s.tap('Export');
    });
    // The adopted `screen` records the chain's *head* — the document — as what
    // the next step follows. Recording the step its name landed on instead
    // would give one node two children with no branch between them, and a
    // walk over the flow would follow only one of them.
    tearDown(() {
      var parents = [for (var capture in captures) capture.parent];
      expect(parents, [null, 1, 2, 3]);
      expect(shape(), ['pumpWidget', 'Exported', 'document receipt', 'tap']);
    });
  });

  group('events land on the beat they led to', () {
    scenario('like they do on any other step', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Export');
      recordAppEvent(
        AppEvent.request(method: 'GET', url: '/receipt', status: 200),
      );
      await s.document('receipt', [1]);
    });
    tearDown(() {
      expect(
        [for (var event in captures.last.events) event.title],
        ['GET /receipt'],
      );
    });
  });

  group('a beat on a shared prefix', () {
    scenario('is emitted once, not once per branch', (s) async {
      await s.pumpWidget(const _App());
      await s.document('receipt', [1]);
      await s.split({
        'left': () => s.screen('Left'),
        'right': () => s.screen('Right'),
      });
    });
    tearDown(
      () =>
          expect(shape(), ['pumpWidget', 'document receipt', 'Left', 'Right']),
    );
  });
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: TextButton(onPressed: () {}, child: const Text('Export')),
      ),
    ),
  );
}
