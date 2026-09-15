import 'channels.dart';
import 'scenario_comparison.dart';

/// The format `index.json` is written in.
///
/// Bumped only when a reader of the previous version would get something
/// wrong. Added fields do not bump it — an older reader ignoring a new key is
/// the behaviour that makes adding one cheap, and every field below was added
/// to a file that shipped without it.
const comparisonReportVersion = 1;

/// What a comparison writes its whole verdict to, in the cache and inside an
/// export alike.
const comparisonReportFile = 'index.json';

/// Which half a row came from.
///
/// The halves are named rather than merged because they are compared by
/// different machinery and a row from one is not interchangeable with a row
/// from the other — but the *counts* merge, because "did this branch break
/// anything" is a question about the branch.
enum ComparedHalfKind { previews, scenarios }

/// Which of a report's frames were written beside it.
///
/// An export is read where nobody has the shot cache, so every frame it wants
/// to show has to be encoded into it — and on a run where the skip rule did
/// not earn its keep, that is overwhelmingly frames of rows that came out
/// **identical**. Measured on one export 2026-09-10: 18.1MB of preview frames
/// for 220 unchanged entries, against 1.5MB for the 24 findings.
///
/// So an export can carry the findings' frames alone. The verdict is
/// untouched either way — every row is still in the file with its state and
/// its channels — and this is how a reader tells a row whose picture was left
/// out from a row that never had one. Without it the page says "neither side
/// rendered" over an entry both sides rendered perfectly well.
enum ExportedFrames {
  /// Every frame the report names.
  all,

  /// The findings' frames only — rows that are neither `same` nor `skipped`.
  findings;

  static ExportedFrames fromName(Object? name) =>
      name == 'findings' ? ExportedFrames.findings : ExportedFrames.all;
}

/// Where the frames a report names actually are.
///
/// The one thing that separates the two files both called `index.json`, and
/// the reason it is written down rather than guessed at from whether a path
/// looks absolute. A reader that guesses wrong hands back paths that do not
/// exist, which is worse than refusing.
enum ComparisonFrames {
  /// Relative to the directory holding the `index.json` — what `--export` and
  /// `--report=` write, and the only portable form: the frames beside it are
  /// PNGs, and the whole directory can be uploaded and read anywhere.
  ///
  /// Says how the frames it *did* write are named, not that it wrote one for
  /// every reference. An export encodes what the shot cache still held, and a
  /// frame evicted before it ran keeps its original reference — which is why
  /// `ComparisonReport.frame` answers with null rather than a path.
  relative,

  /// This machine only. A preview's frames are `ShotCache` keys, computed
  /// from a closure fingerprint nothing outside the runner reproduces; a
  /// scenario step's are absolute paths to headerless raw frames under
  /// `~/.flutterware`. Neither survives leaving the machine, so
  /// `ComparisonReport.frame` refuses rather than pretending.
  local,
}

/// What one half of a comparison did.
///
/// Not the writer's `ComparisonResult`/`ScenarioResults`, deliberately: those
/// exist to *conclude* a run and carry things a file cannot — the elapsed
/// stopwatch, a live item list. This holds what the file says and nothing it
/// would have to invent.
class ComparedHalf {
  const ComparedHalf({
    this.worked = 0,
    this.skipped = 0,
    this.ms = 0,
    this.counts = const {},
    this.because = const {},
    this.packages = const [],
    this.note,
  });

  /// What the half actually did, in its own unit — the previews half counts
  /// *renders* and the scenario half *replays*, up to two per row because a
  /// row has two sides and a side already in the store costs nothing. Named
  /// per half in the file (`rendered` and `replayed`) and read into one field
  /// here, because the question the two numbers answer is the same one: did
  /// the skip rule and the store earn their keep. A scenario half written
  /// before replays were filed says `ran` instead — whole scenarios, replayed
  /// on both sides.
  final int worked;

  /// Rows the skip rule answered without looking at a picture.
  final int skipped;

  final int ms;

  final Map<ComparedState, int> counts;

  /// Why the skip rule could not answer what it could not answer — one clause
  /// naming a path, and how many rows carried it.
  ///
  /// The other half of [worked]. That number says the skip rule did not earn
  /// its keep; this one says which path both checkouts disagreed about, which
  /// is the only form of the answer anybody can act on. Empty when there was
  /// nothing to explain.
  final Map<String, int> because;

