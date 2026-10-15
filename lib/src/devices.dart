/// The device vocabulary — shared by the GUI's pickers, `fw`, MCP, and the
/// scenario axes.
///
/// In the package rather than the app because three files outside the GUI name
/// devices: a project's `tool/flutterware.dart`, a scenario folder's
/// `flutter_test_config.dart`, and CI. Pure Dart, no Flutter import: it is a
/// table of numbers, and the one place that draws a frame around them
/// translates on the spot.
library;

/// What silhouette to draw around a screen, if any.
enum DeviceKind { phone, tablet, desktop }

/// Ours rather than `TargetPlatform`, which is Flutter-only. Translated at the
/// one place a frame is drawn.
enum DevicePlatform { ios, android, macos, windows, linux }

/// Which way up a device is — an axis applied on top of a [Device], not a
/// device of its own.
///
/// A rotated iPad is the same iPad: same id, same ratio, same artwork. A second
/// entry for it would double the table per rotatable device and turn a
/// 4-device × 2-orientation matrix into eight ids instead of two crossed lists.
///
/// One landscape, not two. Real hardware has a left and a right, and they
/// differ only in which side the cutout lands on — so a second value would
/// double every matrix to buy a mirrored inset. This one is defined by a fixed
/// physical side: **the cutout on the left**. Deliberately not "the leading
/// side", which flips under an RTL locale: orientation must not change meaning
/// because the language axis moved.
///
/// The enum is open on purpose. A second value can arrive without changing the
/// grammar, and it would be the mirror of this one rather than a new
/// declaration.
///
/// Not `DeviceOrientation`, which Flutter already defines in `services.dart`
/// and therefore has in scope in every file that imports `material.dart`. A
/// consumer declaring a profile would have had to hide one of the two to name
/// the other, in the API whose whole job is to be nameable from a
/// `flutter_test_config.dart`. `Orientation` is taken as well, by
/// `widgets.dart`.
enum ScreenOrientation { portrait, landscape }

/// Whether the software keyboard follows the app, or the person looking at it.
///
/// An axis applied on top of a [Device], like [ScreenOrientation] — and like it
/// in the way that matters: a phone with its keyboard up is the same phone,
/// with less screen.
///
/// Auto is not "off". It is the whole feature: the app asks for a keyboard
/// when a field takes focus and lets go of it when the view dismisses one, and
/// that is what a phone does. The two forced states are for the layout with no
/// field in it — *what does this do with 335 points less* — which nothing on
/// screen would otherwise ask.
///
/// Here rather than beside the guest that drives it, for the reason
/// [ScreenOrientation] is: a `PreviewCanvas` names these, and a project
/// declaring one must not have to import Flutter to do it.
enum KeyboardMode {
  /// Exactly what the app asks for. The default everywhere.
  auto,

  /// Raised, focus or no focus. Sticky until it is cleared, or until the
  /// keyboard's own dismiss key is pressed.
  up,

  /// Down, whatever the app asks for.
  down,
}

/// Which keyboard a field asked for — what a platform draws, not only how
/// tall it is.
///
/// Two facts wear one name here, and they are genuinely separate. The
/// *height* differs by platform: an iPhone gives a keypad 27 fewer points than
/// a QWERTY upright and 44 on its side, Gboard drops its suggestion strip for
/// one — about 44 — and an iPad gives every type the same keyboard. The
/// *picture* differs
/// everywhere — a number pad looks nothing like a letter keyboard on any
/// device. So a variant always changes what is drawn, and changes the height
/// only where the device has a measurement saying it should.
///
/// Here rather than beside the guest that reads it, for the reason
/// [KeyboardMode] and [ScreenOrientation] are: this is a fact about the
/// device, and the code that maps a `TextInputType` onto it must not have to
/// import Flutter.
enum KeyboardVariant {
  /// The full letter keyboard, and what most fields get.
  letters,

  /// Letters with an `@` and a dot on the bottom row.
  email,

  /// Letters with a slash and a `.com`.
  url,

  /// A digit pad — a grid of numbers rather than rows of letters.
  keypad,
}

