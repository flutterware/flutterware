/// What a branch changed, in the terms a tree of entries can be painted from.
///
/// Pure Dart — `fw` links this. The git half is the changes screen's own
/// probe; the reach half is the comparison's import graph. This is the answer
/// they give together, reduced to what a row needs: which lines of which files
/// moved, and which changed files each entry's closure reads.
library;

import 'package:path/path.dart' as p;

import '../changes/patch_index.dart' show ChangeStatus;
import 'change_kind.dart';

export '../changes/patch_index.dart' show ChangeStatus;
export 'change_kind.dart';

/// A run of 1-based, inclusive line numbers on the working-tree side.
class LineRange {
  const LineRange(this.start, this.end);

  final int start;
  final int end;

  bool overlaps(int from, int to) => from <= end && to >= start;
  bool covers(int from, int to) => start <= from && end >= to;

  @override
  String toString() => start == end ? '$start' : '$start–$end';
}

/// One tracked file the branch changed.
class DeltaFile {
  const DeltaFile({
    required this.path,
    required this.status,
    this.oldPath,
    this.added = const [],
    this.removedAt = const [],
    this.uncommitted = false,
  });

  /// Worktree-relative, `/`-separated.
  final String path;

  /// The changes screen's own status — one vocabulary for one delta.
  final ChangeStatus status;

  /// Where a renamed file came from.
  final String? oldPath;

  /// The lines that are new on the working-tree side, read off the hunk
  /// bodies — not the hunks' own ranges, which carry three lines of context
  /// at each end and would tint a declaration for being *near* an edit.
  final List<LineRange> added;

  /// New-side line numbers after which lines were removed. A deletion inside
  /// a declaration is an edit to it even though no surviving line changed.
  final List<int> removedAt;

  /// Whether some of this file's delta is not committed yet.
  final bool uncommitted;

  /// Whether the edit touches lines [from]..[to].
  ///
  /// A removal counts only strictly inside the span. One at its edge — after
  /// line `from - 1`, or after line `to` — is ambiguous by line numbers
  /// alone: the declaration's own first or last line gone, or the neighbour's.
  /// The neighbour is the common case (a rewritten line is a removal at
  /// `x - 1` and an addition at `x`, and it must not light the declaration
  /// that ends at `x - 1`), and a declaration that lost its own edge line has
  /// rarely survived as a declaration.
  bool touches(int from, int to) =>
      added.any((run) => run.overlaps(from, to)) ||
      removedAt.any((at) => at >= from && at < to);

  /// Whether this describes the same edit as [other].
  bool sameAs(DeltaFile other) {
    if (path != other.path ||
        status != other.status ||
        oldPath != other.oldPath ||
        uncommitted != other.uncommitted ||
        added.length != other.added.length ||
        removedAt.length != other.removedAt.length) {
      return false;
    }
    for (var i = 0; i < added.length; i++) {
      if (added[i].start != other.added[i].start ||
          added[i].end != other.added[i].end) {
        return false;
      }
    }
    for (var i = 0; i < removedAt.length; i++) {
      if (removedAt[i] != other.removedAt[i]) return false;
    }
    return true;
  }

  /// Whether every line of [from]..[to] is new — inserted, not rewritten. A
  /// removal beside or inside the span means lines were replaced, and a
  /// replaced declaration is an edited one.
  bool wholly(int from, int to) =>
      added.any((run) => run.covers(from, to)) &&
      !removedAt.any((at) => at >= from - 1 && at <= to);
}

/// One worktree's delta against its base, plus what each entry file reaches
/// of it.
class BranchDelta {
  BranchDelta({
    required this.worktreePath,
    required this.base,
    required this.mergeBase,
    required this.head,
    required this.readAt,
    Map<String, DeltaFile> files = const {},
    Set<String> untracked = const {},
    Set<String> untrackedDirectories = const {},
    Map<String, List<String>> reach = const {},
  }) : files = Map.unmodifiable(files),
       untracked = Set.unmodifiable(untracked),
       untrackedDirectories = Set.unmodifiable(untrackedDirectories),
       // ignore: prefer_initializing_formals
       _reach = reach;

  /// A delta that answers nothing: no base resolved, or nothing changed.
  BranchDelta.none({required this.worktreePath, required this.readAt})
    : base = null,
      mergeBase = null,
      head = null,
      files = const {},
      untracked = const {},
      untrackedDirectories = const {},
      _reach = const {};

  final String worktreePath;

  /// The branch the delta is measured from, or null when none resolved — on
  /// which nothing is tinted, since nothing is diffed against a guess.
  final String? base;

  /// `merge-base(base, HEAD)`, the commit the delta starts at.
  final String? mergeBase;
  final String? head;

  final DateTime readAt;

  /// Tracked files with a delta, by worktree-relative path.
  final Map<String, DeltaFile> files;

  /// Untracked files, worktree-relative. Directories git reported as wholly
  /// untracked are in [untrackedDirectories] instead — git does not walk
  /// them, and neither does this.
  final Set<String> untracked;
  final Set<String> untrackedDirectories;

