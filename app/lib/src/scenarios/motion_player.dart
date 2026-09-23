import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../plugins/native/scenarios_results.dart';
import 'artifacts.dart';

/// Playback over one step's recorded frames.
///
/// The frames are the transition *into* a step, and the last of them is the
/// frame the step's own screenshot was taken on — so playback always ends
/// where the still already was, and a player that stops is indistinguishable
/// from a picture. That is the whole reason the flow canvas can play a node in
/// place without anything moving.
///
/// Drives off a [Ticker] rather than a timer per frame: the index is a
/// function of elapsed time, so a slow decode drops a frame instead of
/// stretching the animation, and the motion keeps the app's real duration.
class ScenarioMotionController extends ChangeNotifier {
  ScenarioMotionController({
    required this.frames,
    required this.interval,
    required TickerProvider vsync,
  }) : assert(frames.length > 1) {
    _ticker = vsync.createTicker(_tick);
  }

  /// Playback for [step], or null when it recorded no motion.
  static ScenarioMotionController? forStep(
    ScenarioRunStep step,
    TickerProvider vsync,
  ) {
    if (!step.hasMotion) return null;
    return ScenarioMotionController(
      frames: step.framePaths,
      interval: Duration(milliseconds: step.frameIntervalMs ?? 33),
      vsync: vsync,
    );
  }

  /// The frames, as the report spells them — resolved by whichever
  /// [ScenarioArtifacts] the surface playing them reads through.
  final List<String> frames;

  /// Fake time between two frames — the app's own speed.
  final Duration interval;

  late final Ticker _ticker;

  var _index = 0;
  Duration _startedAt = Duration.zero;

  /// Which frame is showing. The last one is the resting state.
  int get index => _index;

  bool get playing => _ticker.isActive;

  /// Where playback is, in the app's own milliseconds — what the scrubber is
  /// labelled with, and honest because fake time has no jitter in it.
  Duration get position => interval * _index;

  Duration get duration => interval * (frames.length - 1);

  /// Plays from the start, or from wherever a scrub left off.
  ///
  /// Restarts when parked on the last frame, which is the common case: the
  /// resting state *is* the end, so "play" almost always means "again".
  void play() {
    if (_ticker.isActive) return;
    if (_index >= frames.length - 1) _index = 0;
    _startedAt = -(interval * _index);
    _ticker.start();
    notifyListeners();
  }

  void pause() {
    if (!_ticker.isActive) return;
    _ticker.stop();
    notifyListeners();
  }

  void toggle() => playing ? pause() : play();

  /// Stops and returns to the resting frame — what a pointer leaving a node
  /// does, so the canvas goes back to being a wall of screenshots.
  void rest() {
    _ticker.stop();
    _seek(frames.length - 1);
  }

  void seek(int index) {
    _ticker.stop();
    _seek(index);
  }

  void step(int delta) => seek(_index + delta);

