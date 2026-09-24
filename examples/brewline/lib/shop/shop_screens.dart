import 'package:material_ui/material_ui.dart';

import 'mini_markdown.dart';
import 'shop_app.dart';

/// Leaves whatever you are on and lands on the menu, as the root.
///
/// Not `pop`, and not `pushReplacement`. The menu is already the first route —
/// `WelcomeScreen` gets there by replacing itself — so replacing the top of the
/// stack with another menu leaves *two*, and the second one wears a back arrow
/// pointing at the first. Clearing the stack puts you exactly where `Get
/// started` does.
void backToMenu(BuildContext context) => Navigator.of(context)
    .pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const MenuScreen()),
      (route) => false,
    );

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  /// The category the list is narrowed to, or null for all of them.
  DrinkCategory? _category;

  void _open(Drink drink) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => DrinkScreen(drink)));

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var cart = Cart.of(context);
    var shown = [
      for (var drink in drinks)
        if (_category == null || drink.category == _category) drink,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.menuTitle),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Badge(
              isLabelVisible: cart.items.isNotEmpty,
              label: Text('${cart.items.length}'),
              child: IconButton(
                key: ShopKeys.openCart,
                icon: const Icon(Icons.shopping_bag_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const CartScreen()),
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          Row(
            children: [
              Icon(Icons.storefront_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.pickupFrom,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                strings.readyIn(6),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SeasonalCard(onTap: () => _open(seasonal)),
          const SizedBox(height: 18),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var (category, label) in [
                  (null, strings.categoryAll),
                  (DrinkCategory.coffee, strings.categoryCoffee),
                  (DrinkCategory.tea, strings.categoryTea),
                  (DrinkCategory.iced, strings.categoryIced),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ShopKeys.category(category),
                      label: Text(label),
                      selected: _category == category,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _category = category),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (var drink in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DrinkTile(drink, onTap: () => _open(drink)),
            ),
        ],
      ),
    );
  }
}

