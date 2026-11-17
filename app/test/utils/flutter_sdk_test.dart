import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/constants.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

// The SDK is the one that started us, and nothing else is consulted. These
// tests exist mostly to keep it that way: a pin file, a version manager's
// cache or `FLUTTER_HOME` next to the process must not change the answer.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fw-sdk-test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// An SDK is two executables — what [FlutterSdkPath.isValid] checks.
  String fakeSdk(String at) {
    for (var name in ['flutter', 'dart']) {
      File(p.join(at, 'bin', name)).createSync(recursive: true);
    }
    return at;
  }

  FlutterSdkPath recorded(String at, Map<String, String> version) {
    var sdk = FlutterSdkPath(fakeSdk(at));
    File(p.join(at, 'bin', 'cache', 'flutter.version.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(version));
    return sdk;
  }

  test("the launcher's dart is the answer", () async {
    var sdk = fakeSdk(p.join(tmp.path, 'sdk'));
    var found = await FlutterSdkPath.findSdk(
      environment: {dartExecutableEnvironmentKey: p.join(sdk, 'bin', 'dart')},
    );
    expect(found?.root, p.canonicalize(sdk));
  });

  test('a dart with no SDK above it does not answer', () async {
    // Falls through to the executable running this test, which is inside a
    // real SDK — so the assertion is that the *stray path* was not adopted.
    var stray = Directory(p.join(tmp.path, 'nowhere'))..createSync();
    var found = await FlutterSdkPath.findSdk(
      environment: {dartExecutableEnvironmentKey: p.join(stray.path, 'dart')},
    );
    expect(found?.root, isNot(p.canonicalize(stray.path)));
  });

  test('nothing else on the machine is consulted', () async {
    // Every source the ladder used to carry, all naming one SDK, all ignored:
    // the answer is the running executable's, never this one.
    var decoy = fakeSdk(p.join(tmp.path, 'decoy'));
    File(p.join(tmp.path, '.fvmrc')).writeAsStringSync('{"flutter":"3.99.0"}');
    File(p.join(tmp.path, 'flutter_version')).writeAsStringSync('3.99.0');
    fakeSdk(p.join(tmp.path, 'home', 'fvm', 'versions', '3.99.0'));
    Link(p.join(tmp.path, '.flutterware', 'sdk'))
      ..parent.createSync(recursive: true)
      ..createSync(decoy);

    var found = await FlutterSdkPath.findSdk(
      environment: {
        'HOME': p.join(tmp.path, 'home'),
        'FLUTTER_HOME': decoy,
        'FVM_CACHE_PATH': p.join(tmp.path, 'home', 'fvm'),
      },
    );

    expect(found?.root, isNot(p.canonicalize(decoy)));
    expect(
      found?.root,
      isNot(contains(tmp.path)),
      reason: 'no source below the temp root may answer',
    );
  });

  // A cache key. A CI image keeps Flutter at one path across every upgrade, so
  // a key naming the path served the previous engine's pictures to the next.
  group('what an SDK is, rather than where', () {
    test('two SDKs at one path are two identities', () {
      var at = p.join(tmp.path, 'sdk');
      var older = recorded(at, {
        'frameworkVersion': '3.47.0',
        'frameworkRevision': 'aaa',
        'engineRevision': 'eee',
      });
      var olderIdentity = older.identity;
      var newer = recorded(at, {
        'frameworkVersion': '3.48.0',
        'frameworkRevision': 'bbb',
        'engineRevision': 'fff',
      });

      expect(newer.root, older.root);
      expect(newer.identity, isNot(olderIdentity));
      expect(newer.version, '3.48.0');
    });

    test('one SDK at two paths is one identity', () {
      var version = {'frameworkRevision': 'aaa', 'engineRevision': 'eee'};

      expect(
        recorded(p.join(tmp.path, 'a'), version).identity,
        recorded(p.join(tmp.path, 'b'), version).identity,
      );
    });

    test('an SDK that recorded nothing falls back to its path', () {
      var sdk = FlutterSdkPath(fakeSdk(p.join(tmp.path, 'bare')));

      expect(sdk.identity, sdk.root);
      expect(sdk.version, isNull);
    });
  });

  test('the SDK of a flutter is the directory above its bin', () {
    var sdk = fakeSdk(p.join(tmp.path, 'sdk'));

    expect(
      FlutterSdkPath.ofFlutter(p.join(sdk, 'bin', 'flutter')).root,
      p.canonicalize(sdk),
    );
  });

  // 3.51 retired the caching service worker and fails a build that passes
  // `--pwa-strategy`. Before it, a build without the flag adds a worker.
  group('a web build without a service worker', () {
    List<String> on(String version) => recorded(p.join(tmp.path, 'sdk'), {
      'frameworkVersion': version,
    }).webBuildWithoutServiceWorker;

    test('passes --pwa-strategy=none before Flutter 3.51', () {
      for (var version in ['3.47.0', '3.47.9', '3.50.0-0.4.pre', '3.50.2']) {
        expect(on(version), ['--pwa-strategy=none'], reason: version);
      }
    });

    test('passes nothing from 3.51 on', () {
      for (var version in [
        '3.51.0-0.1.pre',
        '3.51.0-1.0.pre-12',
        '3.51.0',
        '3.52.1',
        '4.0.0',
      ]) {
        expect(on(version), isEmpty, reason: version);
      }
    });

    test('passes nothing for an SDK that recorded no version', () {
      var sdk = FlutterSdkPath(fakeSdk(p.join(tmp.path, 'bare')));

      expect(sdk.webBuildWithoutServiceWorker, isEmpty);
    });
  });
}
