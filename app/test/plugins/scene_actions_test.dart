// The actions, which are the only part of the plugin `fw` and an agent can
// reach. Everything here goes through `invoke` by name, the same door the CLI
// and MCP use.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/scene_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/scene/group_file.dart';
import 'package:flutterware_app/src/scene/skeletons.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/tokens_file.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory scratch;
  late Directory root;

  SceneCore core() {
    var worktree = Worktree(path: root.path);
    return SceneCore(
      PluginHost(
        id: scenePluginId,
        label: 'Scene',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: const [Pkg('.')],
          discovered: const ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {
          'packages': [
            {'path': '.'},
          ],
        },
      ),
    );
  }

  /// The scene goes in `demo/`, which this makes a group on the way.
  void writeScene(String name, {bool withMotion = true}) {
    var scene = coffeeBannerDraft();
    var file = File(p.join(root.path, 'demo', '$name.scene.dart'));
    file.parent.createSync(recursive: true);
    var declaration = File(p.join(root.path, 'demo', sceneGroupFileName));
    if (!declaration.existsSync()) {
      declaration.writeAsStringSync(emitGroupSkeleton());
    }
    file.writeAsStringSync(
      emitSceneFile(
        scene,
        className: name,
        motions: withMotion
            ? {'${name}Intro': coffeeIntroDraft(scene)}
            : const {},
      ),
    );
  }

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('fw_scene_actions_test');
    root = Directory(p.join(scratch.path, 'app'))..createSync();
  });
  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  group('importTokens', () {
    var fixture = p.absolute('test/scene/fixtures/variables.json');

    test('writes the library, lists it in the group, regenerates', () async {
      writeScene('BannerScene', withMotion: false);
      var result =
          (await core().invoke('importTokens', arguments: {'file': fixture}))!
              as Map<String, Object?>;
      expect(result['path'], 'demo/imported.tokens.dart');
      expect(result['symbol'], 'importedTokens');
      expect((result['tokens']! as List).length, 6);
      expect(result['added'], 6);
      expect(
        (result['refusals']! as List).length,
        5,
        reason:
            'two unusable variables, a STRING and a BOOLEAN the library does '
            "not hold, and Colors' non-default mode",
      );
      expect(result['readBy'], [
        'demo',
      ], reason: "it landed in the group's folder, so the group reads it");
      var written = File(p.join(root.path, 'demo', 'imported.tokens.dart'));
      expect(written.readAsStringSync(), startsWith(sceneTokensFileMarker));
      expect(
        written.readAsStringSync(),
        contains("Token<double>('radiusCard', 28"),
      );
      var declaration = File(p.join(root.path, 'demo', sceneGroupFileName));
      expect(
        declaration.readAsStringSync(),
        contains("import 'imported.tokens.dart';"),
      );
      expect(
        declaration.readAsStringSync(),
        contains('libraries: [importedTokens]'),
      );
      var args = File(p.join(root.path, 'demo', 'scene_args.dart'));
      expect(args.readAsStringSync(), contains('class SceneTokens {'));
      expect(
        args.readAsStringSync(),
        contains('final SceneColor brandPrimary;'),
      );
      expect(written.readAsStringSync(), contains('// Imported from '));
      // Importing again finds everything as it left it.
      var again =
          (await core().invoke('importTokens', arguments: {'file': fixture}))!
              as Map<String, Object?>;
      expect(again['added'], 0);
      expect(again['unchanged'], 6);
    });

    test('merges into a library the editor wrote, keeping its own', () async {
      writeScene('BannerScene', withMotion: false);
      var written = File(p.join(root.path, 'demo', 'brand.tokens.dart'))
        ..writeAsStringSync('''
$sceneTokensFileMarker
import 'package:flutterware/scene_authoring.dart';

final brandTokens = [
  const Token<SceneColor>('brandPrimary', SceneColor(0xFF000000)),
  const Token<double>('espresso', 3),
];
''');
      var result =
          (await core().invoke(
                'importTokens',
                arguments: {
                  'file': fixture,
                  'library': 'demo/brand.tokens.dart',
                },
              ))!
              as Map<String, Object?>;
      expect(result['symbol'], 'brandTokens');
      expect(result['updated'], 1);
      expect(result['added'], 5);
      expect(result['kept'], ['espresso']);
      var source = written.readAsStringSync();
      expect(source, contains("'espresso', 3"));
      expect(source, contains('SceneColor(0xFFE8632B)'));
      expect(source, contains('// Kept, not in the design file: espresso'));
      var args = File(p.join(root.path, 'demo', 'scene_args.dart'));
      expect(args.readAsStringSync(), contains('final double espresso;'));
    });

    test('a library the reader refuses is not merged into', () async {
      writeScene('BannerScene', withMotion: false);
      File(p.join(root.path, 'demo', 'broken.tokens.dart'))
          .writeAsStringSync('final brokenTokens = 3;');
      expect(
        () => core().invoke(
          'importTokens',
          arguments: {'file': fixture, 'library': 'demo/broken.tokens.dart'},
        ),
        throwsA(
          isA<ActionRefusal>().having(
            (e) => e.message,
            'message',
            contains('cannot be read as a token library'),
          ),
        ),
      );
    });

    test('a missing file, or one with nothing in it, is refused', () {
      expect(
        () => core().invoke('importTokens', arguments: {'file': 'nope.json'}),
        throwsA(isA<ArgumentError>()),
      );
      var empty = File(p.join(scratch.path, 'empty.json'))
        ..writeAsStringSync('{"document": {}}');
      expect(
        () => core().invoke('importTokens', arguments: {'file': empty.path}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('nothing to import'),
          ),
        ),
      );
    });
  });

  test('list reports the groups, their scenes and where they are', () async {
    writeScene('BannerScene');
    writeScene('OtherScene', withMotion: false);
    var result = (await core().invoke('list'))! as Map<String, Object?>;
    expect(result['package'], '.');
    var groups = (result['groups']! as List).cast<Map<String, Object?>>();
    expect(groups.single['name'], 'demo');
    expect(groups.single['folder'], 'demo');
    var scenes = (groups.single['scenes']! as List)
        .cast<Map<String, Object?>>();
    expect(scenes.map((s) => s['class']).toSet(), {
      'BannerScene',
      'OtherScene',
    });
    expect(scenes.first['path'], startsWith('demo/'));
    expect(result['strayScenes'], 0);
  });

  group('tokens across the group', () {
    late String library;
    setUp(() {
      writeScene('BannerScene', withMotion: false);
      writeScene('OtherScene', withMotion: false);
      library = p.join(root.path, 'demo', 'brand.tokens.dart');
      File(library).writeAsStringSync('''
$sceneTokensFileMarker
import 'package:flutterware/scene_authoring.dart';

final brandTokens = [
  const Token<SceneColor>('brand', SceneColor(0xFFE8632B)),
];
''');
      var declaration = File(p.join(root.path, 'demo', sceneGroupFileName));
      declaration.writeAsStringSync(
        attachLibraryIn(
          declaration.readAsStringSync(),
          declaration.path,
          library,
          refuse: (r) => fail(r),
        )!,
      );
      // Both scenes read the token, spelled by hand the way the tool would.
      for (var name in ['BannerScene', 'OtherScene']) {
        var file = File(p.join(root.path, 'demo', '$name.scene.dart'));
        var source = file.readAsStringSync();
        expect(source, contains('fill: SceneColor(0xFF2B1B12)'));
        file.writeAsStringSync(
          source
              .replaceFirst(
                'fill: SceneColor(0xFF2B1B12)',
                'fill: tokens.brand',
              )
              .replaceFirst(
                'class $name extends SceneDefinition {',
                'class $name({final SceneTokens tokens = const SceneTokens()}) '
                    'extends SceneDefinition {',
              ),
        );
      }
    });

    test('readers are found in every scene of the group', () async {
      var core_ = core();
      await core_.invoke('list');
      var readers = core_.tokenReaders(
        '.',
        library,
        'brand',
        except: {p.join(root.path, 'demo', 'BannerScene.scene.dart')},
      );
      expect(readers.map((r) => '$r'), ['OtherScene · root.fill']);
      expect(core_.tokenReaders('.', library, 'brand'), hasLength(2));
      expect(core_.tokenReaders('.', library, 'nope'), isEmpty);
    });

    test('a rename rewrites the closed files, and they parse after', () async {
      var core_ = core();
      await core_.invoke('list');
      var open = p.join(root.path, 'demo', 'BannerScene.scene.dart');
      var touched = core_.renameTokenInFiles(
        '.',
        library,
        'brand',
        'accent',
        except: {open},
      );
      expect(touched.map(p.basename), ['OtherScene.scene.dart']);
      var other = File(p.join(root.path, 'demo', 'OtherScene.scene.dart'))
          .readAsStringSync();
      expect(other, contains('fill: tokens.accent'));
      expect(other, isNot(contains('tokens.brand')));
      expect(
        File(open).readAsStringSync(),
        contains('fill: tokens.brand'),
        reason: "the open file is its editor's to rename",
      );
    });
  });

  test('a scene file outside any group is counted, not listed', () async {
    File(p.join(root.path, 'lib', 'loose.scene.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        emitSceneFile(coffeeBannerDraft(), className: 'LooseScene'),
      );
    var result = (await core().invoke('list'))! as Map<String, Object?>;
    expect(result['groups'], isEmpty);
    expect(result['strayScenes'], 1);
  });

  test('newGroup writes the skeleton, and list finds the folder', () async {
    var made =
        (await core().invoke(
              'newGroup',
              arguments: {'folder': 'lib/scenes/m'},
            ))!
            as Map<String, Object?>;
    expect(made['path'], 'lib/scenes/m/$sceneGroupFileName');
    var result = (await core().invoke('list'))! as Map<String, Object?>;
    var groups = (result['groups']! as List).cast<Map<String, Object?>>();
    expect(groups.single['name'], 'm');
    expect(groups.single['scenes'], isEmpty);
    expect(
      File(p.join(root.path, 'lib/scenes/m', 'scene_args.dart')).existsSync(),
      isTrue,
      reason: 'the generated file follows, entries and all',
    );
    expect(
      () => core().invoke('newGroup', arguments: {'folder': 'lib/scenes/m'}),
      throwsA(isA<ActionRefusal>()),
    );
  });

  group('newScene', () {
    test('writes the folder and its declaration on the way', () async {
      // The action the panel's one verb had no twin for: an agent could make
      // a folder and a library and not the thing either exists for.
      var made =
          (await core().invoke(
                'newScene',
                arguments: {'name': 'PromoBadge', 'folder': 'lib/scenes'},
              ))!
              as Map<String, Object?>;
      expect(made['path'], 'lib/scenes/promo_badge.scene.dart');
      expect(made['class'], 'PromoBadge');
      expect(
        made['alsoWrote'],
        'lib/scenes/$sceneGroupFileName',
        reason: 'the second file is named, not sprung',
      );
      var written = File(
        p.join(root.path, 'lib', 'scenes', 'promo_badge.scene.dart'),
      ).readAsStringSync();
      expect(written, startsWith(sceneFileMarker));
      expect(written, contains('class PromoBadge extends SceneDefinition'));

      var listed = (await core().invoke('list'))! as Map<String, Object?>;
      var groups = (listed['groups']! as List).cast<Map<String, Object?>>();
      expect(groups.single['folder'], 'lib/scenes');
    });

    test('an existing folder gets the scene alone', () async {
      writeScene('BannerScene', withMotion: false);
      var made =
          (await core().invoke(
                'newScene',
                arguments: {'name': 'PromoBadge', 'folder': 'demo'},
              ))!
              as Map<String, Object?>;
      expect(made['path'], 'demo/promo_badge.scene.dart');
      expect(made.containsKey('alsoWrote'), isFalse);
    });

    test(
      'with no folder named, it lands where the scenes already are',
      () async {
        writeScene('BannerScene', withMotion: false);
        var made =
            (await core().invoke('newScene', arguments: {'name': 'Teaser'}))!
                as Map<String, Object?>;
        expect(made['folder'], 'demo');
        expect(made['path'], 'demo/teaser.scene.dart');
      },
    );

    test('a name that is not a class is refused by saying what one is', () {
      // Rejected rather than thrown: the check is past the first await, so
      // a synchronous expectation would pass on a Future nobody looked at.
      expect(
        core().invoke('newScene', arguments: {'name': 'promo badge'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('a capital first'),
          ),
        ),
      );
    });

    test(
      'the artboard is the size asked for, however it was spelled',
      () async {
        await core().invoke(
          'newScene',
          arguments: {'name': 'Square', 'width': '1080', 'height': 1080},
        );
        var written = File(
          p.join(root.path, 'lib', 'scenes', 'square.scene.dart'),
        ).readAsStringSync();
        expect(written, contains('width: 1080'));
        expect(written, contains('height: 1080'));
      },
    );
  });

  test('newLibrary names a group to mean its folder', () async {
    writeScene('BannerScene', withMotion: false);
    var made =
        (await core().invoke(
              'newLibrary',
              arguments: {'name': 'Brand', 'group': 'demo'},
            ))!
            as Map<String, Object?>;
    expect(made['path'], 'demo/brand.tokens.dart');
    expect(made['symbol'], 'brandTokens');
    expect(made['readBy'], ['demo']);
    var result = (await core().invoke('list'))! as Map<String, Object?>;
    var groups = (result['groups']! as List).cast<Map<String, Object?>>();
    expect(groups.single['libraries'], ['demo/brand.tokens.dart']);
    var libraries = (result['libraries']! as List).cast<Map<String, Object?>>();
    expect(libraries.single['symbol'], 'brandTokens');
    expect(libraries.single['readBy'], ['demo']);
  });

  test('an unknown package is refused by naming the declared ones', () {
    expect(
      () => core().invoke('list', arguments: {'package': 'nope'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'message',
          contains('Declared: .'),
        ),
      ),
    );
  });

  test('a scene that is not there is refused by listing what is', () {
    writeScene('BannerScene');
    expect(
      () => core().invoke('video', arguments: {'scene': 'Nope'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'message',
          contains('Found: BannerScene'),
        ),
      ),
    );
  });

  test('a scene with no motion refuses rather than rendering one frame', () {
    writeScene('StillScene', withMotion: false);
    expect(
      () => core().invoke('video', arguments: {'scene': 'StillScene'}),
      throwsA(
        isA<ActionRefusal>().having(
          (e) => e.message,
          'message',
          contains('has no motion'),
        ),
      ),
    );
  });

  group('a library goes where the scenes that read it are', () {
    /// A `scenes.dart` in [folder], and a library at [libraryPath] that the
    /// declaration knows nothing about — the state a human reaches by
    /// dropping a file into a folder, or dragging one out of it.
    void writeLibrary(String libraryPath) {
      var file = File(p.join(root.path, libraryPath));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('''
$sceneTokensFileMarker
import 'package:flutterware/scene_authoring.dart';

final ${tokensSymbolFor(libraryPath)} = [
  const Token<SceneColor>('brand', SceneColor(0xFFE8632B)),
];
''');
    }

    test(
      'a new one is listed where it lands, without being attached',
      () async {
        writeScene('BannerScene', withMotion: false);
        var result =
            (await core().invoke(
                  'newLibrary',
                  arguments: {'name': 'Brand', 'folder': 'demo'},
                ))!
                as Map<String, Object?>;
        expect(result['path'], 'demo/brand.tokens.dart');
        expect(result['readBy'], ['demo']);
        expect(
          File(p.join(root.path, 'demo', sceneGroupFileName))
              .readAsStringSync(),
          contains('libraries: [brandTokens]'),
        );
      },
    );

    test('one written beside a group is read by nobody', () async {
      writeScene('BannerScene', withMotion: false);
      var result =
          (await core().invoke(
                'newLibrary',
                arguments: {'name': 'Brand', 'folder': 'design'},
              ))!
              as Map<String, Object?>;
      expect(result['path'], 'design/brand.tokens.dart');
      expect(result['readBy'], isEmpty);
      // And nothing was written into a declaration to pretend otherwise.
      expect(
        File(p.join(root.path, 'demo', sceneGroupFileName)).readAsStringSync(),
        isNot(contains('brandTokens')),
      );
    });

    test(
      'a file dropped in is drift, shown and not silently adopted',
      () async {
        writeScene('BannerScene', withMotion: false);
        var c = core();
        await c.invoke('list');
        writeLibrary('demo/brand.tokens.dart');
        await c.reload('.');
        var group = c.scanFor('.')!.groups.single;
        var drift = c.driftFor('.', group);
        expect(drift.missing.map((l) => l.symbol), ['brandTokens']);
        expect(drift.stray, isEmpty);
        // A scan does not write: the declaration is code somebody owns.
        expect(
          File(group.declarationPath).readAsStringSync(),
          isNot(contains('brandTokens')),
        );

        await c.reconcileLibraries('.', group);
        expect(
          File(group.declarationPath).readAsStringSync(),
          contains('libraries: [brandTokens]'),
        );
        expect(c.driftFor('.', c.scanFor('.')!.groups.single).isEmpty, isTrue);
      },
    );

    test('a file dragged out is drift the other way, and reconciles', () async {
      writeScene('BannerScene', withMotion: false);
      writeLibrary('demo/brand.tokens.dart');
      var c = core();
      await c.invoke('list');
      await c.reconcileLibraries('.', c.scanFor('.')!.groups.single);
      expect(
        File(p.join(root.path, 'demo', sceneGroupFileName)).readAsStringSync(),
        contains('libraries: [brandTokens]'),
      );

      // Moved out from under the folder, the way a person moves a file.
      Directory(p.join(root.path, 'design')).createSync();
      File(p.join(root.path, 'demo', 'brand.tokens.dart'))
          .renameSync(p.join(root.path, 'design', 'brand.tokens.dart'));
      await c.reload('.');
      var group = c.scanFor('.')!.groups.single;
      var drift = c.driftFor('.', group);
      expect(drift.stray.map((l) => l.symbol), ['brandTokens']);

      await c.reconcileLibraries('.', group);
      var declaration = File(group.declarationPath).readAsStringSync();
      expect(declaration, isNot(contains('brandTokens')));
      expect(declaration, isNot(contains("import 'brand.tokens.dart';")));
    });
  });

  test('a group whose generated player is gone says so', () async {
    writeScene('BannerScene');
    // The generated file carries the player; scan once so it exists, then
    // take it away.
    await core().invoke('list');
    File(p.join(root.path, 'demo', 'scene_args.dart')).deleteSync();
    expect(
      () => core().invoke('video', arguments: {'scene': 'BannerScene'}),
      throwsA(
        isA<ActionRefusal>().having(
          (e) => e.message,
          'message',
          allOf(contains('no scene player'), contains('demo/')),
        ),
      ),
    );
  });
}
