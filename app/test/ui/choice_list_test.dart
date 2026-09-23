// The list's one mechanic a picker does not have: a control that belongs to
// one row, built only while that row is the answer.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/choice_list.dart';
import 'package:flutterware_app/src/ui/theme.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required String selected,
    required ValueChanged<String> onChanged,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: FwChoiceList<String>(
          choices: const [
            FwChoiceRow(
              value: 'demo',
              label: 'demo',
              detail: 'demo · 8 scenes',
            ),
            FwChoiceRow(value: 'new', label: 'A new folder…'),
            FwChoiceRow(value: 'locked', label: 'Locked', enabled: false),
          ],
          selected: selected,
          onChanged: onChanged,
          below: (context, value) =>
              value == 'new' ? const Text('a path field') : const Text('—'),
        ),
      ),
    ),
  );

  testWidgets('the row is chosen by tapping it, and only enabled rows are', (
    tester,
  ) async {
    var picked = <String>[];
    await mount(tester, selected: 'demo', onChanged: picked.add);

    await tester.tap(find.text('A new folder…'));
    expect(picked, ['new']);

    await tester.tap(find.text('Locked'));
    expect(picked, ['new'], reason: 'a disabled row is listed, not tappable');
  });

  testWidgets('what hangs under a row is built for the chosen row alone', (
    tester,
  ) async {
    // The whole reason this is not a picker: an unselected row with its field
    // showing is a second answer to a question that has one.
    await mount(tester, selected: 'demo', onChanged: (_) {});
    expect(find.text('a path field'), findsNothing);
    expect(find.text('—'), findsOneWidget);

    await mount(tester, selected: 'new', onChanged: (_) {});
    expect(find.text('a path field'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('a detail is a line of its own, not a suffix', (tester) async {
    await mount(tester, selected: 'demo', onChanged: (_) {});
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('demo · 8 scenes'), findsOneWidget);
  });
}
