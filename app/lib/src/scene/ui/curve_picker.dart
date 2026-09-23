// Picking and showing an easing, salvaged from the motion plugin.
//
// The plot SAMPLES THE CURVE ITSELF rather than drawing stored control points,
// so a name this build cannot resolve draws nothing and says so — the same
// answer the file's own parser would give. And because it samples, elastic and
// bounce (which overshoot 0..1) are plotted to what they actually reach
// instead of being clipped at the box.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../../ui/tappable.dart';

/// The curve on a key, and the menu of the ones the grammar writes.
class SceneCurvePicker extends StatelessWidget {
  const SceneCurvePicker({super.key, required this.name, required this.onPick});

  /// The curve's name, or null for the default (linear).
  final String? name;

  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => onPick(null),
          child: Text('Default', style: context.type.caption),
        ),
        for (var candidate in sceneCurvesByName.keys)
          MenuItemButton(
            onPressed: () => onPick(candidate),
            leadingIcon: Icon(
              candidate == name ? Icons.check : null,
              size: FwIconSize.sm,
              color: context.colors.accent,
            ),
            child: Text(candidate, style: context.type.caption),
          ),
      ],
      builder: (context, controller, _) => Tappable(
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: SceneCurveBox(name),
      ),
    );
  }
}

/// The easing, plotted from the curve the file names.
class SceneCurveBox extends StatelessWidget {
  const SceneCurveBox(this.name, {super.key});

  final String? name;

  @override
  Widget build(BuildContext context) {
    var name = this.name;
    var curve = name == null ? null : sceneCurvesByName[name];

    return Container(
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: Row(
        spacing: FwSpacing.lg,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: context.colors.panel2,
              borderRadius: BorderRadius.circular(context.radii.micro),
            ),
            child: curve == null
                ? null
                : CustomPaint(
                    painter: _CurvePainter(
                      curve: curve,
                      tone: context.colors.accent,
                      axis: context.colors.line,
                    ),
                  ),
          ),
          Expanded(
            child: Text(
              name == null
                  ? 'Default'
                  : curve == null
                  ? '$name — not a curve this editor writes'
                  : 'Curves.$name',
              style: context.type.caption.copyWith(
                color: curve == null && name != null
                    ? context.colors.amber
                    : context.colors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({required this.curve, required this.tone, required this.axis});

  final SceneCurve curve;
  final Color tone;
  final Color axis;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 4.0;
    var left = pad;
    var right = size.width - pad;
    var top = pad;
    var bottom = size.height - pad;

    canvas
      ..drawLine(
        Offset(left, bottom),
        Offset(right, bottom),
        Paint()..color = axis,
      )
      ..drawLine(
        Offset(left, bottom),
        Offset(left, top),
        Paint()..color = axis,
      );

    var path = Path();
    // Elastic and bounce overshoot 0..1, so the plot is scaled to what the
    // curve actually reaches rather than clipped at the box.
    var samples = [
      for (var i = 0; i <= 32; i++) (i / 32, curve.transform(i / 32)),
    ];
    var lo = math.min(0.0, samples.map((s) => s.$2).reduce(math.min));
    var hi = math.max(1.0, samples.map((s) => s.$2).reduce(math.max));
    for (var (index, (t, value)) in samples.indexed) {
      var x = left + t * (right - left);
      var y = bottom - (value - lo) / (hi - lo) * (bottom - top);
      index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = tone
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.curve != curve || old.tone != tone || old.axis != axis;
}
