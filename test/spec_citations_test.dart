import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Nothing outside `docs/superpowers/` cites the specs, plans and findings
/// kept there.
///
/// They are working notes. A reader of the code, the guides or the app cannot
/// do anything with "Design: docs/superpowers/specs/…" or "see the design note
/// §9", so a comment states the reason itself and a message says what to do.
void main() {
  var root = Directory.current.path;

  /// Directories never read: git's, a build's or a tool's output, and the
  /// notes themselves.
  const skipped = {'build', 'ephemeral', 'node_modules', 'Pods'};
  var notes = p.join('docs', 'superpowers');

  /// Files allowed to name the folder, and why.
  var exempt = {
    // Instructions for coding agents, which do read the notes.
    'CLAUDE.md',
    // Configuration: the changes tool flags an edited spec for attention.
    p.join('tool', 'flutterware.dart'),
    // This file.
    p.join('test', 'spec_citations_test.dart'),
  };

  const extensions = {
    '.dart',
    '.md',
    '.yaml',
    '.yml',
    '.c',
    '.h',
    '.cc',
    '.mm',
    '.swift',
    '.svg',
    '.sh',
  };

  Iterable<File> files(Directory dir) sync* {
    for (var entity in dir.listSync(followLinks: false)) {
      var name = p.basename(entity.path);
      var relative = p.relative(entity.path, from: root);
      if (entity is Directory) {
        if (name.startsWith('.') && name != '.github') continue;
        if (skipped.contains(name) || relative == notes) continue;
        yield* files(entity);
      } else if (entity is File &&
          extensions.contains(p.extension(name)) &&
          !exempt.contains(relative)) {
        yield entity;
      }
    }
  }

  test('the repository root is where this runs', () {
    // Run from anywhere else, the scan would find nothing and pass.
    expect(File(p.join(root, 'CLAUDE.md')).existsSync(), isTrue);
    expect(Directory(p.join(root, notes)).existsSync(), isTrue);
  });

  test('nothing cites the design notes', () {
    var citation = RegExp(
      r'docs/superpowers'
      r'|\b\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.md\b'
      r'|\bdesign (?:doc|note)s?\b',
      caseSensitive: false,
    );
    var offenders = <String>[];
    for (var file in files(Directory(root))) {
      String text;
      try {
        text = file.readAsStringSync();
      } on FileSystemException {
        continue; // Not UTF-8: not prose anybody reads.
      }
      var lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (citation.hasMatch(lines[i])) {
          offenders.add(
            '${p.relative(file.path, from: root)}:${i + 1}: '
            '${lines[i].trim()}',
          );
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Write the reason in place of the pointer, or drop the pointer. '
          'The notes in docs/superpowers/ are for agents working on this '
          'repository, not for its readers.',
    );
  });
}
