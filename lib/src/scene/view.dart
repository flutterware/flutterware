// The scene, rendered by the app that owns it.
//
// This widget is the scene system's other deliverable. The editor's canvas is
// this widget in the app's own process — which is the whole reason the editor
// has no renderer of its own — and a scene that ships is this widget mounted
// in a screen. One renderer, so what you designed is what runs.
//
// External nodes are the seam: a scene names an entry, and the app hands over
// the real widget for it. Nothing about that widget crosses a wire — its
// mockup data, its theme, its own animations all live here, on this side.
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../previews/playhead.dart';
import 'core/model.dart';
import 'core/motion_model.dart';
import 'core/props.dart';
import 'core/motion_runtime.dart';
import 'core/values.dart';
import 'flutter_bridge.dart';
import 'layered_text.dart';

/// Reports what the layout measured, in artboard coordinates. The editor's
/// geometry comes from here: a flex child has no authored position, so the
/// only true answer is the one the renderer laid out.
///
/// Keyed by the NODE, not by its name. A compiled scene has no names — the
/// field names live in the source, where the editor reads them — so a
/// name-keyed report would collide every node of it onto one empty string.
/// Whoever holds names (the editor, the guest naming rects for the wire)
/// puts them on at its own edge.
typedef SceneMeasured = void Function(Map<SceneNode, SceneRect> rects);

/// The same rects under the names the nodes carry — what the guest sends
/// back over the wire, and what a surface holding a PARSED document asks
/// its geometry by.
///
/// Meaningless for a compiled scene, whose nodes have no names: every entry
/// would land on the empty string. That is the whole reason [SceneMeasured]
/// hands over the nodes and this is a separate step.
Map<String, SceneRect> namedRects(Map<SceneNode, SceneRect> rects) => {
  for (var entry in rects.entries)
    if (entry.key.name.isNotEmpty) entry.key.name: entry.value,
};

/// Draws one node of a registered kind. It reads the node's rows itself —
/// composed through `fxRendered`, so a motion's track reaches it — and its
/// children, which the view does not lay out for it. [child] draws one of
/// them the way the view draws any node, for a kind that shows a child
/// somewhere the view cannot reach — on a mesh, say. What it returns stays
/// live: it redraws with the document, wherever it is mounted.
typedef SceneKindRenderer = Widget Function(
  BuildContext context,
  KindNode node,
  SceneChildRenderer child,
);

/// The view's own picture of one node, handed to a kind's renderer.
typedef SceneChildRenderer = Widget Function(SceneNode child);

class SceneView extends StatefulWidget {
  /// Draws a scene an app COMPILED — `SceneView(BannerScene())`, which is
  /// the whole of what mounting one takes.
  ///
  /// The definition holds its document (built once, `late final`), so this
  /// costs nothing per rebuild. It does not make the definition safe to
  /// build in `build()`: a fresh `BannerScene()` is fresh nodes, and a
  /// player would go on writing its fx onto the ones that went away. Hold
  /// it in a field.
  SceneView(
    SceneDefinition definition, {
    super.key,
    SceneMotion? motion,
    this.time,
    this.selected = const {},
    this.onMeasured,
    this.renderers = const {},
  }) : scene = definition.scene,
       motion = motion?.playable;

  /// Draws a document that was READ — parsed from source, or decoded off
  /// the editor's wire. There is no definition behind one of those, which is
  /// why it is a door of its own rather than the same one.
  const SceneView.document(
    this.scene, {
    super.key,
    this.motion,
    this.time,
    this.selected = const {},
    this.onMeasured,
    this.renderers = const {},
  });

  /// How a registered kind ([SceneKind]) is drawn, by the kind's name — the
  /// door a renderer the core never imports comes through, the way an
  /// external widget's builder does. A kind with no renderer draws a named
  /// placeholder, never a silent gap.
  final Map<String, SceneKindRenderer> renderers;

  /// The live document. Edits and fx writes both notify it, and this widget
  /// redraws from the RENDERED plane — base composed with every fx writer —
  /// so a playing motion and a saved layout are one picture.
  final SceneDocument scene;

