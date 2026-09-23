import 'dart:async';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../plugins/native/scenarios_results.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'motion_player.dart';
import 'step_status.dart';

/// The way out of a step, in both directions: the step it came from at the
/// bottom left, everything it leads to stacked at the bottom right.
///
/// Dropped over whatever a step is drawn as — a framed screenshot, a document
/// sheet, a notification banner — so a reader pressing next walks the whole
/// run without going back to the flow, and does not hit a wall on the beat in
/// the middle of it. One widget rather than one per page: a link that looked
/// or behaved differently on a document than on a screen would be a seam in
/// the middle of the walk.
///
/// Meant for a [Stack]: it fills, but only the links themselves take a
/// pointer, so the picker underneath keeps the rest of the surface.
class ScenarioStepLinks extends StatefulWidget {
  const ScenarioStepLinks({
    super.key,
    required this.steps,
    required this.step,
    required this.onOpenStep,
    this.onPreview,
  });

  final List<ScenarioRunStep> steps;
  final ScenarioRunStep step;
  final void Function(ScenarioRunStep) onOpenStep;

  /// Called with the step the pointer is over, and null when it leaves — so
  /// the surface underneath can show what pressing that link would do. Only
  /// for a next: a back link goes where the reader has already been.
  final ValueChanged<ScenarioRunStep?>? onPreview;

  @override
  State<ScenarioStepLinks> createState() => _ScenarioStepLinksState();
}

class _ScenarioStepLinksState extends State<ScenarioStepLinks> {
  /// The recording warmed ahead, so a rebuild does not start the loop again.
  String? _warmed;

