// The stop bar, driven the way a hand drives it: a tap on the bar adds a
// stop, a drag moves one past its neighbour, and the last two stay.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/ui/gradient_field.dart';
import 'package:flutterware_app/src/ui/theme.dart';

const _red = SceneColor(0xFFFF0000);
const _green = SceneColor(0xFF00FF00);
const _blue = SceneColor(0xFF0000FF);

void main() {
  late SceneGradient current;
  late List<String> labels;

  Future<void> pump(WidgetTester tester, SceneGradient g) async {
    current = g;
    labels = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: Center(
            child: SizedBox(
              width: 240,
              child: StatefulBuilder(
                builder: (context, setState) => SceneGradientField(
                  gradient: current,
                  onChanged: (next, {required label, mergeKey}) {
                    labels.add(label);
                    setState(() => current = next);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a tap on the bar adds a stop there, in the colour there', (
    tester,
  ) async {
    await pump(tester, const LinearPaint(colors: [_red, _blue]));
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('gradient:bar'))),
    );
    await tester.pump();
    expect(current.colors, hasLength(3));
    expect(current.resolvedStops[1], closeTo(0.5, 0.01));
    expect(labels, ['Add stop']);
  });

  testWidgets('a stop dragged past its neighbour is re-sorted', (tester) async {
    await pump(tester, const LinearPaint(colors: [_red, _green, _blue]));
    // The track is 240 less a 12px handle: 180px is ~0.79 of the way,
    // past green at 0.5.
    await tester.drag(
      find.byKey(const ValueKey('gradient:stop:0')),
      const Offset(180, 0),
    );
    await tester.pump();
    expect(current.colors, [_green, _red, _blue]);
    expect(current.resolvedStops[1], closeTo(0.79, 0.01));
  });

  testWidgets('removing stops refuses the last two', (tester) async {
    await pump(tester, const LinearPaint(colors: [_red, _green, _blue]));
    await tester.tap(find.byKey(const ValueKey('gradient:stop:1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('gradient:remove')));
    await tester.pump();
    expect(current.colors, [_red, _blue]);
    await tester.tap(find.byKey(const ValueKey('gradient:remove')));
    await tester.pump();
    expect(current.colors, [_red, _blue]);
    expect(labels, ['Remove stop']);
  });

  testWidgets(
    'a pending edit survives an unrelated rebuild, only the echo clears it',
    (tester) async {
      late StateSetter rebuild;
      var recorded = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Material(
            child: Center(
              child: SizedBox(
                width: 240,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return SceneGradientField(
                      // The parent never feeds the edit back — its echo
                      // has not arrived yet — so this stays the two-stop
                      // gradient throughout.
                      gradient: const LinearPaint(colors: [_red, _blue]),
                      onChanged: (next, {required label, mergeKey}) =>
                          recorded.add(label),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('gradient:bar'))),
      );
      await tester.pump();

      // An ancestor rebuild unrelated to the gradient: same value, just a
      // new SceneGradientField instance for the element to diff against.
      rebuild(() {});
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('gradient:remove')));
      await tester.pump();

      expect(recorded, ['Add stop', 'Remove stop']);
    },
  );
}
