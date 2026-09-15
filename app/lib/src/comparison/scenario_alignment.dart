import 'package:flutterware/comparison_report.dart';

/// One step of a scenario, as the aligner needs to see it.
///
/// Deliberately not `ScenarioRunStep`: the aligner is a pure algorithm over a
/// shape, and the shape is smaller than the artifact. Built from either side's
/// report, and from a JSON file that nobody has a session for.
class AlignableStep {
  const AlignableStep({
    required this.index,
    required this.position,
    this.parent,
    this.branch,
    this.name,
    this.verb,
    this.target,
    this.failure,
  });

  final int index;

  /// The split choices taken to reach it, then the count since the last one.
  /// The anchor a retargeted step is recognised by.
  final String position;

  final int? parent;

  /// The `split` branch label, on a branch's first step.
  final String? branch;

  final String? name;
  final String? verb;
  final String? target;

  /// What the scenario broke on at this step, when it did. Read for the
  /// [label] alone: whether a failure lines up is the signature's business,
  /// and a message is not a signature — it carries whatever the error does.
  final String? failure;

  /// What two steps are "the same step" under.
  ///
  /// The tiers are trust: an authored `Shot` name is a decision somebody made
  /// and does not move on its own; a verb and its target are derived from the
  /// line of code, so they move when the code does — which is right, since
  /// that *is* a different step; and a step with neither has only where it
  /// sits.
  String get signature => name ?? _did ?? position;

  String? get _did => switch ((verb, target)) {
    (null, _) => null,
    (var v, null) => v,
    (var v, var t) => '$v $t',
  };

  /// How it reads in a report.
  ///
  /// A failure with neither a name nor a verb is the body throwing between
  /// verbs, and it reads as what it threw. `step N` was all it used to say,
  /// and `N` counts every capture of the run — a number no reader can place.
  String get label => name ?? _did ?? _failed ?? 'step $index';

  String? get _failed {
    if (failure == null) return null;
    var line = failure!.trim().split('\n').first.trim();
    return 'failed: ${line.length > 80 ? '${line.substring(0, 79)}…' : line}';
  }
}

/// What happened to one step between two runs.
enum StepDelta {
  /// On head only.
  added,

  /// On base only.
  removed,

  /// The same step, aimed somewhere else — a renamed key, a re-worded label.
  /// Paired after the fact, by sitting in the same place under the same verb.
  retargeted,

  /// Matched, and whether anything about it changed is the channels' business
  /// rather than the aligner's.
  matched,
}

/// A base step and a head step, paired or not.
class AlignedPair {
  const AlignedPair({required this.delta, this.base, this.head, this.branch});

  final StepDelta delta;
  final AlignableStep? base;
  final AlignableStep? head;

  /// The branch this pair belongs to, innermost last — `['signed in']`.
  final List<String>? branch;

  /// The path a report addresses it by.
  String get path => [...?branch, (head ?? base)!.label].join(' › ');
}

/// Two runs of one scenario, matched up.
class ScenarioAlignment {
  const ScenarioAlignment({required this.pairs, required this.branches});

  final List<AlignedPair> pairs;
  final List<BranchDelta> branches;

  /// Aligns two step lists.
  ///
  /// A scenario is a tree, so this is a tree alignment. `split` replays the
  /// body per branch and the shared prefix is captured once, so what lands on
  /// disk is a trunk that forks. Two flows laid side by side and zipped stop
  /// being readable at the first inserted step and stop being *correct* at the
  /// first added branch.
  ///
  /// The rule is: match branches by their label, then align the linear run
  /// inside each branch by longest common subsequence. Labels are authored
  /// strings — the most stable identifier in the system — and the LCS is what
  /// makes one inserted step read as one insertion rather than as every step
  /// after it changing.
  static ScenarioAlignment of({
    required List<AlignableStep> base,
    required List<AlignableStep> head,
  }) {
    var pairs = <AlignedPair>[];
    var branches = <BranchDelta>[];
    _alignChildren(
      _childrenOf(base, null),
      _childrenOf(head, null),
      base,
      head,
      const [],
      pairs,
      branches,
    );
    return ScenarioAlignment(pairs: pairs, branches: branches);
  }

  static List<AlignableStep> _childrenOf(
    List<AlignableStep> steps,
    int? parent,
  ) => [
    for (var step in steps)
      if (step.parent == parent) step,
  ];