/// The variant a field asking for [name] gets.
///
/// [name] and [signed] are the text input channel's own spelling — the
/// `{name, signed, decimal}` map that rides `TextInput.setClient`, which both
/// the previews guest and the scenario binding receive verbatim. Taking the
/// pair rather than a `TextInputType` is what lets one function serve both
/// without either lane translating first.
///
/// `signed` is the discriminator nobody expects. A plain number field and
/// a decimal one get iOS's keypad; the moment a minus sign is allowed the
/// platform gives the full punctuation keyboard at full height instead.
/// Measured on two phones, both agreeing.
///
/// Anything unrecognised is [KeyboardVariant.letters], which is the shape most
/// types have and the safe answer for a type this build has not heard of.
KeyboardVariant keyboardVariantForName(String name, {bool signed = false}) =>
    switch (name) {
      'TextInputType.phone' => KeyboardVariant.keypad,
      'TextInputType.number' when !signed => KeyboardVariant.keypad,
      'TextInputType.emailAddress' => KeyboardVariant.email,
      'TextInputType.url' => KeyboardVariant.url,
      _ => KeyboardVariant.letters,
    };

/// How tall the keyboard a field asked for [variant] is, on a screen whose
/// letters keyboard is [letters] and whose digit pad is [keypad].
///
/// [Device.keyboardFor] is this rule with a device's own numbers. It is out
/// here for the previews guest, which is told the two numbers over the wire
/// and never holds a [Device] — one rule for both, so they cannot drift.
double keyboardHeightFor(
  KeyboardVariant variant, {
  required double letters,
  double? keypad,
}) => switch (variant) {
  KeyboardVariant.keypad => keypad ?? letters,
  // Email and URL are the *same* keyboard with two keys swapped in the
  // bottom row, on every device measured. They differ in the picture and not
  // in the height.
  _ => letters,
};

/// A device's safe areas, as one value.
///
/// Ours rather than `EdgeInsets` because this file is pure Dart by design: a
/// project's `tool/flutterware.dart` and a scenario folder's
/// `flutter_test_config.dart` both import it, and neither should have to pull
/// in Flutter to name a device.
class DeviceInsets {
  const DeviceInsets({
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.left = 0,
  });

  final double top;
  final double right;
  final double bottom;
  final double left;
}

/// One device an address may name.
class Device {
  const Device(
    this.id,
    this.label, {
    required this.kind,
    required this.platform,
    required this.group,
    required this.width,
    required this.height,
    required this.pixelRatio,
    this.insetTop = 0,
    this.insetRight = 0,
    this.insetBottom = 0,
    this.insetLeft = 0,
    this.landscape,
    this.keyboard = 0,
    this.landscapeKeyboard,
    this.keypadKeyboard,
    this.landscapeKeypadKeyboard,
  });

  /// What goes in an address — `?device=iphone-16`.
  ///
  /// Ours rather than `device_frame`'s identifier: an address is written by
  /// hand, pasted into a terminal and produced by an agent, so its vocabulary
  /// has to be stable and guessable. A third party's internal identifier is
  /// neither, and it would leak into every saved link.
  final String id;

  /// What a person reads in the picker.
  final String label;

  /// The heading it appears under.
  final String group;

  final DeviceKind kind;

  final DevicePlatform platform;

  /// The screen in **logical** pixels — the number a layout is written
  /// against, and what the app reads from `MediaQuery`.
  final double width;
  final double height;

  final double pixelRatio;

  /// The notch, the island, the gesture bar — whatever is not drawable.
  /// Without these an `AppBar` renders under the cutout and a capture misses
  /// the exact thing a phone frame exists to catch.
  final double insetTop;
  final double insetRight;
  final double insetBottom;
  final double insetLeft;

  /// The safe areas when this device is on its side, or null for the swap-only
  /// case: width and height trade places and the insets stay where they are.
  ///
  /// Declared, not computed. Permuting the four insets geometrically is
  /// wrong on exactly the devices it matters on. An iPhone in landscape *loses*
  /// its status bar rather than moving it — the top inset goes to 0, not to a
  /// side — the cutout inset lands on both sides, and the home indicator stays
  /// at the interface bottom and shrinks. A tablet, meanwhile, really is just
  /// swap-width-and-height, which is why null is the default: only the notched
  /// phones say anything here.
  ///
  /// `device_frame` storing a separately measured `rotatedSafeAreas` beside its
  /// `safeAreas` is the same conclusion reached from the hardware.
  final DeviceInsets? landscape;

