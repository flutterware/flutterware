import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/explorer_row.dart';
import 'package:flutterware_app/src/worktrees/explorer_screen.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

/// The list must not move while you are reading it.
///
/// This became a real complaint the day the watchers landed: with two agents
/// working, the rows swapped every couple of seconds and were hard to read or
/// click. The cause was ordering by a timestamp the row does not show — see
/// `coarseAge` in facts_text.dart — plus `List.sort` being unstable in Dart, so
/// even ties were free to reshuffle on any rebuild.
void main() {
  var now = DateTime(2026, 8, 10, 14, 30);

  Future<List<String>> order(
    WidgetTester tester,
    List<ExplorerEntry> entries, {
    ExplorerSort sort = ExplorerSort.activity,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: WorktreeExplorerView(entries: entries, now: now, sort: sort),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .widgetList<WorktreeRow>(find.byType(WorktreeRow))
        .map((row) => row.branch!)
        .toList();
  }

  testWidgets('two agents working do not shuffle the list', (tester) async {
    // Both mid-answer, seconds apart, both rendering `now` — and each line
    // either one writes flips which is newest.
    List<ExplorerEntry> entries({required bool flipped}) => [
      _entry('beta', now, seconds: flipped ? 9 : 1),
      _entry('alpha', now, seconds: flipped ? 1 : 9),
      _entry('gamma', now, seconds: 3600),
    ];

    expect(await order(tester, entries(flipped: false)), [
      'alpha',
      'beta',
      // An hour old, and the only row whose position says anything.
      'gamma',
    ]);
    expect(await order(tester, entries(flipped: true)), [
      'alpha',
      'beta',
      'gamma',
    ], reason: 'the newest of the two changed, and nothing moved');
  });

  testWidgets('a row that crosses into a new label does move', (tester) async {
    // The other half of the rule: the list is as steady as the labels and no
    // steadier. `beta` has gone quiet long enough to read `2m`, so it drops.
    expect(
      await order(tester, [
        _entry('beta', now, seconds: 120),
        _entry('alpha', now, seconds: 30),
      ]),
      ['alpha', 'beta'],
    );
    expect(
      await order(tester, [
        _entry('beta', now, seconds: 30),
        _entry('alpha', now, seconds: 120),
      ]),
      ['beta', 'alpha'],
    );
  });

  testWidgets('rows with nothing known sort last, not first', (tester) async {
    expect(
      await order(tester, [
        ExplorerEntry(worktree: _worktree('unknown')),
        _entry('touched', now, seconds: 86400 * 5),
      ]),
      ['touched', 'unknown'],
    );
  });

  testWidgets('ties are broken by something that cannot change', (
    tester,
  ) async {
    // Identical facts in every mode: without a final tiebreak, `List.sort`
    // being unstable means any rebuild is free to reorder these.
    var entries = [
      _entry('ccc', now, seconds: 5),
      _entry('aaa', now, seconds: 5),
      _entry('bbb', now, seconds: 5),
    ];
    for (var sort in ExplorerSort.values) {
      expect(await order(tester, entries, sort: sort), [
        'aaa',
        'bbb',
        'ccc',
      ], reason: 'sorted by ${sort.label}');
    }
  });

  testWidgets('a refresh landing mid-word does not disturb the filter', (
    tester,
  ) async {
    var query = '';
    // The screen as the shell drives it: the parent owns the query and hands it
    // back down, and the facts underneath change on their own.
    Future<void> pump(List<ExplorerEntry> entries) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) => WorktreeExplorerView(
              entries: entries,
              now: now,
              query: query,
              onQueryChanged: (value) => setState(() => query = value),
            ),
          ),
        ),
      ),
    );

    await pump([_entry('alpha', now, seconds: 5)]);
    await tester.enterText(find.byType(TextField), 'alph');
    await tester.pump();

    // Put the caret back into the middle of the word, as it would be if you
    // were correcting a typo.
    var field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();

    // A watcher fires: new facts, a rebuild nobody asked for.
    await pump([_entry('alpha', now, seconds: 1)]);

    var after = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(after.text, 'alph', reason: 'the query survived the rebuild');
    expect(
      after.selection.baseOffset,
      2,
      reason: 'and so did the caret — a new controller would have reset it',
    );
    expect(
      find.byType(WorktreeRow),
      findsOneWidget,
      reason: 'still filtering on what was typed',
    );
  });

  testWidgets('a query set from outside still lands', (tester) async {
    Future<void> pump(String query) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: WorktreeExplorerView(
            entries: [_entry('alpha', now, seconds: 5)],
            now: now,
            query: query,
          ),
        ),
      ),
    );

    await pump('');
    await pump('alpha');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'alpha',
    );
  });

  testWidgets('needs-you is a partition of the same order', (tester) async {
    var entries = [
      _entry('quiet-fresh', now, seconds: 5),
      _entry('loud-old', now, seconds: 7200, needsYou: true),
      _entry('loud-fresh', now, seconds: 10, needsYou: true),
    ];
    expect(await order(tester, entries, sort: ExplorerSort.needsYou), [
      'loud-fresh',
      'loud-old',
      'quiet-fresh',
    ]);
  });
}

Worktree _worktree(String branch) =>
    Worktree(path: '/repo/$branch', gitName: branch, branch: branch);

ExplorerEntry _entry(
  String branch,
  DateTime now, {
  required int seconds,
  bool needsYou = false,
}) => ExplorerEntry(
  worktree: _worktree(branch),
  facts: WorktreeFacts(
    agent: Fact.fresh(
      AgentFacts(
        state: needsYou ? AgentState.waiting : AgentState.working,
        at: now.subtract(Duration(seconds: seconds)),
      ),
    ),
    activity: Fact.fresh(
      ActivityFacts(
        at: now.subtract(Duration(seconds: seconds)),
        source: ActivitySource.agent,
      ),
    ),
  ),
);
