import 'dart:io';

import 'package:image/image.dart' as img;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/assets_core.dart';
import 'package:flutterware_app/src/plugins/native/assets_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// The actions, which are the only part of the plugin `fw` and an agent can
/// reach. Everything asserted here is reached by name through `invoke`, the
/// same door the CLI and MCP go through.
void main() {
  late Directory scratch;
  late Directory root;

  AssetsCore core() {
    var worktree = Worktree(path: root.path);
    return AssetsCore(
      PluginHost(
        id: assetsPluginId,
        label: 'Assets',
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

  void write(String relative, List<int> content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(content);
  }

  void writeText(String relative, String content) =>
      write(relative, content.codeUnits);

  setUp(() {
    // The worktree sits inside a directory of its own, so that a test writing a
    // sibling of the worktree — a path dependency, below — writes it somewhere
    // only this test owns.
    scratch = Directory.systemTemp.createTempSync('fw_assets_actions_test');
    root = Directory(p.join(scratch.path, 'app'))..createSync();
    writeText(
      '.dart_tool/package_config.json',
      '{"configVersion":2,"packages":[]}',
    );
  });
  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  group('list', () {
    test('names every key, with where it is', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/
''');
      write('assets/images/logo.png', _png(4, 4));
      write('assets/images/2.0x/logo.png', _png(8, 8));
      writeText('assets/images/notes.txt', 'hi');

      var result = (await core().invoke('list'))! as AssetListResult;
      var package = result.packages.single;

      expect(package.own, 2);
      expect(package.assets.map((a) => a.key), [
        'assets/images/logo.png',
        'assets/images/notes.txt',
      ]);

      var logo = package.assets.first;
      expect(logo.kind, 'image');
      expect(logo.densities, [2.0]);
      expect(
        logo.address,
        'fw:///worktrees/${p.basename(root.path)}/flutterware.assets/./assets/images/logo.png',
        reason: 'An entry a caller can act on without a second lookup.',
      );
    });

    test('counts what it did not list', () async {
      writeText('pubspec.yaml', '''
name: app
dependencies:
  brand:
''');
      writeText('.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {"name":"brand","rootUri":"../../brand","packageUri":"lib/","languageVersion":"3.0"}
  ]
}
''');
      // A sibling of the worktree root; it goes with the scratch directory in
      // tearDown.
      var brand = Directory(p.join(p.dirname(root.path), 'brand'));
      File(p.join(brand.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: brand
flutter:
  assets:
    - assets/mark.png
''');
      File(p.join(brand.path, 'assets', 'mark.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png(2, 2));

      var plugin = core();
      var quiet = (await plugin.invoke('list'))! as AssetListResult;
      // The dependency's asset is in the bundle whether or not it was listed,
      // so a list that dropped it still has to say it is there.
      expect(quiet.packages.single.assets, isEmpty);
      expect(quiet.packages.single.fromPackages, 1);

      var loud =
          (await plugin.invoke('list', arguments: {'dependencies': true}))!
              as AssetListResult;
      expect(
        loud.packages.single.assets.single.key,
        'packages/brand/assets/mark.png',
      );
    });

    test('refuses a package the plugin does not declare', () async {
      writeText('pubspec.yaml', 'name: app\n');

      expect(
        () => core().invoke('list', arguments: {'package': 'nope'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('describe', () {
    test('reads a raster header for its dimensions', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/logo.png
''');
      write('assets/logo.png', _png(48, 24));

      var result =
          (await core().invoke(
                'describe',
                arguments: {'asset': 'assets/logo.png'},
              ))!
              as AssetDescription;

      expect(result.raster?.width, 48);
      expect(result.raster?.height, 24);
      expect(
        result.code,
        "Image.asset('assets/logo.png')",
        reason: 'The line a model otherwise guesses at.',
      );
    });

    test('reads an animation without the lottie package', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/pulse.json
''');
      writeText('assets/pulse.json', '''
{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":200,"h":200,
 "layers":[{"nm":"Dot","ty":4},{"nm":"Caption","ty":5}],
 "markers":[{"tm":0,"cm":"start"}]}
''');

      var result =
          (await core().invoke(
                'describe',
                arguments: {'asset': 'assets/pulse.json'},
              ))!
              as AssetDescription;

      // The CLI and an agent get the interesting half of a Lottie for free,
      // because it is a JSON document.
      expect(result.kind, 'animation');
      expect(result.animation?.frameRate, 30);
      expect(result.animation?.frames, 60);
      expect(result.animation?.durationMs, 2000);
      expect(result.animation?.layers.map((l) => '${l.name}:${l.type}'), [
        'Dot:shape',
        'Caption:text',
      ]);
      expect(result.animation?.markers, ['start']);
    });

    test('a plain JSON is data, not a broken animation', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/config.json
''');
      writeText('assets/config.json', '{"retries": 3}');

      var result =
          (await core().invoke(
                'describe',
                arguments: {'asset': 'assets/config.json'},
              ))!
              as AssetDescription;

      expect(result.kind, 'data');
      expect(result.animation, isNull);
    });

    test('says what a font family claims about it', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  fonts:
    - family: Inter
      fonts:
        - asset: assets/Inter-Bold.ttf
          weight: 700
''');
      writeText('assets/Inter-Bold.ttf', 'not really a font');

      var result =
          (await core().invoke(
                'describe',
                arguments: {'asset': 'assets/Inter-Bold.ttf'},
              ))!
              as AssetDescription;

      expect(result.font?.family, 'Inter');
      expect(result.font?.weight, 700);
      expect(result.code, "TextStyle(fontFamily: 'Inter')");
    });

    test('a key that does not resolve offers the ones that do', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/logo.png
''');
      write('assets/images/logo.png', _png(2, 2));

      // The usual mistake: the right filename, the wrong directory.
      await expectLater(
        core().invoke('describe', arguments: {'asset': 'images/logo.png'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('assets/images/logo.png'),
          ),
        ),
      );
    });
  });

  group('audit', () {
    Future<AssetAuditResult> audit([
      Map<String, Object?> arguments = const {},
    ]) async =>
        (await core().invoke('audit', arguments: arguments))!
            as AssetAuditResult;

    test('finds the file a directory declaration cannot reach', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/images/
''');
      write('assets/images/logo.png', _png(2, 2));
      write('assets/images/icons/star.png', _png(2, 2));

      var result = await audit();

      var finding = result.findings.singleWhere(
        (f) => f.kind == 'unreachable-file',
      );
      expect(finding.path, 'assets/images/icons/star.png');
      // The fix, not just the complaint.
      expect(finding.detail, contains('assets/images/icons/'));
      expect(
        result.checked,
        1,
        reason: 'The unreachable file is not an asset — that is the finding.',
      );
    });

    test('says nothing about a choice a project has already made', () async {
      // Both of these were findings once, and both were right on the facts and
      // wrong to conclude. Measured on a real bundle, `duplicate` was 20 of 27
      // findings — one deliberate icon aliased per symptom so a generated map
      // could stay readable — and a project cannot silence a finding, so it
      // would have decided against them again every run. An audit is only
      // worth reading if a clean run means something.
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/badge.png
    - assets/logo.png
    - assets/wordmark.png
''');
      // A ladder with 3× and no 2×.
      write('assets/badge.png', _png(2, 2));
      write('assets/3.0x/badge.png', _png(6, 6));
      // The same bytes under two keys.
      write('assets/logo.png', _png(4, 4));
      write('assets/wordmark.png', _png(4, 4));

      expect((await audit()).findings, isEmpty);
    });

    test('finds a raster bigger than anything will draw', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/hero.png
''');
      write('assets/hero.png', _png(64, 64));

      expect(
        (await audit()).findings.where((f) => f.kind == 'oversized'),
        isEmpty,
        reason: '64px is nothing at the default limit.',
      );

      var finding = (await audit({'maxEdge': 32})).findings
          .singleWhere((f) => f.kind == 'oversized');
      expect(finding.detail, contains('64 × 64'));
    });

    test('reports weight without an opinion about it', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/logo.png
''');
      write('assets/logo.png', _png(8, 8));

      var result = await audit();
      expect(
        result.bytes,
        greaterThan(0),
        reason: 'The number is the useful half, and it is still here.',
      );
      expect(
        result.findings,
        isEmpty,
        reason:
            'There is no weight a bundle is wrong to be. A target is measured '
            'against a built artifact, not against this sum.',
      );
    });

    test('a clean bundle audits to nothing, having looked', () async {
      writeText('pubspec.yaml', '''
name: app
flutter:
  assets:
    - assets/logo.png
''');
      write('assets/logo.png', _png(4, 4));

      var result = await audit();

      expect(result.findings, isEmpty);
      // An audit that examined nothing must not look like one that found
      // nothing wrong.
      expect(result.checked, 1);
      expect(result.bytes, greaterThan(0));
    });

    test(
      'a package it could not scan is reported, not counted clean',
      () async {
        File(p.join(root.path, '.dart_tool', 'package_config.json'))
            .deleteSync();
        writeText('pubspec.yaml', 'name: app\n');

        var result = await audit();

        expect(result.unreadable, ['.']);
        expect(result.checked, 0);
      },
    );
  });
}

/// A real PNG of [width] × [height].
///
/// Encoded rather than hand-written: the `image` package's decoder validates
/// chunk CRCs, so a file assembled by hand reads as no image at all — which is
/// how the first version of this helper made `describe` look broken.
List<int> _png(int width, int height) =>
    img.encodePng(img.Image(width: width, height: height));
