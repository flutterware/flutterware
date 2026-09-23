/// The right-hand pane: one role, where it is actually seen.
///
/// The plates answer "what have I got, and what does each platform do to it".
/// This answers the question they provoke and cannot settle — *is it any good* —
/// by putting the icon on the surface it ships to, among neighbours, at the
/// size it is really drawn at.
///
/// A **View**: plain data and `ImageProvider`s in.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../../ui/design/design.dart';
import '../../ui/theme.dart';
import '../model/role.dart';
import 'icon_render.dart';
import 'situ.dart';

/// One file, as far as the pane is concerned.
typedef IconDetailFile = ({ImageProvider image, int? size, String? density});

class IconDetail extends StatelessWidget {
  const IconDetail({
    super.key,
    required this.role,
    required this.files,
    this.image,
    this.backgroundImage,
    this.backgroundColor,
    this.color,
    this.findings = const [],
    this.context_,
    this.adaptiveMask = AdaptiveMask.squircle,
    this.onMask,
    this.showSafeZone = false,
    this.onSafeZone,
    this.dark = true,
    this.onDark,
  });

  final IconRole role;

  /// Every file playing this role, smallest first — drawn at true size.
  final List<IconDetailFile> files;

  /// The largest, which is what the stage draws. Null when the role is a colour
  /// rather than an image.
  final ImageProvider? image;

  final ImageProvider? backgroundImage;
  final Color? backgroundColor;

  /// The adaptive background when it is a colour, spelled for a caption.
  final String? color;

  final List<({Tone tone, String message})> findings;

  /// The one line of project context that changes what this role means —
  /// that a flavor inherits it, today. Named oddly because `context` is
  /// taken.
  final String? context_;

