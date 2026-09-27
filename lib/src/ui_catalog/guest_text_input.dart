import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../devices.dart';

/// The guest's text input — what lets a demo's `TextField` receive typing.
///
/// The guest has no platform text input: the host is a few hundred lines of C
/// with nothing on the other end of `flutter/textinput`, so the platform
/// control's messages go into the void and no field could ever receive a
/// character. This control replaces it ([TextInput.setInputControl]) and
/// builds the editing state in Dart instead, from the key events the GUI
/// already forwards — each carrying the character the host's keyboard layout
/// resolved it to.
///
/// It owns two things, and the second is the one that surprises: insertion,
/// and the **editing commands**. On Apple platforms the framework refuses to
/// act on backspace, delete, the arrows, home, end and page while a field is
/// focused, and waits for the platform to name the command instead — see
/// [_selectorFor]. So a guest doing only insertion gets a field that can be
/// typed into and never corrected.
///
/// The chords stay the framework's: ⌘A, ⌘C, ⌘Z and the rest are not disabled,
/// and resolve as ordinary shortcuts once the panel forwards them — see
/// `isReservedAppChord` on the host side, which decides what a demo is
/// allowed to hear.
///
/// What stays missing is composition: dead keys (⌥e → é) and CJK need a real
/// IME, which means proxying the host's, which is not built.
class GuestTextInput with TextInputControl {
  GuestTextInput._();

  static final instance = GuestTextInput._();

  TextInputClient? _client;
  TextInputConfiguration? _configuration;
  TextEditingValue _value = TextEditingValue.empty;
  var _listening = false;

  /// What keyboard the platform would be showing right now, or null for none.
  ///
  /// The two signals, and the whole state machine they drive. The
  /// framework computes this and hands it to whatever control is installed, so
  /// nothing downstream needs a heuristic for when a phone would raise its
  /// keyboard: it is up between a [show] and the [hide] after it.
  ///
  /// Three things about the traffic are worth knowing before reading it.
  /// [show] arrives **twice** per focus — an `EditableText` asks on focus and
  /// again on tap — so a listener must be edge-triggered on the value rather
  /// than counting calls, which a [ValueNotifier] does for free. Moving from
  /// one field to the next produces **no [hide] at all**: `TextInput` defers it
  /// to a microtask that cancels itself if anything re-attaches
  /// (`_scheduleHide`), which is why nothing here needs a debounce. And the
  /// *variant* can change without the keyboard ever going down — a text field
  /// to a number field is one keyboard morphing into a shorter one — which is
  /// why this carries which keyboard rather than only whether there is one.
  final asking = ValueNotifier<KeyboardVariant?>(null);

  @override
  void show() {
    _shown = true;
    asking.value = _asked;
  }

  @override
  void hide() {
    _shown = false;
    asking.value = null;
  }

  /// Whether the platform has been told to show, kept apart from what
  /// [asking] resolves to.
  ///
  /// The two are not the same question and collapsing them loses one: a
  /// `TextInputType.none` field is *shown* and asks for nothing, so reading
  /// "asking is null" as "hidden" would leave a field that switches from a
  /// custom pad to a normal keyboard unable to raise one.
  var _shown = false;

  /// What the attached field asked for, or null when it wants no system
  /// keyboard at all.
  ///
  /// `TextInputType.none` is a field that opens a connection and brings its
  /// own input surface: a custom pad, a date picker sheet, a calculator's own
  /// keys. The platform shows nothing for it — and `show()` is still called,
  /// so a control that took the call at face value would raise a keyboard over
  /// a screen that has none on the phone it is imitating.
  ///
  /// Read at [show] rather than at [attach] because a field may change its
  /// mind — see [updateConfig].
  KeyboardVariant? get _asked {
    var json = _configuration?.inputType.toJson();
    if (json == null) return null;
    var name = '${json['name']}';
    if (name == 'TextInputType.none') return null;
    // The channel's own `{name, signed, decimal}`, handed to the same
    // pure-Dart discriminator the scenario lane uses on the same map.
    return keyboardVariantForName(name, signed: json['signed'] == true);
  }

  /// Replaces the platform control. Call once, before `runApp`.
  void install() {
    TextInput.setInputControl(this);
  }

  /// Whether a field has focus: somewhere [fill] can put what it is given.
  bool get focused => _client != null;

