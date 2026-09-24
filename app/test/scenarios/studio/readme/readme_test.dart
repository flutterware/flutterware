import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware_app/src/demo/recorded_project.dart';
import 'package:flutterware_app/src/demo/recording.dart';
import 'package:flutterware_app/src/shell/shell_controller.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:path/path.dart' as p;

/// The README's grid, one card per scenario, over the same recording the
/// studio's own scenarios walk.
///
/// Each scenario taps its way to the screen worth showing with the rail
/// there, as a person would, and its one named step folds the rail away:
/// that step's picture is the card, and its name is the file it becomes —
/// `tool/screenshots.dart` keeps the named steps and nothing else.
///
/// The shell is the presenting one: the recorded app answers as a live run,
/// so the Run card shows the cockpit rather than the recording's disclosure.
void main() {
  final recording = FileScenarioArtifacts(
    p.join(Directory.current.path, 'demo', 'fixture'),
  );

  Future<ShellController> studio(ScenarioTester s) async {
    var shell = recordedShell(recording: recording, presenting: true);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    return shell;
  }

  Future<void> card(ScenarioTester s, ShellController shell, String name) =>
      s.act(name, shell.toggleSidebar);

  scenario('Scenarios card', (s) async {
    var shell = await studio(s);
    await s.tap('Scenarios');
    await s.tap('Around the shop');
    await s.tap(Icons.zoom_out);
    await s.tap(Icons.zoom_out);
    await s.tap(Icons.zoom_out);
    // The rail and the panel's own list both: the flow is the picture.
    await s.act('card-scenarios', shell.aside.toggleExpanded);
  });

  scenario('Store card', (s) async {
    var shell = await studio(s);
    await s.tap('Store');
    await card(s, shell, 'card-store');
  });

  scenario('Translations card', (s) async {
    var shell = await studio(s);
    await s.tap('Translations');
    await s.tap('drink.maple');
    await card(s, shell, 'card-translations');
  });

  scenario('Run card', (s) async {
    var shell = await studio(s);
    await s.tap('Run');
    await s.tap(const Target.containing('Brewline (devbar) · iPhone 16'));
    await s.tap('Steps');
    await s.tap(const Target.containing('tap "Large"'));
    await card(s, shell, 'card-run');
  });

  scenario('Comparison card', (s) async {
    var shell = await studio(s);
    await s.tap('Changes');
    await s.tap('scenarios');
    await s.tap('Order a cappuccino');
    await card(s, shell, 'card-comparison');
  });

  scenario('Changes card', (s) async {
    var shell = await studio(s);
    await s.tap('Changes');
    await s.tap('All');
    await s.tap('shop_app.dart');
    await card(s, shell, 'card-changes');
  });

  scenario('Server card', (s) async {
    var shell = await studio(s);
    await s.tap('Server');
    await s.tap(const Target.containing('/orders?today=1'));
    await card(s, shell, 'card-server');
  });
}
