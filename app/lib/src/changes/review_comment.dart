/// A note left on this delta for the agent that produced it.
///
/// A comment is an observation rather than a pointer. It carries the code it
/// was written about, quoted at the moment you wrote it, and the line numbers
/// are a hint beside that quote rather than the thing being stored. That is the
/// answer to *what happens when the agent keeps editing while I type*: nothing
/// happens, because nothing here addresses a line that can move. The receiving
/// agent relocates a three-line snippet better than any tracking we could write
/// against a [DiffLine], which has no identity, or a [HunkSpan], whose only key
/// is a byte range that any upstream edit invalidates.
///
/// Pure Dart — no widgets, no `dart:io` — so the model, the folding and the
/// markdown are all testable without pumping or writing a file.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Which side of the diff a line number is counted on.
///
/// A removed line exists only in the old file and an added line only in the
/// new one, so a comment on either has exactly one number that means anything.
/// Recording which avoids the classic off-by-a-whole-file error of printing an
/// old-side number as if you could open the file and find it there.
enum ReviewSide {
  /// Numbers on the left gutter: the file as the base branch has it.
  before,

  /// Numbers on the right gutter: the file as this checkout has it.
  after,
}

/// What a comment is about.
///
/// Three anchors, and no more. A line-only tool forces *this whole file is
/// untested* into a lie about line 1, and forces *three of these are the same
/// problem* into a lie about a file. Each of the three is a thing people
/// actually write, and each reads differently in the markdown.
sealed class ReviewAnchor {
  const ReviewAnchor();

  /// The file this comment is filed under, or null for [ReviewWide].
  String? get path;

  /// The whole thing — the grammar you would use to look it up, and the only
  /// spelling the markdown ever uses. An agent gets a path or it gets nothing.
  String get label;

  /// The part worth reading in a 320 px column: the file's name and the line.
  ///
  /// The directory is not dropped, it is [directory] — drawn beside this,
  /// dimmed, and the first thing given up when the row runs out of width.
  String get shortLabel {
    var slash = label.lastIndexOf('/');
    return slash < 0 ? label : label.substring(slash + 1);
  }

  /// Everything before [shortLabel], with its trailing slash, or null when the
  /// anchor names no directory.
  ///
  /// Drawn beside [shortLabel] where there is room for it — the composer — and
  /// given up entirely where there is not. The index row carries it in a
  /// tooltip instead: sharing a 320 px line, it ellipsised the name it was
  /// supposed to make room for.
  String? get directory {
    var slash = label.lastIndexOf('/');
    return slash < 0 ? null : label.substring(0, slash + 1);
  }

  Map<String, Object?> toJson();

  static ReviewAnchor fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'line' => LineAnchor(
          path: json['path']! as String,
          from: json['from']! as int,
          to: json['to']! as int,
          side: json['side'] == 'before' ? ReviewSide.before : ReviewSide.after,
        ),
        'file' => FileAnchor(json['path']! as String),
        _ => const ReviewWide(),
      };
}

/// One line, or a span of them.
final class LineAnchor extends ReviewAnchor {
  const LineAnchor({
    required this.path,
    required this.from,
    required this.to,
    required this.side,
  });

  @override
  final String path;

  /// Inclusive, and in the numbering [side] names.
  final int from;
  final int to;

  final ReviewSide side;

  bool get isSpan => to > from;

  @override
  String get label => isSpan ? '$path:$from–$to' : '$path:$from';

  @override
  Map<String, Object?> toJson() => {
    'kind': 'line',
    'path': path,
    'from': from,
    'to': to,
    'side': side.name,
  };
}

/// The file, with no line worth singling out.
final class FileAnchor extends ReviewAnchor {
  const FileAnchor(this.path);

  @override
  final String path;

  @override
  String get label => path;

  @override
  Map<String, Object?> toJson() => {'kind': 'file', 'path': path};
}

/// The review itself — the note that is about the shape of the change rather
/// than about any part of it.
final class ReviewWide extends ReviewAnchor {
  const ReviewWide();

  @override
  String? get path => null;

  @override
  String get label => 'Whole review';

  @override
  Map<String, Object?> toJson() => const {'kind': 'review'};
}

