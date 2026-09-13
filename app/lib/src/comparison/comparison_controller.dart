import 'dart:async';

import 'package:flutterware/comparison_report.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'artifact.dart';
import 'cancel.dart';
import 'last_run.dart';
import 'rules.dart';
import 'runner.dart';
import 'shot_cache.dart';
import 'shot_store.dart';

/// Which half of a comparison, where both are spelled the same way.
enum ComparisonHalfKind {
  previews,
  scenarios;

  String get label => name;
}

/// Where one half of a comparison has got to.
///
/// Declared in the order a half moves through them. A run cycles
/// idle → preparing → running → done and back to running on the next Compare;
/// [refused] is the one exit, and even it is retryable.
enum HalfStage {
  /// The plugin is not declared here, so the tab does not exist.
  undeclared,

  /// Nothing is running. What the tab shows here is the last run — restored
  /// from disk or just finished and stopped — or, before any first run, the
  /// offer to make one.
  idle,

  /// Waiting on the base checkout, which both halves share.
  preparing,

  /// Rendering or replaying. Rows arrive as they are decided.
  running,

  /// Everything this half has to say.
  done,

  /// It cannot run, and the reason is worth more than a spinner.
  refused,
}

/// One half of a comparison, as a tab draws it.
class ComparisonHalf extends ChangeNotifier {
  ComparisonHalf(this.kind, {HalfStage stage = HalfStage.idle})
    // ignore: prefer_initializing_formals
    : _stage = stage;

  final ComparisonHalfKind kind;

  HalfStage _stage;
  HalfStage get stage => _stage;

  /// Why it cannot run: an SDK mismatch, a base whose harness will not build.
  String? refusal;

  /// Rows as they land, worst first. Filled while [stage] is [running], so a
  /// list has something to draw before the slowest entry is answered.
  final rows = <ComparedItem>[];

  /// The scenario half's rows, which are trees rather than entries.
  final scenarios = <ScenarioComparison>[];

  /// The ids still owed a verdict this run — what the list draws as ghost
  /// rows. Set when the plan lands, drained as each verdict arrives.
  final pending = <String>[];

  /// Every entry this run will answer, once the plan has said. The progress
  /// bar's denominator; null until the plan lands.
  int? planTotal;

  /// One sentence of what the run is doing right now. Null when nothing is.
  String? progress;

  /// When the current run started — what the elapsed counter ticks from.
  DateTime? startedAt;

  /// The receipt of the run the rows belong to: when it finished, what it was
  /// against, how long it took. Set on completion, and on restore from disk.
  LastComparison? lastRun;

  /// Records what the previous comparison found, and says so.
  ///
  /// A setter rather than a bare field, because both callers reach it *after*
  /// the notification that drew the rows: `_restore` notifies inside
  /// `restoreFrom` and then awaits this, and a run notifies on `moveTo` first.
  /// Assigned silently, the verdict rendered with no previous run to measure
  /// against and never learned otherwise — and since `newCount` distinguishes
  /// *no previous run* from *nothing new*, it went missing rather than wrong.
  void knowPrevious(Set<String>? ids) {
    previousFindingIds = ids;
    notifyListeners();
  }

  /// The finding ids the *previous* comparison reported, or null before there
  /// has ever been one.
  ///
  /// Null and empty mean different things and must not be conflated: no
  /// previous run means "new" cannot be answered, where an empty one means
  /// every finding is new. Four entries that report changed on every
  /// comparison forever are what this exists to stop shouting.
  Set<String>? previousFindingIds;

  /// What this reader has said they do not want to see.
  ///
  /// Session-scoped and deliberately not persisted: a filter that survives a
  /// restart with its chips off screen is how a reader is quietly lied to, and
  /// the chips are only guaranteed visible while the panel is. It *does*
  /// survive a re-compare, because the chips are right there and turning the
  /// noise back on between two runs is nobody's intention.
  final rules = <ComparisonRule>[];

