import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';

import '../plugins/native/dev_stack_results.dart';
import '../shell/worktree_filter.dart';
import '../ui/menu.dart';
import '../ui/popover.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'explorer_detail.dart';
import 'facts.dart';

/// One worktree in the explorer.
///
/// Two lines: line 1 is the answer, line 2 is the evidence. Every line-2
/// item explains the line-1 item directly above it, which is the rule that keeps
/// six cells in 52 pixels from reading as a wall.
///
/// A View in the catalog sense — plain data in, callbacks out. It never asks
/// what a worktree is; the facts arrive already probed. See
/// `docs/superpowers/specs/2026-08-10-worktree-explorer-view-design.md` §7.
class WorktreeRow extends StatefulWidget {
  const WorktreeRow({
    super.key,
    required this.label,
    required this.facts,
    required this.now,
    this.branch,
    this.isMain = false,
    this.isOpen = false,
    this.isCurrent = false,
    this.match,
    this.scale = 1,
    this.showAgent = true,
    this.showForge = true,
    this.showStack = false,
    this.expanded = false,
    this.cursor = false,
    this.path,
    this.onToggleExpand,
    this.onOpen,
    this.onRemove,
    this.onOpenChanges,
    this.repoRoot,
  });

  /// Whether the detail is showing below the row.
  final bool expanded;

  /// Whether the keyboard is on this row.
  ///
  /// Deliberately **not** the same tone as hover: the pointer already draws its
  /// own cursor on the glass, so its highlight is a hint, while this one is the
  /// thing Enter will act on and has to be findable after you have looked away.
  final bool cursor;

  /// The checkout's directory, for the detail. Null in a demo that has none.
  final String? path;

  /// Tapping the row expands it; it does not open the worktree.
  ///
  /// Opening costs a config subprocess and a tab, and the whole premise of this
  /// screen is that you can decide *before* spending that. A row that opened on
  /// a stray click would make the cheap surface expensive. Opening is the
  /// deliberate act and has its own button.
  final VoidCallback? onToggleExpand;

  /// Opens the teardown checklist. Null for the primary checkout.
  final VoidCallback? onRemove;

  /// Opens the full changes screen for this checkout — the popover's footer,
  /// and where `⌘⇧D` goes.
  final VoidCallback? onOpenChanges;

  /// The main checkout, which keys the cached `ChangesConfig`. Null ranks by
  /// the built-in defaults.
  final String? repoRoot;

  /// Whether these columns are drawn at all.
  ///
  /// Decided across the list, not per row — otherwise the cells stop lining
  /// up, which is the one thing a table has to do. A column no row can fill is
  /// 150 pixels of dashes: it is what a repo with no agents looks like, what a
  /// machine with no `gh` looks like, and what an agent format that stopped
  /// parsing looks like. One rule covers all three.
  final bool showAgent;
  final bool showForge;

  /// Off unless some checkout in this repository has a stack reading — which
  /// most repositories will never have, since most projects declare no stack.
  /// A column that is empty for everyone should not exist at all, let alone
  /// take 116 pixels from the names.
  final bool showStack;

  /// The label-priority winner: agent title, then PR title, then branch, then
  /// the directory. Resolved above this widget — the row does not know the
  /// precedence, it just draws what won.
  final String label;

  final String? branch;
  final bool isMain;
  final bool isOpen;

  /// The worktree the rest of the window is on.
  final bool isCurrent;

  final WorktreeFacts facts;

  /// Passed in rather than read from the clock, so a demo and a widget test are
  /// deterministic and a screenshot does not change every minute.
  final DateTime now;

  /// Where the filter matched, so the run that kept this row is lit.
  final FilterMatch? match;

  /// This row's branch size as a fraction of the busiest row's. What makes the
  /// bars comparable down the column instead of fourteen unrelated widths.
  final double scale;

  final VoidCallback? onOpen;

  @override
  State<WorktreeRow> createState() => WorktreeRowState();
}

const _rowHeight = 52.0;

/// Left breathing room, past the 2px "open" edge which stays at x=0 so it reads
/// as an edge rather than as a stripe. The header pads to the same figure, so
/// its title sits over the column of names.
const explorerInsetLeft = 26.0;

/// Kept clear on the right so the overlay scrollbar — which appears only while
/// the pointer is over the list, exactly when you are reaching for a row
/// control — does not land on top of the one button it would cover.
const explorerInsetRight = 16.0;