/// Who wrote something into the log.
///
/// Recorded on every resolution because *the agent says it did this* and *I
/// decided this is dealt with* are different claims, and a list that mixes them
/// silently is a list where you cannot tell which rows you are taking on faith.
enum ReviewActor {
  human,
  agent;

  static ReviewActor parse(Object? name) =>
      name == 'agent' ? ReviewActor.agent : ReviewActor.human;
}

/// A note is dealt with, and this records who did it.
///
/// A message rather than a status. There is no `done` / `declined` / `wontfix`
/// enum: the sentence carries the nuance, where a taxonomy invites picking
/// whichever label is closest. If a shape emerges from a year of real messages
/// it can be added over the data instead of over a guess.
class ReviewResolution {
  const ReviewResolution({required this.by, required this.at, this.message});

  final ReviewActor by;
  final DateTime at;

  /// What the resolver had to say — *did it*, or *I disagree, and here is why*.
  /// Optional, because a note you tick off yourself needs no words.
  final String? message;

  Map<String, Object?> toJson() => {
    'by': by.name,
    'at': at.toIso8601String(),
    if (message != null) 'message': message,
  };

  static ReviewResolution fromJson(Map<String, Object?> json) =>
      ReviewResolution(
        by: ReviewActor.parse(json['by']),
        at:
            DateTime.tryParse('${json['at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        message: json['message'] as String?,
      );
}

/// One note.
class ReviewComment {
  const ReviewComment({
    required this.id,
    required this.anchor,
    required this.body,
    required this.createdAt,
    this.quote = const [],
    this.fileDigest,
    this.resolution,
  });

  /// Unique within a worktree's log, and stable across a rewrite of the body —
  /// it is what a delete and an edit name.
  final String id;

  final ReviewAnchor anchor;

  /// What you wrote.
  final String body;

  final DateTime createdAt;

  /// The code as it stood when you wrote the comment, without diff markers.
  ///
  /// Kept as it was, forever. Re-reading it from the current patch would
  /// turn a note about a line the agent has since deleted into a note about
  /// whatever now occupies that position, which is the one failure mode a
  /// review tool must not have.
  final List<String> quote;

  /// A fingerprint of the file at capture time.
  ///
  /// The only drift claim we can make honestly: *this file changed after you
  /// commented*. Whether **your** line moved is not knowable from a patch, and
  /// a badge that claimed it would be wrong exactly when it mattered. Null for
  /// [ReviewWide], which is about no file.
  ///
  /// **Two kinds, and they are told apart rather than compared.** A tracked
  /// file's is a sha1 over its slice of the patch; an untracked file has no
  /// slice, so its is what a stat knows — see `untrackedStamp`, which carries
  /// the whole argument. Opaque here either way: this class stores it and the
  /// screen decides what it means.
  final String? fileDigest;

  /// Who dealt with this and what they said, or null while it is outstanding.
  ///
  /// Not written by the author of the comment, and not part of what a
  /// comment is: it arrives as its own event, from either side, minutes or days
  /// later. It lives on the comment because every reader wants the two
  /// together.
  final ReviewResolution? resolution;

  bool get isResolved => resolution != null;

  ReviewComment withBody(String body) => _copy(body: body);

  /// The same note, dealt with — or outstanding again when [resolution] is null.
  ReviewComment withResolution(ReviewResolution? resolution) =>
      _copy(resolution: resolution, keepResolution: false);

  ReviewComment _copy({
    String? body,
    ReviewResolution? resolution,
    bool keepResolution = true,
  }) => ReviewComment(
    id: id,
    anchor: anchor,
    body: body ?? this.body,
    createdAt: createdAt,
    quote: quote,
    fileDigest: fileDigest,
    resolution: keepResolution ? this.resolution : resolution,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'anchor': anchor.toJson(),
    'body': body,
    'createdAt': createdAt.toIso8601String(),
    if (quote.isNotEmpty) 'quote': quote,
    if (fileDigest != null) 'fileDigest': fileDigest,
  };

