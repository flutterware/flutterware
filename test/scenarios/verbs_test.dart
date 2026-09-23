import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The verbs beyond tap and enterText, and the target vocabulary behind them.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('scrollTo walks a list until the item is on screen', () {
    scenario('and the step it captures shows it', (s) async {
      await s.pumpWidget(const _ListApp());
      expect(find.text('Item 40'), findsNothing);

      await s.scrollTo('Item 40', shot: Shot('Item 40'));

      expect(find.text('Item 40'), findsOneWidget);
    });
    tearDown(() => expect(captures.last.texts, contains('Item 40')));
  });

  scenario('scrollTo walks back up with a negative step', (s) async {
    await s.pumpWidget(const _ListApp());
    await s.scrollTo('Item 40');

    await s.scrollTo('Item 0', step: -200);

    expect(find.text('Item 0'), findsOneWidget);
  });

  // Reported by a consumer suite: a horizontal filter row taps the last pill,
  // then asks for the first — which the viewport has scrolled past. The walk
  // only drags toward the end, so it could never come back; a target still in
  // the tree is jumped to instead, both directions, both axes.
  scenario('scrollTo reaches a target the viewport has scrolled past', (
    s,
  ) async {
    await s.pumpWidget(const _PillsApp());
    await s.scrollTo('Pill 4');
    expect(find.text('Pill 1'), findsNothing);

    await s.scrollTo('Pill 1');

    expect(find.text('Pill 1'), findsOneWidget);
  });

  scenario('scrollTo does not jump to a target on an inactive route', (
    s,
  ) async {
    await s.pumpWidget(const _RoutedListsApp());
    await s.tap('Open details');
    expect(find.text('Home item'), findsNothing);

    // 'Home item' is still in the tree — on the route behind this one. A
    // jump there would scroll a hidden list and capture a screen without the
    // target; the honest answer is the walk's own exhaustion.
    await expectLater(
      () => s.scrollTo('Home item', maxScrolls: 2),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          contains('scrolled 2 times'),
        ),
      ),
    );
  });

  scenario('scrollTo says so when the item never turns up', (s) async {
    await s.pumpWidget(const _ListApp());

    await expectLater(
      () => s.scrollTo('Item 500', maxScrolls: 3),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('scrolled 3 times'),
            contains('"Item 500"'),
            contains('negative step'),
          ),
        ),
      ),
    );
  });

  scenario('scrollTo says so when nothing scrolls', (s) async {
    await s.pumpWidget(const _StaticApp());

    await expectLater(
      () => s.scrollTo('anywhere'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          contains('nothing on screen scrolls'),
        ),
      ),
    );
  });

  // Reported by a consumer walking a flow whose pages vary in length: which
  // pages scroll depends on the device, so a scenario cannot know statically,
  // and the old unconditional refusal made every walking scenario carry a
  // guard around the verb.
  group('scrollTo on a target already on screen is a no-op', () {
    scenario('and still captures the step it was asked for', (s) async {
      await s.pumpWidget(const _StaticApp());

      await s.scrollTo('nothing to scroll', shot: Shot('short page'));
    });
    tearDown(() {
      expect(captures.last.name, 'short page');
      expect(captures.last.texts, contains('nothing to scroll'));
    });
  });

  // The same consumer, one report later: the defensive call the loop above
  // makes became, on every page that happened not to scroll, a step
  // byte-identical to its parent — measured at half the suite's duplicate
  // warnings. A no-op that drew nothing now skips its automatic capture; the
  // explicit shot above still gets its picture, because the author asked.
  group('a no-op scrollTo that drew nothing', () {
    scenario('skips its automatic capture', (s) async {
      await s.pumpWidget(const _StaticApp());

      await s.scrollTo('nothing to scroll');
    });
    tearDown(() {
      expect(captures, hasLength(1));
      expect(captures.single.verb, 'pumpWidget');
    });
  });

  // The measured consumer shape is not the group above: the page *has* a
  // list, the list happens not to scroll on this device, and the walk's
  // trailing alignment moves nothing because there is no extent to move
  // through. The skip has to fire on this path too — it rests on the SDK's
  // trailing `ensureVisible` clamping to a zero scroll extent, which this
  // pins against the moving beta.
  group('a no-op scrollTo in a list with nothing to scroll', () {
    scenario('skips its automatic capture too', (s) async {
      await s.pumpWidget(const _FittingListApp());

      await s.scrollTo('Row 2');
    });
    tearDown(() {
      expect(captures, hasLength(1));
      expect(captures.single.verb, 'pumpWidget');
    });
  });

  group('a scrollTo that scrolled', () {
    scenario('captures as ever', (s) async {
      await s.pumpWidget(const _ListApp());

      await s.scrollTo('Item 40');
    });
    tearDown(() {
      expect(captures, hasLength(2));
      expect(captures.last.verb, 'scrollTo');
      expect(captures.last.texts, contains('Item 40'));
    });
  });

  group('a no-op scrollTo after frames it did not draw', () {
    scenario('still captures — the flow has no picture of them yet', (s) async {
      await s.pumpWidget(const _StaticApp());
      // A raw pump redraws outside the verbs. The skip must not swallow the
      // capture that is the flow's only look at whatever it showed.
      s.tester.binding.scheduleFrame();
      await s.tester.pump();

      await s.scrollTo('nothing to scroll');
    });
    tearDown(() {
      expect(captures, hasLength(2));
      expect(captures.last.verb, 'scrollTo');
      expect(captures.last.strayFrames, greaterThan(0));
    });
  });

  // A skipped shot consumes its position — mapped to the chain's head, like
  // an adoption — so however the skip decision falls on a replay, the walk
  // keeps recognising the shared prefix and the branches hang off the right
  // step.
  group('a skipped no-op scrollTo on a shared split prefix', () {
    scenario('leaves the replay aligned', (s) async {
      await s.pumpWidget(const _StaticApp());
      await s.scrollTo('nothing to scroll');
      await s.split({
        'left': () => s.screen('Left'),
        'right': () => s.screen('Right'),
      });
    });
    tearDown(() {
      expect(captures, hasLength(3));
      expect(captures[1].name, 'Left');
      expect(captures[2].name, 'Right');
      expect(captures[1].parent, captures[0].index);
      expect(captures[2].parent, captures[0].index);
    });
  });

  scenario('scrollTo still refuses a target off screen that nothing scrolls', (
    s,
  ) async {
    await s.pumpWidget(const _OffstageApp());

    await expectLater(
      () => s.scrollTo('parked off canvas'),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          contains('sits off screen'),
        ),
      ),
    );
  });

  scenario('drag dismisses, and longPress opens what a tap does not', (
    s,
  ) async {
    await s.pumpWidget(const _GestureApp());

    await s.longPress('Hold me');
    expect(find.text('held'), findsOneWidget);

    await s.drag('Swipe me', const Offset(-500, 0));
    expect(find.text('Swipe me'), findsNothing);
  });

  scenario('settle waits per the policy and captures nothing', (s) async {
    await s.pumpWidget(const _SplashApp());
    var count = captures.length;

    // The wait without the step — what a bridge maps a legacy
    // `pumpAndSettle()` onto. `elapse` here, because this splash waits on a
    // timer, which no frame-following policy can see.
    await s.settle(const Settle.elapse(Duration(seconds: 3)));

    expect(find.text('Home'), findsOneWidget);
    expect(captures.length, count);
  });

  scenario('wait moves the clock a settle would not', (s) async {
    await s.pumpWidget(const _SplashApp());
    // The trap the verb exists for: the timer schedules no frames, so no
    // amount of settling reaches the second screen.
    expect(find.text('Splash'), findsOneWidget);

    await s.wait(const Duration(seconds: 3), shot: Shot('Home'));

    expect(find.text('Home'), findsOneWidget);
  });

  scenario('back pops the route the platform way', (s) async {
    await s.pumpWidget(const _RoutedApp());
    await s.tap('Open details');
    expect(find.text('Details'), findsOneWidget);

    await s.back(shot: Shot('Back on the list'));

    expect(find.text('Details'), findsNothing);
  });

  scenario('a semantics label is a target — the only handle on an icon', (
    s,
  ) async {
    await s.pumpWidget(const _LabelledApp());

    await s.tap(const Target.label('Add to cart'));

    expect(find.text('added'), findsOneWidget);
  });

  scenario('a tooltip is a target', (s) async {
    await s.pumpWidget(const _LabelledApp());

    await s.tap(const Target.tooltip('Remove'));

    expect(find.text('removed'), findsOneWidget);
  });

  scenario('within scopes a target, and nth picks one of many', (s) async {
    await s.pumpWidget(const _CardsApp());

    // A 'Buy' button on every card: ambiguous alone, exact once scoped.
    await expectLater(
      () => s.tap(const Target.containing('Buy')),
      throwsA(
        isA<ScenarioTargetError>().having(
          (e) => '$e',
          'message',
          // The target reads back as what was written, not as
          // `Instance of '_Containing'`.
          contains('2 widgets match Target.containing("Buy")'),
        ),
      ),
    );

    await s.tap(
      const Target.within(ValueKey('second'), Target.containing('Buy')),
    );
    expect(find.text('bought second'), findsOneWidget);

    await s.tap(const Target.nth(Target.containing('Buy'), 0));
    expect(find.text('bought first'), findsOneWidget);
  });

  scenario('containing matches part of a string', (s) async {
    await s.pumpWidget(const _CardsApp());

    await s.tap(const Target.containing('the second'));

    expect(find.text('bought second'), findsOneWidget);
  });

  /// Reported by a consumer driving a form. A point is the target for a
  /// control with no words, a field labelled from its decoration is one, and
  /// `enterText` at a point resolves *below* the editable — so the search the
  /// verb makes downwards found nothing to type into.
  scenario('a point inside a field types into it', (s) async {
    await s.pumpWidget(const _FormApp());
    var box = s.tester.getRect(find.byType(TextField));

    await s.enterText(Target.at(box.center.dx, box.center.dy), '918406');

    expect(find.text('918406'), findsOneWidget);
  });

  group('frames the verbs did not draw', () {
    scenario('are counted onto the next step', (s) async {
      await s.pumpWidget(const _CardsApp());

      // The escape hatch, used for something a verb covers: the app changes,
      // and the flow has no picture of it.
      await s.tester.tap(find.text('Buy the first'));
      await s.tester.pump();

      await s.screen('after a raw tap');
    });
    // Two steps, because that raw pump drew: a `screen` names the frame the
    // verb before it took, and this is not that frame any more.
    tearDown(() {
      expect(captures, hasLength(2));
      expect(captures[0].strayFrames, 0);
      expect(captures[1].name, 'after a raw tap');
      expect(captures[1].strayFrames, greaterThan(0));
    });
  });
}

