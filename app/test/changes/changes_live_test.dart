import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/ranking.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// What survives a re-index — and after the split, the answer is *the thing
/// you are reading*, by construction.
///
/// The old screen needed a scroll anchor for this: index and content were one
/// list, so an agent creating a file renumbered rows under your eyes and slid
/// the diff down by 63 px. Measured, fixed, and then deleted — with the panes
/// separated, a new file changes the left column and the right pane does not
/// move at all. That is the strongest argument the layout has.
///
/// A live re-probe is indistinguishable here from the refresh button: both go
/// through `ChangesController.refresh`, and the button is the half a widget
/// test can press.
void main() {
  var worktree = const Worktree(
    path: '/wt/feature',
    gitName: 'feature',
    branch: 'claude/feature',
  );

  FileChange file(String path, {int added = 10, int hunks = 1}) => FileChange(
    path: path,
    status: ChangeStatus.modified,
    added: added,
    removed: 0,
    hunks: [
      for (var i = 0; i < hunks; i++)
        HunkSpan(
          oldStart: 1 + i * 10,
          oldCount: 1,
          newStart: 1 + i * 10,
          newCount: 1,
          added: 1,
          removed: 0,
          byteStart: 0,
          byteEnd: 0,
        ),
    ],
    byteStart: 0,
    byteEnd: 0,
  );

  ChangeSet setOf(
    List<FileChange> files, {
    Ranking? ranking,
    Set<String> uncommitted = const {},
  }) => ChangeSet(
    worktreePath: worktree.path,
    patch: PatchIndex.empty,
    base: 'master',
    baseSource: BaseSource.inferred,
    files: files,
    ranking: ranking,
    uncommitted: uncommitted,
  );

  // Two digits, so the index's alphabetical order and the loop's are the same
  // one — `f9` after `f19` is correct and unreadable in a test about which row
  // moved.
  List<FileChange> twenty() => [
    for (var i = 0; i < 20; i++)
      file('lib/f${i.toString().padLeft(2, '0')}.dart', added: 100 - i),
  ];

  late ChangeSet current;

  Future<void> pump(WidgetTester tester, {bool live = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree,
            // This file is about what a re-probe does to the screen, not about
            // what wakes it. A real watch on a path that does not exist would
            // only make the header say so.
            live: live,
            load: (_) async => current,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reprobe(WidgetTester tester, ChangeSet next) async {
    current = next;
    await tester.tap(find.byTooltip('Read this checkout again'));
    await tester.pumpAndSettle();
  }

  Finder inIndex(String text) => find.descendant(
    of: find.byKey(changesListKey),
    matching: find.text(text),
  );

  setUp(() => current = setOf(twenty()));

  testWidgets('a file appearing does not move what you are reading', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inIndex('f09.dart'));
    await tester.pumpAndSettle();
    var before = tester.getTopLeft(find.textContaining('@@').first);

    await reprobe(
      tester,
      setOf([file('lib/BIG.dart', added: 999), ...twenty()]),
    );

    expect(inIndex('BIG.dart'), findsOneWidget, reason: 'the index did move');
    expect(tester.getTopLeft(find.textContaining('@@').first), before);
  });

  testWidgets('the index keeps its own scroll position', (tester) async {
    await pump(tester);
    await tester.drag(find.byKey(changesListKey), const Offset(0, -200));
    await tester.pumpAndSettle();
    var before = tester.getTopLeft(inIndex('f09.dart'));

    // Nothing above it moved, so nothing below it should have either.
    await reprobe(tester, setOf(twenty()));
    expect(tester.getTopLeft(inIndex('f09.dart')), before);
  });

  testWidgets('the file you are on survives, and its counts update', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(inIndex('f03.dart'));
    await tester.pumpAndSettle();
    expect(find.textContaining('@@'), findsOneWidget);

    var grown = [
      for (var f in twenty())
        if (f.path == 'lib/f03.dart')
          file('lib/f03.dart', added: 400, hunks: 3)
        else
          f,
    ];
    await reprobe(tester, setOf(grown, uncommitted: {'lib/f03.dart'}));

    expect(find.textContaining('@@'), findsNWidgets(3));
    expect(
      find.descendant(
        of: find.byKey(changesFileKey).hitTestable(),
        matching: find.text('+400'),
      ),
      findsNothing,
      reason: 'the counts live in the pane header, above the list',
    );
    expect(find.text('+400'), findsWidgets);
    expect(find.text('uncommitted'), findsWidgets);
  });

  testWidgets('the filter you typed is still there', (tester) async {
    // The explorer learned this the hard way once the watchers landed: a screen
    // that rebuilds every couple of seconds makes a text field unusable if the
    // field's state is rebuilt with it.
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'f1');
    await tester.pumpAndSettle();
    expect(inIndex('f00.dart'), findsNothing);

    await reprobe(tester, setOf([file('lib/new.dart'), ...twenty()]));

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'f1',
    );
    expect(
      inIndex('f00.dart'),
      findsNothing,
      reason: 'and it is still filtering, not merely still displaying',
    );
  });

  testWidgets('a live screen says it is watching; a dead one says that', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Watching'), findsNothing, reason: 'live: false');

    // `/wt/feature` does not exist, so the watch cannot be established — which
    // is exactly the state worth naming, because the screen otherwise looks
    // live and has stopped being true.
    await pump(tester, live: true);
    expect(find.text('Not watching'), findsOneWidget);
  });

  testWidgets(
    'a file that vanished under you says so, and the index moves on',
    (tester) async {
      await pump(tester);
      await tester.tap(inIndex('f03.dart'));
      await tester.pumpAndSettle();

      await reprobe(
        tester,
        setOf([
          for (var f in twenty())
            if (f.path != 'lib/f03.dart') f,
        ]),
      );

      expect(
        find.textContaining('no longer part of the delta'),
        findsOneWidget,
      );
      expect(inIndex('f03.dart'), findsNothing);
    },
  );
}
