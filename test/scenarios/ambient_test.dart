import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart' as ft;
import 'package:flutterware/ambient.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// `Ambient`: motion the app declares carries no information, photographed
/// standing still under a scenario and left alone everywhere else.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  ft.testWidgets('outside a scenario it is its child', (tester) async {
    await tester.pumpWidget(const _Orders());
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(_controllerOf(tester), isNull);
  });

  group('under a scenario the step settles on a spinner declared ambient', () {
    scenario('and draws it at one phase', (s) async {
      await s.pumpWidget(const _Orders());
      expect(s.tester.binding.hasScheduledFrame, isFalse);
      expect(_controllerOf(s.tester)?.value, 0.3);
    });
    tearDown(() {
      expect(captures.single.settled, isTrue);
      expect(captures.single.stillTicking, isEmpty);
    });
  });

  group('a spinner nobody declared still does not', () {
    scenario('beside one that was', (s) async {
      await s.pumpWidget(const _Orders(undeclared: true));
    });
    tearDown(() {
      expect(captures.single.settled, isFalse);
      expect(captures.single.stillTicking, [
        startsWith('CircularProgressIndicator (test/scenarios/ambient_test'),
      ]);
    });
  });

  group('Settle.strict still fails a step with one on screen', () {
    scenario('frozen or not', settle: Settle.strict, (s) async {
      await expectLater(
        () => s.pumpWidget(const _Orders()),
        throwsA(
          isA<ScenarioStillAnimating>().having(
            (e) => '$e',
            'message',
            allOf(contains('left an `Ambient` on screen'), contains('strict')),
          ),
        ),
      );
    });
  });

  group('and passes the step once it is gone', () {
    scenario('by the verb that removed it', settle: Settle.strict, (s) async {
      await s.pumpWidget(const _Orders(), settle: Settle.standard);
      await s.tap('Show shipped only');
    });
    tearDown(() => expect(captures.last.failure, isNull));
  });

  // Declared after the scenarios, so it runs after them in the same process.
  ft.testWidgets('a widget test after a scenario gets the motion back', (
    tester,
  ) async {
    await tester.pumpWidget(const _Orders());
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(_controllerOf(tester), isNull);
  });
}

/// The controller the ambient spinner draws from — the theme's, since it has
/// none of its own.
AnimationController? _controllerOf(ft.WidgetTester tester) =>
    ProgressIndicatorTheme.of(
      tester.element(find.byKey(const ValueKey('packing'))),
    ).controller;

class _Orders extends StatefulWidget {
  const _Orders({this.undeclared = false});

  final bool undeclared;

  @override
  State<_Orders> createState() => _OrdersState();
}

class _OrdersState extends State<_Orders> {
  var _shippedOnly = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          TextButton(
            onPressed: () {
              setState(() => _shippedOnly = true);
            },
            child: const Text('Show shipped only'),
          ),
          const ListTile(title: Text('Shipped'), trailing: Icon(Icons.check)),
          if (!_shippedOnly)
            const ListTile(
              title: Text('Packing'),
              trailing: Ambient(
                child: CircularProgressIndicator(key: ValueKey('packing')),
              ),
            ),
          if (widget.undeclared)
            const ListTile(
              title: Text('Returning'),
              trailing: CircularProgressIndicator(),
            ),
        ],
      ),
    ),
  );
}
