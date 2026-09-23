// A gradient pass, read back as pixels. The test font draws every glyph as
// a filled box, which is what makes this possible: the ink covers the whole
// line, so the colour at a point is the gradient's colour there.
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

const _red = SceneColor(0xFFFF0000);
const _green = SceneColor(0xFF00FF00);
const _blue = SceneColor(0xFF0000FF);
const _yellow = SceneColor(0xFFFFFF00);

/// [layers] over [text] at 20px, painted by the stack painter alone into a
/// [size] picture — no widget tree, so the box is exactly [size]. Ten `M`s
/// are one 200×20 line.
Future<ui.Image> _paint(
  List<TextLayer> layers, {
  String text = 'MMMMMMMMMM',
  Size size = const Size(200, 20),
}) {
  var painter = SceneTextStackPainter(
    span: TextSpan(text: text),
    style: const TextStyle(fontSize: 20, height: 1, color: Color(0xFFFFFFFF)),
    layers: layers,
    textAlign: TextAlign.left,
    maxLines: null,
    overflow: TextOverflow.clip,
    textDirection: TextDirection.ltr,
    scaler: TextScaler.noScaling,
    widthBasis: TextWidthBasis.parent,
    heightBehavior: null,
  );
  var recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
}

/// The mean colour of the inked pixels in [region] — ink only, so a gap
/// between glyphs in a real font would not dilute it.
Future<({int r, int g, int b})> _mean(ui.Image image, Rect region) async {
  var bytes = (await image.toByteData())!;
  var (r, g, b, n) = (0, 0, 0, 0);
  for (var y = region.top.toInt(); y < region.bottom.toInt(); y++) {
    for (var x = region.left.toInt(); x < region.right.toInt(); x++) {
      var i = (y * image.width + x) * 4;
      if (bytes.getUint8(i + 3) < 128) continue;
      r += bytes.getUint8(i);
      g += bytes.getUint8(i + 1);
      b += bytes.getUint8(i + 2);
      n++;
    }
  }
  expect(n, greaterThan(0), reason: 'no ink in $region');
  return (r: r ~/ n, g: g ~/ n, b: b ~/ n);
}

