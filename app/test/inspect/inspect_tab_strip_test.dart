import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/inspect/inspect_dock.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The strip had no notion of a tab that cannot be opened, so the one host that
/// needed one enforced it by swallowing the tap: the run cockpit drew all six
/// of its tabs in the normal colour while a build was in flight and answered
/// five of them with nothing. A control that looks alive and is not costs the
/// reader a hypothesis about their own machine.
void main() {
  Future<List<String>> pumpStrip(
    WidgetTester tester, {
    required List<InspectDockTab> tabs,
    String current = 'a',
  }) async {
    var picked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: InspectTabStrip(
            tabs: tabs,
            current: current,
            onSelect: picked.add,
          ),
        ),
      ),
    );
    return picked;
  }

  Widget nothing(BuildContext context) => const SizedBox.shrink();

  testWidgets('a disabled tab does not answer, and an enabled one does', (
    tester,
  ) async {
    var picked = await pumpStrip(
      tester,
      tabs: [
        InspectDockTab(id: 'a', label: 'Alpha', body: nothing),
        InspectDockTab(id: 'b', label: 'Bravo', body: nothing),
        InspectDockTab(
          id: 'c',
          label: 'Charlie',
          enabled: false,
          body: nothing,
        ),
      ],
    );

    await tester.tap(find.text('Charlie'));
    await tester.pump();
    expect(picked, isEmpty);

    await tester.tap(find.text('Bravo'));
    await tester.pump();
    expect(picked, ['b']);
  });

  testWidgets('it says why, and only where there is a why', (tester) async {
    // The label alone cannot carry it: a greyed *Screen* is either "there is no
    // app yet" or "this build cannot do that", and those are a wait and a dead
    // end.
    await pumpStrip(
      tester,
      tabs: [
        InspectDockTab(id: 'a', label: 'Alpha', body: nothing),
        InspectDockTab(
          id: 'c',
          label: 'Charlie',
          enabled: false,
          disabledReason: 'waiting for the app',
          body: nothing,
        ),
        InspectDockTab(id: 'd', label: 'Delta', enabled: false, body: nothing),
      ],
    );

    expect(find.byTooltip('waiting for the app'), findsOneWidget);
    expect(find.byType(Tooltip), findsOneWidget, reason: 'not on the others');
  });

  testWidgets('the current tab loses its underline when it goes dead', (
    tester,
  ) async {
    // A host can be on a tab when the thing behind it stops answering — a run
    // whose app died while its Screen pane was open. Painting the accent under
    // a tab nothing can open makes the strip say two things at once.
    await pumpStrip(
      tester,
      current: 'a',
      tabs: [
        InspectDockTab(id: 'a', label: 'Alpha', enabled: false, body: nothing),
      ],
    );

    var decoration =
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text('Alpha'),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration?;
    expect(decoration!.border!.bottom.color, Colors.transparent);
  });
}
