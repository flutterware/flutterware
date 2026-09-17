/// What a scenario run writes down, typed — the model behind `run.json`.
///
/// One vocabulary, three careers. The harness records each step in this shape
/// as it captures; `fw run scenarios run` writes the whole run to `run.json`
/// beside its artifacts; and whoever reads that file back — the studio's own
/// panels, an exported web page, or a consumer's `tool/` script — parses it
/// into these same classes. A shape with fewer careers than that was the old
/// state of affairs: three hand-kept copies that could drift one field apart.
///
/// This is published API. A field renamed here breaks somebody's script,
/// which is why [scenarioRunReportVersion] exists and why [ScenarioRunResult.fromJson]
/// refuses a major it does not know rather than handing back a half-decoded
/// object. Added fields do not bump the version — an older reader ignoring a
/// new key is the behaviour that makes adding one cheap.
///
/// Plain Dart on purpose — nothing here may import `package:flutter`, and
/// nothing here may import `dart:io`: a consumer's script runs under a bare
/// `dart run`, and the exported scenario page parses this very model in a
/// browser. The disk-facing reader lives in `report_io.dart`.
library;

import '../plugins/address.dart';
import '../plugins/artifact.dart';
import '../plugins/plugin_result.dart';
import 'aim.dart';
import 'drift.dart';
// The drift types are part of this model's surface — `ScenarioRunPackage`
// carries one — so whoever has the model has them.
export 'aim.dart';
export 'drift.dart';
// The one thing near this model that needs a filesystem, behind the one seam
// that lets the rest of it compile for the web. The exported scenario page
// renders these very classes in a browser, where there is no `dart:io` to
// import — see `2026-08-11-scenario-web-export-design.md`.
import 'notification.dart';
import 'report_events_web.dart' if (dart.library.io) 'report_events_io.dart';

/// The format `run.json` (and the matrix's `index.json`) is written in.
///
/// Bumped only when a reader of the previous version would get something
/// wrong. Added fields do not bump it — an older reader ignoring a new key is
/// the behaviour that makes adding one cheap.
const scenarioRunReportVersion = 1;

/// What a run writes beside its artifacts: itself, whole, in this shape.
///
/// Named next to the model rather than next to the writer, because reading it
/// back is the point — [ScenarioRunResult.fromJson] on this file is the other
/// half of an answer that summarised.
const scenarioRunReportFile = 'run.json';

/// What a run writes beside [scenarioRunReportFile] when it had a run before
/// it to compare against: [ScenarioRunDrift], whole.
///
/// Its own file rather than a key in the report, because the report is a
/// record of one run and which run came before it is not a fact about that
/// run — a copy of it taken elsewhere would carry a baseline that means
/// nothing there. Its own file also because the drift a caller is handed back
/// is capped and this is not: the full list of what moved is the thing an
/// agent chasing a regression actually wants, and truncating names while
/// keeping counts is the wrong end to cut.
const scenarioRunDriftFile = 'drift.json';

/// What a matrix run writes at the root of its output tree: one line per
/// point, each naming the directory whose `run.json` holds the rest.
///
/// A matrix's artifacts are a tree a CI job has to *find* things in; the
/// result of the call says the same thing, but the call is gone by the time
/// the upload step runs.
const scenarioRunIndexFile = 'index.json';

/// A whole `run` — scenarios executed in the runner's `flutter_tester`, with
/// one artifact triple (PNG, widget tree, texts) per captured step.
class ScenarioRunResult
    implements PluginResult, ReportsFailure, ProducesArtifacts {
  ScenarioRunResult({
    this.version = scenarioRunReportVersion,
    required this.packages,
    this.axes,
    this.clock,
  });

  /// Decodes a `run.json`.
  ///
  /// Throws [FormatException] on a version this reader does not know: the
  /// reader of that message is looking at somebody else's build output, so it
  /// names what was found and what would work.
  factory ScenarioRunResult.fromJson(Map<String, Object?> json) {
    var version = _int(json['version'], 1);
    if (version > scenarioRunReportVersion) {
      throw FormatException(
        'This run report is version $version and this is a reader for '
        '$scenarioRunReportVersion. Upgrade the flutterware dependency of '
        'whatever reads it.',
      );
    }
    return ScenarioRunResult(
      version: version,
      packages: _listOf(json['packages'], ScenarioRunPackage.fromJson),
      axes: _stringsOrNull(json['axes']),
      clock: switch (json['clock']) {
        String it => DateTime.tryParse(it),
        _ => null,
      },
    );
  }

  final int version;

  final List<ScenarioRunPackage> packages;

  /// The axis assignment the whole request ran under —
  /// `{device: iphone-se, language: fr}` — or null for the test defaults.
  /// Recorded because a screenshot is under-specified without it; the same
  /// values ride every step's address as query parameters.
  final Map<String, String>? axes;

  /// What `clock.now()` read at the start of every scenario in the run.
  ///
  /// Recorded for the reason [axes] is: a capture is under-specified without
  /// it. Scenarios are pinned to a date by default — see `pinnedClockOrigin`
  /// — and a pin is only safe while it is stated, because an app with a trial
  /// expiry, a seasonal theme or a "new since" badge sits in a different state
  /// under one and nothing on the screen says why.
  ///
  /// Null only in a report written before runs recorded it.
  final DateTime? clock;

  /// False when any package failed to run at all, or any scenario it ran came
  /// back red — what makes `fw run scenarios run` exit 1.
  @override
  bool get ok => packages.every(
    (p) => p.error == null && p.scenarios.every((scenario) => scenario.ok),
  );

  /// The frame just before each failure, and nothing else.
  ///
  /// Every step's PNG is on the wire as a path already; the reader that can
  /// open files opens them. This is for the reader that cannot — an MCP client
  /// with no filesystem — and for the one that can but should not have to
  /// guess which of fifty pictures matters. A green run offers none: there is
  /// nothing to look at.
  @override
  List<Artifact> get artifacts => [
    for (var package in packages)
      for (var scenario in package.scenarios)
        if (!scenario.ok && scenario.steps.isNotEmpty)
          if (scenario.steps.last case var step
              when step.format == 'png' && step.image != null)
            Artifact(
              kind: Artifact.png,
              address: Address.parse(step.address),
              path: step.image!,
              meta: {
                'scenario': scenario.name,
                'file': scenario.file,
                'step': step.index,
                'name': ?step.name,
                'texts': step.texts,
                // The failing transition in full, `system` and all — the
                // digest every step carries is capped and filtered, and this
                // is the one step where the thing that broke it may be the
                // twentieth line. Same reasoning as the frame itself: the
                // reader should not have to make a second call for the answer.
                if (readStepEvents(step) case var events when events.isNotEmpty)
                  'events': events,
                if (scenario.errors.firstOrNull case var error?)
                  'error': error.error,
              },
            ),
  ];

  /// Every scenario that came back red, and every package that could not
  /// run at all, as one flat list — what a script reads instead of walking
  /// every package's every scenario to find the one that failed.
  ///
  /// Each entry names its `package` and, for a scenario, its `file`, its
  /// `scenario` and the first line of its first `error`; a package that did
  /// not run has only `package` and `error`. Derived, like [ok], and written
  /// into `run.json` beside it for the same reason.
  List<Map<String, Object?>> get failed => [
    for (var package in packages) ...[
      if (package.error case var error?)
        {'package': package.path, 'error': _firstLine(error)},
      for (var scenario in package.scenarios)
        if (!scenario.ok)
          {
            'package': package.path,
            'file': scenario.file,
            'scenario': scenario.name,
            if (scenario.errors.firstOrNull case var error?)
              'error': _firstLine(error.error),
          },
    ],
  ];

  @override
  Map<String, Object?> toJson() => {
    'version': version,
    // Derivable from the packages, and said anyway: `ok` is what a CI step
    // greps a report for, and what the action's exit code is read against.
    'ok': ok,
    // The same reasoning one level down: a red run says *which* without
    // making the reader walk the tree. Absent on a green one.
    if (!ok) 'failed': failed,
    if (axes != null) 'axes': axes,
    if (clock != null) 'clock': clock!.toIso8601String(),
    'packages': packages,
  };
}

