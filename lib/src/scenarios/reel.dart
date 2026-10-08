import 'stage.dart';
import 'take.dart';

/// A reel: what the output shows, when, and what the stage is told while it
/// does.
///
/// Built by an [ScenarioReelEdit] from a [Take] and then handed to a second,
/// filming run. It is a **structure, not a stream** — every decision is made
/// before a pixel is drawn, which is what lets a camera start moving *before*
/// the tap it is moving toward.
class Reel {
  Reel({
    required this.shots,
    required this.cues,
    required this.holds,
    this.stage = const BareStage(),
  });

  /// What the frames are drawn through. An edit that built a scene hands it
  /// over here, so a reel is one object: the picture and the timing of it.
  final ReelStage stage;

  /// The output, in order and contiguous.
  final List<ReelShot> shots;

  /// What the stage is told, over stretches of output time.
  final List<CueSpan> cues;

  /// Extra source time to pump before the phase at each index — a **hold**.
  ///
  /// The one thing a reel asks of the run rather than of the picture. A hold
  /// is not a freeze: the app keeps animating through it, because the frames
  /// are really pumped, which is the whole reason a reel is a re-run and not a
  /// post-process.
  final Map<int, Duration> holds;

  Duration get duration => shots.isEmpty ? Duration.zero : shots.last.end;

  /// The cues live at [at].
  List<CueSpan> cuesAt(Duration at) => [
    for (var cue in cues)
      if (cue.at <= at && at < cue.end) cue,
  ];
}

/// One stretch of output.
///
/// `ReelShot` rather than `Shot`, which in the scenario lane is already the
/// request for a screenshot — and an edit imports both.
class ReelShot {
  ReelShot({required this.at, required this.duration, required this.frozen});

  /// Where this begins in the reel.
  final Duration at;

  final Duration duration;

  /// Whether the app moves under it.
  ///
  /// A frozen shot repeats the last frame and consumes no source: it is the
  /// title card and the last beat held. A playing shot spends one source frame
  /// per output frame.
  final bool frozen;

  Duration get end => at + duration;
}

/// A cue over a stretch of output time.
///
/// The stage is handed the span, not just the value, so it can draw a fade
/// from where it is inside one. Interpolated tracks are the scene's job; this
/// is what a reel can say before a stage is a scene.
class CueSpan {
  CueSpan({required this.at, required this.duration, required this.cue});

  final Duration at;
  final Duration duration;
  final Object cue;

  Duration get end => at + duration;

  /// How far through this span [now] is, from 0 to 1.
  double progress(Duration now) => duration == Duration.zero
      ? 1
      : ((now - at).inMicroseconds / duration.inMicroseconds).clamp(0, 1);
}

/// Builds a [Reel] while walking a [Take].
///
/// It owns **both clocks**. Reel time and source time diverge the moment a
/// title takes two seconds of reel and none of scenario, and an edit that adds
/// to a single cursor is an edit whose captions drift. Nothing here lets you
/// touch them separately.
class ReelBuilder {
  ReelBuilder(this.take);

  final Take take;

  /// Where we are in the output.
  Duration get reel => _reel;
  var _reel = Duration.zero;

  final _shots = <ReelShot>[];
  final _cues = <CueSpan>[];
  final _holds = <int, Duration>{};

  /// Shows [of] of scenario, live. Advances both clocks.
  void play(Duration of) => _add(of, frozen: false);

  /// Shows one beat, live — the ordinary step of a walk over `take.beats`.
  ///
  /// Remembers where the beat's take time landed in reel time, which is what
  /// [reelTimeOf] answers from: a cue said *inside* a beat is walked after
  /// it, and without this it would be placed where the walk has got to.
  void playBeat(Beat beat) {
    if (beat.duration <= Duration.zero) return;
    _played.add((take: beat.at, until: beat.end, reel: _reel));
    play(beat.duration);
  }

  final _played = <({Duration take, Duration until, Duration reel})>[];

  /// Where a moment of the take landed in the reel, or null if that stretch
  /// of the take has not been played — cut, or not walked yet.
  Duration? reelTimeOf(Duration takeTime) {
    for (var (:take, :until, :reel) in _played) {
      if (takeTime >= take && takeTime < until) {
        return reel + (takeTime - take);
      }
    }
    return null;
  }

  /// Holds the *viewer* while the app keeps running.
  ///
  /// Asks the filming run to pump [d] more of the app in the pause after
  /// [after], and shows it. A spinner keeps spinning, a video keeps playing —
  /// which a freeze cannot do and no recording contains.
  ///
  /// The pause is where it goes because that is where the film already has
  /// the run in its hands with no verb running. A beat with no pause of its
  /// own — one that never settled — cannot be held after.
  void hold(Duration d, {required Beat after}) {
    var phase = after.phase(PhaseKind.dwell) ?? after.phase(PhaseKind.open);
    if (phase == null || d <= Duration.zero) return;
    _holds[phase.index] = (_holds[phase.index] ?? Duration.zero) + d;
    _add(d, frozen: false);
  }

  /// Holds the *picture*. Advances reel time only; the app stands still.
  void freeze(Duration d) => _add(d, frozen: true);

  /// Says [cue] for [over] of reel time, starting now.
  ///
  /// Does not advance either clock — a cue is laid *over* what plays, and an
  /// edit that wanted it alone freezes first.
  void say(Object cue, {required Duration over, Duration? at}) =>
      _cues.add(CueSpan(at: at ?? _reel, duration: over, cue: cue));

  void _add(Duration d, {required bool frozen}) {
    if (d <= Duration.zero) return;
    // Contiguous by construction: a gap in the output is a black frame nobody
    // asked for, so shots are appended and never placed.
    _shots.add(ReelShot(at: _reel, duration: d, frozen: frozen));
    _reel += d;
  }

  /// The reel, drawn through [stage].
  ///
  /// The stage is named here rather than up front because an edit that
  /// builds a scene builds it *while* walking the take — a caption node per
  /// title, a push-in group per tap — and only has the finished thing to hand
  /// over at the end.
  Reel build({ReelStage stage = const BareStage()}) => Reel(
    shots: List.of(_shots),
    cues: List.of(_cues),
    holds: Map.of(_holds),
    stage: stage,
  );
}

/// An edit: a [Take] in, a [Reel] out.
///
/// Pure and synchronous. Everything it needs is already known, so there is
/// nothing to await and nothing to stream — which is what makes it testable as
/// data, with no app and no pixels anywhere near it.
abstract class ScenarioReelEdit {
  const ScenarioReelEdit();

  Reel edit(Take take);
}

/// The edit a run gets when nobody wrote one: the whole take, at its own pace,
/// with the scenario's own titles over it and a beat held at the end.
///
/// Conservative on purpose. A clever default that guesses wrong is worse than
/// a plain one, and everything characterful belongs in an edit somebody wrote.
class StockReel extends ScenarioReelEdit {
  const StockReel({
    this.titleFor = const Duration(milliseconds: 1800),
    this.tail = const Duration(milliseconds: 900),
  });

  /// How long a `s.title(...)` stays up.
  final Duration titleFor;

  /// The freeze at the end, so the clip does not cut on the last frame.
  final Duration tail;

  @override
  Reel edit(Take take) {
    var b = ReelBuilder(take);
    for (var beat in take.beats) {
      switch (beat) {
        case Said(:var cue):
          b.say(cue, over: titleFor, at: b.reelTimeOf(beat.at));
        case _:
          b.playBeat(beat);
      }
    }
    b.freeze(tail);
    return b.build();
  }
}
