import 'dart:async';

import 'package:flutter/material.dart';

import '../previews/devices.dart';
import '../plugins/native/scenarios_results.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import '../ui/zoom_buttons.dart';
import '../ui/zoomable_canvas.dart';
import '../utils/graphite.dart';
import 'artifacts.dart';
import 'beat_view.dart';
import 'framed_shot.dart';
import 'motion_player.dart';
import 'step_status.dart';

/// One run as a flow: every captured step a device-framed screenshot on a
/// pannable, zoomable canvas — dev_studio's proven shape, on the design
/// tokens.
///
/// Laid out by graphite even though today's runs are linear chains: splits
/// fan a scenario into a DAG, and when they arrive the canvas is already the
/// right kind of surface.
class ScenarioFlowView extends StatefulWidget {
  const ScenarioFlowView({
    super.key,
    required this.steps,
    required this.device,
    required this.transform,
    required this.onOpenStep,
    this.appLabel,
    this.appIcon,
    this.statusFallback = Brightness.dark,
  });

  final List<ScenarioRunStep> steps;

  /// The device the run was framed as, or null for the bare surface.
  final Device? device;

  /// Status-chrome tint when a step declared no overlay style.
  final Brightness statusFallback;

  /// Owned by the page, not this widget, so pushing a step's detail and
  /// coming back lands exactly where the canvas was.
  final TransformationController transform;

  /// A tap on a step — the caller pushes the detail page.
  final void Function(ScenarioRunStep) onOpenStep;

  /// A tap on an attachment card — the caller pushes its detail page. Null
  /// leaves the cards on the canvas but inert.

  /// What a notification banner calls the app when its payload does not say
  /// — the project's own name, when the caller knows it.
  final String? appLabel;

  /// The project's launcher icon for the banner tile, when the host could
  /// find one — the panel can, an exported page cannot.
  final ImageProvider? appIcon;

  /// Where the canvas opens: zoomed out and a little inset, so the first
  /// glance is the flow rather than one giant phone.
  ///
  /// Half size by default, which fits a short flow and shows the first two or
  /// three steps of a long one. [scale] is what the address's `?zoom=` sets:
  /// there is no fit-to-content here, so a run that fans out at a `split` is
  /// only legible as a *shape* when somebody says how far back to stand.
  static Matrix4 initialTransform({double scale = 0.5}) =>
      (Matrix4.identity() * scale as Matrix4)
        ..translateByDouble(50.0, 100.0, 0, 1);

  @override
  State<ScenarioFlowView> createState() => _ScenarioFlowViewState();
}

