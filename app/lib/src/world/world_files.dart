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

  /// Why it cannot be opened — its file is not there — or null.
  final String? problem;

  /// What `worlds open` takes: the file's name without `.dart`.
  String get id => p.posix.basenameWithoutExtension(path);
}

/// The worlds one package's declaration lists, as the manifest carries it:
/// `{path, worlds: [{path, name?, description?}]}`. A world whose file is not
/// there is still listed, with the reason it cannot open.
List<WorldFile> declaredWorlds({
  required Map<String, Object?> config,
  required String packageRoot,
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
                ? null
                : '$package/$path does not exist.',
          ),
  ];
}

/// `pickup_order` as `Pickup order`.
String worldName(String stem) {
  var words = stem.split(RegExp('[_-]+')).where((w) => w.isNotEmpty).join(' ');
  return words.isEmpty ? stem : words[0].toUpperCase() + words.substring(1);
}
