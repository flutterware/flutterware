/// The screen's two lists, each flattened to one row per drawable line.
///
/// An index and a body, never one list doing both. They used to be the
/// same list: file rows that expanded to inject their own diff between
/// themselves and the next file. That made the thing you navigate with and the
/// thing you read the same surface, and every complaint about this screen came
/// out of it — clicking a name scrolled instead of opening, a live re-index
/// moved the lines you were reading, and getting to the next file meant
/// scrolling through the last one's diff.
///
/// So [buildImportantRows] and [buildUntrackedDirectoryRows] are the left
/// column's two flat lists and [buildFileRows] is the right pane. The body
/// stays flat and virtualised for the same reason as before: a file is
/// thousands of diff lines, and only a flat list stays smooth at that size —
/// which needs every row addressable by index without building the ones above
/// it.
///
/// What makes that affordable is [HunkSpan.displayLines]: a hunk's header says
/// how many lines it will draw, so the row list is built from **metadata
/// alone** and the patch text is decoded only for the hunks actually on screen.
/// Scroll extents are therefore right before anything is read, and expanding a
/// file does not make the scrollbar jump as its content arrives.
///
/// Pure Dart — no widgets here, so the flattening is testable without pumping.
library;

import 'change_set.dart';
import 'diff_lines.dart';
import 'patch_index.dart';
import 'ranking.dart';
import 'review_comment.dart';

/// One drawable row.
sealed class ChangeRow {
  const ChangeRow();
}

/// A heading. One survives: `Untracked`, at the foot of the *All* tab. The
/// others became tab labels, and a tab label carries its own count.
final class SectionRow extends ChangeRow {
  const SectionRow(this.label);

  final String label;
}

/// A file's own row in the index: status, name, counts, ruler.
final class FileRow extends ChangeRow {
  const FileRow(this.file, {required this.selected, this.reason});

  final FileChange file;

  /// Whether this is the file the right pane is showing.
  final bool selected;

  /// The rule that pinned or demoted this file, in the words it was written
  /// in. Null for the ordinary case, which is most files.
  final String? reason;
}

/// The `@@` line of an expanded hunk, plus the context git guessed.
final class HunkRow extends ChangeRow {
  const HunkRow(this.file, this.hunk);

  final FileChange file;
  final HunkSpan hunk;
}

/// One line of a hunk, addressed by its position **within that hunk** so the
/// text can be decoded lazily and thrown away on collapse.
final class DiffLineRow extends ChangeRow {
  const DiffLineRow(this.file, this.hunk, this.index);

  final FileChange file;
  final HunkSpan hunk;

  /// Zero-based, counting only the lines this hunk draws.
  final int index;
}

/// Why a file's body is not shown even though it is expanded.
final class FileNoticeRow extends ChangeRow {
  const FileNoticeRow(this.file, this.message);

  final FileChange file;
  final String message;
}

/// A comment, drawn in the body under the line it is about.
///
/// A row of its own, not a decoration on a diff line. It wraps, so it is
/// the one variable-height thing in a list whose every other row is a fixed
/// line of monospace — keeping it separate is what stops that variability
/// leaking into the three thousand rows around it.
final class CommentRow extends ChangeRow {
  const CommentRow(this.comment, {this.drifted = false});

  final ReviewComment comment;

  /// Whether the file has changed since this was written. The comment keeps its
  /// quote either way; this only decides whether the row flags it.
  final bool drifted;
}

/// The box you are typing a comment into.
///
/// In the row list rather than floating above it, so the diff moves down to
/// make room instead of the composer covering the lines you are describing.
final class ComposerRow extends ChangeRow {
  const ComposerRow(this.anchor);

  final ReviewAnchor anchor;
}

/// An untracked path, exactly as git reported it.
final class UntrackedRow extends ChangeRow {
  const UntrackedRow(this.entry, {this.selected = false});
  final UntrackedEntry entry;
  final bool selected;
}

