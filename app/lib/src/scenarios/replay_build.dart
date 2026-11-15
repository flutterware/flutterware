import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/scenarios/default_fonts.dart';
import 'package:flutterware/scenario_replay_protocol.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// What a replay build put on disk.
class ScenarioReplayBuild {
  const ScenarioReplayBuild({
    required this.output,
    required this.index,
    required this.files,
    required this.testsPassed,
    required this.droppedFonts,
    required this.indexMs,
    required this.buildMs,
  });

  /// The directory to serve, absolute.
  final String output;

  final ReplayIndex index;

  /// The test files the page can run.
  final List<String> files;

  /// Whether the `flutter test` run that wrote the index passed. Null when
  /// the index was read from a directory instead.
  final bool? testsPassed;

  /// Font families the app declares that no step draws text in, left out of
  /// the page so it does not download them.
  final List<String> droppedFonts;

  final int indexMs;
  final int buildMs;
}

/// Builds the scenario replay page for one package, and the index beside it.
///
/// Three steps, each a process: a `flutter test` of the scenario files that
/// records what each step shows and reads, a generated entry point that
/// declares those files, and a `flutter build web` of it. Then the page's own
/// files are written over the build's.
class ScenarioReplayBuilder {
  ScenarioReplayBuilder({
    required this.flutterExecutable,
    required this.packageRoot,
  });

  final String flutterExecutable;
  final String packageRoot;

  /// Where the page goes by default, package-relative.
  static const defaultOutput = 'build/scenario_replay';

  /// Where the generated entry point and the index's raw files go.
  String get workDirectory =>
      p.join(packageRoot, '.dart_tool', 'flutterware', 'scenario_replay');

  String get entryPoint => p.join(workDirectory, 'main.dart');

  /// Stands in for the processes, so a test can exercise everything around
  /// them without a toolchain.
  @visibleForTesting
  Future<int> Function(
    List<String> arguments, {
    Map<String, String> environment,
  })?
  debugRun;

  Process? _process;
  var _cancelled = false;

  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
  }

  /// [files] are the scenario files, package-relative with `/`.
  /// [indexFrom] is a directory a `flutter test` run with `FW_REPLAY_INDEX`
  /// already wrote; without it this runs one, at each folder's first device
  /// and language, or at every one it declares when [everyPoint] is set.
  Future<ScenarioReplayBuild> build({
    required List<String> files,
    required String output,
    String? indexFrom,
    bool everyPoint = false,
    bool offline = false,
    List<String> keepFonts = const [],
    void Function(String line)? onOutput,
  }) async {
    if (files.isEmpty) {
      throw StateError('There are no scenario files to replay.');
    }
    var watch = Stopwatch()..start();
    bool? passed;
    var indexDirectory = indexFrom;
    if (indexDirectory == null) {
      indexDirectory = p.join(workDirectory, 'index');
      var directory = Directory(indexDirectory);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      directory.createSync(recursive: true);
      onOutput?.call('[replay] running the scenarios to write the index');
      var code = await _run(
        ['test', ...files],
        environment: {
          'FW_REPLAY_INDEX': indexDirectory,
          if (everyPoint) 'FW_MATRIX': 'declared',
        },
        onOutput: onOutput,
      );
      passed = code == 0;
      if (_cancelled) throw StateError('The replay build was cancelled.');
    }
    var index = readReplayIndex(indexDirectory);
    if (index.scenarios.isEmpty) {
      throw StateError(
        'The index in $indexDirectory names no scenario. It is written by '
        '`runScenarios` in a flutter_test_config.dart, under a `flutter test` '
        'run with FW_REPLAY_INDEX set to that directory.',
      );
    }
    var indexMs = watch.elapsedMilliseconds;

    watch.reset();
    File(entryPoint)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        replayEntryPoint(
          files: files,
          configOf: (file) => nearestTestConfig(packageRoot, file),
          from: p.relative(workDirectory, from: packageRoot),
        ),
      );
    onOutput?.call('[replay] building the page');
    var code = await _run([
      'build',
      'web',
      '--release',
      // Minified, with `flutter_test`'s debug checks kept: it writes
      // `debugDefaultTargetPlatformOverride`, which exists only in debug.
      '-O2',
      '--wasm',
      '--dart-define=dart.vm.product=false',
      // Every language and device the folders declare, so a request can
      // name any of them.
      '--dart-define=fw.matrix=declared',
      '--pwa-strategy=none',
      if (offline) '--no-web-resources-cdn',
      '--target',
      p.relative(entryPoint, from: packageRoot),
      '--output',
      output,
    ], onOutput: onOutput);
    if (_cancelled) throw StateError('The replay build was cancelled.');
    if (code != 0) {
      throw StateError(
        'The replay page did not compile (exit $code). A scenario file that '
        'imports a library the web does not have, `dart:ffi` say, cannot be '
        'replayed; the error above names it.',
      );
    }

    var dropped = writeReplayPage(
      output: output,
      index: index,
      keepFonts: keepFonts,
      flutterRoot: p.dirname(p.dirname(flutterExecutable)),
    );
    return ScenarioReplayBuild(
      output: output,
      index: index,
      files: files,
      testsPassed: passed,
      droppedFonts: dropped,
      indexMs: indexMs,
      buildMs: watch.elapsedMilliseconds,
    );
  }

  Future<int> _run(
    List<String> arguments, {
    Map<String, String> environment = const {},
    void Function(String line)? onOutput,
  }) async {
    if (debugRun case var run?) {
      return run(arguments, environment: environment);
    }
    var process = _process = await Process.start(
      flutterExecutable,
      arguments,
      workingDirectory: packageRoot,
      environment: environment,
    );
    if (_cancelled) process.kill();
    var lines = [
      for (var stream in [process.stdout, process.stderr])
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) => onOutput?.call(line)),
    ];
    var code = await process.exitCode;
    await Future.wait(lines);
    _process = null;
    return code;
  }
}

