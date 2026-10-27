import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../utils/run_dir.dart';

/// What one running owned service announces about itself, on disk under
/// `~/.flutterware/run/`.
///
/// **The point of the file is that the process outlives the GUI.** An owned
/// service is spawned detached, so closing the window does not take the server
/// down — and without a record on disk the next session would have no way to
/// tell "nothing is running" from "something is running and I have forgotten
/// its pid". The second is the orphan: a port held by a process nothing is
/// tracking, and an `EADDRINUSE` on the next bring-up with no name attached to
/// it.
///
/// It is the same ledger property `RunHandle` gives a `flutter run`, for the
/// same three reasons: a GUI restart re-adopts rather than duplicates, two GUIs
/// on one worktree agree about what is up, and `fw` in a terminal sees what the
/// window sees.
class ServiceHandle {
  const ServiceHandle({
    required this.worktree,
    required this.service,
    required this.pid,
    required this.command,
    required this.workingDirectory,
    required this.startedAt,
    this.name,
    this.logPath,
    this.ready,
    this.readyPort,
    this.stopping = false,
    this.handlePath,
  });

  /// The worktree root this was started from. Part of the key, so two
  /// checkouts of one repository run their own copies without seeing each
  /// other's.
  final String worktree;

  /// The declared `StackService.id`.
  final String service;

  final String? name;

  /// The detached process, and the leader of its own process group — see
  /// `OwnedServiceCore.stop`, which signals the group rather than the pid.
  final int pid;

  /// What was spawned, joined. So a reader who wants to run it themselves can,
  /// and so a handle written before the declaration changed still says what is
  /// actually running.
  final String command;

  final String workingDirectory;

  /// Where its stdout and stderr went. flutterware owns this file, which is why
  /// an owned service gets a `logs` action without declaring one.
  final String? logPath;

  /// How readiness was decided when it was started, as a line to show.
  final String? ready;

  /// The port readiness watches, as it was **resolved at the start**.
  ///
  /// Recorded rather than recomputed, and that is the point of it. A port that
  /// comes from the project's own tool costs a `dart run` to ask for; a
  /// session that reopens onto a running service would otherwise have to ask
  /// again to know where to look — and would get today's answer about a
  /// process started yesterday. What is here is the number this process was
  /// actually started against.
  final int? readyPort;

  /// When flutterware spawned it. The tie-breaker for a recycled pid — see
  /// [isProcessCurrent].
  final DateTime startedAt;

  /// Someone has begun stopping it. A process that finds the pid gone
  /// afterwards knows it was stopped rather than that it exited on its own,
  /// because the stopper records that itself.
  final bool stopping;

  /// Where this was read from, or null before it is published.
  final String? handlePath;

  /// Whether the process is still there *and* still the one recorded here.
  ///
  /// Current rather than merely alive: a handle can sit on disk for a day, and
  /// a busy machine recycles pids well inside that. Believing a recycled number
  /// would have `stop` signalling a stranger's process group, which is the one
  /// mistake here that is not recoverable.
  bool get isAlive => isProcessCurrent(pid, startedAt);

  Duration get uptime => DateTime.now().difference(startedAt);

  Map<String, Object?> toJson() => {
    'worktree': worktree,
    'service': service,
    if (name != null) 'name': name,
    'pid': pid,
    'command': command,
    'workingDirectory': workingDirectory,
    if (logPath != null) 'logPath': logPath,
    if (ready != null) 'ready': ready,
    if (readyPort != null) 'readyPort': readyPort,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (stopping) 'stopping': true,
  };

  /// Writes this handle into [runDir] under its own name, and returns it
  /// knowing where it went.
  ServiceHandle publish(String runDir) {
    var path = p.join(
      runDir,
      '${serviceHandleKey(worktree, service)}-$pid.json',
    );
    Directory(runDir).createSync(recursive: true);
    File(path).writeAsStringSync(jsonEncode(toJson()));
    return _copy(handlePath: path);
  }

