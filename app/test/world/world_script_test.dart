import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/world/world_script.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';

void main() {
  /// A reload that the VM answers with [errors], one call each, then with
  /// `ok`; and how many times it was asked.
  (Future<String> Function(), int Function()) vm(List<RPCError> errors) {
    var calls = 0;
    return (
      () async {
        if (calls++ < errors.length) throw errors[calls - 1];
        return 'ok';
      },
      () => calls,
    );
  }

  var reloading = RPCError('reloadSources', 108);
  // What a project's own reloader, compiling at the same moment, left the
  // VM's compiler saying.
  var tripped = RPCError.withDetails(
    'reloadSources',
    -32603,
    'Internal error',
    details: 'Bad state: No element',
  );
  // Its connection to the script's VM dropped mid-call.
  var dropped = RPCError(
    'reloadSources',
    -32000,
    'Service connection disposed',
  );
  var compile = RPCError.withDetails(
    'reloadSources',
    -32603,
    'Internal error',
    details:
        "lib/world.dart:17:22: Error: Expected ';' after this.\n"
        "String greeting() => 'v3'",
  );

  test('goes after a reload already running, after the compiler tripping '
      "over another reload's, and after its connection dropped", () async {
    var (reload, calls) = vm([reloading, tripped, dropped, reloading]);
    expect(await reloadWhenFree(reload, pause: Duration.zero), 'ok');
    expect(calls(), 5);
  });

  test('a compile error is the source, said at once and never retried', () {
    var (reload, calls) = vm([compile]);
    expect(
      reloadWhenFree(reload, pause: Duration.zero),
      throwsA(
        isA<WorldScriptReloadFailed>()
            .having((f) => f.refused, 'refused', isFalse)
            .having((f) => f.message, 'message', contains('17:22: Error:')),
      ),
    );
    expect(calls(), 1);
  });

  test('a compiler that went down is said at once, with the way out', () {
    var (reload, calls) = vm([
      RPCError.withDetails(
        'reloadSources',
        -32603,
        'Internal error',
        details:
            'SocketException: Connection refused (OS Error: Connection '
            'refused, errno = 61), address = 127.0.0.1, port = 59858',
      ),
    ]);
    expect(
      reloadWhenFree(reload, pause: Duration.zero),
      throwsA(
        isA<WorldScriptReloadFailed>()
            .having((f) => f.refused, 'refused', isTrue)
            .having(
              (f) => f.message,
              'message',
              allOf(contains('compiler went down'), contains('Reload again')),
            ),
      ),
    );
    expect(calls(), 1);
  });

  test('a compiler that died is replaced at the same path, and one that '
      'answers is left alone', () async {
    var compiler = WorldCompiler(
      p.join(Platform.environment['FLUTTER_ROOT']!, 'bin', 'dart'),
    );
    addTearDown(compiler.shutdown);
    // What a compiler that died leaves: its file, naming a port nobody
    // listens on.
    var gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var port = gone.port;
    await gone.close();
    File(compiler.infoFile)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('address:127.0.0.1 sdkHash:0 port:$port ');

    expect(await compiler.revive(), contains('had died'));
    var info = File(compiler.infoFile).readAsStringSync();
    expect(info, isNot(contains('port:$port ')));
    expect(await compiler.revive(), isNull);
    expect(File(compiler.infoFile).readAsStringSync(), info);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('still refused once it has waited long enough, saying why', () async {
    var (reload, _) = vm(List.filled(1000, reloading));
    await expectLater(
      reloadWhenFree(
        reload,
        busyFor: const Duration(milliseconds: 20),
        pause: const Duration(milliseconds: 5),
      ),
      throwsA(
        isA<WorldScriptReloadFailed>()
            .having((f) => f.refused, 'refused', isTrue)
            .having(
              (f) => f.message,
              'message',
              allOf(contains('another reloader'), contains('(108)')),
            ),
      ),
    );
  });
}
