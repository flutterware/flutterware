import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/externals_file.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/measure.dart';
import 'package:flutterware_app/src/scene/playback.dart';
import 'package:flutterware_app/src/scene/ui/workspace_view.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// The scene workspace over a stage-set editor: the coffee banner fixture,
/// its intro motion, a node selected and the playhead parked mid-clip.
///
/// The renderer is `SceneView` with stub externals, so the canvas has real
/// measured rects without a guest: what a demo needs is the geometry, not the
/// app's theme. This is where the panels are iterated — `previews
/// screenshot` this rather than booting the studio.
///
/// The shape (tree · canvas over timeline · inspector) was chosen 2026-09-01
/// over two alternatives built here as siblings — Design/Animate modes and a
/// timeline drawer — and deleted once the pictures had decided it.
@Preview(name: 'Workspace', group: 'Scene', wrapper: wrapInAppTheme)
Widget workspace() => const _Workspace();

/// The resting state: no motion open, the timeline strip alone.
@Preview(name: 'Workspace, static', group: 'Scene', wrapper: wrapInAppTheme)
Widget workspaceStill() => const _Workspace(motion: false);

class _Workspace extends StatefulWidget {
  const _Workspace({this.motion = true});

  final bool motion;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> with TickerProviderStateMixin {
  late final SceneDocument _doc = coffeeBannerDraft();
  late final SceneEditor _editor = SceneEditor(
    _doc,
    motions: widget.motion ? {'BannerIntro': coffeeIntroDraft()} : const {},
  );
  final _playbacks = <String, ScenePlayback>{};

  ScenePlayback _playbackFor(String motion) => _playbacks.putIfAbsent(
    motion,
    () => ScenePlayback(_editor, motion, vsync: this),
  );

  @override
  void initState() {
    super.initState();
    _editor.select(_doc.nodeNamed('headline'));
    if (widget.motion) {
      _editor.activeMotion = 'BannerIntro';
      _playbackFor('BannerIntro').seek(const Duration(milliseconds: 420));
    }
  }

  @override
  void dispose() {
    for (var playback in _playbacks.values) {
      playback.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SceneWorkspaceView(
    _editor,
    playbackFor: _playbackFor,
    sceneClassName: 'BannerScene',
    externals: describeExternals(_externals),
    content: SceneView.document(
      _doc,
      onMeasured: (rects) => applyMeasuredRects(_doc, rects),
    ),
  );
}

/// Stand-ins for the app's widgets, so the fixture lays out at the sizes
/// the real ones take — declared exactly as an app declares its own, which
/// is also what puts a type and a default beside each argument in the
/// inspector this demo is for.
final _externals = [
  ExternalWidget(
    'DrinkBadge',
    args: [const Arg<double>('size', 56)],
    build: (args) {
      var size = args.number('size') ?? 56;
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0xFF6B4226),
          shape: BoxShape.circle,
        ),
        child: Text('☕', style: TextStyle(fontSize: size * 0.45)),
      );
    },
  ),
  ExternalWidget(
    'Spinner',
    args: [const Arg<double>('size', 36)],
    build: (args) {
      var size = args.number('size') ?? 36;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFD8C9BD), width: 3),
        ),
      );
    },
  ),
  ExternalWidget(
    'OrderButton',
    args: [const Arg<String>('label', 'Order now')],
    build: (args) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8632B),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Text(
        args.text('label') ?? 'Order now',
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ),
    ),
  ),
];
