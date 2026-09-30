import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scenarios/settle.dart';
import 'live_settle.dart';

/// Where the drive verbs run: what a frame, a wait and a settle are.
///
/// A scenario is a script and a lane is where it runs; the verbs are the same
/// idea. Everything a verb *does* goes through a [WidgetController], which a
/// running app and a widget test both have. What differs is time — a live
/// app's clock is real and its frames come from the engine, a tester's clock
/// is fake and a frame is a pump — and the one platform message whose reply a
/// fake clock never delivers. Those are all that is here.
abstract interface class DriveLane {
  WidgetController get controller;

  /// One frame, so a change is laid out before it is read.
  Future<void> pump();

  /// [duration] of this lane's clock, passing.
  Future<void> elapse(Duration duration);

  /// Frames until nothing is pending, or until [budget] of this lane's clock
  /// is spent. Running out is reported, never thrown.
  Future<LiveSettleResult> settle(Duration budget);

  /// Keeps a hovering pointer where it is for up to [budget], so what an app
  /// only shows to a mouse — a tooltip's timer — has fired.
  Future<void> hold(Duration budget);

  /// Whether a refused target is worth retrying on this lane.
  ///
  /// A live screen is mid-flight — a route transition holds an `IgnorePointer`
  /// up for a few hundred milliseconds — so a refusal there may be gone a
  /// frame later. A tester's screen has been settled on a clock nothing else
  /// moves, and waiting changes nothing: its refusal is final, which is what a
  /// scenario has always said.
  bool get retries;

  /// The platform's back gesture, as the engine delivers it.
  Future<void> popRoute();
}

/// A running app: real time, the engine's frames, a window that may be
/// hidden.
class LiveLane implements DriveLane {
  LiveLane(WidgetsBinding binding) : controller = _LiveController(binding);

  @override
  final LiveWidgetController controller;

  @override
  Future<void> pump() => controller.pump();

  @override
  Future<void> elapse(Duration duration) => Future<void>.delayed(duration);

  @override
  Future<LiveSettleResult> settle(Duration budget) =>
      settleLive(budget: budget);

  /// Waits out a hover's *delayed* reaction, in real time.
  ///
  /// Two phases, and the order is the whole trick. The immediate reaction — a
  /// tint, an elevation, a cursor — schedules a frame the moment the event
  /// lands, so a plain "stop as soon as the app reacts" poll would stop on
  /// that and never see the thing hovering is usually asked about. The settle
  /// absorbs the immediate reaction first; only after it is a newly scheduled
  /// frame or a newly running ticker evidence of the *second*, delayed one.
  ///
  /// Missing that evidence costs latency and never correctness: on a visible
  /// window a frame can be scheduled and run inside one 16ms beat, and then
  /// this simply holds the full budget — and the caller's settle, which runs
  /// after every hold, sees the finished screen either way.
  ///
  /// [budget] covers both phases, which is why the clock starts before the
  /// settle. The two used to have a budget each, and a hover that landed
  /// mid-route-transition paid twice: the settle spent the whole 600ms on the
  /// transition, the poll then found the app quiet and spent 600ms more. What
  /// the caller asked for is how long the pointer is held there, and the
  /// settle happens while it is held. Nothing is lost by counting it — a
  /// delayed reaction's own timer starts when the hover lands, not when the
  /// immediate one finishes, so it is still inside this window.
  @override
  Future<void> hold(Duration budget) async {
    if (budget <= Duration.zero) return;
    var watch = Stopwatch()..start();
    await settleLive(budget: budget);
    var binding = controller.binding;
    while (watch.elapsed < budget) {
      if (binding.hasScheduledFrame || binding.transientCallbackCount > 0) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  @override
  bool get retries => true;

  @override
  Future<void> popRoute() {
    var completer = Completer<void>();
    ui.channelBuffers.push(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) => completer.complete(),
    );
    return completer.future;
  }
}

/// `LiveWidgetController` with a pump that survives a hidden window: frames
/// are forced when the platform has disabled them, and every wait is capped
/// so nothing here can hang the verb that pumps.
class _LiveController extends LiveWidgetController {
  _LiveController(super.binding);

  @override
  Future<void> pump([Duration? duration]) async {
    if (duration != null) {
      await Future<void>.delayed(duration);
    }
    binding.scheduleFrame();
    if (!binding.framesEnabled) binding.scheduleForcedFrame();
    await Future.any([
      binding.endOfFrame,
      Future<void>.delayed(const Duration(milliseconds: 250)),
    ]);
  }
}

/// A widget test: a fake clock that moves only when pumped.
///
/// Every wait is exact here, which a live app cannot offer. A hover held for
/// 600ms fires a tooltip whose `waitDuration` is 500ms every time, rather
/// than whenever the machine got round to it, so a picture of it is the same
/// picture on every run.
class TesterLane implements DriveLane {
  /// [settle] is how the host settles, given a budget — the preview harness
  /// lands the real work its entries hand off as it goes. Omitted, a plain
  /// [Settle.upTo].
  TesterLane(this.controller, {Future<bool> Function(Duration budget)? settle})
    : _settle = settle ?? ((budget) => Settle.upTo(budget).apply(controller));

  @override
  final WidgetTester controller;

  final Future<bool> Function(Duration budget) _settle;

  @override
  Future<void> pump() => controller.pump();

  @override
  Future<void> elapse(Duration duration) => controller.pump(duration);

  @override
  Future<LiveSettleResult> settle(Duration budget) async {
    var clock = controller.binding.clock;
    var started = clock.now();
    // Counted by the frames themselves rather than by the policy, which only
    // answers whether it settled: a post-frame callback that re-arms itself
    // for as long as the settle runs.
    var frames = 0;
    var counting = true;
    void count(Duration _) {
      if (!counting) return;
      frames++;
      SchedulerBinding.instance.addPostFrameCallback(count);
    }

    SchedulerBinding.instance.addPostFrameCallback(count);
    bool settled;
    try {
      settled = await _settle(budget);
    } finally {
      counting = false;
    }
    return LiveSettleResult(
      settled: settled,
      frames: frames,
      forcedFrames: 0,
      framesEnabled: true,
      elapsed: clock.now().difference(started),
    );
  }

  /// All of it, in one pump: the timers due inside it fire in order, and the
  /// settle that follows every verb draws what they started.
  @override
  Future<void> hold(Duration budget) async {
    if (budget > Duration.zero) await controller.pump(budget);
  }

  @override
  bool get retries => false;

  /// Handed to the messenger rather than pushed on the channel buffers, whose
  /// reply comes back through a zone a fake clock never runs.
  @override
  Future<void> popRoute() async {
    await controller.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
  }
}
