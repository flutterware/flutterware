import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'resolve.dart';

/// One keystroke's keys — `escape`, `enter`, `meta+k`, `shift+tab` — resolved,
/// checked, and pressed the way the engine presses them.
///
/// Shared by the two engines that press keys: the live drive, against a
/// running app, and a scenario, under the test binding's fake clock. What
/// each of them refuses and how it words the refusal is its own; which key a
/// name means, and what a keystroke *is*, is this.
class KeyChord {
  KeyChord._(this.modifiers, this.trigger);

  /// [chord] resolved: `+`-separated, the last name is the key that fires and
  /// everything before it is held down for it.
  ///
  /// Names are `LogicalKeyboardKey` debug names spelled any way that reads
  /// (`arrowDown`, `Arrow Down`), a single character (`k`), or one of the
  /// shorthands people actually type — `cmd`, `ctrl`, `alt`, `opt`, `shift`,
  /// `esc`. A shorthand modifier resolves to its **left** key, which is what
  /// every `SingleActivator` checks for. A Mac shortcut and its Windows/Linux
  /// twin are different chords: `meta+k` and `control+k`.
  ///
  /// **Every key in the chord is checked before any of them is sent**, so a
  /// refusal never leaves half a chord pressed. [verb] is how the caller
  /// spells the verb, for the one refusal that names it.
  factory KeyChord.parse(String chord, {String verb = 'key'}) {
    var names = [
      for (var name in chord.split('+'))
        if (name.trim().isNotEmpty) name.trim(),
    ];
    if (names.isEmpty) {
      throw TargetError(
        TargetFailure.notFound,
        '`$verb` needs something to press: a key name, or a chord like '
        '`meta+k` — the last name fires and the ones before it are held.',
      );
    }
    var trigger = _logicalKey(names.removeLast());
    var modifiers = [for (var name in names) _logicalKey(name)];
    for (var key in [...modifiers, trigger]) {
      _checkSimulatable(key);
    }
    return KeyChord._(modifiers, trigger);
  }

  /// Held down for [trigger], and released after it in reverse.
  final List<LogicalKeyboardKey> modifiers;

  /// The key that fires.
  final LogicalKeyboardKey trigger;

  /// The first key of this chord that is already down, or null when none is.
  ///
  /// A down for a key that is already pressed leaves the framework's idea of
  /// the keyboard wrong the moment this releases it — `HardwareKeyboard`
  /// asserts on it outright under a test binding — so each engine refuses it,
  /// in its own words.
  LogicalKeyboardKey? get held {
    var pressed = HardwareKeyboard.instance.physicalKeysPressed;
    for (var key in [...modifiers, trigger]) {
      if (pressed.contains(_physicalKey(key))) return key;
    }
    return null;
  }

  /// Presses the modifiers, then the trigger, and releases them all in
  /// reverse. Answers whether anything took the trigger.
  ///
  /// The releases are in a `finally`, and only for what actually went down: a
  /// key left pressed is state whoever presses next inherits.
  Future<bool> press() async {
    var pressed = <LogicalKeyboardKey>[];
    var handled = false;
    try {
      for (var modifier in modifiers) {
        await _sendKey(modifier, down: true);
        pressed.add(modifier);
      }
      handled = await _sendKey(trigger, down: true, typing: modifiers.isEmpty);
      pressed.add(trigger);
    } finally {
      for (var key in pressed.reversed) {
        await _sendKey(key, down: false);
      }
    }
    return handled;
  }

