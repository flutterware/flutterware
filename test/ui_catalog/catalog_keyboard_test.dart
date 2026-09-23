import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/devices.dart';
import 'package:flutterware/src/ui_catalog/catalog_keyboard.dart';
import 'package:flutterware/src/ui_catalog/guest_text_input.dart';
import 'package:flutterware/src/ui_catalog/keyboard.dart';

/// The two signals and what is done with them.
///
/// The whole feasibility of the feature is the first group. The framework
/// already computes when a phone would raise its keyboard and hands it to
/// whatever [TextInputControl] is installed — so this asserts the traffic
/// rather than a heuristic, and a Flutter upgrade that moved the rule would
/// surface here rather than as a keyboard that stops following the app.
void main() {
  var input = GuestTextInput.instance;
  var keyboard = CatalogKeyboard.instance;

  setUp(() {
    input.install();
    keyboard.install();
    // A singleton the whole guest shares, so each test starts it from the
    // same place rather than from whatever the last one left.
    keyboard.apply(mode: KeyboardMode.auto, deviceHeight: 0);
  });

  tearDown(TextInput.restorePlatformInputControl);

  /// Two fields, the first optionally autofocused, each with a node the test
  /// can ask rather than one the `TextField` keeps to itself.
  late FocusNode first;
  late FocusNode second;

  setUp(() {
    first = FocusNode();
    second = FocusNode();
  });

  tearDown(() {
    first.dispose();
    second.dispose();
  });

  Future<void> pumpFields(WidgetTester tester, {bool autofocus = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Column(
            children: [
              TextField(
                key: const Key('a'),
                focusNode: first,
                autofocus: autofocus,
              ),
              TextField(key: const Key('b'), focusNode: second),
              const Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('the app asks', () {
    testWidgets('a field taking focus raises it', (tester) async {
      await pumpFields(tester);
      expect(input.asking.value, isNull);
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      expect(input.asking.value, isNotNull);
    });

    testWidgets('autofocus raises it before anything is touched', (
      tester,
    ) async {
      await pumpFields(tester, autofocus: true);
      expect(input.asking.value, isNotNull);
    });

    testWidgets('field to field does not flicker', (tester) async {
      await pumpFields(tester);
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      var flickers = 0;
      void count() {
        if (input.asking.value == null) flickers++;
      }

      input.asking.addListener(count);
      addTearDown(() => input.asking.removeListener(count));
      await tester.tap(find.byKey(const Key('b')));
      await tester.pump();
      // `TextInput` defers the hide to a microtask that cancels itself when
      // something re-attaches, so moving between fields produces no hide at
      // all — which is why nothing here needs a debounce of its own.
      expect(flickers, 0);
      expect(input.asking.value, isNotNull);
    });

    testWidgets('letting go of the field lowers it', (tester) async {
      await pumpFields(tester);
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      primaryFocus?.unfocus();
      await tester.pump();
      expect(input.asking.value, isNull);
    });

    testWidgets('the dismiss key makes the app let go', (tester) async {
      await pumpFields(tester, autofocus: true);
      expect(first.hasFocus, isTrue);
      input.dismiss();
      await tester.pump();
      // Not artwork disappearing: the field itself unfocused, because that is
      // what `connectionClosed` means and what a real platform sends.
      expect(first.hasFocus, isFalse);
      expect(input.asking.value, isNull);
    });

    testWidgets('a field that wants no system keyboard asks for none', (
      tester,
    ) async {
      keyboard.apply(deviceHeight: 336);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: TextField(
              focusNode: first,
              autofocus: true,
              keyboardType: TextInputType.none,
            ),
          ),
        ),
      );
      await tester.pump();
      // `show()` is called all the same — the platform is the one that decides
      // to draw nothing, because the app brought its own pad. Taking the call
      // at face value put a keyboard over a screen that has none.
      expect(first.hasFocus, isTrue);
      expect(input.asking.value, isNull);
      expect(keyboard.height, 0);
    });

    testWidgets('and changing its mind while focused moves the keyboard', (
      tester,
    ) async {
      keyboard.apply(deviceHeight: 336);
      var custom = ValueNotifier(true);
      addTearDown(custom.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: ValueListenableBuilder<bool>(
              valueListenable: custom,
              builder: (context, on, _) => TextField(
                focusNode: first,
                autofocus: true,
                keyboardType: on ? TextInputType.none : TextInputType.text,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(keyboard.height, 0);
      // The "use the normal keyboard" toggle a custom pad usually sits beside.
      // It arrives as `updateConfig` rather than a fresh attach, so a control
      // that only read the type at `attach` would never notice.
      custom.value = false;
      await tester.pump();
      expect(keyboard.height, 336);
    });

    testWidgets('and it can be pressed with nothing focused', (tester) async {
      await pumpFields(tester);
      input.dismiss();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('which keyboard the field asked for', () {
    Future<KeyboardVariant?> ask(
      WidgetTester tester,
      TextInputType type,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: TextField(
              focusNode: first,
              autofocus: true,
              keyboardType: type,
            ),
          ),
        ),
      );
      await tester.pump();
      return keyboard.asked;
    }

    testWidgets('a phone or a plain number is a keypad', (tester) async {
      expect(await ask(tester, TextInputType.phone), KeyboardVariant.keypad);
    });

    testWidgets('and so is a decimal one', (tester) async {
      expect(
        await ask(tester, const TextInputType.numberWithOptions(decimal: true)),
        KeyboardVariant.keypad,
      );
    });

    testWidgets('but a **signed** number is letters', (tester) async {
      // The discriminator nobody expects, and the reason the mapping takes
      // `signed` rather than the type name alone: allowing a minus sign gets
      // iOS's full punctuation keyboard at full height. Measured on two
      // phones, both agreeing.
      expect(
        await ask(tester, const TextInputType.numberWithOptions(signed: true)),
        KeyboardVariant.letters,
      );
    });

    testWidgets('email and url get their own keys', (tester) async {
      expect(
        await ask(tester, TextInputType.emailAddress),
        KeyboardVariant.email,
      );
      expect(await ask(tester, TextInputType.url), KeyboardVariant.url);
    });

    testWidgets('and a type this build never heard of is letters', (
      tester,
    ) async {
      // Forwards-compatible for the reason a canvas drops an unknown device:
      // the guest is compiled against the *project's* flutterware, which can
      // run behind the SDK that names the type.
      expect(
        keyboardVariantForName('TextInputType.holographic'),
        KeyboardVariant.letters,
      );
    });
  });

  group('the height follows the keys', () {
    testWidgets('a keypad is the shorter measurement', (tester) async {
      keyboard.apply(deviceHeight: 336, deviceKeypadHeight: 291);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: TextField(
              focusNode: first,
              autofocus: true,
              keyboardType: TextInputType.phone,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(keyboard.variant, KeyboardVariant.keypad);
      expect(keyboard.height, 291);
    });

    testWidgets('and a device that does not shrink keeps its letters height', (
      tester,
    ) async {
      // Every iPad, and every Android geometry: Gboard swaps the keys without
      // moving the height. Null is also what an unmeasured cell carries, and
      // it has to mean the same thing — no shrink — because a keyboard that
      // is too tall is the failure this distinction exists to remove.
      keyboard.apply(deviceHeight: 405.5, clearKeypad: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: TextField(
              focusNode: first,
              autofocus: true,
              keyboardType: TextInputType.phone,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(keyboard.variant, KeyboardVariant.keypad);
      expect(keyboard.height, 405.5);
    });

    testWidgets('a field held up by hand draws letters', (tester) async {
      keyboard.apply(
        mode: KeyboardMode.up,
        deviceHeight: 336,
        deviceKeypadHeight: 291,
      );
      await pumpFields(tester);
      expect(keyboard.variant, KeyboardVariant.letters);
      expect(keyboard.height, 336);
    });
  });

  group('the mode decides', () {
    testWidgets('auto follows the app', (tester) async {
      keyboard.apply(deviceHeight: 336);
      await pumpFields(tester);
      expect(keyboard.height, 0);
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      expect(keyboard.height, 336);
    });

    testWidgets('up raises it with nothing focused', (tester) async {
      keyboard.apply(mode: KeyboardMode.up, deviceHeight: 336);
      await pumpFields(tester);
      expect(keyboard.requested, isFalse);
      expect(keyboard.height, 336);
    });

    testWidgets('down overrules the app', (tester) async {
      keyboard.apply(mode: KeyboardMode.down, deviceHeight: 336);
      await pumpFields(tester, autofocus: true);
      // The app's opinion is still reported — it is a fact about the app, not
      // about the screen — and the screen simply does not move.
      expect(keyboard.requested, isTrue);
      expect(keyboard.height, 0);
    });

    testWidgets('a stage with no measurement raises nothing', (tester) async {
      keyboard.apply(mode: KeyboardMode.up, deviceHeight: 0);
      await pumpFields(tester, autofocus: true);
      // `Fit` and every desktop window. Inventing a height here is the one
      // thing the measured table exists not to do.
      expect(keyboard.height, 0);
    });

    testWidgets('the scope puts the insets and the slab on screen', (
      tester,
    ) async {
      keyboard.apply(mode: KeyboardMode.up, deviceHeight: 200);
      late MediaQueryData seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: CatalogKeyboardScope(
              child: Builder(
                builder: (context) {
                  seen = MediaQuery.of(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      expect(seen.viewInsets.bottom, 200);
      // And it follows without the demo being rebuilt around it: the push
      // moves a `MediaQuery` and repaints, which is what keeps raising a
      // keyboard cheaper than switching an entry.
      keyboard.apply(mode: KeyboardMode.down);
      await tester.pump();
      expect(seen.viewInsets.bottom, 0);
    });
  });

  group('what the host is told', () {
    test('a state survives the wire', () {
      var state = const KeyboardState(
        mode: KeyboardMode.up,
        requested: true,
        height: 336,
        deviceHeight: 336,
      );
      expect(KeyboardState.fromJson(state.toJson()), state);
    });

    test('a mode this build has never heard of reads as auto', () {
      // Forwards-compatible for the reason a canvas drops an unknown device:
      // the guest is compiled against the *project's* flutterware, which can
      // run behind the GUI pushing to it.
      expect(
        KeyboardState.fromJson(const {'mode': 'floating'}).mode,
        KeyboardMode.auto,
      );
    });

    testWidgets('applying the same thing twice moves nothing', (tester) async {
      keyboard.apply(mode: KeyboardMode.up, deviceHeight: 336);
      expect(keyboard.apply(mode: KeyboardMode.up, deviceHeight: 336), isFalse);
      expect(keyboard.apply(mode: KeyboardMode.down), isTrue);
    });
  });
}
