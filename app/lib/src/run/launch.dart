import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../utils/daemon/events.dart';
import '../utils/daemon/protocol.dart';
import '../utils/flutter_sdk.dart';
import '../utils/run_dir.dart';
import 'guest_entrypoint.dart';
import 'handle.dart';
import 'run_files.dart';

final _logger = Logger('run_launch');

/// Disambiguates two launches from one process in the log file name; see the
/// naming comment in [launchApp].
var _launchSequence = 0;

/// Enough for an Xcode signing failure with its four remediation steps, which
/// is the longest real one measured. Past that it is a build log, not a reason.
const _maxFailureLines = 40;

/// Lines that name a fault rather than narrate one. Used only to pick a
/// headline out of a block that is reported in full either way, so a miss
/// costs a worse first line and never a lost reason.
final _saysError = RegExp(
  r'^\s*(error|exception|failed|failure|could not|unable to|no such)\b',
  caseSensitive: false,
);

/// The `flutter run --machine` argv a launch runs.
///
/// Split out of [launchApp] because it is the one part of a launch that is a
/// pure function of its inputs, and the flag rules below are worth holding to
/// a test rather than to a reading of a process that has to be spawned.
List<String> runCommand({
  required String flutter,
  required String device,
  required String target,
  required String? flavor,
  required bool targetsWeb,
  Map<String, String> defines = const {},
}) => [
  flutter,
  'run',
  '--machine',
  '--device-id',
  device,
  '--target',
  target,
  // Before the defines, because a flavor decides which variant is built and
  // the defines only decide what goes into it.
  //
  // **Never on web, which is where most of these flavors come from.** A
  // resolved flavor is often the pubspec's `flutter: default-flavor:`, and
  // that field exists *because* web takes no `--flavor` — it is how a web
  // build gets `appFlavor` populated at all. Passing it back on the command
  // line inverts what the field is for, and `flutter run` answers with a
  // deprecation warning on every launch, whose wording does not promise to
  // stay a warning. Everything else takes the flag: read off the pinned SDK,
  // `supportsFlavors` is true on macOS, Linux and Windows as well as Android
  // and iOS, and web is what inherits the `false` default. A device the daemon
  // has never described reads as not-web and keeps the flag, as before.
  if (flavor != null && !targetsWeb) ...['--flavor', flavor],
  for (var define in defines.entries) ...[
    '--dart-define',
    '${define.key}=${define.value}',
  ],
];

