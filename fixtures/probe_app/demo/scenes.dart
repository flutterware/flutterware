//@flutterware:scenes=1
// widgets   the app's widgets a scene may place, with their arguments
// exports   the app's own values, named for the scenes — any type
// libraries the *.tokens.dart these scenes read, imported above
// wrap      what the canvas is mounted under — the app's theme
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_probes/model_view.dart' as v3d;
import 'package:flutterware_probes/scene3d_renderers.dart' as v3d;
import 'package:flutterware_probes/scene_widgets.dart' as app;
import 'package:flutterware_probes/shot_image.dart' as shots;

import 'brand.tokens.dart';

final scenes = SceneGroup(
  libraries: [brandTokens],
  widgets: [
    ExternalWidget(
      'DrinkBadge',
      args: [const Arg<double>('size', 56)],
      build: (a) => app.Badge(glyph: '☕', size: a.number('size') ?? 56),
    ),
    ExternalWidget(
      'Spinner',
      args: [const Arg<double>('size', 36)],
      build: (a) => app.Spinner(size: a.number('size') ?? 36),
    ),
    // A 3D view: one asset, an orbit camera and a clip, every knob a number
    // the timeline can key. See lib/model_view.dart for what it cannot carry.
    ExternalWidget(
      'ModelView',
      args: [
        const Arg<String>('asset', 'assets/models/probe_rig.glb'),
        const Arg<double>('yaw', 0),
        const Arg<double>('pitch', 10),
        const Arg<double>('distance', 5),
        const Arg<double>('fov', 45),
        const Arg<String>('clip', 'Open'),
        const Arg<double>('clipTime', 0),
      ],
      build: (a) => v3d.ModelView(
        asset: a.text('asset') ?? 'assets/models/probe_rig.glb',
        yaw: a.number('yaw') ?? 0,
        pitch: a.number('pitch') ?? 10,
        distance: a.number('distance') ?? 5,
        fov: a.number('fov') ?? 45,
        clip: a.text('clip') ?? 'Open',
        clipTime: a.number('clipTime') ?? 0,
      ),
    ),
    // The app's own pixels, by path. A store scene's screenshots arrive
    // through this: `path` is bound to a scene parameter, so one scene
    // renders every locale's export without the file knowing any of them.
    ExternalWidget(
      'Shot',
      args: [const Arg<String>('path', '')],
      build: (a) => shots.ShotImage(a.text('path') ?? ''),
    ),
    ExternalWidget(
      'OrderButton',
      // `style` is the app's own object: a scene fills it with an exported
      // token or leaves it to the widget, and the editor never sees inside.
      args: [
        const Arg<String>('label', 'Order now'),
        const Arg<ButtonStyle>('style'),
      ],
      build: (a) => app.CtaButton(
        label: a.text('label') ?? 'Order now',
        style: a.raw('style') as ButtonStyle?,
      ),
    ),
  ],
  exports: [
    // The app's own values, re-exported by name: a scene reads
    // `tokens.shopBrand` as a colour and `tokens.shopSubtitle` as a text
    // style, the editor offers each where its type fits, and this process
    // draws them — the italic in the subtitle is the app's, unnamed in the
    // editor and on the canvas all the same.
    const Token<Color>('shopBrand', app.brandColor),
    const Token<TextStyle>('shopSubtitle', app.subtitleStyle),
    // The app's own look for its call to action: named here, filled into
    // `OrderButtonArgs(style: tokens.ctaStyle)` by a scene, built by this
    // process — only this app ever sees inside a ButtonStyle.
    Token<ButtonStyle>(
      'ctaStyle',
      FilledButton.styleFrom(
        backgroundColor: const Color(0xFFE8632B),
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
      ),
    ),
  ],
  // How the 3D kinds are drawn: the engine lives in lib/scene3d_renderers.dart,
  // and the core draws a named placeholder without it.
  renderers: v3d.scene3dRenderers,
  // The app's own look — what the editor canvas inherits by construction.
  wrap: (child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF8C5A3C)),
    home: child,
  ),
);
