import 'package:flutterware/comparison_report.dart';

/// Collects where a comparison's time goes, as [ComparisonTimings] records it.
///
/// One clock for a whole run, handed down as a view that stamps the package it
/// was handed to — see [within] — so a runner that knows nothing of packages
/// still files its phases under the right one.
class PhaseClock {
  PhaseClock()
    : this._(
        <ComparisonPhase>[],
        <String, int>{},
        <String>[],
        <String, Set<String>>{},
        null,
        false,
      );

  PhaseClock._(
    this._phases,
    this._unsettled,
    this._pooledOnly,
    this._stillTicking,
    this.package,
    this._qualify,
  );

  final List<ComparisonPhase> _phases;
  final Map<String, int> _unsettled;
  final List<String> _pooledOnly;
  final Map<String, Set<String>> _stillTicking;

  /// What every phase recorded through this view is filed under.
  final String? package;

  /// Whether a scenario id is recorded with [package] in front of it — as the
  /// rows of a comparison covering several packages are.
  final bool _qualify;

  /// The same clock, filing under [package]. [qualify] is the comparison's
  /// own answer to whether its ids carry their package — see `comparedIdIn`.
  PhaseClock within(String package, {required bool qualify}) => PhaseClock._(
    _phases,
    _unsettled,
    _pooledOnly,
    _stillTicking,
    package,
    qualify,
  );

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
  /// keeping the most any replay of it had, and what [stillTicking] on them
  /// across every replay.
  void unsettled(
    String scenario,
    int count, {
    List<String> stillTicking = const [],
  }) {
    if (count <= 0) return;
    var id = _qualified(scenario);
    if (count > (_unsettled[id] ?? 0)) _unsettled[id] = count;
    if (stillTicking.isNotEmpty) {
      _stillTicking.putIfAbsent(id, () => {}).addAll(stillTicking);
    }
  }

  /// Records that [scenario] differed beside other replays and not alone —
  /// see [ComparisonTimings.pooledOnlyDifferences].
  void pooledOnly(String scenario) => _pooledOnly.add(_qualified(scenario));

  String _qualified(String scenario) =>
      _qualify && package != null ? comparedIdIn(package!, scenario) : scenario;

  ComparisonTimings get timings => ComparisonTimings(
    phases: List.unmodifiable(_phases),
    unsettledSteps: Map.unmodifiable(_unsettled),
    pooledOnlyDifferences: List.unmodifiable(_pooledOnly),
    stillTicking: {
      for (var MapEntry(:key, :value) in _stillTicking.entries)
        key: List.unmodifiable(value),
    },
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
