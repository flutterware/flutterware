import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/store.dart';

/// Which frame a project that declared none gets, per set.
///
/// The rule matters more than it looks: it is what decides whether an App Store
/// screenshot is the app's own pixels or a composition around them, and it is
/// read at compose time for every shot of every set.
StoreShot _shot(StoreTarget target) => StoreShot(
  image: MemoryImage(_pixel),
  imageSize: Size(target.device.width, target.device.height),
  slug: 'home',
  index: 1,
  total: 1,
  locale: const Locale('en'),
  device: target.device,
  canvas: target.canvas,
);

/// A 1×1 PNG. The frame under test draws whatever it is handed; what matters
/// here is the chrome over it, so the cheapest decodable image will do.
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
  'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  var appStore = const AppStoreListing(locales: {'en': 'en-US'});
  var play = const PlayListing(locales: {'en': 'en-US'});

  group('defaultStoreFrame', () {
    test('gives Apple a pane of glass, not a composition', () {
      for (var target in appStore.targets) {
        expect(
          defaultStoreFrame(_shot(target)),
          isA<PlainStoreFrame>(),
          reason:
              '${target.id} would gain an invented ground and device body, '
              'which is a marketing decision nobody asked for',
        );
      }
    });

    test("composes Play's phone, whose canvas is not its device", () {
      var targets = {for (var t in play.targets) t.id: t};
      expect(
        defaultStoreFrame(_shot(targets['phone']!)),
        isA<DefaultStoreFrame>(),
      );
      // 800×1280 at ratio 2 is Play's own recommended 10" size, so nothing is
      // forced here either.
      expect(
        defaultStoreFrame(_shot(targets['tablet-10']!)),
        isA<PlainStoreFrame>(),
      );
    });

    test('frames every set either way', () {
      // A status bar is not marketing, so no set is handed over unframed any
      // more. What varies is which frame, never whether there is one.
      for (var target in [...appStore.targets, ...play.targets]) {
        expect(defaultStoreFrame(_shot(target)), isA<StoreFrame>());
      }
    });
  });

  group('DefaultStoreFrame composition', () {
    /// The device body's rect on the canvas, in logical pixels.
    ///
    /// Found by the one `BoxFit.fill` image in the tree, which is the capture:
    /// it fills the body exactly, so its rect is the body's.
    Future<(Rect, Size)> layOut(WidgetTester tester, String? headline) async {
      var target = {for (var t in play.targets) t.id: t}['phone']!;
      var shot = _shot(target);
      // The canvas is taller than a test surface, and a `SizedBox` under tight
      // constraints is silently shrunk to fit — which would make every number
      // below a measurement of the default 800×600 instead.
      tester.view.physicalSize = Size(
        shot.canvas.width.toDouble(),
        shot.canvas.height.toDouble(),
      );
      tester.view.devicePixelRatio = shot.canvas.pixelRatio;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        StoreFrameStage(
          shot: shot,
          child: DefaultStoreFrame(shot, headline: headline),
        ),
      );

      return (
        tester.getRect(
          find.byWidgetPredicate((w) => w is Image && w.fit == BoxFit.fill),
        ),
        Size(shot.canvas.logicalWidth, shot.canvas.logicalHeight),
      );
    }

    // A consumer measured the headline-less export and found the device
    // floating with 42 pixels of ground under it — the whole phone visible,
    // bottom corners and gesture bar included, top-aligned under an
    // asymmetric margin. The comment in the frame said it bled. Both cases
    // are pinned here because the two differ in the margins, and it was the
    // margins that decided it.
    for (var (label, headline) in [
      ('with a headline', 'Order ahead, skip the queue'),
      ('with none', null),
    ]) {
      testWidgets('the body bleeds off the bottom edge, $label', (
        tester,
      ) async {
        var (body, canvas) = await layOut(tester, headline);

        expect(
          body.bottom,
          greaterThan(canvas.height),
          reason:
              'the device stops ${canvas.height - body.bottom} logical pixels '
              'short of the canvas, so it reads as stranded rather than as a '
              'body running off the edge',
        );
        // Off the bottom only: an overflow the sides shared would be a
        // cropped picture, which is the one thing a store shot may not be.
        expect(body.left, greaterThanOrEqualTo(0));
        expect(body.right, lessThanOrEqualTo(canvas.width));
      });
    }

    // The failure the aspect ratio exists to prevent, and the one that hides
    // best: a body stretched to fill its space paints the capture through
    // `BoxFit.fill`, so the phone inside comes out a little short and wide and
    // nothing about the picture says so.
    for (var (label, headline) in [
      ('with a headline', 'Order ahead, skip the queue'),
      ('with none', null),
    ]) {
      testWidgets('the capture keeps the device aspect ratio, $label', (
        tester,
      ) async {
        var (body, _) = await layOut(tester, headline);
        var device = Devices.androidTall;

        expect(
          body.width / body.height,
          closeTo(device.width / device.height, 0.001),
        );
      });
    }

    testWidgets('no caption buys the device width, not empty ground', (
      tester,
    ) async {
      var (bare, canvas) = await layOut(tester, null);
      var (captioned, _) = await layOut(tester, 'Order ahead');

      expect(bare.width, greaterThan(captioned.width));
      expect(bare.top, lessThan(captioned.top));
      expect(bare.width, lessThan(canvas.width));
    });
  });

  group('PlainStoreFrame', () {
    testWidgets('draws the capture at its own size, chrome over it', (
      tester,
    ) async {
      var target = appStore.targets.first;
      var shot = _shot(target);
      await tester.pumpWidget(
        StoreFrameStage(shot: shot, child: PlainStoreFrame(shot)),
      );

      // Nothing resampled: an uncomposed canvas is its device's own output, so
      // the frame's scale is exactly one and the store receives the bytes the
      // app painted.
      expect(shot.canvas.logicalWidth, shot.imageSize.width);
      expect(find.byType(StatusChrome), findsOneWidget);
      expect(find.text('9:41'), findsOneWidget);
    });
  });
}
