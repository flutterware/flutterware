import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../utils/run_dir.dart';
import 'run_files.dart';

/// One app running on one device, announced as a file under the run dir.
///
/// This is the ledger the cockpit answers "is that phone free?" from. It is a
/// file rather than a registry in some process because the question is asked
/// across worktrees and across surfaces: a `fw` in one checkout has to see the
/// GUI in another holding a device, and neither of them is a server the other
/// can call. The server plugin's `srv-*.json` handles work the same way, for
/// the same reason.
///
/// Nothing in a handle is trusted to be current. The file says what was
/// true when it was written; whether the app is still up is decided by
/// connecting ([probe]), and whether the launcher is still up by looking for
/// its process. That split is not pedantry — the launch spike found that they
/// die separately, and which one died decides what the app can still be told
/// to do.
class RunHandle {
  RunHandle({
    required this.worktree,
    required this.worktreeName,
    required this.device,
    required this.entrypoint,
    required this.launcherPid,
    required this.startedAt,
    this.package,
    this.entrypointName,
    this.deviceName,
    this.flavor,
    this.vmService,
    this.appId,
    this.logPath,
    this.defines = const {},
    this.knobs = const {},
    this.world,
    this.protocol = runHandleProtocol,
    this.handlePath,
  });

  /// Absolute path to the worktree that launched it. What makes a device "held
  /// by another worktree" answerable.
  final String worktree;

  /// The worktree's [Worktree.name] — carried rather than derived because the
  /// process reading this handle is in a *different* checkout and cannot ask
  /// git about one it has not opened.
  final String worktreeName;

  /// The device id, as `flutter run -d` takes it.
  final String device;

  /// What to call the device on screen. A mirror, like [worktreeName]: a cold
  /// reader with no daemon has no other way to say "iPhone 11" rather than a
  /// 40-character UDID.
  final String? deviceName;

  /// Package-relative path of the entry point — `lib/main_staging.dart`.
  final String entrypoint;

  /// The declared name of the entry point, when it had one — `Staging`.
  final String? entrypointName;

  /// The package it belongs to, relative to [worktree].
  final String? package;

  /// The `--flavor` it was built with, when the project has them.
  ///
  /// Part of what makes a run *this* run and not another: two flavors of one
  /// entry point are two apps, usually with different bundle ids, and both can
  /// be on the phone at once. See [runHandleKey].
  final String? flavor;

  /// The `flutter run` child. It owns the port forward and registers
  /// `reloadSources`/`hotRestart` on the app's VM service, so its death is a
  /// loss of capability rather than the end of the session.
  final int launcherPid;

  /// The app's VM service, as a `ws://` URI. Null while the launcher is still
  /// building — a handle is written before there is anything to connect to, so
  /// that a device shows as taken during the ninety seconds a cold Android
  /// build takes.
  final String? vmService;

  /// The daemon's app id, for `app.stop` and `app.restart` on the launcher's
  /// own protocol.
  final String? appId;

  /// The launch defines this run was built with — the dart-defines. Recorded
  /// because changing one costs a rebuild, so "what is running there" is not
  /// answered by the entry point alone.
  final Map<String, String> defines;

  /// The values this run's `main` was called with, by parameter name.
  ///
  /// Recorded for a different reason than [defines]: those cost a rebuild to
  /// change, so knowing them tells you what is running there. These cost a hot
  /// restart, so knowing them is what lets the cockpit *show* them and offer to
  /// change one — a knob whose current value the tool had forgotten would be a
  /// field you can only overwrite blind.
  final Map<String, String> knobs;

  /// Where the launcher's `--machine` stream is being written.
  final String? logPath;

  /// The world this app belongs to, when it is a person's app in one — its
  /// name. Such an app's knobs are the world script's, so they change with
  /// the world's restart rather than here.
  final String? world;

  final DateTime startedAt;

  final int protocol;

  /// Where this handle was read from; null on the writing side.
  final String? handlePath;

