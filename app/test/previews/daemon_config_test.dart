import 'dart:io';

import 'package:flutterware_app/src/previews/daemon_address.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The daemon address invariant, checked rather than asserted.
///
/// > *"The address is derived, not assigned, so every consumer that wants the
/// > same catalog — the GUI, `fw`, an agent, a test — arrives at the same socket
/// > without being told about each other."*
///
/// That sentence was in [DaemonAddress]'s docstring for months while it was
/// false. The GUI and `fw` each built their own [DaemonConfig] for the same
/// package and disagreed about `appPackageRoot`, so they hashed differently and
/// never shared a compiler. Nothing failed: two daemons is a slow success, and
/// the divergence was found by reading, not by running.
///
/// So these tests are about the *shape* of the mistake rather than about either
/// call site. A test that reconstructed both configs by hand would only be
/// checking that this file agrees with itself; what makes the invariant hold is
/// that [DaemonConfig.forPackage] is the only door, which is what the last group
/// verifies against the source.
///
/// Pure unit tests — no SDK, no daemon, no Flutter.
void main() {
  late Directory temp;
  late String appTool;
  late String package;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fw-daemon-config');
    // `forPackage` resolves the package config off disk, and a workspace member
    // has none of its own — so the fixture is a workspace: one `.dart_tool/` at
    // the root, packages below it.
    File(p.join(temp.path, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"configVersion": 2, "packages": []}');
    appTool = p.join(temp.path, 'app');
    package = p.join(temp.path, 'fixtures', 'probe_app');
    for (var dir in [appTool, package]) {
      Directory(dir).createSync(recursive: true);
    }
  });

  tearDown(() => temp.deleteSync(recursive: true));

  DaemonConfig configFor({String? appToolDirectory, String? packageRoot}) =>
      DaemonConfig.forPackage(
        appToolDirectory: appToolDirectory ?? appTool,
        packageRoot: packageRoot ?? package,
        flutterSdkRoot: '/flutter',
        roots: const ['demo'],
      );

  group('forPackage', () {
    test('two callers with the same inputs reach the same socket', () {
      // The GUI and `fw` differ in everything except these four values. If the
      // key is a function of them alone, the surfaces cannot disagree.
      expect(
        DaemonAddress(configFor()).key,
        DaemonAddress(configFor()).key,
        reason: 'One package, one daemon — this is the whole property.',
      );
    });

    test('the app install and the package are not interchangeable', () {
      // The bug, in one line: passing the package where the app install goes
      // produced a config that looked fine and addressed a different daemon.
      expect(
        DaemonAddress(configFor(appToolDirectory: package)).key,
        isNot(DaemonAddress(configFor()).key),
      );
    });

    test('the app install is appPackageRoot; the package is projectRoot', () {
      var config = configFor();
      // Named apart because the field name reads like the wrong one. This is
      // the assignment the daemon depends on: `appPackageRoot` is where it
      // finds its own script, `.engine/` and `native/`.
      expect(config.appPackageRoot, appTool);
      expect(config.projectRoot, package);
    });

    test("the package config is the project's, resolved by walking up", () {
      // A workspace member has no `.dart_tool/` of its own, and the config the
      // catalog needs is the one that resolves flutter, flutterware *and* the
      // demos' own package. That is always the project's.
      expect(
        configFor().packageConfig,
        p.join(temp.path, '.dart_tool', 'package_config.json'),
      );
    });

    test('a package with no resolution says so', () {
      var orphan = Directory(
        p.join(Directory.systemTemp.createTempSync('fw-orphan').path, 'pkg'),
      )..createSync(recursive: true);
      addTearDown(() => orphan.parent.deleteSync(recursive: true));
      expect(
        () => configFor(packageRoot: orphan.path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('dart pub get'),
          ),
        ),
      );
    });

    test('every field of the config forks the address', () {
      // `DaemonAddress` hashes the whole config on purpose: adding a field
      // without thinking about sharing should split the daemon rather than hand
      // a client someone else's compiler. Checked so that a field added with a
      // custom `toJson` cannot quietly fall out of the key.
      var base = DaemonAddress(configFor()).key;
      var variants = {
        'roots': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/flutter',
          roots: const ['tool/catalog'],
        ),
        'flutterSdkRoot': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/other-flutter',
          roots: const ['demo'],
        ),
        'emitProbe': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/flutter',
          roots: const ['demo'],
          emitProbe: true,
        ),
        'daemonRevision': configFor().withDaemonRevision('123'),
        'setup': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/flutter',
          roots: const ['demo'],
          setup: 'lib/preview_setup.dart',
        ),
      };
      variants.forEach((field, config) {
        expect(
          DaemonAddress(config).key,
          isNot(base),
          reason:
              '$field changes what the daemon would produce, so it has to '
              'change where it listens.',
        );
      });
    });

    test('a package that declares no setup keeps the address it had', () {
      // Left out of the JSON when null, rather than written as `null`: every
      // daemon already running for a package without one would otherwise be
      // orphaned by an upgrade, and its warm kernel with it.
      expect(configFor().toJson().containsKey('setup'), isFalse);
    });

    test('a new daemon revision keeps the kernel it can start from', () {
      // `key` and `kernelKey` answer different questions. A daemon of another
      // revision must not serve this one's clients — it decides what goes into
      // a hot-reload delta. But the kernel and the quarantine describe the
      // *sources*, which flutterware's own code moving says nothing about.
      // Measured before they were keyed apart: 841ms became 10493ms.
      var base = configFor();
      var next = base.withDaemonRevision('a-later-build');
      expect(
        DaemonAddress(next).key,
        isNot(DaemonAddress(base).key),
        reason: 'a stale daemon must not answer for a newer one',
      );
      expect(
        DaemonAddress(next).kernelKey,
        DaemonAddress(base).kernelKey,
        reason: 'but it starts from what the last one compiled',
      );
      expect(
        DaemonAddress(next).warmDillPath,
        DaemonAddress(base).warmDillPath,
      );
      expect(
        DaemonAddress(next).quarantinePath,
        DaemonAddress(base).quarantinePath,
      );
    });

    test('everything else still forks the kernel too', () {
      // `daemonRevision` is the *only* field the kernel is allowed to ignore.
      // A field added without thinking about sharing must split both, or a
      // daemon starts from a kernel compiled against something else.
      var base = DaemonAddress(configFor()).kernelKey;
      var variants = {
        'roots': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/flutter',
          roots: const ['tool/catalog'],
        ),
        'flutterSdkRoot': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/other-flutter',
          roots: const ['demo'],
        ),
        'emitProbe': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/flutter',
          roots: const ['demo'],
          emitProbe: true,
        ),
        // Imported by the entrypoint, so it is compiled into the kernel.
        'setup': DaemonConfig.forPackage(
          appToolDirectory: appTool,
          packageRoot: package,
          flutterSdkRoot: '/flutter',
          roots: const ['demo'],
          setup: 'lib/preview_setup.dart',
        ),
      };
      variants.forEach((field, config) {
        expect(
          DaemonAddress(config).kernelKey,
          isNot(base),
          reason: '$field changes what the compiler would produce',
        );
      });
    });

    test('reading the kernel key does not consume the config', () {
      // It is computed by dropping a field from `toJson()`; dropping it from
      // the *config* instead would make the address depend on who asked first.
      var config = configFor().withDaemonRevision('rev-1');
      var address = DaemonAddress(config);
      expect(address.kernelKey, isNotEmpty);
      expect(
        address.key,
        DaemonAddress(configFor().withDaemonRevision('rev-1')).key,
      );
      expect(config.daemonRevision, 'rev-1');
    });

    test('the key does not depend on the order toJson emits fields', () {
      // The canonicalisation in `DaemonAddress`, exercised rather than trusted:
      // a hash over raw `jsonEncode` would move when a field was reordered in
      // the class, splitting every running daemon for no reason.
      var json = configFor().toJson();
      var reversed = {
        for (var key in json.keys.toList().reversed) key: json[key],
      };
      expect(
        DaemonAddress(DaemonConfig.fromJson(reversed)).key,
        DaemonAddress(configFor()).key,
      );
    });
  });

  group('one door', () {
    // The invariant above only holds while `forPackage` is the only way a
    // config gets built. A second construction site is exactly how the last
    // divergence happened, and it is invisible to any test that calls
    // `forPackage` itself — so this reads the source.
    test('nothing in lib/ constructs a DaemonConfig directly', () {
      var offenders = <String>[];
      for (var file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        var lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('DaemonConfig(')) continue;
          // `protocol.dart` declares it and `forPackage` calls it; that is the
          // door, not a way around it. Its generated codec is the decode side —
          // the daemon reads a config it was handed, it does not build one.
          if (p.basename(file.path) == 'protocol.dart' ||
              file.path.endsWith('.g.dart')) {
            continue;
          }
          offenders.add('${file.path}:${i + 1}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Build configs through DaemonConfig.forPackage. A second '
            'construction site is how the GUI and `fw` came to address '
            'different daemons for the same package.',
      );
    });
  });
}
