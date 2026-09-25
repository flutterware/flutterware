import 'dart:io';

import 'package:path/path.dart' as p;

/// One world a project declares — a `WorldScript` in `tool/flutterware.dart`.
class WorldFile {
  const WorldFile({
    required this.package,
    required this.path,
    required this.name,
    this.description,
    this.problem,
  });

  /// The package it runs in, relative to the worktree.
  final String package;

  /// Package-relative, `/`-separated: `tool/worlds/pickup_order.dart`.
  final String path;

  /// What to call it: the declared name, or the file's name as words.
  final String name;

  final String? description;

  /// Why it cannot be opened — its file is not there, or this machine is not
  /// one a world opens on — or null.
  final String? problem;

  /// What `worlds open` takes: the file's name without `.dart`.
  String get id => p.posix.basenameWithoutExtension(path);
}

/// The worlds one package's declaration lists, as the manifest carries it:
/// `{path, worlds: [{path, name?, description?}]}`. A world that cannot open
/// is still listed, with the reason: its file is not there, or [unsupported],
/// why none opens on this machine.
List<WorldFile> declaredWorlds({
  required Map<String, Object?> config,
  required String packageRoot,
  String? unsupported,
}) {
  var package = config['path']! as String;
  return [
    for (var entry in config['worlds'] as List? ?? const [])
      if (entry is Map)
        if (entry['path'] case String path)
          WorldFile(
            package: package,
            path: path,
            name:
                entry['name'] as String? ??
                worldName(p.posix.basenameWithoutExtension(path)),
            description: entry['description'] as String?,
            problem: File(p.join(packageRoot, path)).existsSync()
                ? unsupported
                : '$package/$path does not exist.',
          ),
  ];
}

/// Why no world opens on this machine, or null. Each person's app runs in the
/// studio's guest, and only the macOS guest has been made to answer a phone's
/// plugins: elsewhere nothing has been tried, and the people's folders would
/// not even be kept apart — `CFFIXED_USER_HOME` is macOS's.
String? worldsUnsupported({bool? macOS}) => (macOS ?? Platform.isMacOS)
    ? null
    : "Worlds open on macOS only for now: each person's app runs in the "
          "studio's guest, and only the macOS guest answers a phone's plugins.";

/// `pickup_order` as `Pickup order`.
String worldName(String stem) {
  var words = stem.split(RegExp('[_-]+')).where((w) => w.isNotEmpty).join(' ');
  return words.isEmpty ? stem : words[0].toUpperCase() + words.substring(1);
}
