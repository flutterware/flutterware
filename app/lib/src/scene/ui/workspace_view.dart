import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../editor.dart';
import '../type_axes.dart';
import '../externals_file.dart';
import '../playback.dart';
import '../shader_library.dart';
import 'canvas.dart';
import 'drawer_header.dart';
import 'inspector.dart';
import 'list_table.dart';
import 'param_pane.dart';
import 'shortcuts.dart';
import 'timeline.dart';
import 'tokens_host.dart';
import 'tree_panel.dart';

/// The scene workspace: tree · canvas over timeline · inspector.
///
/// One surface, decided 2026-09-01 over two alternatives (Design/Animate
/// modes, a timeline drawer) built as catalog demos and looked at. The
/// argument that won: selection is one set across the tree, the canvas and
/// the lanes — a timeline row *is* a scene node — so nothing that shows the
/// nodes should leave when the keys arrive.
///
/// The scene is static first: the timeline appears only once a motion is
/// opened from the strip under the canvas, and a scene may have several.
///
/// Tree and canvas share the editing focus scope; the timeline has its own
/// (an arrow means something else to a key); the inspector sits outside both,
/// so its fields keep every keystroke.
class SceneWorkspaceView extends StatefulWidget {
  const SceneWorkspaceView(
    this.editor, {
    super.key,
    this.content,
    required this.playbackFor,
    this.sceneClassName,
    this.status,
    this.onEnterNested,
    this.canvasTrailing = const [],
    this.pane,
    this.externals = const [],
    this.axesFor,
    this.packageRoot,
    this.shaders,
    this.tokens,
  });

  final SceneEditor editor;

  /// The package the open file belongs to — where the inspector finds the
  /// project's model files for a row that picks one.
  final String? packageRoot;

  /// The package's declared shaders — see [SceneInspector.shaders].
  final SceneShaders? shaders;

  /// The group's libraries and the doors past this file — see
  /// [SceneOutlineSections.tokens].
  final SceneTokensHost? tokens;

  /// The widgets the app declares — see [SceneInspector.externals].
  final List<ExternalWidgetDecl> externals;

  /// What a family's variable axes are — see [SceneInspector.axesFor].
  final AxesLookup? axesFor;

  /// The renderer, sized to the artboard — see [SceneCanvas.content].
  final Widget? content;

  /// The playback for one of the editor's motions, by name — made once and
  /// kept by the host, because a playback owns a ticker.
  final ScenePlayback Function(String motion) playbackFor;

  /// What a new motion animates; null hides "New motion".
  final String? sceneClassName;

  final ValueListenable<String>? status;

  /// Drill into a nested scene — the workspace's `enter`, when there is one.
  final ValueChanged<SceneNode>? onEnterNested;

  /// Controls the host wants on the canvas bar's right — a guest reload.
  final List<Widget> canvasTrailing;

  /// A pane-sized picture under the artboard — see [SceneCanvas.pane].
  final Widget Function(
    BuildContext context,
    Matrix4 view,
    Size pane,
    Size artboard,
  )?
  pane;

  static const treeWidth = 230.0;
  static const inspectorWidth = 290.0;

  @override
  State<SceneWorkspaceView> createState() => _SceneWorkspaceViewState();
}

class _SceneWorkspaceViewState extends State<SceneWorkspaceView> {
  /// Leaves the open motion: playback stops (the scene shows as authored),
  /// recording ends, no chip is active. The chevron; there is no folding a
  /// motion away while it stays on the picture — static first.
  void _closeMotion() {
    var active = editor.activeMotion;
    if (active == null) return;
    widget.playbackFor(active).stop();
    editor.autoKey = false;
    editor.activeMotion = null;
  }

  /// Opens a parameter — its pane, or a list's table: the motion, if one is
  /// open, closes first — the drawer holds one thing.
  void _openParam(String name) {
    _closeMotion();
    editor.openParam = name;
  }

  void _openMotion(String name) {
    editor.openParam = null;
    editor.activeMotion = name;
    // A motion that was closed comes back on the picture; one already open
    // is unchanged.
    widget.playbackFor(name).apply();
  }

  void _closeDrawer() {
    _closeMotion();
    editor.openParam = null;
  }

  /// How tall the drawer is, dragged by hand. Null until dragged: two fifths
  /// of the column, which is where the timeline always sat.
  double? _drawerHeight;

  SceneEditor get editor => widget.editor;

  @override
  Widget build(BuildContext context) {
    var line = context.colors.line;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: EditorShortcuts(
            editor,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: SceneWorkspaceView.treeWidth,
                  child: SceneTreePanel(
                    editor,
                    onEnterNested: widget.onEnterNested,
                    sceneClassName: widget.sceneClassName,
                    onOpenMotion: _openMotion,
                    onOpenParam: _openParam,
                    tokens: widget.tokens,
                  ),
                ),
                Container(width: 1, color: line),
                Expanded(
                  child: AnimatedBuilder(
                    animation: editor.listenable,
                    builder: (context, _) => LayoutBuilder(
                      builder: (context, constraints) {
                        var open = editor.drawer;
                        var shown = open != null && !editor.drawerCollapsed;
                        var height =
                            (_drawerHeight ?? constraints.maxHeight * 0.4)
                                .clamp(120.0, constraints.maxHeight - 160);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SceneCanvas(
                                editor,
                                content: widget.content,
                                status: widget.status,
                                onEnterNested: widget.onEnterNested,
                                trailing: widget.canvasTrailing,
                                pane: widget.pane,
                              ),
                            ),
                            Container(height: 1, color: line),
                            SceneDrawerHeader(
                              editor,
                              tokens: widget.tokens,
                              onClose: _closeDrawer,
                              onPick: (pick) => switch (pick) {
                                MotionAside(:var name) => _openMotion(name),
                                ParamAside(:var name) => _openParam(name),
                              },
                            ),
                            if (shown) ...[
                              // The divider is the handle: drag it to trade
                              // canvas for drawer, which is how twelve rows
                              // or a long timeline get their room.
                              MouseRegion(
                                cursor: SystemMouseCursors.resizeRow,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragUpdate: (d) => setState(() {
                                    _drawerHeight = height - d.delta.dy;
                                  }),
                                  child: Container(
                                    height: 5,
                                    alignment: Alignment.center,
                                    child: Container(height: 1, color: line),
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: height,
                                child: switch (open) {
                                  MotionAside(:var name) => SceneTimeline(
                                    editor,
                                    widget.playbackFor(name),
                                    axesFor: widget.axesFor,
                                    packageRoot: widget.packageRoot,
                                  ),
                                  ParamAside(:var name) =>
                                    editor.doc.paramNamed(name)?.kind ==
                                            SceneParamKind.list
                                        ? SceneListTable(editor, name)
                                        : SceneParamPane(editor, name),
                                },
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: line),
        SizedBox(
          width: SceneWorkspaceView.inspectorWidth,
          // The inspector shows whatever is selected now; the other panels
          // subscribe for themselves, this one is stateless over the editor.
          child: AnimatedBuilder(
            animation: Listenable.merge([
              editor.listenable,
              editor.doc.listenable,
            ]),
            builder: (context, _) => SceneInspector(
              editor,
              externals: widget.externals,
              axesFor: widget.axesFor,
              packageRoot: widget.packageRoot,
              shaders: widget.shaders,
              onOpenParam: _openParam,
              onEnterNested: widget.onEnterNested,
            ),
          ),
        ),
      ],
    );
  }
}