  /// Adds the rule, or removes the one that matches it.
  void toggleRule(ComparisonRule rule) {
    var existing = rules.indexWhere((held) => held.sameAs(rule));
    if (existing >= 0) {
      rules.removeAt(existing);
    } else {
      rules.add(rule);
    }
    notifyListeners();
  }

  /// True when [rows] came off disk rather than from a run this session.
  var restored = false;

  /// True when the current rows are a run that was stopped partway.
  var stopped = false;

  /// What the run concluded, once it has.
  ComparisonResult? previewsResult;
  ScenarioResults? scenarioResults;

  bool get isRunning => _stage == HalfStage.running;

  /// Busy in any form — the states a Compare press should join, not restart.
  bool get isBusy =>
      _stage == HalfStage.preparing || _stage == HalfStage.running;

  bool get hasRun => previewsResult != null || scenarioResults != null;

  /// Findings on this half alone — a tab badge's number.
  int get findingCount =>
      rows.where((row) => row.state.isFinding).length +
      scenarios.where((scenario) => scenario.state.isFinding).length;

  void moveTo(HalfStage stage) {
    if (_stage == stage) return;
    _stage = stage;
    notifyListeners();
  }

  void refuse(String reason) {
    refusal = reason;
    progress = null;
    pending.clear();
    moveTo(HalfStage.refused);
    // moveTo returns early when the stage already matches, and a second
    // refusal with a new reason has to reach the panel.
    notifyListeners();
  }

  /// Resets everything a fresh run replaces. Silent: the stage move that
  /// follows is the notification.
  void beginRun() {
    refusal = null;
    restored = false;
    stopped = false;
    lastRun = null;
    previewsResult = null;
    scenarioResults = null;
    rows.clear();
    scenarios.clear();
    pending.clear();
    planTotal = null;
    progress = null;
    startedAt = DateTime.now();
  }

  void setProgress(String phase) {
    progress = phase;
    notifyListeners();
  }

  /// The run's shape, the moment the plan lands: [total] entries, of which
  /// [toAnswer] still owe a verdict.
  void plan(int total, List<String> toAnswer) {
    planTotal = total;
    pending
      ..clear()
      ..addAll(toAnswer);
    notifyListeners();
  }

  /// Fills the half back in from a previous session's run.
  void restoreFrom(LastComparison last) {
    lastRun = last;
    restored = true;
    rows
      ..clear()
      ..addAll(last.items ?? const [])
      ..sort(_bySeverity);
    scenarios
      ..clear()
      ..addAll(last.scenarios ?? const [])
      ..sort(_scenariosBySeverity);
    notifyListeners();
  }

  void add(ComparedItem row) {
    pending.remove(row.id);
    rows
      ..add(row)
      ..sort(_bySeverity);
    notifyListeners();
  }

  void addScenario(ScenarioComparison scenario) {
    pending.remove(scenario.scenario);
    scenarios
      ..add(scenario)
      ..sort(_scenariosBySeverity);
    notifyListeners();
  }

  static int _bySeverity(ComparedItem a, ComparedItem b) =>
      a.state.index == b.state.index
      ? a.id.compareTo(b.id)
      : a.state.index.compareTo(b.state.index);

  static int _scenariosBySeverity(ScenarioComparison a, ScenarioComparison b) =>
      a.state.index == b.state.index
      ? a.scenario.compareTo(b.scenario)
      : a.state.index.compareTo(b.state.index);
}

/// Everything a comparison needs from the world, as one seam.
///
/// A seam rather than a session, for the reason the runners already have
/// one: none of the sequencing here — when the base is prepared, what a tab
/// says before it is, what happens when a half refuses — needs a compiler, a
/// guest or a git worktree to be wrong. A fake environment makes the whole
/// controller testable in milliseconds.
abstract interface class ComparisonEnvironment {
  /// The checkout's top level, which is what both halves compare from. Not the
  /// package directory: a base checkout mirrors the whole worktree.
  String get headRoot;

  /// What is being compared against, for the header.
  String get baseLabel;