/// The **Important** tab: every file a rule pinned, flat and all of it open.
///
/// Two tabs rather than a band above a tree. The band was tried and rejected in
/// use: it made the top of the index a place where the ranking's answer and the
/// directory structure argued for the same column, and it was still there
/// taking space on the branches where it said nothing. A tab hides the alert
/// half the time — that is the real cost, and it is paid back by the tab
/// *label*, which carries the count and so says there is something to look at
/// without being opened.
///
/// No headings in here. The tab is the heading, and there is only one kind of
/// row: this is the short list, in rank order, and it never collapses
/// anything.
///
/// [visible] is null when nothing is filtering.
List<ChangeRow> buildImportantRows(
  ChangeSet set, {
  String? selected,
  Set<String>? visible,
}) {
  var rows = <ChangeRow>[];

  for (var ranked in set.ordered(RankTier.attention)) {
    if (visible != null && !visible.contains(ranked.file.path)) continue;
    rows.add(
      FileRow(
        ranked.file,
        selected: ranked.file.path == selected,
        reason: ranked.reason,
      ),
    );
  }

  // An untracked file that matched a rule belongs here even though it has no
  // diff — see `attentionForUntracked`. The motivating case is a file an agent
  // wrote thirty seconds ago and has not staged, which is exactly the thing
  // this tab exists to surface.
  for (var entry in set.untracked) {
    if (!entry.isPinned) continue;
    if (visible != null && !visible.contains(entry.path)) continue;
    rows.add(UntrackedRow(entry, selected: entry.path == selected));
  }

  return rows;
}

/// The **All** tab's flat tail: the untracked *directories*, under one heading.
///
/// Everything else is in the tree above it — tracked files and untracked files
/// alike, see [treeFiles] and [treeUntracked]. A directory cannot join them:
/// git reports the topmost wholly-untracked directory and does not descend, so
/// `build/` is one entry standing for a subtree nobody has walked. Folding that
/// into a directory tree would claim a shape that was never read, and draw a
/// folder row that does not open.
///
/// So the tail is short and it is about one thing, which is what lets its rows
/// say the only sentence there is to say about them: *not scanned*.
List<ChangeRow> buildUntrackedDirectoryRows(
  ChangeSet set, {
  String? selected,
  Set<String>? visible,
}) {
  var kept = [
    for (var entry in set.untracked)
      if (entry.isDirectory)
        if (visible == null || visible.contains(entry.path)) entry,
  ];
  if (kept.isEmpty) return const [];
  return [
    const SectionRow('Untracked directories'),
    for (var entry in kept)
      UntrackedRow(entry, selected: entry.path == selected),
  ];
}

/// The untracked **files** the tree holds — the other half of [treeFiles].
///
/// Never a directory: [buildUntrackedDirectoryRows] draws those, and the reason
/// they are apart is the whole of `buildTree`'s doc.
List<UntrackedEntry> treeUntracked(ChangeSet set, {Set<String>? visible}) => [
  for (var entry in set.untracked)
    if (!entry.isDirectory)
      if (visible == null || visible.contains(entry.path)) entry,
];

/// The files the **tree** holds: every one of them.
///
/// Pinned files are in here too, which they were not at first. Leaving them
/// out to avoid "listing a file twice" made the tree an *incomplete map*: its
/// directory counts came out one short for every pin, so the header said 53
/// files over a tree that totalled 52, and browsing to `CLAUDE.md` could not
/// find it. A quietly wrong count is worse than a repetition.
///
/// The Important tab is a **view onto** this tree, not a removal from it — the
/// way a problems panel lists files that are also in the file explorer. The
/// tree marks a pinned file where it lives.
/// Every tier, in tier order — `RankTier.values` rather than a list spelled
/// out here, which is what it used to be when one of the three was held back.
/// A hand-written enumeration is how a tier added later goes missing from the
/// tree, and a tree that can lose a file is what this whole file argues against.
List<FileChange> treeFiles(ChangeSet set, {Set<String>? visible}) => [
  for (var tier in RankTier.values)
    for (var ranked in set.ordered(tier))
      if (visible == null || visible.contains(ranked.file.path)) ranked.file,
];

/// Where a row sits in the body: which hunk, and how far into it.
///
/// Not a line number. A hunk's rows include both sides of the diff, so
/// *line 388* is one of two rows depending on which gutter you meant, and a
/// removed line has no number in the other one at all. This is the coordinate
/// the list is actually built on.
typedef RowSpot = ({int hunkStart, int index});

