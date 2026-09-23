import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/context_menu.dart';
import '../../ui/design/design.dart';
import '../../ui/tappable.dart';
import '../../ui/menu.dart';
import '../../ui/tree_row.dart';
import '../editor.dart';
import 'inline_name.dart';
import 'param_pane.dart';
import 'tokens_host.dart';

/// The rest of what the file declares, under the layers: its parameters and
/// its motions, each a section with a count and its own `+`.
///
/// A click OPENS a row in the drawer under the canvas — a motion's
/// timeline, a parameter's pane or table — and the open one is the
/// highlighted one. One verb, because the drawer is independent of the node
/// selection: it stays put while nodes are clicked on the canvas to key
/// them, so there was nothing a separate "select" had to protect. Rename in
/// place with a double-click on the name; right-click for the rest.
class SceneOutlineSections extends StatefulWidget {
  const SceneOutlineSections(
    this.editor, {
    super.key,
    this.sceneClassName,
    this.onOpenMotion,
    this.onOpenParam,
    this.tokens,
  });

  final SceneEditor editor;

  /// The group's libraries and the doors past this file; null hides the
  /// Tokens section's `+` and makes rename and delete local.
  final SceneTokensHost? tokens;

  /// What a new motion animates; null hides the motions' `+`.
  final String? sceneClassName;

  /// Opens a motion's timeline — the workspace's door, which also starts
  /// its playback.
  final ValueChanged<String>? onOpenMotion;

  /// Opens a parameter below the canvas.
  final ValueChanged<String>? onOpenParam;

  @override
  State<SceneOutlineSections> createState() => _SceneOutlineSectionsState();
}

class _SceneOutlineSectionsState extends State<SceneOutlineSections> {
  SceneEditor get editor => widget.editor;
  SceneDocument get doc => editor.doc;

  var _paramsOpen = true;
  var _motionsOpen = true;

  /// The row being renamed in place, if any.
  SceneAside? _renaming;

  /// The last row tapped and when: a second tap on it within the double-tap
  /// window renames. Detected by hand rather than with a double-tap
  /// recognizer, which would hold every single tap for 300ms — selection
  /// has to be instant. The same rule as the layers above.
  (SceneAside, DateTime)? _lastTap;