  /// What animates this scene, bound to it. Mounting one REGISTERS A
  /// PLAYHEAD: an export walks it, a test parks it, and `previews` can
  /// photograph the scene at any moment without the app wiring anything.
  ///
  /// The view never plays it — a clock is the app's business, and a
  /// [MotionPlayer] over the same playable is how a scene plays on screen.
  final Playable? motion;

  /// Scene time for what the clock draws — a shader pass's `uTime`. Null
  /// reads the motion's; with neither it is zero.
  ///
  /// A listenable rather than a value, because a seek that moves no track
  /// writes no fx: the document never notifies, this view never rebuilds,
  /// and only something listening to the clock itself hears the time move.
  final ValueListenable<Duration>? time;

  /// Names to outline — editor chrome, and empty in a shipped scene.
  final Set<String> selected;

  final SceneMeasured? onMeasured;

  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView> {
  /// Keyed by the node's NAME where it has one, and by the node itself
  /// where it does not. A document that arrived as data is a fresh set of
  /// objects on every push from the editor, and a key that followed the
  /// object remounted every subtree per push — a 3D view loaded its
  /// assets again on each keystroke (measured 2026-09-07). The name is the
  /// identity the editor keys on, so a key that follows it keeps a node's
  /// state across pushes. A compiled scene may have no names — identity
  /// there is the object — and two nodes sharing one key is a
  /// duplicate-GlobalKey crash rather than a wrong picture, so an unnamed
  /// node keys on itself. A nested instance's nodes carry their ref's
  /// prefix, since two scenes both have a `root`.
  final _keys = <Object, GlobalKey>{};
  final _artboard = GlobalKey();

  GlobalKey _key(SceneNode node, [String prefix = '']) =>
      _keys.putIfAbsent(_identity(node, prefix), GlobalKey.new);

  /// A second key, on the node's CONTENT rather than its box. The box's
  /// wrappers come and go — a selection outline, an opacity below one, an
  /// imposed transform — and each changes the structure between the box
  /// and what it holds, which recreates the content's element unless a
  /// global key lets Flutter move it. A 3D view lost its engine scene on
  /// every selection change until this (measured 2026-09-07).
  final _contentKeys = <Object, GlobalKey>{};

  GlobalKey _contentKey(SceneNode node, String prefix) =>
      _contentKeys.putIfAbsent(_identity(node, prefix), GlobalKey.new);

  static Object _identity(SceneNode node, String prefix) =>
      node.name.isEmpty ? node : '$prefix${node.name}';

  String? _playheadId;

  /// The one time every text of this view is handed. Held, because the
  /// motion's is a fresh adapter per ask, and a painter compares its time by
  /// identity: a new object each build would re-subscribe and repaint it for
  /// a rebuild that moved nothing.
  ValueListenable<Duration>? _time;

  ValueListenable<Duration>? _timeOf(SceneView w) =>
      w.time ?? w.motion?.clock.flutter;

  @override
  void initState() {
    super.initState();
    installSceneFrameFlush();
    widget.scene.addListener(_onChanged);
    _mountPlayhead();
    _time = _timeOf(widget);
  }

  void _mountPlayhead() {
    var motion = widget.motion;
    if (motion == null) return;
    _playheadId = PlayheadRegistry.instance.attach(_ScenePlayhead(motion));
  }

  void _unmountPlayhead() {
    var id = _playheadId;
    if (id != null) PlayheadRegistry.instance.detach(id);
    _playheadId = null;
  }

  @override
  void didUpdateWidget(SceneView old) {
    super.didUpdateWidget(old);
    if (old.scene != widget.scene) {
      old.scene.removeListener(_onChanged);
      widget.scene.addListener(_onChanged);
    }
    if (old.motion != widget.motion) {
      _unmountPlayhead();
      _mountPlayhead();
    }
    if (old.time != widget.time || old.motion != widget.motion) {
      _time = _timeOf(widget);
    }
  }

  @override
  void dispose() {
    _unmountPlayhead();
    widget.scene.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Sweeps the laid-out boxes after the frame that drew them. Every node
  /// gets its rect relative to the artboard, which is the space the editor
  /// works in.
  void _sweep() {
    if (widget.onMeasured == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      var root = _artboard.currentContext?.findRenderObject() as RenderBox?;
      if (root == null) return;
      var rects = <SceneNode, SceneRect>{};
      SceneRect? visit(SceneNode node) {
        var box =
            _keys[_identity(node, '')]?.currentContext?.findRenderObject()
                as RenderBox?;
        SceneRect? rect;
        if (box != null && box.hasSize) {
          rect =
              (box.localToGlobal(Offset.zero, ancestor: root) & box.size).scene;
        }
        SceneRect? spanned;
        // A registered kind draws its children itself, somewhere the
        // artboard's plane does not reach — a mesh, a texture — so their
        // boxes, where there are any, are not artboard boxes. The tree is
        // their door, not the canvas.
        if (node is! KindNode) {
          for (var child in node.children) {
            var childRect = visit(child);
            if (childRect == null) continue;
            spanned = spanned == null ? childRect : _union(spanned, childRect);
          }
        }
        // A table row draws no box of its own — the table lays out the
        // cells and paints the row behind them — so the row IS what its
        // cells span, which is the rect the editor selects and drops on.
        rect ??= spanned;
        if (rect != null) rects[node] = rect;
        return rect;
      }

      visit(widget.scene.root);
      widget.onMeasured!(rects);
    });
  }

  /// How far the children of a free frame reach along one axis: the
  /// authored size where there is one, and what the last layout measured
  /// where there is not.
  double _freeExtent(FrameNode f, {required bool horizontal}) {
    var extent = 0.0;
    for (var child in f.children) {
      var authored = horizontal ? child.width : child.height;
      var size = authored != null && authored.isFinite
          ? authored
          : switch (child.measured) {
              var m? => horizontal ? m.width : m.height,
              _ => 0.0,
            };
      var end = (horizontal ? child.x : child.y) + size;
      if (end > extent) extent = end;
    }
    return extent;
  }

  /// Which axes of [n] its parent has already sized for it. The parent is
  /// passed rather than looked up: a repeated copy hangs in no tree.
  ({bool width, bool height}) _stretchedBy(SceneNode n, FrameNode? parent) {
    if (parent == null || parent.layout == NodeLayout.absolute) {
      return (width: false, height: false);
    }
    // A cell's width is the column's, and a cell that also asked for one
    // would be fighting the table for it.
    if (parent.layout == NodeLayout.table) {
      return (width: true, height: false);
    }
    var row = parent.layout == NodeLayout.row;
    var mainFilled = row ? n.widthFills : n.heightFills;
    var crossStretched = parent.crossAlign == SceneCrossAxisAlignment.stretch;
    return (
      width: row ? mainFilled : crossStretched,
      height: row ? crossStretched : mainFilled,
    );
  }

  @override
  Widget build(BuildContext context) {
    _sweep();
    var root = widget.scene.root;
    // The three shapes a scene root comes in, and the only difference
    // between the three things a scene is for. A banner is fixed on both
    // axes; a screen takes the constraints the app hands it; a document is
    // fixed across and grows down. Fill is that: leave the axis alone and
    // let what is above decide.
    return SizedBox(
      key: _artboard,
      width: root.width,
      height: root.height,
      // Material, not a bare ColoredBox: without a Material ancestor every
      // Text falls back to the debug style — the yellow double underline.
      child: Material(
        color: root.fill?.flutter ?? const Color(0x00000000),
        // The root's corner lives here with its fill, since its decoration
        // is skipped below — a nested scene's root is often a pill.
        borderRadius: root.corners.isZero ? null : root.corners.flutter,
        clipBehavior: root.corners.isZero && !root.clip
            ? Clip.none
            : Clip.antiAlias,
        child: _node(context, root, root: true),
      ),
    );
  }

  /// [prefix] namespaces the keys of a nested instance's nodes under the
  /// ref that holds them: two scenes both have a `root`.
  Widget _node(
    BuildContext context,
    SceneNode n, {
    bool root = false,
    String prefix = '',
    FrameNode? parent,
  }) {
    Widget? inner;
    switch (n) {
      case TextNode t:
        inner = LayeredText(
          span: TextSpan(children: sceneTextRuns(t)),
          style: sceneTextStyleFor(t),
          layers: t.layers,
          textAlign: t.align.flutter,
          maxLines: t.maxLines,
          time: _time,
        );
      case ShapeNode _:
        inner = null;
      case KindNode k:
        inner =
            widget.renderers[k.kind.name]?.call(
              context,
              k,
              (child) => _live(child, prefix),
            ) ??
            _MissingKind(k.kind.name);
      case ExternalNode e:
        // A compiled node reaches the app's declaration through its own
        // generated class, so nothing is passed in for it. A node that
        // arrived as data was bound by whoever holds the declarations.
        var built = e.buildWidget();
        inner = built == null
            // Named rather than blank: a scene naming an entry nothing can
            // build is a wiring mistake, and a silent gap reads as a layout
            // one.
            ? _MissingExternal(e.entry)
            : _asWidget(built, e.entry);
      case SceneRefNode r:
        var inst = r.instance;
        if (inst == null) {
          inner = _MissingScene(r.sceneClassName);
        } else {
          r.syncInstance();
          inner = _node(context, inst.root, prefix: '$prefix${r.name}/');
        }
      case FrameNode f:
        var gap = f.fxRendered('gap') as double;
        if (f.layout == NodeLayout.absolute) {
          var stack = Stack(
            clipBehavior: Clip.none,
            children: [
              for (var c in f.children)
                if (c.visible)
                  for (var drawn in widget.scene.expand(c))
                    _child(context, f, drawn, prefix),
            ],
          );
          // A stack cannot lay out under an unbounded constraint, and a
          // column hands its children exactly that on the main axis. A free
          // frame with no size of its own inside one would assert, so it is
          // given the extent its children actually reach — which is the only
          // size a free frame has ever meant.
          inner = LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              width: constraints.hasBoundedWidth
                  ? null
                  : _freeExtent(f, horizontal: true),
              height: constraints.hasBoundedHeight
                  ? null
                  : _freeExtent(f, horizontal: false),
              child: stack,
            ),
          );
          break;
        }
        if (f.layout == NodeLayout.table) {
          inner = _table(context, f, prefix);
          break;
        }
        var row = f.layout == NodeLayout.row;
        Widget flex({required bool expand}) {
          var children = [
            for (var c in f.children)
              if (c.visible)
                for (var drawn in widget.scene.expand(c))
                  _child(context, f, drawn, prefix, expand: expand),
          ];
          return row
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: f.mainAlign.flutter,
                  crossAxisAlignment: f.crossAlign.flutter,
                  spacing: gap,
                  children: children,
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: f.mainAlign.flutter,
                  crossAxisAlignment: f.crossAlign.flutter,
                  spacing: gap,
                  children: children,
                );
        }

