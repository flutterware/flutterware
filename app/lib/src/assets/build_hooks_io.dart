import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:file/local.dart';
import 'package:hooks_runner/hooks_runner.dart';

export 'package:hooks_runner/hooks_runner.dart'
    show KernelAsset, KernelAssetAbsolutePath, KernelAssets;
import 'package:logging/logging.dart' as logging;
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

final _log = logging.Logger('flutterware.buildHooks');

/// What one [BuildHooks.run] found, so a caller can say something about it.
///
/// [failure] is a sentence, not an exception: a hook is a program a
/// *dependency* ships, and one that fails is closer to a compile error in that
/// dependency than to a broken catalog. Everything that did not need its output
/// still works, so the bundle is built either way and this is reported beside
/// it.
///
/// [nativeAssets] is what the `NativeAssetsManifest.json` the engine reads is
/// made of — the map the VM resolves `@Native` external functions through,
/// with a bundled library still pointing at the hook's own output file.
/// [AssetBundleBuilder] copies those into the bundle and writes the manifest
/// against the copies, so what a guest maps is never a file another tool
/// rewrites. Empty when nothing shipped native code, and always empty after a
/// [failure], because a mapping that names libraries a failed build may not
/// have produced is worse than one that says to look in the process.
typedef BuildHooksResult = ({
  List<String> packages,
  String? failure,
  List<KernelAsset> nativeAssets,
});

/// Runs the `hook/build.dart` a project's dependencies ship, so the files they
/// produce exist before anything goes looking for them.
///
/// A package may generate part of itself at build time — `flutter_scene`
/// compiles its engine's shader bundles this way, and without them it throws
/// on the first frame. Nothing in flutterware ever ran those hooks, and a
/// preview of a 3D scene rendered anyway *because some other build had already
/// run them* and left the output in the shared pub cache. A clean checkout
/// rendered nothing, a developer who had run the app once rendered everything,
/// and neither could tell which they were.
///
/// **We ask for code assets for the machine we are on, and for no data
/// assets.** Each half of that is a decision:
///
/// - Code assets are what a scenario's own dependencies load —
///   `package:sqlite3` resolves `@Native` functions through the mapping this
///   run produces — and the tester lane is the one lane where nobody else
///   builds them: `flutter test` builds them before it spawns a tester, and
///   spawning the tester ourselves means doing the same. Shipping the empty
///   map instead does not even fail honestly, because the VM's process-lookup
///   fallback masks the gap on macOS and only there. The target is the host,
///   the way `flutter test` builds for `TargetPlatform.tester`, because
///   `flutter_tester` *is* a host binary.
/// - No data assets is what `flutter_tools` does on beta and stable, where
///   `dartDataAssets` is not yet a feature. A well-behaved hook answers by
///   writing into its own package directory, which its pubspec declares as an
///   ordinary asset and [AssetBundleBuilder] already ships. Ask for data
///   assets instead and the same hook takes the other branch — output lands
///   beside the package unbundled, and we would have to key and copy every
///   file ourselves to keep what already works working.
///
/// No C compiler is named, deliberately: `flutter test` itself tolerates not
/// finding one for this target (`mustMatchAppBuild: false`), and a hook that
/// compiles C discovers the host toolchain the same way it does under a plain
/// `dart test`. A machine where that discovery fails gets the [failure]
/// sentence and the empty map — which is exactly what it got before this ran
/// hooks at all.
///
/// Measured on a project that loads a `.glb`: **49.9s the first time on a
/// checkout, 110–125ms after that**, and neither number is ours to improve —
/// `package:hooks_runner` caches the run under the checkout's own
/// `.dart_tool`, and the hook caches its own output again inside it. Asking
/// whether there is anything to run at all costs 30ms, which is what a
/// project with no hooks pays and all it pays. A hook that compiles native
/// code now genuinely compiles, and the same cache holds: it is paid once per
/// checkout per resolution, not per bundle. A hook that *fails* is held
/// instead — see [retryHold] — because `hooks_runner` caches no failures and
/// a reload loop must not re-pay a failing native build per tick.
class BuildHooks {
  BuildHooks({
    required this.dartExecutable,
    required this.packageConfigPath,
    required this.rootPackageRoot,
  });

