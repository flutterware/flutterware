import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart' show Tone;
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The design system, on one screen.
///
/// Every token the app has, rendered beside its own name. This is the page that
/// makes drift reviewable instead of a matter of taste: the finding that started
/// it — four different greys doing muted-grey work at the same size and weight —
/// took a live query against a running app to notice, and on this page it would
/// have been obvious at a glance and permanently.
///
/// Read it as the answer to *"is this the same grey?"*, *"is there already a
/// size for this?"* and *"what does `mut2` actually look like?"* — three
/// questions that were previously answered by picking a neighbour's literal.
@Preview(name: 'Palette', group: 'Design system', wrapper: wrapInAppTheme)
Widget palette() => const _Palette();

/// The same swatches in the dark build. Paired deliberately: the dark theme is
/// fully wired — `themeMode: system`, its own palette, brightness derived from
/// the background — and until these previews existed nothing had looked at it.
@Preview(
  name: 'Palette · dark',
  group: 'Design system',
  wrapper: wrapInDarkTheme,
)
Widget paletteDark() => const _Palette();

@Preview(name: 'Type ramp', group: 'Design system', wrapper: wrapInAppTheme)
Widget typeRamp() => const _TypeRamp();

@Preview(
  name: 'Type ramp · dark',
  group: 'Design system',
  wrapper: wrapInDarkTheme,
)
Widget typeRampDark() => const _TypeRamp();

/// Radii and icon sizes side by side, each drawn at its own value.
///
/// Both scales gained entries because call sites had gone around them: the radii
/// had no answer for a chip or a pill, so thirty sites wrote their own, and
/// there was no icon scale at all. Drawn together, "is there already a step for
/// this?" is a question you can answer by looking.
@Preview(
  name: 'Radii & sizing',
  group: 'Design system',
  wrapper: wrapInAppTheme,
)
Widget radiiAndSizing() => const _RadiiAndSizing();

/// The five tones, as the plugin API hands them over, and the surfaces derived
/// from them. `toneColor` is the single place a tone becomes a pixel.
@Preview(name: 'Tones', group: 'Design system', wrapper: wrapInAppTheme)
Widget tones() => const _Tones();

// ── palette ──────────────────────────────────────────────────────────────────

class _Palette extends StatelessWidget {
  const _Palette();

