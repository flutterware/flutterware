import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Where flutterware puts unix sockets and other per-run scratch.
///
/// Deliberately short and *not* under the project's build directory. A unix
/// socket path is capped at 104 bytes on macOS — `sun_path` in `man 7 unix` —
/// and the CLI installs its copy of the GUI under
/// `~/.flutterware/<sha1>/app/`, which is 70 characters before anything else is
/// appended. A socket under that copy's `build/` overflows, and the error the
/// OS gives is about path length rather than about anything the caller did.
String flutterwareRunDir() {
  var dir = p.join(flutterwareDir(), 'run');
  try {
    Directory(dir).createSync(recursive: true);
  } on UnsupportedError {
    // A browser: nothing can be created, and nothing will be run.
  }
  return dir;
}

/// The `~/.flutterware` directory: per-user state that outlives any one run
/// or checkout, such as compiled-shader caches keyed by engine revision and
/// the stages they were compiled for.
String flutterwareDir() {
  if (flutterwareDirOverride case var it?) return it;
  String home;
  try {
    home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
  } on UnsupportedError {
    // A browser has no environment and no home. The studio's web demo opens
    // a recording and writes nothing, so a nominal path is all anything
    // needs — see `lib/main_demo_web.dart`.
    home = '/';
  }
  return p.join(home, '.flutterware');
}

/// Somewhere else to put it, for a test that writes here.
///
/// The environment cannot be set from inside a Dart process, so a test that
/// exercises real path resolution — *the* thing that failed in the review-log
/// report — would otherwise write into the developer's own `~/.flutterware`,
/// which is the one directory a test may not touch.
@visibleForTesting
String? flutterwareDirOverride;

