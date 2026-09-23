import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../editor.dart';

/// Whether the keyboard currently belongs to a text field.
///
/// The editing scopes bind plain letters and Backspace, and a field anywhere
/// inside them — the tree's inline rename — must keep every key: a `t`
/// that switched tools and a Backspace that deleted the node were the first
/// thing a user hit.
bool focusIsInTextField() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>() !=
    null;

/// A focus scope that answers a table of chords, unless a text field has
/// the keyboard — then every key passes through to it.
///
/// A [CallbackShortcuts] cannot do that: once a chord matches it reports the
/// key handled, so a text field below it never sees the letter.
class SceneShortcutScope extends StatelessWidget {
  const SceneShortcutScope({
    super.key,
    required this.focusNode,
    required this.bindings,
    required this.child,
    this.autofocus = false,
  });

  final FocusNode focusNode;
  final Map<ShortcutActivator, VoidCallback> bindings;
  final Widget child;
  final bool autofocus;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (focusIsInTextField()) return KeyEventResult.ignored;
    for (var MapEntry(key: activator, value: action) in bindings.entries) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        action();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Listener(
    // Any press inside takes the keyboard back. A press on a field inside
    // still ends in the field: its own focus request comes after this one.
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => focusNode.requestFocus(),
    child: Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: _onKey,
      child: child,
    ),
  );
}

/// The scene editing focus scope: keyboard verbs for whatever it wraps.
///
/// Owns its focus node, and any pointer-down inside takes the keyboard back
/// — a press in the inspector (which sits outside) leaves it there, so a
/// Backspace in a field never deletes a node. The node is this widget's own
/// rather than `Focus.of(context)`, because the nearest Focus is whatever
/// happens to be nearest — a Scrollable brings one — and focus returned to
/// the wrong one is how cmd-Z reached a text field's built-in undo and beeped.
class EditorShortcuts extends StatefulWidget {
  const EditorShortcuts(this.editor, {super.key, required this.child});

  final SceneEditor editor;
  final Widget child;

  @override
  State<EditorShortcuts> createState() => _EditorShortcutsState();
}

class _EditorShortcutsState extends State<EditorShortcuts> {
  final _node = FocusNode(debugLabel: 'scene editor');

  SceneEditor get editor => widget.editor;

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var arrows = <ShortcutActivator, VoidCallback>{};
    for (var (key, dx, dy) in [
      (LogicalKeyboardKey.arrowLeft, -1.0, 0.0),
      (LogicalKeyboardKey.arrowRight, 1.0, 0.0),
      (LogicalKeyboardKey.arrowUp, 0.0, -1.0),
      (LogicalKeyboardKey.arrowDown, 0.0, 1.0),
    ]) {
      arrows[SingleActivator(key)] = () =>
          editor.nudgeSelection(dx, dy, mergeKey: 'nudge');
      arrows[SingleActivator(key, shift: true)] = () =>
          editor.nudgeSelection(dx * 10, dy * 10, mergeKey: 'nudge');
    }
    return SceneShortcutScope(
      focusNode: _node,
      autofocus: true,
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): editor.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            editor.redo,
        const SingleActivator(LogicalKeyboardKey.backspace):
            editor.deleteSelection,
        const SingleActivator(LogicalKeyboardKey.delete):
            editor.deleteSelection,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          editor.tool = SceneTool.select;
          editor.clearSelection();
        },
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
            editor.duplicateSelection,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () => editor
            .setSelection([for (var n in editor.doc.root.children) n.name]),
        // The drawing tools, as the letter each is known by in every editor
        // of this kind. Plain letters are safe: a text field with the
        // keyboard keeps them.
        const SingleActivator(LogicalKeyboardKey.keyV): () =>
            editor.tool = SceneTool.select,
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            editor.tool = SceneTool.frame,
        const SingleActivator(LogicalKeyboardKey.keyT): () =>
            editor.tool = SceneTool.text,
        const SingleActivator(LogicalKeyboardKey.keyS): () =>
            editor.tool = SceneTool.shape,
        const SingleActivator(LogicalKeyboardKey.digit3): () =>
            editor.tool = SceneTool.view3d,
        const SingleActivator(LogicalKeyboardKey.keyO): () =>
            editor.tool = SceneTool.orbit,
        ...arrows,
      },
      child: widget.child,
    );
  }
}
