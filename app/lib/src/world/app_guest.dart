import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

import '../embedder/embedder_build.dart';
import '../embedder/flutter_cache.dart';
import '../embedder/resident_compiler.dart';
import '../embedder/seed_kernel.dart';
import '../embedder/source_invalidator.dart';
import '../previews/asset_bundle.dart';
import '../run/entrypoint_knobs.dart';
import '../run/wrapper_import.dart';
import 'plugin_registrant.dart';

/// An app's own `main`, built to run in embedded guests — one kernel for every
/// person in a world.
///
/// **One kernel, every person.** The generated entry reads its knobs at run
/// time — from a file of that person's, on every start — and hands them to
/// `main` by name, so a second person is a second process over the same
/// kernel rather than a second build, a reload compiles once for all of them,
/// and a restart takes whatever knobs were written since.
///
/// The entry wraps `main` in Run's own `runGuest`, so a guest carries the same
/// drive, inspection and log extensions as an app Run launched, and installs
/// the guest keyboard and text input Previews uses.
///
/// **The app's plugins are its own.** Their Dart halves are registered the way
/// `flutter run` registers them, and what they send the platform is answered
/// by the studio (`StudioPlatform`) — so the guests need
/// [guestEnvironment]'s forwarding.
class AppGuestBuild {
  AppGuestBuild({
    required String package,
    required this.cache,
    this.entrypoint = 'lib/main.dart',
    this.platform,
    String? buildDir,
    this.seeds = false,
    this.seedDill,
  }) : package = p.normalize(p.absolute(package)),
       buildDir =
           buildDir ??
           p.join(p.normalize(p.absolute(package)), 'build', 'world_guest');

  final String package;
  final FlutterCache cache;

  /// Package-relative: `lib/main.dart`, or a `demo/` or `tool/` entry point.
  final String entrypoint;

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