/// One package's run: where its artifacts went, and how each scenario fared.
class ScenarioRunPackage {
  ScenarioRunPackage({
    required this.path,
    required this.output,
    this.axes,
    this.ms = 0,
    this.scenarios = const [],
    this.report,
    this.log,
    this.error,
    this.drift,
    int? passed,
    int? failed,
    int? skipped,
    int? unsettledCount,
    this.scenariosElided = 0,
    this.time = 'fake',
    this.animations,
  }) : passed = passed ?? scenarios.where((s) => s.ok && !s.skipped).length,
       failed = failed ?? scenarios.where((s) => !s.ok).length,
       skipped = skipped ?? scenarios.where((s) => s.skipped).length,
       unsettledCount =
           unsettledCount ??
           scenarios.fold(0, (sum, s) => sum + s.unsettledCount);

  factory ScenarioRunPackage.fromJson(Map<String, Object?> json) =>
      ScenarioRunPackage(
        path: json['path'] as String? ?? '',
        output: json['output'] as String? ?? '',
        axes: _stringsOrNull(json['axes']),
        ms: _int(json['ms'], 0),
        scenarios: _listOf(json['scenarios'], ScenarioRunOutcome.fromJson),
        report: json['report'] as String?,
        log: json['log'] as String?,
        error: json['error'] as String?,
        drift: switch (json['drift']) {
          Map<String, Object?> drift => ScenarioRunDrift.fromJson(drift),
          _ => null,
        },
        // Absent on a report written before they were counted, whose
        // scenarios are all present and can count themselves.
        passed: json['passed'] as int?,
        failed: json['failed'] as int?,
        skipped: json['skipped'] as int?,
        unsettledCount: json['unsettledCount'] as int?,
        scenariosElided: _int(json['scenariosElided'], 0),
        // Absent on every report from before there was a second clock.
        time: json['time'] as String? ?? 'fake',
        animations: (json['animations'] as num?)?.toDouble(),
      );

  final String path;

  /// Where this run's artifacts were written.
  final String output;

  /// The whole run, on disk, in this same shape — every step of every
  /// scenario, whatever this copy carries.
  ///
  /// Because the whole thing does not fit in an answer. A full suite across
  /// a 2×2 matrix is 160 steps and 60k tokens of paths, past anything a client
  /// hands a model, and most of it is about scenarios that passed. So the
  /// answer summarises and the file keeps everything: one read when a reader
  /// wants a step it was not given, and no read at all in the ordinary case
  /// where the answer is "20 scenarios, all green" — which is [passed], with
  /// the twenty rows left here.
  final String? report;

  /// The harness process's console, whole, on disk — engine noise, and
  /// anything printed outside a test zone. Not where a scenario's own prints
  /// or exceptions go: those ride the steps' events and the outcome's
  /// `errors`. This file is for the failure mode nothing structured has a
  /// slot for yet. One file per harness process, truncated when it starts.
  final String? log;

  /// The assignment **this** entry ran under, when the request asked for a
  /// matrix (`devices=` / `languages=`): one entry per package per point of
  /// it, each with its own [output]. Null for a single-assignment run, where
  /// [ScenarioRunResult.axes] already says it once.
  final Map<String, String>? axes;

  /// Whole-run wall time inside the harness.
  final int ms;

  /// Every scenario in `run.json`; in an action's answer, only the ones with
  /// something to say. A green scenario is counted in [passed] and left in
  /// the file, and [scenariosElided] says how many were. What stays is every
  /// red one, every skipped one, and every green one whose walk stalled —
  /// `unchangedCount` above zero, which is a pass nobody should take at its
  /// word.
  final List<ScenarioRunOutcome> scenarios;

  /// How many scenarios passed — every one of the package's, whether or not
  /// [scenarios] lists it.
  ///
  /// The answer to "did it pass", in one number. Rows for 136 green scenarios
  /// were 8k tokens of an answer whose reader wanted exactly this, reported
  /// by a consumer who had asked for the short form and got every row anyway.
  final int passed;

  /// How many came back red. Each of them is also in [scenarios], and in
  /// [ScenarioRunResult.failed].
  final int failed;

  /// How many declared `skip: true` and never ran. Not counted in [passed]:
  /// green they are not.
  final int skipped;

  /// How many steps across the whole package a settle gave up on — the sum
  /// of every scenario's [ScenarioRunOutcome.unsettledCount], including the
  /// ones [scenarios] leaves out, so folding the green rows does not fold
  /// the number away with them.
  final int unsettledCount;

  /// How many of the package's scenarios are in `run.json` rather than in
  /// this copy — zero when [scenarios] is the whole of them. The package's
  /// [ScenarioRunOutcome.stepsElided]: stated, so a short list is never read
  /// as a short run.
  final int scenariosElided;

  /// The clock this package ran on — `fake` (FakeAsync) or `real` (the wall
  /// clock, real sockets). A `real` run's pictures came off live data, which
  /// is why a comparison leaves them alone; see `compareScenarioRuns`.
  final String time;

  /// The ticker scale a `real` run applied — 0.1 by default — or null under
  /// the fake clock, where there is nothing to scale.
  final double? animations;

  bool get isRealTime => time == 'real';

  /// This package with [keep] in place of its scenarios, and its counts left
  /// as they were — they describe the run, not the copy.
  ScenarioRunPackage carrying(List<ScenarioRunOutcome> keep) =>
      ScenarioRunPackage(
        path: path,
        output: output,
        axes: axes,
        ms: ms,
        scenarios: keep,
        report: report,
        log: log,
        error: error,
        drift: drift,
        passed: passed,
        failed: failed,
        skipped: skipped,
        unsettledCount: unsettledCount,
        scenariosElided: scenariosElided + scenarios.length - keep.length,
        time: time,
        animations: animations,
      );

  /// Set when the package could not be run at all — the harness did not
  /// compile, the tester did not start — in which case [scenarios] is empty.
  final String? error;

  /// What this run recorded that the run before it did not: `compared`,
  /// `nameMatched`, the `baseline` it was compared against, and a count plus a
  /// capped list of steps under `changed`, `added` and `removed`, each saying
  /// in `what` which facets moved.
  ///
  /// A suite that is green every pass and draws different pixels every pass
  /// says so here and nowhere else — and so does one whose status bar stopped
  /// being tinted, which no screenshot of the app's own surface can show. Null
  /// when there was no run before this one to compare against, which is not
  /// the same answer as a suite that did not move.
  ///
  /// The lists are capped; `file` names the `drift.json` beside the report
  /// that holds all of them. See [compareScenarioRuns] for how two runs are
  /// paired, which is the part worth knowing before trusting a count.
  ///
  /// Not part of what the harness writes to `run.json`: a report is about the
  /// run it belongs to, and which run came before it is not a fact about that
  /// run. It has its own file — [scenarioRunDriftFile].
  final ScenarioRunDrift? drift;

  Map<String, Object?> toJson() => {
    'path': path,
    'output': output,
    if (axes != null) 'axes': axes,
    'ms': ms,
    // Only for a package that ran: one that did not has an `error` and no
    // scenarios, and `passed: 0` beside it would read as a verdict.
    if (error == null) 'passed': passed,
    if (error == null) 'failed': failed,
    if (skipped > 0) 'skipped': skipped,
    if (unsettledCount > 0) 'unsettledCount': unsettledCount,
    'scenarios': scenarios,
    if (scenariosElided > 0) 'scenariosElided': scenariosElided,
    if (report != null) 'report': report,
    if (log != null) 'log': log,
    if (error != null) 'error': error,
    if (drift != null) 'drift': drift!.toJson(),
    if (time != 'fake') 'time': time,
    if (animations != null) 'animations': animations,
  };
}

/// Every step's [ScenarioRunStep.stillTicking], once each, in step order —
/// what [ScenarioRunOutcome.stillTicking] says of a scenario.
List<String> stillTickingOf(Iterable<ScenarioRunStep> steps) =>
    {for (var step in steps) ...step.stillTicking}.toList();

