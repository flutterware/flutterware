import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

/// A text's paint stack, in the shapes it is actually reached for.
///
/// Each of these is the same one list with different numbers in it — an
/// outline is a stroke beneath the fill, a sticker is stroke-stroke-fill, a
/// shadow is a blurred offset fill, an extrusion is a run of offset fills
/// under a gradient one. That combinatorial reach is the argument for a list
/// over a `shadows` property and a `stroke` property, which are two points in
/// it and do not compose (master plan §4.5). The last four are paint rather
/// than structure: a radial, a sweep, a gradient laid across each line of a
/// two-line title, and a gloss that fades to nothing so it sits on any colour.
///
/// It is a picture rather than a test because that is what it answers: does a
/// 14px stroke survive a tight counter, does an extrusion read as depth, is
/// the gradient measured against the box, the line or the glyph.
@Preview(name: 'Text layers', group: 'Scene')
Widget sceneLayers() => const _Layers();

const _ink = SceneColor(0xFF120720);
const _neon = SceneColor(0xFFFF2D95);
const _gold = LinearPaint(
  colors: [SceneColor(0xFFFFF3B0), SceneColor(0xFFFFB020)],
);

/// The stack for each specimen, what it is called in a design tool, and the
/// words it is shown on.
const _specimens = <(String, List<TextLayer>, String)>[
  ('plain', [], 'Layers'),
  (
    'outline',
    [
      StrokeLayer(width: 8, paint: SolidPaint(_ink)),
      FillLayer(paint: SolidPaint(SceneColor(0xFFFFC400))),
    ],
    'Layers',
  ),
  (
    'sticker',
    [
      StrokeLayer(width: 20, paint: SolidPaint(SceneColor(0xFFFFFFFF))),
      StrokeLayer(width: 10, paint: SolidPaint(_ink)),
      FillLayer(paint: SolidPaint(SceneColor(0xFFFFC400))),
    ],
    'Layers',
  ),
  (
    'shadow',
    [
      FillLayer(
        paint: SolidPaint(SceneColor(0xCC000000)),
        dx: 4,
        dy: 6,
        blur: 8,
      ),
      FillLayer(paint: SolidPaint(SceneColor(0xFFFFFFFF))),
    ],
    'Layers',
  ),
  (
    'neon',
    [
      FillLayer(paint: SolidPaint(_neon), blur: 24),
      FillLayer(paint: SolidPaint(_neon), blur: 10),
      FillLayer(paint: SolidPaint(SceneColor(0xFFFFFFFF))),
    ],
    'Layers',
  ),
  // One pixel a step: a depth is a run of offsets close enough to read as a
  // solid side, and two apart is where it starts to band instead.
  (
    'extruded',
    [
      FillLayer(paint: SolidPaint(_ink), dx: 8, dy: 8),
      FillLayer(paint: SolidPaint(_ink), dx: 7, dy: 7),
      FillLayer(paint: SolidPaint(_ink), dx: 6, dy: 6),
      FillLayer(paint: SolidPaint(_ink), dx: 5, dy: 5),
      FillLayer(paint: SolidPaint(_ink), dx: 4, dy: 4),
      FillLayer(paint: SolidPaint(_ink), dx: 3, dy: 3),
      FillLayer(paint: SolidPaint(_ink), dx: 2, dy: 2),
      FillLayer(paint: SolidPaint(_ink), dx: 1, dy: 1),
      FillLayer(paint: _gold),
    ],
    'Layers',
  ),
  (
    'radial',
    [
      StrokeLayer(width: 6, paint: SolidPaint(_ink)),
      FillLayer(
        paint: RadialPaint(
          colors: [SceneColor(0xFFFFFFFF), _neon],
          radius: 1.1,
        ),
      ),
    ],
    'Layers',
  ),
  (
    'sweep',
    [
      StrokeLayer(
        width: 8,
        paint: SweepPaint(
          colors: [
            _neon,
            SceneColor(0xFF00E5FF),
            SceneColor(0xFFFFE600),
            _neon,
          ],
        ),
      ),
      FillLayer(paint: SolidPaint(SceneColor(0xFF1B0F26))),
    ],
    'Layers',
  ),
  // Two lines, so the difference shows: across each line both start pale and
  // end deep; across the text, the second line would be all deep.
  (
    'gold, per line',
    [
      StrokeLayer(width: 8, paint: SolidPaint(_ink)),
      FillLayer(paint: _gold, box: SceneLayerBox.line),
    ],
    'Game\nover',
  ),
  (
    'gloss',
    [
      FillLayer(paint: SolidPaint(SceneColor(0xFF2D7BFF))),
      FillLayer(
        paint: LinearPaint(
          colors: [SceneColor(0x99FFFFFF), SceneColor(0x00FFFFFF)],
          stops: [0, 0.5],
        ),
        box: SceneLayerBox.line,
      ),
    ],
    'Layers',
  ),
];

class _Layers extends StatelessWidget {
  const _Layers();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: const Color(0xFF1B0F26),
      child: Align(
        alignment: Alignment.topLeft,
        child: SceneView.document(_specimenSheet()),
      ),
    ),
  );
}

SceneDocument _specimenSheet() {
  var rows = <SceneNode>[];
  // Nodes are named by position: a specimen's name is a caption with spaces
  // and commas in it, and a node name is an identifier.
  for (var (i, (name, layers, words)) in _specimens.indexed) {
    var label = TextNode(
      name,
      name: 'label_$i',
      style: const SceneTextStyle(
        fontSize: 11,
        letterSpacing: 2,
        textCase: SceneTextCase.upper,
        color: SceneColor(0xFF7A6A88),
      ),
    );
    var word = TextNode(
      words,
      name: 'word_$i',
      style: SceneTextStyle(
        fontSize: 54,
        weight: SceneFontWeight.w900,
        letterSpacing: -1,
        color: const SceneColor(0xFFFFFFFF),
        layers: layers,
      ),
    );
    rows.add(
      FrameNode(name: 'row_$i', layout: NodeLayout.column)
        ..gap = 2
        ..crossAlign = SceneCrossAxisAlignment.start
        ..children.addAll([label, word]),
    );
  }
  var root = FrameNode(name: 'root', layout: NodeLayout.column)
    ..width = 380
    ..height = 1120
    ..fill = const SceneColor(0xFF1B0F26)
    ..padding = const SceneEdges.all(24)
    ..gap = 18
    ..children.addAll(rows);
  return SceneDocument(root);
}