  /// Writes the knobs [person]'s app is started with — and restarted with,
  /// since the entry reads them again each time `main` runs — and answers
  /// where, for [guestEnvironment].
  String writeKnobs(String person, Map<String, Object?> knobs) {
    var file = File(p.join(buildDir, 'knobs', '$person.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(knobs));
    return file.path;
  }

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
    _writeEnumKnobs();
    var entry = _writeEntry(
      await dartPluginRegistrations(
        packageConfig: packageConfig,
        package: package,
        // The look decides, not the Mac the guest runs on: a plugin that
        // picks its implementation by the target platform — the
        // notifications plugin does — finds none for iOS if the macOS half
        // was registered, and every call does nothing.
        platform: platform == 'iOS' ? 'ios' : 'macos',
      ),
    );
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
    // Before the sweep, so an enum parameter added to `main` since is in it.
    _writeEnumKnobs();
    var changed = _invalidator.sweep(compiler.sources, compiledAt: _compiledAt);
    _compiledAt = DateTime.now();
    return (changed.length, await compiler.compile(changed));
  }

  /// As [recompile], but the whole program — what a guest restarts from. The
  /// deltas after it build on it, so whoever restarts one guest from it must
  /// first have reloaded the others to where it starts.
  Future<(int, CompileOutcome)> recompileWhole() {
    _compiler!.reset();
    return recompile();
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

  late final String _packageName = RegExp(r'^name:\s*(\S+)', multiLine: true)
      .firstMatch(File(p.join(package, 'pubspec.yaml')).readAsStringSync())!
      .group(1)!;

  /// The library that turns [entrypoint]'s enum knobs back into constants.
  ///
  /// Beside Run's own wrapper, because the entry point's imports are spelled
  /// from there: written anywhere else, a relative one would name another
  /// file.
  String get _enumKnobsFile => p.joinAll([
    package,
    ...p.posix.split(wrapperDirectory),
    '${p.posix.withoutExtension(entrypoint).replaceAll('/', '_')}_world_knobs.dart',
  ]);

  /// Writes [_enumKnobsFile] from `main` as it is declared now, unless it
  /// already says that: an unchanged file is not recompiled.
  void _writeEnumKnobs() {
    var source = enumKnobsSource(
      scanEntrypointKnobs(packageRoot: package, entrypoint: entrypoint),
      entryImport: wrapperImportOf(entrypoint, package: _packageName),
    );
    var file = File(_enumKnobsFile);
    if (file.existsSync() && file.readAsStringSync() == source) return;
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
  }

  String _writeEntry(List<PluginRegistration> registrations) {
    var plugins = [
      for (var (i, plugin) in registrations.indexed)
        registrationSource(plugin, 'plugin$i'),
    ];
    // A `lib/` entry point by its package URI; anything else — a `demo/` or
    // `tool/` entry point, which no package URI reaches — by its file.
    var main = entrypoint.startsWith('lib/')
        ? 'package:$_packageName/${entrypoint.substring(4)}'
        : '${Uri.file(p.join(package, entrypoint))}';
    var entry = File(p.join(buildDir, 'entry.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
// Generated by flutterware's world guest (app/lib/src/world/app_guest.dart).
// Do not edit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterware/previews_guest.dart'
    show GuestKeyboard, GuestLogs, GuestTextInput, WorldSteps, installWorldInput;
import 'package:flutterware/run_guest.dart';
import '$main' as app;
import '${Uri.file(_enumKnobsFile)}' as enums;
${[for (var plugin in plugins) ...plugin.imports].join('\n')}

/// The guest's binding, for what only a binding can do for an app whose
/// `runApp` is its own: give it a device's safe areas. They reach a guest as
/// view *insets* — `FlutterWindowMetricsEvent` has no padding field — so they
/// are turned back into padding under the root `View`.
class _GuestBinding extends RunGuestBinding {
  /// Every gesture — a person's or an agent's — is dispatched inside its
  /// step, so the requests it causes say which tap they came from.
  @override
  void handlePointerEvent(PointerEvent event) =>
      _steps.dispatch(event, super.handlePointerEvent);

  /// Whether the app has called `runApp`. Until it has, a `main` that fails
  /// leaves nothing that will ever draw.
  bool ranApp = false;

  @override
  void scheduleAttachRootWidget(Widget rootWidget) {
    ranApp = true;
    super.scheduleAttachRootWidget(rootWidget);
  }

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

/// The person this guest is, from the world, as its steps are named.
final _steps = WorldSteps(
  person: Platform.environment['FW_WORLD_PERSON'] ?? 'guest',
);

// The binding is created before `runGuest` makes its own, and inside the log
// zone `runGuest` would open: `install` does not nest, so `runGuest` runs in
// this same zone, finds the binding, and the zone the binding captured is the
// one `runApp` is called in — or holds it, when the app calls `runApp` from a
// zone of its own, which `RunGuestBinding` lets pass. Any flutterware with the
// guest plumbing has this.
void main() => GuestLogs.instance.install<Object?>(() {
  _steps.install();
  var binding = _GuestBinding();
  return runGuest(() {
    ${platform == null ? '' : 'debugDefaultTargetPlatformOverride = TargetPlatform.$platform;'}
    GuestKeyboard.instance.install();
    GuestTextInput.instance.install();
    // A code the world delivers is typed into the focused field, and each
    // delivery is a step.
    installWorldInput(_steps);
    ${[for (var plugin in plugins) ...plugin.statements].join('\n    ')}
    // Read on every start, so a restart takes the knobs written since.
    var knobs = (jsonDecode(
      File(Platform.environment['FW_KNOBS_FILE']!).readAsStringSync(),
    ) as Map).cast<String, Object?>();
    // An enum arrives as the name of one of its constants.
    return _start(() => binding.ranApp, () => Function.apply(app.main, const [], {
      for (var MapEntry(:key, :value) in knobs.entries)
        Symbol(key): switch ((enums.enumKnobs[key], value)) {
          (var constant?, String name) => constant(name),
          _ => value,
        },
    }));
  });
});

${guestStartSource()}''');
    return entry.path;
  }
}

/// The library a guest entry turns enum knobs back into constants with: each
/// enum `main` takes, by its parameter's name, from the name of one of its
/// constants — `local` for `Env.local` — which is how a knob carries one, in
/// Run as in a world.
///
/// It imports what the entry point imports, and the entry point itself for an
/// enum declared there, so each enum is spelled as `main` spells it. Those
/// imports are kept out of the entry, where a name one of them exports could
/// clash with the names the entry uses.
String enumKnobsSource(EntrypointKnobs scan, {String? entryImport}) {
  var enums = [
    for (var knob in scan.knobs)
      if (knob.knob.kind == KnobKind.picker && knob.enumType != null) knob,
  ];
  return '''
// Generated by flutterware's world guest (app/lib/src/world/app_guest.dart).
// Do not edit.
${enums.isEmpty ? '' : [...scan.imports, if (entryImport != null) "import '$entryImport';"].join('\n')}

final enumKnobs = <String, Object Function(String name)>{
${[for (var knob in enums) "  r'${knob.name}': (name) => ${knob.enumType}.values.byName(name),"].join('\n')}
};
''';
}

/// The guest entry's `_start`, which runs the app's `main` and calls
/// `ranApp` to learn whether it has called `runApp` yet.
///
/// Its own function, and [grace] a parameter, so that a test can run it as
/// the entry does.
String guestStartSource({Duration grace = const Duration(seconds: 5)}) =>
    '''
/// Runs the app's `main`, and says so when it fails before `runApp`: that app
/// will never draw, and whoever waits for its first frame need not wait out
/// the minute to learn it. The error is still reported as it would have been.
///
/// An error nothing catches counts too, since a `main` that starts the app
/// without returning that future leaves its failure to the zone. It counts
/// once `main` has returned, and only when `runApp` has not followed
/// ${grace.inMilliseconds}ms later: a call the app fired and forgot can fail
/// on the way to a `runApp` that still comes.
Object? _start(bool Function() ranApp, Object? Function() main) {
  var said = false;
  void stopped(Object error) {
    if (said || ranApp()) return;
    said = true;
    print('$guestStoppedMarker\${'\$error'.split('\\n').first}');
  }

  Object? uncaught;
  var returned = false;
  void settle() {
    if (uncaught case var error? when returned && !ranApp()) {
      Timer(
        const Duration(milliseconds: ${grace.inMilliseconds}),
        () => stopped(error),
      );
    }
  }

  return runZoned(
    () {
      Object? started;
      try {
        started = main();
      } catch (error) {
        stopped(error);
        rethrow;
      }
      if (started is! Future) {
        returned = true;
        settle();
        return started;
      }
      return started.then<Object?>(
        (value) {
          returned = true;
          settle();
          return value;
        },
        onError: (Object error, StackTrace stack) {
          stopped(error);
          Error.throwWithStackTrace(error, stack);
        },
      );
    },
    zoneSpecification: ZoneSpecification(
      handleUncaughtError: (self, parent, zone, error, stack) {
        if (uncaught == null && !ranApp()) {
          uncaught = error;
          settle();
        }
        parent.handleUncaughtError(zone, error, stack);
      },
    ),
  );
}
''';

/// What a guest prints, before the error's first line, when the app's `main`
/// failed before calling `runApp`.
const guestStoppedMarker = '[world] main failed before runApp: ';

/// Why the app stopped before it drew, when [line] is the guest saying so;
/// otherwise null. In words for the person's panel, with what to do when the
/// cause is a plugin a world cannot run.
String? stoppedBeforeDrawing(String line) {
  var at = line.indexOf(guestStoppedMarker);
  if (at < 0) return null;
  var error = line.substring(at + guestStoppedMarker.length).trim();
  return 'The app stopped before it drew anything: $error'
      '${error.contains('FailedToLoadClassException') ? ' A plugin calls its '
                'native code directly, and a world builds none. Fake the '
                'plugin in the entry point, behind a knob.' : ''}';
}

/// [path], emptied and made: a person's home as their guest starts. A world
/// creates what it needs every time it opens, so nothing is kept.
Directory emptyGuestHome(String path) {
  var home = Directory(path);
  if (home.existsSync()) home.deleteSync(recursive: true);
  return home..createSync(recursive: true);
}

/// What one person's guest process runs with: its knobs, as the file
/// [AppGuestBuild.writeKnobs] wrote, its home, its locales. Only knobs
/// somebody named — `main` is called by name, and a name it does not declare
/// fails the call.
///
/// The guest hands its platform messages to the studio, and CoreFoundation's
/// idea of the home directory is the person's — `CFFIXED_USER_HOME`, the
/// variable the iOS simulator gives each device — so a plugin whose macOS half
/// calls Foundation directly, `path_provider`, finds the person's own folders
/// without the app knowing.
Map<String, String> guestEnvironment({
  required String person,
  required String home,
  required String knobsFile,
  String locales = 'en-US',
}) => {
  'FW_WORLD_PERSON': person,
  'FW_KNOBS_FILE': knobsFile,
  'FW_GUEST_LOCALES': locales,
  'FW_FORWARD_PLATFORM': '1',
  'CFFIXED_USER_HOME': home,
};

/// The machine's half of a guest: the engine and the C host, built once per
/// flutterware checkout rather than per worktree. Answers the host's path.
Future<String> ensureGuestHost(FlutterCache cache, String appRoot) async {
  var engineDir = await ensureEmbedderEngine(cache);
  return buildHost(
    nativeSourceDir: p.join(appRoot, 'native'),
    nativeBuildDir: p.join(appRoot, 'build', 'embedder', 'native'),
    engineDir: engineDir,
    quiet: true,
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
