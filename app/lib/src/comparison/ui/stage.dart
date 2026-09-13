import 'dart:async';

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import 'shot_image.dart';
import '../../ui/empty_state.dart';

/// The five ways of looking at two frames.
///
/// Five, because each answers a question the others cannot. Side by side
/// says what each one *is* — with the changed regions outlined on the head, so
/// the subtle change is pointed at rather than hunted; the slider says where a
/// boundary falls; onion says
/// how far something moved; blink is the only one that finds a two-pixel shift
/// a human eye would otherwise walk past; pixels says where to look without
/// needing an eye at all — and it is the one an agent reads.
enum StageMode {
  sideBySide('side by side'),
  slider('slider'),
  onion('onion'),
  blink('blink'),
  pixels('pixels');

  const StageMode(this.label);

  final String label;
}

Key stageModeKey(StageMode mode) => ValueKey('stage.mode.${mode.name}');

const stageKey = Key('comparison-stage');

/// The cluster-box overlay, in whichever mode draws one.
const clusterBoxesKey = Key('stage.clusters');

/// Two frames in one place, five ways.
class ComparisonStage extends StatefulWidget {
  const ComparisonStage({
    super.key,
    required this.shots,
    required this.mode,
    required this.onMode,
    this.diff,
    this.onEnlarge,
  });

  final ShotPair shots;
  final StageMode mode;
  final ValueChanged<StageMode> onMode;

  /// Where the pixels moved, for the clusters overlay.
  final PixelDiff? diff;

  /// Opens these frames over the whole window. Null draws no button — the
  /// window-sized stage itself, which has nowhere bigger to go.
  final VoidCallback? onEnlarge;

  @override
  State<ComparisonStage> createState() => _ComparisonStageState();
}

class _ComparisonStageState extends State<ComparisonStage> {
  /// Where the slider's boundary sits, 0 (all base) to 1 (all head).
  var _split = 0.5;

  /// How much of head shows through in onion mode.
  var _blend = 0.5;

  /// Which side blink is showing.
  var _blinkHead = true;
  Timer? _blink;

  @override
  void initState() {
    super.initState();
    _syncBlink();
  }

