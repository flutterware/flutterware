import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/reel.dart';
import 'package:flutterware/scene_authoring.dart';

/// A stage that is a **scene**, and the stock edit that builds one.
///
/// Pure: an edit is a take in and a reel out, and a motion is `apply(t)`, so
/// every claim here is checked with no pixels and no app.
void main() {
  group('the camera', () {
    const screen = Size(400, 800);

    test('stays put when the target is the centre', () {
      expect(
        cameraOffset(screen: screen, toward: const Offset(200, 400), zoom: 2),
        Offset.zero,
      );
    });

    test('brings the target to the centre, scaled about the centre', () {
      // A point 50 right of centre lands 100 right of it at 2×, so the
      // camera moves 100 left to put it back.
      expect(
        cameraOffset(screen: screen, toward: const Offset(250, 400), zoom: 2),
        const Offset(-100, 0),
      );
    });

    test('never shows past the edge of the screen', () {
      // The corner would want −400,−800; at 2× the screen only has 200 and
      // 400 to spare on each side, and that is what it gets.
      expect(
        cameraOffset(screen: screen, toward: const Offset(400, 800), zoom: 2),
        const Offset(-200, -400),
      );
      // No zoom, no slack — whatever the target.
      expect(
        cameraOffset(screen: screen, toward: const Offset(400, 800), zoom: 1),
        Offset.zero,
      );
    });
  });

  group('the stock scene edit', () {
    Map<String, Object?> phase(
      String kind,
      int atMs,
      int durationMs, {
      String? verb,
      String? target,
      Rect? aim,
    }) => {
      'kind': kind,
      'frame': atMs ~/ 33,
      'atMs': atMs,
      'frames': durationMs ~/ 33,
      'durationMs': durationMs,
      'verb': ?verb,
      'target': ?target,
      if (aim != null)
        'aim': {'x': aim.left, 'y': aim.top, 'w': aim.width, 'h': aim.height},
    };

    late Take take;
    late Reel reel;

    setUp(() {
      take = Take.decode({
        'version': 2,
        'scenario': 'Order a cappuccino',
        'fps': 30,
        'scale': 1,
        'width': 400,
        'height': 800,
        'screen': {'width': 400, 'height': 800},
        'frames': 100,
        'durationMs': 3333,
        'beats': [
          phase('open', 0, 500),
          phase('travel', 500, 300, verb: 'tap'),
          phase('aim', 800, 100, verb: 'tap'),
          phase('press', 900, 100, verb: 'tap'),
          phase(
            'act',
            1000,
            300,
            verb: 'tap',
            target: 'Buy',
            aim: const Rect.fromLTWH(150, 700, 100, 40),
          ),
          phase('dwell', 1300, 400),
        ],
        'cues': [
          {
            'atMs': 100,
            'type': 'ScenarioTitle',
            'label': 'title: Order a coffee',
            'data': {'text': 'Order a coffee'},
          },
        ],
      });
      reel = const StockSceneReel().edit(take);
    });

    test('draws through a scene the size of the app', () {
      var stage = reel.stage as SceneStage;
      expect(stage.sizeFor(const Size(1, 1)), const Size(400, 800));
      expect(stage.scene.nodeNamed('camera'), isNotNull);
      expect(stage.scene.nodeNamed('screen'), isA<ExternalNode>());
      expect(stage.scene.nodeNamed('caption0'), isA<TextNode>());
      expect(stage.scene.nodeNamed('closing'), isA<TextNode>());
    });

    test('plays the take, holds after the first tap, and freezes the end', () {
      // 1700ms of take, 800ms of hold, 1200ms of tail.
      expect(reel.duration, const Duration(milliseconds: 1700 + 800 + 1200));
      expect(reel.shots.last.frozen, isTrue);
      var dwell = take.beats.whereType<Tapped>().single.phase(PhaseKind.dwell)!;
      expect(reel.holds, {dwell.index: const Duration(milliseconds: 800)});
    });

    test('pushes in on the tap, and the camera is moving before the press', () {
      var stage = reel.stage as SceneStage;
      var camera = stage.scene.nodeNamed('camera')!;
      // The press is at 900ms of take, which is 900ms of reel; the push-in
      // starts 420ms before it and is fully in by then.
      stage.motion!.apply(const Duration(milliseconds: 400));
      expect(camera.fxRendered('scale'), 1.0);
      stage.motion!.apply(const Duration(milliseconds: 700));
      expect(camera.fxRendered('scale'), greaterThan(1.0));
      expect(camera.fxRendered('scale'), lessThan(1.6));
      stage.motion!.apply(const Duration(milliseconds: 900));
      expect(camera.fxRendered('scale'), 1.6);
      // And the target, 200 below centre, is what it is pushing toward: the
      // camera has moved up by as much as the screen has to spare.
      expect(camera.fxRendered('translateY'), lessThan(0));
      // Back out by the end of the beat.
      stage.motion!.apply(const Duration(milliseconds: 1700));
      expect(camera.fxRendered('scale'), 1.0);
    });

    test('a title fades in as a caption, in reel time', () {
      var stage = reel.stage as SceneStage;
      var caption = stage.scene.nodeNamed('caption0')!;
      stage.motion!.apply(const Duration(milliseconds: 100));
      expect(caption.fxRendered('opacity'), 0.0);
      stage.motion!.apply(const Duration(milliseconds: 100 + 350));
      expect(caption.fxRendered('opacity'), 1.0);
      stage.motion!.apply(const Duration(milliseconds: 100 + 1800));
      expect(caption.fxRendered('opacity'), 0.0);
    });
  });
}
