import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware_app/src/previews/asset_bundle.dart';
import 'package:flutterware_app/src/previews/package_config_locator.dart';
import 'package:flutterware_app/src/embedder/embedder_build.dart';
import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/protocol.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// Asks whether `flutter build bundle` is actually needed to run the guest.
///
/// Renders the same scene twice — once against a bundle the Flutter tool
/// produced, once against a directory of symlinks assembled here — and compares
/// the rendered frames byte for byte. The scene uses Material icons and text,
/// because fonts are what a hand-assembled bundle is most likely to get wrong.
///
/// ```sh
/// cd app && dart run tool/catalog/bundle_probe.dart
/// ```
Future<void> main() async {
  var packageRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  var repoRoot = p.dirname(packageRoot);
  var cache = FlutterCache.fromRunningSdk();
  var work = Directory(p.join(packageRoot, 'build', 'bundle_probe'))
    ..createSync(recursive: true);

  var scene = File(p.join(work.path, 'scene.dart'))
    ..writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.home_outlined, size: 48),
                Icon(Icons.settings_outlined, size: 48),
                Icon(Icons.table_chart_outlined, size: 48),
              ],
            ),
            SizedBox(height: 24),
            Text('Bundle probe', style: TextStyle(fontSize: 32)),
          ],
        ),
      ),
    ),
  ),
);
''');

  var engineDir = await ensureEmbedderEngine(cache);
  var hostPath = await buildHost(
    nativeSourceDir: p.join(packageRoot, 'native'),
    nativeBuildDir: p.join(packageRoot, 'build', 'catalog', 'native'),
    engineDir: engineDir,
  );

  // A — what the Flutter tool builds.
  var toolDir = p.join(work.path, 'tool_bundle');
  var watch = Stopwatch()..start();
  var built = await Process.run(p.join(cache.flutterRoot, 'bin', 'flutter'), [
    'build',
    'bundle',
    '-t',
    scene.path,
    '--asset-dir',
    toolDir,
  ], workingDirectory: packageRoot);
  if (built.exitCode != 0) {
    stderr.writeln('flutter build bundle failed:\n${built.stderr}');
    exit(1);
  }
  stdout.writeln('flutter build bundle : ${watch.elapsedMilliseconds}ms');

  // B — manifests written, payloads symlinked.
  var fastDir = p.join(work.path, 'fast_bundle');
  watch.reset();
  await AssetBundleBuilder(
    cache: cache,
    rootPackageRoot: packageRoot,
    packageConfigPath: p.join(repoRoot, '.dart_tool', 'package_config.json'),
  ).build(fastDir);
  stdout.writeln('AssetBundleBuilder   : ${watch.elapsedMilliseconds}ms');

  // The same kernel in both, so only the asset half differs.
  await compileScene(
    scenePath: scene.path,
    kernelBlob: p.join(toolDir, 'kernel_blob.bin'),
    packageConfig: requirePackageConfig(packageRoot),
    cache: cache,
  );
  File(p.join(toolDir, 'kernel_blob.bin'))
      .copySync(p.join(fastDir, 'kernel_blob.bin'));

  // The scene never draws the framework shaders, so frame identity cannot
  // vouch for them; their compiled bytes are checked directly instead — but
  // not for equality, which they deliberately no longer have. `flutter build
  // bundle` compiles for one target platform and ships that target's stages;
  // [shaderStages] is the union of every list flutter_tools has, because the
  // file cached here is loaded by a `flutter_tester` on the host's own backend
  // *and* by a Metal guest, and no single target covers both.
  //
  // So the check is the two halves that can still be exact. The tool's bytes
  // have to be reproducible from one of flutter_tools' own stage lists — that
  // is what says the invocation in [compileShader] is faithful, which is all
  // the old byte-for-byte comparison ever established — and ours have to be the
  // union build of the same source, no more and no less.
  var scratch = Directory(p.join(work.path, 'shader_probe'))
    ..createSync(recursive: true);
  for (var source in frameworkShaderSources(cache)) {
    var shader = p.basename(source);
    var tool = File(p.join(toolDir, 'shaders', shader)).readAsBytesSync();
    var fast = File(p.join(fastDir, 'shaders', shader)).readAsBytesSync();

    Future<String?> digestFor(String label, List<String> stages) async {
      var out = p.join(scratch.path, '$label-$shader');
      try {
        await compileShader(
          cache: cache,
          source: source,
          destination: out,
          stages: stages,
        );
      } on StateError {
        // A stage list this impellerc will not take is not this probe's
        // business; it just cannot be the one the tool used.
        return null;
      }
      return _digest(File(out).readAsBytesSync());
    }

    var matched = <String>[];
    for (var target in _toolShaderStages.entries) {
      if (await digestFor(target.key, target.value) == _digest(tool)) {
        matched.add(target.key);
      }
    }
    if (matched.isEmpty) {
      stdout.writeln(
        "shaders/$shader — the tool's ${tool.length} bytes match no "
        'flutter_tools stage list compiled here; the invocation has drifted',
      );
      exit(1);
    }
    stdout.writeln(
      'shaders/$shader — the tool targeted ${matched.join(' or ')}, '
      'reproduced here byte for byte (${tool.length} bytes)',
    );

    var union = await digestFor('union', shaderStages);
    if (union != _digest(fast)) {
      stdout.writeln(
        'shaders/$shader — the bundled ${fast.length} bytes are not the '
        'union build of this source',
      );
      exit(1);
    }
    stdout.writeln(
      'shaders/$shader — bundled as the union of every stage '
      '(${fast.length} bytes, against the tool)',
    );
  }

  var a = await _render(hostPath, toolDir, cache, work.path, 'tool');
  var b = await _render(hostPath, fastDir, cache, work.path, 'fast');

  stdout.writeln('tool bundle frame    : ${a.length} bytes, ${_digest(a)}');
  stdout.writeln('fast bundle frame    : ${b.length} bytes, ${_digest(b)}');

  var identical = a.length == b.length && _digest(a) == _digest(b);
  stdout.writeln(
    identical
        ? '\nIDENTICAL — the symlinked bundle renders exactly the same frame.'
        : '\nDIFFERENT — the symlinked bundle is not equivalent.',
  );
  exit(identical ? 0 : 1);
}

Future<List<int>> _render(
  String hostPath,
  String assetsDir,
  FlutterCache cache,
  String workDir,
  String label,
) async {
  // Under the run dir, not [workDir]: a unix socket path is capped at 104
  // bytes, and a build directory inside a worktree already spends most of
  // that. The hash keeps two checkouts' probes apart.
  var key = sha1.convert(utf8.encode(workDir)).toString().substring(0, 12);
  var socketPath = checkSocketPath(
    p.join(flutterwareRunDir(), 'probe-$key-$label.sock'),
  );
  var rawFrame = p.join(workDir, '$label.rawframe');
  for (var path in [socketPath, rawFrame]) {
    var file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
  var server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );

  // No `--capture-raw`: that arms a one-shot capture the *first* presented
  // frame consumes, which photographs the scene before anything asynchronous
  // — an image decode above all — has landed. Instead the scene gets a moment
  // to settle after its first frame, and then a capture of a current frame is
  // asked for explicitly.
  var guest = await Process.start(hostPath, [
    assetsDir,
    cache.icuData,
    socketPath,
    '800',
    '600',
  ]);
  unawaited(guest.stdout.drain<void>());
  unawaited(guest.stderr.drain<void>());

  var conn = await server.first;
  var reader = FrameReader();
  var sawFrame = Completer<void>();
  var captured = Completer<void>();
  var subscription = conn.listen((chunk) {
    for (var message in reader.addBytes(chunk)) {
      if (message is FrameReadyMessage && !sawFrame.isCompleted) {
        sawFrame.complete();
      }
      if (message is CapturedMessage) captured.complete();
      if (message is ErrorMessage) {
        stderr.writeln('[$label] guest error: ${message.message}');
        guest.kill();
        exit(1);
      }
    }
  });
  await sawFrame.future;
  await Future<void>.delayed(const Duration(seconds: 2));
  conn.add(encodeMessage(CaptureMessage(rawFrame)));
  await conn.flush();
  await captured.future;
  await subscription.cancel();

  conn.add(encodeMessage(const ShutdownMessage()));
  await conn.flush();
  await conn.close();
  await guest.exitCode;
  await server.close();
  var socket = File(socketPath);
  if (socket.existsSync()) socket.deleteSync();
  return File(rawFrame).readAsBytesSync();
}

/// A cheap content fingerprint; the frames are either identical or not.
/// Every stage list `ShaderCompiler` in flutter_tools hands `impellerc`, by the
/// target platforms that select it — `_shaderTargetsFromTargetPlatform`, read
/// from the SDK this repo pins.
///
/// Here so the probe can say *which* target `flutter build bundle` chose rather
/// than assume one: the default has moved before and the answer is worth
/// printing either way.
const _toolShaderStages = {
  'android, linux or windows': [
    '--sksl',
    '--runtime-stage-gles',
    '--runtime-stage-gles3',
    '--runtime-stage-vulkan',
  ],
  'darwin': ['--sksl', '--runtime-stage-metal'],
  'ios': ['--runtime-stage-metal'],
  'tester or fuchsia': ['--sksl', '--runtime-stage-vulkan'],
  'web': ['--sksl'],
};

String _digest(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (var byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
