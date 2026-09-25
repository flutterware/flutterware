import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

// Only the equality: this file has its own `firstOrNull`.
import 'package:collection/collection.dart' show DeepCollectionEquality;
import 'package:flutterware/plugins.dart';

// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../comparison/compare_command.dart';
import '../constants.dart';
import '../delta/branch_delta_controller.dart';
import '../context.dart';
import '../plugins/manifest_loader.dart';
import '../plugins/native/assets_core.dart';
import '../plugins/native/dependencies_core.dart';
import '../plugins/native/dev_stack_core.dart';
import '../plugins/native/lints_core.dart';
import '../plugins/native/run_core.dart';
import '../plugins/native/server_core.dart';
import '../plugins/native/renders_core.dart';
import '../plugins/native/scenarios_core.dart';
import '../plugins/native/scene_core.dart';
import '../plugins/native/icon_core.dart';
import '../plugins/native/splash_core.dart';
import '../plugins/native/store_core.dart';
import '../plugins/native/previews_core.dart';
import '../plugins/native/translations_core.dart';
import '../plugins/native/worlds_core.dart';
import '../plugins/plugin_core.dart';
import '../shell/workspace.dart';
import '../shell/worktree.dart';
import '../shell/worktree_discovery.dart';
import '../utils/flutter_sdk.dart';
import 'job.dart';

/// One open worktree, and the plugin cores for it — the thing `fw`, MCP and
/// (later) the GUI all drive.
///
/// Pure Dart on purpose. It is what makes "no renderer is privileged" true
/// rather than aspirational: the CLI does not reimplement the GUI's behaviour,
/// it instantiates the same [PluginCore]s.
///
/// Laziness is subscription. A widget subscribes for as long as it is
/// mounted; `fw` subscribes for the duration of a request and releases. Same
/// sources, same rule, no GUI required.
///
/// What laziness buys is that *reading* a report is free — which is what lets
/// the GUI read one per sidebar row per frame. It is not a reason to make a
/// caller ask twice: a `fw` process has no history to be lazy about, so
/// `fw status` loads and then reports.
class Session {
  Session._(
    this.root,
    this.worktree,
    this.workspace,
    List<PluginCore> cores,
    this._ownsWorkspace,
    this.manifest,
  ) : _cores = cores {
    // The `compare` action spans the previews and scenarios plugins, and a
    // core cannot see its siblings — so the one thing that holds them both
    // installs the runner, closing over itself. Same hook-not-dependency
    // pattern as `busyStatusFor`.
    var previews = coreById(uiCatalogPluginId);
    if (previews is PreviewsCore) {
      previews.compareRunner = (arguments) =>
          runCompareAction(session: this, arguments: arguments);
    }
    // What the branch changed is one fact about the worktree, read once for
    // the two trees that paint from it. Same hook: the cores cannot see each
    // other, and neither should own what both read.
    branchDelta = BranchDeltaController(
      worktreePath: root,
      packages: [for (var package in workspace.declared) package.path],
    );
    if (previews is PreviewsCore) previews.branchDelta = branchDelta;
    if (coreById(scenariosPluginId) case ScenariosCore scenarios) {
      scenarios.branchDelta = branchDelta;
    }
  }

  /// The worktree's delta against its base — see [BranchDeltaController].
  /// Owned here, installed on the cores that paint from it, refreshed by the
  /// shell when git moves.
  late final BranchDeltaController branchDelta;

  /// Builds a session over pieces the caller has already resolved.
  ///
  /// The GUI's way in: the shell has run the config file and built the
  /// [Workspace] before it knows whether the worktree will open at all, so it
  /// cannot go through [open] — and a second resolution would be a second
  /// answer to "which plugins does this worktree have".
  ///
  /// The workspace stays the caller's to dispose; the cores are this session's.
  factory Session.resolved({
    required Worktree worktree,
    required Workspace workspace,
    required PluginManifest manifest,
    PluginCoreRegistry? registry,
  }) => Session._(
    worktree.path,
    worktree,
    workspace,
    (registry ?? defaultCoreRegistry()).resolve(manifest, worktree, workspace),
    false,
    manifest,
  );

  /// Whether disposing this session also disposes the workspace under it.
  ///
  /// True for [open], which built it; false for [Session.resolved], where the
  /// shell owns the workspace and outlives the session on a reload.
  final bool _ownsWorkspace;

