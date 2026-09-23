/// The rows the changes list draws.
///
/// Each one is deliberately **cheap and of a predictable height**: they are
/// built inside a virtualised list, so anything that measures text or reflows a
/// subtree per row shows up as jank while scrolling a four-thousand-line file.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../ui/syntax.dart';
import '../ui/tappable.dart';
import '../ui/selectable_line.dart';
import '../ui/theme.dart';
import 'change_set.dart';
import 'diff_lines.dart';
import 'hunk_syntax.dart';
import 'patch_index.dart';

/// A file's row **in the index**: what happened to it, and how much.
///
/// Sized for a 320 px column, not a window: name on the first line where the
/// eye scans, **the directory on its own line under it**, counts hard right.
/// The full-width version this replaces put the whole path on one line with a
/// ruler and two 46 px count columns, which is a row that only reads at 1200 px.
///
/// The directory is not a note. It was, briefly, and it was the last of
/// them — behind `binary` — in one `·`-joined line, which
/// made *where a file lives* the first thing ellipsised away. Three lines of a
/// list like that and you cannot tell `app/lib/src/changes/ranking.dart` from
/// `test/changes/ranking.dart`. It gets its own line; the flags get theirs, and
/// only when there are any.
class IndexFileRow extends StatelessWidget {
  const IndexFileRow({
    required this.file,
    required this.selected,
    required this.onTap,
    this.reason,
    this.showDirectory = true,
    this.pinned = false,
    super.key,
  });

  final FileChange file;

  /// Whether the right pane is showing this file.
  final bool selected;
  final VoidCallback onTap;

  /// False inside the tree, where the row's position already says where the
  /// file is and repeating the path is the noise the tree exists to remove.
  /// True in the *Important* tab, which is flat and has no other way to say
  /// it.
  final bool showDirectory;

  /// Draws the flag an attention rule earned this file. Set inside the tree,
  /// where a pin has to be visible in passing. Not in the *Important* tab,
  /// which is all pins and would only be marking every row.
  final bool pinned;

  /// Why this file was pinned or demoted, in the words the rule was written in.
  final String? reason;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var slash = file.path.lastIndexOf('/');
    var name = slash < 0 ? file.path : file.path.substring(slash + 1);
    var directory = slash < 0 ? '' : file.path.substring(0, slash);

