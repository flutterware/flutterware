import 'dart:io';

import 'package:flutterware_app/src/plugins/manifest_loader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/dart_executable.dart';

const _config = 'void main() => print(0);';
const _manifest = '{"version":1,"plugins":[]}';

/// Counts compiles, and writes a stand-in kernel so [ManifestLoader] sees the
/// artifact it expects without a real compiler being present.
class _Runs {
  _Runs(this.depfileInputs);

  /// The sources the fake compiler claims to have read.
  List<String> depfileInputs;
  var compiles = 0;

  /// Every spawn, as its first argument — `pub`, `compile`, `run` or a kernel.
  final spawned = <String>[];
  final pubGets = <({List<String> arguments, String? workingDirectory})>[];
  var pubResult = ProcessResult(0, 0, '', '');

  /// What compiling and running the config answer instead, when it is broken.
  ProcessResult? configFailure;

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    spawned.add(arguments.first);
    if (arguments.first == 'pub') {
      pubGets.add((arguments: arguments, workingDirectory: workingDirectory));
      return pubResult;
    }
    if (configFailure case var failure?) return failure;
    if (arguments.firstOrNull == 'compile') {
      compiles++;
      var out = arguments[arguments.indexOf('-o') + 1];
      File(out)
        ..createSync(recursive: true)
        ..writeAsStringSync('kernel');
      // What the real compiler writes: everything the config reached. The
      // stamp is derived from this, so a test that omits it is testing a
      // cache that trusts nothing.
      var deps = arguments[arguments.indexOf('--depfile') + 1];
      File(deps)
        ..createSync(recursive: true)
        ..writeAsStringSync('$out: ${depfileInputs.join(' ')}\n');
      return ProcessResult(0, 0, '', '');
    }
    // Either `dart run tool/flutterware.dart` or `dart <kernel>` — both print
    // the manifest and nothing else.
    return ProcessResult(0, 0, _manifest, '');
  }
}

