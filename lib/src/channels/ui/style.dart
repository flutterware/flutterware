/// The look of a rendered panel, in the published package, without the GUI's
/// design tokens.
///
/// Why this exists rather than `FwTokens` (owner, 2026-08-11: *"we don't
/// move the token, that doesn't make sense — inline them so it looks mostly
/// right on both sides"*). One renderer serves two hosts: the flutterware
/// cockpit, which has `FwTokens`, and the in-app devbar overlay inside
/// somebody else's app, which does not and never will. Moving the GUI's design
/// system into the published package to share a few widgets would make it
/// published API for every flutterware user.
///
/// So: **colours come from the ambient `Theme`** — both hosts have one, and
/// deriving from `ColorScheme` is what makes a panel look native in either —
/// and the **rhythm is inlined** from `app/lib/src/ui/design/`, the numbers
/// copied deliberately so the cockpit's new tabs sit on the same beat as the
/// panels beside them. The numbers are duplicated on purpose: a copy that
/// drifts by a pixel is a far smaller cost than a shared dependency in the
/// wrong direction.
library;

import 'package:material_ui/material_ui.dart';

class PanelStyle {
  const PanelStyle._({
    required this.surface,
    required this.raised,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.accent,
    required this.good,
    required this.warn,
    required this.bad,
    required this.heading,
    required this.sectionLabel,
    required this.body,
    required this.bodyStrong,
    required this.small,
    required this.caption,
    required this.micro,
    required this.mono,
  });

  factory PanelStyle.of(BuildContext context) {
    var theme = Theme.of(context);
    var scheme = theme.colorScheme;
    var ink = scheme.onSurface;
    TextStyle style(
      double size, {
      FontWeight weight = FontWeight.w400,
      Color? color,
      double letterSpacing = 0,
    }) => TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color ?? ink,
      letterSpacing: letterSpacing,
    );

    var muted = ink.withValues(alpha: 0.62);
    return PanelStyle._(
      surface: scheme.surface,
      raised: scheme.surfaceContainerHighest,
      ink: ink,
      muted: muted,
      faint: ink.withValues(alpha: 0.38),
      line: scheme.outlineVariant,
      accent: scheme.primary,
      // Status has no home in ColorScheme, so these are the one genuinely
      // hardcoded triple. Picked to read on both a light and a dark surface.
      good: const Color(0xFF2E9E5B),
      warn: const Color(0xFFB8860B),
      bad: scheme.error,
      // The `FwTypography` scale, verbatim: 16 / 12 / 13 / 12.5 / 11.5 / 10.5.
      heading: style(16, weight: FontWeight.w600),
      sectionLabel: style(
        12,
        weight: FontWeight.w600,
        color: muted,
        letterSpacing: 0.3,
      ),
      body: style(13),
      bodyStrong: style(13, weight: FontWeight.w600),
      small: style(12.5),
      caption: style(11.5, color: muted),
      micro: style(
        10.5,
        weight: FontWeight.w600,
        color: muted,
        letterSpacing: 0.2,
      ),
      // Verbatim from the reference panel (`server_plugin.dart:1859`), so a
      // payload reads the same in a descriptor tab as in the Requests tab
      // beside it.
      mono: style(12).copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
      ),
    );
  }

  final Color surface;
  final Color raised;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color line;
  final Color accent;
  final Color good;
  final Color warn;
  final Color bad;

  final TextStyle heading;
  final TextStyle sectionLabel;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle small;
  final TextStyle caption;
  final TextStyle micro;
  final TextStyle mono;

  /// `FwSpacing`, inlined.
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 6.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;

  /// `defaultRadii`, inlined.
  static const radiusSmall = 7.0;
  static const radius = 9.0;

  /// `InspectTabStrip.height`, inlined — the strip this one stands in for.
  static const stripHeight = 34.0;
}

/// A transparent `Material` under a rendered panel.
///
/// Every exported view wraps itself in one. `Switch`, `TextField`,
/// `DropdownButtonFormField` and `InkWell` all require a `Material` ancestor,
/// and a bare `Text` without one renders in Flutter's yellow-underlined
/// fallback style. These widgets are embedded in a cockpit pane *and* in some
/// app's overlay, and neither is guaranteed to have provided one — the same
/// reason `InspectTabStrip` carries its own. Both failures showed up the first
/// time the previews rendered.
class PanelSurface extends StatelessWidget {
  const PanelSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Material(type: MaterialType.transparency, child: child);
}

/// A square spacer, the published-package twin of the GUI's `Gap`.
class PanelGap extends StatelessWidget {
  const PanelGap(this.size, {super.key});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size);
}