  /// Which packages this half covered, worktree-relative and in the order
  /// they were compared.
  ///
  /// What lets a page say *across 3 packages* and a reader tell a comparison
  /// that covered a repository from one that covered a corner of it — a
  /// question the row ids answer only by being read in full and counted.
  /// Empty on a comparison written before one could span several.
  final List<String> packages;

  /// Why this half has nothing to say, when it has nothing to say.
  ///
  /// A harness that would not build leaves the same empty list as a project
  /// with no scenarios at all, and the same counts. This is the only thing
  /// separating them, so a reader that ignores it will read a silent half as a
  /// clean one.
  final String? note;

  static ComparedHalf fromJson(Map<String, Object?> json) {
    var counts = _counts(json['counts']);
    return ComparedHalf(
      // `rendered` is the previews half's word, `replayed` the scenario
      // half's — and `ran` what the scenario half said before it had one.
      worked:
          (json['rendered'] ?? json['replayed'] ?? json['ran']) as int? ?? 0,
      // The scenario half records this; the previews half never has, because
      // its own counts already carry it. Read from there rather than left at
      // zero, which is a number and therefore reads as an answer.
      skipped: json['skipped'] as int? ?? counts[ComparedState.skipped] ?? 0,
      ms: json['ms'] as int? ?? 0,
      counts: counts,
      because: {
        for (var entry in (json['because'] as Map? ?? const {}).entries)
          '${entry.key}': entry.value as int? ?? 0,
      },
      packages: [
        for (var package in json['packages'] as List? ?? const []) '$package',
      ],
      note: json['note'] as String?,
    );
  }
}

/// One row worth attention, with the half it came from.
///
/// A finding is a row that is neither `same` nor `skipped`. The whole row
/// travels with it rather than a summary of it: whoever is acting on a finding
/// wants its channels and its frames next, and having to go back to the two
/// lists to find them again is the step that makes a script re-implement the
/// ranking.
class ComparedFinding {
  const ComparedFinding({
    required this.id,
    required this.half,
    required this.state,
    this.note,
    this.preview,
    this.scenario,
    this.package,
  });

  /// The entry id, or the scenario id.
  final String id;

  /// Which package it came from, worktree-relative, or null on a comparison
  /// that recorded none — see [ComparedItem.package].
  final String? package;

  final ComparedHalfKind half;
  final ComparedState state;

  /// Why it is in the state it is, when the state alone does not say.
  final String? note;

  /// The previews row, when [half] is [ComparedHalfKind.previews].
  final ComparedItem? preview;

  /// The whole flow, when [half] is [ComparedHalfKind.scenarios] — its
  /// steps, its branches and its frames.
  final ScenarioComparison? scenario;
}

/// Whether [state] is worth a reader's attention.
bool isComparedFinding(ComparedState state) =>
    state != ComparedState.same && state != ComparedState.skipped;

/// Every row worth attention, worst first, both halves merged.
///
/// One ranking, however many surfaces ask for it. `ComparedState` is declared
/// worst-first, so ranking is a sort — and doing it here rather than at each
/// surface is what stops the CLI, the MCP action and a consumer's script from
/// each having their own idea of what counts and in what order.
List<ComparedFinding> rankComparedFindings({
  List<ComparedItem> previews = const [],
  List<ScenarioComparison> scenarios = const [],
}) =>
    <ComparedFinding>[
      for (var item in previews)
        if (isComparedFinding(item.state))
          ComparedFinding(
            id: item.id,
            half: ComparedHalfKind.previews,
            state: item.state,
            note: item.note,
            package: item.package,
            preview: item,
          ),
      for (var scenario in scenarios)
        if (isComparedFinding(scenario.state))
          ComparedFinding(
            id: scenario.scenario,
            half: ComparedHalfKind.scenarios,
            state: scenario.state,
            package: scenario.package,
            scenario: scenario,
          ),
    ]..sort(
      (a, b) => a.state.index == b.state.index
          ? a.id.compareTo(b.id)
          : a.state.index.compareTo(b.state.index),
    );

