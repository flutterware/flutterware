import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/render.dart';
import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';
import 'package:flutterware/src/render/svg_writer.dart';

/// Layer effects used to vanish silently: pushLayer inlined the child and
/// the effect never existed. These tests pin the fix — every effect becomes
/// a span the unsupported-op policy decides over, and the raster lane
/// replays reproducible ones with the effect applied.
final _key = GlobalKey();

Widget _host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: RepaintBoundary(key: _key, child: child),
    ),
  ),
);

RenderRepaintBoundary _boundary(WidgetTester tester) =>
    tester.renderObject(find.byKey(_key)) as RenderRepaintBoundary;

/// Red channel minus blue channel at a fractional position of a patch.
int _redMinusBlue(VgRecording rec, int rasterId, double fx) {
  var image = rec.images[rasterId]!;
  var rgba = rec.imageRgba[rasterId]!;
  var x = (image.width * fx).floor();
  var y = image.height ~/ 2;
  var o = (y * image.width + x) * 4;
  return rgba[o] - rgba[o + 2];
}

void main() {
  testWidgets('a shader mask replays into a patch with the mask applied', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ShaderMask(
          shaderCallback: (bounds) =>
              const LinearGradient(colors: [Colors.red, Colors.blue])
                  .createShader(bounds),
          blendMode: BlendMode.srcIn,
          child: Container(width: 100, height: 40, color: Colors.white),
        ),
      ),
    );
    var boundary = _boundary(tester);
    await tester.runAsync(() async {
      var recording = captureVector(boundary);
      var begin = recording.ops.whereType<VgBeginEffect>().single;
      expect(begin.kind, VgEffectKind.shaderMask);
      await recording.rasterizeUnsupported();
      await recording.encodeImages();
      expect(begin.rasterId, isNotNull);

      // The patch really carries the mask: red end left, blue end right.
      expect(_redMinusBlue(recording, begin.rasterId!, 0.05), greaterThan(60));
      expect(_redMinusBlue(recording, begin.rasterId!, 0.95), lessThan(-60));

      // The writer places the patch and swallows the child's own ops.
      var svg = writeSvg(recording, boundary.size, []);
      expect(svg, contains('<image'));
      expect(svg, isNot(contains('<rect')));
      expect(
        recording.collectWarnings(CaptureOptions()).map((w) => w.kind),
        contains(RenderWarningKind.effectRasterized),
      );
    });
  });

  testWidgets('a color filter routes through pushColorFilter into a patch', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ColorFiltered(
          colorFilter: const ColorFilter.mode(
            Color(0xFFFF0000),
            BlendMode.srcIn,
          ),
          child: Container(width: 80, height: 40, color: Colors.white),
        ),
      ),
    );
    var boundary = _boundary(tester);
    await tester.runAsync(() async {
      var recording = captureVector(boundary);
      var begin = recording.ops.whereType<VgBeginEffect>().single;
      expect(begin.kind, VgEffectKind.colorFilter);
      await recording.rasterizeUnsupported();
      await recording.encodeImages();
      expect(begin.rasterId, isNotNull);
      // The white child came out red: the filter applied in the replay.
      expect(_redMinusBlue(recording, begin.rasterId!, 0.5), greaterThan(200));

      // UnsupportedPolicy.skip leaves the whole span out instead.
      var svg = writeSvg(
        recording,
        boundary.size,
        [],
        options: CaptureOptions(unsupported: UnsupportedPolicy.skip),
      );
      expect(svg, isNot(contains('<image')));
      expect(svg, isNot(contains('<rect')));
    });
  });

  testWidgets('a backdrop filter keeps its child and warns', (tester) async {
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 120,
          height: 60,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.orange),
              BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: const Center(child: Text('frosted')),
              ),
            ],
          ),
        ),
      ),
    );
    var boundary = _boundary(tester);
    await tester.runAsync(() async {
      // Through the public facade: the honest contract is the point.
      var result = await captureSvg(boundary);
      expect(
        result.warnings.map((w) => w.kind),
        contains(RenderWarningKind.effectDropped),
      );
      // The child is not lost with the effect: the text still renders.
      expect(result.text, contains('frosted'));
    });
  });

  group('a canvas layer', () {
    testWidgets('with only opacity stays a vector group', (tester) async {
      await tester.pumpWidget(
        _host(
          CustomPaint(
            size: const Size(60, 60),
            painter: _LayerPainter(
              Paint()..color = const Color(0x80000000),
              Paint()..color = const Color(0xFFFF0000),
            ),
          ),
        ),
      );
      var boundary = _boundary(tester);
      var recording = captureVector(boundary);
      expect(recording.ops.whereType<VgBeginEffect>(), isEmpty);
      var svg = writeSvg(recording, boundary.size, []);
      expect(svg, contains(RegExp(r'<g opacity="0\.50\d">')));
      expect(svg, contains('<rect'));
      expect(svg, isNot(contains('<image')));
    });

    testWidgets('with a blend and no bounds takes the box of its painter', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          CustomPaint(
            size: const Size(60, 40),
            painter: _LayerPainter(
              Paint()..blendMode = BlendMode.multiply,
              Paint()..color = const Color(0xFFFFFF00),
              bounded: false,
            ),
          ),
        ),
      );
      var boundary = _boundary(tester);
      await tester.runAsync(() async {
        var recording = captureVector(boundary);
        var span = recording.ops.whereType<VgBeginEffect>().single;
        expect(span.kind, VgEffectKind.layer);
        expect(span.blendMode, BlendMode.multiply);
        // The painter's frame is already translated to the box's corner.
        expect(span.bounds, const Rect.fromLTWH(0, 0, 60, 40));
        await recording.rasterizeUnsupported();
        await recording.encodeImages();
        var svg = writeSvg(recording, boundary.size, []);
        expect(svg, contains(RegExp('<image[^>]*mix-blend-mode:multiply')));
      });
    });

    testWidgets(
      'a blended layer nested in an opacity-only layer promotes the outer '
      'to one patch',
      (tester) async {
        await tester.pumpWidget(
          _host(
            CustomPaint(
              size: const Size(60, 40),
              painter: _NestedLayerPainter(),
            ),
          ),
        );
        var boundary = _boundary(tester);
        await tester.runAsync(() async {
          var recording = captureVector(boundary);
          var spans = recording.ops.whereType<VgBeginEffect>().toList();
          expect(spans, hasLength(2)); // the outer layer and the inner one
          await recording.rasterizeUnsupported();
          await recording.encodeImages();

          // Only the outer span was patched; the inner one, replayed as
          // part of the outer's patch, kept no rasterId of its own.
          var patched = spans.where((s) => s.rasterId != null).toList();
          expect(patched, hasLength(1));
          expect(patched.single.kind, VgEffectKind.layer);
          expect(patched.single.blendMode, BlendMode.srcOver);

          var svg = writeSvg(recording, boundary.size, []);
          expect('<image'.allMatches(svg), hasLength(1));

          // The inner blend is baked into the outer's patch: cyan under
          // yellow, multiplied, reads green — not a plain overwrite.
          var rgba = recording.imageRgba[patched.single.rasterId]!;
          var image = recording.images[patched.single.rasterId]!;
          var o = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
          expect([rgba[o], rgba[o + 1], rgba[o + 2]], [0, 255, 0]);

          var warnings = recording.collectWarnings(CaptureOptions());
          expect(
            warnings.where((w) => w.kind == RenderWarningKind.effectDropped),
            isEmpty,
          );
          var rasterized = warnings.where(
            (w) => w.kind == RenderWarningKind.effectRasterized,
          );
          expect(rasterized, hasLength(1));
          expect(rasterized.single.message, startsWith('1 layer'));
        });
      },
    );

    testWidgets('with a blend no document can name is placed plain, warned', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          CustomPaint(
            size: const Size(60, 40),
            painter: _LayerPainter(
              Paint()..blendMode = BlendMode.dstOut,
              Paint()..color = const Color(0xFFFFFF00),
            ),
          ),
        ),
      );
      var boundary = _boundary(tester);
      await tester.runAsync(() async {
        var result = await captureSvg(boundary);
        expect(result.text, contains('<image'));
        expect(result.text, isNot(contains('mix-blend-mode')));
        expect(
          result.warnings.where(
            (w) =>
                w.kind == RenderWarningKind.effectDropped &&
                w.message.contains('dstOut'),
          ),
          hasLength(1),
        );
      });
    });
  });

  testWidgets('drawArc is captured as a path', (tester) async {
    await tester.pumpWidget(
      _host(CustomPaint(size: const Size(60, 60), painter: _ArcPainter())),
    );
    var recording = captureVector(_boundary(tester));
    expect(recording.unhandled, isEmpty);
    expect(recording.ops.whereType<VgDrawPath>(), isNotEmpty);
  });
}

/// One rect inside one `saveLayer`, bounded by the box unless told not to.
class _LayerPainter extends CustomPainter {
  _LayerPainter(this.layer, this.fill, {this.bounded = true});

  final Paint layer;
  final Paint fill;
  final bool bounded;

  @override
  void paint(Canvas canvas, Size size) {
    var box = Offset.zero & size;
    canvas.saveLayer(bounded ? box : null, layer);
    canvas.drawRect(box, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A layer that only carries opacity, holding a cyan backdrop and a yellow
/// rect painted through a nested layer that multiplies.
class _NestedLayerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    var box = Offset.zero & size;
    canvas.saveLayer(box, Paint());
    canvas.drawRect(box, Paint()..color = const Color(0xFF00FFFF));
    canvas.saveLayer(box, Paint()..blendMode = BlendMode.multiply);
    canvas.drawRect(box, Paint()..color = const Color(0xFFFFFF00));
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawArc(
      const Rect.fromLTWH(5, 5, 50, 50),
      0.4,
      3.6,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF1E88E5),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
