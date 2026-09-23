import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The blinking caret, and why a run holds it still.
///
/// On iOS a `TextField` animates its caret through an `AnimationController`
/// rather than a timer, so a screen with a focused field never stops asking
/// for frames. No settle policy can tell that from a spinner, and the two that
/// do not stop at the first quiet frame — [Settle.elapse], which is what a
/// boot-time pump spends, and [Settle.none] — land wherever the blink happens
/// to be. The step then reports `settled: false` on the phase of an animation
/// nobody is waiting for, and the caret's opacity in the pixels moves with it
/// — enough for a `screen` to refuse to adopt its verb's frame and emit a
/// second step instead.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('a screen with a focused iOS field', () {
    scenario('settles under a policy that spends its whole budget', (s) async {
      await s.pumpWidget(
        const _FocusedField(),
        settle: const Settle.elapse(Duration(seconds: 10)),
      );
    });
    tearDown(() => expect(captures.single.settled, isTrue));
  });

  group('the flag belongs to the run', () {
    scenario('which is what a body sees', (s) async {
      await s.pumpWidget(const _FocusedField());
      expect(EditableText.debugDeterministicCursor, isTrue);
    });
    // Put back on the way out: a process runs other tests, and whether their
    // caret blinks may not depend on which scenario ran before them.
    tearDown(() => expect(EditableText.debugDeterministicCursor, isFalse));
  });
}

class _FocusedField extends StatelessWidget {
  const _FocusedField();

  @override
  Widget build(BuildContext context) => MaterialApp(
    // The platform is what decides the caret animates at all — read off the
    // theme, so a run staged on an iPhone gets this without saying so.
    theme: ThemeData(platform: TargetPlatform.iOS),
    home: const Scaffold(body: TextField(autofocus: true)),
  );
}
