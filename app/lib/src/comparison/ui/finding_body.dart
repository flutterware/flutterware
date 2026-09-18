import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';

import '../../ui/tappable.dart';
import '../rules.dart';
import '../../ui/theme.dart';
import 'channel_lines.dart';
import 'compared_name.dart';
import 'shot_image.dart';
import 'stage.dart';

/// The frames and the finding, for whichever half is asking.
///
/// **One copy, and that is the point.** The two halves each had their own —
/// `StepPage` for a scenario step, `_Detail` for a preview entry — laid out
/// identically and drifting independently. Teaching the page to lead with
/// whatever changed therefore fixed the scenarios half and left the previews
/// half exactly as it was, which is the failure mode a second copy exists to
/// produce. Design:
/// `docs/superpowers/specs/2026-08-31-comparison-detail-page-design.md`.
///
/// **The page leads with whatever changed.** When the pixels moved, that is
/// the pictures and this is the layout it has always had. When they did not,
/// two identical frames were taking 60% of the height and the finding was a
/// footnote — a `200 → 500` drawn smaller than the picture that did not
/// change.
class FindingBody extends StatelessWidget {
  const FindingBody({
    super.key,
    required this.item,
    required this.shots,
    required this.mode,
    required this.onMode,
    this.whenNotRendered,
    this.onRule,
  });

  final ComparedItem item;
  final ShotPair shots;
  final StageMode mode;
  final ValueChanged<StageMode> onMode;

  /// See [ChannelLines.onRule] — hides what a delta row shows, from the row.
  final ValueChanged<ComparisonRule>? onRule;

  /// What to draw instead of frames for an entry nothing rendered — a skipped
  /// preview has no pictures and never will, and that is not a failed decode.
  final Widget? whenNotRendered;