/// One scenario's verdict, and the steps it captured on the way to it.
class ScenarioRunOutcome {
  factory ScenarioRunOutcome.fromJson(Map<String, Object?> json) {
    var steps = _listOf(json['steps'], ScenarioRunStep.fromJson);
    return ScenarioRunOutcome(
      file: json['file'] as String? ?? '',
      name: json['name'] as String? ?? '',
      ok: json['ok'] == true,
      skipped: json['skipped'] == true,
      skipReason: json['skipReason'] as String?,
      device: json['device'] as String?,
      ms: _int(json['ms'], 0),
      steps: steps,
      // Absent on the harness's own record, where the steps are all present
      // and the counts are theirs to state.
      stepCount: _int(json['stepCount'], steps.length),
      unchangedCount: _int(
        json['unchangedCount'],
        steps.where((step) => step.unchanged).length,
      ),
      unsettledCount: _int(
        json['unsettledCount'],
        steps.where((step) => !step.settled && step.waited).length,
      ),
      guessedCount: _int(
        json['guessedCount'],
        steps.where((step) => step.guessed != null).length,
      ),
      stillTicking: switch (json['stillTicking']) {
        List lines => [...lines.whereType<String>()],
        _ => stillTickingOf(steps),
      },
      errors: _listOf(json['errors'], ScenarioRunError.fromJson),
      translations: _translationsOrNull(json['translations']),
      stepsElided: _int(json['stepsElided'], 0),
    );
  }

  ScenarioRunOutcome({
    required this.file,
    required this.name,
    required this.ok,
    this.skipped = false,
    this.skipReason,
    this.device,
    this.ms = 0,
    this.steps = const [],
    this.stepCount = 0,
    this.unchangedCount = 0,
    this.unsettledCount = 0,
    this.guessedCount = 0,
    this.stillTicking = const [],
    this.errors = const [],
    this.translations,
    this.stepsElided = 0,
  });

  final String file;
  final String name;
  final bool ok;

  /// True when the scenario declared `skip: true` and its body never ran —
  /// the same answer `flutter test` gives the same file. [ok] is true, so a
  /// skipped scenario does not fail the run, but green it is not: zero
  /// steps, zero milliseconds, and this flag saying why.
  final bool skipped;

  /// The reason the declaration gave, when it gave one.
  final String? skipReason;

  /// The device it actually ran as. Worth saying because a run that named no
  /// device gets one per folder — whatever profile the scenario's
  /// `flutter_test_config.dart` declares — so two scenarios of the same run
  /// can differ here.
  final String? device;

  final int ms;

  /// Trimmed in an action's answer per its `steps=` mode; whole in the file
  /// `ScenarioRunPackage.report` names. Count them with [stepCount], never
  /// with this list's length.
  final List<ScenarioRunStep> steps;

  /// How many steps the scenario captured — which is [steps]`.length` unless
  /// they were left out of this copy.
  ///
  /// Carried separately so a trimmed answer cannot be read as an empty one: a
  /// green scenario whose steps went to the file on disk still says it took
  /// five pictures. See [ScenarioRunPackage.report].
  final int stepCount;

  /// How many of those steps a verb acted for nothing on — pictures
  /// byte-identical to their parent's. A green run with most of its steps
  /// here is the signature of a stalled walk: a loop tapping `Continue` on a
  /// page that never completed passes every assertion and photographs the
  /// same screen until its bound. Carried beside [stepCount] for the same
  /// reason: the summary is the copy a reader gets, and this is the number
  /// that makes a stall visible in it.
  final int unchangedCount;

  /// How many of those steps were captured with the app still animating after
  /// a policy that **waited** for it to stop — `settled: false` with
  /// `waited: true`, the settle giving up with frames still scheduled.
  ///
  /// A capture parked on purpose is not one of these. `Settle.none`,
  /// `Settle.frames` and `Settle.elapse` stop on a count or on the clock, so
  /// a frame still scheduled when they return is what the author asked to
  /// photograph — counting those makes the number a measure of how much
  /// mid-flight the suite captures rather than of anything to look at.
  ///
  /// Not a failure and not usually a surprise: a spinner does it, and the
  /// default policy exists to survive one. It is here because nothing at a
  /// *call site* distinguishes a verb that settled from one that gave up, so
  /// a suite acquires them silently and a reader has to open steps one at a
  /// time to find out. Reported by a consumer who swept a 397-call
  /// `pumpAndSettle` cleanup through 125 scenarios: the deletions that broke
  /// the suite were all at places the settle had already stopped short of,
  /// and this number is the one that would have said so before the sweep.
  /// Carried beside [unchangedCount] for the same reason it is: the summary
  /// is the copy a reader gets.
  final int unsettledCount;

  /// How many steps drew work nothing announced, found only by turning the
  /// real event loop — see [ScenarioRunStep.guessed]. Each is a picture that
  /// depended on how fast the machine was, and a comparison against another
  /// run of the same scenario on a slower one can differ there for no reason
  /// in the branch. Carried beside [unsettledCount] for the reason it is.
  final int guessedCount;

  /// What kept asking for frames on the steps counted in [unsettledCount] —
  /// every step's [ScenarioRunStep.stillTicking], once each.
  ///
  /// Carried beside the count for the reason [unsettledCount] is: the summary
  /// is the copy a reader gets, and a trimmed one has no steps to read it
  /// from.
  final List<String> stillTicking;

  /// The failure, when [ok] is false. The last captured step is the frame
  /// just before it.
  final List<ScenarioRunError> errors;

  /// Every key each catalog was asked for on the way through this scenario,
  /// and what it answered: `catalog -> key -> value`.
  ///
  /// Per scenario, and that is load-bearing. A scenario runs under one
  /// assignment, so this belongs to one locale — which is what lets the
  /// falling-back report compare a rendered string against the file that was
  /// supposed to supply it. Carried across a whole run it would hold whichever
  /// locale ran last.
  ///
  /// Wider than the steps: a key read and never rendered is here and in no
  /// step, which is the difference between "not on this screen" and "this
  /// product never asks for it".
  final Map<String, Map<String, String>>? translations;

  /// How many of [stepCount]'s steps are on disk rather than in this copy —
  /// zero when [steps] is the whole of them, which is what `run.json` and a
  /// `steps: all` request both hold.
  ///
  /// The field exists so `stepCount` and `steps.length` can never disagree
  /// silently: the difference is either zero or stated.
  final int stepsElided;

  /// This outcome with [keep] in place of its steps, and nothing else
  /// changed.
  ///
  /// Not a trim by itself: the run description passes every step back through
  /// here to re-point it at where its artifacts actually landed. [stepsElided]
  /// falls out of the arithmetic, and is zero for that caller.
  ScenarioRunOutcome carrying(List<ScenarioRunStep> keep) => ScenarioRunOutcome(
    file: file,
    name: name,
    ok: ok,
    skipped: skipped,
    skipReason: skipReason,
    device: device,
    ms: ms,
    steps: keep,
    stepCount: stepCount,
    unchangedCount: unchangedCount,
    unsettledCount: unsettledCount,
    guessedCount: guessedCount,
    stillTicking: stillTicking,
    errors: errors,
    translations: translations,
    stepsElided: stepCount - keep.length,
  );

  /// This outcome as an *answer* carries it: [keep] of its steps, and the
  /// bulk left in the `run.json` its package names.
  ///
  /// Two things stay behind, and they stay together because they are in the
  /// same file — written whole, before anything here is trimmed. The steps
  /// beyond [keep], and [translations], which is every key every catalog was
  /// asked for: bounded by the catalog rather than by the run, and on a real
  /// suite with one registered it is the largest thing in the answer by a
  /// long way. Only the translations plugin reads them, and it asks for every
  /// step, so it never comes through here.
  ///
  /// What is left says so. An outcome reading `stepCount: 27, steps: []` with
  /// nothing else to go on reads as a run that captured nothing, and an agent
  /// goes looking for a failure that is not there — reported by a consumer
  /// who read exactly that. [stepsElided] is the difference, and it is
  /// present whenever there is one.
  ScenarioRunOutcome summarised(List<ScenarioRunStep> keep) =>
      ScenarioRunOutcome(
        file: file,
        name: name,
        ok: ok,
        skipped: skipped,
        skipReason: skipReason,
        device: device,
        ms: ms,
        steps: keep,
        stepCount: stepCount,
        unchangedCount: unchangedCount,
        unsettledCount: unsettledCount,
        guessedCount: guessedCount,
        stillTicking: stillTicking,
        errors: errors,
        stepsElided: stepCount - keep.length,
      );

