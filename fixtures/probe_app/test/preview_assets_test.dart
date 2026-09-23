import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/flutter_test.dart';

import '../demo/asset_smoke.dart';
import '../demo/shell.dart';

/// The claim the preview harness rests on, checked against the one demo whose
/// subject is the asset pipeline: that a preview run under a test binding still
/// **decodes real images and measures real fonts**.
///
/// It is not free. A test binding runs under FakeAsync, where an image load
/// started during build never completes because nothing turns the real event
/// loop — so a harness without the boot turn below renders this demo perfectly
/// minus its pictures, and passes. That is the failure this exists to catch,
/// and it is invisible from the outcome of the demo's own test.
void main() {
  testWidgets('a preview decodes its images and loads its fonts', (
    tester,
  ) async {
    var fonts = await loadScenarioFonts();
    // Declared by this package's pubspec, so a manifest that reached the bundle
    // brought them. Falling back to the test font would still lay this demo out
    // — differently, and without saying so.
    expect(fonts, contains('Roboto'));

    rootBundle.clear();
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: ScenarioAssetBundle(),
        child: wrapInApp(assetSmoke()),
      ),
    );

    var cache = PaintingBinding.instance.imageCache;
    expect(
      cache.pendingImageCount,
      greaterThan(0),
      reason:
          'the build asked for images, so they are in flight before the '
          'boot turn — if this is already zero the demo stopped loading any '
          'and the rest of this test proves nothing',
    );

    // The turn of the *real* event loop the harness gives every entry.
    await tester.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await tester.pumpAndSettle();

    expect(cache.pendingImageCount, 0, reason: 'every load finished');
    expect(cache.currentSize, greaterThan(0), reason: 'and decoded to pixels');
  });
}