        // A child can only take what is left when there is a left: a flex
        // whose own main axis is unbounded has none, and Flutter throws
        // rather than guessing. Fill degrades to hug there, which is the
        // honest answer and what the editor has to say out loud.
        var anyFills = f.children.any(
          (c) => row ? c.widthFills : c.heightFills,
        );
        inner = anyFills
            ? LayoutBuilder(
                builder: (context, constraints) => flex(
                  expand: row
                      ? constraints.hasBoundedWidth
                      : constraints.hasBoundedHeight,
                ),
              )
            : flex(expand: false);
    }

    var circle = n is ShapeNode && n.circle;
    var fill = n.hasFx('fill') ? n.fxRendered('fill') as SceneColor : n.fill;
    var padding = n is FrameNode ? n.padding : SceneEdges.zero;
    // A node the parent already stretched must not also ask for infinity:
    // `Expanded` hands it a tight box, and an infinite width inside one is
    // an unbounded-constraint error rather than a wide node.
    var stretched = _stretchedBy(n, parent);
    Widget result = Container(
      key: _key(n, prefix),
      width: stretched.width ? null : n.width,
      height: stretched.height ? null : n.height,
      padding: padding.isZero ? null : padding.flutter,
      foregroundDecoration: !root && widget.selected.contains(n.name)
          ? BoxDecoration(
              border: Border.all(color: const Color(0xFF4A64D0), width: 1.5),
            )
          : null,
      // The root's own fill is painted by the Material above, so a nested
      // decoration would double it.
      decoration:
          !root && (fill != null || n.borderColor != null || !n.corners.isZero)
          ? BoxDecoration(
              color: fill?.flutter,
              border: n.borderColor == null
                  ? null
                  : Border.all(
                      color: n.borderColor!.flutter,
                      width: n.borderWidth,
                    ),
              shape: circle ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: circle || n.corners.isZero
                  ? null
                  : n.corners.flutter,
            )
          : null,
      child: inner == null
          ? null
          : KeyedSubtree(key: _contentKey(n, prefix), child: inner),
    );
    // A clipping frame cuts its children at its own corners; a bounded node
    // is held between its bounds whatever its parent hands it.
    if (n is FrameNode && n.clip && !root) {
      result = ClipRRect(borderRadius: n.corners.flutter, child: result);
    }
    if (n.minWidth != null ||
        n.maxWidth != null ||
        n.minHeight != null ||
        n.maxHeight != null) {
      result = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: n.minWidth ?? 0,
          maxWidth: n.maxWidth ?? double.infinity,
          minHeight: n.minHeight ?? 0,
          maxHeight: n.maxHeight ?? double.infinity,
        ),
        child: result,
      );
    }

    // The wrappers below stay for as long as a writer holds the property,
    // not only while its value is non-identity. A wrapper that comes and
    // goes with the value reparents the keyed node under it on the frame the
    // value crosses 1 — and a GlobalKey reparent resolves through the
    // *binding's* build owner, so in a tree mounted on an owner of its own
    // (an export, a reel's stage) it cannot resolve and the framework
    // asserts a duplicate key. Stable while animated is also cheaper: no
    // subtree deactivates and re-inflates mid-motion.
    var opacity = (n.fxRendered('opacity') as double).clamp(0.0, 1.0);
    if (opacity < 1 || n.hasFx('opacity')) {
      result = Opacity(opacity: opacity, child: result);
    }

    // The imposed transforms have no authored slots — identity is the base —
    // so they wrap only while a writer moves them, about the node's centre.
    var tx = n.fxRendered('translateX') as double;
    var ty = n.fxRendered('translateY') as double;
    var scale = n.fxRendered('scale') as double;
    var rotate = n.fxRendered('rotate') as double;
    var moved =
        n.hasFx('translateX') ||
        n.hasFx('translateY') ||
        n.hasFx('scale') ||
        n.hasFx('rotate');
    if (moved || tx != 0 || ty != 0 || scale != 1 || rotate != 0) {
      var m = Matrix4.translationValues(tx, ty, 0);
      if (rotate != 0) m.rotateZ(rotate * 3.1415926535897932 / 180);
      if (scale != 1) m.multiply(Matrix4.diagonal3Values(scale, scale, 1));
      result = Transform(
        alignment: Alignment.center,
        transform: m,
        child: result,
      );
    }
    return result;
  }

  /// [child] drawn as the view draws it, rebuilt on every change of the
  /// document — a renderer may mount it in a tree of its own (a widget
  /// captured onto a texture is one), where this state's rebuild never
  /// reaches, so the picture listens for itself.
  Widget _live(SceneNode child, String prefix) => ListenableBuilder(
    listenable: widget.scene.listenable,
    builder: (context, _) => _node(context, child, prefix: prefix),
  );

  /// A table: rows that agree on their columns.
  ///
  /// The tracks belong to the frame, so every row is measured against the
  /// same ones — which is the only way a column hugging its widest cell can
  /// mean anything, and the reason stacked rows are not a table.
  Widget _table(BuildContext context, FrameNode f, String prefix) {
    var rows = [
      for (var c in f.children)
        if (c.visible)
          for (var drawn in widget.scene.expand(c)) drawn,
    ];
    List<SceneNode> cellsOf(SceneNode row) =>
        row is FrameNode ? row.children : [row];
    var count = f.columns.length;
    for (var r in rows) {
      var cells = cellsOf(r).length;
      if (cells > count) count = cells;
    }
    if (rows.isEmpty || count == 0) return const SizedBox.shrink();

    Widget table({required bool bounded}) => Table(
      columnWidths: {
        for (var i = 0; i < count; i++)
          i: _track(
            i < f.columns.length ? f.columns[i] : null,
            bounded: bounded,
          ),
      },
      defaultVerticalAlignment: switch (f.crossAlign) {
        SceneCrossAxisAlignment.start => TableCellVerticalAlignment.top,
        SceneCrossAxisAlignment.end => TableCellVerticalAlignment.bottom,
        SceneCrossAxisAlignment.stretch => TableCellVerticalAlignment.fill,
        _ => TableCellVerticalAlignment.middle,
      },
      children: [
        for (var r in rows)
          TableRow(
            decoration: _rowDecoration(r),
            children: [
              for (var i = 0; i < count; i++)
                if (cellsOf(r) case var cells)
                  i < cells.length
                      ? Padding(
                          padding: f.cellPadding.flutter,
                          child: _node(
                            context,
                            cells[i],
                            prefix: prefix,
                            parent: f,
                          ),
                        )
                      : const SizedBox.shrink(),
            ],
          ),
      ],
    );

    // A column that takes what is left needs there to BE a left, exactly as
    // `Expanded` does: under an unbounded width it hugs instead.
    var anyFills = f.columns.any((c) => c != null && c.isInfinite);
    return anyFills
        ? LayoutBuilder(
            builder: (context, constraints) =>
                table(bounded: constraints.hasBoundedWidth),
          )
        : table(bounded: false);
  }

  TableColumnWidth _track(double? width, {required bool bounded}) =>
      switch (width) {
        null => const IntrinsicColumnWidth(),
        var w when w.isInfinite =>
          bounded ? const FlexColumnWidth() : const IntrinsicColumnWidth(),
        var w => FixedColumnWidth(w),
      };

  /// What paints behind a table row. A row under a table contributes its
  /// decoration and nothing else — the table lays the cells out, so the
  /// row's own box, padding and size have nowhere to apply.
  Decoration? _rowDecoration(SceneNode r) {
    var selected = widget.selected.contains(r.name);
    var fill = r.hasFx('fill') ? r.fxRendered('fill') as SceneColor : r.fill;
    if (fill == null && r.borderColor == null && !selected) return null;
    // A row has no box to wrap in an Opacity, so it fades what it paints.
    var opacity = (r.fxRendered('opacity') as double).clamp(0.0, 1.0);
    return BoxDecoration(
      color: fill?.flutter.withValues(alpha: fill.alpha / 255 * opacity),
      border: selected
          ? Border.all(color: const Color(0xFF4A64D0), width: 1.5)
          : r.borderColor == null
          ? null
          : Border.all(
              color: r.borderColor!.flutter.withValues(
                alpha: r.borderColor!.alpha / 255 * opacity,
              ),
              width: r.borderWidth,
            ),
      borderRadius: r.corners.isZero ? null : r.corners.flutter,
    );
  }

  Widget _child(
    BuildContext context,
    FrameNode parent,
    SceneNode child,
    String prefix, {
    bool expand = false,
  }) {
    var view = _node(context, child, prefix: prefix, parent: parent);
    if (parent.layout == NodeLayout.absolute) {
      return Positioned(left: child.x, top: child.y, child: view);
    }
    // Fill along the parent's main axis is the parent handing out what is
    // left, which is `Expanded` and nothing else. Along the cross axis it is
    // the child asking for all of it, which its own box already does with an
    // infinite width or height.
    var fillsMain = parent.layout == NodeLayout.row
        ? child.widthFills
        : child.heightFills;
    return fillsMain && expand ? Expanded(child: view) : view;
  }
}

