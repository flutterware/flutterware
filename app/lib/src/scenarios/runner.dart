import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ignore: implementation_imports
import 'package:flutterware/src/scenarios/network_mode.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/film_settings.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/pixels.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/selector.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/time_mode.dart';
import 'package:meta/meta.dart';

import '../embedder/build_directory.dart';
import '../embedder/tester_host.dart';
import '../session/job.dart';
import 'axes.dart';
import 'discovery.dart';
import 'harness_entrypoint.dart';
import 'live_pool.dart';

/// Which steps a run photographs, as callers of [ScenarioRunner.run] name it.
// ignore: implementation_imports
export 'package:flutterware/src/scenarios/pixels.dart';

/// How a run renders a film, as callers of [ScenarioRunner.run] name it.
// ignore: implementation_imports
export 'package:flutterware/src/scenarios/film_settings.dart' show FilmSettings;

/// One scenario listed by the live harness — ground truth, where the scan is
/// provisional.
class ScenarioListing {
  ScenarioListing({
    required this.file,
    required this.name,
    this.profile,
    this.devices = const [],
    this.languages = const [],
    this.orientations = const [],
    this.tags = const [],
    this.skip = false,
  });

  final String file;
  final String name;

  /// The name of the profile its folder's `flutter_test_config.dart` declared,
  /// or null where the folder has none.
  final String? profile;

  /// What that profile offers — the picker's list, and the first of each is
  /// what a run takes when none is named.
  final List<String> devices;
  final List<String> languages;
  final List<String> orientations;

  /// What `scenario(tags: [...])` declared — the vocabulary `run --tag` and
  /// `shots --tag` filter on. Only the live harness can see these; the
  /// syntactic scan does not evaluate arguments.
  final List<String> tags;

  /// Whether `scenario(skip: …)` declared it skipped — same reason as [tags]:
  /// only the harness evaluates the argument, so only this listing can say a
  /// run will report the scenario skipped rather than run it.
  final bool skip;

  /// The harness's own wire shape for one listing — what `list` answers and
  /// what a recording of it keeps.
  factory ScenarioListing.fromJson(Map<String, Object?> json) =>
      ScenarioListing(
        file: json['file']! as String,
        name: json['name']! as String,
        profile: json['profile'] as String?,
        devices: (json['devices'] as List?)?.cast<String>() ?? const [],
        languages: (json['languages'] as List?)?.cast<String>() ?? const [],
        orientations:
            (json['orientations'] as List?)?.cast<String>() ?? const [],
        tags: (json['tags'] as List?)?.cast<String>() ?? const [],
        skip: json['skip'] == true,
      );

  Map<String, Object?> toJson() => {
    'file': file,
    'name': name,
    'profile': ?profile,
    if (devices.isNotEmpty) 'devices': devices,
    if (languages.isNotEmpty) 'languages': languages,
    if (orientations.isNotEmpty) 'orientations': orientations,
    if (tags.isNotEmpty) 'tags': tags,
    if (skip) 'skip': true,
  };
}

/// Where a package's scenario runs come from, as the scenarios core sees it.
///
/// Five members, which is everything the core asks of the thing that runs a
/// scenario: the live listing, a run, where the harness log is, a hook for
/// each step as it lands, and disposal. [ScenarioRunner] is the real one — a
/// warm `flutter_tester` — and a recording of a run answers the same five
/// from files, which is what lets the panel draw a run where no harness can
/// be spawned. The core does not know which it has; see
/// `lib/src/demo/recorded_scenarios.dart`.
abstract interface class ScenarioRunSource {
  /// The harness console file, when a run has left one behind.
  String get logPath;

  /// One step, announced the moment its artifacts are written — the same
  /// event the harness publishes over the VM service.
  void Function(Map<String, Object?> event)? onStep;

  Future<List<ScenarioListing>> list();

  /// See [ScenarioRunner.run].
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,

    /// How many guests a real-time run keeps busy; null for the runner's
    /// default. A fake-time run ignores it.
    int? jobs,
    double? captureScale,
    bool captureRaw = false,
    bool captureNative = false,
    Duration? recordInterval,

    /// Null records at the same scale as the step's own screenshot, which is
    /// the only setting where playback does not visibly change resolution
    /// when it stops.
    double? recordScale,
    int recordMaxFrames = 90,
    DateTime? clock,

    /// What this run's http requests reach, or null to leave it to the
    /// project, each folder's `runScenarios(network: ...)` and each scenario's
    /// own.
    ScenarioNetwork? network,

    /// Where a recording is read and written, or null for the package's
    /// `test/scenarios/network`.
    String? networkStore,

