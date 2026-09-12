import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';
import 'package:flutterware/plugins.dart' show FilePerLocaleCatalog;
import 'package:flutterware/server.dart';
import 'package:flutterware/translations.dart' show translationExportFile;
import 'package:flutterware_app/src/demo/recorded_config.dart';
import 'package:flutterware_app/src/dependencies/model/pub_deps.dart';
import 'package:flutterware_app/src/dependencies/model/pubspec_lock.dart';
import 'package:flutterware_app/src/dependencies/model/service.dart';
import 'package:flutterware_app/src/dependencies/model/source.dart';
import 'package:flutterware_app/src/demo/recording_paths.dart';
import 'package:flutterware_app/src/launcher_icon/model/scan.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';
import 'package:flutterware_app/src/scenarios/discovery.dart';
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:flutterware_app/src/splash/model/files.dart';
import 'package:flutterware_app/src/splash/model/fingerprint.dart';
import 'package:flutterware_app/src/splash/model/scan.dart';
import 'package:flutterware_app/src/translations/loader.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:image/image.dart' as img;
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart' show Pubspec;
import 'package:yaml/yaml.dart';

import 'server_traffic.dart';
import 'stack_traffic.dart';

/// Writes the recording the studio's demos open: `app/demo/fixture/`.
///
/// Runs the real readers on a real project and keeps what they produced, with
/// every file they name copied in beside it. Nothing here is written by hand,
/// so the recording is only ever an output of the shipped formats and cannot
/// drift from the code that reads it — a recording that stops loading is a
/// format change, found at the right time.
///
/// ```sh
/// cd app && fvm dart run tool/demo/record.dart [project-dir]
/// ```
///
/// The project defaults to `examples/brewline`, the demo app, recorded **as
/// if it were the root of its own repository**: its package path in the
/// recording is `.`.
/// That is what a reader's project usually looks like, and it keeps the
/// recorded project's workspace to one package nothing on disk has to
/// confirm.
///
/// `--only=launcher-icon`, `--only=scenarios`, `--only=server`,
/// `--only=stack`, `--only=translations`, `--only=store`,
/// `--only=dependencies` or `--only=splash` records one part. The
/// launcher-icon, server, stack and splash parts are byte-identical on every
/// machine, which CI checks; the scenario, translations and store parts
/// spawn the harness and keep its pixels, and the dependencies part asks
/// pub.dev, none of which is, and those are recorded from one machine on
/// purpose.
///
/// The server part runs no server: a real [ServerInspector] is started in
/// this process, `tool/demo/server_traffic.dart` reports into it the way a
/// server's adapters do, and the recorder attaches over the real protocol
/// and keeps what came back — so the recording is the wire's own shapes.
Future<void> main(List<String> arguments) async {
  var appRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  String? only;
  String? projectArg;
  for (var argument in arguments) {
    if (argument.startsWith('--only=')) {
      only = argument.substring('--only='.length);
      if (!const {
        'launcher-icon',
        'scenarios',
        'server',
        'stack',
        'translations',
        'store',
        'dependencies',
        'splash',
      }.contains(only)) {
        stderr.writeln(
          'usage: record.dart [project] '
          '[--only=launcher-icon|scenarios|server|stack|translations|store'
          '|dependencies|splash]',
        );
        exit(64);
      }
    } else {
      projectArg = argument;
    }
  }
  var project = projectArg == null
      ? p.join(p.dirname(appRoot), 'examples', 'brewline')
      : p.normalize(p.absolute(projectArg));
  var out = p.join(appRoot, 'demo', 'fixture');

  if (!File(p.join(project, 'pubspec.yaml')).existsSync()) {
    stderr.writeln('Not a package: $project');
    exit(1);
  }

  var written = <String>[
    if (only == null || only == 'launcher-icon')
      _recordLauncherIcons(project: project, out: out),
    if (only == null || only == 'scenarios')
      await _recordScenarios(
        project: project,
        out: out,
        scratch: p.join(appRoot, 'build', 'demo_record'),
      ),
    if (only == null || only == 'server') await _recordServer(out: out),
    if (only == null || only == 'stack') _recordStack(out: out),
    if (only == null || only == 'translations')
      await _recordTranslations(project: project, out: out, appRoot: appRoot),
    if (only == null || only == 'store')
      await _recordStore(project: project, out: out, appRoot: appRoot),
    if (only == null || only == 'dependencies')
      await _recordDependencies(project: project, out: out),
    if (only == null || only == 'splash')
      _recordSplash(project: project, out: out),
  ];
  print(
    'Recorded ${p.relative(project, from: p.dirname(appRoot))} into '
    '${p.relative(out, from: appRoot)}:\n  ${written.join('\n  ')}',
  );
}

