import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/explorer_row.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

/// Every cell must survive every state, including the ones a happy path never
/// produces.
///
/// Written after finding that the changes cell enumerated `failed` and
/// `unknown` and then asserted the value was there — so a git fact that ever
/// became `unavailable` would have thrown a null assertion in the middle of a
/// list, on a screen whose entire purpose is to keep reporting when something is
/// missing. Nothing produces that state today, which is exactly why no test and
/// no demo would have caught it.
void main() {
  var now = DateTime(2026, 8, 10, 14, 30);

  /// One [Fact] per state, with the value states carrying [value].
  List<(String, Fact<T>)> states<T>(T value) => [
    ('unknown', Fact<T>.unknown()),
    ('unavailable', Fact<T>.unavailable('nothing here')),
    ('failed', Fact<T>.failed('it broke')),
    ('fresh', Fact.fresh(value)),
    ('stale', Fact.stale(value)),
  ];

  Future<void> pump(WidgetTester tester, WorktreeFacts facts) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: SizedBox(
            width: 1200,
            child: WorktreeRow(
              label: 'A worktree',
              branch: 'claude/thing',
              path: '/repo/thing',
              facts: facts,
              now: now,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  const git = GitFacts(
    ahead: 2,
    behind: 1,
    dirty: 3,
    base: 'main',
    changes: ChangeShape(
      files: 4,
      buckets: [ChangeBucket('app', added: 10, removed: 2)],
    ),
  );
  var agent = AgentFacts(
    state: AgentState.working,
    title: 'Doing a thing',
    at: now,
  );
  const pr = ForgeFacts(
    number: 79,
    title: 'A pull request',
    state: PrState.open,
    checks: ChecksState.failing,
    failingChecks: 1,
    review: ReviewState.changesRequested,
  );
  var activity = ActivityFacts(at: now, source: ActivitySource.agent);

  for (var (name, fact) in states(git)) {
    testWidgets('the changes cell renders a $name git fact', (tester) async {
      await pump(tester, WorktreeFacts(git: fact));
    });
  }

  for (var (name, fact) in states(agent)) {
    testWidgets('the agent cell renders a $name agent fact', (tester) async {
      await pump(tester, WorktreeFacts(agent: fact));
    });
  }

  for (var (name, fact) in states(pr)) {
    testWidgets('the PR cell renders a $name forge fact', (tester) async {
      await pump(tester, WorktreeFacts(forge: fact));
    });
  }

  for (var (name, fact) in states(activity)) {
    testWidgets('the when cell renders a $name activity fact', (tester) async {
      await pump(tester, WorktreeFacts(activity: fact));
    });
  }

  testWidgets('and the expanded detail does too, on a row that knows nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: SizedBox(
            width: 1200,
            child: WorktreeRow(
              label: 'A worktree',
              path: '/repo/thing',
              facts: const WorktreeFacts(
                git: Fact.unavailable('nothing here'),
                agent: Fact.unavailable('no agent session'),
                forge: Fact.unavailable('gh is not installed'),
              ),
              now: now,
              expanded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('PATH'), findsOneWidget);
  });
}
