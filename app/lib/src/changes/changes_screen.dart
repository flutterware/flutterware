import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shell/worktree.dart';
import '../ui/empty_state.dart';
import '../ui/syntax.dart';
import '../ui/tappable.dart';
import '../ui/panel_header.dart';
import '../ui/theme.dart';
import 'change_rows.dart';
import 'change_set.dart';
import 'changes_config_cache.dart';
import 'changes_controller.dart';
import 'changes_tree.dart';
import 'diff_lines.dart';
import 'diff_view.dart';
import 'file_body.dart';
import 'file_contents.dart';
import 'hunk_syntax.dart';
import 'patch_index.dart';
import 'ranking.dart';
import 'review_comment.dart';
import 'review_export.dart';
import 'review_controller.dart';
import 'review_store.dart';
import 'review_view.dart';

/// The changes screen's root, so a test can scope to it.
const changesScreenKey = Key('changes-screen');

/// The index of paths, on the left.
const changesListKey = Key('changes-list');

/// The selected file's diff, on the right.
const changesFileKey = Key('changes-file');

/// Which of the index's tabs is showing.
///
/// The ranking's answer and the directory structure are two orderings of one
/// set of files, and they do not fit in one column. Putting the pinned files
/// in a band above the tree was tried and used, and it lost on both counts: the
/// alert competed with the tree for the top of a 320 px column, and it was
/// still occupying that column on the branches where it had nothing to say.
///
/// The third is not an ordering of the files at all — it is what *you* have
/// said about them — and it is here for the same reason: it is a list you
/// navigate by, and this column is the screen's one place for those.
enum IndexTab {
  /// Everything, as a directory tree.
  all,

  /// What a rule pinned: flat, in rank order, nothing folded.
  important,

  /// What you have written about this delta, in the order you wrote it.
  ///
  /// A tab, not a third column. The list of comments is navigation — every
  /// row opens the line it is about — which is what this column already is, and
  /// a 1200 px window has no room for another one. The comments themselves are
  /// drawn in the diff, where the code is.
  review,
}

/// `fw:///worktrees/<worktree>/changes` — what this checkout has changed
/// against its base branch, committed and uncommitted together.
///
/// Deliberately not a plugin, and unlike the config screen not merely because
/// of what it is *about*: it reads git rather than the project, so it renders
/// for a worktree that is **not open**. A plugin needs a resolved config and a
/// session; the checkout you most want to look at is the one an agent has been
/// working in while you were elsewhere.
///
/// Master and detail. Left: every path in the delta, and nothing else.
/// Right: the one file you picked. They used to be a single list of file rows
/// that expanded to inject their own diff, which made the surface you navigate
/// with and the surface you read the same one — every complaint about this
/// screen came out of that, from "clicking a file scrolls but does not open it"
/// to a live update sliding the lines under your eyes.
///
/// The index is **three tabs**: *All*, a directory tree; *Important*, the files
/// a rule pinned; and *Review*, the notes you have left for the agent that
/// wrote this delta. A churn map was a fourth way into the *files* and is gone
/// — three navigation surfaces for one list of files was two too many, and the
/// Review tab is not one of them: it lists comments, not files.
///
/// A comment carries the code it is about, quoted when you wrote it, so the
/// agent may keep editing while you type. See `review_comment.dart`.
class ChangesScreen extends StatefulWidget {
  const ChangesScreen({
    required this.worktree,
    this.isOpen = false,
    this.repoRoot,
    this.initialPath,
    this.onPathChanged,
    this.gitMoved,
    this.load,
    this.contents,
    this.reviewStore,
    this.live = true,
    this.showTitle = true,
    super.key,
  });

  final Worktree worktree;

  /// The main checkout, which the repository-wide cache holding this project's
  /// ranking rules is keyed by. Null means nothing is pinned: there are no
  /// built-in rules to fall back on.
  final String? repoRoot;

  /// Whether the checkout has a tab. Only affects what the empty state says.
  final bool isOpen;

  /// The file the address names, expanded and scrolled to on arrival.
  ///
  /// Segments after the plugin id belong to the panel, which is the rule
  /// every other panel in the shell already follows. Here it means a file's
  /// diff has a name you can paste: `fw:///worktrees/<n>/changes/lib/a.dart`.
  final String? initialPath;

  /// Writes the expansion back into the address, so what you are looking at is
  /// what the bar says and what a link would reopen.
  final ValueChanged<String?>? onPathChanged;

  /// The shell's repository-wide git signal. Staging and committing write a
  /// linked worktree's index under the *main* checkout, so no watch on this
  /// working tree can see them — and committing is exactly what clears the
  /// `uncommitted` marks this screen draws.
  final Stream<void>? gitMoved;

  /// Whether to watch the checkout. Off for a test that would otherwise put a
  /// recursive watch on a real temporary directory to prove something else.
  final bool live;

  /// Injected for widget tests, which must neither spawn an isolate nor need a
  /// repository — and by the studio's recordings, which have neither.
  final Future<ChangeSet> Function(String path)? load;

  /// The bytes behind the bodies a diff cannot draw. Defaults to the working
  /// tree and git; a recording hands in its own.
  final FileContentStore Function(String worktreePath)? contents;

  /// Where review comments are logged. Defaults to this checkout's own file —
  /// injected only by tests, which must not append to the developer's real
  /// `~/.flutterware`.
  final ReviewStore? reviewStore;

  /// Whether this screen has to name itself.
  ///
  /// False when it is a tab. `ComparisonTabs` draws a strip above all three
  /// renderings of one delta, and only this one was also writing a page title
  /// and a branch line under it — so the files tab began with two lines of
  /// chrome the previews and scenarios tabs do not have, and the strip's
  /// `against <base>` sat six pixels above this screen's own `base <x>`. The
  /// same delta, stated twice, in two different vocabularies.
  ///
  /// True when there is no strip, which is a real case rather than a fallback:
  /// an unopened checkout gets the file diff and no comparison, with no
  /// rail and no tabs around it, and then this line is the only thing on screen
  /// that says whose changes these are.
  final bool showTitle;

  @override
  State<ChangesScreen> createState() => _ChangesScreenState();
}

class _ChangesScreenState extends State<ChangesScreen> {
  late ChangesController _changes;

  /// One controller each, because they are two independent readings. The index
  /// stays where you left it while you read; the body starts at the top of
  /// whatever you just picked.
  final _index = ScrollController();
  final _body = ScrollController();

  /// The path the right pane is showing. **One, not a set** — the screen used
  /// to expand any number of files inline, which is what made the list you
  /// navigate with and the thing you read the same surface.
  String? _selected;

  /// Rebuilt whenever the patch is, which is what throws the decoded text of
  /// the previous one away.
  HunkLineCache? _lines;
  ChangeSet? _cachedFor;

  /// The same, for syntax tokens — see [_tokensFor], which is keyed by the open
  /// file rather than by the patch.
  HunkTokenCache? _tokens;
  String? _tokensFile;

  /// The bytes behind the bodies a diff cannot draw — images, rendered
  /// markdown, an untracked file's lines. Keyed by the worktree because the
  /// screen can be re-targeted at another one under the same element.
  FileContentStore get _contents {
    if (_contentsStore?.worktreePath != widget.worktree.path) {
      _contentsStore =
          widget.contents?.call(widget.worktree.path) ??
          FileContentStore(widget.worktree.path);
    }
    return _contentsStore!;
  }

  FileContentStore? _contentsStore;

  var _query = '';

  /// The review log for this checkout.
  late ReviewController _review;

  /// What the open composer is about, or null when nothing is being written.
  ///
  /// One at a time. Two half-written comments is two things to lose track
  /// of, and the second one is always opened by accident.
  ReviewAnchor? _composing;

  /// The comment being rewritten, when the composer is an edit rather than an
  /// add.
  String? _editing;

  /// A note you deleted a moment ago, whose tombstone has **not been written**.
  ///
  /// The undo window is the delete. The log is append-only and a tombstone
  /// cannot be unwritten, so an undo that re-added the comment would give it a
  /// new place at the end of the list — the third note becoming the sixth is
  /// not the note you took back. Holding the delete instead costs a few
  /// seconds of a row saying so, and restores the note exactly, in place.
  ///
  /// Deferring is also the safe direction: a crash inside the window loses the
  /// deletion, not the writing.
  String? _pendingDelete;
  Timer? _deleteTimer;

  /// Long enough to notice the row and reach it.
  static const _undoWindow = Duration(seconds: 6);

  /// Which note the body should scroll to, and how many times it has been
  /// asked. The counter is what makes clicking the same row twice a second
  /// scroll rather than nothing — after the first, you may have scrolled away.
  String? _reveal;
  var _revealSeq = 0;

  /// The note drawn in the accent for a moment after arriving at it.
  String? _flash;
  Timer? _flashTimer;

  /// How long that lasts. Long enough to catch the eye landing, short enough
  /// not to read as a selection that will stay.
  static const _flashFor = Duration(milliseconds: 1600);

  /// What is outstanding, without the note whose delete is still being held.
  List<ReviewComment> get _live => [
    for (var comment in _review.unresolved)
      if (comment.id != _pendingDelete) comment,
  ];

  /// Every note the two panes may draw, under one rule so that the list and the
  /// diff cannot disagree about whether a note is on this screen.
  List<ReviewComment> get _visibleComments => [
    for (var comment in _review.comments)
      if (!comment.isResolved ||
          _showResolved ||
          _unseenNow.contains(comment.id))
        comment,
  ];

  /// Whether the resolved notes are being shown as well.
  ///
  /// Off, and not remembered. The list is what is still to do; a filter
  /// that persisted across launches would make a screen that opens on nine
  /// answered notes and two live ones, which is the pile the resolve was for.
  var _showResolved = false;

  /// The quote an *edit* shows: the one the comment already carries.
  ///
  /// Null when the composer is writing a new comment, which reads the patch
  /// instead. Re-reading it here would show the code as it is **now** under a
  /// note whose whole promise is that it kept what was there then — and the
  /// moment that differs is the moment the note matters.
  List<String>? get _editingQuote {
    if (_editing case var id?) {
      return _review.comments.where((c) => c.id == id).firstOrNull?.quote;
    }
    return null;
  }

  /// The draft, owned here rather than by the composer: the composer lives
  /// inside the virtualised body, and scrolling it past the cache extent
  /// disposes it. Holding the text a level up makes that a redraw instead of a
  /// loss.
  final _draft = TextEditingController();

  /// Each commented file's patch fingerprint, computed once per [ChangeSet].
  ///
  /// See [ReviewComment.fileDigest]: this is the half of the comparison that
  /// comes from the checkout, and it is a sha1 over a file's slice of the
  /// patch, so it is worth not recomputing per frame.
  final _digests = <String, String>{};
  ChangeSet? _digestsFor;

  /// Null until you pick one, which is what lets the default depend on what the
  /// checkout turned out to contain — see [_tabFor]. Set the moment a tab is
  /// clicked, and never re-derived after that: a screen that switches tabs
  /// under you because a rule started matching is a screen that moved your
  /// place while you were reading.
  IndexTab? _tab;

  /// Important when there is something in it, All otherwise.
  ///
  /// The one thing a tab costs is that the alert is hidden half the time, so
  /// the half it is hidden in is the half where it is empty. On a branch where
  /// a rule fired, the screen opens on the four files it fired for; on one
  /// where none did, opening on an empty tab would be the worst of both.
  IndexTab _tabFor(ChangeSet set) =>
      _tab ??
      (buildImportantRows(set).isEmpty ? IndexTab.all : IndexTab.important);

