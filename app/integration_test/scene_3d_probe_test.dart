@Tags(['gpu'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/previews/catalog_render.dart';
import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/headless_catalog.dart';
import 'package:flutterware_app/src/previews/package_config_locator.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The model probe rendered through the **embedder** guest — the editor's
/// canvas lane, Metal on macOS — rather than the tester lane the walk tests
/// use. One frame at the playhead's rest, which the probe draws with a red
/// screen (hue 0°) on the imported asset.
///
/// Tagged `gpu` like its neighbours: it composites through Metal and runs by
/// hand. Prints the centre hue and where the picture went; the expectation is
/// that the screen surface rendered at all.
void main() {
  test('the model probe renders on the embedder guest', () async {
    var appRoot = Directory.current.path;
    var repoRoot = p.dirname(appRoot);
    var exampleRoot = p.join(repoRoot, 'fixtures', 'probe_app');
    var cache = FlutterCache.fromRunningSdk();
    var dartExecutable = p.join(cache.flutterRoot, 'bin', 'dart');
    var config = DaemonConfig(
      appPackageRoot: appRoot,
      projectRoot: exampleRoot,
      packageConfig: requirePackageConfig(exampleRoot),
      flutterSdkRoot: cache.flutterRoot,
      roots: const ['demo'],
    );
    var (stale, _) = await CompilerDaemonClient.connect(
      dartExecutable: dartExecutable,
      config: config,
    );
    await stale.stopDaemon();

    var output = p.join(
      Directory.systemTemp.createTempSync('fw_scene_3d').path,
      'model_probe.png',
    );
    var clock = Stopwatch()..start();
    var capture =
        await HeadlessCatalog(
          dartExecutable: dartExecutable,
          config: config,
        ).render(
          CatalogRender(
            entryId: 'demo/model_probe.dart#modelProbe',
            screenshot: output,
          ),
        );
    print('embedder capture in ${clock.elapsedMilliseconds}ms: $output');
    print('guest errors: ${capture.errors}');

    var picture = img.decodePng(capture.screenshot!.readAsBytesSync())!;
    var (hue, sat) = _centreHue(picture);
    print(
      'centre hue ${hue.toStringAsFixed(0)}° sat ${sat.toStringAsFixed(2)}',
    );
    expect(
      sat,
      greaterThan(0.5),
      reason: 'the centre of the frame is not a saturated screen surface',
    );
    expect(_hueDistance(hue, 0), lessThan(25), reason: 'the screen is not red');
  });
}

(double, double) _centreHue(img.Image picture) {
  var cx = picture.width ~/ 2;
  var cy = picture.height ~/ 2;
  var r = 0.0, g = 0.0, b = 0.0;
  var n = 0;
  for (var y = cy - 4; y <= cy + 4; y++) {
    for (var x = cx - 4; x <= cx + 4; x++) {
      var pixel = picture.getPixel(x, y);
      r += pixel.r;
      g += pixel.g;
      b += pixel.b;
      n++;
    }
  }
  r /= n * 255;
  g /= n * 255;
  b /= n * 255;
  var max = math.max(r, math.max(g, b));
  var min = math.min(r, math.min(g, b));
  var delta = max - min;
  var sat = max == 0 ? 0.0 : delta / max;
  double hue;
  if (delta == 0) {
    hue = 0;
  } else if (max == r) {
    hue = 60 * (((g - b) / delta) % 6);
  } else if (max == g) {
    hue = 60 * ((b - r) / delta + 2);
  } else {
    hue = 60 * ((r - g) / delta + 4);
  }
  if (hue < 0) hue += 360;
  return (hue, sat);
}

double _hueDistance(double a, double b) {
  var d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}
