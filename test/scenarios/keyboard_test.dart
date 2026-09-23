import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/keyboard.dart';
import 'package:flutterware/src/scenarios/profile.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';
import 'package:flutterware/src/ui_catalog/fake_keyboard.dart';

/// The scenario keyboard: up when the app asks, down when the view lets go,
/// and over whatever it is over.
///
/// What this is really asserting. Not that a widget draws — that a flow
/// which fills a form is a flow a phone could have performed. So every group
/// here checks a *consequence*: the layout meets the smaller screen, a button
/// under the band is refused rather than silently missed, the step says how
/// much of the screen went.
void main() {
  var captures = <ScenarioStepCapture>[];

  /// An iPhone 16, whose measured keyboard is 336 points tall.
  void stageAPhone() {
    var phone = deviceById('iphone-16')!;
    scenarioRunArgs = ScenarioRunArgs.forAssignment(
      ScenarioAssignment(device: phone),
    );
  }

  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() {
    scenarioRunListener = null;
    scenarioRunArgs = null;
    scenarioAmbientKeyboard = null;
  });

  group('the app asks and the keyboard comes up', () {
    setUp(stageAPhone);

    scenario('tapping a field raises it', (s) async {
      await s.pumpWidget(const _Form());
      expect(s.keyboard.isUp, isFalse, reason: 'nothing focused yet');
      await s.tap(const Key('name'));
      expect(s.keyboard.height, 336, reason: "the iPhone 16's measurement");
      // The whole point: the app is laid out against what is left. Measured
      // on the *body* — a `Scaffold` goes on filling the screen while it hands
      // its body what the keyboard did not take.
      expect(s.tester.getSize(find.byKey(const Key('body'))).height, 852 - 336);
    });
  });

  group('and the step says so', () {
    setUp(stageAPhone);

    scenario('a keyboard is a note about the screen', (s) async {
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
    });
    tearDown(() {
      expect(captures.first.keyboard, isNull, reason: 'the pump, before focus');
      expect(captures.last.keyboard, 336);
    });
  });

  group('the slide is real, and it is free', () {
    setUp(stageAPhone);

    scenario('a bounded settle waits for it rather than stopping halfway', (
      s,
    ) async {
      await s.pumpWidget(const _Form());
      var before = s.tester.binding.clock.now();
      await s.tap(const Key('name'));
      // 250ms of *fake* time — the settle kept pumping because writing the
      // view schedules a forced frame, and it stopped when the slide landed
      // rather than at the first quiet frame a third of the way down.
      expect(
        s.tester.binding.clock.now().difference(before),
        greaterThanOrEqualTo(ScenarioKeyboard.raise),
      );
      expect(s.keyboard.height, 336);
    });

    scenario('and `Settle.full` waits it out too', (s) async {
      // The one policy with no per-frame hook — `pumpAndSettle` owns its loop.
      // It lands *around* it instead. The round before is all a raise needs:
      // the tap has already given the field focus, so the sample points the
      // ticker and the SDK's own settle waits the slide out like any other
      // animation.
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'), settle: Settle.full);
      expect(s.keyboard.height, 336);
    });

    scenario('and it takes down the keyboard the loop itself let go of', (
      s,
    ) async {
      // The round *after* is for this one, and nothing else can be: the focus
      // is still on the form when the loop starts and the form is gone by the
      // time it ends, so a policy that sampled only at the start would leave
      // 336 points of keyboard staged over a screen with no field on it —
      // for the next verb to start sliding away, one frame into its own
      // capture.
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
      expect(s.keyboard.height, 336);

      await s.act('the app leaves the form', _leaveForm, settle: Settle.full);
      expect(s.keyboard.height, 0);
      expect(captures.last.settled, isTrue);
    });

    scenario('and a policy that pumps one frame catches it mid-slide', (
      s,
    ) async {
      await s.pumpWidget(const _Form());
      await s.tap(
        const Key('name'),
        settle: const Settle.frames(3, interval: Duration(milliseconds: 50)),
      );
      // A fifth of the way up. `Settle.frames` is how an author says *land
      // here in the animation*, and the keyboard obeys it like anything else
      // the clock drives.
      expect(s.keyboard.height, greaterThan(0));
      expect(s.keyboard.height, lessThan(336));
    });
  });

  group('field to field does not flicker', () {
    setUp(stageAPhone);

    scenario('the keyboard never dips between two fields', (s) async {
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
      expect(s.keyboard.height, 336);
      // The two frames right after the switch are where a dip would be, so
      // they are what this samples: `TextInput` defers its hide to a microtask
      // that cancels itself when something re-attaches, so moving between
      // fields produces no hide at all and nothing here needs a debounce.
      const oneFrame = Settle.frames(1, interval: Duration(milliseconds: 20));
      await s.tap(const Key('email'), settle: oneFrame);
      expect(s.keyboard.height, 336, reason: 'the frame after the switch');
      await s.wait(Duration.zero, settle: oneFrame);
      expect(s.keyboard.height, 336, reason: 'and the one after that');
    });
  });

  group('what the view sees is what a real embedder writes', () {
    setUp(stageAPhone);

    scenario('insets up, safe area eaten, viewPadding remembering', (s) async {
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
      // Read above the app, not inside it: a `Scaffold` that resizes hands its
      // body a `MediaQuery` with the bottom inset *removed*, which is the
      // whole of how it gets out of the way. What arrives from the view is
      // what this is about.
      var media = MediaQuery.of(s.tester.element(find.byType(MaterialApp)));
      expect(media.viewInsets.bottom, 336);
      // The iPhone 16's home indicator is 34 points and the keyboard is over
      // it — measured as 0 on every device in the table.
      expect(media.padding.bottom, 0);
      expect(media.viewPadding.bottom, 34, reason: 'the phone is still there');
    });
  });

  group('a target under it is refused, not silently missed', () {
    setUp(stageAPhone);

    scenario('and the refusal says what to do about it', (s) async {
      await s.pumpWidget(const _Form(resizes: false));
      await s.tap(const Key('name'));
      await expectLater(
        s.tap('Submit'),
        throwsA(
          isA<ScenarioTargetError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('behind the software keyboard'),
              contains('336'),
              contains('s.keyboard.dismiss()'),
              // And pointedly *not* `scrollTo`: measured, it stops inside a
              // viewport that runs under the keyboard, so the next verb is
              // refused again. See [_keyboardOver].
              isNot(contains('scrollTo')),
            ),
          ),
        ),
      );
    });

    scenario('and dismissing it is the way past', (s) async {
      await s.pumpWidget(const _Form(resizes: false));
      await s.tap(const Key('name'));
      await s.keyboard.dismiss();
      await s.tap('Submit');
      expect(find.text('submitted'), findsOneWidget);
    });
  });

  group('the verbs', () {
    setUp(stageAPhone);

    scenario('show holds one up with nothing focused', (s) async {
      await s.pumpWidget(const _Form());
      await s.keyboard.show();
      expect(s.keyboard.isUp, isTrue);
      // Nobody asked for it — which is the case the verb exists for: *what
      // does this layout do with a third of the screen gone*, asked without
      // hunting for a field to tap.
      expect(s.keyboard.isRequested, isFalse);
    });

    scenario('hide overrules the app, and leaves the field focused', (s) async {
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
      await s.keyboard.hide();
      expect(s.keyboard.isUp, isFalse);
      // The difference from `dismiss`: the app was not told anything, so it
      // still believes it has a keyboard and the field still has focus.
      expect(s.keyboard.isRequested, isTrue);
      expect(_name.hasFocus, isTrue);
    });

    scenario('dismiss makes the app let go', (s) async {
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
      await s.keyboard.dismiss();
      expect(s.keyboard.isUp, isFalse);
      // Not artwork disappearing: the field itself let go, which is what
      // `connectionClosed` means and what a real platform sends.
      expect(_name.hasFocus, isFalse);
      expect(s.keyboard.isRequested, isFalse);
    });

    scenario('auto hands it back to the app', (s) async {
      await s.pumpWidget(const _Form());
      await s.keyboard.show();
      await s.keyboard.auto();
      expect(s.keyboard.isUp, isFalse, reason: 'nothing is focused');
    });
  });

  group('a replay starts from a screen with no keyboard on it', () {
    setUp(stageAPhone);

    var seen = <String, double>{};
    scenario('whatever the branch before it typed into', (s) async {
      await s.pumpWidget(const _Form());
      await s.split({
        'types': () async {
          await s.tap(const Key('name'));
          seen['types'] = s.keyboard.height;
        },
        'does not type': () async {
          // **The regression this pins.** A replay tears the tree down, which
          // takes the host widget — and with it anything that could have put
          // the view back. So the *driver* has to, from between the replays,
          // unconditionally: it once believed the unmount had already zeroed
          // things and wrote nothing, and every branch after one that typed
          // was laid out against 336 points of keyboard nobody had asked for.
          seen['does not type'] = MediaQuery.of(
            s.tester.element(find.byType(MaterialApp)),
          ).viewInsets.bottom;
        },
      });
    });
    tearDown(() {
      expect(seen['types'], 336);
      expect(
        seen['does not type'],
        0,
        reason: 'a fresh branch, a fresh screen',
      );
    });
  });

  group('which keyboard, and how tall', () {
    setUp(stageAPhone);

    scenario('a number field gets the shorter one', (s) async {
      await s.pumpWidget(const _Form(number: true));
      await s.tap(const Key('name'));
      expect(s.keyboard.variant, KeyboardVariant.keypad);
      // The iPhone 16's measured keypad, 45 points under its letters
      // keyboard — so the layout meets the screen a phone would give it and
      // not one 45 points smaller.
      expect(s.keyboard.height, 291);
      expect(s.tester.getSize(find.byKey(const Key('body'))).height, 852 - 291);
    });

    scenario('and the morph between them needs no going down', (s) async {
      // Tapping from a text field to a number field on a phone turns one
      // keyboard into a shorter one — it never leaves the screen. The slide
      // has nowhere to travel, so the driver has to notice the *variant*
      // moved rather than waiting for a fraction that never changes.
      await s.pumpWidget(const _Form(number: true));
      await s.tap(const Key('email'));
      expect(s.keyboard.variant, KeyboardVariant.letters);
      expect(s.keyboard.height, 336);
      await s.tap(const Key('name'));
      expect(s.keyboard.variant, KeyboardVariant.keypad);
      expect(s.keyboard.height, 291);
    });

    scenario('and the picture follows even when the height does not', (
      s,
    ) async {
      // **The gap a state check cannot see.** The slab sits above the app, so
      // no frame the app draws rebuilds it — the only thing that does is the
      // view's insets moving, which is the height. Letters and email are the
      // same height on every device measured, so this pair once reported
      // `email` from the driver beside a slab still painting letters.
      await s.pumpWidget(const _Form());
      await s.tap(const Key('email'));
      expect(_drawnVariant(s), KeyboardVariant.letters);
      await s.tap(const Key('mail'));
      expect(s.keyboard.variant, KeyboardVariant.email);
      expect(s.keyboard.height, 336, reason: 'the same height, on purpose');
      expect(_drawnVariant(s), KeyboardVariant.email);
    });
  });

  group('a field that wants no keyboard gets none', () {
    setUp(stageAPhone);

    scenario('TextInputType.none is a custom pad, not a keyboard', (s) async {
      await s.pumpWidget(const _Form(custom: true));
      await s.tap(const Key('name'));
      // The field takes focus and `TextInput.show` is still sent — the
      // platform simply shows nothing for it, because the app has its own
      // input surface. Reading the show alone put 336 points of keyboard over
      // a screen that has none on the phone.
      expect(s.keyboard.isRequested, isFalse);
      expect(s.keyboard.isUp, isFalse);
      expect(s.tester.getSize(find.byKey(const Key('body'))).height, 852);
    });

    scenario('and holding one up is still the human asking', (s) async {
      // The forced modes are about the layout, not about the app: they ignore
      // focus already, so they ignore this too.
      await s.pumpWidget(const _Form(custom: true));
      await s.keyboard.show();
      expect(s.keyboard.isUp, isTrue);
    });
  });

  group('a stage with no keyboard', () {
    scenario('raises nothing rather than inventing a height', (s) async {
      // No device: the plain surface, which is what a desktop run and a `fit`
      // run both come down to.
      await s.pumpWidget(const _Form());
      expect(s.keyboard.isAvailable, isFalse);
      await s.keyboard.show();
      expect(s.keyboard.isUp, isFalse);
      await s.tap(const Key('name'));
      expect(s.keyboard.isUp, isFalse);
    });
  });

  group('the folder switch turns the whole thing off', () {
    setUp(stageAPhone);
    // Set here rather than in a `setUp`, because a scenario reads the folder's
    // policy **as it declares** — the same rule the shots policy follows, and
    // for the same reason: a matrix declares one body once per assignment and
    // each declaration keeps what it was made under. `runScenarios` arms it
    // around `testMain` for exactly this.
    scenarioAmbientKeyboard = false;

    scenario('no insets, no slab, no refusal', (s) async {
      await s.pumpWidget(const _Form());
      await s.tap(const Key('name'));
      expect(s.keyboard.isUp, isFalse);
      expect(
        s.tester.getSize(find.byKey(const Key('body'))).height,
        852,
        reason: 'the screen is what it always was',
      );
      // And the button the keyboard would have covered is reachable again,
      // which is the half a suite would otherwise fail on separately.
      await s.tap('Submit');
    });
    tearDown(() => expect(captures.last.keyboard, isNull));
    scenarioAmbientKeyboard = null;
  });
}