class _StaticApp extends StatelessWidget {
  const _StaticApp();

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: Text('nothing to scroll')));
}

/// A list whose content fits its viewport — a scrollable with zero extent,
/// which is what a walking suite's short pages actually are.
class _FittingListApp extends StatelessWidget {
  const _FittingListApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          for (var i = 1; i <= 3; i++)
            SizedBox(height: 40, child: Text('Row $i')),
        ],
      ),
    ),
  );
}

/// A widget laid out past the screen's edge, with nothing that scrolls — the
/// dead end the refusal is kept for.
class _OffstageApp extends StatelessWidget {
  const _OffstageApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: -2000, top: 0, child: Text('parked off canvas')),
        ],
      ),
    ),
  );
}

class _ListApp extends StatelessWidget {
  const _ListApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          for (var i = 0; i < 60; i++)
            SizedBox(height: 80, child: Text('Item $i')),
        ],
      ),
    ),
  );
}

/// A horizontal filter row wider than the screen — the consumer shape whose
/// first pill ends up *behind* the viewport after the last one is reached.
/// Four pills of 300 on an 800-wide surface: everything stays built (well
/// inside cache extent), so the scrolled-past one is in the tree, invisible.
class _PillsApp extends StatelessWidget {
  const _PillsApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 60,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: 4,
          itemBuilder: (_, i) =>
              SizedBox(width: 300, child: Center(child: Text('Pill ${i + 1}'))),
          separatorBuilder: (_, _) => const SizedBox(width: 20),
        ),
      ),
    ),
  );
}

