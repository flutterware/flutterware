import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutterware/comparison_report.dart';

/// Which part of the frames a stage shows.
///
/// Every frame on a stage shows the same part, so base and head stay under one
/// magnifier whichever way they are compared. Positions are fractions of a
/// frame rather than pixels: the two sides are drawn at their own sizes, and a
/// frame is drawn at a different size in every mode.
class StageView {
  const StageView({this.zoom = 1, this.center = const Offset(0.5, 0.5)});

  /// The whole frame.
  static const fit = StageView();

  /// Far enough to read single pixels of a desktop frame fitted to half a
  /// laptop window.
  static const maxZoom = 16.0;

  /// 1 is the whole frame.
  final double zoom;

  /// The point in the middle of what shows.
  final Offset center;

  bool get isFit => zoom <= 1;

  /// The top left of what shows.
  Offset get origin => center - Offset(0.5 / zoom, 0.5 / zoom);

  /// Zoomed by [factor] with the point under the pointer kept under it. [at]
  /// is that point as a fraction of the box the frame is drawn in.
  StageView zoomedAt(double factor, Offset at) {
    var next = (zoom * factor).clamp(1.0, maxZoom);
    var under = origin + at / zoom;
    return StageView(
      zoom: next,
      center: under - at / next + Offset(0.5 / next, 0.5 / next),
    )._inside();
  }

  /// Dragged by [delta], in fractions of the box.
  StageView panned(Offset delta) =>
      StageView(zoom: zoom, center: center - delta / zoom)._inside();

  /// Close on [rect] of a [width] by [height] frame, with enough of what is
  /// around it to say where it is.
  static StageView around(DiffRect rect, int width, int height) {
    if (width <= 0 || height <= 0) return fit;
    var margin = math.max(width, height) * 0.04;
    var zoom = math
        .min(
          width / (rect.width + 2 * margin),
          height / (rect.height + 2 * margin),
        )
        .clamp(1.0, maxZoom);
    return StageView(
      zoom: zoom,
      center: Offset(
        (rect.x + rect.width / 2) / width,
        (rect.y + rect.height / 2) / height,
      ),
    )._inside();
  }

  /// Never past the frame's edges: what shows is always frame.
  StageView _inside() {
    var half = 0.5 / zoom;
    return StageView(
      zoom: zoom,
      center: Offset(
        center.dx.clamp(half, 1 - half),
        center.dy.clamp(half, 1 - half),
      ),
    );
  }
}
