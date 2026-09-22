/// What the recorded project declares that the recorder has to know too.
///
/// Pure Dart, like `recording_paths.dart`, and for the same reason: the
/// studio reads a recording under Flutter and `tool/demo/record.dart` writes
/// one under `dart`, and both must agree on what was declared without either
/// loading the other's world. `recordedManifest()` declares these; the
/// recorder walks them.
library;

import 'package:flutterware/plugins.dart';

/// The demo app's translation catalogs, as its `tool/flutterware.dart`
/// declares them: the shop's strings and, apart from them, the store
/// listing's headlines.
const recordedTranslationCatalogs = [
  TranslationCatalog(name: 'shop', files: 'assets/i18n/*.json'),
  TranslationCatalog(name: 'store', files: 'assets/store/*.json'),
];

/// How the demo app's delta is ranked, as its `tool/flutterware.dart`
/// declares it: the words first, then the package and the app's shell. The
/// recorder ranks the recorded delta by the same rules, so the *Important*
/// tab over a recording is the tab the project would show.
const recordedChangesConfig = ChangesConfig(
  attention: ['assets/i18n/*.json', 'pubspec.yaml', 'lib/shop/shop_app.dart'],
);

/// The demo app's entry points, as its `tool/flutterware.dart` declares
/// them. The recorder launches [recordedRunEntrypoint] — the shop with its
/// devbar plugin, which is what gives the App tab something to show.
const recordedRunEntrypoints = [
  Entrypoint('lib/main.dart', name: 'Brewline', description: 'The coffee shop'),
  recordedRunEntrypoint,
];

const recordedRunEntrypoint = Entrypoint(
  'lib/shop_devbar.dart',
  name: 'Brewline (devbar)',
  description:
      'The shop, with a plugin that pushes a notification into it — the '
      'sample for driving an app from the cockpit, `fw` or an agent',
);
