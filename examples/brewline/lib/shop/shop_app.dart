import 'package:material_ui/material_ui.dart';

import 'drink_art.dart';
import 'shop_screens.dart';
import 'shop_strings.dart';

export 'drink_art.dart';
export 'shop_screens.dart';
export 'shop_strings.dart';

/// Brewline — the scenario demo app: a small coffee shop that looks like a
/// product rather than a fixture. Welcome → menu → drink → cart →
/// confirmation, localized in English and French, themed light and dark, so
/// every axis of the scenario runner has something real to move.
///
/// Interactive targets carry [ShopKeys], which is what lets one scenario run
/// under every language: `tap(ShopKeys.addToCart)` does not care what the
/// button says.
class ShopApp extends StatefulWidget {
  const ShopApp({
    super.key,
    this.navigatorKey,
    this.overlay,
    this.home,
    this.cart,
    this.themeMode,
    this.locale,
  });

  /// The first screen — the welcome screen unless a preview asks for another,
  /// which is how one of the shop's screens is drawn on its own with the
  /// shop's theme, strings and cart around it.
  final Widget? home;

  /// A cart to start with, so a preview of the cart has something in it.
  final Cart? cart;

  /// Both null in the app, where the platform decides. A preview turns them.
  final ThemeMode? themeMode;
  final Locale? locale;

  /// Reaches the navigator from outside the widget tree. Ordinary app
  /// machinery: a notification tapped on a lock screen is delivered to a
  /// callback, not to a widget, so something has to hold the key.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Painted above every screen, below nothing. Brewline has nothing of its
  /// own to put here; the push demo puts its banner there.
  final Widget? overlay;

  @override
  State<ShopApp> createState() => _ShopAppState();
}

class _ShopAppState extends State<ShopApp> {
  late final _cart = widget.cart ?? Cart();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brewline',
      debugShowCheckedModeBanner: false,
      supportedLocales: const [Locale('en'), Locale('fr')],
      localizationsDelegates: const [
        ShopStrings.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      theme: shopTheme(Brightness.light),
      darkTheme: shopTheme(Brightness.dark),
      themeMode: widget.themeMode,
      locale: widget.locale,
      navigatorKey: widget.navigatorKey,
      // Above the navigator, so every pushed route sees the cart.
      builder: (context, child) => CartScope(
        cart: _cart,
        child: widget.overlay == null
            ? child!
            : Stack(
                children: [
                  child!,
                  // Positioned rather than a plain child: an overlay sized to
                  // the whole stack would swallow every tap meant for the app
                  // underneath it.
                  Positioned(top: 0, left: 0, right: 0, child: widget.overlay!),
                ],
              ),
      ),
      home: widget.home ?? const WelcomeScreen(),
    );
  }
}

/// Brewline's own look, public so that a preview of one screen is a preview of
/// the app rather than of Material's defaults.
///
/// A screen previewed under a different theme is a picture of a shop nobody
/// ships, which is the failure mode a catalog exists to prevent — so the app
/// and `demo/shop.dart` read the same function rather than each describing the
/// brown they think the coffee is.
ThemeData shopTheme(Brightness brightness) {
  var scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6F4E37),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

/// The stable identities scenarios drive — translation-proof tap targets.
class ShopKeys {
  static const getStarted = Key('shop.getStarted');
  static const addToCart = Key('shop.addToCart');
  static const cupName = Key('shop.cupName');
  static const placeOrder = Key('shop.placeOrder');
  static const backToMenu = Key('shop.backToMenu');
  static const openCart = Key('shop.openCart');
  static const seasonal = Key('shop.seasonal');
  static const extraShot = Key('shop.extraShot');
  static Key size(DrinkSize size) => Key('shop.size.${size.name}');
  static Key milk(Milk milk) => Key('shop.milk.${milk.name}');
  static Key category(DrinkCategory? category) =>
      Key('shop.category.${category?.name ?? 'all'}');
  static Key pickup(Pickup pickup) => Key('shop.pickup.${pickup.name}');
}

enum DrinkSize { small, medium, large }

enum Milk { whole, oat, almond }

enum DrinkCategory { coffee, tea, iced }

/// When the order is collected. The shop brews to it, so the drink is warm
/// when you arrive rather than when it was ready.
enum Pickup { asap, in15, in30 }

class Drink {
  const Drink(
    this.id,
    this.name,
    this.price,
    this.look, {
    required this.category,
  });

  /// Also the key into [ShopStrings.describe] — proper nouns stay
  /// untranslated, descriptions do not.
  final String id;

  final String name;
  final double price;
  final DrinkLook look;
  final DrinkCategory category;

  /// Whether a milk is poured into it. A cold brew is served black.
  bool get takesMilk => category != DrinkCategory.iced;
}

/// The shop's own colour and copy style, named so a scene can read them:
/// `demo/scenes.dart` exports these, and the scene editor offers them by
/// name — the canvas, which is this app, draws the value.
const brandColor = Color(0xFF6F4E37);
const subtitleStyle = TextStyle(
  fontSize: 18,
  fontStyle: FontStyle.italic,
  color: Color(0xFFD8C9BD),
);

