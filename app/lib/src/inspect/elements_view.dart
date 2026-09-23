import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/previews_guest.dart';
// `InspectFilter` is not on the guest's public surface — the same import
// `screen_read.dart` makes, so both trees are trimmed by one rule.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart' show InspectFilter;

import '../address/address_scope.dart';
import 'inspect_dock.dart';
import '../ui/popover.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';

/// Tree on the left, the selected node's detail on the right — the Elements
/// tab of an [InspectDock], shared verbatim between Previews' live
/// tree and a scenario step's snapshot. It renders an [InspectNode] and
/// neither knows nor cares which of the two produced it.
///
/// Selection is the `node` address parameter, read and written here: the
/// catalog and the step page use the same name, so a link with a node in it
/// means the same thing on both pages.
class ElementsView extends StatefulWidget {
  const ElementsView({
    super.key,
    required this.root,
    required this.placeholder,
    required this.highlight,
    required this.displayRoot,
    required this.readsWidgets,
  });

  /// The tree, or null while the host has nothing — the [placeholder] says
  /// why.
  final InspectNode? root;

  /// What an empty view says: "Reading the tree…", "No entry selected" — the
  /// host knows, this widget only shows it.
  final String placeholder;

  /// Set as the pointer runs down the rows, so the surface above draws the
  /// box for whatever is under it; read as well, so the row lights up when
  /// the *picker* is what put it there.
  final ValueNotifier<String?> highlight;

  /// What a source path is shortened against.
  final String displayRoot;

  /// Whether whatever produced this tree can see the widgets themselves —
  /// their boxes and their own diagnostics — or only the structure.
  ///
  /// False for the run cockpit, whose trees come over the VM service: reaching
  /// a `RenderObject` or a `Widget` needs to be *inside* the app, so
  /// [InspectNode.layout] and [InspectNode.properties] arrive empty there for
  /// every node (`app/lib/src/run/inspect.dart`). Without this the pane read
  /// that emptiness as an answer and told the reader that `Scaffold` lays
  /// nothing out — a statement about the widget, made from a fact about the
  /// reader.
  final bool readsWidgets;

  @override
  State<ElementsView> createState() => _ElementsViewState();
}

class _ElementsViewState extends State<ElementsView> {
  /// The tree's share of the width. The detail pane is the narrower of the
  /// two because a tree row is wide by nature — type, description, box and
  /// source all read on one line — while a detail is a short column of pairs.
  double _split = 0.62;

  /// Whether to show the wrappers too.
  ///
  /// Off, so this pane says what the drive verbs say. An agent's `tree` has
  /// dropped the scaffolding since the noise filter landed, and this pane had
  /// not learned to: it opened on fifteen levels of `AppDevbar → Devbar →
  /// FutureBuilder → Builder → FeatureFlags → …` before the first widget anyone
  /// wrote, so the two surfaces disagreed about the shape of the same app. The
  /// wrappers are still one click away, because a question about a `MouseRegion`
  /// is a real question — just not the one this pane opens on.
  var _showAll = false;

