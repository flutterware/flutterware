import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../shell/worktree.dart';
import '../shell/worktree_filter.dart';
import '../ui/theme.dart';
import 'explorer_row.dart';
import 'facts.dart';
import 'facts_text.dart';

/// One worktree and everything known about it.
///
/// Pairs the shell's existing identity type with the facts layer rather than
/// inventing a third: `Worktree` stays the only thing that knows what a
/// checkout *is*.
class ExplorerEntry {
  const ExplorerEntry({
    required this.worktree,
    this.facts = const WorktreeFacts(),
    this.isOpen = false,
  });

  final Worktree worktree;
  final WorktreeFacts facts;

  /// Whether the shell holds a tab for it. The shell's business, not the facts
  /// layer's — passed in rather than probed.
  final bool isOpen;

  /// The label-priority stack, resolved.
  ///
  /// Open question (inherited from the 2026-05-18 plugin design, and this is
  /// the first surface where both are routinely present): an agent title and a
  /// PR title both want to be the name. The rule here is that a *live* agent
  /// wins — while it is working or waiting, its title is what the worktree is
  /// currently about — and the PR title wins otherwise.
  String get label {
    var agent = facts.agent.value;
    if (agent != null &&
        agent.title != null &&
        (agent.state == AgentState.working ||
            agent.state == AgentState.waiting)) {
      return agent.title!;
    }
    if (facts.forge.value?.title case var title?) return title;
    if (agent?.title case var title?) return title;
    return worktree.displayName;
  }

  int get branchLines => facts.git.value?.changes?.lines ?? 0;
}

/// How the list is ordered.
///
/// [activity] is the default, and deliberately **not** grouped open-first: the
/// worktree that needs you is most often the one that is *not* open — an agent
/// finished while you were elsewhere — and grouping by open-ness buries exactly
/// the row this screen exists to surface. Open-ness is a marker, not a section.
enum ExplorerSort {
  activity('activity'),
  needsYou('needs you'),
  name('name'),
  branch('branch');

  const ExplorerSort(this.label);
  final String label;
}

/// The explorer — `fw:///worktrees`.
///
/// A View: entries and callbacks in, no probing, no git, no clock of its own.
/// See `docs/superpowers/specs/2026-08-10-worktree-explorer-view-design.md`.
class WorktreeExplorerView extends StatefulWidget {
  const WorktreeExplorerView({
    super.key,
    required this.entries,
    required this.now,
    this.query = '',
    this.sort = ExplorerSort.activity,
    this.refreshedAt,
    this.isRefreshing = false,
    this.currentWorktreePath,
    this.onQueryChanged,
    this.onSortChanged,
    this.onRefresh,
    this.onOpen,
    this.onRemove,
    this.onOpenChanges,
    this.repoRoot,
  });

  final List<ExplorerEntry> entries;
  final DateTime now;
  final String query;
  final ExplorerSort sort;
  final DateTime? refreshedAt;
  final bool isRefreshing;
  final String? currentWorktreePath;

  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<ExplorerSort>? onSortChanged;
  final VoidCallback? onRefresh;
  final ValueChanged<ExplorerEntry>? onOpen;

  /// Opens the teardown checklist for a row. Never offered for the primary
  /// checkout — [Worktree.isMain] says it cannot be removed, so the row does
  /// not carry the affordance rather than carrying a disabled one.
  final ValueChanged<ExplorerEntry>? onRemove;

  /// Opens the full changes screen for a checkout — the popover's footer and
  /// the `⌘⇧D` destination. Deliberately separate from [onOpen]: reading what
  /// a checkout changed must not cost the config subprocess that opening it
  /// does, which is the whole reason the changes screen is shell-owned.
  final ValueChanged<ExplorerEntry>? onOpenChanges;

  /// The main checkout, which keys the cached `ChangesConfig` the popovers
  /// rank by.
  final String? repoRoot;