  /// The `dart` that runs each hook — the project's SDK, never PATH's.
  final String dartExecutable;

  final String packageConfigPath;

  /// The package whose dependencies are the ones with hooks. Only its closure
  /// is asked, which is why a workspace sibling's dependency is never built:
  /// `sqlite3` sits in this repo's workspace and is not reachable from the app,
  /// so it is not even in the list.
  final String rootPackageRoot;

  /// Runs in flight or already finished, keyed by [_key].
  ///
  /// Two reasons, and each would be a bug on its own. `hooks_runner` documents
  /// that it does not support reentrancy for an identical input, and two
  /// bundle builds for one workspace are ordinary here. And a warm answer,
  /// while cheap, is not free — a preview reload rebuilds the bundle, and
  /// paying 222ms per reload to re-derive an answer that cannot have moved is
  /// the sort of tax that is never noticed and never removed.
  static final _runs = <String, Future<BuildHooksResult>>{};

  /// The resolution, hashed, plus who is asking about it.
  ///
  /// Content rather than mtime, and the same reason as
  /// [ManifestLoader]: `pub get` rewrites `package_config.json` whether or not
  /// anything moved, and flutterware runs `pub get` itself.
  ///
  /// What this key does *not* notice is a hook's own source changing under a
  /// path dependency. That is a package author editing their own hook, which
  /// no consumer does, and it costs them a restart rather than a wrong answer.
  String? _key() {
    var file = File(packageConfigPath);
    if (!file.existsSync()) return null;
    return '$rootPackageRoot\n${sha1.convert(file.readAsBytesSync())}';
  }

  /// Failures being held, keyed like [_runs]: the result every ask in the
  /// hold is served, and when a retry may begin.
  ///
  /// "A failure must not be remembered" was this class's original rule, and
  /// it was written when a run cost ~40ms: forgetting a failure only meant a
  /// cheap re-ask. Code assets changed the price — a failing run is now a
  /// real native build attempt, `hooks_runner` caches only successes, and
  /// every previews reload rebuilds the bundle — so a machine where the hooks
  /// persistently fail (no network for a download hook, no C toolchain) would
  /// re-pay the whole failing build on every reload, serially, announcing it
  /// each time. So a failure *is* remembered now, but never forever: see
  /// [run] for the retry that clears it.
  static final _heldFailures =
      <String, ({BuildHooksResult result, DateTime retryAt})>{};

  /// How long a failure is held before an ask may kick a retry.
  ///
  /// The number bounds waste and noise, not latency — no caller ever waits on
  /// a retry — so it only has to be long enough that a reload loop ticking
  /// every few seconds is not paying a failing native build each tick, and
  /// short enough that a fixed toolchain is noticed while the fixer is still
  /// looking.
  static const retryHold = Duration(minutes: 1);

  /// Runs whatever hooks this project has, once — and once more per
  /// [retryHold] while they fail.
  ///
  /// A project that has not been resolved yet has no hooks to speak of and no
  /// package config to find them through; it reports nothing rather than
  /// failing, because the caller is about to fail on the resolution itself and
  /// will say so better.
  ///
  /// A held failure is served without waiting: the ask that finds the hold
  /// expired *kicks* a retry and is still answered from the hold, so the cost
  /// of retrying lands on no bundle build — a reload during an outage stays a
  /// reload. Recovery is one build behind by construction: the retry that
  /// succeeds updates the memo, and the next bundle build ships the assets.
  Future<BuildHooksResult> run() {
    var key = _key();
    if (key == null) return Future.value(_nothing);

    if (_heldFailures[key] case var held?) {
      // `_runs` holding the key here *is* the retry in flight — a success
      // would have cleared the hold — so its absence is what makes this ask
      // the one that pays nothing but the kick.
      if (!_runs.containsKey(key) && !clock.now().isBefore(held.retryAt)) {
        _runs[key] = _guarded(key);
      }
      return Future.value(held.result);
    }
    if (_runs[key] case var running?) return running;
    var started = _guarded(key);
    _runs[key] = started;
    return started;
  }

