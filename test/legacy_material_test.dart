import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Material and Cupertino are `material_ui` and `cupertino_ui`, and nothing
/// here imports the copies the SDK still carries.
///
/// The two are not aliases. `material_ui` is its own copy of Material, so its
/// `Theme`, `MaterialLocalizations` and `Tooltip` are different types from
/// `package:flutter/material.dart`'s, and an inherited widget one of them
/// provides is invisible to a lookup through the other. A single legacy import
/// does not fail to compile — it compiles, and then a dialog finds no
/// localizations, or a markdown pane falls back to a light theme inside a dark
/// app. So the whole workspace is held to one of them.
///
/// The check reads lines, not directives, so the templates that write an
/// import into somebody else's project — a new preview, a scenario skeleton —
/// are held to it too: an import line inside a string is one a user receives.
void main() {
  var root = Directory.current.path;

  var scanned = [
    'lib',
    'bin',
    'tool',
    'test',
    p.join('app', 'lib'),
    p.join('app', 'bin'),
    p.join('app', 'tool'),
    p.join('app', 'test'),
    p.join('app', 'integration_test'),
    p.join('examples', 'brewline'),
    p.join('fixtures', 'probe_app'),
    'web_demo',
  ];

  /// What a build or the tool wrote: `ephemeral/` holds a desktop runner's
  /// `.plugin_symlinks`, which are the plugins' own trees in the pub cache.
  const generated = {'build', '.dart_tool', 'ephemeral'};

  List<File> sources() => [
    for (var relative in scanned)
      if (Directory(p.join(root, relative)) case var dir when dir.existsSync())
        ...dir
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where(
              (f) => !p
                  .split(p.relative(f.path, from: root))
                  .any(generated.contains),
            ),
  ];

  test('the directories this guards are actually there', () {
    // Without this the whole file passes by scanning nothing, which is how a
    // guard dies silently when a path moves.
    for (var relative in scanned) {
      expect(
        Directory(p.join(root, relative)).existsSync(),
        isTrue,
        reason: '$relative is missing — run this from the repo root',
      );
    }
  });

  test('nothing imports the SDK copy of Material or Cupertino', () {
    var legacy = RegExp(
      r'''^\s*(import|export)\s+['"]package:flutter/(material|cupertino)\.dart['"]''',
      multiLine: true,
    );
    var offenders = [
      for (var file in sources())
        for (var match in legacy.allMatches(file.readAsStringSync()))
          '${p.relative(file.path, from: root)}: ${match.group(0)!.trim()}',
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          "Import package:material_ui/material_ui.dart (or cupertino_ui's). "
          '`dart fix --apply --code=migrate_design_widgets` rewrites a file.',
    );
  });
}
