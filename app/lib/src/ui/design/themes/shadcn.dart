import 'package:flutter/widgets.dart';

import '../palette.dart';
import '../radii.dart';
import '../typography.dart';
import 'fw_theme.dart';

/// shadcn/ui (zinc) — neutral, near-black primary, hairline borders, crisp.
const shadcnPalette = FwPalette(
  accent: Color(0xFF18181B),
  accentDark: Color(0xFF09090B),
  accentSoft: Color(0xFFF4F4F5),
  accentSoft2: Color(0xFFFAFAFA),
  bg: Color(0xFFFFFFFF),
  panel: Color(0xFFFAFAFA),
  panel2: Color(0xFFF4F4F5),
  ink: Color(0xFF09090B),
  ink2: Color(0xFF27272A),
  mut: Color(0xFF71717A),
  mut2: Color(0xFFA1A1AA),
  mut3: Color(0xFFD4D4D8),
  line: Color(0xFFE4E4E7),
  line2: Color(0xFFF4F4F5),
  grn: Color(0xFF16A34A),
  amber: Color(0xFFF59E0B),
  red: Color(0xFFEF4444),
  warningText: Color(0xFF92660A),
  primaryOnMenu: Color(0xFFFAFAFA),
  menuBackground: Color(0xFF18181B),
  menuSecondaryBackground: Color(0xFF27272A),
  dividerDark: Color(0xFF3F3F46),
  tabDivider: Color(0xFFE4E4E7),
  info: Color(0xFF2563EB),
);

const shadcnDarkPalette = FwPalette(
  accent: Color(0xFFFAFAFA),
  accentDark: Color(0xFFD4D4D8),
  accentSoft: Color(0xFF18181B),
  accentSoft2: Color(0xFF27272A),
  bg: Color(0xFF09090B),
  panel: Color(0xFF18181B),
  panel2: Color(0xFF27272A),
  ink: Color(0xFFFAFAFA),
  ink2: Color(0xFFE4E4E7),
  mut: Color(0xFFA1A1AA),
  mut2: Color(0xFF71717A),
  mut3: Color(0xFF52525B),
  line: Color(0xFF27272A),
  line2: Color(0xFF3F3F46),
  grn: Color(0xFF4ADE80),
  amber: Color(0xFFFBBF24),
  red: Color(0xFFF87171),
  warningText: Color(0xFFD9A036),
  primaryOnMenu: Color(0xFFFAFAFA),
  menuBackground: Color(0xFF0C0C0E),
  menuSecondaryBackground: Color(0xFF18181B),
  dividerDark: Color(0xFF27272A),
  tabDivider: Color(0xFF3F3F46),
  info: Color(0xFF60A5FA),
  people: peopleOnDark,
);

/// shadcn/ui — neutral zinc, near-black primary, tight type.
//
// Upstream specified `googleFont: 'Inter'`; the port has no network font
// loading, so this falls back to the platform default unless Inter is bundled.
final shadcnTheme = FwTheme.from(
  name: 'shadcn',
  palette: shadcnPalette,
  dark: shadcnDarkPalette,
  radii: const FwRadii(
    micro: 4,
    radiusSmall: 6,
    radius: 8,
    radiusLarge: 12,
    pill: 999,
  ),
  type: const FwTypeSpec(
    heading: FontWeight.w600,
    strong: FontWeight.w500,
    tracking: -0.2,
  ),
);
