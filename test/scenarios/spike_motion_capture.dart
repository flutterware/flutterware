import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spike: can a scenario record the *motion* of a transition, not just its
/// endpoints?
///
/// The measurement record behind the feature, kept rather than deleted — the
/// numbers in `2026-08-11-scenario-motion-capture-findings.md` and the
/// settings in `ScenariosCore.panelMotionInterval` all come from here, and a
/// later change to either should be able to re-run them.
///
/// Not part of the suite — it takes half a minute and asserts almost
/// nothing. Hence the name: no `_test` suffix, so no glob picks it up. Run it
/// on purpose:
///
/// ```sh
/// fvm flutter test test/scenarios/spike_motion_capture.dart
/// ```
///
/// Answers four questions with numbers, in flutterware's own harness
/// (`AutomatedTestWidgetsFlutterBinding`, the binding `scenario()` runs
/// under):
///
/// 1. Does `OffsetLayer.toImageSync` work inside the FakeAsync pump loop?
/// 2. What does one recorded frame cost, against the 11.5ms/56ms per-step
///    numbers `_emit` is documented with?
/// 3. How many frames is a real Material page transition, and how many bytes?
/// 4. Does an *unchanged* frame cost anything to notice? (dedup headroom)
///
/// Output lands in `build/spike-motion/` for eyeballing.
void main() {
  var out = Directory('build/spike-motion')..createSync(recursive: true);

  // The harness loads fonts from the app's `FontManifest.json`; a bare
  // `flutter test` renders every glyph as a box, which makes the recordings
  // unreadable. Loaded straight from the SDK cache so the frames look like
  // what a real run produces.
  setUpAll(() async {
    var dir = Directory('.fvm/flutter_sdk/bin/cache/artifacts/material_fonts');
    if (!dir.existsSync()) return;
    for (var (family, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      var bytes = File('${dir.path}/$file').readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });

  testWidgets('records a page transition frame by frame', (tester) async {
    await tester.pumpWidget(const _DemoApp());
    await tester.pumpAndSettle();

    var recorder = _Recorder(tester);

    var sw = Stopwatch()..start();
    await tester.tap(find.text('Espresso'));
    var frames = await recorder.record(
      step: const Duration(milliseconds: 16),
      cap: const Duration(seconds: 2),
    );
    sw.stop();
    var pumpMs = sw.elapsedMicroseconds / 1000;

    // The same flow through the settle policy scenarios actually use, for a
    // baseline: 100ms steps, no capture at all. Torn down first — re-pumping
    // over the same app keeps every State alive, navigator stack included.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const _DemoApp());
    await tester.pumpAndSettle();
    var base = Stopwatch()..start();
    await tester.tap(find.text('Espresso'));
    var pumps = 0;
    do {
      await tester.pump(const Duration(milliseconds: 100));
      pumps++;
    } while (tester.binding.hasScheduledFrame && pumps < 50);
    base.stop();

    var report = await recorder.encode(frames, out, 'push');

    print('--- page transition (tap → detail route) ---');
    print(
      'settle-only baseline (100ms steps): '
      '${base.elapsedMicroseconds / 1000}ms, $pumps pumps',
    );
    print(
      'record loop (16ms steps): ${pumpMs}ms, ${frames.length} frames '
      '(${(pumpMs / frames.length).toStringAsFixed(2)}ms/frame in-loop)',
    );
    print(report);

    expect(frames.length, greaterThan(5));
  });

  testWidgets('records a tap ripple and an expansion', (tester) async {
    await tester.pumpWidget(const _DemoApp());
    await tester.pumpAndSettle();

    var recorder = _Recorder(tester);
    await tester.tap(find.text('More'));
    var frames = await recorder.record(
      step: const Duration(milliseconds: 16),
      cap: const Duration(seconds: 2),
    );

    print('--- expansion + ripple ---');
    print(await recorder.encode(frames, out, 'expand'));
  });

  testWidgets('records a whole scenario continuously', (tester) async {
    // The "one movie per scenario" shape: never stop recording, every verb
    // pumps through the sink.
    var recorder = _Recorder(tester);
    var sw = Stopwatch()..start();

    await tester.pumpWidget(const _DemoApp());
    var frames = await recorder.record(
      step: const Duration(milliseconds: 16),
      cap: const Duration(seconds: 2),
    );
    await tester.tap(find.text('Espresso'));
    frames.addAll(
      await recorder.record(
        step: const Duration(milliseconds: 16),
        cap: const Duration(seconds: 2),
      ),
    );
    await tester.tap(find.byTooltip('Back'));
    frames.addAll(
      await recorder.record(
        step: const Duration(milliseconds: 16),
        cap: const Duration(seconds: 2),
      ),
    );
    await tester.tap(find.text('More'));
    frames.addAll(
      await recorder.record(
        step: const Duration(milliseconds: 16),
        cap: const Duration(seconds: 2),
      ),
    );
    sw.stop();

    print('--- whole scenario, 4 verbs ---');
    print(
      'in-loop: ${sw.elapsedMicroseconds / 1000}ms, '
      '${frames.length} frames',
    );
    print(await recorder.encode(frames, out, 'scenario'));
  });

  testWidgets('records on a phone-sized device, at 1× and at 3×', (
    tester,
  ) async {
    // What a real run looks like: a 393×852 logical phone at dpr 3, which is
    // what `ScenarioRunArgs` sets up.
    tester.view
      ..physicalSize = const Size(393 * 3, 852 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    for (var scale in [1.0, 3.0]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const _DemoApp());
      await tester.pumpAndSettle();

      var recorder = _Recorder(tester, scale: scale);
      var sw = Stopwatch()..start();
      await tester.tap(find.text('Espresso'));
      var frames = await recorder.record(
        step: const Duration(milliseconds: 16),
        cap: const Duration(seconds: 2),
      );
      sw.stop();

      print('--- phone push at ${scale.toStringAsFixed(0)}× ---');
      print('in-loop: ${sw.elapsedMicroseconds / 1000}ms');
      print(await recorder.encode(frames, out, 'phone-${scale.toInt()}x'));
    }
  });

  testWidgets('recording does not perturb the settled frame', (tester) async {
    // The question the comparison work makes urgent: a recorded run pumps at
    // 16ms where an ordinary one pumps at 100ms, so does it land on the same
    // pixels? If it does not, a recorded run cannot be diffed against a
    // baseline captured without recording.
    Future<Uint8List> endFrame(Duration step) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const _DemoApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Espresso'));
      var elapsed = Duration.zero;
      while (tester.binding.hasScheduledFrame &&
          elapsed < const Duration(seconds: 5)) {
        await tester.pump(step);
        elapsed += step;
      }
      var view = tester.binding.renderViews.single;
      var dpr = view.flutterView.devicePixelRatio;
      var image = (view.debugLayer! as OffsetLayer).toImageSync(
        Offset.zero & (view.size * dpr),
        pixelRatio: 1 / dpr,
      );
      late Uint8List bytes;
      await tester.runAsync(() async {
        bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
      });
      image.dispose();
      return bytes;
    }

    var normal = await endFrame(const Duration(milliseconds: 100));
    var recorded = await endFrame(const Duration(milliseconds: 16));

    var differing = 0;
    for (var i = 0; i < normal.length; i++) {
      if (normal[i] != recorded[i]) differing++;
    }
    print('--- settled frame, 100ms settle vs 16ms record ---');
    print('bytes differing: $differing of ${normal.length}');
  });

  testWidgets('records a Hero flight', (tester) async {
    await tester.pumpWidget(const _HeroApp());
    await tester.pumpAndSettle();

    var recorder = _Recorder(tester);
    await tester.tap(find.byType(Card));
    var frames = await recorder.record(
      step: const Duration(milliseconds: 16),
      cap: const Duration(seconds: 2),
    );
    print('--- hero flight ---');
    print(await recorder.encode(frames, out, 'hero'));
  });

  testWidgets('a whole run, at every rate and scale worth shipping', (
    tester,
  ) async {
    // The number that decides always-on against on-demand: what a panel run
    // pays to record *every* transition, at a frame rate low enough to be
    // honest about. The panel draws the flow at 50% zoom, so 0.5× frames are
    // not obviously wrong — this says what they buy.
    tester.view
      ..physicalSize = const Size(393 * 3, 852 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    for (var step in [16, 33, 66]) {
      for (var scale in [1.0, 0.5]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(const _DemoApp());
        await tester.pumpAndSettle();

        var recorder = _Recorder(tester, scale: scale);
        var interval = Duration(milliseconds: step);
        var sw = Stopwatch()..start();
        var frames = <ui.Image>[];
        await tester.tap(find.text('Espresso'));
        frames.addAll(
          await recorder.record(
            step: interval,
            cap: const Duration(seconds: 2),
          ),
        );
        await tester.tap(find.byTooltip('Back'));
        frames.addAll(
          await recorder.record(
            step: interval,
            cap: const Duration(seconds: 2),
          ),
        );
        await tester.tap(find.text('More'));
        frames.addAll(
          await recorder.record(
            step: interval,
            cap: const Duration(seconds: 2),
          ),
        );
        sw.stop();

        print('--- 3 transitions at ${step}ms / $scale× ---');
        print(
          'in-loop: ${(sw.elapsedMicroseconds / 1000).toStringAsFixed(1)}ms',
        );
        print(await recorder.encode(frames, out, 'run-$step-$scale'));
      }
    }
  });

  testWidgets('an indefinite animation runs to the cap', (tester) async {
    // `Settle.standard` gives up after 5 fake seconds on a spinner. A
    // recorder pumping at 16ms would keep 313 frames of it — the reason a
    // frame budget is not optional.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: RefreshProgressIndicator())),
      ),
    );
    var recorder = _Recorder(tester);
    var frames = await recorder.record(
      step: const Duration(milliseconds: 16),
      cap: const Duration(seconds: 5),
    );
    print('--- indefinite spinner, 5s cap ---');
    print(await recorder.encode(frames, out, 'spinner'));
  });

  testWidgets('an idle screen records nothing', (tester) async {
    await tester.pumpWidget(const _DemoApp());
    await tester.pumpAndSettle();

    var recorder = _Recorder(tester);
    var frames = await recorder.record(
      step: const Duration(milliseconds: 16),
      cap: const Duration(seconds: 2),
    );
    print('--- idle screen ---');
    print('frames: ${frames.length}');
    for (var f in frames) {
      f.dispose();
    }
  });
}

