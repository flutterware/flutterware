import 'dart:convert';

import 'package:collection/collection.dart';

import '../scenarios/network_mode.dart';
import 'address.dart';
import 'changes_config.dart';
import 'package.dart';
import 'plugin.dart';
import 'project_identity.dart';

/// Re-exported because [FlutterwareConfig.network] takes one: a
/// `tool/flutterware.dart` imports `package:flutterware/plugins.dart` and
/// nothing else.
export '../scenarios/network_mode.dart' show ScenarioNetwork;

/// What `tool/flutterware.dart` prints: the project's plugin declarations.
///
/// Bumped only on a breaking shape change; the GUI refuses a version it does
/// not understand rather than guessing.
const manifestVersion = 1;

/// One declared plugin, as read back by the GUI.
class PluginDeclaration {
  const PluginDeclaration({
    required this.id,
    required this.label,
    this.config = const {},
  });

  final String id;
  final String label;
  final Map<String, Object?> config;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (config.isNotEmpty) 'config': config,
  };

  static PluginDeclaration fromJson(Map<String, Object?> json) =>
      PluginDeclaration(
        id: json['id']! as String,
        label: json['label']! as String,
        config: (json['config'] as Map?)?.cast<String, Object?>() ?? const {},
      );
}

/// The decoded manifest.
class PluginManifest {
  const PluginManifest(
    this.plugins, {
    this.version = manifestVersion,
    this.changes,
    this.identity,
    this.clock,
    this.network,
  });

  final int version;
  final List<PluginDeclaration> plugins;

  /// What the project says about ranking its own changes, or null when it says
  /// nothing.
  ///
  /// Not a plugin, for the same reason the screen it feeds is not one: it
  /// has to be readable for a worktree with no session, which is precisely a
  /// worktree whose plugins have not been resolved.
  final ChangesConfig? changes;

  /// Which package stands for the repository, or null when it says nothing.
  ///
  /// Not a plugin, for the same reason [changes] is not: it describes the
  /// project rather than something mounted in it, and the window that needs it
  /// has to be identifiable before any plugin has resolved.
  final ProjectIdentity? identity;

  /// What `clock.now()` reads in everything this project renders — previews,
  /// scenario steps, store shots — or null for flutterware's own
  /// `pinnedClockOrigin`.
  ///
  /// Not a plugin, for the same reason [changes] and [identity] are not: four
  /// plugins render a screen that can show a date, and a date that differs
  /// between them is a project with four answers. It is one setting because
  /// the thing it buys — two renders of the same code producing the same
  /// picture — is only true if everything renders at the same instant.
  ///
  /// There is deliberately no "the wall clock, always" here. That is the
  /// default this replaced: it makes every capture differ from itself daily,
  /// and previews and store shots have no per-run override to climb back out
  /// with. A single scenario run that wants today's date says `--clock now`.
  ///
  /// It reaches whatever flutterware itself starts. A bare `flutter test` reads
  /// no manifest, so a suite run that way stays on `pinnedClockOrigin` unless
  /// the host says otherwise — `FW_CLOCK`, or the `fw.clock` dart-define,
  /// which is that lane's spelling of this same setting and deliberately the
  /// same name.
  final DateTime? clock;

  /// What this project's scenarios reach when nothing nearer says otherwise,
  /// or null for [ScenarioNetwork.off].
  ///
  /// The **lowest** of the four altitudes, under a folder's
  /// `runScenarios(network: ...)`, a run's `--network=` and a
  /// `scenario(network: ...)`. A project declares what it *is* — a suite that
  /// plays its requests back from a committed recording is a fact about the
  /// project, and repeating it in every folder is how one of them ends up
  /// disagreeing.
  ///
  /// `fw.network(ScenarioNetwork.replay)` is the one worth stating.
  /// [ScenarioNetwork.off] is already the default, and no project should be a
  /// [ScenarioNetwork.live] project.
  final ScenarioNetwork? network;

  /// Every package any plugin names, in declaration order, deduplicated.
  ///
  /// Derived rather than declared. It used to be its own `fw.packages([...])`
  /// call, which meant a package a plugin was configured with but the list
  /// forgot was *silently dropped* from that plugin — the one failure mode a
  /// declaration list exists to prevent. Reading it off the plugins cannot
  /// disagree with them.
  List<Pkg> get packages {
    var byPath = <String, Pkg>{};
    for (var plugin in plugins) {
      for (var entry in (plugin.config['packages'] as List? ?? const [])) {
        if (entry is! Map) continue;
        if (entry['path'] case String path) {
          // First mention wins, so the order is the order they are read in. The
          // plugin's own keys in this entry — `entrypoint`, `directory` — are
          // not this decoder's business and are ignored.
          byPath.putIfAbsent(
            path,
            () => Pkg.fromJson(entry.cast<String, Object?>()),
          );
        }
      }
    }
    return byPath.values.toList();
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'plugins': [for (var p in plugins) p.toJson()],
    'changes': ?changes?.toJson(),
    'identity': ?identity?.toJson(),
    'clock': ?clock?.toIso8601String(),
    'network': ?network?.name,
  };

