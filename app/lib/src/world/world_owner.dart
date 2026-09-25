import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';

/// Where the process that owns a worktree's world can be asked about it.
///
/// **Whoever opens a world owns it** — its script, its compiler and its
/// people's guests live in that process — but everyone else on the machine
/// may still need it: an agent that opened it with `fw … --hold` and now
/// wants its status, a studio showing a world the MCP server opened. So the
/// owner leaves this file, one per worktree, as a world is one per worktree,
/// and answers on its [socket]; another process forwards `status`, `invoke`,
/// `restart` and `close` there instead of refusing them.
///
/// The world's own file, not its people's Run handles: a world whose people
/// have no app has no Run handle at all.
class WorldHandle {
  const WorldHandle({
    required this.worktree,
    required this.world,
    required this.name,
    required this.pid,
    required this.socket,
  });

  factory WorldHandle.fromJson(Map<String, Object?> json) => WorldHandle(
    worktree: json['worktree']! as String,
    world: json['world']! as String,
    name: json['name']! as String,
    pid: json['pid']! as int,
    socket: json['socket']! as String,
  );

  final String worktree;

  /// Its id, what `worlds open` took.
  final String world;
  final String name;

  /// The owner's.
  final int pid;
  final String socket;

  Map<String, Object?> toJson() => {
    'worktree': worktree,
    'world': world,
    'name': name,
    'pid': pid,
    'socket': socket,
  };

  /// Where [worktree]'s handle is, whether or not a world is open there.
  static String pathFor(String worktree, {String? directory}) => p.join(
    directory ?? flutterwareRunDir(),
    'world-${sha1.convert(utf8.encode(worktree)).toString().substring(0, 16)}'
    '.json',
  );

  /// [worktree]'s world, if a live process owns one. A handle whose owner
  /// died without closing is deleted on the way.
  static WorldHandle? read(String worktree, {String? directory}) {
    var file = File(pathFor(worktree, directory: directory));
    WorldHandle handle;
    try {
      handle = WorldHandle.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast(),
      );
    } on Object {
      // Absent, or half written: nobody to ask.
      return null;
    }
    if (handle.worktree != worktree || !isProcessAlive(handle.pid)) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Somebody else swept it.
      }
      return null;
    }
    return handle;
  }

  void write({String? directory}) {
    var file = File(pathFor(worktree, directory: directory))
      ..parent.createSync(recursive: true);
    var partial = File('${file.path}.$pid.tmp')
      ..writeAsStringSync(jsonEncode(toJson()));
    partial.renameSync(file.path);
  }

  /// Removes the file, if it is still this owner's.
  void delete({String? directory}) {
    var file = File(pathFor(worktree, directory: directory));
    if (read(worktree, directory: directory)?.pid != pid) return;
    try {
      file.deleteSync();
    } on FileSystemException {
      // Gone already.
    }
  }
}

/// What a world's owner does with a request from another process: runs
/// [action] with [arguments] and answers its result's JSON.
typedef WorldRequestHandler = Future<Map<String, Object?>> Function(
  String action,
  Map<String, Object?> arguments,
);

/// The owner's socket: one request a connection, a JSON line each way —
/// `{"action", "arguments"}` in, `{"result"}` or `{"refusal"}` out.
class WorldOwnerServer {
  WorldOwnerServer._(this.socket, this._server);

  final String socket;
  final ServerSocket _server;

  static var _count = 0;

  /// Serves [handle] until [close]. A request it refuses — or fails — is
  /// answered in words, as a refusal the asking process says as its own.
  static Future<WorldOwnerServer> start(WorldRequestHandler handle) async {
    var path = checkSocketPath(
      p.join(flutterwareRunDir(), 'world-owner-$pid-${_count++}.sock'),
    );
    if (File(path).existsSync()) File(path).deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    server.listen((connection) async {
      Map<String, Object?> answer;
      try {
        var line = await utf8.decoder
            .bind(connection)
            .transform(const LineSplitter())
            .first;
        var request = (jsonDecode(line) as Map).cast<String, Object?>();
        answer = {
          'result': await handle(
            request['action']! as String,
            (request['arguments'] as Map? ?? const {}).cast(),
          ),
        };
      } on Object catch (error) {
        answer = {'refusal': '$error'};
      }
      try {
        connection.writeln(jsonEncode(answer));
        await connection.flush();
        await connection.close();
      } on Object {
        // The asker went; nothing to tell.
      }
    });
    return WorldOwnerServer._(path, server);
  }

  Future<void> close() async {
    await _server.close();
    try {
      File(socket).deleteSync();
    } on FileSystemException {
      // Never bound, or gone.
    }
  }
}

/// Asks the owner at [socket] to run [action] and answers its result's JSON,
/// or throws [WorldOwnerRefusal] with the owner's words.
Future<Map<String, Object?>> askWorldOwner(
  String socket,
  String action, {
  Map<String, Object?> arguments = const {},
  Duration timeout = const Duration(minutes: 5),
}) async {
  Socket connection;
  try {
    connection = await Socket.connect(
      InternetAddress(socket, type: InternetAddressType.unix),
      0,
    );
  } on SocketException {
    throw WorldOwnerRefusal(
      'The process that owns this world no longer answers. It may be '
      'closing, or have ended without closing it.',
    );
  }
  connection.writeln(jsonEncode({'action': action, 'arguments': arguments}));
  await connection.flush();
  try {
    var line = await utf8.decoder
        .bind(connection)
        .transform(const LineSplitter())
        .first
        .timeout(timeout);
    var answer = (jsonDecode(line) as Map).cast<String, Object?>();
    if (answer['refusal'] case String refusal) {
      throw WorldOwnerRefusal(refusal);
    }
    return (answer['result']! as Map).cast();
  } on StateError {
    throw WorldOwnerRefusal(
      'The process that owns this world hung up before it answered.',
    );
  } finally {
    connection.destroy();
  }
}

/// The owner's answer when it would not, or could not, do what was asked.
class WorldOwnerRefusal implements Exception {
  WorldOwnerRefusal(this.message);

  final String message;

  @override
  String toString() => message;
}
