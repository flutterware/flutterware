/// The timers a running scenario started, for the two readers that need to
/// know what is still waiting on the fake clock.
///
/// Under `FakeAsync` a timer fires only when something moves the clock, and
/// only a pump does — so a body that awaits one between pumps waits forever.
/// `flutter_test` keeps the list that would say so, but on a `FakeAsync` the
/// binding holds privately, so it is kept again here, from a zone around the
/// scenario's body: everything the app does it does from inside that body, so
/// the timers it starts are started there.
///
/// `s.act` reads it to decide whether moving the clock can finish what its
/// body is waiting for, and the deadline reads it to stop saying that no pump
/// would complete a future when one would.
library;

import 'dart:async';

/// A timer the running scenario started, and where.
class ScenarioTimer {
  ScenarioTimer(this._timer, this.duration, {required this.periodic, this.at});

  final Timer _timer;

  final Duration duration;
  final bool periodic;

  /// The stack at the timer's creation — the app's frames in it say which
  /// delay, debounce or poll this is.
  final StackTrace? at;

  /// Whether it is still waiting to fire: a one-shot timer stops being
  /// pending as it fires, a periodic one only when it is cancelled.
  bool get pending => _timer.isActive;
}

final _started = <ScenarioTimer>[];

/// The timers the running scenario started that have yet to fire, oldest
/// first.
List<ScenarioTimer> get pendingScenarioTimers => [
  for (var timer in _started)
    if (timer.pending) timer,
];

/// Forgets what an earlier scenario started. Its timers belong to a fake zone
/// nothing will ever advance again.
void forgetScenarioTimers() => _started.clear();

void _remember(ScenarioTimer timer) {
  // Pruned in batches rather than per timer: a gesture recognizer starts one
  // per tap, and almost every timer has fired long before anyone asks.
  if (_started.length >= 256) _started.removeWhere((each) => !each.pending);
  _started.add(timer);
}

/// Where a firing timer's callback goes while [deferringTimers] runs; null
/// the rest of the time, which is almost all of it.
List<void Function()>? _deferred;

/// Runs [body] with every timer it starts — and every timer the code it calls
/// starts — recorded in [pendingScenarioTimers].
Future<T> recordingTimers<T>(Future<T> Function() body) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      void fire() {
        if (_deferred case var deferred?) {
          deferred.add(callback);
        } else {
          callback();
        }
      }

      var timer = parent.createTimer(zone, duration, fire);
      _remember(
        ScenarioTimer(timer, duration, periodic: false, at: StackTrace.current),
      );
      return timer;
    },
    createPeriodicTimer: (self, parent, zone, period, callback) {
      void fire(Timer timer) {
        if (_deferred case var deferred?) {
          deferred.add(() => callback(timer));
        } else {
          callback(timer);
        }
      }

      var timer = parent.createPeriodicTimer(zone, period, fire);
      _remember(
        ScenarioTimer(timer, period, periodic: true, at: StackTrace.current),
      );
      return timer;
    },
  ),
);

/// Runs [advance] — something that moves the fake clock — with the callbacks
/// of the timers it fires held back, and runs them once it has returned.
///
/// A timer fires from inside `FakeAsync.elapse`, and whatever its callback
/// completes runs there too, synchronously: `Future.delayed` completes its
/// future straight from the timer, and the `await` on it resumes on the same
/// stack. A body that resumes there and calls a verb calls a pump from inside
/// a pump — which `FakeAsync` refuses (`Cannot elapse until previous elapse is
/// complete`) and `flutter_test`'s guard reports as a leaked call — so the
/// callbacks wait until the clock has stopped moving, then run in the order
/// they fired, at the instant it stopped.
Future<void> deferringTimers(Future<void> Function() advance) async {
  var deferred = _deferred = <void Function()>[];
  try {
    await advance();
  } finally {
    _deferred = null;
    // Fired is fired: a callback dropped here would be a future that never
    // completes, whatever went wrong while the clock moved.
    for (var callback in deferred) {
      callback();
    }
  }
}