const _gutterWidth = explorerInsetLeft;

/// Marks the changes column, which is the first to go when the row runs out of
/// room. Named so a test can assert it left, rather than asserting on a picture.
const changesCellKey = ValueKey('worktree-row.changes');
const _scrollGutter = explorerInsetRight;

/// Marks the stack column, so a test can assert it left rather than assert on
/// a picture.
const stackCellKey = ValueKey('worktree-row.stack');

const _changesWidth = 220.0;
const _agentWidth = 190.0;
const _prWidth = 150.0;

/// A word and a port. It carries less than any other column and is sized for
/// it — which is also why it is the last to be dropped: taking it away buys
/// half of what taking `forge` away buys.
const _stackWidth = 116.0;
const _whenWidth = 64.0;
// Wider than the 76 it was, and than the 32 the design budgeted: the column
// carries Open, a menu trigger and the chevron, and at 76 that Row overflowed
// by 11px — which clipped the trigger off the right edge, so it looked like it
// vanished as you reached for it.
//
// It has to hold all three *at once*, because the hover-only controls keep
// their space rather than vacating it — a button that disappeared shifted the
// trigger out from under the cursor arriving at it. So this is sized for the
// widest state, not the common one.
//
// Measured, not chosen, and guarded by `explorer_row_menu_test.dart`. The name
// column no longer pays for it: `_affordable` drops a column instead.
const _actionsWidth = 96.0;
const _nameMinWidth = 220.0;

/// Which optional columns fit, given how much room the row actually has.
///
/// The row has to survive a narrow window, and it did not. The fixed
/// columns come to 758px before the name gets anything, so at an 800px window
/// the name cell was squeezed to 42 — and a name cell that narrow cannot hold
/// its own trailing marker. The label ellipsised to nothing, as it should, but
/// `current` is not text that gives way: it is a fixed 75px sitting in 30px of
/// space, and the row painted a yellow-and-black stripe over itself.
///
/// So the fix is not in the cell. Ellipsis cannot save a row whose *fixed*
/// parts already exceed it; something has to go. Columns drop widest-first,
/// which is also least-first by what the screen is for: `changes` is the
/// fingerprint, while `agent` and PR carry "needs you", and that is the
/// question the explorer exists to answer.
///
/// The name column keeps [_nameMinWidth] throughout, because a list of
/// worktrees you cannot read the names of is not a list of worktrees.
({bool changes, bool agent, bool forge, bool stack}) _affordable(
  double width, {
  required bool agent,
  required bool forge,
  required bool stack,
}) {
  if (width.isInfinite) {
    return (changes: true, agent: agent, forge: forge, stack: stack);
  }
  var fixed =
      _gutterWidth + _whenWidth + _actionsWidth + _scrollGutter + _nameMinWidth;
  var showChanges = true;
  var showAgent = agent;
  var showForge = forge;
  var showStack = stack;
  double total() =>
      fixed +
      (showChanges ? _changesWidth : 0) +
      (showAgent ? _agentWidth : 0) +
      (showForge ? _prWidth : 0) +
      (showStack ? _stackWidth : 0);

  if (total() > width) showChanges = false;
  if (total() > width) showAgent = false;
  if (total() > width) showForge = false;
  // Last, on the same widest-first rule: at 116 it is the narrowest column
  // here, so dropping it is the smallest saving available and buying room with
  // it is the worst trade on offer.
  if (total() > width) showStack = false;
  return (
    changes: showChanges,
    agent: showAgent,
    forge: showForge,
    stack: showStack,
  );
}

class WorktreeRowState extends State<WorktreeRow> {
  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var facts = widget.facts;

