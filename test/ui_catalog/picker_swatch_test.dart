import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/knobs.dart';

enum _Theme { light, dark }

void main() {
  test('picker carries swatch/icon onto the PickerKnob', () {
    final knobs = EditableKnobs(onRefresh: () {}, onAdded: () {});

    final picked = knobs.picker<_Theme>(
      'Theme',
      {'Light': _Theme.light, 'Dark': _Theme.dark},
      _Theme.light,
      swatch: (t) => t == _Theme.light ? Colors.white : Colors.black,
      icon: (t) => Icons.palette,
    );

    expect(picked, _Theme.light);
    final p = knobs.knobs['Theme']! as PickerKnob<_Theme>;
    expect(p.swatch, isNotNull);
    expect(p.icon, isNotNull);
    expect(p.swatch!(_Theme.dark), Colors.black);
  });

  testWidgets('pickerOptionWidget draws a swatch dot before the label', (
    tester,
  ) async {
    final p = PickerKnob<_Theme>(
      options: {'Light': _Theme.light, 'Dark': _Theme.dark},
      swatch: (t) => t == _Theme.light ? Colors.white : Colors.black,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: pickerOptionWidget(p, 'Dark', _Theme.dark)),
      ),
    );

    expect(find.text('Dark'), findsOneWidget);
    final decoration =
        tester.widget<Container>(find.byType(Container)).decoration!
            as BoxDecoration;
    expect(decoration.color, Colors.black);
    expect(decoration.shape, BoxShape.circle);
  });
}