  static ReviewComment fromJson(Map<String, Object?> json) => ReviewComment(
    id: json['id']! as String,
    anchor: ReviewAnchor.fromJson(
      (json['anchor']! as Map).cast<String, Object?>(),
    ),
    body: json['body']! as String,
    createdAt:
        DateTime.tryParse('${json['createdAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    quote: [for (var line in json['quote'] as List? ?? const []) '$line'],
    fileDigest: json['fileDigest'] as String?,
  );
}

/// The fingerprint [ReviewComment.fileDigest] holds.
///
/// Over the file's own bytes of the patch rather than over the whole patch, so
/// an edit somewhere else in the branch does not mark every comment stale.
String digestOfPatchSlice(List<int> bytes) => sha1.convert(bytes).toString();

/// The notes, as markdown.
///
/// One format, every reader. The clipboard, the file and the reply the
/// agent's own tool hands back all render this — so there is one thing to keep
/// readable, one to test, and no way for what you previewed to differ from what
/// the agent got.
///
/// Fenced with the language guessed from the extension, because an agent that
/// gets ` ```dart ` reads the snippet as code on the first pass.
///
/// A resolved note carries its resolution under the body: who dealt with it and
/// what they said. In a list of unresolved notes there are none, and it costs
/// nothing; in the filter-off view it is what you came to read.
String reviewMarkdown(
  List<ReviewComment> comments, {
  required String worktree,
  String? base,
  DateTime? at,
  Set<String> drifted = const {},
  bool withIds = false,
}) {
  var buffer = StringBuffer()..writeln('# Review — $worktree');
  var meta = [
    if (base != null) 'Against `$base`',
    '${comments.length} ${comments.length == 1 ? 'comment' : 'comments'}',
    if (at != null) _clock(at),
  ];
  buffer
    ..writeln(meta.join(' · '))
    ..writeln();

  for (var comment in comments) {
    // The id rides in the heading for the reader that can act on a note — it is
    // what `resolve` is addressed by. Off for the export, where it is a serial
    // number in the middle of a sentence nobody can use.
    buffer.writeln(
      '## ${comment.anchor.label}${withIds ? ' · `${comment.id}`' : ''}',
    );
    if (comment.anchor.path case var path? when drifted.contains(path)) {
      buffer.writeln(
        '> ⚠ This file has changed since the comment was written. The quote '
        'below is as it stood then.',
      );
    }
    if (comment.quote.isNotEmpty) {
      buffer
        ..writeln('```${_language(comment.anchor.path)}')
        ..writeAll(comment.quote, '\n')
        ..writeln()
        ..writeln('```');
    }
    buffer.writeln(comment.body.trim());
    if (comment.resolution case var it?) {
      buffer.writeln(
        '\n— resolved by ${it.by == ReviewActor.agent ? 'the agent' : 'you'} '
        'at ${_clock(it.at)}'
        '${it.message == null ? '' : ': ${it.message!.trim()}'}',
      );
    }
    buffer.writeln();
  }

  return '${buffer.toString().trimRight()}\n';
}

String _clock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

/// The fence's language tag. Unknown extensions get no tag rather than a wrong
/// one — a mislabelled fence is worse for a reader than an unlabelled one.
String _language(String? path) {
  if (path == null) return '';
  var dot = path.lastIndexOf('.');
  if (dot < 0) return '';
  return switch (path.substring(dot + 1).toLowerCase()) {
    'dart' => 'dart',
    'yaml' || 'yml' => 'yaml',
    'json' => 'json',
    'md' => 'markdown',
    'sh' || 'bash' || 'zsh' => 'bash',
    'html' => 'html',
    'css' => 'css',
    'js' => 'javascript',
    'ts' => 'typescript',
    'kt' => 'kotlin',
    'swift' => 'swift',
    'java' => 'java',
    'py' => 'python',
    'sql' => 'sql',
    'xml' => 'xml',
    _ => '',
  };
}

/// One line of the append-only log, as it is written and read back.
///
/// Events rather than a snapshot. The alternative — a JSON document holding
/// the current list — is what `worktrees.json` is, and it has a documented
/// clobber history across Studio instances: two windows on one repository each
/// write the whole file, and the last one wins. An appended line physically
/// cannot revert another writer's line.
sealed class ReviewEvent {
  const ReviewEvent();

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson();