/// Why a comparison's verdict is incomplete, or null when it is whole.
///
/// The exit-code question, and deliberately answered in the published reader
/// rather than in `fw` alone: `fw compare` exits 1 on exactly this sentence,
/// and a consumer's script reading `index.json` — or an agent reading the
/// compare reply — has to reach the same conclusion from the same rule, not
/// re-implement it. A consumer's workflow once grew fifteen lines of guards
/// around a comparison that could not run recording itself as clean; the
/// rule exists so nobody writes those lines again. [ComparisonIndex.verdictGap]
/// asks it of a file.
///
/// Three gaps. A half that recorded a [scenariosNote] never produced a
/// verdict — its harness would not build, say — and whatever next prevents a
/// half from running is covered by the note the day it appears. A half whose
/// rows **all** came out [ComparedState.failed] is the same gap wearing a
/// different record: `failed` means neither side rendered, so a half made of
/// nothing else answered no question about the branch — and it is near-always
/// environmental, one missing native library rather than fifty-one
/// simultaneous regressions. And a half of nothing but
/// [ComparedState.wasBroken] is that gap's mirror: `wasBroken` means the base
/// alone would not render, so not one pair of pictures was ever compared —
/// and every row at once is near-always one base-side cause (a fresh base
/// checkout whose native assets did not build, a pin the base cannot run
/// under), which would otherwise read as "already broken before this branch"
/// and exit 0. The genuine mass repair exists — a branch fixing a crash in
/// `main` fixes every flow — and it pays one red check whose sentence names
/// what to look at, then clears when it merges and the base moves on; the
/// silent wrong verdict would be paid on every branch until someone noticed.
///
/// *All*, not *any*, for both: one pre-broken or one repaired flow among
/// compared ones is a half that did its job, and its row is an ordinary
/// finding. [ComparedState.broke] deliberately gets no such rule: mass
/// breakage on the *head* side is the branch's problem either way —
/// environmental or not, a dependency the branch added that will not build is
/// the branch's to fix — and a verdict full of `broke` findings is already
/// loud.
///
/// [narrowed] switches the all-one-state rules off — the note rule stands.
/// Uniformity is evidence of environment only over the whole suite; a run
/// narrowed to named entries compares the rows somebody picked, and picking
/// the one pre-broken flow would otherwise turn its ordinary finding into a
/// permanent gap no change on the branch can lift.
///
/// [inconclusiveScenarios] is how many of the scenario rows were replayed and
/// not compared — see [ScenarioComparison.inconclusive]. A half in which that
/// is every replayed scenario compared nothing, which is the same gap an
/// all-failed half is, and near-always the same kind of cause: a host that
/// could not run anything to the end.
String? verdictGapOf({
  String? scenariosNote,
  String? previewsNote,
  Iterable<ComparedState> scenarioStates = const [],
  Iterable<ComparedState> previewStates = const [],
  int inconclusiveScenarios = 0,
  bool narrowed = false,
}) {
  if (scenariosNote case var note?) {
    return 'the scenario half produced no verdict — ${note.split('\n').first}';
  }
  // The previews half records one for the same reason the scenario half does,
  // and only since a comparison could span several packages: a package whose
  // catalog will not compile used to end the whole run, which is the right
  // answer when it is the only package and the wrong one when three others
  // compared cleanly. Its rows are simply absent, and absence is what a note
  // exists to explain.
  if (previewsNote case var note?) {
    return 'the previews half produced no verdict — ${note.split('\n').first}';
  }
  if (narrowed) return null;
  if (inconclusiveScenarios > 0 &&
      !scenarioStates.any(
        (state) => state != ComparedState.skipped && !_settledUnrun(state),
      )) {
    return 'the scenario half produced no verdict — all '
        '$inconclusiveScenarios replayed scenarios were inconclusive';
  }
  return _uniformGap('scenario', 'scenarios', scenarioStates) ??
      _uniformGap('previews', 'entries', previewStates);
}

/// A state a scenario gets without being replayed: it exists on one side.
bool _settledUnrun(ComparedState state) =>
    state == ComparedState.added || state == ComparedState.removed;

/// The gap sentence for a half whose rows all carry one no-verdict state, or
/// null for one that compared anything at all — one copy of both the
/// predicates and the wording, so the two halves cannot drift apart.
String? _uniformGap(String half, String unit, Iterable<ComparedState> s) {
  var states = s.toList();
  if (states.isEmpty) return null;
  if (states.every((state) => state == ComparedState.failed)) {
    return 'the $half half produced no verdict — all '
        '${states.length} $unit failed on both sides';
  }
  if (states.every((state) => state == ComparedState.wasBroken)) {
    return 'the $half half produced no verdict — all '
        '${states.length} $unit failed on the base side alone';
  }
  return null;
}