class _ScenarioFlowViewState extends State<ScenarioFlowView> {
  late var _scale = widget.transform.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    widget.transform.addListener(_onTransform);
  }

  void _onTransform() {
    var scale = widget.transform.value.getMaxScaleOnAxis();
    if (scale != _scale) setState(() => _scale = scale);
  }

  @override
  void didUpdateWidget(ScenarioFlowView old) {
    super.didUpdateWidget(old);
    if (old.transform != widget.transform) {
      old.transform.removeListener(_onTransform);
      widget.transform.addListener(_onTransform);
    }
  }

  @override
  void dispose() {
    widget.transform.removeListener(_onTransform);
    super.dispose();
  }

  Size get _cell {
    var device = widget.device;
    // Room for the label above and the frame's bezels around the screen.
    if (device == null) return const Size(800 + 60, 600 + 100);
    return Size(device.width + 120, device.height + 180);
  }

  @override
  Widget build(BuildContext context) {
    var steps = widget.steps;
    // The edges are the parent links the capture recorded — a linear
    // scenario chains, a split fans out. Data without parents (older
    // artifacts) falls back to the chain the list order implies.
    var hasParents = steps.any((s) => s.parent != null);
    var children = <int, List<int>>{};
    if (hasParents) {
      for (var step in steps) {
        if (step.parent case var parent?) {
          children.putIfAbsent(parent, () => []).add(step.index);
        }
      }
    } else {
      for (var (i, step) in steps.indexed) {
        if (i + 1 < steps.length) children[step.index] = [steps[i + 1].index];
      }
    }
    // One node per step, and the run's own edges between them. There is no
    // splicing left to do: a beat that is not a screen is a step like any
    // other, sitting in the chain where it happened, so the graph is the
    // report's shape unaltered.
    var nodes = {
      for (var (position, step) in steps.indexed)
        '${step.index}': _FlowNode(
          step,
          // The screen a frameless beat is drawn on: the parent where the run
          // recorded parents, the list's previous step where it did not.
          background: step.image != null
              ? step
              : hasParents
              ? scenarioFrameFor(steps, step)
              : _previousScreen(steps, position),
        ),
    };
    var next = <String, List<String>>{
      for (var step in steps)
        '${step.index}': [
          for (var child in children[step.index] ?? const <int>[]) '$child',
        ],
    };
    var inputs = [
      for (var id in nodes.keys) NodeInput(id: id, next: next[id] ?? const []),
    ];
    var byId = {for (var step in steps) '${step.index}': step};

    return Stack(
      children: [
        Positioned.fill(
          child: DirectGraph(
            list: inputs,
            cellSize: _cell,
            cellPadding: 90,
            contactEdgesDistance: 0,
            tipLength: 20,
            orientation: MatrixOrientation.horizontal,
            // A mouse wheel zooms by itself; a trackpad scroll pans unless ⌘
            // (or Ctrl) turns it into the zoom gesture — dev_studio's
            // behaviour.
            interactiveBuilder: (context, child) => ZoomableCanvas(
              transformationController: widget.transform,
              maxScale: 1.5,
              minScale: 0.05,
              boundaryMargin: const EdgeInsets.all(5000),
              child: child,
            ),
            builder: (context, node) => switch (nodes[node.id]!) {
              _FlowNode(:var step) when step.kind == ScenarioStepKind.screen =>
                _StepNode(
                  step,
                  device: widget.device,
                  statusFallback: widget.statusFallback,
                  onTap: () => widget.onOpenStep(step),
                ),
              _FlowNode(:var step, :var background) => _BeatNode(
                step,
                background: background,
                device: widget.device,
                statusFallback: widget.statusFallback,
                appLabel: widget.appLabel,
                appIcon: widget.appIcon,
                onTap: () => widget.onOpenStep(step),
              ),
            },
            paintBuilder: (edge) => Paint()
              ..color = context.colors.mut3
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3.5,
            // What the arrow has to say, in two registers. The split's branch
            // label goes on the arrow that forks — dev_studio's placement, and
            // the one that reads: a fan-out is several arrows leaving one
            // node, and the question is which arrow is which. Under it, the
            // transition itself: the verb that caused the next frame and how
            // many events the app fired getting there, so the flow reads as
            // `tap "Pay" › 4 events › Receipt` rather than as two pictures.
            edgeTooltip: (from, to) {
              var step = byId[to];
              if (step == null) return null;
              // The fork label rides the edge that enters the branch, which is
              // now simply the edge into the branch's first step — no card is
              // spliced in front of it any more to take the label instead.
              var branch = step.branch;
              var transition = scenarioStepTransition(step);
              // The quiet facts share one line under the transition: `7
              // events` needs no legend, and the milliseconds — only where
              // the run recorded the motion, which makes them the cue that
              // hovering the node will play it — are the animation's declared
              // duration in fake time, never a measurement of this machine.
              var count = step.notableEventCount;
              var meta = [
                if (count > 0) '$count event${count == 1 ? '' : 's'}',
                if (step.hasMotion)
                  '${scenarioMotionDuration(step).inMilliseconds}ms',
              ].join(' · ');
              if (branch == null && transition == null) return null;
              return EdgeTooltip(
                branch,
                // dev_studio's edge-label size. The painter gives the label
                // more width than the gap between nodes, so a transition
                // stays on one line instead of wrapping mid-word.
                style: context.type.body.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.colors.accent,
                ),
                subtitle: transition == null
                    ? null
                    : meta.isEmpty
                    ? transition
                    : '$transition\n$meta',
                subtitleStyle: context.type.body.copyWith(
                  fontSize: 12.5,
                  color: context.colors.mut,
                ),
                // The label may stray over a phone's bezel now that it is
                // wider than the gap; the chip keeps it legible there.
                background: context.colors.bg.withValues(alpha: 0.85),
              );
            },
          ),
        ),
        Positioned(
          right: FwSpacing.md,
          bottom: FwSpacing.md,
          child: ZoomButtons(
            value: _scale,
            onScale: (factor) => widget.transform.value = widget.transform.value
                .scaledByDouble(factor, factor, factor, 1),
          ),
        ),
      ],
    );
  }
}

