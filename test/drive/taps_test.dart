import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';

/// The two taps that are not `tap`.
///
/// `doubleTap` is the awkward one and the reason this file exists: the gap
/// between its taps is real elapsed time that a gesture recognizer measures
/// with a `Timer`, so every one of its cases runs inside [WidgetTester.runAsync]
/// — a `Future.delayed` in the ordinary test zone is fake time nobody advances,
/// and the verb would simply hang.
void main() {
  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  group('doubleTap', () {
    testWidgets('fires the double-tap callback, and not two single taps', (
      tester,
    ) async {
      var doubles = 0;
      var singles = 0;
      await tester.pumpWidget(
        app(
          GestureDetector(
            onTap: () => singles++,
            onDoubleTap: () => doubles++,
            child: const Text('Handle'),
          ),
        ),
      );
      var drive = Drive();

      await tester.runAsync(
        () => drive.doubleTap('Handle', settle: Duration.zero),
      );
      await tester.pump();

      expect(doubles, 1);
      expect(singles, 0, reason: 'one gesture, not two');
    });

    /// The gap is the whole verb. Below `kDoubleTapMinTime` the recognizer
    /// treats the second tap as a restarted first one — touch screens report a
    /// single touch intermittently, and that rule is what tells the two apart.
    /// A zero gap is what a naive "tap twice" implementation does, so it is
    /// worth having a test that says what it costs.
    testWidgets('a gap under the minimum is not a double tap', (tester) async {
      var doubles = 0;
      await tester.pumpWidget(
        app(
          GestureDetector(
            onDoubleTap: () => doubles++,
            child: const Text('Handle'),
          ),
        ),
      );
      var drive = Drive();

      await tester.runAsync(
        () => drive.doubleTap(
          'Handle',
          gap: Duration.zero,
          settle: Duration.zero,
        ),
      );
      await tester.pump();

      expect(doubles, 0);
      expect(
        drive.doubleTapGap,
        greaterThan(kDoubleTapMinTime),
        reason: 'which is why the default is not zero',
      );
      expect(drive.doubleTapGap, lessThan(kDoubleTapTimeout));
    });

    /// The one case that needs no `runAsync`: the target is resolved before
    /// either tap, so the refusal arrives before the gap does.
    testWidgets('a target that matches nothing is refused', (tester) async {
      await tester.pumpWidget(app(const Text('Only this')));
      var drive = Drive()..actTimeout = Duration.zero;

      await expectLater(
        drive.doubleTap('Not here', settle: Duration.zero),
        throwsA(
          isA<Object>().having(
            (e) => '$e',
            'message',
            allOf(contains('Not here'), contains('Only this')),
          ),
        ),
      );
    });
  });

  group('secondaryTap', () {
    testWidgets('right-clicks, rather than tapping', (tester) async {
      var secondaries = 0;
      var primaries = 0;
      await tester.pumpWidget(
        app(
          GestureDetector(
            onTap: () => primaries++,
            onSecondaryTap: () => secondaries++,
            child: const Text('Row'),
          ),
        ),
      );
      var drive = Drive();

      await drive.secondaryTap('Row', settle: Duration.zero);
      await tester.pump();

      expect(secondaries, 1);
      expect(primaries, 0, reason: 'the other button entirely');
    });

    /// It is the same pointer `hover` uses, so the click leaves the target
    /// hovered — which is what a real mouse does, and what a context menu
    /// opening under the cursor depends on.
    testWidgets('leaves the target hovered, and unhover releases it', (
      tester,
    ) async {
      var hovering = false;
      await tester.pumpWidget(
        app(
          MouseRegion(
            onEnter: (_) => hovering = true,
            onExit: (_) => hovering = false,
            child: GestureDetector(
              onSecondaryTap: () {},
              child: const Text('Row'),
            ),
          ),
        ),
      );
      var drive = Drive();

      await drive.secondaryTap('Row', settle: Duration.zero);
      await tester.pump();
      expect(hovering, isTrue);
      expect(drive.hovering, contains('Row'));

      await drive.unhover(hold: Duration.zero, settle: Duration.zero);
      await tester.pump();

      expect(hovering, isFalse);
    });

    /// The pointer must come back up. `TestPointer` asserts a hover is only
    /// generated while it is up, so one click that left it down would wedge
    /// every later mouse verb for the life of the run.
    testWidgets('the button is released, so a later hover still works', (
      tester,
    ) async {
      var entered = 0;
      await tester.pumpWidget(
        app(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(onSecondaryTap: () {}, child: const Text('Row')),
              MouseRegion(
                onEnter: (_) => entered++,
                child: const Text('Other'),
              ),
            ],
          ),
        ),
      );
      var drive = Drive();

      await drive.secondaryTap('Row', settle: Duration.zero);
      await drive.hover('Other', hold: Duration.zero, settle: Duration.zero);
      await tester.pump();

      expect(entered, 1);
    });
  });
}
