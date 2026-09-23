import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/context_menu.dart';
import '../../ui/design/design.dart';
import '../../ui/menu.dart';
import '../../ui/tappable.dart';
import '../editor.dart';
import 'inline_name.dart';
import 'param_pane.dart';
import 'tokens_host.dart';

/// The line above the drawer under the canvas, naming the one thing that is
/// open there — a motion's timeline, a parameter's pane or table — and
/// nothing else.
///
/// Left, the chevron folds the drawer away without closing it: the header
/// stays as a one-line reminder, the motion stays on the picture. Then the
/// kind, the name with a switcher among its siblings, and the item's own
/// facts. Right, the item's menu and the cross that closes it. Nothing
/// open, it says where to go. Never chips: twelve motions are twelve rows in
/// the tree, and one name here.
class SceneDrawerHeader extends StatefulWidget {
  const SceneDrawerHeader(
    this.editor, {
    super.key,
    required this.onClose,
    required this.onPick,
    this.tokens,
  });

  final SceneEditor editor;

  /// The group's libraries and the doors past this file, for a token's
  /// facts, menu and rename.
  final SceneTokensHost? tokens;

  /// Closes whatever is open — for a motion, the scene as authored.
  final VoidCallback onClose;

  /// Opens a motion (starting its playback) or a parameter.
  final ValueChanged<SceneAside> onPick;

  @override
  State<SceneDrawerHeader> createState() => _SceneDrawerHeaderState();
}

