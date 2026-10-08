import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_rows.dart';
import 'package:flutterware_app/src/changes/diff_lines.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/review_comment.dart';
import 'package:flutterware_app/src/changes/review_store.dart';

/// The half of the review that has no widgets in it: what a log folds to, what
/// leaves in the handoff, and where a comment lands in a diff.
void main() {
  ReviewComment comment(
    String id, {
    ReviewAnchor? anchor,
    String body = 'note',
    List<String> quote = const [],
    String? digest,
  }) => ReviewComment(
    id: id,
    anchor:
        anchor ??
        const LineAnchor(
          path: 'lib/a.dart',
          from: 1,
          to: 1,
          side: ReviewSide.after,
        ),
    body: body,
    createdAt: DateTime.utc(2026, 8, 14, 10, 30),
    quote: quote,
    fileDigest: digest,
  );

  CommentResolved resolved(
    String id, {
    ReviewActor by = ReviewActor.human,
    String? message,
    DateTime? at,
  }) => CommentResolved(
    id: id,
    resolution: ReviewResolution(
      by: by,
      at: at ?? DateTime.utc(2026, 8, 14, 11),
      message: message,
    ),
  );

  group('folding a log', () {
    test('adds accumulate in the order they were written', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
      ]);

      expect(state.unresolved.map((c) => c.id), ['a', 'b']);
      expect(state.resolved, isEmpty);
    });

    test('an edit rewrites the body and keeps the place', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
        const CommentEdited(id: 'a', body: 'rewritten'),
      ]);

      expect(state.unresolved.map((c) => c.id), ['a', 'b']);
      expect(state.unresolved.first.body, 'rewritten');
    });

    test('a delete is a tombstone, not a rewrite of the file', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
        const CommentDeleted('a'),
      ]);

      expect(state.unresolved.map((c) => c.id), ['b']);
    });

    test('resolving moves a note without taking it out of the log', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
        resolved('a', by: ReviewActor.agent, message: 'did it'),
      ]);

      expect(state.unresolved.map((c) => c.id), ['b']);
      expect(state.resolved.map((c) => c.id), ['a']);
      expect(state.resolved.single.resolution!.by, ReviewActor.agent);
      expect(state.resolved.single.resolution!.message, 'did it');
      // The quote and the anchor are the note's, not the resolution's: an
      // answered note is still about the code it was written on.
      expect(state.resolved.single.anchor.path, 'lib/a.dart');
    });

    test('unresolving puts it back where it was', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
        resolved('a'),
        const CommentUnresolved('a'),
      ]);

      // Back in the numbering, and in its original place — the order is the
      // order they were written, which resolving does not touch.
      expect(state.unresolved.map((c) => c.id), ['a', 'b']);
      expect(state.resolved, isEmpty);
    });

    test('newest answer first, because that is the one you have not read', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
        resolved('a', at: DateTime.utc(2026, 8, 14, 10)),
        resolved('b', at: DateTime.utc(2026, 8, 14, 11)),
      ]);

      expect(state.resolved.map((c) => c.id), ['b', 'a']);
    });

    test('a resolution of a note that is gone changes nothing', () {
      // The agent answering a note you deleted while it worked. It is not an
      // error and it is not a resurrection: the note is gone.
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        const CommentDeleted('a'),
        resolved('a'),
      ]);

      expect(state.isEmpty, isTrue);
    });

    test('a line this version does not understand costs that line only', () {
      var lines = [
        CommentAdded(comment('a')).encode(),
        '{"event":"reacted","emoji":"🎉"}',
        'not json at all',
        CommentAdded(comment('b')).encode(),
      ];

      var events = [for (var line in lines) ?ReviewEvent.decode(line)];
      expect(ReviewState.fold(events).unresolved.map((c) => c.id), ['a', 'b']);
    });
  });

  group('what the agent resolved while you were away', () {
    test('an agent resolution after the marker is unseen', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        ReviewSeen(DateTime.utc(2026, 8, 14, 10)),
        resolved('a', by: ReviewActor.agent, at: DateTime.utc(2026, 8, 14, 11)),
      ]);

      expect(state.unseenResolutions.map((c) => c.id), ['a']);
    });

    test('and is seen once the marker passes it', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        resolved('a', by: ReviewActor.agent, at: DateTime.utc(2026, 8, 14, 11)),
        ReviewSeen(DateTime.utc(2026, 8, 14, 12)),
      ]);

      expect(state.unseenResolutions, isEmpty);
    });

    test('your own resolutions are never unseen', () {
      // You do not need telling about a note you ticked off yourself — and if
      // they counted, the tab would carry an alert for your own click.
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        resolved('a', at: DateTime.utc(2026, 8, 14, 11)),
      ]);

      expect(state.unseenResolutions, isEmpty);
    });

    test('a log nobody has looked at yet has every agent answer unseen', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        resolved('a', by: ReviewActor.agent),
      ]);

      expect(state.unseenResolutions.map((c) => c.id), ['a']);
    });
  });

  group('a log written by the version that handed off batches', () {
    // **The one migration that has to ship with the fold.** Every note ever
    // handed off would otherwise come back as outstanding on first launch —
    // for a log of any age, that is all of them.
    ReviewEvent legacy(List<String> ids) => ReviewEvent.decode(
      jsonEncode({
        'event': 'handoff',
        'batch': 'b1',
        'ids': ids,
        'at': DateTime.utc(2026, 8, 14, 11).toIso8601String(),
        'route': 'copy',
        'savedTo': '/tmp/review.md',
      }),
    )!;

    test('a handed-off batch reads as resolved, by you, when it left', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        CommentAdded(comment('b')),
        legacy(['a']),
      ]);

      expect(state.unresolved.map((c) => c.id), ['b']);
      expect(state.resolved.single.id, 'a');
      expect(state.resolved.single.resolution!.by, ReviewActor.human);
      expect(
        state.resolved.single.resolution!.at,
        DateTime.utc(2026, 8, 14, 11),
      );
      // And it does not light the tab up: an export you made months ago is not
      // an answer you have not read.
      expect(state.unseenResolutions, isEmpty);
    });

    test('and can be reopened like any other', () {
      var state = ReviewState.fold([
        CommentAdded(comment('a')),
        legacy(['a']),
        const CommentUnresolved('a'),
      ]);

      expect(state.unresolved.map((c) => c.id), ['a']);
    });

    test('a handoff is never written back', () {
      expect(
        () => BatchHandedOff(ids: const ['a'], at: DateTime.utc(2026)).encode(),
        throwsUnsupportedError,
      );
    });
  });

  group('the store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('review'));
    tearDown(() => dir.deleteSync(recursive: true));

    ReviewStore storeIn(Directory at) =>
        ReviewStore(File('${at.path}/review.jsonl'));

    test('appending survives a round trip through the file', () {
      storeIn(dir).append([
        CommentAdded(comment('a', quote: ['var x = 1;'])),
      ]);

      var read = storeIn(dir).read();
      expect(read.unresolved.single.id, 'a');
      expect(read.unresolved.single.quote, ['var x = 1;']);
    });

    test("another window's line is folded in, not clobbered", () {
      // The whole reason this is a log rather than a document: two writers,
      // and neither one can revert the other.
      var mine = storeIn(dir)..append([CommentAdded(comment('mine'))]);
      storeIn(dir).append([CommentAdded(comment('theirs'))]);

      var after = mine.append([CommentAdded(comment('mine-2'))]);
      expect(after.unresolved.map((c) => c.id), ['mine', 'theirs', 'mine-2']);
    });

    test('a log that will not parse is an empty log', () {
      File('${dir.path}/review.jsonl').writeAsStringSync(' garbage');
      expect(storeIn(dir).read().isEmpty, isTrue);
    });

    test('two ids from one process do not collide', () {
      expect(newReviewId(), isNot(newReviewId()));
    });
  });

  group('the markdown', () {
    test('the export carries no ids, and the agent list does', () {
      // The id is what `resolve` is addressed by, and a serial number in the
      // middle of a sentence is noise to a reader who cannot act on one.
      var comments = [comment('fx3k-1')];
      expect(
        reviewMarkdown(comments, worktree: 'feature'),
        isNot(contains('fx3k-1')),
      );
      expect(
        reviewMarkdown(comments, worktree: 'feature', withIds: true),
        contains('## lib/a.dart:1 · `fx3k-1`'),
      );
    });

    test('an answered note carries who answered it and what they said', () {
      var text = reviewMarkdown([
        comment('a').withResolution(
          ReviewResolution(
            by: ReviewActor.agent,
            at: DateTime.utc(2026, 8, 14, 11, 30),
            message: 'the test at foo_test.dart:88 covers this',
          ),
        ),
      ], worktree: 'feature');

      expect(
        text,
        contains(
          '— resolved by the agent at 11:30: '
          'the test at foo_test.dart:88 covers this',
        ),
      );
    });

    test('a line comment carries its anchor, its quote and its words', () {
      var text = reviewMarkdown(
        [
          comment(
            'a',
            body: 'Hoist this out of the loop.',
            quote: ['  for (var x in xs) {', '    build(x);'],
          ),
        ],
        worktree: 'feature',
        base: 'master',
        at: DateTime.utc(2026, 8, 14, 9, 5),
      );

      expect(text, contains('# Review — feature'));
      expect(text, contains('Against `master` · 1 comment · 09:05'));
      expect(text, contains('## lib/a.dart:1'));
      expect(text, contains('```dart'));
      expect(text, contains('  for (var x in xs) {'));
      expect(text, contains('Hoist this out of the loop.'));
    });

    test('a span reads as a span, and a file and a review as themselves', () {
      var text = reviewMarkdown([
        comment(
          'a',
          anchor: const LineAnchor(
            path: 'lib/a.dart',
            from: 10,
            to: 14,
            side: ReviewSide.after,
          ),
        ),
        comment('b', anchor: const FileAnchor('test/a_test.dart')),
        comment('c', anchor: const ReviewWide()),
      ], worktree: 'feature');

      expect(text, contains('## lib/a.dart:10–14'));
      expect(text, contains('## test/a_test.dart'));
      expect(text, contains('## Whole review'));
    });

    test('a fence is unlabelled rather than mislabelled', () {
      var text = reviewMarkdown([
        comment(
          'a',
          anchor: const FileAnchor('Makefile'),
          quote: const ['all:'],
        ),
      ], worktree: 'feature');

      expect(text, contains('```\nall:\n```'));
    });

    test('a drifted file says so above its quote', () {
      var text = reviewMarkdown(
        [
          comment('a', quote: const ['old line']),
        ],
        worktree: 'feature',
        drifted: const {'lib/a.dart'},
      );

      expect(text, contains('⚠ This file has changed'));
      expect(text, contains('old line'));
    });
  });

  group('placing a comment in a diff', () {
    var patch = [
      'diff --git a/lib/a.dart b/lib/a.dart',
      '--- a/lib/a.dart',
      '+++ b/lib/a.dart',
      '@@ -1,4 +1,5 @@',
      ' one',
      '-two was',
      '+two is',
      '+two and a half',
      ' three',
      ' four',
      '',
    ].join('\n');

    late FileChange file;
    late HunkLineCache lines;

    setUp(() {
      var index = indexPatch(Uint8List.fromList(utf8.encode(patch)));
      file = index.files.single;
      lines = HunkLineCache(index);
    });

    test('a new-side line lands on its own row', () {
      var spot = spotOf(file, 3, ReviewSide.after, lines.linesFor)!;
      var rows = buildFileRows(
        file,
        placed: {
          spot: [CommentRow(comment('a'))],
        },
      );

      var index = rows.indexWhere((r) => r is CommentRow);
      var before = rows[index - 1] as DiffLineRow;
      expect(lines.linesFor(before.hunk)[before.index].text, 'two and a half');
    });

    test('an old-side line is a different row from the same number', () {
      // Line 2 is `two was` on the left and `two is` on the right — a comment
      // that ignored the side would land on the wrong one.
      var before = spotOf(file, 2, ReviewSide.before, lines.linesFor)!;
      var after = spotOf(file, 2, ReviewSide.after, lines.linesFor)!;
      expect(before, isNot(after));

      expect(lines.linesFor(file.hunks.single)[before.index].text, 'two was');
      expect(lines.linesFor(file.hunks.single)[after.index].text, 'two is');
    });

    test('a line no longer in the diff has no spot', () {
      expect(spotOf(file, 900, ReviewSide.after, lines.linesFor), isNull);
    });

    test('a quote is the span, without the diff markers', () {
      expect(quoteFor(file, 2, 3, ReviewSide.after, lines.linesFor), [
        'two is',
        'two and a half',
      ]);
    });

    test('a file comment draws above the first hunk', () {
      var rows = buildFileRows(file, fileComments: [CommentRow(comment('a'))]);
      expect(rows.first, isA<CommentRow>());
      expect(rows[1], isA<HunkRow>());
    });

    test('the composer sits under the line it is about', () {
      var spot = spotOf(file, 1, ReviewSide.after, lines.linesFor)!;
      var rows = buildFileRows(
        file,
        composer: {
          spot: const ComposerRow(
            LineAnchor(
              path: 'lib/a.dart',
              from: 1,
              to: 1,
              side: ReviewSide.after,
            ),
          ),
        },
      );

      var index = rows.indexWhere((r) => r is ComposerRow);
      expect(rows[index - 1], isA<DiffLineRow>());
    });
  });

  group('the drift fingerprint', () {
    test('is over the file, so an edit elsewhere does not move it', () {
      var a = digestOfPatchSlice(utf8.encode('diff --git a/lib/a.dart\n+x\n'));
      var b = digestOfPatchSlice(utf8.encode('diff --git a/lib/a.dart\n+x\n'));
      var c = digestOfPatchSlice(utf8.encode('diff --git a/lib/a.dart\n+y\n'));

      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('anchors', () {
    test('the short form keeps the name and the line', () {
      const anchor = LineAnchor(
        path: 'app/lib/src/changes/path_glob.dart',
        from: 3,
        to: 3,
        side: ReviewSide.after,
      );
      expect(anchor.label, 'app/lib/src/changes/path_glob.dart:3');
      expect(anchor.shortLabel, 'path_glob.dart:3');
      expect(anchor.directory, 'app/lib/src/changes/');
    });

    test('a review-wide anchor names no file at all', () {
      const anchor = ReviewWide();
      expect(anchor.path, isNull);
      expect(anchor.directory, isNull);
      expect(anchor.shortLabel, 'Whole review');
    });

    test('every anchor survives its own json', () {
      for (var anchor in const <ReviewAnchor>[
        LineAnchor(path: 'lib/a.dart', from: 2, to: 9, side: ReviewSide.before),
        FileAnchor('lib/b.dart'),
        ReviewWide(),
      ]) {
        var back = ReviewAnchor.fromJson(
          jsonDecode(jsonEncode(anchor.toJson())) as Map<String, Object?>,
        );
        expect(back.label, anchor.label);
        expect(back.runtimeType, anchor.runtimeType);
      }
    });
  });
}