  /// How tall the software keyboard is on this device, in logical pixels — 0
  /// for a device that has none, which is every desktop size.
  ///
  /// Measured, not computed, like [landscape] and for the same reason:
  /// there is no formula. A 375-wide phone with a home button gets 260 and a
  /// 375-wide phone with a notch gets a different number entirely, because the
  /// number includes whatever the platform puts under the keys.
  ///
  /// The height *with* the predictive bar, which is what a phone shows out of
  /// the box.
  final double keyboard;

  /// The keyboard's height with the device on its side, or null when it has no
  /// keyboard at all.
  ///
  /// Declared rather than scaled, exactly like [landscape]: a landscape
  /// keyboard is not a portrait keyboard in a wider box — it is shorter, by a
  /// different amount on every device.
  final double? landscapeKeyboard;

  /// How tall the **digit pad** is — what a `phone` or `number` field gets —
  /// or null where this device does not shrink for one.
  ///
  /// Null is the conservative answer and it means *no shrink*: the letters
  /// height stands. It covers three different situations on purpose, because
  /// they all want the same behaviour — a device that genuinely does not
  /// shrink (every iPad), a device with no keyboard at all, and a cell nobody
  /// has measured yet. A keyboard that is too *tall* is the failure this whole distinction
  /// exists to remove, so an unmeasured cell must never guess downwards.
  final double? keypadKeyboard;

  /// The digit pad with the device on its side, and null with the same meaning
  /// as [keypadKeyboard] — no shrink, use the landscape letters height.
  final double? landscapeKeypadKeyboard;

  /// How tall this device's keyboard is when a field asks for [variant].
  ///
  /// The one place a variant becomes a number, so nothing downstream has
  /// to know which variants differ on which platform — an iPad answers the
  /// same height for all four, and that is a property of the iPad rather than
  /// something a caller should special-case.
  ///
  /// Already turned: call it on the device [oriented] gave you.
  double keyboardFor(KeyboardVariant variant) =>
      keyboardHeightFor(variant, letters: keyboard, keypad: keypadKeyboard);

  /// Whether orientation is a question this device answers. Desktops are
  /// windows: there is no other way up.
  ///
  /// Mirrors `device_frame`'s `canRotate`, and it is what stops a matrix from
  /// running a desktop twice to produce the same pixels.
  bool get canRotate => kind != DeviceKind.desktop;

  /// This device as [orientation] shows it — itself for portrait, for null, and
  /// for anything that cannot rotate.
  ///
  /// The one place the orientation axis becomes geometry. Everything
  /// downstream takes a [Device] and reads `width`, `height` and the insets —
  /// the capture viewport, the harness args, the silhouette, the splash sweep —
  /// so resolving the axis into a device here leaves all of them untouched.
  Device oriented(ScreenOrientation? orientation) =>
      orientation == ScreenOrientation.landscape && canRotate
      ? rotated()
      : this;

  /// This device on its side, whatever it thinks of the idea — [oriented] is
  /// the one that asks [canRotate] first.
  ///
  /// Keeps [id] and [label]: a rotated iPad is still `ipad`, which is what lets
  /// the frame lookup and every saved address go on working.
  Device rotated() => Device(
    id,
    label,
    kind: kind,
    platform: platform,
    group: group,
    width: height,
    height: width,
    pixelRatio: pixelRatio,
    insetTop: landscape?.top ?? insetTop,
    insetRight: landscape?.right ?? insetRight,
    insetBottom: landscape?.bottom ?? insetBottom,
    insetLeft: landscape?.left ?? insetLeft,
    landscape: landscape,
    keyboard: landscapeKeyboard ?? keyboard,
    landscapeKeyboard: landscapeKeyboard,
    // **Not `?? keypadKeyboard`.** A portrait keypad is *taller* than a
    // landscape letters keyboard on every phone in the table, so falling back
    // to it would turn on a shrink that grows the keyboard. Null here is the
    // conservative answer the field documents: no shrink, letters height.
    keypadKeyboard: landscapeKeypadKeyboard,
    landscapeKeypadKeyboard: landscapeKeypadKeyboard,
  );

  @override
  String toString() => 'Device($id)';
}

/// What `?device=` means "no device at all": the panel itself, at whatever size
/// the window happens to be.
///
/// A value rather than an absent parameter, because picking it is a decision.
/// Leaving it out means "not chosen", which is what lets an entry's own
/// `formFactor` speak; `fit` means "I chose not to frame this", and those are
/// different answers.
const fitDeviceId = 'fit';

