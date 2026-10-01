import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/previews/error_location.dart';
import 'package:path/path.dart' as p;

/// Which frame an error is traced back to. The guest keeps the frames; the
/// choice is made here, where the project is known.
void main() {
  var worktree = p.join(p.rootPrefix(Directory.current.path), 'work', 'tree');
  String file(String relative) => '${p.toUri(p.join(worktree, relative))}';

  var locator = ErrorLocator(worktree: worktree, ownPackages: {'app', 'ui'});

  test("the project's own frame over a dependency's above it", () {
    // A theme that called into a font package which threw: the package's
    // frame is nearer, and the theme's is the one somebody can edit.
    expect(
      locator.locate([
        'package:some_fonts/src/load.dart:12:5',
        'package:ui/src/theme.dart:42:7',
      ]),
      'package:ui/src/theme.dart:42:7',
    );
  });

  test('a file in the worktree reads relative to it', () {
    expect(
      locator.locate([file('app/demo/probes.dart:30:3')]),
      'app/demo/probes.dart:30:3',
    );
  });

  test('what flutterware ran the entry under is never the answer', () {
    expect(
      locator.locate([
        file('app/build/flutterware/previews_harness/entry_3.dart:9:1'),
        'package:flutterware/src/previews/harness.dart:771:25',
        'package:app/src/theme.dart:42:7',
      ]),
      'package:app/src/theme.dart:42:7',
    );
  });

  test("a dependency's frame when there is nothing of the project's", () {
    expect(
      locator.locate(['package:some_fonts/src/load.dart:12:5']),
      'package:some_fonts/src/load.dart:12:5',
    );
    expect(locator.locate(const []), isNull);
    expect(
      locator.locate(['package:flutterware/src/previews/harness.dart:1:1']),
      isNull,
    );
  });

  test('its own packages are the ones resolved inside the worktree', () {
    var root = Directory.systemTemp.createTempSync('fw_error_location');
    addTearDown(() => root.deleteSync(recursive: true));
    var tree = p.join(root.path, 'tree');
    Directory(p.join(tree, '.dart_tool')).createSync(recursive: true);
    Directory(p.join(tree, 'packages', 'ui')).createSync(recursive: true);
    File(p.join(tree, '.dart_tool', 'package_config.json')).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
          {'name': 'ui', 'rootUri': '../packages/ui', 'packageUri': 'lib/'},
          {
            'name': 'some_fonts',
            'rootUri': '${p.toUri(p.join(root.path, 'cache', 'some_fonts'))}',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    var found = ErrorLocator.forPackage(
      p.join(tree, 'packages', 'ui'),
      worktree: tree,
    );
    expect(found.ownPackages, {'app', 'ui'});
  });
}
