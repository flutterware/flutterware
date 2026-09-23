import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart' show fuzzyMatch;
import 'package:path/path.dart' as p;

import '../ui/anchored_card.dart';
import '../ui/matched_text.dart';
import '../ui/theme.dart';
import 'kind_icon.dart';
import 'popover.dart';
import 'model/asset_catalog.dart';
import 'model/asset_scan.dart';
import 'model/asset_tree.dart';
import '../ui/tappable.dart';
import '../ui/tree_row.dart';

/// The left half: every key in the bundle, filtered.
///
/// A view — it takes the scan's data and hands back a selection. What it owns
/// is the filter, which is local to it: a search box is not state worth putting
/// in an address, because it names no place.
class AssetListView extends StatefulWidget {
  const AssetListView({
    super.key,
    required this.own,
    required this.fromPackages,
    required this.problems,
    required this.selected,
    required this.onSelect,
    this.onReload,
    this.scanning = false,
    this.initialQuery = '',
    this.peek = true,
  });

  final List<ResolvedAsset> own;
  final List<AssetOwner> fromPackages;
  final List<AssetProblem> problems;

  /// What the address names — an asset key, or a directory path once folders
  /// became places you can be in. One field for both, because the address does
  /// not distinguish them either: `assets/images` and `assets/images/logo.png`
  /// are the same grammar, and which one you landed on is a question for
  /// whoever holds the scan, not for a list drawing rows.
  final String? selected;

  /// The row that was picked, by that same path.
  final ValueChanged<String> onSelect;

  /// Re-reads the bundle off disk. Absent in a catalog demo, where there is no
  /// core behind the data and a dead button would only mislead.
  final VoidCallback? onReload;

  /// Whether a scan is in flight, so the reload button can say so.
  final bool scanning;

  /// What the filter starts with. Empty in the app; a catalog demo sets it so
  /// the matched-character highlighting is on screen rather than one keystroke
  /// away from it.
  final String initialQuery;

  /// Whether resting on a row shows the asset beside it. Off in a demo that
  /// stacks four of these side by side, where a card summoned by one case
  /// would be drawn over its neighbour.
  final bool peek;

  @override
  State<AssetListView> createState() => _AssetListViewState();
}

class _AssetListViewState extends State<AssetListView> {
  late final _search = TextEditingController(text: widget.initialQuery);
  AssetKind? _kind;
  var _problemsOnly = false;
  final _expanded = <String>{};

  /// The card that shows what a row is, and what it points at.
  ///
  /// An [OverlayPortal] rather than a stack member: the card has to escape the
  /// list's own clip, which is what makes it a card *beside* the list rather
  /// than one squeezed inside it.
  final _peek = OverlayPortalController();
  ResolvedAsset? _peeking;
  Rect? _anchor;
  Timer? _resting;

  /// Directories the reader opened and directories the reader closed, held
  /// apart rather than as one set of open ones. What is left — a directory
  /// nobody has touched — falls to the default, and a default that depends on
  /// where the row sits cannot be seeded into a single set up front.
  final _opened = <String>{};
  final _closed = <String>{};

