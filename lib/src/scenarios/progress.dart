/// Whether a running scenario is still getting somewhere, and the deadline
/// that reads it.
///
/// A scenario's `timeout:` used to be a wall-clock budget for everything the
/// harness did on its behalf — setUp, every replay of every `split` path,
/// every capture, every wait on tracked real work, tearDown — in one
/// `Future.timeout`. That measures the host. A five-path split that imports a
/// model on each path passed in five seconds on a quiet machine and failed on
/// a CI runner shared by three jobs, and the failure read as the scenario's.
///
/// So the timeout is **how long a scenario may go without progress**, which is
/// what an author means when they write one. See
/// `docs/superpowers/specs/2026-09-15-comparison-determinism-design.md` § 3.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart' show Timeout;
import 'package:meta/meta.dart';

import '../real_work/tracker.dart';

/// Bumped whenever the body gets somewhere: a verb returned, a step was
/// recorded. Read by [ProgressDeadline], which only asks whether it moved.
var scenarioProgressMarks = 0;

/// Says the running scenario got somewhere.
void markScenarioProgress() => scenarioProgressMarks++;

/// The `timeout:` the running scenario declared, set as its body starts.
///
/// Beside the test rather than on it. Under the harness `testWidgets` is given
/// `Timeout.none`, because `test_api` arms a timer of its own from the test's
/// metadata, and that timer — knowing nothing about progress — would fail a
/// slow scenario first, with no diagnosis and without abandoning it. Null
/// until a body has started; the harness clears it before each scenario.
Timeout? scenarioDeclaredTimeout;

/// Whether the body is inside a landing, waiting for tracked real work — which
/// is what a deadline over pending work has to know before it can say whether
/// the scenario was waiting for that work or stuck on something else beside it.
var scenarioLandingTrackedWork = false;

/// How long one tracked future may stay pending before a scenario fails on it.
///
/// Tracked work is waited for as long as it takes — a 6 MB model import on a
/// software rasterizer on a shared runner is slow, not wrong — so it counts as
/// progress while it is pending. This is where that stops: work pending this
/// long is not coming, and the usual reason is a future a dependency memoized
/// in an earlier scenario's zone.
const trackedWorkCeiling = Duration(minutes: 2);

/// Why a [ProgressDeadline] gave up.
enum ScenarioStallKind {
  /// No progress for the declared timeout, on an idle isolate.
  stalled,

  /// A tracked future stayed pending past [trackedWorkCeiling].
  trackedWork,

  /// Still going at the hard ceiling, however much progress it was making.
  ceiling,
}

/// What a [ProgressDeadline] throws when a scenario stops getting anywhere.
class ScenarioStall implements Exception {
  ScenarioStall(
    this.kind, {
    required this.timeout,
    required this.idle,
    required this.elapsed,
    this.work,
  });

  final ScenarioStallKind kind;

  /// The declared timeout — how long it may go without progress.
  final Duration timeout;

  /// How long it had gone without progress.
  final Duration idle;

  /// How long it had been running.
  final Duration elapsed;

  /// The tracked future that ran past its ceiling, for
  /// [ScenarioStallKind.trackedWork].
  final TrackedRealWork? work;

  @override
  String toString() => 'ScenarioStall(${kind.name}, idle $idle)';
}

/// Watches a running scenario and fails when it stops getting anywhere.
///
/// Progress is any of:
///
/// - [scenarioProgressMarks] moving — a verb returned, a step was recorded;
/// - a tracked future completing, or one still pending under its ceiling;
/// - **the isolate being busy.** The check is a periodic timer on the same
///   isolate as the body, and a check a second or more late fired late because
///   the isolate was working — a mount, a pump, a capture's encode. Lateness
///   shorter than that is a loaded machine's scheduling as often as it is
///   work, so it is taken off the idle time instead of resetting it. A stall
///   is an *idle* isolate, waiting on something that never comes.
///
/// Frames are not progress: a spinner schedules them forever.
///
/// A hard ceiling of ten times the timeout, and never less than twice
/// [trackedWorkCeiling], stops a body that makes progress forever.
class ProgressDeadline {
  ProgressDeadline({
    required this.timeout,
    this.tick = const Duration(milliseconds: 250),
    this.trackedCeiling = trackedWorkCeiling,
    Duration Function()? now,
    List<TrackedRealWork> Function()? pendingWork,
    int Function()? marks,
    @visibleForTesting bool ticking = true,
  }) : _now = now ?? _stopwatch().call,
       _pendingWork = pendingWork ?? (() => RealWork.pendingWork),
       _marks = marks ?? (() => scenarioProgressMarks) {
    _lastTick = _now();
    _lastProgress = _lastTick;
    _started = _lastTick;
    _lastMarks = _marks();
    _timer = ticking ? Timer.periodic(tick, (_) => check()) : null;
  }