class _MissingScene extends StatelessWidget {
  const _MissingScene(this.sceneClassName);

  final String sceneClassName;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFFCC3333)),
    ),
    child: Text(
      'no scene "$sceneClassName" here',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 10, color: Color(0xFFCC3333)),
    ),
  );
}

/// A registered kind nobody handed the view a renderer for — named, so a
/// missing registration reads as one.
class _MissingKind extends StatelessWidget {
  const _MissingKind(this.kind);

  final String kind;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0x33FF0000),
    child: Center(
      child: Text(
        'no renderer for $kind',
        style: const TextStyle(color: Color(0xFFB00020), fontSize: 12),
      ),
    ),
  );
}

class _MissingExternal extends StatelessWidget {
  const _MissingExternal(this.entry);

  final String entry;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFFCC3333)),
    ),
    child: Text(
      'no widget registered for "$entry"',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 10, color: Color(0xFFCC3333)),
    ),
  );
}

/// A bound motion as a [Playhead]: parking it applies the fx plane for that
/// moment, and the document's own flush repaints whatever is watching. No
/// clock — that is the point, and what makes a walk repeatable.
class _ScenePlayhead implements Playhead {
  _ScenePlayhead(this.playable);

  final Playable playable;

  @override
  Duration get duration => playable.duration;