    /// Which steps are worth a picture. A probe pass reads the walk and not
    /// the frames; a translation pass wants only the screens showing a key.
    ScenarioPixels pixels = ScenarioPixels.all,

    /// Pad every translation read by this percentage: the max-length probe.
    int? expandTranslations,

    /// When no device is named, frame each file on the *narrowest* device its
    /// folder profile declares instead of the first — the probe's geometry.
    bool narrowestDevice = false,

    /// Render this run as a **film**: every pumped frame kept at the film's
    /// own pace, the verbs given a cursor that travels and presses, and the
    /// frames written to [FilmSettings.directory] for an encoder to drain.
    ///
    /// A film is one scenario and one path through it, so a run that asks for
    /// one names the scenario and — where it splits — its branches.
    FilmSettings? film,

    /// Render the film as a **reel**: the scenario runs twice in one request
    /// — dry for the take, then filmed under the edit it declared (or the
    /// stock one), which decides what every output frame shows. Nothing
    /// without [film].
    bool filmReel = false,
  });

  Future<void> dispose();
}

/// Runs a package's scenarios in a directly-spawned `flutter_tester`, exactly
/// as spike S4 proved (`2026-07-30-s4-flutter-tester-findings.md`): our own
/// resident `frontend_server`, the SDK's tester binary, FakeAsync inside,
/// driven over the VM service.
///
/// Deliberately Flutter-free: `fw run scenarios run` links this, and the
/// purity guardrail (`entry_point_purity_test.dart`) holds it to that.
///
/// Not passing `--use-test-fonts` / `--disable-asset-fonts` — the two flags
/// `flutter test` always passes — is what makes captures render real fonts;
/// the harness loads `FontManifest.json` on top.
///
/// A warm runner stays honest: [run] re-syncs with the sources on disk before
/// every warm run, so the Run button never replays code that has since been
/// edited. See [refresh] for the two lanes that takes.
/// What this lane's dill, bundle and log are called.
const scenariosProgramName = 'scenarios';

/// The scenario half of a [TesterHost]: which files make up the program, and
/// what the harness they generate calls itself.
class _ScenarioProgram extends TesterProgram {
  _ScenarioProgram({
    required this.packageRoot,
    required this.directory,
    required this.lane,
    required this.time,
  });

  final String packageRoot;
  final String directory;

  /// The clock the generated entrypoint asks the harness for.
  final ScenarioTime time;

  /// Where the generated entrypoint goes — the host's own lane, so an isolated
  /// runner's harness sits beside its dill rather than on top of the warm
  /// one's.
  final BuildLane lane;

  @override
  String get name => scenariosProgramName;

  @override
  String get readyLine => 'scenarios harness ready';

  /// The streaming half of a run — `{file, scenario, step}` with the artifacts
  /// already on disk, which is how a panel fills the flow in while the scenario
  /// executes.
  @override
  String get eventStream => 'flutterware.scenarios.step';

  @override
  List<String> sources() {
    var scan = ScenarioScanner(
      packageRoot: packageRoot,
      directory: directory,
    ).scan();
    var files = {for (var ref in scan.scenarios) ref.file}.toList()..sort();
    if (files.isEmpty) {
      throw ActionRefusal(
        'No scenarios found under $directory. '
        "Write one with scenario('…', (s) async { … }).",
      );
    }
    return files;
  }

  @override
  String writeEntrypoint(List<String> sources) => writeHarnessEntrypoint(
    packageRoot,
    sources,
    directory: lane.path,
    time: time,
  );
}

/// Runs a package's scenarios in a directly-spawned `flutter_tester` — see
/// [TesterHost], which is everything here that is not about scenarios in
/// particular.
///
/// Deliberately Flutter-free: `fw run scenarios run` links this, and the
/// purity guardrail (`entry_point_purity_test.dart`) holds it to that.
///
/// A warm runner stays honest: [run] re-syncs with the sources on disk before
/// every warm run, so the Run button never replays code that has since been
/// edited.
class ScenarioRunner implements ScenarioRunSource {
  /// [buildDirectory] is what this runner would *rather* build in; where it
  /// actually builds is [takeBuildLane]'s answer, because another process may
  /// already hold it.
  ScenarioRunner({
    required String packageRoot,
    required String directory,
    required String flutterSdkRoot,
    String buildDirectory = TesterHost.defaultBuildDirectory,
    DateTime? projectClock,
    ScenarioNetwork? projectNetwork,
    ScenarioTime? time,
    int? jobs,
    bool followEdits = true,
    void Function(String line)? onLog,
  }) : this._(
         packageRoot: packageRoot,
         directory: directory,
         lane: BuildLane(
           packageRoot,
           preferred: buildDirectory,
           program: scenariosProgramName,
         ),
         projectClock: projectClock,
         projectNetwork: projectNetwork,
         time: time ?? ScenarioTime.fake,
         jobs: jobs,
         host: (lane, time) => TesterHost(
           packageRoot: packageRoot,
           flutterSdkRoot: flutterSdkRoot,
           program: _ScenarioProgram(
             packageRoot: packageRoot,
             directory: directory,
             lane: lane,
             time: time,
           ),
           lane: lane,
           followEdits: followEdits,
           onLog: onLog,
         ),
       );