void main() {
  late Directory root;
  late File config;
  late File packageConfig;
  late _Runs runs;
  late ManifestLoader loader;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_manifest_loader');
    config = File(p.join(root.path, configFilePath))
      ..createSync(recursive: true)
      ..writeAsStringSync(_config);
    packageConfig = File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[]}');
    runs = _Runs([config.path]);
    loader = ManifestLoader(dartExecutable: '/sdk/dart', runProcess: runs.call);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('compiles once, then reuses the kernel', () async {
    expect((await loader.load(root.path))!.plugins, isEmpty);
    expect(runs.compiles, 1);

    await loader.load(root.path);
    expect(runs.compiles, 1, reason: 'the second load must hit the cache');
  });

  test('a rewritten config with identical bytes does not recompile', () async {
    await loader.load(root.path);
    expect(runs.compiles, 1);

    // What a `git checkout` away and back leaves behind: same content, later
    // mtime. A stat-based key recompiled here.
    config.writeAsStringSync(_config);
    config.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));

    await loader.load(root.path);
    expect(runs.compiles, 1);
  });

  test(
    'a rewritten package_config with identical bytes does not recompile',
    () async {
      await loader.load(root.path);
      expect(runs.compiles, 1);

      // What a `pub get` that settled on the same resolution leaves behind,
      // and what the loader's own refresh leaves when it touches the file —
      // the case that used to make using flutterware invalidate
      // flutterware's own cache.
      var contents = packageConfig.readAsStringSync();
      packageConfig.writeAsStringSync(contents);
      packageConfig.setLastModifiedSync(
        DateTime.now().add(const Duration(minutes: 5)),
      );

      await loader.load(root.path);
      expect(runs.compiles, 1);
    },
  );

  test('an edit to an imported file recompiles', () async {
    // `dart compile kernel` bundles the whole program, so a declaration can
    // move in a file the config imports without the config itself changing a
    // byte. Keying on the config alone served a stale kernel — and a stale
    // manifest reads as "no changes", which is the one wrong answer the reload
    // machinery cannot recover from.
    var imported = File(p.join(root.path, 'tool', 'plugins.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('const label = "One";');
    runs.depfileInputs = [config.path, imported.path];

    await loader.load(root.path);
    expect(runs.compiles, 1);

    await loader.load(root.path);
    expect(runs.compiles, 1, reason: 'nothing moved');

    imported.writeAsStringSync('const label = "Two";');
    await loader.load(root.path);
    expect(
      runs.compiles,
      2,
      reason: 'the closure moved, so the kernel is stale',
    );
  });

  test('a missing dependency list is not trusted', () async {
    await loader.load(root.path);
    expect(runs.compiles, 1);

    File(p.join(root.path, '.dart_tool', 'flutterware', 'manifest.deps'))
        .deleteSync();

    await loader.load(root.path);
    expect(
      runs.compiles,
      2,
      reason: 'unknown inputs means recompile, not reuse',
    );
  });

  test('changed config content recompiles', () async {
    await loader.load(root.path);
    config.writeAsStringSync('void main() => print(1);');

    await loader.load(root.path);
    expect(runs.compiles, 2);
  });

  test('changed package resolution recompiles', () async {
    await loader.load(root.path);
    packageConfig.writeAsStringSync(
      '{"configVersion":2,"packages":[],"flutterVersion":"3.48.0"}',
    );

    await loader.load(root.path);
    expect(runs.compiles, 2);
  });

  test('a different dart recompiles, even with both files untouched', () async {
    await loader.load(root.path);
    expect(runs.compiles, 1);

    // An fvm switch with no `pub get` after it: `flutterRoot` in
    // package_config.json still names the old SDK, so the executable is the
    // only thing that says otherwise.
    await ManifestLoader(
      dartExecutable: '/other-sdk/dart',
      runProcess: runs.call,
    ).load(root.path);
    expect(runs.compiles, 2);
  });

  group('a package config older than its lock', () {
    setUp(() {
      // What moving a worktree's branch leaves: the checkout writes the new
      // pubspec and lock now, and the resolution is from the last `pub get`.
      for (var name in ['pubspec.yaml', 'pubspec.lock']) {
        File(p.join(root.path, name)).writeAsStringSync('# $name');
      }
      packageConfig.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
    });

    test(
      'is refreshed offline before the config runs, and only once',
      () async {
        await loader.load(root.path);

        expect(runs.pubGets.single.arguments, [
          'pub',
          'get',
          '--offline',
          '--enforce-lockfile',
        ]);
        expect(runs.pubGets.single.workingDirectory, root.path);
        expect(runs.spawned.first, 'pub');

        // A `pub get` with nothing to change writes nothing, so without the
        // touch every load would pay for the same refresh.
        await loader.load(root.path);
        expect(runs.pubGets, hasLength(1));
      },
    );

    test(
      'a refresh that fails leads the error of a config that fails',
      () async {
        runs
          ..pubResult = ProcessResult(
            0,
            69,
            'Resolving dependencies...',
            "Because proj depends on extra any which doesn't exist (could not "
                'find package extra in cache), version solving failed.',
          )
          ..configFailure = ProcessResult(
            0,
            254,
            '',
            "Error: Type 'StackService' not found.",
          );

        await expectLater(
          loader.load(root.path),
          throwsA(
            isA<ManifestLoadException>()
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    startsWith('$configFilePath exited with 254. '),
                    contains('older than pubspec.yaml and pubspec.lock'),
                    contains('version solving failed'),
                    contains('Run `dart pub get` in ${root.path}'),
                  ),
                )
                .having((e) => e.details, 'details', contains('StackService')),
          ),
        );
      },
    );

    test('a refresh that fails does not stop a config that runs', () async {
      runs.pubResult = ProcessResult(0, 69, '', 'version solving failed.');

      expect((await loader.load(root.path))!.plugins, isEmpty);
    });
  });

  test('a package config newer than its inputs is not refreshed', () async {
    for (var name in ['pubspec.yaml', 'pubspec.lock']) {
      File(p.join(root.path, name))
        ..writeAsStringSync('# $name')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)),
        );
    }

    await loader.load(root.path);
    expect(runs.pubGets, isEmpty);
  });

  test('a worktree whose branch moved loads against its own lock', () async {
    // Real pub and a real compile. Path dependencies stand in for the
    // flutterware commit a lock pins, so nothing touches git or the pub cache.
    var dart = resolveDartExecutable();
    void package(String dir, Map<String, String> files) {
      for (var MapEntry(:key, :value) in files.entries) {
        File(p.join(root.path, dir, key))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
    }

    String pubspec(String dependency) =>
        'name: proj\n'
        'environment:\n'
        '  sdk: ^3.10.0\n'
        'dependencies:\n'
        '  dep:\n'
        '    path: ../$dependency\n';

    const pubspecOfDep = 'name: dep\nenvironment:\n  sdk: ^3.10.0\n';
    package('old', {'pubspec.yaml': pubspecOfDep, 'lib/dep.dart': ''});
    package('new', {
      'pubspec.yaml': pubspecOfDep,
      'lib/dep.dart': "const manifest = '$_manifest';",
    });
    var config =
        "import 'package:dep/dep.dart';\nvoid main() => print(manifest);\n";
    package('proj', {'pubspec.yaml': pubspec('old'), configFilePath: config});
    package('main', {'pubspec.yaml': pubspec('new'), configFilePath: config});
    for (var dir in ['proj', 'main']) {
      var got = Process.runSync(dart, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: p.join(root.path, dir));
      expect(got.exitCode, 0, reason: '${got.stderr}');
    }

    // The branch moves: the checkout writes main's pubspec and lock, and
    // leaves the resolution of the last `pub get`.
    var worktree = p.join(root.path, 'proj');
    var resolution = File(p.join(worktree, '.dart_tool', 'package_config.json'))
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    for (var name in ['pubspec.yaml', 'pubspec.lock']) {
      File(p.join(root.path, 'main', name)).copySync(p.join(worktree, name));
    }
    expect(resolution.readAsStringSync(), contains('../old'));

    var manifest = await ManifestLoader(dartExecutable: dart).load(worktree);

    expect(manifest!.plugins, isEmpty);
    expect(resolution.readAsStringSync(), contains('../new'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
