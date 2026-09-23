import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/launcher_icon/model/role.dart';
import 'package:flutterware_app/src/launcher_icon/model/scan.dart';
import 'package:flutterware_app/src/launcher_icon/ui/flavor_chips.dart';
import 'package:flutterware_app/src/launcher_icon/ui/plate.dart';
import 'package:flutterware_app/src/launcher_icon/ui/situ.dart';
import 'package:flutterware_app/src/ui/design/design.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:image/image.dart' as img;

import 'command_palette.dart' show wrapInAppTheme;

/// Two directions for the launcher-icon panel, side by side.
///
/// Nothing here touches the filesystem. Every icon is synthesised in
/// memory, which is what lets these views be looked at without finding a
/// project that happens to have a monochrome layer — the exact gap that meant
/// the plugin's marquee surfaces had never been seen rendered by anyone.
/// `asset_inspector.dart` makes the same bargain for the same reason.
///
/// Stacked rather than behind a picker, per the house rule: a surface that
/// collapses or a caption that overflows shows up on opening the demo.

@Preview(name: 'In situ', group: 'Launcher icon', wrapper: wrapInAppTheme)
Widget launcherIconSitu() => const _Situ();

@Preview(name: 'Flat plates', group: 'Launcher icon', wrapper: wrapInAppTheme)
Widget launcherIconPlates() => const _Plates();

@Preview(name: 'Side by side', group: 'Launcher icon', wrapper: wrapInAppTheme)
Widget launcherIconComparison() => const _Comparison();

@Preview(name: 'Flavors', group: 'Launcher icon', wrapper: wrapInAppTheme)
Widget launcherIconFlavors() => const _Flavors();

// ---- The ambitious direction ----------------------------------------------

/// Every surface, with the icon among neighbours.
class _Situ extends StatelessWidget {
  const _Situ();

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'In situ — device chrome and neighbours',
      subtitle:
          'The icon where it is actually seen. Neighbours are the point: size '
          'and weight are relative judgements, and a thumbnail has nothing to '
          'be relative to.',
      child: Wrap(
        spacing: FwSpacing.xxl,
        runSpacing: FwSpacing.xxl,
        children: [
          _Stage(
            caption: 'Android · adaptive foreground, squircle',
            role: IconRole.androidAdaptiveForeground,
            image: _fullBleed,
            backgroundColor: const Color(0xFF0B57D0),
          ),
          _Stage(
            caption: 'Android · same icon, circle mask, safe zone on',
            role: IconRole.androidAdaptiveForeground,
            image: _fullBleed,
            backgroundColor: const Color(0xFF0B57D0),
            adaptiveMask: AdaptiveMask.circle,
            showSafeZone: true,
          ),
          _Stage(
            caption: 'Android · themed icon, on a light wallpaper',
            role: IconRole.androidMonochrome,
            image: _silhouette,
            dark: false,
          ),
          _Stage(
            caption: 'iOS · app icon',
            role: IconRole.iosApp,
            image: _withMargin,
          ),
          _Stage(
            caption:
                'macOS · full-bleed, beside icons that follow the template',
            role: IconRole.macosApp,
            image: _fullBleed,
            showSafeZone: true,
          ),
          _Stage(
            caption: 'macOS · the same artwork inset conventionally',
            role: IconRole.macosApp,
            image: _withMargin,
            showSafeZone: true,
          ),
          _Stage(
            caption: 'Web · favicon at the 16px a tab gives it',
            role: IconRole.webFavicon,
            image: _detailed,
          ),
          _Stage(
            caption: 'Android · notification, colour discarded',
            role: IconRole.androidNotification,
            image: _detailed,
          ),
        ],
      ),
    );
  }
}

/// One stage, captioned, at the aspect its surface asks for.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.caption,
    required this.role,
    required this.image,
    this.backgroundColor,
    this.adaptiveMask = AdaptiveMask.squircle,
    this.showSafeZone = false,
    this.dark = true,
  });

  final String caption;
  final IconRole role;
  final Uint8List image;
  final Color? backgroundColor;
  final AdaptiveMask adaptiveMask;
  final bool showSafeZone;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    var surface = IconSurface.forRole(role);
    const width = 300.0;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(context.radii.radiusLarge),
            child: SizedBox(
              width: width,
              height: width / situAspectRatio(surface),
              child: IconSitu(
                role: role,
                image: MemoryImage(image),
                backgroundColor: backgroundColor,
                adaptiveMask: adaptiveMask,
                showSafeZone: showSafeZone,
                dark: dark,
              ),
            ),
          ),
          const Gap(FwSpacing.md),
          Text(
            caption,
            style: context.type.caption.copyWith(color: context.colors.mut),
          ),
        ],
      ),
    );
  }
}

