// Zooming the canvas: a trackpad gesture is the canvas's, never a node's,
// and a host drawing a pane layer is told where the artboard is.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/measure.dart';
import 'package:flutterware_app/src/scene/ui/canvas.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  group('on the canvas', () {
    late SceneEditor editor;
    var views = <Matrix4>[];

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      views = [];
      editor = SceneEditor(coffeeBannerDraft());
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Material(
            child: SceneCanvas(
              editor,
              pane: (context, view, pane, artboard) {
                views.add(view);
                return const SizedBox();
              },
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

    testWidgets(
      'a two-finger scroll over a node pans the canvas, not the node',
      (tester) async {
        await pump(tester);
        var headline = editor.doc.nodeNamed('headline')!;
        var view = tester.getRect(find.byType(SceneView));
        var scale = view.width / 1024;
        var over = view.topLeft + Offset(200 * scale, 150 * scale);
        var before = tester.getRect(find.byType(SceneView));
        var (x, y) = (headline.x, headline.y);

        var gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomStart(over);
        await tester.pump();
        await gesture.panZoomUpdate(over, pan: const Offset(0, -40));
        await tester.pump();
        await gesture.panZoomEnd();
        await tester.pump();

        expect((headline.x, headline.y), (x, y), reason: 'the node stayed');
        expect(editor.selectionNames, isEmpty);
        expect(
          tester.getRect(find.byType(SceneView)).top,
          isNot(before.top),
          reason: 'the canvas moved',
        );
      },
    );

    testWidgets('a pinch zooms, and the pane layer is told the view', (
      tester,
    ) async {
      await pump(tester);
      var view = tester.getRect(find.byType(SceneView));
      var before = views.last;
      var gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(view.center);
      await tester.pump();
      await gesture.panZoomUpdate(view.center, scale: 2);
      await tester.pump();
      await gesture.panZoomEnd();
      await tester.pump();
      expect(
        tester.getRect(find.byType(SceneView)).width,
        greaterThan(view.width * 1.5),
      );
      var after = views.last;
      expect(after.storage[0], greaterThan(before.storage[0] * 1.5));
      // The matrix maps the artboard's origin onto the pane where the
      // SceneView (inside the viewer, at the same place) is drawn.
      var canvas = tester.getRect(find.byType(SceneCanvas));
      var origin = MatrixUtils.transformPoint(after, Offset.zero);
      var drawn =
          tester.getRect(find.byType(SceneView)).topLeft - canvas.topLeft;
      expect(origin.dx, closeTo(drawn.dx, 1));
      expect(
        origin.dy,
        closeTo(drawn.dy - 32, 1),
        reason: 'the toolbar sits above the pane',
      );
    });

    testWidgets('a mouse drag still moves the node', (tester) async {
      await pump(tester);
      // `copy` is the addressable node at that point: its children only
      // become targets once it is selected.
      var copy = editor.doc.nodeNamed('copy')!;
      var view = tester.getRect(find.byType(SceneView));
      var scale = view.width / 1024;
      var over = view.topLeft + Offset(200 * scale, 150 * scale);
      var (x, y) = (copy.x, copy.y);
      var gesture = await tester.startGesture(
        over,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(Offset(30 * scale, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(editor.selectionNames, ['copy']);
      expect(copy.x, closeTo(x + 30, 2));
      expect(copy.y, y);
    });
  });
}
