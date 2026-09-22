import 'dart:async';

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutterware/real_work.dart';

import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../../ui/zoom_buttons.dart';
import '../../ui/zoomable_canvas.dart';
import '../../utils/graphite.dart';
import '../shot_store.dart';
import 'channel_signature.dart';
import 'shot_image.dart';
import 'state_chip.dart';

const mergedTreeKey = Key('comparison.merged-tree');

Key stepNodeKey(String id) => ValueKey('comparison.step.$id');

/// One scenario's two runs as a single tree.
///
/// Merged, not side by side, and that is the whole design of the scenario
/// half. Two flows drawn next to each other make a reader do the alignment —
/// which is the expensive part, and the part the aligner has already done. One
/// tree with a ring per node says *where* the runs diverged in the shape a
/// scenario actually has: a trunk that forks.
///
/// A branch that exists on one side only is **one labelled row**, however many
/// steps hang off it. A new `split` branch is one decision in the source;
/// drawing its four steps as four nodes describes that decision four times and
/// buries whatever else the run found.
class MergedTree extends StatefulWidget {
  const MergedTree({
    super.key,
    required this.scenario,
    required this.store,
    required this.transform,
    required this.selected,
    required this.onSelect,
  });

  final ScenarioComparison scenario;
  final ShotStore store;

  /// The canvas's pan and zoom, owned by the tab: it has to survive a pushed
  /// step and be *reset* when another flow is picked, and only the tab knows
  /// which of the two just happened. Reset means back to identity, which this
  /// reads as "open the flow afresh" — see [_MergedTreeState._opening].
  final TransformationController transform;

  /// The step id the address names, or null.
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  State<MergedTree> createState() => _MergedTreeState();
}

class _MergedTreeState extends State<MergedTree> {
  /// The graph's own size, measured once it is laid out, and the pane it is
  /// drawn in. Both are needed to know what fits.
  Size? _content;
  Size? _pane;

  @override
  void initState() {
    super.initState();
    widget.transform.addListener(_onTransform);
  }

  @override
  void didUpdateWidget(MergedTree old) {
    super.didUpdateWidget(old);
    if (!identical(old.transform, widget.transform)) {
      old.transform.removeListener(_onTransform);
      widget.transform.addListener(_onTransform);
    }
  }

  @override
  void dispose() {
    widget.transform.removeListener(_onTransform);
    super.dispose();
  }

  /// Not a rebuild: the graph is the whole canvas, and a pan moves the
  /// transform every frame. The zoom readout listens for itself.
  void _onTransform() => _openIfFresh();

  void _onContent(Size size) {
    if (size == _content) return;
    _content = size;
    _openIfFresh();
  }

