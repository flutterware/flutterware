import 'dart:io';

import 'package:flutterware_app/src/comparison/closure.dart';
import 'package:flutterware_app/src/comparison/import_graph.dart';
import 'package:flutterware_app/src/comparison/lock_inputs.dart';
import 'package:flutterware_app/src/comparison/skip.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The lockfile, per package rather than whole.
///
/// It used to be one input like any other, so one changed byte anywhere in it
/// re-rendered and re-replayed the project. Measured on this repository:
/// `217 entries, 430 rendered, 0 skipped` — `because pubspec.lock differs`.
/// In CI that is every dependency bump.
///
/// Everything here is about the two directions this must not get wrong: a
/// package the entry reaches must never be dropped, and a package it does not
/// must not cost a render.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw_lock'));
  tearDown(() => root.deleteSync(recursive: true));

  String lockOf(Map<String, String> versions) => [
    'packages:',
    for (var entry in versions.entries) ...[
      '  ${entry.key}:',
      '    dependency: "direct main"',
      '    source: hosted',
      '    version: "${entry.value}"',
    ],
    'sdks:',
    '  dart: ">=3.0.0 <4.0.0"',
  ].join('\n');

  /// A checkout whose package graph says [graph] and whose lock says
  /// [versions].
  String checkout(
    String name, {
    required Map<String, String> versions,
    Map<String, List<String>> graph = const {},
    Map<String, String> files = const {},
    bool withGraph = true,
  }) {
    var dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    void write(String relative, String content) {
      File(p.join(dir.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    write('pubspec.lock', lockOf(versions));
    if (withGraph) {
      write('.dart_tool/package_graph.json', '''
{"roots":["pkg"],"packages":[
  {"name":"pkg","dependencies":${_json(graph['pkg'] ?? const [])}},
  ${[for (var entry in graph.entries)
        if (entry.key != 'pkg') '{"name":"${entry.key}","dependencies":${_json(entry.value)}}'].join(',')}
  ${graph.keys.where((k) => k != 'pkg').isEmpty ? '' : ','}
  {"name":"unrelated","dependencies":[]}
]}''');
    }
    files.forEach(write);
    return dir.path;
  }

  ImportGraph graphIn(String checkout) => ImportGraph.read(
    root: checkout,
    packageConfig: p.join(checkout, '.dart_tool', 'package_config.json'),
  );

  /// The skip decision for an entry whose closure is [file].
  SkipDecision decide({
    required String base,
    required String head,
    required String file,
  }) {
    var memo = ClosureMemo(p.join(root.path, 'memo'))..remember('e', [file]);
    return SkipDecision.of(
      entryId: 'e',
      memo: memo,
      baseRoot: base,
      headRoot: head,
      lock: LockSides(
        packagePath: '.',
        roots: [head, base],
      ).forPackages(graphIn(head).packagesOf(file)),
    );
  }

  group('a bump the entry cannot reach', () {
    test('does not render it', () {
      var source = "import 'package:used/used.dart';\nvar a = 1;\n";
      var base = checkout(
        'base',
        versions: {'used': '1.0.0', 'unrelated': '1.0.0'},
        graph: {
          'pkg': ['used'],
        },
        files: {'lib/a.dart': source},
      );
      var head = checkout(
        'head',
        versions: {'used': '1.0.0', 'unrelated': '2.0.0'},
        graph: {
          'pkg': ['used'],
        },
        files: {'lib/a.dart': source},
      );

      expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isTrue);
    });
  });

  group('a bump the entry can reach', () {
    test('renders it, and says which package moved', () {
      var source = "import 'package:used/used.dart';\nvar a = 1;\n";
      var base = checkout(
        'base',
        versions: {'used': '1.0.0'},
        graph: {
          'pkg': ['used'],
        },
        files: {'lib/a.dart': source},
      );
      var head = checkout(
        'head',
        versions: {'used': '2.0.0'},
        graph: {
          'pkg': ['used'],
        },
        files: {'lib/a.dart': source},
      );

      var decision = decide(base: base, head: head, file: 'lib/a.dart');
      expect(decision.skip, isFalse);
      // `pubspec.lock differs` said only that something moved.
      expect(decision.reason, 'pubspec.lock#used differs');
    });

    // An entry that imports `flutter_svg` has never heard of `vector_math`,
    // and a bump to it changes what the entry draws all the same.
    test('through a dependency of a dependency', () {
      var source = "import 'package:used/used.dart';\nvar a = 1;\n";
      var files = {'lib/a.dart': source};
      var graph = {
        'pkg': ['used'],
        'used': ['deep'],
      };
      var base = checkout(
        'base',
        versions: {'used': '1.0.0', 'deep': '1.0.0'},
        graph: graph,
        files: files,
      );
      var head = checkout(
        'head',
        versions: {'used': '1.0.0', 'deep': '2.0.0'},
        graph: graph,
        files: files,
      );

      expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isFalse);
    });

    // A package's *pictures* are reached by naming it in a string, and its
    // import graph says nothing at all.
    test('named only as an asset', () {
      var source = "var a = Image.asset('x.png', package: 'icons');\n";
      var files = {'lib/a.dart': source};
      var graph = {'pkg': <String>[]};
      var base = checkout(
        'base',
        versions: {'icons': '1.0.0'},
        graph: graph,
        files: files,
      );
      var head = checkout(
        'head',
        versions: {'icons': '2.0.0'},
        graph: graph,
        files: files,
      );

      expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isFalse);
    });

    test('named only as a bundle path', () {
      var source = "var a = 'packages/icons/logo.png';\n";
      var files = {'lib/a.dart': source};
      var graph = {'pkg': <String>[]};
      var base = checkout(
        'base',
        versions: {'icons': '1.0.0'},
        graph: graph,
        files: files,
      );
      var head = checkout(
        'head',
        versions: {'icons': '2.0.0'},
        graph: graph,
        files: files,
      );

      expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isFalse);
    });
  });

  // The obvious "belongs to no package, so everything carries it" input, and
  // measuring it is what killed it: on a base whose Dart floor had moved, that
  // one line put 145 of 244 entries back into the render pass. A constraint is
  // not a resolution — both sides render with the same SDK, which the shot key
  // already carries.
  test('a change to the sdk constraint reaches nothing', () {
    var files = {'lib/a.dart': 'var a = 1;\n'};
    var base = checkout('base', versions: {'used': '1.0.0'}, files: files);
    var head = checkout('head', versions: {'used': '1.0.0'}, files: files);
    File(p.join(head, 'pubspec.lock')).writeAsStringSync(
      '${lockOf({'used': '1.0.0'}).split('sdks:').first}sdks:\n'
      '  dart: ">=3.9.0 <4.0.0"\n',
    );

    expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isTrue);
  });

  // Without the graph a reached package's own dependencies are invisible, and
  // narrowing to a set that stops at the first hop would miss the very bump it
  // was asked about. So it does not narrow at all.
  test('a checkout with no package graph falls back to the whole lock', () {
    var files = {'lib/a.dart': 'var a = 1;\n'};
    var base = checkout(
      'base',
      versions: {'unrelated': '1.0.0'},
      files: files,
      withGraph: false,
    );
    var head = checkout(
      'head',
      versions: {'unrelated': '2.0.0'},
      files: files,
      withGraph: false,
    );

    expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isFalse);
  });

  // A monorepo that is not a pub workspace resolves each package beside
  // itself, and has no `.dart_tool` at the top at all. Looking only there
  // refused the split for every one of its packages — safely, and for exactly
  // the repositories with the most packages.
  test('a package resolved on its own narrows too', () {
    String standalone(String name, String unrelated) {
      var dir = Directory(p.join(root.path, name))..createSync();
      void write(String relative, String content) {
        File(p.join(dir.path, relative))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      write(
        'pkg/pubspec.lock',
        lockOf({'used': '1.0.0', 'unrelated': unrelated}),
      );
      write(
        'pkg/.dart_tool/package_graph.json',
        '{"roots":["pkg"],"packages":['
            '{"name":"pkg","dependencies":["used"]},'
            '{"name":"used","dependencies":[]},'
            '{"name":"unrelated","dependencies":[]}]}',
      );
      write('pkg/lib/a.dart', "import 'package:used/used.dart';\n");
      return dir.path;
    }

    var base = standalone('base', '1.0.0');
    var head = standalone('head', '2.0.0');
    var memo = ClosureMemo(p.join(root.path, 'memo'))
      ..remember('e', ['pkg/lib/a.dart']);
    var decision = SkipDecision.of(
      entryId: 'e',
      memo: memo,
      baseRoot: base,
      headRoot: head,
      lock: LockSides(
        packagePath: 'pkg',
        roots: [head, base],
      ).forPackages({'used'}),
    );

    expect(decision.skip, isTrue);
  });

  test('an unparseable lock falls back to the whole lock', () {
    var files = {'lib/a.dart': 'var a = 1;\n'};
    var base = checkout('base', versions: {'unrelated': '1.0.0'}, files: files);
    var head = checkout('head', versions: {'unrelated': '1.0.0'}, files: files);
    File(p.join(head, 'pubspec.lock')).writeAsStringSync('packages: [oh: :\n');

    expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isFalse);
  });

  // Two checkouts whose resolution is identical must hash identically, and
  // nothing promises pub writes a map in one order forever.
  // Removing a direct dependency something else still pulls in flips it to
  // `transitive` with the same source and version: a fact about the pubspec,
  // not about the resolution.
  test('a dependency turning transitive is not a change', () {
    var base = checkout(
      'base_kind',
      versions: {'http': '1.2.0'},
      graph: {
        'pkg': ['http'],
      },
    );
    var head = checkout(
      'head_kind',
      versions: {'http': '1.2.0'},
      graph: {
        'pkg': ['http'],
      },
    );
    var lock = File(p.join(head, 'pubspec.lock'));
    lock.writeAsStringSync(
      lock.readAsStringSync().replaceFirst('"direct main"', 'transitive'),
    );

    var baseInputs = LockInputs.of(root: base, packagePath: '.');
    var headInputs = LockInputs.of(root: head, packagePath: '.');

    expect(headInputs.forPackages({'http'}), baseInputs.forPackages({'http'}));
  });

  test('the order keys were written in is not a change', () {
    var files = {'lib/a.dart': "import 'package:used/used.dart';\n"};
    var graph = {
      'pkg': ['used'],
    };
    var base = checkout(
      'base',
      versions: {'used': '1.0.0'},
      graph: graph,
      files: files,
    );
    var head = checkout(
      'head',
      versions: {'used': '1.0.0'},
      graph: graph,
      files: files,
    );
    File(p.join(head, 'pubspec.lock')).writeAsStringSync(
      'packages:\n'
      '  used:\n'
      '    version: "1.0.0"\n'
      '    source: hosted\n'
      '    dependency: "direct main"\n'
      'sdks:\n'
      '  dart: ">=3.0.0 <4.0.0"\n',
    );

    expect(decide(base: base, head: head, file: 'lib/a.dart').skip, isTrue);
  });
}

String _json(List<String> names) =>
    '[${names.map((name) => '"$name"').join(',')}]';
