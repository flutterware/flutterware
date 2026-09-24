import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// How the top of a drink looks from above — which is how a menu shows it.
enum DrinkTop {
  /// A heart poured into the foam.
  heart,

  /// A tulip: three stacked pours and a line pulled through them.
  tulip,

  /// Foam dusted with spice.
  dusted,

  /// A glass with ice and a straw, no saucer.
  iced,

  /// A heart with a syrup drizzle across it.
  drizzle,
}

/// The palette one drink is painted with.
class DrinkLook {
  const DrinkLook({
    required this.top,
    required this.liquid,
    required this.foam,
    required this.ground,
  });

  final DrinkTop top;

  /// The coffee, tea or syrup under the foam.
  final Color liquid;

  /// The pour on top of it.
  final Color foam;

  /// The round ground the cup sits on, top-left to bottom-right.
  final (Color, Color) ground;
}

/// A drink seen from above: the cup on its saucer, on a round ground.
///
/// Painted rather than shipped as bitmaps, so it is sharp at any size, the
/// same on every machine, and the demo carries no image whose licence anyone
/// has to check.
class DrinkArt extends StatelessWidget {
  const DrinkArt(
    this.look, {
    super.key,
    required this.size,
    this.ground = true,
  });

  final DrinkLook look;
  final double size;

  /// Whether to paint the round ground behind the cup. Off where the cup sits
  /// on a surface of its own, like the drink screen's header.
  final bool ground;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _DrinkPainter(look, ground: ground)),
  );
}

class _DrinkPainter extends CustomPainter {
  const _DrinkPainter(this.look, {required this.ground});

  final DrinkLook look;
  final bool ground;

  static const _porcelain = Color(0xFFFFFCF8);
  static const _saucer = Color(0xFFF4ECE2);
  static const _rim = Color(0xFFE3D6C7);

  @override
  void paint(Canvas canvas, Size size) {
    var u = size.shortestSide / 2;
    var c = size.center(Offset.zero);

    if (ground) {
      canvas.drawCircle(
        c,
        u,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [look.ground.$1, look.ground.$2],
          ).createShader(Rect.fromCircle(center: c, radius: u)),
      );
    }

    if (look.top == DrinkTop.iced) {
      _glass(canvas, c, u);
      return;
    }

    // The saucer, and the shadow the cup throws onto it.
    _shadow(canvas, c + Offset(u * 0.04, u * 0.07), u * 0.8);
    canvas.drawCircle(c, u * 0.8, Paint()..color = _saucer);
    canvas.drawCircle(
      c,
      u * 0.64,
      Paint()
        ..color = _rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.018,
    );

    // The handle, at four o'clock, under the cup.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(math.pi / 5);
    var handle = RRect.fromRectAndRadius(
      Rect.fromLTWH(u * 0.5, -u * 0.1, u * 0.34, u * 0.2),
      Radius.circular(u * 0.1),
    );
    canvas.drawRRect(handle, Paint()..color = _porcelain);
    canvas.drawRRect(
      handle,
      Paint()
        ..color = _rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.02,
    );
    canvas.restore();

    _shadow(canvas, c + Offset(u * 0.02, u * 0.04), u * 0.6);
    canvas.drawCircle(c, u * 0.6, Paint()..color = _porcelain);
    canvas.drawCircle(
      c,
      u * 0.6,
      Paint()
        ..color = _rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.022,
    );

