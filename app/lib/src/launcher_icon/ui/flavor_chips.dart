/// The row of icon sets above the plates.
///
/// Its own file because a chip stopped being a label. A set arrives with the
/// evidence for it, and the row's job is to say which ones you can go and
/// read — a chip for an ungenerated one has to be visibly different from one
/// that is there, or the row invites a click into an empty panel.
///
/// **These are icon sets, not the project's flavor list**, and the row says so
/// because the difference bit a real project. A set is discovered from files —
/// a `flutter_launcher_icons-<name>.yaml`, an `android/app/src/<name>/`, an
/// `AppIcon-<name>.appiconset` — and that spelling is `flutter_launcher_icons`'
/// convention rather than a rule of Gradle or Xcode. A project that writes the
/// wiring itself can point four product flavors at one `src/<name>/res` through
/// a `sourceSets` block and point all four configurations'
/// `ASSETCATALOG_COMPILER_APPICON_NAME` at one catalog; then `<name>` is an
/// icon set that several flavors share and not a flavor anybody can build. The
/// real list lives in Gradle and in Xcode schemes, which is two parsers this
/// panel does not have — so it reports what it can prove, which is the files,
/// and every chip carries them in its tooltip rather than asserting more than
/// it read.
library;

import 'package:material_ui/material_ui.dart';

import '../../ui/design/design.dart';
import '../../ui/theme.dart';
import '../model/scan.dart';

/// Every icon set the package has, with the unflavored one in front.
///
/// `main` leads because it is what the panel shows when the address names no
/// set, and a row that opened with `dev` would read as though `dev` were the
/// project's own default.
class FlavorChips extends StatelessWidget {
  const FlavorChips({
    super.key,
    required this.flavors,
    this.selected,
    this.onSelect,
  });

  final List<IconFlavor> flavors;

  /// The set the panel is showing, or null for the unflavored one.
  final String? selected;

  /// Goes to that set's files; null for the unflavored one. A row that only
  /// *reported* the sets left the address bar as the one way to reach the
  /// others, which is no way at all.
  final ValueChanged<String?>? onSelect;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Icon sets', style: context.type.sectionLabel),
        const Gap(FwSpacing.md),
        Wrap(
          spacing: FwSpacing.sm,
          runSpacing: FwSpacing.sm,
          children: [
            _Chip(
              label: 'main',
              selected: selected == null,
              onTap: onSelect == null ? null : () => onSelect!(null),
              hint: mainHint,
            ),
            for (var flavor in flavors)
              _Chip(
                label: flavor.name,
                selected: flavor.name == selected,
                // Selectable even with nothing generated: what the panel says
                // behind an ungenerated set — no files, for a config that
                // exists — is the answer, not a dead end.
                onTap: onSelect == null ? null : () => onSelect!(flavor.name),
                // A set with nothing generated is still worth a chip — it is
                // how you find out the config exists at all — but it must not
                // look like one there is something to see behind.
                //
                // Said in words rather than drawn. The first attempt muted the
                // label and thinned the border, which in a screenshot of the
                // row was indistinguishable from the chip beside it; a suffix
                // survives being small, being greyscale, and not being
                // hovered.
                note: flavor.isUnbuilt ? 'not generated' : null,
                hint: flavorHint(flavor),
              ),
          ],
        ),
        const Gap(FwSpacing.sm),
        Text(
          'Named by the files on disk — Gradle and Xcode decide which build '
          'uses which.',
          style: context.type.caption.copyWith(color: colors.mut2),
        ),
      ],
    );
  }
}

/// What the unflavored chip stands for.
const mainHint =
    'android/app/src/main/res/ and the AppIcon asset catalog — what a build '
    'that overrides neither uses.';

/// What is behind a set, for the chip's tooltip.
///
/// On every chip now, which reverses the rule this started with. The rule was
/// right about *warnings* — a caution on every chip is a caution nobody
/// reads — and wrong about evidence: a chip that names a directory as though
/// it named a flavor is a claim, and the files are what turns it back into a
/// fact. The caution still only appears when there is one.
String? flavorHint(IconFlavor flavor) {
  var found = [
    if (flavor.has(IconFlavorSource.config))
      'flutter_launcher_icons-${flavor.name}.yaml',
    if (flavor.has(IconFlavorSource.androidSourceSet))
      'android/app/src/${flavor.name}/',
    if (flavor.has(IconFlavorSource.iosCatalog))
      'AppIcon-${flavor.name}.appiconset',
  ];
  var evidence = 'Found: ${found.join(', ')}.';

  if (flavor.isUnbuilt) {
    return '$evidence Nothing has been generated for it yet.';
  }
  var missing = [
    if (!flavor.has(IconFlavorSource.androidSourceSet))
      'no android/app/src/${flavor.name}/',
    if (!flavor.has(IconFlavorSource.iosCatalog))
      'no AppIcon-${flavor.name}.appiconset',
  ];
  if (missing.isEmpty) return evidence;
  return '$evidence Generated for one platform only — ${missing.join(' and ')}. '
      'The other platform falls back to the unflavored set.';
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    this.note,
    this.hint,
    this.onTap,
  });

  final String label;
  final bool selected;

  final VoidCallback? onTap;

  /// A muted qualifier after the name, for a chip with nothing behind it.
  final String? note;

  final String? hint;

  @override
  Widget build(BuildContext context) {
    var chip = _build(context);
    return hint == null ? chip : Tooltip(message: hint!, child: chip);
  }

  Widget _build(BuildContext context) {
    var colors = context.colors;
    var radius = BorderRadius.circular(context.radii.pill);
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: _label(context, colors, radius),
    );
  }

  Widget _label(BuildContext context, FwPalette colors, BorderRadius radius) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: selected ? colors.accentSoft : colors.panel2,
        borderRadius: radius,
        border: Border.all(color: selected ? colors.accent : colors.line),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: label),
            if (note != null)
              TextSpan(
                text: '  ·  $note',
                style: TextStyle(color: colors.mut),
              ),
          ],
        ),
        style: context.type.caption,
      ),
    );
  }
}
