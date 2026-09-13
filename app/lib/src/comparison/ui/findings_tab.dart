import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';

import '../../ui/empty_state.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../../utils/string/plural.dart';
import '../shot_store.dart';
import 'channel_signature.dart';
import 'compared_name.dart';
import 'shot_image.dart';
import 'stage.dart';
import 'state_chip.dart';

const findingsTabKey = Key('comparison-findings');

Key findingRowKey(String id) => ValueKey('findings.row.$id');

/// Everything worth attention, worst first, both halves together.
///
/// **What a comment link opens onto.** The pull-request comment has always
/// merged the halves — one table, ranked by `rankComparedFindings` — and the
/// page then split them back into two tabs and opened on whichever came
/// first. A reader who has just been shown a ranked list of eleven findings
/// and clicks *Open the full comparison* was landing on a previews rail that
/// could not mention the scenarios and had no idea which row they came for.
///
/// So this is that table, drawn: the same function, the same order, with the
/// pictures the comment could only put in a mosaic. Tapping a row hands it to
/// the half that owns it, because the detail — the five-mode stage, the merged
/// flow — already lives there and a third copy of either is the drift this
/// codebase keeps paying for.
class FindingsTab extends StatelessWidget {
  const FindingsTab({
    super.key,
    required this.index,
    required this.store,
    required this.onOpen,
  });

  final ComparisonIndex index;
  final ShotStore store;

  /// Hands a finding to the half that owns it — `(tab, id)`.
  final void Function(String tab, String id) onOpen;

  /// How many rows get their frames.
  ///
  /// Every finding is listed; the ones past this are listed without pictures.
  /// A frame is a decoded `ui.Image` held for as long as its row is mounted,
  /// and a page with four hundred findings that decoded all of them would
  /// spend its memory on rows nobody has scrolled to — the same arithmetic
  /// `ShotPair` makes when it disposes on every selection change. Twenty is
  /// the mosaic's cap, for the same reason and in the same place in the
  /// argument.
  static const framedRows = 20;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var findings = index.findings;
    if (findings.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Nothing changed',
        message:
            index.verdictGap ??
            'Neither half found a row worse than identical. The other tabs '
                'have everything that was compared.',
      );
    }
    return ListView.separated(
      key: findingsTabKey,
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      itemCount: findings.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: colors.line),
      itemBuilder: (context, at) => _FindingRow(
        finding: findings[at],
        store: store,
        framed: at < framedRows,
        onOpen: onOpen,
      ),
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({
    required this.finding,
    required this.store,
    required this.framed,
    required this.onOpen,
  });

  final ComparedFinding finding;
  final ShotStore store;
  final bool framed;
  final void Function(String tab, String id) onOpen;

  String get _tab =>
      finding.half == ComparedHalfKind.previews ? 'previews' : 'scenarios';

  /// The scenario's face: its worst step that has frames.
  ///
  /// A flow's own verdict is a roll-up and carries no picture, so a row that
  /// showed only what the flow says would show nothing at all. The same choice
  /// the mosaic makes.
  ComparedItem? get _face {
    if (finding.preview case var preview?) return preview;
    ComparedItem? worst;
    for (var step in finding.scenario?.items ?? const <ComparedItem>[]) {
      if (!isComparedFinding(step.state)) continue;
      if (finding.scenario!.frames[step.id] == null) continue;
      if (worst == null || step.state.index < worst.state.index) worst = step;
    }
    return worst;
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var face = _face;
    var (:name, :file) = comparedName(
      finding.id,
      label: finding.preview?.label,
    );
    var changedSteps = [
      for (var step in finding.scenario?.items ?? const <ComparedItem>[])
        if (isComparedFinding(step.state)) step.label ?? step.id,
    ];

    return Tappable(
      key: findingRowKey(finding.id),
      onTap: () => onOpen(_tab, finding.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.xl,
          vertical: FwSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: context.type.bodyStrong,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Gap(FwSpacing.sm),
                      StateChip(finding.state),
                    ],
                  ),
                  const Gap(FwSpacing.xs),
                  Text(
                    file,
                    style: context.type.micro.copyWith(color: colors.mut),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Which steps, the way the comment says it: a flow's verdict
                  // is a roll-up, and the row was the one place on the page
                  // that could not name what inside it changed.
                  if (changedSteps.isNotEmpty) ...[
                    const Gap(FwSpacing.xs),
                    Text(
                      changedAt(changedSteps),
                      style: context.type.caption.copyWith(color: colors.ink2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (finding.note case var note?) ...[
                    const Gap(FwSpacing.xs),
                    Text(
                      // One line. A compile failure's note is the compiler's
                      // whole output, and the detail page is where it belongs.
                      note.split('\n').first,
                      style: context.type.micro.copyWith(color: colors.red),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (face != null && face.channelsFired.isNotEmpty) ...[
                    const Gap(FwSpacing.xs),
                    ChannelSignature(
                      channels: face.channelsFired,
                      pixelFraction: face.pixels?.diff.fraction,
                      maxLines: 1,
                    ),
                  ],
                ],
              ),
            ),
            if (framed && face != null) ...[
              const Gap(FwSpacing.lg),
              _Frames(finding: finding, face: face, store: store),
            ],
          ],
        ),
      ),
    );
  }
}

