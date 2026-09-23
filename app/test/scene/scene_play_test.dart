// The shipped app's whole loop: a compiled scene, a compiled motion, and a
// clock — no document read from anywhere, no lookup by name, no editor.
//
// This is the path an app actually writes, and until now nothing pumped it:
// the pieces were each tested apart, and the timeline was only ever parked
// by hand at a time.
//
// Note the imports. `scene.dart` and the scene file, and nothing else — an
// app has no business importing the authoring vocabulary, which is the
// tool's. That only became true when `MotionPlayer` learned to take a
// motion: before it, starting one meant reaching for `playTimeline` in
// `scene_authoring.dart`. The one exception is the shader pass a test puts
// on a compiled node by hand, which an app would write in its scene file.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart' show FillLayer, ShaderPaint;

import 'sample.scene.dart';

/// What an app writes. The definition is a FIELD, not something built in
/// `build()`: a new `SampleScene()` is new nodes, and the player would go on
/// writing its fx onto the ones that went away.
class _Banner extends StatefulWidget {
  const _Banner();

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with SingleTickerProviderStateMixin {
  final scene = SampleScene();
  late final motion = SampleIntro(scene);
  late final player = MotionPlayer(motion, vsync: this);

  @override
  void initState() {
    super.initState();
    player.play();
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SceneView(scene);
}

void main() {
  group('the clock', () {
    late SampleScene scene;
    late MotionPlayer player;

    setUp(() {
      scene = SampleScene();
      player = MotionPlayer(SampleIntro(scene), vsync: null);
      addTearDown(player.dispose);
    });

    double opacity() => scene.title.fxRendered('opacity') as double;

    testWidgets('reverse runs back to zero and stops there', (tester) async {
      // The bug this replaced: direction was a negative `rate`, and the end
      // it watched for was only the far one — so backwards ran the playhead
      // past zero into negative time and ticked there forever.
      player.position = const Duration(milliseconds: 360);
      expect(opacity(), 1.0);
      player.reverse();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(player.position, Duration.zero);
      expect(player.status, MotionPlayerStatus.completed);
      expect(opacity(), 0.0);
    });

    testWidgets('finished completes however the playback ended', (
      tester,
    ) async {
      var ended = <String>[];
      player.play();
      unawaited(player.finished.then((_) => ended.add('ran out')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(ended, ['ran out']);
      expect(player.status, MotionPlayerStatus.completed);

      // And a stop is an ending too — the caller asks status which it was.
      player.play();
      unawaited(player.finished.then((_) => ended.add('stopped')));
      await tester.pump(const Duration(milliseconds: 50));
      player.stop();
      await tester.pump();
      expect(ended, ['ran out', 'stopped']);
      expect(player.status, MotionPlayerStatus.idle);

      // Nothing playing is an answer, not a hang.
      await player.finished;
    });

    testWidgets('repeat counts traversals, and yoyo turns around', (
      tester,
    ) async {
      player.repeat(times: 2, yoyo: true);
      // Out to the end...
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(opacity(), greaterThan(0.5));
      // ...and back, which is the second traversal, and then done.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(player.position, Duration.zero);
      expect(player.status, MotionPlayerStatus.completed);
    });

    testWidgets('a pause keeps the repeat, and play resumes it', (
      tester,
    ) async {
      player.repeat();
      await tester.pump(const Duration(milliseconds: 100));
      player.pause();
      var held = player.position;
      await tester.pump(const Duration(milliseconds: 200));
      expect(player.position, held, reason: 'paused is paused');
      player.play();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Still going: a repeat with no count runs until somebody stops it,
      // and resuming did not quietly turn it into a single play.
      expect(player.status, MotionPlayerStatus.playing);
      player.stop();
    });

    testWidgets('finish holds the end pose; stop drops it', (tester) async {
      player.finish();
      expect(opacity(), 1.0);
      expect(player.progress, 1.0);
      expect(player.status, MotionPlayerStatus.completed);
      player.stop();
      expect(scene.title.opacity, 1.0, reason: 'the authored value is back');
      expect(player.progress, 0.0);
    });

    testWidgets('it notifies, so a scrubber can bind to it', (tester) async {
      var ticks = 0;
      player.addListener(() => ticks++);
      player.progress = 0.5;
      expect(ticks, 1);
      expect(player.position, const Duration(milliseconds: 180));
    });
  });

  group('scene time', () {
    late SampleScene scene;
    late SampleIntro motion;
    late MotionPlayer player;

    setUp(() {
      scene = SampleScene();
      // A pass drawn by the clock rather than by a track: nothing in the
      // motion writes it, so only the time reaches it.
      scene.title.layers = [
        const FillLayer(paint: ShaderPaint('test/scene/shaders/probe.frag')),
      ];
      motion = SampleIntro(scene);
      player = MotionPlayer(motion, vsync: null);
      addTearDown(player.dispose);
    });

    Widget mount(Widget view) => MaterialApp(
      home: Align(alignment: Alignment.topLeft, child: view),
    );

    LayeredText title(WidgetTester tester) => tester.widget<LayeredText>(
      find.byWidgetPredicate((w) => w is LayeredText && w.layers.isNotEmpty),
    );

    testWidgets("a text's time is the motion's position", (tester) async {
      await tester.pumpWidget(mount(SceneView(scene, motion: motion)));
      player.position = const Duration(milliseconds: 400);
      await tester.pump();
      var text = title(tester);
      expect(text.time!.value, const Duration(milliseconds: 400));
    });

    testWidgets('an explicit time wins over the motion', (tester) async {
      var time = ValueNotifier(const Duration(seconds: 2));
      addTearDown(time.dispose);
      await tester.pumpWidget(
        mount(
          SceneView.document(scene.scene, motion: player.playable, time: time),
        ),
      );
      player.position = const Duration(milliseconds: 100);
      await tester.pump();
      expect(title(tester).time, same(time));
      expect(title(tester).time!.value, const Duration(seconds: 2));
    });

    testWidgets('the time listenable is the same object across rebuilds', (
      tester,
    ) async {
      await tester.pumpWidget(mount(SceneView(scene, motion: motion)));
      var first = title(tester).time;
      expect(first, isNotNull);
      // A rebuild from above, and one from the document an fx write flushes.
      await tester.pumpWidget(mount(SceneView(scene, motion: motion)));
      player.position = const Duration(milliseconds: 130);
      await tester.pump();
      await tester.pump();
      expect(title(tester).time, same(first));
    });

    testWidgets('a stop puts the time back at zero; a pause holds it', (
      tester,
    ) async {
      await tester.pumpWidget(mount(SceneView(scene, motion: motion)));
      var time = title(tester).time!;
      player.play();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      player.pause();
      var held = time.value;
      expect(held, greaterThan(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
      expect(time.value, held);
      player.stop();
      expect(time.value, Duration.zero);
    });

    testWidgets('a finish holds the end time, and a dispose drops it', (
      tester,
    ) async {
      await tester.pumpWidget(mount(SceneView(scene, motion: motion)));
      var time = title(tester).time!;
      player.finish();
      expect(time.value, const Duration(milliseconds: 360));
      // A second player over the same motion, so the group's own tear-down
      // still has one to dispose.
      MotionPlayer(motion, vsync: null)
        ..position = const Duration(milliseconds: 200)
        ..dispose();
      expect(time.value, Duration.zero);
    });
  });

  testWidgets('a compiled scene plays its compiled motion', (tester) async {
    var widget = const _Banner();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(alignment: Alignment.topLeft, child: widget),
      ),
    );
    var state = tester.state<_BannerState>(find.byWidget(widget));

    expect(state.player.playable.duration, const Duration(milliseconds: 360));
    expect(state.scene.title.fxRendered('opacity'), 0.0);

    // The clock is real: pumping frames is what moves it, and the view
    // redraws because an fx write notifies the document it wrote into.
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pump(const Duration(milliseconds: 130));
    var mid = state.scene.title.fxRendered('opacity') as double;
    expect(mid, greaterThan(0.0));
    expect(mid, lessThanOrEqualTo(1.0));

    await tester.pump(const Duration(milliseconds: 300));
    expect(state.scene.title.fxRendered('opacity'), 1.0);
    expect(state.player.status, MotionPlayerStatus.completed);

    // The authored plane was never touched — stopping drops the fx and the
    // scene is back to what the file says.
    state.player.stop();
    expect(state.scene.title.fxRendered('opacity'), 1.0);
    expect(state.scene.title.opacity, 1.0);
  });
}