/// Which scenario files of the demo app are recorded: the coffee shop's
/// walks, on a phone and in a window. Enough to show a flow, a device frame
/// of each kind and a step page, without the whole suite's pictures in git.
const recordedScenarioFiles = [
  'test/scenarios/mobile/shop_test.dart',
  'test/scenarios/desktop/shop_window_test.dart',
];

/// The scan, the harness's listing, and a run of [recordedScenarioFiles] with
/// every artifact copied in. The harness is the real one, spawned the way the
/// panel spawns it; what is kept is its report, verbatim but for the paths.
Future<String> _recordScenarios({
  required String project,
  required String out,
  required String scratch,
}) async {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'scenarios'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  if (Directory(scratch).existsSync()) {
    Directory(scratch).deleteSync(recursive: true);
  }
  var sdk = await FlutterSdkPath.findSdk();
  if (sdk == null) {
    stderr.writeln("Run this through a Flutter SDK's dart: fvm dart run …");
    exit(1);
  }

  void write(String path, Map<String, Object?> json) => File(p.join(out, path))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );

  // The scan, as the core takes it: the default root, since the recorded
  // manifest declares no directory.
  // The scan, as the core takes it, narrowed to the files that are run
  // below: the recorded project *has* those scenarios and no others, so
  // its list offers nothing a click cannot open.
  var scanned = ScenarioScanner(
    packageRoot: project,
    directory: defaultScenariosScanRoot,
  ).scan();
  var scan = ScenarioScanResult(
    scenarios: [
      for (var ref in scanned.scenarios)
        if (recordedScenarioFiles.contains(ref.file)) ref,
    ],
    diagnostics: scanned.diagnostics,
    unnamed: scanned.unnamed,
    configFolders: scanned.configFolders,
  );
  write(recordedScenarioScanPath(packagePath), scan.toJson());

  // The banner icon the flow page shows, found the way the page finds it.
  if (representativeIconPath(packageRoot: project) case var icon?) {
    File(icon).copySync(
      (File(
        p.join(out, recordedScenarioAppIconPath(packagePath)),
      )..parent.createSync(recursive: true)).path,
    );
  }

  var runner = ScenarioRunner(
    packageRoot: project,
    directory: defaultScenariosScanRoot,
    flutterSdkRoot: sdk.root,
    onLog: (line) => stderr.writeln('  [harness] $line'),
  );
  var copied = 0;
  var bytes = 0;
  var scenarios = 0;
  var steps = 0;
  try {
    var listed = await runner.list();
    write(recordedScenarioListingsPath(packagePath), {
      'scenarios': [
        for (var listing in listed)
          if (recordedScenarioFiles.contains(listing.file)) listing.toJson(),
      ],
    });

    for (var (i, file) in recordedScenarioFiles.indexed) {
      var report = await runner.run(
        outDir: p.join(scratch, '$i'),
        file: file,
        unspecifiedDevice: defaultScenarioDeviceId,
      );
      for (var entry in (report['scenarios']! as List)) {
        var outcome = (entry as Map).cast<String, Object?>();
        scenarios++;
        var into = recordedScenarioArtifactDir(
          packagePath,
          file,
          outcome['name']! as String,
        );
        for (var step in (outcome['steps'] as List? ?? const [])) {
          steps++;
          var fields = (step as Map).cast<String, Object?>();
          for (var key in _stepPathFields) {
            if (fields[key] case String source when source.isNotEmpty) {
              var destination = '$into/${p.basename(source)}';
              var target = File(p.join(out, destination))
                ..parent.createSync(recursive: true);
              if (source.endsWith('.json')) {
                // A tree names each widget's source file by absolute path,
                // which is this machine's. Re-rooted so the recorded project
                // is where it says it is, and nothing of the laptop that
                // recorded it ships.
                target.writeAsStringSync(
                  _reroot(File(source).readAsStringSync(), project),
                );
              } else {
                File(source).copySync(target.path);
              }
              copied++;
              bytes += target.lengthSync();
              fields[key] = destination;
            }
          }
        }
      }
      write(
        recordedScenarioRunPath(packagePath, file),
        (jsonDecode(_reroot(jsonEncode(report), project)) as Map)
            .cast<String, Object?>(),
      );
    }
    write(recordedScenarioRunsIndexPath(packagePath), {
      'files': recordedScenarioFiles,
    });
  } finally {
    await runner.dispose();
  }
  return '${scanned.scenarios.length} scenarios scanned, '
      '${scan.scenarios.length} kept, '
      '${recordedScenarioFiles.length} files run ($scenarios scenarios, '
      '$steps steps), $copied artifacts, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// The catalogs as their globs read them, and an export of the whole suite.