  /// Entry file → the changed paths its imports reach, transitively, the file
  /// itself excluded. Only the files a caller asked for are keys.
  final Map<String, List<String>> _reach;

  bool get hasBase => mergeBase != null;

  /// This delta with [reach] attached.
  BranchDelta withReach(Map<String, List<String>> reach) => BranchDelta(
    worktreePath: worktreePath,
    base: base,
    mergeBase: mergeBase,
    head: head,
    readAt: readAt,
    files: files,
    untracked: untracked,
    untrackedDirectories: untrackedDirectories,
    reach: reach,
  );

  bool get isEmpty =>
      files.isEmpty && untracked.isEmpty && untrackedDirectories.isEmpty;

  /// Whether [path] is new to git — listed untracked, or under a directory
  /// that is.
  bool isUntracked(String path) =>
      untracked.contains(path) ||
      untrackedDirectories.any((dir) => path.startsWith(dir));

  /// The changed paths [file]'s closure reads, or none when it was not asked
  /// about or reaches nothing.
  List<String> reachOf(String file) => _reach[file] ?? const [];

  /// Which files reach was computed for.
  Iterable<String> get reachedFiles => _reach.keys;

  /// The reach as computed, to carry into the next answer when the git half
  /// came back unchanged — see `BranchDeltaProbe.probe`.
  Map<String, List<String>> get reach => _reach;

  /// Whether the git half — base, files, lines, untracked — is the same as
  /// [other]'s. What decides that the import graph need not be read again.
  bool sameChangesAs(BranchDelta other) {
    if (identical(this, other)) return true;
    if (worktreePath != other.worktreePath ||
        base != other.base ||
        mergeBase != other.mergeBase ||
        head != other.head ||
        files.length != other.files.length ||
        !_sameSet(untracked, other.untracked) ||
        !_sameSet(untrackedDirectories, other.untrackedDirectories)) {
      return false;
    }
    for (var MapEntry(key: path, value: mine) in files.entries) {
      var theirs = other.files[path];
      if (theirs == null || !mine.sameAs(theirs)) return false;
    }
    return true;
  }

  /// Whether [other] would paint the same trees — [sameChangesAs] plus the
  /// reach, for the same set of files.
  bool sameAnswerAs(BranchDelta other) {
    if (!sameChangesAs(other)) return false;
    if (_reach.length != other._reach.length) return false;
    for (var MapEntry(key: file, value: mine) in _reach.entries) {
      var theirs = other._reach[file];
      if (theirs == null || !_sameList(mine, theirs)) return false;
    }
    return true;
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _sameList(List<Object> a, List<Object> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// `main (abc1234)` — what the header names as the other side.
  String describeBase() {
    var name = base;
    if (name == null) return 'no base';
    var at = mergeBase;
    return at == null ? name : '$name (${at.substring(0, 7)})';
  }
}

/// An entry as the classifier sees it: an id, the file it is declared in and
/// the lines it spans.
class EntrySpan {
  const EntrySpan({
    required this.id,
    required this.file,
    required this.line,
    required this.endLine,
  });

  final String id;

  /// Worktree-relative, `/`-separated — the delta's own coordinates.
  final String file;

  /// 1-based, inclusive. Zero when the declaration's position is unknown, in
  /// which case any edit to the file counts as an edit to the entry.
  final int line;
  final int endLine;

  bool get located => line > 0 && endLine >= line;
}

/// How the branch touched one entry, and in words.
class EntryChange {
  const EntryChange(this.kind, this.why, {this.files = const []});

  final EntryChangeKind kind;

  /// One sentence for the row's tooltip.
  final String why;

  /// For [EntryChangeKind.reached], the changed files the entry reads.
  final List<String> files;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'why': why,
    if (files.isNotEmpty) 'files': files,
  };
}

/// Every entry's change, over one list — the tree's — because whether reach is
/// worth painting is a question about the list as a whole.
class EntryChanges {
  EntryChanges._(this.delta, this._byId, this.total, this.suppressedReach);

  /// No delta yet, or nothing to say.
  EntryChanges.none(this.delta)
    : _byId = const {},
      total = 0,
      suppressedReach = 0;

  final BranchDelta delta;
  final Map<String, EntryChange> _byId;

  /// How many entries were classified.
  final int total;

  /// Entries reached through a shared file whose tint was withheld — see
  /// [reachThreshold]. Non-zero is what the header explains.
  final int suppressedReach;

  /// Past this share of the tree, a reach tint says nothing: touching a
  /// widget every demo imports would paint the whole list, and a colour on
  /// every row is a colour on none. The rows keep their added and edited
  /// states; the header says a shared file changed instead.
  static const reachThreshold = 0.25;

  EntryChange? operator [](String id) => _byId[id];

  bool get isEmpty => _byId.isEmpty;

  Iterable<String> get ids => _byId.keys;

  int count(EntryChangeKind kind) =>
      _byId.values.where((change) => change.kind == kind).length;

