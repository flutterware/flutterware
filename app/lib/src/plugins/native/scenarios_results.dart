import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart' show InspectStyle;
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';
import 'package:json_annotation/json_annotation.dart';

// The run's own record — `run.json` and the matrix's `index.json` — is
// published API: it lives in `package:flutterware` so a consumer's script
// reads the same classes the harness writes and this GUI renders. The `src`
// path rather than `scenarios_report.dart` because that entry also exports the
// `dart:io` reader, and this file still has to compile for the exported web
// page.
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/report.dart';
// ignore: implementation_imports
export 'package:flutterware/src/scenarios/report.dart';
// The reported events themselves, for `read events: true`. Same reason as
// above for the `src` path, and this half is plain Dart either way.
// ignore: implementation_imports
import 'package:flutterware/src/app_events/events.dart';

import '../../delta/branch_delta.dart';

part 'scenarios_results.g.dart';

/// `list` — every scenario of every requested package, from the syntactic
/// scan.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioListResult implements PluginResult {
  ScenarioListResult({required this.packages});

  final List<ScenarioListPackage> packages;

  @override
  Map<String, Object?> toJson() => _$ScenarioListResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioListPackage {
  ScenarioListPackage({
    required this.path,
    required this.directory,
    this.scenarios = const [],
    this.diagnostics = const [],
    this.error,
    this.authoring,
    this.branch,
  });

  final String path;

  /// What this branch changed among [scenarios], against which base. Absent
  /// when no base resolved, nothing changed, or the delta has not been read.
  final BranchChangeSummary? branch;

  /// The scanned directory, relative to the package.
  final String directory;

  final List<ScenarioListEntry> scenarios;

  /// What the scan noticed but could not act on — non-literal names,
  /// duplicates. Empty is the healthy case.
  final List<String> diagnostics;

  /// Set when the package could not be scanned, in which case [scenarios]
  /// means nothing.
  final String? error;

  /// How to write one — present only when this package has none, which is
  /// exactly when the reader needs it and never when it would be noise. The
  /// answer to "an agent can run scenarios but cannot find out how to write
  /// one".
  final String? authoring;

  Map<String, Object?> toJson() => _$ScenarioListPackageToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioListEntry {
  ScenarioListEntry({
    required this.name,
    required this.file,
    required this.line,
    this.change,
  });

  final String name;

  /// How this branch touched the scenario — `added`, `edited` or `reached`,
  /// with a sentence — or absent when it did not. See `EntryChangeKind`.
  final EntryChange? change;

  /// Package-relative source file.
  final String file;

  final int line;

  Map<String, Object?> toJson() => _$ScenarioListEntryToJson(this);
}

/// `export` — the run, written out as a page you can serve.
///
/// Reports the run's own verdict, not the build's: the scenarios really ran to
/// produce this, and a page of red flows is still a failure worth an exit code.
/// The page exists either way — showing what broke is most of what it is for.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioWebExportResult implements PluginResult, ReportsFailure {
  ScenarioWebExportResult({
    required this.output,
    required this.indexHtml,
    required this.scenarios,
    required this.steps,
    required this.artifacts,
    required this.durationMs,
    this.failed = 0,
    required this.serve,
  });

  /// The directory to serve, worktree-relative where it sits inside one.
  final String output;

  final String indexHtml;

  final int scenarios;
  final int steps;

  /// Files copied in beside the page — screenshots, trees, semantics, events.
  final int artifacts;

  final int durationMs;

  /// Scenarios that came back red. Their flows are on the page.
  final int failed;

  /// How to look at it. A page nobody can open is a directory, and the one
  /// thing every reader of this result needs to know is that a `file://` open
  /// will not do.
  final String serve;

  @override
  bool get ok => failed == 0;

  @override
  Map<String, Object?> toJson() => _$ScenarioWebExportResultToJson(this);
}

/// `new` — a runnable scenario file written where the package keeps them.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioNewResult implements PluginResult {
  ScenarioNewResult({
    required this.package,
    required this.file,
    required this.name,
    required this.next,
  });

  final String package;

  /// The written file, package-relative — the same spelling `list` reports and
  /// `run --file=` takes, so the next call needs no translation.
  final String file;

  final String name;

  /// The command that runs what was just written. A scaffold that does not say
  /// how to run itself sends the reader back to `actions`.
  final String next;

  @override
  Map<String, Object?> toJson() => _$ScenarioNewResultToJson(this);
}