  /// Whether [path] has moved since a comment on it was written.
  bool _drifted(ReviewComment comment, ChangeSet set) {
    if (comment.fileDigest case var was?) {
      var now = _digestFor(comment.anchor.path, set);
      // A file that has left the delta entirely is not *drift*, it is gone —
      // and the row that says so is the one in the review list, which still
      // has the quote. Claiming a change here would be a second, weaker
      // statement of the same thing.
      if (now == null) return false;
      // **A `git add` is not an edit.** Staging an untracked file swaps which
      // fingerprint this path answers to — a stat's stamp for a sha1 of a
      // patch slice — and comparing the two would badge every note on a new
      // file the moment the agent staged it. Different kinds claim nothing.
      if (!sameDigestKind(was, now)) return false;
      return now != was;
    }
    return false;
  }

  /// This path's fingerprint as the checkout has it now, or null when the path
  /// is not in the delta at all.
  ///
  /// **Two kinds, one for each side of the screen.** A tracked file is a sha1
  /// over its slice of the patch, which is already in memory. An untracked file
  /// has no slice, so it is the stamp the probe took with a stat — see
  /// [untrackedStamp], which is also where the tagging that keeps the two apart
  /// is explained.
  String? _digestFor(String? path, ChangeSet set) {
    if (path == null) return null;
    if (!identical(_digestsFor, set)) {
      _digestsFor = set;
      _digests.clear();
    }
    if (_digests[path] case var it?) return it;
    var file = set.changed.where((f) => f.path == path).firstOrNull;
    if (file == null) {
      var stamp = set.untracked.where((e) => e.path == path).firstOrNull?.stamp;
      return stamp == null ? null : _digests[path] = stamp;
    }
    return _digests[path] = digestOfPatchSlice(
      set.patch.bytes.sublist(file.byteStart, file.byteEnd),
    );
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.initialPath;
    _start();
  }

  @override
  void didUpdateWidget(ChangesScreen old) {
    super.didUpdateWidget(old);
    if (old.worktree.path != widget.worktree.path) {
      _changes.dispose();
      // Same as [dispose]: this checkout's held delete belongs to this
      // checkout's log, and the controller about to replace it writes another.
      _review.removeListener(_onChanged);
      _commitPendingDelete(rebuild: false);
      _review.dispose();
      _selected = widget.initialPath;
      // A draft is about a line in the checkout you were looking at. Carrying
      // it to the next one would attach it to whatever happens to be there.
      _cancelComposing();
      // **The tab goes back to being derived**, like the selection. Holding a
      // click made about the last checkout would open the next one on an
      // *Important* tab that has nothing in it — see [_tabFor], whose whole
      // point is that the empty half is the half a tab may not open on.
      _tab = null;
      _start();
      return;
    }
    // An address that arrived from outside — pasted, or followed from the
    // explorer — selects what it names.
    if (widget.initialPath case var path?
        when path != old.initialPath && path != _selected) {
      _show(path);
    }
  }

  void _start() {
    _review = ReviewController(
      worktreePath: widget.worktree.path,
      store: widget.reviewStore,
      watch: widget.live,
    )..addListener(_onChanged);
    _changes = ChangesController(
      worktreePath: widget.worktree.path,
      repoRoot: widget.repoRoot,
      load: widget.load,
    )..addListener(_onChanged);
    // **Watching is scoped to this screen being mounted**, which is what makes
    // one recursive watch affordable: the explorer refuses fourteen of them,
    // and this is one, on the checkout you are looking at, for as long as you
    // are looking at it.
    if (widget.live) _changes.watch(gitMoved: widget.gitMoved);
    unawaited(_changes.refresh());
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _changes
      ..removeListener(_onChanged)
      ..dispose();
    // Leaving the screen closes the window: you deleted it and walked away.
    // Before the controller goes, or the write has nowhere to land.
    _flashTimer?.cancel();
    _review.removeListener(_onChanged);
    _commitPendingDelete(rebuild: false);
    _review.dispose();
    _draft.dispose();
    _index.dispose();
    _body.dispose();
    super.dispose();
  }

  HunkLineCache _linesFor(ChangeSet set) {
    if (!identical(_cachedFor, set)) {
      _cachedFor = set;
      _lines = HunkLineCache(set.patch);
      // Tokens are per *file*, and the file being read changes far more often
      // than the patch does — see [_tokensFor].
      _tokens = null;
      _tokensFile = null;
    }
    return _lines!;
  }

  /// The tokens for the file the right pane is showing.
  ///
  /// Keyed by the file, not by the patch, because the language is: a
  /// `.dart` file and a `.yaml` file in one delta are two grammars, and a cache
  /// that outlived the selection would hand a hunk of one to the other. One
  /// file is open at a time, so one cache is the right number.
  HunkTokenCache _tokensFor(ChangeSet set, FileChange file) {
    if (_tokensFile != file.path || _tokens == null) {
      _tokensFile = file.path;
      _tokens = HunkTokenCache(
        _linesFor(set),
        language: languageForPath(file.path),
      );
    }
    return _tokens!;
  }

  /// Null when nothing is narrowing the index at all.
  ///
  /// The filter box is drawn under both tabs and so narrows both.
  Set<String>? _visible(ChangeSet set) {
    if (_query.trim().isEmpty) return null;
    return pathsMatching([
      ...set.changed.map((f) => f.path),
      ...set.untracked.map((e) => e.path),
    ], _query);
  }

  /// Shows [path] in the right pane, from the top.
  ///
  /// The body scrolls back to the start. Two files' diffs share a scroll
  /// offset only by accident, and arriving four hundred lines into a file you
  /// just picked is the sort of thing that reads as the app losing its place.
  void _show(String? path) {
    if (path == _selected) return;
    setState(() => _selected = path);
    if (_body.hasClients) _body.jumpTo(0);
    widget.onPathChanged?.call(path);
  }

  /// What the right pane is showing, and what it falls back to.
  ///
  /// Nothing is auto-selected. The claim this screen makes is that it knows
  /// what to look at first, so opening straight into the top-ranked file would
  /// be tempting — and wrong: the first thing you want is the *shape* of what
  /// an agent did, which is the index. Reading a file is the second question,
  /// and it is one you should have asked.
  FileChange? _selectedFile(ChangeSet set) {
    if (_selected case var path?) {
      return set.changed.where((f) => f.path == path).firstOrNull;
    }
    return null;
  }

  void _cancelComposing() {
    _composing = null;
    _editing = null;
    _draft.clear();
  }

  /// The `+` in a diff line's margin.
  void _composeLine(FileChange file, DiffLine line) {
    // A line exists on one side or the other, and the side it exists on is the
    // only numbering that can be looked up in a file.
    var number = line.newNumber ?? line.oldNumber;
    if (number == null) return;
    _composeAt(
      file.path,
      number,
      line.newNumber != null ? ReviewSide.after : ReviewSide.before,
    );
  }

  /// The same `+`, in the margin of a file with no diff — an untracked one.
  ///
  /// Always [ReviewSide.after]: the numbers drawn beside those lines are the
  /// file's own, in the checkout, and there is no other side for them to be
  /// counted on.
  void _composeTextLine(String path, int number) =>
      _composeAt(path, number, ReviewSide.after);

