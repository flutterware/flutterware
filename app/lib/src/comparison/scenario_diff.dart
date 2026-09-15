/// What *produces* a `ScenarioComparison`, as opposed to what one is.
///
/// The result travels — it is written into `index.json` and read back by
/// `package:flutterware/comparison_report.dart` — and these two do not. A
/// [ScenarioStepShot] holds live pixels and a live tree straight out of a
/// replay, and the alignment is how two runs' steps are matched up; neither
/// reaches the file, so neither is anybody's API. That is the whole reason
/// this is a separate file from the model it builds: they were one file doing
/// two jobs, and publishing the model is what made the seam visible.
library;

import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

import 'scenario_alignment.dart';

/// One step of one run, with everything a comparison reads off it.
///
/// The artifact triple plus the transition: the picture, the tree, the texts,
/// and what the app did on the way here.
class ScenarioStepShot {
  const ScenarioStepShot({
    required this.step,
    this.rgba,
    this.width = 0,
    this.height = 0,
    this.tree,
    this.treeFormat,
    this.texts = const [],
    this.events = const [],
    this.failure,
    this.frame,
  });

  final AlignableStep step;

  final Uint8List? rgba;
  final int width;
  final int height;
  final InspectNode? tree;

  /// The format [tree] was read in — see `InspectTree.format`.
  final int? treeFormat;
  final List<String> texts;
  final List<Map<String, Object?>> events;

  /// What the scenario broke on at this step, when it did.
  final String? failure;

  /// Where the harness left this step's frame.
  ///
  /// A [FrameRef] rather than a `ShotCache` key, because a scenario's frames
  /// are written by the replay rather than filed by a renderer — one run
  /// produces a whole tree of them, which is the granularity the design gives
  /// scenarios and the reason their key covers the scenario rather than the
  /// step.
  final FrameRef? frame;
}

/// What one side's replay of one scenario produced.
class ScenarioReplay {
  const ScenarioReplay(
    this.steps, {
    this.complete = true,
    this.errors = const [],
  });

  final List<ScenarioStepShot> steps;

  /// False when the harness gave up on the scenario — it blew its deadline,
  /// and what it hands back is how far it got, which is not where it would
  /// get next time. Never a result, and never filed.
  final bool complete;

  /// What the outcome says the scenario failed on, first line each.
  ///
  /// Read off the outcome rather than off its steps, because a failure is not
  /// always a step: a `setUpAll` that throws fails the scenario before it
  /// captures anything.
  final List<String> errors;

  /// Everything this replay failed on: [errors], or — for a replay whose
  /// outcome did not say, such as one filed before outcomes were read — the
  /// messages its failed steps carry.
  List<String> get failures => errors.isNotEmpty
      ? errors
      : [
          for (var shot in steps)
            if (shot.failure case var failure?) firstLineOf(failure),
        ];

  /// A result with nothing wrong in it — the only replay that is believed the
  /// first time.
  bool get clean => complete && failures.isEmpty;
}

/// The first line of a message, trimmed — what a report carries of an error.
String firstLineOf(String message) => message.trim().split('\n').first.trim();

/// One side of one scenario, once it has been replayed as often as it had to
/// be: a [replay] that is a result, or the sentence saying why there is none.
class ConfirmedSide {
  const ConfirmedSide.result(ScenarioReplay this.replay) : inconclusive = null;

  const ConfirmedSide.inconclusive(String this.inconclusive) : replay = null;

  final ScenarioReplay? replay;

  /// Why this side is not a result — see `ScenarioComparison.inconclusive`.
  final String? inconclusive;

  bool get isResult => replay != null;
}

