import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/teardown/dialog.dart';
import 'package:flutterware_app/src/teardown/plan.dart';
import 'package:flutterware_app/src/teardown/remove_worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

import 'shell.dart';

/// The checklist assembled when a worktree is removed.
///
/// A dialog is opened by a click, so it has no address and `fw capture`
/// cannot reach it. These are how it gets looked at: each button below builds
/// a [TeardownPlan] by hand and shows the real dialog over a fake `git`, so
/// every state — blocked, warned, closed, and a run that fails halfway — can be
/// seen without a checkout to destroy.
///
/// The remover is stubbed in all of them. Nothing here can delete anything, and
/// that is deliberate: a preview that ran real `git worktree remove` would be a
/// demo you could only look at once.
@Preview(name: 'Teardown checklist', group: 'Shell', wrapper: wrapInApp)
Widget teardownDialog() => const _TeardownCases();

/// The states worth a picture, each opening itself so a screenshot catches the
/// dialog rather than the button that opens it.
@Preview(name: 'Teardown · ordinary', group: 'Shell', wrapper: wrapInApp)
Widget teardownOrdinary() => _AutoOpen(
  _TeardownCases._plan(
    facts: _TeardownCases._facts(),
    reports: [_TeardownCases._runReport(), _TeardownCases._stackReport()],
  ),
);

@Preview(name: 'Teardown · dirty', group: 'Shell', wrapper: wrapInApp)
Widget teardownDirty() => _AutoOpen(
  _TeardownCases._plan(
    facts: _TeardownCases._facts(dirty: 5),
    reports: [_TeardownCases._runReport(), _TeardownCases._stackReport()],
  ),
);

@Preview(name: 'Teardown · warned', group: 'Shell', wrapper: wrapInApp)
Widget teardownWarned() => _AutoOpen(
  _TeardownCases._plan(
    facts: _TeardownCases._facts(ahead: 3, agent: AgentState.working),
    reports: [_TeardownCases._stackReport()],
  ),
);

@Preview(name: 'Teardown · not open', group: 'Shell', wrapper: wrapInApp)
Widget teardownClosed() => _AutoOpen(
  _TeardownCases._plan(facts: _TeardownCases._facts(), sessionOpen: false),
);

/// Shows [plan]'s dialog as soon as there is a [Navigator] to show it in.
class _AutoOpen extends StatefulWidget {
  const _AutoOpen(this.plan);

  final TeardownPlan plan;

  @override
  State<_AutoOpen> createState() => _AutoOpenState();
}

class _AutoOpenState extends State<_AutoOpen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showTeardownDialog(
          context,
          prepare: () async => TeardownPreparation(widget.plan, null),
          repositoryRoot: '/tmp',
          remover: _Case._fakeGit(fails: false),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.colors.bg, child: const SizedBox.expand());
}

