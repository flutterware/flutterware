import 'package:flutterware_app/src/previews/daemon_phase.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:test/test.dart';

/// What the daemon has to survive reading, and what a client has to survive
/// being told.
///
/// The daemon is a **shared** process: one panel, one `fw` command and one agent
/// lean on the same compiler. So a line it cannot read is not a local problem —
/// decoding used to throw out of a `listen` callback, which is an unhandled
/// async error, which kills the isolate and every other client's warm state with
/// it. These tests pin the two halves of that: decoding an unknown message is
/// *fallible* (so the daemon's `catch` is the right catch), and the fallible path
/// is *reachable* from an ordinary JSON line (so it is not theoretical).
///
/// The survival of the process itself needs a real one; that check lives in
/// `integration_test/compiler_daemon_test.dart`, which pokes a running daemon
/// from a raw socket.
void main() {
  group('reading a request', () {
    test('an unknown type is a FormatException, not a crash-shaped null', () {
      // A newer client, or a stray line. It must be an exception the daemon can
      // name — a decoder that returned null here would push the failure into
      // whatever used the result.
      expect(
        () => DaemonRequest.decode({'type': 'a-request-from-the-future'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('a-request-from-the-future'),
          ),
        ),
      );
    });

    test('a line with no type at all fails the same way', () {
      expect(
        () => DaemonRequest.decode({'no': 'type'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('tryDecodeLine hands any JSON object straight to the decoder', () {
      // This is why the above is reachable rather than theoretical: the only
      // thing filtered out before decoding is a line that is not a JSON object.
      expect(tryDecodeLine('{"type":"nonsense"}'), {'type': 'nonsense'});
      expect(tryDecodeLine('not json'), isNull);
      expect(tryDecodeLine('[1,2,3]'), isNull);
      expect(tryDecodeLine('   '), isNull);
    });

    test('every declared request round-trips', () {
      for (var request in <DaemonRequest>[
        const SelectRequest(7, 'demo/a.dart#a', full: true, ifChanged: true),
        const RefreshRequest(),
        const StopDaemonRequest(),
      ]) {
        var line = encodeLine(request);
        var decoded = DaemonRequest.decode(tryDecodeLine(line)!);
        expect(decoded.runtimeType, request.runtimeType, reason: line);
        if (decoded is SelectRequest && request is SelectRequest) {
          expect(decoded.requestId, request.requestId);
          expect(decoded.id, request.id);
          expect(decoded.full, isTrue);
          expect(decoded.ifChanged, isTrue);
        }
      }
    });
  });

  group('reading a response', () {
    test('an unknown type is a FormatException', () {
      expect(
        () => DaemonResponse.decode({'type': 'invented'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a request id survives the wire', () {
      // The client matches a reply on this id and nothing else, because the
      // daemon answers other clients' selects onto streams of the same shape.
      var line = encodeLine(
        const DaemonCompiled(
          requestId: 42,
          id: 'demo/a.dart#a',
          compile: Duration(milliseconds: 1500),
          newSourceCount: 3,
        ),
      );
      var decoded =
          DaemonResponse.decode(tryDecodeLine(line)!) as DaemonCompiled;
      expect(decoded.requestId, 42);
      expect(decoded.compile, const Duration(milliseconds: 1500));
      expect(decoded.ok, isFalse, reason: 'no dill, so nothing to load');
    });

    test('a phase survives the wire, started and finished', () {
      // The message a panel narrates a cold start from. It arrives *before*
      // the handshake, so a client that could not read it would show nothing
      // for the whole of the wait it describes.
      for (var progress in [
        const DaemonProgress(phase: 'cold compile', done: false),
        const DaemonProgress(
          phase: 'cold compile',
          done: true,
          elapsedMs: 14830,
        ),
      ]) {
        var decoded = DaemonResponse.decode(
          tryDecodeLine(encodeLine(progress))!,
        ) as DaemonProgress;
        expect(decoded.phase, 'cold compile');
        expect(decoded.done, progress.done);
        expect(decoded.elapsedMs, progress.elapsedMs);
      }
    });

    test('what a start began from survives the wire', () {
      // The two facts that separate two identical-looking slow starts: one
      // found no shared kernel, and one found a kernel built for a program
      // reaching a fraction of what this one does.
      var line = encodeLine(
        const DaemonReady(
          sessionId: 's',
          assetsDir: 'assets',
          icuData: 'icu',
          coldCompile: Duration(seconds: 15),
          entries: [],
          timings: {'cold compile': 14830},
          seed: SeedReport(packages: 20, path: '/seeds/abc.dill'),
          warmStart: true,
        ),
      );
      var decoded = DaemonResponse.decode(tryDecodeLine(line)!) as DaemonReady;
      expect(decoded.seed?.packages, 20);
      expect(decoded.seed?.path, '/seeds/abc.dill');
      expect(decoded.warmStart, isTrue);
      expect(decoded.timings['cold compile'], 14830);
    });

    test('a start with no seed says so rather than omitting the fact', () {
      var decoded = DaemonResponse.decode(
        tryDecodeLine(
          encodeLine(
            const DaemonReady(
              sessionId: 's',
              assetsDir: 'assets',
              icuData: 'icu',
              coldCompile: Duration.zero,
              entries: [],
            ),
          ),
        )!,
      ) as DaemonReady;
      expect(decoded.seed, isNull);
      expect(decoded.warmStart, isFalse);
    });

    test('an asset change names the shaders it recompiled', () {
      // A live guest holds a program per key until it is told to read that
      // key again, so the keys are the whole of what it needs to hear.
      var sent = AssetsChanged(
        fontsChanged: false,
        shaders: ['shaders/glow.frag'],
      );
      var back = DaemonResponse.decode(
        tryDecodeLine(encodeLine(sent))!,
      ) as AssetsChanged;
      expect(back.shaders, ['shaders/glow.frag']);
      expect(back.fontsChanged, isFalse);
    });

    test('an asset change from an older daemon names none', () {
      // The JSON a daemon from before shaders were bundled sends.
      var back = DaemonResponse.decode(
        tryDecodeLine('{"type":"assets-changed","fontsChanged":true}')!,
      ) as AssetsChanged;
      expect(back.shaders, isEmpty);
      expect(back.fontsChanged, isTrue);
    });

    test('an unreadable shader list decodes to the keys it can read', () {
      for (var (shaders, expected) in [
        ('"shaders/glow.frag"', <String>[]),
        ('null', <String>[]),
        ('{"a":1}', <String>[]),
        ('["shaders/glow.frag", 3, null]', ['shaders/glow.frag']),
      ]) {
        var back = DaemonResponse.decode(
          tryDecodeLine(
            '{"type":"assets-changed","fontsChanged":false,'
            '"shaders":$shaders}',
          )!,
        ) as AssetsChanged;
        expect(back.shaders, expected, reason: shaders);
      }
    });
  });

  group('reading a phase back into words', () {
    test('the ones the daemon actually reports', () {
      expect(daemonPhaseLabel('cold compile'), 'Compiling the previews');
      expect(daemonPhaseLabel('asset bundle'), 'Building the asset bundle');
      expect(
        daemonPhaseLabel('rebuild after quarantine'),
        daemonPhaseLabel('rebuild after seeding'),
        reason: 'what sent it back is not a distinction anybody waiting uses',
      );
    });

    test('the one whose key carries a number keeps the number', () {
      // `source baseline (649 files)` is the only phase the daemon files under
      // a key it computes, and the count is the interesting half of it.
      expect(
        daemonPhaseLabel('source baseline (649 files)'),
        'Recording 649 source files to watch',
      );
      expect(
        daemonPhaseLabel('source baseline'),
        'Recording the source files to watch',
      );
    });

    test('a phase from a newer daemon survives the trip', () {
      // A daemon newer than the client is the ordinary case here — one is a
      // spawned process and the other is the GUI that spawned it. Its own word
      // for what it is doing is a worse sentence than the ones above and a much
      // better one than silence.
      expect(
        daemonPhaseLabel('linking the widget graph'),
        'Linking the widget graph',
      );
      expect(daemonPhaseLabel(''), '');
    });
  });
}
