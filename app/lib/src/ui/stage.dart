/// What an app-under-test sits *on*, and what marks where it ends.
///
/// The problem this solves: the studio and the app it is showing you are built
/// out of the same design system, and without a ground they run together —
/// same white, edges flush with the pane's own chrome, and a demo's `Reload`
/// button two pixels from a real one. The rule is that **the app is never the
/// pane's background**: there is always a ground, and the picture always has an
/// edge.
///
/// Previews arrived at this first and four other looks were built and
/// photographed against it — a dot grid, a checkerboard, print crop marks, and
/// the flush original. Nothing switches between them: the grid and the
/// checkerboard have nowhere to live where the ground is a 12px margin, and the
/// crop marks go invisible in dark against a ground that is *lighter* than the
/// pane.
///
/// It lives in the design system rather than in previews because the same
/// question is asked wherever the studio shows you somebody else's app — the
/// run cockpit's Screen tab asks it of a photograph. Two surfaces disagreeing
/// about how deep the ground is would read as two different greys rather than
/// as one convention.
library;

import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'theme.dart';

/// How far the app is held off the pane's edges.
///
/// A constant rather than a literal at each site because sites have to agree:
/// previews pads by it *and* tells a fitted guest to render the size that
/// padding leaves.
const stageInset = FwSpacing.lg;

/// The recessed surface a staged app sits on.
///
/// Derived rather than a token: the palette has no "ground" step, and its two
/// candidates do not survive both themes — light `panel2` (#fbfbfa) is
/// *lighter* than `panel`, so a ground made of it disappears against the white
/// it is supposed to sit behind. Blending ink into the panel moves the right
/// way in both.
///
/// How deep. 5.5% was the first guess and it measured `#EBECEE` — a real step,
/// and invisible in use: against a 393pt white phone the eye reads the whole
/// stage as white and the margin as a rendering artefact. A ground has to be as
/// far below what it holds as that is above it, which is where every canvas
/// that works sits — roughly a tenth of ink between the two.
Color stageGroundColor(FwPalette colors) =>
    Color.alphaBlend(colors.ink.withValues(alpha: 0.10), colors.panel);

/// Paints the ground behind a whole stage.
///
/// A painter rather than a coloured box so it can sit outside a zoom
/// transform: the specimen then moves over the ground rather than dragging it
/// along, and magnifying reads as leaning towards the phone rather than as the
/// table leaning with you.
class StageGround extends StatelessWidget {
  const StageGround({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _GroundPainter(stageGroundColor(context.colors)),
    child: child,
  );
}

/// The edge around the app's own pixels, and the lift that puts it above the
/// ground.
///
/// Drawn only where nothing else already draws one: a device body *is* this,
/// and a border inside a silhouette would be a second frame a millimetre in.
///
/// `foregroundDecoration` for the border, not a clip. In previews the child is
/// a `Texture` — an external layer — and painting the line over its edge asks
/// nothing of the compositor, where clipping it to a rounded rect asks
/// something that has to be verified per platform.
class StageEdge extends StatelessWidget {
  const StageEdge({super.key, this.color, required this.child});

  /// The line's colour. Null is the resting one; previews turns it accent
  /// while the guest holds the keyboard.
  final Color? color;

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(boxShadow: context.elevation.sm),
    foregroundDecoration: BoxDecoration(
      border: Border.all(color: color ?? context.colors.line),
    ),
    child: child,
  );
}

class _GroundPainter extends CustomPainter {
  _GroundPainter(this.fill);

  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = fill);
  }

  @override
  bool shouldRepaint(_GroundPainter old) => old.fill != fill;
}