  @override
  void dispose() {
    _resting?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// The pointer arriving on a row, or leaving one.
  ///
  /// Called from a [MouseRegion] callback rather than read during a build,
  /// because showing an overlay is a side effect and a build is not allowed to
  /// have one.
  ///
  /// The wait is what stops a card strobing down the list while the hand
  /// travels through it: a row you passed over did not ask a question. Short
  /// enough that a row you stopped on answers before you wonder whether it
  /// will.
  void _onHover(ResolvedAsset? asset, {Rect? at}) {
    _resting?.cancel();
    if (asset == null || at == null) {
      if (_peek.isShowing) _peek.hide();
      return;
    }
    _resting = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _peeking = asset;
        _anchor = at;
      });
      if (!_peek.isShowing) _peek.show();
    });
  }

  @override
  void didUpdateWidget(AssetListView old) {
    super.didUpdateWidget(old);
    var key = widget.selected;
    if (key == null || key == old.selected) return;
    // A selection arrives from outside this list as often as from inside it —
    // the address bar, the command palette, a link in the detail pane — and it
    // has to be visible when it does. A directory the reader closed stays
    // closed until something inside it is selected; then the selection wins,
    // because a list that cannot show the row it reports as selected is lying.
    _closed.removeWhere((path) => key == path || key.startsWith('$path/'));
  }

  /// The same matcher the command palette ranks with, so a query that finds an
  /// asset here finds it there.
  bool _matches(String key) {
    if (_search.text.trim().isEmpty) return true;
    return fuzzyMatch(_search.text.trim(), key) != null;
  }

  List<ResolvedAsset> _filter(List<ResolvedAsset> assets) => [
    for (var asset in assets)
      if (_matches(asset.key) &&
          (_kind == null || assetKindOf(asset.key) == _kind))
        asset,
  ];

  @override
  Widget build(BuildContext context) {
    var own = _filter(widget.own);
    var problems = [
      for (var problem in widget.problems)
        if (_matches(problem.declaration)) problem,
    ];

    return OverlayPortal(
      controller: _peek,
      overlayChildBuilder: (context) {
        var asset = _peeking;
        var anchor = _anchor;
        if (asset == null || anchor == null) return const SizedBox.shrink();
        return AssetPopover(asset: asset, anchor: anchor);
      },
      child: Column(
        children: [
          _filters(context),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: FwSpacing.xl),
              children: [
                if (problems.isNotEmpty) ...[
                  _SectionHeader(
                    'Problems',
                    count: problems.length,
                    tone: context.colors.amber,
                  ),
                  for (var problem in problems)
                    _ProblemRow(problem: problem, query: _search.text),
                ],
                if (!_problemsOnly) ...[
                  ..._ownSection(context, own),
                  for (var owner in widget.fromPackages)
                    ..._ownerSection(context, owner),
                  if (own.isEmpty && widget.fromPackages.isEmpty)
                    _Empty(searching: _search.text.trim().isNotEmpty),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Whether the reader is hunting a name rather than reading the bundle.
  ///
  /// The one thing that switches arrangements. A kind chip does not: it narrows
  /// the bundle and the narrowed bundle still has a shape, so the tree is built
  /// from whatever survived the filter. A typed query is different — it ranks,
  /// and a ranking hidden behind collapsed directories is worse than no
  /// ranking, so the query flattens the list back to what it was.
  bool get _searching => _search.text.trim().isEmpty == false;

  /// The package's own assets: a header carrying the weight, then rows.
  List<Widget> _ownSection(BuildContext context, List<ResolvedAsset> own) {
    if (own.isEmpty) return const [];
    var tree = _searching ? null : AssetTree.of(own);
    return [
      // The way out of a folder, and the row that is *all* of them. It is the
      // header rather than a row of its own because the header already counts
      // and weighs exactly what "all" means here — a second row saying the same
      // two numbers is a second thing to keep in agreement.
      Tappable(
        onTap: () => widget.onSelect(''),
        child: _SectionHeader(
          // The prefix every key shares, said once here instead of on every row.
          tree == null || tree.prefix.isEmpty
              ? 'In this package'
              : 'In this package · ${tree.prefix}/',
          count: own.length,
          detail: formatBytes(_bytesOf(own)),
          selected: widget.selected == null,
        ),
      ),
      if (tree != null)
        ..._treeRows(context, tree.root, depth: 0)
      else
        for (var asset in own) _assetRow(asset),
    ];
  }

  /// A dependency's assets are collapsed until asked for. They are in the
  /// bundle and they are not what you came to look at.
  List<Widget> _ownerSection(BuildContext context, AssetOwner owner) {
    var assets = _filter(owner.assets);
    if (assets.isEmpty) return const [];
    var open = _expanded.contains(owner.package);
    // No prefix on this header: it is `packages/<name>/assets` for every
    // dependency there has ever been, and the header already says the package.
    var tree = _searching || !open ? null : AssetTree.of(assets);
    return [
      // [Tappable]: `_SectionHeader` is a `Container(color: panel2)`, which
      // covered the ink an [InkWell] painted under it.
      Tappable(
        onTap: () => setState(() {
          open ? _expanded.remove(owner.package) : _expanded.add(owner.package);
        }),
        child: _SectionHeader(
          'package:${owner.package}',
          count: assets.length,
          detail: formatBytes(owner.bytes),
          leading: Icon(
            open ? Icons.expand_more : Icons.chevron_right,
            size: FwIconSize.sm,
            color: context.colors.mut,
          ),
        ),
      ),
      if (open)
        if (tree != null)
          ..._treeRows(context, tree.root, depth: 0)
        else
          for (var asset in assets) _assetRow(asset),
    ];
  }

  /// One directory's contents, deepest-last: its subdirectories, then the
  /// assets sitting directly in it.
  ///
  /// Directories first for the reason every file explorer puts them first —
  /// they are the choices, and the assets are what is left once the choosing is
  /// done.
  List<Widget> _treeRows(
    BuildContext context,
    AssetNode node, {
    required int depth,
  }) => [
    for (var child in node.sortedChildren) ...[
      _DirectoryRow(
        node: child,
        depth: depth,
        open: _isOpen(child, depth),
        selected: child.path == widget.selected,
        onTap: () => widget.onSelect(child.path),
        onToggleFold: () => _toggle(child, depth),
      ),
      if (_isOpen(child, depth)) ..._treeRows(context, child, depth: depth + 1),
    ],
    for (var asset in node.sortedAssets) _assetRow(asset, depth: depth),
  ];

  Widget _assetRow(ResolvedAsset asset, {int? depth}) => _AssetRow(
    asset: asset,
    selected: asset.key == widget.selected,
    onTap: () => widget.onSelect(asset.key),
    // **Nothing for the row already selected.** Its picture is in the pane
    // beside, full size, a few hundred pixels away — a second copy of it under
    // the pointer says nothing and covers something. Reported as *leaving*
    // rather than ignored, so arriving here from a neighbouring row closes
    // that row's card instead of stranding it.
    onHover: !widget.peek
        ? null
        : (hovered, {at}) => _onHover(
            hovered == null || hovered.key == widget.selected ? null : hovered,
            at: at,
          ),
    query: _search.text,
    // The directory is the row above in a tree, and repeating it under every
    // filename is the thing the tree was built to stop.
    depth: depth,
  );

  /// Open by default at the top level only.
  ///
  /// Deeper closed, because the whole bundle expanded is the flat list with
  /// extra rows in it. Top level open, because a panel that opens on six folder
  /// names and no assets has made every asset two clicks away to answer a
  /// question — how heavy is this directory — that the header answers anyway.
  bool _isOpen(AssetNode node, int depth) {
    if (_opened.contains(node.path)) return true;
    if (_closed.contains(node.path)) return false;
    var selected = widget.selected;
    if (selected == null) return depth == 0;
    // Arriving at a folder opens it. Not the toggle in disguise — picking the
    // same folder again does not close it — but a consequence of being there:
    // a pane showing a directory beside a tree that has it folded away is two
    // answers to one question.
    return depth == 0 ||
        selected == node.path ||
        selected.startsWith('${node.path}/');
  }

  /// Whether anything is folded away — which is also what decides which of the
  /// two directions the one button offers.
  bool get _anyClosed => _closed.isNotEmpty;

  /// Every directory in the own section's tree, which is what a fold-all has to
  /// name. Built from the same filtered list the rows are, so folding away a
  /// filtered tree does not silently also fold what the filter is hiding.
  Iterable<String> get _allDirectories =>
      AssetTree.of(_filter(widget.own)).root.descendantPaths;

  void _foldAll() => setState(() {
    _opened.clear();
    _closed.addAll(_allDirectories);
  });

  void _unfoldAll() => setState(() {
    _closed.clear();
    _opened.addAll(_allDirectories);
  });

  void _toggle(AssetNode node, int depth) => setState(() {
    if (_isOpen(node, depth)) {
      _opened.remove(node.path);
      _closed.add(node.path);
    } else {
      _closed.remove(node.path);
      _opened.add(node.path);
    }
  });

  Widget _filters(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.all(FwSpacing.md),
      child: Column(
        spacing: FwSpacing.md,
        children: [
          Row(
            spacing: FwSpacing.xs,
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  style: context.type.body,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Filter by key',
                    prefixIcon: const Icon(Icons.search, size: FwIconSize.md),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: FwIconSize.sm,
                            onPressed: () => setState(_search.clear),
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              // One button for both directions: with nothing folded away the
              // only useful thing it can do is fold, and after that, unfold.
              // Absent while a query is typed, because a filtered list is flat
              // and there is nothing there to fold.
              if (!_searching && _allDirectories.isNotEmpty)
                IconButton(
                  onPressed: _anyClosed ? _unfoldAll : _foldAll,
                  iconSize: FwIconSize.md,
                  visualDensity: VisualDensity.compact,
                  tooltip: _anyClosed ? 'Expand all' : 'Collapse all',
                  icon: Icon(
                    _anyClosed ? Icons.unfold_more : Icons.unfold_less,
                    // Set, because an `IconButton` that names no colour takes
                    // Material's pure black, which is not a token this app has.
                    color: context.colors.mut,
                  ),
                ),
              // The bundle is written by things outside this process — a
              // designer dropping a PNG in, a pubspec edit, a pub get — so
              // there has to be a way to look again without reopening the
              // panel.
              if (widget.onReload != null)
                IconButton(
                  onPressed: widget.scanning ? null : widget.onReload,
                  iconSize: FwIconSize.md,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Read the assets again',
                  icon: widget.scanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
            ],
          ),
          Row(
            spacing: FwSpacing.xs,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    spacing: FwSpacing.xs,
                    children: [
                      for (var kind in _presentKinds)
                        _Chip(
                          label: kind.plural,
                          selected: _kind == kind,
                          onTap: () => setState(
                            () => _kind = _kind == kind ? null : kind,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.problems.isNotEmpty)
                _Chip(
                  label: 'Problems',
                  tone: colors.amber,
                  selected: _problemsOnly,
                  onTap: () => setState(() => _problemsOnly = !_problemsOnly),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Only the kinds this bundle actually has. A filter offering "Media" to a
  /// project with no media is a control that can only disappoint.
  List<AssetKind> get _presentKinds {
    var present = <AssetKind>{
      for (var asset in widget.own) assetKindOf(asset.key),
    };
    return [
      for (var kind in AssetKind.values)
        if (present.contains(kind)) kind,
    ];
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.asset,
    required this.selected,
    required this.onTap,
    this.onHover,
    this.query = '',
    this.depth,
  });

  final ResolvedAsset asset;
  final bool selected;
  final VoidCallback onTap;

  /// The pointer arriving on this row — with where the row is, so a card can
  /// point at it — and leaving it.
  final void Function(ResolvedAsset?, {Rect? at})? onHover;

  /// How deep in the tree this sits, or null when there is no tree — which is
  /// also what decides whether the row carries its directory. In a tree the
  /// directory is the row above; in a filtered list there is no row above and
  /// the key is the only thing telling two `logo.png`s apart.
  final int? depth;

  /// What the filter is looking for, so the row can light the characters that
  /// answered it.
  final String query;

  List<int> get _matched => query.trim().isEmpty
      ? const []
      : fuzzyMatch(query.trim(), asset.key)?.matched ?? const [];

  /// Where the directory ends in the key, which is also where the filename's
  /// indexes start.
  int get _nameOffset => asset.key.length - p.basename(asset.key).length;

  List<int> get _matchedInName => [
    for (var index in _matched)
      if (index >= _nameOffset) index - _nameOffset,
  ];

  List<int> get _matchedInDirectory => [
    for (var index in _matched)
      if (index < p.dirname(asset.key).length) index,
  ];

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var variants = asset.variants.length;
    var row = FwTreeRow(
      depth: depth ?? 0,
      selected: selected,
      onTap: onTap,
      leading: Icon(
        assetKindIcon(assetKindOf(asset.key)),
        size: 15,
        color: colors.mut,
      ),
      label: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Split rather than ellipsised whole: the filename is what tells two
          // assets apart and the directory is what they share, so truncating
          // the key end-first hides the only part that identifies it. The full
          // key is in the detail pane.
          //
          // The match is computed against the whole key and then split the same
          // way, so a query spanning the slash lights on both halves rather
          // than on whichever one it happened to land in.
          MatchedText(
            p.basename(asset.key),
            matched: _matchedInName,
            style: context.type.body,
          ),
          // `p.dirname` answers `.` for a key at the root of the package, and a
          // lone dot under a filename reads as a bug.
          if (depth == null && p.dirname(asset.key) != '.')
            MatchedText(
              p.dirname(asset.key),
              matched: _matchedInDirectory,
              style: context.type.micro,
            ),
        ],
      ),
      trailing: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatBytes(asset.totalBytes), style: context.type.micro),
            if (variants > 0)
              Text(
                '$variants variant${variants == 1 ? '' : 's'}',
                style: context.type.micro,
              ),
          ],
        ),
      ],
    );
    if (onHover case var onHover?) {
      return MouseRegion(
        // Its own box, read here rather than tracked: this fires once when the
        // pointer arrives, and a row that reported its rectangle on every
        // build would be doing it for a list nobody is pointing at.
        onEnter: (_) => onHover(asset, at: globalBoxOf(context)),
        onExit: (_) => onHover(null),
        child: row,
      );
    }
    return row;
  }
}

class _ProblemRow extends StatelessWidget {
  const _ProblemRow({required this.problem, this.query = ''});

  final AssetProblem problem;
  final String query;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        spacing: FwSpacing.md,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: FwIconSize.md,
            color: colors.amber,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MatchedText(
                  problem.declaration,
                  matched: query.trim().isEmpty
                      ? const []
                      : fuzzyMatch(
                              query.trim(),
                              problem.declaration,
                            )?.matched ??
                            const [],
                  style: context.type.body,
                ),
                Text(
                  problem.package == null
                      ? problem.kind.summary
                      : '${problem.kind.summary} (${problem.package})',
                  style: context.type.micro,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(
    this.title, {
    required this.count,
    this.detail,
    this.tone,
    this.leading,
    this.selected = false,
  });

  final String title;
  final int count;
  final String? detail;
  final Color? tone;
  final Widget? leading;

  /// Whether the pane beside the list is showing what this header names.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      color: selected ? colors.accentSoft : colors.panel2,
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xs,
      ),
      child: Row(
        spacing: FwSpacing.xs,
        children: [
          ?leading,
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.sectionLabel.copyWith(color: tone),
            ),
          ),
          if (detail != null) Text(detail!, style: context.type.micro),
          Text('$count', style: context.type.micro),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tone,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var accent = tone ?? colors.accent;
    // [Tappable] for the reason the dependencies filter chip gives: the fill
    // is opaque `panel` when the chip is off, and Material ink paints below
    // its child, so the hover was covered by the chip itself.
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusLarge),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(context.radii.radiusLarge),
          color: selected ? accent.withValues(alpha: 0.15) : colors.panel,
          border: Border.all(color: selected ? accent : colors.line),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: FwSpacing.xxs,
        ),
        child: Text(
          label,
          style: context.type.caption.copyWith(
            color: selected ? accent : colors.mut,
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Center(
        child: Text(
          searching
              ? 'No asset matches that.'
              : 'This package declares no assets.\n'
                    'Add them under `flutter: assets:` in its pubspec.',
          textAlign: TextAlign.center,
          style: context.type.bodyMuted,
        ),
      ),
    );
  }
}

/// One directory of the tree: the choice, and what taking it costs.
class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({
    required this.node,
    required this.depth,
    required this.open,
    required this.selected,
    required this.onTap,
    required this.onToggleFold,
  });

  final AssetNode node;
  final int depth;
  final bool open;

  /// Whether this folder is what the pane beside the list is showing.
  final bool selected;

  final VoidCallback onTap;
  final VoidCallback onToggleFold;

  @override
  Widget build(BuildContext context) {
    return FwTreeRow(
      depth: depth,
      open: open,
      selected: selected,
      onTap: onTap,
      onToggleFold: onToggleFold,
      label: Text(
        node.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.type.body,
      ),
      trailing: [
        // Bytes then count, in that order, because the section header above
        // reads that way and these are the same two columns one level in.
        Text(formatBytes(node.totalBytes), style: context.type.micro),
        Text('${node.totalCount}', style: context.type.micro),
      ],
    );
  }
}

int _bytesOf(List<ResolvedAsset> assets) =>
    assets.fold(0, (sum, asset) => sum + asset.totalBytes);