/// Deletes what previous runs left behind in [flutterwareRunDir].
///
/// Nothing used to. Every daemon writes a `<key>.log` and a `<key>.lock` there,
/// and its `<key>.sock` survives any exit that is not graceful — while the key
/// itself moves whenever the daemon's own sources change, so *every edit to the
/// daemon leaves a fresh set behind*. Measured on one machine after three days
/// of development: 458 files, 227 locks, 214 logs, 14 orphaned sockets. None of
/// it large, all of it permanent, and `_tailLog` reads a whole log on every
/// failed connect.
///
/// `<key>.failed` is swept on the same rule. It is normally consumed by the
/// client waiting for it, but a client that had already connected hears the
/// failure over the socket and never reads the file — so it is orphaned exactly
/// when a daemon fails with a client attached.
///
/// Two rules, and the difference between them is what makes this safe to run
/// while other flutterware processes are up:
///
/// - **Nothing modified within [keepFor] is touched.** That is what protects
///   everything in use: a live daemon appends to its log, and a client that is
///   *this moment* deciding whether to spawn is holding a lock it just created.
///   It also leaves a post-mortem window — the log of a daemon that died an hour
///   ago is the only account of why.
/// - **Older than that, a daemon socket is deleted only if nothing answers it**,
///   and its log and lock only if its socket did not. A daemon can legitimately
///   run for days; unlinking its socket would leave it running and unreachable,
///   which is worse than the litter.
///
/// Guest sockets (`g-*`, `shot-*`, and the spikes) are aged out without a
/// connect test. Unlinking a unix socket does not disturb connections already
/// established on it, so the cost of being wrong about a guest is that nobody
/// new can reach it — and a guest that has been up for [keepFor] is a leak
/// rather than a guest. They are not probed because a guest's IPC socket expects a
/// protocol, not a knock.
///
/// Frame-scratch directories (`cap-*`) age out the same way. A session that
/// closes cleanly deletes its own; this catches the ones a crash left behind.
/// A directory's mtime moves with every file created or deleted inside it, and
/// a capture does both per frame, so a directory old enough to sweep belongs
/// to nothing.
///
/// `srv-*` sockets get the daemon rule rather than the guest rule. The guest
/// rationale inverts for an inspected server: a dev server running since
/// Monday is normal, and aging its socket out would cascade —
/// nothing new could connect, so the next attacher would delete its handle as
/// dead, and the server would vanish from every list while still running. The
/// knock is free by protocol: an inspected server writes nothing to a
/// connection that has not sent `meta/attach` (see
/// `lib/src/server/protocol.dart` in `package:flutterware`).
///
/// `world-owner-*` sockets get the daemon rule too: a world stays open in the
/// studio for as long as somebody works in it, and its owner's socket — or
/// the studio's door, which takes the openings `fw` and the MCP server are
/// asked for — is how every other process reaches it. Aged out, the world
/// was still open and answered nobody. The knock costs nothing: an owner
/// answers a connection that asks nothing with nothing anyone reads.
///
/// `live-*.json` is left alone: there is exactly one per project, so it is
/// bounded, and [attachToLiveSession] already deletes one that will not
/// connect. `srv-*.json` does not share that bound — one per server process,
/// under names that change — so an old one is swept with its socket, and kept
/// while its socket still answers.
///
/// `app-*.json` — a run's handle — is kept while its launcher is alive, and
/// aged out otherwise. It has no socket here to knock on: it points at a VM
/// service on a device, and deciding it properly means an async websocket
/// connect, which this sweeper is the wrong place for. The run plugin does that
/// probe continuously while anything is watching, so this only catches what a
/// crash left behind — hence the pid check, which spares a desktop session that
/// has legitimately been up since Monday, and the age gate, which spares a
/// launch that started thirty seconds ago.
///
/// `devices.json` is never swept: there is exactly one, it is small, and the
/// next daemon overwrites it. Deleting it would only make a cold `fw devices`
/// answer "nothing has ever looked" about a machine that had a device list a
/// minute ago.
///
/// Every failure is swallowed per file. This is housekeeping — another process
/// winning a race to delete the same orphan is the expected case, not an error,
/// and nothing here is worth failing a daemon start over.
///
/// [directory] defaults to [flutterwareRunDir] and exists so the rules can be
/// tested: what they turn on is a file's name and age, not where it sits, and
/// "spares a daemon that still answers" is not checkable against a directory the
/// test cannot put a listening socket in.
Future<int> sweepRunDir({
  Duration keepFor = const Duration(days: 1),
  String? directory,
}) async {
  var dir = Directory(directory ?? flutterwareRunDir());
  var cutoff = DateTime.now().subtract(keepFor);
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync();
  } on FileSystemException {
    return 0;
  }

  var deleted = 0;
  // Keys whose daemon is still there, so its log and lock stay with it.
  var serving = <String>{};

  for (var entity in entries) {
    var name = p.basename(entity.path);
    if (!name.endsWith('.sock')) continue;
    var key = name.substring(0, name.length - '.sock'.length);
    if (!_isOlderThan(entity, cutoff)) {
      serving.add(key);
      continue;
    }
    // A daemon key is the 16 hex characters of a config hash; `srv-*` is an
    // inspected server's socket, `world-owner-*` a world's owner or a
    // studio's door. All are probed rather than aged — see the doc above.
    // Anything else is a guest or a spike, aged out unprobed.
    if ((_daemonKey.hasMatch(key) ||
            key.startsWith('srv-') ||
            key.startsWith('world-owner-')) &&
        await _answers(entity.path)) {
      serving.add(key);
      continue;
    }
    if (_delete(entity)) deleted++;
  }

  for (var entity in entries) {
    var name = p.basename(entity.path);
    var isServerHandle = name.startsWith('srv-') && name.endsWith('.json');
    // `.png` is a run's last screenshot, written beside its log and swept on
    // the same terms: an observation of a moment nobody asked to keep.
    if (!name.endsWith('.log') &&
        !name.endsWith('.lock') &&
        !name.endsWith('.failed') &&
        !name.endsWith('.png') &&
        !isServerHandle) {
      continue;
    }
    var key = name.substring(0, name.lastIndexOf('.'));
    if (serving.contains(key)) continue;
    if (!_isOlderThan(entity, cutoff)) continue;
    if (_delete(entity)) deleted++;
  }

  for (var entity in entries) {
    var name = p.basename(entity.path);
    if (entity is! File ||
        !name.startsWith('app-') ||
        !name.endsWith('.json')) {
      continue;
    }
    if (!_isOlderThan(entity, cutoff)) continue;
    if (_launcherIsAlive(entity)) continue;
    if (_delete(entity)) deleted++;
  }

  for (var entity in entries) {
    if (entity is! Directory) continue;
    if (!p.basename(entity.path).startsWith('cap-')) continue;
    if (!_isOlderThan(entity, cutoff)) continue;
    try {
      entity.deleteSync(recursive: true);
      deleted++;
    } on FileSystemException {
      // Another sweeper won the race, or a frame is mid-write; either way it
      // is not ours to force.
    }
  }

  // A run's journal and its step artifacts. The stem ties the pieces to
  // their run: `app-<key>-<pid>.journal.jsonl` (and its `.1` rotation) and
  // `journal/app-<key>-<pid>/` belong to the handle `app-<key>-<pid>.json`.
  // A story whose run is still in the ledger is spared at any age — the
  // Steps tab replays it — and once the handle is gone (loop three, possibly
  // this very pass) the story ages out on the normal terms. Before this rule
  // existed the journals matched nothing and accumulated forever.
  bool runIsGone(String stem) =>
      !File(p.join(dir.path, '$stem.json')).existsSync();
  for (var entity in entries) {
    var name = p.basename(entity.path);
    var stem = name.endsWith('.journal.jsonl')
        ? name.substring(0, name.length - '.journal.jsonl'.length)
        : name.endsWith('.journal.jsonl.1')
        ? name.substring(0, name.length - '.journal.jsonl.1'.length)
        : null;
    if (stem == null) continue;
    if (!_isOlderThan(entity, cutoff)) continue;
    if (!runIsGone(stem)) continue;
    if (_delete(entity)) deleted++;
  }
  List<FileSystemEntity> journalDirs;
  try {
    journalDirs = Directory(p.join(dir.path, 'journal')).listSync();
  } on FileSystemException {
    journalDirs = const [];
  }
  for (var entity in journalDirs) {
    if (entity is! Directory) continue;
    if (!_isOlderThan(entity, cutoff)) continue;
    if (!runIsGone(p.basename(entity.path))) continue;
    try {
      entity.deleteSync(recursive: true);
      deleted++;
    } on FileSystemException {
      // Same as `cap-*`: a step mid-write or a lost race, neither ours to
      // force.
    }
  }

  return deleted;
}

