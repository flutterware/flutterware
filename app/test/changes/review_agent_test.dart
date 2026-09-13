import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/review_agent.dart';
import 'package:flutterware_app/src/changes/review_comment.dart';
import 'package:flutterware_app/src/changes/review_store.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// The half of the review an agent sees.
///
/// These run against a **real worktree path**, resolved the way the shipped
/// code resolves it — a sha1 of the canonicalised path under `~/.flutterware`.
/// A test that constructed the store by hand would prove the folding and not
/// the one thing that actually failed in the field: finding the log at all.
void main() {
  late Directory home;
  late Directory worktree;
  late String path;

  setUp(() {
    home = Directory.systemTemp.createTempSync('fw-home');
    worktree = Directory.systemTemp.createTempSync('wt');
    path = worktree.path;
    // What `flutterwareDir()` reads. Without it these would write into the
    // developer's own log, which is the one directory a test may not touch.
    _homeOverride(home.path);
  });
  tearDown(() {
    _homeOverride(null);
    home.deleteSync(recursive: true);
    worktree.deleteSync(recursive: true);
  });

  FileReviewStore storeFor() => FileReviewStore.forWorktree(path);

  ReviewComment note(String id, {String body = 'a note'}) => ReviewComment(
    id: id,
    anchor: const LineAnchor(
      path: 'lib/a.dart',
      from: 12,
      to: 12,
      side: ReviewSide.after,
    ),
    body: body,
    createdAt: DateTime.utc(2026, 8, 16, 10),
    quote: const ['  return null;'],
  );

  group('status', () {
    test('says where the log is, so nobody derives a hash again', () {
      // The report this whole surface answers: an agent found the log by
      // knowing the storage layout from a commit message. The path is a value
      // now.
      var status = reviewStatusJson(path);
      expect(status['log'], storeFor().file.path);
      expect(p.isWithin(home.path, status['log']! as String), isTrue);
    });

    test('counts nothing as nothing, and still says so', () {
      // A zero is what tells a reader that notes exist as a thing at all —
      // which is the half of the report that cost a day.
      expect(reviewStatusJson(path), {
        'unresolved': 0,
        'resolved': 0,
        'log': storeFor().file.path,
      });
    });

    test('counts what is outstanding, not what the log holds', () {
      storeFor().append([CommentAdded(note('a')), CommentAdded(note('b'))]);
      reviewResolveJson(path, 'a');

      var status = reviewStatusJson(path);
      expect(status['unresolved'], 1);
      expect(status['resolved'], 1);
    });
  });

  group('the list', () {
    test('is markdown with the ids in it, and the ids are what resolve', () {
      storeFor().append([CommentAdded(note('fx3k-1', body: 'no test here'))]);

      var list = reviewListJson(path, worktree: 'feature');
      var notes = list['notes']! as String;
      expect(notes, contains('## lib/a.dart:12 · `fx3k-1`'));
      expect(notes, contains('no test here'));
      // The quote rides along: the note is about code that may since have
      // moved, and this is the copy that cannot.
      expect(notes, contains('  return null;'));

      expect(reviewResolveJson(path, 'fx3k-1')['resolved'], isTrue);
    });

    test('leaves out what is resolved unless asked', () {
      storeFor().append([CommentAdded(note('a')), CommentAdded(note('b'))]);
      reviewResolveJson(path, 'a', message: 'did it');

      var outstanding = reviewListJson(path, worktree: 'f')['notes']! as String;
      expect(outstanding, contains('`b`'));
      expect(outstanding, isNot(contains('`a`')));
      var all = reviewListJson(path, worktree: 'f', all: true)['notes']!;
      expect(all, contains('`a`'));
      expect(all, contains('resolved by the agent'));
      expect(all, contains('did it'));
    });

    test('an empty review is null rather than an empty document', () {
      // A heading and a count of zero is a page that reads as *something is
      // here*. The caller says "no notes" better than the renderer can.
      expect(reviewListJson(path, worktree: 'f')['notes'], isNull);
    });
  });

  group('resolving', () {
    test('is recorded as the agent, always', () {
      // Not a parameter, and this is the assertion that keeps it that way: the
      // human reading their own screen is told who answered, and a caller that
      // could claim to be them would make that line worthless.
      storeFor().append([CommentAdded(note('a'))]);
      reviewResolveJson(path, 'a', message: 'done');

      var resolution = storeFor().read().resolved.single.resolution!;
      expect(resolution.by, ReviewActor.agent);
      expect(resolution.message, 'done');
    });

    test('unresolving puts it back', () {
      storeFor().append([CommentAdded(note('a'))]);
      reviewResolveJson(path, 'a');
      reviewResolveJson(path, 'a', resolve: false);

      expect(storeFor().read().unresolved.single.id, 'a');
    });

    test('an id that is not there refuses with the ids that are', () {
      // The usual cause is a stale list — the note was deleted while the agent
      // worked, or this is the wrong checkout's log. Both are answered by
      // saying what is actually here.
      storeFor().append([CommentAdded(note('real'))]);

      var result = reviewResolveJson(path, 'ghost');
      expect(result['error'], contains('ghost'));
      expect(result['ids'], ['real']);
      expect(storeFor().read().unresolved.single.isResolved, isFalse);
    });

    test('reports what is left, so a caller knows when it is done', () {
      storeFor().append([CommentAdded(note('a')), CommentAdded(note('b'))]);

      expect(reviewResolveJson(path, 'a')['unresolved'], 1);
      expect(reviewResolveJson(path, 'b')['unresolved'], 0);
    });
  });
}

/// Points `flutterwareDir()` at a temporary home for the duration of a test.
void _homeOverride(String? path) {
  if (path == null) {
    flutterwareDirOverride = null;
  } else {
    flutterwareDirOverride = p.join(path, '.flutterware');
  }
}