  /// This outcome with its steps left on disk.
  ScenarioRunOutcome withoutSteps() => summarised(const []);

  /// This outcome carrying only the frame the failure was captured at — the
  /// last one, per [errors]. The trail that led there is in the file.
  ScenarioRunOutcome withFailingStepOnly() =>
      summarised(steps.isEmpty ? const [] : [steps.last]);

  Map<String, Object?> toJson() => {
    'file': file,
    'name': name,
    'ok': ok,
    // The field itself rather than a `true` literal, here and on every flag
    // below: the shape extractor reads a hand-written literal's values, and a
    // value that names its field carries the field's type and doc into
    // `docs/capabilities.md`.
    if (skipped) 'skipped': skipped,
    if (skipReason != null) 'skipReason': skipReason,
    if (device != null) 'device': device,
    'ms': ms,
    'steps': steps,
    'stepCount': stepCount,
    'unchangedCount': unchangedCount,
    'unsettledCount': unsettledCount,
    if (guessedCount > 0) 'guessedCount': guessedCount,
    if (stillTicking.isNotEmpty) 'stillTicking': stillTicking,
    if (stepsElided > 0) 'stepsElided': stepsElided,
    if (errors.isNotEmpty) 'errors': errors,
    if (translations != null) 'translations': translations,
  };
}

/// What a step is a picture *of*.
///
/// A flow produces beats, and most of them are screens — but not all. A run
/// that exports a receipt has a moment where the receipt is the thing on
/// stage, and a run whose backend pushes a notification has a moment that is
/// the push. Those are steps like any other: named, positioned, parented,
/// carrying the events that led to them. What differs is what a viewer draws.
enum ScenarioStepKind {
  /// A rendered frame of the app — every automatic capture, and `screen()`.
  screen,

  /// Something the flow produced that is not a screen: a PDF, an email body,
  /// a payload. Bytes with a name and a type, drawn as itself. It has no
  /// frame, because there was no screen showing it.
  document,

  /// A push the flow's backend would have sent. No frame of its own either —
  /// a viewer draws it the way the recipient's phone would, as a banner over
  /// the nearest screen before it.
  notification,

  /// Work done before the flow — an account created through the API, a
  /// database seeded — captured for its duration and its exchanges, never its
  /// pixels. `s.setup(...)`.
  setup,
}

/// One captured step: what it is a picture of, its sibling legs on disk, and
/// what the app did on the way to it.
class ScenarioRunStep {
  factory ScenarioRunStep.fromJson(Map<String, Object?> json) =>
      ScenarioRunStep(
        index: _int(json['index'], 0),
        position: json['position'] as String? ?? '',
        parent: json['parent'] as int?,
        branch: json['branch'] as String?,
        name: json['name'] as String?,
        auto: json['auto'] == true,
        tags: _stringList(json['tags']),
        // Absent means `screen`, which is what every report written before
        // there was anything else to be holds — and what almost every step of
        // every report since holds too.
        kind: switch (json['kind']) {
          'document' => ScenarioStepKind.document,
          'notification' => ScenarioStepKind.notification,
          'setup' => ScenarioStepKind.setup,
          _ => ScenarioStepKind.screen,
        },
        image: json['image'] as String?,
        format: json['format'] as String?,
        width: json['width'] as int?,
        height: json['height'] as int?,
        tree: json['tree'] as String?,
        file: json['file'] as String?,
        mimeType: json['mimeType'] as String?,
        bytes: json['bytes'] as int?,
        ms: json['ms'] as int?,
        notification: switch (json['notification']) {
          Map notification => ScenarioNotification(
            body: '${notification['body'] ?? ''}',
            title: notification['title'] as String?,
            appName: notification['appName'] as String?,
          ),
          _ => null,
        },
        keys: json['keys'] as String?,
        semantics: json['semantics'] as String?,
        texts: _stringList(json['texts']),
        address: json['address'] as String? ?? '',
        statusBrightness: json['statusBrightness'] as String?,
        navBrightness: json['navBrightness'] as String?,
        verb: json['verb'] as String?,
        target: json['target'] as String?,
        aim: ScenarioAim.fromJson(json['aim']),
        events: json['events'] as String?,
        eventCount: json['eventCount'] as int?,
        eventChannels: switch (json['eventChannels']) {
          Map channels => {
            for (var entry in channels.entries)
              '${entry.key}': _int(entry.value, 0),
          },
          _ => null,
        },
        eventTitles: switch (json['eventTitles']) {
          List titles => [for (var title in titles) '$title'],
          _ => null,
        },
        eventsDropped: json['eventsDropped'] as int?,
        frames: json['frames'] as String?,
        frameCount: json['frameCount'] as int?,
        frameWidth: json['frameWidth'] as int?,
        frameHeight: json['frameHeight'] as int?,
        frameIntervalMs: json['frameIntervalMs'] as int?,
        framesDropped: json['framesDropped'] as int?,
        settled: json['settled'] as bool? ?? true,
        waited: json['waited'] as bool? ?? true,
        landed: json['landed'] as bool? ?? true,
        guessed: json['guessed'] as int?,
        stillTicking: [
          for (var line in json['stillTicking'] as List? ?? const [])
            if (line is String) line,
        ],
        digest: json['digest'] as String?,
        strayFrames: _int(json['strayFrames'], 0),
        keyboard: (json['keyboard'] as num?)?.toDouble(),
        unchanged: json['unchanged'] == true,
        failure: json['failure'] as String?,
      );

  ScenarioRunStep({
    required this.index,
    required this.position,
    required this.auto,
    this.kind = ScenarioStepKind.screen,
    this.image,
    this.format,
    this.width,
    this.height,
    this.tree,
    this.file,
    this.mimeType,
    this.bytes,
    this.notification,
    this.ms,
    this.keys,
    this.texts = const [],
    this.address = '',
    this.root = '',
    this.semantics,
    this.parent,
    this.branch,
    this.name,
    this.tags = const [],
    this.statusBrightness,
    this.navBrightness,
    this.verb,
    this.target,
    this.aim,
    this.events,
    this.eventCount,
    this.eventChannels,
    this.eventTitles,
    this.eventsDropped,
    this.frames,
    this.frameCount,
    this.frameWidth,
    this.frameHeight,
    this.frameIntervalMs,
    this.framesDropped,
    this.settled = true,
    this.waited = true,
    this.landed = true,
    this.guessed,
    this.stillTicking = const [],
    this.digest,
    this.strayFrames = 0,
    this.keyboard,
    this.unchanged = false,
    this.failure,
  });

  /// 1-based position in the scenario's capture sequence.
  final int index;

  /// Where the step sits in the scenario's *shape* — the `split` choices
  /// taken to reach it by index, then the count since the last one: `'#2'` on
  /// the trunk, `'0.1#3'` two splits deep. Unlike [index] it shifts only
  /// within its own branch when a step is inserted.
  final String position;

  /// The [index] of the step this one follows; null for the scenario's
  /// first. `split` gives one parent several children — these are the flow
  /// graph's edges.
  final int? parent;

  /// The `split` branch label when this step is a branch's first capture.
  final String? branch;

  /// The `Shot`'s name; null for an automatic capture.
  final String? name;

  /// True when nothing named this capture — a collapsible detail step.
  final bool auto;

  final List<String> tags;

  /// What this step is a picture of. See [ScenarioStepKind].
  final ScenarioStepKind kind;

  /// The captured image, in [format], **relative to the worktree root** — the
  /// same convention the catalog's artifacts follow, so the value survives
  /// being read on another machine and an agent whose tools are scoped to the
  /// repo can open it.
  ///
  /// Null on a step that is not a screen. A [ScenarioStepKind.document] has no
  /// frame at all; a [ScenarioStepKind.notification] is drawn over the nearest
  /// screen before it rather than over one of its own, so neither stores
  /// pixels and neither invents any.
  final String? image;

