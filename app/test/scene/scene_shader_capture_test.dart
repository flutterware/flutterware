// A shader pass under the vector capture. The capture keeps each draw's live
// shader object and replays it later, so each band of a per-line pass has to
// have drawn with a shader of its own — one shared shader would replay every
// band with the last line's uniforms.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/render.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';
import 'package:flutterware/src/scene/shader_programs.dart'
    hide precacheSceneShaders;

const probe = 'test/scene/shaders/probe.frag';

final _key = GlobalKey();

void main() {
  testWidgets("a two-line shader pass keeps each band's own shader", (
    tester,
  ) async {
    await tester.runAsync(() => SceneShaderPrograms.instance.load(probe));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: Center(
            child: RepaintBoundary(
              key: _key,
              child: const SizedBox(
                width: 200,
                height: 60,
                child: LayeredText(
                  span: TextSpan(text: 'One\nTwo'),
                  style: TextStyle(fontSize: 20),
                  layers: [
                    FillLayer(
                      paint: ShaderPaint(
                        probe,
                        uniforms: {
                          'uMode': [2],
                        },
                      ),
                      box: SceneLayerBox.line,
                    ),
                  ],
                  textAlign: TextAlign.left,
                  maxLines: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    var boundary =
        tester.renderObject(find.byKey(_key)) as RenderRepaintBoundary;

    await tester.runAsync(() async {
      var recording = captureVector(boundary);
      var shaders = [
        for (var op in recording.ops)
          if (op is VgDrawRect && op.paint.blendMode == BlendMode.srcIn)
            op.paint.source!.shader,
      ];
      expect(shaders, hasLength(2));
      expect(identical(shaders[0], shaders[1]), isFalse);
      var svg = await captureSvg(boundary);
      // The layer went out as a raster patch.
      expect(svg.text, contains('<image'));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));
}