/// The devices worth offering, which is not all of them.
///
/// A picker with a hundred entries is unusable. What a *layout*
/// meets is a handful of size classes — small, standard, large, tablet,
/// desktop — so this is one of each per platform, named after a device that
/// sits in that class.
///
/// **Every phone and iPad here is a real screen**, because each one wears
/// `device_frame`'s hand-drawn body for it (`device_frames.dart`) and a body
/// only fits the glass it was drawn around: `test/device_frames_test.dart`
/// holds every row's size and ratio to its body's. The Android tablets, which
/// `device_frame` draws none of, take its generic silhouette instead.
///
/// The safe areas and the keyboards are not the bodies'. They are what the
/// platform reports on the OS that ships now — iOS 26.2 simulators and API 35
/// emulators — and the frame is handed ours, because
/// those numbers move with the OS and not only with the glass: an iPad's status
/// bar grew from 24 to 32 with iPadOS 26, an iPhone's landscape home indicator
/// shrank from 21 to 20, and its landscape keyboard from 219 to 209.
/// `tool/measure_devices.dart` takes every one of them again, and is what to
/// run when a major OS ships.
abstract final class Devices {
  // ---------------------------------------------------------------- iOS
  //
  // The keyboards are iOS 26.2's, and on it the keyboard follows the width
  // class rather than the generation: every notched or island phone up to 402
  // wide raises 335 (308 for digits), every one from 428 up raises 345 (318),
  // and all of them 209 on their side (165). The 16s' 336 and 219 that used
  // to be here were iOS 18's — the same glass, a different keyboard.

  static const iphoneSe = Device(
    'iphone-se',
    'iPhone SE',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 375,
    height: 667,
    pixelRatio: 2,
    insetTop: 20,
    // Nothing at all on its side: the status bar hides in landscape, and with
    // a home button there is no indicator to make room for. Swap-only would
    // have kept the 20.
    landscape: DeviceInsets(),
    keyboard: 260,
    landscapeKeyboard: 206,
    keypadKeyboard: 233,
    landscapeKeypadKeyboard: 162,
  );

  static const iphone13 = Device(
    'iphone-13',
    'iPhone 13',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 390,
    height: 844,
    pixelRatio: 3,
    insetTop: 47,
    insetBottom: 34,
    landscape: DeviceInsets(left: 47, right: 47, bottom: 20),
    keyboard: 335,
    landscapeKeyboard: 209,
    keypadKeyboard: 308,
    landscapeKeypadKeyboard: 165,
  );

  /// The Dynamic Island generation — the same screen as an iPhone 15, and the
  /// one most users are holding.
  static const iphone16 = Device(
    'iphone-16',
    'iPhone 16',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 393,
    height: 852,
    pixelRatio: 3,
    insetTop: 59,
    insetBottom: 34,
    landscape: DeviceInsets(left: 59, right: 59, bottom: 20),
    keyboard: 335,
    landscapeKeyboard: 209,
    keypadKeyboard: 308,
    landscapeKeypadKeyboard: 165,
  );

  /// The screen the base iPhone 17 moved to as well — so the current standard
  /// size, not only the Pro's — with a status bar three points taller than a
  /// 16's.
  static const iphone16Pro = Device(
    'iphone-16-pro',
    'iPhone 16 Pro',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 402,
    height: 874,
    pixelRatio: 3,
    insetTop: 62,
    insetBottom: 34,
    landscape: DeviceInsets(left: 62, right: 62, bottom: 20),
    keyboard: 335,
    landscapeKeyboard: 209,
    keypadKeyboard: 308,
    landscapeKeypadKeyboard: 165,
  );

  static const iphone12ProMax = Device(
    'iphone-12-pro-max',
    'iPhone 12 Pro Max',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 428,
    height: 926,
    pixelRatio: 3,
    insetTop: 47,
    insetBottom: 34,
    landscape: DeviceInsets(left: 47, right: 47, bottom: 20),
    keyboard: 345,
    landscapeKeyboard: 209,
    keypadKeyboard: 318,
    landscapeKeypadKeyboard: 165,
  );

