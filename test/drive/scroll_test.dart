import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';

/// The wheel.
///
/// A wheel turn is a pointer *signal*, which is a different path through the
/// framework than a drag and a different question than [Drive.scrollTo]: the
/// framework hit-tests it to whatever is under the pointer and hands it to
/// that. These are about the two things that follow from it — that the pane
/// under the pointer is the one that moves, and that the sign is the wheel's
/// rather than the finger's.
void main() {
  const instant = Duration.zero;

  /// Two independent lists side by side, each with its own labels. A verb that
  /// picks "the first `Scrollable`" moves the wrong one and this notices.
  Widget twoLists() => MaterialApp(
    home: Scaffold(
      body: Row(
        children: [
          for (var side in ['L', 'R'])
            Expanded(
              child: SizedBox(
                height: 300,
                child: ListView(
                  children: [
                    for (var i = 0; i < 40; i++)
                      SizedBox(height: 50, child: Text('$side$i')),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );

  /// The two lists in tree order — left, then right. By position rather than
  /// by a row's text, because the row a scroll started from is disposed the
  /// moment it leaves the viewport.
  double offsetOf(WidgetTester tester, int list) => tester
      .state<ScrollableState>(find.byType(Scrollable).at(list))
      .position
      .pixels;

  testWidgets('the wheel moves the pane under the pointer, not the first one', (
    tester,
  ) async {
    await tester.pumpWidget(twoLists());
    var drive = Drive();

    await drive.scroll('R0', const Offset(0, 400), settle: instant);
    await tester.pump();

    expect(find.byType(Scrollable), findsNWidgets(2));
    expect(offsetOf(tester, 1), 400);
    expect(
      offsetOf(tester, 0),
      0,
      reason: 'the left list was never under the pointer',
    );
  });

  /// The sign is the wheel's, not the finger's. The delta is added to the
  /// scroll offset, so positive `dy` moves *down* the list — where `drag` wants
  /// a negative `dy` to achieve the same thing. Both conventions belong to the
  /// platform; getting them backwards is the one mistake this verb invites.
  testWidgets('positive dy moves down the list', (tester) async {
    await tester.pumpWidget(twoLists());
    var drive = Drive();

    await drive.scroll('L0', const Offset(0, 300), settle: instant);
    await tester.pump();
    expect(offsetOf(tester, 0), 300);

    await drive.scroll('L6', const Offset(0, -100), settle: instant);
    await tester.pump();
    expect(offsetOf(tester, 0), 200, reason: 'negative goes back up');
  });

  /// A wheel reaches a list by being over it, so the mouse is moved there
  /// first — which means a scroll leaves the target hovered, exactly as a real
  /// mouse does, and `unhover` is what ends that.
  testWidgets('scrolling parks the mouse, and unhover releases it', (
    tester,
  ) async {
    var hovering = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ListView(
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(
                    height: 50,
                    child: MouseRegion(
                      onEnter: (_) => hovering.add('$i'),
                      onExit: (_) => hovering.remove('$i'),
                      child: Text('Row $i'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    var drive = Drive();

    await drive.scroll('Row 0', const Offset(0, 100), settle: instant);
    await tester.pump();
    expect(hovering, isNotEmpty);
    expect(drive.hovering, contains('Row 0'));

    await drive.unhover(hold: instant, settle: instant);
    await tester.pump();

    expect(hovering, isEmpty);
    expect(drive.hovering, isNull);
  });

  /// The same resolve ladder as every other verb: a target that matches nothing
  /// is refused with the screen it was refused on, rather than turning the
  /// wheel over an arbitrary point.
  testWidgets('a target that matches nothing is refused', (tester) async {
    await tester.pumpWidget(twoLists());
    var drive = Drive()..actTimeout = Duration.zero;

    await expectLater(
      drive.scroll('Z9', const Offset(0, 100), settle: instant),
      throwsA(isA<Object>().having((e) => '$e', 'message', contains('Z9'))),
    );
  });
}
