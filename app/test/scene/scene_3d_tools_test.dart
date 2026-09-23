// The 3D window on the canvas: drawn with its own tool, turned with the
// orbit tool, brought closer with the wheel, and given its placements from
// the tree — each writing the rows the inspector and the guest read.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/measure.dart';
import 'package:flutterware_app/src/scene/ui/canvas.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  late SceneEditor editor;

  SceneDocument scene() => SceneDocument(
    FrameNode(name: 'root')
      ..width = 1024
      ..height = 576
      ..children.add(
        View3DNode(name: 'view', x: 100, y: 100, width: 300, height: 300),
      ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    editor = SceneEditor(scene());
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: SceneCanvas(
            editor,
            pane: (context, view, pane, artboard) => const SizedBox(),
            content: SceneView.document(
              editor.doc,
              onMeasured: (r) => applyMeasuredRects(editor.doc, r),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Where the window's middle is on screen.
  Offset middle(WidgetTester tester) {
    var view = tester.getRect(find.byType(SceneView));
    var scale = view.width / 1024;
    return view.topLeft + Offset(250 * scale, 250 * scale);
  }

  double row(String name) {
    var k = editor.doc.nodeNamed('view')! as KindNode;
    return (scenePropNamed(k, name)!.read(k)! as num).toDouble();
  }

  testWidgets('a drag with the orbit tool turns the camera, not the node', (
    tester,
  ) async {
    await pump(tester);
    editor.tool = SceneTool.orbit;
    await tester.pump();
    var node = editor.doc.nodeNamed('view')!;
    var gesture = await tester.startGesture(
      middle(tester),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(40, -20));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    // About half a degree a pixel; the recognizer's slop eats a pixel or two.
    expect(row('yaw'), closeTo(20, 2));
    expect(row('pitch'), closeTo(20, 2), reason: 'from its default of 10');
    expect((node.x, node.y), (100.0, 100.0), reason: 'the node stayed put');
    expect(editor.selectionNames, ['view']);
    expect(editor.undoLabel, 'Orbit view', reason: 'one entry for the drag');
  });

  testWidgets('the wheel with the orbit tool moves the camera in and out', (
    tester,
  ) async {
    await pump(tester);
    editor.tool = SceneTool.orbit;
    await tester.pump();
    var before = row('distance');
    var pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(middle(tester));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();
    expect(row('distance'), closeTo(before * 1.1, 0.6));
  });

  testWidgets('a drag with the select tool still moves the window', (
    tester,
  ) async {
    await pump(tester);
    var node = editor.doc.nodeNamed('view')!;
    var view = tester.getRect(find.byType(SceneView));
    var scale = view.width / 1024;
    var gesture = await tester.startGesture(
      middle(tester),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(Offset(30 * scale, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(node.x, closeTo(130, 2));
    expect(row('yaw'), 0);
  });

  testWidgets('the 3D window tool draws one', (tester) async {
    await pump(tester);
    editor.tool = SceneTool.view3d;
    await tester.pump();
    var view = tester.getRect(find.byType(SceneView));
    var scale = view.width / 1024;
    var from = view.topLeft + Offset(500 * scale, 100 * scale);
    var gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(Offset(200 * scale, 150 * scale));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    var drawn = editor.doc.root.children.last;
    expect(drawn, isA<KindNode>());
    expect((drawn as KindNode).kind, view3dKind);
    expect(drawn.width, closeTo(200, 2));
    expect(drawn.height, closeTo(150, 2));
    expect(editor.tool, SceneTool.select, reason: 'back to select after');
  });

  test('a model and a screen are added under the window', () {
    editor = SceneEditor(scene());
    var view = editor.doc.nodeNamed('view')!;
    editor.addChild(view, ModelNode(name: editor.doc.uniqueName('model')));
    editor.addChild(
      view,
      SurfaceNode(
        name: editor.doc.uniqueName('screen'),
        children: [FrameNode(name: 'content')],
      ),
    );
    expect(view.children.map((c) => (c as KindNode).kind), [
      modelKind,
      surfaceKind,
    ]);
    expect(editor.selectionNames, [view.children.last.name]);
    editor.undo();
    // An undo restores a snapshot, so the node is looked up again.
    var restored = editor.doc.nodeNamed('view')!;
    expect(restored.children.map((c) => (c as KindNode).kind), [modelKind]);
  });
}