  /// The worktree root — where `tool/flutterware.dart` lives.
  final String root;

  final Worktree worktree;
  final Workspace workspace;

  /// One core per declared plugin, in the order the config declared them.
  ///
  /// Unmodifiable to callers: [reconcile] is the only thing that writes it, so
  /// a plugin set can only change by re-running the config.
  List<PluginCore> get cores => List.unmodifiable(_cores);

  final List<PluginCore> _cores;

  /// flutterware's own `app/` install, for the cores that need to find the
  /// machinery shipped beside them — the catalog daemon and its native host.
  ///
  /// Three strategies, in this order, because no one of them covers every way
  /// `fw` and the MCP server get started:
  ///
  /// - **[appPathEnvironmentKey], recorded by the launcher.** Authoritative, and
  ///   the only thing that can work in production: `fw` is an AOT binary there,
  ///   so `Platform.resolvedExecutable` is itself and `Platform.script` is a
  ///   path inside `build/cli/bundle`. The launcher ran under `dart run` and
  ///   therefore knew — the same "record, do not discover" rule
  ///   `.flutterware/sdk` follows.
  /// - **Derived from [Platform.script].** For `dart run app/bin/fw.dart`, which
  ///   is how this CLI is driven while being worked on and has no launcher to
  ///   record anything. `bin/fw.dart` sits two directories below the package
  ///   root, and this is exactly the case where that is true, because it is the
  ///   case where the script *is* a source file.
  /// - **Resolved from this package's own URI.** For `dart run
  ///   flutterware_app:fw` and `dart run flutterware_app:mcp`, where
  ///   `Platform.script` is a *snapshot* under
  ///   `.dart_tool/pub/bin/`, two directories above which is `.dart_tool` and
  ///   not a package at all. Measured, on `a911609e`:
  ///   `…/.dart_tool/pub/bin/flutterware_app/mcp.dart-<sdk>.snapshot`.
  ///
  ///   Without this the MCP server resolved null and every catalog action
  ///   refused with *"appPackageRoot must be flutterware's own app/
  ///   directory"* — an error that names the symptom and not the invocation,
  ///   which cost an afternoon before anyone measured it.
  ///
  /// A derivation is accepted only if the result is *this* package's root — by
  /// name, see [_packageRootAbove] — so the strategies cannot be confused with
  /// each other or with the workspace root. In the AOT case there is no
  /// `pubspec.yaml` above `bin/` and no package config to resolve against,
  /// which is what makes guessing safe to attempt at all.
  ///
  /// Null when none answer — including under `flutter test`, where the script
  /// is the runner's and `resolvePackageUriSync` does not answer either. That
  /// is fine and deliberate: a test that needs one passes `appToolDirectory`
  /// explicitly. A core that needs it and has none fails naming the path it
  /// looked for, rather than spawning something against the working directory
  /// and timing out.
  static Directory? findAppToolDirectory() {
    var recorded = Platform.environment[appPathEnvironmentKey];
    if (recorded != null && recorded.isNotEmpty) return Directory(recorded);

    return _packageRootAbove(
          Platform.script.isScheme('file')
              ? p.dirname(p.dirname(p.fromUri(Platform.script)))
              : null,
        ) ??
        _packageRootAbove(_ownLibDirectory());
  }

  /// `<root>/lib` for this very package, or null under AOT, where there is no
  /// package config to resolve against.
  static String? _ownLibDirectory() {
    try {
      var lib = Isolate.resolvePackageUriSync(
        Uri.parse('package:flutterware_app/'),
      );
      return lib != null && lib.isScheme('file')
          ? p.dirname(p.fromUri(lib))
          : null;
    } on Object {
      return null;
    }
  }

  /// [_packageRootAbove], for the test that pins the wrong-package rejection.
  ///
  /// The live resolution cannot be exercised under `flutter test` — neither
  /// derivation answers there — but the rule it applies can.
  @visibleForTesting
  static Directory? debugAppPackageRootAt(String directory) =>
      _packageRootAbove(directory);

