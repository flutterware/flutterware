import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../plugins/native/scenarios_results.dart';
import '../ui/theme.dart';

/// Where the next verb goes, drawn over the frame it acts on.
///
/// A scenario has no cursor, so a screenshot of a tap and a screenshot of a
/// screen sitting still are the same picture. Hovering a next link answers
/// the question the link's own label cannot — the label says `tap
/// "Cappuccino"`, this says *which* Cappuccino.
///
/// Three marks, not one, because the verbs make three different promises.
/// A pointer verb goes down at a point, and gets a ring. `enterText` touches
/// nothing at all — it focuses an editable and pushes a value — so it gets a
/// caret and a washed field and deliberately no finger. `scrollTo` and
/// `keyboard` act on a *region*: which pane, which way, and nothing about a
/// point. What decides is [verb], because the rect on a [ScenarioAim] means a
/// different thing for each.
///
/// Area over line, and that is measured. The step page draws a phone at
/// about a quarter of its logical size, so every stroke here is divided by
/// four before anybody sees it. A washed band survives that; a 2.5px arrow
/// across a pane does not, and neither does the difference between two marks
/// that differ only by the arrow inside them. So the region marks are told
/// apart by their fill.
///
/// Painted **inside a surface that is the app's own logical size**, like
/// [NodeHighlightPainter] and for the same reason: [ScenarioAim] is in the
/// view's logical pixels, so in that box there is no transform to apply and
/// whatever `FittedBox` or device frame sits above it is inherited.
class ScenarioAimOverlay extends StatelessWidget {
  const ScenarioAimOverlay({super.key, required this.aim, required this.verb});

  final ScenarioAim aim;

  /// What the verb was — `tap`, `tapAt`, `longPress`, `drag`, `dragFrom`,
  /// `enterText`, `scrollTo`, `keyboard`. A held press is drawn as a held
  /// press and a scroll as a scroll, because the picture is the only place a
  /// reader would learn the difference without reading the code. The point
  /// verbs need no case of their own: their box is empty by construction, and
  /// the finger drops the outline for one, leaving the ring alone.
  final String? verb;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: ScenarioAimPainter(
      aim: aim,
      verb: verb,
      color: context.colors.accent,
    ),
  );
}

class ScenarioAimPainter extends CustomPainter {
  ScenarioAimPainter({
    required this.aim,
    required this.verb,
    required this.color,
  });

  final ScenarioAim aim;
  final String? verb;
  final Color color;