    return Tappable.builder(
      onTap: widget.onToggleExpand,
      // The wash is the primitive's; the flag still reveals the row's actions.
      feedback: TapFeedback.overlay,
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          // `accentSoft` for the keyboard; the pointer's wash is the
          // primitive's. Not a left edge: that slot is 2px of accent meaning
          // "open", and a border would inset the row out of line with the
          // header.
          color: widget.cursor ? colors.accentSoft : Colors.transparent,
          border: Border(bottom: BorderSide(color: colors.line)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _rowHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  var afford = _affordable(
                    constraints.maxWidth,
                    agent: widget.showAgent,
                    forge: widget.showForge,
                    stack: widget.showStack,
                  );
                  return Row(
                    children: [
                      _Gutter(isOpen: widget.isOpen, tone: facts.tone),
                      Expanded(
                        child: _NameCell(
                          label: widget.label,
                          branch: widget.branch,
                          isMain: widget.isMain,
                          isCurrent: widget.isCurrent,
                          match: widget.match,
                        ),
                      ),
                      if (afford.changes)
                        SizedBox(
                          key: changesCellKey,
                          width: _changesWidth,
                          child: _ChangesCell(
                            fact: facts.git,
                            scale: widget.scale,
                          ),
                        ),
                      if (afford.stack)
                        SizedBox(
                          key: stackCellKey,
                          width: _stackWidth,
                          child: _StackCell(fact: facts.stack, now: widget.now),
                        ),
                      if (afford.agent)
                        SizedBox(
                          width: _agentWidth,
                          child: _AgentCell(fact: facts.agent, now: widget.now),
                        ),
                      if (afford.forge)
                        SizedBox(
                          width: _prWidth,
                          child: _PrCell(fact: facts.forge),
                        ),
                      SizedBox(
                        width: _whenWidth,
                        child: _WhenCell(fact: facts.activity, now: widget.now),
                      ),
                      SizedBox(
                        width: _actionsWidth,
                        child: _Actions(
                          hovered: hovered,
                          isOpen: widget.isOpen,
                          expanded: widget.expanded,
                          onOpen: widget.onOpen,
                          onToggleExpand: widget.onToggleExpand,
                          onRemove: widget.onRemove,
                        ),
                      ),
                      const Gap(_scrollGutter),
                    ],
                  );
                },
              ),
            ),
            if (widget.expanded)
              WorktreeDetail(
                facts: facts,
                path: widget.path,
                branch: widget.branch,
                now: widget.now,
                insetLeft: explorerInsetLeft,
                insetRight: explorerInsetRight,
              ),
          ],
        ),
      ),
    );
  }
}

/// Two marks, two meanings: the edge says *open*, the dot says *attention*.
/// Conflating them would make one pixel answer two different questions.
class _Gutter extends StatelessWidget {
  const _Gutter({required this.isOpen, required this.tone});

  final bool isOpen;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return SizedBox(
      width: _gutterWidth,
      child: Row(
        children: [
          Container(
            width: 2,
            height: _rowHeight,
            color: isOpen ? colors.accent : Colors.transparent,
          ),
          const Spacer(),
          if (tone != Tone.neutral)
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: toneColor(colors, tone),
                shape: BoxShape.circle,
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// The two-line frame every cell shares.
///
/// Both lines are always laid out, even when one is empty, so the top lines
/// share a baseline across cells whatever any given worktree happens to know.
class _Lines extends StatelessWidget {
  const _Lines({this.top, this.bottom, this.dim = false, this.padded = true});

  final Widget? top;
  final Widget? bottom;

  /// A stale value is shown rather than hidden — dimmed, and never replaced by
  /// a spinner. One "Refreshing…" in the header covers the progress.
  final bool dim;

  final bool padded;

  @override
  Widget build(BuildContext context) {
    Widget child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 17,
          child: Align(alignment: Alignment.centerLeft, child: top),
        ),
        SizedBox(
          height: 15,
          child: Align(alignment: Alignment.centerLeft, child: bottom),
        ),
      ],
    );
    if (dim) child = Opacity(opacity: 0.5, child: child);
    return Padding(
      padding: EdgeInsets.only(right: padded ? FwSpacing.lg : 0),
      child: child,
    );
  }
}

/// The dash a cell shows when there is nothing to know and never will be.
/// Quiet on purpose: `unavailable` is not an error and must not read as one.
class _Nothing extends StatelessWidget {
  const _Nothing([this.caption, this.tooltip]);

  /// Short enough for the narrowest cell. The full reason goes in [tooltip] —
  /// an ellipsised explanation explains nothing.
  final String? caption;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Widget lines = _Lines(
      top: Text(
        '—',
        style: context.type.bodySmall.copyWith(color: colors.mut3),
      ),
      bottom: caption == null
          ? null
          : Text(
              caption!,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
    );
    return tooltip == null ? lines : Tooltip(message: tooltip!, child: lines);
  }
}

/// A probe that broke. Never a red row — a failing probe is a flutterware
/// problem rather than a worktree problem.
class _Broken extends StatelessWidget {
  const _Broken(this.failure);