/// Starts `flutter run --machine` as a detached process, and announces it in
/// the run dir.
///
/// Detached, with its output going to a file. Detached because the thing
/// that launched an app must not be the thing that keeps it alive: a `fw
/// launch` returns, a GUI window closes, and the phone keeps running the app.
/// To a file because the `--machine` stream carries the build progress and the
/// VM-service URI, and a client that arrives *after* the interesting part
/// scrolled past still has to be able to read them — which is also what makes
/// the handle self-healing (see [refreshFromLog]).
///
/// The child owns the port forward, so on hardware nothing waits on it and
/// everything depends on it. Its death is detected rather than prevented: see
/// [RunProbe].
Future<RunHandle> launchApp({
  required FlutterSdkPath sdk,
  required String runDir,
  required String worktree,
  required String worktreeName,
  required String packageRoot,
  required String device,
  required String entrypoint,
  String? package,
  String? entrypointName,
  String? deviceName,
  String? flavor,
  bool targetsWeb = false,
  Map<String, String> defines = const {},
  Map<String, Object?> knobs = const {},
}) async {
  if (Platform.isWindows) {
    // `ProcessStartMode.detached` gives no stdio to redirect, and the POSIX
    // trick below needs a shell that is not there. Said plainly rather than
    // failing somewhere less legible.
    throw UnsupportedError(
      'Launching is implemented for macOS and Linux hosts. The child has to '
      'outlive this process with its output going to a file, and that is done '
      'with a shell redirect this platform has no equivalent of yet.',
    );
  }

  // **One log per launch, not per key.** The handle file is pid-suffixed so
  // two launchers racing produce two files and one visible conflict; a log
  // named by the key alone did not get that lesson, and two live runs of the
  // same key shared one file — the second launch truncated the first's story,
  // and [refreshFromLog] then read the second's `app.debugPort` into the
  // *first's* handle, pointing both at one VM. The suffix cannot be the
  // child's pid (the path travels into `Process.start` below, before there is
  // a child), so it is this process's pid plus a counter — unique across
  // racing launchers and within one. The stale-URI relaunch hazard this used
  // to truncate against is gone with the sharing: a fresh name has no
  // previous run's `app.debugPort` in it. Created eagerly so a poller that
  // arrives before the shell's redirect sees an empty log, not a missing one.
  var logPath = p.join(
    runDir,
    '${runHandleKey(worktree, device, entrypoint, flavor)}'
    '-$pid-${_launchSequence++}.log',
  );
  try {
    File(logPath).writeAsStringSync('');
  } on FileSystemException catch (e) {
    // Not fatal on its own — the shell redirect will still create it — so this
    // must not stop a launch.
    _logger.warning('Could not create $logPath before launching: $e');
  }
  // The guest wrapper is what makes the app driveable; without it the run is
  // inspect-only over the bare VM service. The handle keeps the *user's*
  // entrypoint either way — the wrapper is a launch detail, not an identity.
  var guestTarget = writeGuestEntrypoint(
    packageRoot: packageRoot,
    entrypoint: entrypoint,
    knobs: knobs,
    targetsWeb: targetsWeb,
  );
  if (!guestTarget.guest) {
    _logger.info('Launching without the run guest: ${guestTarget.reason}');
  }
  var command = runCommand(
    flutter: sdk.flutter,
    device: device,
    target: guestTarget.target,
    flavor: flavor,
    targetsWeb: targetsWeb,
    defines: defines,
  );

  // `exec "$@"` replaces the shell with flutter, so the pid this returns *is*
  // the launcher's — which matters, because the handle's `launcherPid` is what
  // every other process checks to decide whether reload is still on offer.
  // The log path travels in the environment rather than in the script, so no
  // amount of punctuation in a path can turn into shell syntax.
  var process = await Process.start(
    '/bin/sh',
    ['-c', r'exec "$@" > "$FW_RUN_LOG" 2>&1 < /dev/null', 'sh', ...command],
    workingDirectory: packageRoot,
    environment: {'FW_RUN_LOG': logPath},
    mode: ProcessStartMode.detached,
  );

  var handle = RunHandle(
    worktree: worktree,
    worktreeName: worktreeName,
    device: device,
    deviceName: deviceName,
    entrypoint: entrypoint,
    entrypointName: entrypointName,
    package: package,
    flavor: flavor,
    launcherPid: process.pid,
    defines: defines,
    knobs: {for (var e in knobs.entries) e.key: '${e.value}'},
    logPath: logPath,
    startedAt: DateTime.now(),
  );
  // Published before there is anything to connect to, deliberately: a cold
  // Android build takes a minute and a half, and for all of it the device is
  // taken. A ledger that only listed apps that had finished starting would
  // report a busy phone as free for exactly as long as it takes two people to
  // collide on it.
  var published = handle.publish(runDir);
  // **Launching is what makes the litter, so launching is what clears it** —
  // the same bargain `tool/catalog/compiler_daemon.dart` states, and until now
  // that daemon was [sweepRunDir]'s only caller, so a session that ran apps and
  // never opened Previews swept nothing at all. Measured 2026-08-13: 161MB of
  // step captures, none of it reachable.
  //
  // After [RunHandle.publish], so this run is already in the ledger and its own
  // journal cannot be swept out from under it. Unawaited: housekeeping must
  // never delay a launch.
  unawaited(
    sweepRunDirOnce(runDir).then((swept) {
      if (swept > 0) _logger.fine('swept $swept stale run files');
    }),
  );
  return published;
}

