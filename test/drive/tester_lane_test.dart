import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';
import 'package:flutterware/src/drive/guest_drive.dart';
import 'package:flutterware/src/drive/lane.dart';
import 'package:flutterware/src/drive/resolve.dart';
import 'package:material_ui/material_ui.dart';

/// The drive verbs on a fake clock, spelled the way `act` sends them.
///
/// What a preview runs before it is photographed. The claim is that the live
/// engine's verbs need nothing from a live app but time, so the same strings
/// an agent sends a running app reach the same state under a widget test —
/// and that the fake clock makes the timed ones exact rather than lucky.
void main() {
  Drive driveOn(WidgetTester tester) =>
      Drive.on(TesterLane(tester))..settleBudget = const Duration(seconds: 5);

  Widget app(Widget home) => MaterialApp(home: home);

  testWidgets('tap opens a menu and escape closes it', (tester) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Center(
            child: PopupMenuButton<String>(
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'a', child: Text('Rename')),
                PopupMenuItem(value: 'b', child: Text('Archive')),
              ],
              child: const Text('More'),
            ),
          ),
        ),
      ),
    );
    var drive = driveOn(tester);

    await runWireVerb(drive, {'verb': 'tap', 'target': 'More'});
    expect(find.text('Archive'), findsOneWidget);

    await runWireVerb(drive, {'verb': 'key', 'keys': 'esc'});
    expect(find.text('Archive'), findsNothing);
  });

  testWidgets('a hover holds exactly as long as it says', (tester) async {
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: Center(
            child: Tooltip(
              message: 'Add to cart',
              waitDuration: Duration(milliseconds: 500),
              child: Icon(Icons.add_shopping_cart),
            ),
          ),
        ),
      ),
    );
    var drive = driveOn(tester);
    var target = '{"tooltip": "Add to cart"}';

    // Short of the tooltip's wait: nothing, every run. Short by more than a
    // beat, because the settle after the hold moves the clock too — in the
    // 100ms beats a scenario settles in — so what a hover waits is its hold
    // plus at least one of them.
    await runWireVerb(drive, {
      'verb': 'hover',
      'target': target,
      'holdMs': '200',
    });
    expect(find.text('Add to cart'), findsNothing);
    await runWireVerb(drive, {'verb': 'unhover', 'holdMs': '0'});

    // Past it: there, every run.
    await runWireVerb(drive, {'verb': 'hover', 'target': target});
    expect(find.text('Add to cart'), findsOneWidget);
    await runWireVerb(drive, {'verb': 'unhover', 'holdMs': '0'});
  });

  testWidgets('scrollTo reaches a row the list has not built', (tester) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ListView.builder(
            itemCount: 100,
            itemBuilder: (_, i) => ListTile(title: Text('Row $i')),
          ),
        ),
      ),
    );
    expect(find.text('Row 57'), findsNothing);

    await runWireVerb(driveOn(tester), {
      'verb': 'scrollTo',
      'target': 'Row 57',
    });

    expect(find.text('Row 57'), findsOneWidget);
  });

  testWidgets('enterText types into the field it names', (tester) async {
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: TextField(decoration: InputDecoration(labelText: 'Email')),
        ),
      ),
    );

    var drive = driveOn(tester);
    await runWireVerb(drive, {
      'verb': 'enterText',
      // The label rather than its text: the text is the decoration's, and
      // drive refuses it as such on this lane exactly as on a live one.
      'target': '{"label": "Email"}',
      'text': 'ada@example.com',
    });

    expect(find.text('ada@example.com'), findsOneWidget);
    // A label target turned semantics on, and a test body may not end with
    // the handle open.
    drive.dispose();
  });

  testWidgets('back pops the route a tap pushed', (tester) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Details')),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    var drive = driveOn(tester);

    await runWireVerb(drive, {'verb': 'tap', 'target': 'Open'});
    expect(find.text('Details'), findsOneWidget);

    await runWireVerb(drive, {'verb': 'back'});
    expect(find.text('Details'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('doubleTap and secondaryTap reach their recognizers', (
    tester,
  ) async {
    var doubles = 0;
    var secondaries = 0;
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Column(
            children: [
              GestureDetector(
                onDoubleTap: () => doubles++,
                child: const Text('Twice'),
              ),
              GestureDetector(
                onSecondaryTap: () => secondaries++,
                child: const Text('Context'),
              ),
            ],
          ),
        ),
      ),
    );
    var drive = driveOn(tester);

    await runWireVerb(drive, {'verb': 'doubleTap', 'target': 'Twice'});
    await runWireVerb(drive, {'verb': 'secondaryTap', 'target': 'Context'});
    await runWireVerb(drive, {'verb': 'unhover', 'holdMs': '0'});

    expect(doubles, 1);
    expect(secondaries, 1);
  });

  testWidgets('a step settles by frames, so what it opened is still there', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Added'))),
              child: const Text('Add'),
            ),
          ),
        ),
      ),
    );

    var step = await runWireVerb(driveOn(tester), {
      'verb': 'tap',
      'target': 'Add',
    });

    // Four seconds of `SnackBar` against five of budget: a settle that spent
    // its budget would have photographed it gone.
    expect(find.text('Added'), findsOneWidget);
    expect(step.settle.settled, isTrue);
    expect(step.settle.frames, greaterThan(0));
  });

  testWidgets('a refusal is final, not retried against a still screen', (
    tester,
  ) async {
    await tester.pumpWidget(app(const Scaffold(body: Text('Only this'))));

    await expectLater(
      runWireVerb(driveOn(tester), {'verb': 'tap', 'target': 'Nonesuch'}),
      throwsA(
        isA<TargetError>().having(
          (e) => e.message,
          'message',
          contains('Only this'),
        ),
      ),
    );
  });
}
