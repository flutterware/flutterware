import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'tappable.dart';
import 'theme.dart';

/// How much room a tree spends per row.
///
/// Two, and the difference is what each tree is for rather than a preference.
/// A catalog rail holds hundreds of entries and is read by scanning, so it is
/// [dense]. An asset row carries a filename over its directory, or a size over
/// a variant count, so it is [roomy] and could not be 26 pixels tall if it
/// wanted to be.
enum TreeRowDensity {
  /// 26px, 14px per level. The catalog rail's.
  dense(height: 26, indent: 14, gap: 0),

  /// Two lines' worth, 16px per level. The asset tree's.
  roomy(height: null, indent: FwSpacing.xl, gap: FwSpacing.md);

  const TreeRowDensity({
    required this.height,
    required this.indent,
    required this.gap,
  });

  /// A fixed row height, or null to let the content and the padding decide.
  final double? height;

  final double indent;

  /// Between the leading slot, the label and each trailing widget.
  final double gap;
}

/// One row of a tree: indented to its depth, selectable, and — for a branch —
/// foldable by a control that does nothing else.
///
/// **Selecting, not toggling.** The row and the chevron do one thing each: the
/// row picks what the pane beside the tree shows, the chevron folds. A row that
/// did both meant one click with two results and no way to ask for either
/// alone. The catalog tree worked this out first and wrote it down; the asset
/// tree shipped the other way for a day and was wrong there for the same
/// reason. This is the one place it is now decided, which is the point of the
/// widget: the metrics are two ([TreeRowDensity]) because the trees really are
/// different sizes, and the *contract* is one because they are not different
/// controls.
///
/// The chevron is a smaller target than the whole row, which is the price of
/// the row meaning one thing. It is affordable because folding stopped being
/// how you look inside a folder — selecting it shows you, and the filter finds
/// by name — so what is left for the chevron is tidying a tree you are done
/// with.
///
/// [Tappable] rather than [InkWell], and not as a preference: these rows are
/// drawn on a panel's opaque fill, and Material ink paints *below* its child,
/// so an ink hover lands underneath the very thing it is meant to answer for.
/// A selected row hides it twice, having a fill of its own.
class FwTreeRow extends StatelessWidget {
  const FwTreeRow({
    super.key,
    required this.depth,
    required this.label,
    this.leading,
    this.trailing = const [],
    this.open,
    this.onToggleFold,
    this.onTap,
    this.selected = false,
    this.density = TreeRowDensity.roomy,
  });

  /// How deep this row sits. Only the indent depends on it.
  final int depth;

  /// The words. A [Widget] rather than a string because a tree that filters
  /// marks the characters that matched, and each marks them its own way — a
  /// subsequence here, a substring there.
  final Widget label;

  /// The icon slot. Ignored for a branch, whose slot holds the chevron: one
  /// slot, so a branch's label and the labels beneath it start at the same x.
  /// Null on a leaf reserves the width anyway, so a file beside a folder is
  /// indented to match rather than sitting under it.
  final Widget? leading;

  /// Counts, sizes, badges — whatever the row is worth saying at its end.
  final List<Widget> trailing;

  /// Whether this branch is open, or null for a leaf. Null is also what decides
  /// there is no chevron.
  final bool? open;

  final VoidCallback? onToggleFold;
  final VoidCallback? onTap;

  /// Whether this row is what the pane beside the tree is showing.
  final bool selected;

  final TreeRowDensity density;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var row = Row(
      spacing: density.gap,
      children: [
        if (open case var open?)
          // Its own target inside the row's. The inner detector is deeper in
          // the tree, so it wins the tap and the chevron never also selects.
          Tappable(
            onTap: onToggleFold,
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.xxs,
                vertical: FwSpacing.xs,
              ),
              child: Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: FwIconSize.sm,
                color: selected ? colors.accentDark : colors.mut,
              ),
            ),
          )
        else
          leading ?? const SizedBox(width: FwIconSize.sm + FwSpacing.xs),
        Expanded(child: label),
        ...trailing,
      ],
    );

    return Tappable(
      onTap: onTap,
      child: Container(
        color: selected ? colors.accentSoft : null,
        padding: EdgeInsets.only(
          left: FwSpacing.md + depth * density.indent,
          right: FwSpacing.md,
          top: density.height == null ? FwSpacing.sm : 0,
          bottom: density.height == null ? FwSpacing.sm : 0,
        ),
        child: density.height == null
            ? row
            : SizedBox(height: density.height, child: row),
      ),
    );
  }
}
