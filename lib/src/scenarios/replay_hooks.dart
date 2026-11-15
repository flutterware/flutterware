import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'profile.dart';

/// One step of a running scenario, as the replay sees it.
class ScenarioStepEvent {
  ScenarioStepEvent({
    required this.tester,
    required this.scenario,
    required this.position,
    this.point = '',
    this.verb,
  });

  final WidgetTester tester;

  /// The scenario's description, without the matrix label its test name
  /// carries.
  final String scenario;

  /// Where the step sits: the split choices taken to reach it, joined by
  /// `.`, then `#` and its count since the last split. `#3` is the third step
  /// of a scenario with no split; `1.0#2` is the second step after taking the
  /// second branch of the first split and the first of the one inside it.
  ///
  /// Stable from one run to the next, and the same in every language and on
  /// every device the scenario runs on.
  final String position;

  /// The point of the matrix the scenario runs at, as its test name says it:
  /// `iPhone 16 · fr`, or empty when it runs one way.
  final String point;

  final String? verb;
}

/// Called at every step of every scenario, before anything is captured.
///
/// The replay page sets it to stop on the step it was asked for, and the
/// replay index sets it to record what each step shows. Null everywhere
/// else, where it costs nothing.
FutureOr<void> Function(ScenarioStepEvent step)? scenarioStepHook;

/// Called as each scenario is declared, with its test name, its description
/// and the matrix point it was declared for.
void Function(String name, String description, ScenarioAssignment? point)?
scenarioDeclarationHook;

/// Called as each scenario's body starts and ends, with its description, so
/// a recorder can attribute what happens between the two to it, including
/// work that runs outside the test's own zone.
void Function(String? description)? scenarioRunningHook;

/// The split branches the next scenario takes, by index, outermost first.
///
/// Set by the replay page so a step on a branch is reached directly, rather
/// than after every branch before it has run. Past the end of the list a run
/// takes the first branch of each split, as it always does.
List<int>? scenarioAimedBranches;

/// The split choices of a [ScenarioStepEvent.position], or null when it is
/// not one.
List<int>? branchesOfPosition(String position) {
  var hash = position.indexOf('#');
  if (hash < 0 || int.tryParse(position.substring(hash + 1)) == null) {
    return null;
  }
  var path = position.substring(0, hash);
  if (path.isEmpty) return const [];
  var choices = <int>[];
  for (var part in path.split('.')) {
    var choice = int.tryParse(part);
    if (choice == null || choice < 0) return null;
    choices.add(choice);
  }
  return choices;
}
