import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../real_work/tracker.dart';
import 'motion.dart';
import 'target.dart';

/// The interval `pumpAndSettle` itself advances the clock by, kept the same so
/// a scenario's frames land where a hand-written test's would.
const _frameInterval = Duration(milliseconds: 100);

/// How a scenario verb waits for the app to be done before it captures.
///
/// Every verb — `pumpWidget`, `tap`, `enterText`, `screen` — applies the same
/// policy, because which verb settles and which does not is exactly the
/// knowledge the high-level API exists to remove. Set it per scenario
/// (`scenario('…', settle: …)`) and override it per call
/// (`s.tap(target, settle: Settle.none)`).
///
/// The default is [Settle.standard], and it is *bounded* on purpose:
/// `pumpAndSettle` never converges on a screen holding an indefinite animation
/// — a spinner, a shimmer, a looping Lottie — and throws
/// `pumpAndSettle timed out` when its ten fake minutes run out. A loading
/// spinner is the first thing most apps show, so the default must survive one:
/// it gives up quietly, captures the frame, and records `settled: false` on
/// the step. Use [Settle.full] where a screen that never settles should be an
/// error.
///
/// Frames are all a policy can follow, and a scenario needs one more thing.
/// Work that resolves on the *real* event loop — an asset read from the engine,
/// and the `vector_graphics`, Lottie or `ImageProvider` decode on the other end
/// of it — schedules no frame while it is in flight, so no policy here can wait
/// for it: `upTo` and `frames` see a quiet tree and `elapse` advances a clock
/// that real work does not read. Landing that work is a separate step a verb
/// takes after this one, deliberately not a policy: it is not a choice an
/// author makes, and a policy applied by hand through [apply] — as a plain
/// widget test does — should keep meaning exactly what it says. What a policy
/// does take is the [apply] hook that *waits* for such work between its own
/// frames, because a landing that only happens afterwards fills in the last
/// frame and leaves every earlier one with a hole in it.
///
/// This is also the one place a run records **motion**: a policy that owns its
/// pump loop hands every frame to the [ScenarioFrameSink] a run passes, and
/// pumps at that sink's finer interval while it does. One seam, and no verb
/// had to learn anything — a panel recording a transition and a film
/// recording a whole scenario arrive here as the same hook.
///
/// Under `ScenarioTime.real` every duration here is a **real** one:
/// `tester.pump(interval)` on the live binding waits the interval on the wall
/// clock and then a real frame, so `upTo(5s)` reads "until quiet, at most
/// five real seconds" and `elapse(2s)` costs two real seconds. Nothing in the
/// policies changes; only what a second is.
sealed class Settle {
  const Settle();

  /// The default: pump while the app keeps asking for frames, up to five
  /// seconds of the fake clock. Fifty frames at the ceiling, instant in wall
  /// time.
  static const standard = Settle.upTo(Duration(seconds: 5));

  /// [standard], and red where it would have shrugged: the same five seconds
  /// and the same landing of real work afterwards, but a screen still asking
  /// for frames when both are done **fails the step** instead of recording
  /// `settled: false` and moving on.
  ///
  /// The default's tolerance is for the loading spinner every app opens on;
  /// this is for the suite where a spinner in a picture is a bug. `settled:
  /// false` is a number in a report, and a scenario whose assertion finds the
  /// widget it wanted passes with a spinner in every frame for as long as
  /// nobody reads that number. The failure this throws captures the frame it
  /// gave up on, so the picture of the spinner is the first thing on the
  /// failed step.
  ///
  /// Not [full]: that is `pumpAndSettle`'s own loop, which throws before any
  /// real work has been given the chance to land and spends ten fake minutes
  /// deciding to. Set it per scenario (`scenario('…', settle: Settle.strict)`)
  /// or per folder (`runScenarios(testMain, settle: Settle.strict)`).
  static const strict = Settle.upTo(Duration(seconds: 5), strict: true);

  /// Pump while the app keeps asking for frames, stopping at the first frame
  /// it does not — or when [budget] of the fake clock is spent, whichever
  /// comes first. Running out is not a failure — it is recorded on the step —
  /// unless [strict], which makes it one after the step's real work has been
  /// landed. See [Settle.strict].
  ///
  /// The budget is a ceiling, not a wait. Frames are the only thing this
  /// loop follows, and work waiting on a timer schedules none: a screen whose
  /// `Future.delayed(Duration(seconds: 1))` has not completed looks exactly
  /// like a screen that is finished, so the loop returns at the first quiet
  /// frame — 100ms in — with the second still on the clock, and the tree is
  /// disposed under it. That is `pumpAndSettle`'s contract too, and a caller
  /// that means to wait for a timer has to say so: [Settle.elapse], or a
  /// [Settle.frames] count that covers it.
  const factory Settle.upTo(Duration budget, {bool strict}) = _Budgeted;

