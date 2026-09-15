import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../real_work/tracker.dart';
import 'asset_bundle.dart';
import 'motion.dart';
import 'progress.dart';
import 'settle.dart';

/// How many turns of the real event loop a caller spends **guessing** — see
/// [landRealWork].
///
/// Every turn nothing needs is paid for in full, because "nothing has landed
/// yet" and "nothing is coming" are the same observation. That is what sets the
/// number, and it was measured rather than picked: on the example scenario
/// suite a turn costs ~56µs, so the 41 of 48 steps with nothing pending paid
/// **678µs** each — against the ~48ms their capture costs — and the whole suite
/// paid **57ms of 2.29s**, 2.5%.
///
/// The other seven steps are what the ceiling is for. The deepest of them
/// needed **seven** turns before its frame appeared — an engine asset read is
/// the slow link, and `vector_graphics` then decodes, lays out and paints on
/// top of it. Twelve is that measured seven with room, and it is spent again
/// from zero every time a turn actually produces a frame, because a decode
/// arrives in links and a chain three links long is not three times the guess.
///
/// The one caller that cannot reset it is the unsettled branch of
/// [landRealWork], where a scheduled frame says nothing — there twelve bounds
/// the whole chain instead of each link.
const realWorkTurns = 12;

/// How long a caller waits for work it has been **told** is in flight.
///
/// Only ever reached by work that never completes at all — a read against an
/// endpoint nothing answers. A decode that finishes takes as long as it takes
/// and is waited for exactly that long, so this is a deadlock ceiling rather
/// than a budget, and hitting it is reported on the step rather than swallowed.
const realWorkWait = Duration(seconds: 1);

/// How often a wait looks again. Real milliseconds, because the thing being
/// waited for is a decode on an engine thread and the only thing that advances
/// it is the wall clock.
///
/// A polling interval, not the unit [realWorkWait] is spent in: a turn of the
/// real loop under `runAsync` costs a good deal more than the millisecond it
/// asks to sleep — measured at ~2.4ms — so counting turns charged 1ms for
/// something like 2.4, and a one-second ceiling took two and a half seconds to
/// reach. [RealWorkBudget] reads a stopwatch instead.
const _waitingTurn = Duration(milliseconds: 1);

