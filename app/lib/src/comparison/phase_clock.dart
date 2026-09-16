import 'package:flutterware/comparison_report.dart';

/// Collects where a comparison's time goes, as [ComparisonTimings] records it.
///
/// One clock for a whole run, handed down as a view that stamps the package it
/// was handed to — see [within] — so a runner that knows nothing of packages
/// still files its phases under the right one.
class PhaseClock {
  PhaseClock() : this._(<ComparisonPhase>[], <String, int>{}, null, false);

  PhaseClock._(this._phases, this._unsettled, this.package, this._qualify);

  final List<ComparisonPhase> _phases;
  final Map<String, int> _unsettled;

  /// What every phase recorded through this view is filed under.
  final String? package;

  /// Whether a scenario id is recorded with [package] in front of it — as the
  /// rows of a comparison covering several packages are.
  final bool _qualify;

  /// The same clock, filing under [package]. [qualify] is the comparison's
  /// own answer to whether its ids carry their package — see `comparedIdIn`.
  PhaseClock within(String package, {required bool qualify}) =>
      PhaseClock._(_phases, _unsettled, package, qualify);

  void add(String name, Duration elapsed, {String? side}) => _phases.add(
    ComparisonPhase(
      name: name,
      ms: elapsed.inMilliseconds,
      package: package,
      side: side,
    ),
  );

  Future<T> time<T>(
    String name,
    Future<T> Function() work, {
    String? side,
  }) async {
    var watch = Stopwatch()..start();
    try {
      return await work();
    } finally {
      add(name, watch.elapsed, side: side);
    }
  }

  T timeSync<T>(String name, T Function() work, {String? side}) {
    var watch = Stopwatch()..start();
    try {
      return work();
    } finally {
      add(name, watch.elapsed, side: side);
    }
  }

  /// Records that [scenario] had [count] steps give up settling in one replay,
  /// keeping the most any replay of it had.
  void unsettled(String scenario, int count) {
    if (count <= 0) return;
    var id = _qualify && package != null
        ? comparedIdIn(package!, scenario)
        : scenario;
    if (count > (_unsettled[id] ?? 0)) _unsettled[id] = count;
  }

  ComparisonTimings get timings => ComparisonTimings(
    phases: List.unmodifiable(_phases),
    unsettledSteps: Map.unmodifiable(_unsettled),
  );
}

/// A running total for a phase that happens many times inside another — a
/// diff per row, a filing per replay — recorded once at the end.
class PhaseTally {
  var _elapsed = Duration.zero;

  T time<T>(T Function() work) {
    var watch = Stopwatch()..start();
    try {
      return work();
    } finally {
      _elapsed += watch.elapsed;
    }
  }

  Duration get elapsed => _elapsed;
}
