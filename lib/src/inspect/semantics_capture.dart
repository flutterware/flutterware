import 'package:flutter/rendering.dart';

/// The semantics tree as assistive tech reads it, serialized — a scenario
/// step's fourth leg beside the pixels, the texts and the widget tree, and
/// what the catalog's live `ext.flutterware.semantics` serves.
///
/// Null when no view has a semantics tree to read. Under a scenario that
/// never happens — `testWidgets` holds a semantics handle by default — but a
/// **live app has semantics off** until something holds a `SemanticsHandle`
/// (the catalog guest's extension does, while the tab is open), and a capture
/// must state the absence rather than invent an empty screen.
///
/// The shape, per node: `rect` in **screen logical pixels** (the space the
/// screenshot and the widget tree's layout boxes are in), `label` / `value` /
/// `hint` / `tooltip` / `identifier` when non-empty, `flags` and `actions`
/// as name lists — this file is read by the GUI, agents, and humans, none of
/// whom should be handed a bitmask — and `children` in **traversal order**,
/// because reading order is half of what the capture exists to show. Nodes
/// merged into their parent are folded: the merged tree is the one a screen
/// reader consumes, and `getSemanticsData` already carries their words.
Map<String, Object?>? captureSemanticsTree() {
  // The same single view every other capture reads; its *own* pipeline owner,
  // not the binding's root one — the root owner exists and owns no tree
  // (measured, see the spec).
  var view = RendererBinding.instance.renderViews.single;
  var root = view.owner?.semanticsOwner?.rootSemanticsNode;
  if (root == null) return null;
  // Composed transforms land in the root's space, which is physical pixels —
  // the device-pixel-ratio transform sits at the root of the semantics tree
  // exactly as it does in the layer tree.
  return _toJson(root, null, 1 / view.flutterView.devicePixelRatio);
}

Map<String, Object?> _toJson(
  SemanticsNode node,
  Matrix4? ancestorTransform,
  double scale,
) {
  var transform = switch ((ancestorTransform, node.transform)) {
    (null, null) => null,
    (var ancestor?, null) => ancestor,
    (null, var own?) => own,
    (var ancestor?, var own?) => (ancestor.clone()..multiply(own)),
  };
  var rect = transform == null
      ? node.rect
      : MatrixUtils.transformRect(transform, node.rect);
  var data = node.getSemanticsData();
  var actions = [
    for (var action in SemanticsAction.values)
      if (data.hasAction(action)) action.name,
  ];
  var flags = data.flagsCollection.toStrings();
  return {
    'rect': {
      'x': rect.left * scale,
      'y': rect.top * scale,
      'width': rect.width * scale,
      'height': rect.height * scale,
    },
    if (data.label.isNotEmpty) 'label': data.label,
    if (data.value.isNotEmpty) 'value': data.value,
    if (data.hint.isNotEmpty) 'hint': data.hint,
    if (data.tooltip.isNotEmpty) 'tooltip': data.tooltip,
    if (data.identifier.isNotEmpty) 'identifier': data.identifier,
    if (data.textDirection case var direction?) 'textDirection': direction.name,
    if (flags.isNotEmpty) 'flags': flags,
    if (actions.isNotEmpty) 'actions': actions,
    'children': [
      for (var child in node.debugListChildrenInOrder(
        DebugSemanticsDumpOrder.traversalOrder,
      ))
        if (!child.isMergedIntoParent) _toJson(child, transform, scale),
    ],
  };
}
