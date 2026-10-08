@Timeout(Duration(minutes: 8))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/embedder/build_directory.dart';
import 'package:flutterware_app/src/previews/catalog_render.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutterware_app/src/previews/discovery.dart';
import 'package:flutterware_app/src/previews/test_runner.dart';
import 'package:flutterware_app/src/previews/tester_renderer.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The 3D probes: each is an entry in the example package's `demo/` with a live
/// widget on a surface showing the playhead's own hue. The walk samples the
/// centre of every frame — a frame carrying the previous stop's screen shows up
/// as the previous stop's hue — and checks the walk repeats and is order-free.
///
/// Prints its measurements; the expectations at the end are the findings.
void main() {
  // Not `modelProbe`, the runtime glTF import: it lands in the first body of
  // a harness process and never in a later one — inside flutter_scene's
  // importer, since a bare `compute` answers every body (below) and the
  // build-time path walks fine. The export lane's path is the built one.
  for (var entryId in const [
    'demo/phone_rig_probe.dart#phoneRigProbe',
    'demo/model_probe.dart#modelProbeBuilt',
    'demo/model_probe.dart#modelProbeBlender',
  ]) {
    test('a walk of $entryId: lag and determinism', () => _probe(entryId));
  }
  // A textured, rigged model from outside, through the version-zero view: no
  // screen to read a hue off, so only that it moves and that it repeats.
  test(
    'a walk of the fox: motion and determinism',
    () => _probe('demo/fox_probe.dart#foxProbe', screen: false),
  );

  // Does an isolate answer a second body? The runtime glTF import's
  // `compute` did not; this is the same question with nothing else in it.
  test('a compute answers a second body of one harness', () async {
    var flutterRoot = Platform.environment['FLUTTER_ROOT']!;
    var packageRoot = p.normalize(
      p.join(Directory.current.path, '..', 'fixtures', 'probe_app'),
    );
    const entryId = 'demo/compute_probe.dart#computeProbe';
    var scan = CatalogScanner(
      projectRoot: packageRoot,
      roots: const ['demo'],
    ).scan();
    var entry = scan.entries.singleWhere((entry) => entry.id == entryId);
    var runner = PreviewTestRunner(
      packageRoot: packageRoot,
      flutterSdkRoot: flutterRoot,
      read: () => (entries: [entry], canvases: const []),
      onLog: (line) => print('tester: $line'),
      buildDirectory: claimBuildDirectory(
        packageRoot,
        root: comparisonBuildRoot,
      ),
    );
    try {
      var renderer = TesterRenderer(runner: runner);
      var dir = Directory.systemTemp.createTempSync('compute_probe');
      for (var body = 1; body <= 3; body++) {
        var clock = Stopwatch()..start();
        var shot = await renderer.render(
          CatalogRender(
            entryId: entry.id,
            screenshot: p.join(dir.path, '$body.png'),
          ),
        );
        var picture = img.decodePng(shot.screenshot!.readAsBytesSync())!;
        // Off centre: the answer is drawn in the middle.
        var centre = picture.getPixel(picture.width ~/ 4, picture.height ~/ 4);
        var green = centre.g > 150 && centre.r < 100;
        print('body $body: ${clock.elapsedMilliseconds}ms, answered: $green');
        expect(green, isTrue, reason: 'body $body never got its isolate reply');
      }
    } finally {
      await runner.dispose();
    }
  });

  // Experiment 3 of the spec: the rate at export resolution, as a number.
  test(
    'the model probe at 1080p, 30 frames',
    () => _cost(
      'demo/model_probe.dart#modelProbeBuilt',
      const CaptureViewport(width: 1920, height: 1080),
    ),
  );
}

