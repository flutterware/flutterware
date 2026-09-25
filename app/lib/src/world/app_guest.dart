import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

import '../embedder/embedder_build.dart';
import '../embedder/flutter_cache.dart';
import '../embedder/resident_compiler.dart';
import '../embedder/seed_kernel.dart';
import '../embedder/source_invalidator.dart';
import '../previews/asset_bundle.dart';

/// An app's own `main`, built to run in embedded guests — one kernel for every
/// person in a world. The worlds guest experiment
/// (`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`).
///
/// **One kernel, every person.** The generated entry reads its knobs from the
/// environment at run time and hands them to `main` by name, so a second
/// person is a second process over the same kernel rather than a second
/// build, and a reload compiles once for all of them.
///
/// The entry wraps `main` in Run's own `runGuest`, so a guest carries the same
/// drive, inspection and log extensions as an app Run launched, and installs
/// the guest keyboard and text input Previews uses. [fakes] names a file with
/// `installGuestFakes({required Directory home, required answerChannel})`, the
/// project's replacements for its plugins: `home` is that person's own
/// directory, and `answerChannel(name, (call) async => …)` answers a channel a
/// plugin with no platform interface calls directly.
class AppGuestBuild {
  AppGuestBuild({
    required String package,
    required this.cache,
    this.entrypoint = 'lib/main.dart',
    String? fakes,
    this.platform,
    String? buildDir,
    this.seeds = false,
    this.seedDill,
  }) : package = p.normalize(p.absolute(package)),
       fakes = fakes == null ? null : p.normalize(p.absolute(fakes)),
       buildDir =
           buildDir ??
           p.join(p.normalize(p.absolute(package)), 'build', 'world_guest');

  final String package;
  final FlutterCache cache;

  /// Package-relative: `lib/main.dart`, or a `demo/` or `tool/` entry point.
  final String entrypoint;
  final String? fakes;

  /// A `TargetPlatform` name — `iOS` — for the look of a phone the guest is
  /// not: it runs on the Mac, so without this it draws the Mac's.
  final String? platform;

  /// Where the kernel, the assets and each person's home go.
  final String buildDir;

  /// Whether to use the studio's machine-level seed kernel — the half of the
  /// program under the SDK and the pub cache — and leave one behind.
  final bool seeds;

  /// A kernel to start the compile from instead.
  final String? seedDill;

  String get assetsDir => p.join(buildDir, 'assets');
  String get kernel => p.join(assetsDir, 'kernel_blob.bin');
  String homeOf(String person) => p.join(buildDir, 'people', person);

  late final String packageConfig = packageConfigFor(package);

  ResidentCompiler? _compiler;
  SeedStore? _store;
  SeedKernel? _seed;
  DateTime? _compiledAt;
  final _invalidator = SourceInvalidator();

  /// The seed this build started from, when [seeds] found one.
  SeedKernel? get seed => _seed;

  /// The asset bundle, the build hooks' native libraries included.
  Future<void> assets() => AssetBundleBuilder(
    cache: cache,
    rootPackageRoot: package,
    packageConfigPath: packageConfig,
  ).build(assetsDir);

  /// Writes the entry and compiles it whole, into [kernel].
  Future<CompileOutcome> compile() async {
    var entry = _writeEntry();
    if (seeds) {
      _store = SeedStore(
        engineRevision: cache.engineRevision,
        flavor: seedFlavor(
          ResidentCompiler.argumentsFor(trackWidgetCreation: true),
        ),
      );
      _seed = _store!.find(await _resolution());
    }
    _compiler = await ResidentCompiler.start(
      entrypoint: entry,
      outputDill: p.join(buildDir, 'app.dill'),
      packageConfig: packageConfig,
      cache: cache,
      workingDirectory: package,
      seedDill: seedDill ?? _seed?.kernelPath,
    );
    _compiledAt = DateTime.now();
    var outcome = await _compiler!.compile();
    if (outcome.ok) File(outcome.dillOutput!).copySync(kernel);
    return outcome;
  }

  /// Compiles what changed since the last compile — the delta every guest
  /// reloads from — and answers how many files that was beside the outcome.
  Future<(int, CompileOutcome)> recompile() async {
    var compiler = _compiler!;
    var changed = _invalidator.sweep(compiler.sources, compiledAt: _compiledAt);
    _compiledAt = DateTime.now();
    return (changed.length, await compiler.compile(changed));
  }

  /// Leaves the shared half of this program for the next checkout, as the
  /// catalog and the tester do. Worth calling once the world is open, not
  /// before.
  Future<String?> writeSeed({void Function(String)? log}) async {
    var store = _store;
    if (store == null) return null;
    return _compiler!.writeSeed(
      store: store,
      resolution: await _resolution(),
      immutableRoots: [cache.flutterRoot, ...pubCacheRoots()],
      improving: _seed,
      log: log,
    );
  }

  Future<void> dispose() async => _compiler?.shutdown();

  Future<PackageConfig> _resolution() =>
      loadPackageConfigUri(Uri.file(packageConfig));