const drinks = [
  Drink(
    'cappuccino',
    'Cappuccino',
    4.20,
    DrinkLook(
      top: DrinkTop.heart,
      liquid: Color(0xFF8B5A3C),
      foam: Color(0xFFFBF3E8),
      ground: (Color(0xFFB08968), Color(0xFF7F5539)),
    ),
    category: DrinkCategory.coffee,
  ),
  Drink(
    'flat-white',
    'Flat white',
    4.60,
    DrinkLook(
      top: DrinkTop.tulip,
      liquid: Color(0xFF9C6B47),
      foam: Color(0xFFFFF8EE),
      ground: (Color(0xFFDDB892), Color(0xFFB08968)),
    ),
    category: DrinkCategory.coffee,
  ),
  Drink(
    'matcha',
    'Matcha latte',
    5.10,
    DrinkLook(
      top: DrinkTop.heart,
      liquid: Color(0xFF7E9F4B),
      foam: Color(0xFFEEF2D8),
      ground: (Color(0xFF9CAF88), Color(0xFF606C38)),
    ),
    category: DrinkCategory.tea,
  ),
  Drink(
    'chai',
    'Chai latte',
    4.80,
    DrinkLook(
      top: DrinkTop.dusted,
      liquid: Color(0xFFB0784A),
      foam: Color(0xFFF5E6D3),
      ground: (Color(0xFFE6B980), Color(0xFFB4764F)),
    ),
    category: DrinkCategory.tea,
  ),
  Drink(
    'cold-brew',
    'Cold brew',
    3.90,
    DrinkLook(
      top: DrinkTop.iced,
      liquid: Color(0xFF3A2618),
      foam: Color(0xFFF2E6D8),
      ground: (Color(0xFF8D99AE), Color(0xFF2B2D42)),
    ),
    category: DrinkCategory.iced,
  ),
];

/// The season's drink: on the menu's banner rather than in its list.
const seasonal = Drink(
  'maple',
  'Maple oat latte',
  5.40,
  DrinkLook(
    top: DrinkTop.drizzle,
    liquid: Color(0xFFC0823F),
    foam: Color(0xFFFBEFDD),
    ground: (Color(0xFFE9A15F), Color(0xFF9C5A2A)),
  ),
  category: DrinkCategory.coffee,
);

String formatPrice(double price) => '${price.toStringAsFixed(2)} €';

class CartItem {
  const CartItem(
    this.drink,
    this.size, {
    this.milk = Milk.whole,
    this.extraShot = false,
  });

  final Drink drink;
  final DrinkSize size;
  final Milk milk;
  final bool extraShot;

  double get price =>
      drink.price +
      switch (size) {
        DrinkSize.small => -0.5,
        DrinkSize.medium => 0.0,
        DrinkSize.large => 0.7,
      } +
      (drink.takesMilk && milk != Milk.whole ? 0.3 : 0) +
      (extraShot ? 0.6 : 0);
}

/// The cart, scoped to the app — a demo does not need more state machinery
/// than an inherited notifier.
class Cart extends ChangeNotifier {
  final items = <CartItem>[];

  double get total => items.fold(0, (sum, item) => sum + item.price);

  void add(CartItem item) {
    items.add(item);
    notifyListeners();
  }

  void clear() {
    items.clear();
    notifyListeners();
  }

  static Cart of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CartScope>()!.notifier!;
}

class CartScope extends InheritedNotifier<Cart> {
  const CartScope({super.key, required Cart cart, required super.child})
    : super(notifier: cart);
}

/// The round drink artwork — see [DrinkArt].
class DrinkBadge extends StatelessWidget {
  const DrinkBadge(this.drink, {super.key, this.size = 56});

  final Drink drink;
  final double size;

  @override
  Widget build(BuildContext context) => DrinkArt(drink.look, size: size);
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [scheme.primaryContainer, scheme.surface],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Center(
                    child: DrinkBadge(
                      drinks.first,
                      size: (box.maxHeight * 0.3).clamp(150, 240),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    strings.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.tagline,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  for (var (icon, text) in [
                    (Icons.phone_iphone_rounded, strings.perkOrderAhead),
                    (Icons.bolt_rounded, strings.perkSkipQueue),
                    (Icons.local_cafe_outlined, strings.perkReady),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: _Perk(icon: icon, text: text),
                    ),
                  const Spacer(flex: 2),
                  FilledButton(
                    key: ShopKeys.getStarted,
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => const MenuScreen(),
                      ),
                    ),
                    child: Text(strings.getStarted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  const _Perk({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 19, color: scheme.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

/// A busy indicator at whatever size it is asked for.
///
/// It lives here rather than in a lambda beside the scene that places it:
/// a scene names the app's widgets, and this is one of them.
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: const CircularProgressIndicator(strokeWidth: 3),
  );
}

/// The call to action, so a scene can place the real button rather than a
/// rectangle that looks like one.
class OrderButton extends StatelessWidget {
  const OrderButton({super.key, this.label = 'Order now', this.style});

  final String label;

  /// The look, when a scene hands one over — the app's own [ButtonStyle],
  /// declared once as a token. Null is the theme's button.
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) =>
      FilledButton(onPressed: () {}, style: style, child: Text(label));
}
