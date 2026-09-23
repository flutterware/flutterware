import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/notification.dart';
import 'package:flutterware_app/src/scenarios/aim_overlay.dart';
import 'package:flutterware_app/src/scenarios/beat_view.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_results.dart';
import 'package:flutterware_app/src/scenarios/artifacts.dart';
import 'package:flutterware_app/src/scenarios/motion_player.dart';
import 'package:flutterware_app/src/scenarios/step_links.dart';
import 'package:flutterware_app/src/scenarios/step_page.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// Walking a run one step at a time.
///
/// Two things the step page owes a reader pressing next: every branch a
/// `split` opened is offered rather than just the first, and the transition
/// into the step they land on plays — so next, next, next is the app running
/// rather than a slideshow.
void main() {
  tearDown(scenarioMotionResidency.clear);

  /// A step of [frames] recorded frames, 1×1 so a whole recording decodes in
  /// no time — the residency counts pixels and these are worth four bytes.
  ScenarioRunStep step(
    int index, {
    int? parent,
    String? branch,
    String? name,
    String? verb,
    ScenarioAim? aim,
    int frames = 4,
  }) => ScenarioRunStep(
    index: index,
    position: '#$index',
    parent: parent,
    branch: branch,
    name: name,
    auto: name == null,
    image: 'run/$index.raw',
    format: 'raw',
    width: 1,
    height: 1,
    texts: const [],
    address: 'fw://wt/p/$index',
    verb: verb,
    aim: aim,
    frames: 'run/$index.frames',
    frameCount: frames,
    frameWidth: 1,
    frameHeight: 1,
    frameIntervalMs: 33,
  );

  group('the graph a reader walks', () {
    test('offers every branch a split opened, in the order it declared them', () {
      var steps = [
        step(1),
        step(2, parent: 1, branch: 'guest', name: 'Guest cart'),
        step(3, parent: 1, branch: 'member', name: 'Member cart'),
        step(4, parent: 2),
      ];

      var (previous, nexts) = scenarioNeighbours(steps, steps.first);
      expect(previous, isNull, reason: 'the first step has no parent');
      expect(nexts.map((s) => s.branch), ['guest', 'member']);

      // Inside a branch the links stay on the branch: step 2's next is its own
      // child, and its previous is the split it came out of.
      var (parent, inBranch) = scenarioNeighbours(steps, steps[1]);
      expect(parent?.index, 1);
      expect(inBranch.map((s) => s.index), [4]);

      // The branch that captured nothing after it is a dead end, not step 4.
      expect(scenarioNeighbours(steps, steps[2]).$2, isEmpty);
    });

    test('falls back to list order for artifacts that recorded no parents', () {
      var steps = [step(1), step(2), step(3)];
      var (previous, nexts) = scenarioNeighbours(steps, steps[1]);
      expect(previous?.index, 1);
      expect(nexts.map((s) => s.index), [3]);
      expect(scenarioNeighbours(steps, steps.last).$2, isEmpty);
    });
  });

  testWidgets("stacks a split's branches, each under its own label", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var steps = [
      step(1),
      step(2, parent: 1, branch: 'guest', name: 'Cart'),
      step(3, parent: 1, branch: 'member', name: 'Cart'),
    ];
    var opened = <int>[];
    await tester.pumpWidget(
      _harness(
        steps: steps,
        step: steps.first,
        onOpenStep: (s) => opened.add(s.index),
      ),
    );

    // Both branches are on offer, and told apart by their labels — the step
    // names are the same word.
    expect(find.text('guest'), findsOneWidget);
    expect(find.text('member'), findsOneWidget);
    expect(find.text('2 · Cart'), findsOneWidget);
    expect(find.text('3 · Cart'), findsOneWidget);

    // Stacked, not overlapping, and in the order the split declared them.
    var guest = tester.getRect(find.text('2 · Cart'));
    var member = tester.getRect(find.text('3 · Cart'));
    expect(guest.bottom, lessThan(member.top));

    await tester.tap(find.text('3 · Cart'));
    expect(opened, [3], reason: 'the branch tapped is the one opened');
  });

  // A step is named by whatever named it, and an auto-derived name is as long
  // as the verb and target it came from. Unbounded, the link grew to fit
  // rather than the label shrinking: one ran the width of the page and pushed
  // the other off the far side of it.
  testWidgets('a long label shrinks the label, not the page', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var long =
        'enterText widget with type "TextField" that are descendants of '
        "widget with key [<'a-long-and-particular-key-name'>] "
        '(ignoring all but first)';
    var steps = [
      step(1, name: long),
      step(2, parent: 1, name: long),
      step(3, parent: 2, name: long),
    ];
    await tester.pumpWidget(_harness(steps: steps, step: steps[1]));

    var back = tester.getRect(find.textContaining('1 · enterText'));
    var next = tester.getRect(find.textContaining('3 · enterText'));

    // Each stays on its own side of the page, and inside it.
    expect(back.left, greaterThanOrEqualTo(0));
    expect(next.right, lessThanOrEqualTo(1200));
    expect(
      back.right,
      lessThanOrEqualTo(next.left),
      reason: 'a link may not run under the one facing it',
    );
    // Truncated rather than wrapped: a link is one line high.
    expect(back.height, lessThan(40));
  });

  testWidgets('the whole label stays one hover away', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var steps = [step(1), step(2, parent: 1, name: 'Cart')];
    await tester.pumpWidget(_harness(steps: steps, step: steps.first));

    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: find.text('2 · Cart'),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      '2 · Cart',
    );
  });

  testWidgets('a lone next carries no branch label', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var steps = [step(1), step(2, parent: 1, branch: 'guest', name: 'Cart')];
    await tester.pumpWidget(_harness(steps: steps, step: steps.first));

    expect(find.text('2 · Cart'), findsOneWidget);
    expect(
      find.text('guest'),
      findsNothing,
      reason: 'there is no sibling branch to tell it apart from',
    );
  });

  testWidgets('plays the transition into a step walked forward into', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var steps = [step(1), step(2, parent: 1, name: 'Cart'), step(3, parent: 2)];
    // What sitting on step 1 does for itself: the page warms the step it
    // leads to before the press. Done here by hand — a decode needs a zone the
    // test binding does not fake time in, and the page's own warm is a
    // post-frame callback inside one.
    await _warm(tester, [steps.first, steps[1]]);

    // Opened cold, on the still: the transport offers play, not pause.
    await tester.pumpWidget(_harness(steps: steps, step: steps.first));
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsNothing);

    // Pressing next: the transition into step 2 runs on arrival.
    await tester.pumpWidget(_harness(steps: steps, step: steps[1], from: 1));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // And walking back does not — the frames on step 1 are its own arrival,
    // not a rewind of the one just watched.
    await tester.pumpWidget(_harness(steps: steps, step: steps.first, from: 2));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('a recording that is not decoded yet rests rather than '
      'flickering', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Nothing warmed: a split's branches are one recording each and the page
    // warms none of them, so the first press of either lands on the still.
    var steps = [
      step(1),
      step(2, parent: 1, branch: 'guest'),
      step(3, parent: 1, branch: 'member'),
    ];
    expect(scenarioMotionResidency.isWarm(steps[1]), isFalse);

    await tester.pumpWidget(_harness(steps: steps, step: steps.first));
    await tester.pumpWidget(_harness(steps: steps, step: steps[1], from: 1));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('a beat is walked through, not backed out of', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // A push in the middle of a flow: a step like any other, and one a walk
    // used to stop dead on.
    var beat = ScenarioRunStep(
      index: 2,
      position: '#2',
      parent: 1,
      name: 'Order ready',
      auto: false,
      kind: ScenarioStepKind.notification,
      notification: ScenarioNotification(body: 'Your cappuccino is ready'),
      texts: const [],
      address: 'fw://wt/p/2',
    );
    var steps = [step(1, name: 'Cart'), beat, step(3, parent: 2, name: 'Menu')];
    var opened = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ScenarioArtifactsScope(
            artifacts: const _Pixels(),
            child: ScenarioBeatPage(
              steps: steps,
              step: beat,
              background: steps.first,
              device: null,
              onBack: () {},
              onOpenStep: (s) => opened.add(s.index),
              statusFallback: Brightness.dark,
            ),
          ),
        ),
      ),
    );

    expect(find.text('1 · Cart'), findsOneWidget);
    expect(find.text('3 · Menu'), findsOneWidget);

    await tester.tap(find.text('3 · Menu'));
    expect(opened, [3]);
  });

  testWidgets('the screen after a beat plays, though the page is new', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Crossing from a beat replaces the whole page rather than updating it,
    // which is why the arrival is told to the page instead of inferred from
    // its own previous step.
    var beat = ScenarioRunStep(
      index: 1,
      position: '#1',
      auto: false,
      kind: ScenarioStepKind.document,
      file: 'run/receipt.pdf',
      mimeType: 'application/pdf',
      texts: const [],
      address: 'fw://wt/p/1',
    );
    var after = step(2, parent: 1, name: 'Menu');
    var steps = [beat, after];
    await _warm(tester, [after]);

    await tester.pumpWidget(_harness(steps: steps, step: after, from: 1));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('hovering a next says where its finger goes', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var steps = [
      step(1, name: 'Menu'),
      step(
        2,
        parent: 1,
        name: 'Cart',
        verb: 'tap',
        aim: const ScenarioAim(x: 20, y: 300, width: 120, height: 40),
      ),
    ];
    await tester.pumpWidget(_harness(steps: steps, step: steps.first));
    expect(find.byType(ScenarioAimOverlay), findsNothing);

    var pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await tester.pump();

    await pointer.moveTo(tester.getCenter(find.text('2 · Cart')));
    await tester.pump();
    expect(find.byType(ScenarioAimOverlay), findsOneWidget);

    // Off the link, the picture goes back to being a picture.
    await pointer.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(find.byType(ScenarioAimOverlay), findsNothing);
  });

  testWidgets('a next with nothing to point at previews nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // `enterText`, `scrollTo`, a beat, a run older than the recording: all of
    // them arrive here as a step with no aim, and the honest answer is to
    // leave the still alone.
    var steps = [step(1), step(2, parent: 1, name: 'Cart', verb: 'enterText')];
    await tester.pumpWidget(_harness(steps: steps, step: steps.first));

    var pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await tester.pump();
    await pointer.moveTo(tester.getCenter(find.text('2 · Cart')));
    await tester.pump();

    expect(find.byType(ScenarioAimOverlay), findsNothing);
  });

  testWidgets('a walk that lands under a next link still plays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Why the picture and the overlay are one decision: pressing next puts a
    // *new* next link under a pointer that never moved, so the arrival fires a
    // hover of its own, and a preview that won there would cover the
    // transition the same press had just started.
    var steps = [
      step(1, name: 'Menu'),
      step(2, parent: 1, name: 'Cart'),
      step(
        3,
        parent: 2,
        name: 'Paid',
        verb: 'tap',
        aim: const ScenarioAim(x: 20, y: 300, width: 120, height: 40),
      ),
    ];
    await _warm(tester, [steps[1]]);

    await tester.pumpWidget(_harness(steps: steps, step: steps.first));
    await tester.pumpWidget(_harness(steps: steps, step: steps[1], from: 1));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: 'playing');

    // The pointer arrives on the link that step 2 now offers.
    var pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await tester.pump();
    await pointer.moveTo(tester.getCenter(find.text('3 · Paid')));
    await tester.pump();

    expect(find.byIcon(Icons.pause), findsOneWidget, reason: 'still playing');
    expect(
      find.byType(ScenarioAimOverlay),
      findsNothing,
      reason: 'the preview may not cover the transition it interrupted',
    );

    // And once the transition lands, the preview takes over with no second
    // movement of the pointer — the walk ends by saying what the next press
    // would do.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget, reason: 'landed');
    expect(find.byType(ScenarioAimOverlay), findsOneWidget);
  });

  testWidgets('a recording handed back is no longer warm', (tester) async {
    var one = step(1);
    await _warm(tester, [one]);
    expect(scenarioMotionResidency.isWarm(one), isTrue);

    // What walking off a step does to the recording behind it. The pixels are
    // gone, so the warmth has to go with them — otherwise the next arrival
    // would autoplay frames that have to be decoded again, which is the
    // flicker the gate exists to prevent.
    scenarioMotionResidency.forget(one);
    expect(scenarioMotionResidency.isWarm(one), isFalse);
  });
}