  /// This run with some fields replaced.
  ///
  /// One copy, not one per caller. There were three, written out field by
  /// field, and a field added to only two of them was silently dropped by the
  /// third: `knobs` survived the launch, survived `publish`'s file, and
  /// vanished from the handle `publish` *returned* — so the first
  /// `refreshFromLog` a second later wrote it back without them. The cockpit
  /// then showed empty fields for an app plainly running with values. Sixteen
  /// fields is too many to copy by hand more than once.
  RunHandle _copy({
    String? vmService,
    String? appId,
    Map<String, String>? knobs,
    String? handlePath,
  }) => RunHandle(
    worktree: worktree,
    worktreeName: worktreeName,
    device: device,
    deviceName: deviceName,
    entrypoint: entrypoint,
    entrypointName: entrypointName,
    package: package,
    flavor: flavor,
    launcherPid: launcherPid,
    vmService: vmService ?? this.vmService,
    appId: appId ?? this.appId,
    defines: defines,
    knobs: knobs ?? this.knobs,
    logPath: logPath,
    world: world,
    startedAt: startedAt,
    protocol: protocol,
    handlePath: handlePath ?? this.handlePath,
  );

  /// The same run with different knob values — what [publish] writes after the
  /// wrapper has been rewritten and the app restarted.
  RunHandle withKnobs(Map<String, String> values) => _copy(knobs: values);

  Map<String, Object?> toJson() => {
    'worktree': worktree,
    'worktreeName': worktreeName,
    'device': device,
    if (deviceName != null) 'deviceName': deviceName,
    'entrypoint': entrypoint,
    if (entrypointName != null) 'entrypointName': entrypointName,
    if (package != null) 'package': package,
    if (flavor != null) 'flavor': flavor,
    'launcherPid': launcherPid,
    if (vmService != null) 'vmService': vmService,
    if (appId != null) 'appId': appId,
    if (defines.isNotEmpty) 'defines': defines,
    if (knobs.isNotEmpty) 'knobs': knobs,
    if (logPath != null) 'logPath': logPath,
    if (world != null) 'world': world,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'protocol': protocol,
  };

  static RunHandle? tryRead(File file) =>
      tryParse(file.path, file.readAsStringSync);

  /// The handle at [path], whose text [read] answers — null for one that
  /// cannot be read, however that happened.
  static RunHandle? tryParse(String path, String? Function() read) {
    try {
      var json = jsonDecode(read() ?? '');
      if (json is! Map) return null;
      var map = json.cast<String, Object?>();
      return RunHandle(
        worktree: map['worktree']! as String,
        worktreeName: map['worktreeName']! as String,
        device: map['device']! as String,
        entrypoint: map['entrypoint']! as String,
        launcherPid: map['launcherPid']! as int,
        startedAt: DateTime.parse(map['startedAt']! as String),
        // Tolerant below this line, like the server handle's mirrors: a
        // wrong-typed decoration must not unread a handle whose app is up.
        deviceName: map['deviceName'] as String?,
        entrypointName: map['entrypointName'] as String?,
        package: map['package'] as String?,
        flavor: map['flavor'] as String?,
        vmService: map['vmService'] as String?,
        appId: map['appId'] as String?,
        logPath: map['logPath'] as String?,
        world: map['world'] as String?,
        defines: {
          for (var entry in (map['defines'] as Map? ?? const {}).entries)
            if (entry.value is String) '${entry.key}': entry.value! as String,
        },
        knobs: {
          for (var entry in (map['knobs'] as Map? ?? const {}).entries)
            '${entry.key}': '${entry.value}',
        },
        protocol: map['protocol'] as int? ?? runHandleProtocol,
        handlePath: path,
      );
    } on Object {
      // Torn write, stale schema, deleted meanwhile — a handle that cannot be
      // read is a handle that does not exist.
      return null;
    }
  }

  /// What to call the entry point on screen.
  String get entrypointLabel => entrypointName ?? p.basename(entrypoint);

  /// What to call the device on screen. The id when the launcher never learned
  /// a name for it — a handle written by a process that had no daemon.
  String get deviceLabel => deviceName ?? device;