  /// Opens the composer on a line, or extends the span it is already about.
  ///
  /// Shift extends rather than starting a new comment. Two clicks is the whole
  /// gesture for *this block*, and it is the gesture every diff viewer already
  /// teaches — a modifier that silently started over instead would lose
  /// whatever you had already typed.
  void _composeAt(String path, int number, ReviewSide side) {
    var current = _composing;
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed &&
          current is LineAnchor &&
          current.path == path &&
          current.side == side) {
        _composing = LineAnchor(
          path: path,
          from: math.min(current.from, number),
          to: math.max(current.to, number),
          side: side,
        );
        return;
      }
      _cancelComposing();
      _composing = LineAnchor(path: path, from: number, to: number, side: side);
    });
  }

  void _composeFile(String path) => setState(() {
    _cancelComposing();
    _composing = FileAnchor(path);
  });

  void _composeReview() => setState(() {
    _cancelComposing();
    _composing = const ReviewWide();
    _tab = IndexTab.review;
  });

  void _composeEdit(ReviewComment comment) {
    if (comment.anchor.path case var path?) _show(path);
    setState(() {
      _composing = comment.anchor;
      _editing = comment.id;
      _draft.text = comment.body;
    });
  }

  /// Writes the draft down, and closes the composer.
  ///
  /// The quote is **the one the composer was showing**, handed up by whichever
  /// body drew it. This is the moment the comment stops depending on the
  /// checkout: from now on it carries its own evidence, and the agent can keep
  /// editing without any of this going wrong.
  ///
  /// Handed up rather than read again here, which is what this used to do.
  /// Two reads of the same span is two chances to disagree — and one of the
  /// bodies has no span to re-read: an untracked file's lines are on disk, not
  /// in the patch, and the pane that loaded them is the only thing that has
  /// them.
  void _submitComment(ChangeSet set, [List<String> quote = const []]) {
    var body = _draft.text.trim();
    var anchor = _composing;
    if (anchor == null || body.isEmpty) return;

    if (_editing case var id?) {
      _review.edit(id, body);
    } else {
      _review.add(
        ReviewComment(
          id: newReviewId(),
          anchor: anchor,
          body: body,
          createdAt: DateTime.now(),
          quote: anchor is LineAnchor ? quote : const [],
          fileDigest: _digestFor(anchor.path, set),
        ),
      );
    }
    setState(_cancelComposing);
  }

  /// Takes the note off the screen, and holds the tombstone.
  ///
  /// One at a time: deleting a second note commits the first, which is also
  /// what stops the held id from being a queue.
  void _deleteComment(String id) {
    if (_editing == id) setState(_cancelComposing);
    _commitPendingDelete();
    setState(() => _pendingDelete = id);
    _deleteTimer = Timer(_undoWindow, _commitPendingDelete);
  }

  /// Writes the held tombstone, if there is one.
  ///
  /// [rebuild] is false where a rebuild is already happening or can no longer
  /// happen — a worktree swap, and teardown. Callers that turn it off remove
  /// the listener first, so the controller's own notification cannot ask for
  /// one either.
  void _commitPendingDelete({bool rebuild = true}) {
    _deleteTimer?.cancel();
    _deleteTimer = null;
    var id = _pendingDelete;
    if (id == null) return;
    _pendingDelete = null;
    _review.delete(id);
    if (rebuild && mounted) setState(() {});
  }

  void _undoDelete() {
    _deleteTimer?.cancel();
    _deleteTimer = null;
    setState(() => _pendingDelete = null);
  }

  /// The agent resolutions that were new when you arrived at the Review tab.
  ///
  /// Held here rather than read from the log, because arriving is also what
  /// marks them seen: a screen that read the log directly would clear the
  /// accent in the same frame that drew it, and the one thing this marker
  /// exists for is that you notice.
  var _unseen = <String>{};

  /// Marked on arrival, once. See [ReviewController.markSeen].
  ///
  /// Re-reads first. The watch on the log is what usually brings the
  /// agent's answers in, and a watch can be refused — a platform without them,
  /// a home that will not take one. Arriving at the tab is the moment the
  /// answer matters, so it is the moment not to rely on that.
  void _enterReview() {
    _review.reload();
    _unseen = {for (var c in _review.state.unseenResolutions) c.id};
    _review.markSeen();
  }

  /// What the list draws as new: what was new when you got here, plus anything
  /// the agent has resolved since — the file watch means those arrive under
  /// you, and they keep their accent until you next come back to the tab.
  Set<String> get _unseenNow => {
    ..._unseen,
    for (var c in _review.state.unseenResolutions) c.id,
  };

  /// Ticks a note off. [ReviewActor.human] by construction: this is the button
  /// on your screen.
  void _resolveComment(String id) {
    if (_editing == id) setState(_cancelComposing);
    _review.resolve(id);
  }

  /// Opens what a review row is about, and goes to it.
  ///
  /// Opening the file is not arriving at the note. This selected the path
  /// and jumped the body to line one, which on a six-hundred-line diff leaves
  /// the note you clicked somewhere below the fold — and when the file was
  /// already open it did nothing at all, because [_show] returns early on the
  /// selection it already has.
  void _openComment(ReviewComment comment) {
    if (comment.anchor.path case var path?) _show(path);
    _flashTimer?.cancel();
    setState(() {
      _reveal = comment.id;
      _revealSeq++;
      _flash = comment.id;
    });
    _flashTimer = Timer(_flashFor, () {
      if (mounted) setState(() => _flash = null);
    });
  }

  /// These notes, as the markdown every reader of them gets.
  String _markdownFor(
    List<ReviewComment> comments,
    ChangeSet? set, {
    DateTime? at,
  }) => reviewMarkdown(
    comments,
    worktree: widget.worktree.displayName,
    base: set?.base,
    at: at,
    drifted: set == null
        ? const {}
        : {
            for (var comment in comments)
              if (_drifted(comment, set)) ?comment.anchor.path,
          },
  );

  /// Takes the outstanding notes somewhere else.
  ///
  /// It changes nothing by itself. Exporting is a read: the agent that works in
  /// this checkout reads the log through its own surface and resolves what it
  /// deals with, and a paste into another window says nothing about whether it
  /// was acted on. What the sheet offers afterwards is *resolve these too*, for
  /// the case where no reply is coming back — and it is offered, not assumed.
  Future<void> _export(ChangeSet? set) async {
    var comments = _live;
    _commitPendingDelete();
    if (comments.isEmpty) return;
    var at = DateTime.now();
    var result = await showExportSheet(
      context,
      markdown: _markdownFor(comments, set, at: at),
      count: comments.length,
      worktree: widget.worktree.displayName,
      base: set?.base,
    );
    if (result == null || !result.resolve) return;
    // The ids the sheet was showing, not "everything outstanding" — a comment
    // written in another window while the sheet was up is not one you exported.
    for (var comment in comments) {
      _review.resolve(comment.id, at: at);
    }
    setState(_cancelComposing);
  }

  UntrackedEntry? _selectedUntracked(ChangeSet set) {
    if (_selected case var path?) {
      return set.untracked.where((e) => e.path == path).firstOrNull;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    var set = _changes.value;
    // Derived once: the tab the index draws and the tab the filter is computed
    // against are the same tab, and reading it twice is two chances to disagree
    // about the value this screen's narrowing now turns on.
    var tab = set == null ? IndexTab.all : _tabFor(set);

    return Column(
      key: changesScreenKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          worktree: widget.worktree,
          set: set,
          isLoading: _changes.isLoading,
          live: widget.live,
          isWatching: _changes.isWatching,
          readAt: _changes.readAt,
          failure: _changes.failure,
          showTitle: widget.showTitle,
          onRefresh: () => unawaited(_changes.refresh()),
        ),
        Divider(height: 1, color: context.colors.line),
        Expanded(
          child: set == null
              ? const SizedBox.shrink()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: _indexWidth,
                      child: _IndexPane(
                        set: set,
                        tab: tab,
                        controller: _index,
                        query: _query,
                        selected: _selected,
                        visible: _visible(set),
                        onTab: (tab) {
                          if (tab == IndexTab.review && _tab != tab) {
                            _enterReview();
                          }
                          setState(() => _tab = tab);
                        },
                        onQuery: (q) => setState(() => _query = q),
                        onSelect: _show,
                        review: _review.state,
                        // **The note the screen is on**, which is the one being
                        // rewritten or, failing that, the last one opened. It
                        // was the editing one alone, so clicking a row marked
                        // nothing: the diff jumped and the list you clicked in
                        // gave no sign of which row you were now looking at.
                        selectedComment: _editing ?? _reveal,
                        deleted: _pendingDelete,
                        onUndoDelete: _undoDelete,
                        drifted: (c) => _drifted(c, set),
                        onOpenComment: _openComment,
                        onDeleteComment: _deleteComment,
                        onCommentReview: _composeReview,
                        onExport: () => unawaited(_export(set)),
                        composing: _composing,
                        editing: _editing != null,
                        draft: _draft,
                        onSubmit: () => _submitComment(set),
                        onCancel: () => setState(_cancelComposing),
                        unseen: _unseenNow,
                        showResolved: _showResolved,
                        onShowResolved: (on) =>
                            setState(() => _showResolved = on),
                      ),
                    ),
                    VerticalDivider(width: 1, color: context.colors.line),
                    Expanded(
                      child: _FilePane(
                        file: _selectedFile(set),
                        untracked: _selectedUntracked(set),
                        missing: _selected,
                        uncommitted: set.uncommitted,
                        contents: _contents,
                        // The left side of the very diff being drawn — what
                        // an image's base cell must be read from, or it is a
                        // differ whose two halves disagree about the range.
                        baseRevision: set.mergeBase ?? set.head,
                        readAt: _changes.readAt,
                        lines: _linesFor(set),
                        tokens: switch (_selectedFile(set)) {
                          var file? => _tokensFor(set, file),
                          null => null,
                        },
                        controller: _body,
                        comments: _visibleComments,
                        onResolveComment: _resolveComment,
                        onUnresolveComment: _review.unresolve,
                        composing: _composing,
                        editing: _editing != null,
                        draft: _draft,
                        drifted: (c) => _drifted(c, set),
                        deleted: _pendingDelete,
                        flash: _flash,
                        reveal: _reveal,
                        revealSeq: _revealSeq,
                        editingQuote: _editingQuote,
                        onUndoDelete: _undoDelete,
                        onCommentLine: _composeLine,
                        onCommentTextLine: _composeTextLine,
                        onCommentFile: _composeFile,
                        onSubmit: (quote) => _submitComment(set, quote),
                        onCancel: () => setState(_cancelComposing),
                        onEditComment: _composeEdit,
                        onDeleteComment: _deleteComment,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// Wider than the tree it replaced, because it now carries the whole index —
  /// a filename, its directory and its counts on one row.
  static const _indexWidth = 320.0;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.worktree,
    required this.set,
    required this.isLoading,
    required this.live,
    required this.isWatching,
    required this.readAt,
    required this.failure,
    required this.showTitle,
    required this.onRefresh,
  });

  final Worktree worktree;
  final ChangeSet? set;
  final bool isLoading;
  final bool live;
  final bool isWatching;
  final DateTime? readAt;
  final Object? failure;
  final bool showTitle;

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      // The same gutter and top inset [FwPanelHeader] uses. Not the header
      // itself: this one has a second mode where the summary *replaces* the
      // title, and the component would restructure that for no visual change.
      // Reading the constant is what keeps it from drifting anyway.
      padding: EdgeInsets.fromLTRB(
        panelGutter,
        showTitle ? FwSpacing.xl : FwSpacing.md,
        panelGutter,
        showTitle ? FwSpacing.lg : FwSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showTitle)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Changes', style: context.type.pageTitle),
                      const Gap(FwSpacing.xs),
                      // **The identity is drawn before anything is loaded.** A
                      // screen that opens on a spinner tells you nothing you
                      // did not already know.
                      Text(
                        worktree.displayName,
                        style: context.type.caption.copyWith(color: colors.mut),
                      ),
                    ],
                  ),
                )
              else
                // Under a strip, the summary *is* the header: the delta's
                // counts move up onto the line the title used to have, rather
                // than leaving an empty band where it was.
                Expanded(child: _Summary(set, showBase: false)),
              // **What makes the liveness believable.** A screen that updates
              // by itself and never says so is indistinguishable from one that
              // has stopped — and the one thing worse than a stale screen is a
              // stale screen you trust.
              //
              // **Centred against the refresh button, not against the title.**
              // These two are one cluster and read as one: aligned to the top
              // of the row, the badge sat seventeen pixels above the icon it
              // belongs beside.
              _Watching(live: live, isWatching: isWatching, readAt: readAt),
              const Gap(FwSpacing.sm),
              _Refresh(onTap: isLoading ? null : onRefresh),
            ],
          ),
          if (showTitle) ...[const Gap(FwSpacing.md), _Summary(set)],
          if (failure case var why?) ...[
            const Gap(FwSpacing.md),
            _Note('Could not read this checkout: $why'),
          ],
          if (set case var it?) ...[
            if (it.baseSource == BaseSource.none) ...[
              const Gap(FwSpacing.md),
              _Note(
                'No base branch: none of origin/HEAD, main or master '
                'resolved here, so there is nothing to compare against. '
                'Showing uncommitted work only.',
              ),
            ],
            // Ranking by rules that have since been edited is worth one line.
            // Nothing is said in the fresh case: a screen that narrates its
            // cache on every load is one whose important message goes unread.
            if (ResolvedChangesConfig(null, it.configState).notice
                case var why?) ...[
              const Gap(FwSpacing.md),
              _Note(why),
            ],
            if (it.isEmpty) ...[
              const Gap(FwSpacing.md),
              _Note('Nothing changed against ${it.base ?? 'the base'}.'),
            ],
          ],
        ],
      ),
    );
  }
}

/// Says whether the screen is still listening — three words, no timer.
///
/// Deliberately not an age that counts up. "14s ago" needs a ticker
/// rebuilding the header every second for a number that means nothing on a
/// screen which refreshes when the checkout moves and not otherwise: on a quiet
/// worktree it would climb to "40m ago" and read as broken. What you actually
/// want to know is whether it will still notice, so that is what it says, and
/// the exact clock time of the last read is in the tooltip for the one moment
/// you want it.
///
/// The failed case gets its own words. A watch can be refused — the checkout
/// was deleted under us, or the system is out of watches — and *that* is the
/// state where the screen quietly stops being true.
///
/// It says nothing about a read in progress, which it tried to and should
/// not: a probe is 60–195 ms, so the word would be an unreadable flicker,
/// and on the one load slow enough to see — the first — the summary below is
/// already saying `Reading…`. Two of that word in one header, six pixels apart,
/// meaning different things.
class _Watching extends StatelessWidget {
  const _Watching({
    required this.live,
    required this.isWatching,
    required this.readAt,
  });

  final bool live;
  final bool isWatching;
  final DateTime? readAt;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (!live) return const SizedBox.shrink();
    var stale = !isWatching;
    return Tooltip(
      message: stale
          ? 'This checkout is not being watched — refresh to read it again'
          : 'Re-read whenever this checkout changes'
                '${readAt == null ? '' : '\nLast read at ${_clock(readAt!)}'}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: stale ? colors.mut3 : colors.grn,
            ),
          ),
          const Gap(FwSpacing.xs),
          Text(
            stale ? 'Not watching' : 'Watching',
            style: context.type.micro.copyWith(
              color: stale ? colors.mut2 : colors.mut3,
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';
}

/// Re-read, as an icon the size of the line it sits on.
///
/// Not an `IconButton`. Material's minimum tap target is 40 px tall, which
/// is more than twice the 18 px of text beside it — under a tab strip it was
/// the only thing setting the header's height, and the band was 65 px to hold
/// one line. A pointer does not need a thumb's target.
class _Refresh extends StatelessWidget {
  const _Refresh({required this.onTap});

  /// Null while a read is in flight.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: 'Read this checkout again',
      child: Tappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.xs),
          child: Icon(
            Icons.refresh,
            size: FwIconSize.md,
            color: onTap == null ? colors.mut3 : colors.mut,
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary(this.set, {this.showBase = true});

  final ChangeSet? set;

  /// False under the comparison strip, which states the base for all three
  /// tabs. `base master (inferred)` under `against origin/master` is one fact
  /// spelled two ways, and a reader who notices the difference has to work out
  /// whether it is one.
  final bool showBase;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var style = context.type.bodySmall;
    if (set case var it?) {
      var uncommitted = it.changed
          .where((f) => it.uncommitted.contains(f.path))
          .length;
      return Wrap(
        spacing: FwSpacing.md,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('${it.changed.length} files', style: style),
          Text('+${it.added}', style: style.copyWith(color: colors.grn)),
          Text('-${it.removed}', style: style.copyWith(color: colors.red)),
          if (uncommitted > 0)
            Text(
              '$uncommitted uncommitted',
              style: style.copyWith(color: colors.amber),
            ),
          // **`no base` is said either way**: it is not a duplicate of the
          // strip's `against <base>` — it is the reason every count beside it
          // is smaller than it looks, and the one state where the two halves
          // of this screen can be answering different questions.
          if (it.baseSource == BaseSource.none)
            Text('no base', style: style.copyWith(color: colors.mut2))
          else if (showBase)
            Text(switch (it.baseSource) {
              BaseSource.configured => 'base ${it.base} (configured)',
              BaseSource.inferred => 'base ${it.base} (inferred)',
              BaseSource.none => '',
            }, style: style.copyWith(color: colors.mut2)),
        ],
      );
    }
    return Text('Reading…', style: style.copyWith(color: colors.mut2));
  }
}