  /// Null for a line this version does not understand, which is how a log
  /// written by a newer build degrades to *the events I know* rather than to a
  /// crash on startup.
  static ReviewEvent? decode(String line) {
    try {
      var json = jsonDecode(line);
      if (json is! Map) return null;
      var map = json.cast<String, Object?>();
      return switch (map['event']) {
        'add' => CommentAdded(
          ReviewComment.fromJson((map['comment']! as Map).cast()),
        ),
        'edit' => CommentEdited(
          id: map['id']! as String,
          body: map['body']! as String,
        ),
        'delete' => CommentDeleted(map['id']! as String),
        'resolve' => CommentResolved(
          id: map['id']! as String,
          resolution: ReviewResolution.fromJson(map),
        ),
        'unresolve' => CommentUnresolved(map['id']! as String),
        'seen' => ReviewSeen(_at(map['at'])),
        'handoff' => BatchHandedOff(
          ids: [for (var id in map['ids'] as List? ?? const []) '$id'],
          at: _at(map['at']),
        ),
        _ => null,
      };
    } on Object {
      // A half-written final line, or a field a future version added and made
      // required. Neither is worth losing the rest of the log over.
      return null;
    }
  }

  static DateTime _at(Object? value) =>
      DateTime.tryParse('$value') ?? DateTime.fromMillisecondsSinceEpoch(0);
}

final class CommentAdded extends ReviewEvent {
  const CommentAdded(this.comment);
  final ReviewComment comment;

  @override
  Map<String, Object?> toJson() => {
    'event': 'add',
    'comment': comment.toJson(),
  };
}

final class CommentEdited extends ReviewEvent {
  const CommentEdited({required this.id, required this.body});
  final String id;
  final String body;

  @override
  Map<String, Object?> toJson() => {'event': 'edit', 'id': id, 'body': body};
}

/// A delete, as a tombstone rather than as a removal.
///
/// An append-only log cannot unwrite a line, and would not want to: the
/// tombstone is what makes two windows agree about a comment one of them
/// deleted.
final class CommentDeleted extends ReviewEvent {
  const CommentDeleted(this.id);
  final String id;

  @override
  Map<String, Object?> toJson() => {'event': 'delete', 'id': id};
}

/// A note that has been dealt with.
///
/// Either side writes this, which is the shape of the feature: you
/// tick off what you no longer need, and the agent reports what it did. Which
/// of the two it was is [ReviewResolution.by], and it is never inferred.
final class CommentResolved extends ReviewEvent {
  const CommentResolved({required this.id, required this.resolution});

  final String id;
  final ReviewResolution resolution;

  @override
  Map<String, Object?> toJson() => {
    'event': 'resolve',
    'id': id,
    ...resolution.toJson(),
  };
}

/// A resolution taken back.
///
/// Not symmetry for its own sake. It is how you recover a note the agent
/// closed by disagreeing with it, and how an agent backs out of a resolution it
/// wrote before its session was cut short. Without it the only repair for a
/// wrong resolve is writing the note again, which loses the quote it was about.
final class CommentUnresolved extends ReviewEvent {
  const CommentUnresolved(this.id);
  final String id;

  @override
  Map<String, Object?> toJson() => {'event': 'unresolve', 'id': id};
}

/// You have looked at the Review tab, as of this moment.
///
/// A marker, not per-note acknowledgement. What it protects against is an
/// agent resolving a note by disagreeing with it and the note vanishing into a
/// filter: a resolution the agent wrote after this marker is drawn whatever the
/// filter says. Per-note acknowledgement would do the same job and cost a click
/// per note forever, which is the hand-ticking this design exists to avoid.
///
/// Written at most once per visit to the tab — a write on draw is a smell, and
/// an unbounded one would be a bug.
final class ReviewSeen extends ReviewEvent {
  const ReviewSeen(this.at);
  final DateTime at;

