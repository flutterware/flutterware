import 'package:material_ui/material_ui.dart';

/// A complete colour palette. One instance per theme; provided to the tree via
/// [FwTokens] and read through `context.colors`. The shipped palettes live with
/// their themes in `themes/`.
@immutable
class FwPalette {
  // primary accent
  final Color accent;
  final Color accentDark;
  final Color accentSoft;
  final Color accentSoft2;

  // surfaces
  final Color bg;
  final Color panel;
  final Color panel2;

  // ── ink / text scale ──
  //
  // Five steps, ranked rather than named for a job, which is the one thing
  // worth knowing about them: a call site picks by feel unless it is told what
  // each step is *for*. So it is told, below, from what the app actually does
  // with them rather than from a taxonomy invented afterwards.
  //
  // Deliberately not re-exposed under role names like `textSecondary`. The
  // palette already tried that during the `AppColors` migration and the
  // evidence is in: `mutedText`, `hairline` and `controlBackground` were added
  // as friendlier aliases and reached **zero** call sites between them. A
  // second vocabulary for the same five colours makes the "are these the same
  // grey?" question harder, not easier.

  /// Primary text, and anything that must be read first.
  final Color ink;

  /// Secondary emphasis that is still ink rather than grey — an active tab's
  /// label, a table header that is the current sort.
  final Color ink2;

  /// The workhorse muted. Captions, field labels, the words of an inactive
  /// control, a running state. If a thing is muted and you have no reason to
  /// pick another step, it is this one — 207 of the 487 muted uses are.
  final Color mut;

  /// One step back from [mut]: provenance and asides. A panel header's
  /// subtitle, a code comment, a keyboard shortcut beside a menu row — present,
  /// and explicitly not competing with the line above it.
  final Color mut2;

  /// The faintest step, for things that must be *visible but never read first*:
  /// an empty state's icon, a spinner, a disabled chevron, a hint under a
  /// field. Text at this weight is decoration; do not put a sentence in it that
  /// the reader needs.
  final Color mut3;

  // lines
  final Color line;
  final Color line2;

  // status
  final Color grn;
  final Color amber;
  final Color red;
  final Color warningText;

  // menu (app chrome)
  final Color primaryOnMenu;
  final Color menuBackground;
  final Color menuSecondaryBackground;
  final Color dividerDark;

  // standalone values the aliases below don't cover
  final Color tabDivider;
  final Color info;

  const FwPalette({
    required this.accent,
    required this.accentDark,
    required this.accentSoft,
    required this.accentSoft2,
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.ink,
    required this.ink2,
    required this.mut,
    required this.mut2,
    required this.mut3,
    required this.line,
    required this.line2,
    required this.grn,
    required this.amber,
    required this.red,
    required this.warningText,
    required this.primaryOnMenu,
    required this.menuBackground,
    required this.menuSecondaryBackground,
    required this.dividerDark,
    required this.tabDivider,
    required this.info,
  });

  // Derived names that carry their own meaning — a status word rather than a
  // second spelling of a colour.
  //
  // The compatibility aliases from the `AppColors` migration are gone:
  // `mutedText`, `hairline` and `controlBackground` had no call sites at all,
  // and `textGrey`/`textSteal` had four between them, all now reading `mut` and
  // `ink` directly. They were a bridge, and the far side has been reached.
  Color get primary => accent;
  Color get scaffoldBackground => panel;
  Color get danger => red;
  Color get warning => amber;
  Color get success => grn;
  Color get divider => line2;
  Color get tableHeader => panel2;

  /// Contrast colour for content on a [primary] fill — white on dark primaries,
  /// a near-black on light ones. Must contrast with [primary] itself, not track
  /// the theme's [ink] (which is light in dark themes, giving white-on-white for
  /// a light primary).
  Color get onPrimary =>
      ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
      ? const Color(0xFFFFFFFF)
      : const Color(0xFF18181B);

  /// Brightness inferred from [bg] — drives the Material [colorScheme] and lets
  /// the same palette shape serve a light or a dark theme.
  Brightness get brightness => ThemeData.estimateBrightnessForColor(bg);

  // ── interaction & focus ── (interactive surfaces read these instead of
  // hardcoding overlay alphas)
  /// Tint laid over a light surface on hover / press.
  Color get hoverOverlay => ink.withValues(alpha: 0.05);
  Color get pressedOverlay => ink.withValues(alpha: 0.10);

  /// Primary-tinted hover / press wash — the *link* affordance, as opposed to
  /// the neutral [hoverOverlay] used by controls. A touch stronger than the
  /// neutral pair since a saturated tint reads fainter.
  Color get primaryHoverOverlay => primary.withValues(alpha: 0.08);
  Color get primaryPressedOverlay => primary.withValues(alpha: 0.14);

  /// Tint laid over a dark or [primary] fill on hover / press.
  Color get hoverOverlayOnFill => const Color(0x24FFFFFF);
  Color get pressedOverlayOnFill => const Color(0x3DFFFFFF);

  /// Keyboard-focus ring colour.
  Color get focusRing => primary.withValues(alpha: 0.3);