/// Whether this process has already swept.
bool _sweptThisProcess = false;

/// [sweepRunDir], at most once in the life of this process.
///
/// For callers on a hot path. The sweep walks the directory and stats every
/// entry; a long-lived GUI that launched a run every few minutes would pay that
/// repeatedly to find nothing, because the litter it is looking for is left by
/// processes that have already died. Once per process is what a launcher wants,
/// and what a daemon that sweeps at startup already does by construction.
///
/// Returns how many entries were removed, or zero for the calls that did not
/// run. Failures are swallowed rather than thrown: this is housekeeping, and no
/// caller should fail over it.
Future<int> sweepRunDirOnce(
  String? directory, {
  Duration keepFor = const Duration(days: 1),
}) async {
  if (_sweptThisProcess) return 0;
  _sweptThisProcess = true;
  try {
    return await sweepRunDir(keepFor: keepFor, directory: directory);
  } on Object {
    return 0;
  }
}

/// Lets a test run [sweepRunDirOnce] more than once per process.
@visibleForTesting
void debugResetRunDirSweep() => _sweptThisProcess = false;

final _daemonKey = RegExp(r'^[0-9a-f]{16}$');

/// Whether a run handle's `flutter run` is still there.
///
/// Read straight out of the file rather than through `RunHandle`, so the
/// sweeper stays a leaf: it must not pull the VM-service client in behind it,
/// and the one field it needs is a number.
bool _launcherIsAlive(File handle) {
  try {
    var json = jsonDecode(handle.readAsStringSync());
    if (json is! Map) return false;
    var pid = json['launcherPid'] as int? ?? 0;
    // Current, not merely alive — a recycled pid would shield a dead run's
    // handle from every sweep. A handle old enough to sweep is exactly the
    // kind old enough to have had its pid recycled.
    var startedAt = DateTime.tryParse('${json['startedAt']}');
    return startedAt == null
        ? isProcessAlive(pid)
        : isProcessCurrent(pid, startedAt);
  } on Object {
    // Unreadable is not "alive": a handle nothing can parse is litter.
    return false;
  }
}

