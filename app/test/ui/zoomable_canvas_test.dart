import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/zoomable_canvas.dart';

/// The canvas zooms the way a browser does, on both devices.
///
/// The two paths carry opposite signs for the same physical gesture — the
/// macOS embedder negates a wheel's delta and leaves a trackpad's pan alone —
/// so a test that only exercised one of them would keep passing through
/// exactly the inconsistency this widget exists to remove. Both are here.
void main() {
  late TransformationController transform;

  Future<void> pumpCanvas(WidgetTester tester) async {
    transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ZoomableCanvas(
          transformationController: transform,
          minScale: 0.05,
          maxScale: 10,
          boundaryMargin: const EdgeInsets.all(5000),
          child: const SizedBox(width: 400, height: 400),
        ),
      ),
    );
  }

  double scale() => transform.value.getMaxScaleOnAxis();
  Offset centerOf(WidgetTester tester) =>
      tester.getCenter(find.byType(ZoomableCanvas));

  /// A trackpad's pan is a finger drag: positive dy is two fingers moving
  /// down, which scrolls a page up.
  Future<void> trackpadScroll(WidgetTester tester, double dy) async {
    var pointer = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(centerOf(tester)));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centerOf(tester), pan: Offset(0, dy)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pump();
  }

  /// A wheel's delta is the scroll itself: positive dy scrolls a page down.
  Future<void> wheelScroll(WidgetTester tester, double dy) async {
    var pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(centerOf(tester)));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pump();
  }

  testWidgets('⌘ + trackpad: fingers up zooms out, down zooms in', (
    tester,
  ) async {
    await pumpCanvas(tester);
    await simulateKeyDownEvent(LogicalKeyboardKey.metaLeft);
    addTearDown(() => simulateKeyUpEvent(LogicalKeyboardKey.metaLeft));
    await tester.pump();

    await trackpadScroll(tester, -20);
    expect(scale(), lessThan(1), reason: 'fingers up zooms out');

    await pumpCanvas(tester);
    await trackpadScroll(tester, 20);
    expect(scale(), greaterThan(1), reason: 'fingers down zooms in');
  });

  testWidgets('wheel: the same gesture zooms the same way', (tester) async {
    await pumpCanvas(tester);
    // Scrolling a page down — what two fingers moving up does — zooms out.
    await wheelScroll(tester, 20);
    expect(scale(), lessThan(1));

    await pumpCanvas(tester);
    await wheelScroll(tester, -20);
    expect(scale(), greaterThan(1));
  });

  testWidgets('trackpad without the modifier pans, and never zooms', (
    tester,
  ) async {
    await pumpCanvas(tester);
    await trackpadScroll(tester, 20);
    expect(scale(), 1);
    expect(transform.value.getTranslation().y, isNot(0));
  });
}
