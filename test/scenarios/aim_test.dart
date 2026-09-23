import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// Where the verb went.
///
/// A scenario runs with no cursor on screen, so nothing in a picture says
/// which of six drinks was tapped. The verbs measure what they were about to
/// act on, on the frame they were about to act on it, and it rides the step
/// they produce.
///
/// **Three shapes, and the rect means something different in each.** A
/// pointer verb records the box its finder resolved. `enterText` records the
/// *editable*, because that is what it acts on whatever the target named.
/// `scrollTo` and `keyboard` act on a region and record one, with [toward]
/// saying which way it moves — the case the whole design has to get right,
/// since a `scrollTo`'s target is usually not on the frame the mark is drawn
/// on and a box around it would point at empty space.
void main() {
  // Cleared rather than replaced: the groups below are handed this list, and
  // a fresh one per test would leave them holding the first.
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures.clear();
    scenarioRunListener = captures.add;
  });
  tearDown(() {
    scenarioRunListener = null;
    scenarioRunArgs = null;
  });

  group('a tap records the box it resolved', () {
    scenario('measured before the tap, on the screen it acted on', (s) async {
      await s.pumpWidget(const _App());
      // Two identical buttons, 200 logical pixels apart: a rect that came from
      // the wrong one is a failure this test can see.
      await s.tap('Second');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      // **The finder's box, not the button's.** `tap('Second')` resolves the
      // `Text`, and the tap lands at its centre — so the box is the word's,
      // sitting inside the 40-high target that handles the gesture. That is
      // the truth of what the verb aimed at, and it is why a viewer marks the
      // point as well as the box.
      expect(aim.y, greaterThan(300), reason: 'inside the second button');
      expect(aim.y + aim.height, lessThan(340));
      expect(aim.height, lessThan(40), reason: 'the word, not the button');
      expect(aim.point, (aim.x + aim.width / 2, aim.y + aim.height / 2));
      expect(aim.dx, isNull, reason: 'a tap does not travel');
    });
  });

  group('a verb with nothing to point at records nothing', () {
    scenario('and does not inherit the last verb that had one', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Second');
      await s.wait(const Duration(milliseconds: 10));
    });
    tearDown(() {
      expect(captures[captures.length - 2].aim, isNotNull, reason: 'the tap');
      expect(captures.last.aim, isNull, reason: 'the wait after it');
    });
  });

  group('a drag records where it went and how far', () {
    scenario("the offset is the verb's own", (s) async {
      await s.pumpWidget(const _App());
      await s.drag('Second', const Offset(0, -80));
    });
    tearDown(() {
      var aim = captures.last.aim!;
      expect((aim.dx, aim.dy), (0.0, -80.0));
      expect(aim.y, greaterThan(300), reason: 'where it started, not ended');
      expect(aim.y, lessThan(340));
    });
  });

  group('a long press aims like a tap', () {
    scenario('same box, no travel', (s) async {
      await s.pumpWidget(const _App());
      await s.longPress('First');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      expect(aim.y, greaterThan(100), reason: 'inside the first button');
      expect(aim.y, lessThan(140));
      expect(aim.dx, isNull);
    });
  });

  group('the aim survives the report', () {
    scenario('written and read back as the same box', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Second');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      var read = ScenarioAim.fromJson(aim.toJson())!;
      expect(
        (read.x, read.y, read.width, read.height),
        (aim.x, aim.y, aim.width, aim.height),
      );
      // A report written before any of this simply has no aim, and a viewer
      // draws nothing rather than guessing.
      expect(ScenarioAim.fromJson(null), isNull);
    });
  });

  _regions(captures);
}

