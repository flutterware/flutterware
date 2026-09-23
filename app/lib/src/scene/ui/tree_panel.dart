import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/context_menu.dart';
import '../../ui/design/design.dart';
import '../../ui/menu.dart';
import '../../ui/tappable.dart';
import '../../ui/tree_row.dart';
import '../editor.dart';
import 'outline_sections.dart';
import 'tokens_host.dart';
import 'modifiers.dart';

/// The scene's nodes as a tree: one row per node, folded per frame, selected
/// as a set. Hovering a row hovers the node on the canvas and the other way
/// round, because both are the same `SceneEditor.hover`.
///
/// A row is dragged to move its node: dropped onto a frame it goes inside,
/// dropped on the top edge of any row it goes before that node. A double-
/// click renames; a right-click offers the rest. Adding is the canvas's job
/// — the tools on its bar — so there is no second way here.
class SceneTreePanel extends StatefulWidget {
  const SceneTreePanel(
    this.editor, {
    super.key,
    this.onEnterNested,
    this.sceneClassName,
    this.onOpenMotion,
    this.onOpenParam,
    this.tokens,
  });

  /// See [SceneOutlineSections.tokens].
  final SceneTokensHost? tokens;

  final SceneEditor editor;

  /// Opening a nested scene drills into it; null leaves the row plain.
  final ValueChanged<SceneNode>? onEnterNested;

  /// See [SceneOutlineSections.sceneClassName].
  final String? sceneClassName;

  /// See [SceneOutlineSections.onOpenMotion].
  final ValueChanged<String>? onOpenMotion;

  /// See [SceneOutlineSections.onOpenParam].
  final ValueChanged<String>? onOpenParam;

  @override
  State<SceneTreePanel> createState() => _SceneTreePanelState();
}

/// Where a dragged node would land relative to the row under it.
enum _Drop { before, into }

class _SceneTreePanelState extends State<SceneTreePanel> {
  final _folded = <String>{};

  /// The node being renamed inline, and what its field says.
  String? _renaming;
  String? _renameError;
  final _renameField = TextEditingController();

  /// The rename field's own focus. `autofocus` would be dropped: a scope
  /// that already has a focused node — the editor's — ignores it.
  final _renameFocus = FocusNode(debugLabel: 'rename');

  /// The row a drag is over and where on it, for the indicator.
  (String, _Drop)? _dropAt;

  /// The last row tapped and when: a second tap on it within the double-tap
  /// window renames. Detected here rather than with a double-tap recognizer,
  /// which would hold every single tap for 300ms to see if another came —
  /// selection has to be instant.
  (String, DateTime)? _lastTap;

  SceneEditor get editor => widget.editor;
  SceneDocument get doc => editor.doc;

