/// One scenario's two runs, compared — the shape `index.json` records.
///
/// The result half only. What *produces* one is a runner's business: it takes
/// two lists of live frames and a step alignment, neither of which reaches the
/// file, so both stay in `app/` beside the runner that holds them. This is
/// what a reader gets back.
library;

import 'channels.dart';
import 'frame_ref.dart';

/// A whole branch that exists on one side only.
///
/// Reported as **one** delta rather than as N added steps. A new `split`
/// branch is one decision in the source; listing its four steps as four
/// additions describes the same decision four times and buries whatever else
/// the run found.
class BranchDelta {
  const BranchDelta({
    required this.label,
    required this.added,
    required this.steps,
    required this.path,
  });

  final String label;

  /// True when the branch is on head only, false when it is on base only.
  final bool added;

  /// How many steps went with it — collapsed, not listed.
  final int steps;

  /// Where the split is, innermost last.
  final List<String> path;
}

/// One scenario's two runs, compared.
class ScenarioComparison {
  const ScenarioComparison({
    required this.scenario,
    required this.items,
    required this.branches,
    required this.state,
    this.frames = const {},
    this.package,
    this.baseErrors = const [],
    this.headErrors = const [],
  }) : inconclusive = null;

  /// A scenario that was never replayed — one that exists on a single side,
  /// or one the skip rule answered without running anything.
  ///
  /// Present in the report rather than omitted, so the list of scenarios is
  /// the list of scenarios: a row that is missing tells a reader nothing, and
  /// "skipped" tells them the tool looked and found no reason to.
  const ScenarioComparison.notRun({
    required this.scenario,
    required this.state,
    this.package,
  }) : items = const [],
       branches = const [],
       frames = const {},
       inconclusive = null,
       baseErrors = const [],
       headErrors = const [];

  /// A scenario that was replayed and did not produce a result on one side
  /// or both — see [inconclusive].
  ///
  /// [ComparedState.skipped] on the wire, deliberately rather than a state of
  /// its own. Every reader already shipped decodes a state name it does not
  /// know as `skipped`, so a new one would read as `skipped` anyway — with no
  /// sentence, in exactly the readers that most need one. And it is not a
  /// finding: a scenario that did not produce a result says nothing about the
  /// branch, so an old reader's `ok` and a new one's agree.
  const ScenarioComparison.notCompared({
    required this.scenario,
    required String this.inconclusive,
    this.package,
    this.baseErrors = const [],
    this.headErrors = const [],
  }) : state = ComparedState.skipped,
       items = const [],
       branches = const [],
       frames = const {};

  /// `<file>#<name>`.
  final String scenario;

  /// Which package declared it, worktree-relative — the twin of
  /// [ComparedItem.package], and recorded for the same reason. Its steps
  /// carry none: they take theirs from here.
  final String? package;

  /// One per step: matched pairs with their channels, plus the steps that
  /// exist on one side only.
  final List<ComparedItem> items;

  /// Branches that exist on one side only — one row each, however many steps
  /// they hold.
  final List<BranchDelta> branches;

  /// The scenario's own verdict, worst of what its steps said.
  final ComparedState state;

  /// Each step's two frames, by the id its [ComparedItem] carries.
  ///
  /// Beside the items rather than on them: a preview's `shots` are cache keys
  /// and these are paths, and one field meaning two different kinds of thing is
  /// how a reader ends up opening the wrong one.
  final Map<String, ({FrameRef? base, FrameRef? head})> frames;

  /// Why this scenario was not compared, when it was replayed and one side
  /// did not produce a result: the harness gave up on it, or its outcome did
  /// not reproduce when it was replayed again. One sentence naming the side,
  /// what happened and what to do about it.
  ///
  /// Null for every scenario that was compared, and for one that never had to
  /// be. A slow host may make a run inconclusive; it must never make it
  /// different — this is where the first half of that is written down.
  final String? inconclusive;

  /// Whether both sides produced a result and were compared. False for a
  /// scenario that was replayed and was [inconclusive].
  bool get compared => inconclusive == null;

