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
class WorldScriptProcess {
  WorldScriptProcess._(this.process, this._socket, this.messages);

  final Process process;
  final Socket _socket;

  /// Everything the script declares, in order, from `hello` to `closed`.
  final Stream<Map<String, Object?>> messages;

  static var _count = 0;

  /// Runs [file] in the package at [packageRoot] with [dart] — `dart run`, so
  /// it resolves and runs its build hooks as any script of that package does,
  /// through [compiler] — and opens the world with [knobs]. [onOutput] gets
  /// what it prints: its server's log, usually.
  static Future<WorldScriptProcess> start({
    required String dart,
    required String packageRoot,
    required String file,
    required Map<String, Object?> knobs,
    WorldCompiler? compiler,
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
        ['run', ...?compiler?.runArguments, file],
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
          .map(withoutToolNoise)
          .where((line) => line != null)
          .cast<String>()
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
    var script = WorldScriptProcess._(process, socket, messages);
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

/// [line] without what `dart run` says about itself, or null when that was
/// all of it. `Running build hooks...` ends in no newline, so it arrives glued
/// to the start of the script's own first line, sometimes twice.
String? withoutToolNoise(String line) {
  var own = line.replaceFirst(_toolNoise, '');
  return own.isEmpty && own.length != line.length ? null : own;
}

final _toolNoise = RegExp(r'^(Running build hooks\.\.\.)+');

/// The resident compiler a world script is compiled by — `dart run
/// --resident` — so an opening after the first, and every restart, starts
/// the script in a fraction of a second rather than compiling it whole: a
/// script that hosts a large server spends most of an opening there.
///
/// One per `OpenWorld`, shut down when it closes: the compiler keeps its
/// kernels on disk, keyed on the script's path, so the next process's
/// compiler starts from them — measured on a heavy script, 0.76 s against 6 s
/// for a plain `dart run` — and nothing is left running after the world.
class WorldCompiler {
  WorldCompiler(this.dart)
    : infoFile = p.join(
        flutterwareRunDir(),
        'world-compiler-$pid-${_count++}.info',
      );

  /// The `dart` it belongs to: a compiler serves the SDK that started it.
  final String dart;

  /// How `dart` finds this compiler; it starts one if the file names none.
  final String infoFile;

  static var _count = 0;

  List<String> get runArguments => [
    '--resident',
    '--quiet',
    '--resident-compiler-info-file=$infoFile',
  ];

  /// Stops the compiler, if one started.
  Future<void> shutdown() => _shutdown(dart, infoFile);

  /// Stops the compilers of processes that ended without closing their world
  /// — killed, or crashed. Housekeeping: nothing fails over it.
  static Future<void> sweep(String dart, {String? directory}) async {
    try {
      for (var entity in Directory(
        directory ?? flutterwareRunDir(),
      ).listSync()) {
        var match = _infoName.firstMatch(p.basename(entity.path));
        if (match == null || isProcessAlive(int.parse(match[1]!))) continue;
        await _shutdown(dart, entity.path);
      }
    } on Object {
      // A run directory that is not there has nothing to sweep.
    }
  }

  static final _infoName = RegExp(r'^world-compiler-(\d+)-\d+\.info$');

  static Future<void> _shutdown(String dart, String infoFile) async {
    if (!File(infoFile).existsSync()) return;
    try {
      await Process.run(dart, [
        'compilation-server',
        'shutdown',
        '--resident-compiler-info-file=$infoFile',
      ]);
    } on Object {
      // Gone already, or never started: the file is all that is left.
    }
    try {
      File(infoFile).deleteSync();
    } on FileSystemException {
      // `shutdown` removed it.
    }
  }
}