  @override
  void dispose() {
    _renameField.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  Iterable<(SceneNode, int)> _rows() sync* {
    // A canvas drag proposing a target inside a folded branch would light up
    // a row nobody can see. Revealed for the length of the drag, and only in
    // the render: [_folded] is untouched, so the tree goes back to how it
    // was left rather than to how a drag happened to open it.
    var revealed = <String>{};
    for (SceneNode? p = editor.dropTarget; p != null; p = doc.parentOf(p)) {
      revealed.add(p.name);
    }
    Iterable<(SceneNode, int)> visit(SceneNode node, int depth) sync* {
      yield (node, depth);
      if (_folded.contains(node.name) && !revealed.contains(node.name)) return;
      for (var child in node.children) {
        yield* visit(child, depth + 1);
      }
    }

    yield* visit(doc.root, 0);
  }

  void _startRename(SceneNode node) {
    if (node == doc.root) return;
    setState(() {
      _renaming = node.name;
      _renameError = null;
      _renameField
        ..text = node.name
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: node.name.length,
        );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _renaming == node.name) _renameFocus.requestFocus();
    });
  }

  void _commitRename(SceneNode node) {
    try {
      editor.rename(node, _renameField.text);
      setState(() {
        _renaming = null;
        _renameError = null;
      });
    } on ArgumentError catch (e) {
      setState(() => _renameError = e.message as String?);
    }
  }

  void _cancelRename() => setState(() {
    _renaming = null;
    _renameError = null;
  });

  /// The nodes a drag of [node] carries: the selection when it is part of
  /// it, otherwise just the node.
  List<SceneNode> _dragged(SceneNode node) =>
      editor.isSelected(node) ? editor.selectedNodes.toList() : [node];

  void _drop(List<SceneNode> nodes, SceneNode onto, _Drop where) {
    switch (where) {
      case _Drop.into:
        if (onto is! FrameNode) return;
        editor.reparent(nodes, onto);
        _folded.remove(onto.name);
      case _Drop.before:
        var parent = doc.parentOf(onto);
        if (parent == null) return;
        editor.reparent(nodes, parent, index: parent.children.indexOf(onto));
    }
    editor.setSelection([for (var n in nodes) n.name]);
  }

  void _menu(BuildContext context, Offset at, SceneNode node) {
    if (!editor.isSelected(node)) editor.select(node);
    var count = editor.selectedNodes.length;
    var what = count > 1 ? '$count nodes' : node.name;
    showContextMenu(context, at, [
      if (node is SceneRefNode && widget.onEnterNested != null)
        MenuItem(
          'Open ${node.sceneClassName}',
          icon: Icons.layers_outlined,
          onSelected: () => widget.onEnterNested!(node),
        ),
      // A placement has no box on the artboard, so the canvas cannot draw
      // one; the window's row is where a model or a screen is added.
      if (node is KindNode && node.kind == view3dKind) ...[
        MenuItem(
          'Add a model',
          icon: Icons.category_outlined,
          onSelected: () =>
              editor.addChild(node, ModelNode(name: doc.uniqueName('model'))),
        ),
        MenuItem(
          'Add a screen',
          icon: Icons.smartphone_outlined,
          onSelected: () => editor.addChild(
            node,
            SurfaceNode(
              name: doc.uniqueName('screen'),
              size: 40,
              children: [
                // Something to see at once: a plain quad with a card on it,
                // until the modeller's mesh and the scene's content replace
                // both.
                FrameNode(name: doc.uniqueName('content'))
                  ..width = 320
                  ..height = 200
                  ..corner = 16
                  ..fill = const SceneColor(0xFFFFD166),
              ],
            ),
          ),
        ),
        const MenuDivider(),
      ],
      if (node != doc.root)
        MenuItem(
          'Rename',
          icon: Icons.edit_outlined,
          shortcut: 'double-click',
          onSelected: () => _startRename(node),
        ),
      if (node != doc.root)
        MenuItem(
          node.visible ? 'Hide $what' : 'Show $what',
          icon: node.visible
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
          onSelected: () => editor.setVisible(!node.visible),
        ),
      if (node != doc.root)
        MenuItem(
          'Duplicate $what',
          icon: Icons.copy_outlined,
          shortcut: '⌘D',
          onSelected: editor.duplicateSelection,
        ),
      if (node != doc.root) ...[
        const MenuDivider(),
        MenuItem(
          'Delete $what',
          icon: Icons.close,
          shortcut: '⌫',
          danger: true,
          onSelected: editor.deleteSelection,
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([doc.listenable, editor.listenable]),
      // The layers take what the outline sections leave; the sections are
      // capped so a scene with many parameters cannot push the layers out,
      // and scroll on their own past the cap.
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
                children: [
                  for (var (node, depth) in _rows()) _row(context, node, depth),
                ],
              ),
            ),
            Container(height: 1, color: context.colors.line),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.45,
              ),
              child: SingleChildScrollView(
                // The scrollbar's lane, so a row's `+` is not under it.
                padding: const EdgeInsets.only(right: FwSpacing.md),
                child: SceneOutlineSections(
                  editor,
                  sceneClassName: widget.sceneClassName,
                  tokens: widget.tokens,
                  onOpenMotion: widget.onOpenMotion,
                  onOpenParam: widget.onOpenParam,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, SceneNode node, int depth) {
    var colors = context.colors;
    var selected = editor.isSelected(node);
    var hovered = editor.hover == node.name;
    var renaming = _renaming == node.name;
    // Two drags can propose this row: the tree's own, and the canvas's,
    // which puts the frame it would drop into on the editor. One indicator
    // for both — a drop target is a drop target, and the tree is where the
    // hierarchy is legible.
    var drop = _dropAt?.$1 == node.name
        ? _dropAt!.$2
        : identical(editor.dropTarget, node)
        ? _Drop.into
        : null;

    var row = FwTreeRow(
      depth: depth,
      density: TreeRowDensity.roomy,
      selected: selected || drop == _Drop.into,
      open: node.children.isNotEmpty ? !_folded.contains(node.name) : null,
      onToggleFold: () => setState(() {
        if (!_folded.remove(node.name)) _folded.add(node.name);
      }),
      // The chevron takes the row's leading slot on a branch, so the type
      // icon lives in the label: a frame with children keeps its icon, and
      // reads as the same kind of thing as a frame without.
      label: Row(
        spacing: FwSpacing.sm,
        children: [
          Icon(
            _iconFor(node),
            size: FwIconSize.sm,
            color: selected ? colors.accentDark : colors.mut,
          ),
          Expanded(
            child: renaming
                ? _renameEditor(context, node)
                : Text(
                    node.name,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.body.copyWith(
                      color: !node.visible
                          ? colors.mut2
                          : hovered
                          ? colors.accentDark
                          : colors.ink,
                    ),
                  ),
          ),
        ],
      ),
      trailing: [
        // A repeated node is one row here and several on the canvas, which
        // is exactly the thing that has to be readable from the tree.
        if (node case FrameNode(repeated: var rep?) when rep.source.isNotEmpty)
          Tooltip(
            message: 'Drawn once per item of "${rep.source}"',
            child: Text(
              '×${rep.items.length}',
              style: context.type.caption.copyWith(color: colors.mut2),
            ),
          ),
        for (var swatch in _swatchesOf(node))
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: swatch.flutter,
              shape: BoxShape.circle,
              border: Border.all(color: colors.line),
            ),
          ),
        if (node is SceneRefNode) ...[
          Text(
            node.sceneClassName,
            style: context.type.caption.copyWith(
              color: node.instance == null ? colors.red : colors.mut2,
            ),
          ),
          if (widget.onEnterNested != null)
            Tooltip(
              message: 'Open ${node.sceneClassName}',
              child: Tappable(
                onTap: () => widget.onEnterNested!(node),
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
                child: Padding(
                  padding: const EdgeInsets.all(FwSpacing.xxs),
                  child: Icon(
                    Icons.arrow_forward,
                    size: FwIconSize.sm,
                    color: colors.mut,
                  ),
                ),
              ),
            ),
        ],
      ],
      onTap: () {
        var now = DateTime.now();
        var again =
            _lastTap?.$1 == node.name &&
            now.difference(_lastTap!.$2) < kDoubleTapTimeout;
        _lastTap = (node.name, now);
        if (again && node != doc.root && !toggleModifier) {
          _startRename(node);
          return;
        }
        editor.select(node == doc.root ? null : node, toggle: toggleModifier);
      },
    );

    // The drop indicator: a line above the row for "before", the row's
    // selected tint (set above) for "into".
    var indicated = Stack(
      children: [
        row,
        if (drop == _Drop.before)
          Positioned(
            left: FwSpacing.md + depth * TreeRowDensity.roomy.indent,
            right: FwSpacing.md,
            top: 0,
            child: Container(height: 2, color: colors.accent),
          ),
      ],
    );

    // Distinct names down the chain: a builder closing over a variable that
    // is then assigned the widget it builds recurses forever.
    Widget target = DragTarget<List<SceneNode>>(
      onWillAcceptWithDetails: (d) {
        var box = context.findRenderObject();
        return d.data.every(
              (n) =>
                  n != node &&
                  (node is! FrameNode || editor.canReparent(n, node)),
            ) &&
            box != null;
      },
      onMove: (d) {
        var box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        // Local y within the row decides: the top third is "before", the
        // rest "into" for a frame and "before" for anything else.
        var rowBox = _rowBoxes[node.name];
        if (rowBox == null || !rowBox.attached) return;
        var local = rowBox.globalToLocal(d.offset);
        var where = local.dy < rowBox.size.height / 3 || node is! FrameNode
            ? _Drop.before
            : _Drop.into;
        if (node == doc.root) where = _Drop.into;
        if (_dropAt != (node.name, where)) {
          setState(() => _dropAt = (node.name, where));
        }
      },
      onLeave: (_) {
        if (_dropAt?.$1 == node.name) setState(() => _dropAt = null);
      },
      onAcceptWithDetails: (d) {
        var where = _dropAt?.$1 == node.name ? _dropAt!.$2 : _Drop.into;
        setState(() => _dropAt = null);
        _drop(d.data, node, where);
      },
      builder: (context, _, _) => _Measured(
        onBox: (box) => _rowBoxes[node.name] = box,
        child: indicated,
      ),
    );

    if (node != doc.root && !renaming) {
      target = Draggable<List<SceneNode>>(
        data: _dragged(node),
        // Anchored to the pointer, so the offset a target is handed IS the
        // pointer — the default anchors the feedback where the row was
        // grabbed, and a drop read off that lands a row too early.
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Transform.translate(
          offset: const Offset(12, 12),
          child: Material(
            color: const Color(0x00000000),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.md,
                vertical: FwSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: colors.panel,
                border: Border.all(color: colors.accent),
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
                boxShadow: context.elevation.sm,
              ),
              child: Text(
                _dragged(node).length > 1
                    ? '${_dragged(node).length} nodes'
                    : node.name,
                style: context.type.body,
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: target),
        child: target,
      );
    }

    return MouseRegion(
      onEnter: (_) => editor.hover = node.name,
      onExit: (_) {
        if (editor.hover == node.name) editor.hover = null;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition, node),
        child: target,
      ),
    );
  }

  /// Each row's box, for the drop indicator's arithmetic.
  final _rowBoxes = <String, RenderBox>{};

  /// The name, editable, drawn where the label was and at its size — no
  /// border, no padding — so starting a rename moves nothing on the row.
  /// A refusal appears under it, which is the one time the row grows.
  Widget _renameEditor(BuildContext context, SceneNode node) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Enter as a key, not only as the platform's submit action: on the
        // desktop the action does not always arrive, and Enter must commit.
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancelRename,
            const SingleActivator(LogicalKeyboardKey.enter): () =>
                _commitRename(node),
            const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
                _commitRename(node),
          },
          child: TextField(
            controller: _renameField,
            focusNode: _renameFocus,
            style: context.type.body,
            decoration: const InputDecoration.collapsed(hintText: null),
            onSubmitted: (_) => _commitRename(node),
            onTapOutside: (_) => _commitRename(node),
          ),
        ),
        if (_renameError case var error?)
          Text(error, style: context.type.caption.copyWith(color: colors.red)),
      ],
    );
  }

  /// What the node paints: its fill, and for a text its colour after it.
  static List<SceneColor> _swatchesOf(SceneNode node) => [
    ?node.fill,
    if (node is TextNode) node.color,
  ];

  static IconData _iconFor(SceneNode node) => switch (node) {
    FrameNode() => Icons.crop_square,
    TextNode() => Icons.text_fields,
    ShapeNode() => Icons.circle_outlined,
    ExternalNode() => Icons.extension_outlined,
    SceneRefNode() => Icons.layers_outlined,
    KindNode k =>
      k.kind.children ? Icons.view_in_ar_outlined : Icons.category_outlined,
  };
}

/// Hands its render box up once laid out, so a drop can be placed against
/// the row it is over.
class _Measured extends SingleChildRenderObjectWidget {
  const _Measured({required this.onBox, required super.child});

  final ValueChanged<RenderBox> onBox;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasured(onBox);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasured renderObject) {
    renderObject.onBox = onBox;
  }
}

class _RenderMeasured extends RenderProxyBox {
  _RenderMeasured(this.onBox);

  ValueChanged<RenderBox> onBox;

  @override
  void performLayout() {
    super.performLayout();
    onBox(this);
  }
}