  /// One key transition, delivered the way the engine delivers one: the
  /// `KeyData` first, then the raw `flutter/keyevent` message. Answers whether
  /// anything took it.
  ///
  /// Both halves are required, and that is the whole finding.
  /// `KeyEventManager.handleKeyData` does not dispatch a non-synthesized event —
  /// it *queues* it and waits for the raw message that always follows on a real
  /// platform. Measured: `metaLeft` + `keyK` through `handleKeyData` alone
  /// reached no `Shortcuts` binding and changed nothing on screen. The raw
  /// message is what flushes the queue, dispatches, and answers `handled`.
  ///
  /// Three things worth knowing before changing this:
  ///
  /// - **`keyEventManager` is deprecated and is nonetheless the only door.**
  ///   Its replacement, `HardwareKeyboard.addHandler`, reaches `HardwareKeyboard`
  ///   listeners and stops there: `FocusManager` registers itself on
  ///   `keyEventManager.keyMessageHandler`, so nothing that goes around it ever
  ///   reaches `Shortcuts`, `Actions` or a focused `TextField`. A Flutter
  ///   release that removes these members takes this with it.
  /// - **The manager is called directly rather than through its channel.**
  ///   `handleRawKeyMessage` *is* the handler `ServicesBinding` puts on
  ///   `SystemChannels.keyEvent`, so this is the same code either way — but a
  ///   `channelBuffers.push` invokes it in the zone the listener was registered
  ///   in and answers back through that zone, which under a test binding's
  ///   `FakeAsync` never completes. Calling it here keeps the reply in the
  ///   caller's zone, and keeps `handled` observable in a widget test.
  /// - **The first keystroke of a run decides the process's transit mode.**
  ///   `KeyEventManager` latches onto whichever kind of message it sees first
  ///   and asserts on the other for the rest of the isolate's life. Sending the
  ///   `KeyData` first latches `keyDataThenRawKeyData` — which is what every
  ///   embedder Flutter currently ships does, so the human's own keyboard keeps
  ///   working. Sending only the raw message would latch the legacy mode and
  ///   then crash on the engine's next real key.
  static Future<bool> _sendKey(
    LogicalKeyboardKey key, {
    required bool down,
    bool typing = false,
  }) async {
    var label = key.keyLabel;
    // A chord types nothing: ⌘K produces no character on a real keyboard, and
    // a field that took one would end up with a stray "k" in it.
    var character = down && typing && label.length == 1 ? label : '';
    var manager =
        // ignore: deprecated_member_use
        ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    manager.handleKeyData(
      ui.KeyData(
        type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
        physical: _physicalKey(key).usbHidUsage,
        logical: key.keyId,
        timeStamp: Duration.zero,
        character: character.isEmpty ? null : character,
        synthesized: false,
      ),
    );
    // ignore: deprecated_member_use
    var answer = await manager.handleRawKeyMessage(
      KeyEventSimulator.getKeyData(
        key,
        platform: _keyPlatform,
        isDown: down,
        character: character,
      ),
    );
    return answer['handled'] == true;
  }

