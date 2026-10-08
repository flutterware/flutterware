import 'package:flutterware/plugins.dart';

import '../worktrees/facts.dart';

/// Everything removing a worktree would do, assembled and not yet done.
///
/// Pure data, and no Flutter in this file. The dialog is one renderer; `fw`
/// printing the same checklist before removing a checkout from a script is the
/// other, and neither should be able to see a step the other cannot.
///
/// Two sources feed it, and the difference is the reason this class exists
/// rather than the dialog reading `session.teardownSteps` directly:
///
/// - **Plugins** contribute steps and guards through their reports. They know
///   about stacks and running apps; they need a session, so they are only there
///   for a worktree that is open.
/// - **The shell** contributes guards from [WorktreeFacts] — uncommitted work,
///   an agent mid-task, the primary checkout. These never run project code, so
///   they are there whether or not anything is open, which is what makes a
///   checklist for a closed worktree honest rather than empty.
class TeardownPlan {
  const TeardownPlan({
    required this.worktree,
    required this.path,
    this.branch,
    this.guards = const [],
    this.steps = const [],
    this.sessionOpen = true,
    this.uncommittedFiles = 0,
  });

  /// Git's own name for the worktree — what an address and a tab call it.
  final String worktree;

  final String path;

  /// The branch checked out here, or null when detached. Removing the worktree
  /// leaves it behind, which is why deleting it is a separate step.
  final String? branch;

  /// Every objection, shell's and plugins', worst first.
  final List<Guard> guards;

  /// Every step, in the order they will run, each knowing which plugin emitted
  /// it.
  final List<PlannedStep> steps;

  /// False when the plan was built without a session, so plugin steps and
  /// guards are missing. The dialog states that rather than implying the
  /// checkout is clean.
  final bool sessionOpen;

  /// How much uncommitted work goes with the checkout, from the last git probe.
  ///
  /// Drives two things that have to agree: the warning the user reads, and
  /// whether `git worktree remove` is given `--force`. Deriving both from one
  /// number is what stops the dialog from warning about files it then fails to
  /// delete.
  final int uncommittedFiles;

  /// True when removing this checkout destroys uncommitted work.
  bool get destroysUncommittedWork => uncommittedFiles > 0;

  /// Nothing may proceed. The primary checkout, or uncommitted work.
  bool get isBlocked => guards.any((guard) => guard.level == GuardLevel.block);

  List<Guard> get blockers => [
    for (var guard in guards)
      if (guard.level == GuardLevel.block) guard,
  ];

  List<Guard> get warnings => [
    for (var guard in guards)
      if (guard.level == GuardLevel.warn) guard,
  ];

  /// The steps that would run if nothing were unticked.
  List<PlannedStep> get defaultSelection => [
    for (var planned in steps)
      if (planned.step.enabled && planned.step.checked) planned,
  ];

  /// Assembles a plan.
  ///
  /// [reports] is empty for a worktree nobody has opened; pass
  /// `sessionOpen: false` with it so the renderer can say which half is
  /// missing.
  ///
  /// Steps are sorted by phase and otherwise left in the order the plugins
  /// declared them, because that order is the project's own — the config file
  /// decides which plugin speaks first, here as everywhere else. Sorting is
  /// stable for exactly that reason.
  static TeardownPlan build({
    required String worktree,
    required String path,
    String? branch,
    bool isMain = false,
    WorktreeFacts facts = const WorktreeFacts(),
    List<PluginReport> reports = const [],
    bool sessionOpen = true,
  }) {
    // **The plugin id is captured here, not looked up later.** `report` is a
    // computed getter — every plugin builds fresh `TeardownStep` objects on
    // each call — so a runner that tried to find a step's owner by scanning the
    // reports again would be comparing objects that cannot match. Recording it
    // at assembly time is the only thing that survives the report being rebuilt
    // between drawing the checklist and running it, which is exactly what
    // happens while the dialog is open and a poll ticks.
    var steps = [
      for (var report in reports)
        for (var step in report.teardown)
          PlannedStep(pluginId: report.id, step: step),
    ]..sort((a, b) => a.step.phase.index.compareTo(b.step.phase.index));

    return TeardownPlan(
      worktree: worktree,
      path: path,
      branch: branch,
      sessionOpen: sessionOpen,
      uncommittedFiles: facts.git.value?.dirty ?? 0,
      guards: [
        ...shellGuards(isMain: isMain, facts: facts),
        for (var report in reports) ...report.guards,
        // Blocks first, and sorted on what they *mean* rather than on
        // `GuardLevel`'s declaration order — which puts `warn` first, and is
        // not a promise the enum makes.
      ]..sort((a, b) => _rank(a).compareTo(_rank(b))),
      steps: steps,
    );
  }

  /// The objections the shell raises on its own behalf.
  ///
  /// Only one thing blocks, and it is the one nothing can be done about.
  ///
  /// - **The primary checkout blocks**, because `Worktree.isMain` says it
  ///   "cannot be removed, so teardown must never offer to". Git will not do it
  ///   either; this is not a policy, it is the shape of a repository.
  /// - **Uncommitted files warn**, and the removal is forced past them.
  /// - **Unpushed commits warn.** Recoverable — the commits survive in the
  ///   repository once the checkout is gone.
  /// - **A working agent warns**, per the plugin design's own example: it is
  ///   mid-task, and you may know better.
  ///
  /// Uncommitted work was a block in the first version, on the reasoning that
  /// nothing should destroy work no reflog can return. That was
  /// wrong about what this tool is *for*. The worktrees people need to remove
  /// are the abandoned ones, and an abandoned checkout has junk in it almost by
  /// definition — so a block on dirty files refuses precisely the case the
  /// screen exists to clean up, and the tool goes unused while the stale
  /// worktrees pile up.
  ///
  /// A refusal you route around by opening a terminal is not a safeguard; it is
  /// friction that teaches people the dialog is not worth opening. The warning
  /// says the number, the button destroys them, and that is a decision the
  /// person looking at their own checkout is entitled to make.
  ///
  /// Facts that never computed raise nothing. A probe that has not run is not
  /// evidence of a clean tree, but it is not evidence of a dirty one either,
  /// and blocking on ignorance would make the button unusable on first launch.
  static List<Guard> shellGuards({
    required bool isMain,
    required WorktreeFacts facts,
  }) => [
    if (isMain)
      const Guard.block(
        "This is the repository's primary checkout. Removing it would take "
        'the repository with it.',
      ),
    if (facts.git.value case var git?) ...[
      if (git.dirty > 0)
        Guard.warn(
          '${git.dirty} uncommitted ${_files(git.dirty)} here. They go with the '
          'checkout, and nothing can bring them back.',
        ),
      if (git.ahead > 0)
        Guard.warn(
          '${git.ahead} ${_commits(git.ahead)} not pushed anywhere. The '
          'commits survive in the repository, but nothing else has them.',
        ),
    ],
    if (facts.agent.value?.state == AgentState.working)
      const Guard.warn(
        'An agent session is still working in this worktree. Make sure it is '
        'done before you remove it.',
      ),
  ];

  static int _rank(Guard guard) => guard.level == GuardLevel.block ? 0 : 1;

  static String _files(int count) => count == 1 ? 'file' : 'files';
  static String _commits(int count) => count == 1 ? 'commit' : 'commits';
}

/// One step, and the plugin whose action runs it.
class PlannedStep {
  const PlannedStep({required this.pluginId, required this.step});

  /// The plugin that emitted [step]. `TeardownStep.id` names an action on it.
  final String pluginId;

  final TeardownStep step;
}