/// How far a launch has got, as a ladder of milestones the log has passed.
///
/// Coarse on purpose. This is not a second opinion about what the tool is
/// doing — while a progress span is open, the tool's own words are better than
/// anything inferred here, and [LaunchLog.stage] prefers them. This exists for
/// the gaps: before the tool has said anything structured at all (pub
/// resolution, measured at 15s warm and minutes on a cold cache), and between
/// one span closing and the next opening.
///
/// Every value is implied by a line the log has actually passed, and none of
/// them is a finished span's message. That distinction is the whole point: the
/// panel used to hold the last *started* span until the next one began, so
/// `Running pod install...` sat on the header for the thirty-five seconds of
/// Xcode build that followed it. A stuck build and a build between spans looked
/// identical, and the one word on offer named the wrong stage of the one you
/// had.
///
/// Ordered, and only ever climbed — a log is read from the top on every poll,
/// and a phrase that went backwards would read as the build restarting.
enum LaunchPhase {
  /// Nothing has been said yet.
  starting('starting'),

  /// `pub get` is running, before there is a daemon to ask.
  resolving('resolving dependencies'),

  /// Dependencies are in and the tool is up, but the build has not begun.
  preparing('preparing the build'),

  /// `Launching … in debug mode` has been printed.
  building('building'),

  /// The artifact exists; what remains is getting it onto the device.
  installing('installing on the device'),

  /// The VM service is up and we are connecting to it.
  attaching('attaching'),

  /// `app.started`.
  running('running');

  const LaunchPhase(this.label);

  /// The phrase, in the voice a status line wants.
  final String label;
}

/// What a launcher's log says so far.
///
/// The log is the source of truth about a run and the handle is a cache of it,
/// which is what lets any process — the GUI that started it, a `fw` in another
/// terminal, an agent — bring a handle up to date without having been present
/// when the app started.
class LaunchLog {
  const LaunchLog({
    this.appId,
    this.vmService,
    this.progress,
    this.phase = LaunchPhase.starting,
    this.error,
    this.output,
    this.trailing = const [],
    this.started = false,
    this.stopped = false,
  });

  final String? appId;

  /// The app's VM service as a `ws://` URI, once `app.debugPort` has arrived.
  final String? vmService;

  /// The most recent thing the tool said it was doing and **has not finished**
  /// — `Installing and launching…`.
  ///
  /// Open spans only. `app.progress` closes a span with `finished: true` and a
  /// null message, so a reader that only assigned on the way in kept the last
  /// started message for as long as the tool was between spans — which on a
  /// macOS launch is the thirty-five seconds of Xcode build following
  /// `Running pod install...`, narrated as pod install.
  ///
  /// Null between spans, which is honest and is why [stage] exists.
  final String? progress;

  /// How far the launch has got, when nothing is narrating it. See
  /// [LaunchPhase].
  final LaunchPhase phase;

  /// The most recent error the launcher *reported* — a `daemon.logMessage` at
  /// error level, an errored `app.log`, or the exception `app.stop` carried.
  ///
  /// Structured only, and that distinction is load-bearing: this is what
  /// [awaitLaunch] treats as terminal, and a plain line is not one. `flutter
  /// run` opens with `No devices found yet. Checking for wireless devices…`,
  /// which is a sentence about waiting and would end the wait if it counted.
  final String? error;

  /// The last plain line the launcher printed — everything in machine mode
  /// that is not an event.
  ///
  /// Context rather than a verdict. It is where the ugly failures land, so it
  /// is what explains a launcher that died without saying anything structured;
  /// while one is still alive it means nothing at all.
  final String? output;

  /// Every plain line since the last structured event, in order.
  ///
  /// A build failure's last line is its least useful one. Measured, an iOS
  /// signing failure ends `App failed to start` — and the reason, `No Account
  /// for Team "B7V224LKE4"`, is twenty lines above it, along with the four
  /// steps that fix it. [output] alone reported the summary and threw the cause
  /// away.
  ///
  /// Delimited by the last structured event rather than by matching words in
  /// the text, because `flutter run --machine` emits **nothing structured at
  /// all** for a build failure — no `daemon.logMessage`, no error on
  /// `app.stop`, measured on the log this was written for. The tool's last
  /// event is its final `app.progress`, so everything plain after it is the
  /// failure and nothing else is.
  final List<String> trailing;

  /// `app.started` has arrived: the build is done and the app is up.
  final bool started;

  /// The launcher reported the app stopping.
  final bool stopped;

