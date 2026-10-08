/// The catalog's device *policy* — the defaults and the resolution rules.
///
/// The table itself lives in `package:flutterware` (`Devices.all`), because a
/// project's `tool/flutterware.dart` and a scenario folder's
/// `flutter_test_config.dart` name devices too, and neither can import the
/// GUI. Re-exported here so the panel keeps one import for both halves.
library;

import 'package:flutterware/devices.dart';

export 'package:flutterware/devices.dart';

/// Whether a finger, rather than a mouse, is what touches this device.
///
/// The other half of staging a device — see [CaptureViewport.platform]. The
/// framework asks *both* questions before it decides what tapping outside a
/// text field means: on a mobile platform a **touch** leaves the keyboard up
/// and a mouse click dismisses it, which is why a phone driven by mouse events
/// behaved like a desktop no matter what platform it claimed to be.
///
/// A desktop size is a window and keeps the mouse, which is also what keeps
/// hover working where hover is real.
bool deviceIsTouched(Device? device) =>
    device != null && device.kind != DeviceKind.desktop;

/// How a device reads in the bar: its screen in logical pixels, which is the
/// number a layout is written against.
String describeDevice(Device device) =>
    '${device.width.round()}×${device.height.round()}';

/// The device an address names, or the panel when it names none.
///
/// The one place a device comes from. Nothing holds one: it is a function
/// of the address, recomputed wherever it is needed. That is what stops the
/// picker and the address from being two copies of the same fact chasing each
/// other a frame apart.
///
/// [fitDeviceId] and an absent parameter both resolve to the panel. They used
/// to differ: an entry could declare a form factor, and "fit" was how you said
/// *no* frame rather than *no opinion*. With the declaration gone there is one
/// answer, and the distinction is kept in the address only because a chosen
/// device should survive a reload.
Device? resolveDevice(String? param) =>
    param == null ? null : deviceById(param);

/// What `orientation` means, for every action that offers it.
///
/// One string because two plugins declare the parameter and a reader meeting it
/// in `previews screenshot` and again in `scenarios run` should not have to
/// work out whether the two differ.
const orientationParameterDoc =
    'Which way up the device is — `portrait` (the default) or `landscape`. '
    'An axis on top of `device` rather than a device of its own, so `ipad` '
    'plus `landscape` is the same iPad on its side: the screen trades width '
    'for height, and the safe areas become the ones that device declares for '
    'landscape (a phone loses its status bar rather than moving it). Ignored '
    'by anything that cannot turn, which is every desktop size and `fit`.';

/// The orientation an address names, or null when it names none — which means
/// portrait.
///
/// Derived from the address like [resolveDevice], and applied by handing the
/// pair to `Device.oriented`: nothing downstream of that sees an orientation,
/// only a device whose numbers already agree with it.
ScreenOrientation? resolveOrientation(String? param) =>
    param == null ? null : orientationById(param);

/// An `?orientation=` this build has never heard of, or null. Shown for the
/// same reason [unknownDeviceIn] is.
String? unknownOrientationIn(String? param) =>
    param != null && !isOrientationId(param) ? param : null;

/// A `?device=` this build has never heard of, or null.
///
/// Derived rather than remembered, like everything else here. Meant to be shown
/// loudly: silently framing as the panel when the address asked for an iPhone
/// produces a picture that is wrong without looking wrong.
String? unknownDeviceIn(String? param) =>
    param != null && !isDeviceId(param) ? param : null;

/// How big the guest renders, and *as what*.
///
/// Four kinds of number rather than a size, because a phone is not a bitmap of
/// a certain shape. The guest is told its buffer in physical pixels and its
/// ratio separately, so a demo reading `MediaQuery` sees the phone's logical
/// size — 390×844, not 1170×2532 — which is the number the layout was written
/// against. The insets are the notch.
///
/// The panel's own capture is the degenerate case: a rectangle at ratio 1 with
/// nothing cut out of it.
class CaptureViewport {
  const CaptureViewport({
    required this.width,
    required this.height,
    this.pixelRatio = 1,
    this.insetTop = 0,
    this.insetRight = 0,
    this.insetBottom = 0,
    this.insetLeft = 0,
    this.platform,
    this.keyboard = 0,
    this.keypadKeyboard,
    this.keyboardMode = KeyboardMode.auto,
  });

  /// The device's screen, at its own ratio, with its safe areas — the same
  /// three things the panel hands its guest, so a capture and what you were
  /// looking at are the same picture.
  factory CaptureViewport.of(Device device) => CaptureViewport(
    width: (device.width * device.pixelRatio).round(),
    height: (device.height * device.pixelRatio).round(),
    pixelRatio: device.pixelRatio,
    insetTop: device.insetTop,
    insetRight: device.insetRight,
    insetBottom: device.insetBottom,
    insetLeft: device.insetLeft,
    platform: device.platform,
    // Already turned: [Device.rotated] swaps in `landscapeKeyboard`, because a
    // phone's landscape keyboard is not its portrait one in a wider box.
    keyboard: device.keyboard,
    keypadKeyboard: device.keypadKeyboard,
  );

