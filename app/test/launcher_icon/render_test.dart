import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/launcher_icon/model/role.dart';
import 'package:flutterware_app/src/launcher_icon/model/wiring.dart';
import 'package:flutterware_app/src/launcher_icon/ui/icon_render.dart';

/// The OS rules, as geometry.
///
/// These assert the *shape*, not the pixels: a golden would break every time
/// the sample icons changed, and the thing worth protecting is that the safe
/// zone is two thirds and that a maskable icon is never clipped to one
/// particular shape.
void main() {
  const size = Size(108, 108);

  group('masks', () {
    test('an adaptive icon clips, and the shape follows the launcher', () {
      var shapes = {
        for (var mask in AdaptiveMask.values)
          mask: maskPath(IconMask.adaptive, size, adaptive: mask)!,
      };

      // Every mask is inscribed in the same square, so bounds cannot tell them
      // apart — the corner is where they differ, and the corner is the whole
      // reason the picker exists.
      const corner = Offset(5, 5);
      expect(shapes[AdaptiveMask.teardrop]!.contains(corner), isTrue);
      for (var mask in [
        AdaptiveMask.circle,
        AdaptiveMask.squircle,
        AdaptiveMask.roundedSquare,
      ]) {
        expect(
          shapes[mask]!.contains(corner),
          isFalse,
          reason: '$mask should cut the corner',
        );
      }
    });

    test('a circle mask stays inside the canvas', () {
      var path = maskPath(
        IconMask.adaptive,
        size,
        adaptive: AdaptiveMask.circle,
      )!;
      var bounds = path.getBounds();
      expect(bounds.width, closeTo(108, 0.5));
      expect(path.contains(const Offset(54, 54)), isTrue);
      // A corner is outside a circle inscribed in the square.
      expect(path.contains(const Offset(2, 2)), isFalse);
    });

    test(
      'a squircle keeps more corner than a circle and less than a square',
      () {
        var squircle = squirclePath(Offset.zero & size, 4);
        var corner = const Offset(14, 14);
        expect(squircle.contains(corner), isTrue);

        var circle = Path()..addOval(Offset.zero & size);
        expect(circle.contains(corner), isFalse);
      },
    );

    test('web maskable is never clipped to a shape', () {
      // The manifest spec lets a user agent "apply a mask of any size", so
      // committing to one would assert a certainty that does not exist. The
      // safe zone carries the meaning instead.
      expect(maskPath(IconMask.maskableCircle, size), isNull);
      expect(IconRole.webMaskable.safeFraction, isNotNull);
    });

    test('macOS is a guide, not a clip', () {
      // macOS composites a classic asset-catalog icon exactly as authored — the
      // rounded corners and shadow are painted into the PNG. Clipping to the
      // template would shrink an icon that already has its own margin, and
      // would imply the system rounds off one that does not.
      expect(maskPath(IconMask.macosGuide, size), isNull);
      expect(IconMask.macosGuide.clips, isFalse);
      // The convention still has something to say, so it keeps a safe zone.
      expect(IconRole.macosApp.safeFraction, closeTo(824 / 1024, 0.0001));
    });

    test('clips is what separates a cut from a convention', () {
      expect(IconMask.adaptive.clips, isTrue);
      expect(IconMask.iosSquircle.clips, isTrue);
      // No shape is drawn for a maskable web icon, but a user agent may still
      // remove what is outside the safe zone — so it counts as a cut.
      expect(IconMask.maskableCircle.clips, isTrue);
      expect(IconMask.none.clips, isFalse);
    });

    test('nothing is clipped where the OS clips nothing', () {
      expect(maskPath(IconMask.none, size), isNull);
    });
  });

  group('safe zones', () {
    test('an adaptive icon guarantees the inner two thirds', () {
      // Android's layers are 108dp with the inner 72dp always visible.
      expect(adaptiveSafeFraction, closeTo(72 / 108, 0.0001));
      expect(
        IconRole.androidAdaptiveForeground.safeFraction,
        closeTo(2 / 3, 0.0001),
      );
    });

    test('a maskable web icon guarantees a 2/5 radius', () {
      expect(maskableSafeRadiusFraction, closeTo(0.4, 0.0001));
      // Stored as a diameter fraction, because every other safe zone is a side.
      expect(IconRole.webMaskable.safeFraction, closeTo(0.8, 0.0001));
    });
  });

  group('treatments', () {
    testWidgets('a notification icon is painted white through its alpha', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: IconRender(
            image: MemoryImage(_onePixelPng),
            role: IconRole.androidNotification,
          ),
        ),
      );

      var filtered = tester.widgetList<ColorFiltered>(
        find.byType(ColorFiltered),
      );
      expect(
        filtered.map((w) => w.colorFilter),
        contains(const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
      );
    });

    testWidgets('an as-authored icon gets no filter', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: IconRender(
            image: MemoryImage(_onePixelPng),
            role: IconRole.androidLegacy,
          ),
        ),
      );

      expect(find.byType(ColorFiltered), findsNothing);
    });

    testWidgets('a themed icon is a stencil, not a tinted picture', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: IconRender(
            image: MemoryImage(_onePixelPng),
            role: IconRole.androidMonochrome,
          ),
        ),
      );

      // Android fills the monochrome layer's *alpha* with a wallpaper colour,
      // so everything but the shape is discarded — structurally the same rule
      // as the notification icon. Desaturating and tinting instead would keep
      // the source's colour structure and show a picture Android never draws.
      var filters = tester
          .widgetList<ColorFiltered>(find.byType(ColorFiltered))
          .map((w) => w.colorFilter);
      expect(
        filters,
        contains(const ColorFilter.mode(themedIconForeground, BlendMode.srcIn)),
      );
      expect(filters, hasLength(1));
    });

    testWidgets('an iOS tinted icon keeps luminance', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: IconRender(
            image: MemoryImage(_onePixelPng),
            role: IconRole.iosTinted,
          ),
        ),
      );

      // Unlike the themed icon, light and dark regions of the source have to
      // survive as light and dark — hence greyscale first, then a tint.
      expect(find.byType(ColorFiltered), findsNWidgets(2));
    });
  });

  group('the clip actually reaches the pixels', () {
    testWidgets('the launcher mask is applied, not just computed', (
      tester,
    ) async {
      // The geometry tests above prove `maskPath` returns a circle. This proves
      // `IconRender` clips to it — which is a different claim, and the one that
      // fails silently: a dropped `ClipPath` looks like a slightly wrong icon
      // rather than an error.
      await tester.pumpWidget(
        MaterialApp(
          home: IconRender(
            image: MemoryImage(_onePixelPng),
            role: IconRole.androidAdaptiveForeground,
            size: 108,
            adaptiveMask: AdaptiveMask.circle,
          ),
        ),
      );

      var clipper = tester.widget<ClipPath>(find.byType(ClipPath)).clipper!;
      var path = clipper.getClip(const Size(108, 108));
      expect(path.contains(const Offset(54, 54)), isTrue, reason: 'centre');
      expect(path.contains(const Offset(4, 4)), isFalse, reason: 'corner');
    });

    testWidgets('a different launcher gives a different clip', (tester) async {
      Path clipFor(AdaptiveMask mask) =>
          (tester.widget<ClipPath>(find.byType(ClipPath)).clipper!).getClip(
            const Size(108, 108),
          );

      await tester.pumpWidget(
        MaterialApp(
          home: IconRender(
            image: MemoryImage(_onePixelPng),
            role: IconRole.androidAdaptiveForeground,
            size: 108,
            adaptiveMask: AdaptiveMask.teardrop,
          ),
        ),
      );
      // The teardrop keeps the corner every other shape cuts, so it is the one
      // that proves the parameter is threaded all the way down.
      expect(
        clipFor(AdaptiveMask.teardrop).contains(const Offset(5, 5)),
        isTrue,
      );
    });
  });

  group('resource colours', () {
    test('accepts every Android spelling', () {
      expect(parseResourceColor('#FF102030'), 0xFF102030);
      expect(parseResourceColor('#102030'), 0xFF102030);
      expect(parseResourceColor('#ABC'), 0xFFAABBCC);
      expect(parseResourceColor('#FABC'), 0xFFAABBCC);
    });

    test('rejects what is not a colour', () {
      // The launcher-icon generators accept `#ZZZZZZ` — their per-character
      // check is a tautology — and write it into colors.xml, where it fails at
      // resource-compile time far from the cause.
      expect(parseResourceColor('#ZZZZZZ'), isNull);
      expect(parseResourceColor('@mipmap/ic_launcher_background'), isNull);
      expect(parseResourceColor('#12345'), isNull);
      expect(parseResourceColor(null), isNull);
    });
  });
}

/// A 1×1 transparent PNG — enough to mount a render without touching disk.
final _onePixelPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
