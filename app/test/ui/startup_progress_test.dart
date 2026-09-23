import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/startup_progress.dart';

/// The rules that decide what a person waiting is told, and when.
///
/// Every one of them exists because the alternative was observed: a readout
/// that flickered between three concurrent compilers, a clock that reported a
/// forty-second first open as `0s` because two lanes handed over in between,
/// and a band of chrome blinking in and out as the pointer crossed a page.
void main() {
  group('what it says', () {
    test('nothing, until something says something', () {
      var progress = StartupProgress();
      addTearDown(progress.dispose);
      expect(progress.task, isNull);
      expect(progress.visible, isFalse);
    });

    test('the lane that has been going longest', () {
      var progress = StartupProgress();
      addTearDown(progress.dispose);
      progress.report('a', const StartupTask('First'));
      progress.report('b', const StartupTask('Second'));
      expect(
        progress.task?.label,
        'First',
        reason:
            'a caption that changes faster than it can be read is one '
            'nobody reads',
      );
      progress.report('a', null);
      expect(
        progress.task?.label,
        'Second',
        reason: 'the words change on news',
      );
    });

    test('counting further along does not restart a lane’s claim', () {
      var progress = StartupProgress();
      addTearDown(progress.dispose);
      progress.report(
        'render',
        const StartupTask('Rendering', done: 1, total: 9),
      );
      progress.report('other', const StartupTask('Compiling'));
      progress.report(
        'render',
        const StartupTask('Rendering', done: 2, total: 9),
      );
      expect(progress.task?.label, 'Rendering');
      expect(progress.task?.done, 2);
    });

    test('a compile has no fraction and the pass does', () {
      expect(const StartupTask('Compiling').fraction, isNull);
      expect(const StartupTask('Rendering', done: 3, total: 4).fraction, 0.75);
      expect(
        const StartupTask('Rendering', done: 1, total: 0).fraction,
        isNull,
        reason: 'nothing to be a fraction of',
      );
    });

    test('finish drops every lane at once', () {
      var progress = StartupProgress();
      addTearDown(progress.dispose);
      progress
        ..report('a', const StartupTask('First'))
        ..report('b', const StartupTask('Second'))
        ..finish();
      expect(progress.task, isNull);
      expect(progress.visible, isFalse);
    });
  });

  group('when it appears', () {
    testWidgets('not until the work has lasted', (tester) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      progress.report('a', const StartupTask('Working'));
      expect(progress.visible, isFalse, reason: 'the truth, not yet the news');
      await tester.pump(const Duration(milliseconds: 400));
      expect(progress.visible, isTrue);
      progress.report('a', null);
      expect(progress.visible, isFalse);
    });

    testWidgets('work that ended inside the floor is never announced', (
      tester,
    ) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      progress.report('a', const StartupTask('Working'));
      await tester.pump(const Duration(milliseconds: 100));
      progress.report('a', null);
      await tester.pump(const Duration(milliseconds: 400));
      expect(progress.visible, isFalse);
    });
  });

  group('the clock', () {
    testWidgets('is the wait’s, not the current lane’s', (tester) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      progress.report('harness', const StartupTask('Compiling'));
      await tester.pump(const Duration(seconds: 4));
      // The handover every first open makes: the harness reports ready, and the
      // render pass it just unblocked opens a frame later.
      progress
        ..report('harness', null)
        ..report('render', const StartupTask('Rendering', done: 0, total: 9));
      expect(
        progress.elapsed.inSeconds,
        greaterThanOrEqualTo(4),
        reason: 'one wait, across the lanes doing it',
      );
      expect(
        progress.visible,
        isTrue,
        reason: 'a surface that had earned its way on screen stays there',
      );
      progress.finish();
    });

    testWidgets('restarts for a wait that is genuinely new', (tester) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      progress.report('a', const StartupTask('Working'));
      await tester.pump(const Duration(seconds: 4));
      progress.report('a', null);
      await tester.pump(const Duration(seconds: 30));
      progress.report('b', const StartupTask('Something else'));
      expect(progress.elapsed.inSeconds, lessThan(2));
      expect(
        progress.visible,
        isFalse,
        reason: 'and it has to earn its way back on screen',
      );
      progress.finish();
    });
  });

  group('the strip', () {
    Widget wrap(StartupProgress progress) => MaterialApp(
      home: Scaffold(body: StartupStrip(progress: progress)),
    );

    testWidgets('takes no room while there is nothing to say', (tester) async {
      var progress = StartupProgress();
      addTearDown(progress.dispose);
      await tester.pumpWidget(wrap(progress));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.getSize(find.byType(StartupStrip)).height, 0);
    });

    testWidgets('reads the phase, the count and the seconds', (tester) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      await tester.pumpWidget(wrap(progress));
      progress.report(
        'render',
        const StartupTask('Rendering the previews', done: 47, total: 53),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Rendering the previews'), findsOneWidget);
      expect(find.text('47 / 53'), findsOneWidget);
      expect(find.text('0s'), findsOneWidget);
      var bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(47 / 53, 0.001));
      progress.finish();
    });

    testWidgets('a compile gets an indeterminate bar and no count', (
      tester,
    ) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      await tester.pumpWidget(wrap(progress));
      progress.report('catalog', const StartupTask('Compiling the catalog'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining(' / '), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
        reason: 'a bar that fills at a rate nobody measured is a bar that lies',
      );
      // And the count climbs where a bar cannot.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('3s'), findsOneWidget);
      progress.finish();
    });

    testWidgets('retires itself when the last lane closes', (tester) async {
      var progress = StartupProgress(
        appearsAfter: const Duration(milliseconds: 300),
      );
      addTearDown(progress.dispose);
      await tester.pumpWidget(wrap(progress));
      progress.report('render', const StartupTask('Rendering'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(find.byType(StartupStrip)).height, greaterThan(0));
      progress.report('render', null);
      await tester.pump();
      expect(
        tester.getSize(find.byType(StartupStrip)).height,
        0,
        reason: 'a progress surface that outlives its progress is chrome',
      );
    });
  });
}