/// Lets work that resolves on the **real** event loop land, and be drawn,
/// before a tree under fake time is judged or photographed.
///
/// A [Settle] policy follows frames, and that is all any of them can do —
/// `upTo` stops at the first frame the app does not ask for, `frames` counts
/// them, `elapse` advances a clock that real work does not read. So a decode
/// running on the real event loop is invisible to every one of them: it
/// schedules no frame while it is in flight, the tree looks finished, and
/// whatever reads it next reads a frame the tree is about to replace.
/// `vector_graphics` is how this was found — a scenario's artwork appeared one
/// step late in every flow that photographs each screen as it arrives — but
/// nothing about it is specific to SVG. Lottie, a PDF or thumbnail renderer, an
/// `ImageProvider` decoding off the fake clock and a `FutureBuilder` on a real
/// future are the same shape.
///
/// Some of that work announces itself, and the announced half is not
/// guesswork. Three counters say work is in flight without anyone taking a
/// turn to find out: `ImageCache.pendingImageCount`, which every
/// `ImageProvider` passes through — `Image.asset`, `Image.memory`,
/// `Image.network`, an `AssetImage` — [ScenarioAssetBundle.readsInFlight],
/// which is every asset the app reads through the scenario's own bundle, so
/// `SvgPicture.asset` and `Lottie.asset` are in it too — and [RealWork.pending],
/// which is whatever the app itself handed to `RealWork.track`: a model
/// import, an isolate, a database open. While any is non-zero this **waits**,
/// in real milliseconds, until it is not. That is the deterministic half: the
/// wait ends when the work ends, on a fast machine and a slow one alike, and a
/// 780×609 PNG does not need a bigger number than an 8×8 one — it needs the
/// same condition, held for longer. The first two are bounded by
/// [realWorkWait]; a tracked future is the app's own promise and is waited
/// for as long as it takes, up to the scenario's deadline.
///
/// What is left over is guessed at, and a turn is the only detector there
/// is. A `FutureBuilder` on a real future announces nothing, so this takes a
/// turn of the real loop and reads what it did: a frame scheduled on a tree
/// that was quiet before it can only have been scheduled by work that just
/// landed. Then it draws that frame with the caller's own policy and looks
/// again — and gives the next link a full [realWorkTurns] again, because a
/// decode arrives in links: a read completes, the app builds, the build starts
/// the next read. `tester.runAsync` flushes the fake microtask queue as it
/// closes, which is why the continuation has run by the time
/// `hasScheduledFrame` is read here and has *not* run when it is read from
/// inside the turn.
///
/// Returns what the step should say about itself: `settled` as the caller's
/// policy left it, and `landed` — false only when [realWorkWait] ran out with a
/// counter still saying work was in flight. There is no such flag for the
/// guessed half, and there cannot be: not knowing whether anything is coming is
/// the whole reason those turns are spent.
///
/// What none of it buys is work that needs real *time* — an http call, a
/// `Future.delayed` on the real clock — which no counter names and which
/// `s.runAsync` is the verb for.
///
/// A tree that never stops asking for frames takes the same turns, spent
/// flat. The loop below reads "a frame was scheduled" as progress and hands
/// the next link a full budget again — which is sound only while a quiet tree
/// is the baseline. On a screen holding an indefinite animation a frame is
/// always scheduled, whatever landed or did not, so that reading is worth
/// nothing there and the reset it drives would never end. Such a step gets
/// [realWorkTurns] turns with no reset instead, each drawn by a bare
/// `tester.pump()` rather than by the policy: re-applying it would spend fake
/// time the caller's policy declined to spend, and one pump at the same
/// instant draws what landed without moving the clock.
///
/// It is the weaker half of the two on purpose — flat turns bound the whole
/// chain rather than each link, so the depth it carries is [realWorkTurns]
/// links and not [realWorkTurns] per link (measured: twelve land, thirteen do
/// not, against the seven the deepest real decode needed). What it buys is
/// that a spinner, a ripple or any other indefinite animation no longer costs
/// a step its artwork — before this, *every* step reporting `settled: false`
/// skipped the landing altogether, the announced half included, and said
/// `landed: true` while doing it.
Future<({bool settled, bool landed})> landRealWork(
  WidgetTester tester,
  Settle policy, {
  required bool settled,
  required RealWorkBudget budget,
  ScenarioAssetBundle? assets,
  ScenarioFrameSink? record,
  void Function()? beforePump,
}) async {
  if (!settled) {
    for (var i = 0; i < realWorkTurns; i++) {
      if (_announced(assets)) {
        if (!await budget.land(tester, assets)) {
          return (settled: false, landed: false);
        }
      } else {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      beforePump?.call();
      await tester.pump();
    }
    // One frame to the recording rather than one per turn: these pumps all
    // draw the same fake instant, so a dozen of them play back as a stall —
    // but without the last of them the movie ends on a frame the still does
    // not match, which is the hole this whole file exists to close.
    record?.capture(tester);
    await record?.flush(tester);
    // Read again rather than repeated: the turns above may have drawn the
    // frame the policy was waiting on — a spinner whose future landed — and
    // a strict policy would otherwise fail a screen that is now quiet.
    return (settled: !tester.binding.hasScheduledFrame, landed: true);
  }
  var guesses = 0;
  while (true) {
    if (_announced(assets)) {
      if (!await budget.land(tester, assets)) {
        return (settled: true, landed: false);
      }
    } else {
      if (guesses >= realWorkTurns) return (settled: true, landed: true);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      guesses++;
    }
    // A frame the landing drew itself counts too: it is the same progress,
    // and the policy below is where the recorder sees it.
    if (!tester.binding.hasScheduledFrame && !budget.takeDrewFrame()) continue;
    // A frame is progress, so the next link starts from a full budget rather
    // than from whatever this one had left.
    guesses = 0;
    // Kept rather than dropped: when the policy does not settle, its landings
    // are the only ones this link gets. A load started by the frame the loop
    // just drew — a read that landed, a build that began an import — behind a
    // spinner is exactly that, and the allowance running out on it is the one
    // fact the step has to report.
    var landed = true;
    settled = await policy.apply(
      tester,
      record: record,
      land: () async {
        beforePump?.call();
        landed = await budget.land(tester, assets);
      },
    );
    if (!settled) return (settled: false, landed: landed);
  }
}

/// One step's allowance of real clock for work that announced itself, spent by
/// the settle loop and by the landing after it out of the same purse.
///
/// It has to be one purse, and one per step. Per *call* and a step with a
/// pending decode could pay [realWorkWait] once inside its policy and again
/// after it; per *run* and one wedged read would spend the ceiling on the step
/// that started it and leave nothing for the rest of the scenario.
class RealWorkBudget {
  /// [trackedWait] is how long tracked work — what the app handed to
  /// `RealWork.track` — may be waited for, out of a purse of its own; null
  /// is as long as it takes. A scenario passes null: a tracked future is the
  /// app's own promise, and a broken one runs into the scenario's deadline,
  /// whose message names it — a better answer than `landed: false` in a
  /// report nobody reads. A lane with no deadline above it passes a ceiling
  /// instead, and has to say on its own output what was still pending when
  /// the ceiling was reached — the previews harness does both, see
  /// `auditTrackedWait`. Ten minutes per entry is not an answer, and neither
  /// is a picture of a spinner that nobody is told about.
  RealWorkBudget({this.trackedWait = realWorkWait});

  final Duration? trackedWait;

  /// Running only across the awaits below, so what it holds is time this step
  /// spent *waiting* and nothing else — a step whose settle takes a second
  /// between two landings has spent none of its allowance.
  final _spent = Stopwatch();

  /// Its own purse, so a two-second model import does not spend the second
  /// the image decodes it kicks off afterwards were going to need.
  final _trackedSpent = Stopwatch();

  var _drewFrame = false;

  /// Whether [land] drew a frame since this was last asked — the frame a
  /// tracked continuation scheduled, pumped so the next link could start.
  /// `landRealWork` reads it as the progress it is: with nothing scheduled
  /// afterwards it would otherwise look like a quiet tree, and the policy
  /// that records the loaded frame would never be re-applied.
  bool takeDrewFrame() {
    var drew = _drewFrame;
    _drewFrame = false;
    return drew;
  }

  /// Waits, on the real clock, while anything announced is still in flight.
  ///
  /// Returns false only when the allowance ran out with something still
  /// pending — which is what puts `landed: false` on the step. Returns
  /// immediately, and free, when nothing is in flight: three integer reads
  /// is the whole cost on the path almost every frame of almost every step
  /// takes.
  ///
  /// [untracked] false waits for tracked work alone, and leaves image decodes
  /// and asset reads to a later landing. That is for landing between the
  /// frames of a policy that is about to move a fake clock. The image cache
  /// counts a decode from the moment its provider starts, and a provider that
  /// sleeps on that clock before it decodes cannot finish while a real wait
  /// holds the clock still: the wait spends the whole allowance on a timer only
  /// the next pump can fire, and nothing is left for the decode once it has.
  /// Tracked work is the app's word that it runs on the real loop, so it is
  /// worth waiting for wherever it is.
  Future<bool> land(
    WidgetTester tester,
    ScenarioAssetBundle? assets, {
    bool untracked = true,
  }) async {
    while (untracked ? _announced(assets) : RealWork.pending > 0) {
      if (RealWork.pending > 0) {
        if (trackedWait case var ceiling?
            when _trackedSpent.elapsed >= ceiling) {
          return false;
        }
        _trackedSpent.start();
        scenarioLandingTrackedWork = true;
        try {
          await tester.runAsync(() => Future<void>.delayed(_waitingTurn));
        } finally {
          scenarioLandingTrackedWork = false;
          _trackedSpent.stop();
        }
        // A tracked load usually arrives in links — a read completes, the
        // continuation runs `setState` or awaits a frame, and the next read
        // starts after it — and only a pump draws the frame between them.
        // Only when one is asked for: `runAsync` has already flushed the
        // microtasks, and a pump with nothing scheduled adds nothing.
        if (tester.binding.hasScheduledFrame) {
          _drewFrame = true;
          await tester.pump();
        }
        continue;
      }
      if (_spent.elapsed >= realWorkWait) return false;
      _spent.start();
      try {
        await tester.runAsync(() => Future<void>.delayed(_waitingTurn));
      } finally {
        _spent.stop();
      }
    }
    return true;
  }
}

/// Work the framework, the scenario's own bundle or the app itself has
/// already said is in flight — the half of real-loop work that does not have
/// to be guessed at.
bool _announced(ScenarioAssetBundle? assets) =>
    PaintingBinding.instance.imageCache.pendingImageCount > 0 ||
    (assets?.readsInFlight ?? 0) > 0 ||
    RealWork.pending > 0;

/// What [_announced] is counting right now, in the shape a report carries:
/// the label of every tracked future, and the image decodes and asset reads
/// when there are any. Empty when nothing is in flight.
Map<String, Object?> pendingRealWork(ScenarioAssetBundle? assets) {
  var images = PaintingBinding.instance.imageCache.pendingImageCount;
  var reads = assets?.readsInFlight ?? 0;
  return {
    if (RealWork.pending > 0)
      'tracked': [for (var work in RealWork.pendingWork) '$work'],
    if (images > 0) 'images': images,
    if (reads > 0) 'assets': reads,
  };
}

/// Drops what a previous test body left the image cache holding, so the next
/// one starts with [_announced] describing **it**.
///
/// `testWidgets` resets a great deal between bodies and the image cache is not
/// in it — it is `PaintingBinding`'s, process-wide, and nothing in
/// `flutter_test` touches it. A body that ends with a decode still in flight
/// therefore hands `pendingImageCount > 0` to every body after it, for the
/// life of the process, and each of them then waits out the whole of
/// [realWorkWait] on work that is not theirs and will never land. It is not a
/// rare shape: `MemoryImage` does not evict its key when a decode *fails*, the
/// way `NetworkImage`, `FileImage` and `ResizeImage` all do, so one preview of
/// an unreadable image is enough. Measured on this repo's own catalog — a
/// single such entry at position 6 took each of the 117 entries after it from
/// ~50ms to a flat ~2.4s, and the catalog from seconds to **287**.
///
/// Called at the top of a body rather than the bottom, so a run also survives
/// whatever ran before the first one — which is the same reason
/// `rootBundle.clear()` sits where it does, and the counters are the same kind
/// of leak.
///
/// Only the framework's half needs this. [ScenarioAssetBundle.readsInFlight]
/// is counted on a bundle each body makes for itself, so it starts at zero by
/// construction.
///
/// Unconditional rather than only when something is pending, so what a body
/// decodes it decodes itself. The cost is re-decoding an asset two entries
/// share — invisible against the measurement above — and in return the
/// comparison gets the property it relies on: a body's picture depends on the
/// body, not on what happened to run before it.
void resetAnnouncedWork() {
  var cache = PaintingBinding.instance.imageCache;
  cache.clear();
  // `clear` leaves the live set alone, and a live entry is a handle on the
  // previous body's decoded pixels — held by a tree that no longer exists.
  cache.clearLiveImages();
  // The app's own announcements are the same kind of leak: a load the
  // previous body started and never finished would otherwise be waited on
  // by this one, up to its deadline.
  resetTrackedRealWork();
}
