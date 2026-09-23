/// The widgets a review is made of: a comment in the diff, the box you write
/// one in, and a comment's row in the index.
///
/// Kept out of `diff_view.dart` because those rows are load-bearing for the
/// virtualised list — cheap, fixed-height, never wrapping — and every widget
/// here is the opposite of that on purpose. A comment wraps; that is what a
/// comment is. Separating them is what keeps the constraint legible where it
/// still applies.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'diff_view.dart' show diffTextStyle;
import 'review_comment.dart';

/// The composer's field, so a test and the drive tools can reach it. Its hint
/// is not a target: it belongs to the decoration, and tapping where it is drawn
/// is refused as covered.
const reviewComposerKey = Key('review-composer');

/// How many quoted lines a thread shows before it stops.
///
/// A span is whatever you shift-clicked, and forty lines of quote would push
/// the note itself off the screen — the quote is the note's evidence, not its
/// subject. Beyond this the rest is counted rather than drawn; the markdown
/// every reader gets still carries every line.
const _quoteLimit = 6;

/// What the amber dot means, said once.
///
/// The thread has room to write it out and the index row has room for a dot
/// and a tooltip, and the two must not drift into two different claims — this
/// is the only honest one we can make. See [ReviewComment.fileDigest].
const driftMessage =
    'This file changed after you commented. The code you quoted is kept as it '
    'was.';

/// A comment as it appears in the diff, under the line it is about.
///
/// The left edge is the accent bar, the same 2 px device the index uses for
/// a pinned file: at a glance down a long diff it says *somebody wrote here*
/// without needing to be read.
///
/// It shows what it captured. The quote is the whole design — a note
/// carries the code it was written about so the agent may keep editing while
/// you type — and for one release it was the one thing on this screen you could
/// not see: written into the comment, rendered only in the markdown.
/// A note about a line the agent has since deleted looked exactly like a note
/// about whatever now sits there, which is the failure mode carrying the quote
/// exists to prevent.
class ReviewThread extends StatelessWidget {
  const ReviewThread({
    required this.comment,
    required this.onDelete,
    required this.onResolve,
    required this.onUnresolve,
    this.drifted = false,
    this.highlighted = false,
    this.onEdit,
    super.key,
  });

  final ReviewComment comment;
  final VoidCallback onDelete;
  final VoidCallback? onEdit;

  /// Ticking it off yourself, and taking that back. The agent writes the same
  /// two events through its own surface; this is the human end of them.
  final VoidCallback onResolve;
  final VoidCallback onUnresolve;

  /// Whether the file moved after this was written.
  ///
  /// Ignored once the note is resolved. On a note the agent dealt with, the
  /// file changing is the work landing — the warning would be on every one of
  /// them, and a warning that is always on is not a warning. See [_drifting].
  final bool drifted;

