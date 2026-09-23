import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/ranking.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// Selection is the whole interaction. One file is showing, the address
/// says which, and the index says the same. Everything the old screen got wrong
/// here — a click that scrolled instead of opening, a file that could only be
/// reached by scrolling past another one's diff — was a consequence of not
/// having this.
void main() {
  var worktree = const Worktree(
    path: '/wt/feature',
    gitName: 'feature',
    branch: 'claude/feature',
  );

  FileChange file(
    String path, {
    int added = 10,
    ChangeStatus status = ChangeStatus.modified,
  }) => FileChange(
    path: path,
    status: status,
    added: added,
    removed: 0,
    hunks: [
      HunkSpan(
        oldStart: 1,
        oldCount: 1,
        newStart: 1,
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

  late List<String?> addressed;
  late ChangeSet current;

  ChangeSet setOf(
    List<FileChange> files, {
    List<UntrackedEntry> untracked = const [],
    Set<String> pinned = const {},
  }) => ChangeSet(
    worktreePath: worktree.path,
    patch: PatchIndex.empty,
    base: 'master',
    baseSource: BaseSource.inferred,
    files: files,
    untracked: untracked,
    attentionConfigured: pinned.isNotEmpty,
    ranking: Ranking([
      for (var file in files)
        RankedFile(
          file: file,
          tier: pinned.contains(file.path)
              ? RankTier.attention
              : RankTier.ordinary,
          rule: pinned.contains(file.path) ? 'lib/api/**' : null,
        ),
    ]),
  );

  Future<void> pump(WidgetTester tester, {String? initialPath}) async {
    addressed = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree,
            live: false,
            initialPath: initialPath,
            onPathChanged: addressed.add,
            load: (_) async => current,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inIndex(String text) => find.descendant(
    of: find.byKey(changesListKey),
    matching: find.text(text),
  );

  setUp(
    () => current = setOf([
      file('lib/alpha.dart', added: 90),
      file('lib/beta.dart', added: 60),
    ]),
  );

  testWidgets('the screen opens on the index, not on a file', (tester) async {
    // **Nothing is auto-selected**, tempting as it is: the screen's claim is
    // that it knows what to look at first, so opening straight into the
    // top-ranked file would seem to follow. It does not. The first question is
    // the *shape* of what an agent did, which is the index; reading a file is
    // the second question, and one you should have asked.
    await pump(tester);
    expect(find.text('Pick a file'), findsOneWidget);
    expect(addressed, isEmpty, reason: 'and the address was not rewritten');
  });

  testWidgets('picking a file writes it into the address', (tester) async {
    await pump(tester);
    await tester.tap(inIndex('beta.dart'));
    await tester.pumpAndSettle();

    expect(addressed, ['lib/beta.dart']);
  });

  testWidgets('an address that names a file opens on it', (tester) async {
    // What makes a file's diff something you can paste to somebody.
    await pump(tester, initialPath: 'lib/beta.dart');
    expect(find.textContaining('@@'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(changesFileKey),
        matching: find.textContaining('@@'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a selection that is no longer in the delta says so', (
    tester,
  ) async {
    // The live case: an agent committed the file away, or reverted it. Falling
    // silently back to nothing would look like the app forgetting.
    await pump(tester, initialPath: 'lib/gone.dart');
    expect(find.text('lib/gone.dart'), findsOneWidget);
    expect(find.textContaining('no longer part of the delta'), findsOneWidget);
  });

  testWidgets('an untracked file opens on its header, not on a diff', (
    tester,
  ) async {
    // The body itself — the file's own lines — is covered in
    // file_body_test.dart, where the worktree is a real directory. Here the
    // path does not exist, which is its own case: the header still stands.
    current = setOf(
      [file('lib/alpha.dart')],
      untracked: const [UntrackedEntry('scratch.txt')],
    );
    await pump(tester);
    await tester.tap(inIndex('scratch.txt'));
    await tester.pumpAndSettle();

    expect(find.text('untracked'), findsOneWidget);
    expect(find.textContaining('no other side to diff against'), findsOne);
    expect(find.textContaining('@@'), findsNothing);
  });

  testWidgets('an untracked directory opens nothing at all', (tester) async {
    // Reading it would be the walk that keeping it to one row exists to avoid.
    current = setOf(
      [file('lib/alpha.dart')],
      untracked: const [UntrackedEntry.directory('packages/newpkg/build/')],
    );
    await pump(tester);
    await tester.tap(inIndex('packages/newpkg/build/'));
    await tester.pumpAndSettle();

    expect(find.text('Pick a file'), findsOneWidget);
    expect(addressed, isEmpty);
  });

  group('narrowing the index', () {
    // The filter box is the one narrowing control left. The lens beside it —
    // `n just changed`, drawn from a session-cumulative moved set — is gone.
    testWidgets('the filter box narrows both tabs, because it is on both', (
      tester,
    ) async {
      // The other half of the rule: a control you can see is a control that is
      // allowed to be filtering what you are looking at.
      current = setOf(
        [file('lib/api/client.dart'), file('lib/busy.dart')],
        pinned: {'lib/api/client.dart'},
      );
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'busy');
      await tester.pumpAndSettle();
      expect(inIndex('client.dart'), findsNothing);
    });

    testWidgets('a project with no rules is told how to write one', (
      tester,
    ) async {
      // **There are no built-in attention rules**, so without this the tab is
      // empty and the whole ranking reads as a feature that does not work. It
      // is the tab's empty state, which is a pane's worth of room to say the
      // whole thing rather than the one dim line a band could fit.
      current = setOf([file('lib/a.dart')]);
      await pump(tester);
      // Nothing is pinned, so it did not open here — All is where an empty
      // Important tab would be the worst of both.
      expect(find.textContaining('Nothing is pinned'), findsNothing);

      await tester.tap(find.text('Important'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing is pinned'), findsOneWidget);
      expect(find.textContaining('ChangesConfig'), findsOneWidget);
    });

    testWidgets('a project that has rules is told nothing', (tester) async {
      current = ChangeSet(
        worktreePath: worktree.path,
        patch: PatchIndex.empty,
        base: 'master',
        baseSource: BaseSource.inferred,
        files: [file('lib/a.dart')],
        attentionConfigured: true,
      );
      await pump(tester);
      await tester.tap(find.text('Important'));
      await tester.pumpAndSettle();

      // Two different silences: a project whose rules matched nothing is
      // looking at good news, not at a feature that appears broken.
      expect(find.textContaining('Nothing is pinned'), findsNothing);
      expect(find.text('No file matched an attention rule.'), findsOneWidget);
    });

    testWidgets('typing finds an untracked file, which it could not before', (
      tester,
    ) async {
      // `pathsMatching` took `FileChange`s, so an untracked entry was never in
      // the candidate set: typing its name hid it.
      current = setOf(
        [file('lib/a.dart')],
        untracked: const [UntrackedEntry('scratch.txt')],
      );
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'scratch');
      await tester.pumpAndSettle();
      expect(inIndex('scratch.txt'), findsOneWidget);
      expect(inIndex('a.dart'), findsNothing);
    });
  });

  testWidgets('the index marks which file the pane is showing', (tester) async {
    await pump(tester, initialPath: 'lib/beta.dart');
    var rows = tester
        .widgetList<IndexFileRow>(find.byType(IndexFileRow))
        .toList();
    expect(rows.where((r) => r.selected).map((r) => r.file.path), [
      'lib/beta.dart',
    ]);
  });
}