  /// Reads [path], tolerating everything.
  ///
  /// A log that does not exist yet, is half-written, or has a line from a
  /// tool version this build does not know is not an error — it is a log that
  /// says less than it will in a second.
  static LaunchLog read(String path, {RunFiles files = const DiskRunFiles()}) {
    var text = files.readString(path);
    if (text == null) return const LaunchLog();
    var lines = const LineSplitter().convert(text);
    String? appId, vmService, error, plain;
    var started = false;
    var stopped = false;
    var trailing = <String>[];
    // Spans by id, in the order they opened. `progress` is the innermost still
    // open; a span that finishes leaves rather than lingering.
    var open = <String, String>{};
    var phase = LaunchPhase.starting;
    void reach(LaunchPhase next) {
      if (next.index > phase.index) phase = next;
    }

    for (var line in lines) {
      Map<String, dynamic>? object;
      try {
        object = DaemonProtocol.tryReadLine(line);
      } on FormatException {
        // A line the launcher is still writing can be `[{`-shaped and not yet
        // valid JSON. This method is read repeatedly *while* another process
        // appends to the file, so that is a normal thing to see and not an
        // error — treat it as plain text and let the next read have the whole
        // line.
        object = null;
      }
      if (object == null) {
        // Not an event. Kept as context, never as a verdict — see [output].
        if (line.trim().isNotEmpty) {
          plain = line.trim();
          trailing.add(line.trimRight());
          if (_phaseOf(plain) case var reached?) reach(reached);
        }
        continue;
      }
      // A structured line closes the plain block before it: whatever the tool
      // was narrating is finished, and anything printed after this belongs to
      // what comes next. `app.stop` is the exception because it is emitted
      // *before* the tool's parting words, so honouring it would clear the
      // very block those words are being collected into.
      if (object['event'] != 'app.stop') trailing.clear();
      switch (DaemonProtocol.tryReadEvent(object)) {
        case AppStartEvent(appId: var id):
          appId = id;
          // The tool is up and talking. It has not begun building — that is
          // `Launching … in debug mode`, a plain line further down.
          reach(LaunchPhase.preparing);
        case AppDebugPortEvent(:var wsUri, appId: var id):
          vmService = wsUri.toString();
          reach(LaunchPhase.attaching);
          // Also from here, not only from `app.start`. The two carry the same
          // id, and this one has fewer required fields — so a tool that adds
          // or renames something on `app.start` costs the id nothing.
          appId ??= id;
        case AppStartedEvent():
          started = true;
          reach(LaunchPhase.running);
        case AppStopEvent(error: var why):
          stopped = true;
          if (why != null) error = why;
        case AppProgressEvent(:var id, :var message, :var finished):
          if (finished) {
            open.remove(id);
          } else if (message != null) {
            open[id] = message;
          }
        case DaemonLogMessageEvent(level: MessageLevel.error, :var message):
          error = message;
        case DaemonLogEvent(:var log, error: true):
          error = log;
        default:
          break;
      }
    }
    return LaunchLog(
      appId: appId,
      vmService: vmService,
      progress: open.values.lastOrNull,
      phase: phase,
      error: error,
      output: plain,
      trailing: trailing,
      started: started,
      stopped: stopped,
    );
  }

  /// The milestone a plain line marks, or null for the overwhelming majority
  /// of lines, which mark none.
  ///
  /// Prefixes rather than substrings, and each one is a fixed string a single
  /// emitter writes at a known moment. `Resolving dependencies` is pub's;
  /// `Launching … in debug mode` and `✓ Built …` are the tool's; `Xcode build
  /// done` is the iOS/macOS build's. A rule that matched loose prose would
  /// climb this ladder on a line of somebody's log output.
  static LaunchPhase? _phaseOf(String line) {
    if (line.startsWith('Resolving dependencies') ||
        line.startsWith('Downloading packages')) {
      return LaunchPhase.resolving;
    }
    if (line.startsWith('Got dependencies')) return LaunchPhase.preparing;
    if (line.startsWith('Launching ')) return LaunchPhase.building;
    if (line.startsWith('Xcode build done') ||
        line.startsWith('✓ Built ') ||
        line.startsWith('Built build/')) {
      return LaunchPhase.installing;
    }
    return null;
  }

