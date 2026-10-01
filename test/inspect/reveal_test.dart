import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/reveal.dart';

/// `--node` on a list longer than the screen.
///
/// The picture used to be of the list at rest, so a row half off the bottom
/// was cropped to its visible half — a picture that looks right — and a row
/// the list had not built yet was "nothing is called that".
void main() {
  // Rows of 110 on a 600-tall screen: row 5 straddles the bottom edge, and
  // the list builds only up to its 250 of cache below that.
  Widget menu({String Function(int)? name}) => Directionality(
    textDirection: TextDirection.ltr,
    child: ListView(
      children: [
        for (var i = 0; i < 60; i++)
          SizedBox(height: 110, child: Text(name?.call(i) ?? 'Row $i.')),
      ],
    ),
  );

  Future<GuestInspector> stage(WidgetTester tester, Widget widget) async {
    tester.view
      ..physicalSize = const Size(400, 600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    return GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => null,
    );
  }

  double offsetOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  testWidgets('a row half off the bottom is brought wholly on screen', (
    tester,
  ) async {
    var inspector = await stage(tester, menu());
    expect(tester.getRect(find.text('Row 5.')).bottom, greaterThan(600));

    var revealed = await revealNode(
      inspector,
      'Row 5.',
      pump: () => tester.pump(),
    );

    // Minimal: just far enough for its bottom edge, not aligned to the top.
    expect(revealed.scrolled, 60);
    expect(tester.getRect(find.text('Row 5.')).bottom, 600);
    expect(
      inspector.read().nodeAt(revealed.id!)?.description,
      'Text("Row 5.")',
    );
  });

  testWidgets('a row the list has not built is walked to', (tester) async {
    var inspector = await stage(tester, menu());
    expect(find.text('Row 30.'), findsNothing);

    var revealed = await revealNode(
      inspector,
      'Row 30.',
      pump: () => tester.pump(),
    );

    var rect = tester.getRect(find.text('Row 30.'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(600));
    expect(revealed.scrolled, offsetOf(tester));
    // The id is the scrolled tree's, which is the point of reporting it: the
    // same position at rest is another row.
    expect(
      inspector.read().nodeAt(revealed.id!)?.description,
      'Text("Row 30.")',
    );
  });

  testWidgets('an id is never walked for', (tester) async {
    var inspector = await stage(tester, menu());
    // Past the rows built at rest, so it names nothing now — and would name
    // some row once the list had scrolled.
    var revealed = await revealNode(
      inspector,
      '0/0/0/40',
      pump: () => tester.pump(),
    );

    expect(revealed.id, isNull);
    expect(offsetOf(tester), 0);
  });

  testWidgets('a name nothing carries leaves every list where it was', (
    tester,
  ) async {
    var inspector = await stage(tester, menu());
    var revealed = await revealNode(
      inspector,
      'Nonesuch',
      pump: () => tester.pump(),
    );

    expect(revealed.id, isNull);
    expect(revealed.scrolled, 0);
    expect(offsetOf(tester), 0);
  });

  testWidgets('a node already on screen moves nothing', (tester) async {
    var inspector = await stage(tester, menu());
    var before = inspector.read().places('Row 1.').single.id;

    var revealed = await revealNode(
      inspector,
      'Row 1.',
      pump: () => tester.pump(),
    );

    expect(revealed.scrolled, 0);
    expect(revealed.id, before);
  });

  testWidgets('several side by side past the fold are refused, and put back', (
    tester,
  ) async {
    var inspector = await stage(
      tester,
      menu(name: (i) => i == 30 || i == 31 ? 'Row $i. twin' : 'Row $i.'),
    );

    var revealed = await revealNode(
      inspector,
      'twin',
      pump: () => tester.pump(),
    );

    expect(revealed.id, isNull);
    expect(revealed.refused, contains('2 widgets side by side'));
    expect(revealed.refused, contains('narrow the text'));
    expect(offsetOf(tester), 0);
  });
}