  /// Fills the focused field with [text], as a platform's autofill does — a
  /// one-time code offered from an SMS — replacing what it held. False when
  /// no field has focus: there is nowhere for it to go.
  bool fill(String text) {
    if (_client == null) return false;
    _value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    TextInput.updateEditingValue(_value);
    return true;
  }

  @override
  void attach(TextInputClient client, TextInputConfiguration configuration) {
    _client = client;
    _configuration = configuration;
    // On while attached, off otherwise: an unfocused catalog pays nothing per
    // key, and a demo's own key handling sees every key whenever no field has
    // focus.
    if (!_listening) {
      _listening = true;
      HardwareKeyboard.instance.addHandler(_handleKey);
    }
  }

  @override
  void detach(TextInputClient client) {
    // A client switch attaches the new client before the old one's connection
    // closes; only the current client's detach may tear down.
    if (_client != client) return;
    _release();
  }

  /// What a platform does when the user closes the IME without touching the
  /// app — the swipe-down on Android, the dismiss key on an iPad, and the one
  /// gesture that takes a keyboard away from outside the app.
  ///
  /// It makes the app *react* rather than making artwork disappear:
  /// [TextInputClient.connectionClosed] is what `EditableText` unfocuses on,
  /// so the field lets go and the keyboard comes down because the view
  /// dismissed it, which is the rule the whole feature is built on.
  ///
  /// The trap it exists to avoid. On this path `TextInput._clearClient()`
  /// never runs, so no [detach] ever arrives: a control that waited for one
  /// would keep its key handler installed and its client believed-focused, and
  /// the next keystroke would go to a field that has already let go. So the
  /// teardown happens here, before the client is told.
  void dismiss() {
    var client = _client;
    if (client == null) return;
    _release();
    client.connectionClosed();
    asking.value = null;
  }

  void _release() {
    _shown = false;
    if (_listening) {
      _listening = false;
      HardwareKeyboard.instance.removeHandler(_handleKey);
    }
    _client = null;
    _configuration = null;
    _value = TextEditingValue.empty;
  }

  @override
  void updateConfig(TextInputConfiguration configuration) {
    _configuration = configuration;
    // A field that swaps its keyboard type while focused — a "use a custom
    // pad" toggle, a "this is a phone number" switch — has to move the
    // keyboard with it, in both directions and between variants.
    if (_client != null && _shown && asking.value != _asked) {
      asking.value = _asked;
    }
  }

  @override
  void setEditingState(TextEditingValue value) {
    _value = value;
  }

  bool _handleKey(KeyEvent event) {
    var client = _client;
    if (client == null || event is KeyUpEvent) return false;
    var keyboard = HardwareKeyboard.instance;

    // Editing commands before text, because a key can be both: backspace
    // arrives carrying DEL.
    var selector = _selectorFor(event.logicalKey, keyboard);
    if (selector != null) {
      client.performSelector(selector);
      return true;
    }

    var character = event.character;
    if (character == null || character.isEmpty) return false;
    // A chord is a command, not text, whichever letter names it. Left to the
    // framework, which still owns ⌘A, ⌘C and the rest.
    if (keyboard.isMetaPressed || keyboard.isControlPressed) return false;
    if (character == '\r' || character == '\n') return _enter();
    // Anything else non-printing belongs to whoever binds it.
    if (_isControl(character)) return false;
    _insert(character);
    return true;
  }