/// Two buttons at known heights, so a wrong box is a wrong number.
class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          for (var (top, label) in [(100.0, 'First'), (300.0, 'Second')])
            Positioned(
              top: top,
              left: 20,
              child: SizedBox(
                height: 40,
                width: 120,
                child: GestureDetector(
                  onTap: () {},
                  onLongPress: () {},
                  child: Center(child: Text(label)),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

void _regions(List<ScenarioStepCapture> captures) {
  group('enterText aims at the editable, not at what named it', () {
    late Rect field;
    scenario('a keyed field gives the text area inside it', (s) async {
      await s.pumpWidget(const _Form());
      field = s.tester.getRect(find.byKey(const Key('name')));
      await s.enterText(const Key('name'), 'Ada');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      var box = Rect.fromLTWH(aim.x, aim.y, aim.width, aim.height);
      // Inside the field and half its height: the decoration's padding is
      // the difference, and it is the proof that the box came from the
      // editable rather than from the `TextField` the target named. The text
      // line, in other words — which is where the typing lands.
      expect(box.top, greaterThan(field.top));
      expect(box.bottom, lessThan(field.bottom));
      expect(box.left, greaterThanOrEqualTo(field.left));
      expect(box.right, lessThanOrEqualTo(field.right));
      expect(aim.toward, isNull, reason: 'typing does not travel');
      expect(aim.dx, isNull);
    });
  });

  group('scrollTo records the pane and the way', () {
    late Rect pane;
    scenario('down the list, when the target is not built yet', (s) async {
      await s.pumpWidget(const _List());
      pane = s.tester.getRect(find.byType(Scrollable));
      await s.scrollTo('Row 40');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      // The viewport, not the row: on the frame this is drawn over, `Row 40`
      // is not built, so its box does not exist to be drawn.
      expect((aim.x, aim.y), (pane.left, pane.top));
      expect((aim.width, aim.height), (pane.width, pane.height));
      expect(aim.toward, 'down');
    });
  });

  group('and the way is where the target actually is', () {
    scenario('back up the list, once the walk has gone past it', (s) async {
      await s.pumpWidget(const _List());
      await s.scrollTo('Row 40');
      await s.scrollTo('Row 1', step: -200);
    });
    tearDown(() => expect(captures.last.aim!.toward, 'up'));
  });

  group('a target already in the pane is boxed where it stands', () {
    scenario('nothing travels, so nothing promises a direction', (s) async {
      await s.pumpWidget(const _List());
      await s.scrollTo('Row 2');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      expect(aim.toward, isNull, reason: 'it is already here');
      // The row, not the viewport: a row is a fraction of the pane's height.
      expect(aim.height, lessThan(120));
    });
  });

  group('and a row as wide as its pane is still in it', () {
    late Rect pane;
    scenario('the edges count as inside', (s) async {
      await s.pumpWidget(const _List(fullWidth: true));
      pane = s.tester.getRect(find.byType(Scrollable));
      await s.scrollTo(const Key('row2'));
    });
    tearDown(() {
      var aim = captures.last.aim!;
      // `Rect.contains` is half-open on the right and the bottom, so the one
      // shape every list actually has — a row exactly as wide as its pane —
      // read as being somewhere else, and the mark promised a scroll for a
      // row already on screen.
      expect(aim.width, pane.width, reason: 'the row spans the pane');
      expect(aim.height, 80, reason: 'the row, not the 600-high viewport');
      expect(aim.toward, isNull, reason: 'nothing has to travel');
    });
  });

  group('a page with nothing to scroll still marks the target', () {
    // Named, because a `scrollTo` that drew nothing skips its automatic shot
    // — so this branch reaches a step only when the author asked for a
    // picture, which is exactly when somebody would hover it.
    scenario('the verb no-ops, and says where the thing already is', (s) async {
      await s.pumpWidget(const _App());
      await s.scrollTo('Second', shot: Shot('Already there'));
    });
    tearDown(() {
      var aim = captures.last.aim!;
      expect(aim.toward, isNull, reason: 'nothing scrolls');
      expect(aim.y, greaterThan(300), reason: 'the second button');
      expect(aim.y, lessThan(340));
    });
  });

  group('the keyboard aims at the band it takes', () {
    setUp(() {
      scenarioRunArgs = ScenarioRunArgs.forAssignment(
        ScenarioAssignment(device: deviceById('iphone-16')!),
      );
    });
    scenario('up, then down again', (s) async {
      await s.pumpWidget(const _Form());
      await s.keyboard.show();
      await s.keyboard.hide();
    });
    tearDown(() {
      var rising = captures[captures.length - 2].aim!;
      expect(rising.height, 336, reason: "the iPhone 16's measurement");
      expect(rising.width, 393, reason: "the iPhone 16's width");
      expect(rising.toward, 'up');
      expect(rising.y + rising.height, 852, reason: 'flush with the bottom');
      expect(captures.last.aim!.toward, 'down');
    });
  });

  group('a keyboard verb that moves nothing marks nothing', () {
    setUp(() {
      scenarioRunArgs = ScenarioRunArgs.forAssignment(
        ScenarioAssignment(device: deviceById('iphone-16')!),
      );
    });
    scenario('hiding a keyboard that is already down', (s) async {
      await s.pumpWidget(const _Form());
      await s.keyboard.hide();
    });
    tearDown(() {
      expect(
        captures.last.aim,
        isNull,
        reason:
            'a mark promising a movement that does not happen is worse '
            'than no mark',
      );
    });
  });

  group('a direction survives the report', () {
    scenario('written and read back as the same word', (s) async {
      await s.pumpWidget(const _List());
      await s.scrollTo('Row 40');
    });
    tearDown(() {
      var aim = captures.last.aim!;
      expect(ScenarioAim.fromJson(aim.toJson())!.toward, 'down');
      // Additive: a report written before there was a direction has none.
      expect(
        ScenarioAim.fromJson({'x': 1, 'y': 2, 'w': 3, 'h': 4})!.toward,
        isNull,
      );
    });
  });
}

/// One keyed field, so `enterText` has a target that is not the editable.
class _Form extends StatelessWidget {
  const _Form();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: EdgeInsets.all(40),
        child: TextField(key: Key('name')),
      ),
    ),
  );
}

/// A list long enough that its far end is not built.
///
/// [fullWidth] keys each row and lets it span the viewport, which is what an
/// ordinary list row does and what a narrow `Center`ed label hides.
class _List extends StatelessWidget {
  const _List({this.fullWidth = false});

  final bool fullWidth;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          for (var i = 0; i < 60; i++)
            SizedBox(
              key: fullWidth ? Key('row$i') : null,
              height: 80,
              width: fullWidth ? double.infinity : null,
              child: Center(child: Text('Row $i')),
            ),
        ],
      ),
    ),
  );
}
