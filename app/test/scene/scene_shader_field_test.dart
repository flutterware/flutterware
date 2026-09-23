// The shader pass's editor, driven through the paint field that mounts it: a
// picker over the package's declared shaders, then a control per uniform the
// reflection lists, drawn from the shader's own comments.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/shader_library.dart';
import 'package:flutterware_app/src/scene/ui/number_field.dart';
import 'package:flutterware_app/src/scene/ui/number_shape.dart';
import 'package:flutterware_app/src/scene/ui/paint_field.dart';
import 'package:flutterware_app/src/scene/ui/shader_field.dart';
import 'package:flutterware_app/src/scene/ui/swatches.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';

const _red = SceneColor(0xFFFF0000);

const _foilDefaults = ShaderPaint(
  'shaders/foil.frag',
  uniforms: {
    'uAngle': [0.6],
    'uShine': [1, 0.85, 0.4],
  },
);

/// Declares one shader and never finishes reading it.
class _Compiling extends ChangeNotifier implements SceneShaders {
  @override
  List<String> get declared => const ['shaders/foil.frag'];

  @override
  SceneShaderInfo? info(String key) => null;
}

/// Declares [infos] but knows nothing of them until [land] — the library
/// between a package view being made and its compiles coming back.
class _Landing extends ChangeNotifier implements SceneShaders {
  _Landing(this.infos);

  final Map<String, SceneShaderInfo> infos;
  var _landed = false;

  void land() {
    _landed = true;
    notifyListeners();
  }

  @override
  List<String> get declared => infos.keys.toList();

  @override
  SceneShaderInfo? info(String key) => _landed ? infos[key] : null;
}