  @override
  void seek(Duration position) => playable.apply(position);
}

/// Gives every external node in [doc] the builder its label names.
///
/// A scene the app COMPILED needs none of this: each node holds its own
/// generated arguments, which reach the declaration themselves. This is for
/// a document that arrived as DATA — over the editor's wire, or read back
/// from a saved pair — where the generated type could not travel and the
/// label is all that did.
///
/// [tokens] are the app's declared tokens, for the opaque ones: an argument
/// that arrived as `{'token': 'cta'}` — the editor never held the object —
/// becomes the declared object here, before the builder sees it. A read
/// document is the only one that needs this; a compiled scene reads
/// `tokens.cta` itself.
void bindExternals(
  SceneDocument doc,
  List<ExternalWidget> declarations, {
  List<Token<Object?>> tokens = const [],
}) {
  var byEntry = {for (var w in declarations) w.entry: w};
  var byName = {for (var t in tokens) t.name: t.value};
  for (var (node, _) in doc.walk()) {
    resolveExports(node, byName);
    if (node is! ExternalNode) continue;
    var build = byEntry[node.entry]?.build;
    node.builder = build == null
        ? null
        : (args) => build(resolveTokenArgs(args, byName));
  }
}

/// Puts the app's own values on the properties of [node] bound to them.
///
/// An EXPORT — `Token<Color>('brand', AppColors.brand)` in the group's
/// declaration — reaches the editor as a name; the editor never holds the
/// value and sends the binding as it is. This end holds the object, so a
/// `fill` bound to `brand` takes the app's colour here, a `double` a number,
/// a `String` text. A `TextStyle` in the style slot is laid UNDER the
/// text's own values: every property the app's style sets and the text
/// left at its default takes the style's — the resolution the compiled
/// `TextNode(…, style: tokens.title)` does with `fontSize ?? style?.
/// fontSize ?? 16`, so the two planes agree.
void resolveExports(SceneNode node, Map<String, Object?> exports) {
  for (var e in node.bindings.entries) {
    var prop = e.key;
    switch (e.value) {
      case TokenRef(:var name) when sceneArgName(prop) == null:
        if (!exports.containsKey(name)) continue;
        var value = switch (exports[name]) {
          Color c => c.scene,
          SceneColor c => c,
          num n => n.toDouble(),
          String s => s,
          bool b => b,
          _ => null,
        };
        if (value != null) setSceneProperty(node, prop, value);
      case StyleRef(:var name) when node is TextNode:
        var style = switch (exports[name]) {
          TextStyle s => sceneTextStyleOf(s),
          SceneTextStyle s => s,
          _ => null,
        };
        if (style == null) continue;
        var props = {for (var p in scenePropsOf(node)) p.name: p};
        for (var f in style.values.entries) {
          var prop = props[f.key];
          if (prop == null) continue;
          if (isSceneDefault(prop, prop.read(node))) {
            setSceneProperty(node, f.key, f.value);
          }
        }
      default:
        break;
    }
  }
}

