import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'run_args.dart';

/// Recording the *motion* of a transition — every frame between two captured
/// steps, not only the frame it ended on.
///
/// A screenshot pair says where the app started and where it stopped. What it
/// cannot say is what happened in between, which for a Hero flight or a
/// cross-fade is the entire question.
///
/// Under `FakeAsync` the frames are the animation's *ideal* curve — exactly
/// [interval] apart, no drops, identical run to run. That is what makes them
/// diffable and slow-motion free, and it is also why a recording can never
/// show jank: there is none to show.
class MotionRecording {
  const MotionRecording({
    this.interval = const Duration(milliseconds: 33),
    this.scale,
    this.maxFrames = 90,
  });

  /// The fake time between frames — the pump step a recording settle takes,
  /// where an ordinary one takes 100ms.
  ///
  /// 33ms is 30fps, which is the measured knee: a transition costs ~70ms to
  /// record there against ~380ms at 60fps and full scale, and no eye reading
  /// a page push on a flow canvas can tell the two apart.
  final Duration interval;

  /// Output pixels per logical pixel, or **null for the step's own scale** —
  /// which is the default, and the only setting that does not show.
  ///
  /// Recording at half scale was tried first, on the theory that the motion is
  /// not the evidence and the last frame is the crisp shot anyway. In the
  /// panel it reads as a blur that snaps sharp when the animation stops, and
  /// the snap is more distracting than the four frames of extra work. So the
  /// frames match the shot, and the cost is paid: at 1× on a phone a frame is
  /// 1.29MB of raw pixels against 323KB at half — which is why
  /// `ScenarioMotionResidency` in the panel exists at all.
  final double? scale;

  /// The ceiling on one transition's frames.
  ///
  /// Not optional. `Settle.standard` spends five fake seconds before it gives
  /// up on an indefinite animation, and at 30fps a spinner would otherwise
  /// bank 150 frames of itself — every time. 90 frames is three seconds of
  /// motion, where a Material page transition is nine.
  final int maxFrames;
}

/// One transition's recorded frames, as bytes.
///
/// The pixel size is the frames' own, not the step's: a recording runs at
/// [MotionRecording.scale] and the shot beside it does not, so a host
/// decoding raw frames needs to be told which of the two it is holding.
class ScenarioMotionFrames {
  const ScenarioMotionFrames({
    required this.bytes,
    required this.width,
    required this.height,
    required this.dropped,
  });

  static const empty = ScenarioMotionFrames(
    bytes: [],
    width: 0,
    height: 0,
    dropped: 0,
  );

  /// One entry per frame, in the order they were drawn, in the step's own
  /// format — `png`, or bare rgba8888 rows of [width]×[height].
  final List<Uint8List> bytes;

  final int width;
  final int height;

  /// Frames refused by the cap. On the record so a recording that was cut off
  /// mid-movement does not read as an animation that ended there.
  final int dropped;

  /// One frame is the still the transition started from — recorded by every
  /// policy, and not a movie.
  bool get hasMotion => bytes.length > 1;
}

/// What a settle loop hands its frames to.
///
/// Two things record a run's frames and they want opposite lifetimes: the
/// panel's recorder ([ScenarioMotionRecorder]) banks one transition and hands
/// the lot over when the step captures, while a film (`ScenarioFilm`) keeps
/// every frame of the whole scenario and has to spill them to disk as it
/// goes. The loops care about neither — they pump, they hand over, and they
/// let the sink say when it needs a turn of the real event loop.
abstract class ScenarioFrameSink {
  /// The fake time between frames — what the loop pumps by while this sink is
  /// following it.
  Duration get interval;

  /// Keeps the frame currently on screen.
  void capture(WidgetTester tester);

  /// A chance to pay for what has been banked, after a frame was captured.
  ///
  /// Nothing for a sink that drains at the step; a `runAsync` and a batch of
  /// files for one that cannot hold a film in memory.
  Future<void> flush(WidgetTester tester) async {}
}

/// Collects one transition's frames, a handle at a time.
///
/// The mechanism the whole feature rests on: `toImageSync` returns without
/// leaving `FakeAsync`, so the pump loop can keep a frame per pump and pay
/// for the pixels once, later, in the single `runAsync` the capture already
/// opens. A `toImage` per frame would need a `runAsync` per frame, and that
/// fixed cost is what makes the naive version 25× slower.
class ScenarioMotionRecorder implements ScenarioFrameSink {
  ScenarioMotionRecorder(this.settings);

