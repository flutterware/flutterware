/// The rendezvous vocabulary: how a tool on this machine *finds* an inspected
/// Dart server — the run dir, the gates, the `srv-*.json` handles.
///
/// The wire half lives in `frames.dart` and is re-exported here, so importing
/// this file still gets the whole protocol. The two are separate files because
/// only this one needs `dart:io`: an inspector running inside a Flutter app on
/// a phone has the frames and no filesystem to publish a handle into.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'frames.dart';

export 'frames.dart';

/// `~/.flutterware/run` if it exists, else null — **never created here**.
///
/// Its absence is one of the inspector's gates: a machine that never ran
/// flutterware has no run dir, and a server there stays inert even under
/// `dart run`. Creating it (as the GUI's `flutterwareRunDir()` does) would
/// defeat that.
String? existingRunDir() {
  var home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) return null;
  var dir = p.join(home, '.flutterware', 'run');
  return Directory(dir).existsSync() ? dir : null;
}

/// Whether the inspector may come alive, from the three gates the spec names:
/// release builds are inert, machines without a run dir are inert, and
/// `FW_SERVER_INSPECT` overrides in both directions.
bool serverInspectionEnabled({
  required bool product,
  required String? envOverride,
  required bool runDirExists,
}) {
  if (envOverride == '0') return false;
  if (envOverride == '1') return true;
  if (product) return false;
  return runDirExists;
}

/// 8 hex of sha1 — a filename uniquifier only. Attachers match handles by
/// [ServerHandle.projectRoot] containment, never by parsing this back.
String projectRootHash(String projectRoot) =>
    sha1.convert(utf8.encode(projectRoot)).toString().substring(0, 8);

/// A server name made safe for a socket filename: the allowed alphabet, and
/// short enough that the path stays under the 104-byte `sun_path` cap.
String sanitizeServerName(String name) {
  var safe = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-');
  if (safe.isEmpty) safe = 'server';
  return safe.length <= 24 ? safe : safe.substring(0, 24);
}

String serverHandleBaseName({
  required String projectRoot,
  required String name,
  required int pid,
}) => 'srv-${projectRootHash(projectRoot)}-${sanitizeServerName(name)}-$pid';

/// The published announcement: one JSON file per live server process.
///
/// [baseUrl] and [environment] are mirrored in from the server's
/// self-description (`FlutterwareServer.info`) so scan-only readers —
/// `fw status`, the GUI rail — can say where a server listens without
/// opening a socket. The mirror is a convenience copy: the `info` channel
/// stays the source of truth, and a handle written before the server
/// described itself simply lacks them.
class ServerHandle {
  ServerHandle({
    required this.projectRoot,
    required this.name,
    required this.socketPath,
    required this.pid,
    required this.startedAt,
    this.baseUrl,
    this.environment,
    this.protocol = protocolVersion,
    this.handlePath,
  });

  final String projectRoot;
  final String name;
  final String socketPath;
  final int pid;
  final DateTime startedAt;
  final String? baseUrl;
  final String? environment;
  final int protocol;

  /// Where this handle was read from — null on the publishing side.
  final String? handlePath;

  Map<String, Object?> toJson() => {
    'projectRoot': projectRoot,
    'name': name,
    'socketPath': socketPath,
    'pid': pid,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (baseUrl != null) 'baseUrl': baseUrl,
    if (environment != null) 'environment': environment,
    'protocol': protocol,
  };

  static ServerHandle? tryRead(File file) {
    try {
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return null;
      var map = json.cast<String, Object?>();
      var baseUrl = map['baseUrl'];
      var environment = map['environment'];
      return ServerHandle(
        projectRoot: map['projectRoot']! as String,
        name: map['name']! as String,
        socketPath: map['socketPath']! as String,
        pid: map['pid']! as int,
        startedAt: DateTime.parse(map['startedAt']! as String),
        // Tolerant, unlike the required fields: the mirror is decoration, and
        // a wrong-typed one must not unread an otherwise live handle.
        baseUrl: baseUrl is String ? baseUrl : null,
        environment: environment is String ? environment : null,
        protocol: map['protocol'] as int? ?? protocolVersion,
        handlePath: file.path,
      );
    } on Object {
      // Torn write, stale schema, deleted meanwhile — a handle that cannot be
      // read is a handle that does not exist.
      return null;
    }
  }

  @override
  String toString() => 'ServerHandle($name, pid $pid, $projectRoot)';
}

/// The `srv-*.json` handles in [runDir], newest first, optionally filtered to
/// servers whose project root sits inside [underRoot].
///
/// Containment rather than equality, deliberately: a server in a monorepo runs
/// from `repo/server_pkg/` and must still appear under the `repo` worktree.
/// Reads files and nothing else — liveness is decided by connecting, and this
/// is called from places (`report`, `computeAll`) that must not open sockets.
List<ServerHandle> scanServerHandles(String runDir, {String? underRoot}) {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(runDir).listSync();
  } on FileSystemException {
    return [];
  }
  var handles = <ServerHandle>[];
  for (var entity in entries) {
    var name = p.basename(entity.path);
    if (entity is! File ||
        !name.startsWith('srv-') ||
        !name.endsWith('.json')) {
      continue;
    }
    var handle = ServerHandle.tryRead(entity);
    if (handle == null) continue;
    if (underRoot != null &&
        !p.equals(underRoot, handle.projectRoot) &&
        !p.isWithin(underRoot, handle.projectRoot)) {
      continue;
    }
    handles.add(handle);
  }
  handles.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return handles;
}

/// Deletes a handle's files — used after a failed connect, the same
/// "on the way past" cleanup `attachToLiveSession` does.
void deleteServerHandle(ServerHandle handle) {
  for (var path in [handle.handlePath, handle.socketPath]) {
    if (path == null) continue;
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Somebody else swept it first; that was the goal.
    }
  }
}