  /// Removes this handle from the ledger. Called when the process is gone, so
  /// nothing goes on claiming a port that is free.
  ///
  /// True when this call removed it, false when it was already gone — so of
  /// two processes noticing one exit, exactly one writes it down.
  bool delete() {
    var path = handlePath;
    if (path == null) return false;
    try {
      File(path).deleteSync();
      return true;
    } on FileSystemException {
      // Another sweeper won the race. Not ours to report.
      return false;
    }
  }

  /// Rewrites the handle with [stopping] set, before the first signal.
  ServiceHandle markStopping() {
    var marked = _copy(stopping: true);
    if (handlePath case var path?) {
      try {
        File(path).writeAsStringSync(jsonEncode(marked.toJson()));
      } on FileSystemException {
        // Gone already: nothing will misread it.
      }
    }
    return marked;
  }

  ServiceHandle _copy({String? handlePath, bool? stopping}) => ServiceHandle(
    worktree: worktree,
    service: service,
    name: name,
    pid: pid,
    command: command,
    workingDirectory: workingDirectory,
    logPath: logPath,
    ready: ready,
    readyPort: readyPort,
    startedAt: startedAt,
    stopping: stopping ?? this.stopping,
    handlePath: handlePath ?? this.handlePath,
  );

  static ServiceHandle? tryRead(File file) {
    try {
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return null;
      var map = json.cast<String, Object?>();
      return ServiceHandle(
        worktree: map['worktree']! as String,
        service: map['service']! as String,
        pid: map['pid']! as int,
        command: map['command']! as String,
        workingDirectory: map['workingDirectory']! as String,
        startedAt: DateTime.parse(map['startedAt']! as String),
        // Tolerant below this line: a wrong-typed decoration must not unread a
        // handle whose process is up.
        name: map['name'] as String?,
        logPath: map['logPath'] as String?,
        ready: map['ready'] as String?,
        readyPort: map['readyPort'] as int?,
        stopping: map['stopping'] == true,
        handlePath: file.path,
      );
    } on Object {
      // Torn write, stale schema, deleted meanwhile — a handle that cannot be
      // read is a handle that does not exist.
      return null;
    }
  }

  /// Every handle in [runDir] for one declared service, newest first.
  ///
  /// More than one means a start raced another, or a stop failed to clean up.
  /// Both are real, so this hands back the lot and lets the caller keep the one
  /// that is alive and delete the rest — silently picking would leave the loser
  /// running with nothing pointing at it, which is the orphan this file exists
  /// to prevent.
  static List<ServiceHandle> findAll(
    String runDir,
    String worktree,
    String service,
  ) {
    var prefix = '${serviceHandleKey(worktree, service)}-';
    List<FileSystemEntity> entries;
    try {
      entries = Directory(runDir).listSync();
    } on FileSystemException {
      return const [];
    }
    var found = <ServiceHandle>[];
    for (var entity in entries) {
      if (entity is! File) continue;
      var name = p.basename(entity.path);
      if (!name.startsWith(prefix) || !name.endsWith('.json')) continue;
      if (ServiceHandle.tryRead(entity) case var handle?) found.add(handle);
    }
    found.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return found;
  }

  @override
  String toString() => 'ServiceHandle($service, pid $pid)';
}

/// The `svc-<hash>` stem shared by an owned service's handle and its log.
///
/// Keyed by worktree and service id rather than by pid, so the pieces of one
/// service are recognisably one service in a directory listing and the next
/// session can find them without knowing what pid to look for. The pid goes in
/// the suffix, which is what makes two racing starts produce two files and one
/// visible conflict rather than one file and a silent overwrite.
String serviceHandleKey(String worktree, String service) {
  var key = sha1
      .convert(utf8.encode('$worktree|$service'))
      .toString()
      .substring(0, 12);
  return 'svc-$key';
}
