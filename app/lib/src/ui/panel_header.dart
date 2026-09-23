import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// The gutter every panel indents its content by.
///
/// Named because the header is not the only thing that has to sit on it: a body
/// padded differently from its own title is the misalignment this constant
/// exists to make impossible. Measured before it was chosen — three panels were
/// already on 24, two had drifted to 32 and 8.
const panelGutter = FwSpacing.xxl;

/// The top of a panel: what is being looked at, and what can be done to it.
///
/// The title names what varies, never the plugin. The rail already says
/// "Splash screen"; repeating it here spends the largest type on the one thing
/// the reader already knows. What varies is which package, which worktree,
/// which dependency — so that is what the eye should land on. The rule is the
/// splash panel's, which arrived at it first and alone; this is that doctrine
/// made reusable rather than a new one.
///
/// A view: every value arrives as data and every action leaves as a callback.
///
/// Panels were each answering this independently, and the drift was measurable
/// rather than a matter of taste — three content gutters (8, 12 and 24 px) and
/// two title baselines four pixels apart, between panels that are otherwise the
/// same shape. One widget settles both, because the padding is no longer
/// something a panel decides.
class FwPanelHeader extends StatelessWidget {
  const FwPanelHeader(
    this.title, {
    super.key,
    this.badge,
    this.subtitle = const [],
    this.selectableSubtitle = false,
    this.trailing,
    this.below,
    this.toolbar,
  });

  /// The subject, in the largest type on the screen. Ellipsised rather than
  /// wrapped: it is the one thing here with no natural bound — a nested example
  /// package is as long as its directories — and it yields before the badge and
  /// the actions beside it, which are short and fixed.
  final String title;

  /// A pill beside the title — a state, a count. Sits with the title rather
  /// than at the far right of the row, where a wide window strands it a screen
  /// away from the thing it describes.
  final Widget? badge;

  /// Provenance, joined with a middot: which file, read when, from where.
  /// Empty for a panel whose title says it all.
  final List<String> subtitle;

  /// Renders [subtitle] selectable. For a path — the thing most likely to be
  /// wanted in a terminal a moment later.
  final bool selectableSubtitle;

  /// Actions, at the right of the title line. Aligned to the title rather than
  /// to the block, so a button sits beside the words it acts on instead of
  /// floating against a subtitle it has nothing to do with.
  final Widget? trailing;

  /// Extra header content under the subtitle — chips, a flavor picker.
  final Widget? below;

  /// A full-width strip under the header block, for controls that belong to the
  /// panel rather than to its subject.
  final Widget? toolbar;

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    var colors = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            panelGutter,
            FwSpacing.xl,
            panelGutter,
            FwSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // One Expanded holding title + badge, rather than a Flexible
                  // title and a Spacer: two flex children split the free space
                  // between them, which parked the trailing actions in the
                  // middle of a wide panel with a phantom gap on their right.
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: type.pageTitle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (badge != null) ...[const Gap(FwSpacing.lg), badge!],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[const Gap(FwSpacing.lg), trailing!],
                ],
              ),
              if (subtitle.isNotEmpty) ...[
                const Gap(FwSpacing.xs),
                _subtitle(context, colors),
              ],
              if (below != null) ...[const Gap(FwSpacing.lg), below!],
            ],
          ),
        ),
        ?toolbar,
      ],
    );
  }

  Widget _subtitle(BuildContext context, FwPalette colors) {
    var text = subtitle.join('  ·  ');
    var style = context.type.caption.copyWith(color: colors.mut2);
    return selectableSubtitle
        ? SelectableText(text, style: style)
        : Text(text, style: style);
  }
}
