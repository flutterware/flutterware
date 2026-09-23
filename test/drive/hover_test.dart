import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';

/// The mouse half of the verb engine.
///
/// The load-bearing claim is that a *synthesized* hover is indistinguishable
/// from the platform's own: `RendererBinding.dispatchEvent` feeds every pointer
/// event to `MouseTracker` before dispatching it, so nothing in the app has to
/// cooperate. These run against the test binding, which is the same
/// `RendererBinding` a real app has — what they cannot cover is the wall-clock
/// hold, which is fake time here.
void main() {
  /// Every verb here passes `hold: Duration.zero`: the hold is real elapsed
  /// time by construction, and `testWidgets` has none. What the hold buys is
  /// covered by the two tooltip cases instead, which advance fake time by hand.
  const instant = Duration.zero;

  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('a hover enters, and stays entered', (tester) async {
    var enters = 0;
    var exits = 0;
    await tester.pumpWidget(
      app(
        MouseRegion(
          onEnter: (_) => enters++,
          onExit: (_) => exits++,
          child: const Text('Hover me'),
        ),
      ),
    );
    var drive = Drive();

    await drive.hover('Hover me', hold: instant, settle: instant);
    await tester.pump();

    expect(enters, 1);
    expect(exits, 0, reason: 'a mouse does not leave because the step ended');
    expect(drive.hovering, contains('Hover me'));
  });

  testWidgets('unhover exits, and says what it released', (tester) async {
    var exits = 0;
    await tester.pumpWidget(
      app(MouseRegion(onExit: (_) => exits++, child: const Text('Hover me'))),
    );
    var drive = Drive();
    await drive.hover('Hover me', hold: instant, settle: instant);
    await tester.pump();

    var step = await drive.unhover(hold: instant, settle: instant);
    await tester.pump();

    expect(exits, 1);
    expect(step.target, contains('Hover me'));
    expect(drive.hovering, isNull);
  });

  /// Not a refusal: "there is no hover to end" is the state the caller asked
  /// for, and nothing about the screen is ambiguous.
  testWidgets('unhover with nothing parked is a no-op', (tester) async {
    await tester.pumpWidget(app(const Text('Nothing hovered')));
    var drive = Drive();

    var step = await drive.unhover(hold: instant, settle: instant);

    expect(step.verb, 'unhover');
    expect(step.target, isNull);
    expect(drive.hovering, isNull);
  });

  /// The second hover has to produce the first one's exit — otherwise two
  /// controls read as hovered at once and the screen lies about where the
  /// mouse is.
  testWidgets('moving the hover exits what it left', (tester) async {
    var on = <String>{};
    Widget spot(String label) => MouseRegion(
      onEnter: (_) => on.add(label),
      onExit: (_) => on.remove(label),
      child: Text(label),
    );
    await tester.pumpWidget(
      app(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [spot('A'), spot('B')],
        ),
      ),
    );
    var drive = Drive();

    await drive.hover('A', hold: instant, settle: instant);
    await tester.pump();
    expect(on, {'A'});

    await drive.hover('B', hold: instant, settle: instant);
    await tester.pump();

    expect(on, {'B'});
  });

  /// A hover is a mouse, and a `WidgetState.hovered` control is the everyday
  /// reason to reach for one.
  testWidgets('a material control reports itself hovered', (tester) async {
    var hovered = false;
    await tester.pumpWidget(
      app(
        TextButton(
          onPressed: () {},
          onHover: (value) => hovered = value,
          child: const Text('Save'),
        ),
      ),
    );
    var drive = Drive();

    await drive.hover('Save', hold: instant, settle: instant);
    await tester.pump();

    expect(hovered, isTrue);
  });

  /// The reason the hold exists, with the clock advanced by hand.
  ///
  /// A tooltip's `waitDuration` is a `Timer`: it schedules no frame, no ticker
  /// and no image decode until it fires, so every probe a settle has reads
  /// "nothing pending" while the tooltip is still on its way. Here fake time is
  /// pumped explicitly to stand in for the wall clock [Drive.hoverHold] burns.
  ///
  /// The tooltip arriving in `visibleTexts` is the other half of the point: it
  /// is an `OverlayEntry`, so it reaches the reply like any other widget, and
  /// "does this control explain itself" becomes machine-readable.
  testWidgets('a tooltip needs the hold, and then shows up in the texts', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const Tooltip(
          message: 'Saves the document',
          waitDuration: Duration(milliseconds: 400),
          child: Text('Save'),
        ),
      ),
    );
    var drive = Drive();

    await drive.hover('Save', hold: instant, settle: instant);
    await tester.pump();
    expect(
      drive.visibleTexts(),
      isNot(contains('Saves the document')),
      reason: 'the wait has not elapsed — this is what settling alone sees',
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(drive.visibleTexts(), contains('Saves the document'));
  });

  /// The exit is on a timer too (`_hoverExitDuration`), which is why `unhover`
  /// holds as well rather than only settling.
  testWidgets('unhover takes the tooltip back down', (tester) async {
    await tester.pumpWidget(
      app(
        const Tooltip(
          message: 'Saves the document',
          waitDuration: Duration(milliseconds: 400),
          child: Text('Save'),
        ),
      ),
    );
    var drive = Drive();
    await drive.hover('Save', hold: instant, settle: instant);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(drive.visibleTexts(), contains('Saves the document'));

    await drive.unhover(hold: instant, settle: instant);
    await tester.pumpAndSettle();

    expect(drive.visibleTexts(), isNot(contains('Saves the document')));
  });

  /// A hover resolves through the same ladder as every other verb, so a target
  /// that matches nothing is refused with the screen it was refused on rather
  /// than parking the pointer somewhere arbitrary.
  testWidgets('a target that matches nothing is refused', (tester) async {
    await tester.pumpWidget(app(const Text('Only this')));
    var drive = Drive()..actTimeout = Duration.zero;

    await expectLater(
      drive.hover('Not here', hold: instant, settle: instant),
      throwsA(
        isA<Object>().having(
          (e) => '$e',
          'message',
          allOf(contains('Not here'), contains('Only this')),
        ),
      ),
    );
    expect(drive.hovering, isNull);
  });
}