  @override
  Widget build(BuildContext context) {
    var root = widget.root;
    if (root == null) {
      return Container(
        color: context.colors.panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          widget.placeholder,
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: context.colors.mut),
        ),
      );
    }

    var full = InspectTree(entryId: null, root: root);
    // The same call `screen_read.dart` makes for the agent's tree, so the two
    // drop exactly the same nodes.
    var trimmed = full.filtered(const InspectFilter());
    var shown = (_showAll ? full : trimmed).root ?? root;
    var hidden = full.length - trimmed.length;

    var selectedId = AddressScope.params(context)['node'];
    // Resolved against the **full** tree, never the shown one. Ids are
    // positions in the tree as it was read, so they survive the filter — but a
    // wrapper the filter dropped still has one, and a selection made with the
    // wrappers showing must not lose its detail pane when they are hidden
    // again.
    var selected = selectedId == null ? null : full.nodeAt(selectedId);

    // Its own (invisible) Material: the tree rows are `InkWell`s, and this was
    // inheriting one from [InspectDock] purely because both hosts happened to
    // put it there. The run cockpit uses it outside a dock, which is where a
    // borrowed ancestor stops arriving.
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          var treeWidth = (constraints.maxWidth * _split)
              .clamp(200.0, math.max(200.0, constraints.maxWidth - 220))
              .toDouble();
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: treeWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hidden > 0)
                      _WrapperToggle(
                        hidden: hidden,
                        showAll: _showAll,
                        onToggle: () => setState(() => _showAll = !_showAll),
                      ),
                    Expanded(
                      child: _TreeView(
                        root: shown,
                        selectedId: selectedId,
                        highlight: widget.highlight,
                      ),
                    ),
                  ],
                ),
              ),
              InspectSplitGrip(
                axis: Axis.vertical,
                onDrag: (delta) => setState(() {
                  _split = ((treeWidth + delta) / constraints.maxWidth).clamp(
                    0.2,
                    0.85,
                  );
                }),
              ),
              Expanded(
                child: _Detail(
                  node: selected,
                  selectedId: selectedId,
                  displayRoot: widget.displayRoot,
                  readsWidgets: widget.readsWidgets,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The one line that says the tree is not the whole tree.
///
/// It exists because a filtered tree with nothing saying so is a tree that
/// lies. The count is the honest part — *what* was dropped is a rule
/// (`InspectFilter`'s scaffolding pass), but *how much* is this app, this
/// frame, and the difference between "a couple of wrappers" and "forty" is
/// worth seeing before deciding whether to look.
class _WrapperToggle extends StatelessWidget {
  const _WrapperToggle({
    required this.hidden,
    required this.showAll,
    required this.onToggle,
  });

  final int hidden;
  final bool showAll;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Container(
    color: context.colors.panel,
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.md,
      FwSpacing.xs,
      FwSpacing.xs,
      FwSpacing.xs,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            showAll ? '$hidden wrappers shown' : '$hidden wrappers hidden',
            style: context.type.micro.copyWith(color: context.colors.mut),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Tappable(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.sm,
              vertical: FwSpacing.xxs,
            ),
            child: Text(
              showAll ? 'Hide' : 'Show all',
              style: context.type.micro.copyWith(color: context.colors.accent),
            ),
          ),
        ),
      ],
    ),
  );
}

class _TreeView extends StatefulWidget {
  const _TreeView({
    required this.root,
    required this.selectedId,
    required this.highlight,
  });

  final InspectNode root;
  final String? selectedId;

  /// Set as the pointer runs down the rows, so the preview draws the box for
  /// whatever is under it. Cleared when the pointer leaves the list — a
  /// highlight that outlived the hover would be pointing at nothing.
  final ValueNotifier<String?> highlight;

  @override
  State<_TreeView> createState() => _TreeViewState();
}

class _TreeViewState extends State<_TreeView> {
  static const _rowHeight = 22.0;

