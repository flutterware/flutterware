import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:brewline/shop/shop_app.dart';

/// The Brewline demo suite. Tap targets are [ShopKeys], so the same flow
/// runs under every language axis; drink names are proper nouns and safe to
/// tap by text.
void main() {
  // The multi-path flagship: one visit to the shop, split at the menu into
  // every way it can go — the flow graph fans out where the app does. Each
  // branch replays the body from the top, so it starts from the exact state
  // the menu was reached with.
  scenario('Around the shop', (s) async {
    await s.pumpWidget(const ShopApp(), shot: Shot('Welcome'));
    await s.tap(ShopKeys.getStarted, shot: Shot('Menu'));
    await s.split({
      'a cappuccino': () async {
        await s.tap('Cappuccino');
        // Splits nest: two cup sizes, and everything after this inner split
        // — the cart, the order — runs once per size, because by then the
        // paths have genuinely diverged.
        await s.split({
          'small cup': () async {
            await s.tap(ShopKeys.size(DrinkSize.small));
            await s.tap(ShopKeys.addToCart, shot: Shot('Cart · small'));
          },
          'large cup': () async {
            await s.tap(ShopKeys.size(DrinkSize.large));
            await s.tap(ShopKeys.addToCart, shot: Shot('Cart · large'));
          },
        });
        await s.enterText(ShopKeys.cupName, 'Ada');
        await s.tap(ShopKeys.placeOrder, shot: Shot('Order placed'));
      },
      'a flat white': () async {
        await s.tap('Flat white');
        await s.tap(ShopKeys.size(DrinkSize.medium));
        await s.tap(ShopKeys.addToCart, shot: Shot('Cart'));
      },
      'a cold brew': () async {
        await s.tap('Cold brew');
        await s.tap(ShopKeys.addToCart, shot: Shot('Cart'));
        await s.tap(ShopKeys.placeOrder, shot: Shot('Order placed'));
      },
      'the empty cart': () async {
        await s.tap(ShopKeys.openCart, shot: Shot('Empty cart'));
        await s.tap(ShopKeys.backToMenu, shot: Shot('Back at the menu'));
      },
    });
  });

  // The linear reference next to the fan-out.
  scenario('Order a cappuccino', (s) async {
    await s.pumpWidget(const ShopApp(), shot: Shot('Welcome'));
    await s.tap(ShopKeys.getStarted, shot: Shot('Menu'));
    await s.tap('Cappuccino');
    await s.tap(ShopKeys.size(DrinkSize.large));
    await s.tap(ShopKeys.addToCart, shot: Shot('Cart'));
    await s.enterText(ShopKeys.cupName, 'Ada');
    await s.tap(ShopKeys.placeOrder, shot: Shot('Order placed'));
  });

  // The one this project ships to the store: `tags: ['store']` is what the
  // listing in `tool/flutterware.dart` narrows to, so the App Store gets five
  // deliberate screenshots, in the order a customer meets them, rather than
  // every frame the suite happens to capture. Each is a screen worth showing
  // — the cart has three drinks in it, not one.
  scenario('A morning order', (s) async {
    await s.pumpWidget(const ShopApp(), shot: Shot('Welcome', tags: _store));
    await s.tap(ShopKeys.getStarted, shot: Shot('Menu', tags: _store));
    await s.tap('Cappuccino');
    await s.tap(ShopKeys.size(DrinkSize.large));
    await s.tap(ShopKeys.milk(Milk.oat));
    await s.tap(ShopKeys.extraShot, shot: Shot('Drink', tags: _store));
    await s.tap(ShopKeys.addToCart);
    // Back to the menu for two more, by the category they are under. The
    // back button is found by type: its tooltip is translated.
    await s.tap(find.byType(BackButton));
    await s.tap(ShopKeys.category(DrinkCategory.iced));
    await s.tap('Cold brew');
    await s.tap(ShopKeys.addToCart);
    await s.tap(find.byType(BackButton));
    await s.tap(ShopKeys.category(DrinkCategory.tea));
    await s.tap('Matcha latte');
    await s.tap(ShopKeys.size(DrinkSize.small));
    await s.tap(ShopKeys.milk(Milk.almond));
    await s.tap(ShopKeys.addToCart);
    await s.tap(ShopKeys.pickup(Pickup.in15), shot: Shot('Cart', tags: _store));
    await s.enterText(ShopKeys.cupName, 'Ada');
    await s.tap(ShopKeys.placeOrder, shot: Shot('Order placed', tags: _store));
  });
}

const _store = ['store'];
