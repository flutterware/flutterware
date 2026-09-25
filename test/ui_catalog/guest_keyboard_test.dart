import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/guest_keyboard.dart';

/// [GuestKeyboard] exists because the framework parks the guest's key events
/// instead of dispatching them, so what matters is that both destinations the
/// framework's own flush would have reached are reached here: the keyboard
/// state and handlers, and the focus tree behind `keyMessageHandler`.
void main() {
  // What the engine hands `onKeyData`.
  ui.KeyData data(
    ui.KeyEventType type, {
    String? character,
    int physical = 0x00070004,
    int logical = 0x00000061,
  }) => ui.KeyData(
    timeStamp: Duration.zero,
    type: type,
    physical: physical,
    logical: logical,
    character: character,
    synthesized: false,
    deviceType: ui.KeyEventDeviceType.keyboard,
  );

  bool send(ui.KeyData event) =>
      WidgetsBinding.instance.platformDispatcher.onKeyData!(event);

  setUp(() => GuestKeyboard.instance.install());

  tearDown(() {
    // Left pressed, a key poisons the next test's state assertions.
    for (var key in HardwareKeyboard.instance.physicalKeysPressed.toList()) {
      send(data(ui.KeyEventType.up, physical: key.usbHidUsage));
    }
  });

  testWidgets('a key reaches HardwareKeyboard and its handlers', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    var seen = <KeyEvent>[];
    bool handler(KeyEvent event) {
      seen.add(event);
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));

    send(data(ui.KeyEventType.down, character: 'a'));
    expect(seen.single, isA<KeyDownEvent>());
    expect(seen.single.character, 'a');
    expect(
      HardwareKeyboard.instance.physicalKeysPressed,
      contains(const PhysicalKeyboardKey(0x00070004)),
    );

    send(data(ui.KeyEventType.up));
    expect(seen.last, isA<KeyUpEvent>());
    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
  });

  testWidgets('a key reaches the focus tree', (tester) async {
    var seen = <KeyEvent>[];
    await tester.pumpWidget(
      Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          seen.add(event);
          return KeyEventResult.handled;
        },
        child: const SizedBox(),
      ),
    );
    await tester.pump();

    send(data(ui.KeyEventType.down, character: 'a'));
    expect(seen.single, isA<KeyDownEvent>());
    expect(seen.single.character, 'a');
  });

  // `ServicesBinding` installs its own `onKeyData` once `getKeyboardState` is
  // answered — after `install` has run, on a host that answers at all. Held
  // here so the answer lands where it does in a guest: after the install.
  testWidgets('keeps the keys when the keyboard sync is answered late', (
    tester,
  ) async {
    var answer = Completer<void>();
    var messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.keyboard, (call) async {
      await answer.future;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.keyboard, null),
    );

    GuestKeyboard.instance.install();
    // What the framework does when its own sync is answered — deprecated, and
    // still exactly the handler it installs.
    tester.binding.platformDispatcher.onKeyData =
        // ignore: deprecated_member_use
        ServicesBinding.instance.keyEventManager.handleKeyData;
    answer.complete();
    await tester.pump();

    var seen = <KeyEvent>[];
    await tester.pumpWidget(
      Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          seen.add(event);
          return KeyEventResult.handled;
        },
        child: const SizedBox(),
      ),
    );
    await tester.pump();

    send(data(ui.KeyEventType.down, character: 'a'));
    expect(seen.single.character, 'a');
  });

  testWidgets('an empty event is ignored', (tester) async {
    await tester.pumpWidget(const SizedBox());
    expect(send(data(ui.KeyEventType.down, physical: 0, logical: 0)), isFalse);
    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
  });

  // The panel forwards keys only while the preview has focus, so a press whose
  // release lands elsewhere leaves the guest holding a key forever. Both
  // repairs below exist so the next keystroke is a keystroke rather than an
  // assertion over the demo.
  testWidgets('a second down for a held key becomes a repeat', (tester) async {
    await tester.pumpWidget(const SizedBox());
    var seen = <KeyEvent>[];
    bool handler(KeyEvent event) {
      seen.add(event);
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));

    send(data(ui.KeyEventType.down, character: 'a'));
    send(data(ui.KeyEventType.down, character: 'a'));
    expect(seen, [isA<KeyDownEvent>(), isA<KeyRepeatEvent>()]);
  });

  testWidgets('an up for a key nothing holds is dropped', (tester) async {
    await tester.pumpWidget(const SizedBox());
    var seen = <KeyEvent>[];
    bool handler(KeyEvent event) {
      seen.add(event);
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));

    expect(send(data(ui.KeyEventType.up)), isFalse);
    expect(seen, isEmpty);
  });
}