  /// What the base side failed on, one message each, first line only — empty
  /// when it did not fail.
  ///
  /// On the scenario rather than only on its steps, because a failure is not
  /// always a step: a `setUpAll` that throws fails every scenario in its file
  /// before any of them captures anything, and a failing step that lines up
  /// with nothing on the other side has no pair to carry its note.
  final List<String> baseErrors;

  /// What the head side failed on — see [baseErrors].
  final List<String> headErrors;

  /// The same scenario, addressed inside [package] — the twin of
  /// [ComparedItem.inPackage], and the same rule.
  ScenarioComparison inPackage(String package, {required bool qualify}) {
    var id = qualify ? comparedIdIn(package, scenario) : scenario;
    if (inconclusive case var reason?) {
      return ScenarioComparison.notCompared(
        scenario: id,
        inconclusive: reason,
        package: package,
        baseErrors: baseErrors,
        headErrors: headErrors,
      );
    }
    return ScenarioComparison(
      scenario: id,
      items: items,
      branches: branches,
      state: state,
      frames: frames,
      package: package,
      baseErrors: baseErrors,
      headErrors: headErrors,
    );
  }

  Map<String, Object?> toJson() => {
    // `id` rather than `scenario`, and `steps` alongside a preview's
    // `channels`: a reader walking the whole artifact should not need to know
    // which half a row came from to find out what it is called.
    'id': scenario,
    'state': state.name,
    'package': ?package,
    'inconclusive': ?inconclusive,
    if (baseErrors.isNotEmpty || headErrors.isNotEmpty)
      'errors': {
        if (baseErrors.isNotEmpty) 'base': baseErrors,
        if (headErrors.isNotEmpty) 'head': headErrors,
      },
    if (branches.isNotEmpty)
      'branches': [
        for (var branch in branches)
          {
            'label': branch.label,
            'state': branch.added ? 'added' : 'removed',
            'steps': branch.steps,
            if (branch.path.isNotEmpty) 'path': branch.path,
          },
      ],
    'steps': [
      for (var item in items)
        {
          ...item.toJson(),
          'frames': ?(frames[item.id] == null
              ? null
              : {
                  'base': ?frames[item.id]!.base?.toJson(),
                  'head': ?frames[item.id]!.head?.toJson(),
                }),
        },
    ],
  };

  /// A scenario read back off `index.json` — the exported page's side of
  /// [toJson].
  static ScenarioComparison fromJson(Map<String, Object?> json) {
    var items = <ComparedItem>[];
    var frames = <String, ({FrameRef? base, FrameRef? head})>{};
    for (var step in json['steps'] as List? ?? const []) {
      var map = (step as Map).cast<String, Object?>();
      var item = ComparedItem.fromJson(map);
      items.add(item);
      var pair = map['frames'] as Map<String, Object?>?;
      if (pair != null) {
        frames[item.id] = (
          base: FrameRef.fromJson(
            (pair['base'] as Map?)?.cast<String, Object?>(),
          ),
          head: FrameRef.fromJson(
            (pair['head'] as Map?)?.cast<String, Object?>(),
          ),
        );
      }
    }
    var errors = json['errors'] as Map<String, Object?>? ?? const {};
    var baseErrors = [for (var e in errors['base'] as List? ?? const []) '$e'];
    var headErrors = [for (var e in errors['head'] as List? ?? const []) '$e'];
    if (json['inconclusive'] case String reason) {
      return ScenarioComparison.notCompared(
        scenario: json['id'] as String? ?? '',
        inconclusive: reason,
        package: json['package'] as String?,
        baseErrors: baseErrors,
        headErrors: headErrors,
      );
    }
    return ScenarioComparison(
      scenario: json['id'] as String? ?? '',
      baseErrors: baseErrors,
      headErrors: headErrors,
      state:
          ComparedState.values.asNameMap()[json['state']] ??
          ComparedState.skipped,
      package: json['package'] as String?,
      items: items,
      frames: frames,
      branches: [
        for (var branch in json['branches'] as List? ?? const [])
          BranchDelta(
            label: (branch as Map)['label'] as String? ?? '',
            added: branch['state'] == 'added',
            steps: branch['steps'] as int? ?? 0,
            path: (branch['path'] as List? ?? const []).cast<String>(),
          ),
      ],
    );
  }
}
