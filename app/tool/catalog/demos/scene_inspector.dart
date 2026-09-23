import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/ui/inspector.dart';
import 'package:flutterware_app/src/ui/design/design.dart';

import 'app_theme.dart';

/// The scene inspector, at the width it has in the studio, with a text node
/// selected and a little of everything on it: a parameter binding, a token
/// binding, a shared style two properties are inherited from and one is
/// typed over, a paint stack, and the two sections that fold.
///
/// This is the page to look at when changing the panel. The question it
/// answers — the one that needs pixels and cannot be read off the code — is
/// whether a reader can tell, at a glance, where each value comes from and
/// which of these fields will do something if they drag it.
@Preview(name: 'Scene inspector', group: 'Scene', wrapper: wrapInAppTheme)
Widget sceneInspector() => _Inspector(_editor());

@Preview(
  name: 'Scene inspector · dark',
  group: 'Scene',
  wrapper: wrapInDarkTheme,
)
Widget sceneInspectorDark() => _Inspector(_editor());

class _Inspector extends StatelessWidget {
  const _Inspector(this.editor);

  final SceneEditor editor;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: SizedBox(width: 290, child: SceneInspector(editor)),
  );
}

SceneEditor _editor() {
  var doc = coffeeBannerDraft();
  doc.params.add(
    SceneParamDecl(
      'headlineText',
      SceneParamKind.string,
      'Fresh coffee, faster',
    ),
  );
  doc.tokens.addAll([
    SceneTokenDecl('brand', SceneParamKind.color, const SceneColor(0xFFE8632B)),
    SceneTokenDecl.style(
      'display',
      const SceneTextStyle(
        fontSize: 54,
        weight: SceneFontWeight.w700,
        // A treatment is a style property like any other: the panel says
        // where the stack came from in the same words it uses on a row.
        layers: [
          StrokeLayer(width: 8, paint: SolidPaint(SceneColor(0xFF120720))),
          FillLayer(),
        ],
      ),
    ),
  ]);
  var headline = doc.nodeNamed('headline')! as TextNode;
  headline.bindings['text'] = const ParamRef('headlineText');
  headline.bindings['style'] = const StyleRef('display');
  headline.bindings['color'] = const TokenRef('brand');
  headline.color = const SceneColor(0xFFE8632B);
  // Typed over the style: the row says so, and offers the way back.
  headline.fontSize = 66;
  headline.layers = [
    const StrokeLayer(width: 8, paint: SolidPaint(SceneColor(0xFF120720))),
    const FillLayer(),
  ];
  var editor = SceneEditor(doc);
  editor.select(headline);
  return editor;
}
