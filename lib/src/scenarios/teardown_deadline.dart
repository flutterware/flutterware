/// A deadline on the teardowns a scenario registers.
///
/// `test_api` waits on a teardown's future for as long as it takes. The test's
/// own timeout reports a failure when it fires, but the run goes on waiting on
/// that future, so one teardown that never finishes stops the whole run with
/// nothing more on the screen, and leaves the test process running after it.
///
/// The usual teardown that never finishes awaits work on the scenario's fake
/// clock: a stream cancellation, a client's `close`, a debounce flushed on the
/// way out. Nothing moves that clock once the body has returned, so the timer
/// it waits on never fires. This is the fake-time version of an `await` on
/// nothing, and it is the one place the scenario's own deadlines did not
/// reach: the body was over.
///
/// So a scenario watches its own teardowns. Past their budget it fails, with
/// the teardown and what it waits on named, and then moves the fake clock
/// until the teardown finishes, so the rest of the run still goes on.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

import '../environment.dart';
import 'fake_timers.dart';
import 'stall.dart';

/// How long a scenario's teardowns may run, together, when the scenario
/// declares no `timeout:` of its own.
///
/// Comfortably over what a teardown that only deletes a directory or closes a
/// database takes, and under the harness's own deadline, so this sentence is
/// the one a run reports.
var scenarioTeardownBudget = const Duration(seconds: 10);

/// How long [own]'s teardowns may run: half of the scenario's own timeout, or
/// [scenarioTeardownBudget] when it declares none.
///
/// [progress] is the deadline the harness keeps over the whole test, teardowns
/// included, when one is kept. The budget stays under half of it, so this
/// deadline fires first, names the teardown, and keeps the run going, where
/// the harness's would give up on the process. Null is no deadline:
/// `Timeout.none` turns every timeout off, this one included.
Duration? teardownBudgetFor(Timeout? own, {Timeout? progress}) {
  if (own == Timeout.none) return null;
  if (own?.duration case var declared?) return declared ~/ 2;
  var budget = scenarioTeardownBudget;
  if (progress?.duration case var limit? when limit ~/ 2 < budget) {
    return limit ~/ 2;
  }
  return budget;
}

/// The running scenario's teardowns while they run, or null.
///
/// Read by the harness: its own deadline fires on a teardown only when this
/// one could not keep the run going, and it must say "a teardown", not where
/// the body was.
ScenarioTeardowns? scenarioTeardownsRunning;