  static void _alignChildren(
    List<AlignableStep> base,
    List<AlignableStep> head,
    List<AlignableStep> allBase,
    List<AlignableStep> allHead,
    List<String> path,
    List<AlignedPair> pairs,
    List<BranchDelta> branches,
  ) {
    // A fork: every child of a split wears its branch label, and the label is
    // what identifies it. Matching these positionally would pair "guest" with
    // "apple pay" the moment somebody adds a branch above it.
    if (base.any((s) => s.branch != null) ||
        head.any((s) => s.branch != null)) {
      var byBase = {for (var step in base) step.branch ?? '': step};
      var byHead = {for (var step in head) step.branch ?? '': step};
      for (var label in {...byBase.keys, ...byHead.keys}) {
        var left = byBase[label];
        var right = byHead[label];
        if (left == null || right == null) {
          var only = (left ?? right)!;
          branches.add(
            BranchDelta(
              label: label,
              added: left == null,
              steps: _subtreeSize(left == null ? allHead : allBase, only),
              path: path,
            ),
          );
          continue;
        }
        _align(
          _chainFrom(left, allBase),
          _chainFrom(right, allHead),
          allBase,
          allHead,
          [...path, label],
          pairs,
          branches,
        );
      }
      return;
    }

    _align(
      _chainFrom(base.firstOrNull, allBase),
      _chainFrom(head.firstOrNull, allHead),
      allBase,
      allHead,
      path,
      pairs,
      branches,
    );
  }

  /// The straight run starting at [first]: every step until one forks or the
  /// scenario ends.
  ///
  /// A linear scenario is a chain of single-child nodes, not a list of
  /// siblings. Aligning sibling lists compares one step against one step at
  /// each level, which recognises no insertion at all — the LCS has to see the
  /// whole run at once, so the run has to be flattened first.
  static List<AlignableStep> _chainFrom(
    AlignableStep? first,
    List<AlignableStep> steps,
  ) {
    var chain = <AlignableStep>[];
    var current = first;
    while (current != null) {
      chain.add(current);
      var children = _childrenOf(steps, current.index);
      if (children.length != 1 || children.single.branch != null) break;
      current = children.single;
    }
    return chain;
  }

  static void _align(
    List<AlignableStep> base,
    List<AlignableStep> head,
    List<AlignableStep> allBase,
    List<AlignableStep> allHead,
    List<String> path,
    List<AlignedPair> pairs,
    List<BranchDelta> branches,
  ) {
    // Splits hanging off a step that matched on neither side. Collected rather
    // than reported on sight, because the two sides' orphans are very often
    // the *same* splits — see [_resolveOrphans].
    var orphans = <({String label, AlignableStep root, bool isBase})>[];
    for (var pair in _lcs(base, head)) {
      switch (pair) {
        case (var left?, var right?):
          pairs.add(
            AlignedPair(
              delta: StepDelta.matched,
              base: left,
              head: right,
              branch: path,
            ),
          );
          // Only a fork: a chain step's single child is the next link and was
          // already taken, so this cannot process anything twice.
          var below = _childrenOf(allBase, left.index);
          var above = _childrenOf(allHead, right.index);
          if (below.any((s) => s.branch != null) ||
              above.any((s) => s.branch != null)) {
            _alignChildren(
              below,
              above,
              allBase,
              allHead,
              path,
              pairs,
              branches,
            );
          }
        case (var left?, null):
          pairs.add(
            AlignedPair(delta: StepDelta.removed, base: left, branch: path),
          );
          _collectOrphans(left, allBase, isBase: true, into: orphans);
        case (null, var right?):
          pairs.add(
            AlignedPair(delta: StepDelta.added, head: right, branch: path),
          );
          _collectOrphans(right, allHead, isBase: false, into: orphans);
        case _:
          break;
      }
    }
    _resolveOrphans(orphans, allBase, allHead, path, pairs, branches);
    _retarget(pairs, path);
  }

  static void _collectOrphans(
    AlignableStep step,
    List<AlignableStep> steps, {
    required bool isBase,
    required List<({String label, AlignableStep root, bool isBase})> into,
  }) {
    for (var child in _childrenOf(steps, step.index)) {
      if (child.branch case var label?) {
        into.add((label: label, root: child, isBase: isBase));
      }
    }
  }

