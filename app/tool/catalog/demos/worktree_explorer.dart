import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/explorer_row.dart';
import 'package:flutterware_app/src/worktrees/explorer_screen.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// The worktree explorer — `fw:///worktrees`.
///
/// Stacked rather than one state per entry, and for the reason the sidebar-row
/// demo gives: the claims this design makes are about rows *relative to each
/// other*. The change bar is drawn on a scale shared across the list, the top
/// lines share a baseline whatever a given worktree happens to know, and the
/// dots are meant to form a column. A gallery showing one row at a time could
/// not catch any of those going wrong.
///
/// No Figma behind this — it is flutterware's own chrome. The design is
/// `docs/superpowers/specs/2026-08-10-worktree-explorer-view-design.md`.

/// Fixed, so a screenshot of this entry is the same picture tomorrow.
final _now = DateTime(2026, 8, 10, 14, 30);

DateTime _minutesAgo(int m) => _now.subtract(Duration(minutes: m));
DateTime _hoursAgo(int h) => _now.subtract(Duration(hours: h));

ChangeShape _shape(List<(String, int, int)> buckets, {required int files}) =>
    ChangeShape(
      files: files,
      buckets: [
        for (var (name, added, removed) in buckets)
          ChangeBucket(name, added: added, removed: removed),
      ],
    );

Worktree _wt(String dir, {String? branch, bool isMain = false}) => Worktree(
  path: '/Users/x/claude_worktrees/flutterware/$dir',
  gitName: isMain ? null : dir,
  branch: branch,
  isMain: isMain,
);

// ─── The realistic list ──────────────────────────────────────────────────────

