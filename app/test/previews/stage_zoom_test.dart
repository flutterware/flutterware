import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/previews/stage_zoom.dart';

/// The two halves of a sharp zoom, and neither is visible in a screenshot.
///
/// The ratio is arithmetic and easy to check. The gestures are the half that
/// actually broke in use: ⌘-scroll did nothing at all on a trackpad, because a
/// trackpad has not sent `PointerScrollEvent` since Flutter 3.3 and the handler
/// watched for nothing else. A test that only ever sends a mouse wheel would
/// have passed throughout, so both device shapes are exercised here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('guestRatioFor', () {
    const phone = Size(393, 852);

    test('at rest the guest renders at the ratio the device declares', () {
      expect(guestRatioFor(phone, 3, 1), 3);
    });

    test('zooming out never renders below the device', () {
      expect(guestRatioFor(phone, 3, 0.5), 3);
    });

    test('the ratio follows the scale, so pixels match what is drawn', () {
      expect(guestRatioFor(phone, 3, 4), 12);
    });

    test('the budget caps the ratio rather than refusing the zoom', () {
      var capped = guestRatioFor(phone, 3, 1000);
      expect(capped, lessThan(3000));
      expect(
        phone.width * capped * (phone.height * capped),
        lessThanOrEqualTo(zoomPixelBudget.toDouble()),
      );
    });

    test('a device already past the budget still renders at its own ratio', () {
      // Nothing is gained by rendering a huge canvas below the resolution it
      // declares — that would make picking a big device *worse* than before
      // zoom existed.
      var huge = const Size(6000, 6000);
      expect(guestRatioFor(huge, 2, 1), 2);
    });
  });

  group('who owns a pointer', () {
    // Read by the stage to decide what to act on and by the panel to decide
    // what to withhold from the demo, so these are the cases where a preview
    // stops being usable if the two ever disagree.
    // Called, not passed: `HardwareKeyboard.instance` reads the binding, and a
    // tear-off evaluates it while the group is still being declared — before
    // any binding exists.
    tearDown(() => HardwareKeyboard.instance.clearState());

    PointerPanZoomUpdateEvent panZoom({double scale = 1.0, double pan = 0}) =>
        PointerPanZoomUpdateEvent(pan: Offset(0, pan), scale: scale);

    test("a bare two-finger scroll is the demo's — it scrolls its lists", () {
      expect(stageOwnsPointer(panZoom(pan: 40)), isFalse);
    });

    test("a bare pinch is the stage's on any machine", () {
      expect(stageOwnsPointer(panZoom(scale: 1.4)), isTrue);
    });

    test("a bare wheel is the demo's", () {
      expect(
        stageOwnsPointer(const PointerScrollEvent(scrollDelta: Offset(0, 40))),
        isFalse,
      );
    });

    test("a down is never the stage's — a tap has to reach the demo", () {
      expect(stageOwnsPointer(const PointerDownEvent()), isFalse);
    });
  });

  group('gestures', () {
    late TransformationController controller;
    late List<bool> interacting;

    Future<void> pump(WidgetTester tester) async {
      controller = TransformationController();
      interacting = [];
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: ZoomableStage(
                controller: controller,
                onInteracting: interacting.add,
                child: const Center(child: Text('stage')),
              ),
            ),
          ),
        ),
      );
    }

    double scale() => controller.value.getMaxScaleOnAxis();

    Future<void> hold(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(key);
      addTearDown(() => tester.sendKeyUpEvent(key));
    }

    testWidgets('an unmodified wheel belongs to the demo', (tester) async {
      await pump(tester);
      var pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(find.byType(ZoomableStage)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      await tester.pump();
      expect(scale(), 1, reason: 'an unmodified scroll must reach the demo');
    });

    testWidgets('a modified wheel magnifies', (tester) async {
      await pump(tester);
      await hold(tester, LogicalKeyboardKey.meta);
      var pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(find.byType(ZoomableStage)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      await tester.pump();
      expect(scale(), greaterThan(1));
    });

    testWidgets('a trackpad two-finger scroll magnifies when modified', (
      tester,
    ) async {
      // The regression this file exists for. A trackpad never sends the wheel
      // event the case above sends.
      await pump(tester);
      await hold(tester, LogicalKeyboardKey.meta);
      var pointer = TestPointer(1, PointerDeviceKind.trackpad);
      var centre = tester.getCenter(find.byType(ZoomableStage));
      await tester.sendEventToBinding(pointer.panZoomStart(centre));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(centre, pan: const Offset(0, 100)),
      );
      await tester.pump();
      expect(scale(), greaterThan(1));
    });

    testWidgets('a trackpad pinch magnifies without a modifier', (
      tester,
    ) async {
      // Pinch means zoom on every application on the machine, and nothing in a
      // demo wants it badly enough to make this one different.
      await pump(tester);
      var pointer = TestPointer(1, PointerDeviceKind.trackpad);
      var centre = tester.getCenter(find.byType(ZoomableStage));
      await tester.sendEventToBinding(pointer.panZoomStart(centre));
      await tester.sendEventToBinding(pointer.panZoomUpdate(centre, scale: 3));
      await tester.pump();
      expect(scale(), closeTo(3, 0.01));
    });

    testWidgets('zooming holds the point under the pointer still', (
      tester,
    ) async {
      // The property that makes a zoom aimable. Without it the detail you were
      // looking at slides off the edge as you go in, which reads as the feature
      // being useless rather than as one term being in the wrong space.
      await pump(tester);
      await hold(tester, LogicalKeyboardKey.meta);
      var stage = find.byType(ZoomableStage);
      var topLeft = tester.getTopLeft(stage) + const Offset(60, 90);
      var pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(topLeft);

      Offset sceneUnderPointer() {
        var local = topLeft - tester.getTopLeft(stage);
        var inverted = Matrix4.inverted(controller.value);
        var v = inverted.applyToVector3Array([local.dx, local.dy, 0]);
        return Offset(v[0], v[1]);
      }

      var before = sceneUnderPointer();
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -60)));
        await tester.pump();
      }
      expect(scale(), greaterThan(1.5));
      var after = sceneUnderPointer();
      expect(after.dx, closeTo(before.dx, 0.5));
      expect(after.dy, closeTo(before.dy, 0.5));
    });

    testWidgets('a small pinch settles back to exactly life-size', (
      tester,
    ) async {
      // A trackpad emits a pan-zoom sequence for every incidental two-finger
      // touch. Left at 1.001× the stage is not at rest: the guest renders at a
      // ratio nothing on screen justifies, and the picture is softer than it
      // was before anyone touched anything.
      await pump(tester);
      var pointer = TestPointer(1, PointerDeviceKind.trackpad);
      var centre = tester.getCenter(find.byType(ZoomableStage));
      await tester.sendEventToBinding(pointer.panZoomStart(centre));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(centre, scale: 1.005),
      );
      await tester.pump();
      expect(controller.value, Matrix4.identity());
    });

    testWidgets(
      'zooming back out returns the stage to rest, translation and all',
      (tester) async {
        // The bug this pins: zoom in, pan, zoom out. The scale clamps at 1, every
        // further notch is then a no-op, and the translation it was left with can
        // never be undone — panning is off at life-size, so nothing else could
        // undo it either. The stage was simply stuck off to one side.
        await pump(tester);
        var pointer = TestPointer(1, PointerDeviceKind.trackpad);
        var centre = tester.getCenter(find.byType(ZoomableStage));
        await tester.sendEventToBinding(pointer.panZoomStart(centre));
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(centre, scale: 4),
        );
        await tester.sendEventToBinding(pointer.panZoomEnd());
        await tester.pump();

        await tester.drag(find.byType(ZoomableStage), const Offset(90, 60));
        await tester.pumpAndSettle();
        expect(
          controller.value.getTranslation().x,
          isNot(0),
          reason:
              'the pan has to actually move something for this to prove much',
        );

        await hold(tester, LogicalKeyboardKey.meta);
        var wheel = TestPointer(2, PointerDeviceKind.mouse);
        wheel.hover(centre);
        for (var i = 0; i < 40; i++) {
          await tester.sendEventToBinding(wheel.scroll(const Offset(0, 200)));
          await tester.pump();
        }
        expect(controller.value, Matrix4.identity());
      },
    );

    testWidgets('panning is off at life-size and on once magnified', (
      tester,
    ) async {
      await pump(tester);
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .panEnabled,
        isFalse,
        reason: 'a drag that panned nothing would still be taken from the demo',
      );
      var pointer = TestPointer(1, PointerDeviceKind.trackpad);
      var centre = tester.getCenter(find.byType(ZoomableStage));
      await tester.sendEventToBinding(pointer.panZoomStart(centre));
      await tester.sendEventToBinding(pointer.panZoomUpdate(centre, scale: 4));
      await tester.pump();
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .panEnabled,
        isTrue,
      );
    });

    testWidgets('the stage says when it has taken the drag', (tester) async {
      // What the demo needs to be told, so it stops scrolling its own lists
      // under a gesture that is moving the stage over them.
      await pump(tester);
      var pointer = TestPointer(1, PointerDeviceKind.trackpad);
      var centre = tester.getCenter(find.byType(ZoomableStage));
      await tester.sendEventToBinding(pointer.panZoomStart(centre));
      await tester.sendEventToBinding(pointer.panZoomUpdate(centre, scale: 4));
      // Ended, or the trackpad's pointer is still down when the drag below
      // tries to put one down of its own.
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pump();
      interacting.clear();

      await tester.drag(find.byType(ZoomableStage), const Offset(40, 40));
      await tester.pump();
      expect(interacting, contains(true));
      expect(
        interacting.last,
        isFalse,
        reason: 'and when it has given it back',
      );
    });
  });
}