  /// Splits hanging off a step that exists on one side only.
  ///
  /// A branch reported as both added and removed is a branch that never
  /// moved. Rename the step above a `split` and the LCS drops its pair, so
  /// every branch under it is orphaned on *both* sides — reported once as gone
  /// and once as new, over a flow whose shape did not change at all. Matching
  /// the leftovers by label puts the two halves back together and aligns their
  /// bodies, leaving the renamed step as the one thing that is reported.
  ///
  /// What is left after that is genuine: a branch with no counterpart, which
  /// is the case this started out handling — a split whose parent was inserted
  /// would otherwise vanish from the report entirely.
  static void _resolveOrphans(
    List<({String label, AlignableStep root, bool isBase})> orphans,
    List<AlignableStep> allBase,
    List<AlignableStep> allHead,
    List<String> path,
    List<AlignedPair> pairs,
    List<BranchDelta> branches,
  ) {
    for (var label in {for (var orphan in orphans) orphan.label}) {
      var mine = [
        for (var orphan in orphans)
          if (orphan.label == label) orphan,
      ];
      var left = mine.where((o) => o.isBase).firstOrNull;
      var right = mine.where((o) => !o.isBase).firstOrNull;
      if (left != null && right != null) {
        _align(
          _chainFrom(left.root, allBase),
          _chainFrom(right.root, allHead),
          allBase,
          allHead,
          [...path, label],
          pairs,
          branches,
        );
        continue;
      }
      var only = (left ?? right)!;
      branches.add(
        BranchDelta(
          label: label,
          added: !only.isBase,
          steps: _subtreeSize(only.isBase ? allBase : allHead, only.root),
          path: path,
        ),
      );
    }
  }

  /// Pairs leftovers that sit in the same place under the same verb.
  ///
  /// Rename a key from `#pay` to `#pay_now` and the signature moves, so the
  /// step reads as removed plus added over two identical pictures. Same
  /// position, same verb, one on each side is as close to proof as this gets,
  /// and *retargeted* is a truer thing to report than a deletion and a
  /// coincidence.
  static void _retarget(List<AlignedPair> pairs, List<String> path) {
    var removed = [
      for (var pair in pairs)
        if (pair.delta == StepDelta.removed && pair.branch == path) pair,
    ];
    for (var gone in removed) {
      var match = pairs.firstWhere(
        (pair) =>
            pair.delta == StepDelta.added &&
            pair.branch == path &&
            pair.head!.position == gone.base!.position &&
            // A verb on both sides, and the same one. Two steps that merely
            // *lack* a verb share nothing but a gap, and pairing them on that
            // would turn a renamed shot into a claim about what the app did.
            gone.base!.verb != null &&
            pair.head!.verb == gone.base!.verb,
        orElse: () => const AlignedPair(delta: StepDelta.matched),
      );
      if (match.head == null) continue;
      pairs
        ..remove(gone)
        ..[pairs.indexOf(match)] = AlignedPair(
          delta: StepDelta.retargeted,
          base: gone.base,
          head: match.head,
          branch: path,
        );
    }
  }

  static int _subtreeSize(List<AlignableStep> steps, AlignableStep root) {
    var count = 1;
    var frontier = [root.index];
    while (frontier.isNotEmpty) {
      var index = frontier.removeLast();
      for (var step in steps) {
        if (step.parent == index) {
          count++;
          frontier.add(step.index);
        }
      }
    }
    return count;
  }

  /// Longest common subsequence over signatures.
  ///
  /// Not a zip, deliberately: insert one step at position three and a zip
  /// reports every step after it as changed, which is unreadable. Duplicate
  /// signatures — `tap "Next"` three times — need
  /// no special handling here, because an LCS pairs them in order.
  static List<(AlignableStep?, AlignableStep?)> _lcs(
    List<AlignableStep> base,
    List<AlignableStep> head,
  ) {
    var lengths = List.generate(
      base.length + 1,
      (_) => List.filled(head.length + 1, 0),
    );
    for (var i = base.length - 1; i >= 0; i--) {
      for (var j = head.length - 1; j >= 0; j--) {
        lengths[i][j] = base[i].signature == head[j].signature
            ? lengths[i + 1][j + 1] + 1
            : (lengths[i + 1][j] > lengths[i][j + 1]
                  ? lengths[i + 1][j]
                  : lengths[i][j + 1]);
      }
    }

    var pairs = <(AlignableStep?, AlignableStep?)>[];
    var (i, j) = (0, 0);
    while (i < base.length && j < head.length) {
      if (base[i].signature == head[j].signature) {
        pairs.add((base[i++], head[j++]));
      } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
        pairs.add((base[i++], null));
      } else {
        pairs.add((null, head[j++]));
      }
    }
    while (i < base.length) {
      pairs.add((base[i++], null));
    }
    while (j < head.length) {
      pairs.add((null, head[j++]));
    }
    return pairs;
  }
}
