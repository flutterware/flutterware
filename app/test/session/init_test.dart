import 'dart:convert';
import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/session/init.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late StringBuffer out;
  late StringBuffer err;

  ProjectInit initWith({bool alreadyIgnored = false}) => ProjectInit(
    root: root.path,
    out: out,
    err: err,
    // `git check-ignore` exits 0 when the path is already covered.
    runProcess: (_, _, {workingDirectory}) async =>
        ProcessResult(0, alreadyIgnored ? 0 : 1, '', ''),
  );

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    root = Directory.systemTemp.createTempSync('fw-init');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('writes nothing about this machine', () async {
    // It used to record the SDK that ran it, in `.flutterware/sdk`, for a
    // global `fw` to read. Nothing reads it now, and a path recorded once is a
    // path that goes stale — so the directory is not created at all.
    expect(await initWith().run(), 0);

    expect(Directory(p.join(root.path, '.flutterware')).existsSync(), isFalse);
    expect(File(p.join(root.path, '.gitignore')).existsSync(), isFalse);
  });

  test('writes a starter config when the project has none', () async {
    await initWith().run();

    var config = File(p.join(root.path, 'tool', 'flutterware.dart'));
    expect(config.existsSync(), isTrue);
    expect(config.readAsStringSync(), contains('Flutterware.configure'));
  });

  group('a declared monorepo', () {
    void workspace(List<String> members) {
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: everything
environment:
  sdk: ^3.10.0
workspace:
${[for (var member in members) '  - $member'].join('\n')}
''');
    }

    void member(String path, String name, {bool flutter = true}) {
      File(p.join(root.path, path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: $name
resolution: workspace
dependencies:
${flutter ? '  flutter:\n    sdk: flutter\n' : ''}  path: ^1.9.0
''');
    }

    Future<String> scaffold() async {
      await initWith().run();
      return File(p.join(root.path, 'tool', 'flutterware.dart'))
          .readAsStringSync();
    }

    /// The consts [plugin] is handed, in order.
    List<String> handedTo(String config, String plugin) {
      var list = RegExp('$plugin\\(\\s*packages:\\s*\\[([^\\]]*)\\]')
          .firstMatch(config);
      if (list == null) return const [];
      return [
        for (var match in RegExp(r'\.new\((\w+)\)').allMatches(list[1]!))
          match[1]!,
      ];
    }

    test('scaffolds as one', () async {
      // A seven-member `workspace:` used to get the single-package form —
      // every tool pointed at the workspace shell, a package with no lib and
      // no tests, while the members went unserved. The list is right there.
      workspace(['packages/app', 'packages/design_system', 'server']);
      member('packages/app', 'app');
      member('packages/design_system', 'design_system');
      member('server', 'server', flutter: false);

      var config = await scaffold();
      expect(config, contains("const app = Pkg('packages/app');"));
      expect(
        config,
        contains("const designSystem = Pkg('packages/design_system');"),
      );
      expect(config, contains("const server = Pkg('server');"));
      expect(handedTo(config, 'Dependencies'), [
        'app',
        'designSystem',
        'server',
      ]);
      // The shell itself gets no tool: it is the one package with nothing in
      // it, and the scaffold is a starting point somebody trims, not grows.
      expect(config, isNot(contains("= Pkg('.');")));
    });

    /// On a 24-package workspace the directory rule handed `example` to one
    /// package's example app, because it was listed first, and pushed the
    /// app the repository exists for out to a 40-character path.
    test('names each member after its pubspec, not its directory', () async {
      workspace([
        'packages/checkout_ui/example',
        'apps/storefront/app',
        'packages/search/example',
      ]);
      member('packages/checkout_ui/example', 'checkout_ui_example');
      member('apps/storefront/app', 'storefront');
      member('packages/search/example', 'search_example');

      var config = await scaffold();
      expect(
        config,
        contains(
          "const checkoutUiExample = Pkg('packages/checkout_ui/example');",
        ),
      );
      expect(
        config,
        contains("const storefront = Pkg('apps/storefront/app');"),
      );
      expect(
        config,
        contains("const searchExample = Pkg('packages/search/example');"),
      );
    });

    test('a member with no pubspec falls back to its directory', () async {
      workspace(['apps/mobile/app', 'apps/desktop/app']);

      var config = await scaffold();
      expect(config, contains("const app = Pkg('apps/mobile/app');"));
      // Two members sharing a basename still get distinct names.
      expect(
        config,
        contains("const appsDesktopApp = Pkg('apps/desktop/app');"),
      );
    });

    test('never names a const after a word the file cannot use', () async {
      // `main` beside `void main()` does not compile, a const called `fw` is
      // shadowed by the closure's parameter, and `switch` is reserved.
      workspace(['main', 'tools/fw', 'switch']);
      member('tools/fw', 'fw');

      var config = await scaffold();
      expect(config, contains("const mainPkg = Pkg('main');"));
      expect(config, contains("const fwPkg = Pkg('tools/fw');"));
      expect(config, contains("const switchPkg = Pkg('switch');"));
      expect(handedTo(config, 'Dependencies'), [
        'mainPkg',
        'fwPkg',
        'switchPkg',
      ]);
    });

    test('hands the widget tools only the members that use Flutter', () async {
      // A pure-Dart package has no widgets, and handed to Previews and
      // Scenarios it reported "no entries" on every `fw status` for good.
      workspace(['apps/shop', 'packages/api_client', 'packages/widgets']);
      member('apps/shop', 'shop');
      member('packages/api_client', 'api_client', flutter: false);
      member('packages/widgets', 'widgets');

      var config = await scaffold();
      expect(handedTo(config, 'Dependencies'), [
        'shop',
        'apiClient',
        'widgets',
      ]);
      expect(handedTo(config, 'Previews'), ['shop', 'widgets']);
      expect(handedTo(config, 'Scenarios'), ['shop', 'widgets']);
      expect(config, contains('only the members that depend on Flutter'));
    });

    test('with no Flutter member, uses no widget tool at all', () async {
      workspace(['packages/core', 'tool/codegen']);
      member('packages/core', 'core', flutter: false);
      member('tool/codegen', 'codegen', flutter: false);

      var config = await scaffold();
      expect(handedTo(config, 'Dependencies'), ['core', 'codegen']);
      expect(config, isNot(contains('fw.use(Previews')));
      expect(config, isNot(contains('fw.use(Scenarios')));
      expect(config, contains('no member here'));
    });

    test('is written formatted', () async {
      // The lists used to be joined onto one line: two dozen members made
      // each `fw.use(...)` about 700 characters long.
      var members = [for (var i = 0; i < 24; i++) 'packages/feature_$i'];
      workspace(members);
      for (var path in members) {
        member(path, p.basename(path));
      }

      var config = await scaffold();
      expect(
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(config),
        config,
      );
      for (var line in const LineSplitter().convert(config)) {
        expect(line.length, lessThanOrEqualTo(80), reason: line);
      }
      expect(handedTo(config, 'Previews'), hasLength(24));
    });

    test('points the identity at the member const it guessed', () async {
      workspace(['packages/core', 'apps/shop']);
      member('packages/core', 'core', flutter: false);
      member('apps/shop', 'shop');
      var icons = p.join(
        root.path,
        'apps/shop/macos/Runner/Assets.xcassets/AppIcon.appiconset',
      );
      Directory(icons).createSync(recursive: true);
      // This repo's own app icon, which is exactly a non-stock one.
      File(
        p.join(
          Directory.current.path,
          'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
        ),
      ).copySync(p.join(icons, 'app_icon_1024.png'));
      File(p.join(icons, 'Contents.json')).writeAsStringSync(
        '{"images":[{"size":"512x512","idiom":"mac",'
        '"filename":"app_icon_1024.png","scale":"2x"}],'
        '"info":{"version":1,"author":"xcode"}}',
      );

      var config = await scaffold();
      expect(config, contains('package: shop,'));
      // Both fields are the declaration; a reader should not come away
      // thinking the package alone is one.
      expect(config, contains('`icon` is the picture'));
    });
  });

  test('never overwrites an existing config', () async {
    File(p.join(root.path, 'tool', 'flutterware.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// mine');

    await initWith().run();

    expect(
      File(p.join(root.path, 'tool', 'flutterware.dart')).readAsStringSync(),
      '// mine',
    );
  });

  group('running before every command', () {
    // `run` is what a project meets on every invocation rather than once, and
    // every step does nothing when its own thing is already there. These are
    // the properties that makes safe.

    test('restores what init writes after it is removed', () async {
      // The bug the gate caused, in the shape it will keep taking: something
      // init writes is added later — or deleted — and a project that ran once
      // already never sees it. Nothing here should need a migration.
      await initWith().run();
      File(p.join(root.path, '.mcp.json')).deleteSync();
      File(p.join(root.path, 'tool', 'flutterware.dart')).deleteSync();

      await initWith().run();

      expect(File(p.join(root.path, '.mcp.json')).existsSync(), isTrue);
      expect(
        File(p.join(root.path, 'tool', 'flutterware.dart')).existsSync(),
        isTrue,
      );
    });

    test('a quiet run never spawns git', () async {
      // The only process a run could spawn, and it is asked solely to tell a
      // human that `.gitignore` is hiding what was just written. Before every
      // command there is no human, so nothing should be spawned at all.
      var gitCalls = 0;
      ProjectInit counted() => ProjectInit(
        root: root.path,
        out: out,
        err: err,
        runProcess: (_, _, {workingDirectory}) async {
          gitCalls++;
          return ProcessResult(0, 1, '', '');
        },
      );

      await counted().run(quiet: true);
      await counted().run(quiet: true);

      expect(gitCalls, 0);
    });
  });

  test('is idempotent, and says nothing the second time', () async {
    await initWith().run();
    out.clear();

    expect(await initWith().run(), 0);
    expect(out.toString(), isEmpty);
  });

  group('.mcp.json', () {
    File mcpConfig() => File(p.join(root.path, '.mcp.json'));
    Map<String, Object?> readConfig() =>
        jsonDecode(mcpConfig().readAsStringSync()) as Map<String, Object?>;

    test('registers the command a user would type', () async {
      // No version manager is named. Whatever `dart` the client provides is the
      // signal, resolved when the server is spawned rather than recorded here.
      await initWith().run();

      expect(readConfig(), {
        'mcpServers': {
          'flutterware': {
            'command': 'dart',
            'args': ['run', 'flutterware', 'mcp'],
          },
        },
      });
    });

    group('in a project that pins its SDK', () {
      // The entry stays plain `dart` — writing a guess from the pin file is
      // what the design refuses. But it is written quietly, before whatever
      // command ran first, and a `dart` on PATH older than the pin fails
      // later, at the client's handshake, where nobody is looking.

      test('still registers plain `dart`', () async {
        File(p.join(root.path, '.fvmrc'))
            .writeAsStringSync('{"flutter": "beta"}');
        await initWith().run(quiet: true);

        var entry =
            (readConfig()['mcpServers']!
                as Map<String, Object?>)['flutterware'];
        expect(entry, {
          'command': 'dart',
          'args': ['run', 'flutterware', 'mcp'],
        });
      });

      test('says so once, on stderr, even when quiet', () async {
        File(p.join(root.path, '.fvmrc'))
            .writeAsStringSync('{"flutter": "beta"}');
        await initWith().run(quiet: true);

        // Not stdout: a quiet run precedes `fw mcp` and `--json`, whose
        // stdout belongs to the protocol or the parser.
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          allOf(
            startsWith('fw: .fvmrc pins'),
            contains('runs `dart` from PATH'),
            contains('`fvm dart run flutterware mcp`'),
          ),
        );

        err.clear();
        await initWith().run(quiet: true);
        expect(err.toString(), isEmpty, reason: 'the entry is already there');
      });

      test('under the registration when init is run by hand', () async {
        File(p.join(root.path, '.fvmrc'))
            .writeAsStringSync('{"flutter": "beta"}');
        await initWith().run();

        expect(
          out.toString(),
          contains(
            '  registered flutterware in .mcp.json\n'
            '    .fvmrc pins',
          ),
        );
        expect(err.toString(), isEmpty);
      });

      test('names mise by its own command', () async {
        File(p.join(root.path, 'mise.toml'))
            .writeAsStringSync('[tools]\nflutter = "3.48.0-0.2.pre-beta"\n');
        await initWith().run(quiet: true);

        expect(err.toString(), contains('`mise exec -- dart run flutterware'));
      });

      test(
        'a .tool-versions pinning Flutter gets the generic advice',
        () async {
          File(
            p.join(root.path, '.tool-versions'),
          ).writeAsStringSync('nodejs 22.1.0\nflutter 3.48.0-0.2.pre-beta\n');
          await initWith().run(quiet: true);

          expect(
            err.toString(),
            contains('run it through your version manager'),
          );
        },
      );

      test('a .tool-versions pinning something else is not one', () async {
        File(p.join(root.path, '.tool-versions'))
            .writeAsStringSync('nodejs 22.1.0\npython 3.12.4\n');
        await initWith().run(quiet: true);

        expect(err.toString(), isEmpty);
      });
    });

    test('says nothing about the SDK in a project that pins none', () async {
      await initWith().run(quiet: true);

      expect(err.toString(), isEmpty);
      expect(out.toString(), isEmpty);
    });

    test('replaces the dead `fw mcp` entry it used to write', () async {
      // The one entry this is allowed to overwrite: ours, and naming a binary
      // that no longer exists. Left alone it is an agent finding a server that
      // cannot start.
      mcpConfig().writeAsStringSync('''
{
  "mcpServers": {
    "other": {"command": "node"},
    "flutterware": {
      "command": "fw",
      "args": ["mcp"]
    }
  }
}
''');

      await initWith().run();

      expect(readConfig()['mcpServers'], {
        'other': {'command': 'node'},
        'flutterware': {
          'command': 'dart',
          'args': ['run', 'flutterware', 'mcp'],
        },
      });
    });

    test('leaves an `fw` entry someone has added to alone', () async {
      // Same command, but edited — an added argument means they meant it, and
      // recognising the key is not permission to overwrite the value.
      var source = '''
{
  "mcpServers": {
    "flutterware": {
      "command": "fw",
      "args": ["mcp", "--verbose"]
    }
  }
}
''';
      mcpConfig().writeAsStringSync(source);

      await initWith().run();

      expect(mcpConfig().readAsStringSync(), source);
    });

    test('keeps servers it did not write', () async {
      // The one outcome to rule out: this file is shared, and clobbering
      // someone else's server is worse than never having written ours.
      mcpConfig().writeAsStringSync('''
{
  "mcpServers": {
    "other": { "command": "other-server" }
  }
}
''');

      await initWith().run();

      var servers = readConfig()['mcpServers']! as Map<String, Object?>;
      expect(servers['other'], {'command': 'other-server'});
      expect(servers, contains('flutterware'));
    });

    test('never rewrites an entry someone has edited', () async {
      mcpConfig().writeAsStringSync('''
{
  "mcpServers": {
    "flutterware": { "command": "/opt/fw", "args": ["mcp", "--verbose"] }
  }
}
''');

      await initWith().run();

      var servers = readConfig()['mcpServers']! as Map<String, Object?>;
      expect(servers['flutterware'], {
        'command': '/opt/fw',
        'args': ['mcp', '--verbose'],
      });
    });

    test('leaves a file it cannot parse exactly as it found it', () async {
      // Replacing it with a valid file would mean deleting whatever it said,
      // which is not a repair anyone asked for.
      mcpConfig().writeAsStringSync('{ not json');

      expect(await initWith().run(), 0);

      expect(mcpConfig().readAsStringSync(), '{ not json');
      expect(out.toString(), isNot(contains('.mcp.json')));
    });

    test('leaves mcpServers alone when it is not an object', () async {
      mcpConfig().writeAsStringSync('{"mcpServers": []}');

      expect(await initWith().run(), 0);

      expect(readConfig()['mcpServers'], isEmpty);
    });

    test('says so when .gitignore hides it', () async {
      // A repo ignoring every dotfile with `.*` gets the file written and
      // hidden, which works for whoever ran init and for nobody else. Silence
      // would read as "your team has this now".
      await initWith(alreadyIgnored: true).run();

      expect(out.toString(), contains('.gitignore hides it'));
    });

    test(
      'says nothing about .gitignore when the file will be shared',
      () async {
        await initWith().run();

        expect(out.toString(), contains('.mcp.json'));
        expect(out.toString(), isNot(contains('.gitignore hides it')));
      },
    );

    test('preserves keys beside mcpServers', () async {
      mcpConfig().writeAsStringSync('{"inputs": [{"id": "token"}]}');

      await initWith().run();

      var config = readConfig();
      expect(config['inputs'], [
        {'id': 'token'},
      ]);
      expect(config['mcpServers'], contains('flutterware'));
    });

    test('reformats nothing, down to the indent width', () async {
      // Re-encoding the parsed file would reindent, requote and reorder all of
      // this, and the entry we added would be lost in a whole-file diff. The
      // only line it may touch is the one that used to be last, which gains a
      // comma.
      mcpConfig().writeAsStringSync('''
{
    "inputs": [{ "id": "token", "type": "promptString" }],
    "mcpServers": {
        "other": {
            "command": "other-server",
            "args": ["--stdio"]
        }
    }
}
''');

      await initWith().run();

      expect(mcpConfig().readAsStringSync(), '''
{
    "inputs": [{ "id": "token", "type": "promptString" }],
    "mcpServers": {
        "other": {
            "command": "other-server",
            "args": ["--stdio"]
        },
        "flutterware": {
            "command": "dart",
            "args": [
                "run",
                "flutterware",
                "mcp"
            ]
        }
    }
}
''');
    });

    test('adds mcpServers to a file that has none, in place', () async {
      mcpConfig().writeAsStringSync('''
{
  "inputs": []
}
''');

      await initWith().run();

      expect(mcpConfig().readAsStringSync(), '''
{
  "inputs": [],
  "mcpServers": {
    "flutterware": {
      "command": "dart",
      "args": [
        "run",
        "flutterware",
        "mcp"
      ]
    }
  }
}
''');
    });

    test('fills an empty mcpServers without collapsing the file', () async {
      mcpConfig().writeAsStringSync('''
{
  "mcpServers": {},
  "inputs": []
}
''');

      await initWith().run();

      expect(mcpConfig().readAsStringSync(), '''
{
  "mcpServers": {
    "flutterware": {
      "command": "dart",
      "args": [
        "run",
        "flutterware",
        "mcp"
      ]
    }
  },
  "inputs": []
}
''');
    });

    test('keeps a file written on one line on one line', () async {
      mcpConfig().writeAsStringSync(
        '{"mcpServers":{"other":{"command":"other-server"}}}',
      );

      await initWith().run();

      expect(
        mcpConfig().readAsStringSync(),
        '{"mcpServers":{"other":{"command":"other-server"}, '
        '"flutterware": {"command":"dart","args":["run","flutterware","mcp"]}}}',
      );
    });
  });
}