  /// Classifies [entries] against [delta].
  ///
  /// In priority order: the file is new to git, or the declaration's lines
  /// are all new → added; an edit lands inside the declaration → edited; the
  /// entry's imports reach a changed file → reached, unless that is most of
  /// the tree.
  static EntryChanges of(List<EntrySpan> entries, BranchDelta delta) {
    if (!delta.hasBase || delta.isEmpty || entries.isEmpty) {
      return EntryChanges.none(delta);
    }
    var byId = <String, EntryChange>{};
    var reached = <String, EntryChange>{};
    for (var entry in entries) {
      var change = _classify(entry, delta);
      if (change == null) continue;
      if (change.kind == EntryChangeKind.reached) {
        reached[entry.id] = change;
      } else {
        byId[entry.id] = change;
      }
    }
    var suppressed = 0;
    if (reached.length > entries.length * reachThreshold) {
      suppressed = reached.length;
    } else {
      byId.addAll(reached);
    }
    return EntryChanges._(delta, byId, entries.length, suppressed);
  }

  static EntryChange? _classify(EntrySpan entry, BranchDelta delta) {
    if (delta.isUntracked(entry.file)) {
      return const EntryChange(
        EntryChangeKind.added,
        'New on this branch, not in git yet',
      );
    }
    var file = delta.files[entry.file];
    if (file != null) {
      if (file.status == ChangeStatus.added) {
        return const EntryChange(
          EntryChangeKind.added,
          'New on this branch: the file was added',
        );
      }
      if (!entry.located) {
        return EntryChange(EntryChangeKind.edited, _edited(file, null));
      }
      if (file.wholly(entry.line, entry.endLine)) {
        return const EntryChange(
          EntryChangeKind.added,
          'New on this branch: every line of it is new',
        );
      }
      if (file.touches(entry.line, entry.endLine)) {
        return EntryChange(EntryChangeKind.edited, _edited(file, entry));
      }
    }
    var reach = delta.reachOf(entry.file);
    if (reach.isNotEmpty) {
      var named = reach.length == 1 ? reach.single : '${reach.length} files';
      return EntryChange(
        EntryChangeKind.reached,
        'Reads $named this branch changed',
        files: reach,
      );
    }
    return null;
  }

  static String _edited(DeltaFile file, EntrySpan? entry) {
    var where = entry == null
        ? ''
        : entry.line == entry.endLine
        ? ', line ${entry.line}'
        : ', lines ${entry.line}–${entry.endLine}';
    var state = file.uncommitted ? ', not all committed' : '';
    var moved = file.oldPath == null ? '' : ' (moved from ${file.oldPath})';
    return 'Edited on this branch$where$state$moved';
  }
}

/// [file], package-relative in [package], as the worktree-relative path the
/// delta keys on. `.` is the worktree itself.
String worktreeRelative(String package, String file) {
  if (package == '.' || package.isEmpty) return file;
  // Normalised, because a package declared as `./app` is accepted everywhere
  // else and git never spells a path that way.
  return p.url.normalize(
    p.url.joinAll([...p.split(package), ...file.split('/')]),
  );
}

/// Memoises [EntryChanges] per key on the pair that decides it — the delta
/// held and the scan the spans came from — so a tree rebuilding forty times a
/// second classifies once per answer rather than once per frame.
class EntryChangesCache {
  final _memo = <String, (BranchDelta, Object, EntryChanges)>{};

  EntryChanges? of(
    String key,
    BranchDelta? delta,
    Object? scan,
    List<EntrySpan> Function() spans,
  ) {
    if (delta == null || scan == null) return null;
    if (_memo[key] case (var d, var s, var changes)
        when identical(d, delta) && identical(s, scan)) {
      return changes;
    }
    var changes = EntryChanges.of(spans(), delta);
    _memo[key] = (delta, scan, changes);
    return changes;
  }
}

/// One package's changes at a glance — what a listing's header carries so a
/// reader knows the per-entry marks are relative to something.
class BranchChangeSummary {
  const BranchChangeSummary({
    required this.base,
    required this.added,
    required this.edited,
    required this.reached,
    required this.reachSuppressed,
  });

  factory BranchChangeSummary.of(EntryChanges changes) => BranchChangeSummary(
    base: changes.delta.describeBase(),
    added: changes.count(EntryChangeKind.added),
    edited: changes.count(EntryChangeKind.edited),
    reached: changes.count(EntryChangeKind.reached),
    reachSuppressed: changes.suppressedReach,
  );

  /// `main (abc1234)` — what the entries are compared against.
  final String base;

  final int added;
  final int edited;
  final int reached;

  /// Entries that read a changed file but were not marked, because that was
  /// most of them — a shared file changed. See `EntryChanges.reachThreshold`.
  final int reachSuppressed;

  Map<String, Object?> toJson() => {
    'base': base,
    'added': added,
    'edited': edited,
    'reached': reached,
    if (reachSuppressed > 0) 'reachSuppressed': reachSuppressed,
  };
}
