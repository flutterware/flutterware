import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart'
    show DartIOExtension, HttpProfileRequest, HttpProfileRequestRef, RPCError;

import '../../run/channel_client.dart';
import '../../run/beat_tracker.dart';
import '../../run/connection.dart';
import '../../run/define_scripts.dart';
import '../../run/entrypoint_knobs.dart';
import '../../run/guest_entrypoint.dart';
import '../../run/drive_session.dart';
import '../../run/entrypoints.dart';
import '../../run/flavors.dart';
import '../../run/device/device_settings.dart';
import '../../run/handle.dart';
import '../../inspect/lens.dart';
import '../../inspect/screen_read.dart';
import '../../run/inspect.dart';
import '../../run/refusal.dart';
import '../../run/run_files.dart';
import '../../run/run_sources.dart';
import '../../run/inventory.dart';
import '../../run/journal.dart';
import '../../run/launch.dart';
import '../../run/logs.dart';
import '../../run/native/native_driver.dart';
import '../../run/native/native_logs.dart';
import '../../run/native/native_session.dart';
import '../../run/network_tracker.dart';
import '../../run/panel_client.dart';
import '../../shell/worktree_discovery.dart';
import '../../utils/parameter_knobs.dart';
import '../../utils/daemon/device.dart';
import '../../utils/run_dir.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'run_address.dart';
import 'run_results.dart';
import 'previews_core.dart' show PreviewsCore;

/// The registered id — also what `tool/flutterware.dart` declares.
const runPluginId = 'flutterware.run';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Which devices exist, which are already running something, and launching '
    "one of the project's entry points onto one — then reloading, driving and "
    'observing the app that comes up.';

/// How many dead runs to keep the reason for. Enough to cover a morning of
/// fighting one signing problem across two devices, and far short of a list too
/// long to read.
const _maxRememberedFailures = 8;

/// Which devices exist, which are already running something — from any
/// worktree of the repo, not just this one — and launching an entry point onto
/// one.
///
/// See `docs/superpowers/specs/2026-07-31-app-launcher-cockpit-brainstorm.md`.
///
/// Two sources, and the difference between them is the whole design:
///
/// - **Devices** come from a `flutter daemon`, which costs seconds to start
///   and answers about the machine. Whoever holds one publishes what it sees
///   to `devices.json`, and a cold `fw` reads that file **and says how old it
///   is**. A run is a fact that happened; it gets old, it does not become
///   wrong.
/// - **Occupancy** comes from the `app-*.json` handles in the run dir. There is
///   no coordinator: a run announces itself in a file, anything that wants to
///   know connects to find out whether it is still there, and a handle nothing
///   answers is deleted by the process that noticed.
///
/// A launch is the third: a detached `flutter run --machine` whose output goes
/// to a log file beside its handle. Nothing waits on it, and the handle is a
/// *cache* of what the log says — so any process can bring one up to date and
/// then drive the app, whether or not it was there when the app started.
///
/// Holds to the [PluginCore.computeAll] budget: this class reads files and
/// nothing else until the panel is mounted ([track]) or an action is named.
/// Sockets, subprocesses and the daemon live behind both.
class RunCore extends PluginCore {
  RunCore(super.host, {this.sources = const RunSources.live()});

  /// Where this core reads runs from — the machine, or a recording.
  final RunSources sources;

  /// The run's files, through [sources]. Everything the panel shows about a
  /// run that is not its live screen is read from here.
  RunFiles get files => sources.files;

  /// Why nothing can change here — see [RunSources.readOnly].
  String? get readOnly => sources.readOnly;