  /// The resolved base commit — what a stored run is checked against to say
  /// "the base has moved since".
  String get baseSha;

  /// Where HEAD sat when the environment was built, or null when the
  /// repository would not say. The other half of the staleness check.
  String? get headCommit;

  /// Whether the base checkout already exists resolved on disk — what lets
  /// the offer to run say "ready" or "first run checks it out" before anything
  /// is paid.
  bool get baseCheckoutReady;

  /// Materialises the base and returns its path. Called once; both halves wait
  /// on the same future. [onProgress] narrates the slow parts: the checkout,
  /// then `pub get`.
  Future<String> prepareBase({void Function(String phase)? onProgress});

  bool get hasPreviews;
  bool get hasScenarios;

  /// Where the frames a comparison rendered are filed.
  ///
  /// Exposed because a verdict is not a picture: `ComparedItem.shots` names two
  /// keys, and something has to be able to open them.
  ShotCache get shots;

  /// Where the tabs read the pictures [shots] filed — the cache, on a
  /// machine that rendered them; a recording, where nothing rendered.
  ShotStore get shotStore;

  /// The half's last finished run, if one was kept.
  Future<LastComparison?> lastRun(ComparisonHalfKind kind);

  /// The run before [lastRun]'s, for *new since you last looked*. Null when
  /// there has never been one.
  Future<LastComparison?> previousRun(ComparisonHalfKind kind);

  /// Keeps [last] as the half's answer for the next visit.
  Future<void> saveLastRun(ComparisonHalfKind kind, LastComparison last);

  Future<ComparisonResult> runPreviews(
    String baseRoot, {
    required void Function(ComparedItem row) onRow,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  });

  Future<ScenarioResults> runScenarios(
    String baseRoot, {
    required void Function(ScenarioComparison scenario) onScenario,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  });
}

/// Owns one worktree's comparison. Nothing runs on its own: building the
/// controller restores what the last run concluded, and everything past that —
/// the base checkout included — waits for [compare].
///
/// That is a reversal of the design's §13.11 ("entering a tab runs that
/// half"), and it is deliberate. The auto-run was justified by a per-tab cost
/// estimate that made the price visible before the click; the estimate was
/// built, measured at four minutes on a real catalog, and removed — leaving a
/// panel that started git checkouts, `pub get` and compilers as a side effect
/// of a tab getting focus, with a one-line spinner for company. The contract
/// is now the opposite one: the tab always *shows* for free (the last
/// run, kept on disk), and the machinery starts only when the button that
/// names it is pressed.
class ComparisonController extends ChangeNotifier {
  ComparisonController(this.environment)
    : previews = ComparisonHalf(
        ComparisonHalfKind.previews,
        stage: environment.hasPreviews ? HalfStage.idle : HalfStage.undeclared,
      ),
      scenarios = ComparisonHalf(
        ComparisonHalfKind.scenarios,
        stage: environment.hasScenarios ? HalfStage.idle : HalfStage.undeclared,
      ) {
    previews.addListener(notifyListeners);
    scenarios.addListener(notifyListeners);
    _restored = _restore();
  }

  final ComparisonEnvironment environment;

  final ComparisonHalf previews;
  final ComparisonHalf scenarios;

  /// The base checkout, once it exists.
  String? baseRoot;

  /// Why nothing can be compared at all — a base that will not check out.
  String? refusal;

  Future<void>? _preparing;
  final _cancels = <ComparisonHalfKind, CancelToken>{};
  var _disposed = false;
  late final Future<void> _restored;

  /// Restoring is loading two small JSON files; a test that wants the restored
  /// state awaits this instead of pumping.
  Future<void> get restored => _restored;

  ComparisonHalf halfFor(ComparisonHalfKind kind) =>
      kind == ComparisonHalfKind.previews ? previews : scenarios;

  /// Both halves, in tab order, skipping the ones this project does not
  /// declare. A tab that would always say "no previews here" should not exist.
  List<ComparisonHalf> get declared => [
    for (var half in [previews, scenarios])
      if (half.stage != HalfStage.undeclared) half,
  ];