  static PluginManifest fromJson(Map<String, Object?> json) {
    var version = json['version']! as int;
    if (version != manifestVersion) {
      throw FormatException(
        'Unsupported flutterware manifest version $version '
        '(this build understands $manifestVersion).',
      );
    }
    var plugins = [
      for (var p in (json['plugins']! as List).cast<Map<String, Object?>>())
        PluginDeclaration.fromJson(p),
    ];

    // Checked on the way *in*, not only on the way out. `FlutterwareConfig.use`
    // refuses both of these, but a manifest does not have to have come from
    // `Flutterware.configure` — and a reservation enforced on one side only is
    // a convention, which is not what [Address.shellConfig] claims to be. The
    // failure without this is silent either way: a duplicate id resolves one
    // plugin and drops another, and an id of `config` is shadowed by the
    // shell's own screen with the plugin simply unreachable.
    var seen = <String>{};
    for (var plugin in plugins) {
      if (!seen.add(plugin.id)) {
        throw FormatException('Plugin id "${plugin.id}" is declared twice.');
      }
      if (Address.shellOwned.contains(plugin.id)) {
        throw FormatException(
          'Plugin id "${plugin.id}" is reserved for one of the shell\'s own '
          'screens.',
        );
      }
      if (_duplicatePackagePath(plugin.config) case var path?) {
        throw FormatException(_duplicatePackageMessage(plugin.id, path));
      }
    }

    return PluginManifest(
      plugins,
      version: version,
      changes: switch (json['changes']) {
        Map<Object?, Object?> it => ChangesConfig.fromJson(
          it.cast<String, Object?>(),
        ),
        _ => null,
      },
      identity: switch (json['identity']) {
        Map<Object?, Object?> it => ProjectIdentity.fromJson(
          it.cast<String, Object?>(),
        ),
        _ => null,
      },
      clock: switch (json['clock']) {
        String it => DateTime.tryParse(it),
        _ => null,
      },
      network: switch (json['network']) {
        String it => ScenarioNetwork.values.firstWhereOrNull(
          (mode) => mode.name == it,
        ),
        _ => null,
      },
    );
  }

  static PluginManifest parse(String source) =>
      fromJson(jsonDecode(source) as Map<String, Object?>);
}

/// The object a project's `tool/flutterware.dart` configures.
class FlutterwareConfig {
  final _plugins = <Plugin>[];

  ChangesConfig? _changes;
  ProjectIdentity? _identity;
  DateTime? _clock;
  ScenarioNetwork? _network;

  /// Declares how this project's changes should be ranked. See [ChangesConfig].
  ///
  /// Refused twice rather than merged or overwritten. Two calls would be a
  /// config with two answers, and either resolution loses one of them silently
  /// — which is the failure mode that killed the standalone package list.
  void changes(ChangesConfig config) {
    if (_changes != null) {
      throw StateError(
        'fw.changes was called twice. Declare one ChangesConfig with every '
        'pattern in it.',
      );
    }
    _changes = config;
  }

  /// Declares which package stands for this repository. See [ProjectIdentity].
  ///
  /// Refused twice, like [changes] and for the same reason. A repository
  /// has one face; two calls are a config with two answers, and either
  /// resolution drops one of them without a word.
  void identity(ProjectIdentity config) {
    if (_identity != null) {
      throw StateError(
        'fw.identity was called twice. A repository has one face — declare one '
        'ProjectIdentity.',
      );
    }
    _identity = config;
  }

  /// Declares the instant everything this project renders reads as *now*.
  /// See [PluginManifest.clock].
  ///
  /// A `DateTime`, not a timestamp string. A string buys a `const` call and
  /// costs a `FormatException` thrown a pass later, in a process that is not
  /// this one — and the whole of this file exists to make a rejected config
  /// unwritable rather than reported.
  ///
  /// Refused twice, like [changes] and [identity] and for the same reason.
  void clock(DateTime origin) {
    if (_clock != null) {
      throw StateError(
        'fw.clock was called twice. A project renders at one instant — '
        'declare one.',
      );
    }
    _clock = origin;
  }