List<ExplorerEntry> get _repo => [
  ExplorerEntry(
    isOpen: true,
    worktree: _wt(
      'worktree-explorer-e5efdc',
      branch: 'claude/worktree-explorer-e5efdc',
    ),
    facts: WorktreeFacts(
      git: Fact.fresh(
        GitFacts(
          ahead: 2,
          dirty: 3,
          changes: _shape([
            ('docs', 612, 4),
            ('app', 208, 71),
            ('lib', 41, 12),
          ], files: 14),
        ),
      ),
      agent: Fact.fresh(
        AgentFacts(
          state: AgentState.waiting,
          title: 'Worktree explorer feature brainstorm',
          lastPrompt: 'mock the row in real tokens',
          at: _minutesAgo(2),
          model: 'Opus 5',
        ),
      ),
      forge: Fact.fresh(
        ForgeFacts(
          number: 76,
          title: 'An entry point says what it runs on',
          state: PrState.open,
          checks: ChecksState.passing,
          review: ReviewState.approved,
        ),
      ),
      activity: Fact.fresh(
        ActivityFacts(at: _minutesAgo(2), source: ActivitySource.agent),
      ),
    ),
  ),
  ExplorerEntry(
    isOpen: true,
    worktree: _wt(
      'ui-catalog-design-38b6c0',
      branch: 'claude/ui-catalog-design-38b6c0',
    ),
    facts: WorktreeFacts(
      git: Fact.fresh(
        GitFacts(
          ahead: 11,
          changes: _shape([
            ('app', 1840, 760),
            ('lib', 210, 130),
            ('test', 90, 40),
            ('docs', 30, 8),
            ('examples', 12, 2),
          ], files: 62),
        ),
      ),
      agent: Fact.fresh(
        AgentFacts(
          state: AgentState.working,
          title: 'The UI catalog becomes Previews',
          lastPrompt: 'fix the analyze failure on beta',
          at: _minutesAgo(1),
          model: 'Opus 5',
        ),
      ),
      forge: Fact.fresh(
        ForgeFacts(
          number: 73,
          title: 'The UI catalog becomes Previews',
          state: PrState.open,
          checks: ChecksState.failing,
          failingChecks: 1,
        ),
      ),
      activity: Fact.fresh(
        ActivityFacts(at: _minutesAgo(4), source: ActivitySource.agent),
      ),
    ),
  ),
  ExplorerEntry(
    worktree: _wt(
      'run-plugin-entry-8e5682',
      branch: 'claude/run-plugin-entry-8e5682',
    ),
    facts: WorktreeFacts(
      git: Fact.fresh(
        GitFacts(ahead: 4, changes: _shape([('app', 320, 96)], files: 9)),
      ),
      agent: Fact.fresh(
        AgentFacts(
          state: AgentState.idle,
          title: 'Run plugin entry restrictions',
          lastPrompt: 'run the tests again',
          at: _hoursAgo(3),
        ),
      ),
      forge: Fact.fresh(
        ForgeFacts(
          number: 74,
          title: 'Run plugin entry restrictions',
          state: PrState.open,
          checks: ChecksState.passing,
          review: ReviewState.changesRequested,
        ),
      ),
      activity: Fact.fresh(
        ActivityFacts(at: _hoursAgo(3), source: ActivitySource.agent),
      ),
    ),
  ),
  ExplorerEntry(
    worktree: _wt(
      'ci-green-merge-df3e7d',
      branch: 'claude/ci-green-merge-df3e7d',
    ),
    facts: WorktreeFacts(
      git: Fact.fresh(
        GitFacts(
          ahead: 1,
          dirty: 1,
          changes: _shape([('docs', 11, 4)], files: 2),
        ),
      ),
      agent: const Fact.fresh(AgentFacts(state: AgentState.none)),
      forge: const Fact.unavailable('no pull request for this branch'),
      activity: Fact.fresh(
        ActivityFacts(at: _hoursAgo(6), source: ActivitySource.commit),
      ),
    ),
  ),
  ExplorerEntry(
    worktree: _wt(
      'asset-inspector-665385',
      branch: 'claude/asset-inspector-665385',
    ),
    facts: WorktreeFacts(
      // Cached from the last launch and not yet revalidated — shown dimmed
      // rather than replaced by a spinner.
      git: Fact.stale(
        GitFacts(
          ahead: 7,
          changes: _shape([('app', 540, 210), ('test', 120, 30)], files: 21),
        ),
      ),
      agent: Fact.stale(
        AgentFacts(
          state: AgentState.idle,
          title: 'Asset inspector plugin',
          lastPrompt: 'add the transformer column',
          at: _hoursAgo(28),
        ),
      ),
      forge: const Fact.unknown(),
      activity: Fact.stale(
        ActivityFacts(at: _hoursAgo(28), source: ActivitySource.commit),
      ),
    ),
  ),
  ExplorerEntry(
    worktree: _wt('scenarios-m4-1068ca', branch: 'claude/scenarios-m4-1068ca'),
    facts: WorktreeFacts(
      git: const Fact.failed('git status exited 128: index.lock exists'),
      agent: const Fact.fresh(AgentFacts(state: AgentState.none)),
      forge: const Fact.unavailable('no pull request for this branch'),
      activity: Fact.fresh(
        ActivityFacts(at: _hoursAgo(50), source: ActivitySource.opened),
      ),
    ),
  ),
  ExplorerEntry(
    isOpen: true,
    worktree: _wt('flutterware', branch: 'master', isMain: true),
    facts: WorktreeFacts(
      git: const Fact.fresh(GitFacts()),
      agent: const Fact.fresh(AgentFacts(state: AgentState.none)),
      forge: const Fact.unavailable('no pull request for this branch'),
      activity: Fact.fresh(
        ActivityFacts(at: _hoursAgo(9), source: ActivitySource.commit),
      ),
    ),
  ),
];

@Preview(name: 'The list', group: 'Worktree explorer', wrapper: wrapInAppTheme)
Widget explorerList() => _LiveExplorer(entries: _repo);