/// The index the files in [directory] make together.
ReplayIndex readReplayIndex(String directory) {
  var parts = <Map<String, Object?>>[];
  var dir = Directory(directory);
  if (!dir.existsSync()) {
    throw StateError('There is no index in $directory.');
  }
  for (var file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    parts.add(jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
  }
  return ReplayIndex.merge(parts);
}

/// The `flutter_test_config.dart` that `flutter test` wraps [file] in: the
/// nearest one in its directory or above, up to the package. Package-relative,
/// or null when there is none.
String? nearestTestConfig(String packageRoot, String file) {
  var directory = p.url.dirname(file);
  while (true) {
    var candidate = p.url.join(directory, 'flutter_test_config.dart');
    if (File(p.join(packageRoot, candidate)).existsSync()) return candidate;
    if (directory == '.' || directory.isEmpty) return null;
    directory = p.url.dirname(directory);
  }
}

/// The page's entry point: every file, wrapped in its config.
///
/// [from] is the entry point's directory, package-relative, which its
/// imports are relative to.
String replayEntryPoint({
  required List<String> files,
  required String? Function(String file) configOf,
  required String from,
}) {
  var up = p.url.joinAll([for (var _ in p.split(from)) '..']);
  String import(String file) => p.url.join(up, file);
  var configs = <String, int>{};
  var buffer = StringBuffer()
    ..writeln('// Written by flutterware for the scenario replay page.')
    ..writeln("import 'package:flutterware/scenario_replay.dart';")
    ..writeln();
  for (var (i, file) in files.indexed) {
    buffer.writeln("import '${import(file)}' as file$i;");
    if (configOf(file) case var config?) {
      if (!configs.containsKey(config)) {
        configs[config] = configs.length;
        buffer.writeln(
          "import '${import(config)}' as config${configs[config]};",
        );
      }
    }
  }
  buffer
    ..writeln()
    ..writeln('Future<void> main() => runScenarioReplay([');
  for (var (i, file) in files.indexed) {
    var config = configOf(file);
    buffer.writeln(
      '  ReplayFile(${jsonEncode(file)}, file$i.main'
      '${config == null ? '' : ', testExecutable: config${configs[config]}.testExecutable'}),',
    );
  }
  buffer.writeln(']);');
  return '$buffer';
}

/// Writes the page's own files over what `flutter build web` wrote in
/// [output], and answers the font families it left out.
List<String> writeReplayPage({
  required String output,
  required ReplayIndex index,
  List<String> keepFonts = const [],
  String? flutterRoot,
}) {
  Directory(output).createSync(recursive: true);
  // Its own page, because the one an app ships may load `main.dart.js`
  // directly, and only `flutter_bootstrap.js` picks WebAssembly.
  File(p.join(output, 'index.html')).writeAsStringSync(replayIndexHtml);

  var dropped = _trimFontManifest(output, {...index.fonts, ...keepFonts});
  var defaultFonts = _copyDefaultFaces(output, index, flutterRoot);

  var manifest = index.manifest;
  File(p.join(output, replayManifestFile)).writeAsStringSync(
    jsonEncode(
      ReplayManifest(
        commonAssets: manifest.commonAssets,
        scenarios: manifest.scenarios,
        defaultFonts: defaultFonts,
      ).toJson(),
    ),
  );
  File(p.join(output, replayIndexFile))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(index));
  return dropped;
}