  /// Injected for tests, so pumping the explorer never spawns an isolate.

  @override
  State<WorktreeExplorerView> createState() => _WorktreeExplorerViewState();
}

class _WorktreeExplorerViewState extends State<WorktreeExplorerView> {
  /// Which rows are showing their detail.
  ///
  /// A set, not one at a time. Comparing two checkouts is the reason this
  /// screen exists, and a detail that closed the moment you opened another one
  /// would turn the comparison into a memory test.
  final _expanded = <String>{};

  /// Where the keyboard is, **as a path rather than an index**.
  ///
  /// An index would be a bug with a schedule attached: the watchers re-probe in
  /// the background, a row can arrive or leave, and the list is ordered by
  /// freshness — so an index that meant `claude/thing` when you pressed Down
  /// can mean something else by the time you press Enter. A path cannot drift.
  String? _cursor;

  final _scroll = ScrollController();

  /// Which row's changes popover is open, if any.
  ///
  /// One at a time, unlike [_expanded]. A detail is comparable and a ranked
  /// file list is not, so the set that makes the explorer worth having would
  /// make this one unreadable.

  /// One key per row, so the cursor can be scrolled into view.
  ///
  /// Keyed by path and reused, because a `GlobalKey` that changed identity
  /// every build would rebuild the row's state with it.
  final _rowKeys = <String, GlobalKey<WorktreeRowState>>{};

