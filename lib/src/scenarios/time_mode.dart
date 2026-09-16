/// What clock a scenario folder runs on.
///
/// A lane is a **process**: the harness picks its binding once, before any
/// scenario is declared, so this is said per folder — `runScenarios(time: …)`
/// in its `flutter_test_config.dart` — and mirrored on the `ScenariosPackage`
/// so the runner knows which harness to spawn. There is deliberately no
/// `scenario(time: …)`: a body written for fake time pays `Settle.elapse(5s)`
/// in five real seconds under the other clock.
///
/// Flutter-free on purpose, like `network_mode.dart`: the CLI validates
/// `--time=` with it and must not reach Flutter to do so.
library;

sealed class ScenarioTime {
  const ScenarioTime._();

  /// FakeAsync under `AutomatedTestWidgetsFlutterBinding`. The default, and
  /// what every scenario before 2026-09 ran on.
  static const ScenarioTime fake = ScenarioTimeFake._();

  /// The wall clock under `LiveTestWidgetsFlutterBinding`: real timers, real
  /// sockets, real work landing on its own. [animations] scales every
  /// ticker — 0.1 runs a 300ms page transition in 30ms, and a step's picture
  /// is taken after settle so the default loses nothing. A folder that films
  /// a transition says `animations: 1`.
  const factory ScenarioTime.real({double animations}) = ScenarioTimeReal._;

  bool get isReal;

  /// The ticker scale; 1 under [fake].
  double get animations;

  /// `fake` or `real` — the wire, the flag and the report all say this.
  String get name => isReal ? 'real' : 'fake';
}

final class ScenarioTimeFake extends ScenarioTime {
  const ScenarioTimeFake._() : super._();

  @override
  bool get isReal => false;

  @override
  double get animations => 1;
}

final class ScenarioTimeReal extends ScenarioTime {
  const ScenarioTimeReal._({this.animations = 0.1}) : super._();

  @override
  bool get isReal => true;

  @override
  final double animations;
}

/// [raw] as a mode, or a refusal listing the ones there are. `real` comes
/// with the default animation scale; the scale itself is not a flag.
ScenarioTime parseScenarioTime(String raw) => switch (raw) {
  'fake' => ScenarioTime.fake,
  'real' => ScenarioTime.real(),
  _ => throw ArgumentError.value(
    raw,
    'time',
    'Not a time mode. One of: ${scenarioTimeNames.join(', ')}',
  ),
};

const scenarioTimeNames = ['fake', 'real'];
