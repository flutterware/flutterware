import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';
import 'package:flutterware/src/drive/lane.dart';
import 'package:flutterware/src/drive/resolve.dart';
import 'package:material_ui/material_ui.dart';

/// [Drive.scrollTo] with a positional finder.
///
/// flutter_test's `.first` and `.last` over nothing throw `No element` rather
/// than match nothing, and `scrollUntilVisible` evaluates its finder on every
/// step of the walk — so a row addressed that way crashed on the first look
/// instead of being walked to.
void main() {
  Drive driveOn(WidgetTester tester) =>
      Drive.on(TesterLane(tester))..settleBudget = const Duration(seconds: 5);

  Widget lazyList() => MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        itemCount: 100,
        itemBuilder: (_, i) => ListTile(title: Text('Row $i')),
      ),
    ),
  );

  for (var (name, positional) in [
    ('.first', (Finder rows) => rows.first),
    ('.last', (Finder rows) => rows.last),
  ]) {
    testWidgets('reaches a row the list has not built, addressed with $name', (
      tester,
    ) async {
      await tester.pumpWidget(lazyList());
      expect(find.text('Row 57', skipOffstage: false), findsNothing);

      await driveOn(tester).scrollTo(positional(find.text('Row 57')));

      expect(find.text('Row 57'), findsOneWidget);
    });
  }

  testWidgets('a .first that never turns up is refused as the walk ran out', (
    tester,
  ) async {
    await tester.pumpWidget(lazyList());

    await expectLater(
      () => driveOn(tester).scrollTo(find.text('Row 500').first, maxScrolls: 3),
      throwsA(
        isA<TargetError>()
            .having((e) => e.failure, 'failure', TargetFailure.notFound)
            .having((e) => '$e', 'message', contains('scrolled 3 times')),
      ),
    );
  });

  testWidgets('a .first over nothing, with nothing scrolling, is refused', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('nothing to scroll'))),
    );

    await expectLater(
      () => driveOn(tester).scrollTo(find.text('anywhere').first),
      throwsA(
        isA<TargetError>().having(
          (e) => '$e',
          'message',
          contains('nothing on screen scrolls'),
        ),
      ),
    );
  });

  testWidgets("a StateError of the finder's own is not taken for a miss", (
    tester,
  ) async {
    await tester.pumpWidget(lazyList());

    await expectLater(
      () => driveOn(tester).scrollTo(
        find.byElementPredicate((_) => throw StateError('not a miss')).first,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'not a miss'),
      ),
    );
  });
}