  @override
  Widget build(BuildContext context) {
    var c = context.colors;
    return _Page(
      title: 'Palette',
      children: [
        _Group('Accent', [
          ('accent', c.accent),
          ('accentDark', c.accentDark),
          ('accentSoft', c.accentSoft),
          ('accentSoft2', c.accentSoft2),
          ('onPrimary', c.onPrimary),
        ]),
        _Group('Surfaces', [
          ('bg', c.bg),
          ('panel', c.panel),
          ('panel2', c.panel2),
        ]),
        // The four that drifted. Rank names — mut, mut2, mut3 — are why: a call
        // site picks one by feel because none of them says what it is *for*.
        _Group('Ink', [
          ('ink', c.ink),
          ('ink2', c.ink2),
          ('mut', c.mut),
          ('mut2', c.mut2),
          ('mut3', c.mut3),
        ]),
        _Group('Lines', [('line', c.line), ('line2', c.line2)]),
        _Group('Status', [
          ('grn', c.grn),
          ('amber', c.amber),
          ('red', c.red),
          ('info', c.info),
          ('warningText', c.warningText),
        ]),
        _Group('Menu chrome', [
          ('primaryOnMenu', c.primaryOnMenu),
          ('menuBackground', c.menuBackground),
          ('menuSecondaryBackground', c.menuSecondaryBackground),
          ('dividerDark', c.dividerDark),
        ]),
        _Group('Interaction', [
          ('hoverOverlay', c.hoverOverlay),
          ('pressedOverlay', c.pressedOverlay),
          ('primaryHoverOverlay', c.primaryHoverOverlay),
          ('focusRing', c.focusRing),
          ('searchMark', c.searchMark),
        ]),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.label, this.swatches);

  final String label;
  final List<(String, Color)> swatches;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: context.type.sectionLabel),
      const Gap(FwSpacing.md),
      Wrap(
        spacing: FwSpacing.md,
        runSpacing: FwSpacing.md,
        children: [for (var (name, color) in swatches) _Swatch(name, color)],
      ),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.name, this.color);

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Laid over a two-tone ground, so a translucent token — the hover and
          // pressed overlays, the search mark — reads as translucent instead of
          // as a flat colour nobody can place.
          SizedBox(
            height: 44,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Row(
                    children: [
                      Expanded(child: ColoredBox(color: context.colors.bg)),
                      Expanded(child: ColoredBox(color: context.colors.ink)),
                    ],
                  ),
                  ColoredBox(color: color),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: context.colors.line),
                      borderRadius: BorderRadius.circular(
                        context.radii.radiusSmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Gap(FwSpacing.xs),
          Text(name, style: context.type.caption),
          Text(
            _hex(color),
            style: context.type.micro.copyWith(
              color: context.colors.mut2,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

String _hex(Color color) {
  var v = color.toARGB32();
  var rgb = (v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  var a = (v >> 24) & 0xFF;
  return a == 0xFF ? '#$rgb' : '#$rgb ${(a / 255 * 100).round()}%';
}

// ── type ─────────────────────────────────────────────────────────────────────

class _TypeRamp extends StatelessWidget {
  const _TypeRamp();

  @override
  Widget build(BuildContext context) {
    var t = context.type;
    return _Page(
      title: 'Type ramp',
      children: [
        for (var (name, style) in <(String, TextStyle)>[
          ('pageTitle', t.pageTitle),
          ('heading', t.heading),
          ('sectionLabel', t.sectionLabel),
          ('fieldLabel', t.fieldLabel),
          ('bodyStrong', t.bodyStrong),
          ('body', t.body),
          ('bodyMuted', t.bodyMuted),
          ('bodySmall', t.bodySmall),
          ('caption', t.caption),
          ('micro', t.micro),
          ('button', t.button),
        ])
          _TypeRow(name, style),
      ],
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow(this.name, this.style);

  final String name;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.lg),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            name,
            style: context.type.micro.copyWith(fontFamily: 'monospace'),
          ),
        ),
        SizedBox(
          width: 96,
          child: Text(
            // The three facts a call site actually chooses between.
            '${style.fontSize} · w${style.fontWeight?.value ?? 400}',
            style: context.type.micro.copyWith(color: context.colors.mut2),
          ),
        ),
        Expanded(child: Text('The quick brown fox', style: style)),
      ],
    ),
  );
}

// ── radii & sizing ───────────────────────────────────────────────────────────

class _RadiiAndSizing extends StatelessWidget {
  const _RadiiAndSizing();