///
/// The catalogs go through the live reader — the same walk the panel does,
/// kept as its answer per glob, since a recording cannot walk one. The
/// export is the real action, `fw run translations export`, run over the
/// project by the CLI the way a script would run it, and its output kept
/// verbatim: the panel resolves every shot under the export's directory,
/// and the recording's copy is that directory.
Future<String> _recordTranslations({
  required String project,
  required String out,
  required String appRoot,
}) async {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'translations'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  var read = catalogFilesUnder(project);
  var globs = <String, Map<String, String>>{};
  for (var catalog in recordedTranslationCatalogs) {
    var glob = (catalog as FilePerLocaleCatalog).files;
    globs[glob] = await read(glob);
  }
  File(p.join(out, recordedTranslationCatalogsPath(packagePath)))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'globs': globs})}\n',
    );

  var exported = await Process.run(Platform.resolvedExecutable, [
    'run',
    p.join(appRoot, 'bin', 'fw.dart'),
    'run',
    'translations',
    'export',
    '--package=$packagePath',
  ], workingDirectory: project);
  if (exported.exitCode != 0) {
    stderr.writeln(exported.stdout);
    stderr.writeln(exported.stderr);
    throw StateError('translations export failed (${exported.exitCode})');
  }
  var export = p.join(project, 'build', 'translations');
  var into = p.join(out, recordedTranslationExportDir(packagePath));
  var copied = 0;
  var bytes = 0;
  for (var entity in Directory(export).listSync(recursive: true)) {
    if (entity is! File) continue;
    var relative = p.relative(entity.path, from: export);
    // The page beside the index is for a browser opened on the export; the
    // panel reads the index and the shots.
    if (relative == 'index.html') continue;
    var target = File(p.join(into, relative))
      ..parent.createSync(recursive: true);
    entity.copySync(target.path);
    copied++;
    bytes += target.lengthSync();
  }
  var index = jsonDecode(
    File(p.join(into, translationExportFile)).readAsStringSync(),
  ) as Map;
  var files = globs.values.fold(0, (sum, found) => sum + found.length);
  return '${globs.length} translation catalogs ($files files), an export of '
      '${(index['keys'] as List).length} keys, $copied files, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// How much smaller than the store's canvas a recorded screenshot is kept.
///
/// The one place a recording is not the tool's bytes. A store canvas is
/// 1320×2868 or 2048×2732 pixels, and the demo app's listing exported whole is
/// 42 MB of PNG — a fixture git would carry forever for a panel whose cards
/// are thumbnails and whose viewer fits a phone into a window. A third along
/// each side, the iPhone sets are 2.6 MB, still larger than anything the page
/// draws them at, and the manifest keeps the canvas the store will receive,
/// which is what the panel prints. Pixel-for-pixel fidelity at a store's own
/// size is what `fw run store export` is for.
const recordedStoreShotDivisor = 3;