  /// The rows whose fold the user flipped away from its default.
  ///
  /// A set of exceptions rather than of closed ids, because the default is no
  /// longer uniform: an ordinary row starts open, and the top of an offstage
  /// subtree starts **closed** — a covered route's ninety widgets are a
  /// distraction wearing rects from a screen that is not the picture.
  final _toggled = <String>{};

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_TreeView old) {
    super.didUpdateWidget(old);
    var id = widget.selectedId;
    if (id != null && id != old.selectedId) _reveal(id);
  }

  /// Whether [node]'s children are shown. The default is open, except at the
  /// top of an offstage subtree — [parentOffstage] is what says "top", so
  /// expanding one does not reveal a pile of still-folded descendants.
  bool _open(InspectNode node, {required bool parentOffstage}) {
    var byDefault = !node.offstage || parentOffstage;
    return _toggled.contains(node.id) ? !byDefault : byDefault;
  }

  /// Unfolds whatever was hiding [id] and scrolls it into view.
  ///
  /// The picker can land three levels inside a folded subtree and below the
  /// scroll, and selecting a row somewhere the asker cannot see is answering
  /// the question into the void. Chrome brings the tree to the element; so
  /// does this.
  void _reveal(String id) {
    var parts = id.isEmpty ? const <String>[] : id.split('/');
    var opened = false;
    // Every ancestor, root first, walked by child index so each one's
    // *default* is known — an address can name a node inside an offstage
    // subtree, and revealing it means overriding that fold too.
    var node = widget.root;
    var parentOffstage = false;
    for (var i = 0; i <= parts.length - 1; i++) {
      if (i > 0) {
        var index = int.tryParse(parts[i - 1]);
        if (index == null || index >= node.children.length) break;
        parentOffstage = node.offstage;
        node = node.children[index];
      }
      if (!_open(node, parentOffstage: parentOffstage)) {
        if (!_toggled.remove(node.id)) _toggled.add(node.id);
        opened = true;
      }
    }
    if (opened) setState(() {});

    // After the frame, so the rows reflect whatever was just unfolded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      var index = _rows().indexWhere((row) => row.$1.id == id);
      if (index < 0) return;
      var offset = index * _rowHeight;
      var top = _scroll.offset;
      var bottom = top + _scroll.position.viewportDimension - _rowHeight;
      // Only when it is actually out of sight: scrolling a row that was
      // already visible moves the tree under the reader for no reason.
      if (offset < top || offset > bottom) {
        _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  /// The visible rows, flattened, with the depth each should be drawn at and
  /// whether its parent was already offstage — which is what tells the top of
  /// a hidden subtree (folded, marked) from its inside (just dim).
  List<(InspectNode, int, bool)> _rows() {
    var rows = <(InspectNode, int, bool)>[];
    void walk(InspectNode node, int depth, bool parentOffstage) {
      rows.add((node, depth, parentOffstage));
      if (!_open(node, parentOffstage: parentOffstage)) return;
      for (var child in node.children) {
        walk(child, depth + 1, node.offstage);
      }
    }

    walk(widget.root, 0, false);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    var rows = _rows();

    return Container(
      color: context.colors.panel,
      child: LayoutBuilder(
        builder: (context, constraints) => MouseRegion(
          onExit: (_) => widget.highlight.value = null,
          child: ListView.builder(
            primary: false,
            controller: _scroll,
            itemCount: rows.length,
            itemExtent: _rowHeight,
            itemBuilder: (context, index) {
              var (node, depth, parentOffstage) = rows[index];
              return _TreeRow(
                node: node,
                depth: depth,
                // Measured once for the list rather than per row: it is the
                // panel's width, and the panel does not change width between
                // two rows of the same frame.
                indent: math.min(depth * 12.0, constraints.maxWidth * 0.4),
                // Below this there is no room for it and the type, and the
                // type is what you scan by.
                showSize: constraints.maxWidth > 320,
                highlight: widget.highlight,
                open: _open(node, parentOffstage: parentOffstage),
                // Marked at the top of the hidden subtree; inside it, the
                // dimming already says so once per row.
                markOffstage: node.offstage && !parentOffstage,
                selected: node.id == widget.selectedId,
                onHover: (over) {
                  if (over) {
                    widget.highlight.value = node.id;
                  } else if (widget.highlight.value == node.id) {
                    // Only if it is still ours: the pointer has already
                    // entered the next row by the time this fires, and
                    // clearing then would put out the light that row just
                    // turned on.
                    widget.highlight.value = null;
                  }
                },
                onToggle: () => setState(() {
                  if (!_toggled.remove(node.id)) _toggled.add(node.id);
                }),
                onTap: () =>
                    AddressScope.write(context).setParam('node', node.id),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.node,
    required this.depth,
    required this.indent,
    required this.showSize,
    required this.open,
    required this.markOffstage,
    required this.selected,
    required this.onToggle,
    required this.onTap,
    required this.onHover,
    required this.highlight,
  });

  final InspectNode node;
  final int depth;

  /// Whether to say "offstage" on this row — true at the top of a hidden
  /// subtree, where the fold starts closed and a bare dim row would read as
  /// merely framework plumbing.
  final bool markOffstage;

  /// How far the row is pushed in, **capped**: twelve levels at twelve pixels
  /// each is most of a narrow panel, and an indent that eats the whole row is
  /// what put Flutter's overflow stripes across an inspector.
  final double indent;

  /// Whether there is room for the box on the right.
  final bool showSize;
  final bool open;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  /// Read as well as written, so the row lights up for whatever the rectangle
  /// is currently on — including when the *picker* is what put it there.
  /// Sweep the demo and the tree follows you, which is the same courtesy in
  /// reverse.
  final ValueNotifier<String?> highlight;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return InkWell(
      onTap: onTap,
      onHover: onHover,
      child: ValueListenableBuilder(
        valueListenable: highlight,
        builder: (context, lit, child) => Container(
          // Selection outranks hover: one is where you are, the other is
          // where you were going.
          color: selected
              ? colors.accentSoft
              : lit == node.id
              ? colors.panel2
              : null,
          child: child,
        ),
        child: Container(
          padding: EdgeInsets.only(left: FwSpacing.sm + indent),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: node.children.isEmpty
                    ? null
                    : InkWell(
                        onTap: onToggle,
                        child: Icon(
                          open ? Icons.arrow_drop_down : Icons.arrow_right,
                          size: FwIconSize.sm,
                          color: colors.mut,
                        ),
                      ),
              ),
              // **One flexible child, not two beside a `Spacer`.** Three flex
              // children divide the free space between them, so the spacer
              // was taking a third of every row — which both truncated the
              // description early, against an obviously empty right margin,
              // and left the size wherever the description happened to stop.
              // The text takes everything that is going; the size is a
              // column.
              Expanded(
                child: Row(
                  children: [
                    // The type keeps what it needs and the description gives
                    // way: a deep node indents its row a long way, and the
                    // type is what you scan by.
                    Flexible(
                      child: Text(
                        node.type,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: context.type.caption.copyWith(
                          // The demo's own widgets bright, the plumbing
                          // between them dim: a summary tree is mostly the
                          // former, and the few that are not are what you
                          // scroll past. Offstage content is dim whoever
                          // wrote it — it is not on the picture.
                          color: node.createdByLocalProject && !node.offstage
                              ? colors.ink
                              : colors.mut,
                        ),
                      ),
                    ),
                    // The key when that is all there was: a `Form` keyed
                    // `[<'draft'>]` says which form it is, and the key is no
                    // longer inside the description to say it.
                    if (node.description ?? node.widgetKey case var detail?
                        when detail != node.type) ...[
                      const SizedBox(width: FwSpacing.sm),
                      Flexible(
                        child: Text(
                          detail,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: context.type.caption.copyWith(
                            color: colors.mut2,
                          ),
                        ),
                      ),
                    ],
                    if (markOffstage) ...[
                      const SizedBox(width: FwSpacing.sm),
                      Text(
                        'offstage',
                        style: context.type.micro.copyWith(color: colors.mut3),
                      ),
                    ],
                  ],
                ),
              ),
              if (showSize)
                // A fixed width and right-aligned, so the numbers form a
                // column rather than each landing where its row's text ran
                // out. Present even when the node has no box, or the rows
                // either side of one would close the gap and the column would
                // wander again.
                SizedBox(
                  width: 84,
                  child: Padding(
                    padding: const EdgeInsets.only(right: FwSpacing.md),
                    child: Text(
                      switch (node.layout) {
                        var l? => '${_n(l.width)}×${_n(l.height)}',
                        null => '',
                      },
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: context.type.micro.copyWith(color: colors.mut3),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What is known about one node.
class _Detail extends StatelessWidget {
  const _Detail({
    required this.node,
    required this.selectedId,
    required this.displayRoot,
    required this.readsWidgets,
  });

  final InspectNode? node;

  /// What a source path is shortened against.
  final String displayRoot;

  /// See [ElementsView.readsWidgets] — what separates "it has no box" from
  /// "nobody looked".
  final bool readsWidgets;

  /// Told apart from [node] being null: an id that resolves to nothing is a
  /// selection that outlived the tree it named, which is worth saying rather
  /// than showing as "nothing selected".
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (node == null) {
      return Container(
        color: context.colors.panel2,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          selectedId == null
              ? 'Select a widget'
              : 'The tree no longer has $selectedId.\nIt named a position, and '
                    'the shape changed.',
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: colors.mut),
        ),
      );
    }

    var it = node!;
    var layout = it.layout;
    return Container(
      color: colors.panel2,
      child: ListView(
        primary: false,
        padding: const EdgeInsets.all(FwSpacing.lg),
        children: [
          SelectableText(
            it.type,
            style: context.type.bodyStrong.copyWith(color: colors.ink),
          ),
          if (it.description ?? it.widgetKey case var detail?
              when detail != it.type)
            SelectableText(
              detail,
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          const SizedBox(height: FwSpacing.md),
          // **No id row.** It is the `node` address parameter, so the address
          // bar at the foot of the window is already showing it — selectable
          // and copyable there, and part of a link that reopens this exact
          // selection. Printing it here too said the same synthetic string
          // twice on one screen. An agent asking `tree --node` reads it out of
          // the JSON rather than off a pixel pane, so nothing lost it.
          if (it.offstage)
            // Why the rect below must not be trusted against the picture: it
            // is where this was, the last time it was on one.
            _Pair(
              label: 'shown',
              value: 'offstage — in the tree, not on the screen',
            ),
          if (it.source case var source?)
            _Pair(
              label: 'source',
              // Shortened against the worktree, so this is the same string
              // `fw run previews inspect --tree` prints for the same node —
              // one can be pasted where the other was expected.
              value: source.describe(relativeTo: displayRoot),
            ),
          if (layout != null) ...[
            const SizedBox(height: FwSpacing.md),
            _Pair(
              label: 'size',
              value: '${_n(layout.width)} × ${_n(layout.height)}',
            ),
            _Pair(label: 'offset', value: '${_n(layout.x)}, ${_n(layout.y)}'),
            if (layout.constraints case var constraints?)
              _Pair(label: 'given', value: constraints.describe()),
            if (layout.flex case var flex?)
              _Pair(
                label: 'flex',
                value: [
                  flex.direction,
                  ?flex.mainAxisAlignment,
                  ?flex.crossAxisAlignment,
                  ?flex.mainAxisSize,
                ].join(', '),
              ),
            if (layout.flexFactor case var factor?)
              _Pair(
                label: 'in parent',
                value: layout.flexFit == null
                    ? 'flex $factor'
                    : 'flex $factor (${layout.flexFit})',
              ),
            if (layout.isRepaintBoundary)
              _Pair(label: 'paints', value: 'repaint boundary'),
          ] else if (readsWidgets) ...[
            const SizedBox(height: FwSpacing.md),
            Text(
              // Not zero-filled, because "it has no box" and "its box is
              // empty" are different answers and only one of them is a bug.
              'Lays nothing out of its own — a provider or a builder.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          ] else ...[
            const SizedBox(height: FwSpacing.md),
            Text(
              // **Whose silence it is.** A reader that cannot see widgets has
              // no box for *any* node, so the sentence above would have said
              // `Scaffold` lays nothing out — and it did. Saying who is not
              // looking beats both lying and leaving a pane that stops after
              // the source line, where the gap reads as a broken tool.
              'Structure and source only — a tree read from outside the app '
              'carries no box and no properties.',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          ],
          // The style the glyphs were painted with, which is a different
          // question from the one below and was for a long time being answered
          // by it. See [InspectNode.textStyle].
          if (it.textStyle.isNotEmpty) ...[
            const SizedBox(height: FwSpacing.md),
            // Header included: whether the block wants one rule or two is the
            // grouping's business, not the caller's.
            ..._styleRows(it),
          ],
          // What the widget says about itself — its diagnostics, already
          // filtered at capture. Empty for a tree read from outside the app,
          // where the line above has already accounted for it; for every other
          // reader an empty map means the widget said nothing, which is not
          // worth a line of its own.
          if (_widgetRows(it) case var rows when rows.isNotEmpty) ...[
            const SizedBox(height: FwSpacing.md),
            if (it.textStyle.isNotEmpty) const _Section('widget'),
            for (var MapEntry(key: name, value: value) in rows.entries)
              _Pair(label: name, value: value),
          ],
        ],
      ),
    );
  }
}

/// The style block: what this widget set, then what it inherited, in that
/// order and divided by a rule that says which is which.
///
/// Grouping replaced a per-row badge, and the badge had two problems. It
/// said `set here` four times down a 170px column on an ordinary label — a
/// checklist rendered as decoration — and, worse, it distinguished nothing in
/// the case a reader most needs it: a widget written
/// `style: theme.textTheme.titleLarge` reports the *whole* style as its own,
/// so every row wore the badge. One divider says the same thing once, and its
/// absence is itself the answer — a block with no rule under it is a widget
/// that set everything.
///
/// A field the widget set to something the renderer then overruled is spelled
/// `300 → 700` rather than given a note. That case is rare (the OS bold-text
/// setting is the one that turns up) and it is the most valuable row in the
/// pane when it happens, so it reads as an arrow rather than as a footnote.
List<Widget> _styleRows(InspectNode node) {
  var resolved = {...node.textStyle}..remove('debugLabel');
  var set = <String>[];
  var inherited = <String>[];
  for (var name in resolved.keys) {
    (node.properties.containsKey(name) ? set : inherited).add(name);
  }
  for (var group in [set, inherited]) {
    group.sort((a, b) => _styleRank(a).compareTo(_styleRank(b)));
  }

  Widget row(String name) {
    var rendered = resolved[name]!;
    var asked = node.properties[name];
    return _Pair(
      label: name,
      value: asked == null || asked == rendered
          ? rendered
          : '$asked → $rendered',
    );
  }

  return [
    // **One rule, never two stacked.** A `Text` that sets no style of its own
    // puts every field in the inherited group, and the divider then landed
    // directly under the block header — two micro labels with rules, four
    // pixels apart, reading as a doubled heading rather than as "everything
    // below here came from the theme". Where there is nothing to divide, the
    // header says it instead.
    _Section(set.isEmpty ? 'style · all inherited' : 'style'),
    for (var name in set) row(name),
    if (set.isNotEmpty && inherited.isNotEmpty)
      const _Section('inherited', inset: true),
    for (var name in inherited) row(name),
    _OriginRow(node: node),
  ];
}

/// The order a person says a style out loud.
///
/// `TextStyle.debugFillProperties` declares them colour-first and puts `family`
/// above `size`, which is a serialisation order rather than a reading one.
/// Nobody describes a label as "dark, Roboto, 13"; they say "13 regular, dark".
const _styleOrder = [
  'size',
  'weight',
  'color',
  'family',
  'letterSpacing',
  'height',
];

int _styleRank(String name) {
  var at = _styleOrder.indexOf(name);
  return at < 0 ? _styleOrder.length : at;
}

/// The name of the style this one was built on — `bodyMedium` — out of the
/// framework's provenance label.
///
/// The raw label is the whole merge chain and it is 88 characters of nested
/// parentheses: `((englishLike bodyMedium 2021).merge((blackRedwoodCity
/// bodyMedium).apply)).merge(unknown)`. Printed in a 170px column it was a
/// paragraph nobody read. The base of that chain is its innermost group, and
/// the name of the base is the last word in it — which is the part everybody
/// was reading it *for*.
///
/// It recognises a shape; it knows no vocabulary. No list of Material slot
/// names, so an app that labels its own styles is read the same way. The
/// tokens that are not names — the `2021` of a type-ramp year — are dropped,
/// and `unknown`, which is what the framework writes for a `TextStyle` literal
/// nobody labelled, is not a name either.
///
/// The whole chain is deliberately not shown anywhere yet. The place for it is
/// the three-way merge popover of `2026-08-18-style-detail-ux.md` § D, on this
/// same row; putting a tooltip here in the meantime would be the second
/// interaction on the target that popover wants, which is the trap
/// `HoverCard`'s own doc records.
String _originOf(String? label) {
  if (label != null && label.isNotEmpty) {
    // The first group with nothing nested in it is the base of the chain;
    // everything outside it was applied to it.
    var inner = _innermost.firstMatch(label)?.group(1) ?? label;
    var names = [
      for (var word in inner.split(RegExp(r'\s+')))
        if (_name.hasMatch(word) && word != 'unknown') word,
    ];
    if (names.isNotEmpty) return names.last;
  }
  // An absence of authorship, not a failure of the read — saying nothing here
  // would read as a gap in the tool.
  return 'nothing labelled it — written inline, not a theme slot';
}

final _innermost = RegExp(r'\(([^()]*)\)');
final _name = RegExp(r'^[a-zA-Z][a-zA-Z0-9]*$');

/// The widget's own properties, minus the ones the style block already showed.
///
/// Subtraction, because the two blocks were saying the same thing twice.
/// Measured on a label written the way this app writes them —
/// `style: TextStyle(fontSize: 13, fontWeight: w400, color: …, letterSpacing:
/// 0)` — four of fourteen rows were a key and a value repeated verbatim:
/// `color`, `size`, `weight`, `letterSpacing`. Ten distinct facts presented as
/// fourteen rows.
///
/// Nothing is lost by dropping them. A key here that the style block also
/// carries *is* that style field, and where the two values disagree the style
/// row already spells the disagreement as `300 → 700`. What survives is the
/// widget's actual configuration — `data`, `maxLines`, `overflow` — which is a
/// different question and now has a block to itself.
Map<String, String> _widgetRows(InspectNode node) => {
  for (var entry in node.properties.entries)
    if (!node.textStyle.containsKey(entry.key)) entry.key: entry.value,
};

/// The `from` row, and the way in to the whole merge.
///
/// The row itself is the slot name — `bodyMedium` — because that is the part
/// of an 88-character provenance label anybody was reading. The rest of the
/// label, and the two columns the pane has no width for, live one click away.
///
/// Click, not hover. `HoverCard` exists for things a pointer brushes past
/// on its way somewhere else; this is a read you go looking for, and its own
/// doc records what happens when one target carries two interactions.
class _OriginRow extends StatelessWidget {
  const _OriginRow({required this.node});

  final InspectNode node;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var origin = _originOf(node.textStyle['debugLabel']);
    // Nothing to decompose: no ambient style was captured (an older reading,
    // or a reader that never had one), so the popover would be one column of
    // what the pane already shows.
    if (node.inheritedStyle.isEmpty) {
      return _Pair(label: 'from', value: origin);
    }
    return Popover(
      autofocus: false,
      // Upward. This is the last row of the style block, which puts it at the
      // bottom of a pane that is itself at the bottom of a dock — opening
      // downward the card landed on the address bar. The primitive clamps
      // on-screen either way, so a pane tall enough to put this row near its
      // top still gets a card that fits.
      side: PopoverSide.top,
      content: (context, controller) => _MergeCard(node: node, origin: origin),
      anchor: (context, controller) => Tappable.builder(
        onTap: controller.toggle,
        builder: (context, hovered) => Padding(
          padding: const EdgeInsets.only(bottom: FwSpacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  'from',
                  style: context.type.micro.copyWith(color: colors.mut3),
                ),
              ),
              Flexible(
                child: Text(
                  origin,
                  style: context.type.caption.copyWith(
                    color: hovered || controller.isOpen
                        ? colors.accent
                        : colors.ink2,
                  ),
                ),
              ),
              const SizedBox(width: FwSpacing.xs),
              Icon(
                Icons.info_outline,
                size: FwIconSize.sm,
                color: hovered || controller.isOpen
                    ? colors.accent
                    : colors.mut3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three-way merge: what was in scope, what this widget said, what won.
///
/// The middle column is the reason this exists. The pane can already show
/// the first and the last — grouped either side of the `inherited` rule — but
/// not both for the *same* field, and that overlap is where the interesting
/// answers are: the theme offered 14 and this widget asked for 13, or the
/// theme offered 400 and this widget asked for 400, which is a line of source
/// doing nothing.
class _MergeCard extends StatelessWidget {
  const _MergeCard({required this.node, required this.origin});

  final InspectNode node;
  final String origin;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var resolved = {...node.textStyle}..remove('debugLabel');
    var ambient = {...node.inheritedStyle}..remove('debugLabel');
    var replaced = node.styleReplacesInherited ?? false;

    // Every field any of the three has an opinion about, in reading order.
    var names =
        <String>{...resolved.keys, ...ambient.keys, ...node.properties.keys}
            .where(
              (name) => resolved.containsKey(name) || ambient.containsKey(name),
            )
            .toList()
          ..sort((a, b) => _styleRank(a).compareTo(_styleRank(b)));

    return Container(
      // Four columns of values that cannot wrap: a font family has no space
      // in it to break at, so a narrow card does not ellipsize it, it spills
      // it into the next column. Width first, ellipsis as the backstop.
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: colors.line),
        boxShadow: [
          BoxShadow(
            color: const Color(0x22000000),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            node.textStyle['debugLabel'] ?? origin,
            style: context.type.micro.copyWith(color: colors.mut2),
          ),
          const SizedBox(height: FwSpacing.sm),
          _MergeHead(replaced: replaced, origin: origin),
          const SizedBox(height: FwSpacing.xs),
          for (var name in names)
            _MergeRow(
              name: name,
              // Struck through rather than dropped when the ambient style was
              // replaced: it *was* in scope here, and "the theme had a
              // bodyMedium and this widget threw it away" is the answer to why
              // a DefaultTextStyle appears to do nothing.
              ambient: ambient[name],
              ambientApplied: !replaced,
              asked: node.properties[name],
              renders: resolved[name],
            ),
        ],
      ),
    );
  }
}

class _MergeHead extends StatelessWidget {
  const _MergeHead({required this.replaced, required this.origin});

  final bool replaced;
  final String origin;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Widget head(String text, int flex) => Expanded(
      flex: flex,
      child: Text(text, style: context.type.micro.copyWith(color: colors.mut3)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (replaced)
          Padding(
            padding: const EdgeInsets.only(bottom: FwSpacing.xs),
            child: Text(
              'this widget’s style is inherit: false — it replaced what '
              'was in scope rather than merging into it',
              style: context.type.micro.copyWith(color: colors.mut),
            ),
          ),
        Row(
          children: [
            head('field', 3),
            head(replaced ? 'was in scope' : 'inherited', 4),
            head('this widget', 4),
            head('renders as', 4),
          ],
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.only(top: FwSpacing.xxs),
          color: colors.line,
        ),
      ],
    );
  }
}

class _MergeRow extends StatelessWidget {
  const _MergeRow({
    required this.name,
    required this.ambient,
    required this.ambientApplied,
    required this.asked,
    required this.renders,
  });

  final String name;
  final String? ambient;
  final bool ambientApplied;
  final String? asked;
  final String? renders;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // An override that changed nothing: the widget asked for the value the
    // ambient style was already going to give it. Worth saying out loud —
    // it is a line of source that could go.
    var redundant = ambientApplied && asked != null && asked == ambient;

    Widget cell(String? value, {required Color color, bool struck = false}) =>
        Expanded(
          flex: 4,
          child: Text(
            value ?? '—',
            overflow: TextOverflow.ellipsis,
            style: context.type.caption.copyWith(
              color: value == null ? colors.mut3 : color,
              decoration: struck ? TextDecoration.lineThrough : null,
              decorationColor: colors.mut3,
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              name,
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          ),
          cell(
            ambient,
            color: colors.mut2,
            // It was in scope and did not apply — see [_MergeCard].
            struck: !ambientApplied && ambient != null,
          ),
          Expanded(
            flex: 4,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    asked ?? '—',
                    overflow: TextOverflow.ellipsis,
                    style: context.type.caption.copyWith(
                      color: asked == null ? colors.mut3 : colors.ink2,
                    ),
                  ),
                ),
                if (redundant) ...[
                  const SizedBox(width: FwSpacing.xxs),
                  Text(
                    'same',
                    style: context.type.micro.copyWith(color: colors.mut3),
                  ),
                ],
              ],
            ),
          ),
          cell(renders, color: colors.ink),
        ],
      ),
    );
  }
}

/// A rule with a word on it, dividing the pane into the questions it answers.
///
/// Only drawn where two blocks would otherwise run together: a text node's
/// resolved style is ten rows, and against the widget's own properties below
/// it the two read as one list of twenty in which `size` appears twice meaning
/// two different things.
class _Section extends StatelessWidget {
  const _Section(this.label, {this.inset = false});

  final String label;

  /// Whether this divides *within* a block rather than between two.
  ///
  /// Pushed in to where the values start, so `inherited` sits visibly inside
  /// the style block. Flush left it was pixel-identical to the `style` and
  /// `widget` headers and read as a third block — which would have made the
  /// inherited rows look like something other than style.
  final bool inset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: inset ? 80 : 0,
      top: inset ? FwSpacing.xs : 0,
      bottom: FwSpacing.xs,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: context.type.micro.copyWith(color: context.colors.mut3),
        ),
        const SizedBox(width: FwSpacing.sm),
        Expanded(child: Container(height: 1, color: context.colors.panel)),
      ],
    ),
  );
}

class _Pair extends StatelessWidget {
  const _Pair({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // Wide enough for `letterSpacing`, which is what the resolved
            // style brought in: at 64 it wrapped to `letterSpaci` / `ng` and
            // took two rows to say one thing. The layout labels above it are
            // all short, so the extra sixteen pixels cost them nothing.
            width: 80,
            child: Text(
              label,
              style: context.type.micro.copyWith(color: context.colors.mut3),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: context.type.caption.copyWith(color: context.colors.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Layout arrives as doubles and is nearly always whole pixels, so `48` beats
/// `48.0` and `47.5` still says so.
String _n(double value) => value == value.roundToDouble()
    ? '${value.round()}'
    : value.toStringAsFixed(1);
