import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/stage_view.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  /// The point of the frame shown at [at], a fraction of the box.
  Offset under(StageView view, Offset at) => view.origin + at / view.zoom;

  test('zooming keeps what is under the pointer under it', () {
    var view = StageView.fit.zoomedAt(4, const Offset(0.25, 0.75));

    expect(view.zoom, 4);
    expect(
      under(view, const Offset(0.25, 0.75)),
      offsetMoreOrLessEquals(const Offset(0.25, 0.75)),
    );
  });

  test('zooming out stops at the whole frame', () {
    var view = StageView.fit
        .zoomedAt(4, const Offset(0.9, 0.9))
        .zoomedAt(0.01, const Offset(0.1, 0.1));

    expect(view.isFit, isTrue);
    expect(view.origin, offsetMoreOrLessEquals(Offset.zero));
  });

  test('a drag stops at the edge of the frame', () {
    var view = StageView.fit
        .zoomedAt(2, const Offset(0.5, 0.5))
        .panned(const Offset(10, -10));

    expect(view.origin, offsetMoreOrLessEquals(const Offset(0, 0.5)));
  });

  test('going to a region shows it, with room around it', () {
    var region = const DiffRect(
      x: 1500,
      y: 20,
      width: 20,
      height: 20,
      pixels: 400,
    );
    var view = StageView.around(region, 1600, 900);

    expect(view.zoom, greaterThan(4));
    var shown = view.origin & Size.square(1 / view.zoom);
    expect(shown.contains(const Offset(1500 / 1600, 20 / 900)), isTrue);
    expect(shown.contains(const Offset(1520 / 1600, 40 / 900)), isTrue);
    // At the frame's top right, and never past it.
    expect(shown.right, lessThanOrEqualTo(1 + 1e-9));
    expect(shown.top, greaterThanOrEqualTo(-1e-9));
  });

  test('a region as large as the frame is the whole frame', () {
    var region = const DiffRect(x: 0, y: 0, width: 400, height: 800, pixels: 1);

    expect(StageView.around(region, 400, 800).isFit, isTrue);
  });
}
