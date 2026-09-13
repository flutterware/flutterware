import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/capture/settle.dart';
import 'package:flutterware_app/src/comparison/comparison_controller.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/ui/merged_tree.dart';
import 'package:flutterware_app/src/comparison/ui/scenarios_tab.dart';
import 'package:flutterware_app/src/comparison/ui/step_page.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The three verdicts reached **without replaying anything**, which is the
/// state the tab had no drawing for: `items` is empty by design, so the merged
/// tree drew nothing and picking the row looked like a row that would not open.
void main() {
  var settle = SettleRegistry();

  Future<void> pump(
    WidgetTester tester,
    List<ScenarioComparison> scenarios, {
    String? selected,
    ValueChanged<String>? onSelect,
  }) async {
    var half = ComparisonHalf(
      ComparisonHalfKind.scenarios,
      stage: HalfStage.done,
    );
    for (var scenario in scenarios) {
      half.addScenario(scenario);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ScenariosTab(
            half: half,
            store: _NoShots(),
            settle: settle,
            selected: selected,
            onSelect: onSelect ?? (_) {},
            header: const Text('THE VERDICT'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a skipped scenario says why there is nothing behind it', (
    tester,
  ) async {
    await pump(tester, [
      const ScenarioComparison.notRun(
        scenario: 'test/cart_test.dart#cart',
        state: ComparedState.skipped,
      ),
    ], selected: 'test/cart_test.dart#cart');

    expect(find.text('Not replayed'), findsOneWidget);
    expect(
      find.textContaining('Nothing that decides its pixels changed'),
      findsOneWidget,
    );
  });

  testWidgets('a scenario only this branch has says so in its own words', (
    tester,
  ) async {
    await pump(tester, [
      const ScenarioComparison.notRun(
        scenario: 'test/cart_test.dart#cart',
        state: ComparedState.added,
      ),
    ], selected: 'test/cart_test.dart#cart');

    expect(find.text('Only on this branch'), findsOneWidget);
  });

  testWidgets('a scenario that was replayed still draws its tree', (
    tester,
  ) async {
    await pump(tester, [
      const ScenarioComparison(
        scenario: 'test/cart_test.dart#cart',
        state: ComparedState.changed,
        items: [ComparedItem(id: 'Cart', state: ComparedState.changed)],
        branches: [],
      ),
    ], selected: 'test/cart_test.dart#cart');

    expect(find.text('Not replayed'), findsNothing);
    expect(find.byKey(mergedTreeKey), findsOneWidget);
  });

  /// Pan is per flow. The canvas is unconstrained, so a place scrolled to
  /// in a long flow is blank canvas in a short one — the tree drawn off behind
  /// you, which reads as a flow that failed to draw.
  testWidgets('another flow opens as if it were the first', (tester) async {
    var cart = const ScenarioComparison(
      scenario: 'test/cart_test.dart#cart',
      state: ComparedState.changed,
      items: [ComparedItem(id: 'Cart', state: ComparedState.changed)],
      branches: [],
    );
    var login = const ScenarioComparison(
      scenario: 'test/login_test.dart#login',
      state: ComparedState.changed,
      items: [ComparedItem(id: 'Login', state: ComparedState.changed)],
      branches: [],
    );
    Matrix4 canvas() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value;

    // How the login flow opens on its own.
    await pump(tester, [login], selected: login.scenario);
    var fresh = canvas().clone();
    expect(fresh, isNot(Matrix4.identity()), reason: 'it is placed, not left');

    await pump(tester, [cart, login], selected: cart.scenario);
    tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value = Matrix4.identity()
      ..translateByDouble(-900.0, -600.0, 0, 1);
    await tester.pump();

    await pump(tester, [cart, login], selected: login.scenario);

    expect(canvas(), fresh);
  });

  // It opened at 100% in the pane's corner: the first frame clipped against
  // the list, the flow off the right edge, and nothing saying it would zoom.
  testWidgets('the flow opens inset and fitted, and fits on request', (
    tester,
  ) async {
    await pump(tester, [
      ScenarioComparison(
        scenario: 'test/cart_test.dart#cart',
        state: ComparedState.changed,
        items: [
          for (var n = 0; n < 12; n++)
            ComparedItem(id: 'Step $n', state: ComparedState.changed),
        ],
        branches: const [],
      ),
    ], selected: 'test/cart_test.dart#cart');
    Matrix4 canvas() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value;

    var opened = canvas();
    expect(opened.getTranslation().x, greaterThan(0));
    expect(find.byKey(mergedTreeZoomKey), findsOneWidget);

    await tester.tap(find.byTooltip('Fit to view'));
    await tester.pump();
    expect(
      canvas().getMaxScaleOnAxis(),
      lessThan(opened.getMaxScaleOnAxis()),
      reason: 'twelve steps are wider than the pane',
    );
  });

  testWidgets('opening a step and coming back lands where the canvas was', (
    tester,
  ) async {
    var scenarios = [
      const ScenarioComparison(
        scenario: 'test/cart_test.dart#cart',
        state: ComparedState.changed,
        items: [ComparedItem(id: 'Cart', state: ComparedState.changed)],
        branches: [],
      ),
    ];
    await pump(tester, scenarios, selected: 'test/cart_test.dart#cart');

    var panned = Matrix4.identity()..translateByDouble(-120.0, -80.0, 0, 1);
    tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value =
        panned;
    await tester.pump();

    await pump(tester, scenarios, selected: 'test/cart_test.dart#cart/Cart');
    expect(find.byKey(stepPageKey), findsOneWidget);

    await pump(tester, scenarios, selected: 'test/cart_test.dart#cart');
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value,
      panned,
    );
  });

  // A page reading only `Menu` could be a step of any flow; and reading the
  // next step meant going back to the canvas to find it.
  testWidgets('a step says where it is, and walks to its neighbours', (
    tester,
  ) async {
    var picked = <String>[];
    var scenarios = [
      const ScenarioComparison(
        scenario: 'test/cart_test.dart#Checkout',
        state: ComparedState.changed,
        items: [
          ComparedItem(id: 'Cart', state: ComparedState.same),
          ComparedItem(id: 'Pay', state: ComparedState.changed),
          ComparedItem(id: 'Done', state: ComparedState.same),
        ],
        branches: [],
      ),
    ];

    await pump(
      tester,
      scenarios,
      selected: 'test/cart_test.dart#Checkout/Pay',
      onSelect: picked.add,
    );
    expect(find.text('Step 2 of 3 · Checkout'), findsOneWidget);

    await tester.tap(find.byKey(stepPreviousKey));
    await tester.tap(find.byKey(stepNextKey));
    expect(picked, [
      'test/cart_test.dart#Checkout/Cart',
      'test/cart_test.dart#Checkout/Done',
    ]);

    // At the end of the flow there is no next.
    picked.clear();
    await pump(
      tester,
      scenarios,
      selected: 'test/cart_test.dart#Checkout/Done',
      onSelect: picked.add,
    );
    await tester.tap(find.byKey(stepNextKey), warnIfMissed: false);
    expect(picked, isEmpty);
  });

  // A scenario is named by whoever wrote it, and a name with a `/` in it —
  // `scenario('Contacts & collaboration / Create group')` — used to be cut in
  // half by the address parse. The flow still drew, because the lookup for the
  // scenario falls back; every step id parsed out of the tail matched nothing,
  // so tapping a step selected an address that resolved back to the canvas it
  // came from and the page did nothing at all.
  testWidgets('a scenario named with a slash still opens its steps', (
    tester,
  ) async {
    var scenarios = [
      const ScenarioComparison(
        scenario: 'test/cart_test.dart#Shop & basket / Create cart',
        state: ComparedState.changed,
        items: [ComparedItem(id: 'Cart', state: ComparedState.changed)],
        branches: [],
      ),
    ];

    await pump(
      tester,
      scenarios,
      selected: 'test/cart_test.dart#Shop & basket / Create cart',
    );
    expect(find.byKey(stepPageKey), findsNothing);

    await pump(
      tester,
      scenarios,
      selected: 'test/cart_test.dart#Shop & basket / Create cart/Cart',
    );
    expect(find.byKey(stepPageKey), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);
  });

  // The verdict is about the half. Drawn above the whole tab it stayed on
  // screen over a pushed page about one step, so a header reading `11 steps`
  // sat above a page describing one of them.
  group("the half's verdict", () {
    const one = ScenarioComparison(
      scenario: 'test/cart_test.dart#cart',
      state: ComparedState.changed,
      items: [ComparedItem(id: 'Cart', state: ComparedState.changed)],
      branches: [],
    );

    testWidgets('is drawn over the list', (tester) async {
      await pump(tester, [one], selected: 'test/cart_test.dart#cart');

      expect(find.text('THE VERDICT'), findsOne);
    });

    testWidgets('is not drawn over a pushed step', (tester) async {
      await pump(tester, [one], selected: 'test/cart_test.dart#cart/Cart');

      expect(find.byKey(stepPageKey), findsOne);
      expect(find.text('THE VERDICT'), findsNothing);
    });
  });
}

/// Every frame evicted — the store is not what these tests are about, and a
/// scenario that was never replayed has no frames to open anyway.
class _NoShots implements ShotStore {
  @override
  Future<Shot?> byKey(String key, {int? width}) async => null;

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async => null;
}