/// Decodes [steps]' frames for real, which is what makes them playable.
Future<void> _warm(WidgetTester tester, List<ScenarioRunStep> steps) async {
  late BuildContext context;
  await tester.pumpWidget(
    ScenarioArtifactsScope(
      artifacts: const _Pixels(),
      child: Builder(
        builder: (inner) {
          context = inner;
          return const SizedBox();
        },
      ),
    ),
  );
  for (var step in steps) {
    await tester.runAsync(() => precacheScenarioMotion(context, step));
  }
}

Widget _harness({
  required List<ScenarioRunStep> steps,
  required ScenarioRunStep step,
  int? from,
  void Function(ScenarioRunStep)? onOpenStep,
}) => MaterialApp(
  theme: appTheme,
  home: Scaffold(
    body: ScenarioArtifactsScope(
      artifacts: const _Pixels(),
      child: ScenarioStepPage(
        steps: steps,
        step: step,
        from: from,
        device: null,
        onBack: () {},
        onOpenStep: onOpenStep ?? (_) {},
        displayRoot: '',
      ),
    ),
  ),
);

/// Every read answers: one opaque pixel for an image, nothing for a tree.
class _Pixels extends ScenarioArtifacts {
  const _Pixels();

  @override
  Future<Uint8List?> readBytes(String path) async =>
      Uint8List.fromList(const [0, 0, 0, 255]);

  @override
  Future<String?> readString(String path) async => null;

  @override
  Uri uriOf(String path) => Uri.file(path);

  @override
  ImageProvider encodedImage(String path) => MemoryImage(Uint8List(0));
}