/// [args] with every opaque-token marker replaced by the token's object;
/// a marker naming nothing the app declared resolves to null, which is the
/// widget's own fallback.
SceneArgs resolveTokenArgs(SceneArgs args, Map<String, Object?> tokens) =>
    SceneArgs({
      for (var name in args.names)
        name: switch (tokenMarkerName(args.raw(name))) {
          var token? => tokens[token],
          null => args.raw(name),
        },
    });

/// The spans a text node draws — its runs, each carrying only what it
/// DIFFERS by, over the node's own style.
///
/// One span today, because a `TextNode` carries one string, and a list
/// because it will not always: a run is a string with a style delta, and
/// when text becomes several of them only this function changes. The
/// renderer already asks for a list and already puts the node's style above
/// it, so that landing is a model and a grammar change with no renderer work
/// (master plan §4.5).
List<InlineSpan> sceneTextRuns(TextNode t) => [
  for (var run in t.runs)
    TextSpan(
      text: t.textCase.apply(run.text),
      // Only what the run DIFFERS by: the renderer puts the node's style
      // above the list, and a span that repeated it would be a second
      // resolution of the same fields — the shape that made the ambient
      // style bug possible.
      style: run.style == null ? null : sceneRunStyle(run.style!),
    ),
];

/// A run's delta as Flutter spells one: only the fields it sets.
///
/// A run never carries a paint stack — that is refused where a file is read
/// — and it never carries the paragraph's own properties, which left the
/// style when `align` and `maxLines` did.
TextStyle sceneRunStyle(SceneTextStyle d) => TextStyle(
  fontFamily: d.fontFamily,
  fontSize: d.fontSize,
  fontWeight: d.weight?.flutter,
  fontStyle: d.italic == null
      ? null
      : (d.italic! ? FontStyle.italic : FontStyle.normal),
  letterSpacing: d.letterSpacing,
  wordSpacing: d.wordSpacing,
  height: d.lineHeight,
  color: d.color?.flutter,
  decoration: d.decoration?.flutter,
  decorationColor: d.decorationColor?.flutter,
  decorationThickness: d.decorationThickness,
  decorationStyle: d.decorationStyle?.flutter,
  fontVariations: d.axes == null
      ? null
      : [for (var e in d.axes!.entries) FontVariation(e.key, e.value)],
);