  /// Why this run is not going to work, or null.
  ///
  /// [error] when the launcher said something structured, and the plain block
  /// only once the launcher is gone or the app stopped before it ever started —
  /// at which point stray sentences are a worse answer than a real error and a
  /// much better one than silence.
  String? failure({required bool launcherAlive}) {
    if (error != null) return error;
    if (started || (launcherAlive && !stopped)) return null;
    var block = _failureBlock();
    return block.isEmpty ? output : block.join('\n');
  }

  /// The one line a row has room for.
  ///
  /// The first line of the block that names something gone wrong, because the
  /// summary line the tool ends on — `App failed to start` — is true of every
  /// failure and tells you which one you have in no case at all.
  String? get failureHeadline {
    if (error != null) return error!.split('\n').first;
    var block = _failureBlock();
    for (var line in block) {
      if (_saysError.hasMatch(line)) return line.trim();
    }
    return block.isNotEmpty ? block.first.trim() : output;
  }

  /// The trailing plain lines, minus the blank ones a terminal used for
  /// spacing, capped so a runaway build log cannot become the error message.
  ///
  /// The head, not the tail. A tool states the fault first and summarises
  /// last — `Failed to build iOS app`, then the Xcode error, then the steps,
  /// then `App failed to start`. Keeping the last N would throw away the cause
  /// and keep the summary, which is the exact bug this block exists to fix. The
  /// cut says what it dropped, and [RunFailure.logPath] points at the whole
  /// thing.
  List<String> _failureBlock() {
    var kept = [
      for (var line in trailing)
        if (line.trim().isNotEmpty) line,
    ];
    if (kept.length <= _maxFailureLines) return kept;
    return [
      ...kept.take(_maxFailureLines),
      '… ${kept.length - _maxFailureLines} more lines in the log',
    ];
  }

  /// Where the launch is right now, or null once it is not launching any more.
  ///
  /// The tool's own words while it is narrating, and the milestone it has
  /// passed when it is not — never a finished span's message, which is the
  /// whole of what this replaced.
  ///
  /// Null for a run that started, stopped or failed, because for those the
  /// question is not *where is it* but *what happened*, which is [summary] and
  /// [failure]. A stage answering `building` about a dead run would be the same
  /// lie in a new place.
  String? get stage {
    if (started || stopped || error != null) return null;
    return progress ?? phase.label;
  }

  /// The launcher's own last word, for a row that has to say something.
  String get summary {
    if (error != null) return error!;
    if (stopped) return 'stopped';
    if (started) return 'running';
    if (vmService != null) return 'started';
    return stage ?? 'starting';
  }
}

/// A run that ended before it ever started, kept after its handle is gone.
///
/// The handle has to go and the reason has to stay. A launcher that never
/// came up is not holding the device, so leaving its handle in the ledger would
/// tell the next person a phone is busy running something that is not there —
/// which is why both the sweeper and a failed `launch` delete it. But that
/// handle was the run's only row, so deleting it bounced you back to the form
/// with nothing said. This is what stands in its place — a rail row in red, and
/// a page with the launcher's own words on it.
///
/// A file beside the log rather than memory. It was memory first, and moving the
/// run list into the rail proved that wrong within the hour: a launch that
/// failed under `fw` was invisible to the GUI and to the next `fw`, so the list
/// it had just been promoted into was the one place it could not appear. Every
/// other fact about a run in this plugin is a file for exactly that reason —
/// there is no coordinator, and the process that asks is rarely the one that
/// knows.
///
/// Named `<key>.failed`, which is the convention the daemon library already
/// uses in this directory, so the run dir's sweeper ages one out with the log
/// it belongs to.
class RunFailure {
  const RunFailure({
    required this.key,
    required this.device,
    required this.entrypoint,
    required this.at,
    this.worktree,
    this.deviceName,
    this.entrypointName,
    this.package,
    this.flavor,
    this.headline,
    this.detail,
    this.logPath,
  });

  /// [runHandleKey], so the address that pointed at the run still points at
  /// the reason it is gone.
  final String key;

