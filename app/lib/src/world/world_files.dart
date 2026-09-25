import 'dart:io';

import 'package:path/path.dart' as p;

/// One world a project declares: a file in a declared package's worlds folder
/// whose `main` calls `World.run`.
class WorldFile {
  const WorldFile({
    required this.package,
    required this.path,
    required this.name,
    this.description,
  });

  /// The package it runs in, relative to the worktree.
  final String package;

  /// Package-relative, `/`-separated: `worlds/pickup_order.dart`.
  final String path;

  /// What to call it: the file's name as words, `Pickup order`.
  final String name;

  /// The doc comment on its `main`, or on the library when `main` has none.
  final String? description;

  /// What `worlds open` takes: the file's name without `.dart`.
  String get id => p.posix.basenameWithoutExtension(path);
}

/// The worlds in [directory] of the package at [packageRoot] — the folder's
/// own files, never its subfolders, which is where the helpers worlds share
/// go. A file is a world when it calls `World.run`; anything else there is
/// not offered.
List<WorldFile> scanWorlds({
  required String package,
  required String packageRoot,
  required String directory,
}) {
  var folder = Directory(p.join(packageRoot, directory));
  if (!folder.existsSync()) return const [];
  var files =
      folder
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (var file in files)
      if (file.readAsStringSync() case var source
          when source.contains('World.run('))
        WorldFile(
          package: package,
          path: p.posix.join(directory, p.basename(file.path)),
          name: worldName(p.basenameWithoutExtension(file.path)),
          description: worldDescription(source),
        ),
  ];
}

/// `pickup_order` as `Pickup order`.
String worldName(String stem) {
  var words = stem.split(RegExp('[_-]+')).where((w) => w.isNotEmpty).join(' ');
  return words.isEmpty ? stem : words[0].toUpperCase() + words.substring(1);
}

/// The doc comment above `main`, else the library's — the lines joined into
/// paragraphs, the way a reader of the file sees them.
String? worldDescription(String source) {
  var lines = source.split('\n');
  var main = lines.indexWhere((line) => RegExp(r'\bmain\s*\(').hasMatch(line));
  var above = <String>[];
  for (var i = main - 1; i >= 0 && lines[i].trimLeft().startsWith('///'); i--) {
    above.insert(0, lines[i]);
  }
  if (above.isEmpty) {
    for (var line in lines) {
      if (line.trimLeft().startsWith('///')) {
        above.add(line);
      } else if (above.isNotEmpty) {
        break;
      }
    }
  }
  if (above.isEmpty) return null;
  var paragraphs = <String>[];
  var current = <String>[];
  for (var line in above) {
    var text = line.trimLeft().substring(3).trim();
    if (text.isEmpty) {
      if (current.isNotEmpty) paragraphs.add(current.join(' '));
      current = [];
    } else {
      current.add(text);
    }
  }
  if (current.isNotEmpty) paragraphs.add(current.join(' '));
  return paragraphs.join('\n\n');
}