/// Whether [pid] is a process this user could signal.
///
/// `SIGCONT` is the probe because it is the signal a running process ignores —
/// `kill` fails with `ESRCH` when the pid is gone, which is the answer we are
/// after, and does nothing when it is not.
///
/// Two ways this can be wrong, both narrow and both worth naming: a pid
/// recycled onto an unrelated process reads as alive, and a process owned by
/// another user reads as dead. Recycling matters whenever the answer decides
/// an *action* — a handle lives on disk for up to a day, and a busy machine
/// recycles pids well inside that — which is what [isProcessCurrent] is for.
bool isProcessAlive(int pid) {
  if (pid <= 0) return false;
  try {
    return Process.killPid(pid, ProcessSignal.sigcont);
  } on Object {
    return false;
  }
}

/// Whether [pid] is alive *and* still the process that was recorded at
/// [recordedAt], rather than a newer one wearing a recycled number.
///
/// The tie-breaker is the process's own age: a launcher recorded at T cannot
/// have started after T, so a process younger than the record is a different
/// one. Believing a recycled pid compounds badly in both directions — `stop`
/// would SIGTERM whatever unrelated process holds the number now, and a dead
/// run whose pid was recycled reads as alive forever, pinning its device as
/// busy in every worktree and shielding its handle from every sweep.
///
/// The slack absorbs `etime`'s whole-second coarseness and the gap between
/// spawning and publishing the handle; doubt resolves to "same process",
/// which is exactly the failure mode this had before. Where the platform
/// cannot say how old a process is, liveness alone answers, as before.
bool isProcessCurrent(int pid, DateTime recordedAt) {
  if (!isProcessAlive(pid)) return false;
  var elapsed = processElapsed(pid);
  if (elapsed == null) return true;
  var started = DateTime.now().subtract(elapsed);
  return !started.isAfter(recordedAt.add(const Duration(minutes: 10)));
}

/// How long [pid] has been running, or null when the platform cannot say.
///
/// `etime` rather than `lstart`: elapsed time is `[[dd-]hh:]mm:ss` on every
/// POSIX `ps`, while a start *time* prints in the current locale and would
/// need a parser per language.
Duration? processElapsed(int pid) {
  if (Platform.isWindows) return null;
  try {
    var result = Process.runSync('ps', ['-p', '$pid', '-o', 'etime=']);
    if (result.exitCode != 0) return null;
    return parseElapsed('${result.stdout}');
  } on Object {
    return null;
  }
}

/// `ps` elapsed format: `[[dd-]hh:]mm:ss`.
@visibleForTesting
Duration? parseElapsed(String text) {
  var match = RegExp(r'^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$')
      .firstMatch(text.trim());
  if (match == null) return null;
  int part(int group) => int.parse(match[group] ?? '0');
  return Duration(
    days: part(1),
    hours: part(2),
    minutes: part(3),
    seconds: part(4),
  );
}