/// The mechanism under test: grab a `ui.Image` handle per pumped frame,
/// synchronously, without leaving FakeAsync.
class _Recorder {
  _Recorder(this.tester, {this.scale = 1.0});

  final WidgetTester tester;

  /// Output pixels per logical pixel — `captureScale`, exactly.
  final double scale;

  /// Pumps until nothing is scheduled or [cap] of fake time is spent, keeping
  /// every frame. This is `Settle.upTo` with a frame sink and a finer step —
  /// the whole product change, in eight lines.
  Future<List<ui.Image>> record({
    required Duration step,
    required Duration cap,
  }) async {
    var view = tester.binding.renderViews.single;
    var dpr = view.flutterView.devicePixelRatio;
    var bounds = Offset.zero & (view.size * dpr);

    var frames = <ui.Image>[];
    var elapsed = Duration.zero;
    // The frame the verb starts from, so the movie opens on "before".
    frames.add(
      (view.debugLayer! as OffsetLayer).toImageSync(
        bounds,
        pixelRatio: scale / dpr,
      ),
    );
    while (tester.binding.hasScheduledFrame && elapsed < cap) {
      await tester.pump(step);
      elapsed += step;
      frames.add(
        (view.debugLayer! as OffsetLayer).toImageSync(
          bounds,
          pixelRatio: scale / dpr,
        ),
      );
    }
    return frames;
  }