/// One graph node: a step, and the screen it is drawn on.
///
/// The two are the same thing for a screen step. They differ only for a beat
/// that has no frame of its own — a document, a notification — which is drawn
/// on the nearest screen before it.
class _FlowNode {
  _FlowNode(this.step, {required this.background});

  final ScenarioRunStep step;
  final ScenarioRunStep? background;
}

/// The nearest screen at or before [position] in list order — the answer for a
/// run whose steps recorded no parents.
ScenarioRunStep? _previousScreen(List<ScenarioRunStep> steps, int position) {
  for (var i = position - 1; i >= 0; i--) {
    if (steps[i].image != null) return steps[i];
  }
  return null;
}

/// A beat that is not a screen, on the canvas in a step's silhouette: the
/// label above, the thing below, tappable through to its detail page.
class _BeatNode extends StatelessWidget {
  const _BeatNode(
    this.step, {
    required this.background,
    required this.device,
    required this.statusFallback,
    required this.appLabel,
    required this.appIcon,
    required this.onTap,
  });

  final ScenarioRunStep step;
  final ScenarioRunStep? background;
  final Device? device;
  final Brightness statusFallback;
  final String? appLabel;
  final ImageProvider? appIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onTap: onTap ?? () {},
      child: Column(
        children: [
          Text(
            step.name ?? scenarioBeatFallbackName(step),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // The step label's size, in the accent that says "not a screen".
            style: context.type.body.copyWith(
              fontSize: 17,
              color: context.colors.accent,
            ),
          ),
          const Gap(FwSpacing.md),
          Expanded(
            child: FittedBox(
              fit: BoxFit.contain,
              child: ScenarioBeatShot(
                step: step,
                background: background,
                device: device,
                statusFallback: statusFallback,
                appLabel: appLabel,
                appIcon: appIcon,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One step on the canvas — and, when the run recorded it, the transition
/// that arrived at it.
///
/// Playing the arrow means playing the node. The frames end on the very
/// screenshot the node is already showing, so a pointer entering the node
/// rewinds it and lets it run forward into the picture that was there all
/// along: no popover, no player chrome, no layout moving on a canvas that is
/// already a dense wall of phones. Leaving parks it back on the still.
class _StepNode extends StatefulWidget {
  const _StepNode(
    this.step, {
    required this.device,
    required this.statusFallback,
    required this.onTap,
  });

  final ScenarioRunStep step;
  final Device? device;
  final Brightness statusFallback;
  final VoidCallback onTap;

  @override
  State<_StepNode> createState() => _StepNodeState();
}

class _StepNodeState extends State<_StepNode>
    with SingleTickerProviderStateMixin {
  ScenarioMotionController? _motion;

  @override
  void didUpdateWidget(_StepNode old) {
    super.didUpdateWidget(old);
    // A re-run replaces the step under this node; whatever was playing was
    // the previous run's frames, and its files are already deleted — so the
    // decoded pixels behind them are dead weight and go back now.
    if (old.step.frames != widget.step.frames) {
      _disposePlayer();
      scenarioMotionResidency.forget(old.step);
    }
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  void _disposePlayer() {
    _motion?.dispose();
    _motion = null;
  }

  void _enter() {
    if (!widget.step.hasMotion) return;
    var motion = _motion ??= ScenarioMotionController.forStep(
      widget.step,
      this,
    )!..addListener(_onFrame);
    // Warmed rather than played-into: the first pass over a recording is the
    // only one that decodes, and the pointer arriving is the earliest honest
    // moment to pay for it.
    unawaited(precacheScenarioMotion(context, widget.step));
    motion.play();
  }

  void _exit() => _motion?.rest();

  void _onFrame() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var step = widget.step;
    var motion = _motion;
    var frame = motion == null || !motion.playing
        ? null
        : scenarioFrameImage(
            ScenarioArtifactsScope.of(context),
            step,
            motion.frames[motion.index],
          );

    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: Tappable(
        onTap: widget.onTap,
        child: Column(
          children: [
            Text(
              '${step.index} · ${scenarioStepLabel(step)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // Big enough to survive the canvas's half-scale opening, small
              // enough not to shout at full scale.
              style: context.type.body.copyWith(
                fontSize: 17,
                color: scenarioStepTone(context, step),
              ),
            ),
            const Gap(FwSpacing.md),
            Expanded(
              child: FittedBox(
                fit: BoxFit.contain,
                child: FramedShot(
                  step: step,
                  device: widget.device,
                  fallbackBrightness: widget.statusFallback,
                  image: frame,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