  /// Where one run's screen is — the same segments the panel reads back.
  Address addressFor(RunHandle handle) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: runSegments(
      runHandleKey(handle.worktree, handle.device, handle.entrypoint),
    ),
  );

  /// Where the ledger and the device cache live. A seam for tests, which point
  /// it at a temp dir rather than the developer's real run dir.
  @visibleForTesting
  static String Function() runDirProvider = flutterwareRunDir;

  /// Where this core's run state lives — what production reads, so a test that
  /// redirects [runDirProvider] redirects everything rather than most things.
  String get runDir => sources.runDir ?? runDirProvider();

  DeviceCache? _cache;
  DeviceDaemon? _daemon;
  var _scanned = false;
  var _tracking = false;
  StreamSubscription<void>? _daemonChanges;
  Timer? _probeTimer;

  /// Handles as the last scan read them, and what the last probe found for
  /// each — keyed by handle path, which is what identifies a run on disk.
  List<RunHandle> _handles = const [];
  final _probes = <String, RunProbe>{};

  /// What to show: the live daemon's list when there is one, the cache
  /// otherwise. They are the same shape on purpose.
  List<DaemonDevice> get devices =>
      _daemon?.devices ?? _cache?.devices ?? const [];

  /// True when this process holds a daemon, so [devices] is a reading rather
  /// than a recollection.
  bool get isLive => _daemon != null;

  /// True while a device list is on its way and has not arrived.
  ///
  /// [_tracking] is the whole point of this, and leaving it out cost every
  /// `fw capture` on this repo its entire timeout. A capture process opens
  /// the shell, goes to one panel and photographs it; it never mounts the Run
  /// panel, so it never calls [track], so no daemon is ever started and
  /// [devices] stays empty forever. The condition this replaces —
  /// `!isLive && devices.isEmpty` — read that as "still finding devices" and
  /// held the window busy until the wait gave up. Measured: 300 of the 360
  /// seconds a cold capture took, waiting for a scan nobody had started, to
  /// photograph a panel that has nothing to do with devices.
  ///
  /// So: busy only while something is actually looking. Nothing in flight is
  /// not a slow answer, it is no question.
  ///
  /// It ends when [_startDaemon] does, either way — a daemon or an error. The
  /// gap between the daemon coming up and its first `device.added` is not
  /// covered, and that is deliberate: the flutter daemon has no "here is the
  /// initial list" event, only a stream of additions, so any wait for a first
  /// device is a wait with no guaranteed end. A capture that catches the list
  /// one frame early is a bounded imprecision; the alternative was an
  /// unbounded one.
  bool get isFindingDevices =>
      _tracking && !isLive && _daemonError == null && readOnly == null;

  /// The runs currently announced, newest first — every worktree's, because a
  /// device held by another checkout is exactly the case this answers.
  List<RunHandle> get handles => _handles;

  /// The runs this worktree launched — what the rail lists and what the panel
  /// falls back to when the address names no run.
  ///
  /// The split matters: [handles] stays every worktree's because *occupancy*
  /// is a machine question, but the rail's rows are subjects you can drive,
  /// and another checkout's app is not one of yours. It is reached through the
  /// desk instead, which jumps to the worktree holding it.
  List<RunHandle> get ownHandles => [
    for (var handle in _handles)
      if (isMine(handle)) handle,
  ];

  /// Whether this worktree launched [handle]. Canonicalized, because the
  /// handle was written by another process whose spelling of the path — a
  /// symlink, a trailing separator — is not ours to assume.
  bool isMine(RunHandle handle) => _isOwnPath(handle.worktree);

  bool _isOwnPath(String path) =>
      p.canonicalize(path) == p.canonicalize(host.worktree.path);

  RunProbe? probeOf(RunHandle handle) =>
      handle.handlePath == null ? null : _probes[handle.handlePath];

  /// What [handle]'s launcher log said at the last probe.
  ///
  /// Read on the probe loop rather than on demand, because a panel that read a
  /// file every time it built would read it sixty times a second while an
  /// animation ran.
  LaunchLog? logOf(RunHandle handle) =>
      handle.handlePath == null ? null : _logs[handle.handlePath];

  final _logs = <String, LaunchLog>{};

  /// True while a run this worktree launched has not come up yet — a build in
  /// flight.
  ///
  /// Own runs only: this gates `busyWith`, and a capture of *this* worktree
  /// must not wait out another checkout's ninety-second Android build.
  bool get isStarting => ownHandles.any(
    (handle) => handle.vmService == null && !(logOf(handle)?.stopped ?? false),
  );

  /// Declared packages, filtered to those the workspace knows about.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  /// The entry points of [path]: what the config declared, or what a scan of
  /// its `lib/` found. Cached, because both are file reads and the report asks
  /// on every keystroke.
  List<EntrypointRef> entrypointsFor(String path) =>
      _entrypoints[path] ?? const [];

  final _entrypoints = <String, List<EntrypointRef>>{};

  /// The flavors [package] declares for the platform [device] describes, or
  /// null where it declares nothing — `RunPackage.flavors`, looked up the way
  /// every per-platform declaration is (concrete key, then shorthand, then
  /// the daemon category for a device that named no platform).
  ///
  /// The null/empty distinction is the point: null is "unknown, check
  /// nothing", empty is "this platform has no flavors" — the declared
  /// equivalent of what web is by nature.
  List<String>? flavorVocabularyFor(String package, String? device) {
    var target = devices
        .where((candidate) => candidate.id == device)
        .firstOrNull;
    return lookupByPlatform(
      _flavorVocabularies[package] ?? const {},
      platformType: target?.platformType,
      category: target?.category,
    );
  }

  /// [package]'s declared flavors, as written — for the report, which echoes
  /// the author's word rather than a per-device expansion.
  Map<RunPlatform, List<String>> flavorVocabularyOf(String package) =>
      _flavorVocabularies[package] ?? const {};

  final _flavorVocabularies = <String, Map<RunPlatform, List<String>>>{};

  /// [path]'s `flutter: default-flavor:`, when its pubspec declares one.
  ///
  /// Cached beside the entry points because it is read the same way, at the
  /// same moment, and answers the same question: what would be built with
  /// nothing filled in.
  String? defaultFlavorFor(String path) => _defaultFlavors[path];

  final _defaultFlavors = <String, String?>{};

  /// What [entry]'s `main` declares it takes, and the imports a wrapper needs.
  ///
  /// Cached on first ask and dropped by [computeAll], for the reason
  /// [definesReadBy] gives: a knob list that outlived the signature it was read
  /// from is the one wrong answer worth paying to avoid.
  EntrypointKnobs knobsReadBy(String package, String entrypoint) =>
      _entrypointKnobs.putIfAbsent(
        '$package|$entrypoint',
        () => scanEntrypointKnobs(
          packageRoot: host.workspace.absolutePathOf(package),
          entrypoint: entrypoint,
          files: files,
        ),
      );

  final _entrypointKnobs = <String, EntrypointKnobs>{};

  /// The knobs to offer for [entry] — the signature's, annotated by the
  /// config's.
  ///
  /// No authority rule, because the two halves answer different questions.
  /// A signature cannot be wrong about what its own `main` accepts, so it is
  /// the list; the config only says what a signature cannot — a computed value,
  /// a human label, options for a type that cannot enumerate itself. This is
  /// why the authority rule the deleted define scan needed does not arise.
  ///
  /// A declaration naming a parameter that is not there comes last, with
  /// `read: null`, so it can be reported: the control would appear and do
  /// nothing, which is indistinguishable from a broken feature.
  List<({ParameterKnob? read, Knob? declared})> knobsFor(
    String package,
    EntrypointRef entry,
  ) {
    var read = knobsReadBy(package, entry.path).knobs;
    var declared = {for (var knob in entry.knobs) knob.name: knob};
    return [
      for (var knob in read) (read: knob, declared: declared[knob.name]),
      for (var knob in entry.knobs)
        if (!read.any((parameter) => parameter.name == knob.name))
          (read: null, declared: knob),
    ];
  }

  /// What [entry] builds with when nobody overrides it, and where that came
  /// from — its per-platform pairing when [device]'s platform is in it, its
  /// own declaration, or [package]'s `flutter: default-flavor:`.
  ///
  /// One chain, used by the panel and by the `launch` action, because a form
  /// that pre-fills `dev` and an agent that passes nothing must build the same
  /// thing. They did not before: the action stopped at the entry point's
  /// declaration and never looked at the pubspec.
  ///
  /// [device] is an id from the cache; one the cache has never mentioned is
  /// still launchable (see `_checkDevice`) and resolves without the pairing,
  /// as does no device at all — which is what the `entrypoints` report asks,
  /// since its answer describes the entry point rather than a launch.
  ({String? flavor, FlavorSource source}) flavorFor(
    String package,
    EntrypointRef entry, {
    String? device,
  }) {
    var target = devices
        .where((candidate) => candidate.id == device)
        .firstOrNull;
    return resolveFlavor(
      entrypointFlavor: entry.flavor,
      packageDefault: defaultFlavorFor(package),
      byPlatform: entry.flavorByPlatform,
      platformType: target?.platformType,
      category: target?.category,
    );
  }

  /// The devices [entry] can run on, in the order every surface lists them.
  ///
  /// The whole list when the entry point declared no platforms, which is the
  /// ordinary case and has to stay free.
  List<DaemonDevice> devicesFor(EntrypointRef entry) => [
    for (var device in devices)
      if (device.allowedBy(entry)) device,
  ];

  /// What to call [device]'s platform in a sentence — `macos`, `ios`, or the
  /// id itself for a device the cache has not described.
  String platformLabelFor(String? device) {
    var target = devices
        .where((candidate) => candidate.id == device)
        .firstOrNull;
    return target?.platformType ?? target?.category ?? device ?? 'this device';
  }

  /// The platform [device] builds for, or null when this build cannot say.
  ///
  /// Distinct from [platformLabelFor], which falls back to the category and
  /// then to the device id so that a *sentence* always has a noun. That is the
  /// right answer for prose and the wrong one for a caller that is going to
  /// **reason** about the platform — how long its builds take, say — because
  /// an id is not a platform and `575104B7-6AB9-42BA-82B6-351FC0DA2921` is not
  /// a word to put in front of the reader.
  ///
  /// Null is reachable and not rare: the list is the live daemon's when there
  /// is one and the cache's otherwise, so a simulator that has since been shut
  /// down, and every frame before [computeAll] has read the cache, answer
  /// nothing here.
  String? platformOf(String? device) => devices
      .where((candidate) => candidate.id == device)
      .map((candidate) => candidate.platformType)
      .firstOrNull;

  /// True when [path]'s entry points came from `tool/flutterware.dart` rather
  /// than from scanning.
  bool isDeclared(String path) =>
      entrypointsFor(path).any((entry) => entry.declared);

  /// This machine's addresses on the local network — what a phone has to be
  /// told, since `localhost` on a phone is the phone — each with the interface
  /// it was found on.
  ///
  /// Cached from [computeAll] because a define's offered values are built inside
  /// [report], which may not do I/O of any kind.
  List<({String interface, String address})> get hostAddresses =>
      _hostAddresses;
  var _hostAddresses = <({String interface, String address})>[];

  /// What each [ScriptSource] said last time it was asked, by script and args.
  ///
  /// Not filled by [computeAll], unlike everything else here, because
  /// asking means running a process and `computeAll` may not. Filled by
  /// [resolveScriptSources], which the surfaces that chose to pay for it call:
  /// the `entrypoints` action, the panel on mount, and every launch.
  ///
  /// Not keyed on the script's content, deliberately. The answer changes
  /// when the dev stack goes up or down, which does not touch the file — a
  /// cache that invalidated on the source would hold a port from before the
  /// stack moved and be confident about it.
  final _scriptOutcomes = <String, ScriptOutcome>{};

  /// Keyed by script and args, separated by a character no argument can
  /// contain: `args: ['a b']` and `args: ['a', 'b']` are two different
  /// questions and must not share an answer.
  static String _scriptKey(ScriptSource source) =>
      [source.path, ...source.args].join('\u0000');

  ScriptOutcome? outcomeOf(ScriptSource source) =>
      _scriptOutcomes[_scriptKey(source)];

  /// Machine-global on purpose — see [handles] vs [ownHandles] for where the
  /// worktree line is drawn.
  List<RunHandle> _scanHandles() => scanRunHandles(runDir, files: files);

  @override
  Future<void> computeAll() async {
    await files.ready;
    _cache = DeviceCache.read(runDir, files: files);
    _handles = _scanHandles();
    _failures = {
      for (var failure in scanRunFailures(runDir, files: files))
        failure.key: failure,
    };
    for (var path in packages) {
      var root = host.workspace.absolutePathOf(path);
      var declared = declaredEntrypoints(_configFor(path));
      _entrypoints[path] = declared.isNotEmpty
          ? declared
          : scanEntrypoints(root);
      _defaultFlavors[path] = defaultFlavorOf(root, files: files);
      _flavorVocabularies[path] = declaredFlavors(_configFor(path)['flavors']);
    }
    // Dropped so the next ask re-reads sources that may have moved since.
    _entrypointKnobs.clear();
    // This machine's addresses, which a recording's machine is not.
    if (readOnly == null) _hostAddresses = await _readHostAddresses();
    _scanned = true;
  }

  Map<String, Object?> _configFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] == path) return config;
    }
    return const {};
  }

  /// The IPv4 addresses of this machine's real interfaces, each named by the
  /// interface it came from.
  ///
  /// A syscall rather than a socket, and it is here rather than behind an
  /// action because "which address can the phone reach me at" is the answer a
  /// define has to offer *before* the launch.
  ///
  /// No attempt to guess which one is *the* address. Nothing here can tell a
  /// Wi-Fi address from a VPN's without asking the network, which is precisely
  /// what this must not do — so the interface name goes out with each one and
  /// the reader decides.
  static Future<List<({String interface, String address})>>
  _readHostAddresses() async {
    try {
      var interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      return [
        for (var interface in interfaces)
          for (var address in interface.addresses)
            (interface: interface.name, address: address.address),
      ];
    } on Object {
      // No permission, no interfaces, an OS that refuses — none of it is worth
      // failing a report over. The define simply offers less.
      return const [];
    }
  }

  /// Starts the daemon and keeps probing the ledger. Idempotent; called by the
  /// panel on mount.
  ///
  /// Spawns a process, which [computeAll] may not — the panel being open is a
  /// caller who chose to pay for a live list.
  void track() {
    if (_tracking || isDisposed) return;
    _tracking = true;
    unawaited(
      computeAll().then((_) {
        notifyChanged();
        // **The first probe goes here, after the handles exist.** It used to
        // sit in the block below, which runs while `computeAll` is still on
        // its way — so it probed an empty `_handles` and answered nothing,
        // and `_probes` then stayed empty until [_scheduleProbe]'s timer.
        //
        // That is five seconds, and the panel spends them rendering every
        // announced run with a null probe: an app that has been up for hours
        // draws as a launch in flight, complete with a spinner and — since
        // the launching pane started measuring — an amber sentence about the
        // build being overdue. Rebuilding *here*, one continuation after the
        // handles land, is the whole fix.
        if (debugLive && !isDisposed) unawaited(_probeAll());
      }),
    );
    // A recording is probed once, above, and then nothing moves under it.
    if (debugLive && readOnly == null) {
      // Same bargain as the daemon: the form is about to show what each define
      // will be, and it cannot show a computed one without asking for it.
      unawaited(resolveScriptSources().then((_) => notifyChanged()));
      unawaited(_startDaemon());
      _scheduleProbe();
    }
  }

  /// False in a widget test. Mounting the panel starts a `flutter daemon` and
  /// a repeating probe, which is right in the app and is a subprocess and a
  /// pending timer in a test — neither of which a pumped panel can settle.
  @visibleForTesting
  static bool debugLive = true;

  /// Polls fast while something is building and slowly otherwise.
  ///
  /// A cold build's only narration is the launcher's progress line, and five
  /// seconds between readings makes a ninety-second build look like a frozen
  /// panel. Once everything is up there is nothing to watch that closely.
  void _scheduleProbe() {
    if (isDisposed || !_tracking) return;
    _probeTimer?.cancel();
    _probeTimer = Timer(
      isStarting ? const Duration(seconds: 1) : const Duration(seconds: 5),
      () {
        _handles = _scanHandles();
        unawaited(_probeAll().then((_) => _scheduleProbe()));
      },
    );
  }

  /// Takes this core's one lease on the shared daemon, starting it if it is not
  /// already up.
  ///
  /// One lease per core, however many times this is called: [track] and the
  /// `devices --refresh` action both want a daemon, and counting each of them
  /// would leave the process alive after the core that asked for it is gone.
  Future<DeviceDaemon> _acquireDaemon() async {
    var existing = _daemon;
    if (existing != null) return existing;
    var daemon = await DeviceDaemon.acquire(
      host.workspace.flutterSdk,
      runDir: runDir,
    );
    if (isDisposed || _daemon != null) {
      // Disposed while starting, or another call won the race — either way this
      // lease has no holder and must go back.
      daemon.release();
      return _daemon ?? daemon;
    }
    _daemon = daemon;
    _daemonError = null;
    return daemon;
  }

  Future<void> _startDaemon() async {
    try {
      var daemon = await _acquireDaemon();
      if (isDisposed) return;
      _daemonChanges = daemon.changes.listen((_) => notifyChanged());
      notifyChanged();
    } on Object catch (e) {
      if (isDisposed) return;
      _daemonError = '$e';
      notifyChanged();
    }
  }

  String? _daemonError;

  var _failures = <String, RunFailure>{};

  /// Runs that ended before they started, newest first.
  ///
  /// Keyed by [runHandleKey] and replaced rather than accumulated, because that
  /// key is stable across relaunch: trying the same thing again should correct
  /// the reason it failed, not stack a second copy of it underneath.
  ///
  /// Read from `*.failed` files, so a launch that failed under `fw` is in the
  /// GUI's rail and vice versa — the same rule as every other fact about a run
  /// here.
  List<RunFailure> get failures =>
      _failures.values.toList()..sort((a, b) => b.at.compareTo(a.at));

  /// The failures this worktree's launches recorded, for the rail.
  ///
  /// A record with no worktree — written before failures carried one — is
  /// kept everywhere rather than shown nowhere.
  List<RunFailure> get ownFailures => [
    for (var failure in failures)
      if (failure.worktree == null || _isOwnPath(failure.worktree!)) failure,
  ];

  RunFailure? failureFor(String key) => _failures[key];

  /// Notes why a run is gone, so the panel has something to show where the
  /// chip used to be. See [RunFailure] for why the handle cannot simply stay.
  @visibleForTesting
  void recordFailure(RunHandle handle, LaunchLog log) {
    if (_failures.length >= _maxRememberedFailures &&
        !_failures.containsKey(handle.key)) {
      var oldest = failures.last;
      _failures.remove(oldest.key);
      RunFailure.forget(runDir, oldest.key);
    }
    var failure = RunFailure(
      key: handle.key,
      worktree: handle.worktree,
      device: handle.device,
      deviceName: handle.deviceName,
      entrypoint: handle.entrypoint,
      entrypointName: handle.entrypointName,
      package: handle.package,
      flavor: handle.flavor,
      headline: log.failureHeadline,
      detail: log.failure(launcherAlive: false),
      logPath: handle.logPath,
      at: DateTime.now(),
    );
    _failures[handle.key] = failure;
    failure.write(runDir);
  }

  /// Forgets a failure, once it has been read.
  void dismissFailure(String key) {
    RunFailure.forget(runDir, key);
    if (_failures.remove(key) != null) notifyChanged();
  }

  /// Probes every announced run and deletes the handles nothing answers.
  ///
  /// Returns how many were swept. A dead handle is one where neither the app
  /// nor its launcher is there — a live launcher with a silent app is a *cold
  /// build*, which on Android takes a minute and a half, and sweeping it would
  /// free a device that is very much in use.
  Future<int> _probeAll() async {
    if (readOnly != null) return _probeRecorded();
    // Top each handle up from its launcher's log first. The log is the source
    // of truth about a run and the handle is a cache of it, so a run launched
    // by somebody else — another `fw`, a GUI that has since closed — becomes
    // connectable here without this process ever having watched it start.
    var handles = [
      for (var handle in _handles) refreshFromLog(handle, files: files),
    ];
    _handles = handles;
    _failures = {
      for (var failure in scanRunFailures(runDir, files: files))
        failure.key: failure,
    };
    var probes = await Future.wait([
      for (var handle in handles) sources.apps.probe(handle),
    ]);
    if (isDisposed) return 0;
    var swept = 0;
    var alive = <RunHandle>[];
    for (var (index, handle) in handles.indexed) {
      var probe = probes[index];
      if (probe.isDead) {
        // Read before deleting, and only for a run that never started: an app
        // that ran and was stopped is not a failure and must leave nothing
        // behind, or every ordinary `stop` would post an obituary.
        var log = LaunchLog.read(handle.logPath ?? '', files: files);
        if (!log.started) recordFailure(handle, log);
        handle.delete();
        _probes.remove(handle.handlePath);
        _logs.remove(handle.handlePath);
        swept++;
        continue;
      }
      if (handle.handlePath != null) {
        _probes[handle.handlePath!] = probe;
        if (handle.logPath case var path?) {
          _logs[handle.handlePath!] = LaunchLog.read(path, files: files);
        }
      }
      alive.add(handle);
    }
    _handles = alive;
    notifyChanged();
    return swept;
  }

  /// A recording's probe: what the app answers, once, with nothing to top up
  /// from a log that is not being written and nothing to sweep.
  Future<int> _probeRecorded() async {
    for (var handle in _handles) {
      var path = handle.handlePath;
      if (path == null) continue;
      _probes[path] = await sources.apps.probe(handle);
      if (handle.logPath case var log?) {
        _logs[path] = LaunchLog.read(log, files: files);
      }
    }
    if (!isDisposed) notifyChanged();
    return 0;
  }

  @override
  PluginReport get report {
    var busy = {for (var handle in _handles) handle.device};
    return PluginReport(
      id: host.id,
      label: host.label,
      description: _pluginDescription,
      status: _status,
      badge: _daemonError != null
          ? const StatusBadge.dot(Tone.error)
          : ownHandles.isNotEmpty
          ? StatusBadge.count(ownHandles.length, tone: Tone.good)
          : StatusBadge.none,
      // **Runs, not devices.** A child's id becomes the first address segment
      // (`_childAddress`), so these have to be the things the panel can be
      // pointed at — and since the rebuild the panel's subjects are runs. A
      // device list in the rail would have been a row of links to nowhere.
      //
      // Devices have not gone anywhere: they are the desk, which the panel
      // renders when nothing is running and whose button in the shell's
      // chrome carries the busy count.
      //
      // **This worktree's runs, not the machine's.** The unfiltered ledger
      // put every checkout's runs in every rail, indistinguishable at a
      // glance and first in line for the panel's fallback — opening Run in
      // one worktree landed you on another's app. Occupancy stays global
      // ([handles], the desk, the `apps` action); the rows do not. The badge
      // counts the rows, so it cannot claim runs the rail will not show.
      children: [
        for (var handle in ownHandles)
          PluginChild(
            id: handle.key,
            label: '${handle.runLabel} · ${handle.deviceLabel}',
            status: _handleStatus(handle),
          ),
        // Runs that never started, listed with the live ones. They were in the
        // panel's chip row and nowhere else, which was the wrong half: the rail
        // is the list, so a launch that failed has to be in it or it has
        // vanished again.
        for (var failure in ownFailures)
          PluginChild(
            id: failure.key,
            label: '${failure.runLabel} · ${failure.deviceLabel}',
            status: Status.error(failure.headline ?? 'failed'),
          ),
      ],
      teardown: _teardown,
      actions: [
        PluginAction(
          'devices',
          'Devices',
          returns: RunDevicesResult,
          description:
              'Every device an app could run on, with what is already running '
              'on it and from which worktree. Reads a cached list and says how '
              'old it is; pass refresh to start a flutter daemon and take a '
              'fresh one, which costs a few seconds.',
          parameters: const [
            ActionParameter(
              'refresh',
              'Refresh',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Ask a live flutter daemon instead of reading the cache',
            ),
          ],
        ),
        PluginAction(
          'apps',
          'Running apps',
          returns: RunAppsResult,
          description:
              "Every app announcing itself under this machine's run "
              'directory, from any worktree, probed: whether the app still '
              'answers, whether the launcher that can hot-reload it is still '
              'alive, and where its log is. Handles nothing answers are '
              'deleted.',
        ),
        PluginAction(
          'entrypoints',
          'Entry points',
          returns: RunEntrypointsResult,
          description:
              'The main() files each package can be launched from, with the '
              'dart-defines each one declares and the values worth offering '
              'for them. Declared in tool/flutterware.dart when the project '
              'says so, found by scanning lib/ when it does not.',
          parameters: [_packageParameter],
        ),
        PluginAction(
          'launch',
          'Launch',
          returns: RunLaunchResult,
          description:
              'Builds an entry point and runs it on a device. The launcher is '
              'detached and its output goes to a log file, so this can return '
              'while the app keeps running. A cold build is slow — about ten '
              'seconds warm on Android and a minute and a half cold — and on a '
              'wireless device it can stall on an OS permission dialog that '
              'nobody is looking at.',
          parameters: [
            ActionParameter(
              'device',
              'Device',
              kind: ActionParameterKind.choice,
              description: 'Which device to run on',
              options: [
                for (var device in devices)
                  ActionOption(device.id, label: device.displayName),
              ],
            ),
            _packageParameter,
            ActionParameter(
              'entrypoint',
              'Entry point',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'The name or the package-relative path, as `entrypoints` '
                  'reports them. Two entry points may share a path — '
                  'declaring one file several times is how one app is run '
                  'against several configurations — so the name is the '
                  "selector that always separates them. The package's only "
                  'entry point when omitted.',
              // The name, not the path: a path is not unique, and two options
              // carrying the same value is a picker whose rows do the same
              // thing. `_resolveEntrypoint` takes either, so a caller already
              // passing a path keeps working.
              options: [
                for (var path in packages)
                  for (var entry in entrypointsFor(path))
                    ActionOption(entry.name),
              ],
            ),
            const ActionParameter(
              'flavor',
              'Flavor',
              required: false,
              description:
                  'The `--flavor` to build. Defaults to what the entry point '
                  'declares. A project with product flavors cannot be built '
                  'without one at all — unlike a define, leaving it out is a '
                  'build failure rather than a default value.',
            ),
            const ActionParameter(
              'dartDefines',
              'Dart defines',
              required: false,
              description:
                  '`--dart-define`s to pass through verbatim: '
                  '`NAME=value,NAME=value`, or a JSON object. An escape hatch, '
                  'not the way to configure a launch — nothing offers them, '
                  'checks them or remembers them, and changing one costs a '
                  'full rebuild. Use `knobs` for anything you switch while '
                  'working. This is for the three a knob cannot reach: a '
                  'define read by a package you do not own, one the native '
                  'build consumes, and anything needed before the Dart entry '
                  'point runs.',
            ),
            const ActionParameter(
              'knobs',
              'Knobs',
              required: false,
              description:
                  'Values to pass the entry point, `name=value,name=value` or '
                  'a JSON object. These are the optional named parameters of '
                  "its `main`, so `entrypoints` lists them with each one's "
                  'type, default and options. Passed as arguments in the '
                  'generated wrapper rather than compiled in, so changing one '
                  'costs a hot restart instead of a rebuild — which is what '
                  'makes a knob the right home for a value you switch while '
                  'working, and a define the right home for one that differs '
                  'per shipped artifact.',
            ),
            const ActionParameter(
              'wait',
              'Wait',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'true',
              description:
                  'Wait for the app to come up before answering. Off returns '
                  'as soon as the launcher is spawned, and `apps` is how you '
                  'find out how it went.',
            ),
            const ActionParameter(
              'timeout',
              'Timeout',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '300',
              description:
                  'Seconds to wait. A timeout is not a failure — the build '
                  'carries on and the answer says how far it got.',
            ),
          ],
        ),
        PluginAction(
          'reload',
          'Hot reload',
          returns: RunControlResult,
          description:
              'Applies edited sources to a running app, in a few hundred '
              'milliseconds. Needs the `flutter run` that launched it to still '
              'be alive: hot reload is registered by the tool, not by the app, '
              'so it goes away with it while the app keeps running.',
          parameters: _appSelector,
        ),
        PluginAction(
          'restart',
          'Hot restart',
          returns: RunControlResult,
          description:
              'Restarts a running app from its main(), in about a second, '
              'without rebuilding or reinstalling. Same requirement as reload: '
              'the launcher has to be alive.',
          parameters: _appSelector,
        ),
        PluginAction(
          'setKnobs',
          'Set knobs',
          returns: RunControlResult,
          description:
              "Changes what a running app's main() was called with, and hot "
              'restarts it — a rewrite of one generated file rather than a '
              'build, so it costs a restart (about a second) instead of a '
              'relaunch (half a minute). The app starts again from its first '
              'screen, because a value reaches it only through main(). What '
              'each entry point takes, with its type and options, is '
              '`entrypoints`.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'knobs',
              'Knobs',
              required: true,
              description:
                  'The values to run with, `name=value,name=value` or a JSON '
                  'object. This replaces the set rather than merging into it: '
                  'a name left out stops being overridden, which is the only '
                  'way to say so. It then falls back to whatever the project '
                  'works out for it — a `from:` script is re-asked, exactly as '
                  'at launch — and to the parameter default only when nothing '
                  'else answers.',
            ),
          ],
        ),
        PluginAction(
          'stop',
          'Stop',
          returns: RunControlResult,
          danger: true,
          description:
              'Asks a running app to exit, kills its launcher, and frees the '
              'device. Asking the app first matters: killing only the launcher '
              'leaves the app running on the phone.',
          parameters: _appSelector,
        ),
        PluginAction(
          'inspect',
          'Inspect',
          returns: RunInspectResult,
          description:
              'One reading of a running app — whether it is up, whether it can '
              'still be reloaded, and whatever you ask about it: its widget '
              'tree, a picture, what it printed. With no flags it answers the '
              'question worth asking first, whether anything has gone wrong. '
              'Everything else is opt-in and every flag you add is answered '
              'from the **same** connection, and the tree and the picture from '
              'the same reading — two calls against a live app are two moments '
              'that only happen to agree. Answers even while the app is still '
              'building, when the logs are the only thing there is to read.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'tree',
              'Widget tree',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Report the widget tree, with the file, line and column '
                  'each widget was constructed at. Off by default because a '
                  'real app is thousands of tokens of tree.',
            ),
            const ActionParameter(
              'full',
              'Full tree',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  "Include the framework's own widgets, not just yours. "
                  'Large: a one-screen app is 25 summary nodes and about 517 '
                  'full ones, six megabytes of them.',
            ),
            const ActionParameter(
              'screenshot',
              'Screenshot',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Write a PNG of the same reading everything else comes from, '
                  'and hand back its path. Rendered by the app rather than '
                  'grabbed from the device, so it works on hardware that '
                  'cannot be asked for a screen grab — and platform views '
                  '(native maps, webviews, video) will not appear.',
            ),
            const ActionParameter(
              'out',
              'Output path',
              required: false,
              description:
                  "Where to write the PNG. A file beside the run's log when "
                  'omitted, overwritten on each call.',
            ),
            const ActionParameter(
              'logs',
              'What it printed',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  "Report the run's output. Read from the launcher's log file "
                  'rather than from the app, so it covers the build and '
                  'survives a crash.',
            ),
            const ActionParameter(
              'source',
              'Log source',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  "Whose lines: the app's own output, `flutter run` talking "
                  'about the build, or the platform log. All of them when '
                  'omitted. Naming `native` turns `native` on by itself, '
                  'since asking for lines nothing read would answer nothing.',
              options: [
                ActionOption('app', label: 'The app'),
                ActionOption('tool', label: 'flutter run'),
                ActionOption('native', label: 'The platform'),
              ],
            ),
            const ActionParameter(
              'native',
              "The platform's own log",
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Also read the platform log — what the *native* half of the '
                  'app logged, which `flutter run` does not forward and no '
                  'amount of reading its output would recover. On an iOS '
                  "simulator its filter admits only the app's own executable "
                  'and the engine, so every line a plugin ships in a framework '
                  'is dropped; on Android a tag allow-list drops the same '
                  'class. This is where push, purchases, deep links, maps, '
                  'camera and biometrics say whether they worked. Off by '
                  'default: it costs a `log show` or an `adb logcat`, about a '
                  'second. Scoped to the code inside the app bundle and to '
                  "this run's lifetime, and the command it ran comes back with "
                  'it. iOS simulator, Android and macOS; a physical iOS device '
                  'is refused with the command to run by hand.',
            ),
            const ActionParameter(
              'lines',
              'Lines',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '200',
              description: 'How many of the most recent lines to return',
            ),
            const ActionParameter(
              'errors',
              'What broke',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'true',
              description:
                  'Report the lines the launcher marked as errors — never '
                  'guessed from the text. On by default, and with no other '
                  'flag it is the whole answer.',
            ),
          ],
        ),
        // **Declared, which it was not.** It has been dispatched by [invoke]
        // since the cockpit was built and named in no report, which made it
        // invisible to `fw run run`, unanswerable by `--help`, and — the
        // expensive part — exempt from the argument check, because that is
        // keyed on the declaration. `screenshot --output=…` therefore wrote
        // the default path and reported success for a flag that does not
        // exist. Found by a consumer who typed `--output` for `out`.
        PluginAction(
          'screenshot',
          'Screenshot',
          returns: RunScreenshotResult,
          description:
              'A PNG of a running app, written to a file. The picture alone, '
              'where `inspect {screenshot: true}` answers it beside the tree '
              'and the logs from one reading. Platform views — native maps, '
              'webviews, video — will not appear: they are composited by the '
              "OS rather than by Flutter's layer tree, so nothing rendering "
              'that tree can photograph them.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'out',
              'Output path',
              required: false,
              description:
                  "Where to write the PNG. A file beside the run's log when "
                  'omitted, overwritten on each call.',
            ),
            const ActionParameter(
              'maxSide',
              'Longest side',
              kind: ActionParameterKind.integer,
              required: false,
              description:
                  'Scale the render so its longest side is at most this many '
                  'pixels. The render is scaled, not the encoding, so this is '
                  'what bounds the cost rather than the file.',
            ),
          ],
        ),
        PluginAction(
          'act',
          'Act',
          returns: RunActResult,
          description:
              'One drive transaction against a running app: resolve the '
              'target, check the pointer can reach it (retrying through '
              'route transitions until a deadline), perform the verb, settle, '
              'and observe — texts, a screenshot, what was printed — all in '
              'one reply describing one moment. Needs the app to have been '
              'launched by flutterware (the launch wraps it in the drive '
              'guest); anything else is inspect-only. A refusal still '
              'observes: the error comes back with the screen it happened '
              "on. Every step is appended to the run's journal. On a phone "
              'the app has to be in the foreground: iOS suspends a '
              'backgrounded app, which answers nothing until somebody brings '
              'it back — that comes back as a timeout saying so, never a '
              'hang. A hidden desktop window is fine, and so is a '
              'backgrounded Android app.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'verb',
              'Verb',
              kind: ActionParameterKind.choice,
              description: 'What to do',
              options: [
                ActionOption('tap'),
                ActionOption('doubleTap'),
                ActionOption('longPress'),
                ActionOption('secondaryTap'),
                ActionOption('hover'),
                ActionOption('unhover'),
                ActionOption('drag'),
                ActionOption('scroll'),
                ActionOption('scrollTo'),
                ActionOption('enterText'),
                ActionOption('key'),
                ActionOption('back'),
                ActionOption('wait'),
                ActionOption('observe'),
                ActionOption('navigate'),
                ActionOption('foreground'),
              ],
            ),
            _layerParameter,
            const ActionParameter(
              'target',
              'Target',
              required: false,
              description:
                  'What to act on. Bare text matches a visible string; JSON '
                  'names the rest: {"key": …}, {"label": …}, {"tooltip": …}, '
                  '{"containing": …}, {"within": {"scope": …, "child": …}}, '
                  '{"nth": {"target": …, "index": …}}, {"at": {"x": …, '
                  '"y": …}}. Resolved inside the app at act time, and refused '
                  'loudly on zero or several matches — never a silent '
                  'wrong-target tap. A reply text ending in … was truncated: '
                  'target it with {"containing": <prefix>}. {"at"} is a hit '
                  'test at that point, in logical pixels, taking the '
                  'innermost widget under it — how a painted surface is '
                  'driven when its zones share one box. On layer: native the '
                  'grammar is the same minus key/tooltip/within, plus '
                  '{"role": …}, and {"at"} is a screen coordinate there.',
            ),
            const ActionParameter(
              'text',
              'Text',
              required: false,
              description: 'What enterText types, as one editing value',
            ),
            const ActionParameter(
              'dx',
              'Horizontal distance',
              required: false,
              description:
                  'For drag and scroll: horizontal distance, logical pixels',
            ),
            const ActionParameter(
              'dy',
              'Vertical distance',
              required: false,
              description:
                  'Vertical distance, and the sign depends on which verb: '
                  'drag is a finger, so negative moves it up the screen; '
                  'scroll is a wheel, whose delta is added to the scroll '
                  'offset, so positive moves *down* the list. Opposite '
                  "conventions, both the platform's.",
            ),
            const ActionParameter(
              'keys',
              'Keys',
              required: false,
              description:
                  'For key: the chord to press. `+`-separated, the last name '
                  'fires and the ones before it are held for it — `escape`, '
                  '`enter`, `meta+k`, `shift+tab`. This is for shortcuts and '
                  'navigation, not for typing: a character never reaches a '
                  'text field through a key event on any platform, so `a` '
                  'leaves a focused field empty — enterText is the verb that '
                  'types. Names are LogicalKeyboardKey '
                  'debug names spelled any way that reads (`arrowDown`), a '
                  'single character (`k`), or a shorthand (`cmd`, `ctrl`, '
                  '`alt`, `opt`, `shift`, `esc`). A Mac shortcut and its '
                  'Windows/Linux twin are different chords: meta+k, control+k.',
            ),
            const ActionParameter(
              'gapMs',
              'Double-tap gap',
              kind: ActionParameterKind.integer,
              required: false,
              description:
                  'For doubleTap: real milliseconds between the two taps. 80 '
                  'by default, which is the middle of the only window that '
                  'works — under 40 the recognizer reads them as one '
                  'restarted tap, over 300 as two separate ones.',
            ),
            const ActionParameter(
              'holdMs',
              'Hover hold',
              kind: ActionParameterKind.integer,
              required: false,
              description:
                  'For hover and unhover: how long to keep the pointer there '
                  'before settling, in real milliseconds. 600 by default, and '
                  'cut short the moment the app reacts — a settle waits on '
                  'frames, and what a hover is usually asked about is a timer '
                  "(a tooltip's waitDuration), which schedules no frame until "
                  'it fires. 0 skips the hold, for a plain enter/exit check.',
            ),
            const ActionParameter(
              'within',
              'Scroll within',
              required: false,
              description:
                  'For scrollTo: which scrollable to walk, as a target. The '
                  'first one on screen when omitted.',
            ),
            const ActionParameter(
              'route',
              'Route',
              required: false,
              description:
                  "For navigate: the route the app's registered navigation "
                  'handler understands',
            ),
            const ActionParameter(
              'waitMs',
              'Wait',
              kind: ActionParameterKind.integer,
              required: false,
              description: 'For wait: real milliseconds to let the app run',
            ),
            ..._observationParameters,
            const ActionParameter(
              'actor',
              'Actor',
              required: false,
              defaultValue: 'agent',
              description: 'Who this step is journaled as',
            ),
          ],
        ),
        PluginAction(
          'observe',
          'Observe',
          returns: RunActResult,
          description:
              'The act-less transaction: settle the running app and look — '
              'texts, a screenshot, what it printed since the last step. The '
              'opening move of a drive loop, and the call to make after a '
              'hot reload. Same reply shape and same journal as act. With '
              "layer: native it reads the platform's own tree instead and "
              'photographs the real device screen — keyboard, dialogs and '
              'platform views included.',
          parameters: [
            ..._appSelector,
            _layerParameter,
            ..._observationParameters,
            const ActionParameter(
              'actor',
              'Actor',
              required: false,
              defaultValue: 'agent',
              description: 'Who this step is journaled as',
            ),
          ],
        ),
        PluginAction(
          'navigate',
          'Navigate',
          returns: RunActResult,
          description:
              'Jumps the running app straight to a screen, through the '
              'navigation handler the app registered (router_outlet does, '
              'and any router can in one line: GuestDrive.navigator = …). '
              'Refuses plainly when the app declares none — it never falls '
              'back to hunting the UI with taps.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'route',
              'Route',
              description: "The route, as the app's handler understands it",
            ),
            ..._observationParameters,
          ],
        ),
        PluginAction(
          'lens',
          'Lens',
          returns: RunLensResult,
          description:
              'How much of an observation comes back, as one word — read it, '
              'or pin it for this run. `act` is the screen alone and the '
              'default, `look` adds the picture, `design` adds the text '
              'styles, `raw` adds the whole tree and costs about 20,000 '
              'tokens. Pin one when a stretch of work wants the same shape '
              'every step and you would rather not say so every call; every '
              'reply names the lens in force and marks a pinned one, because '
              'a human or another agent driving this run can pin it too. '
              'Anything a call names explicitly still beats the lens.',
          parameters: [
            ..._appSelector,
            ActionParameter(
              'lens',
              'Lens',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'Pin this one. Omitted, the action reports what is in force '
                  'without changing it; `none` clears the pin.',
              options: [
                for (var lens in ObserveLens.values) ActionOption(lens.name),
                const ActionOption('none', label: 'Clear the pin'),
              ],
            ),
          ],
        ),
        PluginAction(
          'panels',
          'Panels',
          returns: RunPanelsResult,
          description:
              'What the app says about *itself*: the panels its own devbar '
              'plugins declare, with every knob and its live value, every '
              'action and its parameters, the states it can be asked for and '
              'the feeds it reports on. Where `observe` sees what flutterware '
              'can see of the screen, this is what the app chose to expose — '
              'feature flags, a simulated push, whatever the project wrote. '
              'Answers plainly for an app with no `Devbar` mounted. One '
              "attach per call, so recent feed events replay from the app's "
              'ring rather than needing a live subscription.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'panel',
              'Panel',
              required: false,
              description: 'One panel by id; all of them when omitted',
            ),
            const ActionParameter(
              'events',
              'Feed events',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '20',
              description:
                  'How many recent events to bring back per feed, newest '
                  'kept. Zero for the declarations alone.',
            ),
          ],
        ),
        PluginAction(
          'panelInvoke',
          'Run a panel action',
          returns: RunPanelResult,
          description:
              'Runs one of the commands a panel declares, inside the app. '
              'This is the reach a test cannot buy: a push notification '
              'delivered with no backend, a permission answered with no '
              'device. The action ids and their parameters come from '
              "`panels`; a refusal is the app's own words, not a wrapper's.",
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'panel',
              'Panel',
              description: 'The panel id `panels` reports',
            ),
            const ActionParameter(
              'action',
              'Action',
              description: "The action id, from that panel's `actions`",
            ),
            const ActionParameter(
              'args',
              'Arguments',
              required: false,
              description:
                  "The action's arguments as a JSON object — "
                  '{"title": "Order ready", "link": "/cart"}. A panel action '
                  'takes whatever it declared, so this stays free-form rather '
                  'than one flag per parameter.',
            ),
            const ActionParameter(
              'event',
              'Event',
              kind: ActionParameterKind.integer,
              required: false,
              description:
                  'For an item action: the id of the feed event to run it '
                  'on, as `panels` reports it.',
            ),
          ],
        ),
        PluginAction(
          'panelKnob',
          'Set a panel knob',
          returns: RunPanelResult,
          description:
              "Writes one of a panel's read-write values — a feature flag, a "
              'permission, an environment. Answers with the knobs **after** '
              'the write, because an app is allowed to clamp or refuse and a '
              'reply that echoed the request would be a lie. A picker is set '
              'by its label.',
          parameters: [
            ..._appSelector,
            const ActionParameter('panel', 'Panel'),
            const ActionParameter(
              'knob',
              'Knob',
              description: 'The knob name `panels` reports',
            ),
            const ActionParameter(
              'value',
              'Value',
              description:
                  'The new value. Parsed as JSON when it parses — so true, 3 '
                  'and "text" arrive as the right type — and taken as a plain '
                  'string when it does not.',
            ),
          ],
        ),
        PluginAction(
          'panelState',
          'Read a panel state',
          returns: RunPanelResult,
          description:
              'Asks the app for one snapshot it offers — the permissions it '
              'holds, its package info, its own account of the device. A '
              'separate call from `panels` because producing one can be '
              'expensive, and nothing should pay for it by listing.',
          parameters: [
            ..._appSelector,
            const ActionParameter('panel', 'Panel'),
            const ActionParameter(
              'state',
              'State',
              description: 'The state id `panels` reports',
            ),
          ],
        ),
        PluginAction(
          'device',
          'Device',
          returns: RunDeviceResult,
          description:
              'What the device this run is on is currently set to — '
              'appearance, text size, orientation, locale and the '
              'accessibility flags — with what each one costs to change and '
              'whether the value is evidence or an echo. Reads live, from the '
              'command that owns each setting; a value nothing owns says so in '
              'its `provenance` rather than passing for an answer. Settings '
              'this target cannot do come back as rows carrying the reason and '
              'the by-hand command, because a missing control reads as an '
              'oversight. iOS simulator and Android for now; everything else '
              'refuses and says what would work instead.',
          parameters: [..._appSelector],
        ),
        PluginAction(
          'setDevice',
          'Set a device setting',
          returns: RunDeviceResult,
          description:
              'Writes one device setting and answers with that setting **re-'
              'read** — what the device says now, not an echo of what it was '
              'asked. Most are live and cost nothing; a locale on the iOS '
              'simulator lands on the device and the running app keeps the old '
              'one until it is relaunched, and a rotation there needs the '
              'Simulator to be the front window, so it takes the keyboard '
              'focus for a moment. Both are said on the row before the call. '
              'Every write lands in the run journal as a `set` step: a device '
              'change is the only thing that alters a screen while leaving no '
              'trace in the app.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'setting',
              'Setting',
              description:
                  'What to change, as `device` reports it — brightness, '
                  'textScale, orientation, language, invertColors, '
                  'disableAnimations, highContrast, boldText',
            ),
            const ActionParameter(
              'value',
              'Value',
              description:
                  "One of that row's `options`. An empty language hands the "
                  'app back to the device default where the platform allows '
                  'it.',
            ),
          ],
        ),
        PluginAction(
          'network',
          'Network',
          returns: RunNetworkResult,
          description:
              "The app's HTTP traffic, read from the VM's own http profile — "
              'the data source behind DevTools, so it needs no devbar and no '
              'wrapper client. Capture is armed at launch by the run guest; '
              'an app launched outside flutterware records from this call '
              'on. A request in flight has no `status` yet and comes back '
              "again, same id, once it completes — pass the reply's "
              '`cursor` as `since` to read only what changed.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'since',
              'Cursor',
              kind: ActionParameterKind.integer,
              required: false,
              description:
                  'The `cursor` of a previous reply — only requests touched '
                  'after it come back. A hot restart clears the profile and '
                  'the cursor with it.',
            ),
            const ActionParameter(
              'limit',
              'Limit',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '50',
              description: 'How many requests to bring back, newest kept',
            ),
          ],
        ),
        PluginAction(
          'networkRequest',
          'One request',
          returns: RunNetworkRequestResult,
          description:
              'Headers, bodies and timing events for one request `network` '
              'listed — held in the app and fetched on demand, which is what '
              'keeps the list light.',
          parameters: [
            ..._appSelector,
            const ActionParameter(
              'id',
              'Request',
              description: 'The request id from `network`',
            ),
          ],
        ),
        PluginAction(
          'emulators',
          'Emulators',
          returns: RunEmulatorsResult,
          description:
              'Every emulator and simulator this machine could boot, and '
              'whether each is already up. Different from devices, which only '
              'lists the ones that are: an emulator that is not running is not '
              'a device. Costs a few seconds — it starts a flutter daemon.',
        ),
        PluginAction(
          'bootEmulator',
          'Boot an emulator',
          returns: RunBootResult,
          description:
              'Starts an emulator and waits for it to appear as a device, '
              'which is well after the boot command returns. A cold Android '
              'emulator can take over a minute; running out of the wait is '
              'not a failure and the answer says so.',
          parameters: const [
            ActionParameter(
              'emulator',
              'Emulator',
              description: 'The id `emulators` reports',
            ),
            ActionParameter(
              'coldBoot',
              'Cold boot',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Skip the saved snapshot. Slower, and the answer to an '
                  'emulator that boots into a broken state.',
            ),
            ActionParameter(
              'timeout',
              'Timeout',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '120',
              description: 'Seconds to wait for it to become a device',
            ),
          ],
        ),
      ],
      view: PluginView([
        if (_daemonError != null)
          ViewText(
            'Could not start a flutter daemon: $_daemonError',
            tone: Tone.error,
          ),
        if (!_scanned)
          ViewText('Not scanned yet.')
        else ...[
          ViewSection('Devices', [
            if (devices.isEmpty)
              ViewText(
                isLive
                    ? 'Nothing connected.'
                    : 'No device list has been taken yet. Run the devices '
                          'action with refresh, or open this panel.',
              )
            else
              ViewItems([
                for (var device in devices)
                  ViewItem(
                    device.displayName,
                    detail: _deviceDetail(device),
                    tone: busy.contains(device.id) ? Tone.info : Tone.neutral,
                  ),
              ]),
            if (!isLive && _cache != null)
              ViewField('Taken', _cache!.ageDescription),
          ]),
          ViewSection('Running', [
            if (_handles.isEmpty)
              ViewText('Nothing running.')
            else
              ViewItems([
                for (var handle in _handles)
                  ViewItem(
                    '${handle.entrypointLabel} on '
                    '${handle.deviceName ?? handle.device}',
                    detail: _handleDetail(handle),
                    // The run's own screen, which is where a row naming a run
                    // should take you. The key is stable across relaunch — see
                    // `run_address.dart` — so the address outlives the process
                    // the row is currently describing.
                    address: addressFor(handle),
                  ),
              ]),
          ]),
        ],
      ]),
    );
  }

  /// The launcher's line for a launch this process is waiting out.
  ///
  /// Because nothing else is watching. The rail's row fills in from the
  /// probe loop, which only runs where something subscribed — the GUI. A
  /// headless `launch` waits ninety seconds with a live log in front of it and
  /// used to publish none of it, so `fw` and an agent both watched a blank
  /// space. Reading it into the report puts it where every renderer already
  /// looks, and MCP forwards each change as progress.
  final _launching = <String, Status>{};

  void _setLaunching(String key, Status? status) {
    if (status == null) {
      _launching.remove(key);
    } else {
      _launching[key] = status;
    }
    notifyChanged();
  }

  /// The rail's line while something is happening — a launch narrating, or a
  /// daemon that died. The device count that used to fill the quiet state is
  /// a fact about the machine, not this worktree, and it lives on the desk
  /// button in the shell's chrome now.
  Status get _status {
    if (_launching.values.firstOrNull case var launching?) return launching;
    if (_daemonError != null) return Status.error('no device list');
    return Status.none;
  }

  /// What a run says about itself in the rail — capability, not liveness.
  ///
  /// The same distinction the panel header makes: an app whose launcher died
  /// keeps its tree and its screenshots and loses hot reload, and a row saying
  /// only "running" would hide it.
  Status _handleStatus(RunHandle handle) {
    var probe = probeOf(handle);
    if (probe == null) return const Status.neutral('not probed');
    if (!probe.canInspect) {
      return Status.neutral(logOf(handle)?.stage ?? 'building');
    }
    if (!probe.launcher) return const Status.warn('no launcher');
    return const Status.good('live');
  }

  String _deviceDetail(DaemonDevice device) => [
    ?device.platformType,
    ?device.sdk,
    if (device.emulator) 'emulator',
    if (device.isWireless) 'wireless',
    if (!device.isConnected) 'not connected',
  ].join(' · ');

  /// The ledger is machine-wide, so this list holds runs this worktree did not
  /// start. The worktree name alone does not make that clear — a reader who
  /// does not already know every checkout on the machine reads an unrelated
  /// repository's app as one of this project's, under a heading that says
  /// Running.
  String _handleDetail(RunHandle handle) {
    var probe = probeOf(handle);
    return [
      isMine(handle)
          ? handle.worktreeName
          : '${handle.worktreeName} · another checkout',
      if (probe == null)
        'not probed'
      else if (probe.canReload)
        'reloadable'
      else if (probe.canInspect)
        'no launcher'
      else
        'starting',
    ].join(' · ');
  }

  ActionParameter get _packageParameter => ActionParameter(
    'package',
    'Package',
    kind: ActionParameterKind.choice,
    required: false,
    description: 'Which declared package; the only one when there is one',
    options: [
      for (var path in packages)
        ActionOption(path, label: path == '.' ? 'root' : path),
    ],
  );

  /// Which running app a control action acts on.
  ///
  /// The device is the key because a device usually runs one app, and naming
  /// the entry point as well is only needed when it does not. Both optional:
  /// with exactly one app running there is nothing to disambiguate, and making
  /// the caller say so anyway is ceremony.
  /// One step per app this worktree launched, so closing the checkout does
  /// not leave one running on a phone with nothing able to reach it.
  ///
  /// One step per app rather than one "stop 3 apps" row, which is what
  /// [TeardownStep.arguments] is for: each row names its own device and says
  /// how long it has been up, and one can be left ticked while another is not.
  /// A lumped row can only be taken or left whole, and the reason to leave one
  /// running — it is on a phone in use — applies to one app and not the rest.
  ///
  /// Scoped to *this* worktree. The ledger is deliberately every worktree's, so
  /// that a device held by another checkout is visible; a teardown that stopped
  /// those too would close one tab and kill an unrelated run.
  List<TeardownStep> get _teardown => [
    for (var handle in ownHandles)
      TeardownStep(
        'stop',
        'Stop ${handle.runLabel} on ${handle.deviceLabel}',
        detail: _startedAgo(handle.startedAt),
        // The same arguments the `stop` action takes from `fw` and a form,
        // because it is the same action.
        arguments: {'device': handle.device, 'entrypoint': handle.entrypoint},
        checked: true,
        phase: TeardownPhase.apps,
      ),
  ];

  static String _startedAgo(DateTime startedAt) {
    var elapsed = DateTime.now().difference(startedAt);
    if (elapsed.inMinutes < 1) return 'started just now';
    if (elapsed.inHours < 1) return 'started ${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) return 'started ${elapsed.inHours}h ago';
    return 'started ${elapsed.inDays}d ago';
  }

  List<ActionParameter> get _appSelector => [
    ActionParameter(
      'device',
      'Device',
      kind: ActionParameterKind.choice,
      required: false,
      description:
          'Which device the app is on; the only running app when omitted',
      options: [
        for (var device in devices)
          ActionOption(device.id, label: device.displayName),
      ],
    ),
    const ActionParameter(
      'entrypoint',
      'Entry point',
      required: false,
      description:
          'Package-relative path, when one device is running more than one',
    ),
    const ActionParameter(
      'worktree',
      'Worktree',
      required: false,
      description:
          'Worktree name or path, to reach a run another checkout launched; '
          'only runs from this worktree match when omitted',
    ),
    const ActionParameter(
      'run',
      'Run',
      required: false,
      description:
          'The run id `apps` reports as `run`, and the ambiguity refusal '
          'lists — the last resort, and the only thing that separates two runs '
          'of the same entry point on the same device from the same worktree. '
          'The stable key an address carries is accepted too, where it is not '
          'ambiguous. Explicit like `worktree`: naming one reaches any run of '
          'this repository.',
    ),
  ];

  /// Which tree a transaction addresses.
  ///
  /// One parameter rather than a second set of verbs, because everything an
  /// agent already knows should keep working: same targets, same reply, same
  /// journal, same refusal voice — one extra word when the widget tree is not
  /// where the thing lives.
  static const _layerParameter = ActionParameter(
    'layer',
    'Layer',
    kind: ActionParameterKind.choice,
    required: false,
    defaultValue: 'flutter',
    description:
        "Which tree to address. `flutter` (default) is the app's own widget "
        'tree — fast, exact, and where everything Flutter draws lives. '
        "`native` is the platform's accessibility tree, reached through adb "
        'or the OS: slower (seconds, not milliseconds) and blunter, but it '
        'sees what Flutter cannot — permission dialogs and other native '
        'popups, the contents of a webview or map, another app the flow '
        'jumped to — and its screenshot is the real device screen rather '
        'than '
        'a raster of the Flutter layer. Reach for it when a drive target is '
        'refused for something you can see in the picture but not in the '
        'texts, or to bring a suspended iOS app back with verb: foreground. '
        'It does observe, tap, enterText (Android) and foreground; drag, '
        'scrollTo, back and navigate stay on the drive layer.',
    options: [ActionOption('flutter'), ActionOption('native')],
  );

  /// What every drive transaction lets you tune about its observation.
  static final _observationParameters = [
    const ActionParameter(
      'settleMs',
      'Settle budget',
      kind: ActionParameterKind.integer,
      required: false,
      defaultValue: '800',
      description:
          'Milliseconds to wait for the app to stop painting before '
          'observing. Running out is reported (settled: false), never an '
          'error — a spinner would otherwise hang every step. It waits on '
          'frames, tickers and image decodes, so settled: true means "nothing '
          'is animating", not "the screen has finished loading": a pending '
          'fetch or file read schedules no frame and is invisible to it. When '
          'the texts still say "Loading…", wait and observe again.',
    ),
    ActionParameter(
      'screenshot',
      'Screenshot',
      kind: ActionParameterKind.boolean,
      required: false,
      defaultValue: 'false',
      description:
          'Return the picture, not just archive it. **Every step is '
          'photographed either way** and the frame is on disk under the '
          'capture — this decides whether it enters the reply, where it is '
          'about 810 tokens. Off by default because `screen` answers most of '
          'what a picture used to be read for; ask for it when the question '
          'is how something *looks*. It is attached without being asked for '
          'when the step was refused or the app threw, because looking is '
          'the useful thing to do then.',
    ),
    ActionParameter(
      'lens',
      'Lens',
      kind: ActionParameterKind.choice,
      required: false,
      defaultValue: 'act',
      description:
          'How much to hand back, as one word, for this call — `act` (the '
          'screen alone), `look` (+ the picture), `design` (+ the text '
          'styles), `raw` (+ the whole tree, ~20,000 tokens). Beaten by any '
          'flag you name explicitly. `run lens` pins one for the whole run.',
      options: [for (var lens in ObserveLens.values) ActionOption(lens.name)],
    ),
    ActionParameter(
      'item',
      'Screen item',
      kind: ActionParameterKind.integer,
      required: false,
      description:
          'Act on the numbered thing from the last screen reply — '
          '`{"item": 20}` instead of a target. **The way past an ambiguous '
          'name**: `tap "Changes"` is refused when two widgets match, and a '
          'screen that lists exactly one Changes button has already told you '
          'which. It is also the only way to reach a control with no words at '
          'all, and there are usually a handful. Resolved to the centre of '
          "that item's box and then through the ordinary ladder, so covered "
          'or gone is refused rather than tapped blind — and it is that '
          'coordinate the finger lands on, so the box you were shown is the '
          'box that gets pressed. Numbers are per '
          'observation: a screen that changed renumbers, and the refusal says '
          'how many items the last one had.',
    ),
    ActionParameter(
      'screen',
      'The screen',
      kind: ActionParameterKind.boolean,
      required: false,
      defaultValue: 'true',
      description:
          'What is on the screen and what can be done to it: every control '
          'and every piece of text, with its words, its box and whether it '
          'is the current one of its group, nested under the panes and lists '
          'that hold them. On by default and the thing to read first — it is '
          'a twentieth of the tree and answers more, because a tree cannot '
          'say which control is disabled or which tab is selected. A control '
          'with no words is reported as such rather than dropped: it has no '
          'accessible name, which an agent and a screen reader both trip on.',
    ),
    ActionParameter(
      'find',
      'Find',
      required: false,
      description:
          'Report only the nodes whose type, description or accessibility '
          'label contains this, case-insensitively — `ElevatedButton`, '
          '`Save`, `SizedBox`. The cheap way to a colour, a size and a '
          "source: 131 tokens against the whole tree's 19,500. Also how to "
          'get a node id without reading a tree first.',
    ),
    ActionParameter(
      'at',
      'At a point',
      required: false,
      description:
          'Report the chain of widgets under this point, as `x,y` in logical '
          'pixels — the same space every box in this reply uses, so a box '
          'centre from `screen` lands here untranslated. Outermost first, '
          'innermost last, capped at the eight that matter: the thing under '
          'a point is usually a Text and the thing you meant is the Row three '
          'levels out whose crossAxisAlignment is the answer.',
    ),
    ActionParameter(
      'styles',
      'Text styles',
      kind: ActionParameterKind.boolean,
      required: false,
      defaultValue: 'false',
      description:
          'Every distinct size/weight/colour of text on screen, most-used '
          'first, with one sample each. The type ramp and the palette as a '
          'table — about 185 tokens, and the answer to "are these two greys '
          'the same grey" and "is the ramp consistent". Asking the same '
          'question as a search costs thirteen times more and truncates.',
    ),
    ActionParameter(
      'tree',
      'Widget tree',
      kind: ActionParameterKind.boolean,
      required: false,
      defaultValue: 'false',
      description:
          'Include the widget tree in the reply. Off by default and the '
          'heaviest thing here by an order of magnitude — `screen` says what '
          'is there, and `find`, `at` and `styles` answer most of what people '
          'read a whole tree for at a hundredth of the cost. Reach for it '
          'when the question is genuinely about structure. Scoped by '
          'treeRoot, treeDepth and treeNoise.',
    ),
    ActionParameter(
      'treeRoot',
      'Subtree root',
      required: false,
      description:
          'Report this node and its descendants instead of the whole tree. A '
          'node id from an earlier read of the same screen — `0/3/1/0`. Ids '
          'are positions in the tree, so one from a screen that has since '
          'changed is refused rather than approximated.',
    ),
    ActionParameter(
      'treeDepth',
      'Tree depth',
      kind: ActionParameterKind.integer,
      required: false,
      description:
          'How many levels below the reported root to include. Counted after '
          'treeNoise has run, so the levels are the ones you would see. A '
          'node whose children were cut says how many with `elided`, so a '
          'bounded read cannot be mistaken for a complete one.',
    ),
    ActionParameter(
      'treeNoise',
      'Keep scaffolding',
      kind: ActionParameterKind.boolean,
      required: false,
      defaultValue: 'true',
      description:
          "Drop widgets that share their only child's box, keeping whichever "
          'of the two carries more — MouseRegion, GestureDetector, Gap, '
          'Expanded and the rest of the wrappers go, and the box, the words '
          "and the flex stay. On by default; measured on this GUI's Changes "
          'screen at 436 nodes down to 252. Pass false for every level, when '
          'the question is about the wrappers themselves. Ids never move '
          'either way, so a filtered child can sit directly under a node that '
          'is not its parent.',
    ),
    ActionParameter(
      'maxSide',
      'Screenshot cap',
      kind: ActionParameterKind.integer,
      required: false,
      defaultValue: '900',
      description:
          "Cap the screenshot's longest side, in pixels — the render is "
          'scaled, not re-encoded. 900 by default, which is ~810 image tokens '
          'and still legible; raise it when the pixels are the question. A '
          'step that returns no picture still photographs itself for the '
          'capture, at 600.',
    ),
  ];

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    if (readOnly case var why? when _changesTheMachine(actionId, arguments)) {
      throw RunRefusal(why);
    }
    return switch (actionId) {
      'devices' => _devicesAction(refresh: _boolArgument(arguments['refresh'])),
      'apps' => _appsAction(),
      'entrypoints' => _entrypointsAction(arguments['package'] as String?),
      'launch' => _launchAction(arguments),
      'reload' => _controlAction('reload', arguments),
      'restart' => _controlAction('restart', arguments),
      'stop' => _controlAction('stop', arguments),
      'setKnobs' => _setKnobsAction(arguments),
      'inspect' => _inspectAction(arguments),
      'screenshot' => _screenshotAction(arguments),
      'act' => _actAction(arguments),
      'observe' => _actAction({...arguments, 'verb': 'observe'}),
      'navigate' => _actAction({...arguments, 'verb': 'navigate'}),
      'lens' => _lensAction(arguments),
      'panels' => _panelsAction(arguments),
      'panelInvoke' => _panelInvokeAction(arguments),
      'panelKnob' => _panelKnobAction(arguments),
      'panelState' => _panelStateAction(arguments),
      'device' => _deviceAction(arguments),
      'setDevice' => _setDeviceAction(arguments),
      'network' => _networkAction(arguments),
      'networkRequest' => _networkRequestAction(arguments),
      'emulators' => _emulatorsAction(),
      'bootEmulator' => _bootEmulatorAction(arguments),
      _ => super.invoke(actionId, arguments: arguments),
    };
  }

  /// Whether [actionId] launches, reloads, boots, drives or dials something —
  /// what a recording refuses. Reading the ledger, the journal and the
  /// panels a recording answered is not.
  static bool _changesTheMachine(
    String actionId,
    Map<String, Object?> arguments,
  ) => switch (actionId) {
    'apps' || 'entrypoints' || 'lens' || 'panels' || 'panelState' => false,
    'devices' => _boolArgument(arguments['refresh']),
    _ => true,
  };

  /// [message] with the launcher's own error lines under it.
  ///
  /// For the failures the app cannot narrate about itself. The lines are the
  /// ones [readRunLog] marked — an errored `app.log`, a `daemon.logMessage` at
  /// error level, or the engine's severity prefix — never a text match, so an
  /// empty tail here means the log genuinely says nothing rather than that the
  /// filter was too shy.
  ///
  /// Bounded, because the reader is usually a context window: an unhandled
  /// exception is one line and a stack, and the first few carry the cause.
  String? _withLauncherErrors(
    RunHandle handle,
    String? message, {
    int tail = 6,
  }) {
    var lines = readLogs(handle, errorsOnly: true, tail: tail);
    if (lines.isEmpty) return message;
    var quoted = [for (var line in lines) '  ${line.text}'].join('\n');
    return [
      ?message,
      'The launcher log says:\n$quoted',
      'All of it: ${handle.logPath}',
    ].join('\n\n');
  }

  static String? _joinNotes(List<String?> parts) {
    var kept = [
      for (var part in parts)
        if (part != null && part.trim().isNotEmpty) part.trim(),
    ];
    return kept.isEmpty ? null : kept.join(' ');
  }

  Future<RunEntrypointsResult> _entrypointsAction(String? package) async {
    await computeAll();
    // A caller who asked what the defines are is a caller who chose to pay for
    // the answer, which computeAll may not spend a process on.
    await resolveScriptSources();
    var wanted = package == null
        ? packages
        : [
            for (var path in packages)
              if (path == package) path,
          ];
    if (wanted.isEmpty) {
      return RunEntrypointsResult(
        packages: const [],
        note: package == null
            ? 'No packages are declared for this plugin. Add them in '
                  'tool/flutterware.dart: fw.use(Run(packages: [...])).'
            : 'No declared package at "$package".',
      );
    }
    return RunEntrypointsResult(
      packages: [
        for (var path in wanted)
          RunEntrypointPackage(
            path: path,
            declared: isDeclared(path),
            flavors: flavorVocabularyOf(path).isEmpty
                ? null
                : {
                    for (var entry in flavorVocabularyOf(path).entries)
                      entry.key.name: entry.value,
                  },
            entrypoints: [
              for (var entry in entrypointsFor(path))
                RunEntrypointEntry(
                  path: entry.path,
                  name: entry.name,
                  description: entry.description,
                  flavor: flavorFor(path, entry).flavor,
                  flavorSource: switch (flavorFor(path, entry).source) {
                    FlavorSource.none => null,
                    var source => source.name,
                  },
                  flavorByPlatform: entry.flavorByPlatform.isEmpty
                      ? null
                      : {
                          for (var pairing in entry.flavorByPlatform.entries)
                            pairing.key.name: pairing.value,
                        },
                  platforms: [
                    for (var platform in entry.platforms) platform.name,
                  ],
                  // Every connected device when the entry point restricts
                  // nothing, which is what `devicesFor` already answers and
                  // what the field promises. Special-cased to empty once, on
                  // the reasoning that an unrestricted entry point has nothing
                  // to report — but the field is not "what was filtered out",
                  // it is what this entry point can run on right now, and the
                  // one entry point in a project that names its platforms was
                  // the only one a picker could offer anything for.
                  devices: [for (var device in devicesFor(entry)) device.id],
                  knobs: knobEntriesOf(path, entry),
                ),
            ],
          ),
      ],
      note: wanted.every((path) => entrypointsFor(path).isEmpty)
          ? 'Nothing found. Entry points are declared in tool/flutterware.dart '
                'or discovered as a top-level main() in lib/*.dart.'
          : null,
    );
  }

  /// Asks every [ScriptSource] any declared define points at, concurrently.
  ///
  /// Every call re-asks. The point of a script source is that it knows
  /// something that changes without the project changing — which port this
  /// worktree's stack came up on — so a resolution kept from last time would be
  /// the wrong kind of fast.
  ///
  /// Distinct by script *and* args: two defines fed by the same tool with
  /// different arguments are two questions, while two defines that ask the
  /// identical thing are one process.
  Future<void> resolveScriptSources() => _resolveScripts([
    for (var path in packages)
      for (var entry in entrypointsFor(path))
        for (var knob in entry.knobs) knob.from,
  ]);

  /// Asks the script sources among [defines], concurrently, and records what
  /// they said.
  ///
  /// Takes the defines rather than reading them off this core, which is
  /// what makes it safe to call from [launch]. The sweep above walks
  /// `entrypointsFor`, which is empty until `computeAll` has run — so a launch
  /// that relied on it would find no source to ask, then refuse itself for a
  /// value that was never looked up. Resolving exactly the defines the caller
  /// is about to use cannot disagree with the caller.
  Future<void> _resolveScripts(Iterable<ValueSource?> from) async {
    var sources = <String, ScriptSource>{};
    for (var source in from) {
      if (source is ScriptSource) sources[_scriptKey(source)] = source;
    }
    if (sources.isEmpty) return;
    var dart = p.join(host.workspace.flutterSdk.root, 'bin', 'dart');
    var asked = sources.entries.toList();
    var outcomes = await Future.wait([
      for (var entry in asked)
        runDefineScript(
          entry.value,
          dartExecutable: dart,
          worktreePath: host.worktree.path,
        ),
    ]);
    for (var (index, entry) in asked.indexed) {
      _scriptOutcomes[entry.key] = outcomes[index];
    }
  }

  /// The interface an offered address was found on — `en0` — or null when it
  /// is not one of ours.
  ///
  /// Worth carrying because [hostAddresses] is every non-loopback IPv4 this
  /// machine has, which on a laptop is the Wi-Fi address plus a VPN `utun`,
  /// a Docker bridge and whatever a VM left behind. Exactly one of them is the
  /// one the phone can reach, and without the interface name the list gives a
  /// reader no way to tell which.
  String? hostInterfaceOf(String address) {
    for (var host in hostAddresses) {
      if (host.address == address) return host.interface;
    }
    return null;
  }

  /// The declaration [handle] was launched from, or null if this worktree has
  /// none matching.
  ///
  /// By name first, then path. #119 made "declare one file several times
  /// under different names" the documented way to run one app against several
  /// configurations, so a path matches several entry points and only the name
  /// separates them. Their *signatures* are identical — it is the same file —
  /// but their config annotations are not, so taking the first match would read
  /// another declaration's `label`, `options` and `from:` script, and
  /// [applyKnobs] would resolve a port from the wrong one.
  EntrypointRef? entrypointOf(RunHandle handle) {
    var package = handle.package;
    if (package == null) return null;
    var candidates = entrypointsFor(package);
    if (handle.entrypointName case var name?) {
      for (var candidate in candidates) {
        if (candidate.name == name) return candidate;
      }
    }
    // A scanned entry point carries no name, and one declared since the launch
    // may have been renamed. The path is the weaker answer and still the right
    // fallback: at worst it is the same file under a sibling declaration.
    for (var candidate in candidates) {
      if (candidate.path == handle.entrypoint) return candidate;
    }
    return null;
  }

  /// Every line to show for [entry] — its knobs, plus one per parameter that
  /// cannot be one, saying why.
  ///
  /// One list, three surfaces. The `entrypoints` action, the running app's
  /// Knobs tab and the New run form each built this loop themselves, so a line
  /// added to one appeared on one. A `required` parameter is exactly such a
  /// line: it is not a knob, it is the reason there will be no launch, and all
  /// three have to say so. A parameter no control can be drawn for is the same
  /// kind of line — the scan has always known why, and nothing said it.
  List<RunKnobEntry> knobEntriesOf(String package, EntrypointRef entry) {
    var scan = knobsReadBy(package, entry.path);
    var undrawable = {
      for (var (:name, :reason) in scan.undrawable) name: reason,
    };
    return [
      for (var (:read, :declared) in knobsFor(package, entry))
        knobEntry(read, declared, undrawable: undrawable),
      // Only the ones no declaration already speaks for: a knob naming one is
      // its line, and two lines for one parameter is the list contradicting
      // itself.
      for (var (:name, :reason) in scan.undrawable)
        if (!entry.knobs.any((knob) => knob.name == name))
          RunKnobEntry(name: name, problem: _undrawable(name, reason)),
      for (var name in scan.required)
        RunKnobEntry(
          name: name,
          problem:
              'main requires this, so nothing can launch it. A knob has to be '
              "optional — give it a default (String $name = 'x') and it "
              'becomes one.',
        ),
    ];
  }

  /// Why a parameter `main` does take still cannot be a knob.
  ///
  /// Composed in one place because two surfaces say it — the launch form and
  /// the refusal a `launch` with that knob throws — and the whole point of the
  /// sentence is that it names the type instead of sending somebody to the
  /// signature.
  String _undrawable(String name, String reason) =>
      'main takes `$name`, but it $reason';

  /// One knob as the wire reports it — the signature's facts, the config's
  /// annotations, and a value worked out just now when a source could.
  RunKnobEntry knobEntry(
    ParameterKnob? read,
    Knob? declared, {
    Map<String, String> undrawable = const {},
  }) {
    var descriptor = read?.knob;
    var computed = declared == null ? null : computedValueOf(declared);
    // Only a knob the signature actually has. A declaration naming a parameter
    // that is not there already carries the typo as its problem, and marking it
    // required as well would say a launch is missing a value that nothing can
    // accept.
    var required = read != null && (declared?.required ?? false);
    return RunKnobEntry(
      name: read?.name ?? declared!.name,
      label: declared?.label,
      description: declared?.description,
      kind: descriptor?.kind.name,
      // A script's answer first, because it is the only one worked out just
      // now; then what the signature falls back to. There is deliberately no
      // config default — the parameter has one, and repeating it is the two
      // places to be wrong this design removes.
      //
      // **Except under `required`, where the parameter's own default is
      // withheld — in both spellings.** That is the whole content of the flag:
      // the default is a placeholder the entry point carries so the file still
      // runs under a plain `flutter run`, not a value to run against.
      // Reporting it would hand an agent a fallback that does not exist and
      // pre-fill the form's hint with it, so a knob nothing can supply reads as
      // one nobody needs to.
      //
      // [defaultSource] especially, because it is the likelier of the two to be
      // there: a required knob's placeholder is typically
      // `const String.fromEnvironment(…)`, which is exactly the const
      // [defaultValue] cannot read and this one can.
      defaultValue:
          computed ?? (required ? null : descriptor?.defaultValue?.toString()),
      // Only when nothing above produced a value. A script that answered has
      // said what the launch will use, and the spelling of a fallback nobody
      // reaches is noise beside it.
      defaultSource:
          required || computed != null || descriptor?.defaultValue != null
          ? null
          : read?.defaultSource,
      options: _knobOptions(descriptor, declared),
      problem: _knobProblem(read, declared, undrawable),
      required: required,
    );
  }

  /// What [knob]'s source works out for this launch, or null when it has none.
  ///
  /// One reading, because three callers want the same value for three
  /// different purposes and a source read differently by any of them would be
  /// a knob shown with one value and launched with another: [knobEntry] reports
  /// it as the default, [_resolveKnobs] passes it to `main`, and
  /// [requiredKnobsProblem] counts it as somebody having chosen.
  ///
  /// A [ScriptSource] answers only once [_resolveScripts] has run — before
  /// then this is null, which reads the same as a script that has not answered
  /// and is refused in the same place.
  String? computedValueOf(Knob knob) => switch (knob.from) {
    FlutterSdkSource() => host.workspace.flutterSdk.root,
    ScriptSource source => outcomeOf(source)?.value,
    _ => null,
  };

  /// The knobs in [recorded] that somebody actually **chose**.
  ///
  /// A launch bakes in everything a `from:` can work out ([_resolveKnobs]), and
  /// the handle records that merged set — so a handle's knobs are the values
  /// the app was *built with*, not the values anybody typed. The two are
  /// different things and only one of them is an instruction.
  ///
  /// This matters because the New run form reads [lastLaunch] on open, and its
  /// contract is the second one: a field left empty means *whatever the default
  /// is*, and a field with text in it is a deliberate override that gets sent.
  /// Priming it from the resolved set turns every derived value into a typed
  /// one — so a `Flutter SDK` knob that tracks whichever flutterware launched
  /// you becomes a frozen path, and a port a script works out per worktree
  /// becomes last worktree's port. That is the failure [_resolveKnobs] already
  /// describes: an app built against the wrong port is indistinguishable from a
  /// correct one until it is talking to another worktree's database.
  ///
  /// A recorded value that equals what the source computes now is dropped. The
  /// comparison errs safe in both directions: somebody who typed the computed
  /// value by hand loses nothing, because leaving the field alone re-derives
  /// exactly it — and a source that cannot answer right now (an unresolved
  /// script) keeps its value rather than silently discarding an override.
  Map<String, String> chosenKnobs(
    String package,
    EntrypointRef entry,
    Map<String, String> recorded,
  ) {
    var declaredByName = {
      for (var (:read, :declared) in knobsFor(package, entry))
        if (read != null && declared != null) declared.name: declared,
    };
    // A loop rather than a collection-if, and not for taste: the two-armed
    // version of this reads `if (declared) if (differs) keep; else keep;` —
    // where the `else` binds to the *inner* `if`, so every declared knob was
    // kept and every undeclared one dropped. Exactly backwards, and it looks
    // right.
    var chosen = <String, String>{};
    for (var knob in recorded.entries) {
      var declared = declaredByName[knob.key];
      if (declared != null && computedValueOf(declared) == knob.value) continue;
      chosen[knob.key] = knob.value;
    }
    return chosen;
  }

  /// Why a launch of [entry] with [values] cannot go ahead — the `required`
  /// knobs nothing has chosen a value for — or null when it can.
  ///
  /// Composed in one place because two surfaces say it, the rule
  /// [_undrawable] already follows: the New run page greys Start out with this
  /// sentence beside it, and `launch` throws it. A form offering a button the
  /// action would refuse is the tool disagreeing with itself, and the disagreement
  /// only shows up after a build.
  String? requiredKnobsProblem(
    String package,
    EntrypointRef entry,
    Map<String, Object?> values,
  ) {
    var missing = [
      for (var (:read, :declared) in knobsFor(package, entry))
        if (read != null && declared != null && declared.required)
          if (!values.containsKey(declared.name) &&
              computedValueOf(declared) == null)
            declared.name,
    ];
    if (missing.isEmpty) return null;
    return '${entry.name} needs ${missing.join(', ')} set. '
        'tool/flutterware.dart declares ${missing.length == 1 ? 'it' : 'them'} '
        'required, which means the parameter default is a placeholder rather '
        'than a value to run against — so launching without one would build, '
        'install and boot an app configured by nobody. Pass '
        '${missing.length == 1 ? 'it' : 'them'} to launch, or give the knob a '
        '`from:` that can work the value out.';
  }

  /// Everything worth offering: an enum's own constants, this machine's
  /// addresses, a script's list, or whatever the config wrote.
  List<String> _knobOptions(KnobDescriptor? descriptor, Knob? declared) {
    var options = [...?descriptor?.options];
    // **An enum's constants are the whole list.** The wrapper writes
    // `Backend.<value>`, so anything else cannot compile — offering it would
    // put a chip on screen that fails the launch it starts, and the value check
    // would refuse the very value the panel had just suggested. What the config
    // added is said out loud by [_knobProblem] instead of quietly dropped.
    if (descriptor?.kind == KnobKind.picker) return options;
    for (var option in declared?.options ?? const <String>[]) {
      if (!options.contains(option)) options.add(option);
    }
    switch (declared?.from) {
      case HostAddressesSource():
        for (var host in hostAddresses) {
          if (!options.contains(host.address)) options.add(host.address);
        }
      case ScriptSource source:
        // Only the list form. A script that computed a single value did not
        // offer a choice, and showing it twice — pre-filled and as a chip —
        // would suggest it did.
        for (var value in outcomeOf(source)?.options ?? const <String>[]) {
          if (!options.contains(value)) options.add(value);
        }
      case FlutterSdkSource():
        // There is one Flutter SDK behind a launch and it is already the
        // knob's default, so a chip offering it would be the same value twice
        // with the second one dressed as a choice.
        break;
      case null:
        break;
    }
    return options;
  }

  /// What is wrong with this knob, worst first.
  String? _knobProblem(
    ParameterKnob? read,
    Knob? declared,
    Map<String, String> undrawable,
  ) {
    if (declared?.from case ScriptSource source) {
      if (outcomeOf(source)?.problem case var problem?) {
        return '$problem. Until it answers, ${declared!.name} has no computed '
            'value and a launch that does not set it will be refused.';
      }
    }
    if (read == null) {
      // A parameter that is there and cannot be drawn is not a parameter that
      // is missing, and the two send somebody to different files. The scan
      // already worked out which this is; before, both came back as the typo.
      if (undrawable[declared!.name] case var reason?) {
        return _undrawable(declared.name, reason);
      }
      return 'main takes no `${declared.name}` parameter. The control would '
          'appear and do nothing — check the spelling against the signature.';
    }
    // A value offered for an enum that the enum does not declare. Worth saying
    // rather than dropping: it is a line in `tool/flutterware.dart` that reads
    // as working, and the only symptom would be a choice missing from a
    // dropdown that nothing explains.
    if (read.knob.kind == KnobKind.picker) {
      var constants = read.knob.options;
      var stray = {
        ...?declared?.options,
        ...switch (declared?.from) {
          ScriptSource source => outcomeOf(source)?.options ?? const <String>[],
          _ => const <String>[],
        },
      }..removeWhere(constants.contains);
      if (stray.isNotEmpty) {
        return '${stray.join(', ')} — offered for ${read.name}, which is an '
            'enum taking ${constants.join(', ')}. Only its own constants '
            'compile, so the rest are not offered.';
      }
    }
    return null;
  }

  Future<RunLaunchResult> _launchAction(Map<String, Object?> arguments) async {
    await computeAll();
    var device = arguments['device'] as String?;
    if (device == null) {
      throw ArgumentError.value(device, 'device', 'which device to run on');
    }
    var (package, entry) = _resolveEntrypoint(
      arguments['package'] as String?,
      arguments['entrypoint'] as String?,
    );
    _checkDevice(device, entry);
    var defines = PreviewsCore.parsePairs(arguments['dartDefines']);
    var knobs = PreviewsCore.parsePairs(arguments['knobs']);

    // The caller's word beats the entry point's declaration, and an empty
    // string is how a caller says "no flavor" about an entry point that
    // declares one.
    var flavor = switch (arguments['flavor']) {
      String given => given.isEmpty ? null : given,
      _ => flavorFor(package, entry, device: device).flavor,
    };
    // The two ways a flavor is quietly not passed, said out loud. Both drops
    // happen below this action — the vocabulary's in `launch`, web's in the
    // command builder — and a flag that silently went missing already
    // confused one agent into filing it as a fault.
    var flavorless =
        flavor != null && flavorVocabularyFor(package, device)?.isEmpty == true
        ? '$package declares no flavors on ${platformLabelFor(device)} — '
              'launched without --flavor, as on web.'
        : null;
    var web =
        flavor != null &&
            devices.any(
              (candidate) =>
                  candidate.id == device && candidate.platformType == 'web',
            )
        ? 'web takes no --flavor — launched without it.'
        : null;

    var handle = await launch(
      device: device,
      package: package,
      entry: entry,
      flavor: flavor,
      defines: defines,
      knobs: knobs,
    );

    var wait = _boolArgument(arguments['wait'] ?? true);
    var log = LaunchLog.read(handle.logPath ?? '', files: files);
    if (wait) {
      var timeout = Duration(seconds: _intArgument(arguments['timeout'], 300));
      try {
        (handle, log) = await awaitLaunch(
          handle,
          timeout,
          onProgress: (line) => _setLaunching(handle.key, Status.info(line)),
        );
      } finally {
        _setLaunching(handle.key, null);
      }
    }
    _handles = _scanHandles();
    await _probeAll();

    var probe = probeOf(handle) ?? await sources.apps.probe(handle);
    var failure = log.failure(launcherAlive: probe.launcher);
    var status = switch (log) {
      // A run that stopped without ever starting did not stop, it failed —
      // and saying `stopped` for it was how an iOS build that could not be
      // signed came back looking like something somebody had turned off.
      _ when failure != null || (log.stopped && !log.started) => 'failed',
      _ when log.stopped => 'stopped',
      _ when log.started => 'running',
      _ => 'starting',
    };
    if (status == 'failed') {
      // A launcher that never came up is not holding the device, and leaving
      // its handle behind would make the next person's `devices` say a phone
      // is busy running something that is not there. The log stays: it is
      // where the reason is, and [logPath] below is what points at it.
      recordFailure(handle, log);
      handle.delete();
      _handles = _scanHandles();
    }
    var stillBuilding =
        'Still building after the timeout. It has not failed — follow it '
        'with the apps action, or read ${handle.logPath}.';
    return RunLaunchResult(
      status: status,
      waited: wait,
      progress: log.stage,
      error:
          failure ?? (status == 'failed' ? 'the app stopped starting' : null),
      headline: status == 'failed' ? log.failureHeadline : null,
      logPath: status == 'failed' ? handle.logPath : null,
      note: _joinNotes([
        flavorless,
        web,
        if (status == 'starting' && wait) stillBuilding,
      ]),
      app: _appEntry(handle, probe),
    );
  }

  /// Starts a run. The panel's entry point too — a button that could only be
  /// reached through `invoke` would be behaviour the other surfaces could not
  /// see.
  ///
  /// [defines] is what the caller *chose*; the defaults and anything a script
  /// source computes are filled in here, so both surfaces bake in the same set.
  ///
  /// [knobs] are checked here rather than in the action. They used to be, on the
  /// grounds that the panel builds its fields from the same list and so cannot
  /// invent a name — true of names, false of *values*. A text field for an `int`
  /// parameter accepts `eight` on a desktop keyboard, and the generator then
  /// declined to write a literal it could not form: the argument vanished, the
  /// wrapper fell back to its no-knobs shape, the app ran on the parameter's own
  /// default, and the handle recorded `eight` — a cockpit showing a value the
  /// app was not using. A knob that quietly does nothing is the exact failure
  /// this design deleted `--dart-define` to escape.
  ///
  /// [flavor] is vetted here too, for the same both-surfaces reason: where the
  /// package declares its flavors per platform, an unlisted one refuses before
  /// the build, and a platform declared flavorless drops the flag the way web
  /// does.
  Future<RunHandle> launch({
    required String device,
    required String package,
    required EntrypointRef entry,
    String? flavor,
    Map<String, String> defines = const {},
    Map<String, String> knobs = const {},
  }) async {
    if (readOnly case var why?) throw RunRefusal(why);
    _checkKnobNames(package, entry, knobs);
    flavor = applyFlavorVocabulary(
      flavor: flavor,
      vocabulary: flavorVocabularyFor(package, device),
      package: package,
      platformLabel: platformLabelFor(device),
    );
    var resolvedKnobs = await _resolveKnobs(package, entry, knobs);
    var known = devices.where((candidate) => candidate.id == device);
    var deviceName = known
        .map((candidate) => candidate.displayName)
        .firstOrNull;
    var handle = await launchApp(
      sdk: host.workspace.flutterSdk,
      runDir: runDir,
      worktree: host.worktree.path,
      worktreeName: host.worktree.name,
      packageRoot: host.workspace.absolutePathOf(package),
      package: package,
      device: device,
      deviceName: deviceName,
      entrypoint: entry.path,
      entrypointName: entry.declared ? entry.name : null,
      flavor: flavor,
      // The device the daemon described, never the id: `chrome` and
      // `web-server` are the two we would think to name, and a browser the
      // daemon adds next would go on compiling into a wrapper it cannot see.
      // A device the cache has never mentioned is launchable on purpose, and
      // reads as not-web here — which wraps it, exactly as today.
      targetsWeb: known.any(
        (candidate) =>
            RunPlatform.byName(candidate.platformType ?? '') == RunPlatform.web,
      ),
      defines: defines,
      knobs: resolvedKnobs,
    );
    _handles = [handle, ..._handles];
    _watchBeats(handle);
    notifyChanged();
    return handle;
  }

  /// The package and entry point a launch means, or an [ArgumentError] naming
  /// what it could have meant.
  ///
  /// [selector] is a name or a package-relative path. Both, because a path is
  /// **not unique**: declaring one file several times under different names is
  /// the documented way to run one app against several configurations, and the
  /// name is the only thing that separates those.
  (String, EntrypointRef) _resolveEntrypoint(
    String? package,
    String? selector,
  ) {
    var candidates = package == null
        ? packages
        : [
            for (var candidate in packages)
              if (candidate == package) candidate,
          ];
    if (candidates.isEmpty) {
      throw ArgumentError.value(
        package,
        'package',
        'not a declared package; declared: ${packages.join(', ')}',
      );
    }
    var matches = [
      for (var candidate in candidates)
        for (var entry in entrypointsFor(candidate))
          if (selector == null ||
              entry.path == selector ||
              entry.name == selector)
            (candidate, entry),
    ];
    if (matches.isEmpty) {
      throw ArgumentError.value(
        selector,
        'entrypoint',
        'no such entry point; known: ${[for (var candidate in candidates)
          for (var entry in entrypointsFor(candidate)) _labelFor(entry)].join(', ')}',
      );
    }
    if (matches.length > 1) {
      throw ArgumentError.value(
        selector,
        'entrypoint',
        _ambiguity(matches, package),
      );
    }
    return matches.single;
  }

  /// How an entry point is offered back to a caller that has to pick one.
  ///
  /// The name, and the path too when they differ — a scanned entry point is
  /// named after its file, so `"App" (lib/main.dart)` is worth two words while
  /// `lib/main.dart` twice is not.
  static String _labelFor(EntrypointRef entry) =>
      entry.name == entry.path ? entry.path : '"${entry.name}" (${entry.path})';

  /// What to say when more than one entry point answers to a selector.
  ///
  /// Never the paths. The set this refusal exists for is usually one file
  /// declared several times, so their paths are the *same string* and listing
  /// them offers a choice between identical options — which is what this
  /// message used to do. What separates the matches is the name within a
  /// package and the package across them, so the refusal asks for whichever of
  /// the two actually differs.
  String _ambiguity(List<(String, EntrypointRef)> matches, String? package) {
    var packagesInPlay = {for (var (candidate, _) in matches) candidate};
    if (package == null && packagesInPlay.length > 1) {
      return 'ambiguous — ${matches.length} entry points match, in different '
          'packages. Pass `package` with one of: '
          '${packagesInPlay.join(', ')}';
    }
    var names = {for (var (_, entry) in matches) entry.name};
    if (names.length == matches.length) {
      return 'ambiguous — ${matches.length} entry points share this path. '
          'Pass `entrypoint` with one of the names: '
          '${names.map((name) => '"$name"').join(', ')}';
    }
    // Two declarations with one name in one package. Nothing the caller can
    // pass separates them, so the refusal is about the config, not the call.
    return 'ambiguous — ${matches.length} entry points match and share the '
        'name ${names.map((name) => '"$name"').join(', ')}. Give them distinct '
        'names in tool/flutterware.dart';
  }

  /// Refuses a device [entry] declared it cannot run on.
  ///
  /// Before the build rather than after it, which is the value: the
  /// alternative is a Gradle or Xcode failure minutes later saying something
  /// true about the toolchain and nothing about the choice that caused it.
  ///
  /// A device the daemon has never mentioned is *not* refused here — `launch`
  /// has always let a caller name one the cache has not caught up with, and
  /// turning that into an error would break launching onto a phone plugged in
  /// a second ago.
  void _checkDevice(String device, EntrypointRef entry) {
    if (entry.allowedPlatforms.isEmpty) return;
    var target = devices.where((candidate) => candidate.id == device);
    for (var candidate in target) {
      if (candidate.allowedBy(entry)) return;
      throw ArgumentError.value(
        device,
        'device',
        '${candidate.displayName} is '
            '${candidate.platformType ?? candidate.category ?? 'a platform'}, '
            'and ${entry.name} declares '
            '${[for (var platform in entry.platforms) platform.name].join(', ')}. '
            'Runs on: ${[for (var allowed in devicesFor(entry)) allowed.id].join(', ')}',
      );
    }
  }

  /// Refuses a knob name `main` does not take.
  ///
  /// The signature is the list, so this can be exact in a way the define check
  /// never could: a misspelled name is not a value that quietly does nothing,
  /// it is a parameter that is not there, and the error can recite the ones
  /// that are.
  void _checkKnobNames(
    String package,
    EntrypointRef entry,
    Map<String, String> given,
  ) {
    // Before the names, because it is not about them: a `required` named
    // parameter has no default to fall back to, so there is no launch to check
    // the knobs *of*. Refused here, by name, rather than left to the wrapper —
    // its no-knobs branch casts `main` to `FutureOr<void> Function()`, which a
    // function with a required parameter cannot satisfy, so the app died at
    // startup on a cast error that named nothing.
    var scan = knobsReadBy(package, entry.path);
    var required = scan.required;
    if (required.isNotEmpty) {
      throw RunRefusal(
        "${entry.name}'s main requires ${required.join(', ')}, so it cannot "
        'start without one. A knob has to be optional — give the parameter a '
        "default (String apiHost = 'localhost') and it becomes one.",
      );
    }
    var known = <String, ParameterKnob>{};
    for (var (:read, declared: _) in knobsFor(package, entry)) {
      if (read != null) known[read.name] = read;
    }
    for (var MapEntry(key: name, value: value) in given.entries) {
      var knob = known[name];
      if (knob == null) {
        // The same distinction the launch form draws, for the same reason: a
        // parameter with no control is not a parameter that is not there, and
        // reciting the ones that are would send somebody looking for a typo.
        var reason = scan.undrawable
            .where((parameter) => parameter.name == name)
            .firstOrNull
            ?.reason;
        var message = switch ((reason, known.isEmpty)) {
          (var reason?, _) => '${entry.name}: ${_undrawable(name, reason)}',
          (_, true) => "${entry.name}'s main takes no knobs",
          _ =>
            '${entry.name} has no such knob; it takes '
                '${known.keys.join(', ')}',
        };
        throw ArgumentError.value(name, 'knobs', message);
      }
      // Checked here rather than left to the compiler. The value becomes a
      // literal in generated source, so a bad one is a build failure pointing
      // at a file the user did not write — where this can say which knob, what
      // it takes, and what was passed.
      if (_knobValueProblem(knob, value) case var problem?) {
        throw ArgumentError.value(value, 'knobs', '$name $problem');
      }
    }
  }

  /// Why [value] is not one [knob] can take, or null when it is.
  String? _knobValueProblem(ParameterKnob knob, String value) =>
      switch (knob.knob.kind) {
        KnobKind.integer when int.tryParse(value) == null =>
          'takes a whole number, not "$value"',
        KnobKind.number when double.tryParse(value) == null =>
          'takes a number, not "$value"',
        KnobKind.boolean when value != 'true' && value != 'false' =>
          'takes true or false, not "$value"',
        KnobKind.picker when !knob.knob.options.contains(value) =>
          'takes ${knob.knob.options.join(', ')} — not "$value"',
        _ => null,
      };

  /// The values a launch will pass `main`: what the caller gave, over what a
  /// source computed just now.
  ///
  /// A parameter's own default is deliberately not passed. Writing it into the
  /// wrapper would record a deliberate choice where none was made, and the
  /// parameter already falls back to it — the same reasoning a define's scanned
  /// default was left alone for.
  ///
  /// A source that could not answer refuses the launch, as it does for a
  /// define and for the same reason: the value is compiled in, and an app built
  /// against the wrong port is indistinguishable from a correct one until it is
  /// talking to another worktree's database.
  Future<Map<String, Object?>> _resolveKnobs(
    String package,
    EntrypointRef entry,
    Map<String, String> given,
  ) async {
    await _resolveScripts([for (var knob in entry.knobs) knob.from]);
    var resolved = <String, Object?>{...given};
    var unresolved = <String>[];
    for (var (:read, :declared) in knobsFor(package, entry)) {
      if (read == null || declared == null) continue;
      if (resolved.containsKey(declared.name)) continue;
      if (declared.from case ScriptSource source) {
        var outcome = outcomeOf(source);
        if (outcome == null || outcome.failed) {
          unresolved.add(
            '${declared.name} (${outcome?.problem ?? 'not resolved'})',
          );
          continue;
        }
      }
      if (computedValueOf(declared) case var value?) {
        resolved[declared.name] = value;
      }
    }
    if (unresolved.isNotEmpty) {
      throw RunRefusal(
        'cannot work out ${unresolved.join(', ')}. Fix the script, or pass the '
        'knob explicitly to launch without it.',
      );
    }
    // Last, so a source that answered counts as somebody having chosen — and
    // after the failed-script refusal above, which is the more specific reason
    // for the same missing value.
    if (requiredKnobsProblem(package, entry, resolved) case var problem?) {
      throw RunRefusal(problem);
    }
    return resolved;
  }

  /// `setKnobs` — rewrite the wrapper with new values and hot restart.
  ///
  /// The agent's half of § K5: without it an agent can launch with knobs and
  /// then has to relaunch to change one, which is the rebuild this design
  /// exists to remove.
  Future<RunControlResult> _setKnobsAction(
    Map<String, Object?> arguments,
  ) async {
    // Before anything else: the entry points are what the values are checked
    // against, and without them the check silently passed — the restart then
    // failed on a wrapper that would not compile, reported as
    // `s1.hotRestart: (-32603)`, which says nothing to anybody.
    await computeAll();
    _handles = _scanHandles();
    await _probeAll();
    var handle = _selectApp(arguments, await _repoWorktrees);
    var values = PreviewsCore.parsePairs(arguments['knobs']);
    var started = DateTime.now();
    try {
      var running = await applyKnobs(handle, values);
      appendJournal(
        handle,
        JournalEntry(
          at: started.toUtc().toIso8601String(),
          verb: 'setKnobs',
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
        ),
      );
      return RunControlResult(
        action: 'setKnobs',
        run: handle.runId,
        device: handle.device,
        entrypoint: handle.entrypoint,
        ok: true,
        ms: DateTime.now().difference(started).inMilliseconds,
        // What it is running with, not what was asked for — the two differ
        // whenever a source filled in a knob this call left out.
        knobs: running,
      );
    } on Object catch (e) {
      return RunControlResult(
        action: 'setKnobs',
        run: handle.runId,
        device: handle.device,
        entrypoint: handle.entrypoint,
        ok: false,
        ms: DateTime.now().difference(started).inMilliseconds,
        error: '$e',
      );
    }
  }

  Future<RunControlResult> _controlAction(
    String action,
    Map<String, Object?> arguments,
  ) async {
    _handles = _scanHandles();
    await _probeAll();
    var handle = _selectApp(arguments, await _repoWorktrees);
    var started = DateTime.now();
    try {
      await control(action, handle);
      // Reloads and restarts are steps in the run's story too: the strip
      // that shows what the agent tapped should show what it reloaded
      // between the taps.
      appendJournal(
        handle,
        JournalEntry(
          at: started.toUtc().toIso8601String(),
          verb: action,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
        ),
      );
      return RunControlResult(
        action: action,
        run: handle.runId,
        device: handle.device,
        entrypoint: handle.entrypoint,
        ok: true,
        ms: DateTime.now().difference(started).inMilliseconds,
      );
    } on Object catch (e) {
      return RunControlResult(
        action: action,
        run: handle.runId,
        device: handle.device,
        entrypoint: handle.entrypoint,
        ok: false,
        ms: DateTime.now().difference(started).inMilliseconds,
        error: '$e',
      );
    }
  }

  /// The knobs [handle]'s entry point takes, or why they cannot be known.
  ///
  /// Empty and unknowable are different answers, and the tab distinguishes them
  /// — `unknown` is the sentence to show instead of the fields. Reporting an
  /// empty list for a run this core cannot read would claim the app takes no
  /// knobs, about source it has not read.
  ///
  /// The worktree check is the one that matters and is easy to miss: another
  /// checkout of the same repo has the same package paths and the same entry
  /// point names, so every lookup here *succeeds* — against source that may be
  /// on a different branch. The knobs shown would be plausible and wrong.
  ({List<RunKnobEntry> knobs, String? unknown}) knobEntriesFor(
    RunHandle handle,
  ) {
    if (!isMine(handle)) {
      return (
        knobs: const [],
        unknown:
            'This run belongs to ${handle.worktreeName}. Its knobs are '
            "declared in that checkout's source, which can be on another "
            'branch — so this one cannot say what it takes.',
      );
    }
    var package = handle.package;
    if (package == null || !packages.contains(package)) {
      return (
        knobs: const [],
        unknown:
            'This run was launched from a package this worktree does not '
            'declare, so there is no signature to read.',
      );
    }
    var entry = entrypointOf(handle);
    if (entry == null) {
      return (
        knobs: const [],
        unknown:
            '${handle.entrypoint} is no longer an entry point of $package — '
            'renamed or removed since this run started.',
      );
    }
    return (knobs: knobEntriesOf(package, entry), unknown: null);
  }

  /// Rewrites [handle]'s wrapper with [values] and hot restarts it.
  ///
  /// The whole point of the design, and the only place a human feels it.
  /// Changing a knob is a rewrite of one generated file plus a restart —
  /// measured at 262ms on desktop, 263ms on the iOS simulator and 3.07s on an
  /// Android emulator, against 29.6s and 38.6s to rebuild. Without this the only
  /// route back to the launch form is Stop, which is the rebuild.
  ///
  /// Restart, never reload. A value passed to `main` moves only when `main`
  /// runs again, and reload does not re-run it — so a reload here would report
  /// success and change nothing.
  ///
  /// The handle is rewritten too: the cockpit shows a run's current knobs, and
  /// one it had forgotten would be a field you can only overwrite blind. It
  /// moves with the wrapper — see the comment on the write below for why that
  /// has to happen before the restart rather than after it.
  /// Returns what the app is now running with, which is not always what was
  /// asked for: a knob left out of [values] is re-asked of its source.
  Future<Map<String, String>> applyKnobs(
    RunHandle handle,
    Map<String, String> values,
  ) async {
    if (readOnly case var why?) throw RunRefusal(why);
    // Refused before anything is written. `absolutePathOf` resolves in *this*
    // worktree, so applying to another checkout's run would rewrite this
    // worktree's wrapper and restart that app onto this worktree's code — a
    // wrong file and a wrong app, with nothing on screen to say so.
    if (!isMine(handle)) {
      throw RunRefusal(
        '${handle.entrypointLabel} belongs to ${handle.worktreeName}. Change '
        'its knobs from that checkout: this one would rewrite its own copy of '
        'the wrapper.',
      );
    }
    var package = handle.package;
    if (package == null) {
      throw RunRefusal(
        '${handle.entrypointLabel} was launched without a package, so there is '
        'no wrapper to rewrite.',
      );
    }
    var entry = entrypointOf(handle);
    if (entry == null) {
      // Refused rather than written unchecked. Without the entry point there is
      // nothing to validate against, and an unvalidated value becomes a literal
      // in generated source — a build failure in a file nobody wrote.
      throw RunRefusal(
        '${handle.entrypoint} is not an entry point this worktree knows, so '
        'its knobs cannot be checked. Run it from the worktree that declares '
        'it.',
      );
    }
    _checkKnobNames(package, entry, values);
    // The same fill-in a launch does, for the same reason. "Replaces the set"
    // is about what the *caller* chose, not about forgetting what the project
    // can work out: leaving `serverPort` out of a call that sets `backend`
    // would otherwise drop a script-computed port back to the parameter's
    // default — an app talking to another worktree's database, which is the one
    // failure `_resolveKnobs` refuses a launch over. A source that cannot
    // answer refuses this the same way.
    var resolved = {
      for (var MapEntry(:key, :value) in (await _resolveKnobs(
        package,
        entry,
        values,
      )).entries)
        key: '$value',
    };

    var packageRoot = host.workspace.absolutePathOf(package);

    // **Both writes happen before the restart, and roll back together.**
    // Recording afterwards looked safer — say it is running only once it is —
    // and it lost the values outright the first time the app being restarted
    // was *this* one. A hot restart tears down the root isolate, so nothing
    // queued after `await control(…)` ever ran: the wrapper on disk carried
    // `apiHost: r'10.0.0.49'`, the app came up on it, and the handle recorded
    // nothing at all, so the Knobs tab showed an empty field for a value the
    // app was plainly holding. Self-hosting is our own inner loop, and only
    // driving the real cockpit found it.
    var previous = handle.knobs;
    void write(Map<String, String> knobs) {
      writeGuestEntrypoint(
        packageRoot: packageRoot,
        entrypoint: handle.entrypoint,
        knobs: knobs,
      );
      handle.withKnobs(knobs).publish(runDir);
      _handles = [
        for (var other in _handles)
          if (other.handlePath == handle.handlePath)
            other.withKnobs(knobs)
          else
            other,
      ];
    }

    write(resolved);
    notifyChanged();
    try {
      await control('restart', handle);
    } on Object {
      // Put both back. A failed restart leaves the app on its old code, so a
      // wrapper on the new one would fail every later reload as well — on a
      // change nobody asked for any more — and a handle on the new one would
      // report values the app never took.
      try {
        write(previous);
      } on Object {
        // **The rollback may not throw.** `previous` was valid when it was set,
        // and the signature can have moved since — this is the edit-reload loop
        // the whole feature exists for. An unwritable literal would then escape
        // from inside this catch, so the `rethrow` never ran: the caller was
        // told the value was malformed instead of why the restart failed, and
        // because the generator throws before it writes, the wrapper was left
        // on the *new* values — the exact state being rolled back from.
        //
        // No knobs is the fallback because it always writes and always
        // compiles. The app keeps running whatever it already had; the next
        // reload puts it on the signature's defaults, which is the honest
        // answer once the old values no longer fit the signature.
        write(const {});
      }
      notifyChanged();
      rethrow;
    }
    return resolved;
  }

  /// Stands in for the VM service round trip, so a test can reach what happens
  /// *after* a restart lands. The same seam [debugRead] and [debugAct] are.
  Future<void> Function(String action, RunHandle handle)? debugControl;

  /// Does one thing to one running app. The panel's entry point as well.
  Future<void> control(String action, RunHandle handle) async {
    if (readOnly case var why?) throw RunRefusal(why);
    await _control(action, handle);
    // A reload or a restart that *returned* is the cockpit changing the app's
    // screen, and the Screen pane re-reads on it. Out here rather than beside
    // the two RPCs so that the stub path counts as well — a test standing in
    // for the VM service is standing in for a reload that worked — and so
    // that a throw skips it, which a `finally` would not.
    if (action == 'reload' || action == 'restart') {
      _screenMovedBy(handle: handle, cockpit: true);
      notifyChanged();
    }
  }

  Future<void> _control(String action, RunHandle handle) async {
    if (debugControl case var stub?) return stub(action, handle);
    var uri = handle.vmService;
    if (uri == null && action != 'stop') {
      throw RunRefusal(
        '${handle.entrypointLabel} has no VM service yet — it is still '
        'building. Watch ${handle.logPath}.',
      );
    }
    RunConnection? connection;
    try {
      if (uri != null) {
        connection = await RunConnection.connect(
          uri,
          // Stopping needs no registration at all — `ext.flutter.exit` is the
          // app's own — so it should not wait for one.
          waitFor: switch (action) {
            'reload' => const {'reloadSources'},
            'restart' => const {'hotRestart'},
            _ => const {},
          },
        );
      }
      switch (action) {
        case 'reload':
          await connection!.reload();
        case 'restart':
          await connection!.restart();
        case 'stop':
          // The app first, then its launcher. The other order leaves an
          // orphaned app running on the phone with nothing able to reload it,
          // which is the worst of both.
          _stopWatchingBeats(handle);
          _humanSinceStep.remove(_driveKey(handle));
          _screenMoved.remove(_driveKey(handle));
          _screenMovedByCockpit.remove(_driveKey(handle));
          unawaited(_driveSessions.remove(_driveKey(handle))?.close());
          unawaited(_nativeSessions.remove(_driveKey(handle))?.close());
          _nativeEchoes.remove(_driveKey(handle));
          await connection?.exitApp();
          // Current, not merely alive: this pid came out of a file that can
          // be a day old, and SIGTERM to a recycled number is SIGTERM to
          // whatever unrelated process holds it now.
          if (isProcessCurrent(handle.launcherPid, handle.startedAt)) {
            Process.killPid(handle.launcherPid, ProcessSignal.sigterm);
          }
          handle.delete();
          _handles = [
            for (var other in _handles)
              if (other.handlePath != handle.handlePath) other,
          ];
        default:
          throw ArgumentError.value(action, 'action', 'unknown');
      }
    } finally {
      unawaited(connection?.close());
      notifyChanged();
    }
  }

  /// The one running app a control action means.
  /// What the desk can offer to boot. Empty until [loadEmulators] has run.
  List<DaemonEmulator> get emulators =>
      debugEmulators ?? _daemon?.emulators ?? const [];

  /// A bootable list without a daemon, for a widget test.
  ///
  /// The desk's `boot` is the control the whole of this page exists to reach,
  /// and the only other way to put a row under it is to spawn a real
  /// `flutter daemon` — which [debugLive] exists to keep out of a test.
  @visibleForTesting
  List<DaemonEmulator>? debugEmulators;

  /// Asks the daemon what it could boot, for the desk.
  ///
  /// Separate from [track] because it is a second round trip that opening the
  /// panel does not need: a device list is what the cockpit opens with, and
  /// enumerating every AVD and simulator is a cost only the desk needs paid.
  ///
  /// Behind [debugLive] for the same reason [track] is. The desk is drawn
  /// whenever the launch form is, so mounting that page now asks for a daemon
  /// — right in the app, and in a widget test a subprocess and a pending timer
  /// that a pumped panel cannot settle. The tests that used to dodge this by
  /// publishing a run so the desk would not draw at all no longer can.
  Future<void> loadEmulators() async {
    if (!debugLive || readOnly != null) return;
    var daemon = await _acquireDaemon();
    await daemon.refreshEmulators();
    if (!isDisposed) notifyChanged();
  }

  /// Takes the device list again, and the bootable list with it. The desk's
  /// **Refresh**.
  ///
  /// A device list is a reading with an age on it, and until this existed the
  /// GUI could only report that age. `devices(refresh: true)` has always been
  /// there for an agent; a person looking at *taken 27m ago* beside a phone
  /// they had just plugged in had nothing to press. Both halves, because they
  /// go stale together — an emulator booted from a terminal is a new device
  /// *and* one fewer thing to boot.
  Future<void> refreshDesk() async {
    if (readOnly case var why?) throw RunRefusal(why);
    var daemon = await _acquireDaemon();
    await daemon.refresh();
    await daemon.refreshEmulators();
    if (!isDisposed) notifyChanged();
  }

  /// Boots one. The panel's entry point, and `bootEmulator`'s.
  Future<DaemonDevice?> bootEmulator(String id, {bool coldBoot = false}) async {
    if (readOnly case var why?) throw RunRefusal(why);
    var daemon = await _acquireDaemon();
    return daemon.launchEmulator(id, coldBoot: coldBoot);
  }

  /// Everything bootable, and whether it is already up.
  ///
  /// Costs a daemon — seconds — which is why it is its own action rather than
  /// part of `devices`: most callers want the desk, not the garage.
  Future<RunEmulatorsResult> _emulatorsAction() async {
    var daemon = await _acquireDaemon();
    var emulators = await daemon.refreshEmulators();
    return RunEmulatorsResult(
      emulators: [
        for (var emulator in emulators)
          RunEmulatorEntry(
            id: emulator.id,
            name: emulator.displayName,
            platform: emulator.platformType,
            booted: isEmulatorBooted(emulator, daemon.devices),
          ),
      ],
      note: emulators.isEmpty
          ? 'Nothing to boot. Android emulators come from the AVD manager and '
                'iOS simulators from Xcode.'
          : emulators.any((e) => e.platformType == 'ios')
          ? 'The iOS row opens the Simulator rather than naming one device, so '
                'it cannot say whether anything is booted. `devices` lists what '
                'actually is.'
          : null,
    );
  }

  Future<RunBootResult> _bootEmulatorAction(
    Map<String, Object?> arguments,
  ) async {
    var id = arguments['emulator'] as String?;
    if (id == null || id.isEmpty) {
      throw ArgumentError.value(id, 'emulator', 'Name one to boot');
    }
    var daemon = await _acquireDaemon();
    var started = DateTime.now();
    var device = await daemon.launchEmulator(
      id,
      coldBoot: _boolArgument(arguments['coldBoot']),
      timeout: Duration(seconds: _intArgument(arguments['timeout'], 120)),
    );
    return RunBootResult(
      emulator: id,
      started: true,
      device: device?.id,
      deviceName: device?.displayName,
      ms: DateTime.now().difference(started).inMilliseconds,
      note: device == null
          ? 'Started, but it had not appeared as a device before the wait ran '
                'out. It is probably still booting — check `devices`.'
          : null,
    );
  }

  /// Refreshes the ledger and picks the one app the arguments name.
  ///
  /// The same opening as [_controlAction]: a handle is a cache of its
  /// launcher's log, so topping it up is what lets a run started by somebody
  /// else — another `fw`, a GUI that has since closed — be read here.
  Future<RunHandle> _selectRunningApp(Map<String, Object?> arguments) async {
    _handles = _scanHandles();
    await _probeAll();
    return _selectApp(arguments, await _repoWorktrees);
  }

  /// What the last launch from this panel chose.
  ///
  /// Held here rather than in the page's state so it survives the page being
  /// closed and reopened, which is the reason it is here: running the same thing
  /// again should be opening the page and pressing Start. Deliberately not
  /// persisted to disk — "what I ran a minute ago" is a fact about this
  /// session, and restoring it from last week would be a worse guess than the
  /// first device in the list.
  /// Knobs rather than defines: the form has no define fields any more, so
  /// recording them was recording a map that is always empty, and the values
  /// actually chosen were the ones being dropped.
  ({
    String device,
    String package,
    String entrypoint,
    String? flavor,
    Map<String, String> knobs,
  })?
  lastLaunch;

  /// The picture and the widget tree of one run, from **one** reading.
  ///
  /// What the panel's Screen tab calls, and the reason `inspect` was merged
  /// into one action: the two are shown side by side, so they have to be the
  /// same frame. Two calls would be two moments, and a live app animates,
  /// fires timers and takes in data between them — the tree would describe a
  /// screen the picture no longer shows.
  ///
  /// The app's own walk first, when it has one. A run launched through
  /// flutterware carries the guest, and the guest's tree is the one with boxes,
  /// properties and resolved text styles in it — everything the pane's detail
  /// side had to say "structure and source only" about. A run that has no
  /// guest, or one attached to by something else, falls back to the service
  /// extension and the pane goes on saying it. The reply says which happened;
  /// see [InspectRead.fromGuest].
  ///
  /// Deliberately not extended to the `inspect` action, whose whole selling
  /// point is that it answers about an app that never heard of flutterware —
  /// and whose caller already has `act` when it wants the richer tree.
  Future<InspectRead> inspectRead(
    RunHandle handle, {
    bool tree = true,
    bool screenshot = true,
    bool semantics = false,
    bool summary = true,
  }) =>
      debugRead?.call(handle) ??
      sources.apps.read(
        handle,
        tree: tree,
        screenshot: screenshot,
        semantics: semantics,
        summary: summary,
      );

  /// Stands in for the VM service so the panel can be pumped in a test.
  ///
  /// The same seam scenarios has for its runner, and for the same reason: the
  /// pane's mount-and-read is where a `setState` on an ancestor slipped in, and
  /// nothing that needs a real app could ever have caught it.
  @visibleForTesting
  Future<InspectRead> Function(RunHandle handle)? debugRead;

  /// Puts a probe result in as though one had been taken.
  @visibleForTesting
  void debugSetProbe(RunHandle handle, RunProbe probe) {
    if (handle.handlePath case var path?) _probes[path] = probe;
  }

  /// The widget tree of one run, on its own.
  Future<InspectTree> inspectTree(RunHandle handle, {bool summary = true}) =>
      _withInspector(handle, (i) => i.tree(summary: summary));

  /// A picture of one run.
  Future<Uint8List> screenshot(RunHandle handle, {int? maxSide}) =>
      _withInspector(handle, (i) => i.screenshot(maxSide: maxSide));

  /// One run's log, read from the file rather than the app — so it works while
  /// the app is still building and after it has died.
  List<RunLogLine> readLogs(
    RunHandle handle, {
    RunLogSource? only,
    bool errorsOnly = false,
    int? tail,
  }) {
    var path = handle.logPath;
    if (path == null) return const [];
    return readRunLog(
      path,
      only: only,
      errorsOnly: errorsOnly,
      tail: tail,
      files: files,
    );
  }

  /// See [withRunInspector].
  Future<T> _withInspector<T>(
    RunHandle handle,
    Future<T> Function(RunInspector inspector) body,
  ) => withRunInspector(handle, body);

  /// Attaches to the app's channels for the length of one action.
  ///
  /// A fresh attach per call, deliberately. The alternative is a cached
  /// attachment per handle, and the cost of that is an undrained queue between
  /// calls: the app would ring events for a peer that might never
  /// return. Attaching costs one round trip and gives the ring's replay, which
  /// is what makes recent feed events readable at all from a stateless call.
  ///
  /// The peer id is unique per call for the same reason the cockpit's is
  /// unique per pane — two attachers sharing a queue race for it, and the
  /// drain that loses returns frames the winner already took.
  Future<T> _withPanels<T>(
    RunHandle handle,
    Future<T> Function(RunAttachment client, RunPanels panels) body,
  ) async {
    RunAttachment client;
    try {
      client = await sources.channels.attach(
        handle,
        peer: 'action:${_nextPanelPeer++}',
      );
    } on RunRefusal {
      rethrow;
    } on Object {
      // Not a failure of this call so much as a fact about the app: an app
      // that mounts no `Devbar` installs no channels, and saying which is the
      // difference between a bug hunt and reading one line.
      throw RunRefusal(
        '${handle.entrypointLabel} is not reporting any panels. An app '
        'reports them by mounting `Devbar(plugins: …)` around its own widget '
        'and being launched by flutterware.',
      );
    }
    try {
      return await body(client, RunPanels(client));
    } finally {
      await client.close();
    }
  }

  var _nextPanelPeer = 1;

  /// The events this attachment replayed, per feed, newest [limit] kept.
  Map<String, List<Map<String, Object?>>> _feedEvents(
    RunAttachment client,
    List<PanelDescriptor> panels,
    int limit,
  ) {
    if (limit <= 0) return const {};
    var wanted = {
      for (var panel in panels)
        for (var feed in panel.feeds) panel.feedChannel(feed.id),
    };
    var byChannel = <String, List<Map<String, Object?>>>{};
    for (var event in client.received) {
      if (!wanted.contains(event.channel)) continue;
      (byChannel[event.channel] ??= []).add({
        'event': event.id,
        'at': event.time.toIso8601String(),
        if (event.rid != null) 'rid': event.rid,
        ...event.payload,
      });
    }
    return {
      for (var entry in byChannel.entries)
        entry.key: entry.value.length <= limit
            ? entry.value
            : entry.value.sublist(entry.value.length - limit),
    };
  }

  Future<RunPanelsResult> _panelsAction(Map<String, Object?> arguments) async {
    var handle = await _selectRunningApp(arguments);
    var only = arguments['panel'] as String?;
    var limit = switch (arguments['events']) {
      null => 20,
      var value => _intArgument(value, 20),
    };
    return _withPanels(handle, (client, panels) async {
      var listed = await panels.list();
      var chosen = only == null
          ? listed
          : [
              for (var panel in listed)
                if (panel.id == only) panel,
            ];
      if (only != null && chosen.isEmpty) {
        throw RunRefusal(
          'This app declares no panel "$only" — it has '
          '${listed.isEmpty ? 'none' : listed.map((p) => p.id).join(', ')}.',
        );
      }
      return RunPanelsResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        panels: [for (var panel in chosen) panel.toJson()],
        events: _feedEvents(client, chosen, limit),
        note: listed.isEmpty
            ? 'The app is reporting, but no plugin declared a panel. A devbar '
                  'plugin joins by implementing `DevbarPanelSource`.'
            : null,
      );
    });
  }

  Future<RunPanelResult> _panelInvokeAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var panelId = _requiredArgument(arguments, 'panel');
    var actionId = _requiredArgument(arguments, 'action');
    var args = _jsonObjectArgument(arguments['args'], 'args');
    if (arguments['event'] case var event?) {
      args = {...args, 'event': _intArgument(event, 0)};
    }
    return _withPanels(handle, (client, panels) async {
      var result = await panels.invoke(panelId, actionId, args);
      return RunPanelResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        panel: panelId,
        result: result,
      );
    });
  }

  Future<RunPanelResult> _panelKnobAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var panelId = _requiredArgument(arguments, 'panel');
    var knob = _requiredArgument(arguments, 'knob');
    var raw = arguments['value'];
    return _withPanels(handle, (client, panels) async {
      var knobs = await panels.setKnob(panelId, knob, _looseValue(raw));
      var after = knobs.where((k) => k.name == knob).firstOrNull;
      return RunPanelResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        panel: panelId,
        result: {'knob': knob, 'value': after?.value},
        knobs: [for (var k in knobs) k.toJson()],
        note: after == null
            ? 'The app kept no knob called "$knob" — it may have been declared '
                  'by a screen that has since unmounted.'
            : null,
      );
    });
  }

  Future<RunPanelResult> _panelStateAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var panelId = _requiredArgument(arguments, 'panel');
    var stateId = _requiredArgument(arguments, 'state');
    return _withPanels(handle, (client, panels) async {
      var snapshot = await panels.state(panelId, stateId);
      return RunPanelResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        panel: panelId,
        result: snapshot,
      );
    });
  }

  static String _requiredArgument(Map<String, Object?> arguments, String id) {
    var value = arguments[id];
    if (value is String && value.isNotEmpty) return value;
    throw ArgumentError('`$id` is required');
  }

  /// One VM-service call against a running app's main isolate, with http
  /// capture armed on the way in — the guest-less fallback, and a 3ms no-op
  /// when the run guest already armed it in `main`.
  Future<T> _withHttpProfile<T>(
    RunHandle handle,
    Future<T> Function(RunConnection connection, String isolateId) body,
  ) async {
    var uri = handle.vmService;
    if (uri == null) {
      throw RunRefusal(
        '${handle.entrypointLabel} has no VM service yet — it is still '
        'building. Watch ${handle.logPath}.',
      );
    }
    var connection = await RunConnection.connect(uri);
    try {
      var isolateId = connection.isolateId;
      if (isolateId == null) {
        throw RunRefusal('${handle.entrypointLabel} has no isolate yet.');
      }
      await connection.service.httpEnableTimelineLogging(isolateId, true);
      return await body(connection, isolateId);
    } finally {
      await connection.close();
    }
  }

  Future<RunDeviceResult> _deviceAction(Map<String, Object?> arguments) async {
    var handle = await _selectRunningApp(arguments);
    var settings = await _deviceSettingsFor(handle);
    var read = await readDeviceSettings(handle);
    return RunDeviceResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      platform: settings.platform,
      settings: [for (var setting in read) setting.toJson()],
      note: _deviceNote(read),
    );
  }

  Future<RunDeviceResult> _setDeviceAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var settings = await _deviceSettingsFor(handle);
    var name = _requiredArgument(arguments, 'setting');
    var id = DeviceSettingId.byName(name);
    if (id == null) {
      throw RunRefusal(
        'No device setting called `$name`. `device` reports them: '
        '${DeviceSettingId.values.map((v) => v.name).join(', ')}.',
      );
    }
    var value = arguments['value'] as String? ?? '';
    var written = await writeDeviceSetting(handle, id, value);

    return RunDeviceResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      platform: settings.platform,
      settings: [written.toJson()],
      note: written.value == value
          ? null
          : 'Asked for "$value" and the device answered '
                '"${written.value ?? 'nothing'}". The reply is the re-read, '
                'not the request.',
    );
  }

  /// Every device setting for [handle], refusals included.
  ///
  /// Public because the strip over the Screen pane calls exactly this, and the
  /// `device` action calls it too. The panel adds no abilities: a chip is a
  /// drawing of what this returned, and pressing one is [writeDeviceSetting].
  ///
  /// Throws [RunRefusal] when nothing here can reach the device — the message
  /// names what would work, which is the useful half and is what the strip
  /// draws in place of chips.
  Future<List<DeviceSetting>> readDeviceSettings(RunHandle handle) async {
    // The same bargain [track] makes, and for the same reason: mounting a panel
    // may not spawn a process in a widget test. Working out *which device this
    // is* costs two, and reading it costs seven more — none of which a pumped
    // panel can settle.
    if (readOnly case var why?) throw RunRefusal(why);
    if (!debugLive) return const [];
    var settings = await _deviceSettingsFor(handle);
    return _refusing(() => settings.read(appSize: _appSizeFor(handle)));
  }

  /// Writes one setting, journals it, and answers with that setting **re-read**.
  ///
  /// The reply is what the device says now rather than what it was asked for.
  /// A refusal is journalled too, and then rethrown as a [RunRefusal]: a
  /// journal that only kept successes would read as a cleaner session than
  /// anyone had, and a refused rotation is exactly the step somebody comes back
  /// to when explaining a screenshot.
  Future<DeviceSetting> writeDeviceSetting(
    RunHandle handle,
    DeviceSettingId id,
    String value,
  ) async {
    if (readOnly case var why?) throw RunRefusal(why);
    var settings = await _deviceSettingsFor(handle);
    var clock = Stopwatch()..start();
    DeviceSetting written;
    try {
      written = await settings.write(id, value, appSize: _appSizeFor(handle));
    } on DeviceRefusal catch (e) {
      appendJournal(
        handle,
        JournalEntry(
          at: DateTime.now().toUtc().toIso8601String(),
          verb: 'set',
          actor: 'device',
          target: id.name,
          elapsedMs: clock.elapsedMilliseconds,
          error: e.toString(),
          failure: 'refused',
          device: {'setting': id.name, 'asked': value},
        ),
      );
      throw RunRefusal(e.toString());
    }

    appendJournal(
      handle,
      JournalEntry(
        at: DateTime.now().toUtc().toIso8601String(),
        verb: 'set',
        actor: 'device',
        target: id.name,
        elapsedMs: clock.elapsedMilliseconds,
        device: {
          'setting': id.name,
          'asked': value,
          'answered': ?written.value,
          'provenance': written.provenance.name,
        },
      ),
    );
    return written;
  }

  /// The backend for this run, or a refusal naming what would work.
  Future<DeviceSettings> _deviceSettingsFor(RunHandle handle) async {
    var settings = await _nativeSessionFor(handle).settings();
    if (settings != null) return settings;
    throw RunRefusal(
      "Nothing here can write ${handle.device}'s settings. A booted iOS "
      'simulator answers to `simctl` and an Android device to `adb`; a '
      'physical iPhone, macOS and the browser each have their own mechanisms '
      'and none of them is built yet. Set it on the device by hand — the '
      'commands are in '
      'docs/superpowers/specs/2026-08-24-run-device-tab-capability-findings.md.',
    );
  }

  /// The app's own root geometry, or null when nothing is answering.
  ///
  /// The one place a device and the app on it meet: an iOS simulator will not
  /// say which way up it is, and the app's width and height do. Null rather
  /// than an error when the app is dead or still building — the setting then
  /// reports `unknown`, which is the truth.
  AppSizeReader _appSizeFor(RunHandle handle) => () async {
    try {
      // `summary` left on, and it is load-bearing rather than a default taken
      // by accident: [inspectRead] only asks the *guest* for the tree when it
      // is summary, and the guest's walk is the one with boxes on it. Asking
      // for the full service tree instead returns nodes with no layout at all,
      // which read as "no app answering" against a perfectly healthy app.
      var read = await inspectRead(handle, tree: true, screenshot: false);
      var layout = _firstBox(read.tree?.root);
      if (layout == null) return null;
      return (width: layout.width, height: layout.height);
    } on Object {
      // No app answering — still building, already dead, or attached to
      // without a guest. The setting then says `unknown`, which is true.
      return null;
    }
  };

  /// The outermost box in the tree.
  ///
  /// Not `root.layout`: the tree's root is above the app's own widgets —
  /// `RootWidget` and the `View` under it lay nothing out — so the root's box
  /// is null on a perfectly healthy app, and reading it as one made orientation
  /// answer `unknown` against a running simulator. The first node that has a
  /// box is the window, and it is the app's outermost widget rather than the
  /// framework's.
  InspectLayout? _firstBox(InspectNode? node) {
    if (node == null) return null;
    if (node.layout case var layout?) return layout;
    for (var child in node.children) {
      if (_firstBox(child) case var found?) return found;
    }
    return null;
  }

  /// Said out loud when the reply would otherwise be read as more than it is.
  String? _deviceNote(List<DeviceSetting> settings) {
    var echoes = [
      for (var setting in settings)
        if (setting.provenance == DeviceProvenance.written) setting.id.name,
    ];
    var refused = settings
        .where((s) => s.state == DeviceSettingState.unavailable)
        .length;
    var echoed =
        'The value of ${echoes.join(' and ')} is the store it was written to '
        'rather than an answer — nothing on this platform reports it.';
    var whose =
        "These are the device's, not the run's: except where a row says "
        'per-app, a write reaches every app on it and outlives the run.';
    return [
      if (echoes.isNotEmpty) echoed,
      if (refused > 0)
        '$refused setting(s) this target cannot do are listed with the reason.',
      whose,
    ].join(' ');
  }

  Future<T> _refusing<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DeviceRefusal catch (e) {
      throw RunRefusal(e.toString());
    }
  }

  Future<RunNetworkResult> _networkAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var since = switch (arguments['since']) {
      null => null,
      var value => DateTime.fromMicrosecondsSinceEpoch(_intArgument(value, 0)),
    };
    var limit = switch (arguments['limit']) {
      null => 50,
      var value => _intArgument(value, 50),
    };
    return _withHttpProfile(handle, (connection, isolateId) async {
      var profile = await connection.service.getHttpProfile(
        isolateId,
        updatedSince: since,
      );
      var requests = profile.requests
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
      var dropped = requests.length > limit ? requests.length - limit : 0;
      if (dropped > 0) requests = requests.sublist(dropped);
      return RunNetworkResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        requests: [for (var r in requests) _networkRow(r)],
        cursor: profile.timestamp.microsecondsSinceEpoch,
        note: dropped > 0
            ? '$dropped older requests over the limit — raise `limit` or '
                  'pass `since` to page forward.'
            : requests.isEmpty && since == null
            ? 'Nothing recorded. Capture starts at launch for an app '
                  'flutterware launched, and from this call on for one it '
                  'attached to.'
            : null,
      );
    });
  }

  Future<RunNetworkRequestResult> _networkRequestAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var id = _requiredArgument(arguments, 'id');
    return _withHttpProfile(handle, (connection, isolateId) async {
      HttpProfileRequest detail;
      try {
        detail = await connection.service.getHttpProfileRequest(isolateId, id);
      } on RPCError {
        throw RunRefusal(
          "No request `$id` in ${handle.entrypointLabel}'s profile. Ids "
          'come from `network`, and a hot restart clears them.',
        );
      }
      return RunNetworkRequestResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        request: {
          ..._networkRow(detail),
          'requestHeaders': ?_headers(
            detail.request?.hasError ?? true ? null : detail.request?.headers,
          ),
          'responseHeaders': ?_headers(detail.response?.headers),
          'requestBody': ?_bodyText(detail.requestBody),
          'responseBody': ?_bodyText(detail.responseBody),
          'events': [
            for (var event in detail.events)
              {'at': event.timestamp.toIso8601String(), 'event': event.event},
          ],
        },
      );
    });
  }

  static Map<String, Object?> _networkRow(HttpProfileRequestRef request) => {
    'id': request.id,
    'method': request.method,
    'uri': request.uri.toString(),
    'status': ?networkStatusOf(request),
    'ms': ?networkDurationOf(request),
    'size': ?networkSizeOf(request),
    'start': request.startTime.toIso8601String(),
    'error': ?networkErrorOf(request),
  };

  static Map<String, Object?>? _headers(Map<Object?, Object?>? raw) =>
      raw?.map((key, value) => MapEntry('$key', value));

  /// A body as JSON can carry it: the text when it decodes, a byte count when
  /// it is binary, capped so one huge download does not swamp a reply.
  static String? _bodyText(List<int>? body) {
    if (body == null || body.isEmpty) return null;
    String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      return '<${body.length} bytes of binary data>';
    }
    const cap = 65536;
    if (text.length <= cap) return text;
    return '${text.substring(0, cap)}… (${text.length - cap} more characters '
        'truncated)';
  }

  /// A knob value the way a caller can actually type one: `true`, `3` and
  /// `"prod"` all arrive as strings from `fw` and from a form, and the app
  /// wants the real type. Anything that is not JSON is itself — a bare
  /// `Staging` is the string, not a syntax error.
  static Object? _looseValue(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  static Map<String, Object?> _jsonObjectArgument(Object? raw, String id) {
    if (raw == null) return const {};
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is! String || raw.isEmpty) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw ArgumentError('`$id` is not JSON: $e');
    }
    if (decoded is! Map) {
      throw ArgumentError(
        '`$id` must be a JSON object, not ${decoded.runtimeType}',
      );
    }
    return decoded.cast<String, Object?>();
  }

  /// One file per run, overwritten. A screenshot is an observation of a
  /// moment, and keeping every one would fill the run dir with unwanted
  /// pictures; a caller that wants to keep one says where.
  ///
  /// `runHandleKey` already carries the `app-` stem the handle and the log
  /// share, so the picture joins them rather than starting a third naming
  /// scheme.
  String _screenshotPathFor(RunHandle handle, Object? given) =>
      given is String && given.isNotEmpty
      ? given
      : p.join(
          runDir,
          '${runHandleKey(handle.worktree, handle.device, handle.entrypoint)}.png',
        );

  Future<RunScreenshotResult> _screenshotAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var out = _screenshotPathFor(handle, arguments['out']);
    var maxSide = switch (arguments['maxSide']) {
      null => null,
      var value => _intArgument(value, 0),
    };
    var started = DateTime.now();
    Uint8List bytes;
    try {
      bytes = await _withInspector(
        handle,
        (i) => i.screenshot(
          maxSide: maxSide == null || maxSide <= 0 ? null : maxSide,
        ),
      );
    } on AppNotStarted {
      // Rethrown carrying the log, because the caller cannot join these two
      // facts themselves: the inspector knows there is no tree and cannot see
      // the file, and the file holds the reason and cannot see the request.
      throw AppNotStarted(_withLauncherErrors(handle, null));
    }
    var file = File(out);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return RunScreenshotResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      path: file.absolute.path,
      bytes: bytes.length,
      ms: DateTime.now().difference(started).inMilliseconds,
    );
  }

  Future<RunInspectResult> _inspectAction(
    Map<String, Object?> arguments,
  ) async {
    var handle = await _selectRunningApp(arguments);
    var probe = probeOf(handle);
    var log = logOf(handle);
    var mine = handle.worktreeName == host.worktree.name;
    var wantsTree = _boolArgument(arguments['tree']);
    var full = _boolArgument(arguments['full']);
    var wantsShot = _boolArgument(arguments['screenshot']);
    var wantsErrors = arguments['errors'] == null
        ? true
        : _boolArgument(arguments['errors']);
    var limit = _intArgument(arguments['lines'], 200);
    var source = switch (arguments['source']) {
      'app' => RunLogSource.app,
      'tool' => RunLogSource.tool,
      'native' => RunLogSource.native,
      _ => null,
    };
    // Naming the source is asking for it: `source: native` with the flag off
    // would answer nothing, and nobody means that. Asking for the platform log
    // is asking for logs, for the same reason.
    var wantsNative =
        _boolArgument(arguments['native']) || source == RunLogSource.native;
    var wantsLogs = _boolArgument(arguments['logs']) || wantsNative;

    // The log first, and unconditionally reachable: it needs no connection, so
    // it is the half that still answers while the app is building or gone.
    var lines = wantsLogs
        ? readLogs(handle, only: source, tail: limit)
        : const <RunLogLine>[];
    var errors = wantsErrors
        ? readLogs(handle, errorsOnly: true, tail: limit)
        : const <RunLogLine>[];

    // The platform's own log, when asked for — a separate read against a
    // separate source, so its tail is its own. Appended rather than merged:
    // the launcher's lines carry no timestamp, so there is no honest order to
    // interleave them in, and a native flood may not evict the build output
    // somebody asked for in the same call.
    String? nativeCommand;
    var nativeNotes = <String>[];
    if (wantsNative) {
      var read = await readNativeLogs(handle, tail: limit);
      nativeCommand = read.command;
      if (read.note case var note?) nativeNotes.add(note);
      lines = [...lines, ...read.lines];
      if (wantsErrors) {
        errors = [...errors, ...read.lines.where((line) => line.error)];
      }
    } else if (wantsLogs) {
      if (await _unreadNativeLog(handle) case var hint?) nativeNotes.add(hint);
    }

    var up = probe?.canInspect ?? false;
    InspectTree? tree;
    String? shotPath;
    String? failure;
    if (up && (wantsTree || wantsShot)) {
      try {
        var read = await _withInspector(
          handle,
          (inspector) => inspector.read(
            tree: wantsTree,
            screenshot: wantsShot,
            summary: !full,
          ),
        );
        tree = read.tree;
        if (read.image case var bytes?) {
          var file = File(_screenshotPathFor(handle, arguments['out']));
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes);
          shotPath = file.absolute.path;
        }
      } on Object catch (e) {
        // Reported rather than thrown: the logs and the liveness in this same
        // answer are often what explains the failure.
        failure = '$e';
      }
    }

    var notes = [
      ?failure ?? _inspectNote(up: up, wanted: wantsTree || wantsShot),
      ...nativeNotes,
    ];

    return RunInspectResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      worktree: handle.worktreeName,
      mine: mine,
      up: up,
      reloadable: (probe?.canReload ?? false) && mine,
      progress: up ? null : log?.stage,
      tree: tree?.root?.toJson(),
      nodes: tree?.length,
      summary: wantsTree ? !full : null,
      screenshot: shotPath,
      logs: wantsLogs ? [for (var line in lines) _logEntry(line)] : null,
      logLines: wantsLogs ? lines.length : null,
      errors: wantsErrors && errors.isNotEmpty
          ? [for (var line in errors) _logEntry(line)]
          : null,
      log: handle.logPath,
      nativeLog: nativeCommand,
      note: notes.isEmpty ? null : notes.join('\n'),
    );
  }

  static RunLogEntry _logEntry(RunLogLine line) =>
      RunLogEntry(source: line.source.name, text: line.text, error: line.error);

  /// The platform's own log for one run, bounded by the run's own lifetime.
  ///
  /// A device log is machine-wide and remembers days; this run is the only
  /// slice of it worth reading. [RunHandle.startedAt] is that bound, and it is
  /// already on the handle — which also makes the read cheap, because a
  /// narrower window is a faster `log show`.
  Future<NativeLogRead> readNativeLogs(RunHandle handle, {int? tail}) async {
    var source = await _nativeSessionFor(handle).logSource();
    if (source == null) {
      return const NativeLogRead.unread(
        note:
            'There is no platform log flutterware can read on this device. It '
            'reads the iOS simulator, Android and macOS. A physical iOS device '
            'is not one of them — its log comes off `xcrun devicectl device '
            'console` or `idevicesyslog`, which is a different mechanism '
            'rather than a different argument, so run one of those by hand.',
      );
    }
    return source.read(since: handle.startedAt, tail: tail);
  }

  /// The line that stops a reader concluding "nothing happened".
  ///
  /// The failure this closes was silence. A launch whose native half was
  /// misbehaving answered `errors: []` and six lines of build narration, which
  /// reads as an uneventful, healthy run rather than as "look somewhere else"
  /// — and the somewhere else held the whole story. So a log read on a device
  /// whose platform log we are *not* reading is labelled as such.
  ///
  /// Only where the omission bites. macOS pipes the app's stdout and stderr
  /// through the launcher already, so a note there would be noise on the inner
  /// loop this repository lives in; and a device with no readable log at all
  /// has nothing to offer instead.
  Future<String?> _unreadNativeLog(RunHandle handle) async {
    var source = await _nativeSessionFor(handle).logSource();
    if (source == null || source.platform == NativeLogPlatform.macos) {
      return null;
    }
    return 'These are the lines `flutter run` forwarded, which on '
        '${source.platform.label} is the app and the engine only — anything '
        'a plugin logs from its own framework is filtered out before it gets '
        'here. Pass `native: true` to read the platform log as well.';
  }

  /// Held drive connections, one per run — the loop's fast path. A session
  /// drops its connection on any error and reconnects on the next call;
  /// closed here on stop and on dispose.
  final _driveSessions = <String, DriveSession>{};

  /// One collector per run, so a run nobody drives still tells its story.
  ///
  /// Started at launch rather than when a panel opens: the human tapping their
  /// own app is exactly the case with no panel in front of it, and a recorder
  /// that only runs while somebody is watching the Steps tab would be a
  /// recorder for the one case that does not need one.
  final _beatTrackers = <String, RunBeatTracker>{};

  /// What the poller collected that no agent has been told about yet, per run.
  ///
  /// The poller and an agent's `act` are two mouths on one buffer in the
  /// guest, and taking clears it — so once the poller is running it wins
  /// almost every race, and the `human` field of an act reply would come back
  /// empty. The facts would still be in the journal, but an agent would have
  /// to know to go and read it, where before they arrived unasked.
  ///
  /// So the host keeps them: the poller journals a beat *and* leaves it here,
  /// and the next act reply says what happened while nobody was asking.
  final _humanSinceStep = <String, List<Map>>{};

  /// Bound on that, matching the guest's own action cap. A run nobody ever
  /// drives would otherwise accumulate a session's worth of taps for an agent
  /// that never arrives.
  static const _humanSinceStepCap = 100;

  /// How many times this run's screen is known to have changed, and how many
  /// of those the cockpit itself caused.
  ///
  /// **Known**, never guessed. An app animates and takes in data with nobody
  /// touching it, and nothing here pretends to see that — what these count is
  /// the three moments the cockpit is *told* about: a reload or restart it
  /// asked for, a drive step it took, and a tap the beat poller collected.
  /// Anything else moves the app without moving these, which is why the pane
  /// they feed keeps its button.
  ///
  /// Two numbers rather than one because the pane does two different things
  /// with them. What the cockpit caused it re-reads, because the read is a
  /// consequence of something the user just asked for. What the *human* did
  /// it merely reports as stale — re-reading there would be a full render and
  /// a tree walk per tap, which is polling wearing a finger.
  final _screenMoved = <String, int>{};
  final _screenMovedByCockpit = <String, int>{};

  /// See [_screenMoved]. Safe on a handle nothing has moved yet: zero.
  (int moved, int byCockpit) screenClockOf(RunHandle handle) {
    var key = _driveKey(handle);
    return (_screenMoved[key] ?? 0, _screenMovedByCockpit[key] ?? 0);
  }

  void _screenMovedBy({required RunHandle handle, required bool cockpit}) {
    var key = _driveKey(handle);
    _screenMoved[key] = (_screenMoved[key] ?? 0) + 1;
    if (cockpit) {
      _screenMovedByCockpit[key] = (_screenMovedByCockpit[key] ?? 0) + 1;
    }
  }

  /// Collects the human's own steps from [handle] until it stops.
  ///
  /// Idempotent, and it shares the drive session's socket rather than opening
  /// one of its own.
  void _watchBeats(RunHandle handle) {
    var key = _driveKey(handle);
    if (_beatTrackers.containsKey(key)) return;
    var tracker = RunBeatTracker(
      drain: () => _driveSessionFor(handle).beats(),
      onBeats: (beats) => _journalHumanBeats(handle, beats),
    );
    _beatTrackers[key] = tracker;
    tracker.start();
  }

  /// Stands in for the poller so the collect-then-act sequence can be pumped
  /// in a test — the same seam [debugAct] is for the guest wire.
  @visibleForTesting
  void debugCollectBeats(RunHandle handle, List<Map> beats) =>
      _journalHumanBeats(handle, beats);

  void _stopWatchingBeats(RunHandle handle) =>
      _beatTrackers.remove(_driveKey(handle))?.dispose();

  /// Writes what the human did into the run's story, pictures and all.
  ///
  /// The same reconciliation the act path does, and for the same reason: this
  /// process's own native taps reach the guest as ordinary platform input and
  /// come back looking exactly like a finger. Without it every `adb shell
  /// input tap` would be journaled twice, once as its step and once as a
  /// phantom human.
  void _journalHumanBeats(RunHandle handle, List<Map> beats) {
    var (human, _) = _reconcileHuman(handle, beats);
    _writeHumanBeats(handle, human);
    var pending = _humanSinceStep[_driveKey(handle)] ??= [];
    pending.addAll(human);
    if (pending.length > _humanSinceStepCap) {
      pending.removeRange(0, pending.length - _humanSinceStepCap);
    }
    if (human.isNotEmpty) _screenMovedBy(handle: handle, cockpit: false);
    notifyChanged();
  }

  /// Writes already-reconciled beats, pictures and all.
  ///
  /// **One writer, because there are two mouths.** A beat reaches the host
  /// either through this poller or through an agent's `act`, whichever drained
  /// the guest first — and which one it was is not something a reader of the
  /// story should be able to tell. The act path used to write `at`, `verb` and
  /// `target` only, so a tap the agent happened to collect lost the picture
  /// the guest had already taken for it.
  void _writeHumanBeats(RunHandle handle, List<Map> human) {
    for (var beat in human) {
      var at =
          beat['at'] as String? ?? DateTime.now().toUtc().toIso8601String();
      var shot = (beat['screenshot'] as Map?)?.cast<String, Object?>();
      var texts = (beat['texts'] as List?)?.cast<String>();
      var capture = shot == null && texts == null
          ? null
          : _Capture.write(
              handle: handle,
              stamp:
                  '${DateTime.tryParse(at)?.millisecondsSinceEpoch ?? 0}-$pid',
              at: DateTime.tryParse(at) ?? DateTime.now(),
              verb: beat['verb'] as String? ?? 'tap',
              target: beat['target'] as String?,
              shot: shot,
              texts: texts,
            );
      appendJournal(
        handle,
        JournalEntry(
          at: at,
          verb: beat['verb'] as String? ?? 'tap',
          actor: 'human',
          target: beat['target'] as String?,
          capture: capture?.address,
          screenshot: capture?.shot,
          texts: capture?.texts,
        ),
      );
    }
  }

  String _driveKey(RunHandle handle) =>
      handle.handlePath ?? handle.vmService ?? handle.entrypoint;

  DriveSession _driveSessionFor(RunHandle handle) =>
      (_driveSessions[_driveKey(handle)] ??= DriveSession(handle))
        ..refresh(handle);

  /// Stands in for the guest wire so the act path can be pumped in a test —
  /// the same seam [debugRead] is for inspect.
  @visibleForTesting
  Future<Map<String, dynamic>> Function(RunHandle, Map<String, String>)?
  debugAct;

  /// Held native drivers, one per run — same lifecycle as [_driveSessions],
  /// and the same reason: a driver learns its device and should not have to
  /// relearn it every call.
  final _nativeSessions = <String, NativeSession>{};

  NativeSession _nativeSessionFor(RunHandle handle) {
    var session = _nativeSessions[_driveKey(handle)] ??= NativeSession(handle);
    return session..debugAvailable = debugNativeAvailable;
  }

  /// Stands in for "does this machine have a native layer for that device",
  /// so a test of the drive path does not shell out to `adb` and `xcrun` to
  /// be told what it already knows. The same seam [debugAct] is.
  @visibleForTesting
  bool? debugNativeAvailable;

  /// `act`, `observe` and `navigate` — one funnel, because the last two are
  /// the first with the verb fixed.
  Future<RunActResult> _actAction(Map<String, Object?> arguments) async {
    var handle = await _selectRunningApp(arguments);
    var verb = arguments['verb'] as String? ?? 'observe';
    var actor = arguments['actor'] as String? ?? 'agent';
    if (arguments['layer'] == 'native') {
      return _nativeAct(handle, arguments, verb: verb, actor: actor);
    }
    // The lens sets the defaults; anything the caller named beats it. A
    // preset that overrode what was actually asked for would be a trap.
    var pinned = pinnedLens(handle);
    var lens = ObserveLens.byName(arguments['lens'] as String?);
    if (lens == null && arguments['lens'] != null) {
      return RunActResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        worktree: handle.worktreeName,
        verb: verb,
        ok: false,
        error: ObserveLens.unknown('${arguments['lens']}'),
        journal: journalPathFor(handle),
      );
    }
    var through = lens ?? pinned ?? ObserveLens.act;
    var wantsTree = _boolArgument(arguments['tree'] ?? through.tree);
    var wantsShot = _boolArgument(arguments['screenshot'] ?? through.picture);
    // The guest sends the whole tree, unfiltered, every step, and the shaping
    // all happens here: the screen is projected from it, `find`/`at`/`styles`
    // are answered from it, and the journal archives it whole. That last one
    // is the point of moving the narrowing across the wire — a journal holding
    // whatever the call happened to ask for is a record of the answer, and
    // what a reviewer wants is a record of the screen.
    // `item: N` is a position on the screen this run last reported, and it
    // becomes a point before it reaches the guest — so it resolves through
    // the same ladder as every other target and a covered or vanished item is
    // refused rather than tapped blind.
    String? itemNote;
    var wireArguments = arguments;
    if (arguments['item'] case var wanted? when '$wanted'.isNotEmpty) {
      switch (_pointForItem(handle, wanted)) {
        case _ItemPoint(:var target, :var described):
          wireArguments = {...arguments, 'target': target};
          itemNote = described;
        case _ItemMiss(:var why):
          return RunActResult(
            device: handle.device,
            entrypoint: handle.entrypoint,
            worktree: handle.worktreeName,
            verb: verb,
            ok: false,
            error: why,
            failure: 'notFound',
            journal: journalPathFor(handle),
          );
      }
    }

    // One capture per step, at one cap, whatever the caller wants to see.
    // Declining the picture makes it cheap rather than absent: measured at
    // ~46ms against ~234ms, which is the difference between an archive that
    // can answer a later question and one that has a hole in it.
    var maxSide =
        int.tryParse('${arguments['maxSide'] ?? ''}') ?? _replyMaxSide;
    var wire = <String, String>{
      'verb': verb,
      'maxSide': '${wantsShot ? maxSide : _declinedMaxSide}',
      for (var key in const [
        'target',
        'text',
        'dx',
        'dy',
        'within',
        'step',
        'maxScrolls',
        'route',
        'keys',
        'gapMs',
        'waitMs',
        'holdMs',
        'settleMs',
        'actTimeoutMs',
      ])
        if (wireArguments[key] case var value?) key: '$value',
    };
    var started = DateTime.now();

    Map<String, dynamic> reply;
    try {
      reply =
          await (debugAct?.call(handle, wire) ??
              _driveSessionFor(handle).act(wire));
    } on Object catch (e) {
      // A guest-less app is a fact about how it was launched, not a fault —
      // and it is [DriveSession]'s to establish, since only it can ask the VM
      // which isolate the extension is in. A bare -32601 reaching here comes
      // from something that bypassed the session, and gets the same sentence
      // without the census the session would have added.
      var error = e is RPCError && e.code == -32601
          ? DriveNoGuest.describe()
          : '$e';
      // The timeout says "bring the app to the front" — which used to be a
      // request only a human could carry out. On a device with a native
      // driver the agent can do it itself, so the sentence that reports the
      // dead end also says the way out of it.
      if (e is DriveTimeout && await _nativeSessionFor(handle).isAvailable) {
        error =
            '$error\nYou can do that from here: '
            '`act {verb: foreground, layer: native}`.';
      }
      appendJournal(
        handle,
        JournalEntry(
          at: started.toUtc().toIso8601String(),
          verb: verb,
          actor: actor,
          target: arguments['target'] as String?,
          error: error,
        ),
      );
      return RunActResult(
        device: handle.device,
        entrypoint: handle.entrypoint,
        worktree: handle.worktreeName,
        verb: verb,
        ok: false,
        error: error,
        journal: journalPathFor(handle),
      );
    }

    var read = ScreenRead.of(
      switch ((reply['tree'] as Map?)?.cast<String, Object?>()) {
        var json? => InspectTree.fromJson(json),
        null => null,
      },
      arguments,
      wantsTree: wantsTree,
      wantsStyles: _boolArgument(arguments['styles'] ?? through.styles),
      worktree: handle.worktree,
    );
    var step = (reply['step'] as Map?)?.cast<String, Object?>();
    var settle = (step?['settle'] as Map?)?.cast<String, Object?>();
    var failure = reply['failure'] as String?;
    var error = reply['error'] as String?;
    // **The app could not say why, so the launcher has to.** `notStarted` is
    // the guest reporting that nothing was ever mounted, which it can detect
    // and cannot explain: the exception that stopped `main` was written to the
    // process's stderr by the engine, and the guest has no more access to that
    // file than it has to a widget tree. The reason is in the log this handle
    // already names, so it rides the refusal rather than waiting for a second
    // call that the reader has to know to make.
    if (failure == 'notStarted') error = _withLauncherErrors(handle, error);
    var treeJson = (reply['tree'] as Map?)?.cast<String, Object?>();
    var texts = (reply['texts'] as List?)?.cast<String>();
    var logs = (reply['logs'] as List?)?.cast<Map>();
    var guestErrors = (reply['errors'] as List?)?.cast<Map>();
    var framesEnabled = settle?['framesEnabled'] as bool?;
    var (human, reconciled) = _reconcileHuman(
      handle,
      (reply['human'] as List?)?.cast<Map>() ?? const [],
    );
    // Told once. Anything the poller collected since the last step is reported
    // now and dropped, so two acts in a row do not both claim the same tap.
    var humanForReply = [
      ...?_humanSinceStep.remove(_driveKey(handle)),
      ...human,
    ];

    var capture = _Capture.write(
      handle: handle,
      stamp: '${started.millisecondsSinceEpoch}-$pid',
      at: started,
      verb: (step?['verb'] as String?) ?? verb,
      target: itemNote ?? step?['target'] as String?,
      shot: (reply['screenshot'] as Map?)?.cast<String, Object?>(),
      tree: treeJson,
      semantics: (reply['semantics'] as Map?)?.cast<String, Object?>(),
      texts: texts,
      screen: read.screen,
      reported: read.reported(wantsShot: wantsShot),
    );
    var shotPath = capture?.shot;
    var treePath = capture?.tree;
    var textsPath = capture?.texts;

    // What the human did on the way here, ahead of the step that saw it —
    // the guest buffers between transactions, so these precede this step in
    // wall time and must precede it in the story too.
    _writeHumanBeats(handle, human);

    appendJournal(
      handle,
      JournalEntry(
        at: started.toUtc().toIso8601String(),
        verb: (step?['verb'] as String?) ?? verb,
        actor: actor,
        // `item 20 "All / 15"` rather than the point it became: the number
        // and the words are what the caller said and what a reviewer can
        // recognise, where `{"at":{"x":30,"y":35}}` is neither.
        target:
            itemNote ??
            step?['target'] as String? ??
            arguments['target'] as String? ??
            arguments['route'] as String?,
        error: error,
        failure: failure,
        attempts: step?['attempts'] as int?,
        elapsedMs: step?['elapsedMs'] as int?,
        settled: settle?['settled'] as bool?,
        settleMs: settle?['elapsedMs'] as int?,
        lifecycle: reply['lifecycle'] as String?,
        capture: capture?.address,
        reported: read.reported(wantsShot: wantsShot),
        screenshot: shotPath,
        tree: treePath,
        texts: textsPath,
        semantics: capture?.semantics,
        logLines: logs?.length,
        errorCount: guestErrors?.length,
        reconciled: reconciled == 0 ? null : reconciled,
      ),
    );

    // `observe` is the one verb that changes nothing, so it is the one verb
    // that does not make the Screen pane's reading stale.
    if (((step?['verb'] as String?) ?? verb) != 'observe') {
      _screenMovedBy(handle: handle, cockpit: true);
      notifyChanged();
    }

    return RunActResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      worktree: handle.worktreeName,
      verb: (step?['verb'] as String?) ?? verb,
      target:
          itemNote ??
          step?['target'] as String? ??
          arguments['target'] as String?,
      // The picture is *shown* when it was asked for — or when the step went
      // wrong, because "look at it yourself" is the one useful thing to say to
      // an agent whose target was refused or whose app threw. It is archived
      // either way, so this decides what enters a context window, not what
      // exists.
      screenshotArtifact:
          shotPath == null ||
              !(wantsShot ||
                  error != null ||
                  (guestErrors?.isNotEmpty ?? false))
          ? null
          : Artifact(
              kind: Artifact.png,
              address: Address(
                worktree: host.worktree.name,
                plugin: runPluginId,
                segments: [handle.key, 'steps'],
              ),
              path: shotPath,
              meta: {
                'verb': (step?['verb'] as String?) ?? verb,
                if (step?['target'] case String target) 'target': target,
                if (settle?['settled'] == false) 'settled': false,
              },
            ),
      ok: error == null,
      error: error == null
          ? null
          : '$error${await _nativeHint(handle, failure)}',
      failure: failure,
      reconciled: reconciled == 0 ? null : reconciled,
      attempts: step?['attempts'] as int?,
      elapsedMs: step?['elapsedMs'] as int?,
      settled: settle?['settled'] as bool?,
      settleMs: settle?['elapsedMs'] as int?,
      frames: settle?['frames'] as int?,
      framesEnabled: framesEnabled,
      lifecycle: reply['lifecycle'] as String?,
      // What the poller already collected, then what this call's own take
      // found — both in the order they happened. Only the second half is
      // journaled here; the first was journaled when it was collected.
      human: humanForReply.isEmpty
          ? null
          : [
              for (var action in humanForReply)
                '${action['verb']} ${action['target']}',
            ],
      texts: texts,
      capture: capture?.address,
      // Named on every reply, because a pinned lens is state somebody else
      // may have set — a human, or another agent co-driving this run. The
      // marker is the difference between "this is the default" and "someone
      // chose this", which is the whole of what makes hidden state survivable.
      lens: lens == null && pinned != null
          ? '${through.name} (pinned)'
          : through.name,
      screen: read.screen,
      tree: read.tree,
      nodes: read.nodes,
      find: read.find,
      at: read.at,
      styles: read.styles,
      screenshot: shotPath,
      logs: logs == null
          ? null
          : [
              for (var line in logs)
                RunLogEntry(source: 'app', text: line['text'] as String? ?? ''),
            ],
      errors: guestErrors == null
          ? null
          : [
              for (var guestError in guestErrors)
                RunLogEntry(
                  source: 'app',
                  text: [
                    guestError['exception'] as String? ?? '',
                    if (guestError['context'] case String context) '($context)',
                    if (guestError['count'] case int count when count > 1)
                      '×$count',
                  ].join(' '),
                  error: true,
                ),
            ],
      journal: journalPathFor(handle),
      next: ScreenRead.offer,
      note: _note([
        // The tree was refused and the rest of the step was not, so it rides
        // the note rather than `error`: the verb landed, and saying it did
        // not would send the caller back to redo it.
        read.note,
        if (framesEnabled == false) _hiddenWindowNote,
      ]),
    );
  }

  /// The reply's screenshot cap when a caller asks for a picture and names no
  /// size.
  ///
  /// 900 rather than 1200: ~810 image tokens against ~1440 and 143ms against
  /// 234, and this GUI's 10.5pt text is still legible at it. A caller that
  /// needs the pixels asks for them.
  /// Reading or pinning the run's lens.
  Future<RunLensResult> _lensAction(Map<String, Object?> arguments) async {
    var handle = await _selectRunningApp(arguments);
    var wanted = arguments['lens'] as String?;
    var before = pinnedLens(handle);

    ObserveLens? pin;
    var changing = wanted != null && wanted.isNotEmpty;
    if (changing && wanted != 'none') {
      pin = ObserveLens.byName(wanted);
      if (pin == null) throw ArgumentError(ObserveLens.unknown(wanted));
      pinLens(handle, pin);
    } else if (changing) {
      pinLens(handle, null);
    }

    var now = changing ? pin : before;
    return RunLensResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      lens: (now ?? ObserveLens.act).name,
      pinned: now != null,
      // Only when it moved: "was act, is act" reads as a change and was not.
      was: changing && before?.name != now?.name
          ? (before ?? ObserveLens.act).name
          : null,
      lenses: [
        for (var lens in ObserveLens.values)
          {
            'lens': lens.name,
            'screen': true,
            'picture': lens.picture,
            'styles': lens.styles,
            'tree': lens.tree,
          },
      ],
    );
  }

  static const _replyMaxSide = 900;

  /// The cap for the archive-only picture, when the caller declined one.
  ///
  /// Small on purpose — it exists so a later question about this step has a
  /// frame to look at, not so it can be zoomed. ~46ms.
  static const _declinedMaxSide = 600;

  static const _hiddenWindowNote =
      'The window is hidden or occluded; every frame this step saw was '
      'forced. What a human sees on screen may lag this reply.';

  static String? _note(List<String?> parts) {
    var said = [
      for (var part in parts)
        if (part != null && part.isNotEmpty) part,
    ];
    return said.isEmpty ? null : said.join(' ');
  }

  /// The sentence that teaches the other layer, appended to a drive refusal.
  ///
  /// This is how the native layer is discovered at all: not from documentation
  /// an agent read once, but at the moment it is looking for something the
  /// widget tree does not have — a permission dialog, a button inside a
  /// webview, the keyboard. The refusal is where the next move belongs, which
  /// is the same rule the rest of this surface already follows.
  ///
  /// Only for `notFound`, and only when this device actually has a driver: an
  /// ambiguous target or a covered widget is a drive-layer problem, and
  /// pointing at a layer that does not exist here would be advice that fails.
  Future<String> _nativeHint(RunHandle handle, String? failure) async {
    if (failure != 'notFound') return '';
    if (!await _nativeSessionFor(handle).isAvailable) return '';
    return '\nIf this is not a Flutter widget — a permission dialog, a '
        'webview, the keyboard, anything the platform draws — the native '
        'layer may see it: retry with layer: native.';
  }

  /// When this run's native layer injected input, so the guest's report of it
  /// can be recognised as an echo rather than journaled as a human.
  ///
  /// The guest cannot tell an injected tap from a finger: an `adb shell input
  /// tap` and an `AXPress` both arrive as ordinary platform input, on the same
  /// global pointer route the human-action recorder watches. Without this,
  /// every native tap the agent makes appears twice in the story — once as its
  /// own step, once as a phantom human's — and the Steps strip then reports
  /// clicks that never happened.
  ///
  /// Windows rather than target sentences, because the two sides genuinely
  /// name things differently: the native layer resolved `"Increment"` while
  /// the guest's ancestor walk called the same tap `tooltip 'Increment'`
  /// (measured). Time is the signal both agree on.
  final _nativeEchoes = <String, List<_NativeEcho>>{};

  void _recordNativeEcho(RunHandle handle, DateTime from, DateTime to) {
    var echoes = _nativeEchoes[_driveKey(handle)] ??= [];
    echoes.add(_NativeEcho(from, to.add(const Duration(milliseconds: 750))));
    // A native step whose echo never arrives — the app was not driveable, or
    // the human tapped nothing — must not sit here forever poisoning a later
    // reconciliation.
    echoes.removeWhere(
      (echo) => DateTime.now().difference(echo.to) > const Duration(minutes: 2),
    );
  }

  /// Drops the human entries that are this process's own native taps coming
  /// back, and says how many. Returns what a real human did.
  (List<Map>, int) _reconcileHuman(RunHandle handle, List<Map> human) {
    var echoes = _nativeEchoes[_driveKey(handle)];
    if (echoes == null || echoes.isEmpty) return (human, 0);
    var kept = <Map>[];
    var dropped = 0;
    for (var action in human) {
      var at = DateTime.tryParse(action['at'] as String? ?? '')?.toUtc();
      var echo = at == null
          ? null
          : echoes.where((candidate) => candidate.contains(at)).firstOrNull;
      if (echo == null) {
        kept.add(action);
        continue;
      }
      // One echo answers for one entry: a native tap produces one recorded
      // action, and a human who really did tap inside the same window should
      // keep their line.
      echoes.remove(echo);
      dropped++;
    }
    return (kept, dropped);
  }

  /// What every native observation says about itself.
  ///
  /// The scale sentence is not decoration: the picture is retina and the
  /// coordinates are not, so an agent reading a point off the screenshot and
  /// passing it straight to `{"at": …}` would tap at half the intended place.
  /// Stating the factor is cheaper than a class of silent misses.
  static String _nativeNote(NativeObservation observation) {
    var origin = observation.screenshotOrigin;
    // The crop moved the origin, so the translation is two steps rather than
    // one — and an unstated second step is exactly the silent miss the first
    // one was written to prevent.
    var cropped = origin == null
        ? '.'
        : ', then add its origin ${origin.left.round()},'
              '${origin.top.round()}: the picture is cropped to this app'
              "'s windows and starts there.";
    var picture =
        'This screenshot is the real device screen, not a raster of the '
        'Flutter layer. Coordinates are ${observation.coordinateSpace} and '
        'the picture is ${observation.screenshotScale ?? 1}× that, so divide '
        'before passing a point you read off it to {"at": …}$cropped';
    return [
      picture,
      ?observation.note,
      'Flutter widgets are addressed better without `layer`.',
    ].join(' ');
  }

  /// The native half of the act funnel: the same transaction, against the
  /// platform's own tree instead of Flutter's.
  Future<RunActResult> _nativeAct(
    RunHandle handle,
    Map<String, Object?> arguments, {
    required String verb,
    required String actor,
  }) async {
    var session = _nativeSessionFor(handle);
    var wantsTree = _boolArgument(arguments['tree']);
    // Still on by default here, unlike the drive layer, and the difference is
    // the point of this layer: there is no `screen` projection of a platform
    // accessibility tree, and what brings anyone to `layer: native` is
    // something Flutter cannot see — a permission dialog, a webview, another
    // app. The picture is the answer rather than a second opinion on it.
    var wantsShot = arguments['screenshot'] == null
        ? true
        : _boolArgument(arguments['screenshot']);
    var started = DateTime.now();
    var injects = verb == 'tap' || verb == 'enterText';

    NativeStep? step;
    String? error;
    String? failure;
    try {
      step = await session.act(
        verb: verb,
        target: arguments['target'] as String?,
        text: arguments['text'] as String?,
        screenshot: wantsShot,
      );
    } on NativeRefusal catch (refusal) {
      error = refusal.message;
      failure = refusal.failure;
    } on Object catch (e) {
      error = '$e';
    }

    if (injects) {
      _recordNativeEcho(handle, started, DateTime.now());
    }

    // A refusal still observes, exactly as on the drive layer: the error comes
    // back with the screen it happened on, so an agent never has to spend a
    // second call finding out what it was looking at.
    if (step == null && error != null) {
      try {
        if (await session.driver() case var driver?) {
          step = NativeStep(
            verb: verb,
            observation: await driver.observe(screenshot: wantsShot),
            elapsedMs: DateTime.now().difference(started).inMilliseconds,
          );
        }
      } on Object {
        // The refusal is the answer; failing to photograph it changes nothing
        // about what to tell the caller.
      }
    }

    var observation = step?.observation;
    String? shotPath;
    if (journalArtifactsDirFor(handle) case var dir?) {
      if (observation?.screenshot case var png?) {
        var file = File(
          p.join(dir, '${started.millisecondsSinceEpoch}-$pid.native.png'),
        );
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(png);
        shotPath = file.absolute.path;
      }
    }

    appendJournal(
      handle,
      JournalEntry(
        at: started.toUtc().toIso8601String(),
        verb: verb,
        actor: actor,
        layer: 'native',
        target: step?.target ?? arguments['target'] as String?,
        error: error,
        failure: failure,
        elapsedMs: step?.elapsedMs,
        screenshot: shotPath,
      ),
    );

    return RunActResult(
      device: handle.device,
      entrypoint: handle.entrypoint,
      worktree: handle.worktreeName,
      verb: verb,
      layer: 'native',
      target: step?.target ?? arguments['target'] as String?,
      ok: error == null,
      error: error,
      failure: failure,
      elapsedMs: step?.elapsedMs,
      coordinateSpace: observation?.coordinateSpace,
      screenshotScale: observation?.screenshotScale,
      screenshotOrigin: switch (observation?.screenshotOrigin) {
        var origin? => '${origin.left.round()},${origin.top.round()}',
        _ => null,
      },
      texts: observation?.texts,
      nativeTree: wantsTree ? observation?.root.toJson() : null,
      nodes: observation?.nodes.length,
      screenshot: shotPath,
      screenshotArtifact: shotPath == null
          ? null
          : Artifact(
              kind: Artifact.png,
              address: Address(
                worktree: host.worktree.name,
                plugin: runPluginId,
                segments: [handle.key, 'steps'],
              ),
              path: shotPath,
              meta: {
                'verb': verb,
                'layer': 'native',
                if (step?.target case String target) 'target': target,
              },
            ),
      journal: journalPathFor(handle),
      note: observation == null ? null : _nativeNote(observation),
    );
  }

  static String? _inspectNote({required bool up, required bool wanted}) {
    if (up) return null;
    return wanted
        ? 'The app is not answering, so there is no tree and no picture. It is '
              'either still building or it died — the logs say which.'
        : 'The app is not answering yet.';
  }

  /// The canonical paths of this repository's worktrees, from git.
  ///
  /// What bounds the `worktree` argument: a worktree's *name* is unique only
  /// within its repository — every repository's main checkout is `~` — so a
  /// name matched against the machine-wide ledger could silently pick an
  /// unrelated project's run. Cached for the core's lifetime; a worktree
  /// added since shows up on the next session, and selection itself goes by
  /// the paths the handles carry.
  late final Future<Set<String>> _repoWorktreePaths = () async {
    var own = p.canonicalize(host.worktree.path);
    try {
      var worktrees = await WorktreeDiscovery().discover(host.worktree.path);
      return {own, for (var w in worktrees) p.canonicalize(w.path)};
    } on Object {
      // No git, or not a repository. Own runs remain reachable.
      return {own};
    }
  }();

  /// Test seam: the repository's worktrees without a git call, the same seam
  /// [debugAct] and [debugRead] are.
  @visibleForTesting
  Future<Set<String>>? debugRepoWorktrees;

  Future<Set<String>> get _repoWorktrees =>
      debugRepoWorktrees ?? _repoWorktreePaths;

  RunHandle _selectApp(
    Map<String, Object?> arguments,
    Set<String> repoWorktrees,
  ) {
    var device = arguments['device'] as String?;
    var entrypoint = arguments['entrypoint'] as String?;
    var worktree = arguments['worktree'] as String?;
    var run = arguments['run'] as String?;
    // Own runs by default, like the rail: the owner's Studio in another
    // worktree is the same device/entrypoint pair as this one's, and neither
    // argument could tell them apart. Naming a worktree is the explicit
    // opt-in — it widens the pool to this *repository's* runs, never the
    // machine's: a sibling checkout is something a session can mean, another
    // project's app is not.
    var repoHandles = [
      for (var handle in _handles)
        if (repoWorktrees.contains(p.canonicalize(handle.worktree))) handle,
    ];
    // A key is as explicit as a worktree name and as unique as a run gets, so
    // it opts into the repository's pool the same way — and then it is the
    // whole selection: nothing else can narrow one run further.
    var pool = worktree == null && run == null
        ? ownHandles
        : [
            for (var handle in repoHandles)
              if (worktree == null ||
                  handle.worktreeName == worktree ||
                  p.canonicalize(handle.worktree) == p.canonicalize(worktree))
                handle,
          ];
    var matches = [
      for (var handle in pool)
        if (run == null || handle.runId == run || handle.key == run)
          if (device == null || handle.device == device)
            if (entrypoint == null ||
                handle.entrypoint == entrypoint ||
                handle.entrypointName == entrypoint)
              handle,
    ];
    if (matches.isEmpty) {
      // The next move rides in the refusal: this is an agent's first contact
      // with a cold machine, and "what now" should not cost a discovery call.
      var others = [
        for (var handle in repoHandles)
          if (!isMine(handle)) handle,
      ];
      var nothing = run != null
          ? 'No run "$run" — `apps` reports the keys that exist.'
          : worktree != null
          ? 'Nothing is running from worktree "$worktree".'
          : device != null
          ? 'Nothing is running on "$device".'
          : 'Nothing is running${others.isEmpty ? '' : ' from this worktree'}.';
      var elsewhere = others.isEmpty
          ? ''
          : ' Other worktrees are: '
                '${others.map((h) => '${h.worktreeName} (${h.device}/${h.entrypoint})').join(', ')}'
                ' — pass `worktree` to drive one.';
      throw RunRefusal(
        '$nothing$elsewhere '
        '`launch` starts an app; `status` lists devices and declared entry '
        'points.',
      );
    }
    if (matches.length > 1) {
      // Every match named by its key, because the ones this refusal exists for
      // are the ones a worktree, a device and an entry point cannot separate:
      // two Studios launched from one checkout onto one device printed the
      // same string twice and left no argument that could pick either.
      throw RunRefusal(
        'More than one app matches. Pass `run` with one of: '
        '${matches.map((h) => '${h.runId} (${h.worktreeName}: ${h.device}/${h.entrypoint}, ${_startedAgo(h.startedAt)})').join(', ')}',
      );
    }
    return matches.single;
  }

  RunAppEntry _appEntry(RunHandle handle, RunProbe? probe) => RunAppEntry(
    run: handle.runId,
    device: handle.device,
    deviceName: handle.deviceName,
    worktree: handle.worktreeName,
    mine: isMine(handle),
    package: handle.package,
    entrypoint: handle.entrypoint,
    entrypointName: handle.entrypointName,
    defines: handle.defines,
    since: handle.startedAt.toUtc().toIso8601String(),
    app: probe?.app ?? false,
    launcher: probe?.launcher ?? false,
    // Own runs only. The URI carries the VM service's auth token — the whole
    // of what gates connecting — and handing it out for another worktree's
    // run is handing out reload/restart/exit on an app this session does not
    // own, past every check `_selectApp` makes. Occupancy needs the row, not
    // the connect string.
    vmService: isMine(handle) ? handle.vmService : null,
    log: handle.logPath,
    error: probe?.error,
  );

  static int _intArgument(Object? value, int fallback) => switch (value) {
    int n => n,
    String s => int.tryParse(s) ?? fallback,
    _ => fallback,
  };

  Future<RunDevicesResult> _devicesAction({required bool refresh}) async {
    if (refresh) {
      try {
        await (await _acquireDaemon()).refresh();
      } on Object catch (e) {
        _daemonError = '$e';
        return RunDevicesResult(
          devices: const [],
          live: false,
          note: 'Could not start a flutter daemon: $e',
        );
      }
    } else {
      _cache = DeviceCache.read(runDir, files: files);
    }

    _handles = _scanHandles();
    await _probeAll();

    var devices = this.devices;
    var cache = _cache;
    return RunDevicesResult(
      live: isLive,
      updatedAt: isLive
          ? DateTime.now().toUtc().toIso8601String()
          : cache?.updatedAt.toUtc().toIso8601String(),
      age: isLive ? 'just now' : cache?.ageDescription,
      note: _devicesNote(devices, cache),
      devices: [
        for (var device in devices)
          RunDeviceEntry(
            id: device.id,
            name: device.displayName,
            platform: device.platformType,
            sdk: device.sdk,
            emulator: device.emulator,
            physical: device.ephemeral && !device.emulator,
            kind: device.kind.name,
            connected: device.isConnected,
            connection: device.connectionInterface,
            running: [
              for (var handle in _handles)
                if (handle.device == device.id) _holder(handle),
            ],
          ),
      ],
    );
  }

  /// An empty list has three different causes and they need three different
  /// next steps — nothing plugged in, nothing has looked yet, or the cache is
  /// stale and empty. An empty array with no note reads as the first.
  String? _devicesNote(List<DaemonDevice> devices, DeviceCache? cache) {
    if (devices.isNotEmpty) return null;
    if (isLive) return 'Nothing is connected.';
    if (cache == null) {
      return 'No device list has been taken on this machine yet. Pass refresh '
          'to start a flutter daemon and take one.';
    }
    return 'The cached list is empty, ${cache.ageDescription}. Pass refresh to '
        'take a fresh one.';
  }

  RunHolder _holder(RunHandle handle) {
    var probe = probeOf(handle);
    return RunHolder(
      worktree: handle.worktreeName,
      package: handle.package,
      entrypoint: handle.entrypoint,
      entrypointName: handle.entrypointName,
      since: handle.startedAt.toUtc().toIso8601String(),
      canReload: probe?.canReload ?? false,
      canInspect: probe?.canInspect ?? false,
    );
  }

  Future<RunAppsResult> _appsAction() async {
    _handles = _scanHandles();
    var swept = await _probeAll();
    return RunAppsResult(
      swept: swept,
      note: _handles.isEmpty
          ? 'Nothing is running. This lists apps launched through flutterware, '
                'which announce themselves in $runDir.'
          : null,
      apps: [for (var handle in _handles) _appEntry(handle, probeOf(handle))],
    );
  }

  static bool _boolArgument(Object? value) => switch (value) {
    bool b => b,
    String s => s == 'true',
    _ => false,
  };

  @override
  void dispose() {
    for (var tracker in _beatTrackers.values) {
      tracker.dispose();
    }
    _beatTrackers.clear();
    _humanSinceStep.clear();
    _screenMoved.clear();
    _screenMovedByCockpit.clear();
    for (var session in _driveSessions.values) {
      unawaited(session.close());
    }
    _driveSessions.clear();
    for (var session in _nativeSessions.values) {
      unawaited(session.close());
    }
    _nativeSessions.clear();
    _probeTimer?.cancel();
    unawaited(_daemonChanges?.cancel());
    // Give the lease back rather than stopping the daemon: another open
    // worktree may still be holding it, and closing one tab must not cost the
    // others their device list. When this was the last holder — which is
    // always the case for `fw` — the daemon stops here, and it has to: the
    // child keeps the VM alive, so a CLI that leaked it would print its answer
    // and then never exit.
    _daemon?.release();
    _daemon = null;
    super.dispose();
  }
}

