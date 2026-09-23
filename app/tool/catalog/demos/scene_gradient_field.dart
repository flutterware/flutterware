import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/ui/gradient_field.dart';
import 'package:flutterware_app/src/ui/design/design.dart';

import 'app_theme.dart';

/// A gradient's stops, at the width the inspector gives a paint pass — live,
/// so a stop can be dragged, added and taken away in the preview.
///
/// The question it answers is whether the handles read as belonging to the
/// bar above them, and whether the selected one is obvious in both themes.
@Preview(name: 'Gradient stops', group: 'Scene', wrapper: wrapInAppTheme)
Widget sceneGradientField() => const _Stops();

@Preview(
  name: 'Gradient stops · dark',
  group: 'Scene',
  wrapper: wrapInDarkTheme,
)
Widget sceneGradientFieldDark() => const _Stops();

class _Stops extends StatefulWidget {
  const _Stops();

  @override
  State<_Stops> createState() => _StopsState();
}

class _StopsState extends State<_Stops> {
  SceneGradient _gradient = const LinearPaint(
    colors: [
      SceneColor(0xFFFFF3B0),
      SceneColor(0xFFFFB020),
      SceneColor(0xFF8A4B00),
    ],
    stops: [0, 0.55, 1],
  );

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: SizedBox(
          width: 250,
          child: SceneGradientField(
            gradient: _gradient,
            onChanged: (next, {required label, mergeKey}) =>
                setState(() => _gradient = next),
          ),
        ),
      ),
    ),
  );
}
