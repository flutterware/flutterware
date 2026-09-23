import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/column_layout.dart';
import 'package:flutterware_app/src/ui/table.dart';
import 'package:flutterware_app/src/ui/theme.dart';

class _Row {
  const _Row(this.name, this.version);
  final String name;
  final String version;
}

const _rows = [
  _Row('async', '2.13.0'),
  _Row('collection', '1.19.1'),
  _Row('path', '1.9.1'),
];

List<FwTableColumn<_Row>> _columns() => [
  FwTableColumn(
    label: 'PACKAGE',
    sortKey: 'name',
    cell: (row) => Text(row.name),
  ),
  FwTableColumn(
    label: 'VERSION',
    sortKey: 'version',
    cell: (row) => Text(row.version),
  ),
  // A display column: no sort key, so it must not offer sorting.
  FwTableColumn(label: 'ACTIONS', cell: (_) => const Icon(Icons.more_horiz)),
];

/// The resize targets, found by the cursor they claim rather than by position —
/// the handle is a deliberately invisible hit area, so there is nothing else to
/// match on.
final resizeHandles = find.byWidgetPredicate(
  (widget) =>
      widget is MouseRegion && widget.cursor == SystemMouseCursors.resizeColumn,
);

/// Moves a real mouse pointer onto a header cell.
///
/// The ⋮ trigger sits behind an [IgnorePointer] until the header is hovered, so
/// tapping it without this finds nothing — which is the affordance working, not
/// a broken test.
Future<void> hoverHeader(WidgetTester tester, String label) async {
  var gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.text(label)));
  await tester.pump();
}