  Future<void> _restore() async {
    for (var half in declared) {
      LastComparison? last;
      try {
        last = await environment.lastRun(half.kind);
      } on Object {
        last = null;
      }
      if (_disposed || last == null) continue;
      // A run that started while the file was loading owns the half now.
      if (half.stage != HalfStage.idle || half.hasRun) continue;
      half.restoreFrom(last);
      half.knowPrevious(await _previousFindings(half.kind));
    }
  }

  /// The finding ids to measure *new* against.
  ///
  /// [current] is the difference between the two callers. A restored half is
  /// showing the last run, so its predecessor is the `previous` slot. A half
  /// that has just finished is showing a run that is not on disk yet, so its
  /// predecessor is the `last` slot — the one about to be rotated.
  Future<Set<String>?> _previousFindings(
    ComparisonHalfKind kind, {
    bool current = false,
  }) async {
    LastComparison? last;
    try {
      last = current
          ? await environment.lastRun(kind)
          : await environment.previousRun(kind);
    } on Object {
      return null;
    }
    if (last == null) return null;
    return {
      for (var item in last.items ?? const <ComparedItem>[])
        if (item.state.isFinding) item.id,
      for (var scenario in last.scenarios ?? const <ScenarioComparison>[])
        if (scenario.state.isFinding) scenario.scenario,
    };
  }

  /// Materialises the base checkout. Idempotent: two halves compared one after
  /// the other share one checkout, and the second waits out the first.
  Future<void> prepare() => _preparing ??= _prepare();

  Future<void> _prepare() async {
    String root;
    try {
      root = await environment.prepareBase(
        onProgress: (phase) {
          for (var half in declared) {
            if (half.stage == HalfStage.preparing) half.setProgress(phase);
          }
        },
      );
    } on Object catch (error) {
      var reason = _firstLine(error);
      refusal = reason;
      for (var half in declared) {
        if (half.stage == HalfStage.preparing) half.refuse(reason);
      }
      notifyListeners();
      return;
    }
    if (_disposed) return;
    baseRoot = root;
  }

  /// Runs [kind], from the start, whatever it concluded before.
  ///
  /// The one way anything runs. A press while the half is busy joins the
  /// run in flight rather than restarting it; a press on a finished, restored
  /// or refused half runs it again — the button is also the refresh and the
  /// retry.
  Future<void> compare(ComparisonHalfKind kind) async {
    var half = halfFor(kind);
    if (half.stage == HalfStage.undeclared || half.isBusy) return;

    // A base that refused to check out is worth one retry per ask — the
    // commonest cause is a ref that did not exist until a fetch a moment ago.
    if (refusal != null) {
      refusal = null;
      _preparing = null;
      baseRoot = null;
    }

    var cancel = _cancels[kind] = CancelToken();
    half
      ..beginRun()
      ..progress = 'preparing the base checkout'
      ..moveTo(HalfStage.preparing);

    await prepare();
    if (_disposed) return;
    var root = baseRoot;
    if (root == null) return; // Refused; the half already says why.
    if (cancel.cancelled) {
      half
        ..stopped = true
        ..progress = null
        ..moveTo(HalfStage.idle);
      return;
    }

    half.moveTo(HalfStage.running);
    var watch = Stopwatch()..start();
    try {
      switch (kind) {
        case ComparisonHalfKind.previews:
          var result = await environment.runPreviews(
            root,
            onRow: (row) {
              if (!_disposed) half.add(row);
            },
            onPlan: (total, toAnswer) {
              if (!_disposed) half.plan(total, toAnswer);
            },
            onProgress: (phase) {
              if (!_disposed) half.setProgress(phase);
            },
            cancel: cancel,
          );
          if (_disposed) return;
          half.previewsResult = result;
          half.lastRun = LastComparison(
            at: DateTime.now(),
            baseSha: result.baseSha,
            against: environment.baseLabel,
            headCommit: environment.headCommit,
            elapsed: watch.elapsed,
            items: result.items,
            rendered: result.rendered,
          );
        case ComparisonHalfKind.scenarios:
          var results = await environment.runScenarios(
            root,
            onScenario: (scenario) {
              if (!_disposed) half.addScenario(scenario);
            },
            onPlan: (total, toAnswer) {
              if (!_disposed) half.plan(total, toAnswer);
            },
            onProgress: (phase) {
              if (!_disposed) half.setProgress(phase);
            },
            cancel: cancel,
          );
          if (_disposed) return;
          half.scenarioResults = results;
          half.lastRun = LastComparison(
            at: DateTime.now(),
            baseSha: environment.baseSha,
            against: environment.baseLabel,
            headCommit: environment.headCommit,
            elapsed: watch.elapsed,
            scenarios: results.items,
            ran: results.ran,
            note: results.note,
          );
      }
      half
        ..progress = null
        ..pending.clear()
        ..moveTo(HalfStage.done);
      if (half.lastRun case var last?) {
        // Read *before* saving, since saving rotates this run's predecessor
        // into the previous slot and would otherwise answer with the run that
        // just finished.
        half.knowPrevious(await _previousFindings(kind, current: true));
        // Best effort: a run whose receipt cannot be written is still a run.
        try {
          await environment.saveLastRun(kind, last);
        } on Object {
          // Nothing to do with it — the rows are on screen either way.
        }
      }
    } on ComparisonCancelled {
      if (_disposed) return;
      // Deliberate, so the rows collected so far stay up — partial, marked as
      // such, and not persisted: a receipt for half a run would read as the
      // whole answer on the next visit.
      half
        ..stopped = true
        ..progress = null
        ..pending.clear()
        ..moveTo(HalfStage.idle);
    } on Object catch (error) {
      if (_disposed) return;
      half.refuse(_firstLine(error));
    } finally {
      unawaited(_sweepShots());
    }
  }