bool _isOlderThan(FileSystemEntity entity, DateTime cutoff) {
  try {
    return entity.statSync().modified.isBefore(cutoff);
  } on FileSystemException {
    return false;
  }
}

/// Whether anything is listening on [socketPath].
///
/// The same test [CompilerDaemonClient] uses to decide whether to spawn: the
/// file being present proves only that a daemon once bound it.
Future<bool> _answers(String socketPath) async {
  try {
    var socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    ).timeout(const Duration(seconds: 1));
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

bool _delete(FileSystemEntity entity) {
  try {
    entity.deleteSync();
    return true;
  } on FileSystemException {
    // Lost a race with another sweeper, or no permission. Neither is ours to
    // report.
    return false;
  }
}

/// A child process that must not outlive the one that spawned it, recorded so
/// that a later process can finish the job when this one never gets to.
///
/// **A `flutter_tester` guest is the one child flutterware spawns that survives
/// its owner.** Measured on one machine: 19 of them with `ppid` 1, the oldest up
/// **1 day 23 hours**, on assets directories belonging to worktrees whose GUI
/// was long gone — where every `frontend_server` on the same machine had a live
/// parent and none had leaked. `TesterHost.dispose` kills its guest and always
/// has; what it cannot cover is the process dying without reaching it, which is
/// every crash, every `kill -9` and every window closed the quick way. No
/// in-process hook covers those, so the cure has to be a sweep by whoever comes
/// next.
///
/// The rules are two, and both are about *whose* guest it is:
///
/// * **The owner is gone** — the ordinary case above. [isProcessCurrent] rather
///   than [isProcessAlive], because a handle can outlive a pid's recycling and
///   believing a recycled owner would shield an orphan for ever.
/// * **The owner is this process, from before it restarted.** A Flutter hot
///   restart replaces the isolate and leaves the process — so `dispose` never
///   runs, statics reset, and the new incarnation spawns its own guests beside
///   the old ones. [_ownGuests] is what keeps that rule from reaching a guest
///   this incarnation actually owns.
class GuestHandle {
  GuestHandle({
    required this.pid,
    required this.startedAt,
    required this.ownerPid,
    required this.ownerRecordedAt,
    required this.what,
  });

  static GuestHandle? _read(File file) {
    try {
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return null;
      var pid = json['pid'];
      var ownerPid = json['ownerPid'];
      if (pid is! int || ownerPid is! int) return null;
      return GuestHandle(
        pid: pid,
        startedAt: DateTime.tryParse('${json['startedAt']}'),
        ownerPid: ownerPid,
        ownerRecordedAt: DateTime.tryParse('${json['ownerRecordedAt']}'),
        what: '${json['what']}',
      );
    } on Object {
      // Unreadable is litter, and litter is swept — the same rule the run
      // handles follow.
      return null;
    }
  }

  final int pid;

  /// When the guest was spawned, for [isProcessCurrent] to tell it from a
  /// process wearing a recycled number.
  final DateTime? startedAt;

  final int ownerPid;

  /// When the owner wrote this. It cannot have started *after* writing, so a
  /// process at [ownerPid] younger than this is somebody else.
  final DateTime? ownerRecordedAt;

  /// What it was running, for the log line the sweep prints.
  final String what;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'startedAt': startedAt?.toIso8601String(),
    'ownerPid': ownerPid,
    'ownerRecordedAt': ownerRecordedAt?.toIso8601String(),
    'what': what,
  };
}

/// The guests this incarnation of this isolate spawned and has not forgotten.
///
/// The guard on the hot-restart rule below: without it, a second host starting
/// while the first sweeps would have its brand-new guest read as one this
/// process left behind, and killed.
final _ownGuests = <int>{};

String _guestHandlePath(int pid, String? directory) =>
    p.join(directory ?? flutterwareRunDir(), 'guest-$pid.json');

