import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/changes_tree.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/ranking.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// Structure, which the ranked list could not carry. A flat column of
/// fifty-three basenames answers "what should I look at" and says nothing about
/// the shape of the branch. The tree was dropped in the master/detail rewrite
/// and put back the same day.
///
/// The interesting half is how it coexists with the ranking rather than
/// competing with it: pinned files get their own tab, and inside the tree the
/// order is the **alphabet** — this is the surface you navigate by name, and a
/// weight order here sorted by a number the row does not print.
void main() {
  FileChange at(
    String path, {
    int added = 10,
    int removed = 0,
    ChangeStatus status = ChangeStatus.modified,
  }) => FileChange(
    path: path,
    status: status,
    added: added,
    removed: removed,
    hunks: const [],
    byteStart: 0,
    byteEnd: 0,
  );

  group('the model', () {
    test('single-child directories fold into one row', () {
      var tree = buildTree([
        at('app/lib/src/a.dart'),
        at('app/lib/src/b.dart'),
      ]);
      expect(tree.sortedChildren.single.name, 'app/lib/src');
    });

    test('a fork stops the folding', () {
      var tree = buildTree([at('app/lib/a.dart'), at('app/test/b.dart')]);
      expect(tree.sortedChildren.single.name, 'app');
      expect(
        tree.sortedChildren.single.sortedChildren.map((c) => c.name),
        containsAll(['lib', 'test']),
      );
    });

    test('counts are totals, not just what is directly inside', () {
      var tree = buildTree([
        at('app/lib/a.dart'),
        at('app/lib/deep/b.dart'),
        at('app/lib/deep/c.dart'),
      ]);
      expect(tree.sortedChildren.single.totalFiles, 3);
    });

    test('directories sort by name, not by how much they churned', () {
      // It used to be weight, so that the hammered module led. The row prints
      // its **file count**, so that order arrived on screen as 59, 60, 6, 3, 4,
      // 5 and read as no order at all. "What first" is the Important tab's
      // question; this one is "where is it".
      var tree = buildTree([
        at('alpha/small.dart', added: 2),
        at('zulu/huge.dart', added: 900),
      ]);
      expect(tree.sortedChildren.map((c) => c.name), ['alpha', 'zulu']);
    });

    test('files sort by name too, deletions among them', () {
      // The old rule promoted `D −88` to the top of its folder. In a tree that
      // buys a jump in the one column that had become scannable, and the status
      // letter already says it at the row.
      var tree = buildTree([
        at('lib/big.dart', added: 400),
        at(
          'lib/gone.dart',
          added: 0,
          removed: 12,
          status: ChangeStatus.deleted,
        ),
        at('lib/small.dart', added: 3),
      ]);
      expect(tree.sortedChildren.single.sortedLeaves.map((f) => f.path), [
        'lib/big.dart',
        'lib/gone.dart',
        'lib/small.dart',
      ]);
    });

    test('a capitalised name sits among its neighbours, not above them', () {
      // A plain `compareTo` puts every uppercase letter before every lowercase
      // one, which strands README.md at the top of a repository root.
      var tree = buildTree([
        at('app/pubspec.yaml'),
        at('app/README.md'),
        at('app/analysis_options.yaml'),
      ]);
      expect(tree.sortedChildren.single.sortedLeaves.map((f) => f.path), [
        'app/analysis_options.yaml',
        'app/pubspec.yaml',
        'app/README.md',
      ]);
    });

    test('two spellings of one name keep a stable order', () {
      var tree = buildTree([at('Foo/x.dart'), at('foo/y.dart')]);
      expect(tree.sortedChildren.map((c) => c.name), ['Foo', 'foo']);
    });

    test('an untracked file sits among its neighbours, by name', () {
      // The whole middle ground: git hands us the full path of an untracked
      // *file*, so placing it costs nothing and hides nothing — and a file an
      // agent wrote thirty seconds ago is the one you are most likely to be
      // looking for. Sorted with them rather than after them: an order that
      // put new files last would be a sort by a fact the row does not print.
      var tree = buildTree(
        [at('lib/alpha.dart'), at('lib/zulu.dart')],
        untracked: const [UntrackedEntry('lib/middle.dart')],
      );
      var lib = tree.sortedChildren.single;
      expect(lib.sortedLeaves.map((l) => l.path), [
        'lib/alpha.dart',
        'lib/middle.dart',
        'lib/zulu.dart',
      ]);
      expect(lib.sortedLeaves[1], isA<UntrackedLeaf>());
      expect(
        lib.totalFiles,
        3,
        reason: 'a count that skipped it would be quietly wrong',
      );
    });

    test('an untracked directory is never placed in the tree', () {
      // The freeze-guard, and the one thing it is actually about: git reports
      // the topmost wholly-untracked directory and does not descend, so this
      // one entry stands for a subtree nobody has walked. A tree is a map of a
      // shape that was read, and it would also draw a folder that cannot open.
      var tree = buildTree(
        [at('lib/a.dart')],
        untracked: const [
          UntrackedEntry.directory('build/'),
          UntrackedEntry.directory('packages/newpkg/build/'),
        ],
      );
      expect(tree.sortedChildren.map((c) => c.name), ['lib']);
      expect(tree.totalFiles, 1);
    });

    test('an untracked file in a directory nothing else touched', () {
      // It brings its own folder with it, and the folding applies to it like
      // any other: the row is `db/migrations`, not three of them.
      var tree = buildTree(
        [],
        untracked: const [UntrackedEntry('db/migrations/2.sql')],
      );
      expect(tree.sortedChildren.single.name, 'db/migrations');
      expect(tree.totalFiles, 1);
    });
  });

  group('on screen', () {
    var worktree = const Worktree(
      path: '/wt/feature',
      gitName: 'feature',
      branch: 'claude/feature',
    );

    late ChangeSet current;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: ChangesScreen(
              worktree: worktree,
              live: false,
              load: (_) async => current,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    ChangeSet setOf(
      List<FileChange> files, {
      Ranking? ranking,
      List<UntrackedEntry> untracked = const [],
    }) => ChangeSet(
      worktreePath: worktree.path,
      patch: PatchIndex.empty,
      base: 'master',
      baseSource: BaseSource.inferred,
      files: files,
      untracked: untracked,
      ranking: ranking,
    );

    testWidgets('the shape of the branch is on screen', (tester) async {
      current = setOf([
        at('app/lib/a.dart'),
        at('app/lib/b.dart'),
        at('docs/design.md'),
      ]);
      await pump(tester);

      expect(find.text('app/lib'), findsOneWidget);
      expect(find.text('docs'), findsOneWidget);
      // The count is the thing a flat list cannot say.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets(
      'a file in the tree is selectable, and does not repeat its path',
      (tester) async {
        current = setOf([at('app/lib/a.dart')]);
        await pump(tester);

        await tester.tap(
          find.descendant(
            of: find.byKey(changesListKey),
            matching: find.text('a.dart'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(changesFileKey), findsOneWidget);

        // `app/lib` is the folder row; the file under it does not say it again.
        expect(
          find.descendant(
            of: find.byKey(changesListKey),
            matching: find.text('app/lib'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a pinned file is in Important and also where it lives', (
      tester,
    ) async {
      // Taking pins *out* of the tree to avoid listing a file twice made the
      // tree an incomplete map: its counts came out one short per pin, so the
      // header said 53 over a tree totalling 52, and browsing to the pinned
      // file could not find it. The Important tab is a view onto the tree, not
      // a removal from it.
      var files = [at('app/lib/a.dart'), at('db/migrations/2.sql', added: 4)];
      current = setOf(
        files,
        ranking: Ranking([
          for (var f in files)
            RankedFile(
              file: f,
              tier: f.path.endsWith('.sql')
                  ? RankTier.attention
                  : RankTier.ordinary,
              rule: f.path.endsWith('.sql') ? '**/migrations/**' : null,
            ),
        ]),
      );
      await pump(tester);

      // It opens on Important, where the pin is one flat row carrying its own
      // directory line — the tab is all pins, so nothing there is flagged.
      expect(find.text('2.sql'), findsOneWidget);
      expect(find.text('matches **/migrations/**'), findsOneWidget);
      expect(find.text('db/migrations'), findsOneWidget);
      expect(find.text('app/lib'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      // The tree is a complete map: both directories, one file each, and the
      // pinned one flagged where it lives.
      expect(find.text('2.sql'), findsOneWidget);
      expect(find.text('app/lib'), findsOneWidget);
      expect(find.text('db/migrations'), findsOneWidget);
      expect(
        tester
            .widgetList<IndexFileRow>(find.byType(IndexFileRow))
            .where((r) => r.pinned),
        hasLength(1),
      );
    });

    testWidgets(
      'an untracked file is in the tree; a directory is in the tail',
      (tester) async {
        current = setOf(
          [at('app/lib/a.dart')],
          untracked: const [
            UntrackedEntry('app/lib/fresh.dart'),
            UntrackedEntry.directory('build/'),
          ],
        );
        await pump(tester);

        // The new file is under `app/lib` with the file it sits beside, and it
        // does not repeat its directory any more than a tracked one does.
        expect(find.text('app/lib'), findsOneWidget);
        expect(find.text('fresh.dart'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('a.dart')).dx,
          tester.getTopLeft(find.text('fresh.dart')).dx,
          reason: 'the same row, at the same indent, under the same folder',
        );
        // Both counted: two files under `app/lib`.
        expect(find.text('2'), findsOneWidget);

        // The directory keeps the tail, under a heading that says which of the
        // two things git calls untracked this one is.
        expect(find.text('Untracked directories'), findsOneWidget);
        expect(find.text('build/'), findsOneWidget);
        expect(find.text('directory, not scanned'), findsOneWidget);
      },
    );

    testWidgets('folders open one level down, and can be shut', (tester) async {
      current = setOf([at('app/lib/deep/a.dart'), at('app/test/b.dart')]);
      await pump(tester);

      // Depth 0 is the root, so the first folder anybody sees is depth 1 —
      // off by that one and every top-level folder opens shut, which looks
      // exactly like an empty index.
      expect(find.text('app'), findsOneWidget);
      expect(find.text('lib/deep'), findsOneWidget);

      await tester.tap(find.text('app'));
      await tester.pumpAndSettle();
      expect(find.text('lib/deep'), findsNothing);
    });
  });
}