  /// Just arrived here from the index. Held for a moment and then dropped —
  /// the index row you clicked and the thread you landed on are otherwise two
  /// unconnected things in a diff of four thousand rows.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.fromLTRB(
        FwSpacing.xxl,
        FwSpacing.sm,
        FwSpacing.xxl,
        FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: highlighted ? colors.accentSoft : colors.panel2,
        border: Border(left: BorderSide(color: colors.accent, width: 2)),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(context.radii.radiusSmall),
          bottomRight: Radius.circular(context.radii.radiusSmall),
        ),
      ),
      padding: const EdgeInsets.all(FwSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _iconFor(comment.anchor),
                size: FwIconSize.xs,
                color: colors.mut3,
              ),
              const Gap(FwSpacing.sm),
              // The short form: the file's name is in the header six pixels
              // above this, and the whole path twice is the same sentence said
              // twice.
              Flexible(
                child: Text(
                  comment.anchor.shortLabel,
                  style: context.type.micro.copyWith(color: colors.mut2),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              const Gap(FwSpacing.md),
              Text(
                clockOf(comment.createdAt),
                style: context.type.micro.copyWith(color: colors.mut3),
              ),
              const Spacer(),
              // A resolved note offers one thing: taking it back. *Edit* and
              // *Delete* on a note the agent has already answered are two ways
              // of making its answer about something else.
              if (comment.isResolved)
                _Action(label: 'Reopen', onTap: onUnresolve)
              else ...[
                if (onEdit case var edit?) ...[
                  _Action(label: 'Edit', onTap: edit),
                  const Gap(FwSpacing.md),
                ],
                _Action(label: 'Delete', onTap: onDelete),
                const Gap(FwSpacing.md),
                _Action(label: 'Resolve', onTap: onResolve),
              ],
            ],
          ),
          if (comment.quote.isNotEmpty) ...[
            const Gap(FwSpacing.sm),
            ReviewQuote(comment.quote),
          ],
          const Gap(FwSpacing.sm),
          // **Selectable, but not on its own.** The first thing anybody does
          // with a note they wrote for an agent is take a piece of it somewhere
          // else — and the body pane now has one [SelectionArea] over all of
          // it, which is what lets a selection run from a note into the code
          // under it. A `SelectableText` inside that would be a second
          // selection model fighting the first.
          Text(
            comment.body,
            style: context.type.bodySmall.copyWith(color: colors.ink),
          ),
          if (comment.resolution case var it?) ...[
            const Gap(FwSpacing.md),
            ReviewResolutionNote(it),
          ],
          if (_drifting) ...[
            const Gap(FwSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.circle, size: 6, color: colors.amber),
                ),
                const Gap(FwSpacing.sm),
                Expanded(
                  child: Text(
                    driftMessage,
                    style: context.type.micro.copyWith(color: colors.mut2),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool get _drifting => drifted && !comment.isResolved;
}

/// The answer, under the note it answers.
///
/// Who, then what they said. *The agent says it did this* and *I ticked
/// this off* are different claims, and the actor is the only thing that tells
/// them apart — a message alone reads as authoritative whoever wrote it.
///
/// The agent's is drawn in the accent. Yours is not: you already know what you
/// decided, and colouring both makes the colour mean *resolved* rather than
/// *the agent answered*.
class ReviewResolutionNote extends StatelessWidget {
  const ReviewResolutionNote(this.resolution, {super.key});

  final ReviewResolution resolution;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var byAgent = resolution.by == ReviewActor.agent;
    var tint = byAgent ? colors.accent : colors.mut2;
    return Container(
      padding: const EdgeInsets.only(left: FwSpacing.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: tint, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check, size: FwIconSize.xs, color: tint),
              const Gap(FwSpacing.sm),
              Text(
                '${byAgent ? 'The agent' : 'You'} resolved this · '
                '${clockOf(resolution.at)}',
                style: context.type.micro.copyWith(color: tint),
              ),
            ],
          ),
          if (resolution.message case var message?) ...[
            const Gap(FwSpacing.xs),
            Text(
              message,
              style: context.type.bodySmall.copyWith(color: colors.mut),
            ),
          ],
        ],
      ),
    );
  }
}

/// The code a note carries, drawn the way the diff draws it.
///
/// [diffTextStyle] rather than a mono face of its own: this is a slice of the
/// file three rows above it, and two typefaces for the same bytes would read as
/// two different things. Lines clip instead of wrapping, for the same reason
/// they do in the diff — a wrapped quote is one whose indentation lies.
class ReviewQuote extends StatelessWidget {
  const ReviewQuote(this.lines, {this.limit = _quoteLimit, super.key});

  final List<String> lines;
  final int limit;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var shown = lines.take(limit).toList();
    var rest = lines.length - shown.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var line in shown)
            Text(
              line,
              style: diffTextStyle(context).copyWith(color: colors.mut),
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          if (rest > 0)
            Text(
              '…and $rest more ${rest == 1 ? 'line' : 'lines'}',
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
        ],
      ),
    );
  }
}

/// A note that has just been deleted, and can still be taken back.
///
/// The delete is not written yet. It stands in the deleted note's place
/// until the window closes, and only then does the tombstone reach the log —
/// so taking it back costs nothing and restores the note exactly, in the
/// position it held. Delete was a single click on a 10.5 px text link beside
/// Edit, against an append-only log with no way back.
class ReviewUndoStrip extends StatelessWidget {
  const ReviewUndoStrip({
    required this.onUndo,
    this.inset = FwSpacing.xxl,
    super.key,
  });

