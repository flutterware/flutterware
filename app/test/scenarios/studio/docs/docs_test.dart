import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware_app/src/demo/recorded_project.dart';
import 'package:flutterware_app/src/demo/recording.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:path/path.dart' as p;

/// The pictures in `doc/`, and the window the README's hero is drawn around.
///
/// A named step is a file: `Shot('store-listing')` becomes
/// `doc/screenshots/store-listing.png` when `tool/screenshots.dart` runs. The
/// walk to each is what a person would do, over the recording the studio's
/// own scenarios use, with the shell presenting — see
/// `readme/readme_test.dart`.
void main() {
  final recording = FileScenarioArtifacts(
    p.join(Directory.current.path, 'demo', 'fixture'),
  );

  Future<void> studio(ScenarioTester s) async {
    var shell = recordedShell(recording: recording, presenting: true);
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
  }

  scenario('The hero window', (s) async {
    await studio(s);
    await s.tap('Scenarios');
    await s.tap('Around the shop');
    await s.tap(Icons.zoom_out);
    await s.tap(Icons.zoom_out, shot: Shot('hero-window'));
  });

  scenario('The scenarios guide', (s) async {
    await studio(s);
    await s.tap('Scenarios');
    await s.tap('Around the shop');
    await s.tap(Icons.zoom_out);
    await s.tap(Icons.zoom_out, shot: Shot('scenarios'));
    await s.tap('Order a cappuccino');
    await s.tap(
      const Target.containing('1 · Welcome'),
      shot: Shot('scenarios-step'),
    );
  });

  scenario('The store guide', (s) async {
    await studio(s);
    await s.tap('Store', shot: Shot('store'));
    await s.tap(
      const Target.nth('Preview listing', 0),
      shot: Shot('store-listing'),
    );
  });

  scenario('The translations guide', (s) async {
    await studio(s);
    await s.tap('Translations');
    await s.tap('drink.maple', shot: Shot('translations'));
  });

  scenario('The comparison guide', (s) async {
    await studio(s);
    await s.tap('Changes');
    await s.tap('previews');
    await s.tap('Menu', shot: Shot('comparison'));
    await s.tap('scenarios');
    await s.tap('Order a cappuccino', shot: Shot('comparison-scenarios'));
  });

  scenario('The changes guide', (s) async {
    await studio(s);
    await s.tap('Changes');
    // Opens on what the project pins; the app's shell is one of them.
    await s.tap('shop_app.dart', shot: Shot('changes'));
  });

  scenario('The run guide', (s) async {
    await studio(s);
    await s.tap('Run');
    await s.tap(const Target.containing('Brewline (devbar) · iPhone 16'));
    await s.tap('Steps');
    await s.tap(const Target.containing('tap "Large"'), shot: Shot('run'));
  });

  scenario('The server guide', (s) async {
    await studio(s);
    await s.tap('Server');
    await s.tap(
      const Target.containing('/orders?today=1'),
      shot: Shot('server'),
    );
  });

  scenario('The dev stack guide', (s) async {
    await studio(s);
    await s.tap('Orders server');
    // The second `Run` is the logs command — the first is the run plugin's
    // row in the rail.
    await s.tap(const Target.nth('Run', 1), shot: Shot('dev-stack'));
    // The button says `Done` for a second and a half after it succeeded.
    await s.wait(const Duration(seconds: 2));
  });

  scenario('The dependencies guide', (s) async {
    await studio(s);
    await s.tap('Dependencies', shot: Shot('dependencies'));
    await s.tap('flutter_native_splash', shot: Shot('dependencies-package'));
  });

  scenario('The splash guide', (s) async {
    await studio(s);
    await s.tap('Splash screen', shot: Shot('native-splash'));
  });

  scenario('The launcher icon guide', (s) async {
    await studio(s);
    await s.tap('Launcher icon');
    await s.tap('Themed icon', shot: Shot('launcher-icon'));
  });
}