/// The display class the recording keeps. The declaration has two, and the
/// iPad's sets are the larger half of an export the fixture cannot carry
/// whole; narrowed by the action's own `--class`, the manifest holds the
/// iPhone sets and the panel draws the iPad cards as it draws any set that
/// has not been exported yet — which is a state worth a picture too.
const recordedStoreClass = 'iphone-6-9';

/// The store export, as the real action wrote it — and the pictures smaller.
///
/// `fw run store export` is run over the project by the CLI, the way a script
/// would run it, so the tree is what the panel reads on any project. What is
/// kept is the manifest with every set's `output` spelled under the recording
/// and its time pinned, the pubspec's name and description beside it, and
/// each set's images at [recordedStoreShotDivisor] — `unframed/` is not read
/// by the panel and is left behind.
Future<String> _recordStore({
  required String project,
  required String out,
  required String appRoot,
}) async {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'store'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  var exported = await Process.run(Platform.resolvedExecutable, [
    'run',
    p.join(appRoot, 'bin', 'fw.dart'),
    'run',
    'store',
    'export',
    '--class=$recordedStoreClass',
  ], workingDirectory: project);
  if (exported.exitCode != 0) {
    stderr.writeln(exported.stdout);
    stderr.writeln(exported.stderr);
    throw StateError('store export failed (${exported.exitCode})');
  }

  var pubspec =
      loadYaml(File(p.join(project, 'pubspec.yaml')).readAsStringSync()) as Map;
  var name = '${pubspec['name']}';
  var storeRoot = p.join(project, 'build', 'flutterware', 'store');
  var manifest = jsonDecode(
    File(p.join(storeRoot, name, '.store', 'manifest.json')).readAsStringSync(),
  ) as Map<String, Object?>;

  var recordedRoot = recordedStoreRootDir(packagePath);
  var copied = 0;
  var bytes = 0;
  var sets = manifest['sets']! as List;
  for (var entry in sets) {
    var set = (entry as Map).cast<String, Object?>();
    var output = set['output']! as String;
    var directory = set['directory']! as String;
    var relativeOutput = p.relative(output, from: storeRoot);
    var recordedOutput =
        '$recordedRoot/${relativeOutput.replaceAll(r'\', '/')}';
    set['output'] = recordedOutput;
    // A recording carries no clock — see `_recordLauncherIcons`.
    set['exportedAt'] = pinnedClockOrigin.toIso8601String();
    for (var image in set['images']! as List) {
      var source = File(p.join(output, directory, '$image'));
      var target = File(p.join(out, recordedOutput, directory, '$image'))
        ..parent.createSync(recursive: true);
      var decoded = img.decodePng(source.readAsBytesSync())!;
      var smaller = img.copyResize(
        decoded,
        width: decoded.width ~/ recordedStoreShotDivisor,
        height: decoded.height ~/ recordedStoreShotDivisor,
        interpolation: img.Interpolation.average,
      );
      target.writeAsBytesSync(img.encodePng(smaller, level: 9));
      copied++;
      bytes += target.lengthSync();
    }
  }
  File(p.join(out, recordedStorePath(packagePath)))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'pubspec': {'name': name, 'description': '${pubspec['description'] ?? ''}'},
        'manifest': manifest,
      })}\n',
    );
  return 'a store export of ${sets.length} sets, '
      '$copied images at 1/$recordedStoreShotDivisor, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// Every read the dependencies plugin makes, made once here and kept.