/// The season's drink, on a banner above the list.
class SeasonalCard extends StatelessWidget {
  const SeasonalCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var (light, dark) = seasonal.look.ground;
    const ink = Color(0xFFFFF6EC);
    return Material(
      key: ShopKeys.seasonal,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(dark, Colors.black, 0.25)!,
              Color.lerp(light, dark, 0.35)!,
            ],
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: ink.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          strings.seasonalLabel.toUpperCase(),
                          style: const TextStyle(
                            color: ink,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        seasonal.name,
                        style: const TextStyle(
                          color: ink,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        strings.describe(seasonal.id),
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.8),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        formatPrice(seasonal.price),
                        style: const TextStyle(
                          color: ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DrinkArt(seasonal.look, size: 112, ground: false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One drink in the menu's list.
class DrinkTile extends StatelessWidget {
  const DrinkTile(this.drink, {super.key, required this.onTap});

  final Drink drink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              DrinkBadge(drink, size: 60),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drink.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      strings.describe(drink.id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                formatPrice(drink.price),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DrinkScreen extends StatefulWidget {
  const DrinkScreen(this.drink, {super.key});

  final Drink drink;

  @override
  State<DrinkScreen> createState() => _DrinkScreenState();
}

class _DrinkScreenState extends State<DrinkScreen> {
  var _size = DrinkSize.medium;
  var _milk = Milk.whole;
  var _extraShot = false;

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var drink = widget.drink;
    var item = CartItem(drink, _size, milk: _milk, extraShot: _extraShot);
    var (light, dark) = drink.look.ground;
    return Scaffold(
      appBar: AppBar(title: Text(drink.name)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              children: [
                Container(
                  height: 200,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [light, dark],
                    ),
                  ),
                  child: DrinkArt(drink.look, size: 176, ground: false),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        strings.describe(drink.id),
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      formatPrice(drink.price),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _Label(strings.size),
                ChoiceRow(
                  values: DrinkSize.values,
                  selected: _size,
                  keyOf: ShopKeys.size,
                  labelOf: (size) => switch (size) {
                    DrinkSize.small => strings.sizeSmall,
                    DrinkSize.medium => strings.sizeMedium,
                    DrinkSize.large => strings.sizeLarge,
                  },
                  onSelected: (size) => setState(() => _size = size),
                ),
                if (drink.takesMilk) ...[
                  const SizedBox(height: 18),
                  _Label(strings.milk),
                  ChoiceRow(
                    values: Milk.values,
                    selected: _milk,
                    keyOf: ShopKeys.milk,
                    labelOf: (milk) => switch (milk) {
                      Milk.whole => strings.milkWhole,
                      Milk.oat => strings.milkOat,
                      Milk.almond => strings.milkAlmond,
                    },
                    onSelected: (milk) => setState(() => _milk = milk),
                  ),
                ],
                const SizedBox(height: 10),
                SwitchListTile(
                  key: ShopKeys.extraShot,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    strings.extraShot,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text('+ ${formatPrice(0.6)}'),
                  value: _extraShot,
                  onChanged: (value) => setState(() => _extraShot = value),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: FilledButton(
              key: ShopKeys.addToCart,
              onPressed: () {
                Cart.of(context).add(item);
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => const CartScreen()),
                );
              },
              child: Text('${strings.addToCart} · ${formatPrice(item.price)}'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
  );
}

/// One of a few, as a row of chips of equal width.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.values,
    required this.selected,
    required this.keyOf,
    required this.labelOf,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final Key Function(T) keyOf;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var value in values) ...[
        Expanded(
          child: ChoiceChip(
            key: keyOf(value),
            label: Center(child: Text(labelOf(value))),
            showCheckmark: false,
            selected: selected == value,
            onSelected: (_) => onSelected(value),
          ),
        ),
        if (value != values.last) const SizedBox(width: 8),
      ],
    ],
  );
}

/// What was chosen for an item, in one line: `Large · Oat · Extra shot`.
String describeChoices(ShopStrings strings, CartItem item) => [
  switch (item.size) {
    DrinkSize.small => strings.sizeSmall,
    DrinkSize.medium => strings.sizeMedium,
    DrinkSize.large => strings.sizeLarge,
  },
  if (item.drink.takesMilk)
    switch (item.milk) {
      Milk.whole => strings.milkWhole,
      Milk.oat => strings.milkOat,
      Milk.almond => strings.milkAlmond,
    },
  if (item.extraShot) strings.extraShot,
].join(' · ');

/// One line of an order: the drink, what was chosen, and its price.
class OrderLine extends StatelessWidget {
  const OrderLine(this.item, {super.key, this.badge = 48});

  final CartItem item;
  final double badge;

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        DrinkBadge(item.drink, size: badge),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.drink.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                describeChoices(strings, item),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Text(
          formatPrice(item.price),
          style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary),
        ),
      ],
    );
  }
}

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _name = TextEditingController();
  var _pickup = Pickup.asap;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _placeOrder(Cart cart) {
    var items = List.of(cart.items);
    var name = _name.text.isEmpty ? '—' : _name.text;
    cart.clear();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) =>
            ConfirmationScreen(name: name, items: items, pickup: _pickup),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var cart = Cart.of(context);
    if (cart.items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(strings.yourOrder)),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.shopping_bag_outlined,
                      size: 56,
                      color: scheme.outlineVariant,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      strings.emptyCart,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              // The back arrow already leaves this screen, but an empty
              // state whose only exit is the chrome is a weak one: the way
              // out should be the thing you came here to do.
              FilledButton(
                key: ShopKeys.backToMenu,
                onPressed: () => backToMenu(context),
                child: Text(strings.backToMenu),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(strings.yourOrder)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              children: [
                for (var item in cart.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: OrderLine(item),
                  ),
                const Divider(height: 24),
                _Label(strings.pickup),
                ChoiceRow(
                  values: Pickup.values,
                  selected: _pickup,
                  keyOf: ShopKeys.pickup,
                  labelOf: (pickup) => switch (pickup) {
                    Pickup.asap => strings.pickupAsap,
                    Pickup.in15 => strings.pickupIn15,
                    Pickup.in30 => strings.pickupIn30,
                  },
                  onSelected: (pickup) => setState(() => _pickup = pickup),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      Icons.storefront_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      strings.pickupFrom,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  key: ShopKeys.cupName,
                  controller: _name,
                  decoration: InputDecoration(
                    hintText: strings.nameOnCup,
                    prefixIcon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.total,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        formatPrice(cart.total),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  key: ShopKeys.placeOrder,
                  onPressed: () => _placeOrder(cart),
                  child: Text(strings.placeOrder),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The order, placed: who it is for, where it has got to, and what is in it.
class ConfirmationScreen extends StatelessWidget {
  const ConfirmationScreen({
    super.key,
    required this.name,
    this.items = const [],
    this.pickup = Pickup.asap,
  });

  final String name;
  final List<CartItem> items;
  final Pickup pickup;

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var minutes = switch (pickup) {
      Pickup.asap => 6,
      Pickup.in15 => 15,
      Pickup.in30 => 30,
    };
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
                children: [
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check_rounded,
                        size: 40,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  MiniMarkdown(
                    strings.thanks(name),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    strings.onItsWay,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      strings.orderLabel,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const Text(
                                      'BL-1042',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  strings.counter,
                                  style: TextStyle(
                                    color: scheme.onPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          OrderProgress(
                            steps: [
                              strings.stepReceived,
                              strings.stepBrewing,
                              strings.stepReady,
                            ],
                            reached: 1,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            '${strings.pickupFrom} · ${strings.readyIn(minutes)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (var item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: OrderLine(item, badge: 40),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: FilledButton(
                key: ShopKeys.backToMenu,
                onPressed: () => backToMenu(context),
                child: Text(strings.backToMenu),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where an order has got to: a row of steps, the ones [reached] filled in.
class OrderProgress extends StatelessWidget {
  const OrderProgress({super.key, required this.steps, required this.reached});

  final List<String> steps;
  final int reached;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var (i, step) in steps.indexed) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.only(bottom: 22),
                color: i <= reached ? scheme.primary : scheme.outlineVariant,
              ),
            ),
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= reached ? scheme.primary : scheme.surface,
                  border: Border.all(
                    color: i <= reached
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: Icon(
                  i < reached
                      ? Icons.check_rounded
                      : i == reached
                      ? Icons.coffee_maker_outlined
                      : Icons.local_cafe_outlined,
                  size: 15,
                  color: i <= reached ? scheme.onPrimary : scheme.outline,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                step,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: i == reached ? FontWeight.w700 : FontWeight.w500,
                  color: i <= reached
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
