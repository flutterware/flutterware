import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/capture/settle.dart';
import 'package:flutterware_app/src/comparison/comparison_controller.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/ui/scenarios_tab.dart';

import 'app_theme.dart';

/// A scenario that was replayed and produced no result, beside ones that did.
///
/// On the wire it is `skipped`; drawn as `skipped` it would say the opposite
/// of what happened. See `2026-09-15-comparison-determinism-design.md`.
@Preview(
  name: 'Scenarios tab · no result',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
  size: Size(900, 520),
)
Widget scenariosNoResult() => const _Tab();

@Preview(
  name: 'Scenarios tab · no result · dark',
  group: 'Comparison',
  wrapper: wrapInDarkTheme,
  size: Size(900, 520),
)
Widget scenariosNoResultDark() => const _Tab();

class _Tab extends StatefulWidget {
  const _Tab();

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  static const _save = 'test/profile/save_test.dart#Save the profile';

  final _settle = SettleRegistry();
  var _selected = _save;
  late final _half = ComparisonHalf(
    ComparisonHalfKind.scenarios,
    stage: HalfStage.done,
  );

  @override
  void initState() {
    super.initState();
    for (var scenario in const [
      ScenarioComparison(
        scenario: 'test/cart_test.dart#Checkout',
        state: ComparedState.changed,
        items: [ComparedItem(id: 'Pay', state: ComparedState.changed)],
        branches: [],
      ),
      ScenarioComparison.notCompared(
        scenario: _save,
        inconclusive:
            'The base failed once and passed when replayed again: Expected: '
            'exactly one matching candidate. Its outcome depends on the '
            'machine running it: something in the scenario is racing real '
            'time.',
        baseErrors: ['Expected: exactly one matching candidate'],
      ),
      ScenarioComparison.notCompared(
        scenario: 'test/viewer/model_test.dart#Open the 3D model',
        inconclusive:
            'This branch did not finish on either of two replays: the '
            'scenario did not finish within 30s.',
      ),
    ]) {
      _half.addScenario(scenario);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: ScenariosTab(
      half: _half,
      store: const _NoShots(),
      settle: _settle,
      selected: _selected,
      onSelect: (id) => setState(() => _selected = id),
    ),
  );
}

class _NoShots implements ShotStore {
  const _NoShots();

  @override
  Future<Shot?> byKey(String key, {int? width}) async => null;

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async => null;
}