  final String? failure;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: failure ?? 'This probe failed.',
      child: _Lines(
        top: Icon(Icons.error_outline, size: FwIconSize.sm, color: colors.mut2),
        bottom: Text(
          "couldn't read",
          style: context.type.micro.copyWith(color: colors.mut3),
        ),
      ),
    );
  }
}

class _NameCell extends StatelessWidget {
  const _NameCell({
    required this.label,
    required this.branch,
    required this.isMain,
    required this.isCurrent,
    required this.match,
  });

  final String label;
  final String? branch;
  final bool isMain;
  final bool isCurrent;
  final FilterMatch? match;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return _Lines(
      top: Row(
        children: [
          Flexible(
            child: DefaultTextStyle(
              style: context.type.bodyStrong,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              child: matchedName(
                context,
                label,
                context.type.bodyStrong,
                match: match,
              ),
            ),
          ),
          if (isMain) ...[const Gap(FwSpacing.sm), _Tag('~')],
        ],
      ),
      bottom: Row(
        children: [
          Flexible(
            child: DefaultTextStyle(
              style: context.type.caption,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              child: matchedName(
                context,
                branch ?? 'detached',
                context.type.caption,
                match: match,
                field: 1,
              ),
            ),
          ),
          if (isCurrent) ...[
            const Gap(FwSpacing.sm),
            Text(
              'current',
              style: context.type.micro.copyWith(color: colors.accent),
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line2),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(text, style: context.type.micro.copyWith(color: colors.mut2)),
    );
  }
}

class _ChangesCell extends StatelessWidget {
  const _ChangesCell({required this.fact, required this.scale});

  final Fact<GitFacts> fact;
  final double scale;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (fact.state == FactState.failed) return _Broken(fact.failure);
    // **On the value, not on the state.** `unknown` is not the only state that
    // carries nothing — `unavailable` does too, and enumerating states here
    // meant this cell was one provider change away from a null assertion in the
    // middle of a list. The other three cells already ask the question this way.
    if (!fact.hasValue) return const _Nothing();

    var git = fact.value!;
    var shape = git.changes;

    // A branch that has committed nothing, in a worktree full of edits. Real
    // and common — the first repo this ran against had one with 45 changed
    // files and no commits of its own. "in sync" is true of the branch and a
    // lie about the worktree, so the dirt is the headline when there is any.
    if (shape == null || shape.isEmpty) {
      var lines = _Lines(
        dim: fact.isDim,
        top: git.dirty > 0
            ? Row(
                children: [
                  _Dirty(git.dirty),
                  const Gap(FwSpacing.sm),
                  Text(
                    'uncommitted',
                    style: context.type.bodySmall.copyWith(color: colors.mut2),
                  ),
                ],
              )
            : Text(
                'in sync',
                style: context.type.bodySmall.copyWith(color: colors.mut2),
              ),
        bottom: git.behind > 0 || git.ahead > 0
            ? Text(
                '${git.ahead > 0 ? '↑${git.ahead} ' : ''}'
                        '${git.behind > 0 ? '↓${git.behind}' : ''}'
                    .trim(),
                style: context.type.micro.copyWith(color: colors.mut3),
              )
            : null,
      );
      // Nothing changed and nothing uncommitted means there is genuinely
      // nothing to list, so hovering it stays inert.
      return lines;
    }

    var ranked = shape.ranked;
    var lines = _Lines(
      dim: fact.isDim,
      top: Row(
        children: [
          _Fingerprint(shape: shape, scale: scale),
          const Gap(FwSpacing.md),
          Flexible(
            child: Text(
              [for (var b in ranked.take(2)) b.name].join('·'),
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.micro.copyWith(color: colors.mut2),
            ),
          ),
        ],
      ),
      bottom: Row(
        children: [
          Text(
            '${shape.files}f',
            style: context.type.micro.copyWith(color: colors.mut),
          ),
          const Gap(FwSpacing.sm),
          Text(
            '+${_short(shape.added)}',
            style: context.type.micro.copyWith(color: colors.grn),
          ),
          const Gap(FwSpacing.xs),
          Text(
            '−${_short(shape.removed)}',
            style: context.type.micro.copyWith(color: colors.red),
          ),
          if (git.dirty > 0) ...[const Gap(FwSpacing.md), _Dirty(git.dirty)],
          if (git.ahead > 0 || git.behind > 0) ...[
            const Gap(FwSpacing.md),
            Text(
              '↑${git.ahead}${git.behind > 0 ? ' ↓${git.behind}' : ''}',
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          ],
        ],
      ),
    );
    return lines;
  }
}

/// Uncommitted work. A different question from branch size, so a different
/// mark — this one is about what you would lose rather than what you
/// changed.
class _Dirty extends StatelessWidget {
  const _Dirty(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: colors.amber,
            shape: BoxShape.circle,
          ),
        ),
        const Gap(FwSpacing.xxs),
        Text('$count', style: context.type.micro.copyWith(color: colors.amber)),
      ],
    );
  }
}

