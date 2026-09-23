import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/splash/model/composition.dart';
import 'package:flutterware_app/src/splash/model/surface.dart';
import 'package:flutterware_app/src/splash/ui/splash_render.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The thin painting layer.
///
/// There is deliberately little here, because there is deliberately little in
/// [SplashRender]: every placement decision was made in `composition.dart`,
/// which is tested exhaustively without a widget in sight. What is left to
/// check is that the mapping onto `BoxFit` and `Alignment` builds and lays out
/// for every surface, and that the two things unique to this layer — the
/// Android 12 mask and the drawn hole for a missing file — are actually drawn.
void main() {
  late Directory root;
  late String logo;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('splash_render_test');
    logo = p.join(root.path, 'logo.png');
    File(logo)
        .writeAsBytesSync(img.encodePng(img.Image(width: 1024, height: 1024)));
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, SplashComposition composition) async {
    var (width, height) = splashPreviewSize(composition.surface);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: SplashRender(composition),
          ),
        ),
      ),
    );
  }

  SplashLayer layer(SplashFit fit, {bool missing = false}) => SplashLayer(
    path: 'logo.png',
    absolutePath: missing ? null : logo,
    fit: fit,
    alignment: SplashAlignment.center,
    naturalWidth: 256,
    naturalHeight: 256,
    missing: missing,
  );

  testWidgets('lays out every surface, theme and fit without overflowing', (
    tester,
  ) async {
    for (var surface in SplashSurface.values) {
      for (var theme in SplashTheme.values) {
        for (var fit in SplashFit.values) {
          await pump(
            tester,
            SplashComposition(
              surface: surface,
              theme: theme,
              enabled: true,
              backgroundColor: 0xFFFFFFFF,
              image: layer(fit),
              iconCanvas: surface == SplashSurface.android12
                  ? android12IconCanvasDp
                  : null,
              iconMaskFraction: surface == SplashSurface.android12
                  ? android12MaskFraction
                  : null,
            ),
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$surface/$theme/$fit',
          );
        }
      }
    }
  });

  testWidgets('draws the background colour when there is nothing else', (
    tester,
  ) async {
    await pump(
      tester,
      const SplashComposition(
        surface: SplashSurface.ios,
        theme: SplashTheme.light,
        enabled: true,
        backgroundColor: 0xFF1E1E1E,
      ),
    );
    expect(
      tester.widgetList<ColoredBox>(find.byType(ColoredBox)).first.color,
      const Color(0xFF1E1E1E),
    );
  });

  testWidgets('clips the Android 12 icon rather than drawing it whole', (
    tester,
  ) async {
    // The mask is the one thing this surface does that no other does, and the
    // thing people are most surprised by.
    await pump(
      tester,
      SplashComposition(
        surface: SplashSurface.android12,
        theme: SplashTheme.light,
        enabled: true,
        backgroundColor: 0xFFFFFFFF,
        image: layer(SplashFit.contain),
        iconCanvas: android12IconCanvasDp,
        iconMaskFraction: android12MaskFraction,
      ),
    );
    expect(find.byType(ClipPath), findsOneWidget);

    // The icon occupies its fixed slot, not the screen.
    var box = tester.getSize(
      find
          .ancestor(of: find.byType(ClipPath), matching: find.byType(SizedBox))
          .first,
    );
    expect(box.width, android12IconCanvasDp);
  });

  testWidgets('draws a hole where a missing file should have been', (
    tester,
  ) async {
    // A missing image that rendered as an empty splash would look like a splash
    // with no image, which is a different bug with a different fix.
    await pump(
      tester,
      SplashComposition(
        surface: SplashSurface.ios,
        theme: SplashTheme.light,
        enabled: true,
        backgroundColor: 0xFFFFFFFF,
        image: layer(SplashFit.none, missing: true),
      ),
    );
    expect(find.text('logo.png'), findsOneWidget);
  });

  testWidgets('hides the status bar only when fullscreen is set', (
    tester,
  ) async {
    Future<int> bars({required bool fullscreen}) async {
      await pump(
        tester,
        SplashComposition(
          surface: SplashSurface.android,
          theme: SplashTheme.light,
          enabled: true,
          backgroundColor: 0xFFFFFFFF,
          fullscreen: fullscreen,
        ),
      );
      return tester.widgetList(find.byType(Row)).length;
    }

    expect(await bars(fullscreen: false), greaterThan(0));
    expect(await bars(fullscreen: true), 0);
  });
}
