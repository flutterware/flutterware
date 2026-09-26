import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';
import 'compiler.dart';
import 'flutter_cache.dart';

/// Where the embedder engine for [revision] lives: once per machine, under
/// `~/.flutterware/engine/<revision>/`.
///
/// Not under the package. It used to be `<appPackageRoot>/.engine`, and a
/// hosted install unpacks `app/` per project — under
/// `~/.flutterware/<sha1(packageRoot)>/` — so every project downloaded and kept
/// its own copy of a 93MB artifact that depends on nothing but the engine
/// revision. Keyed by revision here, so switching Flutter versions back and
/// forth reuses what is already on disk instead of re-downloading each way.
///
/// Keyed by revision alone and not by host, because a machine is one host. What
/// lands inside differs per host — a `FlutterEmbedder.framework` on macOS, a
/// `libflutter_engine.so` elsewhere — which is what [embedderEngineMarker]
/// names.
String embedderEngineDir(String revision) =>
    p.join(flutterwareDir(), 'engine', revision);

/// The file whose presence means [embedderEngineDir] holds a complete engine.
///
/// Also the thing CMake links against, so the two halves cannot drift: if this
/// is there, `native/CMakeLists.txt` has what it needs.
String embedderEngineMarker(String engineDir) => Platform.isMacOS
    ? p.join(engineDir, 'FlutterEmbedder.framework')
    : p.join(engineDir, 'libflutter_engine.so');

/// Reclaims the per-package copy this used to keep at `<appPackageRoot>/.engine`.
///
/// 93MB per project, and after the move to [embedderEngineDir] nothing reads
/// it — so without this, every install that ever ran the old code keeps a copy
/// forever, in a directory named with a leading dot that nobody will think to
/// look in.
///
/// Deletes only on proof that the directory is ours: the `engine.revision`
/// stamp beside a `FlutterEmbedder.framework`, which is exactly what the old
/// code wrote and nothing else has reason to. A `.engine` that is somebody
/// else's is left alone.
void removeLegacyEngineDir(String appPackageRoot) {
  var legacy = Directory(p.join(appPackageRoot, '.engine'));
  if (!legacy.existsSync()) return;
  if (!File(p.join(legacy.path, 'engine.revision')).existsSync()) return;
  if (!Directory(p.join(legacy.path, 'FlutterEmbedder.framework'))
      .existsSync()) {
    return;
  }
  try {
    legacy.deleteSync(recursive: true);
    stdout.writeln(
      '[embedder] removed the per-package engine copy at ${legacy.path}; '
      'it is shared under ${p.dirname(embedderEngineDir(''))} now',
    );
  } catch (e) {
    // A cache we no longer read. Failing to reclaim it is not worth an error.
    stderr.writeln('[embedder] could not remove ${legacy.path}: $e');
  }
}

/// Ensures the embedder engine (the C embedder API, not part of the local
/// Flutter cache) is on disk for the running engine revision, downloading it
/// from Flutter's artifact storage if it is not, and answers with the directory
/// holding it — what `buildHost` takes as its `engineDir`.
///
/// Callers no longer choose the location: two of them choosing differently is
/// how the same artifact came to be downloaded once per project.
///
/// The artifact is one file per host with two shapes. macOS ships
/// `FlutterEmbedder.framework.zip`, a bundle that has to unzip *into* a
/// directory of that name; every other host ships `<host>-embedder.zip`, which
/// already holds `libflutter_engine.so` and a header at its top level and so
/// unzips flat. [embedderEngineMarker] is what says which one landed.
Future<String> ensureEmbedderEngine(FlutterCache cache) async {
  var revision = cache.engineRevision;
  var engineDir = embedderEngineDir(revision);
  if (_isComplete(engineDir, revision)) return engineDir;

  var host = cache.hostPlatform;
  var archive = Platform.isMacOS
      ? 'FlutterEmbedder.framework.zip'
      : '$host-embedder.zip';
  stdout.writeln('[embedder] downloading $archive ($host, $revision)');

  // Downloaded beside the target and moved into place, never into it. Two
  // projects' daemons can start at once, and a half-unzipped directory that
  // already has its final name is one the other process will happily link
  // against. The stamp is written before the move, so what appears at
  // [engineDir] is complete the moment it exists.
  var staging = Directory('$engineDir.incoming.$pid');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);
  try {
    var url =
        'https://storage.googleapis.com/flutter_infra_release/flutter/'
        '$revision/$host/$archive';
    var zip = p.join(staging.path, archive);
    await _run('curl', ['-fSL', url, '-o', zip]);
    await _run('unzip', [
      '-q',
      '-o',
      zip,
      '-d',
      Platform.isMacOS
          ? p.join(staging.path, 'FlutterEmbedder.framework')
          : staging.path,
    ]);
    File(zip).deleteSync();
    File(p.join(staging.path, 'engine.revision')).writeAsStringSync(revision);

    Directory(p.dirname(engineDir)).createSync(recursive: true);
    try {
      staging.renameSync(engineDir);
    } on FileSystemException {
      // Another process got there first, or something stale is in the way.
      // Theirs is as good as ours if it passes the same test we would have
      // returned on; otherwise it is ours to replace.
      if (!_isComplete(engineDir, revision)) {
        if (Directory(engineDir).existsSync()) {
          Directory(engineDir).deleteSync(recursive: true);
        }
        staging.renameSync(engineDir);
      }
    }
  } finally {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }
  return engineDir;
}

