// The paint field's own arithmetic, driven through the real widget: a
// centre field rounds what it writes, and a sweep's "From" turns the arc
// rather than shrinking it.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/ui/number_field.dart';
import 'package:flutterware_app/src/scene/ui/paint_field.dart';
import 'package:flutterware_app/src/ui/theme.dart';

const _red = SceneColor(0xFFFF0000);
const _blue = SceneColor(0xFF0000FF);

void main() {
  ScenePaint? result;

  Future<void> pump(WidgetTester tester, ScenePaint paint) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: ScenePaintField(
                paint: paint,
                own: _red,
                onChanged: (next, {required label, mergeKey}) => result = next,
              ),
            ),
          ),
        ),
      ),
    );
  }

  SceneNumberField field(WidgetTester tester, String label) =>
      tester.widget<SceneNumberField>(
        find.byWidgetPredicate(
          (w) => w is SceneNumberField && w.label == label,
        ),
      );

  testWidgets('a centre field rounds what it writes, positive zero included', (
    tester,
  ) async {
    await pump(tester, const RadialPaint(colors: [_red, _blue]));
    field(tester, 'Centre X').onCommit(33);
    expect((result! as RadialPaint).center.x, -0.34);
    field(tester, 'Centre X').onCommit(50);
    expect((result! as RadialPaint).center.x, 0);
    expect((result! as RadialPaint).center.x.isNegative, isFalse);
  });

  testWidgets("a sweep's From turns the arc, keeping its width", (
    tester,
  ) async {
    await pump(tester, const SweepPaint(colors: [_red, _blue]));
    field(tester, 'From').onCommit(90);
    var turned = result! as SweepPaint;
    expect(turned.startAngle, 90);
    expect(turned.endAngle, 450);
  });
}
