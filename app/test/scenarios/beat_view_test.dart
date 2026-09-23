import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_results.dart';
import 'package:flutterware_app/src/scenarios/beat_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// A setup beat has no picture; its card is what it did to the backend.
void main() {
  ScenarioRunStep setup({List<String>? titles, int? ms, int exchanges = 0}) =>
      ScenarioRunStep(
        index: 1,
        position: '#1',
        auto: false,
        kind: ScenarioStepKind.setup,
        name: 'an account, confirmed over the API',
        ms: ms,
        eventCount: exchanges + 1,
        eventChannels: {'system': 1, if (exchanges > 0) 'network': exchanges},
        eventTitles: titles,
      );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('a setup beat draws its name, its facts and its exchanges', (
    tester,
  ) async {
    await pump(
      tester,
      ScenarioBeatShot(
        step: setup(
          ms: 154,
          exchanges: 2,
          titles: const [
            'POST http://localhost:5119/api/auth/register → 200',
            'POST http://localhost:5119/api/account → 200',
          ],
        ),
        background: null,
        device: null,
        statusFallback: Brightness.dark,
      ),
    );
    expect(find.text('an account, confirmed over the API'), findsOneWidget);
    expect(find.text('154 ms · 2 exchanges'), findsOneWidget);
    expect(
      find.text('POST http://localhost:5119/api/account → 200'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.description_outlined), findsNothing);
  });

  testWidgets('a setup beat that stayed off the wire says so', (tester) async {
    await pump(
      tester,
      ScenarioBeatShot(
        step: setup(ms: 3),
        background: null,
        device: null,
        statusFallback: Brightness.dark,
      ),
    );
    expect(find.text('3 ms'), findsOneWidget);
    expect(find.text('Nothing went over the wire.'), findsOneWidget);
  });

  test('the facts line is empty when nothing is known', () {
    expect(scenarioSetupFacts(setup()), '');
    expect(scenarioSetupFacts(setup(exchanges: 1)), '1 exchange');
    expect(scenarioBeatFallbackName(setup()), 'setup');
  });
}