  /// The large screen of the line that is not Pro — the same glass as a 15 Pro
  /// Max.
  static const iphone16Plus = Device(
    'iphone-16-plus',
    'iPhone 16 Plus',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 430,
    height: 932,
    pixelRatio: 3,
    insetTop: 59,
    insetBottom: 34,
    landscape: DeviceInsets(left: 59, right: 59, bottom: 20),
    keyboard: 345,
    landscapeKeyboard: 209,
    keypadKeyboard: 318,
    landscapeKeypadKeyboard: 165,
  );

  /// The largest iPhone screen there is — what a layout overflows on last and
  /// what a store listing wants first.
  static const iphone16ProMax = Device(
    'iphone-16-pro-max',
    'iPhone 16 Pro Max',
    kind: DeviceKind.phone,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 440,
    height: 956,
    pixelRatio: 3,
    insetTop: 62,
    insetBottom: 34,
    landscape: DeviceInsets(left: 62, right: 62, bottom: 20),
    keyboard: 345,
    landscapeKeyboard: 209,
    keypadKeyboard: 318,
    landscapeKeypadKeyboard: 165,
  );

  /// The iPad with a home button, whose status bar is all there is to avoid.
  static const iPad = Device(
    'ipad',
    'iPad',
    kind: DeviceKind.tablet,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 810,
    height: 1080,
    pixelRatio: 2,
    insetTop: 32,
    keyboard: 320,
    landscapeKeyboard: 408,
  );

  static const iPadPro13 = Device(
    'ipad-pro-13',
    'iPad Pro 13"',
    kind: DeviceKind.tablet,
    platform: DevicePlatform.ios,
    group: 'iOS',
    width: 1032,
    height: 1376,
    pixelRatio: 2,
    insetTop: 32,
    insetBottom: 25,
    keyboard: 403,
    landscapeKeyboard: 498,
  );

  // ------------------------------------------------------------ Android
  //
  // **Named by size, drawn as a handset.** Android screens cluster into a few
  // logical sizes that a dozen phones share, so a row is a size class rather
  // than a model — but each size is a real panel, which is what lets it wear
  // that panel's body instead of a generic lozenge: a compact Samsung, a
  // Pixel, a large Pixel.
  //
  // The phones' insets are the body author's, read off the hardware, and not
  // ours: an emulator cannot check them. Most of its device profiles emulate
  // no camera cutout at all and report a 24-point status bar that no
  // punch-hole phone has; the one that does (a Pixel 8a) gives 46, in line
  // with these. The gesture bar along the bottom is measured, on every row.

  /// The compact flagship — a Galaxy S25's screen.
  static const androidSmall = Device(
    'android-small',
    'Small phone',
    kind: DeviceKind.phone,
    platform: DevicePlatform.android,
    group: 'Android',
    width: 360,
    height: 780,
    pixelRatio: 3,
    insetTop: 32,
    insetBottom: 24,
    // The cutout goes to the left, where `ScreenOrientation.landscape` puts
    // it, and the status bar stays along the top.
    landscape: DeviceInsets(left: 32, top: 24, bottom: 24),
    keyboard: 303,
    landscapeKeyboard: 235,
    keypadKeyboard: 259,
    landscapeKeypadKeyboard: 197,
  );

  /// The shape almost every current Android phone is — a Pixel 9's screen:
  /// tall, a punch hole in the status bar, a gesture bar eating the bottom.
  static const androidTall = Device(
    'android-tall',
    'Tall phone',
    kind: DeviceKind.phone,
    platform: DevicePlatform.android,
    group: 'Android',
    // The panel's pixels over its ratio, as the platform reports it: 411.43
    // wide, which is why the table holds a quotient and not a rounding.
    width: 1080 / 2.625,
    height: 2424 / 2.625,
    pixelRatio: 2.625,
    insetTop: 54.1,
    insetBottom: 24,
    landscape: DeviceInsets(left: 54.1, top: 52.2, bottom: 24),
    keyboard: 336.4,
    landscapeKeyboard: 261.3,
    keypadKeyboard: 292.2,
    landscapeKeypadKeyboard: 220.2,
  );

  /// The large phone — a Pixel 9 Pro XL's screen.
  static const androidBig = Device(
    'android-big',
    'Big phone',
    kind: DeviceKind.phone,
    platform: DevicePlatform.android,
    group: 'Android',
    width: 1344 / 3,
    height: 2992 / 3,
    pixelRatio: 3,
    insetTop: 53,
    insetBottom: 24,
    landscape: DeviceInsets(left: 53, top: 52, bottom: 24),
    keyboard: 336,
    landscapeKeyboard: 261,
    keypadKeyboard: 292,
    landscapeKeypadKeyboard: 220,
  );