  /// Spend all of [budget] on the fake clock, whatever the frame loop is
  /// doing — the policy for work that waits on a timer rather than on frames.
  ///
  /// Where [Settle.upTo] asks the app whether to keep going, this one does not
  /// ask: it advances the clock, so a timer due inside [budget] fires and
  /// whatever it wakes gets its frames. Pumping past a quiet screen is close to
  /// free — a pump with nothing due builds nothing — so the cost is not the
  /// frames.
  ///
  /// The cost is that the clock really does move. A snackbar that
  /// auto-dismisses at four seconds is gone by the end of a five-second
  /// budget, and a screen captured after this policy is the screen as it stands
  /// at `budget`, not as it stood when it stopped changing. That is why it is
  /// not the default: reach for it where the question is *does this work at
  /// all* rather than *what does it look like now*.
  const factory Settle.elapse(Duration budget) = _Elapsed;

  /// Pump until [target] is on screen, then settle as [standard] does — for
  /// data that arrives without announcing itself.
  ///
  /// A step waits on what announces itself: frames, a tracked future, a live
  /// request until its headers are in. Two things a real app does every day
  /// announce nothing. A row that comes down a sync stream whose headers
  /// arrived long before, and a list that asks its local database for rows
  /// after the tap that opened it: the step settles on the empty state before
  /// either lands. This names what the step is waiting *for* instead:
  ///
  /// ```dart
  /// await s.tap('Orders', settle: Settle.until('Order #1042'));
  /// await s.act(
  ///   'An order placed on the other device reaches this one',
  ///   () => otherDevice.placeOrder('#1043'),
  ///   settle: Settle.until('Order #1043'),
  /// );
  /// ```
  ///
  /// [target] is anything a verb takes — visible text, a `Key`, a `Finder`, a
  /// `Target`. The wait needs nothing from the app, and it is on the lane's
  /// clock like every policy here: [timeout] of fake time under the fake
  /// clock, where it is how to wait out a timer without knowing how long it
  /// is, and of real time under `ScenarioTime.real`.
  ///
  /// Not seeing [target] within [timeout] **fails the step**, with the screen
  /// as it stood at the end of the wait as its picture. An empty list captured
  /// and passed is the failure this exists to prevent, so running out is never
  /// only a number on the step.
  const factory Settle.until(Object target, {Duration timeout}) = _Until;

  /// One frame, no clock advance — for a capture that must show the app
  /// mid-transition, or after work the scenario already pumped itself.
  static const none = _None();

  /// [count] frames of [interval] each, whatever is still scheduled at the
  /// end — how to capture a fixed way into an animation.
  const factory Settle.frames(int count, {Duration interval}) = _Frames;

  /// `pumpAndSettle`'s own semantics, ten-minute timeout and throw included.
  ///
  /// The one policy that records no motion: `pumpAndSettle` is the SDK's loop
  /// and offers no per-frame hook, and reimplementing it here to get one would
  /// be trading the exact semantics this policy exists to provide for a
  /// nicety.
  ///
  /// [apply] lands *around* the loop rather than inside it, which is the whole
  /// of what a hookless policy can do. Before is enough for anything that only
  /// needs to be told where to head: the software keyboard reads the app's
  /// focus there, points its ticker at the right height, and `pumpAndSettle`
  /// waits the slide out like any other animation. After is for what the loop
  /// itself changed — a settle that navigates away from a form takes the focus
  /// with it, and a policy that only sampled at the start would leave the
  /// keyboard staged at a height nothing on screen is asking for, for the next
  /// verb to discover.
  static const full = _Full();

  /// Whether the app going quiet is what stops this policy.
  ///
  /// True for [Settle.upTo] and [Settle.full], which pump *while* the app
  /// keeps asking for frames. False for the three that stop on a count or on
  /// the clock — [Settle.none], [Settle.frames] and [Settle.elapse]: they were
  /// never asked to wait, so a frame still scheduled when they return is the
  /// picture the author wanted rather than a budget that ran out.
  ///
  /// [apply]'s answer says what it says either way — whether a frame was
  /// scheduled — and this is what tells a run which of those answers is worth
  /// reporting. A step captured mid-flight on purpose and a settle that gave
  /// up are the same fact about frames and opposite facts about the scenario.
  bool get waits => true;

