// The table and the repeater: columns that agree across rows, and one
// authored row drawn once per item of a list parameter.
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';

void main() {
  TextNode text(String name, String value) =>
      TextNode(value, name: name)..fontSize = 12;

  /// A two-row table with three cells each, in a root wide enough for it.
  (SceneDocument, FrameNode) table({List<double?> columns = const []}) {
    var head = FrameNode(name: 'head')
      ..children.addAll([
        text('h1', 'Item'),
        text('h2', 'Qty'),
        text('h3', 'Amount'),
      ]);
    var line = FrameNode(name: 'line')
      ..children.addAll([
        text('c1', 'Espresso beans, 1kg'),
        text('c2', '12'),
        text('c3', '£384.00'),
      ]);
    var grid = FrameNode(name: 'grid', layout: NodeLayout.table)
      ..width = 400
      ..columns = [...columns]
      ..children.addAll([head, line]);
    var root = FrameNode(name: 'root')
      ..width = 500
      ..height = 300
      ..children.add(grid);
    return (SceneDocument(root), grid);
  }

  Future<Map<String, SceneRect>> render(
    WidgetTester tester,
    SceneDocument doc,
  ) async {
    var rects = <String, SceneRect>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SceneView.document(
            doc,
            onMeasured: (r) => rects.addAll(namedRects(r)),
          ),
        ),
      ),
    );
    await tester.pump();
    return rects;
  }

  testWidgets('a column is as wide in one row as in the other', (tester) async {
    var (doc, _) = table();
    var rects = await render(tester, doc);

    // The whole point: the header's second cell and the line's second cell
    // are the same column, so they start and end together — which stacked
    // rows, each sizing its own children, could never promise.
    expect(rects['h2']!.left, rects['c2']!.left);
    expect(rects['h2']!.width, rects['c2']!.width);
    expect(rects['h3']!.left, rects['c3']!.left);
  });

  testWidgets('a fixed track is exactly that wide', (tester) async {
    var (doc, _) = table(columns: [double.infinity, 48, 96]);
    var rects = await render(tester, doc);

    expect(rects['h2']!.width, 48);
    expect(rects['h3']!.width, 96);
    // The filling column takes the rest of the 400.
    expect(rects['c1']!.width, 400 - 48 - 96);
  });

  testWidgets('a filling track hugs when the width is unbounded', (
    tester,
  ) async {
    var (doc, grid) = table(columns: [double.infinity, 48, 96]);
    grid.width = null;
    var rects = await render(tester, doc);

    // Nothing to take a share of, so the column is its content — the same
    // honest degradation `Expanded` gets under an unbounded main axis.
    expect(rects['c1']!.width, lessThan(400 - 48 - 96));
  });

  testWidgets('cell padding is the space inside every cell', (tester) async {
    var (doc, grid) = table(columns: [double.infinity, 48, 96]);
    grid.cellPadding = const SceneEdges.all(8);
    var rects = await render(tester, doc);

    expect(rects['h2']!.width, 48 - 16);
    expect(rects['h2']!.left - rects['grid']!.left, greaterThan(0));
  });

  testWidgets('a row is the rect its cells span', (tester) async {
    var (doc, _) = table(columns: [double.infinity, 48, 96]);
    var rects = await render(tester, doc);

    // A table lays the cells out itself, so the row draws no box — and the
    // editor still has to be able to select and drop on it.
    var row = rects['line']!;
    expect(row.left, rects['c1']!.left);
    expect(row.right, rects['c3']!.right);
  });

  // ---------------------------------------------------------------------
  // The repeater
  // ---------------------------------------------------------------------

  /// The rule as a READ document has it: the cells carry the binding as
  /// bindings and the frame records which parameter it draws from, which
  /// is what [bindRepeats] turns into the closure everything draws through.
  SceneDocument repeated({List<SceneItem>? items}) {
    var cell = text('cell', 'Espresso beans, 1kg')
      ..bindings['text'] = const ItemRef('lines', 'item');
    var qty = text('qty', '12')
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
        SceneParamDecl(
          'lines',
          SceneParamKind.list,
          items ??
              <SceneItem>[
                {'item': 'Espresso beans, 1kg', 'qty': '12'},
                {'item': 'Oat milk, 12 × 1L', 'qty': '8'},
                {'item': 'Takeaway cups, 500', 'qty': '4'},
              ],
        ),
      );
    bindRepeats(doc);
    return doc;
  }

  /// The same rule as a COMPILED scene has it: a closure, and no refs.
  SceneDocument compiledRepeat() {
    var row = FrameNode.repeating(
      name: 'row',
      layout: NodeLayout.row,
      over: const [
        (item: 'Espresso beans, 1kg', qty: '12'),
        (item: 'Oat milk, 12 × 1L', qty: '8'),
      ],
      row: (line) => [text('cell', line.item), text('qty', line.qty)],
    );
    var root = FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 400
      ..height = 300
      ..children.add(row);
    return SceneDocument(root);
  }

  testWidgets('one authored row is drawn once per item', (tester) async {
    var doc = repeated();
    await render(tester, doc);

    expect(find.text('Espresso beans, 1kg'), findsOneWidget);
    expect(find.text('Oat milk, 12 × 1L'), findsOneWidget);
    expect(find.text('Takeaway cups, 500'), findsOneWidget);
    // Still one node: the tree, the file and the inspector see one row.
    expect(doc.root.children.length, 1);
  });

  testWidgets('an empty list draws nothing', (tester) async {
    var doc = repeated(items: const []);
    await render(tester, doc);

    expect(find.text('Espresso beans, 1kg'), findsNothing);
  });

  testWidgets('an argument replaces the items, first one included', (
    tester,
  ) async {
    var doc = repeated();
    doc.applyArgs({
      'lines': [
        {'item': 'Cocoa, 2kg', 'qty': '3'},
        {'item': 'Syrup, 6 × 750ml', 'qty': '1'},
      ],
    });
    await render(tester, doc);

    // The first item lands on the TEMPLATE — the node keeps its identity
    // and takes the data, exactly as a scalar argument does.
    expect(find.text('Cocoa, 2kg'), findsOneWidget);
    expect(find.text('Syrup, 6 × 750ml'), findsOneWidget);
    expect(find.text('Espresso beans, 1kg'), findsNothing);
  });

  test('the wire carries the rows, not the rule that made them', () {
    var doc = repeated();
    var wire = jsonDecode(jsonEncode(doc.toWire())) as Map<String, Object?>;
    var children = (wire['root']! as Map)['children']! as List;
    expect(children.length, 3);
    expect((children[0] as Map)['name'], 'row');
    expect((children[1] as Map)['name'], 'row#1');
    // The copy carries the item's values, already resolved — and its cells
    // are renamed with it, so nothing answers to the template's name twice.
    // A cell that did would be outlined as the selection in every row, and
    // measured as the template by the last one.
    var cells = (children[1] as Map)['children'] as List;
    expect((cells[0] as Map)['text'], 'Oat milk, 12 × 1L');
    expect((cells[0] as Map)['name'], 'cell#1');
    expect(
      [for (var c in children) (c as Map)['name']],
      ['row', 'row#1', 'row#2'],
    );
  });

  test('the authored document keeps the rule instead', () {
    var doc = repeated();
    var back = sceneFromJson(
      jsonDecode(jsonEncode(doc.toJson())) as Map<String, Object?>,
    );
    expect(back.root.children.length, 1);
    expect((back.root.children.single as FrameNode).repeated?.source, 'lines');
    expect(back.itemsOf('lines').length, 3);
  });

  test('editing a cell changes every row, not just the first', () {
    // The frame's cells ARE the first row, so a property nobody bound has
    // to reach the copies too. Getting this wrong looks like it worked: the
    // row on screen changes and the ones under it do not.
    var doc = repeated();
    var row = doc.root.children.single as FrameNode;
    (row.children.first as TextNode).fontSize = 30;

    expect(
      [
        for (var drawn in doc.expand(row))
          ((drawn as FrameNode).children.first as TextNode).fontSize,
      ],
      [30, 30, 30],
      reason: 'every row reads the cell that was edited',
    );
  });

  test('and a bound property still belongs to its item', () {
    // The other half of the same rule: `text` reads `lines.item`, so each
    // row keeps its own value however the cell is edited.
    var doc = repeated();
    var row = doc.root.children.single as FrameNode;
    var rows = doc.expand(row);
    expect(
      [for (var r in rows) ((r as FrameNode).children.first as TextNode).text],
      ['Espresso beans, 1kg', 'Oat milk, 12 × 1L', 'Takeaway cups, 500'],
    );
  });

  testWidgets('a closure draws the same rows as a recorded binding', (
    tester,
  ) async {
    // One mechanism, two ways in: the file compiles a closure, a reader
    // rebuilds one. Neither is a second renderer.
    await render(tester, compiledRepeat());
    expect(find.text('Espresso beans, 1kg'), findsOneWidget);
    expect(find.text('Oat milk, 12 × 1L'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
  });

  // ---------------------------------------------------------------------
  // The grammar
  // ---------------------------------------------------------------------

  const source =
      '''
$sceneFileMarker
$sceneAuthoringImport

class Ledger({
  final List<({String item, String qty})> lines = const [
    (item: 'Espresso beans, 1kg', qty: '12'),
    (item: 'Oat milk, 12 × 1L', qty: '8'),
  ],
}) extends SceneDefinition {
  late final row = FrameNode.repeating(
    over: lines,
    row: (line) => [
      TextNode(line.item, fontSize: 12),
      TextNode(line.qty, fontSize: 12),
    ],
  );
  @override
  late final root = FrameNode(
    width: 400,
    layout: NodeLayout.table,
    columns: [double.infinity, 48],
    cellPadding: 8,
    children: [row],
  );
}
''';

  test('a list parameter, a repeat and a table survive a round trip', () {
    var parsed = parseSceneFile(source);
    expect(parsed.refusals, isEmpty);
    var doc = parsed.doc!;

    expect(doc.params.single.kind, SceneParamKind.list);
    expect(doc.params.single.typeName, 'List<({String item, String qty})>');
    expect(doc.itemsOf('lines').length, 2);
    var row = doc.nodeNamed('row')! as FrameNode;
    expect(row.repeated?.source, 'lines');
    // Its cells are the first item's, and they are not fields.
    expect((row.children.first as TextNode).text, 'Espresso beans, 1kg');
    expect((row.children.last as TextNode).text, '12');
    expect(doc.root.columns, [double.infinity, 48]);
    expect(doc.root.cellPadding, const SceneEdges.all(8));

    var out = emitSceneFile(doc, className: parsed.className!);
    var again = parseSceneFile(out);
    expect(again.refusals, isEmpty);
    expect(
      emitSceneFile(again.doc!, className: again.className!),
      out,
      reason: 'emit ∘ parse is the identity on what emit wrote',
    );
    expect(out, contains('FrameNode.repeating('));
    expect(out, contains('over: lines'));
    expect(out, contains('row: (line) =>'));
    expect(out, contains('TextNode(line.item'));
    expect(out, contains('columns: [double.infinity, 48]'));
    // The cells are inline, so they are not declared beside the row.
    expect(out, isNot(contains('late final cell')));
  });

  test('an item reference outside its closure is not one', () {
    // `lines.item` where no closure binds it is just an unknown identifier
    // — there is no scope for it to mean anything in.
    var parsed = parseSceneFile('''
$sceneFileMarker
$sceneAuthoringImport

class Ledger({
  final List<({String item})> lines = const [(item: 'Espresso beans, 1kg')],
}) extends SceneDefinition {
  late final stray = TextNode(lines.item, fontSize: 12);
  @override
  late final root = FrameNode(width: 400, children: [stray]);
}
''');
    expect(parsed.ok, isFalse);
    expect(parsed.refusals.first.construct, 'identifier');
  });

  test('a repeat over something that is not a list is refused', () {
    var parsed = parseSceneFile('''
$sceneFileMarker
$sceneAuthoringImport

class Ledger({final String title = 'x'}) extends SceneDefinition {
  late final row = FrameNode.repeating(over: title, row: (line) => []);
  @override
  late final root = FrameNode(width: 400, children: [row]);
}
''');
    expect(parsed.ok, isFalse);
    expect(parsed.refusals.first.construct, 'over');
  });

  test('a field the items do not carry is refused', () {
    var parsed = parseSceneFile('''
$sceneFileMarker
$sceneAuthoringImport

class Ledger({
  final List<({String item})> lines = const [(item: 'Espresso beans, 1kg')],
}) extends SceneDefinition {
  late final row = FrameNode.repeating(
    over: lines,
    row: (line) => [TextNode(line.price, fontSize: 12)],
  );
  @override
  late final root = FrameNode(width: 400, children: [row]);
}
''');
    expect(parsed.ok, isFalse);
    expect(parsed.refusals.first.construct, 'unknown field');
    expect(parsed.refusals.first.message, contains('"item"'));
  });

  test('a named cell inside a row is refused', () {
    var parsed = parseSceneFile('''
$sceneFileMarker
$sceneAuthoringImport

class Ledger({
  final List<({String item})> lines = const [(item: 'Espresso beans, 1kg')],
}) extends SceneDefinition {
  late final cell = TextNode('x', fontSize: 12);
  late final row = FrameNode.repeating(over: lines, row: (line) => [cell]);
  @override
  late final root = FrameNode(width: 400, children: [row]);
}
''');
    expect(parsed.ok, isFalse);
    expect(parsed.refusals.first.construct, 'named cell');
  });

  test('an edited cell rewrites the first item, and keeps its reference', () {
    var parsed = parseSceneFile(source);
    var doc = parsed.doc!;
    var row = doc.nodeNamed('row')! as FrameNode;
    (row.children.first as TextNode).text = 'Something else';
    expect(reconcileBindings(doc), isEmpty);

    // The first item IS the cell: editing the cell edited the mockup data.
    expect(doc.paramNamed('lines')!.items.first['item'], 'Something else');
    var out = emitSceneFile(doc, className: parsed.className!);
    expect(out, contains("(item: 'Something else'"));
    expect(out, contains('TextNode(line.item'));
    expect(out, isNot(contains("TextNode('Something else'")));
    expect(parseSceneFile(out).refusals, isEmpty);
  });

  test('a cell dragged out of its repeat loses the item binding', () {
    var parsed = parseSceneFile(source);
    var doc = parsed.doc!;
    var row = doc.nodeNamed('row')! as FrameNode;
    var cell = row.children.first;
    row.children.remove(cell);
    doc.root.children.add(cell);
    expect(reconcileBindings(doc), ['${cell.name}.text']);
    expect(cell.bindings, isEmpty);
  });
}