Future<void> _cost(String entryId, CaptureViewport viewport) async {
  var flutterRoot = Platform.environment['FLUTTER_ROOT']!;
  var packageRoot = p.normalize(
    p.join(Directory.current.path, '..', 'fixtures', 'probe_app'),
  );
  var scan = CatalogScanner(
    projectRoot: packageRoot,
    roots: const ['demo'],
  ).scan();
  var entry = scan.entries.singleWhere((entry) => entry.id == entryId);
  var runner = PreviewTestRunner(
    packageRoot: packageRoot,
    flutterSdkRoot: flutterRoot,
    read: () => (entries: [entry], canvases: const []),
    buildDirectory: claimBuildDirectory(packageRoot, root: comparisonBuildRoot),
  );
  try {
    var renderer = TesterRenderer(runner: runner);
    Future<int> timed(List<double> stops) async {
      var clock = Stopwatch()..start();
      var result = await renderer.walk(
        CatalogWalk(entryId: entry.id, stops: stops, viewport: viewport),
      );
      var frames = await result.frames.toList();
      expect(frames, hasLength(stops.length));
      return clock.elapsedMilliseconds;
    }

    // One cold walk for the harness and the engine; the rate is the warm one.
    await timed(const [0]);
    var stops = [for (var i = 0; i < 30; i++) i / 29];
    var ms = await timed(stops);
    print(
      'cost ${viewport.width}x${viewport.height}: ${stops.length} frames in '
      '${ms}ms, ${(ms / stops.length).toStringAsFixed(1)}ms a frame',
    );
    ms = await timed(stops);
    print(
      'cost ${viewport.width}x${viewport.height}, again: ${stops.length} '
      'frames in ${ms}ms, ${(ms / stops.length).toStringAsFixed(1)}ms a frame',
    );
  } finally {
    await runner.dispose();
  }
}

Future<void> _probe(String entryId, {bool screen = true}) async {
  {
    var flutterRoot = Platform.environment['FLUTTER_ROOT'];
    expect(flutterRoot, isNotNull, reason: 'flutter test always sets it');
    var packageRoot = p.normalize(
      p.join(Directory.current.path, '..', 'fixtures', 'probe_app'),
    );
    var scan = CatalogScanner(
      projectRoot: packageRoot,
      roots: const ['demo'],
    ).scan();
    var entry = scan.entries.singleWhere((entry) => entry.id == entryId);

    var runner = PreviewTestRunner(
      packageRoot: packageRoot,
      flutterSdkRoot: flutterRoot!,
      read: () => (entries: [entry], canvases: const []),
      onLog: (line) => print('tester: $line'),
      buildDirectory: claimBuildDirectory(
        packageRoot,
        root: comparisonBuildRoot,
      ),
    );
    try {
      var renderer = TesterRenderer(runner: runner);
      var stops = [for (var i = 0; i < 5; i++) i / 4];
      Future<List<WalkFrame>> walk(List<double> order) async {
        var clock = Stopwatch()..start();
        var result = await renderer.walk(
          CatalogWalk(entryId: entry.id, stops: order),
        );
        var frames = await result.frames.toList();
        print(
          'walk ${order.map((s) => s.toStringAsFixed(2)).join(' ')}: '
          '${clock.elapsedMilliseconds}ms for ${frames.length} frames',
        );
        return frames;
      }

      var first = await walk(stops);
      expect(first, hasLength(stops.length));
      _report('forwards', first);

      var again = await walk(stops);
      _report('again', again);
      var backwards = (await walk(stops.reversed.toList())).reversed.toList();
      _report('backwards', backwards);

      // A picture of each stop of each walk, for looking at — under the
      // app's build directory, which CI uploads when this goes red.
      var out = Directory(
        p.join(
          Directory.current.path,
          'build',
          'phone_rig_probe',
          entryId.split('#').last,
        ),
      )..createSync(recursive: true);
      for (var (label, frames) in [
        ('forwards', first),
        ('again', again),
        ('backwards', backwards),
      ]) {
        for (var frame in frames) {
          var picture = img.Image.fromBytes(
            width: frame.width,
            height: frame.height,
            bytes: frame.pixels.buffer,
            numChannels: 4,
          );
          File(p.join(out.path, '${label}_${frame.t.toStringAsFixed(2)}.png'))
              .writeAsBytesSync(img.encodePng(picture));
        }
      }
      print('frames: ${out.path}');

      var lagging = <double>[];
      if (!screen) {
        expect(
          _same(first.first.pixels, first[2].pixels),
          isFalse,
          reason: 'nothing moved between the first stop and the middle one',
        );
      }
      for (var frame in screen ? first : const <WalkFrame>[]) {
        var (hue, sat) = _centreHue(frame);
        var expected = _hueAt(frame.t);
        if (sat < 0.2 || _hueDistance(hue, expected) > 25) lagging.add(frame.t);
      }
      var repeats = <double>[];
      var orderFree = <double>[];
      for (var i = 0; i < stops.length; i++) {
        var repeat = _diff(first[i], again[i]);
        if (repeat.pixels > 0) print('  again t=${stops[i]}: ${repeat.report}');
        if (repeat.pixels > edgeNoiseBudget) repeats.add(stops[i]);
        var reversed = _diff(first[i], backwards[i]);
        if (reversed.pixels > 0) {
          print('  backwards t=${stops[i]}: ${reversed.report}');
        }
        if (reversed.pixels > edgeNoiseBudget) orderFree.add(stops[i]);
      }
      print("stops whose screen is not the stop's own: $lagging");
      print('stops that differed on a repeated walk: $repeats');
      print('stops that differed taken backwards: $orderFree');

      expect(lagging, isEmpty, reason: 'the screen lags the playhead');
      expect(repeats, isEmpty, reason: 'the walk does not repeat');
      expect(orderFree, isEmpty, reason: 'the walk is not order-free');
    } finally {
      await runner.dispose();
    }
  }
}

