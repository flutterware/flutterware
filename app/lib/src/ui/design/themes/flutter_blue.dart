import 'package:flutter/widgets.dart';

import '../palette.dart';
import 'fw_theme.dart';

/// Flutter blue — the default look, and the palette behind `defaultTokens`.
///
/// The accents are Flutter's own brand blues rather than an invented hue:
/// `#0553b1` is the blue flutter.dev uses for interactive text, and `#42a5f5`
/// its lighter sibling, which is what the dark palette leans on. [info] stays a
/// distinctly lighter sky, so an in-progress status never reads as a selection.
const flutterBluePalette = FwPalette(
  accent: Color(0xFF0553b1),
  accentDark: Color(0xFF04407f),
  accentSoft: Color(0xFFe7f0fb),
  accentSoft2: Color(0xFFf2f7fd),
  bg: Color(0xFFffffff),
  panel: Color(0xFFf7f8fa),
  panel2: Color(0xFFfbfbfa),
  ink: Color(0xFF15181d),
  ink2: Color(0xFF3a3d43),
  mut: Color(0xFF6b7280),
  mut2: Color(0xFF9aa1ac),
  mut3: Color(0xFFc4c7cd),
  line: Color(0xFFe8eaee),
  line2: Color(0xFFf0f1f4),
  grn: Color(0xFF2f9e63),
  amber: Color(0xFFcf8a00),
  red: Color(0xFFd24b3e),
  warningText: Color(0xFF9a6700),
  primaryOnMenu: Color(0xFF42a5f5),
  menuBackground: Color(0xFF0b1d32),
  menuSecondaryBackground: Color(0xFF182a41),
  dividerDark: Color(0xFF243447),
  tabDivider: Color(0xFFc5cfdc),
  info: Color(0xFF4eabfb),
);

const flutterBlueDarkPalette = FwPalette(
  accent: Color(0xFF42a5f5),
  accentDark: Color(0xFF027dfd),
  accentSoft: Color(0xFF152b40),
  accentSoft2: Color(0xFF1b3550),
  bg: Color(0xFF15171f),
  panel: Color(0xFF1c1f29),
  panel2: Color(0xFF222633),
  ink: Color(0xFFecedf2),
  ink2: Color(0xFFcdcfd9),
  mut: Color(0xFF9a9dad),
  mut2: Color(0xFF73768a),
  mut3: Color(0xFF565a6e),
  line: Color(0xFF2a2e3c),
  line2: Color(0xFF383d4f),
  grn: Color(0xFF6fd68a),
  amber: Color(0xFFe6b450),
  red: Color(0xFFf07171),
  warningText: Color(0xFFcb983b),
  primaryOnMenu: Color(0xFF42a5f5),
  menuBackground: Color(0xFF191b24),
  menuSecondaryBackground: Color(0xFF1f2230),
  dividerDark: Color(0xFF2a2e3c),
  tabDivider: Color(0xFF383d4f),
  info: Color(0xFF13b9fd),
  people: peopleOnDark,
);

final flutterBlueTheme = FwTheme.from(
  name: 'Flutter blue',
  palette: flutterBluePalette,
  dark: flutterBlueDarkPalette,
);