/// A 10×4 patch centred on ([x], [y]).
Rect _spot(double x, double y) => Rect.fromLTWH(x - 5, y - 2, 10, 4);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a linear gradient', () {
    const across = LinearPaint(
      colors: [_red, _blue],
      begin: SceneAlignment.centerLeft,
      end: SceneAlignment.centerRight,
    );

    test('runs across the box, begin to end', () async {
      var image = await _paint(const [FillLayer(paint: across)]);
      var left = await _mean(image, _spot(10, 10));
      var right = await _mean(image, _spot(190, 10));
      expect(left.r, greaterThan(left.b));
      expect(right.b, greaterThan(right.r));
    });

    test('with three colours and no stops, spreads them evenly', () async {
      // dart:ui refuses a gradient with no stops unless it has exactly two
      // colours. The model says a null is an even spread, so the renderer is
      // what has to say it to the engine — before this it threw mid-paint.
      var image = await _paint(const [
        FillLayer(
          paint: LinearPaint(
            colors: [_red, _green, _blue],
            begin: SceneAlignment.centerLeft,
            end: SceneAlignment.centerRight,
          ),
        ),
      ]);
      var middle = await _mean(image, _spot(100, 10));
      expect(middle.g, greaterThan(middle.r));
      expect(middle.g, greaterThan(middle.b));
    });

    test(
      'with stops that do not fit its colours, spreads them evenly',
      () async {
        var image = await _paint(const [
          FillLayer(
            paint: LinearPaint(
              colors: [_red, _green, _blue],
              stops: [0, 1],
              begin: SceneAlignment.centerLeft,
              end: SceneAlignment.centerRight,
            ),
          ),
        ]);
        var middle = await _mean(image, _spot(100, 10));
        expect(middle.g, greaterThan(middle.r));
      },
    );

    test('with fewer than two colours, is a solid', () async {
      var one = await _paint(const [
        FillLayer(paint: LinearPaint(colors: [_red])),
      ]);
      expect((await _mean(one, _spot(100, 10))).r, greaterThan(200));
      // None at all is the text's own colour, white here.
      var none = await _paint(const [
        FillLayer(paint: LinearPaint(colors: [])),
      ]);
      var own = await _mean(none, _spot(100, 10));
      expect([own.r, own.g, own.b], everyElement(greaterThan(200)));
    });
  });

  test(
    'a radial gradient is stretched to the box, not its short side',
    () async {
      var image = await _paint(const [
        FillLayer(
          paint: RadialPaint(
            colors: [SceneColor(0xFFFFFFFF), SceneColor(0xFF000000)],
          ),
        ),
      ]);
      // 20px left of the middle of a 200px line is a fifth of the way to the
      // edge: still light. Measured on the 20px side, the way Flutter's
      // RadialGradient is, the circle would have ended 10px before it.
      var near = await _mean(image, _spot(80, 10));
      expect(near.r, greaterThan(150));
      var edge = await _mean(image, _spot(195, 10));
      expect(edge.r, lessThan(40));
    },
  );

  group('a sweep gradient', () {
    test("starts at twelve o'clock and runs clockwise", () async {
      var image = await _paint(const [
        FillLayer(paint: SweepPaint(colors: [_red, _blue])),
      ]);
      // Three o'clock is a quarter of the way round, nine o'clock three
      // quarters. With the engine's own zero at three o'clock, nine would be
      // halfway and read as purple.
      var three = await _mean(image, _spot(150, 10));
      var nine = await _mean(image, _spot(50, 10));
      expect(three.r, greaterThan(three.b));
      expect(nine.b, greaterThan(nine.r));
    });

    test('puts its first colour at its start angle', () async {
      // A full turn past the start, so the arc is the whole circle shifted
      // rather than a half-turn with the far side clamped.
      var image = await _paint(const [
        FillLayer(
          paint: SweepPaint(
            colors: [_red, _blue],
            startAngle: 180,
            endAngle: 540,
          ),
        ),
      ]);
      var three = await _mean(image, _spot(150, 10));
      var nine = await _mean(image, _spot(50, 10));
      expect(nine.r, greaterThan(nine.b));
      expect(three.b, greaterThan(three.r));
    });
  });

  test('a multiplied pass multiplies the pass beneath it', () async {
    // Cyan times yellow is green; painted normally, yellow is yellow.
    var image = await _paint(const [
      FillLayer(paint: SolidPaint(SceneColor(0xFF00FFFF))),
      FillLayer(
        paint: SolidPaint(SceneColor(0xFFFFFF00)),
        blend: SceneBlendMode.multiply,
      ),
    ]);
    var mixed = await _mean(image, _spot(100, 10));
    expect(mixed.g, greaterThan(200));
    expect(mixed.r, lessThan(60));
    expect(mixed.b, lessThan(60));
  });

  group('a pass laid across each line', () {
    // Ten Ms over two: the second line is a fifth as long as the first.
    const twoLines = 'MMMMMMMMMM\nMM';
    const size = Size(200, 40);
    const across = LinearPaint(
      colors: [_red, _blue],
      begin: SceneAlignment.centerLeft,
      end: SceneAlignment.centerRight,
    );

    test('runs a short line through the whole gradient', () async {
      var boxed = await _paint(
        const [FillLayer(paint: across)],
        text: twoLines,
        size: size,
      );
      var lined = await _paint(
        const [FillLayer(paint: across, box: SceneLayerBox.line)],
        text: twoLines,
        size: size,
      );
      // The end of "MM": across the text it is a fifth of the way along and
      // still red; across its own line it is the blue end.
      var inBox = await _mean(boxed, _spot(35, 30));
      var inLine = await _mean(lined, _spot(35, 30));
      expect(inBox.r, greaterThan(inBox.b));
      expect(inLine.b, greaterThan(inLine.r));
    });

    test('restarts a gradient down the text on every line', () async {
      var lined = await _paint(
        const [
          FillLayer(
            paint: LinearPaint(colors: [_red, _blue]),
            box: SceneLayerBox.line,
          ),
        ],
        text: twoLines,
        size: size,
      );
      var topOfSecond = await _mean(lined, _spot(20, 22));
      expect(topOfSecond.r, greaterThan(topOfSecond.b));
    });

    test('a multiplied per-line pass multiplies the pass beneath it', () async {
      // Same mechanism as a direct blended pass: the blend is applied at
      // the layer's restore, not on the pass's own Paint.
      var image = await _paint(
        const [
          FillLayer(paint: SolidPaint(SceneColor(0xFF00FFFF))),
          FillLayer(
            paint: LinearPaint(colors: [_yellow, _yellow]),
            box: SceneLayerBox.line,
            blend: SceneBlendMode.multiply,
          ),
        ],
        text: twoLines,
        size: size,
      );
      var mixed = await _mean(image, _spot(35, 10));
      expect(mixed.g, greaterThan(200));
      expect(mixed.r, lessThan(60));
      expect(mixed.b, lessThan(60));
    });

    test(
      'a per-line pass at half opacity mixes with what is beneath it',
      () async {
        var image = await _paint(
          const [
            FillLayer(paint: SolidPaint(SceneColor(0xFF000000))),
            FillLayer(
              paint: LinearPaint(
                colors: [SceneColor(0xFFFFFFFF), SceneColor(0xFFFFFFFF)],
              ),
              box: SceneLayerBox.line,
              opacity: 0.5,
            ),
          ],
          text: twoLines,
          size: size,
        );
        var mixed = await _mean(image, _spot(35, 10));
        // Roughly half-way between black and white, not an exact value.
        expect(mixed.r, inInclusiveRange(90, 165));
        expect(mixed.g, inInclusiveRange(90, 165));
        expect(mixed.b, inInclusiveRange(90, 165));
      },
    );

    test('changes nothing for a solid pass', () async {
      Future<List<int>> bytes(SceneLayerBox box) async {
        var image = await _paint(
          [FillLayer(paint: const SolidPaint(_green), box: box)],
          text: twoLines,
          size: size,
        );
        return (await image.toByteData())!.buffer.asUint8List();
      }

      expect(await bytes(SceneLayerBox.line), await bytes(SceneLayerBox.text));
    });
  });
}