  final AdaptiveMask adaptiveMask;
  final ValueChanged<AdaptiveMask>? onMask;
  final bool showSafeZone;
  final ValueChanged<bool>? onSafeZone;
  final bool dark;
  final ValueChanged<bool>? onDark;

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    var colors = context.colors;
    var surface = IconSurface.forRole(role);

    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        Text(role.label, style: type.heading),
        const Gap(FwSpacing.xs),
        Text(role.description, style: type.caption.copyWith(color: colors.mut)),
        const Gap(FwSpacing.xl),
        if (image == null)
          _NoImage(color: color)
        else ...[
          Text(surface.label, style: type.micro.copyWith(color: colors.mut2)),
          const Gap(FwSpacing.md),
          _Stage(
            role: role,
            image: image!,
            backgroundImage: backgroundImage,
            backgroundColor: backgroundColor,
            adaptiveMask: adaptiveMask,
            showSafeZone: showSafeZone,
            dark: dark,
            surface: surface,
          ),
          const Gap(FwSpacing.lg),
          _Controls(
            role: role,
            adaptiveMask: adaptiveMask,
            onMask: onMask,
            showSafeZone: showSafeZone,
            onSafeZone: onSafeZone,
            dark: dark,
            onDark:
                surface == IconSurface.androidHome ||
                    surface == IconSurface.iosHome
                ? onDark
                : null,
          ),
          const Gap(FwSpacing.xxl),
          _TrueSize(role: role, files: files),
        ],
        if (findings.isNotEmpty) ...[
          const Gap(FwSpacing.xxl),
          for (var finding in findings) _Finding(finding),
        ],
        if (context_ != null) ...[
          const Gap(FwSpacing.xl),
          Text(context_!, style: type.caption.copyWith(color: colors.mut2)),
        ],
      ],
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.role,
    required this.image,
    required this.adaptiveMask,
    required this.showSafeZone,
    required this.dark,
    required this.surface,
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
  final IconSurface surface;

  @override
  Widget build(BuildContext context) {
    if (surface == IconSurface.none) {
      return Container(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        decoration: BoxDecoration(
          color: context.colors.panel,
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: context.colors.line),
        ),
        child: Column(
          children: [
            IconRender(image: image, role: role, size: 96),
            const Gap(FwSpacing.lg),
            Text(
              'Nothing on a device shows this one — it is uploaded with the '
              'release, or packaged.',
              textAlign: TextAlign.center,
              style: context.type.caption.copyWith(color: context.colors.mut),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = situWidthFor(constraints.maxWidth);
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(context.radii.radiusLarge),
            child: SizedBox(
              width: width,
              height: width / situAspectRatio(surface),
              child: IconSitu(
                role: role,
                image: image,
                backgroundImage: backgroundImage,
                backgroundColor: backgroundColor,
                adaptiveMask: adaptiveMask,
                showSafeZone: showSafeZone,
                dark: dark,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What can be changed about the stage, and nothing that cannot.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.role,
    required this.adaptiveMask,
    required this.showSafeZone,
    required this.dark,
    this.onMask,
    this.onSafeZone,
    this.onDark,
  });

  final IconRole role;
  final AdaptiveMask adaptiveMask;
  final ValueChanged<AdaptiveMask>? onMask;
  final bool showSafeZone;
  final ValueChanged<bool>? onSafeZone;
  final bool dark;
  final ValueChanged<bool>? onDark;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: FwSpacing.sm,
      runSpacing: FwSpacing.sm,
      children: [
        // The launcher's choice, so it only appears where a launcher makes one.
        if (role.mask == IconMask.adaptive && onMask != null)
          for (var mask in AdaptiveMask.values)
            _Toggle(
              label: mask.label,
              on: mask == adaptiveMask,
              onTap: () => onMask!(mask),
            ),
        if (role.safeFraction != null && onSafeZone != null)
          _Toggle(
            label: 'Safe zone',
            on: showSafeZone,
            onTap: () => onSafeZone!(!showSafeZone),
          ),
        if (onDark != null)
          _Toggle(
            label: dark ? 'Dark wallpaper' : 'Light wallpaper',
            on: true,
            onTap: () => onDark!(!dark),
          ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.lg,
            vertical: FwSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: on ? colors.accentSoft : colors.panel2,
            borderRadius: BorderRadius.circular(context.radii.pill),
            border: Border.all(color: on ? colors.accent : colors.line),
          ),
          child: Text(label, style: context.type.caption),
        ),
      ),
    );
  }
}

/// Every file at the size it is actually drawn at.
///
/// A 16px favicon at 16px is the point: scaled up to a thumbnail it looks fine,
/// and in the browser tab it is mush.
class _TrueSize extends StatelessWidget {
  const _TrueSize({required this.role, required this.files});

  final IconRole role;
  final List<IconDetailFile> files;

  /// Beyond this a "true size" row stops fitting and stops being informative —
  /// nobody misjudges whether a 512px icon has enough detail.
  static const _cap = 128;

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    var colors = context.colors;
    var shown = [
      for (var file in files)
        if ((file.size ?? 0) <= _cap && (file.size ?? 0) > 0) file,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('At true size', style: type.micro.copyWith(color: colors.mut2)),
        const Gap(FwSpacing.md),
        Wrap(
          spacing: FwSpacing.xl,
          runSpacing: FwSpacing.lg,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (var file in shown)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconRender(
                    image: file.image,
                    role: role,
                    size: file.size!.toDouble(),
                  ),
                  const Gap(FwSpacing.xs),
                  Text(
                    '${file.size}px',
                    style: type.micro.copyWith(color: colors.mut2),
                  ),
                ],
              ),
            if (shown.length < files.length)
              Padding(
                padding: const EdgeInsets.only(bottom: FwSpacing.lg),
                child: Text(
                  '+${files.length - shown.length} larger',
                  style: type.micro.copyWith(color: colors.mut3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _NoImage extends StatelessWidget {
  const _NoImage({this.color});

  final String? color;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var parsed = color == null ? null : _parse(color!);

    return Row(
      children: [
        Container(
          width: 72,
          height: 72,
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
                ? 'No image on disk for this role.'
                : 'A colour rather than an image — $color, from colors.xml.',
            style: context.type.caption.copyWith(color: colors.mut),
          ),
        ),
      ],
    );
  }

  static int? _parse(String value) {
    var digits = value.replaceFirst('#', '');
    var parsed = int.tryParse(digits, radix: 16);
    if (parsed == null) return null;
    return digits.length == 6 ? 0xFF000000 | parsed : parsed;
  }
}

class _Finding extends StatelessWidget {
  const _Finding(this.finding);

  final ({Tone tone, String message}) finding;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = finding.tone == Tone.error ? colors.red : colors.amber;
    return Container(
      margin: const EdgeInsets.only(bottom: FwSpacing.md),
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
          Expanded(child: Text(finding.message, style: context.type.caption)),
        ],
      ),
    );
  }
}
