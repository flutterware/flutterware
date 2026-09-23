/// The icon where it actually lives.
///
/// The tile grid answers "what have I got". None of it answers the questions
/// that decide whether an icon is any good: is it too heavy next to its
/// neighbours, does it vanish against a dark wallpaper, does it still read at
/// the size a browser tab gives it. Those are all *relative* judgements, and a
/// thumbnail on a checkerboard has nothing to be relative to.
///
/// Every serious icon tool arrived at the same answer — draw the thing on a
/// home screen, with neighbours, at the right scale. This is that, built from
/// the device catalog and mask geometry the plugin already owns.
///
/// A **View**: plain data and an `ImageProvider` in, pixels out. It never
/// touches the filesystem, so the catalog can exercise every surface with
/// synthesised bytes.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/design/design.dart';
import '../../ui/theme.dart';
import '../model/role.dart';
import 'icon_render.dart';

/// Where a role is shown.
///
/// Derived from the role rather than chosen by a caller: a notification icon
/// has exactly one honest context, and offering to draw it on a home screen
/// would be offering a lie.
enum IconSurface {
  androidHome,
  iosHome,
  macosDock,
  browserTab,
  notificationShade,

  /// Nothing on a device shows it — the Play Store listing, a snap package.
  none;

  static IconSurface forRole(IconRole role) => switch (role) {
    IconRole.androidLegacy ||
    IconRole.androidAdaptiveForeground ||
    IconRole.androidAdaptiveBackground ||
    IconRole.androidRound ||
    IconRole.androidMonochrome => IconSurface.androidHome,
    IconRole.androidNotification => IconSurface.notificationShade,
    IconRole.iosApp ||
    IconRole.iosDark ||
    IconRole.iosTinted => IconSurface.iosHome,
    IconRole.macosApp => IconSurface.macosDock,
    IconRole.webIcon ||
    IconRole.webMaskable ||
    IconRole.webFavicon => IconSurface.browserTab,
    // A Windows .ico is shown in the taskbar and Explorer, both of which would
    // need their own chrome to be honest about; until one exists, its frames at
    // true size say more than a wrong backdrop would.
    IconRole.androidPlayStore ||
    IconRole.linuxSnap ||
    IconRole.windowsIco => IconSurface.none,
  };

  String get label => switch (this) {
    IconSurface.androidHome => 'On the launcher',
    IconSurface.iosHome => 'On the home screen',
    IconSurface.macosDock => 'In the Dock',
    IconSurface.browserTab => 'In a browser tab',
    IconSurface.notificationShade => 'In the status bar',
    IconSurface.none => 'Not shown on a device',
  };
}

/// The icon in place, among neighbours.
class IconSitu extends StatelessWidget {
  const IconSitu({
    super.key,
    required this.role,
    required this.image,
    this.backgroundImage,
    this.backgroundColor,
    this.adaptiveMask = AdaptiveMask.squircle,
    this.showSafeZone = false,
    this.dark = false,
    this.label = 'Your app',
  });

  final IconRole role;
  final ImageProvider image;
  final ImageProvider? backgroundImage;
  final Color? backgroundColor;
  final AdaptiveMask adaptiveMask;
  final bool showSafeZone;

  /// Wallpapers are dark more often than not, and a light-on-light icon
  /// disappearing is the failure this surface exists to catch.
  final bool dark;

  final String label;

  @override
  Widget build(BuildContext context) {
    return switch (IconSurface.forRole(role)) {
      IconSurface.androidHome || IconSurface.iosHome => _HomeScreen(
        role: role,
        image: image,
        backgroundImage: backgroundImage,
        backgroundColor: backgroundColor,
        adaptiveMask: adaptiveMask,
        showSafeZone: showSafeZone,
        dark: dark,
        label: label,
      ),
      IconSurface.macosDock => _Dock(
        role: role,
        image: image,
        showSafeZone: showSafeZone,
      ),
      IconSurface.browserTab => _BrowserTabs(
        role: role,
        image: image,
        showSafeZone: showSafeZone,
        label: label,
      ),
      IconSurface.notificationShade => _StatusBar(role: role, image: image),
      IconSurface.none => const SizedBox.shrink(),
    };
  }
}

