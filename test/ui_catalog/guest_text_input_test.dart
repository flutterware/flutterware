import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/guest_text_input.dart';

/// The whole loop a guest runs when someone types into a demo's field: a key
/// event carrying a character arrives, [GuestTextInput] turns it into editing
/// state, and the field shows it. The framework half — deletion, caret keys,
/// chords — is asserted too, because the control's design leans on it staying
/// framework-side; a Flutter upgrade that moved it would surface here.
void main() {
  setUp(GuestTextInput.instance.install);

  tearDown(TextInput.restorePlatformInputControl);

  // The guest runs as macOS; the editing shortcuts asserted below are that
  // platform's.
  var macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  Future<TextEditingController> pumpField(
    WidgetTester tester, {
    int? maxLines = 1,
    ValueChanged<String>? onSubmitted,
  }) async {
    var controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: maxLines,
            onSubmitted: onSubmitted,
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  Future<void> type(WidgetTester tester, String text) async {
    for (var rune in text.runes) {
      var character = String.fromCharCode(rune);
      // The logical key is irrelevant to insertion — the control reads the
      // character — so one letter key stands in for all of them.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: character);
    }
    await tester.pump();
  }

  testWidgets('typing inserts the characters the keys produced', (
    tester,
  ) async {
    var controller = await pumpField(tester);
    await type(tester, 'héllo');
    expect(controller.text, 'héllo');
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
  }, variant: macOS);

  testWidgets('typing over a selection replaces it', (tester) async {
    var controller = await pumpField(tester);
    await type(tester, 'abc');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();
    await type(tester, 'x');
    expect(controller.text, 'xc');
  }, variant: macOS);

  testWidgets('backspace stays the framework shortcut it always was', (
    tester,
  ) async {
    var controller = await pumpField(tester);
    await type(tester, 'ab');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, 'a');
  }, variant: macOS);

  testWidgets('enter submits a single-line field instead of inserting', (
    tester,
  ) async {
    String? submitted;
    var controller = await pumpField(
      tester,
      onSubmitted: (value) => submitted = value,
    );
    await type(tester, 'ok');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter, character: '\n');
    await tester.pump();
    expect(controller.text, 'ok');
    expect(submitted, 'ok');
  }, variant: macOS);

  testWidgets('enter inserts a newline into a multiline field', (tester) async {
    var controller = await pumpField(tester, maxLines: null);
    await type(tester, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter, character: '\n');
    await tester.pump();
    await type(tester, 'b');
    expect(controller.text, 'a\nb');
  }, variant: macOS);

  testWidgets('a chord letter is a command, not text', (tester) async {
    var controller = await pumpField(tester);
    await type(tester, 'ab');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.text, 'ab');
  }, variant: macOS);

  testWidgets('an unfocused field hears nothing', (tester) async {
    var controller = await pumpField(tester);
    await type(tester, 'a');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await type(tester, 'b');
    expect(controller.text, 'a');
  }, variant: macOS);
}