  /// The filter's node, and the screen's key handling — **the same node**.
  ///
  /// The field keeps focus the whole time you are here, so typing filters
  /// without a gesture to reach for it, and the keys the list wants are taken
  /// on the way in. That is exactly how `CommandPalette` is wired; a screen with
  /// a filter and a list is the same instrument.
  late final FocusNode _focus = FocusNode(
    onKeyEvent: _onKey,
    debugLabel: 'worktree explorer',
  );

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toggle(String path) => setState(
    () =>
        _expanded.contains(path) ? _expanded.remove(path) : _expanded.add(path),
  );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Recomputed rather than remembered: it is the same list the last build
    // drew, and a cached copy is one refresh away from being a different one.
    var rows = _filtered();

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(rows, 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(rows, -1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        var entry = _cursorEntry(rows);
        if (entry == null) return KeyEventResult.ignored;
        // **The same split the mouse has.** Enter expands, because clicking a
        // row expands; opening costs a subprocess and a tab, so it keeps its
        // modifier the way it keeps its button.
        var keyboard = HardwareKeyboard.instance;
        if (keyboard.isMetaPressed || keyboard.isControlPressed) {
          widget.onOpen?.call(entry);
        } else {
          _toggle(entry.worktree.path);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyC:
        // **A plain letter, and it can be**: the filter field takes every
        // printable key, so a bare `c` would type. This one is only reached
        // when the field is empty *and* a cursor exists — which is the state
        // where the keyboard is driving the list rather than the filter. Any
        // other time it falls through and types a `c`, which is what the user
        // meant.
        if (widget.query.isNotEmpty || _cursor == null) {
          return KeyEventResult.ignored;
        }
        var entry = _cursorEntry(rows);
        if (entry == null) return KeyEventResult.ignored;
        widget.onOpenChanges?.call(entry);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // The filter, and only that. Escape with nothing to clear is left
        // alone, so whatever the shell does with it still happens.
        if (widget.query.isEmpty) return KeyEventResult.ignored;
        widget.onQueryChanged?.call('');
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  ExplorerEntry? _cursorEntry(List<(ExplorerEntry, FilterMatch?)> rows) {
    for (var (entry, _) in rows) {
      if (entry.worktree.path == _cursor) return entry;
    }
    return null;
  }

  void _move(List<(ExplorerEntry, FilterMatch?)> rows, int delta) {
    if (rows.isEmpty) return;
    var index = rows.indexWhere((r) => r.$1.worktree.path == _cursor);
    // No cursor yet — or one that the filter has just excluded. Down starts at
    // the top and Up at the bottom, which is what the key means when there is
    // nothing to move from.
    var next = index < 0
        ? (delta > 0 ? 0 : rows.length - 1)
        : (index + delta).clamp(0, rows.length - 1);
    setState(() => _cursor = rows[next].$1.worktree.path);
    _revealCursor();
  }

  void _revealCursor() {
    // After layout, so the row being scrolled to has been built. A step of one
    // is nearly always already within the list's cache extent; a jump further
    // than that simply does not scroll, which is better than throwing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      var context = _rowKeys[_cursor]?.currentContext;
      if (context == null || !context.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 80),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var rows = _filtered();
    // The busiest row sets the scale every bar is drawn against — which is what
    // makes the widths mean something relative to each other.
    var busiest = rows.fold(0, (max, r) => math.max(max, r.$1.branchLines));

    // Decided once for the whole list, so the cells stay in line. See
    // `WorktreeRow.showAgent`.
    var showAgent = rows.any(
      (r) =>
          (r.$1.facts.agent.value?.state ?? AgentState.none) != AgentState.none,
    );
    var showForge = rows.any((r) => r.$1.facts.forge.hasValue);
    // Most repositories declare no stack anywhere, and a column of dashes is
    // 116 pixels taken from the names for nothing.
    var showStack = rows.any((r) => r.$1.facts.stack.hasValue);

    return ColoredBox(
      color: colors.bg,
      child: Column(
        children: [
          _Header(
            focusNode: _focus,
            total: widget.entries.length,
            shown: rows.length,
            query: widget.query,
            sort: widget.sort,
            refreshedAt: widget.refreshedAt,
            isRefreshing: widget.isRefreshing,
            now: widget.now,
            onQueryChanged: widget.onQueryChanged,
            onSortChanged: widget.onSortChanged,
            onRefresh: widget.onRefresh,
          ),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: NoWorktreeMatches())
                : ListView.builder(
                    controller: _scroll,
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      var (entry, match) = rows[i];
                      var worktree = entry.worktree;
                      return WorktreeRow(
                        // Identity, so a row that moves takes its own hover and
                        // expansion with it instead of inheriting the state of
                        // whatever used to sit at this index. A `GlobalKey`
                        // rather than a `ValueKey` because the cursor has to
                        // find this row's context to scroll it into view.
                        key: _rowKeys[worktree.path] ??= GlobalKey(),
                        cursor: worktree.path == _cursor,
                        label: entry.label,
                        branch: worktree.branch,
                        isMain: worktree.isMain,
                        isOpen: entry.isOpen,
                        isCurrent: worktree.path == widget.currentWorktreePath,
                        facts: entry.facts,
                        now: widget.now,
                        match: match,
                        scale: busiest == 0 ? 0 : entry.branchLines / busiest,
                        showAgent: showAgent,
                        showForge: showForge,
                        showStack: showStack,
                        expanded: _expanded.contains(worktree.path),
                        path: worktree.path,
                        onToggleExpand: () => _toggle(worktree.path),
                        onOpen: () => widget.onOpen?.call(entry),
                        onRemove: worktree.isMain || widget.onRemove == null
                            ? null
                            : () => widget.onRemove!.call(entry),
                        onOpenChanges: () => widget.onOpenChanges?.call(entry),
                        repoRoot: widget.repoRoot,
                      );
                    },
                  ),
          ),
          const _KeyHints(),
        ],
      ),
    );
  }

  List<(ExplorerEntry, FilterMatch?)> _filtered() {
    var rows = <(ExplorerEntry, FilterMatch?)>[];
    for (var entry in widget.entries) {
      if (widget.query.trim().isEmpty) {
        rows.add((entry, null));
        continue;
      }
      var match = matchWorktreeFilter(widget.query, [
        entry.label,
        entry.worktree.branch,
        entry.worktree.name,
      ]);
      if (match != null) rows.add((entry, match));
    }
    rows.sort((a, b) => _compare(a.$1, b.$1));
    return rows;
  }

