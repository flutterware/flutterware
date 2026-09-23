import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import 'arcade_poster.scene.dart';

/// A scene mounted as a preview, which is how a poster gets looked at at the
/// size it will be printed rather than at whatever fraction fits a pane.
///
/// The scene itself is `arcade_poster.scene.dart` — ordinary Dart the editor
/// owns, instantiated here like any other widget, with its parameters filled
/// the way a caller would fill them.
@Preview(name: 'Arcade poster', group: 'Scene')
Widget arcadePoster() => const _Poster();

class _Poster extends StatelessWidget {
  const _Poster();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: const Color(0xFF0C0714),
      child: Align(
        alignment: Alignment.topLeft,
        child: SceneView(ArcadePoster()),
      ),
    ),
  );
}

/// The same poster with its parameters answered differently — the point of a
/// scene having parameters at all.
@Preview(name: 'Arcade poster · win', group: 'Scene')
Widget arcadePosterWin() => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: ColoredBox(
    color: const Color(0xFF0C0714),
    child: Align(
      alignment: Alignment.topLeft,
      child: SceneView(
        ArcadePoster(
          title: 'new record',
          kicker: 'enter your initials',
          score: '00312750',
          neon: const SceneColor(0xFF39FF14),
        ),
      ),
    ),
  ),
);

/// The poster mid-breath: the same scene with its motion applied at a time
/// the knob picks, so the weight axis can be looked at anywhere along its
/// travel rather than only where it rests.
///
/// The headline is set in Archivo and its `wght` is a motion track, which is
/// the whole point of an axis over a named weight: 900 to 240 and back is a
/// continuum, and no set of static cuts has the frames in between.
@Preview(name: 'Arcade poster · mid-breath', group: 'Scene')
Widget arcadePosterBreathing() => const _Breathing();

class _Breathing extends StatefulWidget {
  const _Breathing();

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing> {
  // Held in fields, not built in `build`: a fresh scene is fresh nodes, and
  // the player would go on writing its fx onto the ones that went away.
  late final _scene = ArcadePoster();
  late final _motion = ArcadeAttract(_scene);

  @override
  Widget build(BuildContext context) {
    var at = context.knobs.int('at (ms)', 900, min: 0, max: 1800);
    _motion.playable.apply(Duration(milliseconds: at));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: const Color(0xFF0C0714),
        child: Align(alignment: Alignment.topLeft, child: SceneView(_scene)),
      ),
    );
  }
}