  @override
  void didUpdateWidget(ComparisonStage old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) _syncBlink();
  }

  /// Only while blink is showing. A timer left running behind another mode
  /// rebuilds the whole detail pane twice a second for nothing, which on a
  /// panel that also holds a live list is hard to trace back to its cause.
  void _syncBlink() {
    _blink?.cancel();
    _blink = null;
    if (widget.mode != StageMode.blink) return;
    _blink = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() => _blinkHead = !_blinkHead);
    });
  }

  @override
  Widget build(BuildContext context) {
    var shots = widget.shots;
    var base = shots.base;
    var head = shots.head;

    return Column(
      key: stageKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // With one frame or none there is nothing to switch between, so the
        // pills are not drawn at all — five disabled ones were furniture over
        // a picture that has no modes. A lone frame can still be enlarged.
        if (base != null && head != null)
          _ModeBar(
            mode: widget.mode,
            onMode: widget.onMode,
            onEnlarge: widget.onEnlarge,
          )
        else if (base != null || head != null)
          if (widget.onEnlarge case var enlarge?) _ModeBar(onEnlarge: enlarge),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.xl),
            child: base == null || head == null
                ? _OneSided(base: base, head: head)
                : _Body(
                    mode: widget.mode,
                    base: base,
                    head: head,
                    diff: widget.diff,
                    split: _split,
                    blend: _blend,
                    blinkHead: _blinkHead,
                    onSplit: (value) => setState(() => _split = value),
                    onBlend: (value) => setState(() => _blend = value),
                  ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _blink?.cancel();
    super.dispose();
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.mode,
    required this.base,
    required this.head,
    required this.split,
    required this.blend,
    required this.blinkHead,
    required this.onSplit,
    required this.onBlend,
    this.diff,
  });

  final StageMode mode;
  final Shot base;
  final Shot head;
  final PixelDiff? diff;
  final double split;
  final double blend;
  final bool blinkHead;
  final ValueChanged<double> onSplit;
  final ValueChanged<double> onBlend;

  @override
  Widget build(BuildContext context) => switch (mode) {
    // The head carries the diff's boxes, so the default mode both shows the
    // frames and says where to look.
    StageMode.sideBySide => _Pair(base: base, head: head, diff: diff),
    StageMode.slider => _Framed(
      label: 'drag the line to compare',
      child: _Stacked(
        base: base,
        head: head,
        // **Clipped, not cross-faded.** A slider is for reading where a
        // boundary falls — a button's edge, a baseline — and a soft one is
        // exactly the thing you cannot measure against.
        clip: split,
        onClip: onSplit,
      ),
    ),
    StageMode.onion => _Framed(
      label: 'head over base',
      child: _Stacked(
        base: base,
        head: head,
        opacity: blend,
        // Under the frame and no wider than it: a blend has no boundary to
        // point at, but a control that spans a pane the picture does not still
        // reads as belonging to something else.
        //
        // Each end says which frame it is: a bare slider under two frames
        // left the reader to find out by dragging which way was which.
        blendSlider: (width) => SizedBox(
          width: width,
          child: Row(
            children: [
              const _EndLabel('base'),
              Expanded(
                child: Slider(value: blend, onChanged: onBlend),
              ),
              const _EndLabel('head'),
            ],
          ),
        ),
      ),
    ),
    StageMode.blink => _Framed(
      label: blinkHead ? 'head' : 'base',
      child: ShotView(blinkHead ? head : base),
    ),
    StageMode.pixels => _Framed(
      label: diff == null
          ? 'head'
          // "Differ", not "moved": the count is of pixels whose colour is not
          // the same, and a replaced icon moves nothing.
          : '${(diff!.fraction * 100).toStringAsFixed(2)}% of pixels differ · '
                '${diff!.clusters.length} region'
                '${diff!.clusters.length == 1 ? '' : 's'}',
      child: _Clusters(head: head, diff: diff),
    ),
  };
}

/// Base beside head, as one picture.
///
/// **One surface, and the pair centred on it.** Each frame used to sit in a
/// bordered half of its own, pushed towards the other so two portrait frames
/// on a wide pane were not a hand's width apart. The pictures were together
/// and the boxes around them were not: base read as off-centre in its box and
/// head as pinned to the left of its, which is a layout bug to anyone who does
/// not know it was meant. So the pair is laid out as one thing, each label
/// over its own frame's edge, on the same surface every other mode draws on.
///
/// Each frame fits its own half, so a frame that changed size still shows as
/// a different shape rather than being scaled to match.
class _Pair extends StatelessWidget {
  const _Pair({required this.base, required this.head, this.diff});

  final Shot base;
  final Shot head;
  final PixelDiff? diff;

