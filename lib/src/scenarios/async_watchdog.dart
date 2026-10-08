import 'dart:async';
import 'dart:io';

/// What the watchdog saw, when it saw anything — read by the harness so a
/// scenario that runs out its deadline says *why* instead of listing the three
/// things it could have been.
///
/// Set from a real-time timer while the run is wedged, and cleared the moment
/// the `runAsync` it is about returns, so a slow-but-honest one leaves nothing
/// behind.
String? scenarioAsyncStall;

/// How long a `runAsync` may stay open before the watchdog calls it a deadlock
/// rather than slowness.
///
/// Comfortably under the harness's own scenario deadline, so the diagnosis is
/// already recorded by the time that fires — and comfortably over anything a
/// real-async step legitimately does, since a scenario otherwise runs in fake
/// time.
var scenarioRunAsyncStallBudget = const Duration(seconds: 8);

/// Depth rather than a flag: the harness watches every `runAsync` at the
/// binding, so `s.runAsync` nests inside one there and must not arm a second
/// timer or clear the outer one's finding.
var _depth = 0;

/// Whether a watched `runAsync` is open — which is every one under the
/// harness, and `s.runAsync` and `s.setup` under a bare `flutter test`.
///
/// While one is, nothing may move the fake clock: the real work it is waiting
/// for runs only once the fake zone stops being flushed, and a pump flushes
/// it.
bool get runAsyncOpen => _depth > 0;

/// Runs [open] — a `runAsync` — with a real-time watchdog on it.
///
/// A `runAsync` that never returns is the one failure mode of fake time that
/// looks exactly like nothing happening: no pump can run while it is open, so
/// a future created outside it that only a pump could complete never will, and
/// the process simply sits there. The watchdog cannot break the deadlock — the
/// body is suspended inside it and there is no way back in — but it can say,
/// in real seconds rather than in whatever times out first, precisely what has
/// happened.
Future<T> watchRunAsync<T>(Future<T> Function() open) {
  if (_depth > 0) return open();
  _depth++;
  var budget = scenarioRunAsyncStallBudget;
  // From the root zone, because every other clock in reach is the fake one:
  // a `Timer` created here would be a fake timer, and a fake timer during a
  // `runAsync` is the one thing guaranteed never to fire.
  var watchdog = Zone.root.createTimer(budget, () {
    scenarioAsyncStall = runAsyncStallMessage(budget);
    stderr.writeln('[flutterware] $scenarioAsyncStall');
  });
  return open().whenComplete(() {
    _depth--;
    watchdog.cancel();
    scenarioAsyncStall = null;
  });
}

/// The sentence a wedged `runAsync` gets instead of silence.
String runAsyncStallMessage(Duration budget) =>
    '`runAsync` has been open for ${_readable(budget)} of real time, which '
    'under fake time means it is stuck. No pump can run while `runAsync` is '
    'open, so a future made outside it, which only a pump can complete, '
    'never completes. The usual source is an asset. `rootBundle` is a '
    '`CachingAssetBundle`, which caches the future of each read, so reading '
    'a key the app already read while building hands `runAsync` a future '
    'from the fake zone. A screen that shows an SVG, followed by a step that '
    'reads the same SVG, is enough. Read assets through `s.assets`, a '
    '`ScenarioAssetBundle` that caches values instead of futures (inside a '
    'scenario, `DefaultAssetBundle.of(context)` already returns it), or move '
    'the read out of `runAsync`.';

/// The budget as a reader would say it — a test may shorten it to
/// milliseconds, and "open for 0s" reads as a bug in the message.
String _readable(Duration budget) => budget.inSeconds > 0
    ? '${budget.inSeconds}s'
    : '${budget.inMilliseconds}ms';
