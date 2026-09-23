import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

/// A variable face at several points of its two axes — the thing a set of
/// static weights cannot do.
///
/// It lives HERE rather than in the studio's own catalog because that is
/// where the font is: a preview renders with its package's declared fonts,
/// and Archivo is this example's. It is a picture rather than a test because
/// that is what it answers — does the width axis read as another face or as
/// a squashed one, and is the weight ramp smooth where a static family steps.
///
/// Archivo, by the Omnibus-Type authors, under the SIL Open Font License 1.1.
@Preview(name: 'Variable axes', group: 'Scene')
Widget variableAxes() => const _Axes();

const _ink = SceneColor(0xFF120720);
const _paper = SceneColor(0xFFF7F2EC);

/// What each specimen is called, and where on the two axes it sits.
const _specimens = <(String, double, double)>[
  ('wght 100', 100, 100),
  ('wght 400', 400, 100),
  ('wght 900', 900, 100),
  ('wdth 62', 700, 62),
  ('wdth 125', 700, 125),
];

class _Axes extends StatelessWidget {
  const _Axes();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: Color(_paper.argb),
      child: Align(
        alignment: Alignment.topLeft,
        child: SceneView.document(_sheet()),
      ),
    ),
  );
}

SceneDocument _sheet() {
  var rows = <SceneNode>[];
  for (var (name, wght, wdth) in _specimens) {
    rows.add(
      FrameNode(name: 'row_$name', layout: NodeLayout.column)
        ..crossAlign = SceneCrossAxisAlignment.start
        ..children.addAll([
          TextNode(
            name,
            name: 'label_$name',
            style: const SceneTextStyle(
              fontFamily: 'Archivo',
              fontSize: 11,
              letterSpacing: 1.5,
              textCase: SceneTextCase.upper,
              color: SceneColor(0xFF8A7F92),
            ),
          ),
          TextNode(
            'Archivo',
            name: 'word_$name',
            style: SceneTextStyle(
              fontFamily: 'Archivo',
              fontSize: 56,
              color: _ink,
              axes: {'wght': wght, 'wdth': wdth},
            ),
          ),
        ]),
    );
  }
  return SceneDocument(
    FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 380
      ..height = 560
      ..fill = _paper
      ..crossAlign = SceneCrossAxisAlignment.start
      ..padding = const SceneEdges.all(24)
      ..gap = 14
      ..children.addAll(rows),
  );
}