class _SceneDrawerHeaderState extends State<SceneDrawerHeader> {
  SceneEditor get editor => widget.editor;
  bool _renaming = false;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var open = editor.drawer;
    var active = open?.name;
    var isMotion = open is MotionAside;
    var thing = switch (open) {
      MotionAside() => 'timeline',
      ParamAside(:var name)
          when editor.doc.paramNamed(name)?.kind == SceneParamKind.list =>
        'table',
      _ => 'parameter',
    };
    var kindWord = switch (open) {
      MotionAside() => 'Motion',
      _ => 'Parameter',
    };
    var collapsed = editor.drawerCollapsed;
    return Container(
      height: 32,
      color: colors.panel,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
      child: Row(
        spacing: FwSpacing.sm,
        children: [
          _HeaderButton(
            tooltip: open == null
                ? 'Open a motion to see its timeline'
                : collapsed
                ? 'Show the $thing'
                : 'Fold the $thing away — the '
                      '${isMotion ? 'motion' : 'parameter'} stays open',
            icon: active == null || collapsed
                ? Icons.keyboard_arrow_up
                : Icons.keyboard_arrow_down,
            size: FwIconSize.md,
            color: active == null ? colors.mut3 : colors.ink,
            onTap: active == null
                ? null
                : (_) => editor.drawerCollapsed = !collapsed,
          ),
          if (open == null || active == null)
            Text(
              'Open a motion or a parameter from the tree  ›',
              style: type.caption.copyWith(color: colors.mut2),
            )
          else ...[
            Text(
              '$kindWord ·',
              style: type.caption.copyWith(color: colors.mut2),
            ),
            GestureDetector(
              onDoubleTap: () => setState(() => _renaming = true),
              onSecondaryTapUp: (d) =>
                  showContextMenu(context, d.globalPosition, _menu(open)),
              child: _renaming
                  ? SizedBox(
                      width: 160,
                      child: InlineNameField(
                        initial: active,
                        dense: true,
                        style: type.bodyStrong,
                        onCommit: (wanted) => _rename(open, wanted),
                        onCancel: () => setState(() => _renaming = false),
                      ),
                    )
                  : Text(active, style: type.bodyStrong),
            ),
            if (_openable().length > 1)
              _HeaderButton(
                tooltip: 'Switch to another motion or parameter',
                icon: Icons.arrow_drop_down,
                size: FwIconSize.md,
                color: colors.mut,
                onTap: (at) => showContextMenu(context, at, _switcher(open)),
              ),
            const SizedBox(width: FwSpacing.sm),
            if (open is ParamAside)
              // The readers are a menu off the facts: each a step to the
              // node, and the ones in other scenes named. Not a column of
              // the pane — the pane is the value.
              Tooltip(
                message: 'Who reads it — click to step to a reader',
                waitDuration: const Duration(milliseconds: 600),
                child: Builder(
                  builder: (context) => Tappable(
                    onTap: () {
                      var box = context.findRenderObject()! as RenderBox;
                      var at = box.localToGlobal(Offset(0, box.size.height));
                      showContextMenu(context, at, _readersMenu(open));
                    },
                    borderRadius: BorderRadius.circular(
                      context.radii.radiusSmall,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FwSpacing.xs,
                        vertical: FwSpacing.xxs,
                      ),
                      child: Text(
                        '${_facts(open)} ▾',
                        style: type.caption.copyWith(color: colors.mut2),
                      ),
                    ),
                  ),
                ),
              )
            else
              Text(
                _facts(open),
                style: type.caption.copyWith(color: colors.mut2),
              ),
            const Spacer(),
            _HeaderButton(
              tooltip: '$kindWord menu',
              icon: Icons.more_horiz,
              size: FwIconSize.md,
              color: colors.mut,
              onTap: (at) => showContextMenu(context, at, _menu(open)),
            ),
            _HeaderButton(
              tooltip: isMotion
                  ? 'Close the motion — the scene as authored'
                  : 'Close the $thing',
              icon: Icons.close,
              size: FwIconSize.sm,
              color: colors.mut,
              onTap: (_) => widget.onClose(),
            ),
          ],
        ],
      ),
    );
  }

  String _facts(SceneAside open) {
    switch (open) {
      case MotionAside(:var name):
        var m = editor.motions[name]!;
        var seconds = m.durationOf(m.timeline).inMilliseconds / 1000;
        var groups = m.groups.length;
        return '${seconds.toStringAsFixed(2)}s · '
            '$groups ${groups == 1 ? 'group' : 'groups'}';
      case ParamAside(:var name):
        var p = editor.doc.paramNamed(name)!;
        var readers = editor.readersOf(name).length;
        var what = p.kind == SceneParamKind.list
            ? '${p.items.length} ${p.items.length == 1 ? 'item' : 'items'}'
            : '${paramKindLabel(p.kind)} · ${p.typeName}';
        return '$what · read by $readers';
    }
  }

  /// Who reads the open parameter: each reader a step to its node.
  List<MenuEntry> _readersMenu(SceneAside open) {
    var readers = switch (open) {
      ParamAside(:var name) => editor.readersOf(name),
      _ => const <(SceneNode, String)>[],
    };
    return [
      MenuHeader(readers.isEmpty ? 'Read by nothing here' : 'Read by'),
      if (readers.isEmpty)
        const MenuItem('Right-click a property of a node to bind it'),
      for (var (node, prop) in readers)
        MenuItem(
          '${node.name} · $prop',
          icon: Icons.subdirectory_arrow_right,
          onSelected: () => editor.select(node),
        ),
    ];
  }

  String? _rename(SceneAside open, String wanted) {
    try {
      switch (open) {
        case MotionAside(:var name):
          editor.renameMotion(name, wanted);
        case ParamAside(:var name):
          editor.renameParam(name, wanted);
      }
    } on ArgumentError catch (e) {
      return e.message as String?;
    }
    setState(() => _renaming = false);
    return null;
  }

  /// The open item's own menu — the same one its row in the tree offers.
  List<MenuEntry> _menu(SceneAside open) {
    void rename() => setState(() => _renaming = true);
    switch (open) {
      case ParamAside(:var name):
        return paramMenu(
          editor,
          editor.doc.paramNamed(name)!,
          onRename: rename,
          host: widget.tokens,
        );
      case MotionAside(:var name):
        return [
          MenuItem(
            'Rename',
            icon: Icons.edit_outlined,
            shortcut: 'double-click',
            onSelected: rename,
          ),
          const MenuDivider(),
          MenuItem(
            'Delete $name',
            icon: Icons.close,
            danger: true,
            onSelected: () => editor.removeMotion(name),
          ),
        ];
    }
  }

  /// Everything that can be open here: the motions, then the parameters.
  List<SceneAside> _openable() => [
    for (var name in editor.motions.keys) MotionAside(name),
    for (var p in editor.doc.params) ParamAside(p.name),
  ];

  List<MenuEntry> _switcher(SceneAside open) {
    var all = _openable();
    var motions = all.whereType<MotionAside>().toList();
    var params = all.whereType<ParamAside>().toList();
    return [
      if (motions.isNotEmpty) const MenuHeader('Motions'),
      for (var m in motions)
        MenuItem(
          m.name,
          icon: m == open ? Icons.check : null,
          onSelected: m == open ? null : () => widget.onPick(m),
        ),
      if (params.isNotEmpty) const MenuHeader('Parameters'),
      for (var p in params)
        MenuItem(
          p.name,
          icon: p == open ? Icons.check : null,
          onSelected: p == open ? null : () => widget.onPick(p),
        ),
    ];
  }
}

/// An icon that answers the pointer: hover wash, click cursor, a tooltip,
/// and — for the ones that open a menu — where its bottom-left corner is,
/// so the menu drops from the button rather than from wherever the pointer
/// happened to be. A bare icon in a [GestureDetector] had none of that, and
/// sat inside the name's double-tap detector, which held every press until
/// it was sure it was not the first half of a double.
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.color,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final Color color;

  /// Called with the global position of the button's bottom-left corner.
  final void Function(Offset at)? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Tappable(
      onTap: onTap == null
          ? null
          : () {
              var box = context.findRenderObject()! as RenderBox;
              onTap!(box.localToGlobal(Offset(0, box.size.height)));
            },
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xs),
        child: Icon(icon, size: size, color: color),
      ),
    ),
  );
}
