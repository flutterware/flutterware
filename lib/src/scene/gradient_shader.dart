// A gradient paint as the engine takes it.
//
// Its own file because two painters will want it — a text pass today, and a
// frame's fill the day `fill` becomes a list of paints — and
// because every rule the engine has about gradients is kept here rather than
// at each call. dart:ui throws on a gradient with no stops unless it has
// exactly two colours, so the even spread the model promises is spelled out
// before the engine sees it.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'core/values.dart';
import 'flutter_bridge.dart';

/// [g] measured against [box], every colour faded by [opacity].
///
/// Needs two colours at least. A caller with fewer paints a solid instead:
/// a gradient of one colour is that colour, and the engine is not asked.
ui.Shader sceneGradientShader(SceneGradient g, Rect box, {double opacity = 1}) {
  var colors = [
    for (var c in g.colors)
      opacity == 1
          ? c.flutter
          : c.flutter.withValues(alpha: c.flutter.a * opacity),
  ];
  var stops = g.resolvedStops;
  return switch (g) {
    LinearPaint(:var begin, :var end) => ui.Gradient.linear(
      Alignment(begin.x, begin.y).withinRect(box),
      Alignment(end.x, end.y).withinRect(box),
      colors,
      stops,
    ),
    RadialPaint(:var center, :var radius) => ui.Gradient.radial(
      Offset.zero,
      math.max(radius, 0.001),
      colors,
      stops,
      ui.TileMode.clamp,
      // A circle at the origin, carried to the centre and stretched to half
      // the box on each axis: at radius 1 it reaches every edge.
      _placed(
        Alignment(center.x, center.y).withinRect(box),
        sx: math.max(box.width / 2, _minHalf),
        sy: math.max(box.height / 2, _minHalf),
      ),
    ),
    SweepPaint(:var center, :var startAngle, :var endAngle) =>
      ui.Gradient.sweep(
        Offset.zero,
        colors,
        stops,
        ui.TileMode.clamp,
        // The engine gets a sweep from its own zero, and the turn is in the
        // matrix: it misreads a negative start or one that wraps past a full
        // turn, and an editor's dial produces both. Its start must also be
        // below its end, which a drag of one past the other would break.
        0,
        _radians((endAngle - startAngle).clamp(0.01, 360)),
        // The engine's zero is three o'clock; the file's is twelve.
        _placed(
          Alignment(center.x, center.y).withinRect(box),
          radians: _radians(startAngle - 90),
        ),
      ),
  };
}

/// Half a pixel: an empty box would otherwise give the shader a singular
/// matrix, which the engine draws as nothing rather than as an error.
const _minHalf = 0.5;

/// A local matrix that scales by [sx] and [sy], turns by [radians] and then
/// moves to [at] — column-major, the way the engine reads it. Hand-built,
/// since these six numbers are the whole of what is needed.
Float64List _placed(
  Offset at, {
  double sx = 1,
  double sy = 1,
  double radians = 0,
}) {
  var cos = math.cos(radians);
  var sin = math.sin(radians);
  return Float64List.fromList([
    cos * sx, sin * sx, 0, 0, //
    -sin * sy, cos * sy, 0, 0, //
    0, 0, 1, 0, //
    at.dx, at.dy, 0, 1, //
  ]);
}

double _radians(double degrees) => degrees * math.pi / 180;