/// The **index**: filter, two tabs, and the paths.
///
/// Navigation only. Nothing here is content, which is the reason for the
/// split — the list stays where you left it while you read, and a live re-probe
/// that adds a file changes this column without moving a line of what is open.
///
/// Two orderings, one column, so two tabs. *All* is a directory tree, which
/// is what navigation wants: structure, ordered by weight inside it, so an
/// agent's heaviest module is the first thing under each folder. *Important* is
/// the ranking's answer — flat, short, in rank order, nothing folded, because a
/// list of four files has no shape to communicate and folding it would only
/// hide it.
///
/// They were one column before this, the pinned files in a band above the tree,
/// and using it settled the argument: two lists arguing for the top of a 320 px
/// column, with the band still taking that space on branches where it had
/// nothing to say.
class _IndexPane extends StatelessWidget {
  const _IndexPane({
    required this.set,
    required this.tab,
    required this.controller,
    required this.query,
    required this.selected,
    required this.onTab,
    required this.onQuery,
    required this.onSelect,
    required this.visible,
    required this.review,
    required this.selectedComment,
    required this.deleted,
    required this.onUndoDelete,
    required this.drifted,
    required this.onOpenComment,
    required this.onDeleteComment,
    required this.onCommentReview,
    required this.onExport,
    required this.composing,
    required this.editing,
    required this.draft,
    required this.onSubmit,
    required this.onCancel,
    required this.unseen,
    required this.showResolved,
    required this.onShowResolved,
  });

  final ChangeSet set;
  final IndexTab tab;

  final ScrollController controller;
  final String query;
  final String? selected;
  final ValueChanged<IndexTab> onTab;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSelect;
  final Set<String>? visible;

  final ReviewState review;

  /// The comment the composer is currently rewriting, if any.
  final String? selectedComment;

  /// The note whose delete is being held. Its row is the undo strip.
  final String? deleted;
  final VoidCallback onUndoDelete;

  final bool Function(ReviewComment) drifted;
  final ValueChanged<ReviewComment> onOpenComment;
  final ValueChanged<String> onDeleteComment;
  final VoidCallback onCommentReview;
  final VoidCallback onExport;

  /// Notes the agent resolved since you last looked at this tab. Drawn whatever
  /// [showResolved] says.
  final Set<String> unseen;

  final bool showResolved;
  final ValueChanged<bool> onShowResolved;

  /// A [ReviewWide] anchor is written here rather than in the body, because it
  /// is about no file and the body is one file's diff. Any other anchor is the
  /// body's to draw.
  final ReviewAnchor? composing;
  final bool editing;
  final TextEditingController draft;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // Unfiltered, because a tab label is a claim about the checkout and not
    // about the box you are typing in. A count that drops to 0 as you type
    // makes the other tab look like the place the file went.
    var pinned = buildImportantRows(set).length;

    // **This pane keeps an 8 px gutter where the rest of the screen uses
    // [panelGutter]'s 24**, so its content starts 16 px left of the page title
    // above it. That step is deliberate, not an oversight: the column is a
    // fixed 320 px and 24 px gutters would spend 48 px of it on air, in a list
    // whose file names already ellipsise. A panel narrow enough to be a list
    // is allowed its own gutter; a wider one is not.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(FwSpacing.md),
          child: TextField(
            onChanged: onQuery,
            style: context.type.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter paths',
              hintStyle: context.type.bodySmall.copyWith(color: colors.mut3),
              prefixIcon: Icon(
                Icons.search,
                size: FwIconSize.md,
                color: colors.mut3,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 26),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.sm,
                vertical: FwSpacing.sm,
              ),
            ),
          ),
        ),
        _Tabs(
          tab: tab,
          all: set.changed.length + set.untracked.length,
          important: pinned,
          review: _liveCount,
          answered: unseen.isNotEmpty,
          onTab: onTab,
        ),
        Expanded(
          child: switch (tab) {
            IndexTab.all => _all(context),
            IndexTab.important => _important(context),
            IndexTab.review => _review(context),
          },
        ),
        if (tab == IndexTab.review)
          _ReviewFooter(
            count: _liveCount,
            onExport: onExport,
            onCommentReview: onCommentReview,
          ),
      ],
    );
  }

  /// Notes still outstanding, which is what the tab's count and the footer
  /// mean.
  int get _liveCount =>
      review.unresolved.where((comment) => comment.id != deleted).length;

  /// The resolved notes this tab is drawing: the ones the agent answered while
  /// you were away, always — and the rest when you ask for them.
  List<ReviewComment> get _resolvedShown => [
    for (var comment in review.resolved)
      if (showResolved || unseen.contains(comment.id)) comment,
  ];

  /// What is outstanding, what was answered while you were away, and — on
  /// request — everything else that has been answered.
  Widget _review(BuildContext context) {
    // A whole-review note is about no file, so it quotes nothing — the one
    // composer on this screen with only its header above the text.
    var wide = composing is ReviewWide
        ? ReviewComposer(
            anchor: const ReviewWide(),
            controller: draft,
            editing: editing,
            inset: FwSpacing.md,
            onSubmit: onSubmit,
            onCancel: onCancel,
          )
        : null;
    if (review.isEmpty && wide == null) return const _NoComments();
    // Numbered over the live ones only — the number is what you say out loud
    // to the agent, so a held delete must not leave a gap in it, and neither
    // may a note that has been answered.
    var number = 0;
    var resolved = _resolvedShown;
    var answeredCount = review.resolved.length;
    return ListView(
      key: changesListKey,
      controller: controller,
      children: [
        ?wide,
        for (var comment in review.unresolved)
          if (comment.id == deleted)
            ReviewUndoStrip(inset: FwSpacing.md, onUndo: onUndoDelete)
          else
            ReviewIndexRow(
              number: ++number,
              comment: comment,
              selected: comment.id == selectedComment,
              drifted: drifted(comment),
              onTap: () => onOpenComment(comment),
            ),
        if (resolved.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.md,
              FwSpacing.lg,
              FwSpacing.md,
              FwSpacing.xs,
            ),
            child: Text('Resolved', style: context.type.caption),
          ),
          for (var comment in resolved)
            ReviewIndexRow(
              comment: comment,
              selected: comment.id == selectedComment,
              unseen: unseen.contains(comment.id),
              onTap: () => onOpenComment(comment),
            ),
        ],
        // **The disclosure, where the handed-off list used to be.** It is the
        // same question in the same place — *what has already been dealt with*
        // — and the only one on this tab that is about the past.
        if (answeredCount > resolved.length || showResolved)
          _ResolvedToggle(
            count: answeredCount,
            on: showResolved,
            onTap: () => onShowResolved(!showResolved),
          ),
      ],
    );
  }

  /// Everything in the delta: the tree — tracked and untracked files alike —
  /// and then the untracked directories, which have no shape to put in it.
  Widget _all(BuildContext context) {
    var tree = buildTree(
      treeFiles(set, visible: visible),
      untracked: treeUntracked(set, visible: visible),
    );
    var untracked = buildUntrackedDirectoryRows(
      set,
      selected: selected,
      visible: visible,
    );
    if (tree.totalFiles == 0 && untracked.isEmpty) {
      // Two silences: a checkout with no delta at all, and a filter that
      // matched none of one — the icon is the quicker way to tell them apart.
      return set.changed.isEmpty
          ? const _Nothing('Nothing to show.', icon: Icons.check_circle_outline)
          : const _Nothing('Nothing matches.');
    }
    // **Not virtualised, deliberately.** The index is the file count, not the
    // line count — a 228-file branch is a few hundred rows, where the list it
    // replaced could be four thousand. A tree that remembers which folders are
    // open cannot be rebuilt by index anyway.
    return ListView(
      key: changesListKey,
      controller: controller,
      children: [
        if (tree.totalFiles > 0)
          _TreeNodeView(
            node: tree,
            depth: 0,
            selected: selected,
            ranking: set.ranking,
            onSelect: onSelect,
            // Open at the top, shut further down: a branch that touched one
            // module wants that module visible, and a repo of forty
            // directories does not want all of them unfolded at once.
            openDepth: 1,
          ),
        for (var row in untracked) _flat(context, row),
      ],
    );
  }

  /// What a rule pinned, and nothing else.
  Widget _important(BuildContext context) {
    var rows = buildImportantRows(set, selected: selected, visible: visible);
    if (rows.isEmpty) {
      // Two different silences, and telling them apart is the whole reason
      // `attentionConfigured` exists: a project that has never written a rule
      // is looking at a feature that appears not to work, and a project whose
      // rules matched nothing is looking at good news.
      return set.attentionConfigured
          ? const _Nothing(
              'No file matched an attention rule.',
              icon: Icons.push_pin_outlined,
            )
          : const _NoRulesYet();
    }
    return ListView(
      key: changesListKey,
      controller: controller,
      children: [for (var row in rows) _flat(context, row)],
    );
  }

  Widget _flat(BuildContext context, ChangeRow row) => switch (row) {
    SectionRow(:var label) => Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.md,
        FwSpacing.lg,
        FwSpacing.md,
        FwSpacing.xs,
      ),
      child: Text(
        label,
        style: context.type.caption,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    FileRow(:var file, :var selected, :var reason) => IndexFileRow(
      file: file,
      selected: selected,
      reason: reason,
      onTap: () => onSelect(file.path),
    ),
    UntrackedRow(:var entry, :var selected) => IndexUntrackedRow(
      entry: entry,
      selected: selected,
      onTap: entry.isDirectory ? null : () => onSelect(entry.path),
    ),
    // The body's rows never reach the index. A comment does have a row here,
    // but it is `ReviewIndexRow` — a numbered, two-line summary, not the
    // thread the diff draws.
    HunkRow() ||
    DiffLineRow() ||
    FileNoticeRow() ||
    CommentRow() ||
    ComposerRow() => const SizedBox.shrink(),
  };
}