  /// A total order, in every mode. `List.sort` is not stable in Dart, so a
  /// comparator that returns 0 for two rows lets them trade places on any
  /// rebuild — and with watchers running, rebuilds happen every couple of
  /// seconds. Every mode therefore ends at the path, which nothing can change.
  int _compare(ExplorerEntry a, ExplorerEntry b) {
    var first = switch (widget.sort) {
      // By the age the row prints — see [activityAge]. Sorting by the exact
      // timestamp made two working agents swap on every keystroke of theirs.
      ExplorerSort.activity => _age(a).compareTo(_age(b)),
      // Then by freshness within each half, so "needs you" is a partition of
      // the activity order rather than a different list.
      ExplorerSort.needsYou =>
        _needs(b).compareTo(_needs(a)) != 0
            ? _needs(b).compareTo(_needs(a))
            : _age(a).compareTo(_age(b)),
      ExplorerSort.name => a.label.toLowerCase().compareTo(
        b.label.toLowerCase(),
      ),
      ExplorerSort.branch => (a.worktree.branch ?? '').compareTo(
        b.worktree.branch ?? '',
      ),
    };
    return first != 0 ? first : a.worktree.path.compareTo(b.worktree.path);
  }

  int _needs(ExplorerEntry e) => e.facts.needsYou ? 1 : 0;

  Duration _age(ExplorerEntry e) => activityAge(e.facts, widget.now);
}

