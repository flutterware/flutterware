import 'package:material_ui/material_ui.dart';

import 'palette.dart';

// Base size ramp (logical px) for the Material text theme and the component
// styles below. Per-theme scaling is applied in [FwTypography.from].
const _sizeDisplayLarge = 35.0;
const _sizeDisplayMedium = 28.0;
const _sizeDisplaySmall = 25.0;
const _sizeHeadlineMedium = 20.0;
const _sizeHeadlineSmall = 19.0;
const _sizeTitleLarge = 18.0;

/// Per-theme typography knobs. Each theme picks a font family, weight scheme,
/// scale and tracking; [FwTypography.from] bakes these onto the ramp.
@immutable
class FwTypeSpec {
  /// Multiplies every size in the ramp (density / scale).
  final double scale;

  /// A system / bundled family name; falls back to the platform default if the
  /// family is absent.
  //
  // The upstream design system routed this through `google_fonts`, which
  // fetches over the network on first paint. A local dev tool must work
  // offline, so only bundled/system families are supported. To match a theme's
  // exact font, bundle it as an asset instead.
  final String? fontFamily;

  /// Weight for headings, labels, page/section titles.
  final FontWeight heading;

  /// Weight for emphasised body, buttons, micro labels.
  final FontWeight strong;

  /// Weight for plain body, captions.
  final FontWeight body;

  /// Added to every style's letter-spacing.
  final double tracking;

  const FwTypeSpec({
    this.scale = 1.0,
    this.fontFamily,
    this.heading = FontWeight.w700,
    this.strong = FontWeight.w600,
    this.body = FontWeight.w400,
    this.tracking = 0.0,
  });

  /// Applies this spec's font to [style], or returns it unchanged (platform
  /// default) when no family is set.
  TextStyle applyFont(TextStyle style) {
    if (fontFamily != null) return style.copyWith(fontFamily: fontFamily);
    return style;
  }

  /// Applies this spec's font across a whole Material [TextTheme] (used for the
  /// bare `Text` / dialog defaults that don't read [FwTypography]).
  TextTheme applyFontTheme(TextTheme theme) {
    if (fontFamily != null) return theme.apply(fontFamily: fontFamily);
    return theme;
  }
}

/// Per-theme typography — the base ramp with component colours resolved from a
/// [FwPalette] and weights/scale/family from a [FwTypeSpec]. Provided via
/// [FwTokens]; read via `context.type`.
@immutable
class FwTypography {
  final double sizeDisplayLarge;
  final double sizeDisplayMedium;
  final double sizeDisplaySmall;
  final double sizeHeadlineMedium;
  final double sizeHeadlineSmall;
  final double sizeTitleLarge;

  final TextStyle fieldLabel;
  final TextStyle pageTitle;
  final TextStyle heading;
  final TextStyle sectionLabel;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle bodyMuted;

  /// One step below [body] (12.5) — dense control text: picker cells, chips,
  /// inline hints, list-row secondaries.
  final TextStyle bodySmall;
  final TextStyle caption;
  final TextStyle micro;
  final TextStyle button;

  /// Machine data — a query, a header, a path, a duration.
  ///
  /// A token because it was six copies: seven files each spelled out the same
  /// family, the same three fallbacks and the same tabular figures, and they
  /// had already drifted on size. Tabular figures are the reason it exists — a
  /// column of durations that shifts as the digits change cannot be compared
  /// down.
  ///
  /// Deliberately not routed through [FwTypeSpec.applyFont]: a theme picks the
  /// face for prose, and prose is exactly what this is not.
  final TextStyle mono;

  /// The spec these styles were built from — kept so chrome (e.g. the Material
  /// [TextTheme] in `buildAppTheme`) can apply the same font.
  final FwTypeSpec spec;