///
/// The resolution's inputs — the pubspec, the lockfile, `pub deps --json` —
/// are kept as the tools wrote them, so the recording is parsed by the same
/// parsers the panel parses a project with. The package config is rewritten
/// so every package sits under [recordedDependencyRoot] by its name, and what
/// the live source computes from the pub cache for each package — its
/// pubspec, readme and changelog, line count, size — is filed under that
/// root, with what pub.dev said about it. The scores table is cut to the
/// packages present: whole, it is 25 MB.
///
/// The project is a workspace member here, so its resolution is the
/// workspace's — wider than a clone's, and scoped back to what the project
/// reaches by the same walk the panel does.
Future<String> _recordDependencies({
  required String project,
  required String out,
}) async {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'dependencies'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  var sdk = await FlutterSdkPath.findSdk();
  if (sdk == null) {
    stderr.writeln("Run this through a Flutter SDK's dart: fvm dart run …");
    exit(1);
  }

  var live = LiveDependencySource();
  var pubspecText = await live.pubspecText(project);
  var pubDepsJson = await PubDeps.loadJson(
    flutterExecutable: sdk.flutter,
    directory: project,
  );
  var lockFile = PubspecLock.findFile(project);
  var lockText = lockFile?.readAsStringSync();
  var packageConfig = await findPackageConfig(Directory(project));
  if (packageConfig == null) {
    throw StateError('No package config above $project — run pub get.');
  }

  // The walk the panel does, over the live source, so what is kept is
  // exactly the set of packages the panel will ask about.
  var resolved = Dependencies.resolve(
    pubspec: Pubspec.parse(pubspecText),
    pubDeps: PubDeps.parse(pubDepsJson),
    lock: lockText == null ? null : PubspecLock.parse(lockText),
    packageConfig: packageConfig,
    readPubspec: live.dependencyPubspec,
    source: live,
  );

  var packages = <String, Object?>{};
  var withPubDev = 0;
  for (var dependency in resolved.dependencies) {
    var root = dependency.rootPath;
    if (root == null) continue;
    var recordedRoot = '$recordedDependencyRoot/${dependency.name}';
    var documents = <String, String>{};
    for (var candidates in const [
      ['README.md', 'readme.md', 'README'],
      ['CHANGELOG.md', 'changelog.md', 'CHANGELOG'],
    ]) {
      if (await live.document(root, candidates) case var found?) {
        documents[found.name] = found.text;
      }
    }
    var pubDev = await live.pubDev(dependency.name);
    if (pubDev != null) withPubDev++;
    packages[recordedRoot] = {
      'name': dependency.name,
      'pubspec': File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
      'documents': documents,
      'cloc': (await live.cloc(root)).toJson(),
      'size': (await live.size(root)).toJson(),
      'pubDev': pubDev?.toJson(),
    };
  }

  // The config, re-rooted: only the packages the walk kept, each at the
  // directory the recording files it under.
  var config = {
    'configVersion': 2,
    'packages': [
      for (var dependency in resolved.dependencies)
        if (dependency.rootPath != null)
          {
            'name': dependency.name,
            'rootUri': 'file://$recordedDependencyRoot/${dependency.name}/',
            'packageUri': 'lib/',
            'languageVersion': ?packageConfig[dependency.name]?.languageVersion
                ?.toString(),
          },
    ],
  };

  var scores = await live.pubScores();
  var names = {for (var dependency in resolved.dependencies) dependency.name};
  var scoresJson = {
    'packages': {
      for (var name in names)
        if (scores[name] case var score?) name: score.toJson(),
    },
  };

  var imports = await live.packageImports(project);
  live.dispose();

  var file = File(p.join(out, recordedDependenciesPath(packagePath)))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'pubspec': pubspecText, 'lock': lockText, 'pubDeps': pubDepsJson, 'packageConfig': config, 'packages': packages, 'pubScores': scoresJson, 'imports': imports.toJson()})}\n',
    );
  return 'a resolution of ${packages.length} packages '
      '(${resolved.directs.length} direct, $withPubDev on pub.dev), '
      '${(file.lengthSync() / 1024).toStringAsFixed(0)} KB';
}

