import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/app_events.dart' show AppChannel, AppEvent;
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/network_mode.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/selector.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../delta/branch_delta.dart';
import '../../delta/branch_delta_controller.dart';
import '../../delta/delta_painting.dart';
import '../../embedder/tester_phase.dart';
import '../../inspect/lens.dart';
import '../../inspect/screen_read.dart';
import '../../previews/devices.dart' show orientationParameterDoc;
import '../../scenarios/authoring.dart';
import '../../scenarios/axes.dart';
import '../../scenarios/discovery.dart';
import '../../scenarios/film_encode.dart';
import '../../scenarios/opaque_png.dart';
import '../../scenarios/run_dirs.dart';
import '../../scenarios/runner.dart';
import '../../scene/export/video.dart' show VideoEncoder;
import '../../scenarios/web_export.dart';
import '../../scenarios/web_report.dart';
import '../../session/job.dart';
import '../../utils/base_href.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'scenarios_address.dart';
import 'scenarios_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const scenariosPluginId = 'flutterware.scenarios';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Scenarios — deterministic headless flows through the app — listed, run, '
    'and read back a step at a time with what each step had on screen.';

/// The action that writes a run out as a page, named once so the CLI, the
/// dialog and the command the dialog echoes cannot drift apart.
const webExportActionId = 'export';

/// `video` — one scenario, rendered as a film. See
/// `docs/superpowers/specs/2026-09-08-scenario-video-design.md`.
const videoActionId = 'video';

/// One scenario's latest panel-driven run — what the flow page renders.
///
/// Replaced wholesale on every transition, never mutated: the panel compares
/// nothing, it just draws whatever this says.
class ScenarioPanelRun {
  ScenarioPanelRun({
    required this.running,
    required this.axes,
    this.device,
    this.steps = const [],
    this.outcome,
    this.error,
    this.output,
    this.clock,
    this.network = const [],
  });

  final bool running;

  /// The axis assignment of the latest *attempt*, **exactly as asked**.
  /// Recorded on failure too, so the page can see "these axes were tried" and
  /// not retry them in a loop — which is also why an unspecified device is
  /// not patched in here once the run answers it. That answer is [device].
  final ScenarioAxes axes;

  /// The device the run actually used — the folder profile's, where [axes]
  /// named none. What the page frames its pictures with, and what the device
  /// chip reports back.
  final String? device;

  /// The run's steps as the page draws them: **growing while the run
  /// executes** — each one announced by the harness the moment its artifacts
  /// hit disk — and the settled list afterwards. A failed run keeps what it
  /// captured before dying, which is the frame just before the failure.
  ///
  /// Starting a run clears this: for a long scenario, an empty flow filling
  /// in beats last run's pictures pretending to be this run's.
  final List<ScenarioRunStep> steps;

  /// The completed outcome of this attempt, or null while running (and after
  /// a failed attempt — [steps] and [error] are what remain of one).
  final ScenarioRunOutcome? outcome;

  /// What the attempt died of, or null.
  final String? error;

  /// The directory the artifacts live in.
  final String? output;

  /// What `clock.now()` read inside the run, or null while it is running.
  ///
  /// Said on the page for the same reason it is written into `run.json`: a
  /// scenario is pinned to a date by default, and an app with a trial expiry,
  /// a seasonal theme or a "new since" badge sits in a different state under
  /// one — with nothing on the screen to say why. A pin that is stated is a
  /// fact; a pin that is not is a bug nobody can find.
  final DateTime? clock;

  /// The network modes the run's scenarios actually ran under, in the enum's
  /// order — empty while it is running.
  ///
  /// Said on the page for the reason [clock] is. A screen photographed with
  /// the network open and the same screen photographed with it shut are not
  /// the same evidence, and the picture does not say which. More than one
  /// entry is a mixed run, which is normal: it is a per-folder setting.
  final List<String> network;
}

/// The panel's word for what a runner log line means, or null for a line that
/// means nothing to a reader watching a spinner.
///
/// A thin dressing over [readTesterPhase], which is where the reading — and
/// the rule that keeps the guest's own console out of a caption — lives. What
/// is added here is the one phase the shared reader has no word for: the
/// scenario itself, running.
@visibleForTesting
String? scenarioRunnerPhase(String line) {
  if (readTesterPhase(line) case var reading?) {
    return switch (reading.phase) {
      TesterPhase.compiling => 'Compiling the harness',
      // The harness answering is still the start of the run from here: the
      // caption moves on when the first step lands, not when the guest is up.
      TesterPhase.starting || TesterPhase.ready => 'Starting the harness',
      TesterPhase.bundling => 'Rebuilding the asset bundle',
      TesterPhase.restarting => 'Restarting the harness',
      TesterPhase.reloading =>
        'Reloading ${reading.files} edited file'
            '${reading.files == 1 ? '' : 's'}',
    };
  }
  if (line.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '').startsWith('running')) {
    return 'Running the scenario';
  }
  return null;
}

/// A run to compare against, and the directory it was read from.
///
/// The directory travels with the report because the report does not carry it
/// usefully: `output` is what that run was *written* to, which a checkout
/// moved or copied since no longer names.
typedef _Baseline = ({String dir, ScenarioRunResult run});

/// Scenarios for each declared package: the syntactic scan projected into the
/// report and the `list` action, the `run` action in a warm
/// [ScenarioRunner], and the panel's per-scenario run state on the same
/// runner; see `docs/superpowers/specs/2026-07-30-scenarios-design.md`.
///
/// Follows the dependencies core's rule: nothing here starts work. The
/// constructor allocates nothing and [report] only reads what a previous call
/// caused to scan. Scanning begins in [track], which the panel calls on mount
/// and `fw` calls for the duration of a request.
class ScenariosCore extends PluginCore {
  /// [scan] answers a package's syntactic scan and [runner] makes the thing
  /// that runs its scenarios. Both default to the real ones — a parse of the
  /// disk off-isolate, a warm `flutter_tester` — and both are the doors a
  /// recording comes in through: the same core, the same panel, reading what
  /// a tool recorded rather than what a machine would do now. See
  /// `lib/src/demo/recorded_scenarios.dart`.
  ScenariosCore(
    super.host, {
    ScenarioScan? scan,
    ScenarioRunSourceFactory? runner,
  }) : _scan = scan ?? _liveScan,
       _runnerFactory = runner;

  final ScenarioScan _scan;
  final ScenarioRunSourceFactory? _runnerFactory;

  /// Parsing runs off-isolate, as the catalog's scan does.
  static Future<ScenarioScanResult> _liveScan({
    required String packageRoot,
    required String directory,
  }) => Isolate.run(
    ScenarioScanner(packageRoot: packageRoot, directory: directory).scan,
  );

  final _scans = <String, Future<void>>{};
  final _results = <String, ScenarioScanResult>{};
  final _errors = <String, Object>{};

  /// The live listing per package — in flight and landed.
  final _listings = <String, Future<void>>{};
  final _listed = <String, List<ScenarioListing>>{};

  /// One warm runner per package, created by the first `run` and kept — a
  /// second run reuses the compiled harness and the live tester.
  final _runners = <String, ScenarioRunSource>{};

  /// The panel's runs, one per scenario, keyed `(package, file, scenario)`.
  final _panelRuns = <(String, String, String), ScenarioPanelRun>{};

  /// What the runner is doing per package, in the panel's own words — the
  /// only narration a cold start has, so the panel can say "Compiling the
  /// harness" rather than spinning silently.
  ///
  /// The *phase*, never the log line. The runner's lines are written for a
  /// log — `[tester] flutterware scenarios harness ready — fonts: Roboto,
  /// MaterialIcons` — and a caption under a spinner is not a log: it has to
  /// be short enough to read at a glance and stable enough that the eye is
  /// not dragged back to it. See [scenarioRunnerPhase].
  final _runnerPhases = <String, String>{};

  /// Declared packages, filtered to those the workspace knows about.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  /// Where discovery looks for [path]'s scenarios: the declared directory, or
  /// all of `test/` — a scenario is an ordinary widget test and may sit next
  /// to the rest of them.
  String scanRootFor(String path) =>
      _configuredDirectoryFor(path) ?? defaultScenariosScanRoot;

  /// Where a new scenario file goes for [path]: the declared directory, or
  /// the `test/scenarios` convention. Narrower than [scanRootFor] on purpose —
  /// "where do we look" widened to `test/`, but "where should the next file
  /// go" still deserves a conventional answer.
  String newScenarioDirectoryFor(String path) =>
      _configuredDirectoryFor(path) ?? defaultScenariosDirectory;

