import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/world/protocol.dart';
import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';

/// A world script while it runs, from its owner's side: the process, and the
/// socket it declares its world on (`package:flutterware/src/world/
/// protocol.dart` has the wire).
///
/// One per opening. A restart closes this one and starts another, rather than
/// asking the script to run its body again: a script whose file changed since
/// it opened would otherwise restart as the old code, and nothing a script
/// kept in a global survives into the next opening by accident.
class WorldScript {
  WorldScript._(this.process, this._socket, this.messages);

  final Process process;
  final Socket _socket;

  /// Everything the script declares, in order, from `hello` to `closed`.
  final Stream<Map<String, Object?>> messages;

  static var _count = 0;

  /// Runs [file] in the package at [packageRoot] with [dart] — `dart run`, so
  /// it resolves as any script of that package does — and opens the world
  /// with [knobs]. [onOutput] gets what it prints: its server's log, usually.
  static Future<WorldScript> start({
    required String dart,
    required String packageRoot,
    required String file,
    required Map<String, Object?> knobs,
    void Function(String line)? onOutput,
    Duration connectTimeout = const Duration(minutes: 2),
  }) async {
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'world-$pid-${_count++}.sock'),
    );
    if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    Process process;
    try {
      process = await Process.start(
        dart,
        ['run', file],
        workingDirectory: packageRoot,
        environment: {worldSocketVariable: socketPath},
      );
    } on Object {
      await server.close();
      rethrow;
    }
    for (var stream in [process.stdout, process.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onOutput ?? (_) {});
    }
    // Refused before it connects — a compile error, a missing dependency —
    // the script exits, and what it printed is the reason. Kept by the script
    // and destroyed by [close].
    // ignore: close_sinks
    Socket socket;
    try {
      socket = await Future.any([
        server.first,
        process.exitCode.then<Socket>((code) => throw WorldScriptExited(code)),
      ]).timeout(connectTimeout);
    } finally {
      await server.close();
      if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    }
    var messages = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(decodeWorldMessage)
        .asBroadcastStream();
    var script = WorldScript._(process, socket, messages);
    script.send(WorldMessage.open, {'knobs': knobs});
    return script;
  }

  void send(String type, [Map<String, Object?> fields = const {}]) {
    try {
      _socket.writeln(encodeWorldMessage(type, fields));
    } on Object {
      // The script is gone; its exit says so.
    }
  }

  /// Asks the script to close — its `onClose` callbacks run — and waits for
  /// it to go, killing it if it has not after [timeout].
  Future<void> close({Duration timeout = const Duration(seconds: 15)}) async {
    send(WorldMessage.close);
    await _socket.flush().catchError((Object _) {});
    await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    _socket.destroy();
  }
}

/// A world script that ended before it said anything.
class WorldScriptExited implements Exception {
  WorldScriptExited(this.exitCode);

  final int exitCode;

  @override
  String toString() => 'The world script exited ($exitCode) before it started.';
}