  /// This run's stable name — see [runHandleKey].
  ///
  /// Stable across relaunch, which is what makes it usable as an address: the
  /// same entry point on the same device from the same worktree is the same
  /// run, whatever pid is carrying it this time.
  String get key => runHandleKey(worktree, device, entrypoint, flavor);

  /// This *launch* — [key] plus the pid carrying it, which is exactly how the
  /// handle, the log and the journal are named on disk.
  ///
  /// The one identity that separates two live runs of the same entry point on
  /// the same device from the same worktree. [key] deliberately cannot: it is
  /// stable across relaunch, which is what makes it an address, and what makes
  /// it useless as an argument when two launchers are up at once — a `stop`
  /// asked to choose between them could only refuse with the same string
  /// twice.
  String get runId => '$key-$launcherPid';

  /// What to call the run on screen: the entry point, and the flavor when
  /// there is one to tell it apart from.
  String get runLabel =>
      flavor == null ? entrypointLabel : '$entrypointLabel ($flavor)';

  /// The same run, now that its VM service is known.
  RunHandle withService({String? vmService, String? appId}) =>
      _copy(vmService: vmService, appId: appId);

  /// Writes this handle into [runDir] under its own name, and returns it
  /// knowing where it went.
  RunHandle publish(String runDir) {
    var path = p.join(
      runDir,
      runHandleFileName(
        worktree: worktree,
        device: device,
        entrypoint: entrypoint,
        flavor: flavor,
        launcherPid: launcherPid,
      ),
    );
    Directory(runDir).createSync(recursive: true);
    File(path).writeAsStringSync(jsonEncode(toJson()));
    return _copy(handlePath: path);
  }

  /// Rewrites the file this handle was read from. A no-op for one that has no
  /// file yet — use [publish] for those.
  void save() {
    var path = handlePath;
    if (path == null) return;
    try {
      File(path).writeAsStringSync(jsonEncode(toJson()));
    } on FileSystemException {
      // The handle was swept while this was being written, which means the run
      // is already believed dead. Losing the update is the right outcome.
    }
  }

  /// Removes this handle from the ledger. Called when a probe says nothing is
  /// there, so a device stops looking held by an app that died.
  void delete() {
    var path = handlePath;
    if (path == null) return;
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Another sweeper won the race. Not ours to report.
    }
  }

  @override
  String toString() => 'RunHandle($entrypoint on $device, from $worktreeName)';
}

/// Bumped when a field stops meaning what it meant. Readers keep working
/// against a handle written by an older writer — every field they need is
/// either required or optional-and-tolerated — so this exists to be *read* in
/// a bug report, not to gate anything yet.
const runHandleProtocol = 1;

/// The file one run announces itself in.
///
/// Keyed by worktree, device and entry point rather than by pid: those three
/// are what makes a run *the same run* across a restart, and a pid-keyed name
/// would leave a stale file behind every time a launcher was replaced. The pid
/// is in the suffix anyway so that two launchers racing for one device produce
/// two files and one visible conflict, rather than one file and a silent
/// overwrite.
String runHandleFileName({
  required String worktree,
  required String device,
  required String entrypoint,
  required int launcherPid,
  String? flavor,
}) => '${runHandleKey(worktree, device, entrypoint, flavor)}-$launcherPid.json';

/// The `app-<hash>` stem shared by a run's handle and its log.
///
/// Shared so the two are recognisably one run in a directory listing, and so
/// the sweeper's existing `*.log` rule ages the log out on its own.
///
/// [flavor] is part of the identity, not a decoration. `dev` and `prod` of
/// one entry point install as different bundle ids and sit on the phone
/// together, so keying without it would give two live runs one handle and one
/// log — the same collision that once had a relaunch publishing the previous
/// run's VM service address, only permanent.
///
/// A null flavor hashes exactly as before, so every key written by a build
/// that had no idea what a flavor was still names the same run.
String runHandleKey(
  String worktree,
  String device,
  String entrypoint, [
  String? flavor,
]) {
  var seed = '$worktree|$device|$entrypoint';
  var key = sha1
      .convert(utf8.encode(flavor == null ? seed : '$seed|$flavor'))
      .toString()
      .substring(0, 12);
  return 'app-$key';
}

