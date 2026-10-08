import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../scene/core/curves.dart';
import '../scene/core/listenable.dart';
import '../scene/core/model.dart';
import '../scene/core/motion_model.dart';
import '../scene/core/motion_runtime.dart';
import '../scene/core/values.dart';
import '../scene/flutter_bridge.dart';
import '../scene/view.dart';
import 'cues.dart';
import 'reel.dart';
import 'stage.dart';
import 'take.dart';

/// A stage that is a **scene**: a document built by an edit, with a motion
/// over it, drawn by the same view the editor draws.
///
/// The picture is a scene, so it lays out, styles and nests the way every
/// scene does; the timing is a [Playable], so it composes with `Par`, `Seq`,
/// `At` and `Speed` the way every motion does; and the app is one node in it
/// — [ScreenArgs] — placed and animated like any other. There is no second
/// animation model and no second layout model.
class SceneStage extends ReelStage {
  SceneStage(this.scene, {this.motion});

  final SceneDocument scene;

  /// The motion over [scene], already bound to it, in **reel** time.
  final Playable? motion;

  @override
  Size sizeFor(Size screen) {
    var root = scene.root;
    var w = root.width;
    var h = root.height;
    return Size(
      w != null && w.isFinite ? w : screen.width,
      h != null && h.isFinite ? h : screen.height,
    );
  }

  /// Parks the motion at the frame's moment.
  ///
  /// The scene coalesces fx notifications through a scheduler the process
  /// installs — a post-frame callback under Flutter, a microtask headless —
  /// and a stage renders in a pipeline of its own that never frames and is
  /// pumped by hand. So the flush is made synchronous for exactly the span
  /// of the apply: the view hears the change now, and the pump that follows
  /// rebuilds what moved.
  @override
  void before(StageFrame frame) {
    var motion = this.motion;
    if (motion == null) return;
    var installed = sceneFlushScheduler;
    sceneFlushScheduler = (flush) => flush();
    try {
      motion.apply(frame.at);
    } finally {
      sceneFlushScheduler = installed;
    }
  }

  /// The motion's clock, for what the clock draws — a shader pass's
  /// `uTime`, which no fx write reaches. Held, because the adapter is a new
  /// object per ask and a painter compares its time by identity.
  ///
  /// Handed over as a time rather than as the motion: a view given a motion
  /// registers it as a previewable playhead, and [before] is what drives
  /// this one.
  late final _time = motion?.clock.flutter;

  @override
  Widget build(StageFrame frame) => SceneView.document(scene, time: _time);
}

/// The app's frame, as a scene node — `ExternalNode(const ScreenArgs())`.
///
/// Sized by the node it is placed in. The widget reads the frame off the
/// stage above it, so the args carry nothing: what changes per frame is the
/// picture, and that never went through the scene's data plane.
class ScreenArgs extends SceneExtArgs {
  const ScreenArgs();

  @override
  String get entry => 'scenario.screen';

  @override
  ScreenArgs merge(SceneArgs fx) => this;

  @override
  Map<String, Object?> toMap() => const {};

  @override
  Object build() => const Screen();
}

/// The cursor, as a scene node — placed in the same node as the screen, so a
/// camera moving one moves both.
///
/// Its args are the cursor's look, so an edit that knows what the finger is
/// drawn over picks the pair of colours that survives it, and a motion track
/// on `args.size` or `args.ink` changes it mid-reel like any other arg. What
/// the args do **not** carry is the pointer's position or whether it is a
/// fingertip or an arrow: where the finger is comes from the run, and what a
/// device is touched with is the device's fact, not the reel's.
class PointerArgs extends SceneExtArgs {
  const PointerArgs({this.ink, this.paper, this.size = 1, this.ripple = true});

  /// The dark mark, or null for the film's own.
  final SceneColor? ink;

  /// The light mark, or null for the film's own.
  final SceneColor? paper;

  /// A multiplier on every dimension of the cursor.
  final double size;

  /// Whether a press sends a ring out.
  final bool ripple;

  @override
  String get entry => 'scenario.pointer';

  @override
  PointerArgs merge(SceneArgs fx) => PointerArgs(
    ink: fx.color('ink') ?? ink,
    paper: fx.color('paper') ?? paper,
    size: fx.number('size') ?? size,
    ripple: fx.flag('ripple') ?? ripple,
  );

  @override
  Map<String, Object?> toMap() => {
    if (ink case var c?) 'ink': c.argb,
    if (paper case var c?) 'paper': c.argb,
    'size': size,
    'ripple': ripple,
  };