  @override
  Widget build(BuildContext context) {
    var params = doc.params;
    var motions = editor.motions.keys.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _section(
          context,
          'Parameters',
          params.length,
          open: _paramsOpen,
          onToggle: () => setState(() => _paramsOpen = !_paramsOpen),
          onAdd: (at) => _addParamMenu(context, at),
        ),
        if (_paramsOpen)
          for (var p in params) _paramRow(context, p),
        _section(
          context,
          'Motions',
          motions.length,
          open: _motionsOpen,
          onToggle: () => setState(() => _motionsOpen = !_motionsOpen),
          onAdd: widget.sceneClassName == null
              ? null
              : (_) => _open(editor.addMotion(widget.sceneClassName!)),
        ),
        if (_motionsOpen)
          for (var name in motions) _motionRow(context, name),
        const SizedBox(height: FwSpacing.sm),
      ],
    );
  }

  // The tokens are NOT here. They were, as a listing whose every row
  // teleported you to the library page, and a tree you cannot edit in that
  // leaves when clicked is worse than no tree. What a property may bind to
  // is on the property's own menu in the inspector, with each token's value
  // beside its name; what a token IS is the library page, one back-step
  // away. Removed 2026-09-09.

  /// A section's line: a branch at the root of this outline, drawn as the
  /// layers draw a frame — the chevron folds, and so does the row, since a
  /// section is nothing to select — with its count, and `+` at its end.
  Widget _section(
    BuildContext context,
    String label,
    int count, {
    required bool open,
    required VoidCallback onToggle,
    required void Function(Offset at)? onAdd,
  }) {
    var colors = context.colors;
    var type = context.type;
    return FwTreeRow(
      depth: 0,
      density: TreeRowDensity.roomy,
      open: open,
      onToggleFold: onToggle,
      onTap: onToggle,
      label: Row(
        spacing: FwSpacing.sm,
        children: [
          Text(label, style: type.sectionLabel),
          Text('$count', style: type.caption.copyWith(color: colors.mut2)),
        ],
      ),
      trailing: [
        if (onAdd != null)
          _addButton(
            context,
            'New ${label.toLowerCase().substring(0, label.length - 1)}',
            onAdd,
          ),
      ],
    );
  }

  Widget _addButton(
    BuildContext context,
    String tooltip,
    void Function(Offset at) onAdd,
  ) {
    return Tooltip(
      message: tooltip,
      child: Builder(
        builder: (context) => Tappable(
          onTap: () {
            var box = context.findRenderObject()! as RenderBox;
            onAdd(box.localToGlobal(Offset(0, box.size.height)));
          },
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.xs),
            child: Icon(
              Icons.add,
              size: FwIconSize.sm,
              color: context.colors.mut,
            ),
          ),
        ),
      ),
    );
  }

  Widget _paramRow(BuildContext context, SceneParamDecl p) {
    var aside = ParamAside(p.name);
    var readers = editor.readersOf(p.name).length;
    return _row(
      context,
      aside,
      icon: paramKindIcon(p.kind),
      name: p.name,
      trailing: readers == 0 ? '' : '· $readers',
      tooltip: '${paramKindLabel(p.kind)} · ${p.typeName}',
      onOpen: () => _openParam(p.name),
      menu: () => paramMenu(
        editor,
        p,
        onRename: () => setState(() => _renaming = aside),
        host: widget.tokens,
      ),
      rename: (wanted) => editor.renameParam(p.name, wanted),
    );
  }

  Widget _motionRow(BuildContext context, String name) {
    var aside = MotionAside(name);
    var m = editor.motions[name]!;
    var seconds = m.durationOf(m.timeline).inMilliseconds / 1000;
    return _row(
      context,
      aside,
      icon: Icons.play_arrow_outlined,
      name: name,
      trailing: '${seconds.toStringAsFixed(2)}s',
      tooltip: '${m.groups.length} groups · on ${m.sceneClassName}',
      onOpen: () => _open(name),
      menu: () => [
        MenuItem(
          'Rename',
          icon: Icons.edit_outlined,
          shortcut: 'double-click',
          onSelected: () => setState(() => _renaming = aside),
        ),
        const MenuDivider(),
        MenuItem(
          'Delete $name',
          icon: Icons.close,
          danger: true,
          onSelected: () => editor.removeMotion(name),
        ),
      ],
      rename: (wanted) => editor.renameMotion(name, wanted),
    );
  }

  void _open(String motion) {
    if (widget.onOpenMotion case var open?) {
      open(motion);
    } else {
      editor.activeMotion = motion;
    }
  }

  void _openParam(String name) {
    if (widget.onOpenParam case var open?) {
      open(name);
    } else {
      editor.openParam = name;
    }
  }

  Widget _row(
    BuildContext context,
    SceneAside aside, {
    int depth = 1,
    required IconData icon,
    required String name,
    required String trailing,
    SceneColor? swatch,
    required String tooltip,
    required VoidCallback onOpen,
    required List<MenuEntry> Function() menu,
    required void Function(String wanted) rename,
  }) {
    var colors = context.colors;
    var open = editor.drawer == aside;
    var renaming = _renaming == aside;
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          showContextMenu(context, d.globalPosition, menu()),
      child: FwTreeRow(
        // Under the section's line, whose chevron is in the leading slot
        // the way a frame's is; the kind's icon takes that slot here.
        depth: depth,
        density: TreeRowDensity.roomy,
        selected: open,
        onTap: () {
          var now = DateTime.now();
          var again =
              _lastTap?.$1 == aside &&
              now.difference(_lastTap!.$2) < kDoubleTapTimeout;
          _lastTap = (aside, now);
          if (again) {
            setState(() => _renaming = aside);
            return;
          }
          onOpen();
        },
        leading: Icon(
          icon,
          size: FwIconSize.sm,
          color: open ? colors.accentDark : colors.mut,
        ),
        label: renaming
            ? InlineNameField(
                initial: name,
                dense: true,
                style: context.type.body,
                onCommit: (wanted) {
                  try {
                    rename(wanted);
                  } on ArgumentError catch (e) {
                    return '${e.message}';
                  }
                  setState(() => _renaming = null);
                  return null;
                },
                onCancel: () => setState(() => _renaming = null),
              )
            : Tooltip(
                message: tooltip,
                waitDuration: const Duration(milliseconds: 600),
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.body.copyWith(
                    color: open ? colors.accentDark : colors.ink,
                  ),
                ),
              ),
        trailing: [
          if (swatch != null)
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: swatch.flutter,
                shape: BoxShape.circle,
                border: Border.all(color: colors.line),
              ),
            ),
          if (trailing.isNotEmpty)
            // Capped, not flexed: a flex would split the row with the name.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 88),
              child: Text(
                trailing,
                overflow: TextOverflow.ellipsis,
                style: context.type.caption.copyWith(color: colors.mut2),
              ),
            ),
        ],
      ),
    );
  }

  void _addParamMenu(BuildContext context, Offset at) {
    showContextMenu(context, at, [
      const MenuHeader('New parameter'),
      for (var (kind, label, type) in paramKinds)
        MenuItem(
          label,
          shortcut: type,
          onSelected: () {
            var name = editor.freeParamName(kind.name);
            editor.addParam(name, kind);
            _openParam(name);
            setState(() {
              _paramsOpen = true;
              _renaming = ParamAside(name);
            });
          },
        ),
    ]);
  }
}
