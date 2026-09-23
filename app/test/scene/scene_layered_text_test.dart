// The painter's shape, which is what its cost rests on: no stack, no extra
// work; a stack, and the widget that does the LAYOUT draws nothing.
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

Widget _mount(List<TextLayer> layers, {ValueListenable<Duration>? time}) =>
    MaterialApp(
      home: Center(
        child: LayeredText(
          span: const TextSpan(text: 'GAME OVER'),
          style: const TextStyle(fontSize: 32, color: Color(0xFFFFC400)),
          layers: layers,
          textAlign: TextAlign.left,
          maxLines: null,
          time: time,
        ),
      ),
    );

/// Scoped, because a `MaterialApp` brings CustomPaints of its own.
final _passes = find.descendant(
  of: find.byType(LayeredText),
  matching: find.byType(CustomPaint),
);

void main() {
  testWidgets('no stack is the plain text it always was', (tester) async {
    await tester.pumpWidget(_mount(const []));
    expect(_passes, findsNothing);
    var text = tester.widget<Text>(find.byType(Text));
    expect(text.style?.color, const Color(0xFFFFC400));
  });

  testWidgets('a stack replaces the single draw rather than adding to it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _mount(const [
        StrokeLayer(width: 8, paint: SolidPaint(SceneColor(0xFF120720))),
        FillLayer(),
      ]),
    );
    expect(_passes, findsOneWidget);
    var text = tester.widget<Text>(find.byType(Text));
    expect(
      text.style?.color,
      const Color(0x00000000),
      reason: 'transparent, not an Opacity: a save layer for the same nothing',
    );
  });

  testWidgets('a pass is shaped by the ambient style, like the base is', (
    tester,
  ) async {
    // The bug this pins: a `Text` merges over the ambient `DefaultTextStyle`
    // and a `TextPainter` merges over nothing, so a scene that names no size
    // or family had the base and the passes SHAPING differently — wrapping at
    // different widths, and a box that no longer described what was painted
    // in it. It reads as a layout bug in whatever holds the text.
    Widget under(TextStyle ambient, List<TextLayer> layers) => MaterialApp(
      home: DefaultTextStyle(
        style: ambient,
        child: Center(
          child: SizedBox(
            width: 220,
            child: LayeredText(
              span: const TextSpan(text: 'GAME OVER AND OVER AGAIN'),
              // Says nothing about size: the ambient style answers, and both
              // halves have to hear the same answer.
              style: const TextStyle(color: Color(0xFFFFC400)),
              layers: layers,
              textAlign: TextAlign.left,
              maxLines: null,
            ),
          ),
        ),
      ),
    );

    const ambient = TextStyle(fontSize: 44);
    await tester.pumpWidget(
      under(ambient, const [
        StrokeLayer(width: 8, paint: SolidPaint(SceneColor(0xFF120720))),
        FillLayer(),
      ]),
    );
    var paint = tester.widget<CustomPaint>(_passes);
    var painter = paint.foregroundPainter! as SceneTextStackPainter;
    var base = tester.widget<Text>(find.byType(Text));
    // The size came from the ambient style, and the passes have to have
    // heard it too — comparing them to each other rather than to a number,
    // because it is their AGREEMENT that keeps one layout.
    expect(painter.style.fontSize, 44);
    expect(
      painter.style,
      base.style!.copyWith(color: painter.style.color),
      reason: 'one resolved style, two consumers',
    );
  });

  testWidgets('the box is the same whether it is painted once or nine times', (
    tester,
  ) async {
    await tester.pumpWidget(_mount(const []));
    var plain = tester.getSize(find.byType(LayeredText));
    await tester.pumpWidget(
      _mount(const [
        FillLayer(paint: SolidPaint(SceneColor(0xFF120720)), dx: 8, dy: 8),
        StrokeLayer(width: 12, paint: SolidPaint(SceneColor(0xFF120720))),
        FillLayer(),
        FillLayer(
          paint: LinearPaint(
            colors: [SceneColor(0xFFFFF3B0), SceneColor(0xFFFFB020)],
          ),
          box: SceneLayerBox.line,
        ),
      ]),
    );
    expect(
      tester.getSize(find.byType(LayeredText)),
      plain,
      reason: 'a pass may change paint, never layout',
    );
  });

  testWidgets('text with no shader pass never listens to time', (tester) async {
    var time = ValueNotifier(Duration.zero);
    await tester.pumpWidget(_mount([const FillLayer()], time: time));
    var painter =
        tester.widget<CustomPaint>(_passes).foregroundPainter!
            as SceneTextStackPainter;
    expect(painter.repaintsOn, isNull);
    time.value = const Duration(seconds: 1);
    expect(tester.renderObject(_passes).debugNeedsPaint, isFalse);
  });

  testWidgets('a shader pass listens to time and to its program', (
    tester,
  ) async {
    var time = ValueNotifier(Duration.zero);
    await tester.pumpWidget(
      _mount([
        const FillLayer(paint: ShaderPaint('test/scene/shaders/probe.frag')),
      ], time: time),
    );
    var painter =
        tester.widget<CustomPaint>(_passes).foregroundPainter!
            as SceneTextStackPainter;
    expect(painter.repaintsOn, isNotNull);
    time.value = const Duration(seconds: 1);
    expect(tester.renderObject(_passes).debugNeedsPaint, isTrue);
  });
}