  /// A canvas still at identity has not been opened: a new flow, or this one
  /// for the first time. One the reader has moved — or that was opened before a
  /// step was pushed over it — is left exactly where it is.
  void _openIfFresh() {
    if (widget.transform.value != Matrix4.identity()) return;
    var opening = _opening();
    if (opening == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.transform.value == Matrix4.identity()) {
        widget.transform.value = opening;
      }
    });
  }

  /// **The flow as tall as the pane, and inset from its edge.** It opened at
  /// 100% at the pane's very corner, so the first frame sat clipped against
  /// the list beside it and the rest of the flow ran off the right with nothing
  /// saying it could be zoomed. Fitted to the height rather than to the whole:
  /// a long flow fitted to the width shrinks its frames past reading, and
  /// panning sideways along one row is what a flow is for.
  Matrix4? _opening() {
    var (content, pane) = (_content, _pane);
    if (content == null || pane == null || content.height <= 0) return null;
    var scale = ((pane.height - 2 * _inset) / content.height).clamp(
      _minScale,
      1.0,
    );
    return _placed(scale, dx: _inset, content: content, pane: pane);
  }

  /// Everything in view, centred.
  void _fit() {
    var (content, pane) = (_content, _pane);
    if (content == null || pane == null) return;
    if (content.width <= 0 || content.height <= 0) return;
    var scale = [
      (pane.width - 2 * _inset) / content.width,
      (pane.height - 2 * _inset) / content.height,
      1.0,
    ].reduce((a, b) => a < b ? a : b).clamp(_minScale, 1.0);
    widget.transform.value = _placed(
      scale,
      dx: ((pane.width - content.width * scale) / 2).clamp(_inset, pane.width),
      content: content,
      pane: pane,
    );
  }

  static Matrix4 _placed(
    double scale, {
    required double dx,
    required Size content,
    required Size pane,
  }) {
    var dy = ((pane.height - content.height * scale) / 2).clamp(
      _inset,
      pane.height,
    );
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    var scenario = widget.scenario;
    var graph = _MergedGraph.of(scenario);
    if (graph.nodes.isEmpty) return const SizedBox.shrink();
    var nodeWidth = _nodeWidthFor(scenario);
    var colors = context.colors;

    return LayoutBuilder(
      builder: (context, constraints) {
        _pane = constraints.biggest;
        return Stack(
          children: [
            Positioned.fill(
              // **The scenarios panel's own flow, with a comparison on it.**
              // That panel draws a run as a horizontal graph of device-framed
              // shots, and a reader who has learned to read one flow should not
              // have to learn a second shape to read two — so this is the same
              // `DirectGraph`, the same orientation and the same pan-and-zoom,
              // with the nodes carrying a verdict.
              child: DirectGraph(
                key: mergedTreeKey,
                list: graph.nodes,
                cellSize: Size(nodeWidth + _gap, _thumbHeight + _captionHeight),
                cellPadding: _gap,
                contactEdgesDistance: 0,
                tipLength: 14,
                orientation: MatrixOrientation.horizontal,
                // The panel's line colour, not the painter's default black: an
                // arrow says only *then*, and drawn in ink it was the heaviest
                // thing on a canvas of pictures.
                paintBuilder: (edge) => Paint()
                  ..color = colors.mut3
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2,
                interactiveBuilder: (context, child) => ZoomableCanvas(
                  transformationController: widget.transform,
                  maxScale: 1.5,
                  minScale: _minScale,
                  boundaryMargin: const EdgeInsets.all(2000),
                  child: _Measured(onSize: _onContent, child: child),
                ),
                builder: (context, node) {
                  var cell = graph.cells[node.id]!;
                  return switch (cell) {
                    _StepCell(:var item) => _StepNode(
                      width: nodeWidth,
                      item: item,
                      frames: scenario.frames[item.id],
                      store: widget.store,
                      selected: item.id == widget.selected,
                      onTap: () => widget.onSelect(item.id),
                    ),
                    _BranchCell(:var branch) => _OneSidedBranch(
                      branch,
                      width: nodeWidth,
                    ),
                  };
                },
              ),
            ),
            Positioned(
              right: FwSpacing.md,
              bottom: FwSpacing.md,
              child: ListenableBuilder(
                listenable: widget.transform,
                builder: (context, _) => ZoomButtons(
                  key: mergedTreeZoomKey,
                  value: widget.transform.value.getMaxScaleOnAxis(),
                  onScale: (factor) => widget.transform.value = widget
                      .transform
                      .value
                      .scaledByDouble(factor, factor, factor, 1),
                  onFit: _fit,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

const mergedTreeZoomKey = Key('comparison.merged-tree.zoom');

/// How far the flow stands off the pane's edges when it is placed.
const _inset = FwSpacing.xl;

const _minScale = 0.2;

/// Reports its child's laid-out size, after the frame that laid it out.
class _Measured extends SingleChildRenderObjectWidget {
  const _Measured({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasured(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasured renderObject) =>
      renderObject.onSize = onSize;
}

class _RenderMeasured extends RenderProxyBox {
  _RenderMeasured(this.onSize);

  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _reported) return;
    _reported = size;
    var measured = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(measured));
  }
}

/// What a node in the merged graph stands for.
sealed class _Cell {
  const _Cell();
}

class _StepCell extends _Cell {
  const _StepCell(this.item);
  final ComparedItem item;
}

class _BranchCell extends _Cell {
  const _BranchCell(this.branch);
  final BranchDelta branch;
}

/// The flat item list, back into the tree it came from.
///
/// Read out of the ids rather than carried alongside them: an item's id
/// *is* its path through the flow — `guest › small cup › Cart` — because that
/// is what a report has to address it by anyway. One representation, so the
/// tree and the artifact cannot disagree about where a step is.
class _MergedGraph {
  const _MergedGraph({required this.nodes, required this.cells});

  final List<NodeInput> nodes;
  final Map<String, _Cell> cells;

  static _MergedGraph of(ScenarioComparison scenario) {
    // Steps grouped by the branch path they sit on, in the order they arrived.
    var laneOrder = <String>[];
    var lanes = <String, List<ComparedItem>>{};
    for (var item in scenario.items) {
      var parts = item.id.split(' › ');
      var lane = parts.take(parts.length - 1).join(' › ');
      lanes
          .putIfAbsent(lane, () {
            laneOrder.add(lane);
            return [];
          })
          .add(item);
    }

    var cells = <String, _Cell>{};
    var next = <String, List<String>>{};

    for (var lane in laneOrder) {
      var steps = lanes[lane]!;
      for (var (index, item) in steps.indexed) {
        cells[item.id] = _StepCell(item);
        if (index + 1 < steps.length) {
          next[item.id] = [steps[index + 1].id];
        }
      }
      // A lane hangs off the last step of the lane above it — which is where
      // its `split` was written.
      var parent = _lastOfParentLane(lane, lanes);
      if (parent != null) {
        (next[parent] ??= []).add(steps.first.id);
      }
    }

    // A branch only one run has: one node, wherever it forked from.
    for (var (index, branch) in scenario.branches.indexed) {
      var id = 'branch:$index:${branch.label}';
      cells[id] = _BranchCell(branch);
      var parent = _lastOfLane(branch.path.join(' › '), lanes);
      if (parent != null) (next[parent] ??= []).add(id);
    }

    return _MergedGraph(
      nodes: [
        for (var id in cells.keys)
          NodeInput(id: id, next: next[id] ?? const []),
      ],
      cells: cells,
    );
  }

  static String? _lastOfParentLane(
    String lane,
    Map<String, List<ComparedItem>> lanes,
  ) {
    if (lane.isEmpty) return null;
    var parts = lane.split(' › ');
    return _lastOfLane(parts.take(parts.length - 1).join(' › '), lanes);
  }

  static String? _lastOfLane(
    String lane,
    Map<String, List<ComparedItem>> lanes,
  ) => lanes[lane]?.lastOrNull?.id;
}

/// A branch only one run has.
class _OneSidedBranch extends StatelessWidget {
  const _OneSidedBranch(this.branch, {required this.width});

  final BranchDelta branch;
  final double width;

  @override
  Widget build(BuildContext context) {
    var state = branch.added ? ComparedState.added : ComparedState.removed;
    var color = state.colorIn(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        color: color.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StateChip(state),
          const Gap(FwSpacing.xs),
          Text(
            '${branch.steps} step${branch.steps == 1 ? '' : 's'}',
            style: context.type.caption.copyWith(color: context.colors.mut),
          ),
        ],
      ),
    );
  }
}

const _thumbHeight = 190.0;

/// What separates two frames on the canvas, and all that separates them.
const _gap = 40.0;

/// Room under the thumbnail for everything the node says about the step.
///
/// Counted rather than guessed, because guessing is what broke it — twice
/// now: the node grew a line naming the channels that fired and this stayed
/// at 70, a measured 10px overflow; then the channel line gained a bold
/// `pixels 94%` span and wrapped 3px past 92. The budget is a gap (4), two
/// lines of label (~28), a gap (2), a state chip (~18), a gap (2) and two
/// lines of channel signature (~28, its bold span is taller than plain
/// micro) — 82, plus slack for a larger text scale. The signature is also
/// capped at two lines, so the slot cannot be outgrown a third way.
const _captionHeight = 100.0;

/// How wide a node is, from the shape of the frames it holds.
///
/// It was a constant 132, which is a landscape figure — and a phone capture
/// fitted to [_thumbHeight] is about **88** wide. That left ~44px dead inside
/// every node, on both sides, *plus* the gap between cells: two 88px pictures
/// ended up about 128px apart, so the space between the frames was wider than
/// the frames. The arrow drawn in that space looked marooned because it was.
///
/// Taken from the pixel channel, which already carries each frame's size and
/// costs nothing to read — no image has to be decoded to lay the graph out.
/// Clamped because a desktop capture would otherwise make a node wider than
/// most windows, and a flow of those is unreadable for the opposite reason.
double _nodeWidthFor(ScenarioComparison scenario) {
  // The **commonest** shape, not the first. A flow whose first step is a bare
  // `pumpWidget` at the default 800×600 and whose remaining twenty are phone
  // captures would otherwise size every node from that one landscape frame,
  // and every phone in it goes back to being letterboxed in a box of the wrong
  // shape — which is the whitespace this function exists to remove.
  var seen = <double, int>{};
  for (var item in scenario.items) {
    var pixels = item.pixels?.diff;
    if (pixels == null || pixels.width <= 0 || pixels.height <= 0) continue;
    var aspect = pixels.width / pixels.height;
    seen[aspect] = (seen[aspect] ?? 0) + 1;
  }
  if (seen.isEmpty) return 132;
  var common = seen.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  return (_thumbHeight * common).clamp(96.0, 260.0);
}

/// One step: its head frame, ringed by what the comparison said about it.
class _StepNode extends StatelessWidget {
  const _StepNode({
    required this.width,
    required this.item,
    required this.frames,
    required this.store,
    required this.selected,
    required this.onTap,
  });

  /// Sized from the frames rather than fixed — see [_nodeWidthFor].
  final double width;
  final ComparedItem item;
  final ({FrameRef? base, FrameRef? head})? frames;
  final ShotStore store;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = item.state.colorIn(context);
    var ring = item.state.isFinding ? color : colors.line;

    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.md),
      child: Tappable.builder(
        key: stepNodeKey(item.id),
        onTap: onTap,
        // **A wash over this one would land on the picture.** The node is
        // mostly thumbnail, and the primitive paints over its child — which is
        // the frame a reader is here to judge. The tint goes behind it instead,
        // which is what the ring note below is about.
        builder: (context, hovered) => SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: _thumbHeight,
                // The node's width, not the picture's: a step with no frame —
                // a `Shot.skip`, a run that ended before it — otherwise
                // collapses this box to its own border, a 2px sliver in the
                // middle of the flow.
                width: double.infinity,
                decoration: BoxDecoration(
                  // **A ring, not a tint.** The frame is the subject; colouring
                  // it changes the very thing a reader is trying to judge.
                  border: Border.all(
                    color: selected ? colors.accent : ring,
                    width: selected || item.state.isFinding ? 2 : 1,
                  ),
                  color: hovered ? colors.hoverOverlay : colors.panel,
                ),
                child: _Thumbnail(
                  // The head frame, falling back to base for a step only the
                  // base run had — there is nothing else to show for it.
                  frames?.head ?? frames?.base,
                  store: store,
                ),
              ),
              const Gap(FwSpacing.xs),
              Text(
                item.label ?? item.id.split(' › ').last,
                style: context.type.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (item.state.isFinding) ...[
                const Gap(2),
                StateChip(item.state),
                // *That* it changed was all a node ever said. Which channel
                // saw it is the difference between a screenshot worth opening
                // and a request that moved behind one — and the flow is where
                // a reader decides which step to open.
                if (item.channelsFired case var channels
                    when channels.isNotEmpty) ...[
                  const Gap(2),
                  ChannelSignature(
                    channels: channels,
                    maxLines: 2,
                    pixelFraction: item.pixels?.changed ?? false
                        ? item.pixels?.diff.fraction
                        : null,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One frame, decoded on demand.
class _Thumbnail extends StatefulWidget {
  const _Thumbnail(this.frame, {required this.store});

  final FrameRef? frame;
  final ShotStore store;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  Shot? _shot;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_Thumbnail old) {
    super.didUpdateWidget(old);
    if (old.frame?.path != widget.frame?.path) unawaited(_load());
  }

  Future<void> _load() async {
    var frame = widget.frame;
    // Announced, for the reason `ShotPair` gives.
    var shot = frame == null
        ? null
        : await RealWork.track(
            widget.store.byRef(frame),
            label: 'comparison thumbnail',
          );
    if (!mounted) {
      shot?.image.dispose();
      return;
    }
    setState(() {
      _shot?.image.dispose();
      _shot = shot;
    });
  }

  @override
  Widget build(BuildContext context) {
    var shot = _shot;
    if (shot == null) {
      // No frame at all is a fact worth a word; still decoding is not.
      if (widget.frame != null) return const SizedBox.shrink();
      return Center(
        child: Text(
          'no frame',
          style: context.type.micro.copyWith(color: context.colors.mut3),
        ),
      );
    }
    return Padding(padding: const EdgeInsets.all(2), child: ShotView(shot));
  }

  @override
  void dispose() {
    _shot?.image.dispose();
    super.dispose();
  }
}
