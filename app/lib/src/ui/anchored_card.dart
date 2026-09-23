import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'theme.dart';

/// A card beside a row, with an arrow pointing back at it.
///
/// **Beside the thing, rather than on the canvas.** The canvas is where a
/// *click* lands, so a hover that changed it read as a commitment nobody made
/// — and it is 500 pixels from the pointer, with nothing between the two to
/// connect them. This is at the hand, it points at the row it belongs to, and
/// it leaves what you actually chose alone.
///
/// Shared because the catalog and the asset inspector want the identical
/// thing: a card at a fixed width beside a list, vertically on its row where
/// the window allows and pushed inside it where it does not. What they put in
/// it is not the same at all — a rendered entry, a file off disk — which is
/// exactly the split: the geometry and the chrome here, the contents theirs.
///
/// [IgnorePointer] throughout, and not incidentally: the card exists because
/// the pointer is somewhere else, and a card that could be hovered would take
/// the pointer off the row that summoned it and close itself.
class FwAnchoredCard extends StatelessWidget {
  const FwAnchoredCard({
    super.key,
    required this.anchor,
    required this.width,
    required this.child,
  });

  /// The row, in global coordinates — which are the root overlay's too.
  final Rect anchor;

  /// Fixed, which is what lets the left edge and the arrow be decided before
  /// the contents have a size.
  final double width;

  final Widget child;

  /// The gap the arrow lives in.
  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var left = math.min(
      anchor.right + _gap,
      MediaQuery.of(context).size.width - width - FwSpacing.md,
    );
    return Stack(
      children: [
        CustomSingleChildLayout(
          // Only the height is unknown — the width is fixed and the left edge
          // with it — so this exists to clamp the top against a window the card
          // might otherwise hang off the bottom of.
          delegate: _CardLayout(
            left: left,
            centre: anchor.center.dy,
            width: width,
          ),
          child: IgnorePointer(
            child: Container(
              width: width,
              decoration: BoxDecoration(
                color: colors.panel,
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(context.radii.radius),
                boxShadow: context.elevation.md,
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
        // The arrow is placed against the *row*, not against the body, so it
        // goes on pointing at what it belongs to however far the body was
        // clamped. A body tall enough to overlap its own row means the two
        // always touch.
        Positioned(
          left: left - 7,
          top: anchor.center.dy - 8,
          child: IgnorePointer(
            child: CustomPaint(
              size: const Size(8, 16),
              painter: _ArrowPainter(fill: colors.panel, edge: colors.line),
            ),
          ),
        ),
      ],
    );
  }
}

/// Where [context]'s render object is on screen, or null before it has one.
///
/// What a row hands over when the pointer arrives on it, so the card knows
/// what to point at.
Rect? globalBoxOf(BuildContext context) {
  var box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Puts the card at a fixed [left], centred on [centre] where the window
/// allows and pushed inside it where it does not.
class _CardLayout extends SingleChildLayoutDelegate {
  const _CardLayout({
    required this.left,
    required this.centre,
    required this.width,
  });

  final double left;

  /// Where the row it belongs to is, vertically.
  final double centre;

  final double width;

  static const _margin = FwSpacing.md;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: width,
        maxHeight: constraints.maxHeight - _margin * 2,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    left,
    (centre - childSize.height / 2).clamp(
      _margin,
      math.max(_margin, size.height - childSize.height - _margin),
    ),
  );

  @override
  bool shouldRelayout(_CardLayout old) =>
      old.left != left || old.centre != centre || old.width != width;
}

/// The little triangle, tip to the left, sitting on the card's edge.
class _ArrowPainter extends CustomPainter {
  _ArrowPainter({required this.fill, required this.edge});

  final Color fill;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    var path = Path()
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    // Only the two sloped edges: the third is where the body is, and a line
    // drawn there would show through as a seam.
    canvas.drawPath(
      Path()
        ..moveTo(size.width, 0)
        ..lineTo(0, size.height / 2)
        ..lineTo(size.width, size.height),
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.fill != fill || old.edge != edge;
}
