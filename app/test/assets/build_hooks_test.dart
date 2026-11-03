import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/assets/build_hooks.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:hooks_runner/hooks_runner.dart' show KernelAssets, Target;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Against the real resolution, on purpose.
///
/// A fixture can say that [BuildHooks] calls what it is told to call. What it
/// cannot say is whether the thing being called still behaves the way the whole
/// design rests on — that asking for the host's code assets gets a native hook
/// built for the machine the tester runs on, and that the runner reads a
/// package graph the same way it did when this was written. Both of those live
/// in packages that move under us, so this asks them.
void main() {
  late FlutterSdkPath sdk;
  var repoRoot = p.normalize(p.absolute('..'));

  setUpAll(() async {
    var found = await FlutterSdkPath.tryFind(Platform.resolvedExecutable);
    if (found == null) {
      fail(
        'Could not find the Flutter SDK from ${Platform.resolvedExecutable}',
      );
    }
    sdk = found;
  });

  test('an unresolved project has nothing to run and nothing to say', () async {
    var temp = Directory.systemTemp.createTempSync('fw_hooks');
    addTearDown(() => temp.deleteSync(recursive: true));

    var result = await BuildHooks(
      dartExecutable: sdk.dart,
      packageConfigPath: p.join(temp.path, '.dart_tool', 'package_config.json'),
      rootPackageRoot: temp.path,
    ).run();

    // Not an error. The caller is about to fail on the resolution itself and
    // will say so better than a complaint about hooks would.
    expect(result.packages, isEmpty);
    expect(result.failure, isNull);
  });

  test('this workspace runs its own hooks, native code included', () async {
    var result = await BuildHooks(
      dartExecutable: sdk.dart,
      packageConfigPath: p.join(repoRoot, '.dart_tool', 'package_config.json'),
      rootPackageRoot: p.join(repoRoot, 'app'),
    ).run();

    expect(result.failure, isNull, reason: 'ran ${result.packages}');
    // Which packages ship a hook is the resolution's business and differs by
    // host — `objective_c` is here on macOS and not on Linux — so what the
    // run *names* cannot be asserted. That every asset is for this machine
    // can: the tester is a host binary, and an entry under any other target
    // would never be read.
    for (var asset in result.nativeAssets) {
      expect('${asset.target}', '${Target.current}');
    }
    // No timing bound, deliberately: a hook that compiles native code now
    // genuinely compiles, once per checkout per resolution, and the first run
    // on a cold `.dart_tool/hooks_runner` is a real build. The warm path
    // stays memoised — the test below pins that.
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the macOS deployment floor is the one flutter_tools builds with', () {
    // Same shape as the hooks_runner pin below, same reason spelled at the
    // constant: the SDK does not export `targetMacOSVersion`, so the copy has
    // to be caught the day a pin bump moves the original — otherwise `fw` and
    // `flutter test` compile the same hook for two different floors on one
    // machine, cached apart, diverging silently.
    var source = File(
      p.join(
        sdk.root,
        'packages',
        'flutter_tools',
        'lib',
        'src',
        'isolated',
        'native_assets',
        'macos',
        'native_assets.dart',
      ),
    );
    if (!source.existsSync()) {
      fail('flutter_tools moved its macOS native-assets file: ${source.path}');
    }
    var match = RegExp(r'targetMacOSVersion\s*=\s*(\d+)')
        .firstMatch(source.readAsStringSync());
    expect(match, isNotNull, reason: 'no targetMacOSVersion in ${source.path}');

    expect(BuildHooks.targetMacOSVersion, int.parse(match!.group(1)!));
  });

  test('the manifest speaks each link mode the way the engine reads it', () {
    var libPath = p.join(Directory.systemTemp.path, 'libsqlite3.dylib');
    var manifest = KernelAssets([
      BuildHooks.kernelAssetOf(
        CodeAsset(
          package: 'sqlite3',
          name: 'src/ffi/libsqlite3.g.dart',
          linkMode: DynamicLoadingBundled(),
          file: Uri.file(libPath),
        ),
      ),
      BuildHooks.kernelAssetOf(
        CodeAsset(
          package: 'other',
          name: 'system.dart',
          linkMode: DynamicLoadingSystem(Uri.file('libsystem.so')),
        ),
      ),
      BuildHooks.kernelAssetOf(
        CodeAsset(
          package: 'other',
          name: 'process.dart',
          linkMode: LookupInProcess(),
        ),
      ),
      BuildHooks.kernelAssetOf(
        CodeAsset(
          package: 'other',
          name: 'executable.dart',
          linkMode: LookupInExecutable(),
        ),
      ),
    ]).toNativeAssetsFile();

    var byId =
        ((jsonDecode(manifest) as Map)['native-assets']
                as Map)['${Target.current}']
            as Map;
    // A bundled library is an absolute host path — still the hook's own
    // output at this layer; `AssetBundleBuilder` is what copies it into the
    // bundle and rewrites the path. The rest carry no file at all.
    expect(byId['package:sqlite3/src/ffi/libsqlite3.g.dart'], [
      'absolute',
      libPath,
    ]);
    expect(byId['package:other/system.dart'], ['system', 'libsystem.so']);
    expect(byId['package:other/process.dart'], ['process']);
    expect(byId['package:other/executable.dart'], ['executable']);
  });

  test('a root the resolution cannot name is a failure, not silence', () async {
    var temp = Directory.systemTemp.createTempSync('fw_hooks_root');
    addTearDown(() => temp.deleteSync(recursive: true));

    // A real resolution, and a root that is not in it. Nothing can be asked of
    // a closure that cannot be found, and reporting that as "no hooks here"
    // would switch the whole feature off silently.
    var result = await BuildHooks(
      dartExecutable: sdk.dart,
      packageConfigPath: p.join(repoRoot, '.dart_tool', 'package_config.json'),
      rootPackageRoot: temp.path,
    ).run();

    expect(result.packages, isEmpty);
    expect(result.failure, contains('does not name a package'));
  });

  test(
    'a failure is held, and retried in the background after the hold',
    () async {
      var temp = Directory.systemTemp.createTempSync('fw_hooks_hold');
      addTearDown(() => temp.deleteSync(recursive: true));
      File(p.join(temp.path, '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'root',
                'rootUri': '../',
                'packageUri': 'lib/',
                'languageVersion': '3.0',
              },
            ],
          }),
        );
      var hooks = BuildHooks(
        dartExecutable: sdk.dart,
        packageConfigPath: p.join(
          temp.path,
          '.dart_tool',
          'package_config.json',
        ),
        rootPackageRoot: temp.path,
      );

      // A resolution with no `package_graph.json`: the graph cannot be read.
      var first = await hooks.run();
      expect(first.failure, isNotNull);

      // Fix the world, then ask inside the hold. Still the failure — which is
      // the proof nothing re-ran, because a re-run would now succeed. This is
      // what keeps a reload loop from re-paying a failing native build per
      // tick.
      File(p.join(temp.path, 'pubspec.yaml'))
          .writeAsStringSync('name: root\nenvironment:\n  sdk: ^3.0.0\n');
      File(
        p.join(temp.path, '.dart_tool', 'package_graph.json'),
      ).writeAsStringSync(
        jsonEncode({
          'roots': ['root'],
          'packages': [
            {'name': 'root', 'version': '1.0.0', 'dependencies': <String>[]},
          ],
          'configVersion': 1,
        }),
      );
      var held = await hooks.run();
      expect(held.failure, first.failure);

      // Past the hold, the ask kicks the retry and is *still* answered from
      // the hold: the cost of retrying lands on no bundle build.
      var later = Clock.fixed(clock.now().add(BuildHooks.retryHold * 2));
      var kicked = await withClock(later, hooks.run);
      expect(kicked.failure, first.failure);

      // The retry lands in the background; recovery is one ask behind.
      var deadline = DateTime.now().add(const Duration(seconds: 30));
      BuildHooksResult recovered;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        recovered = await hooks.run();
      } while (recovered.failure != null && DateTime.now().isBefore(deadline));
      expect(recovered.failure, isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a second ask is the same run, not a second one', () async {
    var hooks = BuildHooks(
      dartExecutable: sdk.dart,
      packageConfigPath: p.join(repoRoot, '.dart_tool', 'package_config.json'),
      rootPackageRoot: p.join(repoRoot, 'app'),
    );
    // `hooks_runner` documents that it does not support reentrancy for an
    // identical input, and two bundle builds for one workspace are ordinary.
    expect(hooks.run(), same(hooks.run()));
  });

  test('one workspace builds its hooks one package at a time', () async {
    var running = <String>{};
    var started = <String>[];
    Future<String> build(String name, Completer<void> gate) async {
      started.add(name);
      running.add(name);
      await gate.future;
      running.remove(name);
      return name;
    }

    var phone = Completer<void>();
    var desk = Completer<void>();
    var other = Completer<void>();
    var workspace = '/ws/.dart_tool';
    var first = BuildHooks.oneAtATime(workspace, () => build('app', phone));
    var second = BuildHooks.oneAtATime(workspace, () => build('admin', desk));
    var elsewhere = BuildHooks.oneAtATime(
      '/other/.dart_tool',
      () => build('other', other),
    );
    await pumpEventQueue();
    // Another workspace's run is not held up; the same one's is.
    expect(running, {'app', 'other'});

    phone.complete();
    expect(await first, 'app');
    await pumpEventQueue();
    expect(running, {'admin', 'other'});

    desk.complete();
    other.complete();
    expect(await second, 'admin');
    expect(await elsewhere, 'other');
    expect(started, ['app', 'other', 'admin']);
  });

  test('a run that throws does not hold up the next one', () async {
    var failing = BuildHooks.oneAtATime<void>(
      '/ws2/.dart_tool',
      () async => throw StateError('hook'),
    );
    await expectLater(failing, throwsStateError);
    expect(
      await BuildHooks.oneAtATime('/ws2/.dart_tool', () async => 'next'),
      'next',
    );
  });

  test('the pinned hooks_runner is the one the SDK builds with', () {
    var tools = p.join(sdk.root, 'packages', 'flutter_tools', 'pubspec.yaml');
    if (!File(tools).existsSync()) {
      fail('No flutter_tools pubspec at $tools');
    }
    Object? pinIn(String pubspec) {
      var yaml = loadYaml(File(pubspec).readAsStringSync()) as YamlMap;
      return (yaml['dependencies'] as YamlMap)['hooks_runner'];
    }

    var theirs = pinIn(tools);
    var ours = pinIn(p.absolute('pubspec.yaml'));

    expect(
      '$ours',
      '$theirs',
      reason:
          'A hook and the runner negotiate a protocol version, so the runner '
          'the SDK resolved a project against is the one that can speak to '
          "that project's hooks. Bump app/pubspec.yaml to match — and check "
          'what the new constraint does to the rest of the resolution before '
          'you do: 1.6.3 requires `code_assets ^2.0.0`, which evicts '
          '`native_toolchain_c` and takes `sqlite3` back a major version.',
    );
  });

  group('a hook another SDK compiled', () {
    late Directory hooks;
    setUp(() => hooks = Directory.systemTemp.createTempSync('hooks_runner'));
    tearDown(() => hooks.deleteSync(recursive: true));

    const ours = '/fvm/versions/3.50.0-0.3.pre/bin/cache/dart-sdk';
    Directory build(String package, String compiledBy) {
      var dir = Directory(p.join(hooks.path, package, '0b282c055b'))
        ..createSync(recursive: true);
      for (var name in ['hook.dill', 'hook.dill.d', 'output.json']) {
        File(p.join(dir.path, name)).writeAsStringSync('');
      }
      File(p.join(dir.path, 'hook.dependencies_hash_file.json'))
          .writeAsStringSync(
            jsonEncode({
              'file_system': [
                {'path': '/project/.dart_tool/package_config.json', 'hash': 1},
                {'path': '$compiledBy/version', 'hash': 2},
              ],
              'environment': <Object>[],
            }),
          );
      return dir;
    }

    test('is compiled again, and one ours compiled is kept', () {
      var stale = build(
        'objective_c',
        '/fvm/versions/3.50.0-0.1.pre/bin/cache/dart-sdk',
      );
      var fresh = build('sqlite3', ours);

      dropHooksCompiledElsewhere(
        hooksDir: hooks.path,
        dartExecutable: '$ours/bin/dart',
      );

      List<String> left(Directory dir) =>
          dir.listSync().map((f) => p.basename(f.path)).toList()..sort();
      expect(left(stale), ['output.json']);
      expect(left(fresh), [
        'hook.dependencies_hash_file.json',
        'hook.dill',
        'hook.dill.d',
        'output.json',
      ]);
    });

    test('fails naming the hook and what it wrote', () {
      // As hooks_runner 1.6.1 logs a hook whose kernel the VM refused.
      var logged = '''
  Building assets for package:objective_c failed.
  build.dart returned with exit code: 255.
  To reproduce run:
  (cd /pub-cache/objective_c-9.5.0/; dart hook.dill --config=input.json)
  stderr:
  Can't load Kernel binary: Invalid SDK hash.

  stdout:
  ''';
      var expected =
          "objective_c's build hook failed: Can't load Kernel binary: "
          'Invalid SDK hash.';
      expect(failedHooks(['Some other line', logged]), [expected]);
    });

    test('names what a hook that threw said, not that it threw', () {
      // As hooks_runner logs a CMake hook whose install step failed.
      var logged = '''
  Building assets for package:webcrypto failed.
  stderr:
  Unhandled exception:
  Exception: Failed to build CMake project: CMake Error at cmake_install.cmake:41 (file):
    file INSTALL cannot set modification time

  #0      RunCMakeBuilder.run (package:native_toolchain_cmake/src/builder/run_builder.dart:192:7)
  ''';
      var expected =
          "webcrypto's build hook failed: Failed to build CMake project: "
          'CMake Error at cmake_install.cmake:41 (file).';
      expect(failedHooks([logged]), [expected]);
    });
  });
}
