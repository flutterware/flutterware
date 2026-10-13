import 'dart:convert';
import 'dart:developer' as developer;

import '../guest_extensions.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../devices.dart';
import 'fake_keyboard.dart';
import 'guest_text_input.dart';
import 'keyboard.dart';

/// The guest's keyboard: what the app asks for, what the host allows, and how
/// tall the answer is.
///
/// Two facts arriving from opposite directions, which is the shape of the
/// whole feature. The app's opinion comes up from the framework — a field took
/// focus, so [GuestTextInput.asking] moved — and it knows nothing about
/// which phone it is on. The measurement comes down from the host, which knows
/// the device and cannot know when a field is focused. Neither half is a
/// keyboard on its own.
///
/// The measurement travels over the VM service rather than with the window
/// metrics, and that is forced rather than chosen: `FlutterWindowMetricsEvent`
/// carries a size, a ratio and four insets, and the guest already spends the
/// insets on the device's safe areas. A keyboard arriving on the same channel
/// would be indistinguishable from a notch.
///
/// *Which* keyboard to draw is on neither wire: the host already stages the
/// platform, so `defaultTargetPlatform` answers it — see
/// [CatalogKeyboardScope].
class CatalogKeyboard {
  CatalogKeyboard._();

  static final instance = CatalogKeyboard._();

  /// Bumped whenever what is on screen would change, so
  /// [CatalogKeyboardScope] has something to rebuild on.
  final revision = ValueNotifier<int>(0);

  KeyboardMode _mode = KeyboardMode.auto;
  double _deviceHeight = 0;
  double? _deviceKeypadHeight;
  var _installed = false;

  /// The device's measured letters keyboard, in logical pixels, already turned
  /// the way the device is. Zero for a stage with no keyboard at all — a
  /// desktop window, and `Fit`, which is not a device and has no measurement
  /// to draw.
  double get deviceHeight => _deviceHeight;

  KeyboardMode get mode => _mode;

  /// What the app is asking for, or null when it is asking for nothing.
  KeyboardVariant? get asked => GuestTextInput.instance.asking.value;

  /// Whether the app has asked for a keyboard, whatever [mode] then does with
  /// it.
  bool get requested => asked != null;

  /// Which keyboard is drawn.
  ///
  /// The app's where it has one, and letters otherwise — which covers a
  /// keyboard the *human* is holding up over a layout with nothing focused,
  /// and is the shape most fields would have asked for anyway.
  KeyboardVariant get variant => asked ?? KeyboardVariant.letters;

  /// What the screen actually loses. Zero on a stage with no measurement, so a
  /// forced-up keyboard on `Fit` raises nothing rather than inventing a height.
  double get height => switch (_mode) {
    KeyboardMode.down => 0,
    KeyboardMode.up => _heightFor(variant),
    KeyboardMode.auto => requested ? _heightFor(variant) : 0,
  };

  double _heightFor(KeyboardVariant variant) => keyboardHeightFor(
    variant,
    letters: _deviceHeight,
    keypad: _deviceKeypadHeight,
  );

  KeyboardState get state => KeyboardState(
    mode: _mode,
    requested: requested,
    variant: variant,
    height: height,
    deviceHeight: _deviceHeight,
  );

  /// Starts following the framework's own signal. Call once, before `runApp`,
  /// and after [GuestTextInput.install].
  void install() {
    if (_installed) return;
    _installed = true;
    GuestTextInput.instance.asking.addListener(_onRequestChanged);
  }

  void _onRequestChanged() {
    // Only when it changes the picture. Held *down*, the app's opinion moves
    // nothing at all; held *up*, it still chooses which keys are drawn and how
    // tall they are, so a forced keyboard follows a field from text to digits
    // the way the phone would.
    if (_mode != KeyboardMode.down && _deviceHeight > 0) _bump();
    // Pushed either way, because the *host* cares about the opinion even where
    // the screen does not move — a forced-down keyboard over a focused field
    // is exactly the state a control should be able to say out loud.
    _announce();
  }

