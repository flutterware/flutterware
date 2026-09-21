import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads every font the asset bundle's `FontManifest.json` declares — the
/// project's own families plus `MaterialIcons`.
///
/// Both scenario lanes come through here, because a scenario that measures
/// text in the fallback font is wrong in the one way nothing catches: it still
/// renders, still passes most assertions, and reports the few that do not as
/// `RenderFlex overflowed by 3.5 pixels` — a layout regression that never
/// happened. The harness loads them at startup; `flutter test` used to have
/// nobody to do it, so the same suite disagreed with itself across the two.
///
/// Cached, so the second caller awaits the first one's work rather than
/// repeating it. `FontLoader` registers into a process-wide collection, so
/// loading twice is waste and nothing else.
Future<List<String>> loadScenarioFonts() => _loading ??= _load();

Future<List<String>>? _loading;

/// The families [loadScenarioFonts] has loaded, or null while nobody has
/// loaded any — which is the difference a lane's own test asserts on, an empty
/// manifest and an unloaded one being otherwise indistinguishable.
List<String>? get loadedScenarioFonts => _loaded;
List<String>? _loaded;

@visibleForTesting
void resetScenarioFontsForTest() {
  _loading = null;
  _loaded = null;
  _loadingDefaults = null;
}

/// Registers real Roboto under the platform-default family names — the text
/// that names **no** family, which is most of an app.
///
/// The `flutter test` lane only, called from `runScenarios` after the
/// probe returns, which is the one path the flutterware harness never takes.
/// That lane's tester runs with `--use-test-fonts`, hardcoded, so a family
/// nobody loads real bytes for draws every glyph as a filled box *and
/// measures it at the box's width* — [loadScenarioFonts] closes that for the
/// families the project bundles, and this closes it for the defaults, which
/// ship with the platform and are in no `FontManifest.json`. Measured: a
/// default-family label went from 213.8 to 111.6 logical pixels when real
/// bytes took over.
///
/// The bytes come from the SDK's own cache
/// (`$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`), so nothing ships in
/// the package. The Apple and Windows default families get the same Roboto —
/// approximate metrics, against the box font's roughly double ones — so a
/// pixel-exact question about an iOS profile still belongs to the flutterware
/// runner, whose tester has no test-font flag and renders the real thing.
///
/// A family the manifest already declared is left alone: a project bundling
/// its own `Roboto` means it. Quietly a no-op where the cache is not there —
/// this is best-effort repair of a lane whose fonts the SDK took away, not a
/// contract the suite depends on.
///
/// The harness lane must never come through here: its fonts are real already,
/// and registering Roboto over `CupertinoSystemText` there would *replace*
/// the genuine platform resolution with the approximation.
Future<void> loadDefaultScenarioFonts() => _loadingDefaults ??= _loadDefaults();

Future<void>? _loadingDefaults;

/// Every family the SDK's own themes fall back to when a style names none —
/// material and cupertino typography across the platforms a device profile
/// can put a scenario on.
const _defaultFamilies = [
  'Roboto',
  '.AppleSystemUIFont',
  'CupertinoSystemDisplay',
  'CupertinoSystemText',
  'Segoe UI',
];

Future<void> _loadDefaults() async {
  var declared = (await loadScenarioFonts()).toSet();
  var root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  var dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  var files = dir.listSync().whereType<File>().where((file) {
    // Lowercased: the Windows SDK ships `roboto-regular.ttf` where macOS and
    // Linux ship `Roboto-Regular.ttf`, and a case-sensitive match found no
    // faces there, so default text measured in the test font's boxes.
    var name = file.uri.pathSegments.last.toLowerCase();
    // Not `RobotoCondensed-*`: a different family, and nothing's
    // default.
    return name.startsWith('roboto-') && name.endsWith('.ttf');
  }).toList()..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) return;
  var faces = [for (var file in files) file.readAsBytesSync()];
  for (var family in _defaultFamilies) {
    if (declared.contains(family)) continue;
    var loader = FontLoader(family);
    for (var face in faces) {
      loader.addFont(Future.value(ByteData.sublistView(face)));
    }
    await loader.load();
  }
}

Future<List<String>> _load() async {
  // The binding owns both the messenger `rootBundle` loads through and the
  // font collection `FontLoader` registers into, so it has to exist first.
  // Under the harness it already does; under `flutter test` this is the
  // earliest anything has needed it.
  TestWidgetsFlutterBinding.ensureInitialized();

  var manifest = await _manifest();
  var families = <String>[];
  for (var entry in manifest.cast<Map<String, dynamic>>()) {
    var family = entry['family']! as String;
    var loader = FontLoader(family);
    for (var font in (entry['fonts']! as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    // Deliberately unguarded: a family the manifest declares and the bundle
    // cannot supply is a broken build, and swallowing it would put the suite
    // straight back on fallback metrics with nothing said.
    await loader.load();
    families.add(family);
  }
  return _loaded = families;
}

/// The manifest's entries, or none when the bundle carries no manifest at all.
///
/// A bundle without one is a project with no fonts, and that may not start
/// failing suites that pass today. A manifest that *is* there and cannot be
/// read is the opposite case and is left to throw: swallowing it would put the
/// suite back on fallback metrics with nothing said, which is the bug this
/// file exists to close.
Future<List<dynamic>> _manifest() async {
  String source;
  try {
    source = await rootBundle.loadString('FontManifest.json');
  } on FlutterError {
    return const [];
  }
  return jsonDecode(source) as List<dynamic>;
}