  /// [_run], with the memo settled either way: a success stays in [_runs], a
  /// failure moves to [_heldFailures] with its retry time.
  ///
  /// Nothing may escape as a throw. A retry runs with no caller awaiting it —
  /// that is the whole point — so an exception here would surface as an
  /// unhandled async error instead of a sentence; and the class's own
  /// contract is that a hook problem degrades and the bundle is built either
  /// way, which a throw was already breaking for the resolution-reading edge
  /// cases.
  Future<BuildHooksResult> _guarded(String key) async {
    BuildHooksResult result;
    try {
      result = await _run();
    } on Object catch (e) {
      result = _failed('Build hooks failed: $e');
    }
    if (result.failure case var failure?) {
      unawaited(_runs.remove(key));
      _heldFailures[key] = (
        result: result,
        retryAt: clock.now().add(retryHold),
      );
      _announce(failure);
    } else {
      _heldFailures.remove(key);
    }
    return result;
  }

  /// Says [failure] somewhere a human will actually see it.
  ///
  /// **Both channels, and the second is the one that works.** `Logger.root` is
  /// listened to in `app/lib/main.dart` and nowhere else — not in
  /// `app/bin/fw.dart`, not in the MCP server, not in the previews compiler
  /// daemon, which are between them where most bundles are built. A hook
  /// failure logged there is a hook failure nobody is told about, and what the
  /// reader gets instead is the dependency's own bewildering sentence about
  /// missing shaders.
  ///
  /// So stderr as well, which every one of those processes has and every one
  /// of them forwards. Same escape, and the same reason, as
  /// `announceFlutterGpuDiagnosis`: a failure that will never pass through a
  /// structured report has to take the channel that exists.
  ///
  /// This is why [run]'s result may be discarded by a caller that has nothing
  /// better to do with it.
  void _announce(String failure) {
    _log.severe(failure);
    stderr.writeln('[flutterware] $failure');
  }

  /// Nothing to run, said in the shape a caller expects.
  static const BuildHooksResult _nothing = (
    packages: <String>[],
    failure: null,
    nativeAssets: <KernelAsset>[],
  );

  /// The one shape a failure takes — the sentence, and no native assets. The
  /// invariant [BuildHooksResult] documents, stated once instead of at every
  /// return.
  static BuildHooksResult _failed(
    String failure, {
    List<String> packages = const [],
  }) => (packages: packages, failure: failure, nativeAssets: const []);

  Future<BuildHooksResult> _run() async {
    var fileSystem = const LocalFileSystem();
    var packageConfigUri = File(packageConfigPath).absolute.uri;
    var packageConfig = await loadPackageConfigUri(packageConfigUri);

    var runPackageName = _rootPackageName(packageConfig);
    if (runPackageName == null) {
      // Not `_nothing`. Which packages have hooks is read from the closure of
      // *this* package, so a root the resolution cannot name means no hook is
      // ever asked — and reported as silence that is indistinguishable from a
      // project that genuinely has none. The whole feature would switch itself
      // off and every test would stay green.
      return _failed(
        'The resolution at $packageConfigPath does not name a package '
        'rooted at $rootPackageRoot, so no build hook could be run for it. '
        'Anything a dependency generates at build time will be missing '
        'from the bundle.',
      );
    }

    var runner = NativeAssetsBuildRunner(
      logger: _forwarder(),
      dartExecutable: Uri.file(dartExecutable),
      fileSystem: fileSystem,
      packageLayout: PackageLayout.fromPackageConfig(
        fileSystem,
        packageConfig,
        packageConfigUri,
        runPackageName,
        includeDevDependencies: true,
      ),
      userDefines: UserDefines(
        workspacePubspec: File(
          p.join(p.dirname(p.dirname(packageConfigPath)), 'pubspec.yaml'),
        ).absolute.uri,
      ),
    );

    List<String> packages;
    try {
      packages = await runner.packagesWithBuildHooks();
    } on Object catch (e) {
      return _failed('Could not read the package graph: $e');
    }
    if (packages.isEmpty) return _nothing;

    var watch = Stopwatch()..start();
    Result<BuildResult, HooksRunnerFailure> result;
    try {
      result = await runner.build(
        extensions: _hostCodeAssets(),
        // What `flutter test` decides for a debug build: link hooks are an
        // AOT concern, and this lane is JIT by construction.
        linkingEnabled: false,
      );
    } on Object catch (e) {
      return _failed('Build hooks failed: $e', packages: packages);
    }
    if (!result.isSuccess) {
      return _failed(
        'The build hooks of ${packages.join(', ')} did not finish '
        '(${result.asFailure.failure.name}). Anything that needed the '
        'files they generate will be missing from the bundle.',
        packages: packages,
      );
    }
    _log.fine(
      'ran the build hooks of ${packages.join(', ')} in '
      '${watch.elapsedMilliseconds}ms',
    );
    List<KernelAsset> assets;
    try {
      assets = [
        for (var encoded in result.success.encodedAssets)
          if (encoded.isCodeAsset) kernelAssetOf(encoded.asCodeAsset),
      ];
    } on Object catch (e) {
      // An asset the mapping cannot place — a link mode a future resolution
      // introduces, say. The contract is that a hook problem degrades, never
      // crashes the bundle, and the success path has to keep that promise too.
      return _failed(
        'Could not map the built native assets: $e',
        packages: packages,
      );
    }
    return (packages: packages, failure: null, nativeAssets: assets);
  }