  /// Declares what this project's scenarios reach by default. See
  /// [PluginManifest.network].
  ///
  /// Refused twice, like [clock] and for the same reason.
  void network(ScenarioNetwork mode) {
    if (_network != null) {
      throw StateError(
        'fw.network was called twice. A project has one answer to what its '
        'scenarios reach — declare one.',
      );
    }
    _network = mode;
  }

  /// Registers a plugin. The same class may be used more than once as long as
  /// the instances have distinct ids.
  void use(Plugin plugin) {
    if (_plugins.any((p) => p.id == plugin.id)) {
      throw StateError(
        'Duplicate plugin id "${plugin.id}". Give one of them a distinct id.',
      );
    }
    // Refused rather than merely discouraged: `fw:///worktrees/<x>/config` and
    // `…/changes` are the shell's own screens, and a plugin able to take one of
    // those addresses could hide the one place that explains why this file did
    // not load.
    if (Address.shellOwned.contains(plugin.id)) {
      throw StateError(
        'Plugin id "${plugin.id}" is reserved for one of the shell\'s own '
        'screens. Give the plugin a dotted, globally unique id.',
      );
    }
    if (_duplicatePackagePath(plugin.config) case var path?) {
      throw StateError(_duplicatePackageMessage(plugin.id, path));
    }
    _plugins.add(plugin);
  }

  PluginManifest toManifest() => PluginManifest(
    [
      for (var p in _plugins)
        PluginDeclaration(id: p.id, label: p.label, config: p.config),
    ],
    changes: _changes,
    identity: _identity,
    clock: _clock,
    network: _network,
  );
}

/// The package path [config] names twice, or null when each one is named once.
///
/// The path is the identity of a per-package entry, everywhere below this
/// file — a plugin's report children are keyed on it, `fw:///` addresses
/// carry it, and the previews compiler hashes it into a daemon address. So two
/// entries naming one package are not two things the tool could tell apart if
/// it tried: the second one's options are simply unreachable. What actually
/// happened before this check is that the first entry won and its result was
/// emitted once per declaration, which reads as though both had been honoured.
///
/// A plugin whose config says `folders: true` keys on the **folder** instead —
/// the scenarios plugin, whose package may keep a fake-time `test/scenarios`
/// beside a real-time `test/integration` and addresses the second by its
/// directory. For it, two entries are two things when each names its own
/// directory; two for one folder, or a second that names none, are still the
/// fault above.
///
/// Refused rather than merged, for the reason a duplicate plugin id is: a
/// silent resolution loses one of two answers, and this one loses it while
/// showing you a copy of the other.
String? _duplicatePackagePath(Map<String, Object?> config) {
  var byFolder = config[foldersConfigKey] == true;
  var seen = <String, Set<String?>>{};
  for (var entry in (config['packages'] as List? ?? const [])) {
    if (entry is! Map) continue;
    if (entry['path'] case String path) {
      var folders = seen.putIfAbsent(path, () => {});
      var directory = byFolder ? entry['directory'] as String? : null;
      if (!folders.add(directory)) return path;
      if (folders.length > 1 && folders.contains(null)) return path;
    }
  }
  return null;
}

/// The config key a plugin sets to `true` when it addresses a package's
/// folders apart, which is what lets one package be declared once per folder.
const foldersConfigKey = 'folders';

/// Names the way out as well as the fault, because "declared twice" on its own
/// reads as a typo and the case that gets here usually is not one: it is a
/// request for two configurations of one package. That is a reasonable thing to
/// want, and the plugin's own options are where it is expressed — or, for a
/// plugin that keys on folders, a `directory` on each entry.
String _duplicatePackageMessage(String pluginId, String path) =>
    'Plugin "$pluginId" declares package "$path" twice. A package may be '
    'named once per plugin — put every option for it in one entry.';

/// Entry point for a project's `tool/flutterware.dart`:
///
/// ```dart
/// import 'package:flutterware/plugins.dart';
///
/// void main() => Flutterware.configure((fw) {
///   fw.use(Scenarios());
///   fw.use(Previews());
/// });
/// ```
///
/// v1 builds the declaration set, prints the manifest as JSON, and returns. The
/// GUI runs this with a plain `dart run` and reads stdout — no resident
/// compiler, no long-lived config process. When the declarative tier lands this
/// grows a long-lived mode; the config file itself does not change.
class Flutterware {
  static void configure(
    void Function(FlutterwareConfig fw) build, {
    void Function(String line) emit = print,
  }) {
    var config = FlutterwareConfig();
    build(config);
    emit(jsonEncode(config.toManifest().toJson()));
  }
}