class _TeardownCases extends StatelessWidget {
  const _TeardownCases();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.bg,
    body: ListView(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      children: [
        _Case(
          'The ordinary case',
          'An app still running, a stack still up, and a branch that could go '
              'with the checkout. Everything is ticked except the branch.',
          plan: _plan(facts: _facts(), reports: [_runReport(), _stackReport()]),
        ),
        _Case(
          'Uncommitted work — warned, then forced',
          'Abandoned checkouts have junk in them almost by definition, so this '
              'warns and goes ahead. The removal row says how many files it '
              'takes, and git is given --force so the promise is kept.',
          plan: _plan(facts: _facts(dirty: 5), reports: [_stackReport()]),
        ),
        _Case(
          'Blocked — a plugin says no',
          'The only refusals left are the primary checkout, which the row '
              'never offers to remove, and a plugin raising a blocking guard.',
          plan: _plan(
            facts: _facts(),
            reports: [
              _stackReport(),
              PluginReport(
                id: 'acme.thing',
                label: 'Thing',
                status: Status.none,
                view: const PluginView([]),
                guards: const [
                  Guard.block(
                    'A migration is half-applied against this stack.',
                  ),
                ],
              ),
            ],
          ),
        ),
        _Case(
          'Warned — unpushed commits, and an agent mid-task',
          'Both recoverable, both worth saying. Proceed is allowed.',
          plan: _plan(
            facts: _facts(ahead: 3, agent: AgentState.working),
            reports: [_stackReport()],
          ),
        ),
        _Case(
          'A worktree nobody has open',
          'No session, so no plugin knows anything. The dialog says which half '
              'is missing rather than implying the checkout is idle.',
          plan: _plan(facts: _facts(), sessionOpen: false),
        ),
        _Case(
          'Git refuses',
          'The second line of defence: a file written since the dialog opened '
              'is not in the cached count, and git looks at the disk as it is '
              'now. The checkout survives.',
          plan: _plan(facts: _facts(), reports: [_stackReport()]),
          gitFails: true,
        ),
      ],
    ),
  );

  static WorktreeFacts _facts({
    int dirty = 0,
    int ahead = 0,
    AgentState? agent,
  }) => WorktreeFacts(
    git: Fact.fresh(GitFacts(dirty: dirty, ahead: ahead)),
    agent: agent == null
        ? const Fact.unknown()
        : Fact.fresh(AgentFacts(state: agent)),
  );

  static TeardownPlan _plan({
    required WorktreeFacts facts,
    List<PluginReport> reports = const [],
    bool sessionOpen = true,
  }) => TeardownPlan.build(
    worktree: 'explorer brainstorm',
    path: '/Users/dev/worktrees/example/explorer-brainstorm-e5efdc',
    branch: 'claude/worktree-explorer-e5efdc',
    facts: facts,
    reports: reports,
    sessionOpen: sessionOpen,
  );

  static PluginReport _runReport() => PluginReport(
    id: 'flutterware.run',
    label: 'Run',
    status: Status.none,
    view: const PluginView([]),
    teardown: const [
      TeardownStep(
        'stop',
        'Stop flutterware GUI on macOS',
        detail: 'started 4h ago',
        checked: true,
        phase: TeardownPhase.apps,
      ),
    ],
  );

  static PluginReport _stackReport() => PluginReport(
    id: 'flutterware.dev_stack',
    label: 'Dev stack',
    status: Status.none,
    view: const PluginView([]),
    teardown: const [
      TeardownStep(
        'stop',
        'Tear down Dev stack',
        detail: '4 containers · slot 8200-8208 · destroys the database',
        checked: true,
        danger: true,
        phase: TeardownPhase.infra,
      ),
    ],
  );
}

class _Case extends StatelessWidget {
  const _Case(
    this.title,
    this.description, {
    required this.plan,
    this.gitFails = false,
  });

  final String title;
  final String description;
  final TeardownPlan plan;
  final bool gitFails;

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: type.bodyStrong),
          const Gap(FwSpacing.xs),
          Text(description, style: type.bodyMuted),
          const Gap(FwSpacing.lg),
          OutlinedButton(
            onPressed: () => showTeardownDialog(
              context,
              // Slow on purpose: the preparing state is what a real closed
              // worktree shows while its config runs, and it is the state the
              // first version had no way to draw.
              prepare: () async {
                await Future<void>.delayed(const Duration(milliseconds: 900));
                return TeardownPreparation(plan, null);
              },
              repositoryRoot: '/tmp',
              remover: _fakeGit(fails: gitFails),
            ),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }

  /// Slow enough that the running state is legible, and incapable of touching
  /// a real repository.
  static WorktreeRemover _fakeGit({required bool fails}) => WorktreeRemover(
    runGit: (arguments, {workingDirectory}) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (fails && arguments.first == 'worktree') {
        return ProcessResult(
          0,
          1,
          '',
          "fatal: '…/explorer-brainstorm-e5efdc' contains modified or "
              'untracked files, use --force to delete it',
        );
      }
      return ProcessResult(0, 0, '', '');
    },
  );
}