  @override
  Widget build(BuildContext context) => _Surface(
    child: LayoutBuilder(
      builder: (context, constraints) {
        var half = Size(
          (constraints.maxWidth - FwSpacing.xl) / 2,
          constraints.maxHeight - _labelHeight,
        );
        var baseBox = _fit(base.aspect, half);
        var headBox = _fit(head.aspect, half);
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Labelled(
                label: 'base',
                child: SizedBox.fromSize(size: baseBox, child: ShotView(base)),
              ),
              const Gap(FwSpacing.xl),
              _Labelled(
                label: 'head',
                child: SizedBox.fromSize(
                  size: headBox,
                  child: BoxedShot(shot: head, diff: diff),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// A frame with its label over its own left edge.
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: _labelHeight,
        child: Text(
          label,
          style: context.type.micro.copyWith(color: context.colors.mut),
        ),
      ),
      child,
    ],
  );
}

/// Two frames on one rect, one clipped or faded over the other.
class _Stacked extends StatelessWidget {
  const _Stacked({
    required this.base,
    required this.head,
    this.clip,
    this.opacity = 1.0,
    this.onClip,
    this.blendSlider,
  });

  final Shot base;
  final Shot head;

  /// Fraction of the width the head frame occupies, from the left.
  final double? clip;
  final double opacity;

  /// Moves [clip]. Given, the boundary is dragged **on the frame**.
  final ValueChanged<double>? onClip;

  /// The onion control, built at the frame's own width.
  final Widget Function(double width)? blendSlider;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Both frames laid on the *base* aspect, so a head that changed size
        // shows that change as a change rather than as a different framing.
        // The control's room comes off the top first: fitting the picture to
        // the whole box and then adding a slider under it overflows by exactly
        // the slider.
        var available = Size(
          constraints.maxWidth,
          constraints.maxHeight - (blendSlider == null ? 0 : _sliderHeight),
        );
        var box = _fit(base.aspect, available);
        void moveTo(Offset local) =>
            onClip?.call((local.dx / box.width).clamp(0.0, 1.0));

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: box.width,
                height: box.height,
                child: GestureDetector(
                  // **The boundary is dragged where it is.** A slider along the
                  // bottom of a wide pane is nowhere near the line it moves,
                  // and a control that far from its effect stops feeling like
                  // it is moving the line at all.
                  onTapDown: onClip == null
                      ? null
                      : (details) => moveTo(details.localPosition),
                  onHorizontalDragUpdate: onClip == null
                      ? null
                      : (details) => moveTo(details.localPosition),
                  child: MouseRegion(
                    cursor: onClip == null
                        ? MouseCursor.defer
                        : SystemMouseCursors.resizeLeftRight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ShotView(base),
                        if (clip == null)
                          ShotView(head, opacity: opacity)
                        else ...[
                          ClipRect(
                            clipper: _LeftFraction(clip!),
                            child: ShotView(head),
                          ),
                          Positioned(
                            left: box.width * clip! - 1,
                            top: 0,
                            bottom: 0,
                            width: 2,
                            child: ColoredBox(color: colors.accent),
                          ),
                          // Which side is which, on the frame: the head is
                          // drawn left of the line and the base right of it.
                          const Positioned(
                            left: FwSpacing.xs,
                            top: FwSpacing.xs,
                            child: _SideTag('head'),
                          ),
                          const Positioned(
                            right: FwSpacing.xs,
                            top: FwSpacing.xs,
                            child: _SideTag('base'),
                          ),
                          Positioned(
                            left: box.width * clip! - 7,
                            top: box.height / 2 - 7,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: colors.accent,
                                shape: BoxShape.circle,
                                border: Border.all(color: colors.bg, width: 2),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (blendSlider case var slider?)
                SizedBox(
                  height: _sliderHeight,
                  // As wide as the frame, but never narrower than a slider
                  // with a word at each end can be used at: a phone frame is a
                  // hundred-odd pixels, and the track between its labels was a
                  // stub.
                  child: slider(
                    box.width < _sliderMinWidth
                        ? _sliderMinWidth.clamp(0, constraints.maxWidth)
                        : box.width,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Which frame a side of the slider shows, on the frame itself.
class _SideTag extends StatelessWidget {
  const _SideTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.xs,
          vertical: 1,
        ),
        child: Text(
          label,
          style: context.type.micro.copyWith(color: colors.mut),
        ),
      ),
    );
  }
}

/// Which frame an end of the onion slider takes you to.
class _EndLabel extends StatelessWidget {
  const _EndLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: context.type.micro.copyWith(color: context.colors.mut),
  );
}

class _LeftFraction extends CustomClipper<Rect> {
  const _LeftFraction(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftFraction old) => old.fraction != fraction;
}

/// The head frame with the changed regions boxed on it.
///
/// Boxes on the picture rather than a heat map. A reader wants to know
/// where to look, and the answer has to stay legible against whatever the
/// preview happens to be — an overlay that tints changed pixels disappears on
/// a dark screen and swamps a light one.
class _Clusters extends StatelessWidget {
  const _Clusters({required this.head, this.diff});

  final Shot head;
  final PixelDiff? diff;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        var box = _fit(head.aspect, constraints.biggest);
        return Center(
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ShotView(head),
                if (diff case var diff?)
                  CustomPaint(
                    key: clusterBoxesKey,
                    painter: _ClusterPainter(diff: diff, color: colors.amber),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A frame with the changed regions boxed on it, wherever it hangs.
///
/// Give it the frame's own box: the painter scales the diff to whatever this
/// is laid out at, so it lands on the pixels only when the picture fills it.
/// **Outlines only, no wash**: side by side is where the two frames' true
/// colours are read against each other, and a tint over the changed regions
/// falsifies exactly the pixels being judged.
///
/// Public for the findings list, whose thumbnails point at the change the same
/// way.
class BoxedShot extends StatelessWidget {
  const BoxedShot({super.key, required this.shot, this.diff});

  final Shot shot;
  final PixelDiff? diff;

  @override
  Widget build(BuildContext context) {
    if (diff case var diff?) {
      // **Expanded, or the boxes miss.** A loose stack let the picture lay
      // itself out at its own size, so the frame came out smaller than the
      // base beside it and the painter scaled the diff to a rectangle the
      // picture did not fill.
      return Stack(
        fit: StackFit.expand,
        children: [
          ShotView(shot),
          Positioned.fill(
            child: CustomPaint(
              key: clusterBoxesKey,
              painter: _ClusterPainter(
                diff: diff,
                color: context.colors.amber,
                wash: false,
              ),
            ),
          ),
        ],
      );
    }
    return ShotView(shot);
  }
}

class _ClusterPainter extends CustomPainter {
  const _ClusterPainter({
    required this.diff,
    required this.color,
    this.wash = true,
  });

  final PixelDiff diff;
  final Color color;

  /// Whether the boxes are filled as well as outlined.
  final bool wash;

  @override
  void paint(Canvas canvas, Size size) {
    if (diff.width == 0 || diff.height == 0) return;
    var scaleX = size.width / diff.width;
    var scaleY = size.height / diff.height;
    var stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    var fill = Paint()..color = color.withValues(alpha: 0.16);
    for (var rect in diff.clusters) {
      // Grown by a pixel so a one-pixel cluster is a box you can see rather
      // than a line you cannot.
      var box = Rect.fromLTWH(
        rect.x * scaleX - 1,
        rect.y * scaleY - 1,
        rect.width * scaleX + 2,
        rect.height * scaleY + 2,
      );
      if (wash) canvas.drawRect(box, fill);
      canvas.drawRect(box, stroke);
    }
  }

  @override
  bool shouldRepaint(_ClusterPainter old) =>
      old.diff != diff || old.color != color || old.wash != wash;
}

/// One frame, when only one side has one.
class _OneSided extends StatelessWidget {
  const _OneSided({this.base, this.head});

  final Shot? base;
  final Shot? head;

  @override
  Widget build(BuildContext context) {
    var only = head ?? base;
    if (only == null) {
      return const EmptyState(
        icon: Icons.compare_outlined,
        title: 'Neither side rendered',
      );
    }
    return _Framed(
      label: head != null ? 'head only' : 'base only',
      child: ShotView(only),
    );
  }
}

class _Framed extends StatelessWidget {
  const _Framed({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.type.micro.copyWith(color: colors.mut)),
        const Gap(FwSpacing.xs),
        Expanded(child: _Surface(child: child)),
      ],
    );
  }
}

/// What every mode draws its frames on.
class _Surface extends StatelessWidget {
  const _Surface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: context.colors.line),
      color: context.colors.panel,
    ),
    child: Padding(padding: const EdgeInsets.all(FwSpacing.sm), child: child),
  );
}

const enlargeStageKey = Key('stage.enlarge');

class _ModeBar extends StatelessWidget {
  const _ModeBar({this.mode, this.onMode, this.onEnlarge});

  /// Null with [onMode] for a lone frame, which has no modes to pick.
  final StageMode? mode;
  final ValueChanged<StageMode>? onMode;
  final VoidCallback? onEnlarge;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          if (onMode case var onMode?)
            for (var option in StageMode.values)
              Padding(
                padding: const EdgeInsets.only(right: FwSpacing.xs),
                child: Tappable(
                  key: stageModeKey(option),
                  onTap: option != mode ? () => onMode(option) : null,
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FwSpacing.md,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: option == mode
                          ? colors.accent.withValues(alpha: 0.12)
                          : null,
                      borderRadius: BorderRadius.circular(
                        context.radii.radiusSmall,
                      ),
                    ),
                    child: Text(
                      option.label,
                      style: context.type.micro.copyWith(
                        color: option == mode ? colors.accent : colors.mut,
                      ),
                    ),
                  ),
                ),
              ),
          const Spacer(),
          if (onEnlarge case var enlarge?)
            Tooltip(
              message: 'Enlarge (the whole window)',
              child: Tappable(
                key: enlargeStageKey,
                onTap: enlarge,
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: FwIconSize.sm,
                    color: colors.mut,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The same frames over the whole window, in the same mode.
///
/// The stage is one pane among several — a list beside it, the channels under
/// or beside it — and a phone frame drawn at a third of the window's height
/// is too small to judge a 0.3% change on. This is the one place the pictures
/// get all of it. The mode travels both ways: whatever is picked here is what
/// the pane shows when this closes.
Future<void> showEnlargedStage(
  BuildContext context, {
  required String title,
  required ShotPair shots,
  required StageMode mode,
  required ValueChanged<StageMode> onMode,
  PixelDiff? diff,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  pageBuilder: (context, _, _) => _EnlargedStage(
    title: title,
    shots: shots,
    mode: mode,
    onMode: onMode,
    diff: diff,
  ),
);

const enlargedStageKey = Key('stage.enlarged');

class _EnlargedStage extends StatefulWidget {
  const _EnlargedStage({
    required this.title,
    required this.shots,
    required this.mode,
    required this.onMode,
    this.diff,
  });

  final String title;
  final ShotPair shots;
  final StageMode mode;
  final ValueChanged<StageMode> onMode;
  final PixelDiff? diff;

  @override
  State<_EnlargedStage> createState() => _EnlargedStageState();
}

class _EnlargedStageState extends State<_EnlargedStage> {
  late var _mode = widget.mode;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    void close() => Navigator.of(context).pop();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: Material(
          key: enlargedStageKey,
          color: colors.bg,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FwSpacing.xl,
                    FwSpacing.md,
                    FwSpacing.lg,
                    FwSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: context.type.heading,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Tooltip(
                        message: 'Close (Esc)',
                        child: Tappable(
                          onTap: close,
                          borderRadius: BorderRadius.circular(
                            context.radii.radiusSmall,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(FwSpacing.xs),
                            child: Icon(
                              Icons.close_rounded,
                              size: FwIconSize.lg,
                              color: colors.mut,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.shots,
                    builder: (context, _) => ComparisonStage(
                      shots: widget.shots,
                      mode: _mode,
                      diff: widget.diff,
                      onMode: (mode) {
                        setState(() => _mode = mode);
                        widget.onMode(mode);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How much height the onion control takes off the picture.
const _sliderHeight = 40.0;

/// The narrowest the onion control is drawn, whatever the frame's width.
const _sliderMinWidth = 260.0;

/// How much height a frame's label takes over it, side by side.
const _labelHeight = 18.0;

/// The largest box of [aspect] that fits inside [available].
Size _fit(double aspect, Size available) {
  if (available.width <= 0 || available.height <= 0 || aspect <= 0) {
    return Size.zero;
  }
  var byWidth = Size(available.width, available.width / aspect);
  return byWidth.height <= available.height
      ? byWidth
      : Size(available.height * aspect, available.height);
}