/// Whether [engineDir] holds a usable engine for [revision] *on this host*.
///
/// The stamp alone is not that, and believing it was cost a whole afternoon:
/// this directory is keyed by revision and not by host, so the first Linux run
/// on a machine that had ever run the macOS code found a stamped, complete
/// `FlutterEmbedder.framework` sitting at the path it wanted, downloaded the
/// Linux engine, declined to replace what was there, and handed the linker a
/// directory with no `libflutter_engine.so` in it.
bool _isComplete(String engineDir, String revision) {
  var stamp = File(p.join(engineDir, 'engine.revision'));
  return FileSystemEntity.typeSync(embedderEngineMarker(engineDir)) !=
          FileSystemEntityType.notFound &&
      stamp.existsSync() &&
      stamp.readAsStringSync().trim() == revision;
}

/// Compiles the embedder scene at [scenePath] to a kernel blob at [kernelBlob].
Future<void> compileScene({
  required String scenePath,
  required String kernelBlob,
  required String packageConfig,
  required FlutterCache cache,
}) async {
  stdout.writeln('[embedder] compiling ${p.basename(scenePath)} -> kernel');
  await compileToKernel(
    entrypoint: scenePath,
    outputDill: kernelBlob,
    packageConfig: packageConfig,
    cache: cache,
  );
}

/// Configures and builds the C host with CMake into [nativeBuildDir].
/// Returns the path to the built `host` executable.
///
/// [quiet] says nothing unless CMake fails — for a caller that builds the
/// host on every open, where CMake finding nothing to do is not news.
Future<String> buildHost({
  required String nativeSourceDir,
  required String nativeBuildDir,
  required String engineDir,
  bool quiet = false,
}) async {
  if (!quiet) stdout.writeln('[embedder] configuring + building the C host');
  await _run('cmake', [
    '-S',
    nativeSourceDir,
    '-B',
    nativeBuildDir,
    '-DFLUTTER_ENGINE_DIR=$engineDir',
  ], quiet: quiet);
  await _run('cmake', ['--build', nativeBuildDir], quiet: quiet);
  return p.join(nativeBuildDir, 'host');
}

/// Resolves [name] without relying on `PATH`.
///
/// A desktop app launched by `flutter run` inherits a stripped environment, so
/// `cmake` is not findable by name even when a terminal finds it fine. This is
/// how macOS behaves; the fallback list carries the places each host installs
/// the two tools this file spawns.
String resolveExecutable(String name) {
  var fromPath = Process.runSync('/usr/bin/which', [name]);
  if (fromPath.exitCode == 0) {
    var resolved = (fromPath.stdout as String).trim();
    if (resolved.isNotEmpty) return resolved;
  }
  for (var dir in const [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
    '/Applications/CMake.app/Contents/bin',
  ]) {
    var candidate = p.join(dir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError(
    'Could not find "$name". It is needed to build the embedder guest, and an '
    'app launched by `flutter run` does not inherit your shell PATH.',
  );
}

Future<void> _run(
  String executable,
  List<String> args, {
  bool quiet = false,
}) async {
  if (quiet) {
    var result = await Process.run(resolveExecutable(executable), args);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        args,
        'exited with ${result.exitCode}:\n${result.stdout}${result.stderr}',
        result.exitCode,
      );
    }
    return;
  }
  var process = await Process.start(
    resolveExecutable(executable),
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  var code = await process.exitCode;
  if (code != 0) {
    throw ProcessException(executable, args, 'exited with $code', code);
  }
}
