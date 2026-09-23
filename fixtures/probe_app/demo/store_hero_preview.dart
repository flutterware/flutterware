/// The store banner as a preview — one entry, every locale, at the size the
/// store publishes.
///
/// This is the *still* half of the store pair: `previews screenshot
/// --entry=storeHero --knobs=locale=fr --width=1024 --height=500` writes a
/// 1024×500 PNG, which is exactly Google Play's feature graphic, with French
/// copy and the French screenshots on the phones. The video half is the same
/// scene walked by `StoreHeroReveal` — `scene video --scene=StoreHero`.
///
/// The knob is the whole localisation story. A scene's parameters are ordinary
/// Dart parameters, so the locale never reaches the scene at all: it reaches
/// *this*, which asks the catalog for the words and the export tree for the
/// pixels, and hands the scene five strings.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_probes/scene3d_renderers.dart';
import 'package:flutterware_probes/store_hero.dart';

import 'store_hero.scene.dart';

@Preview(name: 'Store banner', group: 'Store')
Widget storeHero() => const _StoreHero();

class _StoreHero extends StatelessWidget {
  const _StoreHero();

  @override
  Widget build(BuildContext context) {
    var locale = context.knobs.string('locale', 'en');
    var front = context.knobs.string('front shot', '01-welcome');
    var back = context.knobs.string('back shot', '02-menu');
    var copy = storeHeroFor(locale, front: front, back: back);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Align(
        alignment: Alignment.topLeft,
        child: SceneView(
          StoreHero(
            headline: copy.headline,
            subtitle: copy.subtitle,
            cta: copy.cta,
            shotFront: copy.front,
            shotBack: copy.back,
          ),
          // The 3D window is drawn by the app, not by the scene core — the
          // same map `demo/scenes.dart` hands the editor's canvas.
          renderers: scene3dRenderers,
        ),
      ),
    );
  }
}

/// The banner mid-reveal: the same scene with `StoreHeroReveal` applied at a
/// moment the knob picks.
///
/// What the video's frames are, one at a time — and the way to judge a beat
/// without encoding 3.2 seconds of mp4 to look at 40ms of it.
@Preview(name: 'Store banner · mid-reveal', group: 'Store')
Widget storeHeroReveal() => const _Reveal();

class _Reveal extends StatefulWidget {
  const _Reveal();

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> {
  // Held in fields: a fresh scene is fresh nodes, and the motion would go on
  // writing its fx onto the ones that went away.
  late final _copy = storeHeroFor('en');
  late final _scene = StoreHero(
    headline: _copy.headline,
    subtitle: _copy.subtitle,
    cta: _copy.cta,
    shotFront: _copy.front,
    shotBack: _copy.back,
  );
  late final _motion = StoreHeroReveal(_scene);

  @override
  Widget build(BuildContext context) {
    var at = context.knobs.int('at (ms)', 1400, min: 0, max: 3200);
    _motion.playable.apply(Duration(milliseconds: at));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Align(
        alignment: Alignment.topLeft,
        child: SceneView(_scene, renderers: scene3dRenderers),
      ),
    );
  }
}