  static const androidSmallTablet = Device(
    'android-small-tablet',
    'Small tablet',
    kind: DeviceKind.tablet,
    platform: DevicePlatform.android,
    group: 'Android',
    width: 800,
    height: 1280,
    pixelRatio: 2,
    insetTop: 24,
    // A tablet's gesture bar is taller than a phone's, and the same on its
    // side.
    insetBottom: 32,
    // The same in both orientations, unlike an iPad's, which grows when it
    // turns. Measured on a phone emulator reshaped to this panel: the Pixel
    // Tablet profile raises a taller one — 368, 320 for digits — and cannot be
    // read standing up, so which of the two a real tablet shows is open.
    keyboard: 320,
    landscapeKeyboard: 320,
    keypadKeyboard: 276,
    landscapeKeypadKeyboard: 276,
  );

  static const androidMediumTablet = Device(
    'android-medium-tablet',
    'Medium tablet',
    kind: DeviceKind.tablet,
    platform: DevicePlatform.android,
    group: 'Android',
    width: 1024,
    height: 1350,
    pixelRatio: 2,
    insetTop: 24,
    insetBottom: 32,
    keyboard: 320,
    landscapeKeyboard: 320,
    keypadKeyboard: 276,
    landscapeKeypadKeyboard: 276,
  );

  // ------------------------------------------------------------ Desktop
  //
  // **Windows, not machines.** A phone entry is a screen, because a phone app
  // gets the whole of one and the layout has to survive exactly that. A desktop
  // app gets a *window*, which the user drags to whatever size they like — so
  // the sizes worth checking are the ones a window is opened at, and the
  // machine's screen is not one of them. These used to be screens: `MacBook
  // Pro` was 1800×970, a size no application has ever opened at, and staging it
  // in a panel a third that wide made every preview a thumbnail of itself.
  //
  // Two axes, both worth having. The **size** is what the layout meets, and
  // three of them cover what a desktop layout actually has to do: hold together
  // small, sit at the size most people leave a window, and not fall apart wide.
  // The **platform** is what the widgets meet — scrollbars, fonts, adaptive
  // Cupertino/Material choices, `Theme.of(context).platform` — so Windows and
  // Linux are here as themselves rather than as sizes that happen to differ.

  static const smallWindow = Device(
    'window-small',
    'Small window',
    kind: DeviceKind.desktop,
    platform: DevicePlatform.macos,
    group: 'Desktop',
    width: 1024,
    height: 700,
    pixelRatio: 2,
  );

  static const window = Device(
    'window',
    'Standard window',
    kind: DeviceKind.desktop,
    platform: DevicePlatform.macos,
    group: 'Desktop',
    width: 1280,
    height: 800,
    pixelRatio: 2,
  );

  static const wideWindow = Device(
    'window-wide',
    'Wide window',
    kind: DeviceKind.desktop,
    platform: DevicePlatform.macos,
    group: 'Desktop',
    width: 1600,
    height: 900,
    pixelRatio: 2,
  );

  /// A Windows window, at the scale Windows actually ships at.
  ///
  /// 1.5 rather than the 2 this entry used to carry: 200% is a 4K laptop, and
  /// 150% is what a mainstream Windows machine is set to. The ratio is not
  /// decoration — it picks which asset resolution loads and how big the texture
  /// behind the preview is.
  static const windowsWindow = Device(
    'windows-window',
    'Windows window',
    kind: DeviceKind.desktop,
    platform: DevicePlatform.windows,
    group: 'Desktop',
    width: 1280,
    height: 800,
    pixelRatio: 1.5,
  );

  /// A Linux window, unscaled — which is still the common case there.
  static const linuxWindow = Device(
    'linux-window',
    'Linux window',
    kind: DeviceKind.desktop,
    platform: DevicePlatform.linux,
    group: 'Desktop',
    width: 1280,
    height: 800,
    pixelRatio: 1,
  );

  /// The screens these window sizes replaced.
  ///
  /// Kept because they are published: a project's `tool/flutterware.dart` names
  /// them, and a package that renames a constant out from under a consumer for
  /// a better name has spent their afternoon to save its own. [deviceById]
  /// resolves the old ids too, so an address or a config that names one goes on
  /// working — see [_renamed].
  @Deprecated(
    'Renamed: a desktop preview is a window, not a screen. Use '
    'Devices.wideWindow.',
  )
  static const macbookPro = wideWindow;