void main() {
  final shaders = FixedSceneShaders({
    'shaders/foil.frag': SceneShaderInfo(
      key: 'shaders/foil.frag',
      uniforms: [
        SceneShaderUniform(name: 'uSize', size: 2, location: 0),
        SceneShaderUniform(
          name: 'uAngle',
          size: 1,
          location: 1,
          range: (0, 6.283),
          defaults: [0.6],
        ),
        SceneShaderUniform(
          name: 'uShine',
          size: 3,
          location: 2,
          isColor: true,
          defaults: [1, 0.85, 0.4],
        ),
        SceneShaderUniform(name: 'uOffset', size: 2, location: 3),
      ],
    ),
    'shaders/plain.frag': SceneShaderInfo(key: 'shaders/plain.frag'),
  });
  tearDownAll(shaders.dispose);

  late ScenePaint? paint;
  late List<(String, String?)> writes;

  Future<void> pump(
    WidgetTester tester,
    ScenePaint? start, {
    SceneShaders? using,
    bool noPackage = false,
  }) async {
    paint = start;
    writes = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: StatefulBuilder(
                builder: (context, setState) => ScenePaintField(
                  paint: paint,
                  own: _red,
                  shaders: noPackage ? null : using ?? shaders,
                  onChanged: (next, {required label, mergeKey}) {
                    writes.add((label, mergeKey));
                    setState(() => paint = next);
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

  SceneNumberField field(WidgetTester tester, String label) =>
      tester.widget<SceneNumberField>(
        find.byWidgetPredicate(
          (w) => w is SceneNumberField && w.label == label,
        ),
      );

  Map<String, List<double>> uniforms() => (paint! as ShaderPaint).uniforms;

  Color captionColor(WidgetTester tester, String text) =>
      tester.widget<Text>(find.textContaining(text)).style!.color!;

  FwPalette colors(WidgetTester tester) =>
      tester.element(find.byType(SceneShaderField)).colors;

  testWidgets('choosing Shader takes the first declared shader, with its '
      'defaults', (tester) async {
    await pump(tester, const SolidPaint(_red));
    await pick(tester, const ValueKey('paint:kind'), 'Shader');
    expect(paint, _foilDefaults);
    expect(find.byType(SceneShaderField), findsOneWidget);
  });

  testWidgets("the renderer's uniforms are not offered", (tester) async {
    await pump(tester, _foilDefaults);
    expect(find.textContaining('uSize'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is SceneNumberField && (w.label ?? '').startsWith('uSize'),
      ),
      findsNothing,
    );
  });

  testWidgets('a ranged float is a slider', (tester) async {
    await pump(tester, _foilDefaults);
    var angle = field(tester, 'uAngle');
    expect(angle.shape.editor, SceneEditorShape.slider);
    expect(angle.shape.softMin, 0);
    expect(angle.shape.softMax, 6.283);
    expect(angle.value, 0.6);
    angle.onChanged(1.2);
    await tester.pump();
    expect(writes.last, ('Shader uniform', 'shader:uAngle'));
    field(tester, 'uAngle').onCommit(1.5);
    await tester.pump();
    expect(uniforms()['uAngle'], [1.5]);
    expect(uniforms()['uShine'], [1, 0.85, 0.4]);
    // The commit lands in the drag's undo entry, as every paint number does.
    expect(writes.last, ('Shader uniform', 'shader:uAngle'));
  });

  testWidgets('an unset uniform reads zeros, which is what it paints', (
    tester,
  ) async {
    await pump(tester, const ShaderPaint('shaders/foil.frag'));
    expect(field(tester, 'uAngle').value, 0);
    expect(
      tester.widget<SceneColorField>(find.byType(SceneColorField)).current,
      const SceneColor(0xFF000000),
    );
  });

  testWidgets('editing one component of an unset vector keeps the rest at '
      'zero, not at the default', (tester) async {
    var offset = FixedSceneShaders({
      'shaders/offset.frag': SceneShaderInfo(
        key: 'shaders/offset.frag',
        uniforms: [
          SceneShaderUniform(
            name: 'uOffset',
            size: 2,
            location: 0,
            defaults: [0.5, 0.25],
          ),
        ],
      ),
    });
    addTearDown(offset.dispose);
    await pump(tester, const ShaderPaint('shaders/offset.frag'), using: offset);
    expect(field(tester, 'uOffset.x').value, 0);
    field(tester, 'uOffset.y').onCommit(3);
    await tester.pump();
    expect(uniforms()['uOffset'], [0, 3]);
  });

  testWidgets('a value of the wrong count reads zeros, and says so', (
    tester,
  ) async {
    await pump(
      tester,
      const ShaderPaint(
        'shaders/foil.frag',
        uniforms: {
          'uAngle': [1, 2],
        },
      ),
    );
    expect(field(tester, 'uAngle').value, 0);
    expect(
      find.text('uAngle is set as 2 numbers, and foil.frag declares 1'),
      findsOneWidget,
    );
    field(tester, 'uAngle').onCommit(1.5);
    await tester.pump();
    expect(uniforms()['uAngle'], [1.5]);
  });

  testWidgets("a renderer's name is not offered at any size, and a value "
      'stored under it says it is ignored', (tester) async {
    var odd = FixedSceneShaders({
      'shaders/odd.frag': SceneShaderInfo(
        key: 'shaders/odd.frag',
        uniforms: [
          SceneShaderUniform(name: 'uTime', size: 2, location: 0),
          SceneShaderUniform(name: 'uAmount', size: 1, location: 1),
        ],
      ),
    });
    addTearDown(odd.dispose);
    await pump(
      tester,
      const ShaderPaint(
        'shaders/odd.frag',
        uniforms: {
          'uTime': [1, 2],
        },
      ),
      using: odd,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is SceneNumberField && (w.label ?? '').startsWith('uTime'),
      ),
      findsNothing,
    );
    expect(field(tester, 'uAmount').value, 0);
    const ignored = 'uTime is set by the renderer; the stored value is ignored';
    expect(find.text(ignored), findsOneWidget);
    expect(captionColor(tester, ignored), colors(tester).mut2);
    expect(find.textContaining('declares no such uniform'), findsNothing);
    expect(find.textContaining('numbers, and'), findsNothing);
  });

  testWidgets('a vec2 is one field per component', (tester) async {
    await pump(tester, _foilDefaults);
    expect(field(tester, 'uOffset.x').value, 0);
    field(tester, 'uOffset.y').onCommit(3);
    await tester.pump();
    expect(uniforms()['uOffset'], [0, 3]);
    expect(field(tester, 'uOffset.y').value, 3);
  });

  testWidgets('a colour uniform is a colour field', (tester) async {
    await pump(tester, _foilDefaults);
    expect(find.byType(SceneColorField), findsOneWidget);
    expect(find.text('uShine'), findsOneWidget);
    await tester.tap(find.byType(SceneColorField));
    await tester.pumpAndSettle();
    // 0xFFE8632B, the palette's orange.
    await tester.tap(
      find
          .descendant(
            of: find.byType(SceneSwatches),
            matching: find.byType(Tappable),
          )
          .at(6),
    );
    await tester.pumpAndSettle();
    var shine = uniforms()['uShine']!;
    expect(shine, [0.91, 0.388, 0.169]);
    expect(shine.every((v) => v >= 0 && v <= 1), isTrue);
  });

  testWidgets('picking another shader starts from its defaults', (
    tester,
  ) async {
    await pump(tester, _foilDefaults);
    await pick(tester, const ValueKey('paint:shader'), 'plain.frag');
    expect(paint, const ShaderPaint('shaders/plain.frag'));
    expect(writes.last.$1, 'Shader');
  });

  testWidgets('an undeclared asset says so', (tester) async {
    await pump(tester, const ShaderPaint('shaders/gone.frag'));
    expect(find.textContaining('is not declared'), findsOneWidget);
  });

  testWidgets('a stray uniform says so', (tester) async {
    await pump(
      tester,
      const ShaderPaint(
        'shaders/foil.frag',
        uniforms: {
          'uNope': [1],
        },
      ),
    );
    expect(find.textContaining('declares no such uniform'), findsOneWidget);
  });

  testWidgets('a shader that did not compile says why, and keeps its values '
      'in reach', (tester) async {
    var broken = FixedSceneShaders({
      'shaders/broken.frag': SceneShaderInfo(
        key: 'shaders/broken.frag',
        error: 'syntax error',
      ),
    });
    addTearDown(broken.dispose);
    await pump(
      tester,
      const ShaderPaint(
        'shaders/broken.frag',
        uniforms: {
          'uA': [1, 2],
        },
      ),
      using: broken,
    );
    expect(captionColor(tester, 'syntax error'), colors(tester).red);
    expect(field(tester, 'uA.x').value, 1);
    field(tester, 'uA.y').onCommit(5);
    await tester.pump();
    expect(uniforms()['uA'], [1, 5]);
  });

  // The library says a sampler is in the way and still lists what it
  // reflected: the controls stay, with the notice above them.
  testWidgets('a notice beside reflected uniforms keeps their controls', (
    tester,
  ) async {
    var sampled = FixedSceneShaders({
      'shaders/foil.frag': SceneShaderInfo(
        key: 'shaders/foil.frag',
        uniforms: shaders.infos['shaders/foil.frag']!.uniforms,
        error: 'uses a sampler (uTexture) — a scene cannot feed one yet',
      ),
    });
    addTearDown(sampled.dispose);
    await pump(tester, _foilDefaults, using: sampled);
    expect(captionColor(tester, 'uses a sampler'), colors(tester).red);
    expect(field(tester, 'uAngle').shape.editor, SceneEditorShape.slider);
    expect(find.byType(SceneColorField), findsOneWidget);
  });

  testWidgets('with no package, it says so and keeps the values in reach', (
    tester,
  ) async {
    await pump(tester, _foilDefaults, noPackage: true);
    expect(find.text('No package to look in.'), findsOneWidget);
    expect(find.textContaining('is not declared'), findsNothing);
    expect(field(tester, 'uAngle').value, 0.6);
    expect(field(tester, 'uShine.z').value, 0.4);
  });

  testWidgets('a pick before the uniforms are read writes none, and one '
      'after they land writes the defaults', (tester) async {
    var landing = _Landing(shaders.infos);
    addTearDown(landing.dispose);
    await pump(tester, const SolidPaint(_red), using: landing);
    await pick(tester, const ValueKey('paint:kind'), 'Shader');
    expect(paint, const ShaderPaint('shaders/foil.frag'));
    expect(find.text('Reading uniforms…'), findsOneWidget);

    landing.land();
    await tester.pump();
    expect(find.text('Reading uniforms…'), findsNothing);
    expect(field(tester, 'uAngle').value, 0);

    await pick(tester, const ValueKey('paint:shader'), 'plain.frag');
    await pick(tester, const ValueKey('paint:shader'), 'foil.frag');
    expect(paint, _foilDefaults);
  });

  testWidgets('while it compiles, it says so', (tester) async {
    var compiling = _Compiling();
    addTearDown(compiling.dispose);
    await pump(tester, _foilDefaults, using: compiling);
    expect(find.text('Reading uniforms…'), findsOneWidget);
  });
}
