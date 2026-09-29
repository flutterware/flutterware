import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/json_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> pumpAt(WidgetTester tester, double width) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const JsonView(
              data: {'id': 'u4', 'name': 'Mia', 'role': 'customer'},
            ),
          ),
        ),
      ),
    ),
  );

  double? searchWidth(WidgetTester tester) {
    var field = find.byType(TextField);
    return field.evaluate().isEmpty ? null : tester.getSize(field).width;
  }

  testWidgets('the toolbar fits a narrow pane: the search field shrinks, '
      'then goes, before anything overflows', (tester) async {
    await pumpAt(tester, 600);
    expect(searchWidth(tester), 180);

    // Run's network detail, beside its list in a person's panel.
    await pumpAt(tester, 300);
    expect(tester.takeException(), isNull);
    expect(searchWidth(tester), inInclusiveRange(96, 179));

    await pumpAt(tester, 200);
    expect(tester.takeException(), isNull);
    expect(searchWidth(tester), isNull);
  });
}