/// A whole `index.json`, read back.
///
/// Parses either file both writers produce, and the object `fw compare --json`
/// prints, because the *verdict* is identical in all three — only the frames
/// differ, and [frames] says how. See `ComparisonReport` for opening them.
class ComparisonIndex {
  const ComparisonIndex({
    this.version = comparisonReportVersion,
    required this.base,
    required this.against,
    required this.previewItems,
    required this.scenarios,
    this.head,
    this.headCommit,
    this.at,
    this.ms = 0,
    this.counts = const {},
    this.frames = ComparisonFrames.local,
    this.exported = ExportedFrames.all,
    this.narrowed = false,
    this.caveats = const [],
    this.previewsHalf = const ComparedHalf(),
    this.scenariosHalf,
    this.export,
    this.report,
  });

  final int version;

  /// The base sha, as the artifact records it.
  final String base;

  /// What the header says the comparison is against — the ref's name where the
  /// export wrote one, the abbreviated sha where it did not.
  final String against;

  /// The worktree the comparison ran in — a **path**, and so meaningless off
  /// the machine that ran it. [headCommit] is the one a reader elsewhere can
  /// use.
  final String? head;

  /// Where HEAD sat when the comparison ran, and when it ran.
  ///
  /// What a page reached from a pull-request comment answers first: whether it
  /// still describes the branch, and whether it still describes today. Absent
  /// from a comparison written before either was recorded.
  final String? headCommit;

  final DateTime? at;

  /// Both halves together.
  final int ms;

  /// Every row either half produced, by state — the header a reader wants
  /// first. One preview that broke and one scenario that broke is two broken
  /// things; which half they came from is the second question.
  final Map<ComparedState, int> counts;

  /// Whether the frames this file names can be opened from beside it.
  final ComparisonFrames frames;

  /// Which of them were written there — see [ExportedFrames]. Always
  /// [ExportedFrames.all] for a report that was never exported, whose frames
  /// are wherever the run left them.
  final ExportedFrames exported;

  /// Whether a row in [state] is one whose frames this report chose not to
  /// carry.
  ///
  /// The question a stage has to ask before it says a side drew nothing: on a
  /// findings-only export an unchanged row has no frames beside the file and
  /// had two perfectly good ones on the machine that ran it.
  bool framesWithheldFor(ComparedState state) =>
      exported == ExportedFrames.findings && !isComparedFinding(state);

  /// Whether the run was narrowed to named entries (`--entry`).
  ///
  /// Recorded in the file so a reader applies the all-failed gap rule the way
  /// the writer did — see [verdictGapOf]. Absent means false, which is what
  /// every file written before the key existed is.
  final bool narrowed;

  /// What a reader has to know before believing the verdict, one sentence
  /// each: the ways the two sides were *measured* differently rather than
  /// drawn differently — trees read by two versions of flutterware, two
  /// pinned Flutter SDKs rendered with one.
  ///
  /// Not a gap: a verdict with caveats is still a verdict, and [ok] and
  /// [verdictGap] are unmoved by them. A gate that wants to refuse on one
  /// checks this is empty itself. Empty for a file written before the key
  /// existed.
  final List<String> caveats;

  final ComparedHalf previewsHalf;

  /// Absent when the project declares no scenarios at all. A half that tried
  /// and could not is present, with a [ComparedHalf.note].
  final ComparedHalf? scenariosHalf;

  final List<ComparedItem> previewItems;
  final List<ScenarioComparison> scenarios;

  /// The exported page's directory, when `fw compare --json` named one.
  ///
  /// Only ever on stdout — a file cannot say where a directory that contains
  /// it is. It is the bridge a script wants: parse the verdict from the pipe,
  /// then open the frames from here.
  final String? export;

  /// The pull-request report's directory, when `--json` named one.
  final String? report;

  /// Why the scenario half has nothing to say, when it has nothing to say.
  String? get scenariosNote => scenariosHalf?.note;