/// What a scenario fails with when its teardowns run past their budget.
class ScenarioTeardownStall implements Exception {
  ScenarioTeardownStall(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The watch over one scenario's teardowns.
///
/// Two teardowns of its own bracket the ones the body registers. `test_api`
/// runs teardowns last registered first, so the one the constructor registers
/// runs after all of them, and the one [bodyReturned] registers runs before
/// them and starts the deadline.
class ScenarioTeardowns {
  /// Call before the body runs.
  ScenarioTeardowns(this.scenario, {required this.budget}) {
    // An earlier scenario's, when the harness gave up on it mid-teardown.
    scenarioTeardownsRunning = null;
    addTearDown(_finished);
  }

  final String scenario;

  /// How long the teardowns may run. Null is no deadline.
  final Duration? budget;

  Timer? _deadline;
  Timer? _moving;

  /// The sentence the scenario failed with, once it has.
  String? failure;

  /// Call once the body has returned, whether or not it threw.
  void bodyReturned() => addTearDown(_started);

  void _started() {
    scenarioTeardownsRunning = this;
    var budget = this.budget;
    if (budget == null) return;
    // The zone the test's teardowns run in. An error handed to it fails this
    // test, the way a throw from a teardown would.
    var zone = Zone.current;
    // From the root zone: under fake time a timer anywhere near the body is a
    // fake one, and a fake timer is what nothing fires any more.
    _deadline = Zone.root.createTimer(budget, () {
      var said = failure = diagnosis();
      zone.handleUncaughtError(ScenarioTeardownStall(said), StackTrace.empty);
      _moveTheClock();
    });
  }

  void _finished() {
    _deadline?.cancel();
    _moving?.cancel();
    if (identical(scenarioTeardownsRunning, this)) {
      scenarioTeardownsRunning = null;
    }
  }

  /// Moves the fake clock until the teardowns finish, so the run goes on past
  /// a scenario that has already failed.
  ///
  /// A second of fake time every few milliseconds: there are no frames to draw
  /// once the body is over, so the jumps cost nothing, and every timer still
  /// fires in order. Bounded, because a teardown waiting on something no clock
  /// completes would otherwise be moved forever.
  void _moveTheClock() {
    var binding = TestWidgetsFlutterBinding.instance;
    if (binding is! AutomatedTestWidgetsFlutterBinding) return;
    var moved = Duration.zero;
    _moving = Zone.root.createPeriodicTimer(const Duration(milliseconds: 5), (
      timer,
    ) {
      if (moved >= _movingLimit) {
        timer.cancel();
        writeDiagnostic(
          '[flutterware] "$scenario": its teardown still had not finished '
          'after its fake clock was moved forward ${spanOf(moved)}, so this '
          'run cannot go on past it. Stop the run and fix the teardown.',
        );
        return;
      }
      try {
        binding.delayed(_movingStep);
      } catch (_) {
        // The clock is gone (the test ended under us) or will not move. The
        // failure is already reported either way.
        timer.cancel();
      }
      moved += _movingStep;
    });
  }

  /// What the teardowns are waiting on, as the sentence the scenario fails
  /// with.
  String diagnosis() {
    var binding = TestWidgetsFlutterBinding.instance;
    var fake = binding is AutomatedTestWidgetsFlutterBinding;
    int? microtasks;
    if (fake) {
      try {
        microtasks = binding.microtaskCount;
      } catch (_) {
        // Readable only until the test's clock is dropped.
      }
    }
    return teardownStallMessage(
      scenario,
      budget: budget ?? Duration.zero,
      fakeClock: fake,
      timers: pendingScenarioTimers,
      microtasks: microtasks,
    );
  }
}

const _movingStep = Duration(seconds: 1);
const _movingLimit = Duration(minutes: 5);

/// The sentence a scenario fails with when its teardowns are still running
/// [budget] after its body returned.
///
/// [timers] are the scenario's timers still waiting to fire and [microtasks]
/// what is queued in its fake zone, both read as the deadline fires.
/// [fakeClock] is false on the real clock, where neither can be the reason.
@visibleForTesting
String teardownStallMessage(
  String scenario, {
  required Duration budget,
  bool fakeClock = true,
  List<ScenarioTimer> timers = const [],
  int? microtasks,
}) {
  var head =
      '"$scenario": a teardown was still running ${spanOf(budget)} after the '
      "scenario's body returned, so the scenario fails.";
  if (fakeClock && timers.isNotEmpty) {
    var site = timers.map((timer) => teardownSiteOf(timer.at)).nonNulls;
    var waiting = switch (site.firstOrNull) {
      var at? => 'The teardown at `$at` is waiting on',
      null => 'It is waiting on',
    };
    var clock = timers.length == 1
        ? "That timer is on the scenario's fake clock. Nothing moves that "
              'clock after the body returns, so it never fires.'
        : "Those timers are on the scenario's fake clock. Nothing moves that "
              'clock after the body returns, so they never fire.';
    return '$head $waiting ${describeTimers(timers)}. $clock $_pumpInstead';
  }
  if (fakeClock && microtasks != null && microtasks > 0) {
    var queued = microtasks == 1
        ? '1 microtask is'
        : '$microtasks microtasks are';
    return "$head $queued queued in the scenario's fake zone. Nothing runs "
        'them after the body returns, so work that started in the body and '
        'finished since, such as a stream cancellation or a request, never '
        'hands back its result. $_pumpInstead';
  }
  var cause = fakeClock
      ? "Nothing is waiting on the scenario's fake clock, so the teardown is "
            'waiting on real work that has not answered, or on a future that '
            'never completes. Real work the body starts belongs in '
            '`s.runAsync`.'
      : 'It is waiting on work that has not answered, or on a future that '
            'never completes.';
  return '$head $cause If the teardown is only slow, give the scenario a '
      'longer `timeout:`. Its teardowns may take half of it.';
}

/// What to do when the teardown is waiting on the fake clock.
const _pumpInstead =
    'It probably needs pumping. Do this cleanup at the end of the body '
    "instead, inside `s.act('…', () => …)`, which moves the clock until it "
    'completes. Real work the body starts belongs in `s.runAsync`.';

/// Where the teardown that started the work in [trace] is, as
/// `test/shop_test.dart:20`, or null when the trace does not pass through a
/// teardown.
///
/// The teardown is the outermost frame of the scenario's own code above the
/// line where `test_api` called it. Work started past an `await` inside the
/// teardown has lost that frame, and gets no site.
@visibleForTesting
String? teardownSiteOf(StackTrace? trace) {
  if (trace == null) return null;
  var lines = '$trace'.split('\n');
  var calledAt = lines.indexWhere((line) => line.contains(_runsTeardowns));
  if (calledAt < 0) return null;
  var above = appFrames(
    StackTrace.fromString(lines.take(calledAt).join('\n')),
    max: calledAt,
  );
  var frame = above.lastOrNull;
  if (frame == null) return null;
  return _location.firstMatch(frame)?.group(1) ?? frame;
}

/// The frame `test_api` calls every teardown from.
const _runsTeardowns = 'Invoker.runTearDowns';

/// The parenthesised location at the end of a frame `appFrames` produced.
final _location = RegExp(r'\(([^()]+)\)$');
