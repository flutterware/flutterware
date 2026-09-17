import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' as ft;
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';
import 'package:flutterware/src/scenarios/still_ticking.dart';

/// What keeps a screen asking for frames, named where the app can act on it.
///
/// Measured on a real suite: a list whose "in progress" row drew an
/// indeterminate spinner ran its scenario ten times slower than its siblings,
/// and the only thing a report said was that steps never settled.
void main() {
  ft.testWidgets('a framework spinner is named by where the app built it', (
    tester,
  ) async {
    await tester.pumpWidget(const _StatusList());
    await tester.pump(const Duration(milliseconds: 100));

    expect(whatKeepsTicking(), [
      matches(
        RegExp(
          r'^CircularProgressIndicator '
          r'\(test/scenarios/still_ticking_test\.dart:\d+\)$',
        ),
      ),
    ]);
  });

  ft.testWidgets('an animation the app started is named by its own frame', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _Pulse()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(whatKeepsTicking(), [
      allOf(startsWith('_PulseState.'), contains('still_ticking_test.dart:')),
    ]);
  });

  ft.testWidgets('nothing is named on a screen that stopped', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(enabled: false, child: CircularProgressIndicator()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(whatKeepsTicking(), isEmpty);
  });

  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('the step a settle gave up on says what kept ticking', () {
    scenario('on the spinner', (s) async {
      await s.pumpWidget(const _StatusList());
      await s.tap('Show shipped only');
    });
    tearDown(() {
      expect(captures, hasLength(2));
      expect(captures.first.settled, isFalse);
      expect(captures.first.stillTicking, [
        startsWith('CircularProgressIndicator (test/scenarios/'),
      ]);
      // The next step settled: the spinner is gone, and so is its name.
      expect(captures.last.settled, isTrue);
      expect(captures.last.stillTicking, isEmpty);
    });
  });

  group('but not the step the author parked mid-flight', () {
    scenario('with Settle.none', (s) async {
      await s.pumpWidget(const _StatusList(), settle: Settle.none);
    });
    tearDown(() {
      expect(captures.single.settled, isFalse);
      expect(captures.single.stillTicking, isEmpty);
    });
  });

  group('and a strict step that fails on it says so on the failed step', () {
    scenario('on the spinner', settle: Settle.strict, (s) async {
      await expectLater(
        () => s.pumpWidget(const _StatusList()),
        throwsA(isA<ScenarioStillAnimating>()),
      );
    });
    tearDown(() {
      expect(captures.single.failure, isNotNull);
      expect(captures.single.stillTicking, [
        startsWith('CircularProgressIndicator (test/scenarios/'),
      ]);
    });
  });
}

class _StatusList extends StatefulWidget {
  const _StatusList();

  @override
  State<_StatusList> createState() => _StatusListState();
}

class _StatusListState extends State<_StatusList> {
  var _shippedOnly = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          TextButton(
            onPressed: () {
              setState(() => _shippedOnly = true);
            },
            child: const Text('Show shipped only'),
          ),
          const ListTile(title: Text('Shipped'), trailing: Icon(Icons.check)),
          if (!_shippedOnly)
            const ListTile(
              title: Text('Packing'),
              trailing: CircularProgressIndicator(),
            ),
        ],
      ),
    ),
  );
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _controller, child: const Text('Live'));
}