  void _seek(int index) {
    var clamped = index.clamp(0, frames.length - 1);
    if (clamped == _index) return;
    _index = clamped;
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    var frame =
        ((elapsed - _startedAt).inMicroseconds / interval.inMicroseconds)
            .floor();
    if (frame >= frames.length - 1) {
      // Held on the last frame rather than looped: it is the screenshot, and
      // a flow canvas of looping phones is a canvas nobody can read.
      _ticker.stop();
      _seek(frames.length - 1);
      notifyListeners();
      return;
    }
    _seek(frame);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// How long the recorded transition took, in the app's own time.
///
/// The interval times the gaps, not the frames: a two-frame recording is one
/// interval long, and counting frames would report every transition one tick
/// longer than it was.
Duration scenarioMotionDuration(ScenarioRunStep step) =>
    Duration(milliseconds: step.frameIntervalMs ?? 33) *
    ((step.frameCount ?? 1) - 1);

/// The image provider for one recorded frame.
///
/// Raw frames go through `RawImageProvider` — the panel records raw for the
/// same reason it captures shots raw, and decoding a PNG thirty times a
/// second to show a transition would give the encoding cost straight back.
ImageProvider scenarioFrameImage(
  ScenarioArtifacts artifacts,
  ScenarioRunStep step,
  String frame,
) => artifacts.frameImageOf(step, frame);

/// The decoded bytes one step's recording occupies once every frame is in the
/// image cache — raw or PNG alike, since the cache holds pixels either way.
int scenarioMotionBytes(ScenarioRunStep step) =>
    (step.frameCount ?? 0) *
    (step.frameWidth ?? 0) *
    (step.frameHeight ?? 0) *
    4;

/// How many transitions' frames stay decoded at once.
///
/// The problem this exists for, measured: at the step's own scale a frame of a
/// phone-sized recording is 1.29MB of pixels, and one five-step scenario is
/// 121MB. Flutter's image cache holds 100MB in total — so without a bound, a
/// walk along a long flow evicts not just the older recordings but the
/// *screenshots* too, and every node you pan back to reloads.
///
/// So the panel keeps its own MRU over whole transitions and hands the rest
/// back. A budget in steps rather than in bytes would be the wrong shape: what
/// gets played is a transition, and half of one is no use.
///
/// Global, like the image cache it is managing, and for the same reason: the
/// flow view, the step page and any future surface are all playing frames out
/// of one shared pool, and a per-widget budget would let two of them
/// double-spend it.
final scenarioMotionResidency = ScenarioMotionResidency();

class ScenarioMotionResidency {
  ScenarioMotionResidency({this.budgetBytes = 64 << 20});

  /// Well under the image cache's own 100MB, because the screenshots — the
  /// thing the flow is actually made of — have to keep fitting beside the
  /// recordings.
  final int budgetBytes;

  /// Least-recently-played first, keyed by the step's frames directory.
  final _order = <String>[];
  final _steps = <String, ScenarioRunStep>{};

  /// What each resident recording was read through, so eviction can rebuild
  /// the very providers that decoded it. A provider built against a different
  /// source is a different cache key, and evicting it would free nothing.
  final _sources = <String, ScenarioArtifacts>{};

  /// The recordings that made it all the way through a precache — a subset of
  /// the resident ones, since warming is a loop that eviction or a reader
  /// moving on can cut short.
  final _warm = <String>{};

  /// What the recordings currently hold, in decoded bytes.
  int get residentBytes =>
      _steps.values.fold(0, (sum, step) => sum + scenarioMotionBytes(step));

  int get residentSteps => _steps.length;

  /// Whether [step]'s frames are still ones the panel wants decoded.
  bool isResident(ScenarioRunStep step) =>
      step.frames != null && _steps.containsKey(step.frames);

  /// Whether every frame of [step] is decoded and in the image cache.
  ///
  /// The difference between a transition that plays and one that draws blanks
  /// while it decodes — which is what anything that starts playback *for* the
  /// reader, rather than because they pressed play, has to ask first.
  bool isWarm(ScenarioRunStep step) =>
      step.frames != null && _warm.contains(step.frames);

  /// Marks [step]'s frames as the ones in use, and evicts whatever that pushes
  /// over the budget. The step just touched is never the one evicted, however
  /// big it is: a transition too large for the budget still has to play.
  void touch(ScenarioRunStep step, ScenarioArtifacts artifacts) {
    if (step.frames case var key?) {
      _order
        ..remove(key)
        ..add(key);
      _steps[key] = step;
      _sources[key] = artifacts;
      while (_order.length > 1 && residentBytes > budgetBytes) {
        _release(_order.first);
      }
    }
  }

  /// Drops [step]'s frames now — for a run whose artifacts have been replaced,
  /// where the files behind the cached pixels are already deleted.
  void forget(ScenarioRunStep step) {
    if (step.frames case var key?) _release(key);
  }

  void _release(String key) {
    _order.remove(key);
    _warm.remove(key);
    var step = _steps.remove(key);
    var artifacts = _sources.remove(key);
    if (step == null || artifacts == null) return;
    for (var frame in step.framePaths) {
      unawaited(scenarioFrameImage(artifacts, step, frame).evict());
    }
  }

  @visibleForTesting
  void clear() {
    for (var key in _order.toList()) {
      _release(key);
    }
  }
}

/// Warms the image cache for every frame of [step], and makes room for them.
///
/// Called when a player arms rather than when it plays: the first pass over a
/// recording is the only one that decodes, and paying for it while the pointer
/// is still arriving is the difference between a transition that plays and one
/// that stutters once and then plays. Every pass after that is a cache hit —
/// [RawImageProvider]'s key is a value over `(size, format, path)`, so the
/// provider rebuilt on each frame resolves to the image already decoded.
Future<void> precacheScenarioMotion(
  BuildContext context,
  ScenarioRunStep step,
) async {
  var artifacts = ScenarioArtifactsScope.of(context);
  scenarioMotionResidency.touch(step, artifacts);
  for (var frame in step.framePaths) {
    if (!context.mounted) return;
    // Stops the moment this recording stops being one of the resident ones.
    // Sweeping the pointer across a flow starts a loop per node it crosses,
    // and a loop that outlived its own eviction would put the frames it was
    // still decoding straight back into the image cache — making the budget
    // true only for somebody hovering slowly.
    if (!scenarioMotionResidency.isResident(step)) return;
    await precacheImage(scenarioFrameImage(artifacts, step, frame), context);
  }
  // Only here, where every frame got through: a recording warmed halfway is
  // one that would still flicker, and saying otherwise is worse than saying
  // nothing.
  if (step.frames case var key?) scenarioMotionResidency._warm.add(key);
}