/// Proportion in the bar, meaning in the text beside it.
///
/// No hue. A colour per directory is not comparable row to row without a
/// hover, which makes it decoration; the luminance ramp already in the palette
/// orders the buckets, and the two dominant names are spelled out next to it.
///
/// Shared scale. Width tracks the branch's size relative to the busiest row
/// on screen, which is the whole reason the bar exists — "that one is big, this
/// one is a typo fix", read straight down the column. Square-rooted so a
/// 2,000-line branch does not render every other row as a stub.
class _Fingerprint extends StatelessWidget {
  const _Fingerprint({required this.shape, required this.scale});

  final ChangeShape shape;
  final double scale;

  static const _maxWidth = 110.0;
  static const _minWidth = 8.0;
  static const _height = 4.0;

  /// Three. A fourth segment is a couple of pixels wide at the widths these
  /// bars get, which is noise rather than information.
  static const _maxSegments = 3;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // Two tones alternating, not a four-step ramp down. A descending ramp put
    // two near-identical greys next to each other and the boundary vanished at
    // the width these bars actually get; which bucket is which is the text's
    // job anyway, and the bar only has to show the split.
    var ramp = [colors.ink2, colors.mut2];

    var ranked = shape.ranked;
    var segments = ranked.take(_maxSegments).toList();
    if (ranked.length > _maxSegments) {
      var rest = ranked.skip(_maxSegments);
      segments[_maxSegments - 1] = ChangeBucket(
        segments.last.name,
        added: segments.last.added + rest.fold(0, (s, b) => s + b.added),
        removed: segments.last.removed + rest.fold(0, (s, b) => s + b.removed),
      );
    }

    // A fixed slot with a variable bar left-aligned inside it, so the bucket
    // labels start at the same x on every row. Sizing the slot to the bar
    // instead put each row's label wherever its branch size happened to leave
    // it, and a column of labels that will not line up is a column you cannot
    // read down.
    return SizedBox(
      width: _maxWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: (_maxWidth * math.sqrt(scale.clamp(0, 1))).clamp(
            _minWidth,
            _maxWidth,
          ),
          height: _height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_height / 2),
            child: Row(
              // Without this the segments are zero-tall: `ColoredBox` has no
              // intrinsic size, and a centred cross axis gives it none.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var (i, bucket) in segments.indexed)
                  Expanded(
                    flex: math.max(1, bucket.lines),
                    child: ColoredBox(color: ramp[i % ramp.length]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What this checkout's dev stack was last seen doing.
///
/// The answer to "which of my worktrees is holding the port block". That is
/// the question the whole per-worktree port allocation exists to create, and
/// until this column existed the only way to answer it was to open eight
/// checkouts one at a time.
///
/// One word and a port, and never anything else: this cell is 116 pixels and
/// the state is the only thing that fits. The reasons, the services and the
/// controls are two clicks away on the worktree's own screen.
///
/// Everything here is a cached reading — see `providers/stack.dart`. So the
/// age is not decoration: a stale cell means *nothing has looked recently*
/// rather than *this is what is true now*, and it dims to show that.
class _StackCell extends StatelessWidget {
  const _StackCell({required this.fact, required this.now});

  final Fact<StackReading> fact;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // No `_Broken` case: there is no probe here to fail, only a file that is
    // there or is not.
    if (!fact.hasValue) return const _Nothing();

    var reading = fact.value!;
    var (label, color) = switch (reading.state) {
      StackState.up when reading.isPartial => (
        'up ${reading.serviceCount!.$1}/${reading.serviceCount!.$2}',
        colors.amber,
      ),
      StackState.up => ('up', colors.grn),
      StackState.down => ('down', colors.mut2),
      StackState.starting => ('bringing up', colors.amber),
      StackState.stopping => ('tearing down', colors.amber),
      StackState.unavailable => ("can't tell", colors.red),
      StackState.unknown => ('—', colors.mut3),
    };

    // The port, when the probe named one. It is what you actually go looking
    // for — "which one has 8080" — and it is four characters.
    var port = reading.services.map((s) => s.port).whereType<int>().firstOrNull;

    return _Lines(
      dim: fact.isDim,
      top: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const Gap(FwSpacing.sm),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.bodySmall.copyWith(color: color),
            ),
          ),
          if (port != null && reading.state == StackState.up) ...[
            const Gap(FwSpacing.sm),
            Text(
              ':$port',
              style: context.type.bodySmall.copyWith(color: colors.mut2),
            ),
          ],
        ],
      ),
      // Only once it is old enough to doubt. On a checkout somebody is watching
      // this line is absent, which is the difference between a column that
      // reports and one that natters.
      bottom: fact.isDim && reading.at != null
          ? Text(
              'seen ${_ago(reading.at!, now)}',
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.micro.copyWith(color: colors.mut3),
            )
          : null,
    );
  }
}

