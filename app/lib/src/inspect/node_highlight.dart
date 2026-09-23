import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Draws a box and its label above it — the inspector's rectangle, painted
/// **inside a surface that is the guest's logical size**: the rects handed in
/// are in the guest's own coordinates, so in that box the painter needs no
/// transform and inherits whatever `FittedBox` or device frame sits above it.
///
/// It takes a plain rect and label rather than a tree node because three
/// sources feed it: the widget tree's layout boxes, the semantics tree's node
/// rects, and — on the catalog's live preview — the guest's own last-frame
/// box, which wins over the tree's because the tree is of the build it was
/// read from and anything animating has already moved. Deciding *which* rect
/// is the host's knowledge; drawing it is this painter's, once.
class NodeHighlightPainter extends CustomPainter {
  NodeHighlightPainter({
    required this.rect,
    required this.label,
    required this.color,
  });

  final Rect? rect;

  /// What the box is — a widget type, a semantics label — because a rectangle
  /// alone does not say which of the four boxes stacked at this corner you
  /// have got.
  final String? label;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect case var rect?) {
      canvas
        ..drawRect(rect, Paint()..color = color.withValues(alpha: 0.18))
        ..drawRect(
          rect,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );

      if (label case var text? when text.isNotEmpty) {
        var label = TextPainter(
          text: TextSpan(
            text: ' $text ',
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Above the box, or inside it when there is no room above — a label
        // off the top of the picture names nothing.
        var top = rect.top >= label.height ? rect.top - label.height : rect.top;
        var left = rect.left
            .clamp(0.0, math.max(0.0, size.width - label.width))
            .toDouble();
        canvas.drawRect(
          Rect.fromLTWH(left, top, label.width, label.height),
          Paint()..color = color,
        );
        label.paint(canvas, Offset(left, top));
      }
    }
  }

  @override
  bool shouldRepaint(NodeHighlightPainter old) =>
      old.rect != rect || old.label != label || old.color != color;
}