PluginCore runCoreFactory(PluginHost host) => RunCore(host);

/// The window a native step's own input arrives in, as the guest reports it.
class _NativeEcho {
  _NativeEcho(this.from, this.to);

  final DateTime from;
  final DateTime to;

  bool contains(DateTime at) =>
      !at.isBefore(from.toUtc()) && !at.isAfter(to.toUtc());
}

/// One settled moment, written whole.
///
/// The archive, as distinct from the testimony. Every step leaves the same
/// four legs a scenario step leaves — the picture, the tree, the semantics, the
/// texts — plus a manifest naming them, and it leaves them whatever the call
/// asked to see. What the step *reported* is the journal entry's business
/// (`JournalEntry.reported`); this is the screen, and it is complete or it is
/// not worth keeping.
///
/// The measurement that made it affordable: the guest was already building the
/// whole tree on every observe and throwing it away, so the tree and the texts
/// cost nothing new. Only the picture does, and only when nobody asked to look
/// — which is why the host caps that one at [_declinedMaxSide] (~46ms) rather
/// than at the reply's cap (~234ms at 1200).
class _Capture {
  const _Capture({
    required this.address,
    required this.manifest,
    this.shot,
    this.tree,
    this.semantics,
    this.texts,
  });

  /// `fw:///worktrees/<wt>/flutterware.run/<runKey>/steps/<stamp>` — what to
  /// hand back to ask a different question about this moment.
  final String address;
  final String manifest;
  final String? shot;
  final String? tree;
  final String? semantics;
  final String? texts;