/// The three tabs, with their counts.
///
/// The count is what justifies the tab. A tab's cost is that half the time
/// it is hiding what it holds; a number on the label means the Important tab
/// still says *there are four files a rule pinned* without being opened, which
/// is most of what the band it replaces was for.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.tab,
    required this.all,
    required this.important,
    required this.review,
    required this.answered,
    required this.onTab,
  });

  final IndexTab tab;
  final int all;
  final int important;
  final int review;

  /// The agent has resolved something you have not looked at.
  final bool answered;

  final ValueChanged<IndexTab> onTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.line)),
      ),
      // **Intrinsic widths, packed left**, like the strip above this pane.
      // Measured in the running app: the three tabs take 194 px of the 320 px
      // column (40 + 85 + 69), and ~236 px with three-digit counts on all of
      // them, so the width they were sharing was never scarce. Sharing it put
      // a 107 px accent underline beneath a 15 px word and left each label
      // stranded mid-third, aligned with nothing — and the thirds were not
      // even buying centred labels, because the [Flexible] around each label
      // consumed the free space its own row was trying to centre in.
      //
      // **[Wrap], not [Row], and the reason is the test binding.** This strip
      // really does overflow 320 px under `flutter test` — by 7.8 px — because
      // that binding loads no font and its fallback measures every glyph far
      // wider than the system font does: 327.8 px for the same three labels
      // that measure 194 px on screen. That is where the *thirds are the only
      // thing that fits* reading came from; it was a measurement of the test
      // font, not of the app. [Wrap] answers both — natural widths in one run
      // here, a second run rather than an assertion wherever the labels really
      // are too wide.
      child: Wrap(
        children: [
          _Tab(
            label: 'All',
            count: all,
            on: tab == IndexTab.all,
            onTap: () => onTab(IndexTab.all),
          ),
          _Tab(
            label: 'Important',
            count: important,
            on: tab == IndexTab.important,
            onTap: () => onTab(IndexTab.important),
          ),
          _Tab(
            label: 'Review',
            count: review,
            on: tab == IndexTab.review,
            onTap: () => onTab(IndexTab.review),
            // The one count on this strip that is about you rather than about
            // the checkout, so it keeps the accent whichever tab is open: it is
            // how many notes are outstanding, and that is worth seeing from the
            // *All* tab.
            live: review > 0,
            // **The agent has answered something.** Not folded into the count,
            // which means *still to do* — an answered note is the opposite of
            // that, and adding the two would make a number that says neither.
            alert: answered,
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.count,
    required this.on,
    required this.onTap,
    this.live = false,
    this.alert = false,
  });

  final String label;
  final int count;
  final bool on;
  final VoidCallback onTap;

  /// Keeps the count in the accent even when the tab is not the open one.
  final bool live;

  /// Something arrived here that you have not seen. A dot after the count —
  /// deliberately not a second number, which would read as more work.
  final bool alert;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      child: Container(
        // The horizontal padding is the column's own gutter, so the first
        // label starts on the same 8 px as the filter field above and every
        // file name below it, and two tabs sit 16 px apart.
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border(
            // Two pixels, drawn where the divider is, so the selected tab
            // sits on the list it is naming. It now runs the label's width
            // rather than a third of the pane, so it marks the word.
            bottom: BorderSide(
              color: on ? colors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              label,
              style: context.type.bodySmall.copyWith(
                color: on ? colors.accent : colors.mut2,
              ),
              softWrap: false,
            ),
            const Gap(FwSpacing.xs),
            Text(
              '$count',
              style: context.type.micro.copyWith(
                color: on || live ? colors.accent : colors.mut3,
              ),
            ),
            if (alert) ...[
              const Gap(FwSpacing.xs),
              Icon(Icons.circle, size: 6, color: colors.accent),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the **Review** tab says before anything has been written.
///
/// It names the gesture, because nothing else on the screen advertises it:
/// the `+` in the margin is drawn on hover, which is the right call for a list
/// of three thousand rows and the wrong one for discovery.
///
/// [EmptyState], like every other *nothing here yet* in the app. This screen
/// had four hand-built ones, each with its own icon size, type and alignment —
/// four answers to a question the app had already answered once.
class _NoComments extends StatelessWidget {
  const _NoComments();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.mode_comment_outlined,
    title: 'No comments yet',
    // Not *hover a line*: the margin is a live target whether or not a pointer
    // is over it, and saying otherwise sends people looking for a hover state
    // they do not need.
    message:
        'Click the + in a diff line’s margin to leave one for the agent. '
        'Shift-click a second line to cover a span.',
  );
}

/// The Review tab's foot.
///
/// Pinned below the list rather than at the end of it. Twelve comments
/// would put the action below the fold, which is the one place a primary action
/// may not be.
///
/// Primary, not loud. It was a solid full-bleed accent slab with the
/// second action as a 10.5 px link under it — between them the heaviest and
/// nearly the lightest thing on the screen, for two actions a note-taker
/// alternates between. The house primary is [FwActionButton]'s: an accent
/// border over [FwPalette.accentSoft], which is emphatic in a panel of greys
/// without being the loudest object in the app.
///
/// It is Export, and it is no longer what the tab is for. The gesture that
/// used to close a batch here has been replaced by an agent that reads the log
/// itself and resolves what it deals with, so this button now serves the case
/// where the reader is somewhere flutterware cannot reach.
class _ReviewFooter extends StatelessWidget {
  const _ReviewFooter({
    required this.count,
    required this.onExport,
    required this.onCommentReview,
  });

  final int count;
  final VoidCallback onExport;
  final VoidCallback onCommentReview;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.all(FwSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tappable.builder(
            onTap: count == 0 ? null : onExport,
            builder: (context, hovered) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(vertical: FwSpacing.md),
              decoration: BoxDecoration(
                color: count == 0
                    ? null
                    : hovered
                    ? colors.accentSoft2
                    : colors.accentSoft,
                borderRadius: BorderRadius.circular(context.radii.radius),
                border: Border.all(
                  color: count == 0 ? colors.line : colors.accent,
                ),
              ),
              child: Text(
                count == 0
                    ? 'Nothing outstanding'
                    : 'Export $count '
                          '${count == 1 ? 'comment' : 'comments'}',
                textAlign: TextAlign.center,
                style: context.type.caption.copyWith(
                  color: count == 0 ? colors.mut3 : colors.accent,
                ),
              ),
            ),
          ),
          const Gap(FwSpacing.sm),
          // The third anchor, and the only one with nowhere else to be
          // offered: *three of these are the same problem* is about the review,
          // not about any line in it. `caption`, matching the button above it —
          // these are two things you alternate between, not a control and its
          // footnote.
          Tappable.builder(
            onTap: onCommentReview,
            builder: (context, hovered) => Padding(
              padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
              child: Text(
                'Comment on the whole review',
                textAlign: TextAlign.center,
                style: context.type.caption.copyWith(
                  color: hovered ? colors.accent : colors.mut,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// *Resolved (12)*, opening and closing the answered notes.
///
/// A row in the list rather than a control in the chrome. It sits where the
/// handed-off section used to start, which is where the eye already goes for
/// *what is already dealt with* — and it costs nothing on a tab with nothing
/// resolved, because it is not drawn at all.
class _ResolvedToggle extends StatelessWidget {
  const _ResolvedToggle({
    required this.count,
    required this.on,
    required this.onTap,
  });

  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable.builder(
      onTap: onTap,
      builder: (context, hovered) => Container(
        color: hovered ? colors.hoverOverlay : null,
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              on ? Icons.expand_less : Icons.expand_more,
              size: FwIconSize.md,
              color: colors.mut3,
            ),
            const Gap(FwSpacing.sm),
            Text(
              on ? 'Hide resolved' : 'Resolved ($count)',
              style: context.type.caption.copyWith(
                color: hovered ? colors.ink : colors.mut2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line, centred, for a list that has nothing in it.
class _Nothing extends StatelessWidget {
  const _Nothing(this.message, {this.icon = Icons.filter_alt_off_outlined});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      EmptyState(icon: icon, title: message, minHeight: 0);
}

/// What the **Important** tab says to a project that has never written an
/// `attention:` rule.
///
/// There are no built-in ones, so without this the tab is empty and the
/// whole ranking reads as a feature that does not work. It is the empty state
/// rather than a line above the list, which is where it used to sit: a note
/// that a band could not fit is a full pane's worth of room here, and it can
/// say the whole thing.
class _NoRulesYet extends StatelessWidget {
  const _NoRulesYet();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return EmptyState(
      icon: Icons.push_pin_outlined,
      title: 'Nothing is pinned yet',
      message: 'Name what you want to see first in tool/flutterware.dart:',
      minHeight: 0,
      // **The snippet is the action.** Everything else here is a sentence
      // about a file you have to open anyway; this is the line you paste into
      // it. Bordered like the quote a comment carries, because it is the same
      // thing — code sitting inside prose.
      action: Container(
        padding: const EdgeInsets.all(FwSpacing.md),
        decoration: BoxDecoration(
          color: colors.panel2,
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          border: Border.all(color: colors.line),
        ),
        child: SelectableText(
          "fw.changes(ChangesConfig(\n  attention: ['lib/api/**'],\n));",
          style: diffTextStyle(context).copyWith(color: colors.mut),
        ),
      ),
    );
  }
}

/// One directory, and everything under it.
///
/// Stateful for the same reason the version before the rewrite was: which
/// folders you have opened is yours, and it has to survive the rebuild that a
/// live re-probe causes every couple of seconds.
class _TreeNodeView extends StatefulWidget {
  const _TreeNodeView({
    required this.node,
    required this.depth,
    required this.selected,
    required this.ranking,
    required this.onSelect,
    required this.openDepth,
  });

  final TreeNode node;
  final int depth;
  final String? selected;

  /// So a pinned file can say, where it lives, what pinned it.
  final Ranking ranking;

  final ValueChanged<String> onSelect;
  final int openDepth;

  @override
  State<_TreeNodeView> createState() => _TreeNodeViewState();
}

class _TreeNodeViewState extends State<_TreeNodeView> {
  /// `<=`, not `<`: depth 0 is the root, which is the tree rather than a row in
  /// it, so the first directory anybody sees is at depth 1. Off by that one and
  /// every top-level folder opens shut, which looks exactly like an empty
  /// index.
  late var _open = widget.depth <= widget.openDepth;

  @override
  Widget build(BuildContext context) {
    var node = widget.node;
    var colors = context.colors;
    // The root is the tree, not a row in it.
    var isRoot = widget.depth == 0 && node.path.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isRoot)
          Tappable(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              // **A row you can hit.** Two pixels above and below a 14 px line
              // is a 18 px target between two other targets, and the folder is
              // the row you click most: it is the only one that folds.
              padding: EdgeInsets.only(
                left: FwSpacing.md + (widget.depth - 1) * FwSpacing.lg,
                right: FwSpacing.md,
                top: FwSpacing.sm,
                bottom: FwSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    _open ? Icons.expand_more : Icons.chevron_right,
                    size: FwIconSize.sm,
                    color: colors.mut3,
                  ),
                  Expanded(
                    child: Text(
                      node.name,
                      style: context.type.bodySmall.copyWith(color: colors.mut),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Gap(FwSpacing.xs),
                  Text(
                    '${node.totalFiles}',
                    style: context.type.micro.copyWith(color: colors.mut3),
                  ),
                ],
              ),
            ),
          ),
        if (isRoot || _open) ...[
          for (var child in node.sortedChildren)
            _TreeNodeView(
              node: child,
              depth: widget.depth + 1,
              selected: widget.selected,
              ranking: widget.ranking,
              onSelect: widget.onSelect,
              openDepth: widget.openDepth,
            ),
          for (var leaf in node.sortedLeaves)
            Padding(
              padding: EdgeInsets.only(
                left: isRoot ? 0 : widget.depth * FwSpacing.lg,
              ),
              child: _leaf(leaf),
            ),
        ],
      ],
    );
  }

  /// One row under this directory: a file in the patch, or an untracked one.
  ///
  /// **Neither draws its directory.** Its position already says where it is,
  /// and repeating the path is what the tree exists to remove.
  Widget _leaf(TreeLeaf leaf) => switch (leaf) {
    ChangedLeaf(:var file) => _fileRow(file),
    // An untracked entry carries its own pin. It never reached the ranking,
    // which is built from the patch — see `attentionForUntracked`.
    UntrackedLeaf(:var entry) => IndexUntrackedRow(
      entry: entry,
      selected: entry.path == widget.selected,
      pinned: entry.isPinned,
      showDirectory: false,
      onTap: () => widget.onSelect(entry.path),
    ),
  };

  Widget _fileRow(FileChange file) {
    var ranked = widget.ranking.forPath(file.path);
    return IndexFileRow(
      file: file,
      selected: file.path == widget.selected,
      // The second place attention is surfaced: a pinned file says what pinned
      // it here too, where you are browsing, not only in the tab you may not
      // have opened.
      reason: ranked?.reason,
      pinned: ranked?.tier == RankTier.attention,
      showDirectory: false,
      onTap: () => widget.onSelect(file.path),
    );
  }
}

/// The **body**: one file's diff, or the reason there is not one.
class _FilePane extends StatefulWidget {
  const _FilePane({
    required this.file,
    required this.untracked,
    required this.missing,
    required this.uncommitted,
    required this.contents,
    required this.baseRevision,
    required this.readAt,
    required this.lines,
    required this.tokens,
    required this.controller,
    required this.comments,
    required this.composing,
    required this.editing,
    required this.draft,
    required this.drifted,
    required this.deleted,
    required this.flash,
    required this.reveal,
    required this.revealSeq,
    required this.editingQuote,
    required this.onUndoDelete,
    required this.onCommentLine,
    required this.onCommentTextLine,
    required this.onCommentFile,
    required this.onSubmit,
    required this.onCancel,
    required this.onEditComment,
    required this.onDeleteComment,
    required this.onResolveComment,
    required this.onUnresolveComment,
  });

  final FileChange? file;
  final UntrackedEntry? untracked;

  /// The path the address named, so a selection that no longer exists can say
  /// so instead of falling silently back to nothing.
  final String? missing;

  final Set<String> uncommitted;

  /// Where the bodies a diff cannot draw get their bytes.
  final FileContentStore contents;

  /// The revision the delta is measured from — an image differ's base side.
  /// Null when nothing resolved, in which case no base is claimed.
  final String? baseRevision;

  /// When the probe last read the worktree. The new-side bodies key their
  /// reload on it, which is what carries an in-place overwrite of a file whose
  /// patch did not move — a tracked file's working-tree side, edited and then
  /// edited back, and every untracked one before the probe stamped them.
  final DateTime? readAt;

  final HunkLineCache lines;

  /// Null when nothing is selected, and carrying a null language for a file
  /// this build has no grammar for.
  final HunkTokenCache? tokens;

  final ScrollController controller;

  /// Every open comment. Filtered to this file here rather than upstream, so
  /// the pane owns the one decode cache the placement needs.
  final List<ReviewComment> comments;

  final ReviewAnchor? composing;
  final bool editing;
  final TextEditingController draft;
  final bool Function(ReviewComment) drifted;

  /// The note whose delete is being held. Drawn as the undo strip, in its own
  /// place in the diff rather than as a bar somewhere else on the screen.
  final String? deleted;
  final VoidCallback onUndoDelete;

  /// The note to draw in the accent, having just been arrived at.
  final String? flash;

  /// The note to scroll to, and the nth time it has been asked for.
  final String? reveal;
  final int revealSeq;

  /// The quote the open composer shows while rewriting an existing comment.
  /// Null when it is writing a new one, which reads the patch.
  final List<String>? editingQuote;

  final void Function(FileChange, DiffLine) onCommentLine;

  /// The same, for a body that draws a file's own lines rather than a diff of
  /// them: a path and a 1-based line number, which is all an untracked file
  /// has and all this anchor needs.
  final void Function(String path, int line) onCommentTextLine;

  final ValueChanged<String> onCommentFile;

  /// Takes the quote the composer was showing — see `_submitComment`.
  final ValueChanged<List<String>> onSubmit;

  final VoidCallback onCancel;
  final ValueChanged<ReviewComment> onEditComment;
  final ValueChanged<String> onDeleteComment;
  final ValueChanged<String> onResolveComment;
  final ValueChanged<String> onUnresolveComment;

  @override
  State<_FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends State<_FilePane> {
  /// A key per thread on screen, so a built one can be brought into view
  /// exactly. Keyed by comment id and cleared with the file, because a key
  /// that outlives its widget is a key whose `currentContext` lies.
  final _threads = <String, GlobalKey>{};

  /// The reveal request already served, so a rebuild does not re-scroll.
  int? _served;

  /// Where each thread this build drew sits in the body's flat row list, and
  /// how many rows there are — what [_revealNow] estimates an offset from.
  ///
  /// Both bodies fill this: a diff's rows and an untracked file's lines are
  /// two flat lists, and a note in either can be four hundred rows down.
  var _threadRow = <String, int>{};
  var _bodyRows = 0;

  /// The open untracked file's lines and their colours.
  ///
  /// Keyed on the [FileBytes] **object**, which the content store re-hands
  /// unchanged until the file's mtime or size moves — so identity here means
  /// exactly *the file has not changed*, and the split text and the tokeniser's
  /// parsed chunks survive as long as that is true. Not keyed on the probe's
  /// `readAt`, which moves every couple of seconds on a checkout nobody is
  /// touching and would throw the colours away under a reader.
  ({List<String> lines, LazyLineTokens? tokens})? _text;
  FileBytes? _textFor;

  /// How far right the code column is, shared by every row it draws.
  final _scrollX = DiffScrollX();

  /// One character's advance in the diff face, measured when the face changes
  /// rather than per row. Monospace, so a line's width is its length times it.
  double _charWidth = 0;
  TextStyle? _measuredFor;

  /// How many times a reveal re-estimates before giving up.
  ///
  /// A virtualised list can only be scrolled to an *offset*, and the offset of
  /// row 900 is not knowable until rows near it are built. Each pass gets
  /// closer, because `maxScrollExtent` is itself refined by whatever the last
  /// jump built.
  static const _revealTries = 4;

  /// Which face of the selected file the body shows, when it has two. Null is
  /// the default for its kind; reset with the selection, because *Rendered* is
  /// an answer about one file, not a mode the pane enters.
  FileBodyView? _view;

  @override
  void didUpdateWidget(_FilePane old) {
    super.didUpdateWidget(old);
    // A new file is a new set of line lengths, and a position 400 px in would
    // open it on whatever happens to sit at that column.
    var was = old.file?.path ?? old.untracked?.path;
    var showing = widget.file?.path ?? widget.untracked?.path;
    if (was != showing) {
      _scrollX.reset();
      _view = null;
    }
    _scheduleReveal();
  }

  @override
  void dispose() {
    _scrollX.dispose();
    _threads.clear();
    super.dispose();
  }

  /// One character's width in the diff face, measured once per face.
  double _measure(BuildContext context) {
    var style = diffTextStyle(context);
    if (_measuredFor == style) return _charWidth;
    // Ten of them, so the answer is not a rounding of one.
    var painter = TextPainter(
      text: TextSpan(text: 'M' * 10, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    _measuredFor = style;
    return _charWidth = painter.width / 10;
  }

  void _scheduleReveal() {
    if (widget.reveal == null || widget.revealSeq == _served) return;
    _served = widget.revealSeq;
    // After this frame: the file may have only just been selected, so the rows
    // holding the note do not exist yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealNow(widget.reveal!, _revealTries);
    });
  }

  void _revealNow(String id, int tries) {
    if (!mounted || tries <= 0) return;
    if (_threads[id]?.currentContext case var target?) {
      // A third of the way down, not at the very top: a note is read together
      // with the lines above it.
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: const Duration(milliseconds: 180),
        ),
      );
      return;
    }
    var index = _threadRow[id];
    var controller = widget.controller;
    if (index == null || !controller.hasClients || _bodyRows == 0) return;
    var position = controller.position;
    var estimate = position.maxScrollExtent * (index / _bodyRows);
    controller.jumpTo(estimate.clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealNow(id, tries - 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.file case var it?) return _filePage(context, it);

    if (widget.untracked case var it?) {
      if (it.isDirectory) {
        return _Empty(
          icon: Icons.folder_outlined,
          title: it.path,
          body:
              'An untracked directory. Nothing here has been scanned — see '
              'the note on the changes list.',
        );
      }
      return _untrackedPage(context, it);
    }

    if (widget.missing case var it?) {
      return _Empty(
        icon: Icons.search_off,
        title: it,
        body:
            'This file is no longer part of the delta — it may have been '
            'committed away, reverted, or renamed.',
      );
    }

    return const _Empty(
      icon: Icons.difference_outlined,
      title: 'Pick a file',
      body:
          'All shows every path in this delta, as a tree. Important shows '
          'what a rule in tool/flutterware.dart pinned.',
    );
  }

  /// One tracked file's body: its diff, its pixels, or its rendered face.
  Widget _filePage(BuildContext context, FileChange it) {
    var kind = fileBodyKind(it.path);

    // An image's diff is one line saying "binary". The pixels are the body.
    if (kind == FileBodyKind.image) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FileHeader(
            file: it,
            uncommitted: widget.uncommitted.contains(it.path),
            onComment: () => widget.onCommentFile(it.path),
          ),
          Divider(height: 1, color: context.colors.line),
          Expanded(
            child: ImageChangeBody(
              store: widget.contents,
              path: it.path,
              oldPath: it.oldPath,
              status: it.status,
              baseRevision: widget.baseRevision,
              refreshedAt: widget.readAt,
              leading: _leadingFor(it.path),
            ),
          ),
        ],
      );
    }

    // Markdown and SVG carry a second face. A deleted file does not: its
    // working-tree side is gone, and the diff already shows what left.
    var faces =
        (kind == FileBodyKind.markdown || kind == FileBodyKind.svg) &&
        it.status != ChangeStatus.deleted;
    var view =
        _view ??
        // Rendered by default only for a *new* markdown file, whose all-`+`
        // diff says nothing the index has not already said. A modified one
        // opens on its diff — the change is what review is about.
        (kind == FileBodyKind.markdown && it.status == ChangeStatus.added
            ? FileBodyView.rendered
            : FileBodyView.source);

    if (!faces || view == FileBodyView.source) {
      return _diffPage(context, it, kind: kind, faces: faces, view: view);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FileHeader(
          file: it,
          uncommitted: widget.uncommitted.contains(it.path),
          onComment: () => widget.onCommentFile(it.path),
          view: view,
          renderedLabel: _renderedLabel(kind),
          onView: (v) => setState(() => _view = v),
        ),
        Divider(height: 1, color: context.colors.line),
        Expanded(
          child: FileContentBuilder(
            signature: (it.path, widget.readAt),
            load: () => widget.contents.onDisk(
              it.path,
              maxBytes: ChangesLimits.textContentBytes,
            ),
            builder: (context, content) => switch (content) {
              FileBytes f when kind == FileBodyKind.svg => SvgFileBody(
                bytes: f.bytes,
                leading: _leadingFor(it.path, composerQuote: _patchQuote(it)),
              ),
              FileBytes f => MarkdownFileBody(
                content: f.text,
                imageDirectory: _imageDirectoryOf(it.path),
                leading: _leadingFor(it.path, composerQuote: _patchQuote(it)),
              ),
              FileMissing() => const FileBodyNotice(
                'Not on disk any more — Source still shows the diff.',
              ),
              FileTooLarge(:var length) => FileBodyNotice(
                'This file is ${bytesLabel(length)} — past what the viewer '
                'renders. Source still shows the diff.',
              ),
            },
          ),
        ),
      ],
    );
  }

  /// The diff, exactly as it has always been drawn — plus the toggle when the
  /// file has a rendered face to switch to.
  Widget _diffPage(
    BuildContext context,
    FileChange it, {
    required FileBodyKind kind,
    required bool faces,
    required FileBodyView view,
  }) {
    var rows = _rowsFor(it);
    _threadRow = {
      for (var (index, row) in rows.indexed)
        if (row is CommentRow) row.comment.id: index,
    };
    _bodyRows = rows.length;
    var lines = widget.lines;
    // The lines the composer's anchor covers, so you can see what you picked
    // while you write about it. Resolved per line rather than per span
    // because a span crosses hunks and its two ends are two lookups anyway.
    var span = <RowSpot>{
      if (widget.composing case LineAnchor a when a.path == it.path)
        for (var line = a.from; line <= a.to; line++)
          ?spotOf(it, line, a.side, lines.linesFor),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FileHeader(
          file: it,
          uncommitted: widget.uncommitted.contains(it.path),
          onComment: () => widget.onCommentFile(it.path),
          view: faces ? view : null,
          renderedLabel: _renderedLabel(kind),
          onView: faces ? (v) => setState(() => _view = v) : null,
        ),
        Divider(height: 1, color: context.colors.line),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // What the code column actually has to itself: the gutters and
              // the comment margin are pinned, so they are not part of the
              // window the offset is clamped against.
              _scrollX.setViewport(constraints.maxWidth - diffChromeWidth);
              return _body(context, rows, lines, span, it);
            },
          ),
        ),
        DiffScrollBar(model: _scrollX),
      ],
    );
  }

  /// An untracked file's body. There is no diff to draw — git has no other
  /// side — but there is a file, and showing it beats a placeholder that says
  /// every line is new without showing one of them.
  ///
  /// Everything a diff body offers over its lines is offered here: the syntax
  /// colours, the `+` in the margin, and threads drawn under the line they are
  /// about. What git can say about a file is not what you can say about it.
  Widget _untrackedPage(BuildContext context, UntrackedEntry it) {
    var kind = fileBodyKind(it.path);
    var faces = kind == FileBodyKind.markdown || kind == FileBodyKind.svg;
    var view =
        _view ??
        // A new markdown file opens rendered — the same rule as a tracked
        // one. An SVG opens on its source: rendering is the second question.
        (kind == FileBodyKind.markdown
            ? FileBodyView.rendered
            : FileBodyView.source);

    Widget body;
    if (kind == FileBodyKind.image) {
      body = ImageChangeBody(
        store: widget.contents,
        path: it.path,
        status: ChangeStatus.added,
        refreshedAt: widget.readAt,
        leading: _leadingFor(it.path),
      );
    } else {
      body = FileContentBuilder(
        signature: (it.path, widget.readAt),
        load: () => widget.contents.onDisk(
          it.path,
          maxBytes: ChangesLimits.textContentBytes,
        ),
        builder: (context, content) => switch (content) {
          FileMissing() => const FileBodyNotice('No longer on disk.'),
          FileTooLarge(:var length) => FileBodyNotice(
            'This file is ${bytesLabel(length)} — past what the viewer '
            'reads. Open it in your editor.',
          ),
          FileBytes f when faces && view == FileBodyView.rendered =>
            kind == FileBodyKind.svg
                ? SvgFileBody(
                    bytes: f.bytes,
                    leading: _leadingFor(
                      it.path,
                      composerQuote: _diskQuote(it.path, f),
                    ),
                  )
                : MarkdownFileBody(
                    content: f.text,
                    imageDirectory: _imageDirectoryOf(it.path),
                    leading: _leadingFor(
                      it.path,
                      composerQuote: _diskQuote(it.path, f),
                    ),
                  ),
          // The one sniff worth doing: no patch has classified this file, and
          // a NUL-ridden blob drawn as monospace rows is a screen of tofu.
          FileBytes f when looksBinary(f.bytes) => FileBodyNotice(
            'Binary file — ${bytesLabel(f.bytes.length)}, and no text to '
            'draw.',
          ),
          FileBytes f => _untrackedText(context, it.path, f),
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _UntrackedHeader(
          entry: it,
          view: faces ? view : null,
          renderedLabel: _renderedLabel(kind),
          onView: faces ? (v) => setState(() => _view = v) : null,
          onComment: () => widget.onCommentFile(it.path),
        ),
        Divider(height: 1, color: context.colors.line),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _scrollX.setViewport(constraints.maxWidth - textChromeWidth);
              return body;
            },
          ),
        ),
        // Invisible unless the text body reported lines wider than the pane.
        DiffScrollBar(model: _scrollX),
      ],
    );
  }

  /// An untracked file's lines, with what has been said about them woven in.
  ///
  /// The twin of [_rowsFor], and the same rule: a note whose line this file no
  /// longer has is drawn at the top rather than dropped — that happens exactly
  /// when the agent rewrote the file out from under it, which is the moment
  /// the note matters, and it still carries the code it was written about.
  Widget _untrackedText(BuildContext context, String path, FileBytes bytes) {
    var text = _textOf(bytes, path);

    // Everything drawn between the lines, in the order it will appear. Built
    // as one list so the row each thread lands on can be counted for a reveal
    // — see [_indexThreads].
    var leading = <({String? id, Widget row})>[];
    var attached = <({int line, String? id, Widget row})>[];

    // A line anchor is placeable only if this file still has that line, and
    // only on the side those numbers are counted on: an untracked file has no
    // *before*, so a note carrying one is about a file that has since been
    // committed and is drawn at the top.
    int? lineOf(ReviewAnchor anchor) => switch (anchor) {
      LineAnchor(:var to, :var side)
          when side == ReviewSide.after && to >= 1 && to <= text.lines.length =>
        to,
      _ => null,
    };

    for (var comment in widget.comments) {
      if (comment.anchor.path != path) continue;
      var row = comment.id == widget.deleted
          ? ReviewUndoStrip(onUndo: widget.onUndoDelete)
          : ReviewThread(
              key: _threads[comment.id] ??= GlobalKey(),
              comment: comment,
              drifted: widget.drifted(comment),
              highlighted: comment.id == widget.flash,
              onEdit: () => widget.onEditComment(comment),
              onDelete: () => widget.onDeleteComment(comment.id),
              onResolve: () => widget.onResolveComment(comment.id),
              onUnresolve: () => widget.onUnresolveComment(comment.id),
            );
      if (lineOf(comment.anchor) case var line?) {
        attached.add((line: line, id: comment.id, row: row));
      } else {
        leading.add((id: comment.id, row: row));
      }
    }

    if (widget.composing case var anchor? when anchor.path == path) {
      var row = _composer(
        anchor,
        widget.editingQuote ?? _diskQuote(path, bytes),
      );
      if (lineOf(anchor) case var line?) {
        attached.add((line: line, id: null, row: row));
      } else {
        leading.add((id: null, row: row));
      }
    }

    // Stable, so two notes on one line keep the order they were written in.
    attached.sort((a, b) => a.line.compareTo(b.line));
    _indexThreads(leading, attached, lines: text.lines.length);

    var placed = <int, List<Widget>>{};
    for (var item in attached) {
      (placed[item.line] ??= []).add(item.row);
    }

    return TextFileBody(
      lines: text.lines,
      tokens: text.tokens,
      scrollX: _scrollX,
      charWidth: _measure(context),
      controller: widget.controller,
      leading: [for (var item in leading) item.row],
      placed: placed,
      selected: switch (widget.composing) {
        LineAnchor a when a.path == path && a.side == ReviewSide.after => {
          for (var line = a.from; line <= a.to; line++) line,
        },
        _ => const {},
      },
      onComment: (line) => widget.onCommentTextLine(path, line),
    );
  }

  /// The lines a line anchor covers, read from the patch.
  ///
  /// For the rendered face of a tracked file, where the composer can be open
  /// on a line the body is not drawing — you picked it in *Source* and
  /// switched. It quotes what it would have quoted there rather than nothing.
  List<String> _patchQuote(FileChange file) {
    if (widget.composing case LineAnchor a when a.path == file.path) {
      return quoteFor(file, a.from, a.to, a.side, widget.lines.linesFor);
    }
    return const [];
  }

  /// The lines a line anchor covers, read from the file on disk.
  ///
  /// The untracked half of [quoteFor], and the only reading of it there is:
  /// nothing in the patch has these lines, so the composer's own copy is what
  /// the comment will carry.
  List<String> _diskQuote(String path, FileBytes bytes) {
    if (widget.composing case LineAnchor a when a.path == path) {
      if (a.side == ReviewSide.before) return const [];
      var lines = _textOf(bytes, path).lines;
      return [
        for (var line = a.from; line <= a.to; line++)
          if (line >= 1 && line <= lines.length) lines[line - 1],
      ];
    }
    return const [];
  }

  /// What the second face is called: an SVG is *previewed*, prose is
  /// *rendered*. One word each, shown beside `Source` in the toggle.
  static String _renderedLabel(FileBodyKind kind) =>
      kind == FileBodyKind.svg ? 'Preview' : 'Rendered';

  /// The composer, wherever it is drawn.
  ///
  /// One place, because the quote is the thing three bodies would otherwise
  /// each have to remember to pass on twice: **what it shows is what it
  /// stores**, and that is true by construction here rather than by two
  /// readings of the same span agreeing.
  Widget _composer(ReviewAnchor anchor, List<String> quote) => ReviewComposer(
    anchor: anchor,
    controller: widget.draft,
    editing: widget.editing,
    quote: quote,
    onSubmit: () => widget.onSubmit(quote),
    onCancel: widget.onCancel,
  );

  /// This file's lines and their colours, split and prepared once per version
  /// of the file. See [_text] for what "version" means here.
  ///
  /// Nothing is tokenised by this call: [LazyLineTokens] parses forward as
  /// rows ask for it, so opening a four-thousand-line file costs one split.
  ({List<String> lines, LazyLineTokens? tokens}) _textOf(
    FileBytes bytes,
    String path,
  ) {
    if (!identical(_textFor, bytes)) {
      _textFor = bytes;
      var lines = _linesOf(bytes.text);
      var language = languageForPath(path);
      _text = (
        lines: lines,
        tokens: language == null
            ? null
            : LazyLineTokens(lines, language: language),
      );
    }
    return _text!;
  }

  /// Which row of the untracked body each thread lands on.
  ///
  /// One line of the file is one row, so a thread's row is the leading rows,
  /// plus its own line number, plus everything already inserted above it. The
  /// arithmetic is here rather than inside [TextFileBody] because a reveal has
  /// to know it *before* the list has built a single one of those rows.
  void _indexThreads(
    List<({String? id, Widget row})> leading,
    List<({int line, String? id, Widget row})> attached, {
    required int lines,
  }) {
    _threadRow = {
      for (var (index, item) in leading.indexed) ?item.id: index,
      for (var (inserted, item) in attached.indexed)
        ?item.id: leading.length + item.line + inserted,
    };
    _bodyRows = leading.length + lines + attached.length;
  }

  /// Comment threads and the composer, for a body with no diff rows to weave
  /// them into. They draw at the top — the same place a diff puts a comment
  /// whose line could not be found, and *about this file* means the same
  /// thing over pixels as over three hundred lines.
  ///
  /// [composerQuote] is what the composer will store if it is submitted from
  /// here — empty for a body with no lines to quote, which is most of them.
  List<Widget> _leadingFor(
    String path, {
    List<String> composerQuote = const [],
  }) {
    var rows = <Widget>[];
    for (var comment in widget.comments) {
      if (comment.anchor.path != path) continue;
      rows.add(
        comment.id == widget.deleted
            ? ReviewUndoStrip(onUndo: widget.onUndoDelete)
            : ReviewThread(
                key: _threads[comment.id] ??= GlobalKey(),
                comment: comment,
                drifted: widget.drifted(comment),
                highlighted: comment.id == widget.flash,
                onEdit: () => widget.onEditComment(comment),
                onDelete: () => widget.onDeleteComment(comment.id),
                onResolve: () => widget.onResolveComment(comment.id),
                onUnresolve: () => widget.onUnresolveComment(comment.id),
              ),
      );
    }
    if (widget.composing case var anchor? when anchor.path == path) {
      rows.add(_composer(anchor, widget.editingQuote ?? composerQuote));
    }
    return rows;
  }

  /// Where a relative image reference in this file's markdown points: its own
  /// directory in the worktree, spelled the way flutter_markdown concatenates
  /// it — absolute, with a trailing slash.
  String _imageDirectoryOf(String path) {
    var slash = path.lastIndexOf('/');
    var directory = slash < 0 ? '' : '${path.substring(0, slash)}/';
    return '${widget.contents.worktreePath}/$directory';
  }

  static List<String> _linesOf(String text) {
    var lines = text.split('\n');
    // The artefact of splitting on a final newline, not a line of the file.
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  /// The rows themselves.
  ///
  /// One [SelectionArea] over the whole body. Nothing in a diff was
  /// selectable: the rows are `Text`, and the app has no selection region
  /// anywhere — so the one thing everybody does with a line of code, take it
  /// somewhere else, could not be done here at all. It wraps the list rather
  /// than each row, because a selection that cannot cross a line is not a
  /// selection of code.
  Widget _body(
    BuildContext context,
    List<ChangeRow> rows,
    HunkLineCache lines,
    Set<RowSpot> span,
    FileChange it,
  ) {
    var charWidth = _measure(context);
    return Listener(
      // Trackpad and shift-wheel, which is how a horizontal scroll arrives.
      // Read rather than claimed: the vertical list is resolving the same
      // event for its own axis, and both of us are entitled to our half of it.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && event.scrollDelta.dx != 0) {
          _scrollX.moveBy(event.scrollDelta.dx);
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.panDelta.dx != 0) _scrollX.moveBy(-event.panDelta.dx);
      },
      child: SelectionArea(
        child: ListView.builder(
          key: changesFileKey,
          controller: widget.controller,
          itemCount: rows.length,
          itemBuilder: (context, index) => switch (rows[index]) {
            HunkRow(:var hunk) => HunkHeaderLine(hunk: hunk),
            // The one place a byte slice becomes text, and it happens for
            // the rows the list actually builds.
            DiffLineRow(:var hunk, :var index) => HunkLineView(
              lines: lines,
              hunk: hunk,
              index: index,
              tokens: widget.tokens,
              scrollX: _scrollX,
              charWidth: charWidth,
              selected: span.contains((
                hunkStart: hunk.byteStart,
                index: index,
              )),
              onComment: (line) => widget.onCommentLine(it, line),
            ),
            CommentRow(:var comment, :var drifted) =>
              comment.id == widget.deleted
                  ? ReviewUndoStrip(onUndo: widget.onUndoDelete)
                  : ReviewThread(
                      // The key is what `ensureVisible` needs, and it is
                      // only ever right for a thread that is on screen —
                      // see [_threads].
                      key: _threads[comment.id] ??= GlobalKey(),
                      comment: comment,
                      drifted: drifted,
                      highlighted: comment.id == widget.flash,
                      onEdit: () => widget.onEditComment(comment),
                      onDelete: () => widget.onDeleteComment(comment.id),
                      onResolve: () => widget.onResolveComment(comment.id),
                      onUnresolve: () => widget.onUnresolveComment(comment.id),
                    ),
            ComposerRow(:var anchor) => _composer(
              anchor,
              // The composer shows the same lines the diff has just tinted
              // behind it, and hands exactly those to the submit — see
              // `_submitComment`, which used to read them a second time.
              widget.editingQuote ??
                  (anchor is LineAnchor
                      ? quoteFor(
                          it,
                          anchor.from,
                          anchor.to,
                          anchor.side,
                          lines.linesFor,
                        )
                      : const []),
            ),
            FileNoticeRow(:var message) => Padding(
              padding: const EdgeInsets.all(FwSpacing.xxl),
              child: Text(
                message,
                style: context.type.bodySmall.copyWith(
                  color: context.colors.mut2,
                ),
              ),
            ),
            _ => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }

  /// This file's rows, with what has been said about it woven in.
  ///
  /// A comment whose line could not be found is drawn at the top of the
  /// file rather than dropped. It happens when the agent rewrote the hunk out
  /// from under it, which is exactly the moment the note matters — and it still
  /// carries the code it was written about, so it reads on its own.
  List<ChangeRow> _rowsFor(FileChange file) {
    var lines = widget.lines;
    var mine = [
      for (var comment in widget.comments)
        if (comment.anchor.path == file.path) comment,
    ];
    var placed = <RowSpot, List<CommentRow>>{};
    var unplaced = <ChangeRow>[];

    for (var comment in mine) {
      var row = CommentRow(comment, drifted: widget.drifted(comment));
      if (comment.anchor case LineAnchor anchor) {
        if (spotOf(file, anchor.to, anchor.side, lines.linesFor)
            case var spot?) {
          (placed[spot] ??= []).add(row);
          continue;
        }
      }
      unplaced.add(row);
    }

    var composer = <RowSpot, ComposerRow>{};
    if (widget.composing case var anchor? when anchor.path == file.path) {
      var row = ComposerRow(anchor);
      var spot = anchor is LineAnchor
          ? spotOf(file, anchor.to, anchor.side, lines.linesFor)
          : null;
      if (spot == null) {
        unplaced.add(row);
      } else {
        composer[spot] = row;
      }
    }

    return buildFileRows(
      file,
      placed: placed,
      composer: composer,
      fileComments: unplaced,
    );
  }
}

/// What the right pane says when it has nothing to draw.
///
/// The whole body of the screen, so it is the most visible empty state there
/// is — and it was the one with no icon, left-aligned prose at two greys,
/// resembling nothing else in the app.
class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.body, required this.icon});

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: EmptyState(icon: icon, title: title, message: body, minHeight: 0),
    ),
  );
}