// ---- The modest direction --------------------------------------------------

class _Plates extends StatelessWidget {
  const _Plates();

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'Flat plates — no chrome',
      subtitle:
          'The same facts without drawing a phone. One card per role, wide '
          'enough that the comparison sits in a row.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: FwSpacing.xl,
        children: [
          IconPlate(
            role: IconRole.androidAdaptiveForeground,
            image: MemoryImage(_fullBleed),
            backgroundColor: const Color(0xFF0B57D0),
            detail: '432×432 · 5 densities',
          ),
          IconPlate(
            role: IconRole.androidMonochrome,
            image: MemoryImage(_silhouette),
            detail: '432×432 · 5 densities',
            findings: const [
              (
                tone: Tone.warn,
                message:
                    'A themed icon exists, but ic_launcher.xml declares no '
                    '<monochrome> layer, so Android 13+ falls back to the '
                    'full-colour icon.',
              ),
            ],
          ),
          IconPlate(
            role: IconRole.androidNotification,
            image: MemoryImage(_detailed),
            detail: '96×96 · 5 densities',
          ),
          IconPlate(
            role: IconRole.iosApp,
            image: MemoryImage(_withMargin),
            detail: '1024×1024 · 15 sizes',
            findings: const [
              (
                tone: Tone.error,
                message:
                    '14 iOS icons carry an alpha channel. App Store Connect '
                    'rejects a build whose icon does.',
              ),
            ],
          ),
          IconPlate(
            role: IconRole.macosApp,
            image: MemoryImage(_fullBleed),
            detail: '1024×1024 · 7 sizes',
          ),
          IconPlate(
            role: IconRole.webMaskable,
            image: MemoryImage(_fullBleed),
            detail: '512×512 · 2 sizes',
          ),
          IconPlate(
            role: IconRole.windowsIco,
            image: MemoryImage(_detailed),
            detail: '10 frames · 16 → 256px',
          ),
        ],
      ),
    );
  }
}

// ---- The choice ------------------------------------------------------------

/// The same role both ways, so the trade is visible rather than argued.
class _Comparison extends StatelessWidget {
  const _Comparison();

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'The same icon, both ways',
      subtitle:
          'Left: in situ. Right: flat. The stage shows whether the icon is any '
          'good; the plate shows exactly what it is.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: FwSpacing.xxxl,
        children: [
          for (var (role, bytes, background) in [
            (IconRole.macosApp, _fullBleed, null),
            (
              IconRole.androidAdaptiveForeground,
              _fullBleed,
              const Color(0xFF0B57D0),
            ),
            (IconRole.androidNotification, _detailed, null),
          ])
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 300,
                  height: 300 / situAspectRatio(IconSurface.forRole(role)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      context.radii.radiusLarge,
                    ),
                    child: IconSitu(
                      role: role,
                      image: MemoryImage(bytes),
                      backgroundColor: background,
                      showSafeZone: true,
                    ),
                  ),
                ),
                const Gap(FwSpacing.xxl),
                Expanded(
                  child: IconPlate(
                    role: role,
                    image: MemoryImage(bytes),
                    backgroundColor: background,
                    detail: 'the same file',
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---- Flavors ---------------------------------------------------------------

/// The flavor row in every state it has.
///
/// The states are the reason this is an entry: three chips that differ only in
/// a border alpha and a text colour is exactly the kind of distinction that
/// reads fine in the source and vanishes on screen.
class _Flavors extends StatelessWidget {
  const _Flavors();

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: 'Icon sets — and what is behind each one',
      subtitle:
          'A set is whatever named it: a config, an Android source set, an '
          'iOS catalog, or all three. The chip has to show which, because '
          '"configured" and "generated" send you to different places — and '
          "because the name is a directory's, not necessarily a flavor the "
          'project can build.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: FwSpacing.xxl,
        children: [
          for (var (caption, flavors, selected) in _states)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FlavorChips(flavors: flavors, selected: selected),
                const Gap(FwSpacing.md),
                Text(
                  caption,
                  style: context.type.caption.copyWith(
                    color: context.colors.mut,
                  ),
                ),
              ],
            ),
          const Gap(FwSpacing.lg),
          Text('The tooltips, spelled out', style: context.type.sectionLabel),
          const Gap(FwSpacing.md),
          for (var flavor in _every)
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.sm),
              child: Text(
                '${flavor.name} — ${flavorHint(flavor) ?? 'no tooltip'}',
                style: context.type.caption.copyWith(color: context.colors.mut),
              ),
            ),
        ],
      ),
    );
  }
}

