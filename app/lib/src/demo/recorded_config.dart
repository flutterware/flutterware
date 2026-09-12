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
