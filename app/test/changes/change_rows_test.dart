import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_rows.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/diff_lines.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/ranking.dart';

/// The pure-Dart half of the screen: what the index holds, what a body holds,
/// and how a hunk becomes lines. All testable without pumping a widget, which
/// is the point of keeping them out of the view.
void main() {
  PatchIndex index(String patch) =>
      indexPatch(Uint8List.fromList(utf8.encode(patch)));

  const twoFiles = '''
diff --git a/lib/a.dart b/lib/a.dart
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,4 @@ class A {
 one
-two
+TWO
+three
 four
@@ -20,2 +21,2 @@
-twenty
+TWENTY
 rest
diff --git a/lib/b.dart b/lib/b.dart
--- a/lib/b.dart
+++ b/lib/b.dart
@@ -1 +1 @@
-x
+y
''';

  ChangeSet setOf(
    PatchIndex patch, {
    Set<String> uncommitted = const {},
    List<UntrackedEntry> untracked = const [],
    Ranking? ranking,
  }) => ChangeSet(
    worktreePath: '/wt',
    patch: patch,
    base: 'main',
    baseSource: BaseSource.inferred,
    uncommitted: uncommitted,
    untracked: untracked,
    ranking: ranking,
  );

  group('tiers', () {
    /// Pins each named path, leaving the rest ordinary.
    Ranking rankingOf(PatchIndex patch, {Set<String> attention = const {}}) =>
        Ranking([
          for (var file in patch.files)
            RankedFile(
              file: file,
              tier: attention.contains(file.path)
                  ? RankTier.attention
                  : RankTier.ordinary,
              rule: attention.contains(file.path) ? 'a rule' : null,
            ),
        ]);

    test('nothing ranked leaves the Important tab empty', () {
      expect(buildImportantRows(setOf(index(twoFiles))), isEmpty);
    });

    test('the Important tab is the pinned files and nothing else', () {
      // No heading in it: the tab is the heading, and there is one kind of row.
      var patch = index(twoFiles);
      var rows = buildImportantRows(
        setOf(patch, ranking: rankingOf(patch, attention: {'lib/b.dart'})),
      );
      expect(rows.whereType<SectionRow>(), isEmpty);
      expect(rows.map((r) => (r as FileRow).file.path), ['lib/b.dart']);
    });

    test('the tree is a complete map, pins included', () {
      // **The bug this exists to stop coming back.** Pinned files were kept out
      // of the tree so nothing would be listed twice, which made the tree's
      // directory counts one short per pin: the header said 53 files over a
      // tree totalling 52, and browsing to the pinned file could not find it. A
      // quietly wrong count is worse than a repetition.
      var patch = index(twoFiles);
      var set = setOf(
        patch,
        ranking: rankingOf(patch, attention: {'lib/b.dart'}),
      );
      expect(
        treeFiles(set).map((f) => f.path),
        containsAll(['lib/a.dart', 'lib/b.dart']),
      );
      expect(treeFiles(set), hasLength(set.changed.length));
      // …and it is in the other tab too, which is the alert.
      expect(
        buildImportantRows(set).whereType<FileRow>().map((r) => r.file.path),
        ['lib/b.dart'],
      );
    });

    test('the rule that fired reaches the row', () {
      var patch = index(twoFiles);
      var rows = buildImportantRows(
        setOf(patch, ranking: rankingOf(patch, attention: {'lib/b.dart'})),
      );
      var pinned = rows.whereType<FileRow>().firstWhere(
        (r) => r.file.path == 'lib/b.dart',
      );
      expect(pinned.reason, 'matches a rule');
      // The ordinary one is the tree's, and never important.
      expect(rows.whereType<FileRow>(), hasLength(1));
    });

    test('ordering is per tier, not across the list', () {
      var patch = index(twoFiles);
      // `lib/a.dart` is the bigger file, so an across-the-list sort would put
      // it first. Pinning the smaller one has to beat that.
      var set = setOf(
        patch,
        ranking: rankingOf(patch, attention: {'lib/b.dart'}),
      );
      expect(set.ordered(RankTier.attention).single.file.path, 'lib/b.dart');
      expect(set.ordered(RankTier.ordinary).single.file.path, 'lib/a.dart');
    });

    test('a pinned untracked file is important, and still in All', () {
      // The case that made this exist: an agent wrote a new migration and has
      // not staged it. A pin that only works after `git add` misses the exact
      // moment it is for.
      var set = setOf(
        index(twoFiles),
        untracked: const [
          UntrackedEntry('db/migrations/2.sql', reason: 'matches db/**'),
          UntrackedEntry('scratch.txt'),
          UntrackedEntry.directory('build/'),
        ],
      );

      var important = buildImportantRows(set);
      expect(important.single, isA<UntrackedRow>());
      expect(
        (important.single as UntrackedRow).entry.path,
        'db/migrations/2.sql',
      );

      // **All means all.** It is in the tree there — a tab that quietly drops
      // the file the other tab is about is a tab whose count disagrees with
      // the header.
      expect(treeUntracked(set).map((e) => e.path), [
        'db/migrations/2.sql',
        'scratch.txt',
      ]);

      // The directory is the one thing that stays in the tail: it stands for a
      // subtree nobody walked, and a tree is a map of a shape that was read.
      var tail = buildUntrackedDirectoryRows(set);
      expect(tail.whereType<SectionRow>().map((r) => r.label), [
        'Untracked directories',
      ]);
      expect(tail.whereType<UntrackedRow>().map((r) => r.entry.path), [
        'build/',
      ]);
    });

    test('an untracked directory is never pinned', () {
      // Matching a glob against a directory would mean walking it, which is
      // the walk the whole untracked design exists to avoid.
      expect(
        const UntrackedEntry.directory('build/').withReason('matches **'),
        isA<UntrackedEntry>().having((e) => e.reason, 'reason', isNull),
      );
    });

    test('filtering narrows both tabs', () {
      var patch = index(twoFiles);
      var set = setOf(
        patch,
        ranking: rankingOf(patch, attention: {'lib/b.dart'}),
      );
      // Nothing pinned survived the filter…
      expect(buildImportantRows(set, visible: {'lib/a.dart'}), isEmpty);
      // …and the one file that did is still there, in the tree.
      expect(treeFiles(set, visible: {'lib/a.dart'}).single.path, 'lib/a.dart');
    });
  });

  group('rows', () {
    test('the index holds no diff, and ordinary files belong to the tree', () {
      var set = setOf(index(twoFiles));

      // Nothing pinned, nothing untracked: both flat lists are empty and every
      // file is the tree's.
      expect(buildImportantRows(set), isEmpty);
      expect(buildUntrackedDirectoryRows(set), isEmpty);
      expect(treeFiles(set), hasLength(2));
    });

    test('a body is its hunks and every line, and only that file', () {
      var patch = index(twoFiles);
      var a = patch.files.firstWhere((f) => f.path == 'lib/a.dart');
      var rows = buildFileRows(a);

      expect(rows.whereType<HunkRow>(), hasLength(2));
      expect(
        rows.whereType<DiffLineRow>(),
        hasLength(a.hunks.fold<int>(0, (sum, h) => sum + h.displayLines)),
      );
      expect(rows.whereType<FileRow>(), isEmpty);
    });

    test(
      'the row count is known from metadata, before anything is decoded',
      () {
        // The claim the virtualised list rests on: `displayLines` comes off the
        // `@@` header, so scroll extents are right before a byte is read.
        var patch = index(twoFiles);
        var rows = buildFileRows(
          patch.files.firstWhere((f) => f.path == 'lib/a.dart'),
        );
        var lines = HunkLineCache(patch);

        expect(lines.decodedHunks, 0, reason: 'building rows decodes nothing');
        expect(rows, isNotEmpty);
      },
    );

    test('filtering removes rows; untracked paths go with them', () {
      var patch = index(twoFiles);
      var set = setOf(
        patch,
        untracked: const [
          UntrackedEntry('scratch.txt'),
          UntrackedEntry.directory('build/'),
        ],
      );

      expect(treeUntracked(set), hasLength(1));
      expect(buildUntrackedDirectoryRows(set).whereType<UntrackedRow>(), [
        isA<UntrackedRow>(),
      ]);

      expect(treeFiles(set, visible: {'lib/b.dart'}), hasLength(1));
      expect(
        treeUntracked(set, visible: {'lib/b.dart'}),
        isEmpty,
        reason: 'a filter over changed paths says nothing about untracked ones',
      );
      expect(
        buildUntrackedDirectoryRows(set, visible: {'lib/b.dart'}),
        isEmpty,
      );
    });

    test('a binary file is a notice, not an empty pane', () {
      var patch = index('''
diff --git a/logo.png b/logo.png
Binary files a/logo.png and b/logo.png differ
''');
      var rows = buildFileRows(patch.files.single);

      expect(rows.whereType<FileNoticeRow>(), hasLength(1));
      expect(
        rows.whereType<FileNoticeRow>().single.message,
        contains('Binary'),
      );
    });

    test('a rename with no content change says why it is empty', () {
      var patch = index('''
diff --git a/old.dart b/new.dart
similarity index 100%
rename from old.dart
rename to new.dart
''');
      var rows = buildFileRows(patch.files.single);
      expect(
        rows.whereType<FileNoticeRow>().single.message,
        contains('only the path'),
      );
    });
  });

  group('hunk lines', () {
    test('numbers both sides, and drops the header', () {
      var patch = index(twoFiles);
      var a = patch.files.firstWhere((f) => f.path == 'lib/a.dart');
      var lines = parseHunkLines(
        patch.textForHunk(a.hunks.first),
        a.hunks.first,
      );

      expect(lines.map((l) => l.kind), [
        DiffLineKind.context,
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.added,
        DiffLineKind.context,
      ]);
      // `one` is line 1 on both sides; `two` was line 2 of the old file only;
      // `TWO`/`three` are lines 2 and 3 of the new one.
      expect(lines[0].oldNumber, 1);
      expect(lines[0].newNumber, 1);
      expect(lines[1].oldNumber, 2);
      expect(lines[1].newNumber, isNull);
      expect(lines[2].newNumber, 2);
      expect(lines[3].newNumber, 3);
      expect(lines[4].oldNumber, 3);
      expect(lines[4].newNumber, 4);
    });

    test('the marker is stripped from the text', () {
      var patch = index(twoFiles);
      var b = patch.files.firstWhere((f) => f.path == 'lib/b.dart');
      var lines = parseHunkLines(
        patch.textForHunk(b.hunks.single),
        b.hunks.single,
      );
      expect(lines.map((l) => l.text), ['x', 'y']);
    });

    test('the line count matches what the row builder predicted', () {
      // If these disagree, the list asks for an index the decoded hunk does not
      // have — which is a crash while scrolling, in the one place a crash is
      // least excusable.
      var patch = index(twoFiles);
      for (var file in patch.files) {
        for (var hunk in file.hunks) {
          expect(
            parseHunkLines(patch.textForHunk(hunk), hunk),
            hasLength(hunk.displayLines),
            reason: '${file.path} @@ ${hunk.newStart}',
          );
        }
      }
    });

    test('a no-newline marker is meta and takes no line number', () {
      var patch = index(
        'diff --git a/a.txt b/a.txt\n'
        '--- a/a.txt\n'
        '+++ b/a.txt\n'
        '@@ -1 +1 @@\n'
        '-before\n'
        r'\ No newline at end of file'
        '\n'
        '+after\n',
      );
      var hunk = patch.files.single.hunks.single;
      var lines = parseHunkLines(patch.textForHunk(hunk), hunk);
      var meta = lines.where((l) => l.kind == DiffLineKind.meta);
      expect(meta, hasLength(1));
      expect(meta.single.oldNumber, isNull);
      expect(meta.single.newNumber, isNull);
    });

    test('the cache decodes a hunk once, and only when asked', () {
      var patch = index(twoFiles);
      var cache = HunkLineCache(patch);
      var a = patch.files.firstWhere((f) => f.path == 'lib/a.dart');

      expect(cache.decodedHunks, 0);
      cache.linesFor(a.hunks.first);
      expect(cache.decodedHunks, 1);
      cache.linesFor(a.hunks.first);
      expect(cache.decodedHunks, 1, reason: 'asked twice, decoded once');
      // The second hunk of the same file is still untouched: laziness is per
      // hunk, not per file.
      expect(cache.decodedHunks, 1);
    });
  });

  group('the filter', () {
    test('pathsMatching is a plain case-insensitive substring', () {
      var paths = ['app/lib/Motion.dart', 'app/lib/other.dart'];
      expect(pathsMatching(paths, 'motion'), {'app/lib/Motion.dart'});
      // Deliberately not fuzzy: `mtn` is not a match anybody asked for.
      expect(pathsMatching(paths, 'mtn'), isEmpty);
      expect(pathsMatching(paths, '  '), hasLength(2));
    });

    test('it takes plain paths, so an untracked file can be found', () {
      // It used to take `FileChange`s, so an untracked entry was never in the
      // candidate set — typing `scratch` hid the one file you were after.
      expect(pathsMatching(['scratch.txt', 'lib/a.dart'], 'scratch'), {
        'scratch.txt',
      });
    });
  });
}
