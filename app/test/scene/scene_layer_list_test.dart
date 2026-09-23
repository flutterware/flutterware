// The layer list's paint editor, driven: a colour pass becomes a gradient
// through the kind picker, and a gradient pass can be laid across each line.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/shader_library.dart';
import 'package:flutterware_app/src/scene/ui/layer_list.dart';
import 'package:flutterware_app/src/ui/theme.dart';

const _red = SceneColor(0xFFFF0000);

void main() {
  late List<TextLayer> layers;
  late List<String> labels;

  Future<void> pump(
    WidgetTester tester,
    List<TextLayer> start, {
    SceneShaders? shaders,
  }) async {
    // Tall enough for the blend picker's sixteen rows to open on screen.
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    layers = start;
    labels = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: StatefulBuilder(
                builder: (context, setState) => SceneLayerList(
                  layers: layers,
                  fontSize: 54,
                  color: const Color(0xFFFFFFFF),
                  shaders: shaders,
                  onChanged: (next, {required label, mergeKey}) {
                    labels.add(label);
                    setState(() => layers = next);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pick(WidgetTester tester, Key picker, String choice) async {
    await tester.tap(find.byKey(picker));
    await tester.pumpAndSettle();
    await tester.tap(find.text(choice).last);
    await tester.pumpAndSettle();
  }

  testWidgets('a colour pass becomes a gradient that fades out of it', (
    tester,
  ) async {
    await pump(tester, const [FillLayer(paint: SolidPaint(_red))]);
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    await pick(tester, const ValueKey('paint:kind'), 'Linear');
    expect(
      layers.single.paint,
      const LinearPaint(colors: [_red, SceneColor(0x00FF0000)]),
    );
    expect(find.byKey(const ValueKey('gradient:bar')), findsOneWidget);
  });

  testWidgets('a gradient pass can be laid across each line', (tester) async {
    await pump(tester, const [
      FillLayer(paint: LinearPaint(colors: [_red, SceneColor(0xFF0000FF)])),
    ]);
    await tester.tap(find.textContaining('Fill'));
    await tester.pumpAndSettle();
    await pick(tester, const ValueKey('layer:box'), 'Each line');
    expect(layers.single.box, SceneLayerBox.line);
    expect(find.textContaining('per line'), findsOneWidget);
  });

  testWidgets('a shader pass laid across each line says so in its row', (
    tester,
  ) async {
    await pump(tester, const [
      FillLayer(
        paint: ShaderPaint('shaders/foil.frag'),
        box: SceneLayerBox.line,
      ),
      FillLayer(paint: ShaderPaint('shaders/foil.frag')),
    ]);
    expect(find.text('Fill · shader · per line'), findsOneWidget);
    expect(find.text('Fill · shader'), findsOneWidget);
  });

  testWidgets('a colour pass offers no box: it would change nothing', (
    tester,
  ) async {
    await pump(tester, const [FillLayer(paint: SolidPaint(_red))]);
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layer:box')), findsNothing);
  });

  testWidgets('switching a per-line pass to a colour drops its box', (
    tester,
  ) async {
    await pump(tester, const [
      FillLayer(
        paint: LinearPaint(colors: [_red, SceneColor(0xFF0000FF)]),
        box: SceneLayerBox.line,
      ),
    ]);
    await tester.tap(find.textContaining('Fill'));
    await tester.pumpAndSettle();
    await pick(tester, const ValueKey('paint:kind'), 'Colour');
    expect(layers.single.box, SceneLayerBox.text);
  });

  testWidgets(
    'a shader pass shows the box picker, and keeps it through an edit',
    (tester) async {
      await pump(tester, const [
        FillLayer(
          paint: ShaderPaint('shaders/foil.frag'),
          box: SceneLayerBox.line,
        ),
      ]);
      await tester.tap(find.textContaining('Fill'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('layer:box')), findsOneWidget);
      // Re-picking the already-selected kind still round-trips the paint
      // through onChanged, which is what the ternary keeping `box` has to
      // survive.
      await pick(tester, const ValueKey('paint:kind'), 'Shader');
      expect(layers.single.paint, isA<ShaderPaint>());
      expect(layers.single.box, SceneLayerBox.line);
    },
  );

  testWidgets(
    'a per-line pass switched to Shader keeps its box, and takes the first '
    'declared shader',
    (tester) async {
      var shaders = FixedSceneShaders({
        'shaders/foil.frag': const SceneShaderInfo(
          key: 'shaders/foil.frag',
          uniforms: [
            SceneShaderUniform(
              name: 'uAngle',
              size: 1,
              location: 0,
              defaults: [0.6],
            ),
          ],
        ),
      });
      addTearDown(shaders.dispose);
      await pump(tester, const [
        FillLayer(
          paint: LinearPaint(colors: [_red, SceneColor(0xFF0000FF)]),
          box: SceneLayerBox.line,
        ),
      ], shaders: shaders);
      await tester.tap(find.textContaining('Fill'));
      await tester.pumpAndSettle();
      await pick(tester, const ValueKey('paint:kind'), 'Shader');
      expect(
        layers.single.paint,
        const ShaderPaint(
          'shaders/foil.frag',
          uniforms: {
            'uAngle': [0.6],
          },
        ),
      );
      expect(layers.single.box, SceneLayerBox.line);
      expect(find.byKey(const ValueKey('layer:box')), findsOneWidget);
      // A shader is not a gradient: what "each line" means for it is a box.
      await tester.pumpAndSettle();
      expect(
        find.textContaining('the shader runs once per line'),
        findsOneWidget,
      );
      expect(find.textContaining('whole gradient'), findsNothing);
    },
  );

  testWidgets('a pass can be set to multiply', (tester) async {
    await pump(tester, const [FillLayer(paint: SolidPaint(_red))]);
    await tester.tap(find.text('Fill'));
    await tester.pumpAndSettle();
    await pick(tester, const ValueKey('layer:blend'), 'Multiply');
    expect(layers.single.blend, SceneBlendMode.multiply);
    expect(find.textContaining('multiply'), findsOneWidget);
    expect(labels.last, 'Layer blend');
  });
}