/// A scrollable page behind a scrollable page: what the previous route shows
/// stays in the tree, and must not count as reachable.
class _RoutedListsApp extends StatelessWidget {
  const _RoutedListsApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: ListView(
          children: [
            const SizedBox(height: 40, child: Text('Home item')),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: ListView(
                      children: [
                        for (var i = 0; i < 3; i++)
                          SizedBox(height: 40, child: Text('Detail $i')),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('Open details'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _GestureApp extends StatefulWidget {
  const _GestureApp();

  @override
  State<_GestureApp> createState() => _GestureAppState();
}

class _GestureAppState extends State<_GestureApp> {
  var _note = '';
  var _swiped = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          GestureDetector(
            onLongPress: () => setState(() => _note = 'held'),
            child: const Text('Hold me'),
          ),
          if (!_swiped)
            Dismissible(
              key: const ValueKey('dismissible'),
              onDismissed: (_) => setState(() => _swiped = true),
              child: const SizedBox(height: 60, child: Text('Swipe me')),
            ),
          Text(_note),
        ],
      ),
    ),
  );
}

/// A splash that navigates on a timer — no animation, so nothing to settle.
class _SplashApp extends StatefulWidget {
  const _SplashApp();

  @override
  State<_SplashApp> createState() => _SplashAppState();
}

class _SplashAppState extends State<_SplashApp> {
  var _done = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(
      const Duration(seconds: 2),
      () => setState(() => _done = true),
    );
  }

  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: Scaffold(body: Text(_done ? 'Home' : 'Splash')));
}

