// The number controls of the scene editor, salvaged from the motion plugin
// where they were private to its sequencer.
//
// Three behaviours are worth naming, because each was got wrong before it was
// got right: the drag ACCUMULATES in display units so a slow drag of a few
// pixels still lands a whole millisecond instead of rounding to nothing; the
// field COMMITS ONCE on release rather than per sample, which is what lets an
// editor door coalesce a whole gesture into one undo entry; and typing an
// unparseable value REFUSES rather than writing a zero for what somebody meant.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/design/design.dart';
import 'number_shape.dart';

/// A number, edited the way its [shape] says it should be: dragged, and
/// dragged beside a slider or a dial when the property's range earns one.
///
/// [onChanged] fires per sample — the canvas is the feedback — and [onCommit]
/// once, at the end of the gesture, which is the moment an undo entry closes.
class SceneNumberField extends StatelessWidget {
  const SceneNumberField({
    super.key,
    required this.value,
    required this.shape,
    required this.onChanged,
    required this.onCommit,
    this.label,
  });

  final double value;
  final SceneNumberShape shape;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final String? label;

  void _changed(double next) => onChanged(shape.settled(next));
  void _committed(double next) => onCommit(shape.settled(next));

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label case var label?)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.xs),
            child: Text(
              label,
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
          ),
        SceneScrubNumber(
          value: value,
          shape: shape,
          onChanged: _changed,
          onCommit: _committed,
        ),
        switch (shape.editor) {
          SceneEditorShape.scrub => const SizedBox.shrink(),
          SceneEditorShape.slider => SceneBoundedSlider(
            value: value,
            shape: shape,
            onChanged: _changed,
            onCommit: _committed,
          ),
          SceneEditorShape.dial => SceneAngleDial(
            value: value,
            shape: shape,
            onChanged: _changed,
            onCommit: _committed,
          ),
        },
      ],
    );
  }
}

/// The number itself: drag it left and right, or click to type it.
class SceneScrubNumber extends StatefulWidget {
  const SceneScrubNumber({
    super.key,
    required this.value,
    required this.shape,
    required this.onChanged,
    required this.onCommit,
    this.held = false,
  });

  final double value;
  final SceneNumberShape shape;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  /// Drawn as active — a key being dragged on the timeline, say.
  final bool held;

  @override
  State<SceneScrubNumber> createState() => _SceneScrubNumberState();
}

class _SceneScrubNumberState extends State<SceneScrubNumber> {
  var _typing = false;
  late final _controller = TextEditingController();
  late final _focus = FocusNode()..addListener(_onFocus);

  /// Accumulated in display units, so a slow drag still lands whole units
  /// instead of rounding to nothing on every sample.
  double? _dragging;

  void _onFocus() {
    if (!_focus.hasFocus && _typing) _commitTyped();
  }

  void _startTyping() {
    setState(() {
      _typing = true;
      _controller.text = widget.shape.format(widget.value);
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
    _focus.requestFocus();
  }

  void _commitTyped() {
    var typed = double.tryParse(_controller.text.trim());
    setState(() => _typing = false);
    // Refuses rather than writing a zero for what somebody meant.
    if (typed == null) return;
    widget.onCommit(typed);
  }

  void _drag(double dx) {
    var next = (_dragging ?? widget.value) + dx * widget.shape.perPixel;
    _dragging = next;
    widget.onChanged(next);
  }

  void _release() {
    var settled = _dragging ?? widget.value;
    _dragging = null;
    widget.onCommit(settled);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var unit = widget.shape.unit;
    var mono = context.type.caption.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      height: 27,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(
          color: widget.held ? context.colors.accent : context.colors.line,
        ),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: _typing
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    onSubmitted: (_) => _commitTyped(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: mono,
                  ),
                ),
                if (unit.isNotEmpty)
                  Text(
                    unit,
                    style: context.type.caption.copyWith(
                      color: context.colors.mut2,
                    ),
                  ),
              ],
            )
          : MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _startTyping,
                onHorizontalDragStart: (_) => _dragging = widget.value,
                onHorizontalDragUpdate: (d) => _drag(d.delta.dx),
                onHorizontalDragEnd: (_) => _release(),
                onHorizontalDragCancel: _release,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.shape.format(widget.value),
                        style: mono,
                      ),
                    ),
                    if (unit.isNotEmpty)
                      Text(
                        unit,
                        style: context.type.caption.copyWith(
                          color: context.colors.mut2,
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// For a value whose soft range *is* its meaning — an opacity of 0.5 is half,
/// and where it sits between 0 and 1 is the whole of what you want to see.
class SceneBoundedSlider extends StatelessWidget {
  const SceneBoundedSlider({
    super.key,
    required this.value,
    required this.shape,
    required this.onChanged,
    required this.onCommit,
  });

  final double value;
  final SceneNumberShape shape;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) {
    var (min, max) = shape.range;
    return SizedBox(
      height: 22,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        ),
        child: Slider(
          // A hint, not a clamp — so a value the file already carries beyond
          // the soft range widens the slider rather than being dragged back
          // inside it the moment you touch the control.
          min: math.min(min, value),
          max: math.max(max, value),
          value: value,
          onChanged: onChanged,
          onChangeEnd: onCommit,
        ),
      ),
    );
  }
}

