import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/profile.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// `Settle.strict`: the bounded default, red where it would have shrugged.
///
/// The default records `settled: false` and carries on, which is right for a
/// loading spinner and wrong for a suite where a spinner in a picture is a
/// bug — and a scenario whose assertion finds its widget passes with one in
/// every frame for as long as nobody reads that flag.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('a strict step fails on a screen that keeps animating', () {
    scenario('and the failed step is the spinner', settle: Settle.strict, (
      s,
    ) async {
      await expectLater(
        () => s.pumpWidget(const _Spinner()),
        throwsA(
          isA<ScenarioStillAnimating>().having(
            (e) => '$e',
            'message',
            allOf(
              contains('`pumpWidget _Spinner`'),
              contains('still animating'),
              contains('after 5s of fake time'),
              contains('Settle.strict'),
              contains(
                'Still ticking: CircularProgressIndicator '
                '(test/scenarios/strict_settle_test.dart:',
              ),
            ),
          ),
        ),
      );
    });
    tearDown(() {
      expect(captures, hasLength(1));
      expect(captures.single.failure, contains('still animating'));
      expect(captures.single.verb, 'pumpWidget');
    });
  });

  group('a strict step passes a screen that finishes', () {
    scenario('so a finite animation is not a failure', settle: Settle.strict, (
      s,
    ) async {
      await s.pumpWidget(const _Fading());
    });
    tearDown(() {
      expect(captures, hasLength(1));
      expect(captures.single.failure, isNull);
      expect(captures.single.settled, isTrue);
    });
  });

  group('a verb may relax the policy for one picture', () {
    scenario('with settle: on the verb', settle: Settle.strict, (s) async {
      await s.pumpWidget(const _Spinner(), settle: Settle.standard);
    });
    tearDown(() {
      expect(captures.single.failure, isNull);
      expect(captures.single.settled, isFalse);
    });
  });

  group('the folder can say it for every scenario in it', () {
    // Armed at declaration, which is when `scenario()` reads it — the way
    // `runScenarios(settle:)` arms it around a file's `main()`.
    scenarioAmbientSettle = Settle.strict;
    scenario('through runScenarios(settle:)', (s) async {
      await expectLater(
        () => s.pumpWidget(const _Spinner()),
        throwsA(isA<ScenarioStillAnimating>()),
      );
    });
    scenarioAmbientSettle = null;
  });

  test('the default policies stay lenient', () {
    expect(Settle.standard.failsWhenUnsettled, isFalse);
    expect(Settle.strict.failsWhenUnsettled, isTrue);
    expect(Settle.none.failsWhenUnsettled, isFalse);
    expect(Settle.full.failsWhenUnsettled, isFalse);
  });
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: CircularProgressIndicator())),
  );
}

class _Fading extends StatefulWidget {
  const _Fading();

  @override
  State<_Fading> createState() => _FadingState();
}

class _FadingState extends State<_Fading> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: FadeTransition(opacity: _controller, child: const Text('Done')),
    ),
  );
}