/// Records [pid] as this process's to kill, so that [sweepOrphanedGuests] can
/// do it if this process never does.
void recordSpawnedGuest({
  required int pid,
  required String what,
  String? directory,
}) {
  _ownGuests.add(pid);
  try {
    File(_guestHandlePath(pid, directory)).writeAsStringSync(
      jsonEncode(
        GuestHandle(
          pid: pid,
          startedAt: DateTime.now(),
          ownerPid: _ownPid,
          ownerRecordedAt: DateTime.now(),
          what: what,
        ).toJson(),
      ),
    );
  } on Object {
    // Bookkeeping for somebody else's benefit. A machine that cannot write it
    // leaks exactly what it leaks today.
  }
}

/// Drops [pid]'s handle, because this process has killed it itself.
void forgetSpawnedGuest(int pid, {String? directory}) {
  _ownGuests.remove(pid);
  try {
    var file = File(_guestHandlePath(pid, directory));
    if (file.existsSync()) file.deleteSync();
  } on Object {
    // The next sweep reads it, finds the pid gone, and removes it.
  }
}

final _ownPid = pid;

/// Kills every recorded guest whose owner is not there to kill it, and returns
/// how many it ended.
///
/// Housekeeping, so every failure is swallowed per handle: another sweeper
/// winning the race is the expected case rather than an error.
int sweepOrphanedGuests({String? directory, void Function(String)? log}) {
  var dir = Directory(directory ?? flutterwareRunDir());
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync();
  } on FileSystemException {
    return 0;
  }
  var killed = 0;
  for (var entity in entries) {
    var name = p.basename(entity.path);
    if (entity is! File || !name.startsWith('guest-')) continue;
    if (!name.endsWith('.json')) continue;
    var handle = GuestHandle._read(entity);
    if (handle == null) {
      _delete(entity);
      continue;
    }
    // Ours, now: this incarnation spawned it and is still using it.
    if (_ownGuests.contains(handle.pid)) continue;
    var ownerHere =
        handle.ownerPid != _ownPid &&
        (handle.ownerRecordedAt == null
            ? isProcessAlive(handle.ownerPid)
            : isProcessCurrent(handle.ownerPid, handle.ownerRecordedAt!));
    if (ownerHere) continue;
    // The handle goes either way. A guest that has already exited leaves
    // nothing to kill and no reason to keep reading about it.
    var alive = handle.startedAt == null
        ? isProcessAlive(handle.pid)
        : isProcessCurrent(handle.pid, handle.startedAt!);
    if (alive) {
      try {
        if (Process.killPid(handle.pid, ProcessSignal.sigterm)) {
          killed++;
          log?.call(
            'killed an orphaned ${handle.what} guest (pid ${handle.pid}) '
            'whose owner ${handle.ownerPid} is gone',
          );
        }
      } on Object {
        // Not ours to signal. The handle still goes.
      }
    }
    _delete(entity);
  }
  return killed;
}