  /// `png`, or `raw` — bare rgba8888 rows, [width]×[height]×4 bytes. Raw is
  /// the fast capture (~5× at 1×, ~25× at device resolution) for hosts that
  /// can display pixels directly; `png` is the portable default the `run`
  /// action serves. Null wherever [image] is.
  final String? format;

  final int? width;
  final int? height;

  /// The widget-tree JSON captured at the same moment, relative like [image].
  /// Null wherever [image] is — there was no tree to read.
  final String? tree;

  /// The payload of a [ScenarioStepKind.document], **relative to the worktree
  /// root** like [image] — a path rather than the bytes, for the reason the
  /// tree and the events beside it are: a run's report stays readable, and
  /// what a reader wants to do with a document is open it.
  final String? file;

  /// What the document is, when the scenario said — `application/pdf`. A
  /// viewer switches on this; absent means "offer it as a download".
  final String? mimeType;

  /// How big [file] is, so a reader knows before opening it.
  final int? bytes;

  /// The push a [ScenarioStepKind.notification] step is.
  ///
  /// Inline rather than a file: it is three short strings, and it is typed on
  /// both ends of the wire — a viewer supplies what it leaves out (the app's
  /// own icon, the banner's "now", the brightness the run was in).
  final ScenarioNotification? notification;

  /// A `setup` beat's wall-clock duration in milliseconds; null elsewhere.
  final int? ms;

  /// The translation keys on this screen, and the words that belonged to no
  /// catalog — relative like [image]. Null when no catalog was wired up,
  /// which is every project that has not asked for this.
  ///
  /// A file rather than an inlined list, like [tree] and for the same reason:
  /// a run's response stays readable, and the export fetches it per step.
  final String? keys;

  /// The semantics-tree JSON — what a screen reader gets — relative like
  /// [image]. Null on artifacts from before the capture existed, and when the
  /// run had no semantics tree to read; a reader states the absence rather
  /// than inventing an empty screen.
  final String? semantics;

  /// The worktree the paths above are relative to, on **this** machine.
  ///
  /// On neither wire: a reader elsewhere has its own checkout, and a path
  /// naming this one is the thing being avoided. It is here so an in-process
  /// panel, which does open the files, is not handed the root separately at
  /// four call sites — and it is empty on a step parsed back out of a report,
  /// where the artifacts are beside the page rather than in a worktree.
  final String root;

  /// The visible texts — the projection an agent reads next to the pixels.
  final List<String> texts;

  /// The verb that produced this step and what it was aimed at — `tap`,
  /// `"Pay"`. Together they name the transition *into* this step, which is
  /// what the events below happened during. Null on artifacts from before the
  /// capture existed, and on a step captured at a failure.
  final String? verb;
  final String? target;

  /// Where the verb's finger went — the box it resolved, in the view's own
  /// logical pixels, measured on the frame it was about to act on. Null for a
  /// verb with nothing to point at (`wait`, `screen`, `back`), for one whose
  /// target had no box, and for every run written before this was recorded.
  ///
  /// Belongs to the step the verb *produced*, and describes the screen the
  /// step *came from* — which is the first frame of this step's own recording,
  /// banked before the verb acted. That is the picture to draw it on.
  final ScenarioAim? aim;

  /// The verb and its target as one label — `tap "Pay"` — or null where
  /// nothing acted. What an unnamed step is labelled with, in place of its
  /// index.
  String? get action {
    var did = [?verb, ?target].join(' ');
    return did.isEmpty ? null : did;
  }

  /// What the app did on the way here — logs, prints, platform channel
  /// messages, and whatever the project's fakes reported through
  /// `recordAppEvent`. Relative like [image]; null when this transition
  /// was quiet, which is distinct from a run too old to have captured any.
  final String? events;

  /// How many, and on which channels — `{platform: 3, print: 1}`. The badge on
  /// the flow's arrow, and the part of the digest that survives filtering.
  ///
  /// Null — not zero, not `{}` — on a transition where nothing happened, which
  /// is most of them: four keys saying "none" on every step of a fifty-step
  /// run is noise an agent pays for. [hasEvents] is the question worth asking.
  final int? eventCount;
  final Map<String, int>? eventChannels;

  /// The one-line summaries, capped, `system` excluded — what a reader gets
  /// without opening [events]. `POST /login → 401` is the part an agent
  /// reasons about; the payloads are what it fetches when it cares.
  ///
  /// The cap says when it bit, as a final `… N more` entry rather than by
  /// going quiet, because twelve of forty handed back silently read as an app
  /// that did twelve things. `scenarios read events: true` is where the rest
  /// live, filtered by `channel` or by `errors`.
  final List<String>? eventTitles;

  /// Events dropped to stay inside the per-step or per-run cap. Reported
  /// rather than swallowed: a truncated transition that said nothing would
  /// read as an app that did nothing.
  final int? eventsDropped;

  /// Whether anything happened on the way to this step.
  bool get hasEvents => (eventCount ?? 0) > 0;

  /// The directory of numbered frames recorded on the way to this step —
  /// what the transition *looked like*, where the events say what it did.
  /// Relative like [image]; null on every run that did not record, which is
  /// every CLI run and every run older than the capture.
  ///
  /// The frames are in [format], at [frameWidth]×[frameHeight] — their own
  /// size, not the step's: a recording runs at half scale and the shot beside
  /// it does not.
  final String? frames;
  final int? frameCount;
  final int? frameWidth;
  final int? frameHeight;

  /// Fake milliseconds between two frames — the speed a player runs at to
  /// show the animation as the app would have played it.
  final int? frameIntervalMs;

  /// Frames refused by the recorder's cap: the transition went on longer than
  /// the recording does, and the last frame is not where the app stopped.
  final int? framesDropped;

  /// Whether there is motion here to play. Two frames is the floor — one is
  /// the still the transition started from.
  bool get hasMotion => frames != null && (frameCount ?? 0) > 1;

  /// The recorded frames in order, spelled the way [image] is — so whoever
  /// reads them resolves them the same way, off a worktree's disk in the panel
  /// or over HTTP on an exported page.
  ///
  /// Built from the count rather than listed: the harness numbers them from
  /// zero and a directory listing would sort `10` before `2` unless it were
  /// re-sorted anyway — and on a page there is no directory to list.
  List<String> get framePaths => [
    if (frames case var directory?)
      for (var index = 0; index < (frameCount ?? 0); index++)
        // A path in a report — the URL spelling, which is the one that has to
        // keep working after the report crosses a machine.
        '$directory/${index.toString().padLeft(4, '0')}.$format',
  ];

  /// The events a reader will actually be shown — everything but `system`.
  ///
  /// What the flow's arrows and the tab's label count. The framework talks to
  /// `flutter/textinput` on any step with a text field, so counting the whole
  /// buffer would put "4 events" on every arrow of every flow and lead every
  /// reader to a tab filtered down to nothing. The `system` chip still carries
  /// its own count, for the reader who wants it.
  int get notableEventCount =>
      (eventCount ?? 0) - (eventChannels?['system'] ?? 0);

  /// The step's `fw://` address. Empty on the harness's own record; the host
  /// that knows the worktree fills it in via [locate].
  final String address;

  /// The `SystemUiOverlayStyle` icon brightness the app had declared at
  /// capture time (`light`/`dark`), if any — what the fake status bar and
  /// home indicator tint themselves with.
  final String? statusBrightness;
  final String? navBrightness;

  /// False when frames were still scheduled at the shutter: something on this
  /// screen was still moving, and the capture is of a moving picture. Not a
  /// failure.
  ///
  /// Read it with [waited], which says whether anything was *asked*. False
  /// here and true there is a settle that gave up. False in both is a picture
  /// parked mid-flight on purpose.
  final bool settled;

