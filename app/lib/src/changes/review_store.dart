/// Where review comments live between launches.
///
/// An append-only log, one file per checkout. Not a field in
/// `worktrees.json`: that file is read-whole and written-whole by every
/// flutterware process on the repository, and it has a documented history of
/// one window reverting another's writes. An appended line cannot revert
/// another appended line — the failure mode is bounded to *my window has not
/// noticed yours yet*, which a re-read fixes, rather than *your six comments
/// are gone*, which nothing fixes.
///
/// Keyed by the worktree rather than by the repository. Elsewhere in the app that
/// would be the wrong way round — per-project identity keys on the main
/// checkout — but a review is of *this* branch's delta against *its* base.
/// Two worktrees of one repository are two different reviews, and merging them
/// into one list would be the same mistake as merging their diffs.
///
/// Outside the checkout, like every other cache here: a review file written
/// into the worktree would show up as an untracked row on the very screen it
/// belongs to.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';
import 'review_comment.dart';

/// The log for one checkout: what it says, and a way to add to it.
///
/// The file is the log — see [FileReviewStore]. The interface is here for the
/// studio's recordings, which draw the screen over a checkout that does not
/// exist and keep the notes taken on it for the session: [MemoryReviewStore].
abstract class ReviewStore {
  /// The file log at [file].
  factory ReviewStore(File file) = FileReviewStore;

  /// `~/.flutterware/<sha1 of the worktree path>/review.jsonl`.
  factory ReviewStore.forWorktree(String worktreePath) =
      FileReviewStore.forWorktree;

  /// Everything the log says, folded.
  ///
  /// Never throws. A log that will not parse is an empty log — the same
  /// rule the facts cache follows, and for a stronger reason: this screen is
  /// how you look at a checkout, and refusing to draw it because a note file
  /// was truncated would be a worse program than one that had never stored
  /// notes.
  ReviewState read();

  /// Appends [events] and returns the log as it now reads.
  ReviewState append(List<ReviewEvent> events);
}

/// The log kept between launches: an append-only file outside the checkout.
class FileReviewStore implements ReviewStore {
  FileReviewStore(this.file);

  FileReviewStore.forWorktree(String worktreePath)
    : file = File(fileFor(worktreePath));

  static String fileFor(String worktreePath) => p.join(
    flutterwareDir(),
    sha1.convert(utf8.encode(p.canonicalize(worktreePath))).toString(),
    'review.jsonl',
  );

  final File file;

  @override
  ReviewState read() => ReviewState.fold(_events());

  Iterable<ReviewEvent> _events() sync* {
    List<String> lines;
    try {
      if (!file.existsSync()) return;
      lines = const LineSplitter().convert(file.readAsStringSync());
    } on Object {
      return;
    }
    for (var line in lines) {
      if (line.trim().isEmpty) continue;
      if (ReviewEvent.decode(line) case var event?) yield event;
    }
  }

  /// The re-read is deliberate: it folds in whatever another window appended
  /// since this one last looked, at no cost worth measuring — these files are
  /// kilobytes, and this runs when you press a button rather than per frame.
  @override
  ReviewState append(List<ReviewEvent> events) {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        events.map((e) => '${e.encode()}\n').join(),
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // A read-only home, or a disk that just filled. The comment stays on
      // screen for this session either way — losing what you typed because the
      // log could not be written would be the worst possible response.
    }
    return read();
  }
}

/// A log that lives as long as the process.
///
/// What a recording's screen writes to: the notes taken on it work — they
/// fold, resolve and export like any other — and are gone with the page. The
/// same events, the same fold, no file.
class MemoryReviewStore implements ReviewStore {
  final _events = <ReviewEvent>[];

  @override
  ReviewState read() => ReviewState.fold(_events);

  @override
  ReviewState append(List<ReviewEvent> events) {
    _events.addAll(events);
    return read();
  }
}

/// A fresh comment id.
///
/// Time plus a per-process counter: unique inside one window by the counter,
/// and across windows by the microsecond, which two of them do not share.
String newReviewId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '-${(_counter++).toRadixString(36)}';

int _counter = 0;