// ---- Home screen -----------------------------------------------------------

/// A launcher page: wallpaper, a status bar, and a grid the subject sits in.
class _HomeScreen extends StatelessWidget {
  const _HomeScreen({
    required this.role,
    required this.image,
    required this.adaptiveMask,
    required this.showSafeZone,
    required this.dark,
    required this.label,
    this.backgroundImage,
    this.backgroundColor,
  });

  final IconRole role;
  final ImageProvider image;
  final ImageProvider? backgroundImage;
  final Color? backgroundColor;
  final AdaptiveMask adaptiveMask;
  final bool showSafeZone;
  final bool dark;
  final String label;

  static const _cell = 52.0;

  @override
  Widget build(BuildContext context) {
    var ios = role.platform == IconPlatform.ios;

    return _Wallpaper(
      dark: dark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusStrip(dark: dark),
            const Gap(FwSpacing.xxl),
            // Two rows of neighbours with the subject third along, which is
            // where the eye lands and where a too-heavy icon shows itself.
            for (var row = 0; row < 3; row++) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var column = 0; column < 4; column++)
                    row == 0 && column == 2
                        ? _Slot(
                            label: label,
                            dark: dark,
                            child: IconRender(
                              image: image,
                              role: role,
                              size: _cell,
                              adaptiveMask: adaptiveMask,
                              showSafeZone: showSafeZone,
                              inspector: false,
                              backgroundImage: backgroundImage,
                              backgroundColor: backgroundColor,
                            ),
                          )
                        : _Slot(
                            label: _neighbourNames[(row * 4 + column) % 8],
                            dark: dark,
                            child: _Neighbour(
                              seed: row * 4 + column,
                              size: _cell,
                              rounded: ios,
                              adaptiveMask: adaptiveMask,
                            ),
                          ),
                ],
              ),
              const Gap(FwSpacing.xl),
            ],
          ],
        ),
      ),
    );
  }
}

const _neighbourNames = [
  'Mail',
  'Photos',
  'Notes',
  'Maps',
  'Music',
  'Files',
  'Clock',
  'Chat',
];

/// One home-screen position: the icon and its caption.
class _Slot extends StatelessWidget {
  const _Slot({required this.child, required this.label, required this.dark});

  final Widget child;
  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const Gap(FwSpacing.sm),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 8,
              height: 1.1,
              color: dark ? Colors.white : const Color(0xFF11181C),
              shadows: dark
                  ? const [Shadow(blurRadius: 3, color: Color(0x66000000))]
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A stand-in for a neighbouring app.
///
/// Painted rather than bundled: an asset would be one more thing to ship and
/// would date, and the only job here is to give the eye something to judge
/// weight and size against.
class _Neighbour extends StatelessWidget {
  const _Neighbour({
    required this.seed,
    required this.size,
    required this.rounded,
    required this.adaptiveMask,
  });

  final int seed;
  final double size;

  /// iOS shapes every icon the same way; a launcher applies its own mask, so
  /// the neighbours have to wear the same one as the subject or the comparison
  /// is rigged.
  final bool rounded;
  final AdaptiveMask adaptiveMask;

  static const _palette = [
    [Color(0xFF4C8DFF), Color(0xFF2B5FD9)],
    [Color(0xFFFF9F45), Color(0xFFE8722C)],
    [Color(0xFF56C596), Color(0xFF2E9E75)],
    [Color(0xFFB07CFF), Color(0xFF7C4DD1)],
    [Color(0xFFFF6B8A), Color(0xFFD93F65)],
    [Color(0xFF4ECDC4), Color(0xFF2AA39B)],
    [Color(0xFFFFD166), Color(0xFFE0A32E)],
    [Color(0xFF8D99AE), Color(0xFF5C6779)],
  ];