  /// The timeout in force, read on every check: a scenario's body declares
  /// its own only once it starts. Null is no deadline at all.
  final Duration? Function() timeout;

  final Duration tick;
  final Duration trackedCeiling;

  final Duration Function() _now;
  final List<TrackedRealWork> Function() _pendingWork;
  final int Function() _marks;

  late final Timer? _timer;
  late Duration _started;
  late Duration _lastTick;
  late Duration _lastProgress;
  late int _lastMarks;
  final _seen = <TrackedRealWork, Duration>{};
  final _stalled = Completer<Never>();

  /// Completes with a [ScenarioStall] when the scenario stops getting
  /// anywhere, and never otherwise.
  Future<Never> get stalled => _stalled.future;

  /// Stops watching. Idempotent.
  void cancel() => _timer?.cancel();

  /// How late a check has to come to count as the isolate having worked.
  static const _busy = Duration(seconds: 1);

  static Duration Function() _stopwatch() {
    var watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// One look at the scenario. The timer calls this every [tick]; a test
  /// that made this with `ticking: false` calls it itself.
  @visibleForTesting
  void check() {
    var now = _now();
    // A check that came late came late because the isolate was working — or
    // because a loaded machine scheduled it late, which is not work at all.
    // A second or more is work: a mount, a pump, an encode. Anything shorter
    // is only taken off the idle time rather than resetting it, so a waiting
    // isolate on a starved host still reaches its deadline, a little later,
    // instead of being called busy on every tick until the hard ceiling.
    var late = now - _lastTick - tick;
    if (late >= _busy) {
      _lastProgress = now;
    } else if (late > Duration.zero) {
      _lastProgress += late;
    }
    _lastTick = now;

    var marks = _marks();
    if (marks != _lastMarks) {
      _lastMarks = marks;
      _lastProgress = now;
    }

    var pending = _pendingWork();
    var completed = _seen.keys.any((work) => !pending.contains(work));
    _seen.removeWhere((work, _) => !pending.contains(work));
    for (var work in pending) {
      // When it was announced, where the tracker knows; otherwise the first
      // check that saw it, which is at most a tick late.
      _seen.putIfAbsent(work, () => now - (work.pendingFor ?? Duration.zero));
    }
    if (completed) _lastProgress = now;

    var limit = timeout();
    for (var MapEntry(key: work, value: since) in _seen.entries) {
      if (now - since >= trackedCeiling) {
        return _fail(ScenarioStallKind.trackedWork, now, limit, work: work);
      }
    }
    if (pending.isNotEmpty) _lastProgress = now;

    if (limit == null) return;
    if (now - _lastProgress >= limit) {
      return _fail(ScenarioStallKind.stalled, now, limit);
    }
    var ceiling = Duration(
      microseconds: max(
        limit.inMicroseconds * 10,
        trackedCeiling.inMicroseconds * 2,
      ),
    );
    if (now - _started >= ceiling) {
      return _fail(ScenarioStallKind.ceiling, now, limit);
    }
  }

  void _fail(
    ScenarioStallKind kind,
    Duration now,
    Duration? limit, {
    TrackedRealWork? work,
  }) {
    cancel();
    if (_stalled.isCompleted) return;
    _stalled.completeError(
      ScenarioStall(
        kind,
        timeout: limit ?? Duration.zero,
        idle: now - _lastProgress,
        elapsed: now - _started,
        work: work,
      ),
    );
  }
}