  /// Another guest running [leader]'s harness, spawned from the kernel
  /// [leader] compiled — see [TesterHost.sharing]. [leader] must have been
  /// built with `followEdits: false`.
  ///
  /// It builds nothing and claims nothing: its artifacts are [leader]'s, so
  /// whoever releases [leader]'s build directory does so after disposing
  /// this.
  ScenarioRunner.sharing(
    ScenarioRunner leader, {
    required int guest,
    void Function(String line)? onLog,
  }) : this._(
         packageRoot: leader.packageRoot,
         directory: leader.directory,
         lane: leader._lane,
         projectClock: leader.projectClock,
         projectNetwork: leader.projectNetwork,
         time: leader.time,
         jobs: leader.jobs,
         host: (_, _) =>
             TesterHost.sharing(leader._host, guest: guest, onLog: onLog),
       );

  ScenarioRunner._({
    required this.packageRoot,
    required this.directory,
    required BuildLane lane,
    required this.projectClock,
    required this.projectNetwork,
    required this.time,
    required TesterHost Function(BuildLane lane, ScenarioTime time) host,
    this.jobs,
  }) : _lane = lane,
       _host = host(lane, time) {
    _host.onEvent = (event) => onStep?.call(event);
  }

  final String packageRoot;

  /// Scenario directory relative to [packageRoot].
  final String directory;

  /// The clock this runner's harness was built for. A real-time package runs
  /// one guest per scenario, [jobs] at a time, from the one kernel.
  final ScenarioTime time;

  /// How many guests a real-time run keeps busy; null picks the smaller of
  /// the scenario count and half the machine's cores.
  final int? jobs;

  final BuildLane _lane;

  /// Where this runner's artifacts live, relative to [packageRoot] — see
  /// [TesterHost.lane]. The comparison hands each of its runners a directory
  /// of its own because its head *is* the worktree the panel's warm runner
  /// lives on, and its base is a checkout every comparison on the machine
  /// shares.
  String get buildDirectory => _lane.path;

  /// What the project declared with `fw.clock(...)`, applied to every run
  /// this runner makes unless the run names its own.
  ///
  /// Held here rather than passed per call because every caller of [run] would
  /// otherwise have to remember it, and the one that forgets renders a
  /// different date from the rest — which is the failure a single project-wide
  /// setting exists to prevent. Null leaves the guest on its own default,
  /// which is `pinnedClockOrigin`, never the wall clock.
  final DateTime? projectClock;

  /// What the project declared with `fw.network(...)` — the lowest of the four
  /// altitudes, under a folder, one run and one scenario.
  ///
  /// A field rather than a parameter of [run], exactly like [projectClock] and
  /// for the reason that one is: three places build a runner — the panel, the
  /// comparison and the store's shots — and a per-call parameter is one every
  /// caller but the first would forget. A comparison whose two sides ran with
  /// the network off would diff two refusal frames, and a store screenshot
  /// would export the error state.
  final ScenarioNetwork? projectNetwork;

  final TesterHost _host;

  /// Where the harness process's console is teed — see [TesterHost.logPath].
  @override
  String get logPath => _host.logPath;

  /// Called for every step the harness announces **mid-run**. The blocking
  /// [run] response remains the complete report; this is the streaming half.
  ///
  /// Mutable rather than constructor-fixed so the owner can attach after the
  /// runner exists.
  @override
  void Function(Map<String, Object?> event)? onStep;

  Future<void> start() => _host.start();

  Future<void> refresh() => _host.refresh();

  @override
  Future<List<ScenarioListing>> list() => _host.exclusive(() async {
    await _host.ensureGuest();
    var response = _refuseIfAsked(
      await _host.vm.requireExtension('ext.flutterware.scenarios.list'),
    );
    return [
      for (var entry
          in (response['scenarios']! as List).cast<Map<String, Object?>>())
        ScenarioListing.fromJson(entry),
    ];
  });

