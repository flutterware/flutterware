import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_args.dart';

/// The folder's network policy, end to end, and the ladder above it.
///
/// The run's answer is armed the way the **harness** arms it: after every
/// file's `main()` has been declared, per scenario, inside the walk. Read at
/// declaration it would always be null, and `--network=` would be a silent
/// no-op in the one lane it exists for — which is what this file is here to
/// catch.
void main() {
  scenario('takes the folder policy', (s) async {
    expect(s.network.mode, ScenarioNetwork.live);
    await s.pumpWidget(const MaterialApp(home: Text('hello')));
  });

  scenario('says its own and wins', network: ScenarioNetwork.off, (s) async {
    expect(s.network.mode, ScenarioNetwork.off);
    await s.pumpWidget(const MaterialApp(home: Text('hello')));
  });

  group('a run beats the folder', () {
    // Armed after these scenarios are declared and left armed while they run,
    // which is `harness.dart`'s own ordering.
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(network: ScenarioNetwork.off),
    );
    tearDown(() => scenarioRunArgs = null);

    scenario('even where the folder said otherwise', (s) async {
      expect(s.network.mode, ScenarioNetwork.off);
      await s.pumpWidget(const MaterialApp(home: Text('hello')));
    });

    scenario('and the scenario beats the run', network: ScenarioNetwork.live, (
      s,
    ) async {
      expect(s.network.mode, ScenarioNetwork.live);
      await s.pumpWidget(const MaterialApp(home: Text('hello')));
    });
  });
}