    // The drink, darker at the wall, where a crema is.
    var liquid = u * 0.5;
    canvas.drawCircle(
      c,
      liquid,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(look.liquid, Colors.white, 0.12)!,
            look.liquid,
            Color.lerp(look.liquid, Colors.black, 0.28)!,
          ],
          stops: const [0, 0.7, 1],
        ).createShader(Rect.fromCircle(center: c, radius: liquid)),
    );

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: c, radius: liquid)),
    );
    switch (look.top) {
      case DrinkTop.heart:
        _heart(canvas, c + Offset(0, u * 0.02), u * 0.34, look.foam);
      case DrinkTop.tulip:
        _tulip(canvas, c, u);
      case DrinkTop.dusted:
        _dusted(canvas, c, u);
      case DrinkTop.drizzle:
        _heart(canvas, c + Offset(0, u * 0.02), u * 0.32, look.foam);
        _drizzle(canvas, c, u);
      case DrinkTop.iced:
        break;
    }
    canvas.restore();

    // A glint on the rim, top-left, so the cup reads as glazed.
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: u * 0.555),
      math.pi * 1.05,
      math.pi * 0.35,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = u * 0.03,
    );
  }

  void _shadow(Canvas canvas, Offset center, double radius) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFF2B1A10).withValues(alpha: 0.22)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.06),
    );
  }

  /// A heart, point down, its lobes [r] apart.
  static void _heart(Canvas canvas, Offset c, double r, Color color) {
    var path = Path()
      ..moveTo(c.dx, c.dy + r * 0.95)
      ..cubicTo(
        c.dx - r * 1.35,
        c.dy + r * 0.05,
        c.dx - r * 0.95,
        c.dy - r * 1.05,
        c.dx,
        c.dy - r * 0.45,
      )
      ..cubicTo(
        c.dx + r * 0.95,
        c.dy - r * 1.05,
        c.dx + r * 1.35,
        c.dy + r * 0.05,
        c.dx,
        c.dy + r * 0.95,
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _tulip(Canvas canvas, Offset c, double u) {
    var paint = Paint()..color = look.foam;
    for (var (dy, r) in [(0.22, 0.2), (0.02, 0.24), (-0.2, 0.2)]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: c + Offset(0, u * dy),
          width: u * r * 2.4,
          height: u * r * 1.5,
        ),
        paint,
      );
      // The line between two pours, where the liquid shows through.
      canvas.drawArc(
        Rect.fromCenter(
          center: c + Offset(0, u * (dy + 0.07)),
          width: u * r * 2.0,
          height: u * r * 1.2,
        ),
        math.pi * 1.1,
        math.pi * 0.8,
        false,
        Paint()
          ..color = look.liquid
          ..style = PaintingStyle.stroke
          ..strokeWidth = u * 0.025,
      );
    }
    canvas.drawLine(
      c + Offset(0, -u * 0.36),
      c + Offset(0, u * 0.4),
      Paint()
        ..color = look.foam
        ..strokeWidth = u * 0.03
        ..strokeCap = StrokeCap.round,
    );
  }

  void _dusted(Canvas canvas, Offset c, double u) {
    canvas.drawCircle(c, u * 0.4, Paint()..color = look.foam);
    // Spice, scattered by a rule rather than by chance, so every capture of
    // this cup is the same picture.
    var dust = Paint()..color = look.liquid.withValues(alpha: 0.75);
    for (var i = 0; i < 46; i++) {
      var angle = i * 2.399963;
      var distance = u * 0.36 * math.sqrt((i + 0.5) / 46);
      canvas.drawCircle(
        c + Offset(math.cos(angle), math.sin(angle)) * distance,
        u * (0.012 + (i % 3) * 0.005),
        dust,
      );
    }
    // A star anise, off-centre.
    var star = Paint()..color = const Color(0xFF6B3A1E);
    var at = c + Offset(u * 0.12, -u * 0.1);
    for (var arm = 0; arm < 8; arm++) {
      var angle = arm * math.pi / 4;
      canvas.drawOval(
        Rect.fromCenter(
          center: at + Offset(math.cos(angle), math.sin(angle)) * u * 0.055,
          width: u * 0.1,
          height: u * 0.05,
        ),
        star,
      );
    }
  }

  void _drizzle(Canvas canvas, Offset c, double u) {
    var paint = Paint()
      ..color = Color.lerp(look.liquid, Colors.black, 0.25)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = u * 0.03
      ..strokeCap = StrokeCap.round;
    var path = Path()..moveTo(c.dx - u * 0.42, c.dy - u * 0.12);
    for (var i = 0; i < 5; i++) {
      var x = c.dx - u * 0.34 + i * u * 0.17;
      path.quadraticBezierTo(
        x,
        c.dy + (i.isEven ? u * 0.3 : -u * 0.3),
        x + u * 0.085,
        c.dy + (i.isEven ? -u * 0.05 : u * 0.05),
      );
    }
    canvas.drawPath(path, paint);
  }

  void _glass(Canvas canvas, Offset c, double u) {
    _shadow(canvas, c + Offset(u * 0.04, u * 0.08), u * 0.66);
    // The glass wall, then the coffee inside it.
    canvas.drawCircle(
      c,
      u * 0.66,
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );
    canvas.drawCircle(
      c,
      u * 0.66,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.03,
    );
    canvas.drawCircle(
      c,
      u * 0.56,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(look.liquid, Colors.white, 0.1)!,
            Color.lerp(look.liquid, Colors.black, 0.3)!,
          ],
        ).createShader(Rect.fromCircle(center: c, radius: u * 0.56)),
    );

    var ice = Paint()..color = Colors.white.withValues(alpha: 0.42);
    var edge = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = u * 0.018;
    for (var (dx, dy, turn) in [
      (-0.2, -0.16, 0.3),
      (0.18, -0.2, -0.2),
      (-0.02, 0.2, 0.1),
    ]) {
      canvas.save();
      canvas.translate(c.dx + u * dx, c.dy + u * dy);
      canvas.rotate(turn);
      var cube = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: u * 0.3, height: u * 0.3),
        Radius.circular(u * 0.06),
      );
      canvas.drawRRect(cube, ice);
      canvas.drawRRect(cube, edge);
      canvas.restore();
    }

    // The straw, seen end-on, with the cream it was dipped through.
    var straw = c + Offset(u * 0.26, u * 0.18);
    canvas.drawCircle(straw, u * 0.08, Paint()..color = look.foam);
    canvas.drawCircle(
      straw,
      u * 0.045,
      Paint()..color = Color.lerp(look.liquid, Colors.black, 0.4)!,
    );
  }

  @override
  bool shouldRepaint(_DrinkPainter old) =>
      old.look != look || old.ground != ground;
}