  /// What a capture that names no device gets.
  static const panel = CaptureViewport(
    width: previewPanelWidth,
    height: previewPanelHeight,
  );

  /// Physical pixels — the size of the image that comes out.
  final int width;
  final int height;

  final double pixelRatio;
  final double insetTop;
  final double insetRight;
  final double insetBottom;
  final double insetLeft;

  /// What the guest is staged *as*, or null for the panel's own rectangle.
  ///
  /// Not a number like the rest, and here anyway: it is the other half of what
  /// makes a capture the picture you were looking at. A window shaped like a
  /// phone running as a Mac renders desktop transitions, desktop scrollbars
  /// and the desktop rule for tapping outside a field — see
  /// `stageGuestPlatform`.
  final DevicePlatform? platform;

  /// How tall this device's software keyboard is, in logical pixels, once it
  /// is up — zero for a stage that has none, which is every desktop size and
  /// the panel's own rectangle.
  ///
  /// Measured per device per orientation rather than derived, and already
  /// turned by the time it lands here.
  final double keyboard;

  /// The digit pad's height — what a `phone` or `number` field gets — or null
  /// where this device does not shrink for one.
  ///
  /// Null carries the same conservative meaning `Device.keypadKeyboard` gives
  /// it: **no shrink**. It covers a device that genuinely does not have a
  /// shorter keypad, one with no keyboard at all, and a cell nobody has
  /// measured — all of which want the letters height rather than a guess
  /// downwards.
  final double? keypadKeyboard;

  /// Whether that keyboard follows the entry or the caller.
  ///
  /// On the viewport for the reason [platform] is: it changes the picture,
  /// so two settings are two captures rather than one file written twice —
  /// and a warm guest being reused has to be re-staged when it moves.
  final KeyboardMode keyboardMode;

  /// The same viewport with the keyboard asked for differently.
  CaptureViewport withKeyboard(KeyboardMode mode) => CaptureViewport(
    width: width,
    height: height,
    pixelRatio: pixelRatio,
    insetTop: insetTop,
    insetRight: insetRight,
    insetBottom: insetBottom,
    insetLeft: insetLeft,
    platform: platform,
    keyboard: keyboard,
    keypadKeyboard: keypadKeyboard,
    keyboardMode: mode,
  );

  /// The same viewport at a different size, for a caller that asked for one
  /// explicitly. The ratio and the insets stay: asking for a taller iPhone is
  /// asking for a taller iPhone, not for a slab of glass with no notch.
  /// This screen, as the `flutter_tester` harness is told about it.
  ///
  /// The one place the host's viewport becomes the wire's, so the two
  /// backends are staged from one set of numbers: the guest gets them over its
  /// resize message and the harness gets them here.
  StagedViewport get staged => StagedViewport(
    width: width.toDouble(),
    height: height.toDouble(),
    pixelRatio: pixelRatio,
    insetTop: insetTop,
    insetRight: insetRight,
    insetBottom: insetBottom,
    insetLeft: insetLeft,
    platform: platform,
    // The variant is the *field's* business, not the stage's, and this lane
    // renders one cold frame with nothing focused — so what travels is the
    // height of the letters keyboard, which is what `KeyboardMode.up` means
    // everywhere else.
    keyboard: keyboard,
    keyboardUp: keyboardMode == KeyboardMode.up,
  );

  CaptureViewport resized({int? width, int? height}) => CaptureViewport(
    width: width ?? this.width,
    height: height ?? this.height,
    pixelRatio: pixelRatio,
    insetTop: insetTop,
    insetRight: insetRight,
    insetBottom: insetBottom,
    insetLeft: insetLeft,
    platform: platform,
    keyboard: keyboard,
    keypadKeyboard: keypadKeyboard,
    keyboardMode: keyboardMode,
  );

  /// By value, because "is this the same screen" is a question about the
  /// numbers and the identity, never about which object holds them. An audit walking a
  /// catalog of mixed form factors asks it once per entry, to resize the warm
  /// guest only where the canvas actually changed.
  @override
  bool operator ==(Object other) =>
      other is CaptureViewport &&
      other.width == width &&
      other.height == height &&
      other.pixelRatio == pixelRatio &&
      other.insetTop == insetTop &&
      other.insetRight == insetRight &&
      other.insetBottom == insetBottom &&
      other.insetLeft == insetLeft &&
      other.platform == platform &&
      other.keyboard == keyboard &&
      other.keypadKeyboard == keypadKeyboard &&
      other.keyboardMode == keyboardMode;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    pixelRatio,
    insetTop,
    insetRight,
    insetBottom,
    insetLeft,
    platform,
    keyboard,
    keypadKeyboard,
    keyboardMode,
  );

  @override
  String toString() => 'CaptureViewport(${width}x$height @$pixelRatio)';
}
