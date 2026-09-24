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

/// The previews guide's pictures — see `app/test/scenarios/studio/docs/` for
/// the others. A named step is a file in `doc/screenshots/`.
void main() {
  ShopStrings.assetPackage = 'brewline';
  final recording = FileScenarioArtifacts(
    p.normalize(p.join(Directory.current.path, '..', 'app', 'demo', 'fixture')),
  );

  scenario('The previews guide', (s) async {
    var shell = recordedShell(
      recording: recording,
      previews: webDemoPreviews,
      presenting: true,
    );
    await shell.start(recordedProjectRoot);
    await s.pumpWidget(ShellApp(shell));
    await s.tap('Previews');
    await s.tap('Menu', shot: Shot('previews'));
    await s.tap('Elements', shot: Shot('previews-tree'));
  });
}