/// Decides what one side is from its replays.
///
/// A clean replay is believed at once. Anything else was replayed a
/// [second] time — alone, because the host is the suspect and the other
/// side's tester is load — and is believed only if it did the same thing
/// again:
///
/// - a failure whose first line reproduces is a result, and can be filed;
/// - a failure that passed the second time, or failed differently, is not: its
///   outcome depends on the machine, and the scenario is what has to change;
/// - a replay the harness gave up on says nothing about the scenario's output,
///   only about its deadline, so a second replay that finished cleanly is the
///   result, and one that did not finish either is not.
///
/// [side] names the side in the sentence: "the base", "this branch".
ConfirmedSide confirmSide(
  ScenarioReplay first,
  ScenarioReplay? second, {
  required String side,
}) {
  if (first.clean) return ConfirmedSide.result(first);
  if (second == null) {
    throw ArgumentError.value(
      second,
      'second',
      'a replay that is not clean '
          'has to be replayed again before it is believed',
    );
  }
  var firstFailure = first.failures.firstOrNull;
  var secondFailure = second.failures.firstOrNull;
  if (!first.complete) {
    if (second.clean) return ConfirmedSide.result(second);
    if (!second.complete) {
      return ConfirmedSide.inconclusive(
        '$side did not finish on either of two replays'
        '${_quoted(secondFailure ?? firstFailure)}',
      );
    }
    return ConfirmedSide.inconclusive(
      '$side did not finish, then failed when replayed again'
      '${_quoted(secondFailure)}',
    );
  }
  if (!second.complete) {
    return ConfirmedSide.inconclusive(
      '$side failed, then did not finish when replayed again'
      '${_quoted(firstFailure)}',
    );
  }
  if (second.clean) {
    return ConfirmedSide.inconclusive(
      '$side failed once and passed when replayed again'
      '${_quoted(firstFailure)} Its outcome depends on the machine running '
      'it: something in the scenario is racing real time.',
    );
  }
  if (_sameFailure(firstFailure, secondFailure)) {
    return ConfirmedSide.result(second);
  }
  return ConfirmedSide.inconclusive(
    '$side failed differently on two replays'
    '${_quoted(firstFailure)} then${_quoted(secondFailure)}',
  );
}

String _quoted(String? failure) => failure == null ? '.' : ': $failure.';

/// Whether two failures are the same one. First lines, with the short hash
/// codes Flutter prints for an object (`#1a2b3`) taken out — they name an
/// instance, and two replays never share one.
bool _sameFailure(String? a, String? b) {
  String normal(String? message) =>
      (message ?? '').replaceAll(RegExp(r'#[0-9a-f]{5}\b'), '#');
  return normal(a) == normal(b);
}

/// Compares two replays that are both results — see [confirmSide].
ScenarioComparison compareScenarioReplays({
  required String scenario,
  required ScenarioReplay base,
  required ScenarioReplay head,
}) => compareScenarioSteps(
  scenario: scenario,
  base: base.steps,
  head: head.steps,
  baseErrors: base.errors,
  headErrors: head.errors,
);

/// Compares two runs of one scenario.
///
/// Pass and fail outrank every pixel. A scenario that stopped completing
/// is the most valuable thing this tool can say, and a percentage next to it
/// would be answering a smaller question — so a failure that appeared is the
/// verdict, whatever the steps before it look like.
///
/// **Whether or not the failing step lines up with anything.** It used to
/// count only on a matched pair: a failure on a step the other side never
/// took — the body throwing between verbs, a flow that broke before its next
/// screen — was an added or removed step, and those fold into `changed`.
/// That is how a base that broke read as the branch's change.
ScenarioComparison compareScenarioSteps({
  required String scenario,
  required List<ScenarioStepShot> base,
  required List<ScenarioStepShot> head,
  List<String> baseErrors = const [],
  List<String> headErrors = const [],
}) {
  var baseFailures = ScenarioReplay(base, errors: baseErrors).failures;
  var headFailures = ScenarioReplay(head, errors: headErrors).failures;
  var alignment = ScenarioAlignment.of(
    base: [for (var shot in base) shot.step],
    head: [for (var shot in head) shot.step],
  );
  var baseByIndex = {for (var shot in base) shot.step.index: shot};
  var headByIndex = {for (var shot in head) shot.step.index: shot};

  var items = <ComparedItem>[];
  var frames = <String, ({FrameRef? base, FrameRef? head})>{};
  for (var pair in alignment.pairs) {
    frames[pair.path] = (
      base: pair.base == null ? null : baseByIndex[pair.base!.index]?.frame,
      head: pair.head == null ? null : headByIndex[pair.head!.index]?.frame,
    );
    items.add(switch (pair.delta) {
      StepDelta.added => _unpaired(
        pair.path,
        pair.head!.label,
        headByIndex[pair.head!.index]?.failure,
        state: ComparedState.added,
        failed: baseFailures.isEmpty
            ? ComparedState.broke
            : ComparedState.failed,
      ),
      StepDelta.removed => _unpaired(
        pair.path,
        pair.base!.label,
        baseByIndex[pair.base!.index]?.failure,
        state: ComparedState.removed,
        failed: headFailures.isEmpty
            ? ComparedState.wasBroken
            : ComparedState.failed,
      ),
      StepDelta.matched || StepDelta.retargeted => _compare(
        pair,
        baseByIndex[pair.base!.index]!,
        headByIndex[pair.head!.index]!,
      ),
    });
  }

  return ScenarioComparison(
    scenario: scenario,
    items: items,
    branches: alignment.branches,
    state: switch ((baseFailures.isNotEmpty, headFailures.isNotEmpty)) {
      (true, true) => ComparedState.failed,
      (false, true) => ComparedState.broke,
      (true, false) => ComparedState.wasBroken,
      (false, false) => _verdict(items, alignment),
    },
    frames: frames,
    baseErrors: baseFailures,
    headErrors: headFailures,
  );
}