  /// A fingertip, near enough: the tap target every mobile guideline asks for,
  /// so the mark stays a mark at whatever scale the phone is drawn at rather
  /// than becoming a dot on a big window and a blob on a small one.
  static const _touch = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    var box = Rect.fromLTWH(aim.x, aim.y, aim.width, aim.height);
    switch (verb) {
      case 'enterText':
        _typing(canvas, box);
      case 'scrollTo':
        _travel(canvas, box);
      case 'keyboard':
        _band(canvas, box);
      case _:
        _finger(canvas, box);
    }
  }

  /// The pointer verbs: a contact ring at the point, the resolved box behind
  /// it, a second ring for a held press, an arrow for a drag.
  void _finger(Canvas canvas, Rect box) {
    var (px, py) = aim.point;
    var point = Offset(px, py);

    // The resolved box, faintly. It is the *finder's* box — `tap('Cappuccino')`
    // resolves the word, not the card around it — so it is drawn as context
    // for the point rather than as the thing that was hit.
    //
    // A point verb has no box and says so with an empty rect, and an empty
    // rect is not nothing to `drawRect`: a 2pt stroke on it paints a dot,
    // dead centre inside the ring, that reads as a mark somebody chose. The
    // ring is the whole of what `tapAt` and `dragFrom` can honestly claim.
    if (!box.isEmpty) _outline(canvas, box);

    if ((aim.dx, aim.dy) case (var dx?, var dy?)) {
      _arrow(canvas, point, point + Offset(dx, dy));
    }

    // A held press wears a second ring: the two verbs are the same picture
    // otherwise, and which one it was changes what the app did.
    if (verb == 'longPress') {
      canvas.drawCircle(
        point,
        _touch + 6,
        Paint()
          ..color = color.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    canvas
      // White under the ring, so the mark survives an accent-coloured button.
      ..drawCircle(
        point,
        _touch,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5,
      )
      ..drawCircle(
        point,
        _touch,
        Paint()..color = color.withValues(alpha: 0.22),
      )
      ..drawCircle(
        point,
        _touch,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
  }

  /// `enterText`: the field fills, and nothing goes down at a point.
  ///
  /// No contact ring, and that is not a matter of taste — `tester.enterText`
  /// focuses the editable and pushes an editing value, without a pointer
  /// anywhere. A finger drawn here would say something that did not happen.
  ///
  /// And no ghost of the text either, though two versions of one were
  /// drawn and looked at. The box here is the *editable*, which on a real
  /// field is exactly the line the text sits on — so a bar through it lands
  /// on the placeholder and a bar under it lands on the descenders, and both
  /// read as a smudge rather than as a promise. The wash is the mark; what
  /// gets typed belongs in the link's label, where it can be read.
  void _typing(Canvas canvas, Rect box) {
    canvas.drawRect(box, Paint()..color = color.withValues(alpha: 0.16));
    _outline(canvas, box);
    var caret = box.left + math.min(14, box.width / 8);
    for (var paint in [_halo, _stroke]) {
      canvas.drawLine(
        Offset(caret, box.top + 2),
        Offset(caret, box.bottom - 2),
        paint,
      );
    }
  }

  /// `scrollTo`: which pane moves, and which way what you are looking for is.
  ///
  /// The band says *further this way*, which is the one thing about a scroll
  /// a picture can say without ambiguity — an arrow across the pane reads
  /// equally as "the content travels down" and "the thing you want is down".
  ///
  /// No direction means the verb moves nothing: the target is already wholly
  /// inside the pane, and then the rect is the *target* rather than the
  /// viewport — so the mark is the thing itself, boxed where it stands.
  void _travel(Canvas canvas, Rect box) {
    if (_toward case var toward?) {
      _outline(canvas, box, alpha: 0.45);
      var depth = math.min(190.0, box.shortestSide * 0.45);
      var band = switch (toward) {
        AxisDirection.up => Rect.fromLTWH(box.left, box.top, box.width, depth),
        AxisDirection.down => Rect.fromLTWH(
          box.left,
          box.bottom - depth,
          box.width,
          depth,
        ),
        AxisDirection.left => Rect.fromLTWH(
          box.left,
          box.top,
          depth,
          box.height,
        ),
        AxisDirection.right => Rect.fromLTWH(
          box.right - depth,
          box.top,
          depth,
          box.height,
        ),
      };
      var angle = _angleOf(toward);
      var away = Offset.fromDirection(angle);
      canvas.drawRect(
        band,
        Paint()
          ..shader = ui.Gradient.linear(
            band.center - away * (band.shortestSide / 2),
            band.center + away * (band.shortestSide / 2),
            [color.withValues(alpha: 0), color.withValues(alpha: 0.3)],
          ),
      );
      var edge = band.center + away * (band.shortestSide / 2);
      for (var i = 0; i < 2; i++) {
        _chevron(canvas, edge - away * (34 + i * 46), angle);
      }
      return;
    }
    _outline(canvas, box);
  }

  /// `keyboard`: the band the stage is about to take, or about to give back.
  ///
  /// Filled for one and hollow for the other, because at the size this is
  /// seen at the wedge inside is the first thing to go and the two verbs
  /// would otherwise be the same picture.
  void _band(Canvas canvas, Rect box) {
    var rising = _toward == AxisDirection.up;
    canvas.drawRect(
      box,
      Paint()
        ..shader = ui.Gradient.linear(
          rising ? box.bottomCenter : box.topCenter,
          rising ? box.topCenter : box.bottomCenter,
          [
            color.withValues(alpha: rising ? 0.32 : 0.2),
            color.withValues(alpha: 0.02),
          ],
        ),
    );
    for (var paint in [_halo, _stroke..strokeWidth = 4]) {
      canvas.drawLine(box.topLeft, box.topRight, paint);
    }
    _wedge(canvas, box.center, rising ? -math.pi / 2 : math.pi / 2);
  }

  AxisDirection? get _toward => switch (aim.toward) {
    'up' => AxisDirection.up,
    'down' => AxisDirection.down,
    'left' => AxisDirection.left,
    'right' => AxisDirection.right,
    _ => null,
  };

  /// Screen angles, where `y` grows downward: `down` is a quarter turn on
  /// from `right`, not back from it.
  double _angleOf(AxisDirection toward) => switch (toward) {
    AxisDirection.right => 0,
    AxisDirection.down => math.pi / 2,
    AxisDirection.left => math.pi,
    AxisDirection.up => -math.pi / 2,
  };

  void _outline(Canvas canvas, Rect box, {double alpha = 0.6}) =>
      canvas.drawRect(
        box,
        Paint()
          ..color = color.withValues(alpha: alpha)
          // Two logical pixels because the phone is drawn at about a quarter
          // size on the step page, where a hairline is a rumour.
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );

  Paint get _stroke => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round;

  Paint get _halo => Paint()
    ..color = Colors.white.withValues(alpha: 0.55)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5.5
    ..strokeCap = StrokeCap.round;

  /// The travel of a drag: a line out of the contact ring's edge to where the
  /// finger let go, with a head on it. From the edge rather than the centre,
  /// so the ring stays a ring.
  void _arrow(Canvas canvas, Offset from, Offset to) {
    var line = to - from;
    if (line.distance <= _touch) return;
    var direction = math.atan2(line.dy, line.dx);
    var start = from + Offset.fromDirection(direction, _touch);
    var stroke = _stroke;
    var halo = _halo;
    const head = 11.0;
    var wings = [
      to - Offset.fromDirection(direction - 0.4, head),
      to - Offset.fromDirection(direction + 0.4, head),
    ];
    for (var paint in [halo, stroke]) {
      canvas.drawLine(start, to, paint);
      for (var wing in wings) {
        canvas.drawLine(to, wing, paint);
      }
    }
  }

  /// A chevron with a body rather than a stroke, pointing along [angle]: at
  /// the size the step page draws a phone, a 2.5px line is a third of a
  /// device pixel.
  void _chevron(Canvas canvas, Offset tip, double angle) {
    const span = 44.0;
    const lift = 30.0;
    const thick = 15.0;
    _rotated(canvas, tip, angle, () {
      var path = Path()
        ..moveTo(-span, -lift)
        ..lineTo(0, 0)
        ..lineTo(span, -lift)
        ..lineTo(span, -lift + thick)
        ..lineTo(0, thick)
        ..lineTo(-span, -lift + thick)
        ..close();
      _solid(canvas, path);
    });
  }

  /// A filled triangle, for the same reason the chevron has a body.
  void _wedge(Canvas canvas, Offset centre, double angle) {
    const half = 46.0;
    const rise = 52.0;
    _rotated(canvas, centre, angle, () {
      var path = Path()
        ..moveTo(0, rise)
        ..lineTo(-half, 0)
        ..lineTo(half, 0)
        ..close();
      _solid(canvas, path);
    });
  }

  /// Runs [draw] with the origin at [about] and local `+y` pointing along
  /// [angle], so a shape is authored once and aimed four ways.
  void _rotated(Canvas canvas, Offset about, double angle, VoidCallback draw) {
    canvas
      ..save()
      ..translate(about.dx, about.dy)
      ..rotate(angle - math.pi / 2);
    draw();
    canvas.restore();
  }

  /// A shape and the white it needs to survive a coloured surface.
  void _solid(Canvas canvas, Path path) => canvas
    ..drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round,
    )
    ..drawPath(path, Paint()..color = color);

  @override
  bool shouldRepaint(ScenarioAimPainter old) =>
      old.aim != aim || old.verb != verb || old.color != color;
}
