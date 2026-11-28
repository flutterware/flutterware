import 'dart:math' as math;

import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/empty_state.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../../utils/string/plural.dart';
import '../finding_face.dart';
import '../shot_store.dart';
import 'channel_signature.dart';
import 'compared_name.dart';
import 'shot_image.dart';
import 'stage.dart';
import 'state_chip.dart';

const findingsTabKey = Key('comparison-findings');

Key findingRowKey(String id) => ValueKey('findings.row.$id');

const findingsSamePictureKey = Key('comparison-findings.same-picture');

/// Everything worth attention, both halves together: what looks different
/// first, and what has the same picture folded under it.
///
/// **What a comment link opens onto.** The pull-request comment has always
/// merged the halves — one table, ranked by `rankComparedFindings` — and the
/// page then split them back into two tabs and opened on whichever came
/// first. A reader who has just been shown a ranked list of eleven findings
/// and clicks *Open the full comparison* was landing on a previews rail that
/// could not mention the scenarios and had no idea which row they came for.
///
/// So this is that table, drawn, with the pictures the comment could only put
/// in a mosaic. Tapping a row hands it to the half that owns it, because the
/// detail — the five-mode stage, the merged flow — already lives there and a
/// third copy of either is the drift this codebase keeps paying for.
class FindingsTab extends StatefulWidget {
  const FindingsTab({
    super.key,
    required this.index,
    required this.store,
    required this.onOpen,
    this.samePictureOpen,
  });

  final ComparisonIndex index;
  final ShotStore store;

  /// Hands a finding to the half that owns it — `(tab, id)`.
  final void Function(String tab, String id) onOpen;

  /// Whether the rows with the same picture are listed. The page holds it, so
  /// the group is as it was left when a reader comes back from one of them;
  /// null keeps it here.
  final ValueNotifier<bool>? samePictureOpen;

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

  /// How wide a row gets: a name, its verdict and two thumbnails, near
  /// enough to read as one line.
  static const rowMaxWidth = 1040.0;

  @override
  State<FindingsTab> createState() => _FindingsTabState();
}

class _FindingsTabState extends State<FindingsTab> {
  final _own = ValueNotifier(false);

  ValueNotifier<bool> get _open => widget.samePictureOpen ?? _own;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var findings = widget.index.findings;
    if (findings.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Nothing changed',
        message:
            widget.index.verdictGap ??
            'No preview or scenario changed. The other tabs list everything '
                'that was compared.',
      );
    }
    var (:different, :samePicture) = splitFindings(findings);
    // **A row is read left to right, so it has a width.** Stretched across a
    // wide window the name sat at one edge and its verdict and pictures at the
    // other, a thousand pixels of nothing between what a row is and what
    // happened to it. The list still scrolls from the window's edge.
    Widget capped(Widget child) => Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: FindingsTab.rowMaxWidth),
        child: child,
      ),
    );
    Widget row(ComparedFinding finding, {required bool framed}) => _FindingRow(
      finding: finding,
      store: widget.store,
      framed: framed,
      onOpen: widget.onOpen,
    );
    return ValueListenableBuilder(
      valueListenable: _open,
      builder: (context, open, _) {
        var entries = <Widget>[
          _Summary(
            different: different.length,
            samePicture: samePicture.length,
          ),
          for (var (at, finding) in different.indexed)
            row(finding, framed: at < FindingsTab.framedRows),
          if (samePicture.isNotEmpty)
            _SamePictureHeader(
              samePicture,
              open: open,
              onToggle: () => _open.value = !open,
            ),
          // No frames: the two of them would be the same picture.
          if (open)
            for (var finding in samePicture) row(finding, framed: false),
        ];
        return ListView.separated(
          key: findingsTabKey,
          padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
          itemCount: entries.length,
          separatorBuilder: (context, index) =>
              capped(Divider(height: 1, color: colors.line)),
          itemBuilder: (context, at) => capped(entries[at]),
        );
      },
    );
  }

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }
}

/// The answer a reader arrives for: does anything look different, and how
/// much.
class _Summary extends StatelessWidget {
  const _Summary({required this.different, required this.samePicture});

  final int different;
  final int samePicture;

  String get _sentence {
    if (different == 0) return 'Nothing looks different';
    var looks = '$different ${different == 1 ? 'looks' : 'look'} different';
    if (samePicture == 0) return looks;
    var have = samePicture == 1 ? 'has' : 'have';
    return '$looks · $samePicture $have the same picture';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: FwSpacing.xl,
      vertical: FwSpacing.md,
    ),
    child: Text(_sentence, style: context.type.heading),
  );
}

/// The one line the findings with the same picture are folded under.
class _SamePictureHeader extends StatelessWidget {
  const _SamePictureHeader(
    this.findings, {
    required this.open,
    required this.onToggle,
  });

