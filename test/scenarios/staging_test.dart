import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// A plain `flutter test` walking a catalog, on the right surface per entry.
///
/// This is the lane a project keeps when it has an existing map-based catalog
/// and a test that pumps every entry to see that none of them throws. That test
/// needs the same fact the panel needs — a desktop entry has to be pumped on a
/// desktop-sized surface, or it reports overflows that are not real — and until
/// this was exported the only way to get it was to reimplement the device table
/// by hand, or to reach into a private function.
///
/// The canvas list here is the shape a project would keep in its own package
/// and hand to `tool/flutterware.dart` as well, which is the whole point: one
/// list, so the tool and the test cannot disagree about what a directory is
/// meant to look like.
void main() {
  const canvases = [
    PreviewCanvas('demo/mobile', devices: [Devices.iphone16]),
    PreviewCanvas('demo/desktop', devices: [Devices.wideWindow]),
    PreviewCanvas(
      'demo/tablet',
      devices: [Devices.iPad],
      orientations: [ScreenOrientation.landscape],
    ),
  ];

  /// The size the widget under test was actually laid out at.
  Size laidOutAt(WidgetTester tester) =>
      tester.element(find.byType(_Probe)).size!;

  testWidgets('the canvas is the surface the entry is pumped on', (
    tester,
  ) async {
    var reset = tester.applyCanvas(
      canvasFor(canvases, 'demo/mobile/tile.dart'),
    );
    await tester.pumpWidget(const _Probe());

    expect(laidOutAt(tester), const Size(393, 852));
    reset();
  });

  testWidgets('a desktop entry gets the rectangle its panel opens on', (
    tester,
  ) async {
    // **A declared window is offered, not staged** — see
    // [PreviewCanvas.defaultDevice] — and this surface follows the panel
    // because that is the whole point of the canvas list: a test, a screenshot
    // and the panel must agree about what a directory is for. A desktop window
    // has no size of its own; the person using it drags the corner.
    var reset = tester.applyCanvas(
      canvasFor(canvases, 'demo/desktop/dashboard.dart'),
    );
    await tester.pumpWidget(const _Probe());

    expect(laidOutAt(tester).width, previewPanelWidth.toDouble());
    reset();
  });

  testWidgets('the canvas brings its orientation with it', (tester) async {
    var reset = tester.applyCanvas(
      canvasFor(canvases, 'demo/tablet/grid.dart'),
    );
    await tester.pumpWidget(const _Probe());

    var size = laidOutAt(tester);
    expect(size.width, greaterThan(size.height));
    reset();
  });

  testWidgets('an entry under no canvas is left exactly as it was', (
    tester,
  ) async {
    // What a project gets before it declares anything, and what a subtree that
    // opts out gets after. The default test surface, untouched.
    var untouched = tester.view.physicalSize / tester.view.devicePixelRatio;

    var reset = tester.applyCanvas(canvasFor(canvases, 'demo/shared/x.dart'));
    await tester.pumpWidget(const _Probe());

    expect(laidOutAt(tester), untouched);
    reset();
  });

  testWidgets('the device decides the target platform too', (tester) async {
    // Not only the numbers: a phone canvas that still reported the host
    // platform would give a Cupertino-switching widget the wrong branch, and
    // the picture would be wrong without being the wrong size.
    var reset = tester.applyDevice(Devices.iphone16);
    await tester.pumpWidget(const _Probe());

    expect(defaultTargetPlatform, TargetPlatform.iOS);
    reset();
    expect(debugDefaultTargetPlatformOverride, isNull);
  });

  testWidgets('the reset puts the surface back', (tester) async {
    var before = tester.view.physicalSize;

    var reset = tester.applyDevice(Devices.iphone16);
    await tester.pumpWidget(const _Probe());
    expect(tester.view.physicalSize, isNot(before));

    reset();
    expect(tester.view.physicalSize, before);
  });

  testWidgets('a null canvas needs no branch around it', (tester) async {
    // The reason both take a nullable: a caller resolving a canvas per entry
    // writes one line, not an if.
    expect(tester.applyCanvas(null), isNotNull);
    expect(tester.applyDevice(null), isNotNull);
    tester.applyCanvas(null)();
  });
}

/// Something with no opinion of its own, so its laid-out size is the surface's.
class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
