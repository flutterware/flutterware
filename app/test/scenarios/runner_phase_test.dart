import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_core.dart';

/// The caption under the panel's spinner. The runner writes for a log file;
/// this is what turns those lines into something readable at a glance — and,
/// as importantly, what keeps everything else out.
void main() {
  test('every phase of a cold start has a word', () {
    expect(
      scenarioRunnerPhase('[scenarios] compiling the harness'),
      'Compiling the scenarios',
    );
    expect(
      scenarioRunnerPhase('[scenarios] the asset bundle changed'),
      'Rebuilding the asset bundle',
    );
    expect(
      scenarioRunnerPhase(
        '[tester] The Dart VM service is listening on '
        'http://127.0.0.1:59309/',
      ),
      'Starting the scenario runner',
    );
    expect(
      scenarioRunnerPhase(
        '[tester] flutterware scenarios harness ready — fonts: Roboto, '
        'MaterialIcons',
      ),
      'Starting the scenario runner',
    );
    expect(scenarioRunnerPhase('[scenarios] running'), 'Running the scenario');
  });

  test('a reload counts what it is reloading, and says it in the singular', () {
    expect(
      scenarioRunnerPhase('[scenarios] reloading 1 edited source(s)'),
      'Reloading 1 edited file',
    );
    expect(
      scenarioRunnerPhase('[scenarios] reloading 3 edited source(s)'),
      'Reloading 3 edited files',
    );
  });

  test('every way back to a fresh harness reads the same', () {
    expect(
      scenarioRunnerPhase(
        '[scenarios] hot reload refused, restarting the harness',
      ),
      'Restarting the scenario runner',
    );
    expect(
      scenarioRunnerPhase(
        '[scenarios] a scenario timed out — restarting the harness',
      ),
      'Restarting the scenario runner',
    );
    expect(
      scenarioRunnerPhase('[scenarios] the harness exited (255)'),
      'Restarting the scenario runner',
    );
  });

  test('the app talking to its own console does not move the caption', () {
    expect(scenarioRunnerPhase('[tester] flutter: signing in as ada'), isNull);
    expect(scenarioRunnerPhase('[tester] '), isNull);
    expect(scenarioRunnerPhase('some line nothing prefixed'), isNull);
  });
}