void main() {
  Future<void> pumpTable(
    WidgetTester tester, {
    List<_Row> rows = _rows,
    List<FwTableColumn<_Row>>? columns,
    FwTableSort? sort,
    void Function(String key, bool ascending)? onSort,
    void Function(_Row row)? onRowTap,
    void Function(String key, double width)? onColumnResize,
    void Function(String key)? onHideColumn,
    Map<String, double>? columnWidths,
    bool loading = false,
    Widget? empty,
    Widget? error,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: FwTable<_Row>(
              rows: rows,
              columns: columns ?? _columns(),
              sort: sort,
              onSort: onSort,
              onRowTap: onRowTap,
              onColumnResize: onColumnResize,
              onHideColumn: onHideColumn,
              columnWidths: columnWidths,
              loading: loading,
              empty: empty,
              error: error,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders a header and every row', (tester) async {
    await pumpTable(tester);

    expect(find.text('PACKAGE'), findsOneWidget);
    expect(find.text('VERSION'), findsOneWidget);
    for (var row in _rows) {
      expect(find.text(row.name), findsOneWidget);
      expect(find.text(row.version), findsOneWidget);
    }
  });

  testWidgets('only the visible rows are built', (tester) async {
    // The reason this replaced DataTable, which builds every row eagerly. The
    // dependencies list is 170 packages and was doing exactly that inside a
    // fixed-height SizedBox.
    var built = 0;
    var many = [for (var i = 0; i < 1000; i++) _Row('package_$i', '1.0.$i')];

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: FwTable<_Row>(
              rows: many,
              columns: [
                FwTableColumn(
                  label: 'PACKAGE',
                  cell: (row) {
                    built++;
                    return Text(row.name);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // 400px of viewport at 44px rows is ~10, plus a cache extent either side.
    expect(built, lessThan(60));
    expect(find.text('package_0'), findsOneWidget);
    expect(find.text('package_999'), findsNothing);
  });

  testWidgets('rows are not reordered by the table itself', (tester) async {
    // Controlled view: it renders the order it was handed. Sorting is the
    // caller's job, reported through onSort.
    await pumpTable(tester, sort: const FwTableSort('name', ascending: false));

    var texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((t) => _rows.any((row) => row.name == t))
        .toList();
    expect(texts, ['async', 'collection', 'path']);
  });

  testWidgets('tapping a sortable header reports the key and direction', (
    tester,
  ) async {
    var reported = <(String, bool)>[];
    await pumpTable(
      tester,
      onSort: (key, ascending) => reported.add((key, ascending)),
    );

    await tester.tap(find.text('PACKAGE'));
    await tester.pump();
    expect(reported, [('name', true)]);
  });

  testWidgets('tapping the active header flips the direction', (tester) async {
    var reported = <(String, bool)>[];
    await pumpTable(
      tester,
      sort: const FwTableSort('name'),
      onSort: (key, ascending) => reported.add((key, ascending)),
    );

    await tester.tap(find.text('PACKAGE'));
    await tester.pump();
    expect(reported, [('name', false)]);
  });

  testWidgets('a display column does not sort', (tester) async {
    var reported = <String>[];
    await pumpTable(tester, onSort: (key, _) => reported.add(key));

    await tester.tap(find.text('ACTIONS'));
    await tester.pump();
    expect(reported, isEmpty);
  });

  testWidgets('tapping a row reports it', (tester) async {
    _Row? tapped;
    await pumpTable(tester, onRowTap: (row) => tapped = row);

    await tester.tap(find.text('collection'));
    await tester.pump();
    expect(tapped?.name, 'collection');
  });

  testWidgets('the header menu offers sort and hide', (tester) async {
    var hidden = <String>[];
    await pumpTable(tester, onSort: (_, _) {}, onHideColumn: hidden.add);

    await hoverHeader(tester, 'PACKAGE');
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    expect(find.text('Sort ascending'), findsOneWidget);
    expect(find.text('Hide column'), findsOneWidget);

    await tester.tap(find.text('Hide column'));
    await tester.pumpAndSettle();
    expect(hidden, ['PACKAGE']);
  });

  testWidgets('the menu sets an explicit direction, not a toggle', (
    tester,
  ) async {
    var sorted = <(String, bool)>[];
    await pumpTable(
      tester,
      sort: const FwTableSort('name'),
      onSort: (key, ascending) => sorted.add((key, ascending)),
    );

    await hoverHeader(tester, 'PACKAGE');
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    // Already sorting ascending, so a tap on the label would flip it. The menu
    // entry says what it means instead.
    await tester.tap(find.text('Sort ascending'));
    await tester.pumpAndSettle();
    expect(sorted, [('name', true)]);
  });

  testWidgets('a column that is not hideable is not offered', (tester) async {
    await pumpTable(
      tester,
      columns: [
        FwTableColumn(
          label: 'PACKAGE',
          sortKey: 'name',
          hideable: false,
          cell: (row) => Text(row.name),
        ),
      ],
      onSort: (_, _) {},
      onHideColumn: (_) {},
    );

    await hoverHeader(tester, 'PACKAGE');
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Sort ascending'), findsOneWidget);
    expect(find.text('Hide column'), findsNothing);
  });

  testWidgets('dragging a column edge reports the new width', (tester) async {
    var widths = <String, double>{};
    await pumpTable(
      tester,
      onColumnResize: (key, width) => widths[key] = width,
      columnWidths: const {'PACKAGE': 200},
    );

    await tester.drag(resizeHandles.first, const Offset(40, 0));
    await tester.pump();

    expect(widths['PACKAGE'], 240);
  });

  testWidgets('a resize clamps at the column minimum', (tester) async {
    var widths = <String, double>{};
    await pumpTable(
      tester,
      columns: [
        FwTableColumn(
          label: 'PACKAGE',
          minWidth: 120,
          cell: (row) => Text(row.name),
        ),
      ],
      onColumnResize: (key, width) => widths[key] = width,
      columnWidths: const {'PACKAGE': 200},
    );

    await tester.drag(resizeHandles.first, const Offset(-500, 0));
    await tester.pump();

    expect(widths['PACKAGE'], 120);
  });

  testWidgets('a column marked unresizable gets no handle', (tester) async {
    await pumpTable(
      tester,
      columns: [
        FwTableColumn(
          label: 'PACKAGE',
          resizable: false,
          cell: (row) => Text(row.name),
        ),
      ],
      onColumnResize: (_, _) {},
    );
    expect(resizeHandles, findsNothing);
  });

  testWidgets('no handles at all without an onColumnResize', (tester) async {
    await pumpTable(tester);
    expect(resizeHandles, findsNothing);
  });

  group('body states', () {
    testWidgets('empty shows a placeholder under a live header', (
      tester,
    ) async {
      await pumpTable(tester, rows: const []);
      expect(find.text('PACKAGE'), findsOneWidget);
      expect(find.text('Nothing here yet'), findsOneWidget);
    });

    testWidgets('a custom empty widget wins', (tester) async {
      await pumpTable(
        tester,
        rows: const [],
        empty: const Text('No dependencies'),
      );
      expect(find.text('No dependencies'), findsOneWidget);
      expect(find.text('Nothing here yet'), findsNothing);
    });

    testWidgets('error takes precedence over empty', (tester) async {
      await pumpTable(
        tester,
        rows: const [],
        empty: const Text('No dependencies'),
        error: const Text('Could not load'),
      );
      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('No dependencies'), findsNothing);
    });

    testWidgets('error takes precedence over loading, and over rows', (
      tester,
    ) async {
      await pumpTable(tester, loading: true, error: const Text('Boom'));
      expect(find.text('Boom'), findsOneWidget);
      expect(find.text('async'), findsNothing);
    });

    testWidgets('loading keeps the previous rows visible', (tester) async {
      await pumpTable(tester, loading: true);
      expect(find.text('async'), findsOneWidget);
    });

    testWidgets('a sub-perceptual load never shows the progress bar', (
      tester,
    ) async {
      await pumpTable(tester, loading: true);
      // The dim + bar are delayed 150ms so a fast refetch does not flash.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });

  group('ColumnLayout', () {
    var columns = _columns();

    test('defaults to declared order with nothing hidden', () {
      var layout = ColumnLayout.of(columns);
      expect(layout.order, ['PACKAGE', 'VERSION', 'ACTIONS']);
      expect(layout.apply(columns).map((c) => c.key), layout.order);
    });

    test('reorders to the saved order', () {
      var layout = const ColumnLayout(order: ['VERSION', 'PACKAGE']);
      expect(layout.apply(columns).map((c) => c.key), [
        'VERSION',
        'PACKAGE',
        // Unknown to the layout, so it appends rather than disappearing.
        'ACTIONS',
      ]);
    });

    test('a column added after the layout was saved stays visible', () {
      // The forward-compatibility rule: a new column must never vanish because
      // an old saved view had never heard of it.
      var layout = const ColumnLayout(order: ['PACKAGE'], hidden: {'VERSION'});
      expect(layout.apply(columns).map((c) => c.key), ['PACKAGE', 'ACTIONS']);
    });

    test('hiding and unhiding round-trips', () {
      var layout = ColumnLayout.of(columns).withVisible('VERSION', false);
      expect(layout.isVisible('VERSION'), isFalse);
      expect(layout.apply(columns).map((c) => c.key), ['PACKAGE', 'ACTIONS']);

      var restored = layout.withVisible('VERSION', true);
      expect(restored.apply(columns).map((c) => c.key), layout.order);
    });

    test('resolvedOrder appends columns the layout has not seen', () {
      var layout = const ColumnLayout(order: ['VERSION']);
      expect(layout.resolvedOrder(columns), ['VERSION', 'PACKAGE', 'ACTIONS']);
    });

    test('survives a JSON round trip', () {
      var layout = ColumnLayout.of(columns)
          .withVisible('ACTIONS', false)
          .withWidth('PACKAGE', 240);
      expect(ColumnLayout.fromJson(layout.toJson()), layout);
    });

    test('an empty layout round-trips too', () {
      expect(
        ColumnLayout.fromJson(const ColumnLayout().toJson()),
        const ColumnLayout(),
      );
    });
  });
}