  /// Runs scenarios — all of them, one file's, or one — writing each step's
  /// PNG and tree under [outDir] and returning the harness's report verbatim.
  /// [axes] is applied for the whole request and reset after it.
  ///
  /// An axis assignment that names no device leaves the choice to each
  /// scenario's folder profile, and to [unspecifiedDevice] where a folder has
  /// none — a policy the runner holds no opinion about, so a caller that
  /// passes nothing gets the bare test surface.
  ///
  /// A warm runner refreshes first, so what runs is always what is on disk.
  @override
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,

    /// How many guests a real-time run keeps busy; null for the runner's
    /// default. A fake-time run ignores it.
    int? jobs,
    double? captureScale,
    bool captureRaw = false,
    bool captureNative = false,
    Duration? recordInterval,

    /// Null records at the same scale as the step's own screenshot, which is
    /// the only setting where playback does not visibly change resolution
    /// when it stops.
    double? recordScale,
    int recordMaxFrames = 90,
    DateTime? clock,

    /// What this run's http requests reach, or null to leave it to the
    /// project, each folder's `runScenarios(network: ...)` and each scenario's
    /// own.
    ScenarioNetwork? network,

    /// Where a recording is read and written, or null for the package's
    /// `test/scenarios/network`.
    String? networkStore,

    /// Which steps are worth a picture. A probe pass reads the walk and not
    /// the frames; a translation pass wants only the screens showing a key.
    ScenarioPixels pixels = ScenarioPixels.all,

    /// Pad every translation read by this percentage: the max-length probe.
    int? expandTranslations,

    /// When no device is named, frame each file on the *narrowest* device its
    /// folder profile declares instead of the first — the probe's geometry.
    bool narrowestDevice = false,

    /// Render this run as a **film**: every pumped frame kept at the film's
    /// own pace, the verbs given a cursor that travels and presses, and the
    /// frames written to [FilmSettings.directory] for an encoder to drain.
    ///
    /// A film is one scenario and one path through it, so a run that asks for
    /// one names the scenario and — where it splits — its branches.
    FilmSettings? film,