  /// Absolute path of the worktree whose launch failed — what scopes a
  /// failure to the rail that owns it. Null in records written before
  /// failures carried one; those show everywhere rather than nowhere.
  final String? worktree;

  final String device;
  final String? deviceName;
  final String entrypoint;
  final String? entrypointName;
  final String? package;
  final String? flavor;

  /// One line naming the fault, for a chip or a row.
  final String? headline;

  /// The launcher's parting words in full, newline-separated.
  final String? detail;

  final String? logPath;

  final DateTime at;

  String get deviceLabel => deviceName ?? device;
  String get entrypointLabel => entrypointName ?? entrypoint;

  /// Matches [RunHandle.runLabel], so the chip does not rename itself when the
  /// run it stands for dies.
  String get runLabel =>
      flavor == null ? entrypointLabel : '$entrypointLabel ($flavor)';

  /// What to say when the log yielded nothing at all — a launcher killed with
  /// `SIGKILL` writes no parting words, and silence is still an answer.
  String get message =>
      detail ?? headline ?? 'The launcher stopped before the app started.';

  Map<String, Object?> toJson() => {
    'key': key,
    if (worktree != null) 'worktree': worktree,
    'device': device,
    if (deviceName != null) 'deviceName': deviceName,
    'entrypoint': entrypoint,
    if (entrypointName != null) 'entrypointName': entrypointName,
    if (package != null) 'package': package,
    if (flavor != null) 'flavor': flavor,
    if (headline != null) 'headline': headline,
    if (detail != null) 'detail': detail,
    if (logPath != null) 'logPath': logPath,
    'at': at.toUtc().toIso8601String(),
  };

  /// Writes `<key>.failed` beside the log. Best effort: an unrecorded failure
  /// is still a failure, and throwing here would replace a legible build error
  /// with a file-system one.
  void write(String runDir) {
    try {
      Directory(runDir).createSync(recursive: true);
      File(p.join(runDir, '$key.failed'))
          .writeAsStringSync(jsonEncode(toJson()));
    } on Object catch (e) {
      _logger.warning('Could not record the failure of $key: $e');
    }
  }

  /// Forgets it, once it has been read.
  static void forget(String runDir, String key) {
    try {
      File(p.join(runDir, '$key.failed')).deleteSync();
    } on FileSystemException {
      // Already gone, or never written. Either way it is forgotten.
    }
  }

  static RunFailure? tryParse(String? text) {
    try {
      var json = jsonDecode(text ?? '');
      if (json is! Map) return null;
      var map = json.cast<String, Object?>();
      return RunFailure(
        key: map['key']! as String,
        worktree: map['worktree'] as String?,
        device: map['device']! as String,
        deviceName: map['deviceName'] as String?,
        entrypoint: map['entrypoint']! as String,
        entrypointName: map['entrypointName'] as String?,
        package: map['package'] as String?,
        flavor: map['flavor'] as String?,
        headline: map['headline'] as String?,
        detail: map['detail'] as String?,
        logPath: map['logPath'] as String?,
        at: DateTime.parse(map['at']! as String),
      );
    } on Object {
      // Torn write, older schema, deleted meanwhile — like a handle that
      // cannot be read, one that cannot be read does not exist.
      return null;
    }
  }
}

/// The `*.failed` records in [runDir], newest first.
///
/// Reads files and nothing else, so [PluginCore.computeAll] may call it.
/// Anything older than [maxAge] is skipped but *not* deleted: deleting is the
/// run dir's sweeper's job, which already ages `<key>.failed` out on the same
/// rule as the log it belongs to. A scan that quietly wrote would be a scan
/// that could not be called from where this one is.
List<RunFailure> scanRunFailures(
  String runDir, {
  Duration maxAge = const Duration(hours: 12),
  RunFiles files = const DiskRunFiles(),
}) {
  var failures = <RunFailure>[];
  var now = DateTime.now();
  for (var path in files.list(runDir)) {
    var name = p.basename(path);
    if (!name.startsWith('app-') || !name.endsWith('.failed')) continue;
    var failure = RunFailure.tryParse(files.readString(path));
    if (failure == null) continue;
    // Old enough to be history rather than news. Left on disk for the sweeper.
    if (now.difference(failure.at) > maxAge) continue;
    failures.add(failure);
  }
  failures.sort((a, b) => b.at.compareTo(a.at));
  return failures;
}