/// How many pixels two frames of one stop may differ by and still count as
/// the same picture.
///
/// On macOS and Linux they never differ: every walk is byte-identical. On
/// `windows-latest` they do, by a little — measured 2026-09-10 over two runs,
/// between 1 and 11 pixels of 630 000 per stop, by up to 78/255, in one- to
/// three-pixel boxes on the model's silhouette; and which walk is the odd one
/// changes from run to run (the first in one run, the backwards one in the
/// next), while the other two agree to the byte. That is the runner's
/// software rasterizer settling edge coverage differently per process, not
/// the walk: the centre hue is right at every stop, and a frame carrying
/// another stop's screen moves the whole model, thousands of pixels. The
/// budget is the hue patch — 9 × 9 — which a wrong screen cannot leave
/// untouched, and any difference at all is still printed above.
const edgeNoiseBudget = 81;

/// Mirrors `phoneRigHueAt` in the demo; kept here so the test reads no
/// Flutter-side code of the example.
double _hueAt(double p) => 300 * p;

void _report(String label, List<WalkFrame> frames) {
  for (var frame in frames) {
    var (hue, sat) = _centreHue(frame);
    print(
      '$label t=${frame.t.toStringAsFixed(2)}: centre hue '
      '${hue.toStringAsFixed(0)}° sat ${sat.toStringAsFixed(2)} '
      '(expected ${_hueAt(frame.t).toStringAsFixed(0)}°)',
    );
  }
}

/// Hue and saturation averaged over a 9×9 patch at the frame's centre.
(double, double) _centreHue(WalkFrame frame) {
  var cx = frame.width ~/ 2;
  var cy = frame.height ~/ 2;
  var r = 0.0, g = 0.0, b = 0.0;
  var n = 0;
  for (var y = cy - 4; y <= cy + 4; y++) {
    for (var x = cx - 4; x <= cx + 4; x++) {
      var at = (y * frame.width + x) * 4;
      r += frame.pixels[at];
      g += frame.pixels[at + 1];
      b += frame.pixels[at + 2];
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

/// How two frames of one stop differ: how many pixels, by how much at most,
/// and where — the difference between a renderer that is off by a rounding
/// step somewhere and a walk that drew another stop's screen.
({int pixels, String report}) _diff(WalkFrame a, WalkFrame b) {
  if (a.width != b.width || a.height != b.height) {
    return (
      pixels: a.width * a.height,
      report: 'sizes differ: ${a.width}×${a.height} vs ${b.width}×${b.height}',
    );
  }
  var pixels = 0;
  var maxDelta = 0;
  var left = a.width, top = a.height, right = -1, bottom = -1;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      var at = (y * a.width + x) * 4;
      var delta = 0;
      for (var c = 0; c < 4; c++) {
        var d = (a.pixels[at + c] - b.pixels[at + c]).abs();
        if (d > delta) delta = d;
      }
      if (delta == 0) continue;
      pixels++;
      if (delta > maxDelta) maxDelta = delta;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  return (
    pixels: pixels,
    report: pixels == 0
        ? 'identical'
        : '$pixels of ${a.width * a.height} pixels differ, by at most '
              '$maxDelta/255, within ($left,$top)–($right,$bottom)',
  );
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