  final List<ComparedFinding> findings;
  final bool open;
  final VoidCallback onToggle;

  String get _what => whatDiffers({
    for (var finding in findings) ...findingUnseenChannels(finding),
  });

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      key: findingsSamePictureKey,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.xl,
          vertical: FwSpacing.lg,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${findings.length} with the same picture',
                    style: context.type.bodyStrong,
                  ),
                  const Gap(FwSpacing.xs),
                  Text(
                    _what,
                    style: context.type.caption.copyWith(color: colors.mut),
                  ),
                ],
              ),
            ),
            const Gap(FwSpacing.lg),
            Text(
              open ? 'Hide' : 'Show',
              style: context.type.caption.copyWith(color: colors.accentDark),
            ),
          ],
        ),
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

  /// The scenario's face: the step its picture is taken from.
  ///
  /// A flow's own verdict is a roll-up and carries no picture, so a row that
  /// showed only what the flow says would show nothing at all. The same choice
  /// the mosaic makes — [scenarioFace].
  ComparedItem? get _face => switch (finding) {
    ComparedFinding(:var preview?) => preview,
    ComparedFinding(:var scenario?) => scenarioFace(scenario),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var face = _face;
    var (:name, :file) = comparedName(
      finding.id,
      label: finding.preview?.label,
    );
    var steps = [
      for (var step in finding.scenario?.items ?? const <ComparedItem>[])
        if (isComparedFinding(step.state)) step,
    ];
    // Where something can be seen leads: only three steps are named.
    var changedSteps = [
      for (var step in [
        ...steps.where((step) => !hasSamePicture(step)),
        ...steps.where(hasSamePicture),
      ])
        step.label ?? step.id,
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
                      switch (finding) {
                        ComparedFinding(:var preview?) => StateChip.item(
                          preview,
                        ),
                        ComparedFinding(:var scenario?) => StateChip.of(
                          scenario,
                        ),
                        _ => StateChip(finding.state),
                      },
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
                      style: context.type.micro.copyWith(
                        color: finding.state.noteColorIn(context),
                      ),
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

  /// The part of the frames the cells show — see [cropFor].
  FrameCrop? get crop => switch (face.pixels?.diff) {
    var diff? => cropFor(diff),
    null => null,
  };

  /// What the frames are decoded at — twice the drawn width, so the cell is
  /// crisp on a 2× display and still a fraction of the frame. Twenty rows of
  /// two frames decoded whole is hundreds of megabytes drawn at a thumbnail.
  /// A cropped cell draws part of the frame, so the whole is decoded that much
  /// larger, up to [maxDecodeWidth].
  int get decodeWidth {
    var shown = cell.width * 2;
    var diff = face.pixels?.diff;
    if (crop case var crop? when diff != null) {
      shown = math.min(shown * diff.width / crop.width, diff.width.toDouble());
    }
    return math.min(shown.ceil(), maxDecodeWidth);
  }

  static const maxDecodeWidth = 1200;

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
            (var shot?, _) => _CellPicture(
              shot: shot,
              diff: diff,
              crop: widget.crop,
              frame: widget.face.pixels?.diff,
              cell: size,
            ),
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
        cell(
          _shots.head,
          widget.crop == null ? 'head' : 'head, zoomed in',
          diff: widget.face.pixels?.diff,
        ),
      ],
    );
  }
}

/// A frame in a cell: whole, or the part [crop] names with the rest of the
/// frame running off the cell's edges.
class _CellPicture extends StatelessWidget {
  const _CellPicture({
    required this.shot,
    required this.cell,
    this.diff,
    this.crop,
    this.frame,
  });

  final Shot shot;
  final Size cell;
  final PixelDiff? diff;
  final FrameCrop? crop;

  /// What [crop] is measured in.
  final PixelDiff? frame;

  @override
  Widget build(BuildContext context) {
    var picture = BoxedShot(shot: shot, diff: diff);
    var (crop, frame) = (this.crop, this.frame);
    // In the frame's own shape, or the boxes land beside the change where the
    // cell is clamped narrower than the frame.
    if (crop == null || frame == null) {
      return Center(
        child: AspectRatio(aspectRatio: shot.aspect, child: picture),
      );
    }
    // Inside the border.
    var box = Size(cell.width - 2, cell.height - 2);
    var scale = math.min(box.width / crop.width, box.height / crop.height);
    var (width, height) = (frame.width * scale, frame.height * scale);
    double place(double centre, double room, double size) => size <= room
        ? (room - size) / 2
        : (room / 2 - centre).clamp(room - size, 0.0).toDouble();
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: place((crop.x + crop.width / 2) * scale, box.width, width),
          top: place((crop.y + crop.height / 2) * scale, box.height, height),
          width: width,
          height: height,
          child: picture,
        ),
      ],
    );
  }
}