  /// The look these args describe.
  CursorLook get look {
    const standard = CursorLook.standard;
    return CursorLook(
      ink: ink == null ? standard.ink : Color(ink!.argb),
      paper: paper == null ? standard.paper : Color(paper!.argb),
      size: size,
      ripple: ripple,
    );
  }

  @override
  Object build() => Pointer(look: look);
}

/// Where a camera has to move to zoom in on a point.
///
/// The scene's imposed transforms scale a node about its **centre**, so a
/// point `p` lands at `c + (p − c)·z` and bringing it back to the centre is a
/// translation of `−(p − c)·z`. Clamped so the screen's edge never comes
/// inside the frame: a push-in that shows the backdrop past the app's corner
/// is a camera that overshot, not a camera that zoomed.
Offset cameraOffset({
  required Size screen,
  required Offset toward,
  required double zoom,
}) {
  var centre = screen.center(Offset.zero);
  var shift = (toward - centre) * -zoom;
  var slackX = (zoom - 1) * screen.width / 2;
  var slackY = (zoom - 1) * screen.height / 2;
  return Offset(
    shift.dx.clamp(-math.max(slackX, 0), math.max(slackX, 0)).toDouble(),
    shift.dy.clamp(-math.max(slackY, 0), math.max(slackY, 0)).toDouble(),
  );
}

/// The edit a run gets when it asks for a scene and nobody wrote one: the app
/// on a dark ground, the scenario's titles as captions, a push-in on every
/// tap, and the last frame held under the scenario's name.
///
/// It is the demo the design was written toward, and it is deliberately
/// plain — everything characterful belongs in an edit somebody wrote against
/// their own app. What it shows is that the pieces meet: a title is a
/// `TextNode` with an opacity track, a push-in is a `scale` and a translate
/// on the node the screen is in, and every one of those is in **reel** time,
/// which the builder already keeps.
class StockSceneReel extends ScenarioReelEdit {
  const StockSceneReel({
    this.zoom = 1.6,
    this.pushIn = const Duration(milliseconds: 420),
    this.titleFor = const Duration(milliseconds: 1800),
    this.holdAfterFirstTap = const Duration(milliseconds: 800),
    this.tail = const Duration(milliseconds: 1200),
    this.ground = const SceneColor(0xFF15161A),
  });

  final double zoom;
  final Duration pushIn;
  final Duration titleFor;

  /// How long the app is left running after the first tap — the hold that
  /// proves a hold is not a freeze.
  final Duration holdAfterFirstTap;

  final Duration tail;
  final SceneColor ground;