  @override
  Map<String, Object?> toJson() => {
    'event': 'seen',
    'at': at.toIso8601String(),
  };
}

/// Read, never written. The batch handoff was how the previous version
/// closed notes, and a log that has been in use since then is full of these.
///
/// Ignoring them would resurface every note ever handed off as outstanding —
/// for a log of any age, that is all of them. So a handoff folds to what it
/// always meant in practice: you dealt with these, at that moment. `route` and
/// `savedTo` are dropped, because the question they answered — *why did the
/// agent not see this* — is one the agent no longer has to ask.
final class BatchHandedOff extends ReviewEvent {
  const BatchHandedOff({required this.ids, required this.at});

  final List<String> ids;
  final DateTime at;

  @override
  Map<String, Object?> toJson() =>
      throw UnsupportedError('handoff events are read, never written');
}

/// What a log folds down to: every note that still exists, and when you last
/// looked at them.
///
/// One list, not two. Resolved and outstanding are a property of a note
/// rather than two places a note can be — which is what makes *show the
/// resolved ones too* a filter instead of a second screen, and what makes
/// taking a resolution back a possibility rather than a migration.
class ReviewState {
  const ReviewState({this.comments = const [], this.seenAt});

  /// Every note, oldest first — the order they were written, which is the order
  /// they are numbered in.
  final List<ReviewComment> comments;

  /// When you last opened the Review tab, or null if this log has never been
  /// looked at. See [unseenResolutions].
  final DateTime? seenAt;

  /// What is still outstanding. The default view.
  List<ReviewComment> get unresolved => [
    for (var comment in comments)
      if (!comment.isResolved) comment,
  ];

  /// What has been dealt with, **newest resolution first** — the order you want
  /// when you turn the filter off, because the interesting one is the last
  /// thing that happened.
  List<ReviewComment> get resolved => [
    for (var comment in comments)
      if (comment.isResolved) comment,
  ]..sort((a, b) => b.resolution!.at.compareTo(a.resolution!.at));

  /// Notes the **agent** resolved since you last looked.
  ///
  /// These are drawn whatever the filter says, and counted on the tab. An agent
  /// that closes a note by disagreeing with it must not be able to do so
  /// silently: the filtered list would look exactly like the one where it did
  /// the work, and the pushback would be gone precisely where it mattered.
  ///
  /// Your own resolutions are never in here. You do not need telling about a
  /// note you ticked off yourself.
  List<ReviewComment> get unseenResolutions => [
    for (var comment in comments)
      if (comment.resolution case var it?)
        if (it.by == ReviewActor.agent &&
            (seenAt == null || it.at.isAfter(seenAt!)))
          comment,
  ];

  bool get isEmpty => comments.isEmpty;

  /// Folds a log.
  ///
  /// Order of events is the order of the file, which is the order they
  /// happened — that is the one guarantee appending gives, and everything here
  /// leans on it rather than on timestamps, which two clocks can disagree
  /// about. The one exception is [seenAt], which is compared against
  /// resolution timestamps and so has to be one.
  static ReviewState fold(Iterable<ReviewEvent> events) {
    var byId = <String, ReviewComment>{};
    var order = <String>[];
    DateTime? seenAt;

    void resolve(String id, ReviewResolution resolution) {
      if (byId[id] case var it?) byId[id] = it.withResolution(resolution);
    }

    for (var event in events) {
      switch (event) {
        case CommentAdded(:var comment):
          if (!byId.containsKey(comment.id)) order.add(comment.id);
          byId[comment.id] = comment;
        case CommentEdited(:var id, :var body):
          if (byId[id] case var it?) byId[id] = it.withBody(body);
        case CommentDeleted(:var id):
          byId.remove(id);
          order.remove(id);
        case CommentResolved(:var id, :var resolution):
          resolve(id, resolution);
        case CommentUnresolved(:var id):
          if (byId[id] case var it?) byId[id] = it.withResolution(null);
        case ReviewSeen(:var at):
          seenAt = at;
        // The legacy handoff, folded to what it meant: you dealt with these.
        // Written by no version of this code — see [BatchHandedOff].
        case BatchHandedOff(:var ids, :var at):
          for (var id in ids) {
            resolve(id, ReviewResolution(by: ReviewActor.human, at: at));
          }
      }
    }

    return ReviewState(
      comments: [for (var id in order) byId[id]!],
      seenAt: seenAt,
    );
  }
}
