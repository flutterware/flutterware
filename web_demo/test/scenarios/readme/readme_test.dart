import 'dart:io';

import 'package:flutterware/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware_app/src/demo/recorded_project.dart';
// ignore: implementation_imports
import 'package:flutterware_app/src/demo/recording.dart';
// ignore: implementation_imports
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:brewline/shop/shop_strings.dart';
import 'package:path/path.dart' as p;

import '../../../demo/entries.g.dart';

/// The README's previews card: the one panel the studio's own cards cannot
/// draw, because the previews it shows are compiled into this package — see
/// `app/test/scenarios/studio/readme/readme_test.dart` for the rest of the
/// grid, and why a card's last step folds the rail away.
void main() {
  ShopStrings.assetPackage = 'brewline';
  final recording = FileScenarioArtifacts(
    p.normalize(p.join(Directory.current.path, '..', 'app', 'demo', 'fixture')),
  );

  scenario('Previews card', (s) async {
    var shell = recordedShell(
      recording: recording,
      previews: webDemoPreviews,
      presenting: true,
    );
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Previews');
    await s.tap('Menu');
    await s.act('card-previews', shell.toggleSidebar);
  });
}
