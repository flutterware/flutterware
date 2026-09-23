import 'dart:io';

import 'package:flutterware_app/src/assets/model/asset_catalog.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The rules in here are Flutter's, not ours, and each test names the one it
/// pins. `fixtures/probe_app` carries the same cases as files you can look at —
/// see `fixtures/probe_app/assets/README.md` — but the checks live in a temp
/// directory so they do not need the workspace to have been resolved.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw_assets_test'));
  tearDown(() => root.deleteSync(recursive: true));

  String appRoot() => p.join(root.path, 'app');
  String depRoot() => p.join(root.path, 'dep');

  void write(String relative, String content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// A config resolving two packages, which is what makes the `packages/…`
  /// prefix reachable without a `pub get`.
  ///
  /// Both are always in the config and neither is always in the bundle — that
  /// gap is the pub-workspace case, and several tests below live in it.
  void writePackageConfig() {
    write('app/.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dep",
      "rootUri": "../../dep",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    },
    {
      "name": "deep",
      "rootUri": "../../deep",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ]
}
''');
  }

  Future<AssetCatalog> resolve() => AssetCatalog.resolve(
    rootPackageRoot: appRoot(),
    packageConfigPath: p.join(appRoot(), '.dart_tool', 'package_config.json'),
  );

  setUp(writePackageConfig);

  test('a directory declaration does not recurse', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/
''');
    write('app/assets/images/logo.png', 'png');
    write('app/assets/images/icons/star.png', 'png');

    var catalog = await resolve();

    expect(catalog.byKey.keys, ['assets/images/logo.png']);
    expect(
      catalog.byKey['assets/images/icons/star.png'],
      isNull,
      reason:
          'A file in a subdirectory of a declared directory is on disk and not '
          'in the bundle. This is the rule the inspector exists to surface.',
    );
  });

  test('density variants attach to the asset and are not entries', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/
''');
    write('app/assets/images/logo.png', 'png');
    write('app/assets/images/2.0x/logo.png', 'png');
    write('app/assets/images/3.0x/logo.png', 'png');
    // Not a density directory, whatever it looks like.
    write('app/assets/images/dark/logo.png', 'png');

    var catalog = await resolve();

    expect(catalog.assets, hasLength(1));
    var logo = catalog.byKey['assets/images/logo.png']!;
    expect(logo.main.scale, isNull);
    expect(logo.main.key, 'assets/images/logo.png');
    expect(logo.variants.map((v) => v.scale), [2.0, 3.0]);
    expect(logo.variants.map((v) => v.key), [
      'assets/images/2.0x/logo.png',
      'assets/images/3.0x/logo.png',
    ]);
  });

  test('a shorthand density directory counts', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/logo.png
''');
    write('app/assets/images/logo.png', 'png');
    write('app/assets/images/3x/logo.png', 'png');

    var catalog = await resolve();

    expect(
      catalog.byKey['assets/images/logo.png']!.variants.map((v) => v.scale),
      [3.0],
      reason:
          "flutter_tools' own regex offers `plants/3x` as an example match, so "
          'the short form is a variant and not a stray directory.',
    );
  });

  test('a declaration can be a map with a path', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - path: assets/heart.svg
''');
    write('app/assets/heart.svg', '<svg/>');

    var catalog = await resolve();

    expect(catalog.byKey.keys, ['assets/heart.svg']);
    expect(catalog.assets.single.declaration, 'assets/heart.svg');
  });

  test("a dependency's assets are keyed under packages/", () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
''');
    write('dep/pubspec.yaml', '''
name: dep
flutter:
  assets:
    - assets/badge.png
''');
    write('dep/assets/badge.png', 'png');

    var catalog = await resolve();

    expect(catalog.byKey.keys, ['packages/dep/assets/badge.png']);
    var badge = catalog.assets.single;
    expect(badge.package, 'dep');
    expect(badge.packageRoot, depRoot());
  });

  test('a package in the config that nothing depends on stays out', () async {
    // The pub workspace case: one config resolves imports for every member, so
    // a sibling app is in the config and is not in this app's bundle.
    write('app/pubspec.yaml', 'name: app\n');
    write('dep/pubspec.yaml', '''
name: dep
flutter:
  assets:
    - assets/sibling.png
''');
    write('dep/assets/sibling.png', 'png');

    var catalog = await resolve();

    expect(
      catalog.assets,
      isEmpty,
      reason:
          'flutter_tools filters the config down to transitive dependencies '
          'for exactly this reason (asset.dart:423).',
    );
  });

  test('a dev-dependency is not in the bundle', () async {
    write('app/pubspec.yaml', '''
name: app
dev_dependencies:
  dep:
''');
    write('dep/pubspec.yaml', '''
name: dep
flutter:
  assets:
    - assets/test_only.png
''');
    write('dep/assets/test_only.png', 'png');

    var catalog = await resolve();

    expect(catalog.assets, isEmpty);
  });

  test('a dependency of a dependency is', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
''');
    write('dep/pubspec.yaml', '''
name: dep
dependencies:
  deep:
''');
    write('deep/pubspec.yaml', '''
name: deep
flutter:
  assets:
    - assets/buried.png
''');
    write('deep/assets/buried.png', 'png');

    var catalog = await resolve();

    expect(catalog.byKey.keys, ['packages/deep/assets/buried.png']);
  });

  test('fonts declare a family, and their files are assets too', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  fonts:
    - family: Roboto
      fonts:
        - asset: assets/fonts/Roboto-Regular.ttf
        - asset: assets/fonts/Roboto-Bold.ttf
          weight: 700
        - asset: assets/fonts/Roboto-Italic.ttf
          style: italic
''');
    write('app/assets/fonts/Roboto-Regular.ttf', 'ttf');
    write('app/assets/fonts/Roboto-Bold.ttf', 'ttf');

    var catalog = await resolve();

    var family = catalog.fonts.single;
    expect(family.family, 'Roboto');
    expect(family.fonts.map((f) => f.weight), [null, 700]);
    expect(
      catalog.byKey.keys,
      containsAll([
        'assets/fonts/Roboto-Regular.ttf',
        'assets/fonts/Roboto-Bold.ttf',
      ]),
      reason: 'A font file is an asset key like any other.',
    );
    expect(catalog.assets.every((a) => a.isFont), isTrue);

    expect(
      catalog.problems.map((e) => e.kind),
      [AssetProblemKind.missingFontFile],
      reason:
          'The italic file is declared and absent. The family still resolves '
          'for its other two weights, which is what makes this easy to miss.',
    );
    expect(
      catalog.problems.single.declaration,
      'assets/fonts/Roboto-Italic.ttf',
    );
  });

  test('what the analyzer already reports is left to the analyzer', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/missing.png
    - assets/nowhere/
    - {}
    - assets/present.png
''');
    write('app/assets/present.png', 'png');

    var catalog = await resolve();

    expect(catalog.byKey.keys, ['assets/present.png']);
    expect(
      catalog.problems,
      isEmpty,
      reason:
          'Measured 2026-08-26: `flutter analyze` reports all three against '
          'the pubspec, with a line and a column this panel has never had — '
          'asset_does_not_exist, asset_directory_does_not_exist and '
          'asset_missing_path. Every problem recorded here also becomes a '
          '`declared-missing` finding that exits `fw` 1, so echoing the '
          'analyzer costs a failed job and teaches a reader to skim.',
    );
  });

  test(
    'a declaration resolves on its variants when the 1x is absent',
    () async {
      write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/logo.png
''');
      write('app/assets/images/2.0x/logo.png', 'png');
      write('app/assets/images/3.0x/logo.png', 'png');

      var catalog = await resolve();

      expect(
        catalog.problems,
        isEmpty,
        reason:
            'asset.dart:535 fails only on `!assetFile.existsSync() && '
            'variants.isEmpty`, and `flutter analyze` stays silent here too. '
            'This used to report a problem *and* drop the asset.',
      );
      var asset = catalog.byKey['assets/images/logo.png'];
      expect(asset, isNotNull);
      expect(asset!.files.map((f) => f.scale), [2.0, 3.0]);
      expect(
        asset.main.scale,
        2.0,
        reason: 'With no 1x on disk, the densest-but-lowest file stands in.',
      );
    },
  );

  test(
    'an unparseable pubspec is reported for the root package only',
    () async {
      write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
''');
      write('dep/pubspec.yaml', 'name: dep\n  : not yaml at all\n');

      var catalog = await resolve();

      expect(
        catalog.problems,
        isEmpty,
        reason:
            "A dependency's pubspec that pub resolved and we cannot parse is a "
            'disagreement between two YAML readers about a file the reader of '
            'this panel does not own.',
      );
    },
  );

  test('an unparseable root pubspec is reported', () async {
    write('app/pubspec.yaml', 'name: app\n  : not yaml at all\n');

    var catalog = await resolve();

    expect(catalog.problems.single.kind, AssetProblemKind.unreadablePubspec);
    expect(catalog.problems.single.package, isNull);
  });

  test('the root package keeps its keys unprefixed', () async {
    write('app/pubspec.yaml', '''
name: app
flutter:
  uses-material-design: true
  assets:
    - assets/logo.png
''');
    write('app/assets/logo.png', 'png');

    var catalog = await resolve();

    expect(catalog.assets.single.key, 'assets/logo.png');
    expect(catalog.assets.single.package, isNull);
    expect(catalog.usesMaterialDesign, isTrue);
  });

  test("a packages/ declaration reaches into the dependency's lib", () async {
    // The documented way to bundle a file a dependency *has* but never
    // declared: `_resolveAsset` at asset.dart:1402 falls through to
    // `_resolvePackageAsset`, which reads `<name>`'s lib/.
    write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
flutter:
  assets:
    - packages/dep/images/logo.png
''');
    write('dep/pubspec.yaml', 'name: dep\n');
    write('dep/lib/images/logo.png', 'png');
    write('dep/lib/images/2.0x/logo.png', 'png');

    var catalog = await resolve();

    var logo = catalog.byKey['packages/dep/images/logo.png']!;
    expect(logo.package, isNull, reason: 'The root package declared it.');
    expect(logo.packageRoot, depRoot());
    expect(logo.main.path, p.join(depRoot(), 'lib', 'images', 'logo.png'));
    expect(logo.variants.map((v) => v.key), [
      'packages/dep/images/2.0x/logo.png',
    ]);
    expect(catalog.problems, isEmpty);
  });

  test(
    'a real file at the literal packages/ path wins over the reach',
    () async {
      // flutter_tools tries the declarer's own tree first, so a project with an
      // actual `packages/` directory keeps meaning its own files.
      write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
flutter:
  assets:
    - packages/dep/logo.png
''');
      write('dep/pubspec.yaml', 'name: dep\n');
      write('app/packages/dep/logo.png', 'the literal one');
      write('dep/lib/logo.png', 'the reached one');

      var catalog = await resolve();

      var logo = catalog.byKey['packages/dep/logo.png']!;
      expect(logo.main.path, p.join(appRoot(), 'packages', 'dep', 'logo.png'));
      expect(logo.packageRoot, appRoot());
    },
  );

  test('a packages/ declaration by a package is not re-prefixed', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
''');
    write('dep/pubspec.yaml', '''
name: dep
dependencies:
  deep:
flutter:
  assets:
    - packages/deep/icons/check.svg
''');
    write('deep/pubspec.yaml', 'name: deep\n');
    write('deep/lib/icons/check.svg', 'svg');

    var catalog = await resolve();

    expect(
      catalog.byKey.keys,
      ['packages/deep/icons/check.svg'],
      reason:
          'The declaration already names its package; '
          '"packages/dep/packages/deep/…" is a key nothing resolves.',
    );
  });

  test('a font asset can be a packages/ reach too', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
flutter:
  fonts:
    - family: Brand
      fonts:
        - asset: packages/dep/fonts/Brand-Regular.ttf
''');
    write('dep/pubspec.yaml', 'name: dep\n');
    write('dep/lib/fonts/Brand-Regular.ttf', 'ttf');

    var catalog = await resolve();

    var family = catalog.fonts.single;
    expect(family.family, 'Brand', reason: 'The root package declared it.');
    expect(family.fonts.single.key, 'packages/dep/fonts/Brand-Regular.ttf');
    expect(
      family.fonts.single.path,
      p.join(depRoot(), 'lib', 'fonts', 'Brand-Regular.ttf'),
    );
    var asset = catalog.byKey['packages/dep/fonts/Brand-Regular.ttf']!;
    expect(asset.packageRoot, depRoot());
    expect(catalog.problems, isEmpty);
  });

  test('a reach that lands nowhere is reported, and says why', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
flutter:
  assets:
    - packages/ghost/logo.png
    - packages/dep/absent.png
''');
    write('dep/pubspec.yaml', 'name: dep\n');

    var catalog = await resolve();

    expect(catalog.assets, isEmpty);
    var byDeclaration = {
      for (var problem in catalog.problems) problem.declaration: problem,
    };
    expect(
      byDeclaration['packages/ghost/logo.png']!.detail,
      contains('No package in the config'),
      reason:
          'The tool prints "Could not resolve package for asset" and fails '
          'the build on the same input.',
    );
    expect(
      byDeclaration['packages/dep/absent.png']!.detail,
      contains('Reaches into package "dep"'),
    );
    expect(catalog.problems.map((e) => e.kind).toSet(), {
      AssetProblemKind.unreachablePackageFile,
    });
  });

  test('a transformed asset carries its chain, and is not a problem', () async {
    // The chain reaches the asset because the bundle builder walks assets: it
    // needs the transformers of the file it is about to link. Not a problem
    // any more, either — this used to file `unsupportedTransformer` against a
    // correct declaration, which put a permanently red job in front of every
    // project that ships SVGs the documented way.
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - path: assets/icons/check.svg
      transformers:
        - package: vector_graphics_compiler
          args: ['--tessellate']
''');
    write('app/assets/icons/check.svg', '<svg/>');

    var catalog = await resolve();

    expect(catalog.problems, isEmpty);
    var asset = catalog.byKey['assets/icons/check.svg']!;
    expect(asset.transformers.single.package, 'vector_graphics_compiler');
    expect(asset.transformers.single.args, ['--tessellate']);
    expect(catalog.declarations.single.transformers, hasLength(1));
  });

  test('a transformer chain keeps its order, and a bare name works', () async {
    // Order is the contract: each output is the next one's input, so a list
    // read backwards is a bundle of wrong bytes that still resolves.
    write('app/pubspec.yaml', '''
name: app
flutter:
  assets:
    - path: assets/icons/check.svg
      transformers:
        - package: first_pass
        - package: second_pass
          args: ['--x=1', 2]
''');
    write('app/assets/icons/check.svg', '<svg/>');

    var catalog = await resolve();

    var chain = catalog.byKey['assets/icons/check.svg']!.transformers;
    expect(chain.map((t) => t.package), ['first_pass', 'second_pass']);
    // Stringified, because a pubspec number is an int and a process takes text.
    expect(chain.last.args, ['--x=1', '2']);
  });

  group('shaders', () {
    test("the root package's shader is keyed as declared", () async {
      write('app/pubspec.yaml', '''
name: app
flutter:
  shaders:
    - shaders/glow.frag
''');
      write('app/shaders/glow.frag', 'frag');

      var catalog = await resolve();

      expect(catalog.shaders.map((s) => s.key), ['shaders/glow.frag']);
      expect(catalog.shaders.single.package, isNull);
      expect(
        catalog.shaders.single.source,
        p.join(appRoot(), 'shaders', 'glow.frag'),
      );
    });

    test("a dependency's shader is keyed under its package", () async {
      write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
''');
      write('dep/pubspec.yaml', '''
name: dep
flutter:
  shaders:
    - shaders/x.frag
''');
      write('dep/shaders/x.frag', 'frag');

      var catalog = await resolve();

      expect(
        catalog.shaders.map((s) => s.key),
        contains('packages/dep/shaders/x.frag'),
      );
    });

    test('a shader reached through packages/ is keyed as declared', () async {
      // How `material_ui` declares the ink-sparkle ripple: a file under its
      // own `lib/`, which it loads by exactly this key.
      write('app/pubspec.yaml', '''
name: app
dependencies:
  dep:
''');
      write('dep/pubspec.yaml', '''
name: dep
flutter:
  shaders:
    - packages/dep/shaders/ink.frag
''');
      write('dep/lib/shaders/ink.frag', 'frag');

      var catalog = await resolve();

      var shader = catalog.shaders.single;
      expect(shader.key, 'packages/dep/shaders/ink.frag');
      expect(shader.source, p.join(depRoot(), 'lib', 'shaders', 'ink.frag'));
      expect(catalog.problems, isEmpty);
    });

    test(
      'a declared shader that is not on disk is a problem, not a key',
      () async {
        write('app/pubspec.yaml', '''
name: app
flutter:
  shaders:
    - shaders/missing.frag
''');

        var catalog = await resolve();

        expect(catalog.shaders, isEmpty);
        expect(catalog.problems.map((p) => p.kind), [
          AssetProblemKind.missingShaderFile,
        ]);
      },
    );

    test('a shader is not an asset', () async {
      write('app/pubspec.yaml', '''
name: app
flutter:
  shaders:
    - shaders/glow.frag
''');
      write('app/shaders/glow.frag', 'frag');

      var catalog = await resolve();

      expect(
        catalog.assets.map((a) => a.key),
        isNot(contains('shaders/glow.frag')),
      );
    });
  });

  group('parseScale', () {
    test('reads a density directory, long form and short', () {
      expect(AssetCatalog.parseScale('assets/2.0x/foo.png'), 2.0);
      expect(AssetCatalog.parseScale('assets/1.5x/foo.png'), 1.5);
      expect(AssetCatalog.parseScale('assets/3x/foo.png'), 3.0);
      expect(AssetCatalog.parseScale('3.0x/'), 3.0);
    });

    test('rejects what only looks like one', () {
      // `dark/` is the one the old overview report got wrong. There is no
      // theme variant in Flutter's asset resolution — only density.
      expect(AssetCatalog.parseScale('assets/dark/foo.png'), isNull);
      expect(AssetCatalog.parseScale('assets/foo.png'), isNull);
      // Narrower than flutter_tools, which suffix-matches this one.
      expect(AssetCatalog.parseScale('assets/foo2x/bar.png'), isNull);
    });
  });
}