  String _writeEntry() {
    var name = RegExp(
      r'^name:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File(p.join(package, 'pubspec.yaml')).readAsStringSync())!;
    // A `lib/` entry point by its package URI; anything else — a `demo/` or
    // `tool/` entry point, which no package URI reaches — by its file.
    var main = entrypoint.startsWith('lib/')
        ? 'package:${name.group(1)}/${entrypoint.substring(4)}'
        : '${Uri.file(p.join(package, entrypoint))}';
    var fakesUri = fakes == null ? null : Uri.file(fakes!);
    var entry = File(p.join(buildDir, 'entry.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
// Generated by flutterware's world guest (app/lib/src/world/app_guest.dart).
// Do not edit.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterware/previews_guest.dart'
    show GuestKeyboard, GuestLogs, GuestTextInput;
import 'package:flutterware/run_guest.dart';
import '$main' as app;
${fakesUri == null ? '' : "import '$fakesUri' as fakes;"}

/// The guest's binding. Two things only a binding can do for an app whose
/// `runApp` is its own:
///
/// * **Answer a plugin that has no platform interface.** Such a plugin calls a
///   `MethodChannel` directly, so no Dart fake can take its place — except the
///   messenger every channel sends through. The project's fakes name the
///   channels they answer; every other message goes to the platform as before.
/// * **Give the app a device's safe areas.** They reach a guest as view
///   *insets* — `FlutterWindowMetricsEvent` has no padding field — so they are
///   turned back into padding under the root `View`.
class _GuestBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _AnsweringMessenger(super.createBinaryMessenger());

  @override
  Widget wrapWithDefaultView(Widget rootWidget) =>
      super.wrapWithDefaultView(Builder(builder: (context) {
        var media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding: media.viewInsets,
            viewPadding: media.viewInsets,
            viewInsets: EdgeInsets.zero,
          ),
          child: rootWidget,
        );
      }));
}

final _answers = <String, Future<Object?> Function(MethodCall)>{};

class _AnsweringMessenger implements BinaryMessenger {
  _AnsweringMessenger(this._platform);

  final BinaryMessenger _platform;
  static const _codec = StandardMethodCodec();

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    var answer = _answers[channel];
    if (answer == null || message == null) {
      return _platform.send(channel, message);
    }
    return answer(_codec.decodeMethodCall(message))
        .then(_codec.encodeSuccessEnvelope);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _platform.setMessageHandler(channel, handler);

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) => _platform.handlePlatformMessage(channel, data, callback);
}

// The binding is created before `runGuest` makes its own, and inside the log
// zone `runGuest` would open: `install` does not nest, so `runGuest` runs in
// this same zone, finds the binding, and the zone the binding captured is the
// one `runApp` is called in. Any flutterware with the guest plumbing has this.
void main() => GuestLogs.instance.install<Object?>(() {
  _GuestBinding();
  return runGuest(() {
    ${platform == null ? '' : 'debugDefaultTargetPlatformOverride = TargetPlatform.$platform;'}
    GuestKeyboard.instance.install();
    GuestTextInput.instance.install();
    ${fakesUri == null ? '' : "fakes.installGuestFakes(home: Directory(Platform.environment['FW_PERSON_HOME']!), answerChannel: (channel, answer) => _answers[channel] = answer);"}
    var knobs = (jsonDecode(Platform.environment['FW_KNOBS'] ?? '{}') as Map)
        .cast<String, Object?>();
    return Function.apply(app.main, const [], {
      for (var knob in knobs.entries) Symbol(knob.key): knob.value,
    });
  });
});
''');
    return entry.path;
  }
}

/// What one person's guest process runs with: its knobs, its home, its
/// locales. Only knobs somebody named — `main` is called by name, and a name
/// it does not declare fails the call.
Map<String, String> guestEnvironment({
  required String home,
  required Map<String, Object?> knobs,
  String locales = 'en-US',
}) => {
  // JSON, so an `int` knob stays an `int` on its way to `main`.
  'FW_KNOBS': jsonEncode(knobs),
  'FW_PERSON_HOME': home,
  'FW_GUEST_LOCALES': locales,
};

/// The machine's half of a guest: the engine and the C host, built once per
/// flutterware checkout rather than per worktree. Answers the host's path.
Future<String> ensureGuestHost(FlutterCache cache, String appRoot) async {
  var engineDir = await ensureEmbedderEngine(cache);
  return buildHost(
    nativeSourceDir: p.join(appRoot, 'native'),
    nativeBuildDir: p.join(appRoot, 'build', 'embedder', 'native'),
    engineDir: engineDir,
  );
}

/// The package config that resolves [package]: its own, or its workspace's.
String packageConfigFor(String package) {
  for (var dir = package; ; dir = p.dirname(dir)) {
    var candidate = p.join(dir, '.dart_tool', 'package_config.json');
    if (File(candidate).existsSync()) return candidate;
    if (p.dirname(dir) == dir) {
      throw StateError('$package is not resolved; run `flutter pub get`.');
    }
  }
}
