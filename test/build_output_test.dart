import 'dart:io';

import 'package:flutterware/src/build_output.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The real `dart`, which is not always the executable running the test.
///
/// Under `flutter test` `Platform.resolvedExecutable` is `flutter_tester`:
/// `--version` exits 1 with "Dart kernel file not specified", so every check
/// below that ran a process saw a failure that had nothing to do with the code
/// under test. Under `dart test` it is the real thing, which is why these
/// passed until CI began running the root package the other way.
///
/// Found by walking up for a `dart-sdk` directory, which works from both:
/// `flutter_tester` sits at `<flutter>/bin/cache/artifacts/engine/<host>/` and
/// the SDK at `<flutter>/bin/cache/dart-sdk/`. The same trick, and the same
/// reason, as `ShapeExtractor.findDartSdk`.
final _dart = () {
  var name = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    var candidate = File(p.join(directory.path, 'dart-sdk', 'bin', name));
    if (candidate.existsSync()) return candidate.path;
    var parent = directory.parent;
    // Already the Dart SDK's own `dart`, or something we cannot improve on.
    if (parent.path == directory.path) return Platform.resolvedExecutable;
    directory = parent;
  }
}();

/// The output policy, and the two things it protects.
///
/// A CI log must never receive an escape sequence, and a failed build must
/// never be reported without both the end of its log and the path to the rest.
/// Everything below is one of those two.
void main() {
  group('isInteractiveOutput', () {
    test('a real terminal that supports escapes is interactive', () {
      expect(
        isInteractiveOutput(
          hasTerminal: true,
          supportsAnsi: true,
          environment: const {},
        ),
        isTrue,
      );
    });

    test('a pipe is not, however capable the terminal claims to be', () {
      expect(
        isInteractiveOutput(
          hasTerminal: false,
          supportsAnsi: true,
          environment: const {},
        ),
        isFalse,
      );
    });

    test('CI and NO_COLOR win over a real terminal', () {
      // The case this exists for: a runner that allocates a tty. Asking
      // `hasTerminal` alone would decorate its log.
      for (var environment in const [
        {'CI': 'true'},
        {'CI': ''},
        {'NO_COLOR': '1'},
        {'TERM': 'dumb'},
      ]) {
        expect(
          isInteractiveOutput(
            hasTerminal: true,
            supportsAnsi: true,
            environment: environment,
          ),
          isFalse,
          reason: '$environment should not be interactive',
        );
      }
    });
  });

  group('narrationOwnsStderr', () {
    test('a person at a terminal watches the plan on stdout', () {
      expect(
        narrationOwnsStderr(speaksProtocol: false, interactive: true),
        isFalse,
      );
    });

    test('a protocol on stdout moves the plan off it', () {
      expect(
        narrationOwnsStderr(speaksProtocol: true, interactive: true),
        isTrue,
      );
    });

    test('anything capturing stdout gets only what it asked for', () {
      // A pipe, a redirect or a CI log — all of them arrive here as
      // `interactive: false`, and all of them are about to read a result as
      // JSON. `build the CLI… (~10s)` above it is a parse error.
      expect(
        narrationOwnsStderr(speaksProtocol: false, interactive: false),
        isTrue,
      );
    });
  });

  group('Step', () {
    test('off a terminal it says what started, and nothing else', () async {
      var out = StringBuffer();
      await Step(
        'Building the flutterware GUI',
        out: out,
        interactive: false,
        budget: const Duration(seconds: 25),
        note: 'first run only',
      ).run(() async => 0);

      expect(
        out.toString(),
        'Building the flutterware GUI… (~25s, first run only)\n',
      );
    });

    test(
      'off a terminal it emits no escape sequence, even on failure',
      () async {
        var out = StringBuffer();
        await Step(
          'Building',
          out: out,
          interactive: false,
        ).run(() async => 1, ok: (result) => result == 0);

        expect(out.toString(), isNot(contains('\x1b')));
        expect(out.toString(), isNot(contains('\r')));
      },
    );

    test(
      'on a terminal it rewrites one line and ends with the duration',
      () async {
        var out = StringBuffer();
        await Step('Building', out: out, interactive: true).run(() async => 0);

        var written = out.toString();
        expect(written, startsWith('\r\x1b[KBuilding… '));
        expect(written, contains('done in '));
        expect(written, endsWith('\n'));
        // One line, whatever the timing did to it.
        expect('\n'.allMatches(written).length, 1);
      },
    );

    test('a failed step says so rather than reporting a duration', () async {
      var out = StringBuffer();
      await Step(
        'Building',
        out: out,
        interactive: true,
      ).run(() async => 1, ok: (result) => result == 0);

      expect(out.toString(), contains('failed after '));
      expect(out.toString(), isNot(contains('done in ')));
    });

    test('a throwing body still stops the line', () async {
      var out = StringBuffer();
      await expectLater(
        Step(
          'Building',
          out: out,
          interactive: true,
        ).run(() async => throw StateError('boom')),
        throwsStateError,
      );
      // The ticker is cancelled and the line terminated, or every later write
      // lands on top of this one.
      expect(out.toString(), contains('failed after '));
      expect(out.toString(), endsWith('\n'));
    });
  });

  group('runLogged', () {
    late Directory directory;
    late File log;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('fw_log');
      // Nested, because a build log has to be writable before anything has
      // created the directory it lives beside.
      log = File('${directory.path}/nested/build.log');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    test('captures both streams instead of the terminal', () async {
      var result = await runLogged(_dart, ['--version'], log: log);

      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      // Dart prints its version banner on stderr; the point is that it landed
      // in the file rather than on our stdout.
      expect(log.readAsStringSync(), contains('Dart SDK version'));
    });

    test('records the command, so a two-command log is readable', () async {
      await runLogged(_dart, ['--version'], log: log);
      expect(log.readAsStringSync(), startsWith(r'$ '));
    });

    test('appending keeps the first command in the same file', () async {
      await runLogged(_dart, ['--version'], log: log);
      await runLogged(_dart, ['--help'], log: log, append: true);

      var written = log.readAsStringSync();
      expect(r'$ '.allMatches(written).length, greaterThanOrEqualTo(2));
      expect(written, contains('--version'));
      expect(written, contains('--help'));
    });

    test('a failure carries its exit code and the end of the log', () async {
      var result = await runLogged(_dart, [
        'run',
        'no_such_file_anywhere.dart',
      ], log: log);

      expect(result.ok, isFalse);
      expect(result.tail(), isNotEmpty);
      // Blank lines are not evidence.
      expect(result.tail().any((line) => line.trim().isEmpty), isFalse);
    });

    test('the tail is the end, not the beginning', () async {
      log.parent.createSync(recursive: true);
      log.writeAsStringSync(
        [for (var i = 0; i < 100; i++) 'line $i'].join('\n'),
      );

      var tail = ProcessLog(1, log).tail(3);
      expect(tail, ['line 97', 'line 98', 'line 99']);
    });
  });

  group('under -v, nothing is captured', () {
    test('a log-less result has no tail to quote', () {
      expect(ProcessLog(1, null).tail(), isEmpty);
    });

    test('describeFailure says only what happened', () {
      // The output the tail would quote already went past on its way to the
      // screen, and there is no file to point at.
      var err = StringBuffer();
      describeFailure(err, 'the GUI build failed.', ProcessLog(1, null));

      expect(err.toString(), 'fw: the GUI build failed.\n');
    });

    test(
      'the child really gets the terminal, and no file is written',
      () async {
        var directory = Directory.systemTemp.createTempSync('fw_log');
        addTearDown(() => directory.deleteSync(recursive: true));
        var log = File('${directory.path}/build.log');

        var result = await runLogged(
          _dart,
          ['--version'],
          log: log,
          verbose: true,
        );

        expect(result.ok, isTrue);
        expect(result.file, isNull);
        // Not written, so a later failure cannot quote a stale one by mistake.
        expect(log.existsSync(), isFalse);
      },
    );
  });

  group('a failure whose message contains no fix gets one', () {
    test('stale hook kernels name the cache and the command', () {
      var directory = Directory.systemTemp.createTempSync('fw_log');
      addTearDown(() => directory.deleteSync(recursive: true));
      // What a consumer met after an SDK bump: the surfaced error names
      // neither the cache nor the bump that invalidated it.
      var log = File('${directory.path}/build.log')
        ..writeAsStringSync(
          "Can't load Kernel binary: Invalid kernel binary format version "
          '(expected 139, found 138).\n'
          '  Building assets for package:sqlite3 failed.\n'
          'Error: Running build hooks failed.\n',
        );

      var err = StringBuffer();
      describeFailure(
        err,
        'could not resolve the flutterware app.',
        ProcessLog(1, log),
      );

      expect(err.toString(), contains('rm -rf .dart_tool/hooks_runner'));
      expect(err.toString(), contains('a different Dart SDK'));
    });

    test('the cause is recognised from above the tail window', () {
      var directory = Directory.systemTemp.createTempSync('fw_log');
      addTearDown(() => directory.deleteSync(recursive: true));
      // Where the consumer actually met it: a build tool reports the cause and
      // then keeps going, so by the time it gives up the explanation is fifty
      // lines back. The tail quotes the giving up; only the whole log holds
      // the reason.
      var kernel =
          "Can't load Kernel binary: Invalid kernel binary format version "
          '(expected 139, found 138).';
      var log = File('${directory.path}/build.log')
        ..writeAsStringSync(
          [
            kernel,
            for (var i = 0; i < 50; i++) 'building step $i',
            'Bad state: Generating AOT kernel dill failed!',
          ].join('\n'),
        );

      var err = StringBuffer();
      describeFailure(err, 'could not build the CLI.', ProcessLog(1, log));

      expect(err.toString(), contains('rm -rf .dart_tool/hooks_runner'));
      // Still only the tail is quoted — the whole log is matched against, not
      // printed.
      expect(err.toString(), isNot(contains("Can't load Kernel binary")));
    });

    test('an ordinary failure is left to speak for itself', () {
      expect(recogniseFailure(const ['Error: it broke']), isNull);
    });
  });

  test('describeFailure gives both the evidence and where the rest is', () {
    var directory = Directory.systemTemp.createTempSync('fw_log');
    addTearDown(() => directory.deleteSync(recursive: true));
    var log = File('${directory.path}/build.log')
      ..writeAsStringSync('warming up\nError: it broke\n');

    var err = StringBuffer();
    describeFailure(err, 'the GUI build failed.', ProcessLog(1, log));

    expect(err.toString(), contains('fw: the GUI build failed.'));
    expect(err.toString(), contains('Error: it broke'));
    expect(err.toString(), contains(log.path));
  });
}