IconFlavor _flavor(String name, Set<IconFlavorSource> sources) =>
    IconFlavor(name, sources);

final _every = [
  _flavor('complete', IconFlavorSource.values.toSet()),
  _flavor('unbuilt', {IconFlavorSource.config}),
  _flavor('androidOnly', {
    IconFlavorSource.config,
    IconFlavorSource.androidSourceSet,
  }),
  _flavor('iosOnly', {IconFlavorSource.config, IconFlavorSource.iosCatalog}),
];

final _states = <(String, List<IconFlavor>, String?)>[
  ('The default selected, one flavor fully generated', [_every.first], null),
  (
    'A flavor selected, beside one that has never been generated',
    [_every[0], _every[1]],
    'complete',
  ),
  ('Every state at once, which is the width test', _every, 'androidOnly'),
];

// ---- Page chrome -----------------------------------------------------------

class _Page extends StatelessWidget {
  const _Page({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colors.bg,
      child: ListView(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        children: [
          Text(title, style: context.type.heading),
          const Gap(FwSpacing.sm),
          Text(
            subtitle,
            style: context.type.bodyMuted.copyWith(color: context.colors.mut),
          ),
          const Gap(FwSpacing.xxl),
          child,
        ],
      ),
    );
  }
}

// ---- Synthesised icons -----------------------------------------------------

/// A logo-ish mark, drawn rather than bundled.
///
/// It needs real structure — a shape whose corners a mask can visibly take, and
/// whose colours greyscale can visibly flatten. A flat block proves nothing,
/// which is exactly what the first attempt produced.
///
/// [margin] is the fraction of the canvas left empty on each side: 0 is the
/// full-bleed case that overflows the macOS template and loses its corners to a
/// launcher mask; 0.12 is a conventionally inset icon. [opaque] false is the
/// transparent-ground case a notification or monochrome layer really has.
Uint8List _mark({double margin = 0, bool opaque = true, bool detail = false}) {
  const size = 512;
  var image = img.Image(width: size, height: size, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));

  var inset = size * margin;
  var box = size - inset * 2;
  double at(double fraction) => inset + box * fraction;

  if (opaque) {
    img.fillRect(
      image,
      x1: inset.round(),
      y1: inset.round(),
      x2: (size - inset).round(),
      y2: (size - inset).round(),
      color: img.ColorRgba8(0x1B, 0x3A, 0x6B, 0xFF),
      radius: (box * 0.06).round(),
    );
  }

  // A chevron, thick enough to survive being shrunk to 16px and angular enough
  // that a circular mask visibly bites it.
  var stroke = (box * 0.16).round();
  var ink = opaque
      ? img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF)
      : img.ColorRgba8(0x12, 0x1B, 0x2E, 0xFF);
  for (var (from, to) in [
    ((0.30, 0.26), (0.63, 0.50)),
    ((0.63, 0.50), (0.30, 0.74)),
  ]) {
    img.drawLine(
      image,
      x1: at(from.$1).round(),
      y1: at(from.$2).round(),
      x2: at(to.$1).round(),
      y2: at(to.$2).round(),
      color: ink,
      thickness: stroke,
      antialias: true,
    );
  }

  // An accent that only exists in colour — so the themed-icon stencil and the
  // tinted duotone visibly lose something the source had.
  if (opaque) {
    img.fillCircle(
      image,
      x: at(0.74).round(),
      y: at(0.50).round(),
      radius: (box * 0.09).round(),
      color: img.ColorRgba8(0x4E, 0xCD, 0xC4, 0xFF),
      antialias: true,
    );
  }

  if (detail) {
    // Fine strokes: what turns to mush at 16px, and to a blob once only the
    // alpha channel survives.
    for (var i = 0; i < 3; i++) {
      img.drawLine(
        image,
        x1: at(0.30).round(),
        y1: at(0.84 + i * 0.05).round(),
        x2: at(0.70).round(),
        y2: at(0.84 + i * 0.05).round(),
        color: ink,
        thickness: (box * 0.018).round(),
        antialias: true,
      );
    }
  }

  return img.encodePng(image);
}

final _fullBleed = _mark();
final _withMargin = _mark(margin: 0.12);
final _silhouette = _mark(opaque: false);
final _detailed = _mark(margin: 0.06, detail: true);
