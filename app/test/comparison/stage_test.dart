import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:flutterware_app/src/comparison/shot_store_io.dart';
import 'package:flutterware_app/src/comparison/ui/shot_image.dart';
import 'package:flutterware_app/src/comparison/ui/stage.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:path/path.dart' as p;

/// The five ways of looking at two frames.
///
/// Driven through a real [ShotPair] over a real cache, because decoding raw
/// rgba into a `ui.Image` is the part of this that can silently produce
/// nothing — and a stage with no frames looks exactly like a comparison of two
/// blank screens.
void main() {
  late ShotCache cache;

  setUp(() {
    cache = ShotCache(
      p.join(Directory.systemTemp.createTempSync('fw_stage').path, 'shots'),
    );
  });

  /// A solid frame, filed under [key].
  void write(String key, int value, {int width = 8, int height = 8}) {
    cache.write(
      key,
      Uint8List(width * height * 4)..fillRange(0, width * height * 4, value),
      ShotRecord(
        format: 'raw',
        width: width,
        height: height,
        entryId: 'demo/card.dart#card',
      ),
    );
  }

  Future<ShotPair> pair(
    WidgetTester tester, {
    bool base = true,
    bool head = true,
  }) async {
    if (base) write('base', 40);
    if (head) write('head', 200);
    var shots = ShotPair(CacheShotStore(cache));
    // **Inside `runAsync`.** Decoding an image goes out to the engine, and the
    // fake clock a widget test runs on never lets that future complete — the
    // test does not fail, it hangs.
    await tester.runAsync(
      () => shots.load(
        baseKey: base ? 'base' : null,
        headKey: head ? 'head' : null,
      ),
    );
    addTearDown(shots.dispose);
    return shots;
  }

  Future<StageMode> pumpStage(
    WidgetTester tester,
    ShotPair shots, {
    StageMode mode = StageMode.sideBySide,
    PixelDiff? diff,
  }) async {
    var chosen = mode;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: StatefulBuilder(
              builder: (context, setState) => ComparisonStage(
                shots: shots,
                mode: chosen,
                onMode: (next) => setState(() => chosen = next),
                diff: diff,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return chosen;
  }

  testWidgets('a raw frame decodes into something drawable', (tester) async {
    var shots = await pair(tester);

    expect(shots.settled, isTrue);
    expect(shots.base, isNotNull);
    expect(shots.head, isNotNull);
    expect(shots.base!.image.width, 8);
  });

  // The distinction is a message: an entry that failed on both sides has no
  // frames and never will, and a pane that said "Loading…" over it said so
  // forever.
  testWidgets('a load that found nothing has still settled', (tester) async {
    var shots = ShotPair(CacheShotStore(cache));
    addTearDown(shots.dispose);

    await tester.runAsync(
      () => shots.load(baseKey: 'missing', headKey: 'also-missing'),
    );

    expect(shots.settled, isTrue);
    expect(shots.hasFrames, isFalse);
  });

  testWidgets('every mode draws both frames', (tester) async {
    var shots = await pair(tester);

    for (var mode in StageMode.values) {
      await pumpStage(tester, shots, mode: mode);
      expect(
        find.byKey(stageKey),
        findsOneWidget,
        reason: '${mode.name} drew nothing',
      );
      expect(tester.takeException(), isNull, reason: mode.name);
    }
  });

  testWidgets('picking a mode changes what is shown', (tester) async {
    var shots = await pair(tester);
    await pumpStage(tester, shots);

    expect(find.text('base'), findsOneWidget);
    await tester.tap(find.byKey(stageModeKey(StageMode.onion)));
    await tester.pump();

    expect(find.text('base under head'), findsOneWidget);
  });

  // Sliding against nothing is a control that does something and means
  // nothing.
  // With one frame there is nothing to switch between, so the mode bar is
  // not drawn at all — five inert pills were furniture over a picture that
  // has no modes.
  testWidgets('the mode bar is not drawn with one frame', (tester) async {
    var shots = await pair(tester, base: false);
    await pumpStage(tester, shots);

    expect(find.byKey(stageModeKey(StageMode.slider)), findsNothing);
    expect(find.text('head only'), findsOneWidget);
  });

  testWidgets('with no frames at all it says so', (tester) async {
    var shots = await pair(tester, base: false, head: false);
    await pumpStage(tester, shots);

    expect(find.text('Neither side rendered'), findsOneWidget);
  });

  // Side by side inherits "where to look": the head half carries the boxes.
  testWidgets('side by side boxes the changed regions on the head', (
    tester,
  ) async {
    var shots = await pair(tester);
    await pumpStage(
      tester,
      shots,
      diff: const PixelDiff(
        width: 8,
        height: 8,
        changedPixels: 4,
        comparedPixels: 64,
        sizeChanged: false,
        clusters: [DiffRect(x: 1, y: 1, width: 2, height: 2, pixels: 4)],
      ),
    );

    expect(find.byKey(clusterBoxesKey), findsOneWidget);
  });

  testWidgets('side by side with no diff draws no boxes', (tester) async {
    var shots = await pair(tester);
    await pumpStage(tester, shots);

    expect(find.byKey(clusterBoxesKey), findsNothing);
  });

  // The mode an agent reads: where to look, in numbers.
  testWidgets('the pixels mode names the fraction and the regions', (
    tester,
  ) async {
    var shots = await pair(tester);
    await pumpStage(
      tester,
      shots,
      mode: StageMode.pixels,
      diff: const PixelDiff(
        width: 100,
        height: 100,
        changedPixels: 38,
        comparedPixels: 10000,
        sizeChanged: false,
        clusters: [DiffRect(x: 1, y: 1, width: 2, height: 2, pixels: 4)],
      ),
    );

    expect(find.text('0.38% of pixels differ · 1 region'), findsOneWidget);
  });

  // A timer left running behind another mode rebuilds the pane twice a second
  // for nothing — and in a test, never lets it settle.
  testWidgets('blink stops when another mode takes over', (tester) async {
    var shots = await pair(tester);
    await pumpStage(tester, shots, mode: StageMode.blink);
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(find.byKey(stageModeKey(StageMode.sideBySide)));
    await tester.pump();

    // No pending timer is left to fire; the test would fail on teardown if one
    // were.
    expect(find.text('base'), findsOneWidget);
  });
}