const replayIndexHtml = '''<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Scenario replay</title>
  <style>
    html, body { margin: 0; height: 100%; overflow: hidden; background: #ececec; }
    @media (prefers-color-scheme: dark) { html, body { background: #1e1e1e; } }
  </style>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

/// Leaves out of `FontManifest.json` every family no step drew text in: the
/// engine downloads each family it lists when the page opens, whether a
/// screen uses it or not.
List<String> _trimFontManifest(String output, Set<String> used) {
  var file = File(p.join(output, 'assets', 'FontManifest.json'));
  if (!file.existsSync() || used.isEmpty) return const [];
  var families = (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, Object?>>();
  var dropped = [
    for (var family in families)
      if (!used.contains(family['family'])) '${family['family']}',
  ];
  file.writeAsStringSync(
    jsonEncode([
      for (var family in families)
        if (used.contains(family['family'])) family,
    ]),
  );
  return dropped;
}

/// Copies the Roboto faces default text was drawn in, and answers their
/// paths in the page.
List<String> _copyDefaultFaces(
  String output,
  ReplayIndex index,
  String? flutterRoot,
) {
  if (flutterRoot == null) return const [];
  var source = Directory(
    p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts'),
  );
  if (!source.existsSync()) return const [];
  var byName = {
    for (var file in source.listSync().whereType<File>())
      p.basename(file.path).toLowerCase(): file,
  };
  var wanted = <String>{};
  for (var face in index.faces) {
    var at = face.lastIndexOf(':');
    if (at < 0) continue;
    if (!scenarioDefaultFontFamilies.contains(face.substring(0, at))) continue;
    var spec = face.substring(at + 1);
    var italic = spec.endsWith('i');
    var weight = int.tryParse(
      italic ? spec.substring(0, spec.length - 1) : spec,
    );
    if (weight == null) continue;
    var nearest = robotoFaceFiles.keys.reduce(
      (a, b) => (a - weight).abs() <= (b - weight).abs() ? a : b,
    );
    var name = robotoFaceFiles[nearest]!;
    wanted.add(
      italic ? (nearest == 400 ? 'Roboto-Italic' : '${name}Italic') : name,
    );
  }
  var paths = <String>[];
  for (var name in wanted.toList()..sort()) {
    var file = byName['${name.toLowerCase()}.ttf'];
    if (file == null) continue;
    var path = 'flutterware/fonts/$name.ttf';
    var target = File(p.join(output, 'flutterware', 'fonts', '$name.ttf'))
      ..parent.createSync(recursive: true);
    file.copySync(target.path);
    paths.add(path);
  }
  return paths;
}
