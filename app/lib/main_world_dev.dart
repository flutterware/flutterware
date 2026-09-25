import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'src/ui/theme.dart';
import 'src/world/app_guest.dart';
import 'src/world/world_lab_screen.dart';

/// Dev entry point: a world's people side by side in embedded guests — the
/// worlds guest experiment's phase 2 pane. See [WorldLabScreen].
///
/// Its parameters are its knobs (`tool/flutterware.dart`, *World lab (dev)*).
/// `people` is `|`-separated, each a name and that person's own knobs:
/// `Ana;person=Ana|Leo;person=Leo`. A knob value is read as JSON when it
/// parses, so `serverPort=8090` reaches `main` as an int.
void main({
  String flutterSdkRoot = '',
  String appRoot = '',
  String package = '',
  String entrypoint = 'lib/main.dart',
  String fakes = '',
  String people = 'Ana;person=Ana|Leo;person=Leo',
  String platform = 'iOS',
  bool studioAnswers = false,
}) {
  WidgetsFlutterBinding.ensureInitialized();
  var lab = p.join(p.dirname(appRoot), 'fixtures', 'world_lab', 'app');
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      home: flutterSdkRoot.isEmpty || appRoot.isEmpty
          ? const Scaffold(
              body: Center(
                child: Text(
                  'Launch through flutterware: flutterSdkRoot and appRoot '
                  'are knobs it supplies.',
                ),
              ),
            )
          : WorldLabScreen(
              appRoot: appRoot,
              flutterSdkRoot: flutterSdkRoot,
              package: package.isEmpty ? lab : package,
              entrypoint: entrypoint,
              fakes: fakes.isEmpty && package.isEmpty
                  ? p.join(lab, 'guest', 'fakes.dart')
                  : (fakes.isEmpty ? null : fakes),
              platform: platform.isEmpty ? null : platform,
              studioAnswers: studioAnswers,
              people: [
                for (var spec in people.split('|'))
                  (
                    spec.split(';').first,
                    parseKnobs(spec.split(';').skip(1).join(';')),
                  ),
              ],
            ),
    ),
  );
}
