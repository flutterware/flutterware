/// The modest direction: a flat plate, no chrome.
///
/// The same information the in-situ stage carries — what the OS does, what it
/// removes, what survives — without drawing a phone around it. One card per
/// role, wide enough to hold the comparison in a row, so a panel of them fills
/// the width instead of trailing down one edge of it.
///
/// Kept beside [IconSitu] rather than instead of it because they answer
/// different questions. The stage answers "is this any good"; the plate answers
/// "what is this, exactly" — and the plate is the one that survives being
/// looked at fifty times.
///
/// A **View**: plain data and an `ImageProvider` in.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../../ui/design/design.dart';
import '../../ui/theme.dart';
import '../model/role.dart';
import '../model/wiring.dart';
import 'icon_render.dart';

class IconPlate extends StatelessWidget {
  const IconPlate({
    super.key,
    required this.role,
    this.image,
    this.backgroundImage,
    this.backgroundColor,
    this.color,
    this.adaptiveMask = AdaptiveMask.squircle,
    this.detail,
    this.findings = const [],
    this.selected = false,
    this.onTap,
  });

  final IconRole role;

  /// Null when the role is a colour rather than an image — an adaptive
  /// background named in `colors.xml` has no file to draw.
  final ImageProvider? image;
  final String? color;
  final ImageProvider? backgroundImage;
  final Color? backgroundColor;
  final AdaptiveMask adaptiveMask;

  /// The line under the title — sizes, densities, whatever the caller knows.
  final String? detail;

  final List<({Tone tone, String message})> findings;
  final bool selected;
  final VoidCallback? onTap;

  static const _size = 84.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var worst = findings.any((f) => f.tone == Tone.error)
        ? Tone.error
        : findings.isEmpty
        ? null
        : Tone.warn;

    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(FwSpacing.xl),
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: BorderRadius.circular(context.radii.radius),
            border: Border.all(
              color: selected
                  ? colors.accent
                  : worst == Tone.error
                  ? colors.red.withValues(alpha: 0.45)
                  : colors.line,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(role.label, style: type.bodyStrong),
                        if (detail != null)
                          Text(
                            detail!,
                            style: type.caption.copyWith(color: colors.mut),
                          ),
                      ],
                    ),
                  ),
                  // The API-level badge is provenance, not the subject. Left
                  // unconstrained it took its full intrinsic width out of a
                  // narrow card and left the [Expanded] label beside it a few
                  // pixels to wrap "Adaptive foreground" into — one character
                  // per line. It yields before the label does.
                  if (role.since != null)
                    Flexible(
                      child: Text(
                        role.since!,
                        style: type.micro.copyWith(color: colors.mut3),
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                ],
              ),
              const Gap(FwSpacing.xl),
              if (image == null)
                _Swatch(color: color)
              else
                // As authored, then every shape the platform might apply — in a
                // row, because the comparison is the content.
                //
                // The cells shrink together rather than the row overflowing.
                // Five icons at [_size] do not fit the plate at the narrowest
                // window we lay out for, and the two usual escapes both destroy
                // the comparison: wrapping puts the shapes on different lines,
                // scrolling puts some of them off the edge. Same size as each
                // other is the only property that matters here, not any
                // particular size.
                LayoutBuilder(
                  builder: (context, constraints) {
                    var count = 1 + _shapes.length;
                    var gaps = FwSpacing.lg * (count - 1);
                    var cell = ((constraints.maxWidth - gaps) / count).clamp(
                      0.0,
                      _size,
                    );
                    return Row(
                      children: [
                        _Cell(
                          label: 'as authored',
                          size: cell,
                          child: IconRender(
                            image: image!,
                            role: role,
                            size: cell,
                            mask: IconMask.none,
                            backgroundImage: backgroundImage,
                            backgroundColor: backgroundColor,
                          ),
                        ),
                        for (var (label, mask) in _shapes)
                          Padding(
                            padding: const EdgeInsets.only(left: FwSpacing.lg),
                            child: _Cell(
                              label: label,
                              size: cell,
                              child: IconRender(
                                image: image!,
                                role: role,
                                size: cell,
                                adaptiveMask: mask ?? adaptiveMask,
                                showSafeZone: true,
                                backgroundImage: backgroundImage,
                                backgroundColor: backgroundColor,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              if (_note != null) ...[
                const Gap(FwSpacing.lg),
                Text(_note!, style: type.caption.copyWith(color: colors.mut)),
              ],
              for (var finding in findings) ...[
                const Gap(FwSpacing.lg),
                _Finding(tone: finding.tone, message: finding.message),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The shapes worth showing beside the source, and their captions.
  List<(String, AdaptiveMask?)> get _shapes => switch (role.mask) {
    IconMask.none => const [],
    IconMask.adaptive => [
      for (var mask in AdaptiveMask.values) (mask.label.toLowerCase(), mask),
    ],
    IconMask.iosSquircle => const [('on iOS', null)],
    IconMask.macosGuide => const [('Dock convention', null)],
    IconMask.maskableCircle => const [('safe zone', null)],
  };

  String? get _note => switch (role.treatment) {
    IconTreatment.asAuthored => null,
    IconTreatment.whiteSilhouette =>
      'The status bar keeps the alpha channel and nothing else.',
    IconTreatment.alphaTinted =>
      'Shape only — the wallpaper decides both colours.',
    IconTreatment.luminanceTinted =>
      'Desaturated, then tinted; light and dark regions survive.',
  };
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.child,
    this.size = IconPlate._size,
  });

  final String label;
  final Widget child;

  /// Width of the caption under [child] — the rendered icon's size, so the two
  /// stay the same width as the row shrinks.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        const Gap(FwSpacing.sm),
        SizedBox(
          width: size,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: context.type.micro.copyWith(color: context.colors.mut2),
          ),
        ),
      ],
    );
  }
}

class _Finding extends StatelessWidget {
  const _Finding({required this.tone, required this.message});

  final Tone tone;
  final String message;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = tone == Tone.error ? colors.red : colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.md,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: FwSpacing.md),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
          Expanded(child: Text(message, style: context.type.caption)),
        ],
      ),
    );
  }
}

/// A colour has no artwork to mask — the swatch is the whole truth.
class _Swatch extends StatelessWidget {
  const _Swatch({this.color});

  final String? color;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var parsed = color == null ? null : parseResourceColor(color!);
    return Row(
      children: [
        Container(
          width: IconPlate._size,
          height: IconPlate._size,
          decoration: BoxDecoration(
            color: parsed == null ? colors.panel2 : Color(parsed),
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            border: Border.all(color: colors.line),
          ),
        ),
        const Gap(FwSpacing.xl),
        Expanded(
          child: Text(
            color == null
                ? 'Nothing on disk for this role.'
                : 'A colour, not an image — $color.',
            style: context.type.caption.copyWith(color: colors.mut),
          ),
        ),
      ],
    );
  }
}
