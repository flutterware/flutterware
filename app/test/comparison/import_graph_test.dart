import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/comparison/closure.dart';
import 'package:flutterware_app/src/comparison/import_graph.dart';
import 'package:flutterware_app/src/comparison/skip.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What an entry reads, worked out by following its imports — the skip rule's
/// missing half, and the reason it can decide before anything is compiled.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw_graph'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String source) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
  }

  /// A `package_config.json` mapping [names] to their `lib/` inside the
  /// checkout, written where a workspace puts it.
  void packages(Map<String, String> names) {
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (var entry in names.entries)
            {
              'name': entry.key,
              'rootUri': '../${entry.value}',
              'packageUri': 'lib/',
            },
        ],
      }),
    );
  }

  ImportGraph graph() => ImportGraph.read(
    root: root.path,
    packageConfig: p.join(root.path, '.dart_tool', 'package_config.json'),
  );

  test('an entry reads itself', () {
    write('demo/card.dart', 'const card = 1;');

    expect(graph().closureOf('demo/card.dart'), ['demo/card.dart']);
  });

  test('a relative import is followed, and so is its import', () {
    write('demo/card.dart', "import 'shell.dart';");
    write('demo/shell.dart', "import '../lib/theme.dart';");
    write('lib/theme.dart', 'const blue = 1;');

    expect(graph().closureOf('demo/card.dart'), [
      'demo/card.dart',
      'demo/shell.dart',
      'lib/theme.dart',
    ]);
  });

  test('a package: import inside the checkout is followed', () {
    packages({'app': 'packages/app'});
    write('demo/card.dart', "import 'package:app/theme.dart';");
    write('packages/app/lib/theme.dart', 'const blue = 1;');

    expect(
      graph().closureOf('demo/card.dart'),
      contains('packages/app/lib/theme.dart'),
    );
  });

  // The SDK and the pub cache cannot change without changing something inside
  // the checkout: a different resolution rewrites `package_config.json`.
  test('a package outside the checkout is not in the closure', () {
    write('demo/card.dart', '''
import 'dart:async';
import 'package:material_ui/material_ui.dart';
''');

    expect(graph().closureOf('demo/card.dart'), ['demo/card.dart']);
  });

  // A part is not an import, but it is unquestionably read, and a change to
  // one changes the library.
  test('a part counts', () {
    write('demo/card.dart', "part 'card.g.dart';");
    write('demo/card.g.dart', 'const generated = 1;');

    expect(graph().closureOf('demo/card.dart'), contains('demo/card.g.dart'));
  });

  test('an export counts', () {
    write('demo/card.dart', "export 'shell.dart';");
    write('demo/shell.dart', 'const shell = 1;');

    expect(graph().closureOf('demo/card.dart'), contains('demo/shell.dart'));
  });

  // Which branch the compiler takes depends on the platform being built for,
  // and guessing wrong drops a real dependency.
  test('both branches of a conditional import count', () {
    write('demo/card.dart', '''
import 'stub.dart'
    if (dart.library.io) 'io.dart'
    if (dart.library.js_interop) 'web.dart';
''');
    write('demo/stub.dart', '');
    write('demo/io.dart', '');
    write('demo/web.dart', '');

    var closure = graph().closureOf('demo/card.dart');

    expect(closure, contains('demo/stub.dart'));
    expect(closure, contains('demo/io.dart'));
    expect(closure, contains('demo/web.dart'));
  });

  test('a cycle terminates', () {
    write('demo/a.dart', "import 'b.dart';");
    write('demo/b.dart', "import 'a.dart';");

    expect(graph().closureOf('demo/a.dart'), ['demo/a.dart', 'demo/b.dart']);
  });

  // Unparseable Dart is still a file the entry reads; what it imports is
  // simply unknown, and its digest still guards the entry.
  test('a file that does not parse stays in the closure', () {
    write('demo/card.dart', "import 'broken.dart';");
    write('demo/broken.dart', 'this is not dart at all {{{');

    expect(graph().closureOf('demo/card.dart'), contains('demo/broken.dart'));
  });

  test('an import naming a file that is gone is not fatal', () {
    write('demo/card.dart', "import 'missing.dart';");

    expect(graph().closureOf('demo/card.dart'), contains('demo/missing.dart'));
  });

  // A checkout that has not been resolved yet still has files, and answering
  // "I cannot tell" for its package: imports means more rendering rather than
  // wrong rendering.
  test('no package config degrades rather than throws', () {
    write('demo/card.dart', """
import 'package:app/theme.dart';
import 'shell.dart';
""");
    write('demo/shell.dart', '');

    var closure = ImportGraph.read(root: root.path).closureOf('demo/card.dart');

    expect(closure, ['demo/card.dart', 'demo/shell.dart']);
  });

  // The point of the whole file: with the graph as the memo's writer, the skip
  // rule can answer before anything is compiled.
  test('the graph is what the skip rule was missing', () {
    write('demo/card.dart', "import '../lib/theme.dart';");
    write('lib/theme.dart', 'const blue = 1;');

    var memo = ClosureMemo(p.join(root.path, 'memo'))
      ..remember('demo/card.dart#card', graph().closureOf('demo/card.dart'));

    // A second checkout where the theme, three imports away, moved.
    var other = Directory(p.join(root.path, 'other'))..createSync();
    File(p.join(other.path, 'demo', 'card.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync("import '../lib/theme.dart';");
    File(p.join(other.path, 'lib', 'theme.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('const green = 1;');

    var decision = SkipDecision.of(
      entryId: 'demo/card.dart#card',
      memo: memo,
      baseRoot: root.path,
      headRoot: other.path,
    );

    expect(decision.skip, isFalse);
    expect(decision.changed, ['lib/theme.dart']);
  });
}
