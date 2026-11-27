import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/previews/catalog_session.dart';
import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/daemon_address.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:path/path.dart' as p;

/// What a session disposed *while starting* leaves behind.
///
/// [CatalogSession.dispose] closes what the fields hold — and during
/// `start()`'s first await the fields hold nothing. The client that the
/// connect then produces belongs to nobody, and a leaked one is not idle
/// litter: the daemon's reaper only arms when its last session leaves, so one
/// leaked client keeps a resident compiler alive for the GUI's lifetime. The
/// window is realistic — the connect spans the cold compile, which is exactly
/// when a config reload disposes and rebuilds the plugin graph.
///
/// Driven through [CatalogSession.connectToDaemon], the injection point that
/// exists for this: the production connect compiles a snapshot and spawns a
/// process, and no test can hold its window open on purpose.
void main() {
  test(
    'disposed during the connect, the client it produced is closed',
    () async {
      var root = Directory.systemTemp.createTempSync('fw-session-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"configVersion": 2, "packages": []}');

      // The same fake-daemon arrangement as `daemon_client_test.dart`: a real
      // socket at the address a real client derives, saying only what the
      // handshake needs said.
      var address = DaemonAddress(
        DaemonConfig.forPackage(
          appToolDirectory: root.path,
          packageRoot: root.path,
          flutterSdkRoot: '/flutter',
          roots: const ['demo'],
        ),
      )..ensureRunDir();
      var stale = File(address.socketPath);
      if (stale.existsSync()) stale.deleteSync();
      var server = await ServerSocket.bind(
        InternetAddress(address.socketPath, type: InternetAddressType.unix),
        0,
      );
      var accepted = 0;
      var live = <Socket>[];
      var everyAccepted = <Socket>[];
      server.listen((socket) {
        accepted++;
        live.add(socket);
        everyAccepted.add(socket);
        socket.writeln(
          encodeLine(
            const DaemonReady(
              sessionId: 'session-0',
              assetsDir: '/assets',
              icuData: '/icu',
              coldCompile: Duration.zero,
              entries: [],
            ),
          ),
        );
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((_) {}, onError: (_) {}, onDone: () => live.remove(socket));
      });
      addTearDown(() async {
        if (Platform.environment['FW_DIAG_FIX'] == '1') {
          for (var socket in everyAccepted) {
            socket.destroy();
          }
        }
        await server.close();
        if (File(address.socketPath).existsSync()) {
          File(address.socketPath).deleteSync();
        }
      });

      var gate = Completer<void>();
      var session = CatalogSession(
        appPackageRoot: root.path,
        flutterSdkRoot: '/flutter',
        projectRoot: root.path,
        connectToDaemon:
            ({
              required dartExecutable,
              required config,
              onLog,
              onProgress,
            }) async {
              await gate.future;
              return CompilerDaemonClient.attach(
                address: address,
                onLog: onLog,
                readyTimeout: const Duration(seconds: 5),
              );
            },
      );

      var started = session.start();
      // The bug window: dispose runs while start() is inside the connect, so it
      // closes a null and the connect's result arrives owner-less.
      session.dispose();
      gate.complete();
      await started;

      var deadline = DateTime.now().add(const Duration(seconds: 5));
      while (live.isNotEmpty || accepted == 0) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(accepted, 1, reason: 'the connect did complete after dispose');
      expect(
        live,
        isEmpty,
        reason:
            'and the client it produced was closed rather than left holding '
            "the daemon's idle reaper open",
      );
    },
  );
}