  /// Which key table [KeyEventSimulator] should build the raw message from.
  static String get _keyPlatform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => 'macos',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      TargetPlatform.fuchsia => 'fuchsia',
      TargetPlatform.linux => 'linux',
      TargetPlatform.windows => 'windows',
    };
  }

  /// The spellings people reach for that are not a `LogicalKeyboardKey` debug
  /// name. Each modifier resolves to its **left** key, which is the one every
  /// `SingleActivator` is satisfied by — `isMetaPressed` is
  /// `metaLeft || metaRight`.
  static const _keyAliases = {
    'cmd': 'Meta Left',
    'command': 'Meta Left',
    'meta': 'Meta Left',
    'win': 'Meta Left',
    'ctrl': 'Control Left',
    'control': 'Control Left',
    'alt': 'Alt Left',
    'opt': 'Alt Left',
    'option': 'Alt Left',
    'shift': 'Shift Left',
    'esc': 'Escape',
    'return': 'Enter',
    'up': 'Arrow Up',
    'down': 'Arrow Down',
    'left': 'Arrow Left',
    'right': 'Arrow Right',
    'del': 'Delete',
  };

  static LogicalKeyboardKey _logicalKey(String name) {
    var wanted = (_keyAliases[name.toLowerCase()] ?? name)
        .toLowerCase()
        .replaceAll(' ', '');
    for (var key in LogicalKeyboardKey.knownLogicalKeys) {
      if (key.debugName?.toLowerCase().replaceAll(' ', '') == wanted) {
        return key;
      }
    }
    // `k` rather than `keyK`, and every other key whose label is what you
    // would call it.
    for (var key in LogicalKeyboardKey.knownLogicalKeys) {
      if (key.keyLabel.toLowerCase() == wanted) return key;
    }
    throw TargetError(
      TargetFailure.notFound,
      'no key is called "$name". Names are `LogicalKeyboardKey` debug names '
      'spelled any way that reads — `escape`, `enter`, `tab`, `arrowDown`, '
      '`f2`, `keyK` — a single character like `k`, or one of '
      '${_keyAliases.keys.join(', ')}.',
    );
  }

  /// Refuses a key this platform's tables cannot produce a keystroke for.
  ///
  /// [_physicalKey] is not this check, and cannot be. It answers from
  /// `knownPhysicalKeys` — every key on every keyboard — because that is the
  /// right set for the `usbHidUsage` the `KeyData` half needs. The raw half is
  /// built by `KeyEventSimulator.getKeyData` out of the *per-platform* tables,
  /// which are much smaller, and it reaches for three of them
  /// (`_findPhysicalKeyByPlatform`, `_getKeyCode`, `_getScanCode`) with a bare
  /// `assert(x != null); return x!;` at each. So a key the set above accepts
  /// can still have no macOS scan code or no Android key code.
  ///
  /// Measured: `f24`, `browserBack` and `abort` all pass [_physicalKey] and
  /// then throw `Failed assertion … not found in android physical key map`
  /// from inside `flutter_test`. That is an `AssertionError`, not a
  /// [TargetError], so it escapes the guest's refusal path entirely and comes
  /// back as a bare stack trace with no screen attached to it, which is a poor
  /// answer for a caller who only mistyped a key name.
  ///
  /// Rather than reimplement three private lookups that would then drift, this
  /// asks the same function the send will ask, and turns whatever it throws
  /// into a refusal the caller can act on. `getKeyData` reads state and
  /// mutates none, so calling it twice costs a map scan and nothing else.
  static void _checkSimulatable(LogicalKeyboardKey key) {
    try {
      KeyEventSimulator.getKeyData(key, platform: _keyPlatform);
    } on Object {
      throw TargetError(
        TargetFailure.notFound,
        '${key.debugName} is not in the key tables for $_keyPlatform, so no '
        'keystroke can be built for it here — Flutter maps a different set of '
        'keys per platform, and this one is missing from that set rather than '
        'from your spelling. Pick another key.',
      );
    }
  }

  /// A logical key's physical twin, matched the way `flutter_test` matches it:
  /// by debug name.
  ///
  /// The complete set, because this answers the `usbHidUsage` the `KeyData`
  /// half carries. Whether *this platform* can build a raw message for it is a
  /// second question, and [_checkSimulatable] is the one that asks it.
  static PhysicalKeyboardKey _physicalKey(LogicalKeyboardKey key) {
    for (var physical in PhysicalKeyboardKey.knownPhysicalKeys) {
      if (physical.debugName == key.debugName) return physical;
    }
    throw TargetError(
      TargetFailure.notFound,
      '${key.debugName} has no physical key on any keyboard this can '
      'simulate, so there is no keystroke to send.',
    );
  }
}

/// Whether nothing in the app holds focus — so a keystroke dispatches from the
/// root scope, above every `Shortcuts` the app declares.
///
/// Key events dispatch from whatever holds primary focus and bubble to its
/// *ancestors*. With nothing focused that is the root scope, and every binding
/// in the app is missed. Read after a keystroke nothing handled, this is how an
/// engine tells "unhandled" — which plenty of keystrokes legitimately are —
/// from "never reached the app".
bool get nothingFocused {
  var focus = FocusManager.instance.primaryFocus;
  return focus == null || focus == FocusManager.instance.rootScope;
}