  @override
  Widget build(BuildContext context) {
    var r = context.radii;
    return _Page(
      title: 'Radii & sizing',
      children: [
        Text('Radii', style: context.type.sectionLabel),
        const Gap(FwSpacing.md),
        Wrap(
          spacing: FwSpacing.lg,
          runSpacing: FwSpacing.lg,
          children: [
            for (var (name, value) in [
              ('micro', r.micro),
              ('radiusSmall', r.radiusSmall),
              ('radius', r.radius),
              ('radiusLarge', r.radiusLarge),
              ('pill', r.pill),
            ])
              _RadiusChip(name, value),
          ],
        ),
        const Gap(FwSpacing.xxxl),
        Text('Icon sizes', style: context.type.sectionLabel),
        const Gap(FwSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var (name, value) in [
              ('xs', FwIconSize.xs),
              ('sm', FwIconSize.sm),
              ('md', FwIconSize.md),
              ('lg', FwIconSize.lg),
              ('xl', FwIconSize.xl),
            ])
              _IconStep(name, value),
          ],
        ),
        const Gap(FwSpacing.xxxl),
        Text('Spacing', style: context.type.sectionLabel),
        const Gap(FwSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var (name, value) in [
              ('xxs', FwSpacing.xxs),
              ('xs', FwSpacing.xs),
              ('sm', FwSpacing.sm),
              ('md', FwSpacing.md),
              ('lg', FwSpacing.lg),
              ('xl', FwSpacing.xl),
              ('xxl', FwSpacing.xxl),
              ('xxxl', FwSpacing.xxxl),
            ])
              _SpaceStep(name, value),
          ],
        ),
        const Gap(FwSpacing.xxxl),
        Text('Elevation', style: context.type.sectionLabel),
        const Gap(FwSpacing.md),
        Row(
          children: [
            for (var (name, shadow) in [
              ('sm', context.elevation.sm),
              ('md', context.elevation.md),
              ('lg', context.elevation.lg),
            ])
              Padding(
                padding: const EdgeInsets.only(right: FwSpacing.xxl),
                child: Column(
                  children: [
                    Container(
                      width: 84,
                      height: 56,
                      decoration: BoxDecoration(
                        color: context.colors.bg,
                        borderRadius: BorderRadius.circular(
                          context.radii.radius,
                        ),
                        boxShadow: shadow,
                      ),
                    ),
                    const Gap(FwSpacing.sm),
                    Text(name, style: context.type.caption),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _RadiusChip extends StatelessWidget {
  const _RadiusChip(this.name, this.value);

  final String name;
  final double value;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 72,
        height: 56,
        decoration: BoxDecoration(
          color: context.colors.accentSoft,
          border: Border.all(color: context.colors.accent),
          borderRadius: BorderRadius.circular(value),
        ),
      ),
      const Gap(FwSpacing.sm),
      Text(name, style: context.type.caption),
      Text(
        value >= 999 ? '∞' : value.toStringAsFixed(0),
        style: context.type.micro.copyWith(color: context.colors.mut2),
      ),
    ],
  );
}

class _IconStep extends StatelessWidget {
  const _IconStep(this.name, this.value);

  final String name;
  final double value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: FwSpacing.xxl),
    child: Column(
      children: [
        Icon(Icons.settings, size: value, color: context.colors.ink),
        const Gap(FwSpacing.sm),
        Text(name, style: context.type.caption),
        Text(
          value.toStringAsFixed(0),
          style: context.type.micro.copyWith(color: context.colors.mut2),
        ),
      ],
    ),
  );
}

class _SpaceStep extends StatelessWidget {
  const _SpaceStep(this.name, this.value);

  final String name;
  final double value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: FwSpacing.lg),
    child: Column(
      children: [
        Container(width: value, height: 40, color: context.colors.accent),
        const Gap(FwSpacing.sm),
        Text(name, style: context.type.caption),
        Text(
          value.toStringAsFixed(0),
          style: context.type.micro.copyWith(color: context.colors.mut2),
        ),
      ],
    ),
  );
}

// ── tones ────────────────────────────────────────────────────────────────────

class _Tones extends StatelessWidget {
  const _Tones();

  @override
  Widget build(BuildContext context) {
    var c = context.colors;
    return _Page(
      title: 'Tones',
      children: [
        Text(
          'A plugin reports a Tone; toneColor is the one place it becomes a '
          'pixel. statusFill and statusBorder derive the soft surfaces, so a '
          'theme authors the accent and gets the rest.',
          style: context.type.bodyMuted,
        ),
        const Gap(FwSpacing.xl),
        for (var tone in Tone.values) _ToneRow(tone, toneColor(c, tone)),
      ],
    );
  }
}

class _ToneRow extends StatelessWidget {
  const _ToneRow(this.tone, this.color);

  final Tone tone;
  final Color color;

  @override
  Widget build(BuildContext context) {
    var c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.md),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              tone.name,
              style: context.type.micro.copyWith(fontFamily: 'monospace'),
            ),
          ),
          Container(width: 40, height: 24, color: color),
          const Gap(FwSpacing.lg),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.lg,
              vertical: FwSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: c.statusFill(color),
              border: Border.all(color: c.statusBorder(color)),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            ),
            child: Text(
              'statusFill / statusBorder',
              style: context.type.caption,
            ),
          ),
        ],
      ),
    );
  }
}

// ── page chrome ──────────────────────────────────────────────────────────────

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        Text(title, style: context.type.pageTitle),
        const Gap(FwSpacing.xl),
        for (var child in children) ...[child, const Gap(FwSpacing.xxl)],
      ],
    ),
  );
}