  /// The sentence for a row whose pictures this **export** left out.
  ///
  /// A different absence from [whenNotRendered]'s and the difference matters:
  /// nothing was skipped and nothing failed, the two sides rendered and came
  /// out identical, and a page carrying only the findings' frames simply did
  /// not bring them. Saying "neither side rendered" over that is the page
  /// contradicting its own verdict.
  static Widget framesWithheld(BuildContext context) {
    var colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hide_image_outlined,
              size: FwIconSize.lg,
              color: colors.mut2,
            ),
            const Gap(FwSpacing.md),
            Text('Identical, and not exported', style: context.type.bodyStrong),
            const Gap(FwSpacing.sm),
            Text(
              'Both sides rendered and the frames matched, so this page — '
              "written with only the findings' pictures — did not carry "
              'them. Every channel it compared is still below.',
              textAlign: TextAlign.center,
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var hasChannels =
        (item.tree?.changed ?? false) ||
        item.texts != null ||
        item.events != null;
    var pixelsMoved = item.pixels?.changed ?? false;
    // One side missing is its own kind of finding, and the stage already draws
    // it well: the frame labelled `base only`, the mode pills disabled, the
    // note in red. Nothing about those states needs to move.
    var oneSided = shots.base == null || shots.head == null;

    if (!shots.settled) {
      return Expanded(
        child: Center(
          child: Text(
            'Loading…',
            style: context.type.body.copyWith(color: colors.mut),
          ),
        ),
      );
    }
    if (whenNotRendered case var instead? when !shots.hasFrames) {
      return Expanded(child: instead);
    }

    if (pixelsMoved || oneSided) {
      var diff = item.pixels?.diff;
      var stage = ComparisonStage(
        shots: shots,
        mode: mode,
        onMode: onMode,
        diff: diff,
        onEnlarge: () => showEnlargedStage(
          context,
          title: comparedName(item.id, label: item.label).name,
          shots: shots,
          mode: mode,
          onMode: onMode,
          diff: diff,
        ),
      );
      if (!hasChannels) return Expanded(child: stage);
      return Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // **The frames decide where the channels go.** Portrait frames are
            // bound by the pane's height, so every row the channels take from
            // under them shrinks the picture — and they leave most of a wide
            // pane's width empty either side. Beside them, the channels cost
            // the pictures nothing. Landscape frames are the other way round:
            // bound by width, and happy to give up height.
            var shot = shots.head ?? shots.base;
            var beside =
                shot != null &&
                shot.aspect < 1 &&
                constraints.maxWidth >= _besideFrom;
            if (beside) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: stage),
                  SizedBox(
                    width: _channelsWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: colors.line)),
                      ),
                      child: ChannelLines(item, onRule: onRule, ruled: false),
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: stage),
                Expanded(flex: 2, child: ChannelLines(item, onRule: onRule)),
              ],
            );
          },
        ),
      );
    }

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _IdenticalFrames(shots: shots, mode: mode, onMode: onMode),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: hasChannels
                ? ChannelLines(item, onRule: onRule)
                : Center(
                    child: Text(
                      // A step found another way is here *because* of that,
                      // and "no changes" under it reads as the page arguing
                      // with itself. Which side of the line changed is the
                      // whole answer.
                      item.retargeted == null
                          ? 'No changes on any channel'
                          : 'Only the test changed here — the app drew the '
                                'same thing on every channel',
                      style: context.type.body.copyWith(color: colors.mut),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The frames, when they are the same frame twice.
///
/// **One picture, not two.** *What does this look like* is a fair question
/// even when the answer is *the same as before*, and a reader who has just
/// arrived from a list needs to know where they are — but a second copy of it
/// answers nothing the word `identical` does not, and the two of them together
/// were taking the space the finding needed.
///
/// Expandable, because *identical* is a claim and somebody is eventually going
/// to want to check it. It expands in place rather than being lifted to the
/// page, so neither half has to carry a flag for it.
class _IdenticalFrames extends StatefulWidget {
  const _IdenticalFrames({
    required this.shots,
    required this.mode,
    required this.onMode,
  });

  final ShotPair shots;
  final StageMode mode;
  final ValueChanged<StageMode> onMode;

  @override
  State<_IdenticalFrames> createState() => _IdenticalFramesState();
}

const _thumbHeight = 96.0;

/// How wide a pane has to be before the channels move beside portrait frames:
/// the column, and a stage that still has room for two phones side by side.
const _besideFrom = 900.0;

/// The channels' column, beside the stage. Wide enough that a `size  52×52 →
/// 60×60` line does not wrap, narrow enough that it is not the pane.
const _channelsWidth = 380.0;

class _IdenticalFramesState extends State<_IdenticalFrames> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (_open) {
      return SizedBox(
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ComparisonStage(
                shots: widget.shots,
                mode: widget.mode,
                onMode: widget.onMode,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  FwSpacing.xl,
                  0,
                  FwSpacing.xl,
                  FwSpacing.sm,
                ),
                child: Tappable(
                  onTap: () => setState(() => _open = false),
                  child: Text(
                    'Hide frames',
                    style: context.type.caption.copyWith(
                      color: colors.accentDark,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.md,
        FwSpacing.xl,
        FwSpacing.md,
      ),
      child: Row(
        children: [
          // Sized in both directions from the frame's own aspect. An
          // `AspectRatio` in a `Row` sizes from the width it is offered, which
          // here is the whole row — so the picture drew itself far larger than
          // its border and spilled out of it.
          if (widget.shots.head ?? widget.shots.base case var shot?)
            SizedBox(
              height: _thumbHeight,
              width: _thumbHeight * shot.aspect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.line),
                ),
                child: ClipRect(child: ShotView(shot)),
              ),
            ),
          const Gap(FwSpacing.lg),
          Expanded(
            child: Text(
              'Frames identical',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          ),
          Tappable(
            onTap: () => setState(() => _open = true),
            child: Text(
              'Show frames',
              style: context.type.caption.copyWith(color: colors.accentDark),
            ),
          ),
        ],
      ),
    );
  }
}
