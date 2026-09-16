import 'dart:io';

import 'package:flutterware/flutter_test.dart' show ScenarioTime;
import 'package:path/path.dart' as p;

/// Where the generated harness entrypoint lives, relative to the package.
const harnessEntrypointPath = 'build/flutterware/scenarios_harness.dart';

/// The generated `main` the runner compiles: one import per scenario file,
/// feeding the harness the map it declares from.
///
/// Scenario files live under `test/`, outside `lib/`, so they have no
/// `package:` URI — imports are relative to the entrypoint's own location,
/// exactly as the catalog's per-entry wrappers re-relativise theirs.
/// [directory] is that location relative to the package, which is what the
/// climb out of it is computed from — a comparison's entrypoint sits two
/// levels deeper than the default, and a hardcoded `../../` there imports
/// nothing.
String generateHarnessEntrypoint(
  List<String> files, {
  List<String> configs = const [],
  String directory = 'build/flutterware',
  ScenarioTime time = ScenarioTime.fake,
}) {
  var sorted = [...files]..sort();
  var sortedConfigs = [...configs]..sort();
  String import(String file) => p.url.relative(file, from: directory);
  var buffer = StringBuffer()
    ..writeln('// GENERATED — flutterware scenarios harness. Do not edit.')
    ..writeln("import 'package:flutterware/src/scenarios/harness.dart'")
    ..writeln('    as harness;');
  for (var (index, file) in sorted.indexed) {
    buffer.writeln("import '${import(file)}' as s$index;");
  }
  for (var (index, config) in sortedConfigs.indexed) {
    buffer.writeln("import '${import(config)}' as c$index;");
  }
  buffer
    ..writeln()
    ..writeln('void main() => harness.runHarness(')
    ..writeln('  {');
  for (var (index, file) in sorted.indexed) {
    buffer.writeln("    '$file': s$index.main,");
  }
  buffer.writeln('  },');
  if (sortedConfigs.isNotEmpty) {
    // Keyed by the folder they govern, which is how the harness works out
    // which scenarios each one speaks for.
    buffer.writeln('  configs: {');
    for (var (index, config) in sortedConfigs.indexed) {
      buffer.writeln("    '${p.url.dirname(config)}': c$index.testExecutable,");
    }
    buffer.writeln('  },');
  }
  if (time.isReal) {
    buffer.writeln(
      '  time: harness.ScenarioTime.real(animations: ${time.animations}),',
    );
  }
  buffer.writeln(');');
  return buffer.toString();
}

/// The name `flutter test` looks for, and looked for the same way: from a test
/// file's own directory upwards, first one wins, the package root stops the
/// walk (`flutter_tools/src/test/test_config.dart`). Mirrored rather than
/// invented, so the runner and a bare `flutter test` never disagree about
/// which config governs a folder.
const testConfigFileName = 'flutter_test_config.dart';

/// Every `flutter_test_config.dart` that governs one of [files],
/// package-relative and listed once.
List<String> findTestConfigs(String packageRoot, List<String> files) {
  var found = <String>{};
  for (var file in files) {
    if (testConfigFolderFor(packageRoot, file) case var directory?) {
      found.add(p.url.join(directory, testConfigFileName));
    }
  }
  return found.toList()..sort();
}

/// The folder whose `flutter_test_config.dart` governs [file] — the nearest
/// one at or above it — or null where nothing does.
///
/// Package-relative, `''` for the package root. Also **the identity of a pool
/// of scenarios**, which is what the panel remembers a device against: two
/// folders configured differently are two pools, and the folder path is enough
/// to tell them apart without compiling the config to read its profile's
/// name.
String? testConfigFolderFor(String packageRoot, String file) {
  var directory = p.url.dirname(file);
  while (true) {
    var candidate = p.url.join(directory, testConfigFileName);
    var absolute = p.join(packageRoot, p.joinAll(p.url.split(candidate)));
    if (File(absolute).existsSync()) return directory;
    if (directory.isEmpty || directory == '.') return null;
    directory = p.url.dirname(directory);
    if (directory == '.') directory = '';
  }
}

/// Writes the entrypoint into the package and returns its absolute path.
///
/// Left alone when the content is already right: the entrypoint is a compiled
/// source, and an untouched mtime is what keeps a refresh from invalidating —
/// and recompiling — it for nothing.
///
/// [directory] is where it goes, relative to the package — the runner's
/// `buildDirectory`, so the entrypoint lives beside the dill it compiles to
/// and an isolated runner never rewrites the warm lane's copy.
String writeHarnessEntrypoint(
  String packageRoot,
  List<String> files, {
  String directory = 'build/flutterware',
  ScenarioTime time = ScenarioTime.fake,
}) {
  var path = p.join(packageRoot, directory, 'scenarios_harness.dart');
  var source = generateHarnessEntrypoint(
    files,
    configs: findTestConfigs(packageRoot, files),
    directory: directory,
    time: time,
  );
  var file = File(path);
  if (!file.existsSync() || file.readAsStringSync() != source) {
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
  }
  return path;
}
