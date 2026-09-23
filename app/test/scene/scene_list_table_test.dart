// The list parameter's table in the drawer: every cell edits the parameter
// in place, and the repeat that draws the list follows.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/ui/list_table.dart';
import 'package:flutterware_app/src/ui/theme.dart';

SceneEditor repeated() {
  var cell = TextNode('Espresso', name: 'cell')
    ..bindings['text'] = const ItemRef('lines', 'item');
  var qty = TextNode('12', name: 'qty')
    ..bindings['text'] = const ItemRef('lines', 'qty');
  var row = FrameNode(name: 'row', layout: NodeLayout.row)
    ..children.addAll([cell, qty]);
  recordRepeat(row, 'lines');
  var root = FrameNode(name: 'root', layout: NodeLayout.column)
    ..width = 400
    ..height = 300
    ..children.add(row);
  var doc = SceneDocument(root)
    ..params.add(
      SceneParamDecl('lines', SceneParamKind.list, <SceneItem>[
        {'item': 'Espresso', 'qty': 12.0},
        {'item': 'Filter', 'qty': 3.0},
      ]),
    );
  bindRepeats(doc);
  return SceneEditor(doc);
}

Future<void> pump(WidgetTester tester, SceneEditor editor) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: SizedBox(
          width: 700,
          height: 300,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              editor.listenable,
              editor.doc.listenable,
            ]),
            builder: (context, _) => SceneListTable(editor, 'lines'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a column per field, a row per item, 26px each', (tester) async {
    var editor = repeated();
    await pump(tester, editor);
    expect(find.text('item'), findsOneWidget);
    expect(find.text('qty'), findsOneWidget);
    expect(find.text('Espresso'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    var rows = find.byWidgetPredicate(
      (w) => w is SizedBox && w.height == SceneListTable.rowHeight,
    );
    expect(rows, findsNWidgets(2));
  });

  testWidgets('typing in a cell edits the item, and the first row follows', (
    tester,
  ) async {
    var editor = repeated();
    await pump(tester, editor);
    await tester.enterText(find.text('Espresso'), 'Latte');
    await tester.pump();
    expect(editor.doc.paramNamed('lines')!.items.first['item'], 'Latte');
    var row = editor.doc.nodeNamed('row')! as FrameNode;
    expect((row.children[0] as TextNode).text, 'Latte');
  });

  testWidgets('add row copies the last; the cross removes one', (tester) async {
    var editor = repeated();
    await pump(tester, editor);
    await tester.tap(find.text('add row'));
    await tester.pump();
    expect(editor.doc.paramNamed('lines')!.items, hasLength(3));
    expect(editor.doc.paramNamed('lines')!.items.last['item'], 'Filter');
    await tester.tap(find.byTooltip('Remove this item').first);
    await tester.pump();
    expect(editor.doc.paramNamed('lines')!.items, hasLength(2));
    expect(editor.doc.paramNamed('lines')!.items.first['item'], 'Filter');
    editor.undo();
    editor.undo();
    expect(editor.doc.paramNamed('lines')!.items.first['item'], 'Espresso');
  });
}