  String? _configuredDirectoryFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] == path) {
        if (config['directory'] case String directory) return directory;
      }
    }
    return null;
  }

  /// The locale tags declared for [path] in `tool/flutterware.dart` —
  /// `Scenarios(packages: [.new(app, languages: ['en', 'fr'])])` — or empty.
  /// The language axis offers exactly this list; it is configuration, not
  /// free text, because a tag the app does not support runs the fallback
  /// locale and produces a picture that is wrong without looking wrong.
  List<String> languagesFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] == path) {
        if (config['languages'] case List<Object?> languages) {
          return languages.cast<String>();
        }
      }
    }
    return const [];
  }

  /// The configured capture scale for [path] — output pixels per logical
  /// pixel on every run — or null for the measured default of 1. An explicit
  /// `capture-scale` on a run still wins; this is the project saying "always
  /// retina" once, in `tool/flutterware.dart`.
  double? captureScaleFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] == path) {
        if (config['captureScale'] case num scale) return scale.toDouble();
      }
    }
    return null;
  }

  /// The absolute root of [path]'s package — what the step page shortens a
  /// node's source paths against.
  String packageRootFor(String path) =>
      host.workspace.packageFor(path).directory.path;

  /// Whether [path] has been scanned (or is scanning) — the laziness rule,
  /// made observable.
  bool isRealised(String path) => _scans.containsKey(path);

  bool isScanning(String path) =>
      _scans.containsKey(path) &&
      !_results.containsKey(path) &&
      !_errors.containsKey(path);

  /// The cached scan for [path], or null when nothing has looked at it yet.
  ScenarioScanResult? scanResultFor(String path) => _results[path];

  Object? scanErrorFor(String path) => _errors[path];

  /// Starts (and keeps) the scan for [path]. Idempotent.
  void track(String path) {
    if (_scans.containsKey(path)) return;
    _scans[path] =
        _scan(
              packageRoot: host.workspace.packageFor(path).directory.path,
              directory: scanRootFor(path),
            )
            .then<void>((result) {
              _results[path] = result;
              _delta.scanLanded(path, result);
              // A scan that lands clears the failure it recovers from — a save
              // caught mid-write fails one rescan, and that error may not outlive
              // the next scan that read the finished file.
              _errors.remove(path);
            })
            .catchError((Object error) => _errors[path] = error)
            .whenComplete(notifyChanged);
    notifyChanged();
  }

  /// A scan result is cheap and kept — releasing it would only buy a rescan.
  void untrack(String path) {}

  /// What the branch changed, installed by the session — see
  /// `Session.branchDelta` and [DeltaPainting].
  BranchDeltaController? get branchDelta => _delta.controller;
  set branchDelta(BranchDeltaController? value) => _delta.controller = value;

  late final _delta = DeltaPainting<ScenarioScanResult>(
    owner: id,
    filesOf: (path, scan) => {
      for (var ref in scan.scenarios) worktreeRelative(path, ref.file),
    },
    spansOf: (path, scan) => [
      for (var ref in scan.scenarios)
        EntrySpan(
          id: scenarioChangeKey(ref),
          file: worktreeRelative(path, ref.file),
          line: ref.line,
          endLine: ref.endLine,
        ),
    ],
    onChanged: notifyChanged,
  );

  /// How the branch touched each scenario of [path], keyed by
  /// [scenarioChangeKey], or null before the delta has landed.
  EntryChanges? entryChangesFor(String path) => _delta.changesFor(path);

  /// What [entryChangesFor] keys a scenario by: file, name and line. The
  /// line, because a name declared twice in one file is two rows (the scan
  /// keeps both and says so), and an edit to one must not paint the other.
  static String scenarioChangeKey(ScenarioRef ref) =>
      '${ref.file}//${ref.name}//${ref.line}';

  /// What the **live harness** says a package has: profiles, the devices and
  /// languages they offer, and each scenario's tags. None of it is visible to
  /// the syntactic scan — a profile is Dart in a `flutter_test_config.dart`,
  /// and tags are arguments the scanner never evaluates.
  ///
  /// Started on demand like everything else here, and by the one caller that
  /// is about to pay for a compiled harness anyway: opening a scenario runs
  /// it. Both calls queue on the runner's single turn, so listing first costs
  /// the ordering and nothing else.
  void trackListings(String path) {
    if (_listings.containsKey(path)) return;
    _listings[path] = _runnerFor(path)
        .list()
        .then<void>((listed) => _listed[path] = listed)
        // Swallowed by design: a failed listing reads as null, and the run
        // that follows reports the same failure with the room to explain it.
        .catchError((Object _) {})
        .whenComplete(notifyChanged);
  }

  /// The live listing of [path], or null while nothing has asked or the ask
  /// has not landed. A failed listing reads as null too — the run that
  /// follows reports the same failure with the room to explain it.
  List<ScenarioListing>? listingsFor(String path) => _listed[path];

  /// The listing for one scenario, by the names the panel addresses it with.
  ScenarioListing? listingFor(
    String path, {
    required String file,
    required String scenario,
  }) => _listed[path]?.firstWhereOrNull(
    (l) => l.file == file && l.name == scenario,
  );

  /// The devices the profile governing [file] offers — the picker's pool, in
  /// the profile's own order, empty where the folder declares none.
  List<String> offeredDevicesFor(String path, String file) =>
      _listed[path]?.firstWhereOrNull((l) => l.file == file)?.devices ??
      const [];

  /// The languages to offer for [file]: the profile's, and the package's
  /// `tool/flutterware.dart` declaration where no profile speaks.
  List<String> offeredLanguagesFor(String path, String file) {
    var profiled = _listed[path]
        ?.firstWhereOrNull((l) => l.file == file)
        ?.languages;
    return (profiled == null || profiled.isEmpty)
        ? languagesFor(path)
        : profiled;
  }

  /// The panel's latest run of one scenario, or null when it has never run.
  ScenarioPanelRun? panelRunFor(
    String package, {
    required String file,
    required String scenario,
  }) => _panelRuns[(package, file, scenario)];

  /// What the runner is doing for [package] right now — the caption under the
  /// panel's spinner, or null when nothing has said anything yet.
  String? runnerPhaseFor(String package) => _runnerPhases[package];

  bool get anyPanelRunning => _panelRuns.values.any((run) => run.running);

  /// Whether panel runs record the motion of every transition.
  ///
  /// On, because a recording you have to ask for goes undiscovered: the feature
  /// is hovering an arrow and watching what happened. It costs the panel about
  /// 70ms a transition — measured, at the
  /// 30fps half-scale settings below — and the switch is here for the run
  /// where that is 70ms too many.
  ///
  /// Panel-only, deliberately. `fw run scenarios` and the MCP surface never
  /// record: nothing on the other end of those can watch a movie, so the frames
  /// would be artifacts no one opens.
  var recordMotion = true;

  void setRecordMotion(bool value) {
    if (recordMotion == value) return;
    recordMotion = value;
    notifyChanged();
  }

  /// 30fps, at the same scale as the step's own screenshot.
  ///
  /// 30fps is the measured knee — a transition costs ~35ms of pumping here
  /// against ~150ms at 60fps, and no eye reading a page push on a flow canvas
  /// can tell the two apart. The *scale* is not a knob for the same reason:
  /// half scale was tried, and playback that blurs and then snaps sharp when
  /// it stops is worse than the work it saves. What that costs is memory —
  /// 1.29MB a frame decoded, on a phone — and that is bounded by
  /// `ScenarioMotionResidency` rather than by recording something smaller.
  ///
  /// See `docs/superpowers/specs/2026-08-11-scenario-motion-capture-findings.md`.
  static const panelMotionInterval = Duration(milliseconds: 33);
  static const panelMotionMaxFrames = 90;

  /// Starts one scenario's run for the panel. A no-op while that scenario is
  /// already running; a completed run may be started again.
  ///
  /// Same runner, same warm guest as the `run` action — the panel is another
  /// caller, not another path. The runner refreshes edited sources before a
  /// warm run, which is what makes the Run button honest after an edit.
  void startRun(
    String package, {
    required String file,
    required String scenario,
    ScenarioAxes axes = const ScenarioAxes(),
  }) {
    var key = (package, file, scenario);
    var previous = _panelRuns[key];
    if (previous?.running ?? false) return;
    // The immediate clear: the page shows *this* run filling in, never the
    // previous run's pictures under this run's spinner.
    _panelRuns[key] = ScenarioPanelRun(running: true, axes: axes);
    notifyChanged();
    unawaited(_panelRun(key, previous, axes));
  }

  /// One step, announced mid-run over the VM service — appended to the
  /// running attempt's [ScenarioPanelRun.steps] as it lands.
  void _onRunnerStep(String package, Map<String, Object?> event) {
    if ((event['file'], event['scenario']) case (
      String file,
      String scenario,
    )) {
      _countScenario(package, '$file/$scenario');
      var key = (package, file, scenario);
      var state = _panelRuns[key];
      if (state == null || !state.running) return;
      // Every step says what it is running as, so a request that named no
      // device frames its first picture correctly rather than snapping into a
      // phone when the run ends.
      var device = event['device'] as String? ?? state.axes.device;
      var step = _stepFrom(
        (event['step']! as Map).cast<String, Object?>(),
        package,
        file: file,
        scenario: scenario,
        axes: state.axes.copyWith(device: device),
      );
      _panelRuns[key] = ScenarioPanelRun(
        running: true,
        axes: state.axes,
        device: device,
        steps: [...state.steps, step],
      );
      notifyChanged();
    }
  }

  Future<void> _panelRun(
    (String, String, String) key,
    ScenarioPanelRun? previous,
    ScenarioAxes axes,
  ) async {
    var (package, file, scenario) = key;
    var packageRoot = host.workspace.packageFor(package).directory.path;
    var outDir = p.join(
      packageRoot,
      'build',
      'flutterware',
      'scenario_runs',
      'panel-${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      // Raw exactly when the recording pays for it, which is the line the
      // measurement drew. A recording turns 31 pictures into 371, and PNG
      // charges ~7.5ms of encoder for every one:
      //
      // |            | raw | PNG |
      // |------------|-----|-----|
      // | shots only | 404ms / 48MB | 587ms / 0.3MB |
      // | recording  | **721ms** / 489MB | 3080ms / 6MB |
      //
      // Recording, raw is 4.3× and there is nothing to discuss. Without one it
      // is 31% for 160× the bytes, which is not a trade worth making: the
      // canvas decodes a PNG thumbnail in 0.75ms and "copy as PNG" stops being
      // a `package:image` re-encode. So the flag follows the recorder.
      var report = await _runnerFor(package).run(
        outDir: outDir,
        file: file,
        scenario: scenario,
        axes: axes,
        unspecifiedDevice: defaultScenarioDeviceId,
        captureScale: captureScaleFor(package),
        captureRaw: recordMotion,
        recordInterval: recordMotion ? panelMotionInterval : null,
        recordMaxFrames: panelMotionMaxFrames,
      );
      var described = _describeRun(package, outDir, report, axes: axes);
      var outcome = described.scenarios
          .where((s) => s.file == file && s.name == scenario)
          .firstOrNull;
      // The run says what it ran as, which the request may have left to the
      // folder's profile — and the page frames its pictures from this.
      var device = outcome?.device ?? axes.device;
      if (outcome == null) {
        _panelRuns[key] = ScenarioPanelRun(
          running: false,
          axes: axes,
          device: device,
          steps: _panelRuns[key]?.steps ?? const [],
          output: outDir,
          error:
              'The harness ran nothing named "$scenario" in $file — '
              'renamed since this page was opened?',
        );
        return;
      }
      _panelRuns[key] = ScenarioPanelRun(
        running: false,
        axes: axes,
        device: device,
        steps: outcome.steps,
        outcome: outcome,
        output: outDir,
        clock: switch (report['clock']) {
          String raw => DateTime.tryParse(raw),
          _ => null,
        },
        network: switch (report['network']) {
          List<Object?> raw => [for (var mode in raw) '$mode'],
          _ => const <String>[],
        },
      );
      // Only once the page is pointed at this run — and every *other* live
      // panel run is named too. A session runs one scenario after another and
      // each keeps its own directory in `_panelRuns`, so "the newest few" is
      // the wrong rule on its own: the fifth scenario you ran would sweep away
      // the steps the first one is still showing.
      _sweepRuns(
        package,
        protect: {outDir, for (var run in _panelRuns.values) ?run.output},
      );
    } catch (error) {
      // The steps captured before the failure stay: the last one is the
      // frame just before it died — and its directory is recorded like any
      // other, or the next run would have nothing to supersede and both
      // would be stranded.
      _panelRuns[key] = ScenarioPanelRun(
        running: false,
        axes: axes,
        device: _panelRuns[key]?.device,
        steps: _panelRuns[key]?.steps ?? const [],
        output: outDir,
        error: '$error',
      );
    } finally {
      // The superseded run's artifacts, **whatever this attempt did**: a
      // failed attempt supersedes the previous one just as a successful one
      // does, and deleting only on success let a single failure strand two
      // directories. The images already on screen are decoded, so pulling the
      // files is safe — and keeping them would grow a directory per click.
      if (previous?.output case var old? when old != outDir) {
        _discardRun(old);
      }
      notifyChanged();
      // The run compiled the suite as it is on disk, which is newer truth
      // than the list pane's scan — catch the pane up.
      _rescan(package);
      _relist(package);
    }
  }

  /// Replaces the cached listing after a run, so an edited
  /// `flutter_test_config.dart` or a re-tagged scenario shows up without a
  /// restart. Only for a package that has already been asked about.
  void _relist(String path) {
    if (!_listings.containsKey(path)) return;
    _listings[path] = _runnerFor(path)
        .list()
        .then<void>((listed) => _listed[path] = listed)
        // Swallowed by design: a failed listing reads as null, and the run
        // that follows reports the same failure with the room to explain it.
        .catchError((Object _) {})
        .whenComplete(notifyChanged);
  }

  /// Re-reads the suite from disk — what [track] deliberately never does.
  ///
  /// The panel's watcher calls this on a save, which is why it is the *scan*
  /// alone: parsing `test/` is ~30ms on a spawned isolate, and a listing is a
  /// compiled harness. A file arriving must cost the first and never the
  /// second.
  void rescan(String path) => _rescan(path);

  /// [rescan], and the live listing with it — profiles, offered devices and
  /// languages, tags — for the one caller that is a person asking: the list
  /// pane's refresh button.
  ///
  /// A relisting is only queued for a package that has already got one, which
  /// is [_relist]'s rule and the reason this is safe to press: refreshing a
  /// suite you have not opened does not trigger a harness compile.
  void refresh(String path) {
    _rescan(path);
    _relist(path);
  }

  /// Replaces the cached scan — what [track] deliberately never does.
  void _rescan(String path) {
    _scans[path] =
        _scan(
              packageRoot: host.workspace.packageFor(path).directory.path,
              directory: scanRootFor(path),
            )
            .then<void>((result) {
              _results[path] = result;
              _delta.scanLanded(path, result);
              // Same recovery rule as [track]: the watcher rescans on every
              // save, and the one that read a half-written file must not brand
              // the suite "scan failed" after the next one read it whole.
              _errors.remove(path);
            })
            .catchError((Object error) => _errors[path] = error)
            .whenComplete(notifyChanged);
  }

  @override
  PluginReport get report {
    return PluginReport(
      id: host.id,
      label: host.label,
      description: _pluginDescription,
      status: _status(),
      children: [
        for (var path in packages)
          PluginChild(
            id: path,
            label: path == '.' ? 'root' : path,
            status: _packageStatus(path),
            badge: switch (_results[path]?.scenarios.length) {
              null || 0 => StatusBadge.none,
              var count => StatusBadge.count(count),
            },
          ),
      ],
      badge: _errors.isNotEmpty
          ? const StatusBadge.dot(Tone.error)
          : StatusBadge.none,
      actions: [
        const PluginAction(
          'diff',
          'Diff',
          returns: ScenarioDiffResult,
          description:
              'Compares two runs that are already on disk and reports which '
              'steps moved — the same comparison every `run` makes against '
              'whatever ran before it, over two directories you name. A green '
              'suite whose pictures move every pass is a suite no comparison '
              'against a base checkout can be trusted through, and nothing '
              'else in a run report shows it. Compares more than the '
              "pictures: the status and nav bar tints, the soft keyboard's "
              'height and whether each step settled are recorded beside the '
              'capture and are invisible to it, so a behaviour change no '
              'screenshot could show still reports here.',
          parameters: [
            ActionParameter(
              'before',
              'Baseline run',
              kind: ActionParameterKind.string,
              required: true,
              description:
                  'The run to compare against, as a directory holding a '
                  '`run.json` — worktree-relative unless absolute. One point '
                  'of a matrix is a directory of its own; `index.json` at the '
                  'root of a matrix names them',
            ),
            ActionParameter(
              'after',
              'Run',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The run to compare, same shape as `before`. Omitted, the '
                  'newest run on disk that holds a report',
            ),
            ActionParameter(
              'steps',
              'Steps',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'How many moved steps of each list ride back. 20 by '
                  'default, `all` for every one of them — the counts are '
                  'whole either way, and it is the names an agent chasing a '
                  'regression reads',
            ),
          ],
        ),
        PluginAction(
          'list',
          'List',
          returns: ScenarioListResult,
          description:
              'Every scenario of a package, with its source location — from '
              'the syntactic scan, without compiling or running anything',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package; all of them when omitted',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
          ],
        ),
        PluginAction(
          'run',
          'Run',
          returns: ScenarioRunResult,
          description:
              'Runs scenarios under FakeAsync in a directly-spawned '
              'flutter_tester, capturing a PNG, a widget tree and the visible '
              'texts per step. The paths in the result point at the '
              'artifacts; a failing scenario reports its error with the frame '
              'captured **at** the failure, whatever the capture policy. The '
              'answer summarises the steps (see `steps=`); `run.json` in the '
              'output directory always carries every one. Every run also '
              'compares itself against the run before it and reports the '
              '`drift`: which steps of a green suite moved that nobody asked '
              'to move — see the `diff` action, which is the same comparison '
              'over two runs you name.',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package; all of them when omitted',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'file',
              'File',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Run only this scenario file, package-relative — as `list` '
                  'reports it. A directory runs everything under it, which is '
                  'the unit the folder profiles are declared in. Several, '
                  'comma-separated (or `--file` repeated), run in the order '
                  'given in one process — the way to reproduce a failure '
                  'that only happens after another file has run',
            ),
            const ActionParameter(
              'scenario',
              'Scenario',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Run only this scenario, by name. Needs `file` too — names '
                  'are unique per file, not per package.',
            ),
            const ActionParameter(
              'output',
              'Output directory',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Where step artifacts are written, worktree-relative '
                  "unless absolute; a fresh directory under the package's "
                  'build/ when omitted. run.json lands in the same '
                  'directory as the images it names. A run over several '
                  'packages writes each into `<output>/<package>`, with '
                  '`/` in its path as `-` and the root package as `root`.',
            ),
            const ActionParameter(
              'baseline',
              'Baseline',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Which run to compare this one against for `drift`, as a '
                  'directory holding a `run.json` — worktree-relative unless '
                  'absolute. Omitted, the newest earlier run of the same '
                  "point under the package's build/, which is 'whatever ran "
                  "last in this directory' and so is not something CI can "
                  'depend on: a gate that wants to catch a suite going '
                  'non-deterministic names a stored base instead. A fanned-'
                  'out run takes the matching point inside it — '
                  '`<baseline>/<slug>` — and refuses where that point is '
                  'missing rather than comparing one point against another, '
                  'which shares no scenario and would answer `compared: 0`. '
                  'A run over several packages takes each one from '
                  '`<baseline>/<package>`, the directory `output` gave it',
            ),
            // The axes. Declared because they change the pixels, and anything
            // that changes the pixels is recorded on the artifact's address.
            ActionParameter(
              'device',
              'Device',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'Run as a device: its screen, its pixel ratio, its safe '
                  'areas and its platform, so the app reads the phone from '
                  '`MediaQuery`. Omitted lets each scenario run as its own '
                  'folder says — the first device of the profile its '
                  '`flutter_test_config.dart` declares, or '
                  '$defaultScenarioDeviceId where a folder declares none. '
                  '`fit` means the bare 800×600 test surface. The same '
                  'vocabulary Previews frames with.',
              options: [
                for (var device in Devices.all)
                  ActionOption(device.id, label: device.label),
                ActionOption(fitDeviceId, label: 'Bare test surface'),
              ],
            ),
            ActionParameter(
              'orientation',
              'Orientation',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  '$orientationParameterDoc Applies to whatever device the run '
                  "ends up as, including one a folder's profile chose rather "
                  'than this call.',
              options: [for (var id in orientationIds) ActionOption(id)],
            ),
            const ActionParameter(
              'language',
              'Language',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'A locale tag — `fr`, `fr-CA` — applied as the platform '
                  "locale and as the scenario's own assignment "
                  '(`s.assignment?.language`), the same pair `FW_LANGUAGES` '
                  'sets under `flutter test`',
            ),
            const ActionParameter(
              'devices',
              'Devices',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'A comma-separated matrix — `iphone-se,android-tall`. Runs '
                  'everything once per device, each into its own '
                  '`<output>/<device>-<language>/` directory with an '
                  '`index.json` beside them. The same plural vocabulary as '
                  '`flutter test --dart-define=fw.devices=`. Overrides '
                  '`device`.',
            ),
            const ActionParameter(
              'languages',
              'Languages',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The other half of the matrix — `en,fr,de`. Crossed with '
                  '`devices`, and overrides `language`.',
            ),
            const ActionParameter(
              'orientations',
              'Orientations',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The third axis — `portrait,landscape`. Crossed with the '
                  'other two, and overrides `orientation`. A device that '
                  'cannot turn contributes one point rather than two '
                  'identical ones, so mixing a desktop into the devices does '
                  'not double the run.',
            ),
            const ActionParameter(
              'matrix',
              'Matrix',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  '`declared` runs every point the folder profiles declare — '
                  'the union of their devices, languages and orientations, '
                  'crossed exactly as explicit lists are. What CI wants '
                  'instead of restating the declaration in `devices=` and '
                  'watching the two drift. Instead of the axis lists, not '
                  'beside them.',
              options: [ActionOption('declared')],
            ),
            const ActionParameter(
              'tag',
              'Tag',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Run only scenarios carrying this tag — the same tag '
                  '`scenario(tags: [...])` declares and `flutter test --tags` '
                  'filters on',
            ),
            const ActionParameter(
              'steps',
              'Steps',
              kind: ActionParameterKind.choice,
              required: false,
              defaultValue: 'failing',
              description:
                  'How many steps ride back in the answer. Every run writes '
                  'all of them to `run.json` in its output directory either '
                  'way and each package names that file — a script reads it '
                  'back typed with `package:flutterware/scenarios_report.dart` '
                  '— so this is about what '
                  'arrives without asking: `failing` (default) is the frame '
                  'each red scenario died on, `all` is every step of every '
                  'scenario — a matrix suite is hundreds — and `none` is the '
                  'summary alone, which is the answer to "did it pass". '
                  'Anything but `all` also counts the green scenarios '
                  'instead of listing them: each package says `passed` and '
                  '`failed`, lists only the red, skipped and stalled ones, and '
                  '`scenariosElided` says how many rows are in the file. '
                  'Every listed scenario reports its `stepCount` whatever '
                  'this says, and `stepsElided` says how many of them are in '
                  'the file rather than here. Anything but `all` also leaves the '
                  "scenario's translation reads on disk: a suite with a "
                  'catalog registered spends more of the answer on those than '
                  'on everything else together.',
              options: [
                ActionOption('failing'),
                ActionOption('all'),
                ActionOption('none'),
              ],
            ),
            const ActionParameter(
              'text-scale',
              'Text scale',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The platform text scale factor — `1.3` is a common '
                  'accessibility setting',
            ),
            const ActionParameter(
              'brightness',
              'Brightness',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'The platform brightness the app sees',
              options: [ActionOption('light'), ActionOption('dark')],
            ),
            const ActionParameter(
              'bold-text',
              'Bold text',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'The bold-text accessibility switch',
              options: [ActionOption('true'), ActionOption('false')],
            ),
            const ActionParameter(
              'high-contrast',
              'High contrast',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'The high-contrast accessibility switch',
              options: [ActionOption('true'), ActionOption('false')],
            ),
            const ActionParameter(
              'invert-colors',
              'Invert colors',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'The invert-colors accessibility switch',
              options: [ActionOption('true'), ActionOption('false')],
            ),
            const ActionParameter(
              'capture-scale',
              'Capture scale',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Screenshot pixels per logical pixel, up to 4. Omitted '
                  "means the package's configured captureScale "
                  "(tool/flutterware.dart), or 1. The device's own ratio "
                  'gives a true screenshot; 1 is ~10× faster and smaller, '
                  'which is what keeps a long FakeAsync run instantaneous. '
                  'Not an axis: it changes the artifact, never what the app '
                  'sees.',
            ),
            const ActionParameter(
              'clock',
              'Clock origin',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'An ISO-8601 timestamp `clock.now()` starts at — '
                  '`2026-01-01T09:00:00Z` — or `now` for the wall clock. '
                  'Omitted, a scenario runs at the date the project pins, '
                  'which is what makes two runs of a suite comparable: a '
                  'clock left to itself starts at the moment the run happened, '
                  'so any screen showing a date differs run to run. Whichever '
                  'applies, the report says which. Reaches code that reads '
                  '`package:clock`; a direct `DateTime.now()` cannot be '
                  'intercepted by anything.',
            ),
            const ActionParameter(
              'network',
              'Network',
              kind: ActionParameterKind.string,
              required: false,
              options: [
                ActionOption('off'),
                ActionOption('replay'),
                ActionOption('record'),
                ActionOption('live'),
              ],
              description:
                  "What this run's http requests reach. `off` — the default "
                  '— lets nothing leave the process: a request no scenario '
                  'stated an answer for fails at once, naming itself, rather '
                  'than hanging the way an https request does under a plain '
                  '`flutter test`. `replay` answers from the recording '
                  'committed beside the scenarios, offline and byte for byte; '
                  'a request the recording does not hold is refused, naming '
                  'it. `record` goes out and writes what comes back, '
                  'overwriting what it fetches and leaving the rest — run it '
                  'once, read the diff, commit. `live` goes out and writes '
                  'nothing, which is the honest reading and the unrepeatable '
                  'one: the same suite run twice is two different runs, and a '
                  'scenario empties the image cache by design, so a suite pays '
                  "its round trips once per scenario. Beats what a folder's "
                  "`runScenarios(network: ...)` and the project's "
                  '`fw.network(...)` said; a `scenario(network: ...)` beats '
                  'all three. The report says which modes ran.',
            ),
            const ActionParameter(
              'format',
              'Image format',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  '`png` (the default) is what everything opens. `raw` — '
                  'bare rgba8888 rows, width×height×4 bytes as the result '
                  'reports them — skips the encoder, which costs ~7.5ms a '
                  'picture, and hands a pipeline pixels with nothing to '
                  'decode. Worth it where the pictures are many or the '
                  'reader has no codec: measured, 4.3× on a run recording '
                  'motion and 31% on one that is not, for 80× to 160× the '
                  'bytes. `none` skips pixels entirely — trees, keys and '
                  'texts are still written; for probe passes that read the '
                  'walk rather than the frames.',
              options: [
                ActionOption('png'),
                ActionOption('raw'),
                ActionOption('none'),
              ],
            ),
            const ActionParameter(
              'pixels',
              'Which steps get a picture',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  '`all` (the default) photographs every step. `keyed` '
                  'photographs only the steps whose read found a translation '
                  'key, plus any step that failed — what a translation export '
                  'wants, since it files a shot against a string id and a '
                  'screen showing no key can contribute none. Measured on the '
                  'example suite, 23 of 62 steps showed no key. `named` '
                  'photographs only the steps a `Shot` named, plus any step '
                  'that failed — what the `shots` action runs with, since it '
                  'keeps the named shots and deletes the rest, and at a '
                  "device's own ratio an automatic step costs eleven times a "
                  '1× one to produce a file nobody opens. Orthogonal to '
                  '`format`, which says how the pixels are encoded; '
                  '`format: none` still means no pixels at all.',
              options: [
                ActionOption('all'),
                ActionOption('keyed'),
                ActionOption('named'),
              ],
            ),
            const ActionParameter(
              'expand',
              'Expand translations',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Pad every translation read — the max-length probe. The '
                  'number is a rung in [1, 100]: that percentage of each '
                  "value's own ceiling, which is larger the shorter the "
                  'value is (a 6-character label is probed up to +300%, a '
                  'sentence up to +100%). Which sightings clip says which '
                  'keys have no room. Identity still resolves and targeting '
                  'still lands: a scenario written against the catalog reads '
                  'the padded value too. Usually paired with `format: none`.',
            ),
            const ActionParameter(
              'device-choice',
              'Device choice',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'How a file with no named device picks from its folder '
                  'profile. `narrowest` takes the tightest declared screen '
                  'instead of the first — what a max-length probe measures '
                  'on. Ignored when `device` names one.',
              options: [ActionOption('narrowest')],
            ),
          ],
        ),
        PluginAction(
          'read',
          'Read a captured step',
          returns: ScenarioReadResult,
          description:
              'Asks a step a run already captured what is on it. Every run '
              'writes four legs per step — the picture, the widget tree, the '
              'semantics and the texts — and until now handed back paths and '
              'nothing that could read them. With no flags this answers the '
              'question worth asking first: **what is on this screen**, as a '
              'nested list of the things that carry words or respond to '
              'touch, with their boxes and their state. Everything heavier is '
              'one flag on the same capture: `find` for where something is, '
              '`at` for what is under a point, `styles` for the type ramp, '
              '`tree` for all of it, `events` for what the app *did* on the '
              'way here. The same grammar `run act` answers with on a live '
              'app — a `find` here and a `find` there differ in which file '
              'was opened and in nothing you have to learn twice.',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'Which declared package the run belongs to; the only one '
                  'when there is one',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'step',
              'Step',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Which capture. Any leg of it as `run` reported it — the '
                  '`tree` path, the `image` path, the `fw://` address — or a '
                  'plain index into the run. Omitted takes the failing step when '
                  'exactly one scenario went red, which is the read that '
                  'happens most. Naming a directory instead lists what is in '
                  'it, so browsing costs a refusal rather than a guess.',
            ),
            const ActionParameter(
              'output',
              'Run directory',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The run to read, when `step` is an index or omitted. The '
                  'newest completed run under the package when omitted — the '
                  'one you just did, never a panel session, which writes '
                  'captures but no run.json to count into.',
            ),
            ActionParameter(
              'lens',
              'Lens',
              kind: ActionParameterKind.choice,
              required: false,
              defaultValue: 'act',
              description:
                  'How much to hand back, as one word. `act` is the screen '
                  'alone; `look` adds the archived picture; `design` adds '
                  'every distinct text style; `raw` adds the whole tree and '
                  'costs about 20,000 tokens. The same four words `run` uses. '
                  'A flag you set explicitly always beats the lens.',
              options: [
                for (var lens in ObserveLens.values) ActionOption(lens.name),
              ],
            ),
            const ActionParameter(
              'screen',
              'Screen',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'true',
              description:
                  'The nested list of what is on the step — the default '
                  'answer. `false` when you only want a query.',
            ),
            const ActionParameter(
              'find',
              'Find',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Report only the nodes matching this, case-insensitively '
                  "against each node's type, its description and the words it "
                  'puts on screen. What to reach for instead of `tree` when '
                  'the question is "is the error message in there".',
            ),
            const ActionParameter(
              'at',
              'At a point',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The chain of widgets under this point as `x,y`, innermost '
                  'last — in the same logical pixels every box in this reply '
                  'is in, so a point read off the screen lands here without a '
                  'transform.',
            ),
            const ActionParameter(
              'styles',
              'Text styles',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Every distinct text size, weight and colour on the step, '
                  'most-used first with a sample of each. ~185 tokens, and it '
                  'settles most typography arguments — two greys that should '
                  'be one, a ramp with both 11.5 and 12.5 in it.',
            ),
            const ActionParameter(
              'texts',
              'Texts',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'The flat list of every string the step showed, as the '
                  'capture recorded it. The screen carries the same words '
                  'attached to what owns them; this is for grepping.',
            ),
            const ActionParameter(
              'events',
              'Events',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'What the app did on the way to this step — every request, '
                  'query, analytics event, log line and platform call it '
                  'reported, with the payload each carried. `eventCount` and '
                  '`eventChannels` ride on every read whether or not you ask, '
                  'so this is the flag to set when they say there is '
                  'something worth seeing. `system` is left out unless '
                  '`channel` names it: it is most of the volume and none of '
                  'the signal.',
            ),
            const ActionParameter(
              'channel',
              'Channel',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Keep only these channels, comma-separated — `network`, '
                  '`db`, `analytics`, `log`, `print`, `platform`, `system`, '
                  'or whatever name a project reported under. Implies '
                  '`events`. Naming `system` is the only way to see the '
                  'framework chatter, which is excluded by default.',
            ),
            const ActionParameter(
              'errors',
              'Errors only',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Keep only the events that are themselves a problem — a '
                  '4xx/5xx, a severe log, a channel call that came back an '
                  'error. Implies `events`. The first question to ask of a '
                  'step that failed.',
            ),
            const ActionParameter(
              'tree',
              'Widget tree',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'The whole widget tree. **~20,000 tokens** on a real '
                  'screen — an order of magnitude past everything else here, '
                  'and `find`, `at` and `styles` answer most of what anyone '
                  'reads a tree for. Narrow it with `treeRoot` and '
                  '`treeDepth`.',
            ),
            const ActionParameter(
              'treeRoot',
              'Tree root',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Narrow `tree` to this node id and below. Ids come from '
                  'tree shape, so one a `find` gave still names this node.',
            ),
            const ActionParameter(
              'treeDepth',
              'Tree depth',
              kind: ActionParameterKind.integer,
              required: false,
              description: 'Stop `tree` this many levels below its root',
            ),
            const ActionParameter(
              'treeNoise',
              'Keep wrappers',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'true',
              description:
                  'Drop the framework wrappers nobody wrote — `Padding`, '
                  '`Semantics`, the twenty nodes under every '
                  '`MaterialApp`. On by default; `false` keeps them.',
            ),
            const ActionParameter(
              'screenshot',
              'Picture',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Hand back the archived PNG as a picture rather than as a '
                  'path. Off by default because the screen answers most '
                  'questions for a fifth of the tokens; `lens: look` is the '
                  'short way to say yes.',
            ),
          ],
        ),
        PluginAction(
          webExportActionId,
          'Export a web page',
          returns: ScenarioWebExportResult,
          description:
              'Runs the scenarios and writes the result as a browsable page: '
              'the same flow canvas, step pages and inspect dock the GUI '
              'draws, over the run it just did. Takes every selector and axis '
              '`run` takes — the page shows what was run, so what to run is '
              'the question it asks. Needs serving over HTTP; the result says '
              'how. For a CI artifact, a review link, or anyone who has the '
              'app but not the checkout.',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package; all of them when omitted',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'file',
              'File',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Export only this scenario file, package-relative — as '
                  '`list` reports it. A directory exports everything under '
                  'it',
            ),
            const ActionParameter(
              'scenario',
              'Scenario',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Export only this scenario, by name. Needs `file` too.',
            ),
            const ActionParameter(
              'tag',
              'Tag',
              kind: ActionParameterKind.string,
              required: false,
              description: 'Export only scenarios carrying this tag',
            ),
            const ActionParameter(
              'output',
              'Output directory',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Where the page goes, worktree-relative unless absolute; '
                  'defaults to `${ScenarioWebExporter.defaultOutput}` under '
                  'the package. Emptied before writing.',
            ),
            const ActionParameter(
              'base-href',
              'Base href',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Where the page is mounted. Defaults to `./`, which '
                  "resolves against the page's own URL and so works at a "
                  'server root and under a prefix alike. Give an absolute '
                  '`/scenarios/` only for a host that serves a directory '
                  'without redirecting to a trailing slash.',
            ),
            const ActionParameter(
              'offline',
              'Self-contained',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'Bundle CanvasKit into the page instead of fetching it '
                  "from Google's CDN. Bigger, and the only form that works "
                  'behind a firewall or after the engine revision stops being '
                  'hosted.',
              options: [ActionOption('true'), ActionOption('false')],
            ),
            // The axes, exactly as `run` declares them: a page is a picture of
            // a run, and a picture is under-specified without them.
            ActionParameter(
              'device',
              'Device',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Run as a device before capturing the page',
              options: [for (var id in deviceIds) ActionOption(id)],
            ),
            ActionParameter(
              'orientation',
              'Orientation',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which way up that device is, before capturing',
              options: [for (var id in orientationIds) ActionOption(id)],
            ),
            const ActionParameter(
              'language',
              'Language',
              kind: ActionParameterKind.string,
              required: false,
              description: 'A locale tag — `fr`, `fr-CA`',
            ),
            const ActionParameter(
              'devices',
              'Devices',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'A matrix — `iphone-se,ipad`. Every point lands on the same '
                  'page, each scenario labelled with what it ran as.',
            ),
            const ActionParameter(
              'languages',
              'Languages',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description: 'The other half of the matrix — `en,fr,de`',
            ),
            const ActionParameter(
              'brightness',
              'Brightness',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'The platform brightness the app sees',
              options: [ActionOption('light'), ActionOption('dark')],
            ),
            const ActionParameter(
              'capture-scale',
              'Capture scale',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Screenshot pixels per logical pixel, up to 4. A page is '
                  'read on a retina screen, so 2 is worth the bytes where 1 is '
                  'right for a panel.',
            ),
            const ActionParameter(
              'clock',
              'Clock origin',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'An ISO-8601 timestamp `clock.now()` starts at, or `now` '
                  "for the wall clock. Omitted, the project's pin applies "
                  'and two exported pages of the same suite are comparable.',
            ),
          ],
        ),
        PluginAction(
          videoActionId,
          'Render a video',
          returns: Artifact,
          description:
              'Renders one scenario as an mp4 — the app moving under a cursor '
              'that travels, presses and types, paced for somebody watching '
              'rather than for a suite. For a landing page, a README or a '
              'release note. It is a second run of the same scenario: the '
              'verbs are the same, the pacing is not, and nothing it captures '
              'is evidence. Needs `ffmpeg` on PATH.',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'file',
              'File',
              kind: ActionParameterKind.string,
              required: true,
              description:
                  'The scenario file, package-relative — as `list` reports it',
            ),
            const ActionParameter(
              'scenario',
              'Scenario',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Which scenario in that file. Optional where the file holds '
                  'exactly one; refused with the names where it holds more.',
            ),
            const ActionParameter(
              'branch',
              'Branch',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Which branch to take at a `split`, outermost first — one '
                  'per split. A film is one path, so a scenario that splits '
                  'is refused until it is told which.',
            ),
            ActionParameter(
              'device',
              'Device',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which device to film it on',
              options: [for (var id in deviceIds) ActionOption(id)],
            ),
            ActionParameter(
              'orientation',
              'Orientation',
              kind: ActionParameterKind.choice,
              required: false,
              description: orientationParameterDoc,
              options: [for (var id in orientationIds) ActionOption(id)],
            ),
            const ActionParameter(
              'language',
              'Language',
              kind: ActionParameterKind.string,
              required: false,
              description: 'A locale tag — `fr`, `fr-CA`',
            ),
            const ActionParameter(
              'brightness',
              'Brightness',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'light or dark',
              options: [ActionOption('light'), ActionOption('dark')],
            ),
            const ActionParameter(
              'scale',
              'Scale',
              kind: ActionParameterKind.string,
              required: false,
              defaultValue: '3',
              description:
                  'Output pixels per logical pixel. Three by default and not '
                  'one: every player insists on `yuv420p`, which halves the '
                  'colour resolution, and rendering above the size the clip '
                  'is watched at is what keeps UI text crisp under it.',
            ),
            const ActionParameter(
              'fps',
              'Frames a second',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '30',
              description:
                  'Of the film and of the fake clock alike — a pump advances '
                  "time by exactly one frame, so the curves are the app's own "
                  'with nothing dropped.',
            ),
            const ActionParameter(
              'travel',
              'Travel (ms)',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '350',
              description: 'How long the cursor takes to fly to its target',
            ),
            const ActionParameter(
              'aim',
              'Aim (ms)',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '140',
              description:
                  'The beat between arriving and pressing. Nobody lands on a '
                  'button and presses it in the same instant, and without this '
                  'every verb reads as hurried.',
            ),
            const ActionParameter(
              'dwell',
              'Dwell (ms)',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '600',
              description:
                  'The hold after a verb has settled — reading time. The app '
                  'keeps running through it, so a spinner keeps spinning.',
            ),
            const ActionParameter(
              'open',
              'Opening hold (ms)',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '500',
              description:
                  'The hold on the first screen, before anything is '
                  'touched',
            ),
            const ActionParameter(
              'press',
              'Press (ms)',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '120',
              description: 'The cursor is down and the verb has not fired yet',
            ),
            const ActionParameter(
              'close',
              'Closing hold (ms)',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '800',
              description:
                  'The final hold, so the clip does not cut on the frame the '
                  'last verb landed on',
            ),
            const ActionParameter(
              'reel',
              'Reel',
              kind: ActionParameterKind.boolean,
              required: false,
              defaultValue: 'false',
              description:
                  'Cut the film as a reel: a push-in on every tap, a caption '
                  'for every `s.title`, the last frame held under the '
                  "scenario's name — the scenario's own `reel:` edit where "
                  'it declared one, the stock one otherwise. The scenario '
                  'runs twice for it, once dry for the take.',
            ),
            const ActionParameter(
              'crf',
              'Quality',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '18',
              description:
                  'What `libx264` aims at, lower being better and bigger. '
                  'Cheap either way: the render moves far more pixels than '
                  'the encode does.',
            ),
            const ActionParameter(
              'preset',
              'Encoder preset',
              kind: ActionParameterKind.string,
              required: false,
              defaultValue: 'slow',
              description:
                  'The `libx264` preset. The whole span from `medium` to '
                  '`ultrafast` is 15% of a render, so `slow` is nearly free '
                  'here.',
            ),
            const ActionParameter(
              'output',
              'Output file',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Where the mp4 goes, worktree-relative unless absolute. '
                  'Defaults to `build/flutterware/video/<scenario>.mp4` under '
                  'the package.',
            ),
          ],
        ),
        PluginAction(
          'new',
          'New scenario',
          returns: ScenarioNewResult,
          description:
              'Writes a runnable scenario file where the package keeps them, '
              'and reports the command that runs it. The scaffold pumps a stub '
              'app and drives it, so it passes as written — replace the stub '
              'with your own widget. Start here when you have never written '
              'one: it is the API, in a file that already works.',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description:
                  'Which declared package; the only one when there is one',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'name',
              'Name',
              kind: ActionParameterKind.string,
              required: true,
              description:
                  "The scenario's name — what `run --scenario=` takes and what "
                  'the panel lists',
            ),
            const ActionParameter(
              'file',
              'File',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Package-relative path to write. Defaults to a snake_cased '
                  "`_test.dart` from the name, under the package's scenario "
                  'directory. Never overwrites.',
            ),
          ],
        ),
        PluginAction(
          'shots',
          'Store screenshots',
          returns: ScenarioShotsResult,
          description:
              'The store/documentation lane: runs the scenarios and keeps '
              'only their **named** shots, at the pixel ratio each device '
              'really has, '
              'into `<output>/<language>/<device>/NN-name.png`. Everything a '
              '`run` leaves behind — the automatic steps, the widget trees — '
              'is dropped. A separate action because every default differs; '
              '`run` stays the debugging lane.',
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package; all of them when omitted',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
            const ActionParameter(
              'output',
              'Output directory',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Where the tree is written, worktree-relative unless '
                  'absolute; `build/flutterware/screenshots` under the '
                  'package when omitted. Emptied first, so what is there '
                  'afterwards is exactly this run. Several packages each get '
                  '`<output>/<package>`, named as `run` names them.',
            ),
            const ActionParameter(
              'devices',
              'Devices',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'A comma-separated list — one directory per device. Omitted '
                  "runs each scenario on its folder profile's first device.",
            ),
            const ActionParameter(
              'languages',
              'Languages',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'A comma-separated list — one directory per language, '
                  'crossed with `devices`',
            ),
            const ActionParameter(
              'orientations',
              'Orientations',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'The third axis — `portrait,landscape`. Crossed with the '
                  'other two. A turned device gets its own directory, '
                  '`<language>/<device>-landscape/`, because the two ways up '
                  'of one device are two sets of screenshots and sharing a '
                  'directory would leave the second overwriting the first. '
                  'Portrait writes no suffix, so a tree that never asked for '
                  'landscape is the tree it was. A device that cannot turn '
                  'contributes one point rather than two identical ones.',
            ),
            const ActionParameter(
              'tag',
              'Shot tag',
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Keep only shots carrying this tag — '
                  "`Shot('Home', tags: ['store'])`. Omitted keeps every named "
                  'shot, which is what a project that tags nothing wants.',
            ),
            const ActionParameter(
              'file',
              'File',
              repeatable: true,
              kind: ActionParameterKind.string,
              required: false,
              description:
                  'Only this scenario file, package-relative — or a directory, '
                  'for everything under it',
            ),
          ],
        ),
        PluginAction(
          'restart',
          'Restart',
          returns: ScenarioRestartResult,
          description:
              'Drops the warm harness so the next run cold-starts from '
              'nothing: fresh asset bundle, fresh kernel, fresh tester '
              'process. The escape hatch for changes no incremental lane '
              "can see — a dependency's assets, or plain distrust.",
          parameters: [
            ActionParameter(
              'package',
              'Package',
              kind: ActionParameterKind.choice,
              required: false,
              description: 'Which declared package; all of them when omitted',
              options: [
                for (var path in packages)
                  ActionOption(path, label: path == '.' ? 'root' : path),
              ],
            ),
          ],
        ),
      ],
      view: _view(),
    );
  }

  /// The request's axis assignment, validated. Refused rather than
  /// approximated — a device this build does not know must fail loudly,
  /// because silently running at the default surface produces a picture that
  /// is wrong without looking wrong.
  static ScenarioAxes _axesFrom(Map<String, Object?> arguments) {
    var device = arguments['device'];
    if (device != null && (device is! String || !isDeviceId(device))) {
      throw ArgumentError.value(
        device,
        'device',
        'no such device. Accepted: ${deviceIds.join(', ')}',
      );
    }
    var orientation = arguments['orientation'];
    if (orientation != null &&
        (orientation is! String || !isOrientationId(orientation))) {
      throw ArgumentError.value(
        orientation,
        'orientation',
        'no such orientation. Accepted: ${orientationIds.join(', ')}',
      );
    }
    var language = arguments['language'];
    if (language != null &&
        (language is! String ||
            !RegExp(r'^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})?$')
                .hasMatch(language))) {
      throw ArgumentError.value(
        language,
        'language',
        'not a locale tag — expected e.g. `fr` or `fr-CA`',
      );
    }
    double? textScale;
    if (arguments['text-scale'] case var raw?) {
      textScale = switch (raw) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      };
      if (textScale == null) {
        throw ArgumentError.value(raw, 'text-scale', 'not a number');
      }
    }
    var brightness = arguments['brightness'];
    if (brightness != null && brightness != 'light' && brightness != 'dark') {
      throw ArgumentError.value(
        brightness,
        'brightness',
        'accepted: light, dark',
      );
    }
    bool flag(String name) {
      var raw = arguments[name];
      if (raw == null || raw == 'false' || raw == false) return false;
      if (raw == 'true' || raw == true) return true;
      throw ArgumentError.value(raw, name, 'accepted: true, false');
    }

    return ScenarioAxes(
      device: device as String?,
      orientation: orientation as String?,
      language: language as String?,
      textScale: textScale,
      brightness: brightness as String?,
      boldText: flag('bold-text'),
      highContrast: flag('high-contrast'),
      invertColors: flag('invert-colors'),
    );
  }

  /// What a run of this core is doing, while one runs — read by the sidebar and
  /// forwarded by MCP as progress. A matrix is one process per point and each
  /// takes seconds, so the point being run is the news.
  final _busy = <String, Status>{};

  void _setBusy(String path, Status? status) {
    if (status == null) {
      _busy.remove(path);
      _ran.remove(path);
      _narrow.remove(path);
    } else {
      _busy[path] = status;
    }
    notifyChanged();
  }

  /// How far the point being run has got: scenarios that have announced a
  /// step, out of what the scan found.
  ///
  /// A point takes as long as the suite does — minutes on a real one — and
  /// "running" for that long is indistinguishable from a hang. The count is of
  /// scenarios rather than steps because a scenario is the unit a person
  /// wrote, and because the denominator for steps is not knowable until they
  /// have all run.
  ///
  /// [total] is the syntactic scan's count, so it is null until that lands and
  /// it counts a scenario that then skips itself. A run that ends a scenario
  /// short of the total has skipped the difference, which is worth seeing.
  ({int done, int? total})? runProgressFor(String path) {
    var ran = _ran[path];
    if (ran == null) return null;
    var narrow = _narrow[path];
    return (
      done: ran.length,
      total: _scenarioCount(
        path,
        file: narrow?.file,
        scenario: narrow?.scenario,
      ),
    );
  }

  /// Scenarios that have announced a step during the point being run, so a
  /// second step from the same one does not count twice. Null for a package
  /// with no point running — a panel run of one scenario counts nothing.
  final _ran = <String, Set<String>>{};

  /// What the running point was narrowed to, so the denominator is narrowed
  /// the same way. Read on every look rather than fixed at the start, because
  /// the scan it counts may land after the point starts.
  final _narrow = <String, ({String? file, String? scenario})>{};

  void _countScenario(String path, String id) {
    if (!(_ran[path]?.add(id) ?? false)) return;
    notifyChanged();
  }

  /// Starts counting [path]'s next point from zero.
  void _startCounting(String path, {String? file, String? scenario}) {
    _ran[path] = <String>{};
    _narrow[path] = (file: file, scenario: scenario);
  }

  /// The busy line with the count appended, which is the whole of the news
  /// while a point runs.
  Status? _busyStatus(String path) {
    var busy = _busy[path];
    if (busy == null) return null;
    var progress = runProgressFor(path);
    if (progress?.total == null) {
      // Nothing to count yet, so the bare word gets its ellipsis back.
      return busy.message == _running ? const Status.info('running…') : busy;
    }
    var count = '${progress!.done} of ${progress.total} scenarios';
    return Status.info(
      busy.message == _running ? 'running $count' : '${busy.message} · $count',
    );
  }

  /// A single point's phrase, kept wordless so the count completes it —
  /// `running 12 of 46 scenarios`, rather than an ellipsis trailing into a
  /// number.
  static const _running = 'running';

  Status _status() {
    if (packages.isEmpty) return Status.none;
    if (_errors.isNotEmpty) return const Status.error('scan failed');
    for (var path in packages) {
      if (_busyStatus(path) case var busy?) return busy;
    }
    var scanning = _scans.keys.where((p) => !_results.containsKey(p)).length;
    return scanning == 0 ? Status.none : const Status.info('scanning…');
  }

  Status _packageStatus(String path) {
    if (_busyStatus(path) case var busy?) return busy;
    if (_errors.containsKey(path)) return const Status.error('scan failed');
    if (!_scans.containsKey(path)) return Status.none;
    if (!_results.containsKey(path)) return const Status.info('scanning…');
    return Status.none;
  }

  /// What each package's last full run moved against the run before it.
  ///
  /// Kept rather than derived: the comparison needs the *previous* report,
  /// which the run that produced this one has since overwritten.
  final _lastDrift = <String, ScenarioRunDrift>{};

  PluginView _view() {
    if (packages.isEmpty) {
      return const PluginView([
        ViewText(
          'This plugin has no packages. Add them in tool/flutterware.dart.',
          tone: Tone.warn,
        ),
      ]);
    }

    return PluginView([
      for (var path in packages)
        ViewSection(path, [
          if (_errors[path] case var error?)
            ViewField('Error', '$error', tone: Tone.error)
          else if (_results[path] case var result?) ...[
            ViewField('Scenarios', '${result.scenarios.length}'),
            // What the last run of this package moved that nobody asked it
            // to. Sticky until the next run replaces it, because that is the
            // question it answers: not "is the suite green" — it was — but
            // "is it the same suite twice".
            if (_lastDrift[path] case var drift? when drift.summary != null)
              ViewText(
                // Named, not "the previous run": the baseline is chosen by
                // walking backwards past panel sessions and report-less
                // directories, which is not a walk a reader can redo in their
                // head — and a number whose origin they cannot place is a
                // number they cannot act on.
                '${drift.summary} · against ${drift.baseline ?? 'the previous run'}',
                tone: Tone.warn,
              ),
            for (var diagnostic in result.diagnostics)
              ViewText(diagnostic, tone: Tone.warn),
            ViewItems([
              for (var ref in result.scenarios)
                ViewItem(
                  ref.name,
                  detail: '${ref.file}:${ref.line}',
                  address: addressFor(path, ref),
                ),
            ]),
          ] else
            const ViewText('not computed'),
        ]),
    ]);
  }

  /// Where one scenario's page is — the same segments the panel writes.
  Address addressFor(String packagePath, ScenarioRef ref) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: scenarioSegments(packagePath, file: ref.file, scenario: ref.name),
  );

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    return switch (actionId) {
      'list' => _list(arguments),
      'run' => _run(arguments),
      'diff' => _diff(arguments),
      webExportActionId => _exportWeb(arguments),
      videoActionId => _video(arguments),
      'new' => _new(arguments),
      'shots' => _shots(arguments),
      'read' => _read(arguments),
      'restart' => _restart(arguments),
      _ => super.invoke(actionId, arguments: arguments),
    };
  }

  /// One archived step, answered.
  ///
  /// The reader half of the archive. A run has written four legs per step
  /// for two milestones and handed back paths; an agent debugging a red
  /// scenario got one inlined frame and a pile of file names. This opens the
  /// tree beside the picture and answers the same questions the live surfaces
  /// answer, in the same shape — `Screen.of` is a pure function of an
  /// `InspectTree`, and a step's tree is one on disk.
  ///
  /// Nothing is re-run. A capture is a settled moment that already happened,
  /// which is the one thing this surface has that the live ones do not: the
  /// answer cannot drift between the question and the reply.
  Future<ScenarioReadResult> _read(Map<String, Object?> arguments) async {
    var lens = _lensFrom(arguments);
    var picked = _pickStep(arguments);

    var treeFile = File('${picked.base}.tree.json');
    if (!treeFile.existsSync()) {
      // The step a timed-out scenario never took: no picture and maybe no
      // tree, but its failure is the diagnosis and its events are what the
      // app printed on the way there — the read that step exists for.
      if (_stepRecordFor(picked.base)?.$2 case var record?
          when record.failure != null || record.hasEvents) {
        var (:events, :eventsNote) = _eventsFor(picked, arguments);
        var noScreen =
            'This step has no screen: the scenario stopped before anything '
            'could be photographed. Its failure says why, and `events: true` '
            'is what the app did on the way there.';
        return ScenarioReadResult(
          step: _relative(picked.base),
          lens: lens.name,
          scenario: picked.scenario,
          file: picked.file,
          index: picked.index,
          failure: picked.failure,
          note: [noScreen, ?eventsNote].join(' '),
          events: events,
          eventCount: record.eventCount,
          eventChannels: record.eventChannels,
          steps: picked.siblings,
        );
      }
      throw ArgumentError.value(
        _relative(picked.base),
        'step',
        'that capture has a picture but no widget tree beside it — a `raw` '
            'run or a `shots` run keeps only pixels. Re-run it with `run` to '
            'get a step this can read.',
      );
    }
    InspectTree tree;
    try {
      tree = InspectTree.fromJson(
        (jsonDecode(treeFile.readAsStringSync()) as Map)
            .cast<String, Object?>(),
      );
    } on FormatException catch (e) {
      throw ArgumentError.value(
        _relative(picked.base),
        'step',
        'its widget tree is not readable JSON ($e). Re-run the scenario.',
      );
    }

    var wantsShot = ScreenRead.boolArgument(
      arguments['screenshot'] ?? lens.picture,
    );
    var read = ScreenRead.of(
      tree,
      arguments,
      wantsTree: ScreenRead.boolArgument(arguments['tree'] ?? lens.tree),
      wantsStyles: ScreenRead.boolArgument(arguments['styles'] ?? lens.styles),
      worktree: host.worktree.path,
    );

    var image = picked.image;
    var showable =
        wantsShot &&
        image != null &&
        p.extension(image) == '.png' &&
        File(p.join(host.worktree.path, image)).existsSync();

    var record = _stepRecordFor(picked.base)?.$2;
    var (:events, :eventsNote) = _eventsFor(picked, arguments);

    return ScenarioReadResult(
      step: _relative('${picked.base}.tree.json'),
      lens: lens.name,
      scenario: picked.scenario,
      file: picked.file,
      index: picked.index,
      failure: picked.failure,
      image: image,
      screen: read.screen,
      texts: ScreenRead.boolArgument(arguments['texts'])
          ? _textsOf(picked.base)
          : null,
      tree: read.tree,
      nodes: read.nodes,
      find: read.find,
      at: read.at,
      styles: read.styles,
      events: events,
      eventCount: record?.eventCount,
      eventChannels: record?.eventChannels,
      // **A note, not a node.** A real phone's keyboard is not in the app's
      // widget tree either, so putting one in the screen would be inventing a
      // widget nobody wrote — and it would land in every `find`, every
      // semantics audit and every transcript. The only reason to mention it at
      // all is that a reader looking at a shot with the bottom third gone
      // cannot otherwise tell why.
      note: switch (<String>[
        if (picked.keyboard case var height?) _keyboardNote(height),
        ?(read.note ?? eventsNote),
      ]) {
        // Null rather than the empty string when nobody said anything, which
        // is what every reply before this one carried and what a reader that
        // checks for a note is checking for.
        [] => null,
        var notes => notes.join(' '),
      },
      next: _offerFor(record),
      steps: picked.siblings,
      picture: showable
          ? Artifact(
              kind: Artifact.png,
              address: Address(
                worktree: host.worktree.name,
                plugin: host.id,
                segments: ['read', p.basename(picked.base)],
              ),
              path: image,
            )
          : null,
    );
  }

  /// What the app did on the way to this step, filtered how the call asked.
  ///
  /// Off unless asked: on a suite the payload is a fraction of the file and
  /// the rest is `system` — measured on the example suite, 183 of 189 events
  /// and 98% of 30KB — so handing it back unasked would cost every read what
  /// one read in ten wants.
  ///
  /// `channel` and `errors` imply `events`, because a caller who named a
  /// filter has already said what they want. So does pointing `step` at the
  /// `.events.json` leg itself: that used to answer silently about the widget
  /// tree instead, which is the one thing a reply must never do.
  ({List<AppEvent>? events, String? eventsNote}) _eventsFor(
    _PickedStep picked,
    Map<String, Object?> arguments,
  ) {
    var channels = switch (arguments['channel']) {
      String text when text.trim().isNotEmpty =>
        text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet(),
      _ => null,
    };
    var errorsOnly = ScreenRead.boolArgument(arguments['errors']);
    var asked =
        ScreenRead.boolArgument(arguments['events']) ||
        channels != null ||
        errorsOnly ||
        (arguments['step'] as String?)?.endsWith('.events.json') == true;
    if (!asked) return (events: null, eventsNote: null);

    var file = File('${picked.base}.events.json');
    if (!file.existsSync()) {
      // Not an error: a quiet transition writes no file, and saying so beats
      // an empty list the caller has to interpret.
      return (
        events: null,
        eventsNote:
            'This step recorded no events — nothing was reported on '
            'the way to it.',
      );
    }

    List<AppEvent> all;
    try {
      all = [
        for (var event in jsonDecode(file.readAsStringSync()) as List)
          AppEvent.fromJson((event as Map).cast<String, Object?>()),
      ];
    } on FormatException catch (e) {
      return (
        events: null,
        eventsNote:
            'Its events are not readable JSON ($e). Re-run the '
            'scenario.',
      );
    }

    var kept = [
      for (var event in all)
        if (channels?.contains(event.channel) ??
            event.channel != AppChannel.system)
          if (!errorsOnly || event.error) event,
    ];
    if (kept.isNotEmpty) return (events: kept, eventsNote: null);

    // Empty after filtering is a real answer, and the reason matters: the
    // step was busy and the filter excluded everything, or `system` is all
    // there was and it is hidden by default.
    var channelsSeen = {for (var event in all) event.channel}.toList()..sort();
    return (
      events: const [],
      eventsNote:
          'No event matched. This step recorded ${all.length} on '
          '${channelsSeen.join(', ')}'
          '${errorsOnly ? ', none of them flagged as an error' : ''}'
          '${channels == null && channelsSeen.contains(AppChannel.system) ? " — `system` is hidden unless `channel` names it" : ''}.',
    );
  }

  /// The `next` line, plus the events clause when this step has any.
  ///
  /// A schema read once at connection time is not where an agent looks on
  /// step forty; the step that *has* events is where being told about them
  /// lands.
  static String _offerFor(ScenarioRunStep? record) {
    var count = record?.eventCount ?? 0;
    if (count == 0) return ScreenRead.offer;
    var channels = record?.eventChannels?.keys.join(', ');
    return '${ScreenRead.offer} · events: true for what the app did on the '
        'way here ($count on ${channels ?? 'several channels'}).';
  }

  /// What a screen with a keyboard over it says about itself.
  static String _keyboardNote(double height) =>
      'The software keyboard is up: it covers the bottom ${height.round()} '
      'points of this screen, and everything above was laid out against what '
      'is left.';

  /// The lens named for this call, or `act`.
  ///
  /// Per call and not pinnable, unlike the run plugin's. A pin earns its keep
  /// in a loop against one long-lived subject; a scenario read names its
  /// capture afresh every time, so a pin here would be hidden state with no
  /// loop to amortise it.
  static ObserveLens _lensFrom(Map<String, Object?> arguments) {
    var name = arguments['lens'] as String?;
    if (name == null || name.isEmpty) return ObserveLens.act;
    return ObserveLens.byName(name) ??
        (throw ArgumentError.value(name, 'lens', ObserveLens.unknown(name)));
  }

  /// The capture's texts leg, as the harness recorded it.
  ///
  /// Read off the report rather than off a `.texts.json`, because a scenario
  /// step keeps its texts in `run.json` where every other surface writes a
  /// fourth file.
  List<String>? _textsOf(String base) => _stepRecordFor(base)?.$2.texts;

  /// The legs a capture is written as, longest first so `.tree.json` is not
  /// read as a `.json`.
  static const _captureLegs = [
    '.semantics.json',
    '.capture.json',
    '.events.json',
    '.tree.json',
    '.png',
    '.raw',
  ];

  static String? _baseOf(String path) {
    for (var leg in _captureLegs) {
      if (path.endsWith(leg)) {
        return path.substring(0, path.length - leg.length);
      }
    }
    return null;
  }

  String _absolute(String path) =>
      p.isAbsolute(path) ? path : p.join(host.worktree.path, path);

  /// Which capture the call meant.
  ///
  /// One parameter with a browse ladder rather than four selectors. A path names
  /// a capture; a directory refuses with what is in it; an index counts into
  /// a run; nothing at all takes the failing step, which is the read that
  /// happens most. Every refusal lists the values that would have worked,
  /// which is what makes browsing cost a call rather than a guess.
  _PickedStep _pickStep(Map<String, Object?> arguments) {
    var raw = arguments['step']?.toString().trim();
    if (raw != null && raw.startsWith('${Address.scheme}://')) {
      return _pickAddressed(raw, arguments);
    }
    if (raw != null && raw.isNotEmpty && int.tryParse(raw) == null) {
      var path = _absolute(raw);
      if (_baseOf(path) case var base?) return _describe(base);
      var directory = Directory(path);
      if (directory.existsSync()) {
        throw ArgumentError.value(raw, 'step', _listing(directory));
      }
      throw ArgumentError.value(
        raw,
        'step',
        'no such file. Give a step as `run` reported it — its `tree` or its '
            '`image` path — or an index into the run, or nothing at all for '
            'the step a scenario failed on.',
      );
    }

    var runDir = _runDirectory(arguments);
    var report = _reportIn(runDir);
    var index = raw == null || raw.isEmpty ? null : int.parse(raw);

    if (report == null) {
      throw ArgumentError.value(
        _relative(runDir),
        'output',
        'no $scenarioRunReportFile in that directory, so there is no run to '
            'count steps into. Name a capture directly with `step`.',
      );
    }

    var outcomes = [
      for (var package in report.packages)
        for (var outcome in package.scenarios) outcome,
    ];
    if (index != null) {
      var hits = [
        for (var outcome in outcomes)
          for (var step in outcome.steps)
            if (step.index == index) (outcome, step),
      ];
      if (hits.length == 1) return _fromRecord(hits.single.$1, hits.single.$2);
      throw ArgumentError.value(
        index,
        'step',
        hits.isEmpty
            ? 'no step $index in that run. ${_listing(Directory(runDir))}'
            : 'step $index exists in ${hits.length} scenarios of that run — '
                  'an index counts within a scenario, so name the capture '
                  'itself. ${_listing(Directory(runDir))}',
      );
    }

    var failed = [
      for (var outcome in outcomes)
        if (!outcome.ok && outcome.steps.isNotEmpty) outcome,
    ];
    if (failed.length == 1) {
      return _fromRecord(failed.single, failed.single.steps.last);
    }
    throw ArgumentError.value(
      null,
      'step',
      failed.isEmpty
          ? 'nothing failed in that run, so there is no obvious step to read. '
                '${_listing(Directory(runDir))}'
          : '${failed.length} scenarios failed in that run, so "the failing '
                'step" names more than one. ${_listing(Directory(runDir))}',
    );
  }

  /// The step an `fw://` address names — the address `run` prints on every
  /// step, accepted back as the step it is, so a step has one identity across
  /// `run`, `read` and the GUI rather than a translation between them.
  ///
  /// Resolved against the run `output` names, or the package's newest: an
  /// address says which scenario and which step, not which run, and the run
  /// a reader has in hand is the one it just took the address from.
  _PickedStep _pickAddressed(String raw, Map<String, Object?> arguments) {
    var grammar =
        'an address here names one step of one scenario — '
        '`fw:///worktrees/<worktree>/${host.id}/<package>/<file>/<scenario>/<n>`, '
        'as `run` reports it on every step.';
    Address address;
    try {
      address = Address.parse(raw);
    } on FormatException catch (error) {
      throw ArgumentError.value(raw, 'step', '${error.message}. $grammar');
    }
    var place = address.plugin == host.id
        ? scenarioPlace(address.segments)
        : null;
    if (place == null || place.scenario == null || place.step == null) {
      throw ArgumentError.value(raw, 'step', grammar);
    }
    var runDir = _runDirectory({
      ...arguments,
      if (arguments['package'] == null) 'package': place.package,
    });
    var report = _reportIn(runDir);
    if (report == null) {
      throw ArgumentError.value(
        _relative(runDir),
        'output',
        'no $scenarioRunReportFile in that directory, so there is no run to '
            'find the addressed step in.',
      );
    }
    var hits = [
      for (var package in report.packages)
        for (var outcome in package.scenarios)
          if (outcome.file == place.file && outcome.name == place.scenario)
            for (var step in outcome.steps)
              if (step.index == place.step) (outcome, step),
    ];
    if (hits.length == 1) return _fromRecord(hits.single.$1, hits.single.$2);
    throw ArgumentError.value(
      raw,
      'step',
      hits.isEmpty
          ? 'no step ${place.step} of `${place.scenario}` (${place.file}) in '
                '${_relative(runDir)}. A matrix point lives in its own '
                'directory — name it with `output`. ${_listing(Directory(runDir))}'
          : 'step ${place.step} of `${place.scenario}` exists ${hits.length} '
                'times in that run — two scenarios in one file share that '
                'name — so name the capture itself. '
                '${_listing(Directory(runDir))}',
    );
  }

  /// The run to count into: the one named, or the newest the package has.
  String _runDirectory(
    Map<String, Object?> arguments, {
    String parameter = 'output',
  }) {
    if (arguments[parameter] case String given when given.isNotEmpty) {
      var path = _absolute(given);
      if (!Directory(path).existsSync()) {
        throw ArgumentError.value(given, parameter, 'no such directory');
      }
      return path;
    }
    var candidates = <Directory>[];
    for (var path in _requested(arguments)) {
      var runs = Directory(
        p.join(
          host.workspace.packageFor(path).directory.path,
          'build',
          'flutterware',
          'scenario_runs',
        ),
      );
      if (!runs.existsSync()) continue;
      candidates.addAll(runs.listSync().whereType<Directory>());
    }
    if (candidates.isEmpty) {
      throw ArgumentError.value(
        null,
        parameter,
        'this package has no scenario run on disk. Run one first — `run '
        'scenarios run` — or give `$parameter` a directory that holds a '
        '$scenarioRunReportFile.',
      );
    }
    // Only directories that can answer. A panel session writes captures but
    // no report — and its `panel-` prefix sorts *after* every millisecond
    // stamp, so without this the "newest" default named a panel directory on
    // every read once one existed, forever.
    var runs = [
      for (var candidate in candidates)
        if (File(p.join(candidate.path, scenarioRunReportFile)).existsSync())
          candidate,
    ];
    // Newest by name, which is the millisecond stamp `run` writes. Reading it
    // off the directory name rather than off the filesystem keeps a checkout
    // or a copy from reordering a run history.
    candidates.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    if (runs.isEmpty) {
      throw ArgumentError.value(
        _relative(candidates.last.path),
        parameter,
        '${candidates.length} capture '
        'director${candidates.length == 1 ? 'y' : 'ies'} on disk, but '
        'none holds a $scenarioRunReportFile — panel sessions write '
        'captures without one. Run `run scenarios run` first, or give '
        '`$parameter` a directory that holds one.',
      );
    }
    runs.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return runs.last.path;
  }

  /// The run this one should be compared against, and the directory it came
  /// from — see [compareScenarioRuns].
  ///
  /// Read **before** the run, because the caller that named a fixed `output`
  /// is about to overwrite the report sitting in it. Where the directory is
  /// one of ours, the answer is instead the newest earlier run of the *same
  /// point*: `<runs>/<stamp>` for a plain run and `<runs>/<stamp>/<slug>` for
  /// one point of a matrix, so a French iPhone is never compared against an
  /// English one.
  ///
  /// The directory comes back with the report because a baseline chosen by
  /// walking backwards past panel sessions and report-less directories is not
  /// one the reader of the answer could guess, and a drift they cannot place
  /// the origin of is a number they cannot act on. [given] short-circuits the
  /// walk for a caller who named one; [point] is the axis slug this call is
  /// for, and only a fanned-out run has one.
  _Baseline? _previousRun(
    String outDir,
    String packageRoot, {
    String? given,
    String? point,
  }) {
    if (given != null) {
      // A matrix compares point against point, so a named baseline means the
      // same point *inside* it — and where that point is missing this refuses
      // rather than falling back to the directory itself. The fallback looked
      // forgiving and was not: an axis slug is part of a scenario's cross-run
      // identity, so an iPhone compared against a baseline that is not the
      // iPhone shares no scenario at all and answers `compared: 0` — a
      // silence indistinguishable from a suite that did not move.
      var dir = point == null ? given : p.join(given, point);
      if (_reportIn(dir) case var previous?) return (dir: dir, run: previous);
      throw ArgumentError.value(
        _relative(given),
        'baseline',
        point == null
            ? 'no $scenarioRunReportFile there, so there is no run to compare '
                  'against. ${_listing(Directory(given))}'
            : 'this run fanned out, and that baseline holds no '
                  '$scenarioRunReportFile for the point `$point` — one point '
                  'is never compared against another, so there is nothing '
                  'here to compare it with. ${_pointsIn(given)}',
      );
    }
    if (_reportIn(outDir) case var here?) return (dir: outDir, run: here);
    var runs = Directory(
      p.join(packageRoot, 'build', 'flutterware', 'scenario_runs'),
    );
    if (!runs.existsSync() || !p.isWithin(runs.path, outDir)) return null;
    var parts = p.split(p.relative(outDir, from: runs.path));
    var stamp = parts.first;
    var suffix = parts.skip(1);
    var names = [
      for (var entry in runs.listSync().whereType<Directory>())
        p.basename(entry.path),
    ]..sort();
    for (var name in names.reversed) {
      // A panel session captures one scenario and writes no report, and its
      // prefix sorts after every millisecond stamp — the same trap
      // `_runDirectory` names.
      if (name == stamp || name.startsWith('panel-')) continue;
      var dir = p.joinAll([runs.path, name, ...suffix]);
      if (_reportIn(dir) case var previous?) return (dir: dir, run: previous);
    }
    return null;
  }

  ScenarioRunResult? _reportIn(String runDir) {
    var file = File(p.join(runDir, scenarioRunReportFile));
    if (!file.existsSync()) return null;
    try {
      return ScenarioRunResult.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    } on FormatException {
      return null;
    }
  }

  /// The report record for a capture, found by the tree path it names.
  (ScenarioRunOutcome, ScenarioRunStep)? _stepRecordFor(String base) {
    var report = _reportIn(p.dirname(p.dirname(p.dirname(base))));
    if (report == null) return null;
    for (var package in report.packages) {
      for (var outcome in package.scenarios) {
        for (var step in outcome.steps) {
          // By whichever leg the step has: a beat with no frame has no tree,
          // and the step a timed-out scenario never took may have only its
          // events — both are still the record a base names.
          if (_baseOfStep(step) == base) return (outcome, step);
        }
      }
    }
    return null;
  }

  _PickedStep _describe(String base) {
    if (_stepRecordFor(base) case var record?) {
      return _fromRecord(record.$1, record.$2);
    }
    // No report to read — a hand-placed capture, or a run directory that was
    // moved. The tree is still readable, and saying less is better than
    // refusing something that works.
    var directory = Directory(p.dirname(base));
    var siblings = <String>[
      if (directory.existsSync())
        for (var file in directory.listSync().whereType<File>())
          if (file.path.endsWith('.tree.json')) p.basename(file.path),
    ]..sort();
    return _PickedStep(
      base: base,
      siblings: siblings,
      image: [
        for (var extension in const ['.png', '.raw'])
          if (File('$base$extension').existsSync())
            _relative('$base$extension'),
      ].firstOrNull,
    );
  }

  /// The stem every leg of [step] hangs off, from whichever leg it has — a
  /// screen has a tree, a beat has none, and the step a timed-out scenario
  /// never took may have only its events. Null when it has nothing on disk
  /// at all.
  String? _baseOfStep(ScenarioRunStep step) {
    for (var leg in [step.tree, step.image, step.events, step.semantics]) {
      if (leg == null) continue;
      if (_baseOf(_absolute(leg)) case var base?) return base;
    }
    return null;
  }

  _PickedStep _fromRecord(ScenarioRunOutcome outcome, ScenarioRunStep step) =>
      _PickedStep(
        base:
            _baseOfStep(step) ??
            (throw ArgumentError.value(
              step.index,
              'step',
              'step ${step.index} of `${outcome.name}` left nothing on disk to '
                  'read — a beat with no frame, or a scenario that stopped '
                  'before anything could be captured. Its failure and errors '
                  'are in $scenarioRunReportFile.',
            )),
        file: outcome.file,
        scenario: outcome.name,
        index: step.index,
        failure:
            step.failure ??
            (outcome.steps.last == step
                ? outcome.errors.firstOrNull?.error
                : null),
        image: step.image,
        keyboard: step.keyboard,
        siblings: [
          for (var other in outcome.steps)
            if (other.tree case var tree?) p.basename(tree),
        ],
      );

  /// What is in a directory, as values that can be passed straight back.
  /// Which points a baseline directory holds, for a refusal that would
  /// otherwise leave the caller guessing what to name instead.
  ///
  /// A point is a subdirectory carrying a report, which is what a fanned-out
  /// run writes. A baseline with none of those was written by a run that did
  /// not fan out, and saying *that* is the answer — the two shapes are not
  /// interchangeable and no amount of naming a subdirectory will make them so.
  String _pointsIn(String directory) {
    var points = [
      for (var entry in Directory(directory).listSync().whereType<Directory>())
        if (File(p.join(entry.path, scenarioRunReportFile)).existsSync())
          p.basename(entry.path),
    ]..sort();
    if (points.isEmpty) {
      return 'It holds no points at all, so it is the output of a run that '
          'did not fan out. Compare against a matrix run, or run this one '
          'without `devices=`/`languages=`/`orientations=`.';
    }
    return 'It holds ${points.length} '
        'point${points.length == 1 ? '' : 's'}: ${points.join(', ')}.';
  }

  String _listing(Directory directory) {
    var steps = [
      for (var file in directory.listSync().whereType<File>())
        if (file.path.endsWith('.tree.json')) _relative(file.path),
    ]..sort();
    if (steps.isNotEmpty) {
      return '${steps.length} captures there: ${steps.join(', ')}';
    }
    if (_reportIn(directory.path) case var report?) {
      var lines = <String>[
        for (var package in report.packages)
          for (var outcome in package.scenarios)
            [
              outcome.file,
              outcome.name,
              '${outcome.stepCount} steps',
              if (outcome.unchangedCount > 0)
                '${outcome.unchangedCount} unchanged',
              if (outcome.unsettledCount > 0)
                '${outcome.unsettledCount} still animating',
              outcome.skipped
                  ? 'skipped'
                  : outcome.ok
                  ? 'ok'
                  : 'FAILED',
              ?outcome.steps.lastOrNull?.tree,
            ].join(' · '),
      ];
      return 'that run holds:\n${lines.join('\n')}';
    }
    var children = [
      for (var child in directory.listSync().whereType<Directory>())
        _relative(child.path),
    ]..sort();
    return children.isEmpty
        ? 'nothing readable in there'
        : 'directories there: ${children.join(', ')}';
  }

  /// Runs the scenarios and keeps only what a store listing or a manual can
  /// use: the named shots, at the device's own resolution, in a tree laid out
  /// by language and device.
  ///
  /// The run itself goes to a scratch directory under the output and is
  /// deleted afterwards — a store run should leave the images and nothing
  /// else, and copying out of a live run directory would leave both.
  Future<ScenarioShotsResult> _shots(Map<String, Object?> arguments) async {
    var paths = _requested(arguments);
    var file = arguments['file'] as String?;
    var tag = arguments['tag'] as String?;
    var devices = _axisList(arguments['devices'], 'devices');
    for (var id in devices) {
      if (!isDeviceId(id)) {
        throw ArgumentError.value(
          id,
          'devices',
          'no such device. Accepted: ${deviceIds.join(', ')}',
        );
      }
    }
    var languages = _axisList(arguments['languages'], 'languages');
    for (var locale in languages) {
      if (!_localePattern.hasMatch(locale)) {
        throw ArgumentError.value(
          locale,
          'languages',
          'not a locale tag — expected e.g. `fr` or `fr-CA`',
        );
      }
    }
    var orientations = _orientationList(arguments['orientations']);
    var assignments = <ScenarioAxes>[
      for (var device in devices.isEmpty ? [null] : devices)
        for (var orientation in _orientationsFor(device, orientations, null))
          for (var language in languages.isEmpty ? [null] : languages)
            ScenarioAxes(
              device: device,
              orientation: orientation,
              language: language,
            ),
    ];

    var results = <ScenarioShotsPackage>[];
    var total = 0;
    for (var path in paths) {
      var packageRoot = host.workspace.packageFor(path).directory.path;
      // Same base as `run`'s `output`: the worktree, unless absolute.
      var output = switch (arguments['output'] as String?) {
        var given? when given.isNotEmpty => _perPackage(
          _absolute(given),
          path,
          paths,
        ),
        _ => p.join(packageRoot, 'build', 'flutterware', 'screenshots'),
      };
      var root = Directory(output);
      // Emptied first: a store tree is a statement about the app as it is
      // now, and yesterday's screenshot of a screen that no longer exists
      // would ship beside today's.
      if (root.existsSync()) root.deleteSync(recursive: true);
      root.createSync(recursive: true);
      var scratch = p.join(output, '.runs');

      // Keyed by the directory the shot lands in — `<language>/<device>` —
      // which is worked out per *outcome*, because with no `devices` the
      // device comes from each scenario's own folder profile and a mixed
      // suite writes into more than one.
      var images = <String, List<String>>{};
      // Collected and flattened off-isolate at the end of the package: the
      // PNG codec is ~250ms an image, and doing it inline freezes the window
      // for as long as the whole set takes. See `flattenPngFile`.
      var flatten = <(String, String)>[];
      var failures = <String, int>{};
      var axesOf = <String, Map<String, String>>{};
      try {
        for (var assignment in assignments) {
          var report = await _runnerFor(path).run(
            outDir: p.join(scratch, axisSlug(assignment)),
            file: file,
            axes: assignment,
            unspecifiedDevice: defaultScenarioDeviceId,
            captureNative: true,
            // The whole economy of this lane. Everything below keeps named
            // shots and drops the rest — and `captureNative` means the rest
            // was being rasterized and encoded at the device's own ratio,
            // eleven times the pixels of a 1× run, written out, and then
            // deleted with the scratch directory.
            pixels: ScenarioPixels.named,
          );
          var described = _describeRun(
            path,
            p.join(scratch, axisSlug(assignment)),
            report,
            axes: assignment,
          );
          for (var outcome in described.scenarios) {
            var language = assignment.language ?? 'default';
            var device = outcome.device ?? fitDeviceId;
            // The orientation joins the device in the directory name, not
            // beside it: without it the two ways up of one device share a key
            // and the second run overwrites the first. Portrait adds nothing,
            // so a store tree that never asked for landscape is the tree it
            // was before.
            var key = p.join(
              language,
              assignment.isLandscape ? '$device-landscape' : device,
            );
            axesOf[key] = {
              'language': ?assignment.language,
              'device': device,
              if (assignment.isLandscape)
                'orientation': ScreenOrientation.landscape.name,
            };
            var into = Directory(p.join(output, key))
              ..createSync(recursive: true);
            var kept = images.putIfAbsent(key, () => []);
            if (!outcome.ok) {
              failures[key] = (failures[key] ?? 0) + 1;
            }
            for (var step in outcome.steps) {
              // Named shots only, and only the tag asked for: an automatic
              // capture is a debugging artefact, not a screenshot somebody
              // chose to show.
              if (step.name == null) continue;
              if (tag != null && !step.tags.contains(tag)) continue;
              // A named step with no picture: the scenario emitted a document
              // or a notification beat, which is a step in the flow and not a
              // screenshot of anything.
              if (step.image == null) continue;
              var number = (kept.length + 1).toString().padLeft(2, '0');
              var name = '$number-${_shotSlug(step.name!)}.png';
              // `step.image` is relative to the worktree, which is what keeps
              // a result portable; `step.root` is this machine's copy of it.
              //
              // Flattened rather than copied: a capture is RGBA whatever it
              // holds, and neither store accepts a PNG with an alpha channel.
              // See `flattenPng`.
              flatten.add((
                p.join(step.root, step.image!),
                p.join(into.path, name),
              ));
              kept.add(name);
              total++;
            }
          }
        }
        await flattenPngFiles(flatten);
        results.add(
          ScenarioShotsPackage(
            path: path,
            output: output,
            sets: [
              for (var key in images.keys.toList()..sort())
                ScenarioShotSet(
                  directory: key,
                  axes: axesOf[key] ?? const {},
                  images: images[key]!,
                  failed: failures[key] ?? 0,
                ),
            ],
          ),
        );
      } catch (error) {
        results.add(
          ScenarioShotsPackage(path: path, output: output, error: '$error'),
        );
      } finally {
        if (Directory(scratch).existsSync()) {
          Directory(scratch).deleteSync(recursive: true);
        }
      }
    }
    return ScenarioShotsResult(packages: results, count: total);
  }

  /// `01-order-placed.png` from `Order placed` — a name that sorts, survives
  /// every filesystem, and still reads as what it shows.
  static String _shotSlug(String name) => name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// The package an action names, checked against the manifest.
  ///
  /// The message names what *is* declared, so a caller that guessed can
  /// correct itself without a second round-trip — the same courtesy
  /// `Session.invoke` extends for a plugin id.
  List<String> _requested(Map<String, Object?> arguments) {
    var requested = arguments['package'];
    if (requested != null && requested is! String) {
      throw ArgumentError.value(requested, 'package', 'must be a package path');
    }
    var paths = requested == null ? packages : [requested as String];
    for (var path in paths) {
      if (!packages.contains(path)) {
        throw ArgumentError.value(
          path,
          'package',
          'not declared for this plugin. Declared: ${packages.join(', ')}',
        );
      }
    }
    return paths;
  }

  /// Writes a scenario file and says how to run it.
  ///
  /// The authoring door. Everything else here operates scenarios that already
  /// exist, which left "how do I write one" answerable only by reading
  /// flutterware's source — a question the GUI answered in an empty state that
  /// no other surface could see.
  Future<ScenarioNewResult> _new(Map<String, Object?> arguments) async {
    var paths = _requested(arguments);
    if (paths.length > 1) {
      throw ArgumentError(
        'Which package? `new` writes one file. Declared: ${packages.join(', ')}',
      );
    }
    var path = paths.single;

    var name = arguments['name'];
    if (name is! String || name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'required — the scenario name');
    }
    name = name.trim();

    var file = arguments['file'];
    if (file != null && file is! String) {
      throw ArgumentError.value(
        file,
        'file',
        'must be a package-relative path',
      );
    }
    var relative =
        (file as String?) ??
        '${newScenarioDirectoryFor(path)}/${scenarioFileName(name)}';
    if (p.isAbsolute(relative) || p.split(relative).contains('..')) {
      throw ArgumentError.value(
        relative,
        'file',
        'must be relative to the package and stay inside it',
      );
    }
    if (!relative.endsWith('.dart')) {
      throw ArgumentError.value(relative, 'file', 'must end in `.dart`');
    }
    // `flutter test` collects `*_test.dart` and nothing else, so a scenario
    // spelled otherwise runs here and silently never runs in CI.
    if (!relative.endsWith('_test.dart')) {
      throw ArgumentError.value(
        relative,
        'file',
        'must end in `_test.dart` — `flutter test` collects nothing else, and '
            'a scenario CI never runs is worse than one that does not exist',
      );
    }

    var target = File(p.join(packageRootFor(path), relative));
    if (target.existsSync()) {
      throw ArgumentError.value(
        relative,
        'file',
        'already exists. Add the scenario to it, or name another file.',
      );
    }
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(scenarioScaffold(name));

    // The scan is now stale by exactly this file.
    _rescan(path);

    return ScenarioNewResult(
      package: path,
      file: relative,
      name: name,
      next:
          'fw run scenarios run --package=$path --file=$relative '
          '--scenario="$name"',
    );
  }

  Future<ScenarioRestartResult> _restart(Map<String, Object?> arguments) async {
    var paths = _requested(arguments);
    for (var path in paths) {
      restartRunner(path);
    }
    return ScenarioRestartResult(restarted: paths);
  }

  /// The scenarios of one package, or of every declared package.
  ///
  /// Loads what it needs — a report may never start work; an action asked
  /// for by name may, and must.
  Future<ScenarioListResult> _list(Map<String, Object?> arguments) async {
    var paths = _requested(arguments);
    for (var path in paths) {
      track(path);
    }
    await Future.wait([for (var path in paths) _scans[path]!]);
    // The scans registered their files, each starting or queueing a load. A
    // load already running when they landed was asked before them, so this
    // waits for the chain to settle rather than for the first to finish.
    await branchDelta?.whenSettled();

    return ScenarioListResult(
      packages: [
        for (var path in paths)
          if (_errors[path] case var error?)
            ScenarioListPackage(
              path: path,
              directory: scanRootFor(path),
              error: '$error',
            )
          else
            ScenarioListPackage(
              path: path,
              directory: scanRootFor(path),
              branch: _delta.summaryFor(path),
              scenarios: [
                for (var ref in _results[path]!.scenarios)
                  ScenarioListEntry(
                    name: ref.name,
                    file: ref.file,
                    line: ref.line,
                    change: _delta.changesFor(path)?[scenarioChangeKey(ref)],
                  ),
              ],
              diagnostics: _results[path]!.diagnostics,
              // Only when there are none: an empty list is the one moment the
              // reader is certainly asking "so how do I write one".
              authoring: _results[path]!.scenarios.isEmpty
                  ? scenarioAuthoringHint(newScenarioDirectoryFor(path))
                  : null,
            ),
      ],
    );
  }

  /// What the progress line counts against: the scan's scenarios, narrowed
  /// the way the run is.
  ///
  /// Null while the scan is still parsing — the count appears a beat after the
  /// run starts rather than the run waiting for it, because compiling the
  /// harness takes far longer than parsing the directory does.
  int? _scenarioCount(String path, {String? file, String? scenario}) {
    var scenarios = _results[path]?.scenarios;
    if (scenarios == null) return null;
    if (scenario != null) return 1;
    if (file == null) return scenarios.length;
    return scenarios.where((ref) => anySelectsFile(file, ref.file)).length;
  }

  /// Runs scenarios in the runner's `flutter_tester`.
  ///
  /// The runner per package is created on first use and **kept warm** — in
  /// the GUI a second run reuses the compiled harness and the live tester; in
  /// a one-shot `fw` process it lives for the request and dies with the
  /// session.
  Future<ScenarioRunResult> _run(Map<String, Object?> arguments) async {
    var paths = _requested(arguments);
    // Not awaited: it is what the progress count is against, and a run that
    // waited on it would pay for the parse before compiling anything. A core
    // the panel has mounted has scanned already; one synthesized for an export
    // has not.
    for (var path in paths) {
      track(path);
    }
    var file = arguments['file'] as String?;
    var scenario = arguments['scenario'] as String?;
    if (scenario != null && file == null) {
      throw ArgumentError(
        '`scenario` needs `file` too — names are unique per file, '
        'not per package.',
      );
    }
    // Resolved here, once, worktree-relative unless absolute — because a
    // relative path handed through verbatim reaches two writers with
    // different working directories: `fw` writes `run.json` from wherever it
    // was invoked, the tester writes the PNGs from the package root.
    // Measured on a real suite as an index in one directory pointing at
    // artifacts in another, with `image` paths that every worktree-relative
    // reader — `read`, MCP artifacts, the web export, `shots` — resolved to
    // files that were not there.
    var output = switch (arguments['output'] as String?) {
      var given? when given.isNotEmpty => _absolute(given),
      _ => null,
    };
    var axes = _axesFrom(arguments);
    var rawTag = arguments['tag'];
    if (rawTag != null && rawTag is! String) {
      throw ArgumentError.value(rawTag, 'tag', 'must be a tag name');
    }
    var tag = rawTag as String?;
    // The matrix, as CI writes it — the same plural vocabulary
    // `--dart-define=fw.devices=` uses in the bare `flutter test` lane, so a
    // project learns one and gets both.
    var devices = _axisList(arguments['devices'], 'devices');
    for (var id in devices) {
      if (!isDeviceId(id)) {
        throw ArgumentError.value(
          id,
          'devices',
          'no such device. Accepted: ${deviceIds.join(', ')}',
        );
      }
    }
    var languages = _axisList(arguments['languages'], 'languages');
    for (var tag in languages) {
      if (!_localePattern.hasMatch(tag)) {
        throw ArgumentError.value(
          tag,
          'languages',
          'not a locale tag — expected e.g. `fr` or `fr-CA`',
        );
      }
    }
    // One point when nothing fanned out, which is every panel run and every
    // `fw run scenarios run` that names at most one of each.
    var orientations = _orientationList(arguments['orientations']);
    var matrix = arguments['matrix'];
    if (matrix != null && matrix != 'declared') {
      throw ArgumentError.value(
        matrix,
        'matrix',
        'accepted: declared — every point the folder profiles declare',
      );
    }
    if (matrix != null &&
        (devices.isNotEmpty ||
            languages.isNotEmpty ||
            orientations.isNotEmpty)) {
      throw ArgumentError(
        '`matrix=declared` reads devices, languages and orientations from '
        'the declaration — drop the explicit lists, or keep them and drop '
        '`matrix`.',
      );
    }
    List<ScenarioAxes> cross(
      List<String> devices,
      List<String> orientations,
      List<String> languages,
    ) => [
      for (var device in devices.isEmpty ? [axes.device] : devices)
        for (var orientation in _orientationsFor(
          device,
          orientations,
          axes.orientation,
        ))
          for (var language in languages.isEmpty ? [axes.language] : languages)
            ScenarioAxes(
              device: device,
              orientation: orientation,
              language: language,
              textScale: axes.textScale,
              brightness: axes.brightness,
              boldText: axes.boldText,
              highContrast: axes.highContrast,
              invertColors: axes.invertColors,
            ),
    ];
    var assignments = cross(devices, orientations, languages);
    double? captureScale;
    if (arguments['capture-scale'] case var raw?) {
      captureScale = switch (raw) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      };
      if (captureScale == null || captureScale <= 0 || captureScale > 4) {
        throw ArgumentError.value(raw, 'capture-scale', 'a number in (0, 4]');
      }
    }
    var format = arguments['format'];
    if (format != null &&
        format != 'png' &&
        format != 'raw' &&
        format != 'none') {
      throw ArgumentError.value(format, 'format', 'accepted: png, raw, none');
    }
    var pixels = arguments['pixels'];
    if (pixels != null &&
        pixels != 'all' &&
        pixels != 'keyed' &&
        pixels != 'named') {
      throw ArgumentError.value(
        pixels,
        'pixels',
        'accepted: all, keyed, named',
      );
    }
    var expand = switch (arguments['expand']) {
      null => null,
      num value => value.toInt(),
      String value => int.tryParse(value),
      var other => throw ArgumentError.value(other, 'expand', 'a rung'),
    };
    if (arguments['expand'] != null &&
        (expand == null || expand < 1 || expand > 100)) {
      throw ArgumentError.value(
        arguments['expand'],
        'expand',
        'a rung in [1, 100]',
      );
    }
    var deviceChoice = arguments['device-choice'];
    if (deviceChoice != null && deviceChoice != 'narrowest') {
      throw ArgumentError.value(
        deviceChoice,
        'device-choice',
        'accepted: narrowest',
      );
    }
    DateTime? clock;
    if (arguments['clock'] case var raw?) {
      // `now` resolves to an instant here rather than travelling as a word,
      // so what the run reports is a date somebody could write down and
      // re-run with — which is the whole point of reporting it.
      clock = switch (raw) {
        'now' => DateTime.now(),
        String it => DateTime.tryParse(it),
        _ => null,
      };
      if (clock == null) {
        throw ArgumentError.value(
          raw,
          'clock',
          'not an ISO-8601 timestamp — expected e.g. `2026-01-01T09:00:00Z`, '
              'or `now` for the wall clock',
        );
      }
    }

    ScenarioNetwork? network;
    if (arguments['network'] case String raw) {
      // The harness's own parser, so the action and the test process cannot
      // disagree about what a mode is called.
      network = parseScenarioNetwork(raw);
    }

    var steps = arguments['steps'] as String? ?? 'failing';
    if (!const ['failing', 'all', 'none'].contains(steps)) {
      throw ArgumentError.value(steps, 'steps', 'accepted: failing, all, none');
    }

    String? baseline;
    if (arguments['baseline'] case String given when given.isNotEmpty) {
      baseline = _absolute(given);
      if (!Directory(baseline).existsSync()) {
        throw ArgumentError.value(given, 'baseline', 'no such directory');
      }
    }

    var results = <ScenarioRunPackage>[];
    // Keyed by output directory, which is one per point of the matrix and so
    // the one thing that separates two entries of the same package.
    var drifts = <String, ScenarioRunDrift>{};
    // The clock every scenario of this request started at, as the harness
    // reports it. One request, one origin — the first package to come back
    // settles it.
    DateTime? ranAtClock;
    var assignmentsFor = <String, List<ScenarioAxes>>{};
    for (var path in paths) {
      if (matrix == null) {
        assignmentsFor[path] = assignments;
        continue;
      }
      // The declared matrix, read from the harness's own listing — the same
      // probe that fills the panel's pickers, and the run is about to pay
      // for the compiled harness anyway. The union across the package's
      // folders, crossed exactly as explicit lists are: CI stops restating
      // in `devices=` what `flutter_test_config.dart` already says, so
      // adding a device to the declaration adds it to CI.
      _setBusy(path, const Status.info('reading the declared matrix…'));
      try {
        var declaredDevices = <String>{};
        var declaredOrientations = <String>{};
        var declaredLanguages = <String>{};
        for (var listing in await _runnerFor(path).list()) {
          declaredDevices.addAll(listing.devices);
          declaredOrientations.addAll(listing.orientations);
          declaredLanguages.addAll(listing.languages);
        }
        assignmentsFor[path] = cross(
          declaredDevices.toList(),
          declaredOrientations.toList(),
          declaredLanguages.toList(),
        );
      } catch (_) {
        // A harness that cannot even list will not run either; one point is
        // enough for the run below to fail with the real error, in the
        // per-package shape everything downstream knows.
        assignmentsFor[path] = assignments;
      } finally {
        _setBusy(path, null);
      }
    }
    var points = assignmentsFor.values.fold(
      0,
      (sum, list) => sum + list.length,
    );
    var anyFannedOut = assignmentsFor.values.any((list) => list.length > 1);
    var point = 0;
    for (var path in paths) {
      var pathAssignments = assignmentsFor[path]!;
      var fannedOut = pathAssignments.length > 1;
      var packageRoot = host.workspace.packageFor(path).directory.path;
      var base = switch (output) {
        var given? => _perPackage(given, path, paths),
        _ => p.join(
          packageRoot,
          'build',
          'flutterware',
          'scenario_runs',
          '${DateTime.now().millisecondsSinceEpoch}',
        ),
      };
      // This run replaces whatever the last one had to say about drift,
      // including having had nothing to say.
      _lastDrift.remove(path);
      for (var assignment in pathAssignments) {
        // One directory per point of the matrix. Without it the second
        // assignment overwrites the first — same file, same scenario, same
        // step names — and only the last language survives on disk.
        var outDir = fannedOut ? p.join(base, axisSlug(assignment)) : base;
        // Before the run, not after: a caller that named a fixed `output` is
        // about to overwrite the report sitting in it. And before this point
        // is marked busy, because a named `baseline` that holds no run is
        // refused from here — a throw between `_setBusy` and the `finally`
        // that clears it would leave the plugin reading `running…` forever.
        var previous = _previousRun(
          outDir,
          packageRoot,
          given: baseline == null ? null : _perPackage(baseline, path, paths),
          point: fannedOut ? axisSlug(assignment) : null,
        );
        // From zero for this point: the count is how far *this* pass has
        // got, and one that carried the previous point's over would start the
        // second language at 46 of 46.
        _startCounting(path, file: file, scenario: scenario);
        // One process per point, seconds each — so which point is running is
        // the news a sidebar shows and MCP forwards. The matrix count only
        // when there is a matrix: "1 of 1" is noise.
        _setBusy(
          path,
          Status.info(
            points > 1
                ? 'running ${++point} of $points · ${axisSlug(assignment)}'
                : _running,
          ),
        );
        try {
          var report = await _runnerFor(path).run(
            outDir: outDir,
            file: file,
            scenario: scenario,
            tag: tag,
            axes: assignment,
            unspecifiedDevice: defaultScenarioDeviceId,
            captureScale: captureScale ?? captureScaleFor(path),
            captureRaw: format == 'raw',
            // `format: none` wins: it says there are no pixels, and `keyed`
            // only ever narrows which steps have them.
            pixels: format == 'none'
                ? ScenarioPixels.none
                : pixels == 'keyed'
                ? ScenarioPixels.keyed
                : pixels == 'named'
                ? ScenarioPixels.named
                : ScenarioPixels.all,
            expandTranslations: expand,
            narrowestDevice: deviceChoice == 'narrowest',
            clock: clock,
            network: network,
          );
          // The harness's own answer, not this side's: the origin it applied
          // may have come from the default or from `FW_CLOCK`, neither of
          // which this side can see. Stated because a pinned date is only safe
          // while it is said out loud — an app with a trial expiry or a
          // seasonal theme sits in a different state under one.
          if (report['clock'] case String raw) {
            ranAtClock ??= DateTime.tryParse(raw);
          }
          var described = _describeRun(
            path,
            outDir,
            report,
            axes: assignment,
            recordAxes: fannedOut,
            log: _harnessLog(path),
          );
          // A selector that matched nothing used to come back as an empty list
          // and exit 0 — a typo reading as a green run. The harness compiled
          // from disk just now, so a fresh scan is the honest list to offer
          // back. Per selector when several were given: a typo in the second
          // file must not run green on the strength of the first.
          var missed = file == null
              ? null
              : fileSelectors(file)
                    .where(
                      (one) => !described.scenarios.any(
                        (ran) => selectsFile(one, ran.file),
                      ),
                    )
                    .firstOrNull;
          if (missed != null ||
              (described.scenarios.isEmpty &&
                  (scenario != null || tag != null))) {
            results.add(
              ScenarioRunPackage(
                path: path,
                output: outDir,
                axes: fannedOut ? assignment.toParams() : null,
                error: await _selectorMiss(
                  path,
                  file: missed ?? file,
                  scenario: scenario,
                  tag: tag,
                ),
              ),
            );
          } else {
            if (previous != null) {
              var drift = compareScenarioRuns(
                previous.run,
                ScenarioRunResult(packages: [described]),
                // The directory it was actually read from, worktree-relative:
                // the `output` the baseline recorded for itself is where that
                // run was written, which a copied or moved checkout no longer
                // names — and this one is what `diff` takes back.
                baseline: _relative(previous.dir),
              );
              drifts[outDir] = drift;
              // One point of a matrix is as good a witness as the whole of
              // it: a suite that moves moves on every point, and the panel
              // has one line to say so in.
              if (!drift.isEmpty || !_lastDrift.containsKey(path)) {
                _lastDrift[path] = drift;
              }
            }
            results.add(described);
          }
        } catch (error) {
          results.add(
            ScenarioRunPackage(
              path: path,
              output: outDir,
              axes: fannedOut ? assignment.toParams() : null,
              log: _harnessLog(path),
              error: '$error',
            ),
          );
        } finally {
          _setBusy(path, null);
        }
      }
      if (fannedOut) _writeIndex(base, results.where((r) => r.path == path));
    }
    var whole = ScenarioRunResult(
      packages: [
        for (var run in results)
          _withReportOnDisk(run, drifts[run.output], clock: ranAtClock),
      ],
      axes: anyFannedOut || axes.isEmpty ? null : axes.toParams(),
      clock: ranAtClock,
    );
    // After the reports are on disk, so a sweep can never race the thing it is
    // meant to keep. The directories this request wrote are named explicitly
    // rather than trusted to sort newest — `--output` may point anywhere,
    // including at a name that looks stamped.
    for (var path in paths) {
      _sweepRuns(path, protect: {for (var run in results) run.output});
    }
    return _carrying(whole, steps);
  }

  /// Two runs already on disk, compared.
  ///
  /// The reader half of what `run` does on its own. A run's own drift asks
  /// whether the suite is deterministic here and now, against whatever
  /// happened to run last in the same directory; this asks whether it has
  /// moved since a base somebody chose — which is the question a CI gate has,
  /// and the one a walk-backwards baseline cannot be pointed at.
  Future<ScenarioDiffResult> _diff(Map<String, Object?> arguments) async {
    ScenarioRunResult read(String dir, String parameter) {
      if (!Directory(dir).existsSync()) {
        throw ArgumentError.value(
          _relative(dir),
          parameter,
          'no such directory',
        );
      }
      if (_reportIn(dir) case var report?) return report;
      throw ArgumentError.value(
        _relative(dir),
        parameter,
        'no $scenarioRunReportFile there, so there is no run to compare. '
        '${_listing(Directory(dir))}',
      );
    }

    var before = switch (arguments['before']) {
      String given when given.isNotEmpty => _absolute(given),
      var other => throw ArgumentError.value(
        other,
        'before',
        'required — the run to compare against, as a directory holding a '
            '$scenarioRunReportFile',
      ),
    };
    // The newest run that can answer, by the same rule every other read here
    // uses — a panel session writes captures and no report, and its name sorts
    // after every stamp.
    // Its own refusals name `after`, which is the parameter this caller has —
    // the same helper answers `read`, where it is called `output`.
    var after = _runDirectory(arguments, parameter: 'after');

    // Parsed once and checked for a range, not just for digits: `take` refuses
    // a negative and would answer a caller's typo with a RangeError from three
    // frames down instead of the refusal below.
    int? maxSteps = 20;
    if (arguments['steps'] case var raw? when '$raw'.isNotEmpty) {
      var count = raw == 'all' ? null : int.tryParse('$raw');
      if (raw != 'all' && (count == null || count < 0)) {
        throw ArgumentError.value(
          raw,
          'steps',
          'a count of 0 or more, or `all`',
        );
      }
      maxSteps = count;
    }

    return ScenarioDiffResult(
      before: _relative(before),
      after: _relative(after),
      maxSteps: maxSteps,
      comparison: compareScenarioRuns(
        read(before, 'before'),
        read(after, 'after'),
        baseline: _relative(before),
      ),
    );
  }

  /// Trims this package's old run directories, and says nothing about it.
  ///
  /// A run writes a directory per invocation and a recorded panel session
  /// writes a large one; nothing ever removed them, and a single worktree here
  /// had reached 848MB. Called where a run *finishes* rather than once per
  /// process, because that is where the litter is made.
  /// Deletes one superseded run directory. Housekeeping, like [_sweepRuns]:
  /// somebody looking at it, a directory already gone, or a host with no
  /// disk to delete from — none of it is worth failing a finished run over.
  void _discardRun(String dir) {
    try {
      Directory(dir).deleteSync(recursive: true);
    } on Object {
      // See above.
    }
  }

  void _sweepRuns(String path, {Set<String> protect = const {}}) {
    try {
      sweepScenarioRuns(
        host.workspace.packageFor(path).directory.path,
        protect: protect,
      );
    } on Object {
      // Housekeeping. A package that cannot be resolved, or a directory
      // somebody else is holding, is not worth failing a finished run over.
    }
  }

  /// Writes the package's own run beside its artifacts and names the file.
  ///
  /// Written before anything is trimmed, so the file is the whole answer no
  /// matter what the caller asked to be handed. Best effort: a run that
  /// produced pictures is not a failure because the directory turned
  /// read-only between writing them and writing this.
  ScenarioRunPackage _withReportOnDisk(
    ScenarioRunPackage run,
    ScenarioRunDrift? drift, {
    DateTime? clock,
  }) {
    ScenarioRunPackage carrying(String? file, ScenarioRunDrift? drift) =>
        ScenarioRunPackage(
          path: run.path,
          output: run.output,
          axes: run.axes,
          ms: run.ms,
          scenarios: run.scenarios,
          report: file,
          log: run.log,
          error: run.error,
          drift: drift,
        );
    if (run.scenarios.isEmpty) return carrying(run.report, drift);
    var file = p.join(run.output, scenarioRunReportFile);
    try {
      Directory(run.output).createSync(recursive: true);
      // Written from `run` rather than from what this returns, so the file
      // stays a record of its own run: which run came before it is the
      // caller's knowledge, not the report's. The drift goes in its own file
      // beside it for that reason, and for one more — what a caller is handed
      // back is capped and this is not.
      File(file).writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert(ScenarioRunResult(packages: [run], clock: clock).toJson()),
      );
    } catch (_) {
      return carrying(run.report, drift);
    }
    return carrying(file, _withDriftOnDisk(run.output, drift));
  }

  /// Writes the whole of [drift] beside the run's own report and hands it back
  /// saying where it went.
  ///
  /// The counts a call answers with were always honest and the lists under
  /// them were always capped — which is the wrong end to cut for a reader who
  /// wants the *names*. This is where all of them are. Best effort, like the
  /// report beside it: a run that produced pictures is not a failure because
  /// the directory turned read-only.
  ///
  /// Written for a comparison that found nothing too, which is the whole
  /// difference between "there was no run to compare against" and "there was,
  /// and the suite is clean". Both would otherwise be an absent file, and a CI
  /// gate reading one cannot tell an unverified run from a verified one.
  ScenarioRunDrift? _withDriftOnDisk(String outDir, ScenarioRunDrift? drift) {
    if (drift == null) return null;
    var file = p.join(outDir, scenarioRunDriftFile);
    try {
      File(file).writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert(drift.inFile(_relative(file)).toJson(maxSteps: null)),
      );
    } catch (_) {
      return drift;
    }
    return drift.inFile(_relative(file));
  }

  /// [whole] with the steps [mode] asks for — the rest are in the file each
  /// package names.
  ///
  /// And with the green scenarios counted rather than listed, whenever it is
  /// not `all`. A green row is sixty tokens saying "this one passed", and a
  /// 136-scenario suite answered "did it pass" in 8k of them — see
  /// [ScenarioRunPackage.passed]. A green row whose walk stalled stays: that
  /// pass is the one thing in a green run worth reading by name.
  static ScenarioRunResult _carrying(ScenarioRunResult whole, String mode) {
    if (mode == 'all') return whole;
    var keepFailing = mode == 'failing';
    return ScenarioRunResult(
      axes: whole.axes,
      // Trimming the steps must not trim the facts that describe them: an
      // answer that says which clock it ran at only in the file is an answer
      // that says it to the reader who already has one.
      clock: whole.clock,
      packages: [
        for (var run in whole.packages)
          run.carrying([
            for (var outcome in run.scenarios)
              if (keepFailing && !outcome.ok)
                // The frame it died on, not the trail that led there: one
                // scenario with split branches is nineteen steps, and four
                // red ones were 99k characters of pictures nobody had asked
                // to see. The trail is in the file, one read away.
                outcome.withFailingStepOnly()
              else if (!outcome.ok ||
                  outcome.skipped ||
                  outcome.unchangedCount > 0)
                outcome.withoutSteps(),
          ]),
      ],
    );
  }

  /// Runs the scenarios and writes the result as a page.
  ///
  /// Re-runs rather than publishing the last run. A page is dated, shared, and
  /// read by people who cannot check it, so it must not be a picture of the
  /// suite as it stood at some earlier, unrecorded moment. That is also why
  /// every selector and axis `run` takes is taken here: what to run is the
  /// question the export asks.
  ///
  /// Takes the same argument map the action does, so the command the dialog
  /// echoes is the call the button makes.
  Future<ScenarioWebExportResult> exportWeb(
    Map<String, Object?> arguments, {
    void Function(String line)? onOutput,
  }) async {
    var baseHref = switch (arguments['base-href'] as String?) {
      var given? when given.isNotEmpty => given,
      _ => defaultBaseHref,
    };
    if (baseHrefProblem(baseHref) case var problem?) {
      throw ArgumentError.value(baseHref, 'base-href', problem);
    }
    // One at a time: an export empties its output directory before writing,
    // and two of them pointed at the same one would each delete the other's
    // page halfway through copying it.
    if (_export != null) {
      throw ActionRefusal(
        'An export is already running. Wait for it, or close the worktree to '
        'stop it.',
      );
    }

    // `output` names the page here and the raw artifacts in `run`, so the run
    // is left to its own default directory and the page copies out of it.
    // Every step, because the page *is* the steps — the summary the action
    // hands an agent would export a viewer with nothing in it.
    var runResult = await _run(
      {...arguments, 'steps': 'all'}..remove('output'),
    );

    // Same base as `run`'s `output`: the worktree, unless absolute. This was
    // the third answer — package-relative — and three bases for one flag
    // name is how a consumer lost an afternoon to an empty directory.
    var page = switch (arguments['output'] as String?) {
      var given? when given.isNotEmpty => _absolute(given),
      _ => ScenarioWebExporter.defaultOutputIn(
        packageRootFor(_requested(arguments).first),
      ),
    };

    var exporter = _export = ScenarioWebExporter(
      flutterExecutable: host.workspace.flutterSdk.flutter,
      appToolRoot: host.workspace.appContext.appToolDirectory.path,
      worktreeRoot: host.worktree.path,
    );
    ScenarioWebExport written;
    try {
      written = await exporter.export(
        report: ScenarioWebReport(
          // The worktree rather than the plugin: a page says what it is a page
          // *of*, and "Scenarios" tells a reader nothing they did not know
          // from the link they followed.
          title: host.worktree.name,
          generated: DateTime.now(),
          run: runResult,
        ),
        output: page,
        baseHref: baseHref,
        offline: arguments['offline'] == 'true' || arguments['offline'] == true,
        onOutput: onOutput,
      );
    } finally {
      _export = null;
    }

    var failed = runResult.packages
        .expand((package) => package.scenarios)
        .where((scenario) => !scenario.ok)
        .length;
    return ScenarioWebExportResult(
      output: _relative(written.output),
      indexHtml: _relative(written.indexHtml),
      scenarios: written.scenarios,
      steps: written.steps,
      artifacts: written.artifacts,
      durationMs: written.duration.inMilliseconds,
      failed: failed,
      serve:
          'Serve it with any static server — `cd ${_relative(written.output)} '
          '&& python3 -m http.server`. Opening index.html as a file leaves the '
          'browser unable to fetch the report beside it, and the page says so '
          'rather than appearing empty. (The GUI serves it for you: "Export a '
          'web page…" on the package, then Open in browser.)',
    );
  }

  /// One scenario, rendered as a film.
  ///
  /// A second run of the same body, paced for a viewer: the harness keeps
  /// every frame it pumps and spends fake time on beats no scenario contains —
  /// the cursor's travel to a button, the pause after a screen arrives — and
  /// this end encodes those frames *while they are being drawn*. See
  /// `docs/superpowers/specs/2026-09-08-scenario-video-design.md`.
  ///
  /// Nothing it produces is evidence: it captures no screenshots, no trees and
  /// no semantics, and its report is thrown away. The panel's step pictures
  /// and the flow canvas remain what a run is for.
  Future<Artifact> _video(Map<String, Object?> arguments) =>
      renderVideo(arguments);

  /// [_video], with somewhere to put the progress.
  ///
  /// Public and callable directly, like [exportWeb] and for the same reason: a
  /// render takes tens of seconds and `Job` has no progress event to carry the
  /// frame count in, so the dialog that asks for one calls this instead of
  /// going through `Session.invoke`. The behaviour is identical either way —
  /// this *is* the action.
  Future<Artifact> renderVideo(
    Map<String, Object?> arguments, {
    void Function(ScenarioFilmProgress progress)? onProgress,
  }) async {
    // Before anything is compiled or rendered. Learning that ffmpeg is absent
    // after a minute of rendering is a bad way to learn it.
    if (!await VideoEncoder.available) {
      throw ActionRefusal(VideoEncoder.missing);
    }

    var paths = _requested(arguments);
    if (paths.length > 1) {
      throw ArgumentError(
        'Which package? A film is one scenario. Declared: '
        '${packages.join(', ')}',
      );
    }
    var path = paths.single;
    var file = arguments['file'] as String?;
    if (file == null || file.isEmpty) {
      throw ArgumentError(
        '`file` names the scenario file to film — as `list` reports it. A '
        'film is one scenario, so there is no "all of them" here.',
      );
    }
    var scenario = switch (arguments['scenario']) {
      String named when named.isNotEmpty => named,
      _ => await _theOneScenarioIn(path, file),
    };
    var branches = _branchList(arguments['branch']);
    var reel = arguments['reel'] == 'true' || arguments['reel'] == true;

    // Frames live in a scratch directory nobody keeps: the drain deletes each
    // one as it feeds it, and what is left at the end is the two JSON files
    // and whatever a failure stopped it from eating.
    var scratch = Directory.systemTemp.createTempSync('fw-film');
    var settings = FilmSettings(
      directory: p.join(scratch.path, 'frames'),
      fps: _positive(arguments['fps'], 'fps')?.round() ?? 30,
      scale: _positive(arguments['scale'], 'scale') ?? 3,
      branches: branches,
      open:
          _millis(arguments['open'], 'open') ??
          const Duration(milliseconds: 500),
      travel:
          _millis(arguments['travel'], 'travel') ??
          const Duration(milliseconds: 350),
      aim:
          _millis(arguments['aim'], 'aim') ?? const Duration(milliseconds: 140),
      press:
          _millis(arguments['press'], 'press') ??
          const Duration(milliseconds: 120),
      dwell:
          _millis(arguments['dwell'], 'dwell') ??
          const Duration(milliseconds: 600),
      close:
          _millis(arguments['close'], 'close') ??
          const Duration(milliseconds: 800),
    );
    var output = switch (arguments['output'] as String?) {
      var given? when given.isNotEmpty => _absolute(given),
      _ => p.join(
        packageRootFor(path),
        'build',
        'flutterware',
        'video',
        '${_slug(scenario)}.mp4',
      ),
    };

    var watch = Stopwatch()..start();
    _setBusy(path, const Status.info('rendering the film…'));
    try {
      var running = _runnerFor(path).run(
        outDir: p.join(scratch.path, 'run'),
        file: file,
        scenario: scenario,
        axes: _axesFrom(arguments),
        unspecifiedDevice: defaultScenarioDeviceId,
        // A film is not evidence, so no step is photographed. The frames are
        // the whole product and the run's own pictures would be a second
        // rendering of screens the film already holds.
        pixels: ScenarioPixels.none,
        film: settings,
        filmReel: reel,
      );
      ScenarioFilm film;
      try {
        film = await ScenarioFilmEncode(
          directory: settings.directory,
          output: output,
          preset: arguments['preset'] as String? ?? 'slow',
          crf: _positive(arguments['crf'], 'crf')?.round() ?? 18,
        ).drain(running, onProgress: onProgress);
      } catch (error) {
        // The render's own failure is the useful one — the drain only saw the
        // frames stop coming. Awaited first so that a harness that threw says
        // so, and the drain's account is what is left when it did not.
        await running;
        rethrow;
      }
      var report = await running;
      // A film of a scenario that broke halfway is not a deliverable: it ends
      // mid-flow and looks like the app failing. The failure is the news.
      if (_filmFailure(report) case var failed?) {
        File(output).deleteSync();
        throw ActionRefusal(
          '`$scenario` did not finish, so there is no film:\n\n$failed',
        );
      }
      watch.stop();
      return Artifact(
        kind: Artifact.mp4,
        address: Address(
          worktree: host.worktree.name,
          plugin: host.id,
          segments: scenarioSegments(path, file: file, scenario: scenario),
        ),
        path: _relative(film.file.path),
        meta: {
          'scenario': scenario,
          'file': file,
          if (branches.isNotEmpty) 'branches': branches,
          if (reel) 'reel': true,
          'frames': film.frames,
          'fps': film.fps,
          'size': [film.width, film.height],
          'durationMs': film.duration.inMilliseconds,
          'renderMs': watch.elapsedMilliseconds,
          'bytes': film.file.lengthSync(),
          if (film.dropped > 0) 'dropped': film.dropped,
          'beats': film.beats.length,
        },
      );
    } finally {
      _setBusy(path, null);
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  /// The scenario in [file], when it holds exactly one — or a refusal naming
  /// the ones it holds.
  ///
  /// A film is one scenario and most files are one scenario, so naming it
  /// twice is a papercut nobody needs. The refusal lists the names rather than
  /// picking the first: which flow is worth a video is not a guess this can
  /// make.
  Future<String> _theOneScenarioIn(String path, String file) async {
    _rescan(path);
    await _scans[path];
    var found = [
      for (var ref in _results[path]?.scenarios ?? const <ScenarioRef>[])
        if (selectsFile(file, ref.file)) ref,
    ];
    if (found.length == 1) return found.single.name;
    if (found.isEmpty) {
      throw ArgumentError.value(
        file,
        'file',
        await _selectorMiss(path, file: file, scenario: null),
      );
    }
    throw ArgumentError.value(
      file,
      'scenario',
      'that file holds ${found.length} scenarios, and a film is one of them. '
          'Name it: ${found.map((ref) => '`${ref.name}`').join(', ')}',
    );
  }

  /// Whichever scenario of a film run came back red, in its own words.
  ///
  /// The caught errors first: a refusal a verb threw — a `split` a film was
  /// not told which way to take — lands there with its whole message, which is
  /// the one thing worth handing back. A failed step's `failure` says the same
  /// sentence where the step got far enough to be captured.
  String? _filmFailure(Map<String, Object?> report) {
    for (var scenario in (report['scenarios'] as List?) ?? const []) {
      var record = (scenario as Map).cast<String, Object?>();
      if (record['ok'] == true || record['skipped'] == true) continue;
      for (var error in (record['errors'] as List?) ?? const []) {
        if ((error as Map)['error'] case String said when said.isNotEmpty) {
          return said;
        }
      }
      for (var step in (record['steps'] as List?) ?? const []) {
        if ((step as Map)['failure'] case String said when said.isNotEmpty) {
          return said;
        }
      }
      return 'it failed without saying why';
    }
    return report['error'] as String?;
  }

  static double? _positive(Object? raw, String name) {
    if (raw == null) return null;
    var value = switch (raw) {
      num it => it.toDouble(),
      String it => double.tryParse(it),
      _ => null,
    };
    if (value == null || value <= 0) {
      throw ArgumentError.value(raw, name, 'a number above zero');
    }
    return value;
  }

  static Duration? _millis(Object? raw, String name) {
    if (raw == null) return null;
    var value = switch (raw) {
      num it => it.toDouble(),
      String it => double.tryParse(it),
      _ => null,
    };
    if (value == null || value < 0) {
      throw ArgumentError.value(raw, name, 'milliseconds, zero or more');
    }
    return Duration(microseconds: (value * 1000).round());
  }

  /// A file name from a scenario's own name.
  /// Where [path]'s share of a directory named for a whole request goes:
  /// [given] itself when [path] is the only package, `<given>/<package>` when
  /// there are several.
  ///
  /// Every package wrote into [given] once, which is one `run.json` per
  /// request whatever the package count — each overwrote the last, and every
  /// package's answer named the survivor. `shots` was worse, emptying the
  /// directory before each package and so deleting the one before it.
  static String _perPackage(String given, String path, List<String> paths) =>
      paths.length < 2
      ? given
      : p.join(given, path == '.' ? 'root' : path.replaceAll('/', '-'));

  static String _slug(String name) {
    var slug = name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'film' : slug;
  }

  Future<ScenarioWebExportResult> _exportWeb(Map<String, Object?> arguments) =>
      exportWeb(arguments);

  /// The export in flight, so a second is refused and the first can be killed
  /// when the worktree goes.
  ScenarioWebExporter? _export;

  /// Why a `file`/`scenario` selector ran nothing, naming what it could have
  /// named instead — so a misspelling costs one round-trip and not a debugging
  /// session against a result that looked like a pass.
  Future<String> _selectorMiss(
    String path, {
    required String? file,
    required String? scenario,
    String? tag,
  }) async {
    _rescan(path);
    await _scans[path];
    var result = _results[path];
    if (result == null) {
      return 'Nothing matched ${_describeSelector(file, scenario, tag)}, and the '
          'scan that would say what does failed: ${_errors[path]}';
    }
    if (result.scenarios.isEmpty) {
      return 'Nothing matched ${_describeSelector(file, scenario, tag)} — this '
          'package has no scenarios at all.\n\n'
          '${scenarioAuthoringHint(newScenarioDirectoryFor(path))}';
    }
    // A tag-only miss: the scan cannot say which tags exist — it never
    // evaluates an argument — so this says what a tag is rather than guessing
    // at a list it does not have.
    if (file == null && tag != null) {
      return 'Nothing carries the tag "$tag". A scenario declares its tags as '
          "`scenario('…', tags: ['$tag'], (s) async { … })`.";
    }
    var inFile = result.scenarios
        .where((ref) => anySelectsFile(file!, ref.file))
        .toList();
    if (scenario != null && inFile.isNotEmpty) {
      return 'No scenario "$scenario" in $file. It declares: '
          '${inFile.map((ref) => '"${ref.name}"').join(', ')}.';
    }
    var files = {for (var ref in result.scenarios) ref.file};
    // A selector naming a directory that exists and declares nothing is a
    // different mistake from one naming a path that is not there, and the
    // old message told both of them the same thing: here is every file in
    // the package, forty-odd paths of it. It reads as "your directory is
    // invalid" when the directory is fine and simply empty.
    var directory = file!.endsWith('/')
        ? file.substring(0, file.length - 1)
        : file;
    var isDirectory = Directory(
      p.join(host.workspace.packageFor(path).directory.path, directory),
    ).existsSync();
    if (isDirectory) {
      var siblings = {
        for (var declared in files)
          if (p.isWithin(p.dirname(directory), declared))
            p.split(p.relative(declared, from: p.dirname(directory))).first,
      };
      return 'No scenarios under "$file". The directory is there and declares '
          'none — nothing below it calls `scenario(…)`'
          '${siblings.isEmpty ? '' : ', where its siblings do: '
                    '${(siblings.toList()..sort()).join(', ')}'}.';
    }
    return 'No scenarios in "$file" — and no such file or directory in this '
        'package, which declares them in: ${files.join(', ')}. `file` takes a '
        'directory too, and runs everything under it.';
  }

  static String _describeSelector(String? file, String? scenario, String? tag) {
    var selector = switch ((file, scenario)) {
      (null, _) => null,
      (var f, null) => 'file "$f"',
      (var f, var s) => 'scenario "$s" in "$f"',
    };
    // A tag is a selector like any other, and a `--tag` nobody declared is
    // exactly as silent as a misspelled file was.
    return [?selector, if (tag != null) 'tag "$tag"'].join(' with ');
  }

  /// A comma-separated axis list, trimmed and emptied of blanks.
  /// The branches a film was told to take, outermost first.
  ///
  /// Never comma-split, unlike an axis list: a branch is a label an author
  /// wrote in a sentence, and `pay by card, then refund` is a plausible one.
  /// Repeat the argument instead.
  static List<String> _branchList(Object? raw) => switch (raw) {
    null => const [],
    List list => [for (var item in list) '$item'],
    String one => one.isEmpty ? const [] : [one],
    var other => throw ArgumentError.value(other, 'branch', 'a branch label'),
  };

  static List<String> _axisList(Object? raw, String name) {
    if (raw == null) return const [];
    if (raw is List) return [for (var item in raw) '$item'.trim()];
    if (raw is! String) {
      throw ArgumentError.value(raw, name, 'a comma-separated list');
    }
    return [
      for (var part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// The orientation list a matrix asked for, checked. Empty stays empty — the
  /// caller decides what "nothing fanned out" falls back to.
  static List<String> _orientationList(Object? raw) {
    var list = _axisList(raw, 'orientations');
    for (var id in list) {
      if (!isOrientationId(id)) {
        throw ArgumentError.value(
          id,
          'orientations',
          'no such orientation. Accepted: ${orientationIds.join(', ')}',
        );
      }
    }
    return list;
  }

  /// Which orientations [device] actually contributes to the matrix.
  ///
  /// One point, not two, for anything that cannot turn. Crossing a desktop
  /// or the bare surface with both orientations would run it twice for
  /// byte-identical pixels — a doubled CI bill for a picture nobody asked for
  /// twice. The same rule the bare `flutter test` lane applies in
  /// `scenarioAssignments`, because the two lanes have to agree on how many
  /// points a matrix has.
  ///
  /// An *unnamed* device keeps whatever was asked: the folder profile that
  /// resolves it only speaks inside the harness, so there is nothing to ask
  /// here, and `Device.oriented` collapses it there instead.
  static List<String?> _orientationsFor(
    String? device,
    List<String> requested,
    String? fallback,
  ) {
    if (device != null && !(deviceById(device)?.canRotate ?? false)) {
      return const [null];
    }
    return requested.isEmpty ? [fallback] : requested;
  }

  static final _localePattern = RegExp(
    r'^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})?$',
  );

  /// The map from assignment to directory, written beside them.
  ///
  /// A matrix's artifacts are a tree a CI job has to *find* things in; the
  /// result of the call says the same thing, but the call is gone by the time
  /// the upload step runs. Paths are relative to the index, which is what
  /// makes the whole directory movable.
  void _writeIndex(String base, Iterable<ScenarioRunPackage> runs) {
    var index = ScenarioRunIndex(
      runs: [
        for (var run in runs)
          ScenarioRunIndexEntry(
            package: run.path,
            axes: run.axes,
            output: p.relative(run.output, from: base),
            ok: run.error == null && run.scenarios.every((s) => s.ok),
            scenarios: run.scenarios.length,
            failed: run.scenarios.where((s) => !s.ok).length,
            skipped: run.scenarios.where((s) => s.skipped).length,
            error: run.error,
          ),
      ],
    );
    Directory(base).createSync(recursive: true);
    File(p.join(base, scenarioRunIndexFile)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(index.toJson()),
    );
  }

  /// The escape hatch: drops [path]'s warm harness, so the next run
  /// cold-starts from nothing — fresh asset bundle, fresh kernel, fresh
  /// tester process. For the changes no incremental lane can see, and for
  /// "I don't trust anything right now".
  void restartRunner(String path) {
    if (_runners.remove(path) case var runner?) {
      unawaited(runner.dispose());
    }
    _runnerPhases.remove(path);
    notifyChanged();
  }

  ScenarioRunSource _runnerFor(String path) {
    var runner = _runners.putIfAbsent(
      path,
      () => (_runnerFactory ?? _liveRunner)(
        path,
        onLog: (line) {
          // Lines the panel has no word for are the guest's own console —
          // an app's `print` during boot. Real log material, and nothing the
          // spinner is waiting for, so the caption does not move for them.
          if (scenarioRunnerPhase(line) case var phase?) {
            _runnerPhases[path] = phase;
            notifyChanged();
          }
        },
      ),
    );
    // (Re)attached on every ask, so an installed test runner streams too.
    runner.onStep = (event) => _onRunnerStep(path, event);
    return runner;
  }

  /// A warm `flutter_tester` for [path] — what runs scenarios everywhere but
  /// in a recording.
  ScenarioRunSource _liveRunner(
    String path, {
    required void Function(String line) onLog,
  }) => ScenarioRunner(
    packageRoot: host.workspace.packageFor(path).directory.path,
    directory: scanRootFor(path),
    flutterSdkRoot: host.workspace.flutterSdk.root,
    projectClock: host.projectClock,
    projectNetwork: host.projectNetwork,
    onLog: onLog,
  );

  /// Installs a runner for [path], so a test can drive the run-state machinery
  /// without a real `flutter_tester` behind it.
  @visibleForTesting
  void debugInstallRunner(String path, ScenarioRunSource runner) =>
      _runners[path] = runner;

  /// An artifact path as every surface reports it: relative to the worktree,
  /// so it survives being read on another machine and an agent whose tools are
  /// scoped to the repo can open it. A `--output` outside the worktree has no
  /// relative spelling, and keeps its absolute one.
  String _relative(String path) {
    var root = host.worktree.path;
    return p.isWithin(root, path) ? p.relative(path, from: root) : path;
  }

  /// One step of the harness's vocabulary — the same record whether it
  /// arrived in the final report or as a mid-run event — located: paths made
  /// worktree-relative, and its `fw://` address assigned, carrying [axes] as
  /// query parameters since the picture depends on them.
  ScenarioRunStep _stepFrom(
    Map<String, Object?> step,
    String path, {
    required String file,
    required String scenario,
    required ScenarioAxes axes,
  }) => _locate(
    ScenarioRunStep.fromJson(step),
    path,
    file: file,
    scenario: scenario,
    axes: axes,
  );

  ScenarioRunStep _locate(
    ScenarioRunStep step,
    String path, {
    required String file,
    required String scenario,
    required ScenarioAxes axes,
  }) {
    return step.locate(
      root: host.worktree.path,
      path: _relative,
      address: Address(
        worktree: host.worktree.name,
        plugin: host.id,
        segments: scenarioSegments(path, file: file, scenario: scenario),
        axes: axes.toParams(),
      ).child('${step.index}').toString(),
    );
  }

  /// The harness console file for [path], when a run has left one behind.
  String? _harnessLog(String path) {
    var log = _runnerFor(path).logPath;
    return File(log).existsSync() ? log : null;
  }

  /// The harness's report, in the declared result shape.
  ScenarioRunPackage _describeRun(
    String path,
    String outDir,
    Map<String, Object?> report, {
    ScenarioAxes axes = const ScenarioAxes(),
    bool recordAxes = false,
    String? log,
  }) {
    return ScenarioRunPackage(
      path: path,
      output: outDir,
      axes: recordAxes ? axes.toParams() : null,
      log: log,
      ms: report['ms'] as int? ?? 0,
      time: report['time'] as String? ?? 'fake',
      animations: (report['animations'] as num?)?.toDouble(),
      scenarios: [
        for (var entry
            in (report['scenarios']! as List).cast<Map<String, Object?>>())
          () {
            var outcome = ScenarioRunOutcome.fromJson(entry);
            return outcome.carrying([
              for (var step in outcome.steps)
                _locate(
                  step,
                  path,
                  file: outcome.file,
                  scenario: outcome.name,
                  // The address on an artifact says what produced it, so an
                  // unspecified device is filled in with what the folder
                  // resolved it to — a link that reopens the same picture.
                  axes: axes.copyWith(device: outcome.device),
                ),
            ]);
          }(),
      ],
    );
  }

  /// Scans every declared package and waits — what `fw` does for the duration
  /// of one request.
  @override
  Future<void> computeAll() async {
    for (var path in packages) {
      track(path);
    }
    await Future.wait(_scans.values);
  }

  @override
  void dispose() {
    _delta.dispose();
    for (var runner in _runners.values) {
      unawaited(runner.dispose());
    }
    _runners.clear();
    // A `flutter build web` outlives its parent on macOS, and the one this
    // started is writing into the worktree that is going away.
    unawaited(_export?.cancel());
    _export = null;
    super.dispose();
  }
}

/// A package's syntactic scan — see [ScenariosCore.new].
typedef ScenarioScan = Future<ScenarioScanResult> Function({
  required String packageRoot,
  required String directory,
});

/// Makes the thing that runs [path]'s scenarios — see [ScenariosCore.new].
/// [onLog] receives the harness's console, a line at a time.
typedef ScenarioRunSourceFactory = ScenarioRunSource Function(
  String path, {
  required void Function(String line) onLog,
});

PluginCore scenariosCoreFactory(PluginHost host) => ScenariosCore(host);

/// One archived capture, chosen — and what the run record knows about it.
class _PickedStep {
  _PickedStep({
    required this.base,
    this.siblings = const [],
    this.file,
    this.scenario,
    this.index,
    this.failure,
    this.image,
    this.keyboard,
  });

  /// Absolute, without an extension: every leg is `$base.<leg>`.
  final String base;

  /// The other captures of the same scenario, as `step:` values — what makes
  /// walking a failing flow backwards one call each.
  final List<String> siblings;

  final String? file;
  final String? scenario;
  final int? index;
  final String? failure;

  /// Worktree-relative, as the run reported it.
  final String? image;

  /// How tall the software keyboard was when this frame was taken, or null
  /// when it was down. See [ScenarioRunStep.keyboard].
  final double? keyboard;
}