  /// Whether this step's settle policy was one that waits for the app to go
  /// quiet — `Settle.upTo` and `Settle.full`, and not `Settle.none`,
  /// `Settle.frames` or `Settle.elapse`, which stop on a count or on the
  /// clock.
  ///
  /// The wire omits the field on the `true` side, so a report written before
  /// this existed reads as every step having waited — which is what a reader
  /// of one already assumed.
  final bool waited;

  /// False when the shutter fell with an image decode or an asset read still
  /// in flight — the picture is of a screen that was still filling in, and
  /// the artwork it is missing turns up on the next step; `true` is the
  /// absence of a report rather than a claim that everything the screen
  /// wanted has arrived, and a step that is not a `screen` has nothing to
  /// land and reads `true` vacuously.
  ///
  /// Not a failure, and not the same thing as [settled] — a screen can be
  /// perfectly still and still be waiting for its illustration.
  ///
  /// Only work that *announced* itself is counted, because nothing can tell a
  /// decode that has not arrived from one that was never coming: a
  /// `FutureBuilder` on a real future is invisible to this, and a step whose
  /// landing ran out of turns to guess with says `true` as well. The wire
  /// omits the field entirely on the `true` side, which is why that is the
  /// default here.
  final bool landed;

  /// The turn of the real event loop on which work nothing announced landed
  /// and was drawn into this step — the deepest, when several did — or null
  /// when nothing had to be guessed at.
  ///
  /// The half of [landed] that *can* be stated. A decode announces itself and
  /// is waited for however long it takes; a `FutureBuilder` on a real future,
  /// an untracked read or an isolate does not, and the landing spends a dozen
  /// turns of the real loop looking for it. When one of them finds it, the
  /// picture is right — on this machine. On a slower one the same work lands
  /// on a later turn, or on none, and the step photographs what came before
  /// it. So this is a **hazard**, not a success: the fix is to hand the work
  /// to `RealWork.run` (`package:flutterware/real_work.dart`), after which it
  /// is announced, waited for, and gone from here.
  final int? guessed;

  /// What kept asking for frames when a settle that waited gave up on the way
  /// to this picture, one line each: `CircularProgressIndicator
  /// (lib/src/orders/status_cell.dart:42)` for a framework widget, by the line
  /// of the app that built it; `_PulseState.initState
  /// (package:app/src/pulse.dart:18)` for an animation the app started, by its
  /// own frame.
  ///
  /// Beside `settled: false`, which says the budget ran out; this says what to
  /// open. Empty on a settled step, on one parked on purpose, and where the
  /// harness ran without asserts and the debug stacks it reads do not exist.
  final List<String> stillTicking;

  /// What this step captured, hashed — the pixels for a screen, the payload
  /// for a document. Null where the step wrote no bytes.
  ///
  /// The whole reason it is recorded: two runs of one suite are comparable
  /// without keeping either run's images. A suite can be entirely green while
  /// a third of its screenshots move every pass — a fixture chosen by hashing
  /// a freshly-minted id, a generated id drawn on screen, a production write
  /// that reached for `DateTime.now()` instead of the injectable clock — and
  /// nothing else in this report would say so. See [compareScenarioRuns].
  ///
  /// Short and hex, and no promise about which function made it: it is
  /// compared against another digest from the same flutterware, never parsed.
  final String? digest;

  /// Frames drawn before this step that none of the scenario's verbs drew —
  /// the scenario reached for the raw `tester`, and whatever the app did in
  /// those frames is not in the flow. Zero is the healthy case.
  final int strayFrames;

  /// How tall the software keyboard was when this frame was taken, in logical
  /// pixels, or null when it was down — which is nearly every step.
  ///
  /// A note about the screen rather than a node in it. A real phone's
  /// keyboard is not in the app's widget tree either, and putting one in would
  /// mean a keyboard in every `find.text`, every semantics audit and every
  /// transcript. The only reason to record it at all is that a reader looking
  /// at a shot with the bottom third missing cannot otherwise tell why.
  final double? keyboard;

  /// True when this step's picture is byte-identical to its parent's: the
  /// verb acted and nothing on screen changed. A fact, not a verdict — a
  /// capture parked mid-flight with `Settle.none` is legitimately unchanged —
  /// but a run of these in a walking scenario is a stalled flow passing
  /// quietly, which is what the flag exists to make visible. Never set on the
  /// step a scenario failed at, nor on one that is not a screen — a document
  /// has no picture to be identical to anything.
  ///
  /// The [digest] rather than the tree, which is what this used to compare.
  /// A tree is not a projection of the picture in either direction: typed
  /// text, an animation, an image and anything painted on a canvas move the
  /// pixels without moving the dump, and a value that changed harmlessly
  /// moves the dump without moving the pixels. Measured on a consumer suite
  /// of 1240 steps, the two agreed on 22 of the 297 the tree flagged.
  final bool unchanged;

  /// The error, when this is the step a scenario broke on. The frame is the
  /// state at the failure, and the message carries the `split` branch that
  /// reached it.
  final String? failure;

  /// This step, published: its artifact paths rewritten through [path], its
  /// [address] assigned, its [root] recorded.
  ///
  /// How a host that knows the worktree turns the harness's own record —
  /// absolute paths, no address — into the one every surface reports. Lives
  /// beside the fields it copies so a new field cannot be forgotten in a
  /// parser three files away.
  ScenarioRunStep locate({
    required String root,
    required String address,
    required String Function(String) path,
  }) => ScenarioRunStep(
    index: index,
    position: position,
    parent: parent,
    branch: branch,
    name: name,
    auto: auto,
    tags: tags,
    kind: kind,
    ms: ms,
    image: switch (image) {
      var image? => path(image),
      null => null,
    },
    format: format,
    width: width,
    height: height,
    tree: switch (tree) {
      var tree? => path(tree),
      null => null,
    },
    file: switch (file) {
      var file? => path(file),
      null => null,
    },
    mimeType: mimeType,
    bytes: bytes,
    notification: notification,
    keys: switch (keys) {
      var keys? => path(keys),
      null => null,
    },
    semantics: switch (semantics) {
      var semantics? => path(semantics),
      null => null,
    },
    texts: texts,
    address: address,
    root: root,
    statusBrightness: statusBrightness,
    navBrightness: navBrightness,
    verb: verb,
    target: target,
    aim: aim,
    events: switch (events) {
      var events? => path(events),
      null => null,
    },
    eventCount: eventCount,
    eventChannels: eventChannels,
    eventTitles: eventTitles,
    eventsDropped: eventsDropped,
    frames: switch (frames) {
      var frames? => path(frames),
      null => null,
    },
    frameCount: frameCount,
    frameWidth: frameWidth,
    frameHeight: frameHeight,
    frameIntervalMs: frameIntervalMs,
    framesDropped: framesDropped,
    settled: settled,
    waited: waited,
    landed: landed,
    guessed: guessed,
    stillTicking: stillTicking,
    digest: digest,
    strayFrames: strayFrames,
    unchanged: unchanged,
    failure: failure,
    keyboard: keyboard,
  );

