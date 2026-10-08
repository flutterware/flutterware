import 'dart:convert';
import 'dart:io';

import 'package:flutterware/render_client.dart';
// ignore: implementation_imports
import 'package:flutterware/src/render/bundle_entrypoint.dart';
import 'package:path/path.dart' as p;

import '../embedder/compiler.dart';
import '../embedder/flutter_cache.dart';
import '../previews/asset_bundle.dart';
import '../previews/package_config_locator.dart';
import '../utils/run_dir.dart';

/// Builds a render bundle: the one directory a server copies into its image.
///
/// `flutter_tester` + `icudtl.dat` for [platform], the registrar compiled to
/// a kernel, the app's asset bundle (fonts included, symlinks materialized —
/// a symlink into the pub cache is dead the moment the directory leaves this
/// machine), and a manifest binding the versions together.
Future<RenderBundleManifest> buildRenderBundle({
  required String packageRoot,
  required String target,
  required String output,
  required FlutterCache cache,
  String? platform,
  void Function(String line)? log,
}) async {
  void say(String line) => log?.call(line);
  packageRoot = p.absolute(packageRoot);
  var targetFile = File(p.join(packageRoot, target));
  if (!targetFile.existsSync()) {
    throw StateError('no registrar file at $target (from $packageRoot)');
  }
  var source = targetFile.readAsStringSync();
  var registrar = findRenderRegistrarName(source);
  if (registrar == null) {
    throw StateError(
      mentionsRenderRegistrar(source)
          ? '$target has @RenderRegistry(), but the registrar must be a '
                'plain top-level `void` function directly under the '
                'annotation:\n\n'
                '  @RenderRegistry()\n'
                '  void registerRenders(RenderHost host) { ... }'
          : '$target declares no @RenderRegistry() function. Mark the '
                'function that binds your render points:\n\n'
                '  @RenderRegistry()\n'
                '  void registerRenders(RenderHost host) { ... }',
    );
  }

  var outDir = Directory(p.absolute(output))..createSync(recursive: true);

  // The registrar, wrapped in the driver, compiled to a kernel.
  var buildDir = p.join('build', 'flutterware', 'render_bundle');
  Directory(p.join(packageRoot, buildDir)).createSync(recursive: true);
  var entrypoint = File(p.join(packageRoot, buildDir, 'entrypoint.dart'));
  var generated = generateRenderBundleEntrypoint(
    registrarFile: target,
    registrarName: registrar,
    directory: buildDir,
  );
  // Only when the bytes differ: a touched mtime reads as an edit to the
  // compiler's invalidation.
  if (!entrypoint.existsSync() || entrypoint.readAsStringSync() != generated) {
    entrypoint.writeAsStringSync(generated);
  }
  var packageConfig = requirePackageConfig(packageRoot);
  say('compiling $target (registrar: $registrar)');
  var dill = await compileToKernel(
    entrypoint: entrypoint.path,
    outputDill: p.join(packageRoot, buildDir, 'app.dill'),
    packageConfig: packageConfig,
    cache: cache,
  );

  // The asset bundle, fonts included. Built straight into the output, then
  // every symlink replaced by the bytes it points at.
  say('bundling assets and fonts');
  var assetsDir = p.join(outDir.path, 'flutter_assets');
  await AssetBundleBuilder(
    cache: cache,
    rootPackageRoot: packageRoot,
    packageConfigPath: packageConfig,
  ).build(assetsDir);
  _materializeSymlinks(assetsDir);
  var fonts = _fontsFromManifest(assetsDir);

  // Engine artifacts for the target platform: local cache for the host,
  // Flutter's artifact storage for a cross build.
  var targetPlatform = platform ?? cache.hostPlatform;
  String testerSource, icuSource;
  if (targetPlatform == cache.hostPlatform) {
    testerSource = cache.flutterTester;
    icuSource = cache.icuData;
  } else {
    say(
      'fetching flutter_tester for $targetPlatform '
      '(engine ${cache.engineRevision})',
    );
    var artifacts = await ensureTesterArtifacts(cache, targetPlatform);
    testerSource = p.join(artifacts, _testerName(targetPlatform));
    icuSource = p.join(artifacts, 'icudtl.dat');
  }
  var testerName = p.basename(testerSource);
  _copyExecutable(testerSource, p.join(outDir.path, testerName));
  File(icuSource).copySync(p.join(outDir.path, 'icudtl.dat'));
  dill.copySync(p.join(outDir.path, 'app.dill'));

  var manifest = RenderBundleManifest(
    protocol: renderProtocolVersion,
    platform: targetPlatform,
    engineVersion: cache.engineRevision,
    flutterVersion: _flutterVersion(cache),
    tester: testerName,
    icuData: 'icudtl.dat',
    kernel: 'app.dill',
    assets: 'flutter_assets',
    fonts: fonts,
  );
  File(p.join(outDir.path, 'manifest.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
  );
  say('bundle ready: ${outDir.path}');
  return manifest;
}

String _testerName(String platform) =>
    platform.startsWith('windows') ? 'flutter_tester.exe' : 'flutter_tester';

/// Downloads `flutter_tester` + `icudtl.dat` for a platform this machine is
/// not, from the same artifact storage the SDK's own cache comes from.
/// Cached once per machine under `~/.flutterware/tester/<revision>/<platform>`.
Future<String> ensureTesterArtifacts(
  FlutterCache cache,
  String platform,
) async {
  var revision = cache.engineRevision;
  var dir = p.join(flutterwareDir(), 'tester', revision, platform);
  var testerName = _testerName(platform);
  if (File(p.join(dir, testerName)).existsSync() &&
      File(p.join(dir, 'icudtl.dat')).existsSync()) {
    return dir;
  }

  // Downloaded beside the target and moved into place, never into it — the
  // same discipline as the embedder engine download.
  var staging = Directory('$dir.incoming.$pid');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);
  try {
    var url =
        'https://storage.googleapis.com/flutter_infra_release/flutter/'
        '$revision/$platform/artifacts.zip';
    var zip = p.join(staging.path, 'artifacts.zip');
    await _run('curl', ['-fSL', url, '-o', zip]);
    await _run('unzip', ['-q', '-o', zip, '-d', staging.path]);
    File(zip).deleteSync();
    var tester = File(p.join(staging.path, testerName));
    if (!tester.existsSync()) {
      throw StateError('the $platform artifacts at $url hold no $testerName');
    }
    if (!Platform.isWindows) {
      await _run('chmod', ['+x', tester.path]);
    }

    Directory(p.dirname(dir)).createSync(recursive: true);
    try {
      staging.renameSync(dir);
    } on FileSystemException {
      // Another process got there first; theirs is as good as ours.
      if (!File(p.join(dir, testerName)).existsSync()) rethrow;
    }
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
  return dir;
}

Future<void> _run(String executable, List<String> arguments) async {
  ProcessResult result;
  try {
    result = await Process.run(executable, arguments);
  } on ProcessException catch (e) {
    throw StateError(
      '`$executable` could not be run ($e). Fetching cross-platform engine '
      'artifacts needs curl and unzip on this machine.',
    );
  }
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed '
      '(${result.exitCode}):\n${result.stderr}',
    );
  }
}

