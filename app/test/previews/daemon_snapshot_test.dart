import 'dart:io';

import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Which SDK a daemon snapshot belongs to, and why the answer has to be in its
/// path.
///
/// The snapshot used to live at one constant path per install —
/// `<appPackageRoot>/build/catalog/daemon.dill` — invalidated by source mtime
/// alone. For a path dependency that is one checkout serving one project and
/// nothing can go wrong. For a hosted or git-pinned install it was
/// `~/.flutterware/<sha1(packageRoot)>/app/`, keyed on the *flutterware*
/// revision alone: every project on the machine pinning that revision shared
/// the directory, and each brought its own Flutter.
///
/// So two projects on two Flutter betas took turns bricking each other.
/// Whichever compiled the snapshot last owned it; the other one handed its own
/// Dart a kernel built by a different Dart, which the VM refuses —
/// `Can't load Kernel binary: Invalid SDK hash.` — before it can bind, so the
/// client polled a socket that would never appear for 30 seconds and then
/// blamed the socket. Permanently: the snapshot stayed newer than the sources,
/// which were never the problem. Deleting it fixed one project and broke the
/// other.
///
/// Pure unit tests — no SDK, no daemon, no compiler. The fixtures below are
/// directory layouts, because a layout is all [DartSdkIdentity.of] reads.

