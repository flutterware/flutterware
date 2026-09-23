import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/playback.dart';
import 'package:flutterware_app/src/scene/ui/inline_name.dart';
import 'package:flutterware_app/src/scene/ui/timeline.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The keyframe editor over the coffee intro: keys are hit by time, moved
/// by time, selected as a set, and every edit is one journal entry.
void main() {
  late SceneEditor editor;
  late MotionDocument motion;

  /// The strip is 800 wide over the 1800ms motion's 2500ms span.
  const stripWidth = 800.0;
  const gutter = 240.0;
  const totalMs = 2500;

  double xOf(Duration at) =>
      gutter + 1 + at.inMilliseconds / totalMs * stripWidth;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = Size(gutter + 1 + stripWidth, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var doc = coffeeBannerDraft();
    motion = coffeeIntroDraft(doc);
    editor = SceneEditor(doc, motions: {'BannerIntro': motion});
    await tester.pumpWidget(MaterialApp(theme: appTheme, home: _Host(editor)));
    await tester.pump();
  }

  /// The row of a lane of the FIRST group: the ruler is 28 + 1, then the
  /// group's own row, then 26 per lane.
  double yOfLane(int index) => 29 + 26 * (index + 1) + 13;

  /// The first group's header row.
  var yOfGroup = 29.0 + 13;

  MotionTrack track(String group, String prop) =>
      motion.groupNamed(group)!.tracks[prop]!;

  testWidgets('right-click on a group row renames the group', (tester) async {
    await pump(tester);
    var before = motion.placements['headlineIn'];
    await tester.tapAt(Offset(gutter / 2, yOfGroup), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Rename headlineIn…'));
    await tester.pump();
    await tester.pump();
    var field = find.descendant(
      of: find.byType(InlineNameField),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    await tester.enterText(field, 'headlineRise');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byType(InlineNameField), findsNothing);
    expect(motion.groupNamed('headlineIn'), isNull);
    expect(motion.placements['headlineRise'], before);
    expect(find.byKey(const ValueKey('group:headlineRise')), findsOneWidget);
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('a trackpad scroll over the ruler is not a seek', (tester) async {
    await pump(tester);
    var playback = tester.state<_HostState>(find.byType(_Host)).playback;
    var at = Offset(xOf(const Duration(milliseconds: 1000)), 14);
    // Two fingers moving across the ruler: to a drag recognizer that takes
    // every device this is a horizontal drag, and the playhead jumped to
    // wherever the fingers were.
    var fingers = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await fingers.panZoomStart(at);
    await tester.pump();
    await fingers.panZoomUpdate(at, pan: const Offset(-40, 0));
    await tester.pump();
    await fingers.panZoomEnd();
    await tester.pump();
    expect(playback.position, Duration.zero);

    // The mouse still seeks.
    await tester.dragFrom(at, const Offset(40, 0));
    await tester.pump();
    expect(playback.position, greaterThan(Duration.zero));
  });

  testWidgets('a tap on a key selects it, elsewhere seeks', (tester) async {
    await pump(tester);
    var opacity = track('headlineIn', 'opacity');
    await tester.tapAt(Offset(xOf(opacity.keys[1].at), yOfLane(0)));
    await tester.pump();
    expect(editor.selectedKeys, hasLength(1));
    expect(editor.selectedKeys.single.keyId, opacity.keys[1].id);

    await tester.tapAt(
      Offset(xOf(const Duration(milliseconds: 900)), yOfLane(0)),
    );
    await tester.pump();
    expect(editor.selectedKeys, isEmpty);
    var playback = tester.state<_HostState>(find.byType(_Host)).playback;
    expect(playback.position.inMilliseconds, closeTo(900, 3));
    // The lanes carry a double-tap recognizer, which arms a timer after any
    // tap; a test that ends with it pending is refused by the framework.
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets(
    'a drag moves the key by the time it crossed, as one undo entry',
    (tester) async {
      await pump(tester);
      var opacity = track('headlineIn', 'opacity');
      var key = opacity.keys[1];
      var from = Offset(xOf(key.at), yOfLane(0));
      var gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(stripWidth / totalMs * 20, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(key.at.inMilliseconds, closeTo(260 + 200, 3));
      expect(editor.undoLabel, 'Move 1 key');
      editor.undo();
      expect(key.at.inMilliseconds, 260);
      expect(editor.canUndo, isFalse, reason: 'the whole drag was one entry');
      await tester.pump(kDoubleTapTimeout);
    },
  );

  testWidgets('a clip block is moved by its body and trimmed by its edge', (
    tester,
  ) async {
    await pump(tester);
    editor.addClip(
      'BannerIntro',
      'headlineIn',
      'opacity',
      at: const Duration(milliseconds: 200),
      length: const Duration(milliseconds: 1000),
    );
    await tester.pump();
    MotionClip clip() => track('headlineIn', 'opacity').clips.single;
    var group = motion.placements['headlineIn']!;
    const pxPerMs = stripWidth / totalMs;

    // The end edge, dragged 300ms to the right: the block grows.
    var end = Offset(xOf(group + clip().end), yOfLane(0));
    var gesture = await tester.startGesture(end, kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(pxPerMs * 30, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(clip().length.inMilliseconds, closeTo(1300, 3));
    expect(clip().at.inMilliseconds, 200);
    expect(editor.undoLabel, 'Trim clip block');

    // The body, dragged 200ms to the left: the block moves whole.
    var body = Offset(xOf(group + clip().at + clip().length ~/ 2), yOfLane(0));
    gesture = await tester.startGesture(body, kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-pxPerMs * 20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(clip().at.inMilliseconds, closeTo(0, 3));
    expect(clip().length.inMilliseconds, closeTo(1300, 3));
    expect(editor.undoLabel, 'Move clip block');
    expect(
      editor.selectedClip?.clipId,
      clip().id,
      reason: 'a press on a block selects it',
    );
    editor.undo();
    expect(
      clip().at.inMilliseconds,
      200,
      reason: 'the whole drag was one entry',
    );
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('shift-tap adds to the selection and arrows nudge the set', (
    tester,
  ) async {
    await pump(tester);
    var opacity = track('headlineIn', 'opacity');
    var translate = track('headlineIn', 'translateY');
    await tester.tapAt(Offset(xOf(opacity.keys[1].at), yOfLane(0)));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(Offset(xOf(translate.keys[1].at), yOfLane(1)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(editor.selectedKeys, hasLength(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(opacity.keys[1].at.inMilliseconds, 270);
    expect(translate.keys[1].at.inMilliseconds, 270);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(opacity.keys, hasLength(1));
    expect(translate.keys, hasLength(1));
    expect(editor.selectedKeys, isEmpty);
    // The lanes carry a double-tap recognizer, which arms a timer after any
    // tap; a test that ends with it pending is refused by the framework.
    await tester.pump(kDoubleTapTimeout);
  });

  test('the strip shows at least a second, with room past the end', () {
    expect(spanFor(0), 1000);
    expect(spanFor(1800), 2500, reason: '1.25× rounded up to the 500ms step');
    expect(spanFor(60), 1000);
    expect(spanFor(10000), 14000, reason: '12500 up to the 2s step');
  });

  testWidgets('⌘-scroll zooms the strip about the pointer; scroll moves it', (
    tester,
  ) async {
    await pump(tester);
    var opacity = track('headlineIn', 'opacity');
    var keyX = xOf(opacity.keys[1].at);
    var origin = xOf(Duration.zero);
    // Zoom in about the origin: the key moves right, the origin stays.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: Offset(origin, yOfLane(0)),
        scrollDelta: const Offset(0, -400),
      ),
    );
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    // The key's diamond sits where a tap selects it: hit-test the new place.
    var zoomed = origin + (keyX - origin) * 1.5;
    await tester.tapAt(Offset(zoomed, yOfLane(0)));
    await tester.pump();
    expect(editor.selectedKeys, isEmpty, reason: 'the key is further right');
    // Find it: the strip is zoomed by exp(400 * 0.0016) ≈ 1.9.
    var factor = 1.896;
    await tester.tapAt(Offset(origin + (keyX - origin) * factor, yOfLane(0)));
    await tester.pump();
    expect(editor.selectedKeys, hasLength(1));
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('a double-click on a lane adds a key there, selected', (
    tester,
  ) async {
    await pump(tester);
    var opacity = track('headlineIn', 'opacity');
    var at = Offset(xOf(const Duration(milliseconds: 130)), yOfLane(0));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await tester.pump();
    expect(opacity.keys, hasLength(3));
    var added = opacity.keys[1];
    expect(added.at.inMilliseconds, closeTo(130, 3));
    expect(editor.selectedKeys.single.keyId, added.id);
    expect(editor.undoLabel, 'Add key');
    // The lanes carry a double-tap recognizer, which arms a timer after any
    // tap; a test that ends with it pending is refused by the framework.
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('dragging the group bar moves the whole group', (tester) async {
    await pump(tester);
    expect(motion.placements['headlineIn'], Duration.zero);
    var gesture = await tester.startGesture(
      Offset(xOf(const Duration(milliseconds: 100)), yOfGroup),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(stripWidth / totalMs * 30, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(motion.placements['headlineIn']!.inMilliseconds, closeTo(300, 3));
    expect(editor.undoLabel, 'Move headlineIn');
    expect(editor.selectionNames, [
      'headline',
    ], reason: 'the bar selects its node');
    editor.undo();
    expect(motion.placements['headlineIn'], Duration.zero);
    // The lanes carry a double-tap recognizer, which arms a timer after any
    // tap; a test that ends with it pending is refused by the framework.
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets(
    'a group the timeline never placed shows at zero; a drag places it',
    (tester) async {
      await pump(tester);
      expect(motion.placements.containsKey('tapPulse'), isFalse);
      expect(
        find.byKey(const ValueKey('group:tapPulse')),
        findsOneWidget,
        reason: 'a row like any other',
      );
      expect(
        find.text('cta  tapPulse', findRichText: true),
        findsNothing,
        reason: 'the only group of a node does not say its name',
      );
      expect(find.text('LIBRARY'), findsNothing);
      // tapPulse is the fourth group in document order: ruler, then
      // headlineIn (1 + 2 lanes), glowMood (1 + 1), badgePop (1 + 2) before it.
      var y = 29 + 26 * 8 + 13.0;
      var gesture = await tester.startGesture(
        Offset(xOf(const Duration(milliseconds: 100)), y),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(stripWidth / totalMs * 20, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(motion.placements['tapPulse']!.inMilliseconds, closeTo(100, 3));
      expect(editor.undoLabel, 'Move tapPulse');
      await tester.pump(kDoubleTapTimeout);
    },
  );
}

class _Host extends StatefulWidget {
  const _Host(this.editor);

  final SceneEditor editor;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final playback = ScenePlayback(
    widget.editor,
    'BannerIntro',
    vsync: this,
  );

  @override
  void dispose() {
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Material(child: SceneTimeline(widget.editor, playback));
}
