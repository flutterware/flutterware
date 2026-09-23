import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/drive.dart';
import 'package:flutterware/src/drive/resolve.dart';

/// The keyboard half of the verb engine.
///
/// `flutter_test`'s own `simulateKeyDownEvent` is unusable in a live app — it
/// routes the raw message through `TestDefaultBinaryMessengerBinding`, which
/// asserts in a process whose binding is the real one — so [Drive.key]
/// reimplements the pair of messages the engine sends. These tests are about
/// that pair arriving intact: the modifier state, the `Shortcuts` dispatch, the
/// release on the way out, and the two refusals.
void main() {
  Widget app(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  /// A focused `Shortcuts` — which is the shape of every real keyboard
  /// shortcut, and the reason [Drive.key] cares about focus at all.
  Widget bound(Map<ShortcutActivator, VoidCallback> bindings, Widget child) =>
      CallbackShortcuts(
        bindings: bindings,
        child: Focus(autofocus: true, child: child),
      );

  testWidgets('a bare key reaches a binding', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      app(
        bound({
          const SingleActivator(LogicalKeyboardKey.escape): () => fired++,
        }, const Text('Bound')),
      ),
    );
    var drive = Drive();

    await drive.key('escape', settle: Duration.zero);
    await tester.pump();

    expect(fired, 1);
  });

  /// The modifiers have to be *down* while the trigger fires — a `+` chord is
  /// three events, not one — and `SingleActivator` reads the modifier state to
  /// decide, so nothing but a real hold satisfies it.
  testWidgets('a chord holds its modifiers for the trigger', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      app(
        bound({
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              fired++,
        }, const Text('Bound')),
      ),
    );
    var drive = Drive();

    await drive.key('meta+k', settle: Duration.zero);
    await tester.pump();

    expect(fired, 1);
  });

  /// The unmodified key must *not* fire a modified binding, which is the other
  /// half of the same claim: the modifier state is real, not decoration.
  testWidgets('the same key without its modifier does not fire', (
    tester,
  ) async {
    var fired = 0;
    await tester.pumpWidget(
      app(
        bound({
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              fired++,
        }, const Text('Bound')),
      ),
    );
    var drive = Drive();

    await drive.key('k', settle: Duration.zero);
    await tester.pump();

    expect(fired, 0);
  });

  /// Nothing may be left held. A key still down after the step is state the
  /// human inherits for the rest of the run, and it would make the next chord
  /// refuse.
  testWidgets('every key is released, modifiers in reverse', (tester) async {
    await tester.pumpWidget(app(bound(const {}, const Text('Bound'))));
    var drive = Drive();

    await drive.key('shift+meta+d', settle: Duration.zero);

    expect(HardwareKeyboard.instance.logicalKeysPressed, isEmpty);
    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
  });

  /// `cmd`, `esc`, `opt` — what a person types. Each modifier alias resolves to
  /// its left key, which is what every `SingleActivator` is satisfied by.
  testWidgets('the shorthands people type resolve', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      app(
        bound({
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            meta: true,
            shift: true,
          ): () =>
              fired++,
        }, const Text('Bound')),
      ),
    );
    var drive = Drive();

    await drive.key('cmd+shift+s', settle: Duration.zero);
    await tester.pump();

    expect(fired, 1);
  });

  /// A key does not type, and that is not a gap in this verb. A character
  /// reaches a text field through the platform's *text input*, never through a
  /// key event — the two merely accompany each other on a real keyboard. So
  /// `key('a')` into a focused field leaves it empty here and in a running app
  /// alike, and `enterText` is the verb that types. Asserted rather than
  /// merely written down, because "typing doesn't work" is what it looks like
  /// from the outside.
  testWidgets('a key does not type — enterText is the verb that types', (
    tester,
  ) async {
    var controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(TextField(controller: controller, autofocus: true)),
    );
    await tester.pump();
    var drive = Drive();

    await drive.key('a', settle: Duration.zero);
    await tester.pump();

    expect(controller.text, isEmpty);
  });

  /// The refusal that stops the verb silently doing nothing.
  ///
  /// A keystroke dispatches from the primary focus *upwards*. With nothing
  /// focused that is the root scope, which sits above the app's `Shortcuts`, so
  /// every binding is missed — and on a window launched hidden, or one nobody
  /// has clicked, that is the normal state rather than an edge case.
  testWidgets('a keystroke that reached nothing, with nothing focused, is '
      'refused', (tester) async {
    var fired = 0;
    // **No `MaterialApp`, deliberately.** A `Navigator`'s modal route takes
    // focus on its own, which is why this state is hard to reach in a test and
    // easy to reach in life: an app whose window was launched hidden, or that
    // nobody has clicked, sits here. With nothing focusable, `primaryFocus` is
    // null and `FocusManager` drops the message on the floor.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () => fired++,
          },
          child: const Text('Unfocused'),
        ),
      ),
    );
    var drive = Drive();

    await expectLater(
      drive.key('escape', settle: Duration.zero),
      throwsA(
        isA<TargetError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('holds focus'),
            contains('enterText'),
            contains('nothing is stuck'),
          ),
        ),
      ),
    );
    expect(fired, 0, reason: 'the binding really was missed');
    expect(
      HardwareKeyboard.instance.physicalKeysPressed,
      isEmpty,
      reason: 'the refusal must not leave the key down',
    );
  });

  /// …and not otherwise. Plenty of keystrokes are legitimately unhandled, so
  /// the refusal is gated on *both* halves — nothing took it, and it never
  /// reached the tree.
  testWidgets('an unhandled key with a focus is not refused', (tester) async {
    await tester.pumpWidget(app(bound(const {}, const Text('Bound'))));
    var drive = Drive();

    var step = await drive.key('f7', settle: Duration.zero);

    expect(step.verb, 'key');
    expect(step.target, 'f7');
  });

  testWidgets('a name that is not a key says so, and lists the spellings', (
    tester,
  ) async {
    await tester.pumpWidget(app(bound(const {}, const Text('Bound'))));
    var drive = Drive();

    await expectLater(
      drive.key('banana', settle: Duration.zero),
      throwsA(
        isA<TargetError>().having(
          (e) => e.message,
          'message',
          allOf(contains('"banana"'), contains('arrowDown'), contains('cmd')),
        ),
      ),
    );
  });

  /// A key that exists but this platform cannot simulate is refused, not
  /// crashed on.
  ///
  /// `getKeyData` builds the raw message from per-platform key tables that are
  /// much smaller than `knownPhysicalKeys`, and it reaches into three of them
  /// with a bare `assert(x != null)`. Every name below passes the physical-key
  /// lookup and then used to throw a raw `AssertionError` from inside
  /// `flutter_test` — which, not being a `TargetError`, escaped the guest's
  /// refusal path and came back as a stack trace with no screen attached.
  /// `browserBack` and `abort` failed the physical-key table, `f24` the
  /// keyCode table: three of the four assert sites between them.
  for (var name in ['f24', 'browserBack', 'abort']) {
    testWidgets('$name is refused rather than asserted on', (tester) async {
      await tester.pumpWidget(app(bound(const {}, const Text('Bound'))));
      var drive = Drive();

      await expectLater(
        drive.key(name, settle: Duration.zero),
        throwsA(
          isA<TargetError>().having(
            (e) => e.message,
            'message',
            contains('key tables for'),
          ),
        ),
      );
      expect(
        HardwareKeyboard.instance.physicalKeysPressed,
        isEmpty,
        reason: 'refused before anything was sent',
      );
    });
  }

  /// The check runs over the whole chord before the first key goes down, so a
  /// modifier is never left held by a trigger that turns out to be unsendable.
  testWidgets('an unsendable trigger refuses before its modifiers press', (
    tester,
  ) async {
    await tester.pumpWidget(app(bound(const {}, const Text('Bound'))));
    var drive = Drive();

    await expectLater(
      drive.key('shift+f24', settle: Duration.zero),
      throwsA(isA<TargetError>()),
    );

    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
  });

  /// Two people drive this app. Injecting a down on top of a key the human is
  /// physically holding would leave the framework's idea of the keyboard wrong
  /// the moment this releases it.
  testWidgets('a key the human is already holding is refused', (tester) async {
    await tester.pumpWidget(app(bound(const {}, const Text('Bound'))));
    var drive = Drive();
    await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    addTearDown(() => simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft));

    await expectLater(
      drive.key('shift+a', settle: Duration.zero),
      throwsA(
        isA<TargetError>().having(
          (e) => e.message,
          'message',
          allOf(contains('already held down'), contains('Shift Left')),
        ),
      ),
    );
  });
}