  /// The macOS deployment floor hooks compile against — flutter_tools'
  /// `targetMacOSVersion`, which the SDK does not export, so it is copied and
  /// `build_hooks_test.dart` reads the SDK's own source to fail on drift. Let
  /// it drift and the two lanes' builds diverge silently: `hooks_runner` keys
  /// its cache on the config, so `fw` and `flutter test` would each compile a
  /// hook for a different floor on the same machine.
  static const targetMacOSVersion = 13;

  /// What the hooks are asked to produce: dynamic libraries for the machine we
  /// are on, which is the machine `flutter_tester` runs on.
  ///
  /// No `cCompiler` — see the class doc — and the macOS config is required
  /// whenever the target is macOS.
  static List<CodeAssetExtension> _hostCodeAssets() => [
    CodeAssetExtension(
      targetArchitecture: Architecture.current,
      targetOS: OS.current,
      linkModePreference: LinkModePreference.dynamic,
      macOS: OS.current == OS.macOS
          ? MacOSCodeConfig(targetVersion: targetMacOSVersion)
          : null,
    ),
  ];

  /// Where the VM will find [asset], in the wording the engine's
  /// `native_assets.cc` expects.
  ///
  /// The mapping is flutter_tools' `_targetLocationSingleArchitecture`. A
  /// bundled library still points at the hook's own output here;
  /// [AssetBundleBuilder] copies it into the bundle and rewrites the path, so
  /// the file a guest maps is one nothing else rewrites — `flutter test` copies
  /// for the same reason.
  @visibleForTesting
  static KernelAsset kernelAssetOf(CodeAsset asset) {
    var linkMode = asset.linkMode;
    var path = switch (linkMode) {
      DynamicLoadingSystem() => KernelAssetSystemPath(linkMode.uri),
      LookupInProcess() => KernelAssetInProcess(),
      LookupInExecutable() => KernelAssetInExecutable(),
      DynamicLoadingBundled() => KernelAssetAbsolutePath(asset.file!),
      _ => throw StateError(
        'Unsupported link mode ${linkMode.runtimeType} in asset ${asset.id}',
      ),
    };
    return KernelAsset(id: asset.id, target: Target.current, path: path);
  }

  /// The name [rootPackageRoot] goes by in the resolution.
  String? _rootPackageName(PackageConfig config) {
    for (var package in config.packages) {
      if (p.equals(package.root.toFilePath(), rootPackageRoot)) {
        return package.name;
      }
    }
    return null;
  }

  /// `hooks_runner` speaks `package:logging`, and so does the app — but a
  /// hook's own console is verbose enough that only what it says about
  /// *failing* belongs anywhere a human is looking.
  logging.Logger _forwarder() => logging.Logger.detached('hooks')
    ..level = logging.Level.ALL
    ..onRecord.listen((record) {
      if (record.level >= logging.Level.SEVERE) {
        _log.severe(record.message);
      } else if (record.level >= logging.Level.WARNING) {
        _log.warning(record.message);
      } else {
        _log.finer(record.message);
      }
    });
}