  @Deprecated(
    'Renamed: a desktop preview is a window, not a screen. Use '
    'Devices.wideWindow.',
  )
  static const wideMonitor = wideWindow;

  @Deprecated(
    'Renamed: a desktop preview is a window, not a screen. Use '
    'Devices.windowsWindow.',
  )
  static const windowsLaptop = windowsWindow;

  @Deprecated(
    'Renamed: a desktop preview is a window, not a screen. Use '
    'Devices.linuxWindow.',
  )
  static const linuxLaptop = linuxWindow;

  /// Dropped, and answered by the nearest phone that stayed.
  ///
  /// No simulator renders an app at a mini's own geometry — both mini device
  /// types fall back to a 320×568 compatibility screen on iOS 18 and 26 alike —
  /// so not one of its numbers could be measured, and a row nobody can check
  /// is a row that is quietly wrong.
  @Deprecated(
    'Dropped: none of its numbers could be measured. Use Devices.iphone13, '
    'the same notch fifteen points wider.',
  )
  static const iphone13Mini = iphone13;

  /// Dropped with the 16:9 phones it stood for, which have left the shelves.
  @Deprecated(
    'Dropped: a 16:9 phone is no longer a size class. Use '
    'Devices.androidTall.',
  )
  static const androidMedium = androidTall;

  /// The phone anything gets when it has not said which: a scenario whose
  /// folder names none, a person in a world, a new scene's artboard, the
  /// previews web page. The screen most people are holding — see [iphone16].
  static const defaultPhone = iphone16;

  /// Every offered device, in picker order.
  static const all = <Device>[
    iphoneSe,
    iphone13,
    iphone16,
    iphone16Pro,
    iphone12ProMax,
    iphone16Plus,
    iphone16ProMax,
    iPad,
    iPadPro13,
    androidSmall,
    androidTall,
    androidBig,
    androidSmallTablet,
    androidMediumTablet,
    smallWindow,
    window,
    wideWindow,
    windowsWindow,
    linuxWindow,
  ];
}

/// Every value `?device=` accepts, [fitDeviceId] first.
///
/// One list, so the picker, the address, `fw`'s usage line and MCP's schema
/// read the same thing.
List<String> get deviceIds => [fitDeviceId, for (var d in Devices.all) d.id];

/// The device [id] names, or null for [fitDeviceId] and for anything unknown —
/// which the caller must tell apart, because one is a choice and the other is a
/// mistake. See [isDeviceId].
///
/// Old ids resolve to what replaced them — see [_renamed]. A stored address is
/// the case that matters: `?device=macbook-pro` was written down by somebody
/// who wanted a desktop stage, and answering "no such device" to it would make
/// a rename look like a broken link.
Device? deviceById(String id) {
  var wanted = _renamed[id] ?? id;
  return Devices.all.where((d) => d.id == wanted).firstOrNull;
}

/// Ids this build no longer offers, and what answers them now: the desktop
/// entries from when they were screens rather than windows, and the two phones
/// the table dropped.
///
/// Deliberately a **map to the current ids** rather than more rows in
/// [Devices.all]: an alias that appeared in the picker would be a second way to
/// ask for the same stage, and the picker is the one place this change is meant
/// to be visible.
const _renamed = {
  'macbook-pro': 'window-wide',
  'wide-monitor': 'window-wide',
  'windows-laptop': 'windows-window',
  'linux-laptop': 'linux-window',
  'iphone-13-mini': 'iphone-13',
  'android-medium': 'android-tall',
};

/// Whether [id] is a value this build accepts at all.
bool isDeviceId(String id) => id == fitDeviceId || deviceById(id) != null;

/// Every value `?orientation=` accepts, portrait first.
///
/// One list, for the same reason [deviceIds] is one: the picker, the address,
/// `fw`'s usage line and MCP's schema all read it.
List<String> get orientationIds => [
  for (var orientation in ScreenOrientation.values) orientation.name,
];

/// The orientation [id] names, or null for anything unknown.
ScreenOrientation? orientationById(String id) =>
    ScreenOrientation.values.where((o) => o.name == id).firstOrNull;