  const FwTypography({
    required this.sizeDisplayLarge,
    required this.sizeDisplayMedium,
    required this.sizeDisplaySmall,
    required this.sizeHeadlineMedium,
    required this.sizeHeadlineSmall,
    required this.sizeTitleLarge,
    required this.fieldLabel,
    required this.pageTitle,
    required this.heading,
    required this.sectionLabel,
    required this.body,
    required this.bodyStrong,
    required this.bodyMuted,
    required this.bodySmall,
    required this.caption,
    required this.micro,
    required this.button,
    required this.mono,
    required this.spec,
  });

  factory FwTypography.from(
    FwPalette p, [
    FwTypeSpec spec = const FwTypeSpec(),
  ]) {
    TextStyle style(
      double size, {
      required FontWeight weight,
      Color? color,
      double letterSpacing = 0,
    }) => spec.applyFont(
      TextStyle(
        fontSize: size * spec.scale,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing + spec.tracking,
      ),
    );

    return FwTypography(
      sizeDisplayLarge: _sizeDisplayLarge * spec.scale,
      sizeDisplayMedium: _sizeDisplayMedium * spec.scale,
      sizeDisplaySmall: _sizeDisplaySmall * spec.scale,
      sizeHeadlineMedium: _sizeHeadlineMedium * spec.scale,
      sizeHeadlineSmall: _sizeHeadlineSmall * spec.scale,
      sizeTitleLarge: _sizeTitleLarge * spec.scale,
      fieldLabel: style(11.5, weight: spec.heading, letterSpacing: 0.4),
      pageTitle: style(22, weight: spec.heading, color: p.ink),
      heading: style(16, weight: spec.heading, color: p.ink),
      sectionLabel: style(
        12,
        weight: spec.heading,
        color: p.ink2,
        letterSpacing: 0.3,
      ),
      body: style(13, weight: spec.body, color: p.ink),
      bodyStrong: style(13, weight: spec.strong, color: p.ink),
      bodyMuted: style(13, weight: spec.body, color: p.mut),
      bodySmall: style(12.5, weight: spec.body, color: p.ink),
      caption: style(11.5, weight: spec.body, color: p.mut),
      micro: style(10.5, weight: spec.strong, color: p.mut, letterSpacing: 0.2),
      button: style(13, weight: spec.strong),
      mono: TextStyle(
        fontSize: 12.5 * spec.scale,
        fontWeight: spec.body,
        color: p.ink,
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Consolas', 'Courier New'],
        letterSpacing: 0,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      spec: spec,
    );
  }

  static FwTypography lerp(FwTypography a, FwTypography b, double t) {
    TextStyle s(TextStyle x, TextStyle y) => TextStyle.lerp(x, y, t)!;
    double d(double x, double y) => x + (y - x) * t;
    return FwTypography(
      sizeDisplayLarge: d(a.sizeDisplayLarge, b.sizeDisplayLarge),
      sizeDisplayMedium: d(a.sizeDisplayMedium, b.sizeDisplayMedium),
      sizeDisplaySmall: d(a.sizeDisplaySmall, b.sizeDisplaySmall),
      sizeHeadlineMedium: d(a.sizeHeadlineMedium, b.sizeHeadlineMedium),
      sizeHeadlineSmall: d(a.sizeHeadlineSmall, b.sizeHeadlineSmall),
      sizeTitleLarge: d(a.sizeTitleLarge, b.sizeTitleLarge),
      fieldLabel: s(a.fieldLabel, b.fieldLabel),
      pageTitle: s(a.pageTitle, b.pageTitle),
      heading: s(a.heading, b.heading),
      sectionLabel: s(a.sectionLabel, b.sectionLabel),
      body: s(a.body, b.body),
      bodyStrong: s(a.bodyStrong, b.bodyStrong),
      bodyMuted: s(a.bodyMuted, b.bodyMuted),
      bodySmall: s(a.bodySmall, b.bodySmall),
      caption: s(a.caption, b.caption),
      micro: s(a.micro, b.micro),
      button: s(a.button, b.button),
      mono: s(a.mono, b.mono),
      spec: t < 0.5 ? a.spec : b.spec,
    );
  }
}