/// The prefix the VM's refusals share, as [DaemonLog]'s callers pass it.
const _rejected = "Can't load Kernel binary";

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('fw-daemon-snapshot'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// A Dart SDK at `<name>/`, as `dart compile kernel` would be invoked from —
  /// `<sdk>/bin/dart`, with the version files the SDK ships beside them.
  String dartSdk(String name, {String? version, String? revision}) {
    var root = p.join(temp.path, name);
    File(p.join(root, 'bin', 'dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
    if (version != null) {
      File(p.join(root, 'version')).writeAsStringSync('$version\n');
    }
    if (revision != null) {
      File(p.join(root, 'revision')).writeAsStringSync('$revision\n');
    }
    return p.join(root, 'bin', 'dart');
  }

  /// A Flutter checkout at `<name>/`, whose `bin/dart` is the *wrapper* and
  /// whose Dart SDK is two directories further down.
  String flutterSdk(String name, {String? version, String? revision}) {
    var root = p.join(temp.path, name);
    File(p.join(root, 'bin', 'dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
    var dartSdk = p.join(root, 'bin', 'cache', 'dart-sdk');
    Directory(dartSdk).createSync(recursive: true);
    if (version != null) {
      File(p.join(dartSdk, 'version')).writeAsStringSync('$version\n');
    }
    if (revision != null) {
      File(p.join(dartSdk, 'revision')).writeAsStringSync('$revision\n');
    }
    return p.join(root, 'bin', 'dart');
  }

  group('reads the SDK it is handed', () {
    test('from a Dart SDK, which is <sdk>/bin/dart', () {
      var sdk = DartSdkIdentity.of(
        dartSdk('a', version: '3.13.0-282.1.beta', revision: 'cdb7217e65aa'),
      );
      expect(sdk.version, '3.13.0-282.1.beta');
      expect(sdk.revision, 'cdb7217e65aa');
    });

    test('from a Flutter checkout, whose bin/dart is a wrapper', () {
      // Both layouts are live: the integration test passes
      // `<flutter>/bin/dart` and `FlutterCache` points at
      // `<flutter>/bin/cache/dart-sdk/bin/dart`. A reader that knew only one
      // would silently fall back to the path for half its callers — and the
      // fallback splits SDKs that are the same, which is the failure this is
      // named after, in reverse.
      var sdk = DartSdkIdentity.of(
        flutterSdk('f', version: '3.13.0-282.1.beta', revision: 'cdb7217e65aa'),
      );
      expect(sdk.version, '3.13.0-282.1.beta');
      expect(sdk.revision, 'cdb7217e65aa');
    });

    test('the bundled Dart SDK wins over the Flutter root beside it', () {
      // Flutter shipped a `version` file at the root of a checkout until
      // recently, and `<flutter>` is a candidate here because it is what
      // `<flutter>/bin/dart` sits two levels under. Asking the vaguer question
      // first read that file and answered with the *Flutter* version and no
      // revision at all — a coarser key than the build hash the VM checks,
      // arrived at silently, on exactly the older checkouts least likely to be
      // noticed.
      var root = p.join(temp.path, 'legacy');
      var dart = flutterSdk(
        'legacy',
        version: '3.13.0-282.1.beta',
        revision: 'cdb7217e65aa',
      );
      File(p.join(root, 'version')).writeAsStringSync('3.47.0-0.1.pre\n');

      var sdk = DartSdkIdentity.of(dart);
      expect(sdk.version, '3.13.0-282.1.beta', reason: 'the Dart SDK, not it');
      expect(sdk.revision, 'cdb7217e65aa');
    });

    test('an unreadable SDK still has an identity', () {
      var sdk = DartSdkIdentity.of(p.join(temp.path, 'nowhere', 'bin', 'dart'));
      expect(sdk.version, isNull);
      expect(sdk.revision, isNull);
      expect(sdk.key, isNotEmpty);
    });
  });

  group('DaemonLog', () {
    late File log;

    setUp(
      () => log = File(p.join(temp.path, 'daemon.log'))..writeAsStringSync(''),
    );

    void append(String text) =>
        log.writeAsStringSync(text, mode: FileMode.append);

    test("a previous run's refusal is not read as this one's", () {
      // The log is appended to across daemons. Opening at the end is what
      // stops the failure that bricked the last start from tearing down a
      // daemon that is working now, because somebody fixed it in between.
      append("Can't load Kernel binary: Invalid SDK hash.\n");
      var tail = DaemonLog(log.path);
      expect(tail.lineContaining(_rejected), isNull);

      append('a new daemon, saying nothing alarming\n');
      expect(tail.lineContaining(_rejected), isNull);
    });

    test('a line written after it opened is found, once', () {
      var tail = DaemonLog(log.path);
      append("Can't load Kernel binary: Invalid SDK hash.\n");
      expect(
        tail.lineContaining(_rejected),
        "Can't load Kernel binary: Invalid SDK hash.",
      );
      // The poll loop throws on the first match and never asks again, so a
      // second report is harmless there — and load-bearing nowhere, which is
      // what this pins.
      expect(tail.lineContaining(_rejected), isNull);
    });

    test('consumed bytes are not read a second time', () {
      // The reason this is a cursor. At 25ms over a 30s deadline this is asked
      // up to 1200 times, and re-reading everything written so far on each one
      // is quadratic in how much the daemon logs while starting.
      var tail = DaemonLog(log.path);
      append('noise\n' * 500);
      expect(tail.lineContaining(_rejected), isNull);
      expect(tail.position, log.lengthSync(), reason: 'all of it consumed');

      // Nothing behind the cursor is re-examined: a match planted in the bytes
      // already consumed cannot be found by rewriting history.
      log.writeAsStringSync("Can't load Kernel binary: gone by\n");
      expect(tail.lineContaining(_rejected), isNull);
    });

    test('a line split across two reads is found when it completes', () {
      // The daemon is writing while this reads, so a read can land mid-line.
      // Consuming it would lose the match; the fragment is held instead.
      var tail = DaemonLog(log.path);
      append("Can't load Kern");
      expect(tail.lineContaining(_rejected), isNull);

      append('el binary: Invalid SDK hash.\n');
      expect(
        tail.lineContaining(_rejected),
        "Can't load Kernel binary: Invalid SDK hash.",
      );
    });

    test('a final line with no newline is still heard', () {
      // A VM that dies mid-write still wrote the thing worth reading.
      var tail = DaemonLog(log.path);
      append("Can't load Kernel binary: Invalid SDK hash.");
      expect(tail.lineContaining(_rejected), contains('Invalid SDK hash'));
    });

    test('the cursor advances in bytes, not characters', () {
      // `setPosition` takes a byte offset, and a daemon logs em dashes and
      // ellipses like anything else. Advancing by string length instead leaves
      // the cursor short by two bytes per such character, compounding on every
      // read.
      //
      // Asserted on the position rather than on a match, because no assertion
      // about matching can catch it: the drift is always *backwards*, so the
      // re-read text still contains the line and every match still succeeds.
      // Only the cost changes — which is the whole reason for this class.
      var tail = DaemonLog(log.path);
      append('compiling … a demo — with punctuation\n' * 20);
      expect(tail.lineContaining(_rejected), isNull);
      expect(tail.position, log.lengthSync());
    });

    test('a log that does not exist yet is not an error', () {
      var tail = DaemonLog(p.join(temp.path, 'absent.log'));
      expect(tail.lineContaining(_rejected), isNull);
    });
  });

  group('key', () {
    test('two Flutter versions do not share a snapshot', () {
      // The reported bug, as one assertion. These two are the betas that took
      // turns: one compiles, the other cannot load what it compiled.
      var older = DartSdkIdentity.of(
        dartSdk('older', version: '3.13.0-282.1.beta', revision: 'aaaaaaaa1'),
      );
      var newer = DartSdkIdentity.of(
        dartSdk('newer', version: '3.13.0-300.4.beta', revision: 'bbbbbbbb2'),
      );
      expect(older.key, isNot(newer.key));
      expect(
        daemonSnapshotPath('/install/app', older),
        isNot(daemonSnapshotPath('/install/app', newer)),
      );
    });

    test('the same SDK checked out twice shares one snapshot', () {
      // Keyed on the SDK rather than on its path, because a kernel is loadable
      // by any build that produced it. Splitting per path would be safe and
      // would also compile the same 3.2s of bytes once per checkout.
      var here = DartSdkIdentity.of(
        dartSdk('here', version: '3.13.0-282.1.beta', revision: 'cdb7217e65aa'),
      );
      var there = DartSdkIdentity.of(
        dartSdk(
          'there',
          version: '3.13.0-282.1.beta',
          revision: 'cdb7217e65aa',
        ),
      );
      expect(here.dartExecutable, isNot(there.dartExecutable));
      expect(here.key, there.key);
      expect(
        daemonSnapshotPath('/install/app', here),
        daemonSnapshotPath('/install/app', there),
      );
    });

    test('one version, two builds, two snapshots', () {
      // A version string is not unique — `.dev` builds and local engines share
      // one — and it is the build whose hash the VM checks.
      var first = DartSdkIdentity.of(
        dartSdk('first', version: '3.13.0-282.0.dev', revision: 'aaaaaaaa1'),
      );
      var second = DartSdkIdentity.of(
        dartSdk('second', version: '3.13.0-282.0.dev', revision: 'bbbbbbbb2'),
      );
      expect(first.key, isNot(second.key));
    });

    test('an unreadable SDK splits per path rather than pooling', () {
      // Over-compiling, which costs 3.2s once. Under-compiling is what hands a
      // VM somebody else's kernel, so the fallback leans this way on purpose.
      var a = DartSdkIdentity.of(p.join(temp.path, 'a', 'bin', 'dart'));
      var b = DartSdkIdentity.of(p.join(temp.path, 'b', 'bin', 'dart'));
      expect(a.key, isNot(b.key));
    });

    test('a version that reads like a path is not a path', () {
      // The two halves of the key are hashed from differently prefixed strings,
      // so a version string that happens to look like an executable cannot
      // collide with the fallback for an executable of that name.
      var elsewhere = p.join(temp.path, 'y', 'bin', 'dart');
      var versioned = DartSdkIdentity.of(dartSdk('x', version: elsewhere));
      var absent = DartSdkIdentity.of(elsewhere);
      expect(absent.version, isNull, reason: 'the fallback case');
      expect(versioned.key, isNot(absent.key));
    });
  });

  group('description', () {
    test('names the version and the short revision', () {
      // What the failure message is for: a hash cannot say which Flutter to
      // blame, and the project that has to move is usually the other one.
      var sdk = DartSdkIdentity.of(
        dartSdk(
          'a',
          version: '3.13.0-282.1.beta',
          revision: 'cdb7217e65aaee33',
        ),
      );
      expect(sdk.description, contains('3.13.0-282.1.beta'));
      expect(sdk.description, contains('cdb7217e'));
      expect(sdk.description, contains(sdk.dartExecutable));
    });

    test('falls back to the executable when there is no version to name', () {
      var path = p.join(temp.path, 'nowhere', 'bin', 'dart');
      expect(DartSdkIdentity.of(path).description, path);
    });
  });

  test('the snapshot and its depfile share the SDK directory', () {
    // The key is a directory rather than part of the filename so these cannot
    // come from different compiles. The depfile decides the daemon's revision,
    // and one written by somebody else's compile is a wrong answer to a
    // question asked on every connect.
    var sdk = DartSdkIdentity.of(
      dartSdk('a', version: '3.13.0-282.1.beta', revision: 'cdb7217e65aa'),
    );
    var snapshot = daemonSnapshotPath('/install/app', sdk);
    expect(p.basename(p.dirname(snapshot)), sdk.key);
    expect(p.isWithin('/install/app', snapshot), isTrue);
  });
}
