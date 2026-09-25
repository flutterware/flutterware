import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Delivers the guest's key events, which the framework otherwise parks
/// forever.
///
/// Without this no key reaches a demo at all — not a shortcut, not an
/// arrow, not a character. The reason is a handshake our embedder cannot take
/// part in. `KeyEventManager.handleKeyData` receives what
/// `FlutterEngineSendKeyEvent` sends, infers from that first event that it is
/// talking to a `keyDataThenRawKeyData` embedder, and then *queues* every
/// event instead of dispatching it — because a platform embedder always
/// follows its key data with a legacy `flutter/keyevent` platform message,
/// and that message is what flushes the queue. The guest's host is a few
/// hundred lines of C with no platform channels, so the flush never comes and
/// the queue only grows.
///
/// Rather than have the C host fake a macOS raw-key JSON message — feeding a
/// path the framework has deprecated, in a keymap-specific format, to reach a
/// `RawKeyboard` whose state would then have to be kept consistent — this
/// replaces `onKeyData` and dispatches to both destinations the flush would
/// have reached: [HardwareKeyboard], which owns the pressed-key state and the
/// handler list, and `keyMessageHandler`, which is where `FocusManager` sits
/// and therefore how `Focus.onKeyEvent`, `Shortcuts` and a text field's own
/// editing keys are reached.
class GuestKeyboard {
  GuestKeyboard._();

  static final instance = GuestKeyboard._();

  /// Takes over key delivery. Call after the binding exists — it is
  /// `ServicesBinding` that installs the handler being replaced — and before
  /// `runApp`.
  ///
  /// Taken twice, because the framework takes it back. `ServicesBinding` asks
  /// the platform for `getKeyboardState` as it starts and installs its own
  /// handler *when the answer arrives* — which is after this has run, on a
  /// host that answers at all. `flutter/keyboard` is an optional channel, so
  /// even the empty reply of a host that implements nothing counts. A host
  /// that never runs its platform tasks never answers, which is how this hid;
  /// one that does puts every key back in the queue. So a sync of our own:
  /// asked after the framework's on the same channel, it is answered after
  /// it too, and its answer is the moment the handler is ours to keep.
  void install() {
    var dispatcher = WidgetsBinding.instance.platformDispatcher;
    dispatcher.onKeyData = _handleKeyData;
    unawaited(
      HardwareKeyboard.instance.syncKeyboardState().then((_) {
        dispatcher.onKeyData = _handleKeyData;
      }),
    );
  }

  bool _handleKeyData(ui.KeyData data) {
    // The framework's own marker for "no event here, I am only telling you
    // which transit mode I speak".
    if (data.physical == 0 && data.logical == 0) return false;
    var event = _toEvent(data);
    if (event == null) return false;

    // Both destinations, in the order the flush would have used: the keyboard
    // state first, so a handler asking what is held sees this event included.
    var handled = HardwareKeyboard.instance.handleKeyEvent(event);
    // Deprecated, and used anyway: this is still where `FocusManager` installs
    // itself, so it remains the only way to reach the focus tree. When the
    // framework finally retires it, `FocusManager` will have moved to a
    // `HardwareKeyboard` handler and the line above will already be enough.
    // ignore_for_file: deprecated_member_use
    var messageHandler =
        ServicesBinding.instance.keyEventManager.keyMessageHandler;
    if (messageHandler != null) {
      handled = messageHandler(KeyMessage([event], null)) || handled;
    }
    return handled;
  }

  /// Builds the event, or null when it would contradict what the keyboard
  /// already believes.
  ///
  /// [HardwareKeyboard] asserts on a contradiction rather than absorbing it,
  /// and the guest is driven by a panel that can stop forwarding mid-press:
  /// hold a key, click away from the preview, release, and the release is
  /// delivered to the host's own focus rather than to us — leaving the guest
  /// certain a key is still down. A platform embedder repairs this by
  /// synthesizing the missing events; here the repair is to drop the event
  /// that cannot be true, which costs one keystroke where the alternative is
  /// a red screen over the demo.
  KeyEvent? _toEvent(ui.KeyData data) {
    var physical = PhysicalKeyboardKey(data.physical);
    var logical = LogicalKeyboardKey(data.logical);
    var held = HardwareKeyboard.instance.physicalKeysPressed.contains(physical);
    switch (data.type) {
      case ui.KeyEventType.down:
        // A key the guest already holds, pressed again: the repeat it must
        // have been, since the release never arrived.
        return held
            ? KeyRepeatEvent(
                physicalKey: physical,
                logicalKey: logical,
                character: data.character,
                timeStamp: data.timeStamp,
              )
            : KeyDownEvent(
                physicalKey: physical,
                logicalKey: logical,
                character: data.character,
                timeStamp: data.timeStamp,
                synthesized: data.synthesized,
              );
      case ui.KeyEventType.up:
        return held
            ? KeyUpEvent(
                physicalKey: physical,
                logicalKey: logical,
                timeStamp: data.timeStamp,
                synthesized: data.synthesized,
              )
            : null;
      case ui.KeyEventType.repeat:
        // A repeat for a key nothing saw go down is the same missing-press
        // story from the other end; a down is what makes the state true.
        return held
            ? KeyRepeatEvent(
                physicalKey: physical,
                logicalKey: logical,
                character: data.character,
                timeStamp: data.timeStamp,
              )
            : KeyDownEvent(
                physicalKey: physical,
                logicalKey: logical,
                character: data.character,
                timeStamp: data.timeStamp,
                synthesized: data.synthesized,
              );
    }
  }
}