/// A dial, for angles.
///
/// Zero is at twelve o'clock and positive winds clockwise, matching the
/// rotation the fx plane applies. The drag accumulates the *change* in pointer
/// angle rather than snapping to it, so winding past a full turn keeps going
/// instead of wrapping back to zero, and a 540° rotation stays expressible.
class SceneAngleDial extends StatefulWidget {
  const SceneAngleDial({
    super.key,
    required this.value,
    required this.shape,
    required this.onChanged,
    required this.onCommit,
  });

  final double value;
  final SceneNumberShape shape;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  @override
  State<SceneAngleDial> createState() => _SceneAngleDialState();
}

class _SceneAngleDialState extends State<SceneAngleDial> {
  static const _size = 34.0;

  double? _lastPointer;

  double _pointerDegrees(Offset local) {
    var centre = const Offset(_size / 2, _size / 2);
    var v = local - centre;
    // Zero at twelve o'clock, clockwise positive.
    return math.atan2(v.dx, -v.dy) * 180 / math.pi;
  }

  void _update(Offset local) {
    var angle = _pointerDegrees(local);
    var last = _lastPointer;
    _lastPointer = angle;
    if (last == null) return;
    var delta = angle - last;
    // The short way round, so crossing twelve o'clock does not jump a turn.
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    widget.onChanged(widget.value + delta);
  }

  void _release() {
    _lastPointer = null;
    widget.onCommit(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: FwSpacing.xs),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _lastPointer = _pointerDegrees(d.localPosition),
          onPanUpdate: (d) => _update(d.localPosition),
          onPanEnd: (_) => _release(),
          onPanCancel: _release,
          child: CustomPaint(
            size: const Size(_size, _size),
            painter: _DialPainter(
              degrees: widget.value,
              tone: context.colors.accent,
              rim: context.colors.line,
              face: context.colors.bg,
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.degrees,
    required this.tone,
    required this.rim,
    required this.face,
  });

  final double degrees;
  final Color tone;
  final Color rim;
  final Color face;

  @override
  void paint(Canvas canvas, Size size) {
    var centre = size.center(Offset.zero);
    var radius = size.shortestSide / 2 - 1;
    var radians = degrees * math.pi / 180;

    canvas
      ..drawCircle(centre, radius, Paint()..color = face)
      ..drawCircle(
        centre,
        radius,
        Paint()
          ..color = rim
          ..style = PaintingStyle.stroke,
      )
      // The mark at twelve, so "which way" has something to be measured from.
      ..drawLine(
        centre + Offset(0, -radius),
        centre + Offset(0, -radius + 3),
        Paint()
          ..color = rim
          ..strokeWidth = 1,
      )
      ..drawLine(
        centre,
        centre + Offset(math.sin(radians), -math.cos(radians)) * (radius - 2),
        Paint()
          ..color = tone
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      )
      ..drawCircle(centre, 2, Paint()..color = tone);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.degrees != degrees ||
      old.tone != tone ||
      old.rim != rim ||
      old.face != face;
}