/// The first field's node, so a test can ask whether the app let go of it —
/// `primaryFocus` never answers that: an app always has *something* focused.
final _name = FocusNode();

/// Two fields and a button at the very bottom.
///
/// [resizes] is what the two halves of this file are about. A `Scaffold` that
/// resizes gets out of the keyboard's way, which is what most apps do and what
/// the inset assertions measure. One that does not — a pinned footer, a bottom
/// bar, `resizeToAvoidBottomInset: false` — leaves its button *under* the
/// keyboard, which is the case the refusal exists for and a real layout bug
/// nothing else in this tool can see.
/// Which keyboard the slab is actually painting — the picture, rather than
/// what the driver says about it.
KeyboardVariant _drawnVariant(ScenarioTester s) {
  var paint = s.tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((p) => p.painter is FakeKeyboardPainter);
  return (paint.painter! as FakeKeyboardPainter).variant;
}

/// Pushes a page over the form, from outside the tree — the shape a deep link
/// or a tapped notification has, and the reason the focus goes away somewhere
/// a verb is not looking.
void _leaveForm() {
  // A block body, not an arrow: `push` completes when the route is *popped*,
  // and `void` erases the type without dropping the object — so an arrow hands
  // the verb a future that never completes.
  unawaited(
    _formNavigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('elsewhere'))),
      ),
    ),
  );
}

