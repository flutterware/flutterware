import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/design/design.dart';
import '../../ui/tappable.dart';

/// The shape every pane in the drawer under the canvas takes: a band of
/// titled columns, side by side, each scrolling on its own.
///
/// The drawer is wide and short — a third of the window's height at most,
/// all of its width. A value pane is one column, the value; a library's
/// modes, tokens and design file are three. Down a column is where a list
/// goes — a token's modes are rows of its value column — and a column
/// outgrowing the band scrolls, the way any properties panel does. The columns always fit the band: a
/// fixed width is a wish, scaled down together when the band is narrower
/// than their sum. Nothing here overflows, and nothing scrolls sideways.
class DrawerPane extends StatelessWidget {
  const DrawerPane({super.key, required this.sections});

  final List<DrawerSection> sections;

  /// What a flexible column asks for when the fixed ones are placed.
  static const minFlexWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      color: colors.panel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          var fixed = 0.0;
          var flexible = 0;
          for (var s in sections) {
            if (s.width case var w?) {
              fixed += w;
            } else {
              flexible++;
            }
          }
          var dividers = math.max(0, sections.length - 1) * 1.0;
          var available = constraints.maxWidth - dividers;
          var flexWidth = flexible == 0
              ? 0.0
              : math.max(minFlexWidth, (available - fixed) / flexible);
          var total = fixed + flexible * flexWidth;
          // Narrower than the wishes: everyone gives up the same share.
          var scale = total > available ? available / total : 1.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var (i, s) in sections.indexed) ...[
                if (i > 0) Container(width: 1, color: colors.line),
                SizedBox(
                  key: s.key,
                  width: (s.width ?? flexWidth) * scale,
                  child: _Section(s),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One column of a [DrawerPane]: a caption, something at its right end,
/// and a body that scrolls when the band is shorter than it.
class DrawerSection {
  const DrawerSection({
    this.title,
    required this.child,
    this.width,
    this.trailing,
    this.key,
  });

  /// Null for a column whose blocks carry their own titles.
  final String? title;
  final Widget child;

  /// Wished for, or null for a share of what is left. Scaled down with
  /// the others when the band is narrower than their sum.
  final double? width;

  /// A link or a word beside the title — `unset`, `same as default`.
  final Widget? trailing;

  final Key? key;
}

class _Section extends StatelessWidget {
  const _Section(this.section);

  final DrawerSection section;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (section.title case var title?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.lg,
              FwSpacing.md,
              FwSpacing.lg,
              FwSpacing.xs,
            ),
            child: DrawerBlockTitle(title, trailing: section.trailing),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              FwSpacing.lg,
              section.title == null ? FwSpacing.md : 0,
              FwSpacing.lg,
              FwSpacing.md,
            ),
            child: section.child,
          ),
        ),
      ],
    );
  }
}

/// A caption over a block, with something at its right end — a section's
/// own title, or one of several blocks down one column.
class DrawerBlockTitle extends StatelessWidget {
  const DrawerBlockTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    var caption = context.type.caption.copyWith(color: context.colors.mut2);
    return Row(
      children: [
        Expanded(
          child: Text(title, overflow: TextOverflow.ellipsis, style: caption),
        ),
        if (trailing case var trailing?) Flexible(child: trailing),
      ],
    );
  }
}

/// A small link in a section's title row — `unset`, `same as default`.
class DrawerLink extends StatelessWidget {
  const DrawerLink(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.caption.copyWith(
      color: onTap == null ? colors.mut3 : colors.accent,
    );
    var text = Text(label, overflow: TextOverflow.ellipsis, style: style);
    if (onTap == null) return text;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xxs),
        child: text,
      ),
    );
  }
}