  Map<String, Object?> toJson() => {
    'index': index,
    'position': position,
    if (parent != null) 'parent': parent,
    if (branch != null) 'branch': branch,
    if (name != null) 'name': name,
    'auto': auto,
    if (tags.isNotEmpty) 'tags': tags,
    // Omitted for a screen, so the overwhelmingly common step's record stays
    // the size it has always been — and so a reader written before there was
    // anything but screens reads one correctly by ignoring the key.
    if (kind != ScenarioStepKind.screen) 'kind': kind.name,
    if (ms != null) 'ms': ms,
    if (image != null) 'image': image,
    if (format != null) 'format': format,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (tree != null) 'tree': tree,
    if (file != null) 'file': file,
    if (mimeType != null) 'mimeType': mimeType,
    if (bytes != null) 'bytes': bytes,
    if (notification case var notification?)
      'notification': {
        'body': notification.body,
        if (notification.title != null) 'title': notification.title,
        if (notification.appName != null) 'appName': notification.appName,
      },
    if (keys != null) 'keys': keys,
    if (semantics != null) 'semantics': semantics,
    'texts': texts,
    if (address.isNotEmpty) 'address': address,
    if (statusBrightness != null) 'statusBrightness': statusBrightness,
    if (navBrightness != null) 'navBrightness': navBrightness,
    if (verb != null) 'verb': verb,
    if (target != null) 'target': target,
    if (aim != null) 'aim': aim!.toJson(),
    if (events != null) 'events': events,
    if (eventCount != null) 'eventCount': eventCount,
    if (eventChannels != null) 'eventChannels': eventChannels,
    if (eventTitles != null) 'eventTitles': eventTitles,
    if (eventsDropped != null) 'eventsDropped': eventsDropped,
    if (frames != null) 'frames': frames,
    if (frameCount != null) 'frameCount': frameCount,
    if (frameWidth != null) 'frameWidth': frameWidth,
    if (frameHeight != null) 'frameHeight': frameHeight,
    if (frameIntervalMs != null) 'frameIntervalMs': frameIntervalMs,
    if (framesDropped != null) 'framesDropped': framesDropped,
    // All omitted in the healthy case, so a normal step's record stays the
    // size it was. Each writes its field rather than a literal so the shape
    // extractor carries the field's doc into `docs/capabilities.md`.
    if (!settled) 'settled': settled,
    if (!waited) 'waited': waited,
    if (!landed) 'landed': landed,
    if (guessed != null) 'guessed': guessed,
    if (stillTicking.isNotEmpty) 'stillTicking': stillTicking,
    if (digest != null) 'digest': digest,
    if (strayFrames > 0) 'strayFrames': strayFrames,
    if (keyboard != null) 'keyboard': keyboard,
    if (unchanged) 'unchanged': unchanged,
    if (failure != null) 'failure': failure,
  };
}

class ScenarioRunError {
  factory ScenarioRunError.fromJson(Map<String, Object?> json) =>
      ScenarioRunError(
        error: json['error'] as String? ?? '',
        stack: json['stack'] as String?,
      );

  ScenarioRunError({required this.error, this.stack});

  final String error;
  final String? stack;

  Map<String, Object?> toJson() => {
    'error': error,
    if (stack != null) 'stack': stack,
  };
}

/// A matrix run's `index.json`: one entry per point, each naming the
/// directory whose own `run.json` holds the rest.
class ScenarioRunIndex {
  ScenarioRunIndex({
    this.version = scenarioRunReportVersion,
    this.runs = const [],
  });

  /// Decodes an `index.json`.
  ///
  /// Throws [FormatException] on a version this reader does not know, like
  /// [ScenarioRunResult.fromJson] and for the same reason.
  factory ScenarioRunIndex.fromJson(Map<String, Object?> json) {
    var version = _int(json['version'], 1);
    if (version > scenarioRunReportVersion) {
      throw FormatException(
        'This run index is version $version and this is a reader for '
        '$scenarioRunReportVersion. Upgrade the flutterware dependency of '
        'whatever reads it.',
      );
    }
    return ScenarioRunIndex(
      version: version,
      runs: _listOf(json['runs'], ScenarioRunIndexEntry.fromJson),
    );
  }

  final int version;

  final List<ScenarioRunIndexEntry> runs;

  Map<String, Object?> toJson() => {'version': version, 'runs': runs};
}

/// One point of the matrix, as the index lists it.
class ScenarioRunIndexEntry {
  ScenarioRunIndexEntry({
    required this.package,
    this.axes,
    required this.output,
    required this.ok,
    this.scenarios = 0,
    this.failed = 0,
    this.skipped = 0,
    this.error,
  });

  factory ScenarioRunIndexEntry.fromJson(Map<String, Object?> json) =>
      ScenarioRunIndexEntry(
        package: json['package'] as String? ?? '',
        axes: _stringsOrNull(json['axes']),
        output: json['output'] as String? ?? '',
        ok: json['ok'] == true,
        scenarios: _int(json['scenarios'], 0),
        failed: _int(json['failed'], 0),
        skipped: _int(json['skipped'], 0),
        error: json['error'] as String?,
      );

  final String package;

  /// The assignment this point ran under — `{device: iphone-se, language: fr}`.
  final Map<String, String>? axes;

  /// This point's output directory, **relative to the index** — which is what
  /// makes the whole tree movable.
  final String output;

  final bool ok;

  /// How many scenarios ran, and how many of them came back red.
  final int scenarios;
  final int failed;

  /// How many declared `skip: true` and never ran — counted into [scenarios],
  /// not into [failed]: a skip is not a failure, and not silently green.
  final int skipped;

  /// Set when this point could not run at all.
  final String? error;

  Map<String, Object?> toJson() => {
    'package': package,
    if (axes != null) 'axes': axes,
    'output': output,
    'ok': ok,
    'scenarios': scenarios,
    'failed': failed,
    if (skipped > 0) 'skipped': skipped,
    if (error != null) 'error': error,
  };
}

int _int(Object? value, int orElse) => switch (value) {
  int value => value,
  num value => value.round(),
  _ => orElse,
};

List<String> _stringList(Object? value) => switch (value) {
  List value => [for (var entry in value) '$entry'],
  _ => const [],
};

Map<String, String>? _stringsOrNull(Object? value) => switch (value) {
  Map value => {
    for (var entry in value.entries) '${entry.key}': '${entry.value}',
  },
  _ => null,
};

Map<String, Map<String, String>>? _translationsOrNull(Object? value) =>
    switch (value) {
      Map read => {
        for (var entry in read.entries)
          '${entry.key}': switch (entry.value) {
            Map values => {
              for (var value in values.entries)
                '${value.key}': '${value.value}',
            },
            _ => <String, String>{},
          },
      },
      _ => null,
    };

List<T> _listOf<T>(Object? value, T Function(Map<String, Object?>) decode) => [
  for (var entry in value as List? ?? const [])
    if (entry is Map) decode(entry.cast<String, Object?>()),
];

/// Two runs of the same suite, compared by what their steps recorded.
///
/// A suite can be entirely green while a third of its screenshots move every
/// pass, and nothing else in a run report shows it: every scenario passes,
/// every assertion holds, and the pictures underneath differ. On a
/// real 125-scenario suite the causes were a fixture chosen by hashing a
/// freshly-minted id, generated ids drawn on screen as text, and two
/// production writes reaching for `DateTime.now()` instead of the injectable
/// clock — a day to find by eye, an afternoon with this.
///
/// It matters beyond tidiness: a comparison against a base checkout is only as
/// useful as the suite's determinism, because a suite that moves on its own
/// drowns the change that was actually asked about.
///
/// **What is compared.** The captured surface, and the facets recorded beside
/// it that the surface does not contain — see [ScenarioDriftFacet]. A status
/// bar that stopped being tinted moves no pixel of a capture that never
/// included the status bar, and a comparison that reads that as "nothing
/// moved" is worse than one that says nothing at all.
///
/// **Which steps.** A step carrying a digest in both runs. A step with no
/// digest is not compared on its other facets either, and a scenario with no
/// digested step at all is not looked at: a notification beat captured no
/// bytes, and a run written by a flutterware that predates digests carries
/// none anywhere, which answers here as two runs with nothing to compare
/// rather than as a suite that moved entirely.
///
/// **How they are paired.** By package, axis point, file, scenario, branch and
/// then — within the branch — by the `Shot`'s name. Never by
/// [ScenarioRunStep.index], which shifts under any insertion, and not by
/// [ScenarioRunStep.position] alone, which shifts under one too: its ordinal
/// counts captures since the branch began, so inserting a step renumbers every
/// step after it and the comparison reports a cascade — one changed, one added
/// and one removed per step below the cut — that says nothing about either
/// run. A name does not move when a step is inserted beside it. An unnamed
/// step is pinned to the nearest name above it plus its distance from it, so
/// an insertion disturbs only the unnamed steps between two names; one before
/// its branch's first name has nothing to hold on to and falls back to its
/// position. [ScenarioRunDrift.nameMatched] reports how much of the comparison
/// was anchored rather than guessed, which is the number that says whether the
/// rest of the report can be trusted.
///
/// Only scenarios both runs contain are looked at. One of them may have been a
/// selective run — one file, one name, one tag — and a scenario the other never
/// executed is not a scenario that moved. A scenario genuinely added or deleted
/// between the two is a change to the suite, which the suite already knows
/// about; this function is for unintended change.
///
/// [baseline] names `before` for a reader who did not choose it — the run
/// directory, worktree-relative. It defaults to the one `before` recorded for
/// itself.
ScenarioRunDrift compareScenarioRuns(
  ScenarioRunResult before,
  ScenarioRunResult after, {
  String? baseline,
}) {
  var changed = <ScenarioStepDrift>[];
  var added = <ScenarioStepDrift>[];
  var removed = <ScenarioStepDrift>[];
  var compared = 0;
  var nameMatched = 0;
  var unanchored = 0;

  var shared = _scenarios(before).intersection(_scenarios(after));
  // A run on the real clock drew its pictures off live data, so two of them
  // differ by weather. Everything the pixels do not carry — status bar tint,
  // keyboard height, whether a step settled — is still compared.
  var live =
      before.packages.any((p) => p.isRealTime) ||
      after.packages.any((p) => p.isRealTime);

  var old = <String, _Compared>{};
  for (var step in _walk(before)) {
    if (step.record != null && shared.contains(step.scenario)) {
      old[step.key] = step.record!;
    }
  }

  var seen = <String>{};
  for (var step in _walk(after)) {
    if (step.record == null || !shared.contains(step.scenario)) continue;
    seen.add(step.key);
    var was = old[step.key];
    if (was == null) {
      added.add(step.drift);
      continue;
    }
    compared++;
    if (step.pairing == _Pairing.name) nameMatched++;
    if (step.pairing == _Pairing.position) unanchored++;
    var moved = was.difference(step.record!, pixels: !live);
    if (moved.isNotEmpty) changed.add(step.drift.movedIn(moved));
  }

  for (var step in _walk(before)) {
    if (step.record != null &&
        shared.contains(step.scenario) &&
        !seen.contains(step.key)) {
      removed.add(step.drift);
    }
  }

  return ScenarioRunDrift(
    compared: compared,
    nameMatched: nameMatched,
    unanchored: unanchored,
    baseline: baseline ?? before.packages.firstOrNull?.output,
    pixelsIgnored: live,
    changed: changed,
    added: added,
    removed: removed,
  );
}