/// A step on one side only. A failed one is the failure first and the
/// missing counterpart second, and carries its message.
ComparedItem _unpaired(
  String id,
  String label,
  String? failure, {
  required ComparedState state,
  required ComparedState failed,
}) => ComparedItem(
  id: id,
  state: failure == null ? state : failed,
  label: label,
  note: failure,
);

ComparedItem _compare(
  AlignedPair pair,
  ScenarioStepShot base,
  ScenarioStepShot head,
) {
  // A step that broke is not a step that looks different: the picture is
  // whatever was on screen when it threw, and comparing it against a working
  // one measures the wrong thing.
  if (base.failure != null || head.failure != null) {
    return ComparedItem.of(
      id: pair.path,
      label: pair.head!.label,
      baseRendered: base.failure == null,
      headRendered: head.failure == null,
      note: _failureNote(base.failure, head.failure),
    );
  }
  var item = ComparedItem.of(
    id: pair.path,
    label: pair.head!.label,
    pixels: base.rgba == null || head.rgba == null
        ? null
        : PixelDiff.of(
            base: base.rgba!,
            baseWidth: base.width,
            baseHeight: base.height,
            head: head.rgba!,
            headWidth: head.width,
            headHeight: head.height,
          ),
    tree: TreeDiff.of(base.tree, head.tree),
    treeSkewed: base.treeFormat != head.treeFormat,
    baseTexts: base.texts,
    headTexts: head.texts,
    baseEvents: base.events,
    headEvents: head.events,
  );
  // A retarget is a change whatever the channels found: the same step now
  // names something else, and two identical pictures are the *reason* it is
  // worth saying rather than a reason to stay quiet.
  if (pair.delta == StepDelta.retargeted && item.state == ComparedState.same) {
    return ComparedItem(
      id: item.id,
      state: ComparedState.changed,
      label: item.label,
      pixels: item.pixels,
      tree: item.tree,
      // Named *and* explained: "retargeted" is this model's word, not a
      // word a reader arrives with, and the whole point of the note is that
      // two identical pictures still deserve a sentence.
      note:
          'retargeted — same step, but it aimed at something else: '
          '${pair.base!.target} → ${pair.head!.target}',
    );
  }
  return item;
}

/// One note for a matched pair that failed: both messages when both sides
/// failed differently, since "head's message" alone hid what the base broke
/// on.
String? _failureNote(String? base, String? head) {
  if (base == null || head == null || firstLineOf(base) == firstLineOf(head)) {
    return head ?? base;
  }
  return 'head: ${firstLineOf(head)}\nbase: ${firstLineOf(base)}';
}

ComparedState _verdict(List<ComparedItem> items, ScenarioAlignment alignment) {
  var worst = ComparedState.skipped;
  for (var item in items) {
    if (item.state.index < worst.index) worst = item.state;
  }
  if (alignment.branches.isNotEmpty &&
      worst.index > ComparedState.changed.index) {
    // A branch appearing or disappearing is a change to the flow even when
    // every step it shares with the other side is identical.
    return ComparedState.changed;
  }
  // A step that appeared is a scenario that *changed*. Carrying the step's
  // own word up would say this flow is new when only a line inside it is —
  // and `added` outranks `changed`, so a gained step sorted a scenario above
  // one that genuinely broke nothing but looks different.
  return switch (worst) {
    ComparedState.added || ComparedState.removed => ComparedState.changed,
    _ => worst,
  };
}
