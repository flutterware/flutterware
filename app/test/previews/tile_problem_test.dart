import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/preview_sheet.dart';

/// What a red tile says when you point at it.
///
/// The page already knew: the store hands the sheet a reason per entry — *the
/// harness returned nothing for this entry*, a compiler diagnostic — and the
/// tile spent it on a red border and a 16px mark and then said nothing at all.
/// The words were reachable only by hovering the same entry's row in the tree
/// beside it, which is not where somebody looking at a red tile is pointing.
void main() {
  CatalogEntry entry(String symbol) => CatalogEntry(
    path: 'demo/a.dart',
    symbol: symbol,
    annotation: "Preview(name: '$symbol')",
    name: symbol,
  );

  var alpha = entry('alpha');
  var beta = entry('beta');

  Widget sheet({String? Function(CatalogEntry entry)? problemOf}) =>
      MaterialApp(
        home: Scaffold(
          body: PreviewSheet(
            sections: [
              PreviewSheetSection(
                label: 'Demos',
                entries: [alpha, beta],
                pictureRatio: 0.75,
              ),
            ],
            screenOf: (_) => const Size(400, 300),
            problemOf: problemOf,
          ),
        ),
      );

  /// Parks a mouse on [target] long enough for a tooltip to be shown.
  Future<void> hover(WidgetTester tester, Finder target) async {
    var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(target));
    // The wait is a timer rather than a frame — `Tooltip.waitDuration` — so
    // pumping alone reports a settled screen with nothing on it.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('the reason is on the tile that is red, and only that one', (
    tester,
  ) async {
    await tester.pumpWidget(
      sheet(
        problemOf: (found) => found.id == alpha.id
            ? 'the harness returned nothing for this entry'
            : null,
      ),
    );
    expect(find.byType(Tooltip), findsOneWidget);

    // **The whole picture box, not the mark inside it.** The mark is 16 points
    // square, and a target you have to hit to be told why a tile is red is one
    // nobody hits.
    expect(tester.getSize(find.byType(Tooltip)).shortestSide, greaterThan(16));

    await hover(tester, find.byType(Tooltip));
    expect(
      find.text('the harness returned nothing for this entry'),
      findsOneWidget,
    );
  });

  testWidgets('a tile with nothing wrong has nothing to say', (tester) async {
    await tester.pumpWidget(sheet());
    await hover(tester, find.text('alpha'));
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('a diagnostic is capped rather than unrolled', (tester) async {
    // A compiler's answer runs to dozens of lines; a tooltip is a glance, and
    // opening the entry is where the whole of it is.
    var diagnostic = [for (var i = 1; i <= 20; i++) 'line $i'].join('\n');
    await tester.pumpWidget(sheet(problemOf: (_) => diagnostic));
    await hover(tester, find.text('alpha'));

    var shown = tester.widget<Tooltip>(find.byType(Tooltip).first).message!;
    expect(shown, startsWith('line 1\n'));
    expect(shown, contains('line 6'));
    expect(shown, isNot(contains('line 7')));
    expect(shown, endsWith('…'), reason: 'a cut that says it is one');
  });
}