  final VoidCallback onUndo;
  final double inset;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      margin: EdgeInsets.fromLTRB(inset, FwSpacing.sm, inset, FwSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.md,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          Icon(Icons.delete_outline, size: FwIconSize.sm, color: colors.mut3),
          const Gap(FwSpacing.sm),
          Expanded(
            child: Text(
              'Comment deleted',
              style: context.type.micro.copyWith(color: colors.mut2),
            ),
          ),
          _Action(label: 'Undo', onTap: onUndo, strong: true),
        ],
      ),
    );
  }
}

IconData _iconFor(ReviewAnchor anchor) => switch (anchor) {
  LineAnchor() => Icons.code,
  FileAnchor() => Icons.description_outlined,
  ReviewWide() => Icons.rate_review_outlined,
};

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.onTap,
    this.strong = false,
  });

  final String label;
  final VoidCallback onTap;

  /// Accent whether or not the pointer is on it — for the one action in a row
  /// that is being offered rather than merely available.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable.builder(
      onTap: onTap,
      builder: (context, hovered) => Text(
        label,
        style: context.type.micro.copyWith(
          color: strong || hovered ? colors.accent : colors.mut3,
        ),
      ),
    );
  }
}

/// The box you write a comment in.
///
/// It shows its anchor and the code it is about to capture, in that order,
/// above the text. That is the entire staleness contract, put where you accept
/// it rather than in a doc nobody opens: *these three lines, as they are now,
/// travel with what you are about to write.* It said `3 lines captured`, which
/// is the claim without the evidence — and the lines it means are the ones the
/// diff has just tinted behind the box, so naming them and not showing them
/// made the reader count rows to check.
///
/// One border, not two. The box had an accent outline and the field inside
/// it had another, so writing a note happened inside two concentric blue
/// rectangles four pixels apart. The box *is* the field: the outline is the
/// focus, and the input draws none of its own.
///
/// The text itself is held by the caller — see [controller] — because this
/// lives inside a virtualised list and a composer scrolled past its cache
/// extent is a composer that was disposed. Owning the controller upstream is
/// what makes that a redraw rather than a loss.
class ReviewComposer extends StatefulWidget {
  const ReviewComposer({
    required this.anchor,
    required this.controller,
    required this.onSubmit,
    required this.onCancel,
    this.quote = const [],
    this.editing = false,
    this.inset = FwSpacing.xxl,
    super.key,
  });

  final ReviewAnchor anchor;
  final TextEditingController controller;

  /// The code that will travel with this comment. Empty for a file or review
  /// anchor, which quote nothing.
  ///
  /// While *editing*, this is the quote the comment already carries rather
  /// than a fresh read of the patch — it is stored precisely so it does not
  /// change under you, and rewriting the body is not re-capturing.
  final List<String> quote;

  /// Whether this is rewriting an existing comment rather than adding one.
  final bool editing;

  /// How far in from the sides. The body's diff can afford the full gutter;
  /// the 320 px index cannot, and the composer for a whole-review note lives
  /// there.
  final double inset;

  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  State<ReviewComposer> createState() => _ReviewComposerState();
}