class _AgentCell extends StatelessWidget {
  const _AgentCell({required this.fact, required this.now});

  final Fact<AgentFacts> fact;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (fact.state == FactState.failed) return _Broken(fact.failure);
    if (fact.state == FactState.unavailable) return const _Nothing('no agent');
    if (!fact.hasValue) return const _Nothing();

    var agent = fact.value!;
    if (agent.state == AgentState.none) return const _Nothing('no agent');

    var (label, color) = switch (agent.state) {
      AgentState.waiting => ('waiting for you', colors.accent),
      AgentState.working => ('working', colors.grn),
      AgentState.idle => (
        'idle ${agent.at == null ? '' : _ago(agent.at!, now)}'.trim(),
        colors.mut2,
      ),
      AgentState.none => ('', colors.mut3),
    };

    return _Lines(
      dim: fact.isDim,
      top: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const Gap(FwSpacing.sm),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.bodySmall.copyWith(color: color),
            ),
          ),
        ],
      ),
      // The last prompt, not the title — the title has already been promoted
      // into the name cell, and repeating it wastes the row's most interesting
      // 190 pixels on something already on screen.
      bottom: agent.lastPrompt == null
          ? null
          : Text(
              '“${agent.lastPrompt}”',
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
    );
  }
}

class _PrCell extends StatelessWidget {
  const _PrCell({required this.fact});

  final Fact<ForgeFacts> fact;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (fact.state == FactState.failed) return _Broken(fact.failure);
    if (fact.state == FactState.unavailable) {
      return _Nothing('no PR', fact.failure);
    }
    if (fact.state == FactState.unknown) return const _Nothing();
    if (!fact.hasValue) return const _Nothing('no PR');

    var pr = fact.value!;
    var (checksIcon, checksColor, checksText) = switch (pr.checks) {
      ChecksState.failing => (
        Icons.close,
        colors.red,
        '${pr.failingChecks} failing',
      ),
      ChecksState.passing => (Icons.check, colors.grn, 'checks pass'),
      ChecksState.pending => (Icons.schedule, colors.amber, 'checks running'),
      ChecksState.none => (null, colors.mut3, ''),
    };
    var reviewText = pr.review.label;

    return _Lines(
      dim: fact.isDim,
      top: Row(
        children: [
          Text(
            '#${pr.number}',
            style: context.type.bodySmall.copyWith(color: colors.mut),
          ),
          const Gap(FwSpacing.sm),
          if (checksIcon != null)
            Icon(checksIcon, size: FwIconSize.xs, color: checksColor),
          const Gap(FwSpacing.xs),
          Flexible(
            child: Text(
              switch (pr.state) {
                PrState.draft => 'draft',
                PrState.open => 'open',
                PrState.merged => 'merged',
                PrState.closed => 'closed',
              },
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: context.type.bodySmall.copyWith(color: colors.mut2),
            ),
          ),
        ],
      ),
      bottom: Text(
        // **Worst wins, and then stops** — the same rule as the row's dot.
        // "checks pass · changes asked" is 27 characters in a 150-pixel cell
        // and ellipsized away the half that was a job; the half that was a
        // reassurance survived. So when somebody has asked for changes, that
        // is the whole line.
        (pr.review == ReviewState.changesRequested
                ? [reviewText]
                : [
                    if (checksText.isNotEmpty) checksText,
                    if (reviewText.isNotEmpty) reviewText,
                  ])
            .join(' · '),
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: context.type.micro.copyWith(
          // Amber only for the one review state that is waiting on you. The
          // others are information; this one is a job.
          color: pr.review == ReviewState.changesRequested
              ? colors.amber
              : colors.mut3,
        ),
      ),
    );
  }
}