/// `restart` — the warm harness dropped, so the next run cold-starts from
/// nothing: fresh asset bundle, fresh kernel, fresh tester process.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioRestartResult implements PluginResult {
  ScenarioRestartResult({required this.restarted});

  /// The package paths whose harness was dropped.
  final List<String> restarted;

  @override
  Map<String, Object?> toJson() => _$ScenarioRestartResultToJson(this);
}

/// `shots` — the store/documentation lane: named shots only, at the device's
/// own pixel ratio, laid out by language and device.
///
/// A separate action rather than five flags on `run`, and rather than a
/// profile: store shots come from the same scenarios a `mobile` profile
/// already governs, so a `store` profile would overlap it and profiles would
/// stop partitioning. What differs is every default — native resolution, a
/// tag filter, an ordered naming scheme and its own output tree — which is
/// what an action is for.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioShotsResult implements PluginResult, ReportsFailure {
  ScenarioShotsResult({required this.packages, this.count = 0});

  final List<ScenarioShotsPackage> packages;

  /// How many images were written, over every package and assignment.
  final int count;

  /// False when a package could not run or a scenario failed: the tree is
  /// written either way, but it is missing whatever came after the failure,
  /// and `fw run scenarios shots && upload` has to stop.
  @override
  bool get ok => packages.every(
    (package) =>
        package.error == null && package.sets.every((set) => set.failed == 0),
  );

  @override
  Map<String, Object?> toJson() => _$ScenarioShotsResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioShotsPackage {
  ScenarioShotsPackage({
    required this.path,
    required this.output,
    this.sets = const [],
    this.error,
  });

  final String path;

  /// The root of the tree — `<language>/<device>/<scenario>/` beneath it.
  final String output;

  final List<ScenarioShotSet> sets;

  /// Set when the package could not be run at all.
  final String? error;

  Map<String, Object?> toJson() => _$ScenarioShotsPackageToJson(this);
}

/// One point of the matrix, and the images it produced.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioShotSet {
  ScenarioShotSet({
    required this.directory,
    this.axes = const {},
    this.images = const [],
    this.failures = const [],
  }) : failed = failures.length;

  /// Relative to `ScenarioShotsPackage.output`, so the whole tree can be
  /// moved or uploaded as it stands.
  final String directory;

  final Map<String, String> axes;

  /// Paths relative to [directory] — `<scenario>/NN-name.png` — in the order
  /// they were captured.
  ///
  /// A directory per scenario, numbered within it: a scenario's shots are in
  /// flow order, and adding one renames nothing in any other scenario. The
  /// number used to run across the whole set in file order, so one shot added
  /// early in a suite renamed every file after it, and an export's diff
  /// touched all of them. The directory is the scenario's name, slugged; two
  /// files that each have a scenario of that name get their files in front of
  /// it — `cart-happy-path/`, `checkout-happy-path/`.
  final List<String> images;

  /// Scenarios that failed while producing this set. Their shots up to the
  /// failure are still here; a store run that silently shipped a half suite
  /// would be worse than one that reports the gap.
  final int failed;

  /// Why, one entry per failed scenario — [failed] is their count.
  ///
  /// A count alone said a gap existed and nothing about it, and the run that
  /// could have said more is scratch this action deletes: a scenario that
  /// stalls spends its whole deadline at every point of the matrix, and all
  /// that reached the reader was `failed: 1`.
  final List<ScenarioShotFailure> failures;

  Map<String, Object?> toJson() => _$ScenarioShotSetToJson(this);
}

/// A scenario that came back red while its set was produced, in its own
/// words. The set it sits in is the matrix point.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioShotFailure {
  ScenarioShotFailure({
    required this.file,
    required this.scenario,
    required this.error,
    required this.rerun,
  });

  /// Package-relative, as `list` reports it.
  final String file;

  final String scenario;

  /// The first lines of what the scenario failed with — the caught error, or
  /// the failed step's message where there was none. Cut, and saying how
  /// much was cut, because a framework error dump is dozens of lines and a
  /// matrix repeats it at every point.
  final String error;

  /// The `run` that reproduces this failure at this point, with its steps
  /// and the frame it broke on kept on disk — which this action's own run is
  /// not.
  final String rerun;

  Map<String, Object?> toJson() => _$ScenarioShotFailureToJson(this);
}