/// A repo that uses worktrees for release branches: no agents, no PRs, and two
/// of the six columns permanently empty.
///
/// Here to keep open question 5 visible — whether that case wants a denser
/// single-line mode, or whether the empty columns are an honest "nothing here".
@Preview(
  name: 'A repo without agents',
  group: 'Worktree explorer',
  wrapper: wrapInAppTheme,
)
Widget explorerNoAgents() => _LiveExplorer(
  entries: [
    for (var (i, name) in [
      'release/24.4',
      'release/24.3',
      'hotfix/24.3.1',
    ].indexed)
      ExplorerEntry(
        worktree: _wt('rel-$i', branch: name),
        facts: WorktreeFacts(
          git: Fact.fresh(
            GitFacts(
              ahead: i + 1,
              changes: _shape([('lib', 40 * (i + 1), 12)], files: 3 + i),
            ),
          ),
          agent: const Fact.unavailable(),
          forge: const Fact.unavailable('no pull request for this branch'),
          activity: Fact.fresh(
            ActivityFacts(
              at: _hoursAgo(20 * (i + 1)),
              source: ActivitySource.commit,
            ),
          ),
        ),
      ),
  ],
);

@Preview(
  name: 'One checkout',
  group: 'Worktree explorer',
  wrapper: wrapInAppTheme,
)
Widget explorerSingle() => _LiveExplorer(
  entries: [
    ExplorerEntry(
      isOpen: true,
      worktree: _wt('my-app', branch: 'main', isMain: true),
      facts: WorktreeFacts(
        git: const Fact.fresh(GitFacts(dirty: 2)),
        agent: const Fact.unavailable(),
        forge: const Fact.unavailable('gh is not installed'),
        activity: Fact.fresh(
          ActivityFacts(at: _minutesAgo(12), source: ActivitySource.commit),
        ),
      ),
    ),
  ],
);

// ─── Row states ──────────────────────────────────────────────────────────────

@Preview(
  name: 'Row states',
  group: 'Worktree explorer',
  wrapper: wrapInAppTheme,
)
Widget explorerRowStates() => _Sheet(
  children: [
    _Labelled(
      'nothing known yet — the first launch, before anything is cached',
      _Row(
        label: 'claude/fresh-checkout-91ab2c',
        branch: 'claude/fresh-checkout-91ab2c',
        facts: const WorktreeFacts(),
      ),
    ),
    _Labelled(
      'the agent is waiting on you — the row this screen exists for',
      _Row(
        label: 'Worktree explorer feature brainstorm',
        branch: 'claude/worktree-explorer-e5efdc',
        isOpen: true,
        isCurrent: true,
        facts: _repo.first.facts,
      ),
    ),
    _Labelled(
      'working, checks failing, a big branch',
      _Row(
        label: 'The UI catalog becomes Previews',
        branch: 'claude/ui-catalog-design-38b6c0',
        isOpen: true,
        facts: _repo[1].facts,
      ),
    ),
    _Labelled(
      'the keyboard is on this one — accentSoft, not the hover tone',
      _Row(
        label: 'The UI catalog becomes Previews',
        branch: 'claude/ui-catalog-design-38b6c0',
        facts: _repo[1].facts,
        cursor: true,
      ),
    ),
    _Labelled(
      'someone asked for changes',
      _Row(
        label: 'Run plugin entry restrictions',
        branch: 'claude/run-plugin-entry-8e5682',
        facts: _repo[2].facts,
      ),
    ),
    _Labelled(
      'stale — a cached value, dimmed, never a spinner',
      _Row(
        label: 'Asset inspector plugin',
        branch: 'claude/asset-inspector-665385',
        facts: _repo[4].facts,
      ),
    ),
    _Labelled(
      'a probe broke — never a red row; it is our problem, not the worktree’s',
      _Row(
        label: 'claude/scenarios-m4-1068ca',
        branch: 'claude/scenarios-m4-1068ca',
        facts: _repo[5].facts,
      ),
    ),
    _Labelled(
      'the main checkout, in sync, nothing to say',
      _Row(
        label: 'master',
        branch: 'master',
        isMain: true,
        isOpen: true,
        facts: _repo.last.facts,
      ),
    ),
    _Labelled(
      'expanded — columns for what has structure, full width for prose',
      _Row(
        label: 'The UI catalog becomes Previews',
        branch: 'claude/ui-catalog-design-38b6c0',
        isOpen: true,
        expanded: true,
        facts: _repo[1].facts,
      ),
    ),
    _Labelled(
      'a title and a branch both too long for their cells',
      _Row(
        label:
            'Rework the dependency table so it counts downloads rather than '
            'percentiles, and says so',
        branch: 'claude/dependency-table-downloads-not-percentiles-4f7ddd',
        facts: WorktreeFacts(
          git: Fact.fresh(
            GitFacts(
              ahead: 3,
              dirty: 12,
              changes: _shape([
                ('app', 210, 40),
                ('packages', 60, 10),
                ('docs', 20, 5),
                ('examples', 8, 1),
                ('tool', 4, 0),
              ], files: 18),
            ),
          ),
          agent: Fact.fresh(
            AgentFacts(
              state: AgentState.working,
              title: 'Rework the dependency table',
              lastPrompt:
                  'now make the percentile column go away entirely and use the '
                  'download counts we already fetch',
              at: _minutesAgo(1),
            ),
          ),
          forge: const Fact.fresh(
            ForgeFacts(
              number: 71,
              title: 'The dependency table counts downloads',
              state: PrState.draft,
              checks: ChecksState.pending,
            ),
          ),
          activity: Fact.fresh(
            ActivityFacts(at: _minutesAgo(1), source: ActivitySource.agent),
          ),
        ),
      ),
    ),
  ],
);

