import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/toolbar.dart';

void main() {
  testWidgets('ToolbarPopover hides options until tapped, then reports taps', (
    tester,
  ) async {
    String? picked;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolbarPopover<String>(
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

    // Collapsed: the trigger shows the selected option; the others are hidden.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Gamma'), findsNothing);

    // Open the popover — every option becomes visible.
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);

    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();
    expect(picked, 'c');
  });
}