  /// The `NSStandardKeyBindingResponding` selector [key] means on macOS, or
  /// null when the key is not an editing command.
  ///
  /// This is the half of an IME that is easy to miss. On Apple platforms
  /// the framework deliberately refuses to act on the editing keys while a
  /// field is focused — `DefaultTextEditingShortcuts` maps backspace, delete,
  /// every arrow, home, end, page and escape to
  /// `DoNothingAndStopPropagationTextIntent` — because the platform is
  /// expected to deliver them as *named commands* through the text input
  /// channel instead. So a guest that forwards only key events gets typing and
  /// nothing else: no backspace, no caret, no selection. Naming the command is
  /// what the real macOS embedder does with `doCommandBySelector:`, and
  /// `EditableTextState.performSelector` turns the name back into the
  /// framework's own intent — word and line boundaries included, which is the
  /// reason to route through here rather than edit the value directly.
  ///
  /// Control chords are left out on purpose: the framework has not disabled
  /// those, so they still resolve as ordinary shortcuts.
  static String? _selectorFor(LogicalKeyboardKey key, HardwareKeyboard state) {
    if (state.isControlPressed) return null;
    var shift = state.isShiftPressed;
    var alt = state.isAltPressed;
    var meta = state.isMetaPressed;
    return switch (key) {
      LogicalKeyboardKey.backspace when meta => 'deleteToBeginningOfLine:',
      LogicalKeyboardKey.backspace when alt => 'deleteWordBackward:',
      LogicalKeyboardKey.backspace => 'deleteBackward:',

      LogicalKeyboardKey.delete when meta => 'deleteToEndOfLine:',
      LogicalKeyboardKey.delete when alt => 'deleteWordForward:',
      LogicalKeyboardKey.delete => 'deleteForward:',

      LogicalKeyboardKey.arrowLeft when meta =>
        shift
            ? 'moveToLeftEndOfLineAndModifySelection:'
            : 'moveToLeftEndOfLine:',
      LogicalKeyboardKey.arrowLeft when alt =>
        shift ? 'moveWordLeftAndModifySelection:' : 'moveWordLeft:',
      LogicalKeyboardKey.arrowLeft =>
        shift ? 'moveLeftAndModifySelection:' : 'moveLeft:',

      LogicalKeyboardKey.arrowRight when meta =>
        shift
            ? 'moveToRightEndOfLineAndModifySelection:'
            : 'moveToRightEndOfLine:',
      LogicalKeyboardKey.arrowRight when alt =>
        shift ? 'moveWordRightAndModifySelection:' : 'moveWordRight:',
      LogicalKeyboardKey.arrowRight =>
        shift ? 'moveRightAndModifySelection:' : 'moveRight:',

      LogicalKeyboardKey.arrowUp when meta =>
        shift
            ? 'moveToBeginningOfDocumentAndModifySelection:'
            : 'moveToBeginningOfDocument:',
      LogicalKeyboardKey.arrowUp when alt =>
        shift
            ? 'moveParagraphBackwardAndModifySelection:'
            : 'moveToBeginningOfParagraph:',
      LogicalKeyboardKey.arrowUp =>
        shift ? 'moveUpAndModifySelection:' : 'moveUp:',

      LogicalKeyboardKey.arrowDown when meta =>
        shift
            ? 'moveToEndOfDocumentAndModifySelection:'
            : 'moveToEndOfDocument:',
      LogicalKeyboardKey.arrowDown when alt =>
        shift
            ? 'moveParagraphForwardAndModifySelection:'
            : 'moveToEndOfParagraph:',
      LogicalKeyboardKey.arrowDown =>
        shift ? 'moveDownAndModifySelection:' : 'moveDown:',

      LogicalKeyboardKey.home =>
        shift
            ? 'moveToLeftEndOfLineAndModifySelection:'
            : 'moveToLeftEndOfLine:',
      LogicalKeyboardKey.end =>
        shift
            ? 'moveToRightEndOfLineAndModifySelection:'
            : 'moveToRightEndOfLine:',

      LogicalKeyboardKey.pageUp =>
        shift ? 'pageUpAndModifySelection:' : 'scrollPageUp:',
      LogicalKeyboardKey.pageDown =>
        shift ? 'pageDownAndModifySelection:' : 'scrollPageDown:',

      LogicalKeyboardKey.escape => 'cancelOperation:',
      LogicalKeyboardKey.tab => shift ? 'insertBacktab:' : 'insertTab:',
      _ => null,
    };
  }

  static bool _isControl(String character) =>
      character.runes.every((r) => r < 0x20 || r == 0x7F);

  /// Splits the way a platform IME does: a newline into a multiline field,
  /// the configured action — submit, usually — for anything else.
  ///
  /// The insert half cannot be left to the field: `EditableText` receiving
  /// `TextInputAction.newline` inserts nothing, *because* it assumes the IME
  /// already did.
  bool _enter() {
    var client = _client;
    var configuration = _configuration;
    if (client == null || configuration == null) return false;
    if (configuration.inputType == TextInputType.multiline) {
      _insert('\n');
    } else {
      client.performAction(configuration.inputAction);
    }
    return true;
  }

  void _insert(String text) {
    var selection = _value.selection;
    var start = selection.isValid ? selection.start : _value.text.length;
    var end = selection.isValid ? selection.end : _value.text.length;
    _value = TextEditingValue(
      text: _value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    TextInput.updateEditingValue(_value);
  }
}