/// `changed at Menu, Order placed` — the first three, then how many more.
@visibleForTesting
String changedAt(List<String> steps) {
  const shown = 3;
  var named = steps.take(shown).join(', ');
  var more = steps.length - shown;
  return more > 0
      ? 'changed at $named and ${counted(more, 'other step')}'
      : 'changed at $named';
}

/// Base beside head — the mosaic's cell, in the page, with the change boxed.
///
/// **Tall enough to see the change, shaped like the frame.** The cells were
/// 84×64 whatever they held: a phone screen came out 30 pixels wide and a
/// laptop's a letterboxed strip, and neither said what changed. Now every cell
/// is [height] tall and as wide as the frame's own shape makes it, within
/// bounds, and the head carries the same boxes the stage draws — so a row
/// points at its change before it is opened.
///
/// The shape comes from what the report already knows about the frame — a
/// step's frame reference, a preview's pixel diff — before either picture has
/// decoded. That is what keeps the rule the fixed cells were for: a row does
/// not grow when its pictures land.
class _Frames extends StatefulWidget {
  const _Frames({
    required this.finding,
    required this.face,
    required this.store,
  });

  final ComparedFinding finding;
  final ComparedItem face;
  final ShotStore store;

  static const height = 140.0;
  static const minWidth = 64.0;
  static const maxWidth = 220.0;

  /// A frame of unknown shape — nothing moved in its pixels, so there is no
  /// diff to say — drawn in a cell that suits most screens well enough.
  static const unknownAspect = 3 / 4;

  Size get cell {
    var frames = finding.scenario?.frames[face.id];
    var diff = face.pixels?.diff;
    var (width, height) = switch ((frames?.head ?? frames?.base, diff)) {
      (var ref?, _) => (ref.width, ref.height),
      (_, var diff?) => (diff.width, diff.height),
      _ => (0, 0),
    };
    var aspect = height == 0 ? unknownAspect : width / height;
    return Size(
      (_Frames.height * aspect).clamp(minWidth, maxWidth),
      _Frames.height,
    );
  }

  /// What the frames are decoded at — twice the drawn width, so the cell is
  /// crisp on a 2× display and still a fraction of the frame. Twenty rows of
  /// two frames decoded whole is hundreds of megabytes drawn at a thumbnail.
  int get decodeWidth => (cell.width * 2).ceil();

  @override
  State<_Frames> createState() => _FramesState();
}

class _FramesState extends State<_Frames> {
  late final _shots = ShotPair(widget.store);

  @override
  void initState() {
    super.initState();
    _shots.addListener(_onShots);
    unawaitedLoad();
  }

  /// A preview names its frames by cache key and a scenario step by path, and
  /// the row does not get to care which: [ShotPair] has a door for each.
  void unawaitedLoad() {
    if (widget.finding.scenario case var scenario?) {
      var frames = scenario.frames[widget.face.id];
      _shots
          .loadFrames(
            base: frames?.base,
            head: frames?.head,
            width: widget.decodeWidth,
          )
          .ignore();
      return;
    }
    var shots = widget.face.shots;
    _shots
        .load(
          baseKey: shots?.base,
          headKey: shots?.head,
          width: widget.decodeWidth,
        )
        .ignore();
  }

  void _onShots() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _shots
      ..removeListener(_onShots)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // The cells are drawn before the frames arrive, and that is the point:
    // a row that grows when its pictures land makes the list jump under
    // whoever is reading it, for as long as forty-odd fetches take. What
    // fills them is the only thing that changes.
    //
    // Blank while loading and a dash once settled, because those are two
    // different statements and `ShotPair.settled` is what tells them apart —
    // "nothing here" said over a frame still being fetched is a lie that
    // corrects itself, which is worse than saying nothing.
    var size = widget.cell;
    Widget cell(Shot? shot, String label, {PixelDiff? diff}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size.width,
          height: size.height,
          decoration: BoxDecoration(
            color: colors.panel2,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          ),
          clipBehavior: Clip.antiAlias,
          // An empty bordered box under the word `head` is the truth and not
          // obviously so — it reads as a frame that has not loaded. The mark
          // says the side drew nothing, which for a `broke` or `added` row is
          // the finding.
          child: switch ((shot, _shots.settled)) {
            (var shot?, _) => BoxedShot(shot: shot, diff: diff),
            (_, false) => const SizedBox.shrink(),
            // An empty bordered box under the word `head` is the truth and
            // not obviously so — it reads as a frame that failed to load. The
            // mark says the side drew nothing, which for a `broke` or `added`
            // row is the finding itself.
            (_, true) => Center(
              child: Text(
                '—',
                style: context.type.micro.copyWith(color: colors.mut2),
              ),
            ),
          },
        ),
        const Gap(FwSpacing.xs),
        Text(label, style: context.type.micro.copyWith(color: colors.mut)),
      ],
    );
    return Row(
      children: [
        cell(_shots.base, 'base'),
        const Gap(FwSpacing.sm),
        cell(_shots.head, 'head', diff: widget.face.pixels?.diff),
      ],
    );
  }
}