  // `didChangeDependencies`, not `initState`: precaching reads the artifacts
  // off an inherited widget, which cannot be depended on before the first
  // build.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmAhead();
  }

  @override
  void didUpdateWidget(ScenarioStepLinks old) {
    super.didUpdateWidget(old);
    _warmAhead();
  }

  /// Decodes the frames of the step this one leads to, while the reader is
  /// still on this one.
  ///
  /// What makes a walk play: a step arrived at plays only what is already
  /// decoded, and the first pass over a recording is the one that decodes it.
  /// Here rather than on the page, because the page that most needs it is the
  /// one with no recording of its own — a document or a notification, where
  /// nothing else would have warmed the screen on the far side of it.
  ///
  /// Only a lone next. A split's branches are a whole recording each and four
  /// of them do not fit in the residency; they warm on hover instead, where
  /// the pointer says which one.
  void _warmAhead() {
    var (_, nexts) = scenarioNeighbours(widget.steps, widget.step);
    if (nexts.length != 1) return;
    var next = nexts.single;
    if (next.frames == null || next.frames == _warmed) return;
    _warmed = next.frames;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(precacheScenarioMotion(context, next));
    });
  }

  /// How wide one link may be.
  ///
  /// Measured off the surface the links are dropped over rather than a
  /// `LayoutBuilder`: this fills a [Stack] whose size is the picture's, and
  /// the number wanted is *that* width. Half of it each when both a back and
  /// a next are on the line, and never the whole of it even alone — a link
  /// that reached both edges would read as a bar rather than a button.
  double _room(BuildContext context, {required bool hasBoth}) {
    var width = (context.findRenderObject() as RenderBox?)?.size.width;
    if (width == null || !width.isFinite || width <= 0) {
      width = MediaQuery.sizeOf(context).width;
    }
    return hasBoth ? (width - FwSpacing.md) / 2 : width * 0.8;
  }

  @override
  Widget build(BuildContext context) {
    var (previous, nexts) = scenarioNeighbours(widget.steps, widget.step);
    // **A link is bounded or it is not a link.** `Positioned` anchored on one
    // side hands its child unbounded width, and a step is named by whatever
    // named it — a scenario's own sentence, or the verb and target derived
    // from the source. Either can be long, and unbounded meant the button
    // grew to fit rather than the label shrinking: one link ran the width of
    // the page and pushed the other off it. Both sit on the same line, so
    // neither may have more than its share of it.
    var room = _room(context, hasBoth: previous != null && nexts.isNotEmpty);
    return Stack(
      children: [
        if (previous != null)
          Positioned(
            left: 0,
            bottom: 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: room),
              child: _StepLink(
                previous,
                isNext: false,
                onTap: () => widget.onOpenStep(previous),
              ),
            ),
          ),
        // Stacked, because a `split` gives one step several nexts and offering
        // only the first would hide whole branches behind the flow canvas.
        if (nexts.isNotEmpty)
          Positioned(
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var (position, next) in nexts.indexed) ...[
                  if (position > 0) const Gap(FwSpacing.xs),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: room),
                    child: _StepLink(
                      next,
                      isNext: true,
                      // What tells one branch of a split from another — their
                      // steps are as likely as not to be named the same thing.
                      showBranch: nexts.length > 1,
                      onTap: () => widget.onOpenStep(next),
                      onPreview: widget.onPreview,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Where a step leads: its parent, and every step that follows it.
///
/// Walks the graph, not the emission order — so inside a split branch the
/// links stay on the branch, and a `split` itself offers *all* of its
/// branches rather than whichever one the harness happened to capture first.
/// The children come back in the order the run recorded them, which is the
/// order the scenario declared its branches in. Parentless data (older
/// artifacts) falls back to the list order the page used to walk.
(ScenarioRunStep?, List<ScenarioRunStep>) scenarioNeighbours(
  List<ScenarioRunStep> steps,
  ScenarioRunStep step,
) {
  if (steps.any((s) => s.parent != null)) {
    return (
      steps.firstWhereOrNull((s) => s.index == step.parent),
      [
        for (var candidate in steps)
          if (candidate.parent == step.index) candidate,
      ],
    );
  }
  var position = steps.indexWhere((s) => s.index == step.index);
  return (
    position > 0 ? steps[position - 1] : null,
    [if (position >= 0 && position + 1 < steps.length) steps[position + 1]],
  );
}

class _StepLink extends StatelessWidget {
  const _StepLink(
    this.step, {
    required this.isNext,
    required this.onTap,
    this.showBranch = false,
    this.onPreview,
  });

  final ScenarioRunStep step;
  final bool isNext;
  final VoidCallback onTap;

  /// Whether to lead with the `split` branch this step opens — only worth the
  /// room when there is another branch beside it to be told apart from.
  final bool showBranch;

  /// See [ScenarioStepLinks.onPreview].
  final ValueChanged<ScenarioRunStep?>? onPreview;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var branch = showBranch ? step.branch : null;
    var label = '${step.index} · ${scenarioStepLabel(step)}';
    return Tappable(
      onTap: onTap,
      // The pointer arrives before the press, and decoding a recording takes
      // less time than a reader takes to aim — so a branch hovered is a
      // branch that plays when it opens. This is the whole warm for a split,
      // where warming every branch up front would not fit; for a lone next
      // it just makes sure of what the page already warmed ahead. Nothing
      // warms a *previous* link: walking back rests, and pixels decoded for
      // it would push a recording somebody is about to watch out of the
      // residency.
      onHover: isNext
          ? (over) {
              if (over) unawaited(precacheScenarioMotion(context, step));
              onPreview?.call(over ? step : null);
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.sm,
        ),
        color: colors.bg.withValues(alpha: 0.9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isNext)
              Icon(
                Icons.arrow_back_ios,
                size: FwIconSize.xs,
                color: colors.mut,
              ),
            if (branch != null) ...[
              Text(
                branch,
                style: context.type.caption.copyWith(color: colors.accent),
              ),
              const Gap(FwSpacing.xs),
            ],
            // Flexible, single line, ellipsis — and the whole label one
            // hover away, because truncating the only thing that says which
            // step this is would trade one unusable link for another.
            Flexible(
              child: Tooltip(
                message: label,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: context.type.caption.copyWith(
                    color: scenarioStepTone(context, step),
                  ),
                ),
              ),
            ),
            if (isNext)
              Icon(
                Icons.arrow_forward_ios,
                size: FwIconSize.xs,
                color: colors.mut,
              ),
          ],
        ),
      ),
    );
  }
}
