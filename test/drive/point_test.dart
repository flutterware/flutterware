import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';
import 'package:flutterware/src/drive/resolve.dart';
import 'package:flutterware/src/scenarios/target.dart';

/// `{"at": {x, y}}` — the target that says *where* rather than *what*.
///
/// It exists for the surfaces whose regions are painted rather than laid out:
/// an SVG map, a chart, a signature pad. There every region shares one widget
/// and one box, so the centre of what a point resolves to is a different
/// region altogether, and pressing it is not what anybody asked for.
void main() {
  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a verb presses the point, not the widget it resolved', (
    tester,
  ) async {
    var canvas = _Canvas();
    await tester.pumpWidget(app(canvas.build()));
    var drive = Drive();

    await drive.tap(const Target.at(120, 300), settle: Duration.zero);

    expect(canvas.pressed, const Offset(120, 300));
    // The centre is what it used to press, and on a full-bleed canvas that is
    // the middle of the screen — a different region every time.
    expect(canvas.pressed, isNot(tester.getCenter(find.byType(_Painted))));
  });

  testWidgets('a long press and a drag go down there too', (tester) async {
    var canvas = _Canvas();
    await tester.pumpWidget(app(canvas.build()));
    var drive = Drive();

    // `runAsync` for the same reason `doubleTap` needs it: the hold is
    // `kLongPressTimeout` of real elapsed time, which nobody advances in the
    // ordinary test zone.
    await tester.runAsync(
      () => drive.longPress(const Target.at(120, 300), settle: Duration.zero),
    );
    expect(canvas.held, const Offset(120, 300));

    await drive.drag(
      const Target.at(120, 300),
      const Offset(0, -200),
      settle: Duration.zero,
    );
    // The *down*, not the pan start: a pan is recognized once the finger has
    // travelled past the slop, so its start is 20pt along and says nothing
    // about where the gesture began.
    expect(canvas.dragged, const Offset(120, 300));
    expect(canvas.travelled?.dy, lessThan(-150));
  });

  testWidgets('a target that says what still presses its centre', (
    tester,
  ) async {
    var pressed = <Offset>[];
    await tester.pumpWidget(
      app(
        Center(
          child: GestureDetector(
            onTapDown: (d) => pressed.add(d.globalPosition),
            child: const Text('Handle'),
          ),
        ),
      ),
    );
    var drive = Drive();

    await drive.tap('Handle', settle: Duration.zero);

    expect(pressed.single, tester.getCenter(find.text('Handle')));
  });

  /// The refusal half. The reachability check hit-tested the *centre* of
  /// whatever the point resolved to, so a canvas with anything over its
  /// middle failed that check at every point on it — including the ones
  /// plainly showing.
  ///
  /// Measured with the centre check put back: this case does not fail, it
  /// hangs. A target that does not reach goes to `ensureVisible` and a pump,
  /// and the live controller a widget test drives never returns from one.
  /// In the app it is a `covered` refusal about a point you can see.
  testWidgets('a point still showing is not refused for a covered centre', (
    tester,
  ) async {
    var canvas = _Canvas();
    await tester.pumpWidget(
      app(
        Stack(
          children: [
            Positioned.fill(child: canvas.build()),
            Center(
              child: Container(width: 400, height: 300, color: Colors.white),
            ),
          ],
        ),
      ),
    );
    var drive = Drive();

    await drive.tap(const Target.at(40, 60), settle: Duration.zero);

    expect(canvas.pressed, const Offset(40, 60));
  });

  /// And the other direction: the ladder still runs. A point *under* the
  /// sheet resolves to the sheet, so the canvas never hears it — the point
  /// form buys a contact, not a way past what is on top.
  testWidgets('a point under a covering resolves to the covering', (
    tester,
  ) async {
    var canvas = _Canvas();
    var sheet = 0;
    await tester.pumpWidget(
      app(
        Stack(
          children: [
            Positioned.fill(child: canvas.build()),
            Center(
              child: GestureDetector(
                onTap: () => sheet++,
                child: Container(width: 400, height: 300, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
    var drive = Drive();

    var centre = tester.getCenter(find.byType(_Painted));
    await drive.tap(Target.at(centre.dx, centre.dy), settle: Duration.zero);

    expect(sheet, 1);
    expect(canvas.pressed, isNull);
  });

  /// A point off the screen reaches nothing but the view, which every hit
  /// test reports — so resolving to "whatever was hit" tapped the root and
  /// said `ok`. It is a miss, and the miss names the screen's size, because
  /// the usual way to get here is a coordinate in physical pixels.
  testWidgets('a point off the screen is refused, with the screen size', (
    tester,
  ) async {
    var canvas = _Canvas();
    await tester.pumpWidget(app(canvas.build()));
    var drive = Drive()..actTimeout = Duration.zero;

    TargetError? refusal;
    try {
      await drive.tap(const Target.at(1800, 900), settle: Duration.zero);
    } on TargetError catch (error) {
      refusal = error;
    }

    expect(refusal?.failure, TargetFailure.notFound);
    expect('$refusal', contains('outside the screen'));
    expect('$refusal', contains('800 × 600 logical pixels'));
    expect(canvas.pressed, isNull);
  });

  test('only a point target names a point', () {
    expect(pointOf(const Target.at(1, 2)), const Offset(1, 2));
    expect(pointOf('Handle'), isNull);
    expect(pointOf(const Target.label('Handle')), isNull);
    // Composition is about lookups: a point inside `nth` named a scope to
    // search, not a place to put a finger.
    expect(pointOf(const Target.nth(Target.at(1, 2), 0)), isNull);
  });
}

/// A full-bleed surface whose regions are painted: every gesture on it lands
/// on the same widget, and only the coordinate says which region was meant.
class _Canvas {
  Offset? pressed;
  Offset? held;
  Offset? dragged;
  Offset? travelled;

  Widget build() => GestureDetector(
    onTapDown: (d) => pressed = d.globalPosition,
    onLongPressStart: (d) => held = d.globalPosition,
    onPanDown: (d) => dragged = d.globalPosition,
    onPanUpdate: (d) => travelled = (travelled ?? Offset.zero) + d.delta,
    child: const _Painted(),
  );
}

class _Painted extends StatelessWidget {
  const _Painted();

  @override
  Widget build(BuildContext context) =>
      Container(color: const Color(0xFF202020));
}