  @override
  Widget build(BuildContext context) {
    var colors = _palette[seed % _palette.length];
    var body = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          _glyphs[seed % _glyphs.length],
          size: size * 0.44,
          color: Colors.white.withValues(alpha: 0.92),
        ),
      ),
    );

    var path = rounded
        ? squirclePath(Offset.zero & Size(size, size), 5)
        : maskPath(
            IconMask.adaptive,
            Size(size, size),
            adaptive: adaptiveMask,
          )!;

    return SizedBox(
      width: size,
      height: size,
      child: ClipPath(clipper: _ShapeClipper(path), child: body),
    );
  }
}

const _glyphs = [
  Icons.mail_outline,
  Icons.photo_outlined,
  Icons.sticky_note_2_outlined,
  Icons.map_outlined,
  Icons.music_note_outlined,
  Icons.folder_outlined,
  Icons.schedule_outlined,
  Icons.chat_bubble_outline,
];

class _ShapeClipper extends CustomClipper<Path> {
  const _ShapeClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_ShapeClipper old) => old.path != path;
}

/// Something for the icons to sit on that is not a flat panel colour.
class _Wallpaper extends StatelessWidget {
  const _Wallpaper({required this.dark, required this.child});

  final bool dark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF1B2430), Color(0xFF2E1F3D), Color(0xFF10161E)]
              : const [Color(0xFFCFE0F5), Color(0xFFE8DCF3), Color(0xFFF6EFE6)],
        ),
      ),
      child: child,
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    var ink = dark ? Colors.white : const Color(0xFF11181C);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          '9:41',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
        Row(
          children: [
            Icon(Icons.signal_cellular_alt, size: 9, color: ink),
            const Gap(FwSpacing.xs),
            Icon(Icons.wifi, size: 9, color: ink),
            const Gap(FwSpacing.xs),
            Icon(Icons.battery_full, size: 9, color: ink),
          ],
        ),
      ],
    );
  }
}

// ---- macOS Dock ------------------------------------------------------------

/// The Dock, which is where a macOS icon's size is actually judged.
///
/// Neighbours matter more here than anywhere: macOS applies no mask, so an icon
/// that fills its canvas is not clipped — it just stands a head taller than
/// everything beside it, and there is no way to see that alone.
class _Dock extends StatelessWidget {
  const _Dock({
    required this.role,
    required this.image,
    required this.showSafeZone,
  });

  final IconRole role;
  final ImageProvider image;
  final bool showSafeZone;

  static const _size = 54.0;

  @override
  Widget build(BuildContext context) {
    return _Wallpaper(
      dark: true,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // **The strip is scaled to the stage, not sized to it.** Four
            // 54-pixel icons, their gaps, the padding and the hairline come to
            // 266, and the stage this is drawn on is 300 wide with 24 of
            // padding each side — 252. It overflowed by exactly 14, in both
            // previews that show a Dock, and had done since the sizes were
            // chosen.
            //
            // Scaling rather than shrinking a number, because a stage is
            // whatever width it is given: `situAspectRatio` exists precisely so
            // each surface can be drawn at its own shape and size, and a strip
            // that only fits one of them is one token change from overflowing
            // again. `scaleDown` leaves it alone wherever it already fits.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: FwSpacing.lg,
                  vertical: FwSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _DockNeighbour(seed: 0, size: _size),
                    const Gap(FwSpacing.md),
                    IconRender(
                      image: image,
                      role: role,
                      size: _size,
                      showSafeZone: showSafeZone,
                      inspector: false,
                    ),
                    const Gap(FwSpacing.md),
                    _DockNeighbour(seed: 3, size: _size),
                    const Gap(FwSpacing.md),
                    _DockNeighbour(seed: 5, size: _size),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A Dock neighbour, inset the way the macOS template asks for — so the
/// comparison is against icons that follow the convention.
class _DockNeighbour extends StatelessWidget {
  const _DockNeighbour({required this.seed, required this.size});

  final int seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    var inset = size * (1 - macosArtworkFraction) / 2;
    return SizedBox(
      width: size,
      height: size,
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: _Neighbour(
          seed: seed,
          size: size - inset * 2,
          rounded: true,
          adaptiveMask: AdaptiveMask.squircle,
        ),
      ),
    );
  }
}

// ---- Browser ---------------------------------------------------------------

/// A tab strip, which is the only place a favicon is ever seen.
class _BrowserTabs extends StatelessWidget {
  const _BrowserTabs({
    required this.role,
    required this.image,
    required this.showSafeZone,
    required this.label,
  });