/// The **body**: one file's diff, with whatever has been said about it.
///
/// Every reason a body is withheld is stated in place. A file that opens to
/// nothing, with no explanation, reads as a bug in the viewer.
///
/// [placed] and [composer] are keyed by [RowSpot] — see [spotOf], which is what
/// turns a comment's line anchor back into one. A comment whose spot could not
/// be found is simply not drawn here; it is still in the review list, with its
/// quote, which is why the quote is stored.
///
/// [fileComments] draw above the first hunk, because that is what *about this
/// file* means when the file has three hundred lines of diff under it.
List<ChangeRow> buildFileRows(
  FileChange file, {
  Map<RowSpot, List<CommentRow>> placed = const {},
  Map<RowSpot, ComposerRow> composer = const {},
  List<ChangeRow> fileComments = const [],
}) {
  if (file.isBinary) {
    return [
      ...fileComments,
      FileNoticeRow(file, 'Binary file, no lines to show.'),
    ];
  }
  if (file.patchBytes > ChangesLimits.filePatchBytes) {
    return [
      ...fileComments,
      FileNoticeRow(
        file,
        "This file's diff is ${(file.patchBytes / 1024).round()} KB, too "
        'large to show here. Open it in your editor.',
      ),
    ];
  }
  if (file.hunks.isEmpty) {
    return [
      ...fileComments,
      FileNoticeRow(file, 'No text changed, only the path or the mode.'),
    ];
  }
  return [
    ...fileComments,
    for (var hunk in file.hunks) ...[
      HunkRow(file, hunk),
      for (var i = 0; i < hunk.displayLines; i++) ...[
        DiffLineRow(file, hunk, i),
        ...?placed[(hunkStart: hunk.byteStart, index: i)],
        ?composer[(hunkStart: hunk.byteStart, index: i)],
      ],
    ],
  ];
}

/// The row a line number lands on, or null when nothing in this file draws it.
///
/// Decoding is injected rather than done here so this stays pure Dart and so
/// the caller keeps its cache: it decodes **only the hunk that covers the
/// line**, which for a file with two comments is two hunks out of forty.
RowSpot? spotOf(
  FileChange file,
  int line,
  ReviewSide side,
  List<DiffLine> Function(HunkSpan) decode,
) {
  for (var hunk in file.hunks) {
    var (start, count) = side == ReviewSide.before
        ? (hunk.oldStart, hunk.oldCount)
        : (hunk.newStart, hunk.newCount);
    if (line < start || line >= start + count) continue;
    var lines = decode(hunk);
    for (var i = 0; i < lines.length; i++) {
      var number = side == ReviewSide.before
          ? lines[i].oldNumber
          : lines[i].newNumber;
      if (number == line) return (hunkStart: hunk.byteStart, index: i);
    }
  }
  return null;
}

/// The code a line anchor is about, without diff markers.
///
/// Read **once**, when the comment is written — see [ReviewComment.quote]. Any
/// later reading of the same span is a reading of whatever is there now, which
/// is a different claim.
List<String> quoteFor(
  FileChange file,
  int from,
  int to,
  ReviewSide side,
  List<DiffLine> Function(HunkSpan) decode,
) {
  var quoted = <String>[];
  for (var hunk in file.hunks) {
    var (start, count) = side == ReviewSide.before
        ? (hunk.oldStart, hunk.oldCount)
        : (hunk.newStart, hunk.newCount);
    // Overlap only: a three-line quote must not decode the other thirty-nine
    // hunks to discover they have nothing in the range.
    if (start + count <= from || start > to) continue;
    for (var line in decode(hunk)) {
      var number = side == ReviewSide.before ? line.oldNumber : line.newNumber;
      if (number == null || number < from || number > to) continue;
      quoted.add(line.text);
    }
  }
  return quoted;
}

/// Paths containing [query], case-insensitively.
///
/// A substring rather than a glob: the box is for *finding* a file among fifty,
/// not for expressing a rule. Rules live in `tool/flutterware.dart` and get to
/// be globs there, where they are written once and read by a parser.
///
/// Takes paths rather than [FileChange]s so an **untracked** entry can be
/// found too. It could not be, which meant typing `scratch` hid the very file
/// you were looking for.
Set<String> pathsMatching(Iterable<String> paths, String query) {
  var needle = query.trim().toLowerCase();
  if (needle.isEmpty) return paths.toSet();
  return {
    for (var path in paths)
      if (path.toLowerCase().contains(needle)) path,
  };
}
