import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';

import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../rules.dart';
import 'compared_name.dart';
import 'finding_body.dart';
import 'shot_image.dart';
import 'stage.dart';
import 'state_chip.dart';

const stepPageKey = Key('comparison.step-page');
const stepBackKey = Key('comparison.step-back');
const stepPreviousKey = Key('comparison.step-previous');
const stepNextKey = Key('comparison.step-next');

/// One step of a flow, pushed over the tree.
///
/// Its own file so it can be a preview entry: the seven shapes of finding it
/// has to render — pixels, tree only, texts only, events only, unchanged,
/// broken, one-sided — are seven different screens, and until they were drawn
/// side by side only the first had ever been looked at. See
/// `docs/superpowers/specs/2026-08-31-comparison-detail-page-design.md`.
class StepPage extends StatelessWidget {
  const StepPage({
    super.key,
    required this.item,
    required this.shots,
    required this.mode,
    required this.onMode,
    required this.onBack,
    this.framesWithheld = false,
    this.onRule,
    this.flow,
    this.position,
    this.onPrevious,
    this.onNext,
  });

  /// The flow this step belongs to, as its id — named under the step's title,
  /// because a page reading only `Menu` could be a step of any of five flows.
  final String? flow;

  /// Where the step sits in its flow: `(1, 11)` for the second of eleven.
  final ({int index, int count})? position;

  /// The steps either side, in the flow's order. Null at an end — and without
  /// them, reading the next step meant going back to the canvas and finding
  /// it there.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  final ComparedItem item;
  final ShotPair shots;
  final StageMode mode;
  final ValueChanged<StageMode> onMode;
  final VoidCallback onBack;

  /// Whether this step's pictures were left out of the page it is being read
  /// from — see [ComparisonIndex.framesWithheldFor]. A step of a flow that is
  /// a finding always has them; a step of a flow that came out identical does
  /// not, on a page written with `--frames=changed`.
  final bool framesWithheld;

  /// See [ChannelLines.onRule].
  final ValueChanged<ComparisonRule>? onRule;

  /// `Step 2 of 11 · Order a cold brew on a laptop`.
  String? get _where {
    var parts = [
      if (position case (:var index, :var count)) 'Step ${index + 1} of $count',
      if (flow case var flow?) comparedName(flow).name,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;

    return Column(
      key: stepPageKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            FwSpacing.md,
            FwSpacing.xl,
            0,
          ),
          child: Row(
            children: [
              Tappable(
                key: stepBackKey,
                onTap: onBack,
                child: Icon(
                  Icons.arrow_back,
                  size: FwIconSize.lg,
                  color: colors.mut,
                ),
              ),
              const Gap(FwSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label ?? item.id,
                      style: context.type.heading,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_where case var where?)
                      Text(
                        where,
                        style: context.type.micro.copyWith(color: colors.mut),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              StateChip(item.state),
              // After the chip, at the edge: the chip's width follows the
              // state, and buttons in front of it moved under the pointer
              // from one step to the next — the second click landed on the
              // other one.
              if (position != null) ...[
                const Gap(FwSpacing.md),
                _StepButton(
                  key: stepPreviousKey,
                  icon: Icons.chevron_left_rounded,
                  tooltip: 'Previous step',
                  onTap: onPrevious,
                ),
                _StepButton(
                  key: stepNextKey,
                  icon: Icons.chevron_right_rounded,
                  tooltip: 'Next step',
                  onTap: onNext,
                ),
              ],
            ],
          ),
        ),
        if (item.note case var note?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xl,
              FwSpacing.xs,
              FwSpacing.xl,
              0,
            ),
            child: Text(
              note,
              style: context.type.caption.copyWith(color: colors.red),
            ),
          ),
        FindingBody(
          item: item,
          shots: shots,
          mode: mode,
          onMode: onMode,
          onRule: onRule,
          whenNotRendered: framesWithheld
              ? FindingBody.framesWithheld(context)
              : null,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;

  /// Null at the end of the flow, which draws the button dimmed.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: Tappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.xxs),
          child: Icon(
            icon,
            size: FwIconSize.lg,
            color: onTap == null ? colors.mut3 : colors.mut,
          ),
        ),
      ),
    );
  }
}