// ─── Harness ─────────────────────────────────────────────────────────────────

/// The screen with its filter and sort live, so the demo exercises them rather
/// than only picturing them.
class _LiveExplorer extends StatefulWidget {
  const _LiveExplorer({required this.entries});

  final List<ExplorerEntry> entries;

  @override
  State<_LiveExplorer> createState() => _LiveExplorerState();
}

class _LiveExplorerState extends State<_LiveExplorer> {
  var _query = '';
  var _sort = ExplorerSort.activity;
  var _refreshing = false;

  @override
  Widget build(BuildContext context) => WorktreeExplorerView(
    entries: widget.entries,
    now: _now,
    query: _query,
    sort: _sort,
    refreshedAt: _minutesAgo(1),
    isRefreshing: _refreshing,
    currentWorktreePath: widget.entries.first.worktree.path,
    onQueryChanged: (value) => setState(() => _query = value),
    onSortChanged: (value) => setState(() => _sort = value),
    onRefresh: () => setState(() => _refreshing = !_refreshing),
  );
}

/// One row at the width it really has, on the real background.
class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.facts,
    this.branch,
    this.isMain = false,
    this.isOpen = false,
    this.isCurrent = false,
    this.expanded = false,
    this.cursor = false,
  });

  final String label;
  final WorktreeFacts facts;
  final String? branch;
  final bool isMain;
  final bool isOpen;
  final bool isCurrent;
  final bool expanded;
  final bool cursor;

  @override
  Widget build(BuildContext context) => WorktreeRow(
    cursor: cursor,
    label: label,
    branch: branch,
    isMain: isMain,
    isOpen: isOpen,
    isCurrent: isCurrent,
    expanded: expanded,
    path: '/Users/x/claude_worktrees/flutterware/${branch?.split('/').last}',
    facts: facts,
    now: _now,
    scale: (facts.git.value?.changes?.lines ?? 0) / 2600,
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xl),
      children: children,
    ),
  );
}

/// A caption above a state, so a screenshot of this entry says what each row is
/// meant to be showing.
class _Labelled extends StatelessWidget {
  const _Labelled(this.caption, this.child);

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.xl,
            0,
            FwSpacing.lg,
            FwSpacing.xs,
          ),
          child: Text(
            caption,
            style: context.type.micro.copyWith(color: context.colors.mut3),
          ),
        ),
        child,
      ],
    ),
  );
}
