import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

/// Where a project declares its plugins, relative to a worktree root.
const configFilePath = 'tool/flutterware.dart';

/// Thrown when the config file exists but could not be turned into a manifest.
class ManifestLoadException implements Exception {
  ManifestLoadException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() =>
      details == null ? message : '$message\n${details!.trimRight()}';
}

/// Runs a worktree's `tool/flutterware.dart` and parses what it prints.
///
/// Still a plain `dart run` model — no resident compiler, no long-lived config
/// process — with the compile step memoised on disk. A `.dill` beside
/// `package_config.json` holds no state and is re-derived whenever either
/// input moves.
///
/// It is worth the file. Measured, `dart run tool/flutterware.dart` costs
/// 510–590ms while the same file precompiled costs 70–80ms — which is the bare
/// VM floor, so the config's *own* work is unmeasurable and effectively all of
/// that half-second was `dart run` resolving and JIT-compiling 29 lines. Since
/// every `fw` invocation opens a session, it was most of the cost of every
/// command.
class ManifestLoader {
  ManifestLoader({
    required this.dartExecutable,
    this.flutterRoot,
    this.timeout = const Duration(seconds: 30),
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    })?
    runProcess,
    // ignore: prefer_initializing_formals
  }) : _runProcess = runProcess;

  /// The `dart` to run — the SDK pinned by the project, not whatever is on PATH.
  final String dartExecutable;

  /// The Flutter SDK root, exported as `FLUTTER_ROOT` while the config runs.
  ///
  /// `dart run` resolves an unresolved workspace before running — which is
  /// every fresh worktree's first load — and satisfying a `flutter from sdk`
  /// dependency during that resolve needs the root spelled out: the SDK's own
  /// `bin/dart` does not export it, and without it the load dies with "the
  /// Flutter SDK is not available" about a project whose SDK discovery just
  /// succeeded. On a resolved worktree it changes nothing.
  final String? flutterRoot;

  /// How long the config gets before it is killed and reported.
  ///
  /// A config is user code and can hang — an accidental infinite loop, a
  /// read from stdin, an `await` on something that never arrives. Without a
  /// deadline that is not a slow reload, it is a permanent one: `fw` waits at
  /// the terminal forever, and in the GUI the watcher treats a reload as still
  /// in flight and folds every later save into it, so even the save that
  /// *fixes* the file does nothing. Generous against a file that normally takes
  /// ~50ms, because being wrong in the other direction kills a config that was
  /// merely doing something slow.
  final Duration timeout;

  /// How long the `dart run` fallback gets, which is a different question.
  ///
  /// A constant rather than a knob: nothing has ever wanted to move it, and
  /// the fakes several tests build over this class would each grow a member
  /// for the privilege.
  ///
  /// That path is taken when there is no usable kernel — a fresh checkout, a
  /// changed SDK — and `dart run` does two things before the config's own 50ms:
  /// it resolves the workspace if pub has not, and it runs the build hooks of
  /// every dependency that ships one. Measured on a project that loads a 3D
  /// model, the hooks alone were **49.9s** the first time on a machine. Under
  /// the 30s budget that is a config killed for doing exactly what it was
  /// supposed to, with a message about infinite loops — and on CI, where the
  /// pub cache is empty every run, it is killed every run.
  ///
  /// So: generous, and bounded anyway, because a config that hangs still has to
  /// be reported rather than waited on forever. Five minutes is
  /// `package:hooks_runner`'s own per-hook ceiling.
  static const _firstRunTimeout = Duration(minutes: 5);

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  })?
  _runProcess;

  Future<ProcessResult> _run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? deadline,
    String? slowHint,
  }) =>
      _runProcess?.call(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      ) ??
      _spawn(
        executable,
        arguments,
        workingDirectory,
        deadline ?? timeout,
        slowHint,
      );

  /// `Process.run` with a deadline.
  ///
  /// It has to be `Process.start`: `Process.run` returns a future that cannot be
  /// cancelled, so timing it out would leave the child alive — and a runaway
  /// config would then accumulate one orphaned process per save.
  Future<ProcessResult> _spawn(
    String executable,
    List<String> arguments,
    String? workingDirectory,
    Duration deadline,
    String? slowHint,
  ) async {
    var process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {'FLUTTER_ROOT': ?flutterRoot},
    );
    var stdout = process.stdout.transform(utf8.decoder).join();
    var stderr = process.stderr.transform(utf8.decoder).join();
    try {
      var exitCode = await process.exitCode.timeout(deadline);
      return ProcessResult(process.pid, exitCode, await stdout, await stderr);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      // Nobody will await these now, and an abandoned future that completes
      // with an error is an unhandled async error — a test failure under
      // `flutter test`, a crash report in the app. SIGKILL can cut a multi-byte
      // sequence in half and `utf8.decoder` is strict, so this is reachable
      // rather than theoretical. Whatever they were going to say, the exception
      // below says it better.
      unawaited(stdout.then((_) {}, onError: (_) {}));
      unawaited(stderr.then((_) {}, onError: (_) {}));
      throw ManifestLoadException(
        '$configFilePath did not finish within ${deadline.inSeconds}s and was '
        'killed.',
        details:
            slowHint ??
            'A config is expected to print its manifest and exit. Check for a '
                'loop, a read from stdin, or an await that never completes.',
      );
    }
  }

  /// Returns the worktree's manifest, or null when it declares no config file.
  ///
  /// Throws [ManifestLoadException] when the file exists but fails — a broken
  /// config must be reported, never quietly treated as "no plugins".
  Future<PluginManifest?> load(String worktreePath) async {
    var configFile = File(p.join(worktreePath, configFilePath));
    if (!configFile.existsSync()) return null;

    var result = await _runConfig(worktreePath, configFile);

    if (result.exitCode != 0) {
      throw ManifestLoadException(
        '$configFilePath exited with ${result.exitCode}.',
        details: '${result.stderr}',
      );
    }

    // The dart tool writes its own chatter to stderr, so stdout is the
    // manifest and nothing else.
    var stdout = (result.stdout as String).trim();
    if (stdout.isEmpty) {
      throw ManifestLoadException(
        '$configFilePath printed nothing. It must call Flutterware.configure.',
      );
    }
    try {
      return PluginManifest.parse(stdout);
    } on FormatException catch (e) {
      throw ManifestLoadException(
        'Could not read the manifest from $configFilePath.',
        details: '$e',
      );
    }
  }

  /// Runs the config, through its cached kernel when there is a good one.
  ///
  /// A kernel that will not load — most often one compiled by a different SDK
  /// — must not be reported as a broken config file, so a non-zero exit
  /// invalidates the cache and falls back to `dart run` before anything is
  /// blamed on the user. The config only prints a manifest, so running it
  /// twice on the error path costs a second and changes nothing.
  Future<ProcessResult> _runConfig(String worktreePath, File configFile) async {
    if (await _kernel(worktreePath, configFile) case var kernel?) {
      var result = await _run(dartExecutable, [
        kernel,
      ], workingDirectory: worktreePath);
      if (result.exitCode == 0) return result;
      _invalidate(worktreePath);
    }
    return _run(
      dartExecutable,
      ['run', configFilePath],
      workingDirectory: worktreePath,
      deadline: _firstRunTimeout,
      slowHint:
          'This was the first run for this checkout, so `dart run` was also '
          'resolving the workspace and running the build hooks of every '
          'dependency that has one. A package that generates shaders can take '
          'minutes the first time on a machine. If that does not explain it, '
          'check the config for a loop, a read from stdin, or an await that '
          'never completes.',
    );
  }

  /// A path to an up-to-date kernel of the config file, or null to use
  /// `dart run` — which is what happens when the project has not been resolved
  /// yet, or when compiling fails for a reason the fallback will report better.
  ///
  /// Keyed on the config file, the package resolution, and which `dart` is
  /// doing the compiling. The first two are what change the output; the third
  /// is there because an fvm switch changes the SDK without touching either —
  /// `package_config.json` names a `flutterRoot`, but only as of whenever pub
  /// last ran, so switching without resolving would otherwise go unnoticed.
  ///
  /// Keyed on content, not mtime. `pub get` rewrites
  /// `package_config.json` whether or not resolution moved, and the
  /// Dependencies plugin runs `pub get` itself — so a stat-based key made
  /// *using* flutterware invalidate flutterware's own cache, and every
  /// following command paid the ~450ms compile again. Content survives that,
  /// and survives a checkout or a stash that restores a file byte for byte.
  ///
  /// Keyed on the whole compiled closure, not just the config file.
  /// `dart compile kernel` bundles every library the config reaches, so a key
  /// naming only `tool/flutterware.dart` went stale the moment a declaration
  /// moved in a file it imports — and the config would then keep reporting the
  /// old manifest, which the reload machinery reads as "no changes". A stale
  /// answer that says *nothing changed* is the one failure this whole feature
  /// cannot tolerate, and content keying made it permanent rather than
  /// transient: nothing else would ever invalidate it.
  ///
  /// `--depfile` is the compiler's own answer to "what did this depend on", so
  /// the key is derived from the build rather than guessed alongside it.
  /// Measured on this repo: 46 inputs, 0.7ms to hash.
  Future<String?> _kernel(String worktreePath, File configFile) async {
    var packageConfig = File(
      p.join(worktreePath, '.dart_tool', 'package_config.json'),
    );
    if (!packageConfig.existsSync()) return null;

    var dill = File(p.join(_cacheDir(worktreePath), 'manifest.dill'));
    var stampFile = File(p.join(_cacheDir(worktreePath), 'manifest.stamp'));
    var depFile = File(p.join(_cacheDir(worktreePath), 'manifest.deps'));

    // The previous compile's own dependency list. A closure that *grew* — a new
    // import — is caught anyway, because adding the import changed the config
    // file, which is in the list.
    if (dill.existsSync() && stampFile.existsSync() && depFile.existsSync()) {
      var stamp = _stamp(worktreePath, packageConfig, depFile);
      if (stamp != null && stampFile.readAsStringSync() == stamp) {
        return dill.path;
      }
    }

    Directory(_cacheDir(worktreePath)).createSync(recursive: true);
    var compiled = await _run(dartExecutable, [
      'compile',
      'kernel',
      '-o',
      dill.path,
      '--depfile',
      depFile.path,
      configFilePath,
    ], workingDirectory: worktreePath);
    if (compiled.exitCode != 0) return null;

    var stamp = _stamp(worktreePath, packageConfig, depFile);
    if (stamp == null) return dill.path; // Usable now, recompiled next time.
    stampFile.writeAsStringSync(stamp);
    return dill.path;
  }

  /// A hash over every source the last compile read, plus the resolution and
  /// the compiler. Null when the dependency list cannot be read, which means
  /// "do not trust the cache" rather than "the cache is fine".
  String? _stamp(String worktreePath, File packageConfig, File depFile) {
    List<String> inputs;
    try {
      inputs = _depfileInputs(depFile.readAsStringSync());
    } on FileSystemException {
      return null;
    }
    if (inputs.isEmpty) return null;

    var parts = <String>[];
    for (var input in inputs..sort()) {
      var file = File(
        p.isAbsolute(input) ? input : p.join(worktreePath, input),
      );
      if (!file.existsSync()) return null;
      parts.add('$input ${sha1.convert(file.readAsBytesSync())}');
    }
    parts
      ..add('${sha1.convert(packageConfig.readAsBytesSync())}')
      ..add(dartExecutable);
    return '${sha1.convert(utf8.encode(parts.join('\n')))}';
  }

  /// The inputs from a Ninja depfile: `output: in1 in2 \<newline> in3`, with
  /// spaces in paths backslash-escaped.
  static List<String> _depfileInputs(String source) {
    var colon = source.indexOf(':');
    if (colon < 0) return const [];
    var body = source
        .substring(colon + 1)
        .replaceAll('\\\n', ' ')
        .replaceAll('\n', ' ');

    var inputs = <String>[];
    var current = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      var char = body[i];
      if (char == r'\' && i + 1 < body.length && body[i + 1] == ' ') {
        current.write(' ');
        i++;
      } else if (char == ' ') {
        if (current.isNotEmpty) inputs.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(char);
      }
    }
    if (current.isNotEmpty) inputs.add(current.toString());
    return inputs;
  }

  void _invalidate(String worktreePath) {
    var stampFile = File(p.join(_cacheDir(worktreePath), 'manifest.stamp'));
    if (stampFile.existsSync()) stampFile.deleteSync();
  }

  static String _cacheDir(String worktreePath) =>
      p.join(worktreePath, '.dart_tool', 'flutterware');

  /// Convenience for callers that would rather render an error than catch.
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String worktreePath,
  ) async {
    try {
      return (manifest: await load(worktreePath), error: null);
    } on ManifestLoadException catch (e) {
      return (manifest: null, error: '$e');
    }
  }
}

/// Decodes a manifest already captured as text (used by tests and by the CLI,
/// which may have run the config itself).
PluginManifest parseManifest(String source) =>
    PluginManifest.fromJson(jsonDecode(source) as Map<String, Object?>);
