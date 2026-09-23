import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/guest_keyboard.dart';
import 'package:flutterware/src/ui_catalog/guest_text_input.dart';

/// The editing keys, driven the way the guest actually receives them —
/// straight into `onKeyData`, the entry point [GuestKeyboard] replaces.
///
/// Driving them with `tester.sendKeyEvent` instead would prove nothing: that
/// path still runs the deprecated raw-key pipeline, which handles these keys
/// even on macOS, so every one of these tests passed before the code they
/// cover existed. On macOS the framework refuses the editing keys and waits
/// for the IME to name the command — and in a guest, [GuestTextInput] is the
/// IME.
void main() {
  late TextEditingController controller;

  setUp(() {
    GuestKeyboard.instance.install();
    GuestTextInput.instance.install();
  });

  tearDown(() {
    TextInput.restorePlatformInputControl();
    for (var key in HardwareKeyboard.instance.physicalKeysPressed.toList()) {
      WidgetsBinding.instance.platformDispatcher.onKeyData!(
        ui.KeyData(
          timeStamp: Duration.zero,
          type: ui.KeyEventType.up,
          physical: key.usbHidUsage,
          logical: 0,
          character: null,
          synthesized: false,
          deviceType: ui.KeyEventDeviceType.keyboard,
        ),
      );
    }
  });

  Future<void> pumpField(WidgetTester tester, {int? maxLines = 1}) async {
    controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: maxLines,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void send(
    ui.KeyEventType type,
    int logical,
    int physical,
    String? character,
  ) {
    WidgetsBinding.instance.platformDispatcher.onKeyData!(
      ui.KeyData(
        timeStamp: Duration.zero,
        type: type,
        physical: physical,
        logical: logical,
        character: character,
        synthesized: false,
        deviceType: ui.KeyEventDeviceType.keyboard,
      ),
    );
  }

  void tap(LogicalKeyboardKey key, PhysicalKeyboardKey physical, {String? c}) {
    send(ui.KeyEventType.down, key.keyId, physical.usbHidUsage, c);
    send(ui.KeyEventType.up, key.keyId, physical.usbHidUsage, null);
  }

  void hold(LogicalKeyboardKey key, PhysicalKeyboardKey physical) =>
      send(ui.KeyEventType.down, key.keyId, physical.usbHidUsage, null);

  void letGo(LogicalKeyboardKey key, PhysicalKeyboardKey physical) =>
      send(ui.KeyEventType.up, key.keyId, physical.usbHidUsage, null);

  Future<void> type(WidgetTester tester, String text) async {
    for (var rune in text.runes) {
      tap(
        LogicalKeyboardKey.keyA,
        PhysicalKeyboardKey.keyA,
        c: String.fromCharCode(rune),
      );
    }
    await tester.pump();
  }

  testWidgets('backspace deletes the character before the caret', (
    tester,
  ) async {
    await pumpField(tester);
    await type(tester, 'abc');
    // Carrying DEL, the way a real keyboard delivers it — the character must
    // not be mistaken for text.
    tap(
      LogicalKeyboardKey.backspace,
      PhysicalKeyboardKey.backspace,
      c: '\u{7F}',
    );
    await tester.pump();
    expect(controller.text, 'ab');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the arrows move the caret', (tester) async {
    await pumpField(tester);
    await type(tester, 'abc');
    tap(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.selection.baseOffset, 2);
    tap(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selection.baseOffset, 3);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('typing after moving the caret inserts in place', (tester) async {
    await pumpField(tester);
    await type(tester, 'ac');
    tap(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    await tester.pump();
    await type(tester, 'b');
    expect(controller.text, 'abc');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('shift and an arrow extends the selection', (tester) async {
    await pumpField(tester);
    await type(tester, 'abc');
    hold(LogicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftLeft);
    tap(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    letGo(LogicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.selection.isCollapsed, false);
    expect(controller.selection.textInside('abc'), 'c');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('alt and backspace deletes the word', (tester) async {
    await pumpField(tester);
    await type(tester, 'one two');
    hold(LogicalKeyboardKey.altLeft, PhysicalKeyboardKey.altLeft);
    tap(LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace);
    letGo(LogicalKeyboardKey.altLeft, PhysicalKeyboardKey.altLeft);
    await tester.pump();
    expect(controller.text, 'one ');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('meta and an arrow goes to the end of the line', (tester) async {
    await pumpField(tester);
    await type(tester, 'abc');
    tap(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    await tester.pump();
    hold(LogicalKeyboardKey.metaLeft, PhysicalKeyboardKey.metaLeft);
    tap(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    letGo(LogicalKeyboardKey.metaLeft, PhysicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(controller.selection.baseOffset, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('an editing key with no field focused is left alone', (
    tester,
  ) async {
    var seen = <KeyEvent>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            seen.add(event);
            return KeyEventResult.handled;
          },
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    tap(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
    await tester.pump();
    // Not swallowed as an editing command: with nothing attached there is no
    // IME to be, and the key is whatever the demo binds it to.
    expect(seen.whereType<KeyDownEvent>(), hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
