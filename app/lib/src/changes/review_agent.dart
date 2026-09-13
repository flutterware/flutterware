/// The review log, as `fw` and the MCP server see it.
///
/// The reason this file exists is a report. A human left a note on a line
/// of a config file and asked whether the agent could read it. It could — by
/// knowing from a commit message that notes live in an append-only JSONL log,
/// guessing that *outside the repository* meant `~/.flutterware`, and searching
/// for a file whose name contained `review`. The note had been sitting unread
/// for a day. Notes were a shell feature rather than a plugin, so they appeared
/// in neither `flutterware_status` nor `flutterware_actions`, and a project that
/// declared three plugins got three plugins and no hint that a fourth kind of
/// thing existed.
///
/// So: one function that says *there are notes, and here is where*, on the call
/// every client is told to start with, and one that hands them over with ids to
/// answer them by.
///
/// Pure Dart. Both callers are compiled without Flutter — see the purity test
/// on the CLI entry point — which is also why [ReviewController] lives in its
/// own file rather than beside the store.
library;

import 'review_comment.dart';
import 'review_store.dart';

/// What a status reply says about a checkout's notes.
///
/// Always present, even at zero. A count of nothing is what tells a reader
/// that notes exist at all and where they would be — which is the half of the
/// report that cost a day, and it costs three keys to answer forever.
Map<String, Object?> reviewStatusJson(String worktreePath) {
  var store = FileReviewStore.forWorktree(worktreePath);
  var state = store.read();
  return {
    'unresolved': state.unresolved.length,
    'resolved': state.resolved.length,
    'log': store.file.path,
  };
}

/// The notes, for a reader that is going to answer them.
///
/// [all] includes the ones already dealt with, which is the audit read rather
/// than the working one.
Map<String, Object?> reviewListJson(
  String worktreePath, {
  required String worktree,
  String? base,
  bool all = false,
}) {
  var store = FileReviewStore.forWorktree(worktreePath);
  var state = store.read();
  var comments = all
      ? [...state.unresolved, ...state.resolved]
      : state.unresolved;
  return {
    'worktree': worktree,
    'log': store.file.path,
    'unresolved': state.unresolved.length,
    'resolved': state.resolved.length,
    // **Markdown, with the ids in it.** The alternative is this list twice —
    // once as prose to read and once as records to address — and the second
    // copy is pure cost: every field it carries is already a line of the first.
    'notes': comments.isEmpty
        ? null
        : reviewMarkdown(
            comments,
            worktree: worktree,
            base: base,
            withIds: true,
          ),
  };
}

/// Deals with one note, or says why it could not.
///
/// [ReviewActor.agent] is not a parameter. This is the surface an agent
/// calls, and letting a caller declare itself the human would make the one
/// distinction the resolution carries — *who says this is dealt with* —
/// something the log cannot be trusted about.
Map<String, Object?> reviewResolveJson(
  String worktreePath,
  String id, {
  String? message,
  bool resolve = true,
}) {
  var store = FileReviewStore.forWorktree(worktreePath);
  var state = store.read();
  var comment = state.comments.where((c) => c.id == id).firstOrNull;
  if (comment == null) {
    // The ids that *are* there, because the usual cause is a stale list — the
    // note was deleted, or this is the wrong worktree's log.
    return {
      'error': 'no note "$id" in this checkout',
      'ids': [for (var c in state.unresolved) c.id],
      'log': store.file.path,
    };
  }
  var after = store.append([
    if (resolve)
      CommentResolved(
        id: id,
        resolution: ReviewResolution(
          by: ReviewActor.agent,
          at: DateTime.now(),
          message: message,
        ),
      )
    else
      CommentUnresolved(id),
  ]);
  return {
    'id': id,
    'resolved': resolve,
    'note': comment.anchor.label,
    'unresolved': after.unresolved.length,
  };
}