  /// Applies what the host asked for. Returns whether anything moved.
  bool apply({
    KeyboardMode? mode,
    double? deviceHeight,
    double? deviceKeypadHeight,
    bool clearKeypad = false,
  }) {
    var before = state;
    _mode = mode ?? _mode;
    _deviceHeight = deviceHeight ?? _deviceHeight;
    if (clearKeypad) {
      _deviceKeypadHeight = null;
    } else if (deviceKeypadHeight != null) {
      _deviceKeypadHeight = deviceKeypadHeight;
    }
    var moved = state != before;
    if (moved) {
      _bump();
      _announce();
    }
    return moved;
  }

  void _bump() => revision.value++;

  /// The event the host listens for. Pushed rather than polled because the
  /// interesting transitions are the app's, and a host that had to ask would
  /// only ever find out about them a poll late — which for a control drawn
  /// over the keyboard band means drawn in the wrong place.
  static const eventKind = 'flutterware.keyboard';

  KeyboardState? _announced;

  void _announce() {
    var now = state;
    if (now == _announced) return;
    _announced = now;
    GuestExtensions.post(eventKind, now.toJson());
  }

  /// Registers the extension. Call once, before `runApp`.
  ///
  /// One extension, read and written through the same name — the shape
  /// `ext.flutterware.watch` already uses. No arguments reads; any argument
  /// writes and then reads, so a host never has to make two calls to find out
  /// what its own write did.
  void registerExtensions() {
    GuestExtensions.register('ext.flutterware.keyboard', (_, args) async {
      if (args['dismiss'] == 'true') {
        // The platform-closed path, not a mode change: the app is told its
        // connection went away and unfocuses, which brings the keyboard down
        // *because the view dismissed it*. A forced-up keyboard also lets go,
        // since pressing dismiss on a keyboard you raised by hand plainly
        // means take it away.
        if (_mode == KeyboardMode.up) apply(mode: KeyboardMode.auto);
        GuestTextInput.instance.dismiss();
      }
      var applied = apply(
        mode: switch (args['mode']) {
          String name => keyboardModeById(name),
          _ => null,
        },
        deviceHeight: switch (args['height']) {
          String height => double.tryParse(height),
          _ => null,
        },
        deviceKeypadHeight: switch (args['keypadHeight']) {
          String height => double.tryParse(height),
          _ => null,
        },
        // The empty string is how a host says *this device does not shrink*,
        // which is a different fact from saying nothing at all.
        clearKeypad: args['keypadHeight'] == '',
      );
      // Answered only once the frame it caused has been painted, so a host
      // that captures straight afterwards photographs the screen it asked for
      // rather than the one before it. Bounded, because a guest that has
      // stopped drawing should make this late rather than stuck.
      if (applied) {
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode(state.toJson()),
      );
    });
  }
}

/// [FakeKeyboard], driven by [CatalogKeyboard].
///
/// Sits above the demo and below nothing: the slab is inside the guest's own
/// tree, so **every capture that exists already contains it** — embedder
/// captures, the panel's texture, thumbnails, the web export — with no
/// compositing step anywhere. Shots come off the render view's layer, so this
/// is free.
///
/// The demo is passed through as a `child` rather than rebuilt, so raising the
/// keyboard costs a `MediaQuery` change and a paint rather than a rebuild of
/// whatever is on screen.
class CatalogKeyboardScope extends StatelessWidget {
  const CatalogKeyboardScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var keyboard = CatalogKeyboard.instance;
    return ValueListenableBuilder<int>(
      valueListenable: keyboard.revision,
      child: child,
      builder: (context, _, child) => FakeKeyboard(
        height: keyboard.height,
        variant: keyboard.variant,
        // Read rather than pushed. The host already stages the platform
        // through the framework's own `ext.flutter.platformOverride`, so
        // `defaultTargetPlatform` is the *same* fact the demo's own
        // `.adaptive` widgets are reading — and a second copy of it on this
        // wire is a second copy that can disagree.
        platform: defaultTargetPlatform == TargetPlatform.android
            ? DevicePlatform.android
            : DevicePlatform.ios,
        child: child!,
      ),
    );
  }
}