    return Tappable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : Colors.transparent,
          // A 2 px edge rather than a badge: it is scannable down a column of
          // forty rows and costs the text no width at all.
          border: pinned
              ? Border(left: BorderSide(color: colors.accent, width: 2))
              : null,
        ),
        padding: EdgeInsets.only(
          left: pinned ? FwSpacing.md - 2 : FwSpacing.md,
          right: FwSpacing.md,
          top: FwSpacing.sm,
          bottom: FwSpacing.sm,
        ),
        // **Baselines, not box tops.** Three different type sizes sit on this
        // row — the status letter, the name, the counts — and
        // `CrossAxisAlignment.start` aligns the tops of their boxes, which for
        // two different ascents is not the same line. It is a two-pixel error
        // that nobody can name and everybody can see. `Column` reports its
        // first child's baseline, so aligning on it puts the letter and the
        // counts on the *name's* line, which is the one being read.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            // **The letter says it, the tooltip spells it.** One character in a
            // colour is a legend a reader has to have been taught; `A` and `R`
            // are the two nobody guesses.
            Tooltip(
              message: _word(file.status),
              child: SizedBox(
                width: 12,
                child: Text(
                  _letter(file.status),
                  style: context.type.bodySmall.copyWith(color: _tone(colors)),
                ),
              ),
            ),
            const Gap(FwSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: context.type.bodySmall,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                  if (showDirectory && directory.isNotEmpty)
                    Text(
                      directory,
                      style: context.type.micro.copyWith(color: colors.mut2),
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  // **[FwPalette.micro]'s own [FwPalette.mut], not a step
                  // down to [FwPalette.mut3].** This line carries the reason a
                  // rule pinned the row, which on the *Important* tab is the
                  // only answer to *why is this here* — and mut3 is documented
                  // as the step where "text is decoration; do not put a
                  // sentence in it that the reader needs". Measured on white:
                  // mut3 #c4c7cd is 1.70:1 and mut2 #9aa1ac is 2.62:1, against
                  // the 4.5:1 normal text is meant to clear; mut #6b7280 is
                  // 4.83:1 and is the only muted step that does.
                  if (_notes.isNotEmpty)
                    Text(
                      _notes.join(' · '),
                      style: context.type.micro,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                ],
              ),
            ),
            const Gap(FwSpacing.sm),
            // **One line.** Stacked, `+309` over `-22` reads as a count that
            // wrapped rather than as two halves of one figure — and the row is
            // already two or three lines tall without help.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '+${file.added}',
                  style: context.type.micro.copyWith(color: colors.grn),
                ),
                if (file.removed > 0) ...[
                  const Gap(FwSpacing.xs),
                  Text(
                    '-${file.removed}',
                    style: context.type.micro.copyWith(color: colors.red),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A third line, and only when there is something to put on it. The
  /// directory is deliberately **not** among these — that is what put it last
  /// in a `·`-joined string behind the other flags, where it was the first
  /// thing to be ellipsised away.
  ///
  /// Whether a file is committed yet is not one of these. It is a fact
  /// about the reader's git state rather than about the change, and this list
  /// is what you scan to decide which file to open — a question it never
  /// answers. The summary above the list still counts them.
  List<String> get _notes => [
    // **The rule first.** A row that was pinned has to say what pinned it or
    // the pin is magic, and magic is what people learn to ignore.
    ?reason,
    // A rename says where it came from: `R` alone is a status nobody can act
    // on, and the index is where you decide whether to look.
    if (file.oldPath case var it?) 'from $it',
    if (file.isBinary) 'binary',
  ];

  Color _tone(FwPalette colors) => switch (file.status) {
    ChangeStatus.added => colors.grn,
    ChangeStatus.deleted => colors.red,
    ChangeStatus.renamed => colors.amber,
    ChangeStatus.modified => colors.mut,
  };

  static String _letter(ChangeStatus status) => switch (status) {
    ChangeStatus.added => 'A',
    ChangeStatus.modified => 'M',
    ChangeStatus.deleted => 'D',
    ChangeStatus.renamed => 'R',
  };

  static String _word(ChangeStatus status) => statusWord(status);
}

/// How a status reads in words — the index's tooltip and the body's header say
/// the same one, because two spellings of four states is four chances to
/// disagree.
String statusWord(ChangeStatus status) => switch (status) {
  ChangeStatus.added => 'added',
  ChangeStatus.deleted => 'deleted',
  ChangeStatus.renamed => 'renamed',
  ChangeStatus.modified => 'modified',
};

/// The `@@` line, drawn from the span rather than from the patch text — which
/// is what lets it appear before the hunk it heads has been decoded.
class HunkHeaderLine extends StatelessWidget {
  const HunkHeaderLine({required this.hunk, super.key});

  final HunkSpan hunk;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      color: colors.panel2,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.xxs,
      ),
      child: FwSelectableLine(
        child: Row(
          children: [
            Text(
              '@@ -${hunk.oldStart},${hunk.oldCount} '
              '+${hunk.newStart},${hunk.newCount} @@',
              style: diffTextStyle(context).copyWith(color: colors.mut3),
            ),
            if (hunk.context case var it?) ...[
              const Gap(FwSpacing.md),
              Expanded(
                child: Text(
                  it,
                  style: diffTextStyle(context).copyWith(color: colors.mut2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One line of an expanded hunk, decoded on demand.
///
/// The header is a prediction; the content is the truth. Row extents come
/// from `HunkSpan.displayLines`, which is arithmetic on the `@@` counts — that
/// is what lets the list size itself before decoding anything. A patch whose
/// header disagrees with its body (truncated mid-hunk, or written by something
/// that is not git) would otherwise index past the end of the decoded lines and
/// crash *while scrolling*, which is the least excusable place to crash.
///
/// So the shortfall is drawn, not swallowed: silently rendering nothing would
/// leave a gap that reads as a viewer bug rather than as a bad patch.
class HunkLineView extends StatelessWidget {
  const HunkLineView({
    required this.lines,
    required this.hunk,
    required this.index,
    this.tokens,
    this.onComment,
    this.selected = false,
    this.scrollX,
    this.charWidth = 0,
    super.key,
  });

  final HunkLineCache lines;
  final HunkSpan hunk;
  final int index;

  /// The body's shared horizontal position, or null for a host without one.
  final DiffScrollX? scrollX;

  /// One character's advance in [diffTextStyle], measured once by the pane.
  ///
  /// A monospace line's width is its length times this, which is how the body
  /// learns how far right it can go without a `TextPainter` per row.
  final double charWidth;

  /// Called with the line, when its `+` is pressed. Null on a screen with no
  /// review — a widget test pumping a diff, and the CLI's renderer.
  final ValueChanged<DiffLine>? onComment;

  /// Whether this line is inside the span the composer is about.
  final bool selected;

  /// Where this line's colours come from, or null for a file nothing here
  /// reads. Asked for per row, computed per hunk — the first row of a hunk to
  /// be built pays for the whole hunk and every row after it is a lookup.
  final HunkTokenCache? tokens;

  @override
  Widget build(BuildContext context) {
    var decoded = lines.linesFor(hunk);
    if (index >= decoded.length) {
      return DiffLineView(
        line: DiffLine(
          kind: DiffLineKind.meta,
          text: index == decoded.length
              ? r'\ this hunk ended before its header said it would'
              : '',
        ),
      );
    }
    var line = decoded[index];
    // Reported from `build`, which is why [DiffScrollX.see] does not notify.
    scrollX?.see(line.text.length * charWidth);
    return DiffLineView(
      line: line,
      tokens: tokens?.forHunk(hunk).at(index),
      selected: selected,
      scrollX: scrollX,
      // A meta line — `\ No newline at end of file` — is not a line of the
      // file, so there is nothing to say about it and nothing to quote.
      onComment: onComment == null || line.kind == DiffLineKind.meta
          ? null
          : () => onComment!(line),
    );
  }
}

/// One line of a diff.
///
/// Tinted by kind, and marked by a glyph. The tint alone would fail for the
/// ~8% of men with red-green colour blindness, and the glyph alone would make a
/// block of additions hard to see at a glance; together neither is load-bearing
/// on its own.
///
/// Syntax colour is a third channel and does not compete with those two.
/// What says *added* is the row's wash and the `+`; what the tokens say is
/// which word is a keyword. So the row keeps its tint, and a token the
/// highlighter had no opinion about keeps the row's own ink rather than being
/// forced to a neutral.
class DiffLineView extends StatefulWidget {
  const DiffLineView({
    required this.line,
    this.tokens,
    this.onComment,
    this.selected = false,
    this.scrollX,
    super.key,
  });

  final DiffLine line;

  /// This line's coloured runs, or null for a file nothing here reads — in
  /// which case the text is drawn exactly as it was before any of this existed.
  final List<Token>? tokens;

  /// Pressing the `+` in the margin. Null leaves the margin empty and the row
  /// exactly as inert as it has always been.
  final VoidCallback? onComment;

  /// Inside the span the composer is about, so you can see what you picked
  /// while you are writing about it.
  final bool selected;

  /// Where the code column is scrolled to, or null for a host that does not
  /// offer horizontal reach — the CLI's renderer and a widget test pumping one
  /// row on its own.
  final DiffScrollX? scrollX;

  @override
  State<DiffLineView> createState() => _DiffLineViewState();
}

class _DiffLineViewState extends State<DiffLineView> {
  /// Hover, not a tap target on the row. The row holds selectable text and
  /// a tap handler over all of it would eat the drag that selects a line — so
  /// only the margin is pressable, and hover is what reveals it.
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    var line = widget.line;
    var colors = context.colors;
    var (background, marker, tone) = switch (line.kind) {
      DiffLineKind.added => (
        colors.grn.withValues(alpha: 0.12),
        '+',
        colors.grn,
      ),
      DiffLineKind.removed => (
        colors.red.withValues(alpha: 0.12),
        '-',
        colors.red,
      ),
      DiffLineKind.meta => (Colors.transparent, '', colors.mut3),
      DiffLineKind.context => (Colors.transparent, ' ', colors.mut3),
    };
    var style = diffTextStyle(context);

    return MouseRegion(
      onEnter: (_) {
        if (widget.onComment != null) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Container(
        color: widget.selected ? colors.accentSoft : background,
        padding: const EdgeInsets.only(right: FwSpacing.lg),
        // One line for the purpose of a selection, so a drag down the diff
        // comes back as lines rather than as one run-together string — see
        // [FwSelectableLine], which is where the mechanics are.
        child: FwSelectableLine(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommentMargin(
                visible: _hovered,
                onTap: widget.onComment,
                style: style,
              ),
              // The furniture stays out of the clipboard. What a selected diff
              // is for is pasting the code somewhere — an editor, a message, a
              // shell — and line numbers welded to the front of every line
              // make it paste as nothing at all. The `+`/`-` goes for the same
              // reason: it is how the row says *added* on screen, not a
              // character of the file.
              SelectionContainer.disabled(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Gutter(line.oldNumber, colors.mut3, style),
                    _Gutter(line.newNumber, colors.mut3, style),
                    const Gap(FwSpacing.sm),
                    SizedBox(
                      width: 10,
                      child: Text(marker, style: style.copyWith(color: tone)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _Code(
                  line: line,
                  tokens: widget.tokens,
                  style: style,
                  scrollX: widget.scrollX,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line's text, shifted by the body's shared horizontal offset.
///
/// Translated inside a clip, not put in a scroll view. Every row must move
/// by the same amount or the columns stop lining up, and a scroll view per row
/// cannot promise that: a short line's own extent is zero, so it would stay
/// put while its neighbours moved. Here the text is laid out at its natural
/// width — [OverflowBox] is what lifts the row's width constraint off it — and
/// the row shows the window onto it.
///
/// Only this subtree rebuilds as the offset changes, not the row: forty rows
/// re-running their token spans on every frame of a swipe is the jank the
/// virtualised list is otherwise careful to avoid.
class _Code extends StatelessWidget {
  const _Code({
    required this.line,
    required this.tokens,
    required this.style,
    required this.scrollX,
  });

  final DiffLine line;
  final List<Token>? tokens;
  final TextStyle style;
  final DiffScrollX? scrollX;

  @override
  Widget build(BuildContext context) {
    // **The same `Text`, given spans instead of a string.** Not a different
    // widget for the coloured case: the row's height and its never-wrapping are
    // the properties that keep a virtualised list smooth, and two widgets is
    // two places to lose one of them.
    //
    // **Never wrapped.** A wrapped line changes a row's height, and a
    // virtualised list whose rows change height as they are built is one whose
    // scrollbar jumps under your hand.
    var text = switch (tokens) {
      var it? when line.kind != DiffLineKind.meta => Text.rich(
        TextSpan(children: spansFor(context, it, style: style)),
        style: style,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
      _ => Text(
        line.text,
        style: line.kind == DiffLineKind.meta
            ? style.copyWith(
                color: context.colors.mut3,
                fontStyle: FontStyle.italic,
              )
            : style,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    };

    var model = scrollX;
    if (model == null) return text;
    // **The row's height is stated, not discovered.** An [OverflowBox] takes
    // the biggest size its own constraints allow, and a list row's height is
    // unbounded — so without this it asks for an infinite one. Saying it
    // outright costs nothing here (every row is one line of monospace, whose
    // height is arithmetic) and hands the virtualised list the predictable
    // extent its doc has always claimed for these rows.
    return SizedBox(
      height: diffLineHeight(style),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: model,
          builder: (context, child) => Transform.translate(
            offset: Offset(-model.x, 0),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: child,
            ),
          ),
          child: text,
        ),
      ),
    );
  }
}

/// How tall one line of diff is: the face's size times its line height.
double diffLineHeight(TextStyle style) =>
    (style.fontSize ?? 12.5) * (style.height ?? 1.45);

/// The `+` in the left margin.
///
/// Its width is always taken, hovered or not. Revealing the affordance by
/// making room for it would shift every line of the diff sideways as the
/// pointer moved down the file, which is the sort of motion that makes a list
/// feel broken even when nothing is wrong.
///
/// The strip is always pressable; only the glyph waits for hover. Gating
/// the *target* on hover made this the one control on the screen that neither a
/// widget test nor the drive tools could reach — neither has a hover verb — so
/// the whole gesture could only ever be verified by a human with a mouse.
/// Leaving the target live costs nothing: a 20 px margin to the left of the
/// line numbers is not where a stray click lands, and the Review tab's empty
/// state names the gesture for anyone who has not found it by moving a pointer.
///
/// Shared with the plain-text body an untracked file gets, so *leave a note on
/// this line* is one gesture with one target and one tooltip wherever lines of
/// a file are drawn.
class CommentMargin extends StatelessWidget {
  const CommentMargin({
    required this.visible,
    required this.onTap,
    required this.style,
    super.key,
  });

  final bool visible;
  final VoidCallback? onTap;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (onTap == null) return const SizedBox(width: width);
    return SizedBox(
      width: width,
      child: Tooltip(
        message: 'Comment on this line — shift-click to extend a span',
        waitDuration: const Duration(milliseconds: 600),
        child: Tappable.builder(
          onTap: onTap,
          // One of these sits in the margin of every line of every hunk, so
          // taking focus would put a few hundred tab stops between the top of
          // a file and anything else on the screen.
          focusable: false,
          builder: (context, hovered) => Center(
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: !visible && !hovered
                    ? null
                    : hovered
                    ? colors.accentDark
                    : colors.accent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Center(
                child: Text(
                  visible || hovered ? '+' : '',
                  style: style.copyWith(color: colors.primaryOnMenu, height: 1),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const width = FwSpacing.lg + 8;
}

/// The body's horizontal scrollbar: a thumb you can drag, and the only thing on
/// the screen that says there is more line out there.
///
/// It appears only when it has somewhere to go, and it sits under the rows
/// rather than over them: a diff's last line is as readable as its first, and a
/// bar floating over it would cover exactly the text that was scrolled to.
class DiffScrollBar extends StatelessWidget {
  const DiffScrollBar({required this.model, super.key});

  final DiffScrollX model;

  static const _height = 10.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        if (!model.canScroll) return const SizedBox.shrink();
        return SizedBox(
          height: _height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              var track = constraints.maxWidth;
              // Never thinner than a thing you can hit.
              var thumb = math.max(28.0, track * model.visibleFraction);
              var left = (track - thumb) * model.progress;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (event) {
                  var travel = track - thumb;
                  if (travel <= 0) return;
                  model.moveBy(event.delta.dx * (model.maxX / travel));
                },
                child: Stack(
                  children: [
                    Positioned(
                      left: left,
                      top: 3,
                      width: thumb,
                      height: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.mut3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter(this.number, this.color, this.style);

  final int? number;
  final Color color;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    child: Text(
      number?.toString() ?? '',
      textAlign: TextAlign.right,
      style: style.copyWith(color: color),
    ),
  );
}

/// An untracked path, exactly as git reported it.
///
/// Two places draw this, and the difference between them is the difference
/// between the two things git means by *untracked*. An untracked **file** is a
/// row in the tree, beside the tracked files of the same directory, dressed the
/// same as [IndexFileRow] down to the pin edge. An untracked **directory** is a
/// row in the tail below the tree, spelling its whole path, because it stands
/// for a subtree nobody has walked and has no place in a map of one.
class IndexUntrackedRow extends StatelessWidget {
  const IndexUntrackedRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.showDirectory = true,
    this.pinned = false,
    super.key,
  });

  final UntrackedEntry entry;
  final bool selected;

  /// Null for a directory, which is the one row here that opens nothing: there
  /// is no diff behind it and reading it would be the walk this avoids.
  final VoidCallback? onTap;

  /// False inside the tree, where the row's position already says where the
  /// file is — the same rule, for the same reason, as [IndexFileRow].
  final bool showDirectory;

  /// Draws the accent edge an attention rule earned this file. Set inside the
  /// tree; not in the tail, which is where you have already arrived.
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var slash = entry.path.lastIndexOf('/');
    var name = slash < 0 ? entry.path : entry.path.substring(slash + 1);
    var notes = [
      ?entry.reason,
      if (entry.isDirectory)
        // **Never a file count.** Counting is the directory walk that keeping
        // this to one row exists to avoid.
        'directory, not scanned'
      else
        'not tracked yet',
      // Not for a directory: its own path is already drawn in full above, and
      // repeating the parent under it reads as two different places.
      if (showDirectory && slash > 0 && !entry.isDirectory)
        entry.path.substring(0, slash),
    ];

    return Tappable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : Colors.transparent,
          border: pinned
              ? Border(left: BorderSide(color: colors.accent, width: 2))
              : null,
        ),
        padding: EdgeInsets.only(
          left: pinned ? FwSpacing.md - 2 : FwSpacing.md,
          right: FwSpacing.md,
          top: FwSpacing.sm,
          bottom: FwSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            // **git's own letter, and it is the one nobody reads.** `A`/`M`/`D`
            // are guessable from the word they start; `?` stands for a question
            // git is asking rather than an answer, so it says so on hover.
            Tooltip(
              message: entry.isDirectory
                  ? 'Untracked — git is not tracking anything in this '
                        'directory yet'
                  : 'Untracked — git is not tracking this file yet, so there '
                        'is no other side to diff it against',
              child: SizedBox(
                width: 12,
                child: Text(
                  '?',
                  style: context.type.bodySmall.copyWith(color: colors.mut3),
                ),
              ),
            ),
            const Gap(FwSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.isDirectory ? entry.path : name,
                    style: context.type.bodySmall.copyWith(
                      // **A file's name is a file's name.** It used to be
                      // dimmed unless a rule had pinned it, which was fair
                      // when every untracked row lived in a drawer at the foot
                      // of the list; in the tree, beside the tracked files of
                      // the same directory, a grey name reads as *disabled*
                      // rather than as *new*. The `?`, the missing counts and
                      // the note under it say what this row is, and a pin now
                      // has the accent edge every other pinned row has.
                      //
                      // A directory keeps the dimming: it is the one row here
                      // that opens nothing.
                      color: entry.isDirectory ? colors.mut : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                  Text(
                    notes.join(' · '),
                    style: context.type.micro.copyWith(color: colors.mut2),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one place the diff's typeface is decided.
///
/// Monospace, because a diff is columns: an indent that does not line up with
/// the line above it is a diff you cannot read.
///
/// Built on `mono`, which is body text, and not on `micro`, which is a
/// label. It was `micro` plus a family override, and `micro` is defined as
/// `10.5, weight: strong, color: mut, letterSpacing: 0.2` — the face the app
/// uses for `PLUGINS`. So every line of code on the screen was rendered at the
/// smallest step in the ramp, in semibold, in a muted grey, with tracking added
/// to a typeface whose entire purpose is that characters line up on a grid.
/// Read against a full screen of diff, there was not one regular-weight glyph
/// in it.
///
/// The line height stays generous: a diff is scanned down as much as read
/// across, and 1.45 is what keeps the `+` and `-` washes reading as bands.
TextStyle diffTextStyle(BuildContext context) =>
    context.type.mono.copyWith(height: 1.45);

/// What a row spends before its code starts: the comment margin, two gutters,
/// a gap and the `+`/`-` marker.
///
/// Named because the body has to subtract it to know how wide the code column
/// is, and a viewport that is wrong by 118 px is a scroll that stops short of
/// the end of the longest line.
const diffChromeWidth =
    CommentMargin.width + 44 * 2 + FwSpacing.sm + 10 + FwSpacing.lg;

/// Where the body is scrolled to horizontally, shared by every row.
///
/// One offset for all the rows, not a scroll view each. The lines of a diff
/// are columns; if each row scrolled by its own amount — or if short rows
/// clamped at their own width while long ones kept going — the indentation
/// would stop lining up, which is the one thing the monospace is for. So the
/// rows do not scroll: they are translated, all by this, and a row with nothing
/// out there simply shows blank space.
///
/// The content width is what the widest row *built so far* needs. A patch's
/// true widest line is not knowable without decoding all of it, which is the
/// work the virtualised list exists to avoid — so the extent grows as you meet
/// longer lines, and never lies in the direction that would strand text off
/// the edge.
class DiffScrollX extends ChangeNotifier {
  double _x = 0;
  double _content = 0;
  double _viewport = 0;

  /// Logical pixels the code column is shifted left by.
  double get x => _x;

  double get maxX => math.max(0, _content - _viewport);

  /// Whether there is anything out of sight to reach.
  bool get canScroll => maxX > 0.5;

  /// The visible fraction, for a thumb's width.
  double get visibleFraction =>
      _content <= 0 ? 1 : (_viewport / _content).clamp(0.0, 1.0);

  /// How far along, 0..1.
  double get progress => maxX <= 0 ? 0 : (_x / maxX).clamp(0.0, 1.0);

  /// Called from `build`, so it must not notify — nothing reads [maxX] except
  /// input handling, which happens between frames.
  void see(double width) {
    if (width > _content) _content = width;
  }

  void setViewport(double width) {
    if (width == _viewport) return;
    _viewport = width;
    moveTo(_x);
  }

  void moveBy(double dx) => moveTo(_x + dx);

  void moveTo(double value) {
    var clamped = value.clamp(0.0, maxX);
    if (clamped == _x) return;
    _x = clamped;
    notifyListeners();
  }

  /// A new file is a new horizontal position: staying 400 px in would open it
  /// on whatever happened to be at that column.
  void reset() {
    _content = 0;
    moveTo(0);
    _x = 0;
  }
}