/// What the splash scan reads, as it read it.
///
/// The real scan, run over the disk through a [RecordingSplashFiles] that
/// remembers every path it touched: afterwards the recording holds exactly
/// those files, at their own relative paths, and the listing of every
/// directory it walked. The fingerprint is run too, since the core takes it
/// after every scan and it stats a few more paths. Times are pinned — a
/// checkout gives every file the same time anyway, and a recording that
/// changes with the checkout is one CI cannot check.
String _recordSplash({required String project, required String out}) {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'splash'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  var files = RecordingSplashFiles();
  var scan = scanSplash(
    packageRoot: project,
    packagePath: packagePath,
    files: files,
  );
  splashFingerprint(packageRoot: project, scan: scan, files: files);

  String relative(String path) =>
      p.relative(path, from: project).replaceAll(r'\', '/');

  var index = <String, Object?>{};
  var bytes = 0;
  for (var path in files.files.toList()..sort()) {
    if (!p.isWithin(project, path)) continue;
    var rel = relative(path);
    var target = File(p.join(out, recordedSplashFilePath(packagePath, rel)))
      ..parent.createSync(recursive: true);
    File(path).copySync(target.path);
    bytes += target.lengthSync();
    index[rel] = {
      'size': target.lengthSync(),
      // The config before its output, so the scan reads the output as
      // current rather than stale — which is what a fresh checkout says too.
      'modified':
          (rel == 'pubspec.yaml' || rel.startsWith('flutter_native_splash')
                  ? pinnedClockOrigin.subtract(const Duration(hours: 1))
                  : pinnedClockOrigin)
              .toIso8601String(),
    };
  }
  var directories = <String, Object?>{};
  for (var entry in files.directories.entries) {
    if (!p.isWithin(project, entry.key) && !p.equals(project, entry.key)) {
      continue;
    }
    directories[relative(entry.key)] = switch (entry.value) {
      null => null,
      var entries => [
        for (var e in entries)
          if (p.isWithin(project, e)) relative(e),
      ]..sort(),
    };
  }
  File(p.join(out, recordedSplashIndexPath(packagePath)))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'files': index, 'directories': directories})}\n',
    );
  return 'a splash scan of ${scan.configs.length} configs, '
      '${index.length} files, ${directories.length} directories, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// [text] with every absolute path under [project] spelled under the
/// recorded project's root instead — the workspace above it too, for the
/// paths that reach into it.
String _reroot(String text, String project) => text
    .replaceAll(project, recordedProjectRoot)
    .replaceAll(p.dirname(p.dirname(project)), '$recordedProjectRoot/..');

/// The step fields that name a file — the ones `ScenarioRunStep.locate`
/// rewrites, and the ones `RecordedScenarioRunner` puts back under the
/// recorded root.
const _stepPathFields = [
  'image',
  'tree',
  'file',
  'keys',
  'semantics',
  'events',
  'frames',
];

/// The default scan and one per flavor, with the files copied flat.
String _recordLauncherIcons({required String project, required String out}) {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'launcher_icon'));
  // Generated wholesale: a flavor that no longer exists would otherwise leave
  // its scan behind, and the recording would claim it.
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  var flavors = <String?>[
    null,
    for (var flavor in discoverIconFlavors(project)) flavor.name,
  ];
  var copied = <String, int>{};
  for (var flavor in flavors) {
    var scan = scanIcons(
      packageRoot: project,
      packagePath: packagePath,
      flavor: flavor,
    );
    var json = scan.toJson();
    for (var role in json['roles']! as List) {
      for (var file in ((role as Map)['files'] as List? ?? const [])) {
        var entry = file as Map;
        var source = File(entry['absolutePath']! as String);
        var destination = recordedIconFilePath(
          packagePath,
          entry['path']! as String,
        );
        if (!copied.containsKey(destination)) {
          var target = File(p.join(out, destination))
            ..parent.createSync(recursive: true);
          source.copySync(target.path);
          copied[destination] = source.lengthSync();
        }
        entry['absolutePath'] = destination;
        // A recording carries no clock. The file's mtime is whatever the last
        // checkout set it to, which would make the same project record
        // differently on every machine — and CI checks that re-recording
        // changes nothing. The panel never draws it; the inventory action
        // reports it, and reports the pinned instant everything else renders
        // at.
        entry['modified'] = pinnedClockOrigin.toIso8601String();
      }
    }
    File(p.join(out, recordedIconScanPath(packagePath, flavor: flavor)))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );
  }

  var bytes = copied.values.fold(0, (sum, length) => sum + length);
  return '${flavors.length} launcher icon scans '
      '(${flavors.skip(1).join(', ')}), ${copied.length} files, '
      '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// The orders server's ring, as an attachment received it.