  /// Trims what comparisons leave behind — see [sweepComparisonLeftovers].
  ///
  /// At the end of a run rather than the start of one: this is where the cache
  /// just grew, and a sweep that ran first would be deciding what to keep
  /// without knowing what the run was about to ask for. A cancelled or refused
  /// run gets it too — it rendered and cached whatever it reached before it
  /// stopped. Nothing waits for it: this isolate is drawing the rows.
  ///
  /// The shot cache sits directly under the root every comparison store
  /// shares, so its parent is that root.
  Future<void> _sweepShots() =>
      sweepComparisonLeftovers(p.dirname(environment.shots.root));

  /// Asks [kind]'s run to stop at its next seam. The rows it has stay up.
  void stop(ComparisonHalfKind kind) => _cancels[kind]?.cancel();

  /// Both halves as one file, once at least one of them has run.
  ComparisonArtifact? get artifact {
    var result = previews.previewsResult;
    if (result == null) return null;
    return ComparisonArtifact(
      previews: result,
      scenarios: scenarios.scenarioResults,
      caveats: comparisonCaveats(
        previews: result,
        scenarios: scenarios.scenarioResults,
      ),
    );
  }

  /// The readable part of an error, without the stack of nested prefixes.
  ///
  /// Not always one line. A daemon failure ends its first line with a colon
  /// and puts what actually went wrong on the next, so a strict first-line rule
  /// renders a sentence that stops mid-thought — which reads as a truncation
  /// bug rather than as the reason it is.
  static String _firstLine(Object error) {
    var lines = [
      for (var line in '$error'.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) return '$error';
    var first = lines.first.replaceFirst(RegExp(r'^\w+: '), '');
    if (!first.endsWith(':') || lines.length < 2) return first;
    return '$first ${lines[1]}';
  }

  @override
  void dispose() {
    _disposed = true;
    // A panel navigating away should not leave two compilers rendering for
    // nobody. The runs check the token at their next seam and unwind.
    for (var cancel in _cancels.values) {
      cancel.cancel();
    }
    previews.dispose();
    scenarios.dispose();
    super.dispose();
  }
}