/// Whether [id] is an orientation this build accepts.
bool isOrientationId(String id) => orientationById(id) != null;

/// Every value `?keyboard=` accepts, the default first.
List<String> get keyboardModeIds => [
  for (var mode in KeyboardMode.values) mode.name,
];

/// The keyboard mode [id] names, or null for anything unknown.
KeyboardMode? keyboardModeById(String id) =>
    KeyboardMode.values.where((m) => m.name == id).firstOrNull;

/// Whether [id] is a keyboard mode this build accepts.
bool isKeyboardModeId(String id) => keyboardModeById(id) != null;

/// A screen to render a preview on, as it travels from the host to a harness.
///
/// **The wire form of the host's `CaptureViewport`, and the same class at both
/// ends** — the host builds one and encodes it, the harness decodes one and
/// stages it. Two classes with a JSON contract between them would be two
/// descriptions of one screen, and this repository has paid for that shape
/// more than once; one class cannot drift from itself.
///
/// It carries numbers rather than a device id on purpose. A viewport is not
/// always a device: `--width`/`--height` override one into a size no phone
/// has, and the panel's own rectangle is no device at all. The embedder guest
/// is told the same numbers over its resize message, so what the two backends
/// are staged with is one vocabulary.
class StagedViewport {
  const StagedViewport({
    required this.width,
    required this.height,
    this.pixelRatio = 1,
    this.insetTop = 0,
    this.insetRight = 0,
    this.insetBottom = 0,
    this.insetLeft = 0,
    this.platform,
    this.keyboard = 0,
    this.keyboardUp = false,
  });

  factory StagedViewport.fromJson(Map<String, Object?> json) => StagedViewport(
    width: (json['width']! as num).toDouble(),
    height: (json['height']! as num).toDouble(),
    pixelRatio: (json['pixelRatio'] as num?)?.toDouble() ?? 1,
    insetTop: (json['insetTop'] as num?)?.toDouble() ?? 0,
    insetRight: (json['insetRight'] as num?)?.toDouble() ?? 0,
    insetBottom: (json['insetBottom'] as num?)?.toDouble() ?? 0,
    insetLeft: (json['insetLeft'] as num?)?.toDouble() ?? 0,
    platform: switch (json['platform']) {
      String name => DevicePlatform.values.firstWhere(
        (platform) => platform.name == name,
      ),
      _ => null,
    },
    keyboard: (json['keyboard'] as num?)?.toDouble() ?? 0,
    keyboardUp: json['keyboardUp'] == true,
  );

  /// **Physical** pixels — the size of the image that comes out, which is what
  /// the host's `CaptureViewport` records and what an address names.
  final double width;
  final double height;

  final double pixelRatio;

  /// The notch, the island, the gesture bar, in **logical** pixels — the space
  /// `EdgeInsets` and `MediaQuery.padding` are written in.
  final double insetTop;
  final double insetRight;
  final double insetBottom;
  final double insetLeft;

  /// What the preview is staged *as*. Null is a rectangle rather than a
  /// device, which is the panel's own surface and what an entry that named no
  /// device gets: no platform override, so `defaultTargetPlatform` stays
  /// whatever the harness is really running on.
  final DevicePlatform? platform;

  /// How tall this screen's software keyboard is once it is up, logical.
  final double keyboard;

  /// Whether to hold one up with nothing focused — `KeyboardMode.up`. `auto`
  /// and `down` both arrive as false: a preview that focuses a field raises
  /// its own, and that is the framework's business rather than the stage's.
  final bool keyboardUp;

  /// The screen in **logical** pixels — what the layout is written against.
  ///
  /// Divided here rather than carried, so the two numbers cannot disagree
  /// about a screen: the physical size is what an address names and what a
  /// picture comes out at, and this is the same fact read the other way.
  double get logicalWidth => width / pixelRatio;
  double get logicalHeight => height / pixelRatio;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    if (pixelRatio != 1) 'pixelRatio': pixelRatio,
    if (insetTop != 0) 'insetTop': insetTop,
    if (insetRight != 0) 'insetRight': insetRight,
    if (insetBottom != 0) 'insetBottom': insetBottom,
    if (insetLeft != 0) 'insetLeft': insetLeft,
    if (platform != null) 'platform': platform!.name,
    if (keyboard != 0) 'keyboard': keyboard,
    if (keyboardUp) 'keyboardUp': true,
  };
}
