// A per-line gradient pass used to size a vector capture's raster patch
// from a band that ran 1e4px past the box — Picture.toImage fails outright
// on a patch that size, unhandled, taking flutter_tester down with it.
//
// Past completing, what the capture has to get right: a per-line pass is a
// glyph mask with a gradient band drawn `srcIn` over it, and a blended pass
// carries its blend on a layer — neither of which a vector writer can say
// op by op, so each exports as one patch, blended by the writer.
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/render.dart';
import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';
import 'package:flutterware/src/render/svg_writer.dart';
import 'package:flutterware/src/scene/core/values.dart';
import 'package:flutterware/src/scene/layered_text.dart';

final _key = GlobalKey();

Widget _host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(key: _key, child: child),
    ),
  ),
);

/// No ambient text style, so a [TextPainter] in the test lays the text out
/// exactly as the passes do, and the patch can be read at a glyph.
Widget _bareHost(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: ColoredBox(
    color: const Color(0xFFFFFFFF),
    child: Center(
      child: RepaintBoundary(key: _key, child: child),
    ),
  ),
);

RenderRepaintBoundary _boundary(WidgetTester tester) =>
    tester.renderObject(find.byKey(_key)) as RenderRepaintBoundary;

int _count(String haystack, Pattern needle) =>
    needle.allMatches(haystack).length;

const _red = SceneColor(0xFFFF0000);
const _blue = SceneColor(0xFF0000FF);

void main() {
  testWidgets('captureSvg of a per-line gradient pass completes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          height: 60,
          child: LayeredText(
            span: const TextSpan(text: 'One\nTwo'),
            style: const TextStyle(fontSize: 20),
            layers: const [
              FillLayer(
                paint: LinearPaint(colors: [_red, _blue]),
                box: SceneLayerBox.line,
              ),
            ],
            textAlign: TextAlign.left,
            maxLines: null,
          ),
        ),
      ),
    );
    var boundary = _boundary(tester);
    await tester.runAsync(() async {
      var result = await captureSvg(boundary);
      expect(result.text, contains('<svg'));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('a per-line pass exports its glyphs coloured, not a band', (
    tester,
  ) async {
    const text = 'One Two\nSix Ten';
    const style = TextStyle(fontSize: 20, height: 2);
    const width = 200.0;
    await tester.pumpWidget(
      _bareHost(
        SizedBox(
          width: width,
          height: 100,
          child: LayeredText(
            span: const TextSpan(text: text),
            style: style,
            layers: const [
              FillLayer(
                paint: LinearPaint(
                  colors: [_red, _blue],
                  begin: SceneAlignment.centerLeft,
                  end: SceneAlignment.centerRight,
                ),
                box: SceneLayerBox.line,
              ),
            ],
            textAlign: TextAlign.left,
            maxLines: null,
          ),
        ),
      ),
    );
    var boundary = _boundary(tester);

    // Where the glyphs are, in the painter's own frame — the frame the
    // pass's layer, and so its patch, is recorded in.
    var layout = TextPainter(
      text: const TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    Rect glyph(int index) => layout
        .getBoxesForSelection(
          TextSelection(baseOffset: index, extentOffset: index + 1),
        )
        .single
        .toRect();

    await tester.runAsync(() async {
      var result = await captureSvg(boundary);
      expect(_count(result.text, '<image'), 1);
      expect(
        result.warnings.where(
          (w) =>
              w.kind == RenderWarningKind.effectRasterized &&
              w.message.contains('blend or a mask'),
        ),
        hasLength(1),
      );

      var recording = captureVector(boundary);
      await recording.rasterizeUnsupported();
      await recording.encodeImages();
      var span = recording.ops
          .whereType<VgBeginEffect>()
          .where((e) => e.kind == VgEffectKind.layer)
          .single;
      var id = span.rasterId!;
      var image = recording.images[id]!;
      var rgba = recording.imageRgba[id]!;
      var patch = recording.rasterRects[id]!;
      ({int r, int b, int a}) at(Offset p) {
        var x = ((p.dx - patch.left) * image.width / patch.width).floor();
        var y = ((p.dy - patch.top) * image.height / patch.height).floor();
        var o = (y * image.width + x) * 4;
        return (r: rgba[o], b: rgba[o + 2], a: rgba[o + 3]);
      }

      // Each line runs the whole gradient: red where it starts, blue where
      // it ends, and red again at the start of the next.
      var first = at(glyph(0).center);
      var last = at(glyph(6).center);
      var nextLine = at(glyph(8).center);
      expect(first.a, greaterThan(200));
      expect(first.r - first.b, greaterThan(60));
      expect(last.a, greaterThan(200));
      expect(last.b - last.r, greaterThan(60));
      expect(nextLine.r - nextLine.b, greaterThan(60));

      // Off the glyphs the patch is empty: clipped to the ink, not a band.
      expect(at(glyph(3).center).a, lessThan(10), reason: 'the space');
      var between = Offset(
        glyph(0).center.dx,
        (glyph(0).bottom + glyph(8).top) / 2,
      );
      expect(at(between).a, lessThan(10), reason: 'between the lines');
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('a multiplied pass exports with its blend', (tester) async {
    await tester.pumpWidget(
      _bareHost(
        const SizedBox(
          width: 200,
          height: 40,
          child: LayeredText(
            span: TextSpan(text: 'Mix'),
            style: TextStyle(fontSize: 20),
            layers: [
              FillLayer(paint: SolidPaint(SceneColor(0xFF00FFFF))),
              FillLayer(
                paint: SolidPaint(SceneColor(0xFFFFFF00)),
                blend: SceneBlendMode.multiply,
              ),
            ],
            textAlign: TextAlign.left,
            maxLines: null,
          ),
        ),
      ),
    );
    var boundary = _boundary(tester);
    await tester.runAsync(() async {
      var svg = (await captureSvg(boundary)).text;
      // Cyan is a patch of its own, placed plainly; yellow's carries the
      // blend.
      expect(_count(svg, '<image'), 2);
      expect(_count(svg, 'mix-blend-mode'), 1);
      expect(_count(svg, RegExp('<image[^>]*mix-blend-mode:multiply')), 1);

      var pdf = latin1.decode((await capturePdf(boundary)).bytes);
      expect(pdf, contains(RegExp(r'/BM\s*/Multiply')));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('a plain gradient pass stays one patch with no layer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _bareHost(
        const SizedBox(
          width: 200,
          height: 40,
          child: LayeredText(
            span: TextSpan(text: 'Plain'),
            style: TextStyle(fontSize: 20),
            layers: [
              FillLayer(paint: LinearPaint(colors: [_red, _blue])),
            ],
            textAlign: TextAlign.left,
            maxLines: null,
          ),
        ),
      ),
    );
    var boundary = _boundary(tester);
    expect(captureVector(boundary).ops.whereType<VgBeginEffect>(), isEmpty);
    await tester.runAsync(() async {
      var svg = (await captureSvg(boundary)).text;
      expect(_count(svg, '<image'), 1);
      expect(svg, isNot(contains('mix-blend-mode')));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('an Opacity widget still exports as a group', (tester) async {
    await tester.pumpWidget(
      _bareHost(
        Opacity(
          opacity: 0.5,
          child: Container(width: 40, height: 40, color: Colors.red),
        ),
      ),
    );
    var boundary = _boundary(tester);
    var recording = captureVector(boundary);
    var svg = writeSvg(recording, boundary.size, []);
    expect(svg, contains(RegExp(r'<g opacity="0\.50\d">')));
    expect(svg, isNot(contains('<image')));
  });
}