class _ReviewComposerState extends State<ReviewComposer> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The composer appears because you asked for it, so it is where you are
    // about to type. Anything else costs a click nobody would understand.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;

    return Container(
      margin: EdgeInsets.fromLTRB(
        widget.inset,
        FwSpacing.sm,
        widget.inset,
        FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border.all(color: colors.accent),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _iconFor(widget.anchor),
                size: FwIconSize.xs,
                color: colors.mut3,
              ),
              const Gap(FwSpacing.sm),
              // The same two-part path the index row uses: the name and its
              // line are what identify the anchor, and the six directories in
              // front of them are what an ellipsis should eat.
              if (widget.anchor.directory case var it?)
                Flexible(
                  child: Text(
                    it,
                    style: context.type.micro.copyWith(color: colors.mut3),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              Flexible(
                child: Text(
                  widget.anchor.shortLabel,
                  style: context.type.micro.copyWith(color: colors.mut2),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ],
          ),
          if (widget.quote.isNotEmpty) ...[
            const Gap(FwSpacing.sm),
            ReviewQuote(widget.quote),
          ],
          const Gap(FwSpacing.sm),
          // **Both shortcuts are bound here rather than on the screen**, so
          // they cannot fire while the focus is somewhere else — Esc in
          // particular, which elsewhere on this screen clears the filter.
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  widget.onSubmit,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  widget.onSubmit,
              const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
            },
            child: TextField(
              key: reviewComposerKey,
              controller: widget.controller,
              focusNode: _focus,
              style: context.type.bodySmall,
              maxLines: null,
              // Two, not three. The box carries a header and often a quote now,
              // and an empty field taller than the code it is about makes the
              // composer the biggest thing in the diff. It grows as you type.
              minLines: 2,
              cursorColor: colors.accent,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'What should the agent change here?',
                hintStyle: context.type.bodySmall.copyWith(color: colors.mut3),
                // The container above is the field's edge — see the class doc.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const Gap(FwSpacing.md),
          Row(
            children: [
              // **The hint gives way, the buttons never do.** At 480 px — the
              // right pane in a narrow window — this row overflowed by 83 px
              // and took *Add comment* off the edge with it, which is the one
              // control the composer exists for.
              //
              // Below that it is shortened rather than ellipsised, and then
              // dropped: `Esc to disc…` is not a shorter way of saying the
              // shortcut, it is a way of not saying it while still taking the
              // room. The composer opens in a 320 px column too — that is
              // where a whole-review note is written.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    var hint = switch (constraints.maxWidth) {
                      > 180 => '⌘↵ to add · Esc to discard',
                      > 80 => '⌘↵ to add',
                      _ => '',
                    };
                    return Text(
                      hint,
                      style: context.type.micro.copyWith(color: colors.mut3),
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    );
                  },
                ),
              ),
              _Action(label: 'Cancel', onTap: widget.onCancel),
              const Gap(FwSpacing.lg),
              // The house primary — an accent border over [FwPalette
              // .accentSoft], the same one the Review tab's *Export* wears.
              // A solid fill was the loudest thing in a panel of greys, and it
              // no longer matched the only other primary in the feature.
              Tappable.builder(
                onTap: widget.onSubmit,
                builder: (context, hovered) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(
                    horizontal: FwSpacing.lg,
                    vertical: FwSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: hovered ? colors.accentSoft2 : colors.accentSoft,
                    borderRadius: BorderRadius.circular(context.radii.radius),
                    border: Border.all(color: colors.accent),
                  ),
                  child: Text(
                    widget.editing ? 'Save' : 'Add comment',
                    style: context.type.caption.copyWith(color: colors.accent),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A comment's row in the index.
///
/// Numbered, while it is outstanding. A number is what lets you say *the
/// third one* to the agent — the one thing the anchor cannot do when three
/// comments sit on one file. A resolved note leaves the numbering rather than
/// renumbering the rest, so *the third one* means one note for a whole session;
/// [number] is null there and the slot carries a tick instead.
///
/// A row, not a paragraph. Three notes with a two-line body and a line of
/// code each ran together into one block of text: nothing said where one ended
/// and the next began except a faint digit in the margin, while the threads
/// they mirror had become composed objects. It carries the same four things a
/// thread does, in the same order — kind, where, when, then the note over the
/// code it is about — and a rule underneath so the eye can find the seam.
class ReviewIndexRow extends StatelessWidget {
  const ReviewIndexRow({
    required this.comment,
    required this.selected,
    required this.onTap,
    this.number,
    this.drifted = false,
    this.unseen = false,
    super.key,
  });

  /// Null on a resolved note, which is not in the numbering: the number is what
  /// you say out loud about work still to do, and shifting it as notes are
  /// answered would make *the third one* mean two things in one session.
  final int? number;

  final ReviewComment comment;

  /// The agent resolved this after you last looked.
  ///
  /// Drawn whatever the filter says — see [ReviewState.unseenResolutions].
  final bool unseen;

  /// The note the screen is currently on — the one you last opened, or the one
  /// being rewritten. Marking it is what makes the list and the diff feel like
  /// two views of one thing rather than a jump into an unrelated file.
  final bool selected;

  final bool drifted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : null,
          border: Border(bottom: BorderSide(color: colors.line)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 16,
              // The number's slot, and on a resolved note the tick that says
              // why there is no number in it.
              child: number == null
                  ? Icon(
                      Icons.check,
                      size: FwIconSize.xs,
                      color: unseen ? colors.accent : colors.mut3,
                    )
                  : Text(
                      '$number',
                      style: context.type.micro.copyWith(
                        color: selected ? colors.accent : colors.mut3,
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _iconFor(comment.anchor),
                        size: FwIconSize.xs,
                        color: colors.mut3,
                      ),
                      const Gap(FwSpacing.sm),
                      // **The directory is given up, not squeezed.** Drawn
                      // beside the name it used to share the squeeze with it,
                      // and once a clock and a drift dot joined the line, a
                      // 320 px column ellipsised *both* — leaving
                      // `example_server.da…` next to `fixtures/probe_app…`, which
                      // is two half-truths where the point was to keep one
                      // whole one. `name:line` is what tells two rows apart;
                      // the whole path is a hover away, and the quoted line
                      // below tells apart two files that share a name.
                      // **One flexible child on this line, not two.** A
                      // `Spacer` to push the clock right is itself flex, so it
                      // split the free width with the name and ellipsised it at
                      // half a column wide. The name's box takes the leftover
                      // instead, and the clock is simply what comes after it.
                      Expanded(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Tooltip(
                                message: comment.anchor.label,
                                child: Text(
                                  comment.anchor.shortLabel,
                                  style: context.type.micro.copyWith(
                                    color: colors.mut2,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  softWrap: false,
                                ),
                              ),
                            ),
                            if (drifted && !comment.isResolved) ...[
                              const Gap(FwSpacing.xs),
                              // The dot said nothing on its own. The thread has
                              // room for the sentence; a 320 px row has room
                              // for the dot and a pointer.
                              Tooltip(
                                message: driftMessage,
                                child: Icon(
                                  Icons.circle,
                                  size: 6,
                                  color: colors.amber,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Gap(FwSpacing.sm),
                      Text(
                        clockOf(comment.createdAt),
                        style: context.type.micro.copyWith(color: colors.mut3),
                      ),
                    ],
                  ),
                  const Gap(FwSpacing.xs),
                  // Two lines of the note, not one: the first line of a review
                  // comment is often the setup and the second is the ask.
                  Text(
                    comment.body,
                    style: context.type.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // **On a resolved note, the answer takes the slot the quote
                  // had.** Both at once is four lines of grey in a 320 px
                  // column, and once a note is answered the thing you are
                  // scanning for is what the answer said — the code it was
                  // about is one click away, in the diff, where it always was.
                  if (comment.resolution case var it? when it.message != null)
                    _Ruled(
                      color: it.by == ReviewActor.agent
                          ? colors.accent
                          : colors.line2,
                      child: Text(
                        it.message!,
                        style: context.type.micro.copyWith(color: colors.mut2),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  // **One line of what it is about.** Three notes on one file
                  // read as three copies of that filename otherwise; the line
                  // of code under each is what tells them apart without
                  // opening any of them. Ruled rather than merely dimmed —
                  // under two lines of prose, a third line of grey text reads
                  // as more prose.
                  else if (_firstCode(comment.quote) case var line?)
                    _Ruled(
                      color: colors.line2,
                      child: Text(
                        line,
                        style: diffTextStyle(context)
                            .copyWith(color: colors.mut3),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The first line of the quote with anything on it, trimmed of the
  /// indentation that would otherwise spend the whole row's width.
  static String? _firstCode(List<String> quote) {
    for (var line in quote) {
      var trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }
}

/// The third line of an index row — a quote, or an answer — under its rule.
class _Ruled extends StatelessWidget {
  const _Ruled({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: FwSpacing.sm),
    child: Container(
      padding: const EdgeInsets.only(left: FwSpacing.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 2)),
      ),
      child: child,
    ),
  );
}

/// Wall-clock, to the minute. A note's own time — not a duration and not a
/// date, because everything on this screen was written in the session you are
/// still in.
String clockOf(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
