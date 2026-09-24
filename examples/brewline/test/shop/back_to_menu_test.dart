import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:brewline/shop/shop_app.dart';

/// Brewline's two ways back to the menu — and the thing that is easy to get
/// wrong about both.
///
/// The menu is already the *first* route: `WelcomeScreen` reaches it by
/// replacing itself. So a "back to menu" button that pushes a replacement
/// leaves two menus stacked, and the one on top wears a back arrow pointing at
/// the one underneath. Nothing about that fails a flow test — you do arrive at
/// a menu — which is why it survived until somebody looked at the screen.
void main() {
  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(const ShopApp());
    // The shop's copy is loaded from `assets/i18n/`, so the first frame has no
    // strings and therefore no screen to tap. One settle is the whole cost of
    // a catalog that is read rather than compiled in — and it is what any
    // app loading its translations asynchronously already pays.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ShopKeys.getStarted));
    await tester.pumpAndSettle();
  }

  /// One menu, and no way back out of it — the same state `Get started` leaves.
  void expectAtTheMenuAlone(WidgetTester tester) {
    expect(find.byType(MenuScreen), findsOneWidget);
    expect(
      find.byType(BackButton),
      findsNothing,
      reason: 'a second menu would carry a back arrow to the first',
    );
  }

  testWidgets('the empty cart offers a way back to the menu', (tester) async {
    await start(tester);

    await tester.tap(find.byKey(ShopKeys.openCart));
    await tester.pumpAndSettle();
    expect(find.text('Your cart is empty.'), findsOneWidget);

    await tester.tap(find.byKey(ShopKeys.backToMenu));
    await tester.pumpAndSettle();

    expectAtTheMenuAlone(tester);
  });

  testWidgets('the confirmation goes back to one menu, not onto a second', (
    tester,
  ) async {
    await start(tester);

    // Below the fold on a test's 800×600 surface, so reached the way a
    // customer would: through its category.
    await tester.tap(find.byKey(ShopKeys.category(DrinkCategory.iced)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cold brew'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ShopKeys.addToCart));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ShopKeys.placeOrder));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmationScreen), findsOneWidget);

    await tester.tap(find.byKey(ShopKeys.backToMenu));
    await tester.pumpAndSettle();

    expectAtTheMenuAlone(tester);
    expect(
      find.byType(ConfirmationScreen),
      findsNothing,
      reason: 'the order is done; it should not be behind the menu',
    );
  });
}
