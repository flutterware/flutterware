// Drawing on the canvas and deleting from the timeline: the static editor's
// own verbs, and the right-click that makes the destructive ones findable.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/ui/inline_name.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/measure.dart';
import 'package:flutterware_app/src/scene/playback.dart';
import 'package:flutterware_app/src/scene/ui/timeline.dart';
import 'package:flutterware_app/src/scene/ui/workspace_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  group('insertion', () {
    late SceneEditor editor;
    setUp(() {
      editor = SceneEditor(coffeeBannerDraft());
      // Measured boxes, as a renderer would leave them.
      editor.doc.root.measured = const SceneRect(0, 0, 1024, 500);
      editor.doc.nodeNamed('copy')!.measured = const SceneRect(
        64,
        120,
        500,
        200,
      );
      editor.doc.nodeNamed('cta')!.measured = const SceneRect(64, 260, 150, 50);
    });

    test('the frame under a point is the deepest one', () {
      expect(editor.frameAt(10, 10), same(editor.doc.root));
      expect(editor.frameAt(100, 150).name, 'copy');
      expect(
        editor.frameAt(100, 280).name,
        'cta',
        reason: 'cta is inside copy',
      );
    });

    test('a node drawn on the root lands at its point, half-pixel', () {
      editor.tool = SceneTool.frame;
      var node = FrameNode(name: 'frame1')..width = 120;
      editor.insertNode(node, x: 700.3, y: 40.6);
      expect(editor.doc.parentOf(node), same(editor.doc.root));
      expect((node.x, node.y), (700.5, 40.5));
      expect(editor.selectionNames, ['frame1']);
      expect(editor.tool, SceneTool.select, reason: 'drawing is one node');
      expect(editor.undoLabel, 'Add frame1');
    });

    test('a node drawn inside a column is appended, its point ignored', () {
      var node = TextNode('Text', name: 'text1');
      editor.insertNode(node, x: 100, y: 150);
      var copy = editor.doc.nodeNamed('copy')! as FrameNode;
      expect(copy.children.last, same(node));
      expect((node.x, node.y), (0.0, 0.0));
    });
  });

  group('deleting', () {
    late SceneEditor editor;
    late MotionDocument motion;
    const m = 'BannerIntro';
    setUp(() {
      var scene = coffeeBannerDraft();
      motion = coffeeIntroDraft(scene);
      editor = SceneEditor(scene, motions: {m: motion});
    });

    test('a group leaves the timeline with it, and comes back on undo', () {
      editor.deleteGroup(m, 'badgePop');
      expect(motion.groupNamed('badgePop'), isNull);
      expect(motion.placements.containsKey('badgePop'), isFalse);
      expect(
        (motion.timeline as ParExpr).children,
        hasLength(2),
        reason: 'the At went too',
      );
      editor.undo();
      expect(
        motion.groupNamed('badgePop')!.tracks['scale']!.keys,
        hasLength(2),
      );
      expect(motion.placements['badgePop'], const Duration(milliseconds: 400));
    });

    test("a track goes; the group stays as the node's place", () {
      editor.deleteTrack(m, 'headlineIn', 'translateY');
      expect(motion.groupNamed('headlineIn')!.tracks.keys, ['opacity']);
      editor.deleteTrack(m, 'badgePop', 'args.size');
      expect(
        motion.groupNamed('badgePop')!.tracks.keys,
        isNot(contains('args.size')),
      );
      expect(motion.groupNamed('badgePop'), isNotNull);
    });
  });

  group('on screen', () {
    late SceneEditor editor;
    late MotionDocument motion;

    Future<void> pump(WidgetTester tester, {bool motionOpen = false}) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var scene = coffeeBannerDraft();
      motion = coffeeIntroDraft(scene);
      editor = SceneEditor(scene, motions: {'BannerIntro': motion});
      if (motionOpen) editor.activeMotion = 'BannerIntro';
      await tester.pumpWidget(
        MaterialApp(theme: appTheme, home: _Host(editor)),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the frame tool draws a frame where the drag went', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Frame (F)'));
      await tester.pump();
      expect(editor.tool, SceneTool.frame);
      var canvas = tester.getRect(find.byType(SceneView));
      // The artboard is fitted; draw over a clear part of it, bottom left.
      var scale = canvas.width / 1024;
      var from = canvas.topLeft + Offset(40 * scale, 400 * scale);
      var gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(Offset(200 * scale, 60 * scale));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      var frame = editor.doc.nodeNamed('frame1');
      expect(frame, isA<FrameNode>());
      expect(editor.doc.parentOf(frame!), same(editor.doc.root));
      expect(frame.x, closeTo(40, 1));
      expect(frame.y, closeTo(400, 1));
      expect(frame.width, closeTo(200, 1));
      expect(frame.height, closeTo(60, 1));
      expect(editor.tool, SceneTool.select);
      expect(editor.selectionNames, ['frame1']);
    });

    testWidgets('the text tool places a text on a click', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      expect(editor.tool, SceneTool.text);
      var canvas = tester.getRect(find.byType(SceneView));
      var scale = canvas.width / 1024;
      await tester.tapAt(canvas.topLeft + Offset(900 * scale, 60 * scale));
      await tester.pump();
      var text = editor.doc.nodeNamed('text1');
      expect(text, isA<TextNode>());
      expect(text!.x, closeTo(900, 1));
      expect(editor.tool, SceneTool.select);
    });

    testWidgets('right-click on a key offers to delete it', (tester) async {
      await pump(tester, motionOpen: true);
      var strip = tester.getRect(find.byType(SceneTimeline));
      // The key strip starts after the 240px gutter + 1; lanes: ruler 28+1,
      // group row 26, first lane centre at +13.
      var opacity = motion.groupNamed('headlineIn')!.tracks['opacity']!;
      var stripLeft = strip.left + 241;
      var stripWidth = strip.width - 241;
      var x = stripLeft + 260 / 2500 * stripWidth;
      var y = strip.top + 29 + 26 + 13;
      await tester.tapAt(Offset(x, y), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump();
      expect(find.text('Delete key'), findsOneWidget);
      await tester.tap(find.text('Delete key'));
      await tester.pump();
      await tester.pump();
      expect(opacity.keys, hasLength(1));
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets('Escape closes a context menu and focus goes back', (
      tester,
    ) async {
      await pump(tester);
      editor.activeMotion = 'BannerIntro';
      await tester.pump();
      // The timeline holds focus, as it does after any click on it.
      await tester.tapAt(tester.getCenter(find.byType(SceneTimeline)));
      await tester.pump();
      var before = FocusManager.instance.primaryFocus;
      await tester.tapAt(
        tester.getCenter(find.text('BannerIntro').last),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Rename'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.text('Rename'), findsNothing);
      expect(
        editor.activeMotion,
        'BannerIntro',
        reason: "Escape was the menu's",
      );
      expect(FocusManager.instance.primaryFocus, before);
      await tester.pump(kDoubleTapTimeout);
    });

    testWidgets("right-click on the open motion's name renames the motion", (
      tester,
    ) async {
      await pump(tester);
      editor.activeMotion = 'BannerIntro';
      await tester.pump();
      await tester.tapAt(
        tester.getCenter(find.text('BannerIntro').last),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Rename'));
      await tester.pump();
      await tester.pump();
      var field = find.descendant(
        of: find.byType(InlineNameField),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      // A name that cannot be a class stays in the field, with the reason.
      await tester.enterText(field, 'not valid');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('not a valid name'), findsOneWidget);
      expect(editor.motions.keys, ['BannerIntro']);
      await tester.enterText(field, 'BannerReveal');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byType(InlineNameField), findsNothing);
      expect(editor.motions.keys, ['BannerReveal']);
      expect(editor.activeMotion, 'BannerReveal');
      expect(find.text('BannerReveal'), findsNWidgets(2));
    });

    testWidgets('right-click on a motion in the tree deletes the motion', (
      tester,
    ) async {
      await pump(tester);
      await tester.tapAt(
        tester.getCenter(find.text('BannerIntro').last),
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Delete BannerIntro'));
      await tester.pump();
      await tester.pump();
      expect(editor.motions, isEmpty);
      editor.undo();
      expect(editor.motions.keys, ['BannerIntro']);
    });
  });
}

class _Host extends StatefulWidget {
  const _Host(this.editor);

  final SceneEditor editor;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  final _playbacks = <String, ScenePlayback>{};

  @override
  void dispose() {
    for (var p in _playbacks.values) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    child: SceneWorkspaceView(
      widget.editor,
      sceneClassName: 'BannerScene',
      playbackFor: (m) => _playbacks.putIfAbsent(
        m,
        () => ScenePlayback(widget.editor, m, vsync: this),
      ),
      content: SceneView.document(
        widget.editor.doc,
        onMeasured: (r) => applyMeasuredRects(widget.editor.doc, r),
      ),
    ),
  );
}