/// Every scenario a run captured *bytes* for, keyed the way two runs agree on
/// one.
///
/// Digest-carrying, and that is the whole subtlety: a run written by a
/// flutterware that predates digests carries none, and reading its scenarios
/// as present would report every step of the newer run as added. A scenario
/// with nothing to compare is a scenario neither run says anything about.
Set<String> _scenarios(ScenarioRunResult run) => {
  for (var step in _walk(run))
    if (step.record != null) step.scenario,
};

/// What one step of a run offers a comparison: which scenario it belongs to,
/// what pairs it with the other run's, how to name it, and what it recorded.
class _Walked {
  _Walked({
    required this.scenario,
    required this.key,
    required this.pairing,
    required this.drift,
    required this.record,
  });

  /// The scenario's cross-run identity.
  final String scenario;

  /// What this step is paired against in the other run.
  final String key;

  /// What [key] rests on, and so how much an edit to the suite can move it.
  final _Pairing pairing;

  final ScenarioStepDrift drift;

  /// Null for a step that captured no pixels, which is not compared at all.
  final _Compared? record;
}

/// The facets of a step two runs are compared on.
class _Compared {
  _Compared(this.step);

  final ScenarioRunStep step;

  /// Which of [ScenarioDriftFacet] disagree between this and [other], in the
  /// order the facets are declared, so two reports of the same drift read the
  /// same way.
  List<String> difference(_Compared other, {required bool pixels}) => [
    if (pixels && step.digest != other.step.digest) ScenarioDriftFacet.pixels,
    if (step.statusBrightness != other.step.statusBrightness)
      ScenarioDriftFacet.statusBrightness,
    if (step.navBrightness != other.step.navBrightness)
      ScenarioDriftFacet.navBrightness,
    if (step.keyboard != other.step.keyboard) ScenarioDriftFacet.keyboard,
    if (step.settled != other.step.settled) ScenarioDriftFacet.settled,
    if (step.landed != other.step.landed) ScenarioDriftFacet.landed,
  ];
}

/// Every step of a run, with what pairs it against the other run's.
///
/// The pairing is the delicate half — see [compareScenarioRuns] for why a
/// position alone will not do. The state here is per branch: a `split` gives
/// one parent several children, the same shot name can appear in each of them,
/// and an unnamed step counts its distance from the last name *in its own
/// branch*. A branch inherits the anchor its parent had reached, which is the
/// split point, so the first steps of a branch are pinned to the name above
/// the fork rather than falling back to a position.
Iterable<_Walked> _walk(ScenarioRunResult run) sync* {
  for (var package in run.packages) {
    var axes = package.axes == null ? null : _slug(package.axes!);
    for (var scenario in package.scenarios) {
      var id =
          '${package.path} ${axes ?? ''} ${scenario.file} ${scenario.name}';
      // Branch path → how many times each name has been seen in it, the
      // anchor it last reached, and how far past that anchor it has walked.
      var repeats = <String, Map<String, int>>{};
      var anchors = <String, String?>{};
      var since = <String, int>{};
      for (var step in scenario.steps) {
        var branch = _branch(step.position);
        if (!anchors.containsKey(branch)) {
          // Seeded from the fork, not from nothing: `'0.1'` continues where
          // `'0'` had got to, and `''` starts with nothing above it.
          var parent = _parent(branch);
          anchors[branch] = parent == null ? null : anchors[parent];
          since[branch] = parent == null ? 0 : (since[parent] ?? 0);
          repeats[branch] = {...?repeats[_parent(branch)]};
        }
        String anchor;
        _Pairing pairing;
        var name = step.name;
        if (name != null && name.isNotEmpty) {
          // Names are not unique within a scenario — a shot taken in a loop
          // has the same one every pass — so the repeat count is part of it.
          var nth = (repeats[branch]![name] ?? 0) + 1;
          repeats[branch]![name] = nth;
          anchor = '@$name#$nth';
          anchors[branch] = anchor;
          since[branch] = 0;
          pairing = _Pairing.name;
        } else if (anchors[branch] case var above?) {
          anchor = '$above+${since[branch] = since[branch]! + 1}';
          pairing = _Pairing.relative;
        } else {
          anchor = step.position;
          pairing = _Pairing.position;
        }
        yield _Walked(
          scenario: id,
          key: '$id $branch $anchor',
          pairing: pairing,
          drift: ScenarioStepDrift(
            package: package.path,
            axes: axes,
            file: scenario.file,
            scenario: scenario.name,
            position: step.position,
            name: step.name,
          ),
          record: step.digest == null ? null : _Compared(step),
        );
      }
    }
  }
}

/// What a step's pairing rests on, weakest last.
enum _Pairing {
  /// The step's own `Shot` name. Immune to an insertion anywhere.
  name,

  /// The nearest name above it, plus the distance. Moves only when a step is
  /// inserted between the two.
  relative,

  /// The raw position, for a step with no name above it at all. Moves under
  /// any insertion earlier in its branch — the cascade case.
  position,
}

/// The `split` choices half of a position — `'0.1'` of `'0.1#3'`, `''` on the
/// trunk. The stable half: inserting a step moves the ordinal after the `#`
/// and never this.
String _branch(String position) {
  var cut = position.lastIndexOf('#');
  return cut < 0 ? position : position.substring(0, cut);
}

/// The branch this one forked from, or null for the trunk.
String? _parent(String branch) {
  if (branch.isEmpty) return null;
  var cut = branch.lastIndexOf('.');
  return cut < 0 ? '' : branch.substring(0, cut);
}

/// The axis map as one comparable string, ordered so that two runs spell the
/// same point the same way.
String _slug(Map<String, String> axes) =>
    (axes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join(',');

/// The first line of an error — what a flat list of failures carries, since
/// the whole message is on the outcome it summarises.
String _firstLine(String error) => error.split('\n').first.trimRight();