/// The right pane's own header: which file, and what it costs.
class _FileHeader extends StatelessWidget {
  const _FileHeader({
    required this.file,
    required this.uncommitted,
    required this.onComment,
    this.view,
    this.onView,
    this.renderedLabel = 'Rendered',
  });

  final FileChange file;
  final bool uncommitted;

  /// Not every note has a line. *No test covers this* is about the file,
  /// and a line-only tool forces it into a lie about line 1.
  final VoidCallback onComment;

  /// Which face the body is on, when this file has two. Null draws no toggle.
  final FileBodyView? view;
  final ValueChanged<FileBodyView>? onView;
  final String renderedLabel;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var slash = file.path.lastIndexOf('/');
    var directory = slash < 0 ? '' : file.path.substring(0, slash + 1);
    var name = slash < 0 ? file.path : file.path.substring(slash + 1);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xxl,
        FwSpacing.lg,
        FwSpacing.xxl,
        FwSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // **Name first, directory after it, dimmed** — the same rule the
          // explorer's card settled on. The name is the column you scan; a
          // directory-first row leaves the names on a ragged left edge.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // **The name and its directory are one flexible thing, and the
              // button is the other.** They used to be three peers — two
              // [Flexible]s and a [Spacer], each with the default flex of 1 —
              // so the free space was split in thirds and the [Spacer] only
              // ever pushed the button a third of the way over. Measured on a
              // root file in a 950 px header: the button ended 323 px short of
              // the right edge, reading as floating rather than trailing.
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: context.type.bodyStrong,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                    if (directory.isNotEmpty) ...[
                      const Gap(FwSpacing.sm),
                      Flexible(
                        child: Text(
                          directory,
                          style: context.type.micro.copyWith(
                            color: colors.mut3,
                          ),
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Gap(FwSpacing.md),
              if (view case var it? when onView != null) ...[
                _ViewToggle(
                  view: it,
                  onView: onView!,
                  renderedLabel: renderedLabel,
                ),
                const Gap(FwSpacing.md),
              ],
              _CommentOnFileButton(onTap: onComment),
            ],
          ),
          const Gap(FwSpacing.xs),
          _FileCounts(file: file, uncommitted: uncommitted),
        ],
      ),
    );
  }

  static String _statusWord(ChangeStatus status) => statusWord(status);
}

