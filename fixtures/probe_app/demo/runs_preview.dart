import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

/// A bold word inside a paragraph that still wraps as one paragraph.
///
/// The point a picture makes and a test cannot: the runs are laid out
/// together, so the line breaks fall where the whole sentence says they do —
/// not where two nodes beside each other would put them. Set in Archivo, so
/// the heavy run is the same face at a different point of its weight axis
/// rather than a second file.
@Preview(name: 'Rich runs', group: 'Scene')
Widget richRuns() => const _Runs();

const _ink = SceneColor(0xFF1C1526);
const _paper = SceneColor(0xFFFDFAF5);
const _brand = SceneColor(0xFFE8632B);

class _Runs extends StatelessWidget {
  const _Runs();

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
  var paragraph = TextNode.rich(
    [
      const TextRun('Order ahead, skip the line, and earn '),
      const TextRun(
        'a free coffee',
        style: SceneTextStyle(
          weight: SceneFontWeight.w700,
          color: _brand,
          axes: {'wght': 800},
        ),
      ),
      const TextRun(' on every tenth cup — no card, no app, '),
      const TextRun(
        'no queue',
        style: SceneTextStyle(
          italic: true,
          decoration: SceneTextDecoration.underline,
          decorationColor: _brand,
        ),
      ),
      const TextRun('.'),
    ],
    name: 'paragraph',
    width: 420,
    style: const SceneTextStyle(
      fontFamily: 'Archivo',
      fontSize: 26,
      lineHeight: 1.35,
      color: _ink,
      axes: {'wght': 380},
    ),
  );
  return SceneDocument(
    FrameNode(name: 'root', layout: NodeLayout.column)
      ..width = 480
      ..height = 300
      ..fill = _paper
      ..crossAlign = SceneCrossAxisAlignment.start
      ..padding = const SceneEdges.all(30)
      ..children.add(paragraph),
  );
}
