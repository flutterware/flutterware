import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/run/entrypoint_knobs.dart';
import 'package:flutterware_app/src/run/entrypoints.dart';
import 'package:path/path.dart' as p;

/// What a launch form can know about an entry point without building it.
void main() {
  late Directory package;

  setUp(() {
    package = Directory.systemTemp.createTempSync('fw-ep-knobs-');
    File(p.join(package.path, 'pubspec.yaml')).writeAsStringSync('name: myapp');
  });
  tearDown(() => package.deleteSync(recursive: true));

  void write(String relative, String content) =>
      File(p.join(package.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);

  EntrypointKnobs scan([String entrypoint = 'lib/main.dart']) =>
      scanEntrypointKnobs(packageRoot: package.path, entrypoint: entrypoint);

  test('reads the signature, enums included', () {
    write('lib/src/backend.dart', 'enum Backend { dev, staging, prod }');
    write('lib/main.dart', '''
import 'src/backend.dart';

void main({
  String apiHost = 'localhost',
  int serverPort = 8086,
  Backend backend = Backend.staging,
}) {}
''');

    var found = scan();

    expect(found.knobs.map((k) => k.name), [
      'apiHost',
      'serverPort',
      'backend',
    ]);
    expect(found.knobs.last.knob.kind, KnobKind.picker);
    expect(found.knobs.last.knob.options, ['dev', 'staging', 'prod']);
    expect(found.knobs.last.knob.defaultValue, 'staging');
    expect(found.knobs.last.enumType, 'Backend');
    expect(found.undrawable, isEmpty);
  });

  test('an entry point taking nothing offers nothing', () {
    // The `Studio (dev)` case: the package-level define scan put four constants
    // belonging to another entry point on this one's form. A signature cannot.
    write('lib/main.dart', 'void main() {}');

    expect(scan().knobs, isEmpty);
  });

  test('a main that takes args is still a main', () {
    write('lib/main.dart', 'void main(List<String> args, {int port = 1}) {}');

    expect(scan().knobs.single.name, 'port');
  });

  test('a file with no main at all is empty, not an error', () {
    write('lib/main.dart', 'const x = 1;');

    expect(scan().knobs, isEmpty);
    expect(scan().undrawable, isEmpty);
  });

  test('a parameter with no drawable type is reported, by name', () {
    write('lib/main.dart', 'void main({Uri base = someUri}) {}');

    expect(scan().knobs, isEmpty);
    // Keyed rather than prose, because the surfaces have to join it back to the
    // parameter: a knob declared for one of these was reported as a parameter
    // `main` does not take.
    expect(scan().undrawable.single.name, 'base');
    expect(scan().undrawable.single.reason, contains('is `Uri`'));
  });

  test('an enum from another package of the workspace is a picker', () {
    // A shared package is the ordinary monorepo shape — the enum lives in one
    // place precisely so two apps cannot disagree about what `staging` means —
    // and every such knob came back as a parameter `main` does not take. The
    // resolution lives in one `.dart_tool/package_config.json` at the workspace
    // root; a member has no copy of its own.
    write(
      'pubspec.yaml',
      'name: monorepo\nworkspace:\n  - mobile\n  - shared\n',
    );
    write('shared/pubspec.yaml', 'name: shared\n');
    write('shared/lib/config.dart', 'enum Backend { dev, staging, prod }');
    write('mobile/pubspec.yaml', 'name: mobile\n');
    write('mobile/lib/main.dart', '''
import 'package:shared/config.dart';
void main({Backend backend = Backend.staging}) {}
''');
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (var name in const ['mobile', 'shared'])
            {'name': name, 'rootUri': '../$name', 'packageUri': 'lib/'},
        ],
      }),
    );

    var found = scanEntrypointKnobs(
      packageRoot: p.join(package.path, 'mobile'),
      entrypoint: 'lib/main.dart',
    );

    expect(found.undrawable, isEmpty);
    expect(found.knobs.single.knob.kind, KnobKind.picker);
    expect(found.knobs.single.knob.options, ['dev', 'staging', 'prod']);
    expect(found.knobs.single.knob.defaultValue, 'staging');
    expect(found.knobs.single.enumType, 'Backend');
    // The wrapper writes `Backend.staging`, so it has to import what declares
    // it — already a `package:` URI, which means the same thing from the
    // `.dart_tool/flutterware/run/` the wrapper is written into.
    expect(found.imports, ["import 'package:shared/config.dart';"]);
  });

  group('the imports a wrapper will need', () {
    test('a relative import becomes a package: URI', () {
      // The wrapper sits in .dart_tool/flutterware/run/, where `src/…` means
      // something else entirely.
      write('lib/src/backend.dart', 'enum Backend { dev }');
      write('lib/main.dart', '''
import 'src/backend.dart';
void main({Backend backend = Backend.dev}) {}
''');

      expect(scan().imports, ["import 'package:myapp/src/backend.dart';"]);
    });

    test('a nested entry point resolves against its own directory', () {
      write('lib/entries/shared.dart', 'enum Backend { dev }');
      write('lib/entries/app.dart', '''
import 'shared.dart';
import '../models.dart';
void main() {}
''');

      expect(scan('lib/entries/app.dart').imports, [
        "import 'package:myapp/entries/shared.dart';",
        "import 'package:myapp/models.dart';",
      ]);
    });

    test('prefixes are kept, because the type is written with them', () {
      write('lib/models.dart', 'enum Backend { dev }');
      write('lib/main.dart', '''
import 'models.dart' as m;
void main({m.Backend backend = m.Backend.dev}) {}
''');

      var found = scan();
      expect(found.imports, ["import 'package:myapp/models.dart' as m;"]);
      expect(found.knobs.single.enumType, 'm.Backend');
    });

    test('dart: and package: imports pass through untouched', () {
      write('lib/main.dart', '''
import 'dart:async';
import 'package:material_ui/material_ui.dart';
void main() {}
''');

      expect(scan().imports, [
        "import 'dart:async';",
        "import 'package:material_ui/material_ui.dart';",
      ]);
    });

    test('an import climbing out of lib/ is spelled from the wrapper', () {
      // It used to be dropped, on the grounds that it has no `package:`
      // spelling. It does not need one: the wrapper sits in the package, so a
      // path reaches `tool/`, and having no `package:` spelling is exactly
      // what makes the path safe — nothing else can name the file either.
      write('lib/main.dart', '''
import '../tool/helpers.dart';
void main() {}
''');

      expect(scan().imports, ["import '../../../tool/helpers.dart';"]);
    });

    test('an entry point outside lib/ keeps its neighbours', () {
      // The whole point of allowing one: `demo/` holds the dev-only entry
      // points and the things only they use.
      write('demo/src/seed.dart', 'enum Seed { empty }');
      write('demo/main_dev.dart', '''
import 'src/seed.dart';
import 'package:myapp/models.dart';
void main({Seed seed = Seed.empty}) {}
''');

      expect(scan('demo/main_dev.dart').imports, [
        "import '../../../demo/src/seed.dart';",
        "import 'package:myapp/models.dart';",
      ]);
    });

    test('an import reaching another package is dropped', () {
      // A path would spell it, and must not: a sibling package is reached by
      // `package:` URI from everywhere else in the checkout, and one library
      // under two URIs is two libraries. The wrapper only misses it if a
      // knob's type needed it, and then the compiler names the type.
      write('lib/main.dart', '''
import '../../shared/lib/config.dart';
void main() {}
''');

      expect(scan().imports, isEmpty);
    });
  });

  group('what the config says about them', () {
    test('a declaration is read back, and carries only what it can', () {
      var entries = declaredEntrypoints({
        'entrypoints': [
          {
            'path': 'lib/main.dart',
            'name': 'App',
            'knobs': [
              {
                'knob': 'serverPort',
                'label': 'Port',
                'from': {
                  'script': 'tool/local_env.dart',
                  'args': ['port'],
                },
              },
              {
                'knob': 'apiHost',
                'from': {'source': 'hostAddresses'},
              },
            ],
          },
        ],
      });

      var knobs = entries.single.knobs;
      expect(knobs.map((k) => k.name), ['serverPort', 'apiHost']);
      expect(knobs.first.label, 'Port');
      expect(knobs.first.from, isA<ScriptSource>());
      expect(knobs.last.from, same(ValueSource.hostAddresses));
    });

    test('an entry point declaring none is the ordinary case', () {
      var entries = declaredEntrypoints({
        'entrypoints': [
          {'path': 'lib/main.dart', 'name': 'App'},
        ],
      });

      expect(entries.single.knobs, isEmpty);
    });

    test('a shape this build cannot read is dropped, not refused', () {
      // The config imports the flutterware the *project* pins, which can run
      // ahead of the GUI reading its manifest.
      var entries = declaredEntrypoints({
        'entrypoints': [
          {
            'path': 'lib/main.dart',
            'knobs': [
              {'knob': 'ok'},
              {'nonsense': true},
              {
                'knob': 'newSource',
                'from': {'fromTheFuture': 'x'},
              },
            ],
          },
        ],
      });

      var knobs = entries.single.knobs;
      expect(knobs.map((k) => k.name), ['ok', 'newSource']);
      // A source we cannot resolve means a knob with fewer suggestions, never
      // a knob that disappears.
      expect(knobs.last.from, isNull);
    });
  });
}
