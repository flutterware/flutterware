import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scenario_replay_protocol.dart';
import 'package:flutterware_app/src/scenarios/replay_build.dart';
import 'package:path/path.dart' as p;

/// What a replay build writes around the two processes it runs.
///
/// Both are stubbed: the `flutter test` writes one index file the way the
/// recorder does, and the `flutter build web` writes the font manifest an
/// app's build has. Whether they work is the integration test's question.
void main() {
  late Directory package;
  late Directory sdk;

  setUp(() {
    package = Directory.systemTemp.createTempSync('replay_build');
    sdk = Directory.systemTemp.createTempSync('replay_sdk');
    for (var path in [
      'test/scenarios/flutter_test_config.dart',
      'test/scenarios/shop_test.dart',
      'test/scenarios/deep/cart_test.dart',
      'test/other_test.dart',
    ]) {
      File(p.join(package.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
    }
    var fonts = p.join(sdk.path, 'bin', 'cache', 'artifacts', 'material_fonts');
    for (var face in ['Roboto-Regular', 'Roboto-Bold', 'Roboto-Italic']) {
      File(p.join(fonts, '$face.ttf'))
        ..createSync(recursive: true)
        ..writeAsStringSync(face);
    }
  });

  tearDown(() {
    package.deleteSync(recursive: true);
    sdk.deleteSync(recursive: true);
  });

  test('a file is wrapped in the nearest config above it', () {
    expect(
      nearestTestConfig(package.path, 'test/scenarios/deep/cart_test.dart'),
      'test/scenarios/flutter_test_config.dart',
    );
    expect(nearestTestConfig(package.path, 'test/other_test.dart'), isNull);
  });

  test('the entry point declares each file in its config', () {
    var entry = replayEntryPoint(
      files: ['test/scenarios/shop_test.dart', 'test/other_test.dart'],
      configOf: (file) => nearestTestConfig(package.path, file),
      from: '.dart_tool/flutterware/scenario_replay',
    );
    expect(
      entry,
      contains("import '../../../test/scenarios/shop_test.dart' as file0;"),
    );
    expect(
      entry,
      contains(
        "import '../../../test/scenarios/flutter_test_config.dart' as config0;",
      ),
    );
    expect(
      entry,
      contains(
        'ReplayFile("test/scenarios/shop_test.dart", file0.main, '
        'testExecutable: config0.testExecutable),',
      ),
    );
    expect(entry, contains('ReplayFile("test/other_test.dart", file1.main),'));
  });

  test('a build writes the page, its manifest and the index', () async {
    var output = p.join(package.path, 'build', 'scenario_replay');
    var calls = <(List<String>, Map<String, String>)>[];
    var builder =
        ScenarioReplayBuilder(
            flutterExecutable: p.join(sdk.path, 'bin', 'flutter'),
            packageRoot: package.path,
          )
          ..debugRun = (arguments, {environment = const {}}) async {
            calls.add((arguments, environment));
            if (arguments.first == 'test') {
              File(p.join(environment['FW_REPLAY_INDEX']!, 'shop.1.json'))
                  .writeAsStringSync(jsonEncode(_recorded));
              // A red suite still writes its index.
              return 1;
            }
            File(p.join(output, 'assets', 'FontManifest.json'))
              ..createSync(recursive: true)
              ..writeAsStringSync(
                jsonEncode([
                  {'family': 'MaterialIcons', 'fonts': []},
                  {'family': 'Lobster', 'fonts': []},
                  {'family': 'packages/icons/Rounded', 'fonts': []},
                ]),
              );
            return 0;
          };

    var built = await builder.build(
      files: ['test/scenarios/shop_test.dart'],
      output: output,
      keepFonts: ['Lobster'],
    );

    expect(calls.first.$1, ['test', 'test/scenarios/shop_test.dart']);
    var buildArguments = calls.last.$1;
    expect(buildArguments, containsAll(['--wasm', '-O2']));
    expect(buildArguments, contains('--dart-define=dart.vm.product=false'));
    expect(buildArguments, contains('--dart-define=fw.matrix=declared'));
    expect(File(builder.entryPoint).existsSync(), isTrue);

    expect(built.testsPassed, isFalse);
    expect(built.index.keys.keys, ['shop/title']);
    expect(built.droppedFonts, ['packages/icons/Rounded']);

    var html = File(p.join(output, 'index.html')).readAsStringSync();
    expect(html, contains('flutter_bootstrap.js'));
    expect(html, isNot(contains('main.dart.js')));

    var manifest = ReplayManifest.fromJson(
      jsonDecode(File(p.join(output, replayManifestFile)).readAsStringSync())
          as Map<String, Object?>,
    );
    expect(manifest.commonAssets, [
      'AssetManifest.bin',
      'AssetManifest.bin.json',
    ]);
    expect(manifest.assetsOf('test/scenarios/shop_test.dart', 'Order'), [
      'assets/i18n/en.json',
    ]);
    // Regular and bold, upright: what the default text was drawn in.
    expect(manifest.defaultFonts, [
      'flutterware/fonts/Roboto-Bold.ttf',
      'flutterware/fonts/Roboto-Regular.ttf',
    ]);
    expect(
      File(p.join(output, 'flutterware', 'fonts', 'Roboto-Bold.ttf'))
          .existsSync(),
      isTrue,
    );
    var index = ReplayIndex.fromJson(
      jsonDecode(File(p.join(output, replayIndexFile)).readAsStringSync())
          as Map<String, Object?>,
    );
    expect(index.scenarios.single.steps, hasLength(2));
  });

  test('an index from elsewhere skips the test run', () async {
    var given = Directory(p.join(package.path, 'ci_index'))..createSync();
    File(p.join(given.path, 'a.json')).writeAsStringSync(jsonEncode(_recorded));
    var calls = <String>[];
    await (ScenarioReplayBuilder(
            flutterExecutable: p.join(sdk.path, 'bin', 'flutter'),
            packageRoot: package.path,
          )
          ..debugRun = (arguments, {environment = const {}}) async {
            calls.add(arguments.first);
            return 0;
          })
        .build(
          files: ['test/scenarios/shop_test.dart'],
          output: p.join(package.path, 'out'),
          indexFrom: given.path,
        );
    expect(calls, ['build']);
  });

  test('an index that names nothing is refused', () async {
    var builder = ScenarioReplayBuilder(
      flutterExecutable: p.join(sdk.path, 'bin', 'flutter'),
      packageRoot: package.path,
    )..debugRun = (arguments, {environment = const {}}) async => 0;
    await expectLater(
      builder.build(
        files: ['test/scenarios/shop_test.dart'],
        output: p.join(package.path, 'out'),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('FW_REPLAY_INDEX'),
        ),
      ),
    );
  });
}

const _recorded = {
  'scenarios': [
    {
      'file': 'test/scenarios/shop_test.dart',
      'scenario': 'Order',
      'steps': [
        {
          'position': '#1',
          'verb': 'pumpWidget',
          'keys': ['shop/title'],
        },
        {'position': '#2', 'verb': 'tap', 'keys': <String>[]},
      ],
      'assets': ['assets/i18n/en.json'],
    },
  ],
  'commonAssets': ['AssetManifest.bin', 'AssetManifest.bin.json'],
  'fonts': ['CupertinoSystemText', 'MaterialIcons'],
  'faces': [
    'CupertinoSystemText:400',
    'CupertinoSystemText:700',
    'MaterialIcons:400',
  ],
};
