import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/preview_sheet.dart';

/// A page of empty frames says nothing about whether the first picture is two
/// seconds away or forty, and the store has always known which — a cold harness
/// compiles the whole catalog and takes tens of seconds, where a warm one is a
/// message and a frame. These are the rules that put that on screen, and the
/// tiles are the whole of it: a counted strip over the top of them said the
/// same thing a second time, and went.
///
/// The no-spinner rule survives all of it. A shimmer is a surface treatment
/// rather than a control, so a hundred and fifty of them read as one page
/// loading where a hundred and fifty spinners read as a hundred and fifty
/// problems — and the queued tile, which is seconds away, gets no treatment at
/// all.
void main() {
  CatalogEntry entry(String symbol) => CatalogEntry(
    path: 'demo/a.dart',
    symbol: symbol,
    annotation: "Preview(name: '$symbol')",
    name: symbol,
  );

  var entries = [entry('alpha'), entry('beta'), entry('gamma')];

  Widget sheet({
    PreviewTileWait? Function(CatalogEntry entry)? waitOf,
    bool animate = false,
  }) => MaterialApp(
    home: Scaffold(
      body: PreviewSheet(
        sections: [
          PreviewSheetSection(
            label: 'Demos',
            entries: entries,
            pictureRatio: 0.75,
          ),
        ],
        screenOf: (_) => const Size(400, 300),
        waitOf: waitOf,
        animate: animate,
      ),
    ),
  );

  // The painter is the shimmer: every waiting tile that has a treatment is
  // painting one, and a tile that has none is painting nothing.
  Finder shimmers() => find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString().contains('Shimmer'),
  );

  testWidgets('a queued tile is a plain reserved box', (tester) async {
    await tester.pumpWidget(
      sheet(waitOf: (_) => PreviewTileWait.queued, animate: true),
    );
    expect(
      shimmers(),
      findsNothing,
      reason: 'seconds away is not news, and a treatment for it is noise',
    );
  });

  testWidgets('a compiling tile shimmers', (tester) async {
    await tester.pumpWidget(
      sheet(waitOf: (_) => PreviewTileWait.compiling, animate: true),
    );
    expect(shimmers(), findsNWidgets(entries.length));
  });

  testWidgets('nothing waiting draws nothing', (tester) async {
    await tester.pumpWidget(sheet());
    expect(shimmers(), findsNothing);
  });

  testWidgets('one ticker for the sheet, stopped when nothing is pending', (
    tester,
  ) async {
    // A hundred and fifty controllers is a hundred and fifty tickers, on
    // exactly the frames where the thing being waited for wants every core.
    await tester.pumpWidget(
      sheet(waitOf: (_) => PreviewTileWait.compiling, animate: true),
    );
    expect(
      tester.binding.transientCallbackCount,
      1,
      reason: 'one controller at the sheet, read down the tree',
    );
    await tester.pumpWidget(sheet(waitOf: (_) => PreviewTileWait.compiling));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the tile being rendered is marked, and it is not a selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewSheet(
            sections: [
              PreviewSheetSection(
                label: 'Demos',
                entries: entries,
                pictureRatio: 0.75,
              ),
            ],
            screenOf: (_) => const Size(400, 300),
            selectedId: entries.first.id,
            waitOf: (entry) => entry.id == entries[1].id
                ? PreviewTileWait.rendering
                : PreviewTileWait.queued,
            animate: true,
          ),
        ),
      ),
    );
    // The mark is the shimmer plus a hairline; the selection is two pixels of
    // the same colour over a tinted fill. Only the marked one paints.
    expect(shimmers(), findsOneWidget);
  });
}