  @override
  Reel edit(Take take) {
    var screen = take.screen;
    var camera = FrameNode(name: 'camera')
      ..x = 0
      ..y = 0
      ..width = screen.width
      ..height = screen.height
      ..clip = true
      ..children.addAll([
        ExternalNode(const ScreenArgs(), name: 'screen')
          ..width = screen.width
          ..height = screen.height,
        ExternalNode(const PointerArgs(), name: 'pointer')
          ..width = screen.width
          ..height = screen.height,
      ]);
    var root = FrameNode(name: 'root')
      ..width = screen.width
      ..height = screen.height
      ..fill = ground
      ..children.add(camera);
    // The document is made *after* the walk below has added its captions:
    // a document adopts the nodes it is given at construction, and a node
    // added later has no document to tell when its fx move.
    var motion = MotionDocument(sceneClassName: 'StockReel');
    var placed = <TimelineExpr>[];

    var b = ReelBuilder(take);
    var captions = 0;
    var held = false;
    for (var beat in take.beats) {
      switch (beat) {
        case Said(cue: ScenarioTitle(:var text)):
          // A lower third: a dark band and the words on it, because a stage
          // that knows nothing about the app cannot know what colour the app
          // is under the caption, and white on a white screen is no caption.
          // Both nodes are authored at full opacity and hidden by the track:
          // opacity fx *multiplies*, so a node authored at 0 stays at 0
          // whatever a track says; the track's first key is 0 and `At` clamps
          // to it before the window opens, which keeps the caption unseen
          // until its cue.
          var n = captions++;
          var band = ShapeNode(name: 'captionBand$n', corner: 10)
            ..x = 16
            ..y = screen.height - 108
            ..width = screen.width - 32
            ..height = 64
            ..fill = const SceneColor(0xCC15161A);
          var caption = TextNode(text, name: 'caption$n')
            ..x = 32
            ..y = screen.height - 94
            ..width = screen.width - 64
            ..fontSize = 28
            ..weight = SceneFontWeight.w700
            ..color = const SceneColor(0xFFFFFFFF);
          root.children.addAll([band, caption]);
          List<MotionKey> fadeKeys() => [
            MotionKey(at: Duration.zero, value: 0.0),
            MotionKey(at: const Duration(milliseconds: 350), value: 1.0),
            MotionKey(
              at: titleFor - const Duration(milliseconds: 350),
              value: 1.0,
            ),
            MotionKey(at: titleFor, value: 0.0),
          ];
          var fadeBand = AnimateGroup(band, name: band.name)
            ..tracks['opacity'] = MotionTrack(fadeKeys());
          var fade = AnimateGroup(caption, name: caption.name)
            ..tracks['opacity'] = MotionTrack(fadeKeys());
          // Said partway through a beat that has already been played — the
          // title over the opening hold — so it lands where it was said, not
          // where the walk has got to.
          var at = b.reelTimeOf(beat.at) ?? b.reel;
          motion.groups.addAll([fadeBand, fade]);
          placed.addAll([AtExpr(at, fadeBand), AtExpr(at, fade)]);
          b.say(ScenarioTitle(text), over: titleFor, at: at);

        case Tapped(:var target?):
          // Start moving before the finger presses: the camera knows what is
          // about to happen, which is the whole reason the edit reads a take
          // rather than watching a run.
          var press = beat.phase(PhaseKind.press) ?? beat.phases.first;
          var start = b.reel + (press.at - beat.at) - pushIn;
          if (start < Duration.zero) start = Duration.zero;
          var off = cameraOffset(
            screen: screen,
            toward: target.center,
            zoom: zoom,
          );
          var end = beat.duration;
          var back = end - pushIn;
          if (back < pushIn) back = pushIn;
          var push = AnimateGroup(camera, name: 'push${beat.at.inMilliseconds}')
            ..tracks['scale'] = MotionTrack([
              MotionKey(
                at: Duration.zero,
                value: 1.0,
                curve: SceneCurves.easeOut,
              ),
              MotionKey(at: pushIn, value: zoom),
              MotionKey(at: back, value: zoom, curve: SceneCurves.easeInOut),
              MotionKey(at: end, value: 1.0),
            ])
            ..tracks['translateX'] = MotionTrack([
              MotionKey(
                at: Duration.zero,
                value: 0.0,
                curve: SceneCurves.easeOut,
              ),
              MotionKey(at: pushIn, value: off.dx),
              MotionKey(at: back, value: off.dx, curve: SceneCurves.easeInOut),
              MotionKey(at: end, value: 0.0),
            ])
            ..tracks['translateY'] = MotionTrack([
              MotionKey(
                at: Duration.zero,
                value: 0.0,
                curve: SceneCurves.easeOut,
              ),
              MotionKey(at: pushIn, value: off.dy),
              MotionKey(at: back, value: off.dy, curve: SceneCurves.easeInOut),
              MotionKey(at: end, value: 0.0),
            ]);
          motion.groups.add(push);
          placed.add(AtExpr(start, push));
          b.playBeat(beat);
          if (!held) {
            held = true;
            b.hold(holdAfterFirstTap, after: beat);
          }

        case _:
          b.playBeat(beat);
      }
    }

    // The end: the last frame held, under the scenario's name.
    var closing = TextNode(take.scenario, name: 'closing')
      ..x = 24
      ..y = screen.height / 2 - 20
      ..width = screen.width - 48
      ..fontSize = 32
      ..weight = SceneFontWeight.w700
      ..color = const SceneColor(0xFFFFFFFF);
    root.children.add(closing);
    var dim = AnimateGroup(camera, name: 'dim')
      ..tracks['opacity'] = MotionTrack([
        MotionKey(at: Duration.zero, value: 1.0),
        MotionKey(at: const Duration(milliseconds: 500), value: 0.35),
      ]);
    var reveal = AnimateGroup(closing, name: 'reveal')
      ..tracks['opacity'] = MotionTrack([
        MotionKey(at: Duration.zero, value: 0.0),
        MotionKey(at: const Duration(milliseconds: 500), value: 1.0),
      ]);
    motion.groups.addAll([dim, reveal]);
    placed.add(AtExpr(b.reel, dim));
    placed.add(AtExpr(b.reel, reveal));
    b.freeze(tail);

    motion.timeline = ParExpr(placed);
    var scene = SceneDocument(root);
    var bound = BoundMotion.bind(motion, scene);
    return b.build(stage: SceneStage(scene, motion: bound));
  }
}
