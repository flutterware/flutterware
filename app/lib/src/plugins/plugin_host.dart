// ignore: implementation_imports
import 'package:flutterware/src/scenarios/network_mode.dart';

import '../previews/catalog_roots.dart';
import '../shell/workspace.dart';
import '../shell/worktree.dart';

/// The handle a native plugin is constructed with: who it is, how the project
/// configured it, and which worktree it is mounted in.
///
/// One host per (plugin, worktree) pair — the same plugin class runs once per
/// open worktree and never shares state across them.
class PluginHost {
  const PluginHost({
    required this.id,
    required this.label,
    required this.worktree,
    required this.workspace,
    this.config = const {},
    this.projectClock,
    this.catalogRoots = const {},
    this.projectNetwork,
    this.peers = const {},
  });

  /// The declared id — also the registry key its implementation was found by.
  final String id;

  /// The label the project declared, or the plugin's default.
  final String label;

  final Worktree worktree;

  /// The worktree's packages, and the services for each — built on demand.
  final Workspace workspace;

  /// What the project declared with `fw.clock(...)`, or null for
  /// flutterware's own pin.
  ///
  /// The one project-level fact a plugin is handed rather than a shell screen,
  /// because four plugins render a date and they have to render the same one.
  final DateTime? projectClock;

  /// What the project declared with `fw.network(...)`, or null for
  /// [ScenarioNetwork.off] — the lowest altitude of the four.
  final ScenarioNetwork? projectNetwork;

  /// Whatever `tool/flutterware.dart` passed for this instance. Already decoded
  /// from the manifest; plugins are responsible for validating their own keys.
  final Map<String, Object?> config;

  /// Where the catalog discovers preview entries, per package — the previews
  /// plugin's declaration, resolved once for the whole project.
  ///
  /// Handed to every plugin rather than read by each, because the daemon's
  /// address hashes its roots: a plugin that renders through the catalog with
  /// roots of its own does not get a narrower catalog, it gets a **second
  /// compiler** on the same files. See [catalogRootsFrom].
  final Map<String, List<String>> catalogRoots;

  /// Where the catalog looks for entries in [package].
  ///
  /// Ask this before building a `DaemonConfig` or a `CatalogSession`. A plugin
  /// that also scans sources of its own — scene looking for `*.scene.dart` —
  /// keeps that directory separate: where to *scan* and where the catalog
  /// *renders from* are different questions with one right answer each.
  ///
  /// Falls back to this host's **own** declaration when the project-wide map
  /// has nothing, which is what a host built outside [PluginCoreRegistry] gets
  /// — a unit test holding one core, mostly. That keeps a plugin reading its
  /// own config in isolation and changes nothing about the resolved case: the
  /// map is what makes two plugins agree, and only the registry can build it.
  List<String> catalogRootsFor(String package) =>
      catalogRoots[package] ?? [_declaredDirectory(package)];

  /// The `directory` this plugin declared for [package], or the whole package.
  String _declaredDirectory(String package) {
    for (var config in packageConfigs) {
      if (config['path'] != package) continue;
      var directory = config['directory'];
      if (directory is String && directory.isNotEmpty) return directory;
    }
    return defaultCatalogRoot;
  }

  /// Every plugin the project declared, by id, as its config — for a plugin
  /// that works with what another declares. A world's people launch Run's
  /// entry points, so worlds read Run's declaration rather than ask the
  /// project to name them twice.
  final Map<String, Map<String, Object?>> peers;

  /// The `packages:` entries plugin [id] was declared with, as raw maps —
  /// what [packageConfigs] is for this one.
  List<Map<String, Object?>> packageConfigsOf(String id) => [
    for (var entry in (peers[id]?['packages'] as List? ?? const []))
      if (entry is Map) entry.cast<String, Object?>(),
  ];

  /// Reads a string setting, or [fallback] when absent or the wrong type.
  String? string(String key, [String? fallback]) {
    var value = config[key];
    return value is String ? value : fallback;
  }

  /// Reads a bool setting, or [fallback] when absent or the wrong type.
  bool boolean(String key, {bool fallback = false}) {
    var value = config[key];
    return value is bool ? value : fallback;
  }

  /// The `packages:` entries this plugin was declared with, as raw maps. Each
  /// plugin decodes its own per-package shape; the framework only guarantees a
  /// `path`.
  List<Map<String, Object?>> get packageConfigs => [
    for (var entry in (config['packages'] as List? ?? const []))
      if (entry is Map) entry.cast<String, Object?>(),
  ];

  /// Declared package paths, filtered to those the workspace knows about, so a
  /// typo cannot make a plugin operate on a directory that is not there.
  List<String> get packagePaths => [
    for (var entry in packageConfigs)
      if (entry['path'] is String) entry['path']! as String,
  ];
}