///
/// A real inspector in a temp run dir, the scripted traffic reported into
/// it, one attachment over the real socket — then everything the attachment
/// holds is written down: hello, events, the details behind each event, and
/// the answers to the two SQL commands. Times are re-rooted to
/// [pinnedClockOrigin] and spaced evenly, and the identity is the recorded
/// project's, so the file is the same on every machine.
Future<String> _recordServer({required String out}) async {
  const packagePath = '.';
  const name = 'orders';
  var dir = Directory(p.join(out, 'server'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);

  // Short paths on purpose: a unix socket path is capped at 104 bytes, and
  // the macOS temp directory alone spends most of that.
  var scratch = Directory('/tmp').existsSync()
      ? Directory('/tmp')
      : Directory.systemTemp;
  var runDir = scratch.createTempSync('fwrec-run-');
  var projectRoot = scratch.createTempSync('fwrec-srv-');
  var inspector = ServerInspector.start(
    runDir: runDir.path,
    projectRoot: projectRoot.path,
    name: name,
    pid: 4242,
  );
  // The recorder stands where a test does: one inspector, attached by hand.
  // ignore: invalid_use_of_visible_for_testing_member
  FlutterwareServer.debugAttachInspector(inspector);
  try {
    await inspector.published;
    playOrdersServer();
    var handle = scanServerHandles(runDir.path).single;
    var client = await ServerAttachClient.connect(handle);
    try {
      var deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!client.replayComplete && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      var events = client.received;
      var details = <String, Map<String, Object?>>{};
      for (var event in events) {
        var fetched = await client.details(event.id);
        if (fetched != null) details['${event.id}'] = fetched;
      }
      var answers = <String, Map<String, Object?>>{
        for (var method in ['explain', 'requery'])
          'sql/$method': await client.request('sql', method, {
            'query': ordersByCustomerQuery,
            'params': [7],
          }),
      };
      var startedAt = pinnedClockOrigin.subtract(const Duration(minutes: 3));
      var json = {
        'handle': {
          'projectRoot': recordedProjectRoot,
          'name': name,
          'socketPath': '$recordedProjectRoot/.dart_tool/$name.sock',
          'pid': handle.pid,
          'startedAt': startedAt.toIso8601String(),
          'baseUrl': handle.baseUrl,
          'environment': handle.environment,
        },
        'hello': {
          'name': client.hello.name,
          'pid': client.hello.pid,
          'projectRoot': recordedProjectRoot,
          'startedAt': startedAt.toIso8601String(),
          'channels': client.hello.channels,
          'eventCount': client.hello.eventCount,
        },
        'events': [
          for (var (i, event) in events.indexed)
            {
              'id': event.id,
              'channel': event.channel,
              'time': pinnedClockOrigin
                  .add(Duration(milliseconds: 350 * i))
                  .toIso8601String(),
              if (event.rid != null) 'rid': event.rid,
              'payload': event.payload,
            },
        ],
        'details': details,
        'answers': answers,
      };
      File(p.join(out, recordedServerPath(packagePath, name)))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(json)}\n',
        );
      File(p.join(out, recordedServerIndexPath(packagePath))).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
          'servers': [name],
        })}\n',
      );
      return '1 server ($name): ${events.length} events, '
          '${details.length} with details, ${answers.length} answers';
    } finally {
      await client.close();
    }
  } finally {
    await inspector.stop();
    // ignore: invalid_use_of_visible_for_testing_member
    await FlutterwareServer.reset();
    for (var d in [runDir, projectRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  }
}

/// The dev stack's script, as answers: what it prints for each verb, in
/// each state. No script runs — `tool/demo/stack_traffic.dart` is the
/// output a run would have left, and the core reads it through the same
/// parser it reads a spawned script with.
String _recordStack({required String out}) {
  const packagePath = '.';
  var dir = Directory(p.join(out, 'stack'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  var answers = recordedStackAnswers();
  File(p.join(out, recordedStackPath(packagePath)))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'state': 'up', 'answers': answers})}\n',
    );
  return '1 stack: ${answers.length} answers';
}
