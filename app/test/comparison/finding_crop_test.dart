import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/finding_face.dart';

/// What a small picture shows of a change: close enough to read, wide enough
/// to say where on the screen it is.
void main() {
  PixelDiff diff(List<DiffRect> clusters, {bool sizeChanged = false}) =>
      PixelDiff(
        width: 1600,
        height: 900,
        changedPixels: 2000,
        comparedPixels: 1600 * 900,
        sizeChanged: sizeChanged,
        clusters: clusters,
      );

  const icon = DiffRect(x: 1500, y: 20, width: 20, height: 20, pixels: 300);

  test("a small change is shown close, in the frame's shape", () {
    var crop = cropFor(diff(const [icon]))!;

    expect(1600 / crop.width, closeTo(4, 0.1));
    expect(crop.width / crop.height, closeTo(1600 / 900, 0.02));
    expect(crop.x, lessThanOrEqualTo(icon.x));
    expect(crop.x + crop.width, greaterThanOrEqualTo(icon.x + icon.width));
    // In the frame, even for a change at its edge.
    expect(crop.y, 0);
    expect(crop.x + crop.width, lessThanOrEqualTo(1600));
  });

  test('a phone frame keeps enough of its width to read', () {
    var crop = cropFor(
      PixelDiff(
        width: 393,
        height: 852,
        changedPixels: 200,
        comparedPixels: 393 * 852,
        sizeChanged: false,
        clusters: const [
          DiffRect(x: 200, y: 300, width: 24, height: 20, pixels: 200),
        ],
      ),
    )!;

    expect(crop.width, greaterThanOrEqualTo(160));
    expect(393 / crop.width, greaterThan(2));
  });

  test('changes far apart are shown by the largest one', () {
    var crop = cropFor(
      diff(const [
        DiffRect(x: 20, y: 800, width: 200, height: 40, pixels: 5000),
        icon,
      ]),
    )!;

    expect(crop.x, 0);
    expect(crop.y + crop.height, greaterThanOrEqualTo(840));
  });

  test('a change too large to gain from it is shown whole', () {
    expect(
      cropFor(
        diff(const [
          DiffRect(x: 0, y: 0, width: 1200, height: 700, pixels: 9000),
        ]),
      ),
      isNull,
    );
  });

  test('a frame that changed size is shown whole', () {
    expect(cropFor(diff(const [icon], sizeChanged: true)), isNull);
  });
}