final _formNavigator = GlobalKey<NavigatorState>();

class _Form extends StatefulWidget {
  const _Form({this.resizes = true, this.custom = false, this.number = false});

  final bool resizes;

  /// Whether the first field wants digits — the shorter keyboard on a phone,
  /// and a different set of keys everywhere.
  final bool number;

  /// Whether the first field brings its own input surface — the shape a date
  /// picker, a PIN pad or a calculator has.
  final bool custom;

  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  var _submitted = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _formNavigator,
    home: Scaffold(
      resizeToAvoidBottomInset: widget.resizes,
      body: Column(
        key: const Key('body'),
        children: [
          TextField(
            key: const Key('name'),
            focusNode: _name,
            keyboardType: widget.custom
                ? TextInputType.none
                : widget.number
                ? TextInputType.phone
                : null,
          ),
          const TextField(key: Key('email')),
          // A field whose keyboard is the *same height* as the plain one and a
          // different picture — which is the only pair that can catch a slab
          // repainting on the height alone.
          const TextField(
            key: Key('mail'),
            keyboardType: TextInputType.emailAddress,
          ),
          const Spacer(),
          if (_submitted) const Text('submitted'),
          TextButton(
            onPressed: () => setState(() => _submitted = true),
            child: const Text('Submit'),
          ),
        ],
      ),
    ),
  );
}