/// The `app-*.json` handles in [runDir], newest first, optionally filtered to
/// runs launched from inside [underRoot].
///
/// Reads files and nothing else — deciding liveness means opening a socket, and
/// this is called from `report` and `computeAll`, which must not.
///
/// Unfiltered is the useful default here, unlike the server plugin's scan: the
/// point of the ledger is that *another* worktree's run is what is holding the
/// phone, so a scan that could only see its own would answer "free" about a
/// device nothing can launch onto.
List<RunHandle> scanRunHandles(
  String runDir, {
  String? underRoot,
  RunFiles files = const DiskRunFiles(),
}) {
  List<String> entries;
  try {
    entries = files.list(runDir);
  } on UnsupportedError {
    // No filesystem at all — a browser. Nothing has been launched from one.
    return [];
  }
  var handles = <RunHandle>[];
  for (var path in entries) {
    var name = p.basename(path);
    if (!name.startsWith('app-') || !name.endsWith('.json')) continue;
    var handle = RunHandle.tryParse(path, () => files.readString(path));
    if (handle == null) continue;
    if (underRoot != null && !_isAtOrWithin(underRoot, handle.worktree)) {
      continue;
    }
    handles.add(handle);
  }
  handles.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return handles;
}

/// The worktree root itself counts, not only what is under it — the launcher
/// runs from the checkout, so equality is the common case and `p.isWithin`
/// alone would filter out every handle a worktree wrote about itself.
bool _isAtOrWithin(String root, String path) =>
    p.canonicalize(root) == p.canonicalize(path) || p.isWithin(root, path);

/// What is actually still there, for one handle.
///
/// The two halves are separate because they fail separately, and the launch
/// spike is what proved it: killing the `flutter run` that started an app
/// leaves the app running and reading its widget tree, while `reloadSources`
/// and `hotRestart` — which the *tool* registered, not the app — vanish with
/// it. A cockpit that reported one boolean would have to choose which of those
/// two truths to tell.
class RunProbe {
  const RunProbe({required this.app, required this.launcher, this.error});

  /// The app answered on its VM service.
  final bool app;

  /// The `flutter run` process that started it is still alive.
  final bool launcher;

  /// Why the app did not answer, when it did not. Kept because "connection
  /// refused" and "no route to host" are different problems on a wireless
  /// phone, and neither is "the app exited".
  final String? error;

  /// Reload and restart are the launcher's to offer.
  bool get canReload => app && launcher;
  bool get canRestart => canReload;

  /// Tree, screenshot and the drive verbs live in the app itself.
  bool get canInspect => app;

  /// Nothing to talk to. The handle's row is a corpse and can be swept.
  bool get isDead => !app && !launcher;
}

/// Connects to [handle]'s VM service and looks for its launcher.
///
/// Opens a socket, so it belongs in an action or in live tracking — never in
/// `report` or `computeAll`.
Future<RunProbe> probeRunHandle(
  RunHandle handle, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  // Current, not merely alive: a dead launcher whose pid was recycled would
  // otherwise read `launcher: true` forever — never `isDead`, never swept,
  // its device reported busy to every worktree.
  var launcher = isProcessCurrent(handle.launcherPid, handle.startedAt);
  var uri = handle.vmService;
  if (uri == null) {
    // Still building: there is no service to ask, and the launcher being alive
    // is the whole of what is known.
    return RunProbe(app: false, launcher: launcher, error: 'not started yet');
  }
  VmService? service;
  try {
    service = await vmServiceConnectUri(uri).timeout(timeout);
    // A connect alone is not proof on Android: `adb forward` accepts on the
    // host and only then discovers there is nothing behind it. One round trip
    // is what distinguishes a live app from a live forward.
    await service.getVersion().timeout(timeout);
    return RunProbe(app: true, launcher: launcher);
  } on Object catch (e) {
    return RunProbe(app: false, launcher: launcher, error: '$e');
  } finally {
    unawaited(service?.dispose());
  }
}
