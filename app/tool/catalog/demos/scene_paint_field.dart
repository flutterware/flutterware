import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/shader_library.dart';
import 'package:flutterware_app/src/scene/ui/paint_field.dart';
import 'package:flutterware_app/src/ui/design/design.dart';

import 'app_theme.dart';

/// One paint field per kind a pass can be painted with, at the width the
/// inspector gives a layer's detail — each live, so a kind can be switched
/// and a stop dragged in the preview.
///
/// What it answers is whether the five shapes read as one control: the
/// picker, then a colour, a bar or a shader, then the numbers that shape it,
/// at one type size down the column. The shader's uniforms come from a fixed
/// reflection — a ranged float, a colour, a plain vec2, and the renderer's
/// own `uSize`, which gets no control.
@Preview(name: 'Paint field', group: 'Scene', wrapper: wrapInAppTheme)
Widget scenePaintField() => const _Paints();

@Preview(name: 'Paint field · dark', group: 'Scene', wrapper: wrapInDarkTheme)
Widget scenePaintFieldDark() => const _Paints();

class _Paints extends StatefulWidget {
  const _Paints();

  @override
  State<_Paints> createState() => _PaintsState();
}

class _PaintsState extends State<_Paints> {
  final _shaders = FixedSceneShaders({
    'shaders/foil.frag': const SceneShaderInfo(
      key: 'shaders/foil.frag',
      uniforms: [
        SceneShaderUniform(name: 'uSize', size: 2, location: 0),
        SceneShaderUniform(
          name: 'uAngle',
          size: 1,
          location: 1,
          range: (0, 6.283),
          defaults: [0.6],
        ),
        SceneShaderUniform(
          name: 'uShine',
          size: 3,
          location: 2,
          isColor: true,
          defaults: [1, 0.85, 0.4],
        ),
        SceneShaderUniform(name: 'uOffset', size: 2, location: 3),
      ],
    ),
    'shaders/plain.frag': const SceneShaderInfo(key: 'shaders/plain.frag'),
  });

  final _paints = <ScenePaint?>[
    const SolidPaint(SceneColor(0xFFFFC400)),
    const LinearPaint(
      colors: [
        SceneColor(0xFFFFF3B0),
        SceneColor(0xFFFFB020),
        SceneColor(0xFF8A4B00),
      ],
      stops: [0, 0.55, 1],
    ),
    const RadialPaint(
      colors: [SceneColor(0xFFFFFFFF), SceneColor(0x00FFFFFF)],
      radius: 0.8,
    ),
    const SweepPaint(
      colors: [
        SceneColor(0xFFFF2D95),
        SceneColor(0xFF00E5FF),
        SceneColor(0xFFFF2D95),
      ],
    ),
    const ShaderPaint(
      'shaders/foil.frag',
      uniforms: {
        'uAngle': [0.6],
        'uShine': [1, 0.85, 0.4],
        'uOffset': [0, 0.25],
      },
    ),
  ];

  @override
  void dispose() {
    _shaders.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Wrap(
        spacing: FwSpacing.xxl,
        runSpacing: FwSpacing.xxl,
        children: [
          for (var i = 0; i < _paints.length; i++)
            SizedBox(
              width: 240,
              child: ScenePaintField(
                paint: _paints[i],
                own: const SceneColor(0xFFFFFFFF),
                shaders: _shaders,
                onChanged: (next, {required label, mergeKey}) =>
                    setState(() => _paints[i] = next),
              ),
            ),
        ],
      ),
    ),
  );
}