  static _Capture? write({
    required RunHandle handle,
    required String stamp,
    required DateTime at,
    required String verb,
    String? target,
    Map<String, Object?>? shot,
    Map<String, Object?>? tree,
    Map<String, Object?>? semantics,
    List<String>? texts,
    Screen? screen,
    List<String> reported = const [],
  }) {
    var dir = journalArtifactsDirFor(handle);
    if (dir == null) return null;
    var stem = p.join(dir, stamp);

    String? write(String suffix, List<int> bytes) {
      try {
        var file = File('$stem$suffix');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        return file.absolute.path;
      } on FileSystemException {
        // A full disk or a swept run dir must not fail the step: the verb
        // landed, and losing the archive is worse news than losing the step
        // but it is not the same news.
        return null;
      }
    }

    String? json(String suffix, Object? value) =>
        value == null ? null : write(suffix, utf8.encode(jsonEncode(value)));

    var shotPath = switch (shot?['base64']) {
      String data => write('.png', base64Decode(data)),
      _ => null,
    };
    var treePath = json('.tree.json', tree);
    var semanticsPath = json('.semantics.json', semantics);
    var textsPath = json('.texts.json', texts);

    var address = Address(
      worktree: handle.worktreeName,
      plugin: runPluginId,
      segments: [handle.key, 'steps', stamp],
    ).toString();

    var manifest = {
      'capture': address,
      'at': at.toUtc().toIso8601String(),
      'verb': verb,
      'target': ?target,
      'run': handle.key,
      'device': handle.device,
      'entrypoint': handle.entrypoint,
      // What is here, and how much of it — so a reader knows what it has
      // before opening anything.
      if (shotPath != null)
        'screenshot': {
          'path': shotPath,
          'width': ?shot?['width'],
          'height': ?shot?['height'],
          'pixelRatio': ?shot?['pixelRatio'],
        },
      if (treePath != null)
        'tree': {'path': treePath, 'nodes': _countTree(tree?['root'])},
      if (semanticsPath != null) 'semantics': {'path': semanticsPath},
      if (textsPath != null)
        'texts': {'path': textsPath, 'count': texts?.length ?? 0},
      if (screen != null)
        'screen': {
          'items': screen.length,
          if (screen.anonymousControls > 0)
            'anonymous': screen.anonymousControls,
        },
      // The one place the two halves meet: the archive says what it holds, and
      // names what the step chose to hand back, so a reviewer never has to
      // infer one from the other.
      if (reported.isNotEmpty) 'reported': reported,
    };

    var capture = _Capture(
      address: address,
      manifest: write('.capture.json', utf8.encode(jsonEncode(manifest))) ?? '',
      shot: shotPath,
      tree: treePath,
      semantics: semanticsPath,
      texts: textsPath,
    );
    // **Writing is what makes the weight, so writing is what bounds it** — the
    // same bargain `launchApp` strikes with `sweepRunDir`, and for the same
    // reason: housekeeping that waits for somebody to open a panel is
    // housekeeping that never runs on the sessions that need it most. The two
    // do not overlap. That sweep clears what *dead* runs left behind, on age;
    // this holds a *live* run's own pictures to a size, and a run the human
    // taps through for an hour never dies and never ages.
    boundJournalArtifacts(handle);
    return capture;
  }

