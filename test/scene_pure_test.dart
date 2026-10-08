// The scene authoring core and both grammars must stay importable by a plain
// `dart` process — the fw CLI, the MCP server, a codemod. One Flutter (or
// dart:ui) import anywhere in their graphs and every headless touch of a scene
// file starts paying a flutter_tester boot. In the ambient_sdk_test mould: a
// static walk, offline.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the scene core and grammars import no Flutter', () {
    // Entry points of the pure surface; the walk is transitive over
    // relative and package:flutterware/ imports.
    var roots = [
      'lib/scene_authoring.dart',
      'app/lib/src/scene/scene_file.dart',
      'app/lib/src/scene/motion_file.dart',
      'app/lib/src/scene/editor.dart',
      'app/lib/src/scene/workspace.dart',
    ];
    var seen = <String>{};
    var queue = [...roots];
    var offenses = <String>[];
    var importLine = RegExp(r"^\s*(?:import|export)\s+'([^']+)'");
    while (queue.isNotEmpty) {
      var path = queue.removeLast();
      if (!seen.add(path)) continue;
      var file = File(path);
      expect(file.existsSync(), true, reason: 'walked to missing file $path');
      for (var line in file.readAsLinesSync()) {
        var uri = importLine.firstMatch(line)?.group(1);
        if (uri == null) continue;
        if (uri.startsWith('package:flutter/') || uri == 'dart:ui') {
          offenses.add('$path imports $uri');
        } else if (uri.startsWith('package:flutterware/')) {
          queue.add(uri.replaceFirst('package:flutterware/', 'lib/'));
        } else if (uri.startsWith('package:flutterware_app/')) {
          queue.add(uri.replaceFirst('package:flutterware_app/', 'app/lib/'));
        } else if (!uri.startsWith('package:') && !uri.startsWith('dart:')) {
          var dir = path.substring(0, path.lastIndexOf('/'));
          queue.add(Uri.parse('$dir/$uri').normalizePath().toString());
        }
        // Other packages (analyzer, dart_style) are pure Dart; if one ever
        // grows a Flutter dependency the analyzer refuses long before this.
      }
    }
    expect(
      offenses,
      isEmpty,
      reason:
          'the pure scene surface reached Flutter — move the offending code '
          'behind lib/scene.dart (the Flutter half) or convert the value at '
          'the bridge',
    );
  });
}
