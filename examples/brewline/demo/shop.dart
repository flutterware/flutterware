import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews.dart';
import 'package:brewline/shop/shop_app.dart';

/// Brewline's screens, one preview each.
///
/// The app the scenarios drive, taken apart: `test/scenarios/mobile/shop_test.dart`
/// walks welcome → menu → drink → cart → confirmation as one flow, and these
/// are the same screens standing still, where a spacing or a dark-mode
/// question can be answered without replaying four taps to reach the screen
/// that asks it.
///
/// Every entry goes through [wrapInShop]: these screens read
/// `Cart.of(context)` and `ShopStrings.of(context)`, so a bare widget throws.
/// That is the ordinary case for previewing a screen out of an app, and the
/// wrapper is the ordinary answer to it.

/// The shell is the shop itself: `ShopApp` takes the screen as its home, so a
/// preview reads the app's theme, strings and cart rather than a copy of
/// them, and the two axes a reader can turn are the ones the app supports —
/// dark, and the two languages of its strings.
///
/// [cart] is how a screen that is only interesting with contents gets some —
/// an empty cart screen is a picture of the empty state, which is worth having
/// too, and is what the default gives. A `Cart` per build rather than a
/// shared one: a preview rebuilds whenever a knob moves, and a cart that
/// accumulated a cappuccino on every rebuild would tell you about the preview
/// rather than about the screen.
Widget wrapInShop(Widget child, {Cart Function()? cart}) => PreviewShell(
  'shop',
  builder: (context, axes) => ShopApp(
    home: child,
    cart: cart?.call(),
    themeMode: axes.flag('dark', false) ? ThemeMode.dark : ThemeMode.light,
    locale: axes.picker('locale', {
      'English': const Locale('en'),
      'Français': const Locale('fr'),
    }, const Locale('en')),
  ),
);

/// Public because `@Preview` only accepts public symbols as arguments — the
/// annotation is read by the analyzer, not called.
Widget wrapWithFullCart(Widget child) => wrapInShop(
  child,
  cart: () => Cart()
    ..add(CartItem(drinks[0], DrinkSize.large))
    ..add(CartItem(drinks[2], DrinkSize.small)),
);

@Preview(name: 'Welcome', group: 'Brewline', wrapper: wrapInShop)
Widget shopWelcome() => const WelcomeScreen();

@Preview(name: 'Menu', group: 'Brewline', wrapper: wrapInShop)
Widget shopMenu() => const MenuScreen();

@Preview(name: 'A drink', group: 'Brewline', wrapper: wrapInShop)
Widget shopDrink() => DrinkScreen(drinks.first);

@Preview(name: 'Cart', group: 'Brewline', wrapper: wrapWithFullCart)
Widget shopCart() => const CartScreen();

/// The one screen with a word of the customer's on it, so the word is a knob.
@Preview(name: 'Order placed', group: 'Brewline', wrapper: wrapInShop)
Widget shopConfirmation() => Builder(
  builder: (context) =>
      ConfirmationScreen(name: context.knobs.string('name', 'Ada')),
);

/// One component in every state it has, on one sheet — the badge that
/// stands for a drink, for every drink at the three sizes the screens use.
/// Not a screen: what a reader checks here is that the set reads as one
/// family, which no screen shows at once.
@Preview(name: 'Drink badges', group: 'Brewline', wrapper: wrapInShop)
Widget shopBadges() => const _BadgeSheet();

class _BadgeSheet extends StatelessWidget {
  const _BadgeSheet();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        for (var size in const [40.0, 56.0, 80.0]) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${size.round()} points',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var drink in drinks) DrinkBadge(drink, size: size),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}