  /// Whether a step this policy leaves unsettled is a failed step — true
  /// for [Settle.strict] and any `upTo(…, strict: true)`.
  ///
  /// Read by the verb *after* the real work has landed, never by [apply]: the
  /// policy itself only ever reports, so a policy applied by hand keeps
  /// meaning what it says, and the landing gets its chance to finish what the
  /// frames were waiting on before anything is called red.
  bool get failsWhenUnsettled => false;

  /// Applies the policy. False when the app was still scheduling frames when
  /// the policy gave up — the step is captured either way.
  ///
  /// True says that and only that: no frame was scheduled. It is not a claim
  /// that the app has nothing left to do, because a pending timer is invisible
  /// from here — as it is to `pumpAndSettle`.
  ///
  /// [record], when a run is recording, receives the frame after every pump —
  /// and, where the policy chooses its own interval, dictates it.
  ///
  /// [land] is awaited *before* every pump, so whatever it lands is drawn by
  /// the frame that follows rather than by the frame after the loop. A scenario
  /// passes one; a policy applied by hand gets none and keeps meaning exactly
  /// what it says. See `landRealWork` for what it waits on and why the
  /// difference is visible: fake time runs a 700ms transition out in a few real
  /// milliseconds, so a decode that a device would have finished in the first
  /// frame otherwise lands after the last one — the still comes out right and
  /// every frame of the movie behind it is a hole.
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  });
}

class _Budgeted extends Settle {
  const _Budgeted(this.budget, {bool strict = false})
    : failsWhenUnsettled = strict;

  final Duration budget;

  @override
  final bool failsWhenUnsettled;

  @override
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  }) async {
    // Our own loop rather than `pumpAndSettle(timeout:)`: the SDK's version
    // *throws* when the budget runs out, and the whole point here is to carry
    // on and capture what the screen looks like.
    //
    // A recording subdivides the step — 30fps instead of 10 — and the budget
    // stays in fake *time*, so both cadences give up at the same instant and
    // land on the same settled frame. Measured byte-identical; that is what
    // lets a recorded run be diffed against one captured without recording.
    var interval = record?.interval ?? _frameInterval;
    var elapsed = Duration.zero;
    do {
      await land?.call();
      await tester.pump(interval);
      elapsed += interval;
      record?.capture(tester);
      await record?.flush(tester);
    } while (tester.binding.hasScheduledFrame && elapsed < budget);
    return !tester.binding.hasScheduledFrame;
  }
}

class _Elapsed extends Settle {
  const _Elapsed(this.budget);

  final Duration budget;

  @override
  bool get waits => false;

  @override
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  }) async {
    // [_Budgeted]'s loop kept in the same shape on purpose — same interval,
    // same recorder cadence, same one guaranteed pump — so the only thing that
    // differs between the two policies is when they are allowed to stop.
    var interval = record?.interval ?? _frameInterval;
    var elapsed = Duration.zero;
    do {
      await land?.call();
      await tester.pump(interval);
      elapsed += interval;
      record?.capture(tester);
      await record?.flush(tester);
    } while (elapsed < budget);
    return !tester.binding.hasScheduledFrame;
  }
}

class _Until extends Settle {
  const _Until(this.target, {this.timeout = const Duration(seconds: 10)});

  final Object target;
  final Duration timeout;

  @override
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  }) async {
    var finder = finderForTarget(target);
    // [_Budgeted]'s loop with a different question at the bottom: whether the
    // target is there yet, rather than whether the app asked for a frame. A
    // quiet tree is exactly what a screen waiting on a stream looks like.
    var interval = record?.interval ?? _frameInterval;
    var elapsed = Duration.zero;
    while (finder.evaluate().isEmpty) {
      if (elapsed >= timeout) {
        throw ScenarioNeverAppeared(
          '${describeTarget(target)} did not appear within '
          '${_readable(timeout)} of '
          '${tester.binding is LiveTestWidgetsFlutterBinding ? 'real' : 'fake'}'
          ' time. The picture on this step is the screen when the wait gave '
          'up. If it is on its way and slower than that, give it longer: '
          '`Settle.until(…, timeout: …)`.',
        );
      }
      await land?.call();
      await tester.pump(interval);
      elapsed += interval;
      record?.capture(tester);
      await record?.flush(tester);
    }
    // Arrived, and possibly still arriving: a row that animates into its
    // list is found on its first frame, and the picture wants its last.
    return Settle.standard.apply(tester, record: record, land: land);
  }
}

class _None extends Settle {
  const _None();

  @override
  bool get waits => false;

  @override
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  }) async {
    await land?.call();
    await tester.pump();
    record?.capture(tester);
    await record?.flush(tester);
    return !tester.binding.hasScheduledFrame;
  }
}