/// What the keyboard does, said once, quietly.
///
/// An undiscoverable shortcut goes unused — and ⌘↵ in particular is not
/// guessable. One muted strip costs 22 pixels and is all the documentation
/// there is.
class _KeyHints extends StatelessWidget {
  const _KeyHints();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: explorerInsetLeft),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Text(
        // The key handler takes either modifier everywhere — being forgiving
        // about that costs nothing — but the hint has to name the one this
        // machine's keyboard actually has on it.
        // `c` was built and then left off this strip, which made the popover
        // undiscoverable twice over: the bar it hangs off looks like a chart,
        // not a button, and the one place that documents the keyboard did not
        // mention it. A feature nobody can find is a feature nobody has.
        '↑↓ move    ↵ detail    c files    '
        '${defaultTargetPlatform == TargetPlatform.macOS ? '⌘↵' : 'ctrl+↵'}'
        ' open    esc clear',
        style: context.type.micro.copyWith(color: colors.mut3),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.total,
    required this.shown,
    required this.query,
    required this.sort,
    required this.refreshedAt,
    required this.isRefreshing,
    required this.now,
    required this.onQueryChanged,
    required this.onSortChanged,
    required this.onRefresh,
    required this.focusNode,
  });

  final FocusNode focusNode;
  final int total;
  final int shown;
  final String query;
  final ExplorerSort sort;
  final DateTime? refreshedAt;
  final bool isRefreshing;
  final DateTime now;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<ExplorerSort>? onSortChanged;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      // Matched to the rows below, so the title sits over the column of names
      // and the refresh button over the column of row controls.
      padding: const EdgeInsets.fromLTRB(
        explorerInsetLeft,
        FwSpacing.lg,
        explorerInsetRight,
        FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          Text('Worktrees', style: context.type.heading),
          const Gap(FwSpacing.md),
          Text(
            shown == total ? '$total' : '$shown of $total',
            style: context.type.caption.copyWith(color: colors.mut2),
          ),
          const Gap(FwSpacing.xxl),
          // Absorbs the slack rather than claiming a fixed 240 beside a
          // `Spacer` — which overflows the moment the window is narrower than
          // the sum of everything on this row, and a header that overflows is
          // the first thing anyone sees.
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: _Filter(
                  query: query,
                  focusNode: focusNode,
                  onChanged: onQueryChanged,
                ),
              ),
            ),
          ),
          const Gap(FwSpacing.lg),
          Text('Sort', style: context.type.micro.copyWith(color: colors.mut3)),
          const Gap(FwSpacing.sm),
          _SortMenu(sort: sort, onChanged: onSortChanged),
          const Gap(FwSpacing.xl),
          // The one progress indicator on the screen. Cells go dim; they never
          // grow spinners.
          if (isRefreshing)
            Text(
              'Refreshing…',
              style: context.type.micro.copyWith(color: colors.mut2),
            )
          else if (refreshedAt != null)
            Text(
              _agoLabel(refreshedAt!, now),
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          const Gap(FwSpacing.sm),
          IconButton(
            onPressed: onRefresh,
            icon: Icon(Icons.refresh, size: FwIconSize.md, color: colors.mut),
            tooltip: 'Refresh every worktree',
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  static String _agoLabel(DateTime then, DateTime now) {
    var d = now.difference(then);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}

/// The filter box, and **the one controller on this screen**.
///
/// It has to be stateful. A `TextEditingController` built in `build` is a new
/// controller on every rebuild, which throws away the selection and the composing
/// region — and once the filesystem watchers landed, this screen rebuilds every
/// couple of seconds whether or not anybody is typing, so the field became
/// unusable: the caret jumped to the start mid-word and the keyboard appeared to
/// lose the field.
///
/// The controller therefore outlives the builds, and the incoming [query] is
/// pushed into it **only when it actually differs** — a blind assignment on every
/// rebuild would move the caret to the end for the same reason, one keystroke
/// later.
class _Filter extends StatefulWidget {
  const _Filter({
    required this.query,
    required this.focusNode,
    required this.onChanged,
  });

  final String query;

  /// Owned by the screen, because the keys the *list* needs are taken on this
  /// node's way in — see `_WorktreeExplorerViewState._onKey`.
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;

  @override
  State<_Filter> createState() => _FilterState();
}

class _FilterState extends State<_Filter> {
  late final _controller = TextEditingController(text: widget.query);

  @override
  void didUpdateWidget(_Filter old) {
    super.didUpdateWidget(old);
    // Only when something *else* changed the query — a cleared filter, an
    // address that carried one. Typing round-trips through `onChanged` and comes
    // back identical, and this must not touch the field then.
    if (widget.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.radii.radius),
      borderSide: BorderSide(color: color),
    );
    // Width is the caller's business — it caps this at 240 and lets it shrink
    // below that on a narrow window.
    return TextField(
      controller: _controller,
      focusNode: widget.focusNode,
      // So the screen is typeable the moment it appears. There is nothing else
      // here that wants the keyboard, and the list's own keys pass through.
      autofocus: true,
      onChanged: widget.onChanged,
      style: context.type.bodySmall,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: colors.panel,
        prefixIcon: Icon(Icons.search, size: FwIconSize.sm, color: colors.mut3),
        prefixIconConstraints: const BoxConstraints.tightFor(
          width: 28,
          height: 20,
        ),
        hintText: 'Filter',
        hintStyle: context.type.bodySmall.copyWith(color: colors.mut3),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.sm,
        ),
        border: border(colors.line),
        enabledBorder: border(colors.line),
        focusedBorder: border(colors.accent),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onChanged});

  final ExplorerSort sort;
  final ValueChanged<ExplorerSort>? onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return MenuAnchor(
      menuChildren: [
        for (var value in ExplorerSort.values)
          MenuItemButton(
            onPressed: () => onChanged?.call(value),
            child: Text(value.label, style: context.type.bodySmall),
          ),
      ],
      builder: (context, controller, child) => TextButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sort.label,
              style: context.type.bodySmall.copyWith(color: colors.ink),
            ),
            Icon(Icons.expand_more, size: FwIconSize.sm, color: colors.mut2),
          ],
        ),
      ),
    );
  }
}