class _FileCounts extends StatelessWidget {
  const _FileCounts({required this.file, required this.uncommitted});

  final FileChange file;
  final bool uncommitted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Wrap(
      spacing: FwSpacing.md,
      children: [
        Text(
          _FileHeader._statusWord(file.status),
          style: context.type.micro.copyWith(color: colors.mut2),
        ),
        if (file.oldPath case var from?)
          Text(
            'from $from',
            style: context.type.micro.copyWith(color: colors.mut2),
          ),
        Text(
          '+${file.added}',
          style: context.type.micro.copyWith(color: colors.grn),
        ),
        Text(
          '-${file.removed}',
          style: context.type.micro.copyWith(color: colors.red),
        ),
        if (uncommitted)
          Text(
            'uncommitted',
            style: context.type.micro.copyWith(color: colors.amber),
          ),
        if (file.hunks.isNotEmpty)
          Text(
            '${file.hunks.length} '
            '${file.hunks.length == 1 ? 'hunk' : 'hunks'}',
            style: context.type.micro.copyWith(color: colors.mut3),
          ),
        // **Nothing here says anything about colour**, and that is the point of
        // the chunked tokeniser: there is no size at which this screen quietly
        // stops colouring, so there is nothing to announce. It briefly had a
        // `not coloured · 1109-line hunk` note beside a 500-line cap — a note
        // that existed only because the cap did.
      ],
    );
  }
}