  static int _countTree(Object? node) {
    if (node is! Map) return 0;
    var count = 1;
    for (var child in (node['children'] as List?) ?? const []) {
      count += _countTree(child);
    }
    return count;
  }
}

/// What `item: N` resolved to, or why it did not.
sealed class _ItemLookup {
  const _ItemLookup();
}

class _ItemPoint extends _ItemLookup {
  const _ItemPoint({required this.target, required this.described});

  /// The wire spelling of a point target — `{"at": {"x": …, "y": …}}`.
  final String target;

  /// `item 20 "All / 15"`, for the journal and the reply, so a reader of the
  /// step sees what was aimed at rather than a bare number.
  final String described;
}

class _ItemMiss extends _ItemLookup {
  const _ItemMiss(this.why);

  final String why;
}

/// The point at the centre of screen item [wanted], from the last capture
/// this run wrote.
///
/// Resolved from disk, not from memory. Every surface here opens a fresh
/// session per call, so "the screen you last saw" cannot live in a field; it
/// lives in the run's journal, which is also what makes an item usable from
/// `fw` after an MCP call took the observation.
///
/// The screen is recomputed from the archived tree rather than stored, because
/// [Screen.of] is deterministic: the same tree numbers the same items, and one
/// fewer thing on disk is one fewer thing that can disagree with the tree
/// beside it.
_ItemLookup _pointForItem(RunHandle handle, Object wanted) {
  var n = int.tryParse('$wanted');
  if (n == null) {
    return _ItemMiss(
      'item: "$wanted" is not a number — pass the `n` of something in the '
      "last reply's screen.",
    );
  }

  var entry = readJournal(
    handle,
    tail: 40,
  ).lastWhereOrNull((entry) => entry.tree != null);
  var path = entry?.tree;
  if (path == null) {
    return const _ItemMiss(
      'nothing has observed this app yet, so item numbers mean nothing. '
      'Observe first; every reply numbers what is on the screen.',
    );
  }

  InspectTree tree;
  try {
    tree = InspectTree.fromJson(
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>,
    );
  } on Object {
    return const _ItemMiss(
      'the last observation could not be read back from the run journal. '
      'Observe again and use an item number from that reply.',
    );
  }

  var projected = Screen.tryOf(tree);
  var screen = projected.screen;
  if (screen == null) return _ItemMiss(projected.note!);
  var item = screen.items.where((item) => item.n == n).firstOrNull;
  if (item == null) {
    return _ItemMiss(
      'no item $n on the screen this run last reported — it had '
      '${screen.length}. Observe again; the numbers are per observation and '
      'a screen that changed renumbers.',
    );
  }

  var x = item.box[0] + item.box[2] / 2;
  var y = item.box[1] + item.box[3] / 2;
  return _ItemPoint(
    target: jsonEncode({
      'at': {'x': x, 'y': y},
    }),
    described: 'item $n${item.words == null ? '' : ' "${item.words}"'}',
  );
}