  /// [directory] if it is **flutterware_app's own** package root.
  ///
  /// Checking the name, not merely that a `pubspec.yaml` is there: this repo is
  /// a workspace whose *root* is also a package, so "two directories above the
  /// script holds a pubspec" is satisfied by `flutterware` itself — and
  /// silently answering with the wrong package is how the catalog daemon came
  /// to be looked for at `<repo>/tool/catalog/compiler_daemon.dart`, one
  /// directory tree away from where it lives.
  static Directory? _packageRootAbove(String? directory) {
    if (directory == null) return null;
    var pubspec = File(p.join(directory, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    try {
      return RegExp(
            r'^name:\s*flutterware_app\s*$',
            multiLine: true,
          ).hasMatch(pubspec.readAsStringSync())
          ? Directory(directory)
          : null;
    } on FileSystemException {
      return null;
    }
  }

  /// The manifest [cores] were built from, and what the next load is compared
  /// against.
  ///
  /// Here, not beside the session in whatever built it. These cores *are*
  /// this manifest resolved; a copy kept elsewhere has to be written and cleared
  /// in step with them, which the reload path used to get wrong.
  final PluginManifest manifest;

  /// Opens the session for whichever repo [start] sits in.
  ///
  /// Walks up to the repo root, the same idiom the shell uses — one window (or
  /// one CLI invocation) per repo, regardless of where you started.
  static Future<Session> open(
    Directory start, {
    PluginCoreRegistry? registry,
    FlutterSdkPath? flutterSdk,
    Directory? appToolDirectory,
    LogClient? logger,
  }) async {
    var root = findRepoRoot(start.path);
    if (root == null) {
      throw SessionException(
        'Not inside a flutterware project: ${start.path}\n'
        'Run this from a git worktree with a tool/flutterware.dart.',
      );
    }

    var sdk = flutterSdk ?? await _defaultSdk();

    var loaded = await ManifestLoader(
      dartExecutable: sdk.dart,
      flutterRoot: sdk.root,
    ).tryLoad(root);
    if (loaded.error != null) {
      throw SessionException('tool/flutterware.dart failed:\n${loaded.error}');
    }
    // No config file is not an error — the worktree opens with no plugins,
    // exactly as it does in the GUI.
    var manifest = loaded.manifest ?? const PluginManifest([]);

    var workspace = Workspace(
      root: root,
      declared: manifest.packages.isEmpty
          ? const [Pkg('.')]
          : manifest.packages,
      discovered: discoverPackages(root),
      appContext: AppContext(
        // Defaults to stdout because every surface but one is a human reading
        // a terminal. MCP is the one, and passes its own.
        logger: logger ?? LogClient.print(),
        // The GUI's shell resolves this too, and both feed the same
        // [DaemonConfig.forPackage] — which is what stops `fw` and a panel
        // starting two daemons for one package.
        appToolDirectory: appToolDirectory ?? findAppToolDirectory(),
      ),
      flutterSdk: sdk,
    );

    var worktrees = await WorktreeDiscovery().discover(root);
    var worktree = worktrees.firstWhere(
      (w) => w.path == root,
      orElse: () => Worktree(path: root),
    );

    return Session._(
      root,
      worktree,
      workspace,
      (registry ?? defaultCoreRegistry()).resolve(
        manifest,
        worktree,
        workspace,
      ),
      true,
      manifest,
    );
  }

  static Future<FlutterSdkPath> _defaultSdk() async {
    var found = await FlutterSdkPath.findSdk();
    if (found == null) {
      throw SessionException(
        'No Flutter SDK above the dart running flutterware. Start it with the '
        'dart from a Flutter SDK — `dart run flutterware`, or whatever your '
        'version manager spells that.',
      );
    }
    return found;
  }

  /// Whether [next] declares exactly what these cores were built from.
  ///
  /// The one question a reload asks. Everything else it might have asked —
  /// which plugin moved, whether one could be kept — was machinery for keeping
  /// state alive across a config change, and losing that state is the accepted
  /// price of having changed the config. What is *not* acceptable is paying it
  /// for a save that changed nothing, so this is the check that has to be right,
  /// and it is the only one.
  ///
  /// Compared through `toJson`, so it sees exactly what crossed the process
  /// boundary rather than object identity.
  bool declares(PluginManifest next) =>
      const DeepCollectionEquality().equals(manifest.toJson(), next.toJson());

  PluginCore? coreById(String id) =>
      cores.where((core) => core.id == id).firstOrNull;

  /// The core whose id ends with [name], so `fw run dependencies reload` works
  /// without spelling out `flutterware.dependencies`. Ambiguity is an error
  /// rather than a guess.
  PluginCore? coreByShortName(String name) {
    var exact = coreById(name);
    if (exact != null) return exact;
    var matches = cores
        .where((core) => core.id.split('.').last == name)
        .toList();
    if (matches.length > 1) {
      throw SessionException(
        '"$name" is ambiguous: ${matches.map((c) => c.id).join(', ')}',
      );
    }
    return matches.firstOrNull;
  }

  /// [coreByShortName], but a miss is an error rather than null.
  ///
  /// The message names what *is* declared, because that is the recovery path,
  /// and it lives here so every surface reports a bad plugin name the same way
  /// — whether it was about to run something or only about to describe it.
  PluginCore requireCore(String plugin) {
    var core = coreByShortName(plugin);
    if (core == null) {
      throw SessionException(
        'No plugin "$plugin". Declared: ${cores.map((c) => c.id).join(', ')}',
      );
    }
    return core;
  }

  /// Every plugin's contract. A pure read — nothing here starts work.
  List<PluginReport> get reports => [for (var core in cores) core.report];

  /// Runs one plugin action, and the only way an action is ever run.
  ///
  /// `fw` and the MCP server both go through here, which is what makes the
  /// parity rule checkable rather than aspirational: a capability those two can
  /// reach that is not a declared [PluginAction] is not expressible, because
  /// there is no other door.
  ///
  /// The GUI is not a third caller. A panel holds its core and calls it, so
  /// what keeps the surfaces in step there is not this method but the split
  /// described on `NativePlugin` — the behaviour belongs to the core either way.
  ///
  /// It is also the seam. Recording the run, joining two clients onto one
  /// execution, reporting progress, and one day forwarding the whole thing to a
  /// daemon are all changes to this method — one edit each, rather than one per
  /// renderer, which is the arrangement that lets a renderer quietly miss one.
  ///
  /// [plugin] may be a full id or its last dotted segment.
  ///
  /// Throws for an unknown plugin; records an unknown action as a failed
  /// job. The line is the same one [Address] draws: the framework owns the
  /// namespace up to and including the plugin, and everything past it belongs
  /// to the plugin. Naming a plugin that does not exist means no run happened
  /// and there is nothing to write down. Naming a bad action is a real
  /// invocation of a real plugin that came back with an error, which is worth
  /// recording — an agent guessing action names leaves a visible trail.
  Job invoke(
    String plugin,
    String action, {
    Map<String, Object?> arguments = const {},
  }) {
    var core = requireCore(plugin);

    Map<String, Object?> coerced;
    try {
      coerced = _coerce(core, action, arguments);
    } on ArgumentError catch (e, stackTrace) {
      // A value of the wrong kind is a failed job, not a throw — the same line
      // an unknown action falls on. A real plugin and a real action were named
      // and the run did not survive its arguments, which is a run, and both
      // renderers already know how to report one.
      var controller = JobController(
        id: newJobId(),
        plugin: core.id,
        action: action,
        arguments: arguments,
      );
      controller.fail(e, stackTrace);
      return controller.job;
    }

    var controller = JobController(
      id: newJobId(),
      // The resolved id, not what the caller typed.
      plugin: core.id,
      action: action,
      arguments: coerced,
    );
    unawaited(_run(core, controller));
    return controller.job;
  }

  /// Arguments as the action declared them, not as the transport delivered
  /// them.
  ///
  /// A shell has no types: `--loud=true` arrives as the *string* `'true'`, and
  /// a plugin asking `arguments['loud'] == true` gets false — silently, and
  /// only on the CLI, while the same call over MCP (where JSON carries a real
  /// bool) works. Found by the surface-parity test rather than by a person,
  /// which is what that test is for.
  ///
  /// So the declared `ActionParameterKind` is applied here, once, at the single
  /// door — rather than in each renderer, or by hand in every core. A parameter
  /// the action does not declare is **refused** here for the same reason and in
  /// the same place; see [_undeclared].
  Map<String, Object?> _coerce(
    PluginCore core,
    String action,
    Map<String, Object?> arguments,
  ) {
    var declaredAction = core.report.actions
        .where((candidate) => candidate.id == action)
        .firstOrNull;
    // **Refused here, before dispatch, and that is what closes the hole.**
    //
    // This used to return the arguments untouched and leave the complaining to
    // `PluginCore.invoke`, on the sound reasoning that answering "no such
    // parameter" for an action that does not exist describes the arguments of
    // nothing. The reasoning holds; the assumption under it did not. A core
    // whose `invoke` *handles* an id it never declared never reaches that
    // refusal — it runs, and the argument check below is keyed on the
    // declaration, so every argument it was given was waved through
    // unexamined. `run`'s `screenshot` was exactly that for the life of the
    // cockpit, which is how `--output` came to be silently ignored in favour
    // of the real `out`.
    //
    // Declared is therefore what makes an action invocable, not implemented.
    // The words are `PluginCore`'s own, so a caller gets one sentence whether
    // they arrived through a session or straight at a core.
    if (declaredAction == null) {
      throw PluginCore.unknownAction(core.id, action, core.report.actions);
    }
    if (arguments.isEmpty) return arguments;
    var declared = {
      for (var parameter in declaredAction.parameters) parameter.id: parameter,
    };

    return {
      for (var entry in arguments.entries)
        entry.key: switch (declared[entry.key]?.kind) {
          // Only text needs converting; anything already typed came from a
          // transport that has types, and second-guessing it would be how
          // `7.0` becomes `7`.
          // A bool where text was declared is a flag that lost its value —
          // `--entry` with nothing after it, or `--entry --knobs`. Refused
          // here rather than passed on: the action would cast it and die with
          // a type error naming neither the flag nor what to do about it.
          ActionParameterKind.string || ActionParameterKind.choice
              when entry.value is bool =>
            // Not `ArgumentError.value`: it would print "… (entry): true", and
            // `true` is not what anybody wrote — it is what a flag with
            // nothing after it became.
            throw ArgumentError(
              'needs a value — `--${entry.key}=<value>` or '
              '`--${entry.key} <value>`',
              entry.key,
            ),
          // `kind` has a default and is never null, so this is the undeclared
          // key and nothing else.
          null => throw _undeclared(core, declaredAction, entry.key),
          ActionParameterKind.string ||
          ActionParameterKind.choice => entry.value,
          ActionParameterKind.boolean => _asBoolean(entry.key, entry.value),
          ActionParameterKind.integer => _asInteger(entry.key, entry.value),
        },
    };
  }

  /// The refusal for an argument naming a parameter the action does not have.
  ///
  /// Silence was the expensive failure here. `describe --entry=… --axes=true`
  /// is a call somebody really made; the parameter is `with-axes`. The argument
  /// was dropped and the answer came back well-formed with no `axes` field —
  /// which is precisely what a *correct* call returns for an entry that has no
  /// shell. A person spots the typo in seconds. An agent gets a wrong fact
  /// wearing the shape of a right one, and nothing downstream can catch it.
  ///
  /// Safe to refuse because nothing accepts what it does not advertise: every
  /// `arguments['…']` read across every core names a declared id, and the one
  /// dynamically-named argument — a dev-stack command's — is declared alongside
  /// the command that reads it.
  static ArgumentError _undeclared(
    PluginCore core,
    PluginAction action,
    String key,
  ) {
    var ids = [for (var parameter in action.parameters) parameter.id];
    var nearest = nearestName(key, ids);
    return ArgumentError(
      'no such parameter on ${core.id} ${action.id}'
      '${nearest == null ? '.' : ' — did you mean `$nearest`?'} '
      '${ids.isEmpty ? 'It takes none.' : 'It takes: ${ids.join(', ')}'}',
      key,
    );
  }

  static Object? _asBoolean(String name, Object? value) => switch (value) {
    bool() || null => value,
    // The spellings a shell and a person actually produce. A bare `--flag` is
    // already `true` before it gets here.
    String text => switch (text.toLowerCase()) {
      'true' || 'yes' || '1' => true,
      'false' || 'no' || '0' => false,
      _ => throw ArgumentError.value(value, name, 'expected true or false'),
    },
    _ => throw ArgumentError.value(value, name, 'expected true or false'),
  };

  static Object? _asInteger(String name, Object? value) => switch (value) {
    int() || null => value,
    String text =>
      int.tryParse(text) ??
          (throw ArgumentError.value(value, name, 'expected an integer')),
    _ => throw ArgumentError.value(value, name, 'expected an integer'),
  };

  Future<void> _run(PluginCore core, JobController controller) async {
    try {
      var value = await core.invoke(
        controller.job.action,
        arguments: controller.job.arguments,
      );
      _checkDeclaredReturn(core, controller.job.action, value);
      controller.succeed(value);
    } catch (e, stackTrace) {
      controller.fail(e, stackTrace);
    }
  }

  /// Fails a run whose result is not the type its action promised.
  ///
  /// An action's `returns` is not a comment: the capability document resolves
  /// it statically and publishes that class's fields as the shape callers can
  /// expect. So a mismatch is not a style problem, it is a document describing
  /// a response that is never sent — and the cheapest moment to notice is the
  /// run that produced it, on whichever surface asked.
  ///
  /// Exact rather than `is`: a subclass would serialise fields the published
  /// shape does not mention, which is the same failure one layer quieter. (A
  /// `Type` cannot be used with `is` anyway, so the check has to name it.)
  void _checkDeclaredReturn(PluginCore core, String action, Object? value) {
    var declared = core.report.actions
        .where((candidate) => candidate.id == action)
        .map((candidate) => candidate.returns)
        .firstOrNull;
    if (declared == null || value == null) return;
    if (value.runtimeType == declared) return;
    throw StateError(
      '${core.id}/$action declares it returns $declared but returned '
      '${value.runtimeType}. Either the action or its `returns:` is wrong; '
      'the capability document believes the declaration.',
    );
  }

  void dispose() {
    for (var core in cores) {
      core.dispose();
    }
    branchDelta.dispose();
    if (_ownsWorkspace) workspace.dispose();
  }
}

/// The cores compiled into this binary.
///
/// Deliberately **not** every plugin the GUI has. A plugin appears here once
/// its behaviour is separable from its panel; until then it resolves to a
/// [MissingPluginCore] and `fw` says so out loud rather than omitting it.
PluginCoreRegistry defaultCoreRegistry() => PluginCoreRegistry({
  assetsPluginId: assetsCoreFactory,
  dependenciesPluginId: dependenciesCoreFactory,
  runPluginId: runCoreFactory,
  serverPluginId: serverCoreFactory,
  scenariosPluginId: scenariosCoreFactory,
  scenePluginId: sceneCoreFactory,
  rendersPluginId: rendersCoreFactory,
  launcherIconPluginId: launcherIconCoreFactory,
  splashPluginId: splashCoreFactory,
  storePluginId: storeCoreFactory,
  uiCatalogPluginId: uiCatalogCoreFactory,
  devStackPluginId: devStackCoreFactory,
  translationsPluginId: translationsCoreFactory,
  lintsPluginId: lintsCoreFactory,
  worldsPluginId: worldsCoreFactory,
});

class SessionException implements Exception {
  SessionException(this.message);

  final String message;

  @override
  String toString() => message;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    var it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

/// The declared id a mistyped one most likely meant, or null rather than a
/// reach.
///
/// Two rules, in order. A declared id that has the typed one as one of its
/// hyphenated words — `axes` finding `with-axes`, which is the shape of the
/// mistake this exists for, and the shape no edit-distance rule catches
/// because a prefix is five characters away. Then a single typo's worth of
/// distance, for `entrie` and `pacakge`.
String? nearestName(String key, List<String> declared) {
  for (var id in declared) {
    if (id.split('-').contains(key)) return id;
  }
  String? best;
  var distance = 2;
  for (var id in declared) {
    var d = _editDistance(key, id);
    if (d < distance) {
      distance = d;
      best = id;
    }
  }
  return best;
}

/// Levenshtein, one row at a time — the ids are short and this runs once, on
/// the way to failing.
int _editDistance(String a, String b) {
  var row = [for (var i = 0; i <= b.length; i++) i];
  for (var i = 1; i <= a.length; i++) {
    var previous = row[0];
    row[0] = i;
    for (var j = 1; j <= b.length; j++) {
      var replace = previous + (a[i - 1] == b[j - 1] ? 0 : 1);
      previous = row[j];
      row[j] = math.min(math.min(row[j] + 1, row[j - 1] + 1), replace);
    }
  }
  return row[b.length];
}