/// The header's one action, shared by the tracked and untracked headers so
/// the same gesture cannot drift into two spellings.
class _CommentOnFileButton extends StatelessWidget {
  const _CommentOnFileButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.xs,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          border: Border.all(color: colors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mode_comment_outlined,
              size: FwIconSize.sm,
              color: colors.mut2,
            ),
            const Gap(FwSpacing.xs),
            Text(
              'Comment on this file',
              style: context.type.micro.copyWith(color: colors.mut),
            ),
          ],
        ),
      ),
    );
  }
}

/// `Source ⇄ Rendered`, in the header. Two labelled segments rather than an
/// icon pair: the words are the whole explanation, and the header has the
/// room.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.view,
    required this.onView,
    required this.renderedLabel,
  });

  final FileBodyView view;
  final ValueChanged<FileBodyView> onView;

  /// What the second face is called for this kind of file.
  final String renderedLabel;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, 'Source', FileBodyView.source),
          Container(width: 1, height: 22, color: colors.line),
          _segment(context, renderedLabel, FileBodyView.rendered),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, FileBodyView value) {
    var selected = view == value;
    return Tappable(
      // The selected segment is inert rather than disabled-looking: pressing
      // the face you are on is not an error, it is just already true.
      onTap: selected ? null : () => onView(value),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.xs,
        ),
        color: selected ? context.colors.accentSoft : null,
        child: Text(
          label,
          style: context.type.micro.copyWith(
            color: selected ? null : context.colors.mut,
          ),
        ),
      ),
    );
  }
}

/// The right pane's header for an untracked file — the same anatomy as
/// [_FileHeader] with the one honest difference: there are no counts,
/// because there is no other side to count against.
class _UntrackedHeader extends StatelessWidget {
  const _UntrackedHeader({
    required this.entry,
    required this.onComment,
    this.view,
    this.onView,
    this.renderedLabel = 'Rendered',
  });

  final UntrackedEntry entry;
  final VoidCallback onComment;
  final FileBodyView? view;
  final ValueChanged<FileBodyView>? onView;
  final String renderedLabel;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var slash = entry.path.lastIndexOf('/');
    var directory = slash < 0 ? '' : entry.path.substring(0, slash + 1);
    var name = slash < 0 ? entry.path : entry.path.substring(slash + 1);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xxl,
        FwSpacing.lg,
        FwSpacing.xxl,
        FwSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: context.type.bodyStrong,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                    if (directory.isNotEmpty) ...[
                      const Gap(FwSpacing.sm),
                      Flexible(
                        child: Text(
                          directory,
                          style: context.type.micro.copyWith(
                            color: colors.mut3,
                          ),
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Gap(FwSpacing.md),
              if (view case var it? when onView != null) ...[
                _ViewToggle(
                  view: it,
                  onView: onView!,
                  renderedLabel: renderedLabel,
                ),
                const Gap(FwSpacing.md),
              ],
              _CommentOnFileButton(onTap: onComment),
            ],
          ),
          const Gap(FwSpacing.xs),
          Wrap(
            spacing: FwSpacing.md,
            children: [
              Text(
                'untracked',
                style: context.type.micro.copyWith(color: colors.amber),
              ),
              Text(
                'no other side to diff against',
                style: context.type.micro.copyWith(color: colors.mut2),
              ),
              if (entry.reason case var it?)
                Text(it, style: context.type.micro),
            ],
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        color: colors.hoverOverlay,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(
        text,
        style: context.type.bodySmall.copyWith(color: colors.mut),
      ),
    );
  }
}
