import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/toolbar.dart';

void main() {
  testWidgets('ToolbarSegmented shows every option inline and reports taps', (
    tester,
  ) async {
    String? picked;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolbarSegmented<String>(
            value: 'a',
            onChanged: (v) => picked = v,
            title: const Text('Theme'),
            items: const {
              'a': Text('Alpha'),
              'b': Text('Beta'),
              'c': Text('Gamma'),
            },
          ),
        ),
      ),
    );

    // All options are visible at once (unlike the dropdown ToolbarPicker).
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);

    await tester.tap(find.text('Gamma'));
    expect(picked, 'c');
  });
}