  /// The wash behind the characters a filter matched. Derived from [amber]
  /// rather than authored per theme, and see-through, so it reads as a
  /// highlighter drawn over the row instead of a second background colour.
  ///
  /// A token because every list that filters lights its matches the same
  /// yellow, and four call sites picking their own alpha is how they stopped
  /// looking the same.
  Color get searchMark => amber.withValues(alpha: 0.35);

  // ── status surfaces ── (soft fill / border derived from a status accent like
  // [grn]/[amber]/[red]/[info], so themes only author the accent)
  Color statusFill(Color accent) => Color.lerp(accent, bg, 0.88)!;
  Color statusBorder(Color accent) => Color.lerp(accent, bg, 0.62)!;

  /// Material scheme derived from this palette — light or dark per [brightness].
  ColorScheme get colorScheme {
    var base = brightness == Brightness.dark
        ? const ColorScheme.dark()
        : const ColorScheme.light();
    return base.copyWith(
      primary: primary,
      secondary: primary,
      surface: bg,
      error: danger,
      onPrimary: onPrimary,
      onSecondary: onPrimary,
      onSurface: mut,
      onError: const Color(0xFFFFFFFF),
    );
  }

  FwPalette copyWith({
    Color? accent,
    Color? accentDark,
    Color? accentSoft,
    Color? accentSoft2,
    Color? bg,
    Color? panel,
    Color? panel2,
    Color? ink,
    Color? ink2,
    Color? mut,
    Color? mut2,
    Color? mut3,
    Color? line,
    Color? line2,
    Color? grn,
    Color? amber,
    Color? red,
    Color? warningText,
    Color? primaryOnMenu,
    Color? menuBackground,
    Color? menuSecondaryBackground,
    Color? dividerDark,
    Color? tabDivider,
    Color? info,
  }) {
    return FwPalette(
      accent: accent ?? this.accent,
      accentDark: accentDark ?? this.accentDark,
      accentSoft: accentSoft ?? this.accentSoft,
      accentSoft2: accentSoft2 ?? this.accentSoft2,
      bg: bg ?? this.bg,
      panel: panel ?? this.panel,
      panel2: panel2 ?? this.panel2,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      mut: mut ?? this.mut,
      mut2: mut2 ?? this.mut2,
      mut3: mut3 ?? this.mut3,
      line: line ?? this.line,
      line2: line2 ?? this.line2,
      grn: grn ?? this.grn,
      amber: amber ?? this.amber,
      red: red ?? this.red,
      warningText: warningText ?? this.warningText,
      primaryOnMenu: primaryOnMenu ?? this.primaryOnMenu,
      menuBackground: menuBackground ?? this.menuBackground,
      menuSecondaryBackground:
          menuSecondaryBackground ?? this.menuSecondaryBackground,
      dividerDark: dividerDark ?? this.dividerDark,
      tabDivider: tabDivider ?? this.tabDivider,
      info: info ?? this.info,
    );
  }

  static FwPalette lerp(FwPalette a, FwPalette b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t)!;
    return FwPalette(
      accent: c(a.accent, b.accent),
      accentDark: c(a.accentDark, b.accentDark),
      accentSoft: c(a.accentSoft, b.accentSoft),
      accentSoft2: c(a.accentSoft2, b.accentSoft2),
      bg: c(a.bg, b.bg),
      panel: c(a.panel, b.panel),
      panel2: c(a.panel2, b.panel2),
      ink: c(a.ink, b.ink),
      ink2: c(a.ink2, b.ink2),
      mut: c(a.mut, b.mut),
      mut2: c(a.mut2, b.mut2),
      mut3: c(a.mut3, b.mut3),
      line: c(a.line, b.line),
      line2: c(a.line2, b.line2),
      grn: c(a.grn, b.grn),
      amber: c(a.amber, b.amber),
      red: c(a.red, b.red),
      warningText: c(a.warningText, b.warningText),
      primaryOnMenu: c(a.primaryOnMenu, b.primaryOnMenu),
      menuBackground: c(a.menuBackground, b.menuBackground),
      menuSecondaryBackground: c(
        a.menuSecondaryBackground,
        b.menuSecondaryBackground,
      ),
      dividerDark: c(a.dividerDark, b.dividerDark),
      tabDivider: c(a.tabDivider, b.tabDivider),
      info: c(a.info, b.info),
    );
  }

  /// Returns this palette rebranded with [seed] as the primary colour; the
  /// dark / soft / on-menu shades are recomputed from the seed via HSL.
  FwPalette branded(Color seed) {
    var hsl = HSLColor.fromColor(seed);
    Color tint(double amount) =>
        Color.lerp(seed, const Color(0xFFFFFFFF), amount)!;
    return copyWith(
      accent: seed,
      accentDark: hsl
          .withLightness((hsl.lightness * 0.82).clamp(0.0, 1.0))
          .toColor(),
      accentSoft: tint(0.90),
      accentSoft2: tint(0.95),
      primaryOnMenu: tint(0.35),
    );
  }
}
