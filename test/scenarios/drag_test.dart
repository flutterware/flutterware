import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The two things `drag(target, by)` cannot say.
///
/// **Where the finger goes down**, when the thing to grab is painted rather
/// than built — a canvas, a chart, a map, a signature pad. Naming the widget
/// grabs its centre, which on a full-bleed canvas is somewhere else entirely.
/// (`drag(Target.at(…), by)` says it too, and lands in the same place; what
/// `dragFrom` adds is a gesture that needs no widget to resolve, and a step
/// that reads as the point verb it is.)
///
/// **How fast it travels**, when the velocity is the point. A flick and a
/// slow pull cover identical distance and a list keeps scrolling after only
/// one of them, so a fling that must — or must not — overscroll is not a
/// question about an offset.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('dragFrom', () {
    scenario('goes down on the point, not on the widget under it', (s) async {
      var canvas = _Gesture();
      await s.pumpWidget(_Canvas(canvas));
      await s.dragFrom(const Offset(200, 500), const Offset(0, -400));
      expect(canvas.start, const Offset(200, 500));
      expect(canvas.travelled?.dy, lessThan(-300));

      // `Target.at` is the same gesture said the other way round: a
      // coordinate is where the finger goes down, whichever spelling names
      // it. The pair is not redundant — this one resolves the widget under
      // the point and refuses what it cannot reach, and the step it writes
      // says `drag` where the other says `dragFrom`.
      canvas.reset();
      await s.drag(const Target.at(200, 500), const Offset(0, -400));
      expect(canvas.start, const Offset(200, 500));
    });
    tearDown(() {
      // The mark is the point itself: a box of no size, which is the honest
      // shape of what the author said.
      var aim = captures[1].aim!;
      expect((aim.x, aim.y), (200.0, 500.0));
      expect((aim.width, aim.height), (0.0, 0.0));
      expect((aim.dx, aim.dy), (0.0, -400.0));
      expect(captures[1].verb, 'dragFrom');
      expect(captures[1].target, '200,500');
    });
  });

  group('a drag with a duration', () {
    scenario('arrives with the velocity that duration implies', (s) async {
      var controller = ScrollController();
      await s.pumpWidget(_List(controller));

      // The plain form moves the finger in one jump, so the velocity tracker
      // sees the whole distance in no time at all and reports *nothing*: the
      // list stops dead where the finger stopped. That is the right gesture
      // for a dismiss or a slider and it is why a fling could not be written
      // here before — no offset makes this one overscroll.
      await s.drag(_List, const Offset(0, -300));
      expect(controller.offset, 300);
      controller.jumpTo(0);

      // Spread over a second, the same distance is a 300pt/s pull, and the
      // list carries a little past the finger.
      await s.drag(
        _List,
        const Offset(0, -300),
        duration: const Duration(seconds: 1),
      );
      var pull = controller.offset;
      expect(pull, greaterThan(310));
      controller.jumpTo(0);

      // Spread over 300ms it is a flick, and it carries much further — same
      // offset, three times the velocity, and the difference is the whole
      // reason this parameter exists.
      await s.drag(
        _List,
        const Offset(0, -300),
        duration: const Duration(milliseconds: 300),
      );
      expect(controller.offset, greaterThan(pull + 100));
    });
  });

  group('dragFrom with a duration', () {
    scenario('is the same pair of choices, made independently', (s) async {
      var canvas = _Gesture();
      await s.pumpWidget(_Canvas(canvas));
      await s.dragFrom(
        const Offset(200, 500),
        const Offset(0, -400),
        duration: const Duration(milliseconds: 300),
      );
      expect(canvas.start, const Offset(200, 500));
      expect(canvas.travelled?.dy, lessThan(-300));
    });
  });
}

/// Where the finger went down on the canvas, and how far it took it.
class _Gesture {
  Offset? start;
  Offset? travelled;

  void reset() {
    start = null;
    travelled = null;
  }
}

class _Canvas extends StatelessWidget {
  const _Canvas(this.gesture);

  final _Gesture gesture;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: GestureDetector(
        onPanStart: (details) => gesture.start = details.globalPosition,
        onPanUpdate: (details) => gesture.travelled =
            (gesture.travelled ?? Offset.zero) + details.delta,
        child: Container(color: const Color(0xFF202020)),
      ),
    ),
  );
}

class _List extends StatelessWidget {
  const _List(this.controller);

  final ScrollController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 200,
        itemBuilder: (context, i) =>
            SizedBox(height: 60, child: Text('row $i')),
      ),
    ),
  );
}