class _RoutedApp extends StatelessWidget {
  const _RoutedApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Details')),
            ),
          ),
          child: const Text('Open details'),
        ),
      ),
    ),
  );
}

class _LabelledApp extends StatefulWidget {
  const _LabelledApp();

  @override
  State<_LabelledApp> createState() => _LabelledAppState();
}

class _LabelledAppState extends State<_LabelledApp> {
  var _note = '';

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          // An icon button with no text and no tooltip: the semantics label
          // is the only handle on it, which is what `Target.label` is for.
          // (A `tooltip:` would not do — Material puts that on the semantics
          // node's *tooltip*, not its label.)
          Semantics(
            label: 'Add to cart',
            child: IconButton(
              icon: const Icon(Icons.add_shopping_cart),
              onPressed: () => setState(() => _note = 'added'),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Remove',
            onPressed: () => setState(() => _note = 'removed'),
          ),
          Text(_note),
        ],
      ),
    ),
  );
}

class _FormApp extends StatelessWidget {
  const _FormApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: TextField(decoration: InputDecoration(labelText: 'Phone number')),
    ),
  );
}

class _CardsApp extends StatefulWidget {
  const _CardsApp();

  @override
  State<_CardsApp> createState() => _CardsAppState();
}

class _CardsAppState extends State<_CardsApp> {
  var _note = '';

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          for (var name in ['first', 'second'])
            Card(
              key: ValueKey(name),
              child: Column(
                children: [
                  Text('The $name card'),
                  TextButton(
                    onPressed: () => setState(() => _note = 'bought $name'),
                    child: Text('Buy the $name'),
                  ),
                ],
              ),
            ),
          Text(_note),
        ],
      ),
    ),
  );
}