  final IconRole role;
  final ImageProvider image;
  final bool showSafeZone;
  final String label;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // A maskable icon is never shown in a tab — it is the installed-app icon,
    // so it gets the home-screen treatment instead.
    var favicon = role == IconRole.webFavicon;

    return Container(
      color: colors.panel2,
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.lg,
        FwSpacing.lg,
        FwSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Row(
            children: [
              const Expanded(
                child: _Tab(
                  label: 'Search',
                  active: false,
                  icon: _Dot(color: Color(0xFF8D99AE)),
                ),
              ),
              const Gap(FwSpacing.xs),
              Expanded(
                child: _Tab(
                  label: label,
                  active: true,
                  icon: SizedBox(
                    width: 16,
                    height: 16,
                    // 16px, because that is what a tab gives it — the whole
                    // reason a favicon that reads at 512 can be unusable.
                    child: IconRender(
                      image: image,
                      role: role,
                      size: favicon ? 16 : 20,
                      showSafeZone: showSafeZone,
                      inspector: false,
                    ),
                  ),
                ),
              ),
              const Gap(FwSpacing.xs),
              const Expanded(
                child: _Tab(
                  label: 'Docs',
                  active: false,
                  icon: _Dot(color: Color(0xFF56C596)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active, required this.icon});

  final String label;
  final bool active;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.md,
      ),
      decoration: BoxDecoration(
        color: active ? colors.bg : colors.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: Row(
        children: [
          icon,
          const Gap(FwSpacing.md),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.micro.copyWith(
                color: active ? colors.ink : colors.mut,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

// ---- Status bar ------------------------------------------------------------

/// The status bar and a notification row.
///
/// The only place a notification icon is ever seen, and the only backdrop on
/// which "colour is discarded, the alpha is filled white" reads as the drastic
/// rule it is.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.role, required this.image});

  final IconRole role;
  final ImageProvider image;

  @override
  Widget build(BuildContext context) {
    return _Wallpaper(
      dark: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: const Color(0xFF10141A),
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.lg,
              vertical: FwSpacing.md,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: IconRender(
                    image: image,
                    role: role,
                    size: 14,
                    inspector: false,
                  ),
                ),
                const Gap(FwSpacing.md),
                const _Dot(color: Color(0x55FFFFFF)),
                const Spacer(),
                const Text(
                  '9:41',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(FwSpacing.lg),
              child: Container(
                padding: const EdgeInsets.all(FwSpacing.lg),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: IconRender(
                        image: image,
                        role: role,
                        size: 18,
                        inspector: false,
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your app',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            'A notification, so the silhouette has somewhere '
                            'to be seen.',
                            style: TextStyle(
                              fontSize: 9,
                              color: Color(0xCCFFFFFF),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The aspect a surface wants to be drawn at.
///
/// Phones are tall, a Dock is wide, a tab strip is a band. Letting each say so
/// keeps the stage from forcing one shape on all of them.
double situAspectRatio(IconSurface surface) => switch (surface) {
  IconSurface.androidHome || IconSurface.iosHome => 0.95,
  IconSurface.notificationShade => 0.95,
  IconSurface.macosDock => 1.5,
  IconSurface.browserTab => 2.4,
  IconSurface.none => 1,
};

/// Clamped so a caller cannot ask for a stage so small the neighbours stop
/// being legible, which is what they are there for.
double situWidthFor(double available) =>
    math.max(260, math.min(available, 380));