    /// Render the film as a **reel**: the scenario runs twice in one request
    /// — dry for the take, then filmed under the edit it declared (or the
    /// stock one), which decides what every output frame shows. Nothing
    /// without [film].
    bool filmReel = false,
  }) => _host.exclusive(() async {
    var wasWarm = _host.isWarm;
    await _host.ensureGuest();
    if (wasWarm) await _host.sync();
    Directory(outDir).createSync(recursive: true);
    // Closes the narration the host started: everything before this was
    // getting a guest ready, and a caption still saying so while the scenario
    // is executing is a stale one.
    _host.onLog?.call('[scenarios] running');
    var args = <String, String>{
      'out': outDir,
      'file': ?file,
      'scenario': ?scenario,
      'tag': ?tag,
      if (captureScale != null) 'captureScale': '$captureScale',
      if (captureRaw) 'captureRaw': 'true',
      if (captureNative) 'captureNative': 'true',
      if (pixels != ScenarioPixels.all) 'pixels': pixels.name,
      if (expandTranslations != null) 'expand': '$expandTranslations',
      if (narrowestDevice) 'deviceChoice': 'narrowest',
      // Present only when recording: the interval is what turns motion
      // capture on, so its absence is the off switch and no run that did
      // not ask pays for one.
      if (recordInterval != null) ...{
        'recordIntervalMs': '${recordInterval.inMilliseconds}',
        if (recordScale != null) 'recordScale': '$recordScale',
        'recordMaxFrames': '$recordMaxFrames',
      },
      // A film's settings travel whole, because every one of them changes
      // what the frames *are*: the pace they were pumped at, the size they
      // were drawn at, and the path through the scenario that produced them.
      if (film case var film?) ...{
        'filmDir': film.directory,
        'filmFps': '${film.fps}',
        'filmScale': '${film.scale}',
        if (film.branches.isNotEmpty) 'filmBranches': jsonEncode(film.branches),
        'filmOpenMs': '${film.open.inMilliseconds}',
        'filmTravelMs': '${film.travel.inMilliseconds}',
        'filmAimMs': '${film.aim.inMilliseconds}',
        'filmPressMs': '${film.press.inMilliseconds}',
        'filmDwellMs': '${film.dwell.inMilliseconds}',
        'filmCloseMs': '${film.close.inMilliseconds}',
        'filmMaxFrames': '${film.maxFrames}',
        if (!film.pixels) 'filmPixels': 'false',
        if (filmReel) 'filmReel': 'true',
      },
      // The project's pin is the fake lane's default; a live run is on the
      // wall clock unless the run itself names one.
      if (clock ?? (time.isReal ? null : projectClock) case var origin?)
        'clock': origin.toIso8601String(),
      if (network case var reach?) 'network': reach.name,
      if (projectNetwork case var reach?) 'networkDefault': reach.name,
      'networkStore': ?networkStore,
      ...axes.harnessArgs(unspecifiedDevice: unspecifiedDevice),
    };
    if (time.isReal) {
      return _runLive(
        args,
        file: file,
        scenario: scenario,
        tag: tag,
        jobs: jobs,
      );
    }
    var response = _refuseIfAsked(
      await _host.vm.requireExtension(
        'ext.flutterware.scenarios.run',
        args: args,
      ),
    );
    if (response['error'] case String error) {
      throw StateError('the harness failed:\n$error\n${response['stack']}');
    }
    // A scenario blew its deadline, so its body is still in there holding the
    // binding. The report is good — it is what the run got to — but the guest
    // is not, and a warm one is exactly what the next run would reuse.
    if (response['abandoned'] == true) {
      _host.onLog?.call(
        '[scenarios] a scenario timed out — restarting the harness',
      );
      await _host.restartGuest();
    }
    return response.cast<String, Object?>();
  });

  /// A real-time run: every selected scenario on its own guest, [jobs] at a
  /// time, from the kernel the host just built. The replies are merged into
  /// the one shape the single-guest path answers with.
  Future<Map<String, Object?>> _runLive(
    Map<String, String> args, {
    String? file,
    String? scenario,
    String? tag,
    int? jobs,
  }) async {
    var watch = Stopwatch()..start();
    var selection = <LiveScenarioRef>[
      for (var listing in await _listOnHost())
        if (file == null ||
            fileSelectors(file).any((one) => selectsFile(one, listing.file)))
          if (scenario == null || listing.name == scenario)
            if (tag == null || listing.tags.contains(tag))
              if (!listing.skip) (file: listing.file, scenario: listing.name),
    ];
    var parallel = jobs ?? this.jobs ?? _defaultJobs(selection.length);
    var pool = LiveScenarioPool(host: _host, jobs: parallel);
    var replies = await pool.run(
      selection,
      (ref) => {...args, 'file': ref.file, 'scenario': ref.scenario},
    );
    for (var reply in replies) {
      _refuseIfAsked(reply);
      if (reply['error'] case String error) {
        throw StateError('the harness failed:\n$error\n${reply['stack']}');
      }
    }
    return {
      'ms': watch.elapsedMilliseconds,
      'scenarios': [
        for (var reply in replies) ...(reply['scenarios'] as List? ?? const []),
      ],
      'time': time.name,
      'animations': time.animations,
      'jobs': parallel,
      'clock': ?replies.map((r) => r['clock']).nonNulls.firstOrNull,
      // Merged the way the harness reports it: the modes any guest ran under.
      if (replies.any((r) => r['network'] != null))
        'network': [
          ...{
            for (var reply in replies)
              ...(reply['network'] as List? ?? const []).cast<Object?>(),
          },
        ],
    };
  }

  /// What the host's guest declares, straight off the harness — the pool
  /// fans out over this rather than a scan, so a scenario the scan would not
  /// see (a non-literal name) still runs.
  Future<List<ScenarioListing>> _listOnHost() async {
    var response = _refuseIfAsked(
      await _host.vm.requireExtension('ext.flutterware.scenarios.list'),
    );
    return [
      for (var entry in (response['scenarios']! as List).cast<Map>())
        ScenarioListing(
          file: entry['file'] as String,
          name: entry['name'] as String,
          tags: (entry['tags'] as List? ?? const []).cast<String>(),
          skip: entry['skip'] == true,
        ),
    ];
  }

  /// The harness's own refusal — a folder it will not run, said at probe —
  /// raised as one, rather than read as a report with nothing in it.
  static Map<String, Object?> _refuseIfAsked(Map<String, Object?>? response) {
    if (response!['refusal'] case String refusal) throw ActionRefusal(refusal);
    return response;
  }

  static int _defaultJobs(int scenarios) =>
      scenarios.clamp(1, math.max(1, Platform.numberOfProcessors ~/ 2));

  /// Kills the guest out from under the runner, so a test can assert that the
  /// next call notices and respawns rather than talking to a dead service.
  /// Awaits the exit, so what follows is testing the recovery rather than
  /// racing the kill.
  @visibleForTesting
  Future<void> debugKillGuest() => _host.killGuest();

  @override
  Future<void> dispose() => _host.dispose();
}
