import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// The reading order, drawn on the picture: a numbered disc on each utterance,
/// joined in traversal order by a thin line. The numbers are the script's own
/// row indices, so the list and the picture answer each other — row 4 is disc
/// 4, wherever the screen put it.
///
/// Rects arrive in screen logical coordinates, the space every overlay here
/// paints in.
class FocusOrderPainter extends CustomPainter {
  FocusOrderPainter({
    required this.rects,
    required this.color,
    required this.onColor,
    required this.haloColor,
  });

  final List<Rect> rects;
  final Color color;

  /// The number on the disc.
  final Color onColor;

  /// The ring separating a disc from whatever pixel it lands on.
  final Color haloColor;

  static const _radius = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (rects.isEmpty) return;
    var centers = [for (var rect in rects) rect.center];

    var line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: 0.55);
    var path = Path()..moveTo(centers.first.dx, centers.first.dy);
    for (var center in centers.skip(1)) {
      path.lineTo(center.dx, center.dy);
    }
    canvas.drawPath(path, line);

    var halo = Paint()..color = haloColor;
    var disc = Paint()..color = color;
    for (var (index, center) in centers.indexed) {
      canvas.drawCircle(center, _radius + 1.5, halo);
      canvas.drawCircle(center, _radius, disc);
      var text = TextPainter(
        text: TextSpan(
          text: '${index + 1}',
          style: TextStyle(
            color: onColor,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(FocusOrderPainter old) =>
      old.color != color ||
      old.onColor != onColor ||
      old.haloColor != haloColor ||
      !listEquals(old.rects, rects);
}
