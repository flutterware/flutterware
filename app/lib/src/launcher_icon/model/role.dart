/// The vocabulary a launcher icon is described in, in **plain Dart**.
///
/// Deliberately free of Flutter, for the reason `splash/model/surface.dart`
/// gives at its own top: `fw` and MCP link this to validate `--role` and to
/// describe a file in words, and they are compiled with `dart compile exe`,
/// where `package:flutter` cannot load at all. The panel maps [IconMask] onto a
/// `Path` at the one place pixels are drawn.
///
/// Everything here describes what an **operating system** does with a file that
/// already exists. Nothing here knows about `icons_launcher`,
/// `flutter_launcher_icons`, or any other generator — that is the whole point
/// of the plugin: it reads the same on a project that generated its icons, a
/// project that drew them by hand, and a project that let Xcode do it.
library;

/// Which platform's rules apply.
enum IconPlatform {
  android('Android'),
  ios('iOS'),
  macos('macOS'),
  web('Web'),
  windows('Windows'),
  linux('Linux');

  const IconPlatform(this.label);

  final String label;

  static IconPlatform? byName(String name) {
    for (var value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// What the OS does to the pixels before showing them.
///
/// Only the transformations severe enough that the file on disk stops
/// predicting what a user sees. Everything else is drawn as authored.
///
/// Android's themed icon and iOS's tinted icon are **not the same rule**, and
/// modelling them as one gets the themed icon visibly wrong. Android takes the
/// monochrome layer's *alpha* and fills it flat, so the source's own colours
/// contribute nothing but a silhouette. iOS maps *luminance* onto a tint, so a
/// light and a dark region of the source stay distinguishable. One is a stencil
/// and the other is a duotone.
enum IconTreatment {
  /// Drawn as authored.
  asAuthored,

  /// Colour is discarded entirely; the alpha channel is filled white.
  ///
  /// Android's status-bar rule since API 21. The cheapest rule to apply and the
  /// most valuable to show: a full-colour logo dropped in as a notification
  /// icon becomes a white blob, and nothing in the toolchain warns about it.
  whiteSilhouette,

  /// The alpha channel filled with a colour the system picks, on a background
  /// the system picks.
  ///
  /// Android themed icons, API 33+. Structurally the same stencil as
  /// [whiteSilhouette] — everything but the shape is thrown away — which is
  /// exactly why a monochrome layer authored as a colourful logo comes out as
  /// a flat blob rather than a tinted version of itself.
  alphaTinted,

  /// Desaturated, then tinted by luminance.
  ///
  /// iOS 18's tinted appearance. Unlike [alphaTinted] the source's light and
  /// dark regions survive as light and dark, which is why Apple asks for a
  /// greyscale asset: a colour source is flattened by luminance, and two
  /// different hues of the same brightness become the same tone.
  luminanceTinted,
}

/// The shape the OS clips an icon to.
enum IconMask {
  none,

  /// Android adaptive icons. **The shape is chosen by the launcher, not the
  /// OS** — Pixel, One UI and the various OEM launchers each pick their own, so
  /// there is no single correct answer to draw. [AdaptiveMask] enumerates the
  /// common ones and the safe zone is the only invariant.
  adaptive,

  /// The iOS/iPadOS rounded rect, which is a continuous-curvature squircle
  /// rather than a circular-arc rounded rectangle. Approximating it with a
  /// plain `RRect` is visibly wrong at large sizes.
  iosSquircle,

  /// macOS **does not clip** a classic asset-catalog icon.
  ///
  /// The rounded rectangle and its shadow are painted into the PNG by whoever
  /// drew it; the system composites the artwork as authored. So this is a
  /// convention to draw *against*, not a mask to apply — clipping to it would
  /// be wrong in both directions, shrinking an icon that already has its own
  /// margin and implying macOS will round off one that does not.
  macosGuide,

  /// A PWA maskable icon: the user agent MAY clip to any shape, so only the
  /// safe zone is guaranteed. See [maskableSafeRadiusFraction].
  maskableCircle;

  /// Whether pixels outside the safe zone are actually **removed**.
  ///
  /// The distinction the overlay depends on: a region that gets cut is shown
  /// dimmed out, and a region that merely breaks a convention gets an outline.
  /// Drawing the second like the first implies the OS destroys artwork it
  /// leaves alone.
  bool get clips => switch (this) {
    IconMask.none || IconMask.macosGuide => false,
    IconMask.adaptive ||
    IconMask.iosSquircle ||
    IconMask.maskableCircle => true,
  };
}

/// The adaptive-icon shapes common launchers apply.
///
/// An axis rather than a single value precisely because the launcher picks:
/// showing one would imply a certainty that does not exist.
enum AdaptiveMask {
  squircle('Squircle'),
  circle('Circle'),
  roundedSquare('Rounded square'),
  teardrop('Teardrop');

  const AdaptiveMask(this.label);

  final String label;

  static AdaptiveMask? byName(String name) {
    for (var value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// The fraction of an adaptive icon's canvas that is guaranteed visible.
///
/// Android's layers are 108×108dp with the inner 72×72dp always visible; the
/// outer 18dp on each edge is reserved for the mask and for parallax. 72/108 is
/// two thirds.
///
/// The splash plugin encodes the same fact as `android12MaskFraction`. Stated
/// again here rather than imported: one plugin's model reaching into another's
/// couples two things that only happen to agree about Android, and would make
/// either one unsafe to change.
const adaptiveSafeFraction = 72 / 108;

/// The radius of a maskable web icon's safe zone, as a fraction of the smaller
/// of width and height.
///
/// The Web Application Manifest spec defines it as "a circle with center point
/// in the center of the icon and with a radius of 2/5 (40%) of the icon size",
/// and says a user agent may make everything outside it transparent.
const maskableSafeRadiusFraction = 2 / 5;

/// The fraction of a macOS icon canvas the artwork conventionally occupies.
///
/// Apple's 1024px template centres the icon body in 824px, leaving the rest as
/// margin and shadow room. Nothing enforces it — a full-bleed icon builds and
/// ships — it just reads as oversized beside every other icon in the Dock,
/// which is not visible in a file browser.
const macosArtworkFraction = 824 / 1024;

/// One thing an OS shows, or refuses to.
///
/// The unit is **a role, not a file**: five densities of `ic_launcher.png` are
/// one thing seen at five sizes, and splitting them into five rows would bury
/// the fact that the monochrome layer is missing entirely.
enum IconRole {
  androidLegacy(
    'android.legacy',
    'Launcher icon',
    IconPlatform.android,
    description:
        'The bitmap launcher icon. What every device below API 26 shows, and '
        'what API 26+ falls back to when no adaptive icon is wired.',
  ),
  androidAdaptiveForeground(
    'android.adaptive-foreground',
    'Adaptive foreground',
    IconPlatform.android,
    mask: IconMask.adaptive,
    safeFraction: adaptiveSafeFraction,
    since: 'Android 8 (API 26)',
    description:
        'The upper layer of an adaptive icon. Only the inner two thirds '
        'survives the launcher mask.',
  ),
  androidAdaptiveBackground(
    'android.adaptive-background',
    'Adaptive background',
    IconPlatform.android,
    mask: IconMask.adaptive,
    safeFraction: adaptiveSafeFraction,
    since: 'Android 8 (API 26)',
    description:
        'The lower layer of an adaptive icon — an image, or a colour named in '
        'colors.xml.',
  ),
  androidRound(
    'android.round',
    'Round icon',
    IconPlatform.android,
    description:
        'android:roundIcon. Predates adaptive icons and is ignored by most '
        'modern launchers, but some OEM launchers still ask for it.',
  ),
  androidMonochrome(
    'android.monochrome',
    'Themed icon',
    IconPlatform.android,
    treatment: IconTreatment.alphaTinted,
    mask: IconMask.adaptive,
    safeFraction: adaptiveSafeFraction,
    since: 'Android 13 (API 33)',
    description:
        'The monochrome layer. Android keeps its shape and throws away '
        'everything else, filling it with a colour taken from the wallpaper. '
        'Shown only when the user turns themed icons on, and only by launchers '
        'that implement them.',
  ),
  androidNotification(
    'android.notification',
    'Notification icon',
    IconPlatform.android,
    treatment: IconTreatment.whiteSilhouette,
    since: 'Android 5 (API 21)',
    description:
        'Drawn in the status bar with all colour discarded — only the alpha '
        'channel survives, filled white.',
  ),
  androidPlayStore(
    'android.play-store',
    'Play Store icon',
    IconPlatform.android,
    description:
        'The 512px listing icon. Never shown on device; uploaded with the '
        'release.',
  ),
  iosApp(
    'ios.app',
    'App icon',
    IconPlatform.ios,
    mask: IconMask.iosSquircle,
    description:
        'The iOS/iPadOS icon. Must not carry an alpha channel — App Store '
        'Connect rejects one that does.',
  ),
  iosDark(
    'ios.dark',
    'Dark icon',
    IconPlatform.ios,
    mask: IconMask.iosSquircle,
    since: 'iOS 18',
    description: 'Shown when the home screen is in dark mode.',
  ),
  iosTinted(
    'ios.tinted',
    'Tinted icon',
    IconPlatform.ios,
    treatment: IconTreatment.luminanceTinted,
    mask: IconMask.iosSquircle,
    since: 'iOS 18',
    description:
        'Desaturated and tinted by the system. Meant to be authored greyscale; '
        'a colour source is flattened, not preserved.',
  ),
  macosApp(
    'macos.app',
    'App icon',
    IconPlatform.macos,
    mask: IconMask.macosGuide,
    safeFraction: macosArtworkFraction,
    description:
        'The macOS icon. Drawn exactly as authored — the rounded corners and '
        'shadow are painted into the artwork, not applied by the system. '
        'Convention insets it, and a full-bleed square reads as oversized in '
        'the Dock.',
  ),
  webIcon(
    'web.icon',
    'Web icon',
    IconPlatform.web,
    description: 'The PWA icons referenced from the web manifest.',
  ),
  webMaskable(
    'web.maskable',
    'Maskable icon',
    IconPlatform.web,
    mask: IconMask.maskableCircle,
    safeFraction: maskableSafeRadiusFraction * 2,
    description:
        'Installed-PWA icon. The user agent may clip it to any shape; only the '
        'central circle of 2/5 radius is guaranteed.',
  ),
  webFavicon(
    'web.favicon',
    'Favicon',
    IconPlatform.web,
    description:
        'The browser tab icon, shown at 16px more often than anything else. '
        'Detail that reads at 512 turns to mush there.',
  ),
  windowsIco(
    'windows.ico',
    'Application icon',
    IconPlatform.windows,
    description:
        'A multi-frame .ico. Windows picks a frame by context, and downscales '
        'badly when the one it wants is missing.',
  ),
  linuxSnap(
    'linux.snap',
    'Snap icon',
    IconPlatform.linux,
    description:
        'The icon a snap package ships. A plain (non-snap) Linux build does '
        'not use it.',
  );

  const IconRole(
    this.id,
    this.label,
    this.platform, {
    required this.description,
    this.treatment = IconTreatment.asAuthored,
    this.mask = IconMask.none,
    this.safeFraction,
    this.since,
  });

  /// What goes in an address — `?role=android.adaptive-foreground`.
  ///
  /// Explicit rather than derived from [name], for the reason `Device.id` gives:
  /// an address is written by hand, pasted into a terminal and produced by an
  /// agent, so its vocabulary has to be stable and guessable. Renaming the enum
  /// constant must not break a saved link.
  final String id;

  final String label;
  final IconPlatform platform;
  final String description;
  final IconTreatment treatment;
  final IconMask mask;

  /// The fraction of the canvas guaranteed to survive [mask], or null when
  /// nothing is clipped.
  final double? safeFraction;

  /// The OS version this role begins to mean anything at, for a caption. Null
  /// when it has always existed.
  final String? since;

  static IconRole? byId(String id) {
    for (var value in values) {
      if (value.id == id) return value;
    }
    return null;
  }

  static List<IconRole> forPlatform(IconPlatform platform) => [
    for (var value in values)
      if (value.platform == platform) value,
  ];
}