  /// Everything that has to leave FakeAsync, once, at the end.
  Future<String> encode(
    List<ui.Image> frames,
    Directory out,
    String name,
  ) async {
    var lines = StringBuffer();
    late int rawBytes;
    late int pngBytes;
    late double rawMs;
    late double pngMs;
    var identical = 0;

    await tester.runAsync(() async {
      var sw = Stopwatch()..start();
      var raws = <Uint8List>[];
      for (var frame in frames) {
        raws.add(
          (await frame.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
              .asUint8List(),
        );
      }
      sw.stop();
      rawMs = sw.elapsedMicroseconds / 1000;
      rawBytes = raws.fold(0, (a, b) => a + b.length);

      for (var i = 1; i < raws.length; i++) {
        if (_same(raws[i - 1], raws[i])) identical++;
      }

      var dir = Directory('${out.path}/$name')..createSync(recursive: true);
      sw = Stopwatch()..start();
      var total = 0;
      for (var (i, frame) in frames.indexed) {
        var png = (await frame.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        total += png.length;
        File('${dir.path}/${i.toString().padLeft(4, '0')}.png')
            .writeAsBytesSync(png);
      }
      sw.stop();
      pngMs = sw.elapsedMicroseconds / 1000;
      pngBytes = total;

      // Raw, concatenated — what a host that can blit pixels would take.
      File('${dir.path}/frames.raw')
          .writeAsBytesSync(Uint8List.fromList([for (var raw in raws) ...raw]));
    });

    var size = '${frames.first.width}×${frames.first.height}';
    for (var frame in frames) {
      frame.dispose();
    }

    lines.writeln('$name: ${frames.length} frames at $size');
    lines.writeln(
      '  rawRgba: ${rawMs.toStringAsFixed(1)}ms total, '
      '${(rawMs / frames.length).toStringAsFixed(2)}ms/frame, '
      '${_mb(rawBytes)}',
    );
    lines.writeln(
      '  png:     ${pngMs.toStringAsFixed(1)}ms total, '
      '${(pngMs / frames.length).toStringAsFixed(2)}ms/frame, '
      '${_mb(pngBytes)}',
    );
    lines.write('  frames identical to their predecessor: $identical');
    return lines.toString();
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _mb(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

class _DemoApp extends StatelessWidget {
  const _DemoApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const _MenuPage(),
  );
}

class _MenuPage extends StatelessWidget {
  const _MenuPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Menu')),
    body: ListView(
      children: [
        for (var name in ['Espresso', 'Latte', 'Cortado'])
          ListTile(
            leading: const Icon(Icons.coffee),
            title: Text(name),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => _DetailPage(name: name)),
            ),
          ),
        const ExpansionTile(
          title: Text('More'),
          children: [
            ListTile(title: Text('Decaf')),
            ListTile(title: Text('Iced')),
          ],
        ),
      ],
    ),
  );
}

class _HeroApp extends StatelessWidget {
  const _HeroApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Beans')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: Center(
                      child: Hero(
                        tag: 'bean',
                        child: Container(
                          width: 300,
                          height: 300,
                          color: Colors.deepOrange,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Card(
                child: Hero(
                  tag: 'bean',
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: ColoredBox(color: Colors.deepOrange),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DetailPage extends StatelessWidget {
  const _DetailPage({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(name)),
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.local_cafe, size: 96),
          Text(name, style: Theme.of(context).textTheme.headlineMedium),
        ],
      ),
    ),
  );
}