class _Frames extends Settle {
  const _Frames(this.count, {this.interval = _frameInterval});

  final int count;
  final Duration interval;

  @override
  bool get waits => false;

  @override
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  }) async {
    // [interval] is the author's, not the recorder's: `Settle.frames(3)` says
    // where in the animation to land, and a recording may not move it.
    for (var i = 0; i < count; i++) {
      await land?.call();
      await tester.pump(interval);
      record?.capture(tester);
      await record?.flush(tester);
    }
    return !tester.binding.hasScheduledFrame;
  }
}

class _Full extends Settle {
  const _Full();

  @override
  Future<bool> apply(
    WidgetTester tester, {
    ScenarioFrameSink? record,
    Future<void> Function()? land,
  }) async {
    // Around the loop, because `pumpAndSettle` owns its own and there is
    // nowhere inside it to stand. Before points whatever needs pointing — see
    // [Settle.full].
    await land?.call();
    await tester.pumpAndSettle();
    // And again after, because the loop is where the app moves. A settle that
    // leaves a form behind takes the focus with it, and this is the first
    // moment anything can notice: sampling here aims the keyboard down, and
    // the second settle is what runs the slide out.
    //
    // Two rounds and not a fixpoint. What [land] starts is one 250ms
    // animation, so a second round finishes what the first found — and a tree
    // that keeps changing focus under a settle is a tree still moving, which
    // is the next verb's business rather than something to spin here over.
    await land?.call();
    if (tester.binding.hasScheduledFrame) await tester.pumpAndSettle();
    return true;
  }
}

/// What a [Settle.strict] step throws when the screen is still asking for
/// frames after the budget and the landing of real work — the failure that
/// replaces `settled: false` in the report.
///
/// Thrown by the verb, after `landRealWork`, and caught by the same path every
/// other failure takes: the step is captured with this as its failure, so the
/// picture of whatever kept animating is on the failed step.
class ScenarioStillAnimating implements Exception {
  ScenarioStillAnimating(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a [Settle.until] step throws when its target is not on screen by the
/// end of the wait. Caught like every other failure, so the step's picture is
/// the screen that was still missing it.
class ScenarioNeverAppeared implements Exception {
  ScenarioNeverAppeared(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The sentence a strict step fails with, built where the facts are: which
/// verb, what policy, and whatever announced work is still to land — which is
/// the difference between "a spinner" and "a load the step did not wait for".
ScenarioStillAnimating stillAnimating(
  Settle policy, {
  String? verb,
  String? target,
  List<String> ticking = const [],
  bool ambient = false,
}) {
  var did = [?verb, ?target].join(' ').trim();
  var budget = switch (policy) {
    _Budgeted(:var budget) => ' after ${_readable(budget)} of fake time',
    _ => '',
  };
  var pendingImages = PaintingBinding.instance.imageCache.pendingImageCount;
  var tracked = RealWork.pendingWork;
  var still = [
    if (pendingImages > 0)
      '$pendingImages image decode${pendingImages == 1 ? '' : 's'} pending',
    if (tracked.isNotEmpty)
      'tracked real work pending: ${tracked.map((w) => '`$w`').join(', ')}',
  ];
  if (ambient) {
    return ScenarioStillAnimating(
      '${did.isEmpty ? 'the step' : '`$did`'} left an `Ambient` on screen. '
      'Under a scenario its motion is frozen, so the screen settled — but '
      '`Settle.strict` is about the loader being there, not about the frames '
      'it costs, and a picture with a spinner in it fails here frozen or not. '
      'If the loader is the point of this picture, say so on the verb: '
      '`settle: Settle.standard`.',
    );
  }
  return ScenarioStillAnimating(
    '${did.isEmpty ? 'the step' : '`$did`'} left the screen still '
    "animating: a frame was still scheduled$budget and after the step's "
    'real work had landed. `Settle.strict` makes that a failure where '
    '`Settle.standard` records `settled: false` and moves on. '
    '${still.isEmpty ? 'Nothing announced is still in flight, so what keeps asking for frames is on the captured step — a spinner, a looping animation, a caret in a focused field on an iOS device.' : 'Still in flight: ${still.join('; ')}.'} '
    '${ticking.isEmpty ? '' : 'Still ticking: ${ticking.join(', ')}. '}'
    'If the animation is the point of this picture, say so on the verb: '
    '`settle: Settle.standard`, or `Settle.frames(n)` for a fixed way in.',
  );
}

String _readable(Duration budget) => budget.inSeconds > 0
    ? '${budget.inSeconds}s'
    : '${budget.inMilliseconds}ms';