/// The relative time, and which clock it came from.
///
/// The attribution matters. "4m" that silently means a commit on one row and an
/// agent message on the next is worse than no time at all.
class _WhenCell extends StatelessWidget {
  const _WhenCell({required this.fact, required this.now});

  final Fact<ActivityFacts> fact;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (!fact.hasValue) return const _Nothing();
    var activity = fact.value!;
    return _Lines(
      dim: fact.isDim,
      padded: false,
      top: Text(
        _ago(activity.at, now),
        style: context.type.bodySmall.copyWith(color: colors.mut),
      ),
      bottom: Text(
        activity.sourceLabel,
        style: context.type.micro.copyWith(color: colors.mut3),
      ),
    );
  }
}

/// Open on hover, and nothing when there is nothing to do.
///
/// Only on hover: a button beside every row is a wall of controls, and the row
/// is already clickable.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.hovered,
    required this.isOpen,
    required this.expanded,
    required this.onOpen,
    required this.onToggleExpand,
    required this.onRemove,
  });

  final bool hovered;
  final bool isOpen;
  final bool expanded;
  final VoidCallback? onOpen;
  final VoidCallback? onToggleExpand;

  /// Null for the primary checkout, which cannot be removed.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // The chevron persists while expanded, so an open row still says how it
    // got that way and how to close it. Otherwise controls are hover-only: a
    // button beside every row is a wall rather than a list.
    var showControls = hovered || expanded;
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!showControls && isOpen)
            Text(
              'open',
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          // **Kept in the layout whether or not it is shown.** It is hover-only,
          // and reaching for the menu beside it ends the hover — so a button
          // that vacated its space made the trigger jump right, out from under
          // the cursor that was arriving at it. The column is a fixed width
          // either way, so reserving ~40px inside it costs nothing.
          Visibility(
            visible: hovered,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: TextButton(
              onPressed: hovered ? onOpen : null,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: FwSpacing.sm,
                  vertical: FwSpacing.xxs,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                isOpen ? 'Go' : 'Open',
                style: context.type.micro.copyWith(color: colors.accent),
              ),
            ),
          ),
          // Destructive, so behind a menu rather than beside Open: a click that
          // deletes a checkout should not be one pixel from a click that opens
          // it.
          //
          // **Mounted whenever there is something to open, and hidden by its
          // own builder rather than by this list.** A trigger that unmounts
          // when hover ends takes its open menu with it — and reaching for a
          // menu item is precisely the gesture that leaves the row, so the item
          // could be seen and never clicked. `controller.isOpen` is what keeps
          // it alive across that gap.
          if (onRemove != null)
            Menu(
              // **Keyed, and that is what makes the menu clickable at all.**
              // The `Open` button above disappears when hover ends, so this
              // widget shifts index within the Row — and unkeyed children are
              // matched by position, so it would be diffed against a
              // `TextButton`, lose its element, and take its open popover with
              // it. Reaching for a menu item is precisely the gesture that ends
              // the hover, so the item could be seen and never clicked.
              key: const ValueKey('worktree-row.menu'),
              entries: [
                MenuItem(
                  'Remove worktree…',
                  icon: Icons.delete_outline,
                  danger: true,
                  onSelected: onRemove,
                ),
              ],
              side: PopoverSide.bottom,
              align: PopoverAlign.end,
              builder: (context, controller) => hovered || controller.isOpen
                  ? Tooltip(
                      message: 'More',
                      child: InkWell(
                        onTap: controller.toggle,
                        child: Icon(
                          Icons.more_horiz,
                          size: FwIconSize.md,
                          color: colors.mut2,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          Visibility(
            visible: showControls,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Tooltip(
              message: expanded ? 'Hide the detail' : 'Show the detail',
              child: Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: FwIconSize.md,
                color: colors.mut2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _short(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// Coarse on purpose: this column is 64 pixels wide and the question it answers
/// is "recently, or not".
String _ago(DateTime then, DateTime now) {
  var d = now.difference(then);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}
