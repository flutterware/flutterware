import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// Telling a capture parked mid-flight from a settle that gave up.
///
/// Both leave a frame scheduled, which is all `settled` has ever said. The
/// difference is whether anything was waiting for it to stop: a policy that
/// follows frames and ran out of budget has news, and one that draws its
/// frames and stops was doing what it was told. Without the second flag a
/// suite that photographs loading screens on purpose reports every one of
/// them as a problem, and the number stops meaning anything.
void main() {
  group('the policies say which of them wait', () {
    test('for the app to go quiet', () {
      expect(Settle.standard.waits, isTrue);
      expect(const Settle.upTo(Duration(seconds: 1)).waits, isTrue);
      expect(Settle.full.waits, isTrue);
    });

    test('and which stop on a count or on the clock', () {
      expect(Settle.none.waits, isFalse);
      expect(const Settle.frames(3).waits, isFalse);
      expect(const Settle.elapse(Duration(seconds: 1)).waits, isFalse);
    });
  });

  group('a step captured under a waiting policy', () {
    var captures = <ScenarioStepCapture>[];
    setUp(() {
      captures = [];
      scenarioRunListener = captures.add;
    });
    tearDown(() => scenarioRunListener = null);

    scenario('that gave up says so', (s) async {
      await s.pumpWidget(const _Spinner());
      await s.screen('Loading');
    });
    tearDown(() {
      expect(captures.last.settled, isFalse);
      expect(captures.last.waited, isTrue);
    });
  });

  group('a step parked on purpose', () {
    var captures = <ScenarioStepCapture>[];
    setUp(() {
      captures = [];
      scenarioRunListener = captures.add;
    });
    tearDown(() => scenarioRunListener = null);

    scenario('reports the same frames and the opposite intent', (s) async {
      await s.pumpWidget(const _Spinner(), settle: Settle.none);
      await s.screen('Loading', settle: Settle.none);
    });
    tearDown(() {
      expect(captures.last.settled, isFalse);
      expect(captures.last.waited, isFalse);
    });
  });

  group('a name adopting a parked verb', () {
    var captures = <ScenarioStepCapture>[];
    setUp(() {
      captures = [];
      scenarioRunListener = captures.add;
    });
    tearDown(() => scenarioRunListener = null);

    // The merged step stands for the whole stretch, so one half that waited
    // is enough to make the flag read with `settled` — the same rule the
    // stray frames and the overflows merge under.
    scenario('keeps the waiting half of the stretch', (s) async {
      await s.pumpWidget(const _Still(), settle: Settle.none);
      await s.screen('Ready');
    });
    tearDown(() {
      expect([for (var c in captures) c.name ?? c.verb], ['Ready']);
      expect(captures.single.waited, isTrue);
    });
  });
}

class _Still extends StatelessWidget {
  const _Still();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('Ready'))),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: CircularProgressIndicator())),
  );
}