/// `read` — one archived step, answered.
///
/// The other half of what a run leaves on disk. A run writes four legs per
/// step and hands back paths; this reads them and answers the same questions
/// the live surfaces answer — the screen, `find`, `at`, `styles`, the tree —
/// in the same shape, so a `find` against a scenario step and a `find` against
/// a running app differ in which file was opened and in nothing an agent has
/// to learn twice.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioReadResult implements PluginResult, ProducesArtifacts {
  ScenarioReadResult({
    required this.step,
    required this.lens,
    this.scenario,
    this.file,
    this.index,
    this.failure,
    this.image,
    this.screen,
    this.texts,
    this.tree,
    this.nodes,
    this.find,
    this.at,
    this.styles,
    this.note,
    this.next,
    this.steps = const [],
    this.picture,
    this.events,
    this.eventCount,
    this.eventChannels,
  });

  /// The capture this answers about, worktree-relative — the value to pass
  /// back as `step` to ask it something else.
  final String step;

  /// The lens the reply was produced under. Said on every reply, because a
  /// caller who does not know a picture was available cannot ask for one.
  final String lens;

  final String? scenario;
  final String? file;

  /// The step's 1-based position in its scenario's capture sequence.
  final int? index;

  /// The error this step died on, when it is a failing step. The reason most
  /// reads of an archive happen at all.
  final String? failure;

  /// The archived PNG, worktree-relative. Always named; inlined as an
  /// artifact only when a picture was asked for.
  final String? image;

  /// What is on the screen, what can be acted on, and how it is laid out.
  final Screen? screen;

  /// Every Text and text field of the step, as the capture recorded them.
  final List<String>? texts;

  /// The whole widget tree, compact. The heaviest thing here by an order of
  /// magnitude — `find`, `at` and `styles` answer most of what anyone reads a
  /// tree for, at a fiftieth of the tokens.
  final Map<String, Object?>? tree;

  /// How many nodes the tree has, whether or not it rode back.
  final int? nodes;

  /// What the app did on the way to this step, when it was asked for.
  ///
  /// The same leg-name convention `tree` follows: on a run's step it is the
  /// **path** to the file, here it is the **contents**. `system` is left out
  /// unless `channel` names it, because it is most of the volume and none of
  /// the signal — 183 of 189 events on the example suite.
  final List<AppEvent>? events;

  /// How many the step recorded, and on which channels — said whether or not
  /// [events] was asked for, because a read that does not advertise what it
  /// is sitting on cannot be drilled into by anyone who did not already know.
  ///
  /// Counts the whole capture, `system` included, exactly as `run` reports
  /// them; [events] is what a filter narrows.
  final int? eventCount;
  final Map<String, int>? eventChannels;

  final List<Map<String, Object?>>? find;
  final List<Map<String, Object?>>? at;
  final List<InspectStyle>? styles;

  /// A query that could not be answered, said so the caller can fix it. The
  /// read still happened; this is not an error.
  final String? note;

  /// One line naming what else this capture can be asked.
  final String? next;

  /// The other captures of the same scenario, as bare file names beside
  /// [step] — what makes walking a failing flow backwards one call each.
  ///
  /// Names rather than paths because they share a directory with [step] and
  /// repeating it is most of the list: measured at 137 of the 365 tokens of a
  /// default reply, for the same eighty characters five times over.
  final List<String> steps;

  /// The archived PNG as a thing to *look at*, set only when a picture was
  /// asked for. [image] names it either way; this is what makes a client that
  /// can show an image show it, and it is opt-in because a picture is ~810
  /// tokens and the screen answers most questions without one.
  @JsonKey(includeToJson: false)
  final Artifact? picture;

  @override
  @JsonKey(includeToJson: false)
  List<Artifact> get artifacts => [?picture];

  @override
  Map<String, Object?> toJson() => _$ScenarioReadResultToJson(this);
}

/// `diff` — two runs of one suite, compared.
///
/// The same comparison every `run` does against whatever ran before it, over
/// two directories a caller names instead. That is the difference worth having
/// a separate action for: a run's own drift answers "is this suite
/// deterministic *here, now*", and this answers "has it moved since the base
/// we agreed on", which is the question a CI gate asks and the one a
/// walk-backwards baseline cannot be pointed at.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ScenarioDiffResult implements PluginResult {
  ScenarioDiffResult({
    required this.before,
    required this.after,
    required ScenarioRunDrift comparison,
    int? maxSteps,
  }) : comparison = comparison,
       drift = comparison.toJson(maxSteps: maxSteps);

  /// The run compared against, worktree-relative.
  final String before;

  /// The run compared, worktree-relative.
  final String after;

  /// What moved, in the shape `run` reports under the same key — so a reader
  /// who knows one knows the other. Capped by `steps=` unless that said `all`;
  /// the counts beside each list are whole either way.
  final Map<String, Object?> drift;

  /// The same comparison, typed — for a caller inside this process rather than
  /// on the wire.
  @JsonKey(includeToJson: false)
  final ScenarioRunDrift comparison;

  @override
  Map<String, Object?> toJson() => _$ScenarioDiffResultToJson(this);
}
