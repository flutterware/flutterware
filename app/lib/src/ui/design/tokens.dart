import 'package:material_ui/material_ui.dart';

import 'elevation.dart';
import 'palette.dart';
import 'radii.dart';
import 'themes/flutter_blue.dart';
import 'typography.dart';

/// The complete set of themeable design tokens, carried on [ThemeData] as a
/// [ThemeExtension]. Read through the `context.colors` / `context.radii` /
/// `context.type` accessors below; switch themes by building a [ThemeData] with
/// a different [FwTokens] (see `buildAppTheme`).
@immutable
class FwTokens extends ThemeExtension<FwTokens> {
  final FwPalette palette;
  final FwRadii radii;
  final FwTypography typography;
  final FwElevation elevation;

  const FwTokens({
    required this.palette,
    required this.radii,
    required this.typography,
    required this.elevation,
  });

  /// Builds a token set from a [palette], with optional [radii], typography
  /// [type] spec, and [elevation]. Typography colours are derived from the
  /// palette so they stay in sync.
  factory FwTokens.from({
    required FwPalette palette,
    FwRadii? radii,
    FwTypeSpec? type,
    FwElevation? elevation,
  }) {
    return FwTokens(
      palette: palette,
      radii: radii ?? defaultRadii,
      typography: FwTypography.from(palette, type ?? const FwTypeSpec()),
      elevation: elevation ?? defaultElevation,
    );
  }

  /// Rebrands this token set: [seed] becomes the primary colour and its
  /// dark/soft/on-menu shades are recomputed from it. Surfaces, ink, status,
  /// radii and typography are untouched.
  FwTokens branded(Color seed) => copyWith(palette: palette.branded(seed));

  @override
  FwTokens copyWith({
    FwPalette? palette,
    FwRadii? radii,
    FwTypography? typography,
    FwElevation? elevation,
  }) {
    return FwTokens(
      palette: palette ?? this.palette,
      radii: radii ?? this.radii,
      typography: typography ?? this.typography,
      elevation: elevation ?? this.elevation,
    );
  }

  @override
  FwTokens lerp(ThemeExtension<FwTokens>? other, double t) {
    if (other is! FwTokens) return this;
    return FwTokens(
      palette: FwPalette.lerp(palette, other.palette, t),
      radii: FwRadii.lerp(radii, other.radii, t),
      typography: FwTypography.lerp(typography, other.typography, t),
      elevation: FwElevation.lerp(elevation, other.elevation, t),
    );
  }
}

/// The default (Flutter blue) token set.
final defaultTokens = FwTokens.from(palette: flutterBluePalette);

/// Its dark counterpart. Same radii, type and elevation — only the palette
/// differs, which is what keeps the two from drifting apart.
final darkTokens = FwTokens.from(palette: flutterBlueDarkPalette);

extension FwTokensContext on BuildContext {
  /// All design tokens for the active theme.
  FwTokens get tokens => Theme.of(this).extension<FwTokens>() ?? defaultTokens;

  /// The active colour palette. `context.colors.accent`, …
  FwPalette get colors => tokens.palette;

  /// The active corner radii. `context.radii.radius`, …
  FwRadii get radii => tokens.radii;

  /// The active typography. `context.type.body`, …
  FwTypography get type => tokens.typography;

  /// The active shadow set. `context.elevation.md`, …
  FwElevation get elevation => tokens.elevation;
}
