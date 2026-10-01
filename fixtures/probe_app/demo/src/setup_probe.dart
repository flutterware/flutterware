import 'package:material_ui/material_ui.dart';

// Not annotated, and not declared as this package's setup in
// `tool/flutterware.dart`: `app/test/previews/preview_setup_render_test.dart`
// declares both, so the rest of the catalog renders as it always has.

/// Who configured the previews, as an entry reads it back.
var configuredBy = 'nobody';

/// A package's setup: run once, awaited, before any entry builds.
Future<void> previewSetup() async {
  await Future<void>.delayed(Duration.zero);
  configuredBy = 'previewSetup';
}

/// Says whether the setup had run before it was built.
Widget setupProbe() =>
    Text('configured by $configuredBy', textDirection: TextDirection.ltr);