  final MotionRecording settings;

  final _frames = <ui.Image>[];

  /// Frames refused by [MotionRecording.maxFrames]. Reported rather than
  /// swallowed, so a recording cut off mid-movement does not look like an
  /// animation that ended there.
  var _dropped = 0;

  @override
  Duration get interval => settings.interval;

  /// Nothing: the frames are banked until the step captures, which is what
  /// makes one `runAsync` pay for a whole transition. See [drain].
  @override
  Future<void> flush(WidgetTester tester) async {}

  /// Keeps the frame currently on screen.
  ///
  /// Silent about everything that can go wrong. This runs inside every verb of
  /// every scenario, and a recording is a nicety — it may slow a run down, it
  /// may not fail one. Before the first `pumpWidget` there is no layer to
  /// read, which is not an error but the first frame of a movie that has not
  /// started.
  @override
  void capture(WidgetTester tester) {
    if (_frames.length >= settings.maxFrames) {
      _dropped++;
      return;
    }
    var view = tester.binding.renderViews.singleOrNull;
    if (view == null) return;
    // A root layer exists only once the view has painted, which is also the
    // only condition under which its size means anything — so this one check
    // covers "nothing on screen yet" as well.
    var layer = view.debugLayer;
    if (layer is! OffsetLayer) return;
    // Physical pixels, like the step capture: the device-pixel-ratio
    // transform sits *inside* the root layer, so a logical rect would save
    // the top-left corner of a 3× device.
    var dpr = view.flutterView.devicePixelRatio;
    // Resolved per frame rather than at construction, and through the same
    // function the shot uses: only the guest, at capture time, knows what
    // ratio it is rendering at when the run asked for the device's own.
    var scale = settings.scale ?? scenarioCaptureScale(scenarioRunArgs, dpr);
    _frames.add(
      layer.toImageSync(
        Offset.zero & (view.size * dpr),
        pixelRatio: scale / dpr,
      ),
    );
  }

  /// Whether there is any motion here.
  ///
  /// One frame is a still: the frame the transition started from, with nothing
  /// after it. Every policy banks that one, so "recorded" and "moved" are
  /// different questions and only the second is worth a player.
  bool get hasMotion => _frames.length > 1;

  int get dropped => _dropped;

  /// The frames' bytes, their pixel size, and how many were dropped. Empties
  /// the recorder and disposes the handles.
  ///
  /// Must be called inside `runAsync` — this is where the rasterization
  /// deferred by [capture] is actually paid, and it is asynchronous.
  ///
  /// [raw] follows the step's own format for the same reason the step has the
  /// choice: encoding is the expensive half and a host that can blit pixels
  /// should not pay it. Measured at half scale, 30fps, three transitions:
  /// 10ms of reading and 18MB raw against 113ms of encoding and 0.29MB as
  /// PNG. The panel takes raw — it displays raw shots already, and its run
  /// directory is replaced on every run rather than accumulated.
  Future<ScenarioMotionFrames> drain({required bool raw}) async {
    var bytes = <Uint8List>[];
    var width = 0;
    var height = 0;
    for (var frame in _frames) {
      var data = await frame.toByteData(
        format: raw ? ui.ImageByteFormat.rawRgba : ui.ImageByteFormat.png,
      );
      if (data != null) {
        bytes.add(data.buffer.asUint8List());
        // Every frame of a transition is the same size — the view cannot
        // resize mid-verb — so the last one answers for all of them.
        (width, height) = (frame.width, frame.height);
      }
      frame.dispose();
    }
    var dropped = _dropped;
    _frames.clear();
    _dropped = 0;
    return ScenarioMotionFrames(
      bytes: bytes,
      width: width,
      height: height,
      dropped: dropped,
    );
  }

  /// Throws the frames away unencoded — a `split` replay walking a prefix
  /// some earlier path already captured, exactly as the event buffer does.
  void discard() {
    for (var frame in _frames) {
      frame.dispose();
    }
    _frames.clear();
    _dropped = 0;
  }
}
