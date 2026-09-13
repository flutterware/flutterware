/// The screen's live handle on the review log.
///
/// Split from [ReviewStore] rather than sitting beside it, because the store is
/// read by `fw` and by the MCP server — both of which are compiled without
/// Flutter, and one `package:flutter/foundation.dart` import for a
/// [ChangeNotifier] would make the whole log unreachable from them. The purity
/// of those entry points is a guarded test, not a preference.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'review_comment.dart';
import 'review_store.dart';

/// The screen's handle on the log.
///
/// Deliberately thin: it holds the folded state, and every mutation is an
/// append followed by the re-read the append already does. There is no
/// in-memory list that the file is a backup of, because two such lists on one
/// machine is exactly the divergence the append-only format exists to avoid.
///
/// It watches the file. The agent writes resolutions into this log while the
/// window is open — that is what the feature is for — so a controller that only
/// re-read on its own writes would spend most of a session showing a state that
/// has moved on, hiding the receipt this feature exists to give you.
class ReviewController extends ChangeNotifier {
  ReviewController({
    required String worktreePath,
    ReviewStore? store,
    bool watch = true,
  }) : _store = store ?? ReviewStore.forWorktree(worktreePath),
       _watching = watch {
    _state = _store.read();
    if (watch) _watch();
  }

  final ReviewStore _store;

  /// Whether this controller is allowed to watch at all. Off for a test that
  /// would otherwise put a watch on a real directory to prove something else —
  /// the same rule, and the same flag, as the checkout watch beside it.
  final bool _watching;
  late ReviewState _state;
  StreamSubscription<void>? _watcher;

  ReviewState get state => _state;
  List<ReviewComment> get comments => _state.comments;
  List<ReviewComment> get unresolved => _state.unresolved;

  /// Comments on [path], in the order they were written.
  ///
  /// Resolved ones included: the diff draws what the list is showing, and a
  /// note that vanished from the code while still being listed beside it would
  /// be the two halves of one screen disagreeing.
  List<ReviewComment> forFile(String path) => [
    for (var comment in _state.comments)
      if (comment.anchor.path == path) comment,
  ];

  void add(ReviewComment comment) => _apply([CommentAdded(comment)]);

  void edit(String id, String body) =>
      _apply([CommentEdited(id: id, body: body)]);

  void delete(String id) => _apply([CommentDeleted(id)]);

  /// Deals with a note. [by] is recorded rather than assumed — this same log is
  /// written by the agent's own surface.
  void resolve(
    String id, {
    ReviewActor by = ReviewActor.human,
    String? message,
    DateTime? at,
  }) => _apply([
    CommentResolved(
      id: id,
      resolution: ReviewResolution(
        by: by,
        at: at ?? DateTime.now(),
        message: message,
      ),
    ),
  ]);

  void unresolve(String id) => _apply([CommentUnresolved(id)]);

  /// Records that the Review tab has been looked at.
  ///
  /// Once per visit, and only when there is something to mark. A log with
  /// no unseen agent resolution in it learns nothing from another line, and
  /// this is called from a widget's lifecycle: the version that wrote
  /// unconditionally appended one line per tab switch, forever.
  void markSeen({DateTime? at}) {
    if (_state.unseenResolutions.isEmpty) return;
    _apply([ReviewSeen(at ?? DateTime.now())]);
  }

  /// Re-reads without writing — for a window that has been sitting open while
  /// another one, or the agent, was used.
  void reload() {
    _state = _store.read();
    notifyListeners();
  }

  /// The parent, not the file. A watch cannot be placed on something that does
  /// not exist, and a checkout with no comments has no log until the first
  /// note. The directory is this checkout's own — see
  /// [FileReviewStore.fileFor] — so the traffic is this log and its neighbours,
  /// not a tree.
  ///
  /// And it does not create it. Creating the directory to watch it would mean
  /// every screen ever opened leaves a permanent empty directory under
  /// `~/.flutterware`, one per checkout, for a review that was never written. Writing the
  /// first note creates it, and [_apply] arms the watch then.
  void _watch() {
    // Only a file can be watched; a memory log has no other writer.
    var store = _store;
    if (store is! FileReviewStore) return;
    var parent = store.file.parent;
    if (!parent.existsSync()) return;
    try {
      _watcher = parent
          .watch()
          .where((event) => p.equals(event.path, store.file.path))
          .listen((_) => reload());
    } on Object {
      // A platform without watches, or a home that will not take one. The
      // screen still works; it just will not notice the agent until something
      // else makes it read — which is why arriving at the tab re-reads.
    }
  }

  void _apply(List<ReviewEvent> events) {
    _state = _store.append(events);
    // The first note is what creates the directory, so it is also the first
    // moment there is anything to watch.
    if (_watching && _watcher == null) _watch();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_watcher?.cancel());
    super.dispose();
  }
}
