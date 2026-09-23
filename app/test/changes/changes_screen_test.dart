import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/changes/changes_config_cache.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/ranking.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The states a happy path never produces are the point of this file: no base,
/// a refused patch, an untracked directory, and the moment before anything has
/// loaded.
void main() {
  var worktree = const Worktree(
    path: '/wt/feature',
    gitName: 'feature',
    branch: 'claude/feature',
  );

  FileChange file(
    String path, {
    ChangeStatus status = ChangeStatus.modified,
    int added = 0,
    int removed = 0,
    String? from,
    int hunks = 1,
  }) => FileChange(
    path: path,
    oldPath: from,
    status: status,
    added: added,
    removed: removed,
    hunks: [
      for (var i = 0; i < hunks; i++)
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

  Future<void> pump(
    WidgetTester tester,
    ChangeSet set, {
    Completer<void>? gate,
    bool isOpen = false,
    bool showTitle = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree,
            isOpen: isOpen,
            showTitle: showTitle,
            load: (_) async {
              if (gate != null) await gate.future;
              return set;
            },
          ),
        ),
      ),
    );
  }

  ChangeSet setOf({
    List<FileChange> files = const [],
    Set<String> uncommitted = const {},
    List<UntrackedEntry> untracked = const [],
    String? base = 'master',
    BaseSource source = BaseSource.inferred,
    Ranking? ranking,
    ChangesConfigState configState = ChangesConfigState.none,
  }) => ChangeSet(
    worktreePath: worktree.path,
    patch: PatchIndex.empty,
    files: files,
    base: base,
    baseSource: source,
    uncommitted: uncommitted,
    untracked: untracked,
    ranking: ranking,
    configState: configState,
  );

  testWidgets('says which checkout it is before anything has loaded', (
    tester,
  ) async {
    // A screen that opens on a spinner tells you nothing you did not know.
    var gate = Completer<void>();
    await pump(tester, setOf(), gate: gate);

    expect(find.text('Changes'), findsOneWidget);
    expect(find.text(worktree.displayName), findsOneWidget);
    expect(find.text('Reading…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Reading…'), findsNothing);
  });

  testWidgets('under a tab strip it names neither itself nor its base', (
    tester,
  ) async {
    // The strip above says both — `files | previews | scenarios` and
    // `against <base>` — and this screen saying them again six pixels below is
    // one delta stated twice, in two vocabularies that can be read as two.
    await pump(tester, setOf(files: [file('lib/a.dart')]), showTitle: false);
    await tester.pumpAndSettle();

    expect(find.text('Changes'), findsNothing);
    expect(find.text(worktree.displayName), findsNothing);
    expect(find.text('base master (inferred)'), findsNothing);
    // The counts stay: they are what the strip does not say.
    expect(find.text('1 files'), findsOneWidget);
  });

  testWidgets('under a tab strip a missing base is still said', (tester) async {
    // Not a duplicate of anything — it is the reason the counts beside it are
    // smaller than they look.
    await pump(
      tester,
      setOf(base: null, source: BaseSource.none),
      showTitle: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('no base'), findsOneWidget);
  });

  testWidgets('lists files with their counts, in name order', (tester) async {
    await pump(
      tester,
      setOf(
        files: [
          file('lib/big.dart', added: 140, removed: 22),
          // Additions here too, so the header's total (+145) cannot be mistaken
          // for this row's (+140) by a text finder.
          file(
            'lib/gone.dart',
            status: ChangeStatus.deleted,
            added: 5,
            removed: 88,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('gone.dart'), findsOneWidget);
    expect(find.text('big.dart'), findsOneWidget);
    expect(find.text('+140'), findsOneWidget);
    expect(find.text('-88'), findsOneWidget);

    // By name. The deletion used to be promoted to the top of its folder; the
    // `D` at the row says it without moving the row.
    expect(
      tester.getTopLeft(find.text('big.dart')).dy,
      lessThan(tester.getTopLeft(find.text('gone.dart')).dy),
    );
  });

  testWidgets('the summary says what is uncommitted and the index does not; '
      'a rename says where from', (tester) async {
    await pump(
      tester,
      setOf(
        files: [
          file('lib/a.dart', added: 1),
          file(
            'lib/new.dart',
            status: ChangeStatus.renamed,
            from: 'lib/old.dart',
          ),
        ],
        uncommitted: {'lib/a.dart'},
      ),
    );
    await tester.pumpAndSettle();

    // **The rows do not repeat it.** Whether a file is committed yet is a fact
    // about the reader's git state rather than about the change, and the index
    // is what you scan to decide which file to open. Scoped to the index,
    // because the summary does say it — an unscoped finder here would pass off
    // the summary and test nothing.
    expect(
      find.descendant(
        of: find.byKey(changesListKey),
        matching: find.textContaining('uncommitted'),
      ),
      findsNothing,
    );
    // And the summary is still where the count lives, so dropping it from the
    // rows did not drop it from the screen.
    expect(find.textContaining('1 uncommitted'), findsOneWidget);
    expect(find.textContaining('from lib/old.dart'), findsOneWidget);

    // Both files live under one directory, and the tree says so once rather
    // than repeating it on every row.
    expect(
      find.descendant(
        of: find.byKey(changesListKey),
        matching: find.text('lib'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the base and where it came from are always shown', (
    tester,
  ) async {
    await pump(tester, setOf(files: [file('a.dart')]));
    await tester.pumpAndSettle();
    expect(find.text('base master (inferred)'), findsOneWidget);
  });

  testWidgets('no base explains itself rather than diffing against a guess', (
    tester,
  ) async {
    await pump(
      tester,
      setOf(files: [file('a.dart')], base: null, source: BaseSource.none),
    );
    await tester.pumpAndSettle();

    expect(find.text('no base'), findsOneWidget);
    expect(find.textContaining('none of origin/HEAD'), findsOneWidget);
  });

  testWidgets('an untracked directory is one row and is never counted', (
    tester,
  ) async {
    // The branch-switch trap, at the widget layer: a count would be the
    // directory walk that keeping this to one row exists to avoid.
    await pump(
      tester,
      setOf(
        files: [file('a.dart')],
        untracked: const [UntrackedEntry.directory('packages/newpkg/build/')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('packages/newpkg/build/'), findsOneWidget);
    expect(find.text('directory, not scanned'), findsOneWidget);
    expect(find.textContaining('files'), findsWidgets); // the header only
  });

  testWidgets('a clean checkout says so instead of showing an empty page', (
    tester,
  ) async {
    await pump(tester, setOf());
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Nothing changed against master'),
      findsOneWidget,
    );
  });

  testWidgets('a failed read keeps the last good answer beside the reason', (
    tester,
  ) async {
    var fail = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree,
            load: (_) async {
              if (fail) throw StateError('the checkout vanished');
              return setOf(files: [file('lib/a.dart', added: 3)]);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a.dart'), findsOneWidget);

    fail = true;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.textContaining('the checkout vanished'), findsOneWidget);
    expect(
      find.text('a.dart'),
      findsOneWidget,
      reason: 'a failed reload must not blank what it last said',
    );
  });

  group('ranking, on screen', () {
    Ranking rankingOf(List<FileChange> files, Map<String, RankTier> tiers) =>
        Ranking([
          for (var file in files)
            RankedFile(
              file: file,
              tier: tiers[file.path] ?? RankTier.ordinary,
              rule: tiers.containsKey(file.path) ? '**/migrations/**' : null,
            ),
        ]);

    testWidgets('the screen opens on what a rule pinned', (tester) async {
      // **The alert is not something you navigate to.** A tab hides what it
      // holds half the time, so the half it is hidden in is the half where it
      // is empty: a checkout with a pin opens on the pin.
      var files = [
        file('lib/huge.dart', added: 900, removed: 900),
        file('db/migrations/1.sql', added: 2, removed: 0),
      ];
      await pump(
        tester,
        setOf(
          files: files,
          ranking: rankingOf(files, {
            'db/migrations/1.sql': RankTier.attention,
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1.sql'), findsOneWidget);
      expect(find.textContaining('matches **/migrations/**'), findsOneWidget);
      // The 1800-line file is not on this tab at all, which is the whole claim:
      // every other ordering of these two puts it first.
      expect(find.text('huge.dart'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('huge.dart'), findsOneWidget);
      // …and the pin is flagged in the tree, where it lives.
      expect(find.text('1.sql'), findsOneWidget);
      expect(
        tester
            .widgetList<IndexFileRow>(find.byType(IndexFileRow))
            .where((r) => r.pinned),
        hasLength(1),
      );
    });

    testWidgets('a stale config is said out loud', (tester) async {
      await pump(
        tester,
        setOf(
          files: [file('lib/a.dart')],
          configState: ChangesConfigState.stale,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('changed since'), findsOneWidget);
    });

    testWidgets('a fresh one says nothing at all', (tester) async {
      // A screen that narrates its cache on every load is one whose important
      // message goes unread.
      await pump(
        tester,
        setOf(
          files: [file('lib/a.dart')],
          configState: ChangesConfigState.fresh,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('changed since'), findsNothing);
    });

    testWidgets('the header total is every file, whatever a tab shows', (
      tester,
    ) async {
      // The tab is a view, never a subtraction. A header that agreed with the
      // list it happens to be over would make the ranking something that can
      // lose a file.
      var files = [
        file('lib/real.dart', added: 1),
        file('a.g.dart', added: 1),
        file('b.g.dart', added: 1),
      ];
      await pump(
        tester,
        setOf(
          files: files,
          ranking: rankingOf(files, {'lib/real.dart': RankTier.attention}),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('3 files'), findsOneWidget);
      // Opened on Important, which is one row of the three.
      expect(find.text('real.dart'), findsOneWidget);
      expect(find.text('a.g.dart'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('a.g.dart'), findsOneWidget);
    });
  });
}