  /// Throws [FormatException] on a version this reader does not know: the
  /// alternative is handing back an object decoded by guesswork.
  static ComparisonIndex fromJson(Map<String, Object?> json) {
    var version = json['version'] as int? ?? 1;
    if (version > comparisonReportVersion) {
      throw FormatException(
        'This comparison is version $version and this is a reader for '
        '$comparisonReportVersion. Upgrade the flutterware dependency of '
        'whatever is reading it.',
      );
    }
    var base = json['base'] as String? ?? '';
    var previews = json['previews'] as Map<String, Object?>? ?? const {};
    var scenarios = json['scenarios'] as Map<String, Object?>?;
    return ComparisonIndex(
      version: version,
      base: base,
      against:
          json['against'] as String? ??
          (base.length > 8 ? base.substring(0, 8) : base),
      head: json['head'] as String?,
      headCommit: json['headCommit'] as String?,
      at: switch (json['at']) {
        String at => DateTime.tryParse(at),
        _ => null,
      },
      ms: json['ms'] as int? ?? 0,
      counts: _counts(json['counts']),
      // Absent means `local`: that is what every file written before this key
      // existed is, and an export is the thing that has to say so.
      frames: json['frames'] == 'relative'
          ? ComparisonFrames.relative
          : ComparisonFrames.local,
      exported: ExportedFrames.fromName(json['exported']),
      narrowed: json['narrowed'] == true,
      caveats: [
        for (var caveat in json['caveats'] as List? ?? const []) '$caveat',
      ],
      previewsHalf: ComparedHalf.fromJson(previews),
      scenariosHalf: scenarios == null
          ? null
          : ComparedHalf.fromJson(scenarios),
      previewItems: [
        for (var item in previews['items'] as List? ?? const [])
          ComparedItem.fromJson((item as Map).cast<String, Object?>()),
      ],
      scenarios: [
        for (var scenario in scenarios?['items'] as List? ?? const [])
          ScenarioComparison.fromJson(
            (scenario as Map).cast<String, Object?>(),
          ),
      ],
      export: (json['export'] as Map?)?['output'] as String?,
      report: (json['report'] as Map?)?['comment'] as String?,
    );
  }

  /// Every row worth attention, worst first, both halves merged.
  List<ComparedFinding> get findings =>
      rankComparedFindings(previews: previewItems, scenarios: scenarios);

  /// True when nothing either half looked at came out worse than `same` — the
  /// gate, in one word.
  ///
  /// A scan rather than `findings.isEmpty`: this answers a boolean, and
  /// building a ranked list of rows to throw it away is the wrong price.
  bool get ok =>
      !previewItems.any((item) => isComparedFinding(item.state)) &&
      !scenarios.any((scenario) => isComparedFinding(scenario.state));

  /// Why this comparison's verdict is incomplete, or null when it is whole —
  /// [verdictGapOf], asked of this file.
  ///
  /// The reader-side twin of the exit code: `fw compare` exits 1 exactly when
  /// this is non-null, so a job gating on the file gates on the same rule.
  /// [ok] answers a different question — whether anything got worse among what
  /// was compared — and an all-failed half makes both speak: [ok] goes false
  /// because `failed` rows are findings, and this names why none of them is a
  /// verdict about the branch.
  String? get verdictGap => verdictGapOf(
    scenariosNote: scenariosNote,
    previewsNote: previewsHalf.note,
    scenarioStates: scenarios.map((scenario) => scenario.state),
    previewStates: previewItems.map((item) => item.state),
    inconclusiveScenarios: notCompared.length,
    narrowed: narrowed,
  );

  /// The scenarios that were replayed and not compared, because a side did not
  /// produce a result — see [ScenarioComparison.inconclusive].
  ///
  /// Not findings, and not silent either: a reader is owed the list, since
  /// every one of them is a scenario whose output depended on the machine.
  List<ScenarioComparison> get notCompared => [
    for (var scenario in scenarios)
      if (!scenario.compared) scenario,
  ];

  /// Findings across both halves, worst first — the header's chips.
  ///
  /// Counted rather than built, for the same reason [ok] is scanned: the
  /// exported page reads this from inside a `build`, and [findings] allocates
  /// a row per finding and sorts them. A number does not need either.
  Map<ComparedState, int> get findingCounts {
    var counts = <ComparedState, int>{};
    for (var state in [
      for (var item in previewItems) item.state,
      for (var scenario in scenarios) scenario.state,
    ]) {
      if (isComparedFinding(state)) {
        counts[state] = (counts[state] ?? 0) + 1;
      }
    }
    return Map.fromEntries(
      counts.entries.toList()
        ..sort((a, b) => a.key.index.compareTo(b.key.index)),
    );
  }
}

Map<ComparedState, int> _counts(Object? json) {
  if (json is! Map) return const {};
  var byName = ComparedState.values.asNameMap();
  return {
    for (var entry in json.entries)
      ?byName['${entry.key}']: entry.value as int? ?? 0,
  };
}