/// A text node's resolved properties as Flutter draws them. The animatable
/// ones are read composed — what a motion track put there this frame — and
/// the rest straight off the node.
///
/// A null [TextNode.fontFamily] is left null on purpose: the span merges
/// with whatever `DefaultTextStyle` the app wraps the canvas in, so a scene
/// that names no typeface inherits the app's rather than a guess.
TextStyle sceneTextStyleFor(TextNode t) => TextStyle(
  fontFamily: t.fontFamily,
  fontSize: t.fxRendered('fontSize') as double,
  fontWeight: t.weight.flutter,
  fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
  letterSpacing: t.fxRendered('letterSpacing') as double,
  wordSpacing: t.fxRendered('wordSpacing') as double,
  height: t.fxRendered('lineHeight') as double,
  color: (t.fxRendered('color') as SceneColor).flutter,
  decoration: t.decoration.flutter,
  // Null is Flutter's own "the text's colour", which is what a design tool
  // means by leaving it unset.
  decorationColor: t.decorationColor?.flutter,
  decorationThickness: t.fxRendered('decorationThickness') as double,
  decorationStyle: t.decorationStyle.flutter,
  fontVariations: sceneFontVariations(t),
);

/// The face's axes, at whatever a motion has them — the one thing a discrete
/// [FontWeight] cannot do, which is why an axis is a number key of its own.
///
/// A tag a track moves but the node never set is included: the track is the
/// whole of what it says, and leaving it out would animate nothing.
List<FontVariation>? sceneFontVariations(TextNode t) {
  var tags = <String>{
    ...t.axes.keys,
    for (var k in t.fx.keys) ?sceneAxisTag(k.$2),
  };
  if (tags.isEmpty) return null;
  return [
    for (var tag in tags)
      FontVariation(tag, (t.fxRendered('axes.$tag') as num).toDouble()),
  ];
}

/// A builder returns `Object`, because the half of the model that declares
/// it is pure Dart. This is where that becomes a widget again, and where a
/// builder that returned something else says so instead of crashing the
/// frame.
Widget _asWidget(Object built, String entry) => built is Widget
    ? built
    : _MissingExternal('$entry built a ${built.runtimeType}, not a widget');

SceneRect _union(SceneRect a, SceneRect b) {
  var left = a.left < b.left ? a.left : b.left;
  var top = a.top < b.top ? a.top : b.top;
  var right = a.right > b.right ? a.right : b.right;
  var bottom = a.bottom > b.bottom ? a.bottom : b.bottom;
  return SceneRect(left, top, right - left, bottom - top);
}