/// Deletes catalog build directories no daemon will ever open again.
///
/// A daemon's build directory is named by its address, and an address is a hash
/// of the whole config — so **every change to what the daemon is given orphans
/// one**, whole. The Impeller flags landing in #270 did it to every project on
/// every machine at once. Each holds an `out/` and an `assets/` of its own:
/// measured on one worktree, **3.6 GB across 30 of them**, all but one dead.
///
/// Three gates: [liveKey] is this daemon's own, a socket file under that key
/// means some daemon has bound it, and the age is the margin for one that is
/// between starting and binding. What is left costs its next start an asset
/// bundle and a host build — the warm kernel and the quarantine live under
/// `kernels/`, which is not a key and is never swept.
///
/// **The socket is tested by existence and never by a knock**, which is the
/// opposite of what [sweepRunDir] does to the socket files themselves, and the
/// difference is what is at stake in being wrong. `_answers` gives up after a
/// second, and a second is a duration a live daemon can miss under load —
/// measured, three integration files running at once and 3.7 GB being deleted
/// was enough. For a socket *file* a false negative costs a relink; here it
/// deletes a running daemon's `out/` from under it, and the daemon dies on the
/// next write with a broken pipe. So a bound socket is left alone whether or
/// not it replies. Nothing is lost by it: [sweepRunDir] runs first and unlinks
/// the sockets of daemons that are really gone, so their directories are
/// reclaimed on the next start rather than this one.
int sweepCatalogBuildDirs({
  required String catalogDir,
  required String liveKey,
  Duration keepFor = const Duration(days: 1),

  /// Where the sockets are, for the same reason [sweepRunDir] takes one: the
  /// rule turns on a name and an age, and a test may not knock on the
  /// developer's own.
  String? runDir,
}) {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(catalogDir).listSync();
  } on FileSystemException {
    return 0;
  }
  var cutoff = DateTime.now().subtract(keepFor);
  var deleted = 0;
  for (var entity in entries) {
    if (entity is! Directory) continue;
    var key = p.basename(entity.path);
    if (key == liveKey || !_daemonKey.hasMatch(key)) continue;
    // **The newest thing inside it, not the directory's own stamp.** A
    // directory's mtime moves when an entry is added or removed, and a daemon
    // that has been up for a week only ever rewrites files already in it — so
    // its own stamp reads as ancient while it is very much in use.
    DateTime newest;
    try {
      var stamps = [
        for (var child in entity.listSync()) child.statSync().modified,
      ];
      // The directory's own stamp only when it holds nothing — as a *fallback*,
      // never folded in with the children's. Creating a child bumps the parent,
      // so a directory whose contents are all ancient still reads as touched a
      // moment ago, and nothing would ever be swept.
      newest = stamps.isEmpty
          ? entity.statSync().modified
          : stamps.reduce((a, b) => a.isAfter(b) ? a : b);
    } on FileSystemException {
      continue;
    }
    if (newest.isAfter(cutoff)) continue;
    if (File(p.join(runDir ?? flutterwareRunDir(), '$key.sock')).existsSync()) {
      continue;
    }
    try {
      entity.deleteSync(recursive: true);
      deleted++;
    } on FileSystemException {
      // Housekeeping: another sweeper, or a file somebody has open.
    }
  }
  return deleted;
}

/// Whether this incarnation has already swept.
bool _sweptGuestsThisProcess = false;

/// [sweepOrphanedGuests], at most once in the life of this isolate.
///
/// Once per *isolate* rather than per process on purpose: a hot restart resets
/// this, which is exactly when the guests of the previous incarnation are owed
/// a sweep.
int sweepOrphanedGuestsOnce({String? directory, void Function(String)? log}) {
  if (_sweptGuestsThisProcess) return 0;
  _sweptGuestsThisProcess = true;
  try {
    return sweepOrphanedGuests(directory: directory, log: log);
  } on Object {
    return 0;
  }
}

/// Lets a test run [sweepOrphanedGuestsOnce] more than once per process.
@visibleForTesting
void debugResetGuestSweep() => _sweptGuestsThisProcess = false;

/// The longest a unix socket path may be, minus the NUL terminator.
///
/// 104 on macOS, 108 on Linux; the smaller is used everywhere so a path that
/// works on one does not fail on the other.
const maxSocketPathLength = 103;

/// Fails early, and legibly, on a socket path the OS will refuse.
///
/// Without this the symptom is a `SocketException` naming a limit rather than
/// the thing that produced the path, which is a long way from the cause.
String checkSocketPath(String path) {
  if (path.length <= maxSocketPathLength) return path;
  throw StateError(
    'Socket path is ${path.length} bytes, over the $maxSocketPathLength-byte '
    'limit:\n  $path\n'
    'Put it under flutterwareRunDir() rather than a build directory.',
  );
}