/// Brings [handle] up to date from its log, rewriting the file when it learns
/// something.
///
/// Returns the handle as it now stands — the same object when the log had
/// nothing new. Any process may call this; the one that launched the app has
/// no special standing, and usually is not running any more.
RunHandle refreshFromLog(
  RunHandle handle, {
  RunFiles files = const DiskRunFiles(),
}) {
  var path = handle.logPath;
  if (path == null) return handle;
  // **The log wins, even when the handle already has an answer.** This used to
  // return early once both fields were set, which made a wrong value permanent:
  // a handle that started life with a stale URI could never be corrected, and
  // the app looked dead to everything that probed it. The early return also
  // saved nothing — `_probeAll` reads this same file for every handle on every
  // pass regardless, to show the progress line.
  var log = LaunchLog.read(path, files: files);
  if (log.vmService == null && log.appId == null) return handle;
  if (log.vmService == handle.vmService && log.appId == handle.appId) {
    return handle;
  }
  var updated = handle.withService(
    vmService: log.vmService ?? handle.vmService,
    appId: log.appId ?? handle.appId,
  );
  updated.save();
  _logger.fine('Handle ${handle.handlePath} learned ${log.vmService}');
  return updated;
}

/// Waits for [handle]'s app to come up, or for the launcher to die trying.
///
/// Polls the log rather than holding a pipe, for the same reason the log
/// exists at all: whoever asks this question is not necessarily the process
/// that started the app, and on a second `fw` it certainly is not.
Future<(RunHandle, LaunchLog)> awaitLaunch(
  RunHandle handle,
  Duration timeout, {
  Duration poll = const Duration(milliseconds: 250),
  void Function(String line)? onProgress,
}) async {
  var deadline = DateTime.now().add(timeout);
  var current = handle;
  String? said;
  while (true) {
    current = refreshFromLog(current);
    var log = LaunchLog.read(current.logPath ?? '');
    // The log is read here every quarter second either way, and its stage is
    // the only narration a cold build has. Handing each new one to the caller
    // costs a comparison and is the difference between a ninety-second silence
    // and a build saying where it is.
    //
    // The stage rather than the raw progress line, so the minutes before the
    // tool says anything structured are narrated too — `fw` and an agent used
    // to watch a blank space through the whole of pub resolution.
    if (log.stage case var line? when line != said) {
      said = line;
      onProgress?.call(line);
    }
    // Only a started app is worth returning on the spot. Every other way out
    // of here is a failure, and a failure's reason is still being written.
    if (log.started) return (current, log);
    if (log.stopped ||
        log.error != null ||
        !isProcessAlive(current.launcherPid)) {
      return (current, await _readWhenSettled(current, poll));
    }
    if (DateTime.now().isAfter(deadline)) return (current, log);
    await Future<void>.delayed(poll);
  }
}

/// Reads [handle]'s log once its launcher has stopped adding to it.
///
/// A launcher is not finished talking when it says it stopped. `app.stop`
/// arrives *before* the tool prints why — measured on an iOS signing failure,
/// where everything that explains it comes after that event. Returning at the
/// event caught the log mid-sentence, and worse, caught the launcher still
/// alive, which made `failure(launcherAlive: true)` answer null and turned a
/// failed launch into a bare `stopped` with no reason attached to it.
///
/// Bounded, because this is only ever tidying up an answer we already have: if
/// the launcher lingers, the log as it stands is still returned.
Future<LaunchLog> _readWhenSettled(
  RunHandle handle,
  Duration poll, {
  Duration grace = const Duration(seconds: 3),
}) async {
  var until = DateTime.now().add(grace);
  while (isProcessAlive(handle.launcherPid) && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(poll);
  }
  // One more poll after it goes, for the lines already in the pipe.
  await Future<void>.delayed(poll);
  return LaunchLog.read(handle.logPath ?? '');
}
