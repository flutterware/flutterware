// The bridge's fidelity contract: the pure core mirrors Flutter's value
// vocabulary, and this file is what keeps the mirror honest — every enum
// order pinned index-by-index, and all 13 curves compared against the
// framework across sampled inputs (the ports are algorithm-identical, so
// equality is exact, not approximate).
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

void main() {
  test('font weights convert by index and agree on the numeric value', () {
    expect(SceneFontWeight.values.length, FontWeight.values.length);
    for (var w in SceneFontWeight.values) {
      expect(w.flutter, FontWeight.values[w.index]);
      expect(w.flutter.value, w.value);
    }
  });

  test('cross-axis alignment order matches Flutter', () {
    expect(
      SceneCrossAxisAlignment.values.map((v) => v.name),
      CrossAxisAlignment.values.map((v) => v.name),
    );
    for (var v in SceneCrossAxisAlignment.values) {
      expect(v.flutter.name, v.name);
    }
  });

  test('main-axis alignment order matches Flutter', () {
    expect(
      SceneMainAxisAlignment.values.map((v) => v.name),
      MainAxisAlignment.values.map((v) => v.name),
    );
    for (var v in SceneMainAxisAlignment.values) {
      expect(v.flutter.name, v.name);
    }
  });

  test('decoration style order matches Flutter, and the line switches', () {
    expect(
      SceneTextDecorationStyle.values.map((v) => v.name),
      TextDecorationStyle.values.map((v) => v.name),
    );
    for (var v in SceneTextDecorationStyle.values) {
      expect(v.flutter.name, v.name);
    }
    // TextDecoration is a combinable set, not an enum: it cannot be indexed
    // and is switched instead, so each member is named here on purpose.
    expect(SceneTextDecoration.none.flutter, TextDecoration.none);
    expect(SceneTextDecoration.underline.flutter, TextDecoration.underline);
    expect(SceneTextDecoration.overline.flutter, TextDecoration.overline);
    expect(SceneTextDecoration.lineThrough.flutter, TextDecoration.lineThrough);
  });

  test('a case is applied to the string, never to the file', () {
    expect(SceneTextCase.none.apply('press start'), 'press start');
    expect(SceneTextCase.upper.apply('press start'), 'PRESS START');
    expect(SceneTextCase.lower.apply('Press START'), 'press start');
    expect(SceneTextCase.title.apply('press start'), 'Press Start');
    expect(SceneTextCase.title.apply(''), '');
  });

  test('colors and rects round-trip through the bridge', () {
    const argb = 0xB34A64D0;
    expect(const SceneColor(argb).flutter.toARGB32(), argb);
    expect(const Color(argb).scene.argb, argb);
    const rect = SceneRect(3.5, -2, 120, 44.25);
    expect(rect.flutter, const Rect.fromLTWH(3.5, -2, 120, 44.25));
    expect(rect.flutter.scene, rect);
  });

  test('blend modes convert by name, and normal is source-over', () {
    expect(SceneBlendMode.normal.flutter, BlendMode.srcOver);
    for (var m in SceneBlendMode.values.skip(1)) {
      expect(m.flutter.name, m.name);
    }
  });

  test('all 13 curves evaluate exactly as Flutter does', () {
    var flutterCurves = <String, Curve>{
      'linear': Curves.linear,
      'ease': Curves.ease,
      'easeIn': Curves.easeIn,
      'easeOut': Curves.easeOut,
      'easeInOut': Curves.easeInOut,
      'easeInBack': Curves.easeInBack,
      'easeOutBack': Curves.easeOutBack,
      'easeInCubic': Curves.easeInCubic,
      'easeOutCubic': Curves.easeOutCubic,
      'decelerate': Curves.decelerate,
      'fastOutSlowIn': Curves.fastOutSlowIn,
      'bounceOut': Curves.bounceOut,
      'elasticOut': Curves.elasticOut,
    };
    expect(sceneCurvesByName.keys.toSet(), flutterCurves.keys.toSet());
    for (var entry in sceneCurvesByName.entries) {
      var flutter = flutterCurves[entry.key]!;
      for (var i = 0; i <= 100; i++) {
        var t = i / 100;
        expect(
          entry.value.transform(t),
          flutter.transform(t),
          reason: '${entry.key} diverges at t=$t',
        );
      }
    }
  });
}
