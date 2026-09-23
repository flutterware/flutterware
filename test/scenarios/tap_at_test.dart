import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// What `tap(target)` cannot say: **where** on a widget the finger goes down.
///
/// A map, a chart, an SVG: the regions are painted rather than built, so they
/// share one widget and one box, and a target that says *what* comes back to
/// that box's centre. Reported by a consumer aiming at an SVG's hit-test
/// regions, who had `dragFrom(point, Offset.zero)` as the only spelling — the
/// right gesture arrived at sideways, and a report that says `dragFrom` about
/// a tap.
///
/// `tap(Target.at(x, y))` presses the same point, and these tests hold the
/// two to it. What `tapAt` is for is the gesture that needs no widget to
/// resolve, and a step that reads as what the author meant.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('tapAt', () {
    scenario('presses the point, not the widget under it', (s) async {
      var canvas = _Regions();
      await s.pumpWidget(_Map(canvas));

      await s.tapAt(const Offset(200, 500));
      expect(canvas.pressed, const Offset(200, 500));

      // The other spelling of the same press. `Target.at` names a coordinate
      // and a coordinate is where the finger goes down, so these two land in
      // the same place — what separates them is that this one resolves the
      // widget under the point first, and so can refuse what it cannot
      // reach, and that the step it writes says `tap` rather than `tapAt`.
      canvas.reset();
      await s.tap(const Target.at(200, 500));
      expect(canvas.pressed, const Offset(200, 500));
    });
    tearDown(() {
      // The step says what the author meant. It is a tap, spelled as a tap,
      // and the report reads it as one.
      expect(captures[1].verb, 'tapAt');
      expect(captures[1].target, '200,500');

      // The mark is the point itself: a box of no size, as on `dragFrom`.
      // Inventing a box would draw a ring around whatever happens to lie
      // under the finger, as though the verb had resolved it.
      var aim = captures[1].aim!;
      expect((aim.x, aim.y), (200.0, 500.0));
      expect((aim.width, aim.height), (0.0, 0.0));
      expect((aim.dx, aim.dy), (null, null));

      // And the same mark for the same press said the other way. `point` is
      // derived from the rect rather than recorded beside it, so a verb that
      // pressed a point and marked the canvas it resolved would put the ring
      // in the middle of the screen — a picture of a press that never
      // happened.
      var byTarget = captures[2].aim!;
      expect(captures[2].verb, 'tap');
      expect((byTarget.x, byTarget.y), (200.0, 500.0));
      expect((byTarget.width, byTarget.height), (0.0, 0.0));
      expect(byTarget.point, (200.0, 500.0));
    });
  });

  group('a point target on the verbs that take one', () {
    scenario('is where the finger goes down for each of them', (s) async {
      var canvas = _Regions();
      await s.pumpWidget(_Map(canvas));

      await s.longPress(const Target.at(120, 300));
      expect(canvas.held, const Offset(120, 300));

      await s.drag(const Target.at(120, 300), const Offset(0, -200));
      expect(canvas.dragged, const Offset(120, 300));
      expect(canvas.travelled?.dy, lessThan(-150));
    });
  });

  // `enterText` is deliberately not on that list: it focuses the editable and
  // pushes a value, with no pointer anywhere, so it has no contact point to
  // move. Its mark stays the editable's own box — the line the text lands on.
  group('enterText keeps the field it is about to fill', () {
    Rect? field;
    scenario('even when the target that found it was a point', (s) async {
      await s.pumpWidget(const _Form());

      await s.enterText(const Target.at(200, 300), 'hello');

      expect(find.text('hello'), findsOneWidget);
      field = s.tester.getRect(find.byType(EditableText));
    });
    tearDown(() {
      var aim = captures.firstWhere((c) => c.verb == 'enterText').aim!;
      expect((aim.x, aim.y), (field!.left, field!.top));
      expect((aim.width, aim.height), (field!.width, field!.height));
    });
  });
}

/// Where the finger went down on the canvas.
class _Regions {
  Offset? pressed;
  Offset? held;
  Offset? dragged;
  Offset? travelled;

  void reset() => pressed = null;
}

class _Form extends StatelessWidget {
  const _Form();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Padding(padding: EdgeInsets.only(top: 280), child: TextField()),
    ),
  );
}

class _Map extends StatelessWidget {
  const _Map(this.regions);

  final _Regions regions;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: GestureDetector(
        onTapDown: (details) => regions.pressed = details.globalPosition,
        onLongPressStart: (details) => regions.held = details.globalPosition,
        // The *down*, not the pan start: a pan is recognized once the finger
        // has travelled past the slop, so its start is 20pt along and says
        // nothing about where the gesture began.
        onPanDown: (details) => regions.dragged = details.globalPosition,
        onPanUpdate: (details) => regions.travelled =
            (regions.travelled ?? Offset.zero) + details.delta,
        child: Container(color: const Color(0xFF202020)),
      ),
    ),
  );
}