void _copyExecutable(String from, String to) {
  // A fresh inode on purpose: macOS caches code signatures per vnode, and a
  // signed binary overwritten in place is SIGKILLed at its next exec — the
  // second `fw render bundle` into the same directory produced a tester the
  // kernel refused to run.
  var target = File(to);
  if (target.existsSync()) target.deleteSync();
  File(from).copySync(to);
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', to]);
  }
}

void _materializeSymlinks(String root) {
  for (var entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is Link) {
      var target = entity.resolveSymbolicLinksSync();
      entity.deleteSync();
      if (FileSystemEntity.isDirectorySync(target)) {
        _copyTree(target, entity.path);
      } else {
        File(target).copySync(entity.path);
      }
    }
  }
}

void _copyTree(String from, String to) {
  Directory(to).createSync(recursive: true);
  for (var entity in Directory(from).listSync(recursive: false)) {
    var name = p.basename(entity.path);
    if (entity is Directory) {
      _copyTree(entity.path, p.join(to, name));
    } else if (entity is File) {
      entity.copySync(p.join(to, name));
    }
  }
}

List<BundleFont> _fontsFromManifest(String assetsDir) {
  var file = File(p.join(assetsDir, 'FontManifest.json'));
  if (!file.existsSync()) return const [];
  var families = jsonDecode(file.readAsStringSync()) as List;
  return [
    for (var family in families.cast<Map>().map(
      (f) => f.cast<String, Object?>(),
    ))
      for (var font in (family['fonts']! as List).cast<Map>().map(
        (f) => f.cast<String, Object?>(),
      ))
        BundleFont(
          family: family['family']! as String,
          path: 'flutter_assets/${font['asset']! as String}',
          bold: ((font['weight'] as num?) ?? 400) >= 600,
          italic: font['style'] == 'italic',
        ),
  ];
}

String _flutterVersion(FlutterCache cache) {
  var versionJson = File(p.join(cache.cacheDir, 'flutter.version.json'));
  if (versionJson.existsSync()) {
    var decoded = jsonDecode(versionJson.readAsStringSync());
    if (decoded is Map && decoded['frameworkVersion'] is String) {
      return decoded['frameworkVersion'] as String;
    }
  }
  var legacy = File(p.join(cache.flutterRoot, 'version'));
  if (legacy.existsSync()) return legacy.readAsStringSync().trim();
  return 'unknown';
}
