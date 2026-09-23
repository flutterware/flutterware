// Auto-layout, first half: a size is fixed, hug or fill, and the root's
// three shapes are the three things a scene is for.
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/ui/canvas.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  /// A column of two boxes inside a root, with sizes the test sets.
  (SceneDocument, FrameNode, ShapeNode, ShapeNode) column() {
    var top = ShapeNode(name: 'top')..fill = const SceneColor(0xFFFF0000);
    var bottom = ShapeNode(name: 'bottom')..fill = const SceneColor(0xFF00FF00);
    var stack = FrameNode(name: 'stack', layout: NodeLayout.column)
      ..gap = 0
      ..children.addAll([top, bottom]);
    var root = FrameNode(name: 'root')
      ..width = 200
      ..height = 400
      ..children.add(stack);
    return (SceneDocument(root), stack, top, bottom);
  }

  testWidgets('fill takes what the parent has left', (tester) async {
    var (doc, stack, top, bottom) = column();
    stack
      ..width = 200
      ..height = 400;
    top.height = 100;
    bottom.height = double.infinity;

    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        home: SceneView.document(
          doc,
          onMeasured: (r) => rects.addAll(namedRects(r)),
        ),
      ),
    );
    await tester.pump();

    expect(rects['top']!.height, 100);
    expect(
      rects['bottom']!.height,
      300,
      reason: 'the rest of the column, not its content',
    );
  });

  testWidgets('a filling child cannot take what a hugging parent has not', (
    tester,
  ) async {
    var (doc, stack, top, bottom) = column();
    // The column hugs its height, so there is no leftover to hand out. This
    // must render rather than throw: the editor is where the contradiction
    // is shown, not the renderer.
    stack.height = null;
    top.height = 60;
    bottom.height = double.infinity;

    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        home: SceneView.document(
          doc,
          onMeasured: (r) => rects.addAll(namedRects(r)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(rects['top']!.height, 60);
  });

  testWidgets('the root comes in three shapes', (tester) async {
    Future<Size> rootSize(
      void Function(FrameNode root) shape, {
      NodeLayout layout = NodeLayout.absolute,
    }) async {
      var child = ShapeNode(name: 'block')
        ..width = 120
        ..height = 90;
      var root = FrameNode(name: 'root', layout: layout)..children.add(child);
      shape(root);
      var doc = SceneDocument(root);
      await tester.pumpWidget(
        MaterialApp(
          // Loose, not tight: a tight box would force every root to the
          // same size and prove nothing.
          home: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
              child: SceneView.document(doc),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byType(SceneView));
    }

    // A banner: fixed on both axes.
    expect(
      await rootSize(
        (r) => r
          ..width = 300
          ..height = 150,
      ),
      const Size(300, 150),
    );

    // A screen: whatever the app gives it.
    expect(
      await rootSize(
        (r) => r
          ..width = double.infinity
          ..height = double.infinity,
      ),
      const Size(500, 400),
    );

    // A document: fixed across, growing down. It has to be a column, not a
    // free-positioned frame: a stack of positioned children has no content
    // extent, so an absolute frame takes the room it is offered and cannot
    // hug. That is a rule the editor owes the author, not a bug here.
    expect(
      await rootSize(
        (r) => r
          ..width = 400
          ..height = null,
        layout: NodeLayout.column,
      ),
      const Size(400, 90),
      reason: 'as tall as its content',
    );
  });

  test('padding is per side, and one number when one number says it', () {
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 200
      ..padding = const SceneEdges.all(16);
    var doc = SceneDocument(root);

    // A frame that only ever wanted one number keeps writing one.
    var uniform = emitSceneFile(doc, className: 'Padded');
    expect(uniform, contains('padding: 16'));
    expect(uniform, isNot(contains('paddingLeft')));
    expect(parseSceneFile(uniform).doc!.root.padding, const SceneEdges.all(16));

    // And a cell that wants a different top says so.
    root.padding = const SceneEdges(left: 8, top: 4, right: 8, bottom: 12);
    var sides = emitSceneFile(doc, className: 'Padded');
    expect(sides, contains('paddingTop: 4'));
    expect(sides, isNot(contains('padding: ')));
    var parsed = parseSceneFile(sides);
    expect(parsed.ok, isTrue, reason: parsed.refusals.join('; '));
    expect(parsed.doc!.root.padding, root.padding);
    expect(emitSceneFile(parsed.doc!, className: 'Padded'), sides);

    // The wire and the JSON both carry it, and still read the old number.
    expect(SceneEdges.fromWire(root.padding.toWire()), root.padding);
    expect(SceneEdges.fromWire(12), const SceneEdges.all(12));
  });

  testWidgets('padding is not a guess any more', (tester) async {
    var block = ShapeNode(name: 'block')
      ..width = 40
      ..height = 40;
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..padding = const SceneEdges(left: 10, top: 20, right: 30, bottom: 40)
      ..children.add(block);
    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        // Centred, so the scene is asked how big it is rather than told.
        home: Center(
          child: SceneView.document(
            SceneDocument(root),
            onMeasured: (r) => rects.addAll(namedRects(r)),
          ),
        ),
      ),
    );
    await tester.pump();
    // Was `EdgeInsets.symmetric(horizontal: p, vertical: p * 0.6)`, which
    // nobody asked for.
    expect(rects['root']!.width, 40 + 10 + 30);
    expect(rects['root']!.height, 40 + 20 + 40);
    expect(rects['block']!.left - rects['root']!.left, 10);
    expect(rects['block']!.top - rects['root']!.top, 20);
  });

  testWidgets('a free frame inside a column lays out rather than asserting', (
    tester,
  ) async {
    // A column hands its children unbounded constraints on the main axis,
    // and a stack cannot lay out under one. Flipping a frame to Free in the
    // inspector used to take the guest down with it.
    var block = ShapeNode(name: 'block')
      ..x = 10
      ..y = 20
      ..width = 60
      ..height = 30;
    var free = FrameNode(name: 'free')..children.add(block);
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 200
      ..children.add(free);
    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SceneView.document(
            SceneDocument(root),
            onMeasured: (r) => rects.addAll(namedRects(r)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // As far as its children reach, which is the only size it has ever had.
    expect(rects['free']!.height, 50);
  });

  testWidgets('a canvas drag reorders; only a modified drop changes parent', (
    tester,
  ) async {
    var doc = coffeeBannerDraft();
    var editor = SceneEditor(doc);
    // The canvas reads measured boxes, so give it the ones a renderer would
    // have left: a column of two, and a free frame beside it.
    var column = FrameNode(name: 'column', layout: NodeLayout.column)
      ..measured = const SceneRect(0, 0, 200, 200);
    var first = ShapeNode(name: 'first')
      ..measured = const SceneRect(0, 0, 200, 100);
    var second = ShapeNode(name: 'second')
      ..measured = const SceneRect(0, 100, 200, 100);
    column.children.addAll([first, second]);
    var other = FrameNode(name: 'other')
      ..measured = const SceneRect(300, 0, 200, 200);
    doc.root.children
      ..clear()
      ..addAll([column, other]);
    doc.root.measured = const SceneRect(0, 0, 600, 300);

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(child: SceneCanvas(editor, content: const SizedBox())),
      ),
    );
    await tester.pump();

    // A node inside a frame is addressable once it is selected — the
    // canvas's drill-down model — so select it the way a click would.
    editor.select(first);
    await tester.pump();

    // Dragged between the widgets rather than by a pixel count: the canvas
    // is zoomed to fit, so a screen delta is not an artboard one.
    Offset centreOf(String name) =>
        tester.getCenter(find.byKey(ValueKey('node:$name')));

    // Past the middle of the second reorders it.
    var first0 = centreOf('first');
    await tester.dragFrom(
      first0,
      centreOf('second') + const Offset(0, 8) - first0,
    );
    await tester.pump();
    expect(column.children.map((c) => c.name), ['second', 'first']);

    // But dragging it over the other frame does NOT move it there. A drag
    // is a position gesture; passing over a frame used to reparent on the
    // way past, which left the node somewhere nobody aimed for — and at a
    // position it no longer had, since a row takes one away.
    var first1 = centreOf('first');
    await tester.dragFrom(first1, centreOf('other') - first1);
    await tester.pump();
    expect(editor.doc.parentOf(first)?.name, 'column');
    expect(editor.dropTarget, isNull);

    // Held at the release, the modifier is what makes the drop a hierarchy
    // change — one entry, and only where you let go.
    var entries = editor.undoLabel;
    var first2 = centreOf('first');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.dragFrom(first2, centreOf('other') - first2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(editor.doc.parentOf(first)?.name, 'other');
    expect(column.children.map((c) => c.name), ['second']);
    expect(editor.dropTarget, isNull, reason: 'cleared on release');
    expect(editor.undoLabel, isNot(entries));
  });

  testWidgets('the drop target holds while the renderer sweeps under it', (
    tester,
  ) async {
    // The bug this pins: the artboard point was derived from the DRAGGED
    // node's own measured rect, and that rect moves on the renderer's clock
    // — swept and reported back — not on layout's. So the point the drag
    // hit-tested and the position Flutter laid the target out at disagreed
    // by however far the node had travelled since the last sweep, and the
    // highlight blinked out while the pointer sat still inside a frame.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var doc = coffeeBannerDraft();
    var editor = SceneEditor(doc);
    for (var (n, _) in doc.walk()) {
      n.measured = SceneRect(n.x, n.y, n.width ?? 100, n.height ?? 40);
    }
    doc.root.measured = const SceneRect(0, 0, 1024, 500);
    (doc.nodeNamed('copy')! as FrameNode).measured = const SceneRect(
      64,
      120,
      500,
      220,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(child: SceneCanvas(editor, content: const SizedBox())),
      ),
    );
    await tester.pump();

    var badge = doc.nodeNamed('badge')!;
    editor.select(badge);
    await tester.pump();

    var start = tester.getCenter(find.byKey(const ValueKey('node:badge')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    var drag = await tester.startGesture(start);
    await tester.pump();

    var proposed = <String?>{};
    for (var dx = -400.0; dx <= -100; dx += 20) {
      await drag.moveTo(start + Offset(dx, -100));
      // The renderer catching up, which is what it does the whole time.
      badge.measured = SceneRect(badge.x, badge.y, 140, 140);
      doc.geometryEpoch.value++;
      await tester.pump();
      proposed.add(editor.dropTarget?.name);
    }
    await drag.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    // The pointer never left `copy`, so neither did the proposal.
    expect(proposed, {'copy'});
  });

  test('the new properties survive the file, the wire and the JSON', () {
    var label = TextNode('Amount', name: 'label')
      ..align = SceneTextAlign.right
      ..maxLines = 2;
    var row = FrameNode(name: 'row', layout: NodeLayout.row)
      ..width = 400
      ..borderColor = const SceneColor(0xFFE0D6CE)
      ..borderWidth = 2
      ..children.add(label);
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 400
      ..children.add(row);
    var doc = SceneDocument(root);

    var source = emitSceneFile(doc, className: 'Doc');
    expect(source, contains('align: SceneTextAlign.right'));
    expect(source, contains('maxLines: 2'));
    expect(source, contains('borderColor: SceneColor(0xFFE0D6CE)'));
    expect(source, contains('borderWidth: 2'));

    var parsed = parseSceneFile(source);
    expect(parsed.ok, isTrue, reason: parsed.refusals.join('; '));
    var back = parsed.doc!.nodeNamed('label')! as TextNode;
    expect(back.align, SceneTextAlign.right);
    expect(back.maxLines, 2);
    var backRow = parsed.doc!.nodeNamed('row')!;
    expect(backRow.borderColor, const SceneColor(0xFFE0D6CE));
    expect(backRow.borderWidth, 2);
    expect(emitSceneFile(parsed.doc!, className: 'Doc'), source);

    var json = sceneFromJson(
      jsonDecode(jsonEncode(doc.toJson())) as Map<String, Object?>,
    );
    expect((json.nodeNamed('label')! as TextNode).align, SceneTextAlign.right);
    expect((json.nodeNamed('label')! as TextNode).maxLines, 2);
    expect(json.nodeNamed('row')!.borderWidth, 2);
    expect(jsonEncode(doc.toWire()), contains('border'));
  });

  testWidgets('a right-aligned amount sits at the right of its box', (
    tester,
  ) async {
    var amount = TextNode('£384.00', name: 'amount')
      ..width = 200
      ..align = SceneTextAlign.right;
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 200
      ..children.add(amount);
    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SceneView.document(
            SceneDocument(root),
            onMeasured: (r) => rects.addAll(namedRects(r)),
          ),
        ),
      ),
    );
    await tester.pump();
    // The box is the full width either way; what moved is the glyphs, so
    // this checks the property reached the renderer rather than the layout.
    expect(rects['amount']!.width, 200);
    var text = tester.widget<Text>(find.text('£384.00'));
    expect(text.textAlign, TextAlign.right);
  });

  test('fill survives the wire, the JSON and the file', () {
    var child = ShapeNode(name: 'block')
      ..width = double.infinity
      ..height = 40;
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 320
      ..height = double.infinity
      ..children.add(child);
    var doc = SceneDocument(root);

    // The wire and the JSON both refuse a non-finite double, so the word is
    // what travels.
    expect(jsonEncode(doc.toWire()), contains('fill'));
    var back = sceneFromJson(
      jsonDecode(jsonEncode(doc.toJson())) as Map<String, Object?>,
    );
    expect(back.root.heightFills, isTrue);
    expect(back.root.width, 320);
    expect(back.root.children.single.widthFills, isTrue);

    // And the file spells it the way Flutter does.
    var source = emitSceneFile(doc, className: 'Sized');
    expect(source, contains('double.infinity'));
    var parsed = parseSceneFile(source);
    expect(parsed.ok, isTrue, reason: parsed.refusals.join('; '));
    expect(parsed.doc!.root.heightFills, isTrue);
    expect(parsed.doc!.root.children.single.widthFills, isTrue);
    expect(
      emitSceneFile(parsed.doc!, className: 'Sized'),
      source,
      reason: 'and round trips',
    );
  });
}
