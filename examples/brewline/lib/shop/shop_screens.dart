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

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var cart = Cart.of(context);
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
      body: ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: drinks.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          var drink = drinks[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => DrinkScreen(drink)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    DrinkBadge(drink),
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
        },
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

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var drink = widget.drink;
    var item = CartItem(drink, _size);
    return Scaffold(
      appBar: AppBar(title: Text(drink.name)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: DrinkBadge(drink, size: 160)),
            const SizedBox(height: 24),
            Text(
              strings.describe(drink.id),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            Text(
              strings.size,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (var size in DrinkSize.values) ...[
                  Expanded(
                    child: ChoiceChip(
                      key: ShopKeys.size(size),
                      label: Center(
                        child: Text(switch (size) {
                          DrinkSize.small => strings.sizeSmall,
                          DrinkSize.medium => strings.sizeMedium,
                          DrinkSize.large => strings.sizeLarge,
                        }),
                      ),
                      selected: _size == size,
                      onSelected: (_) => setState(() => _size = size),
                    ),
                  ),
                  if (size != DrinkSize.values.last) const SizedBox(width: 8),
                ],
              ],
            ),
            const Spacer(),
            FilledButton(
              key: ShopKeys.addToCart,
              onPressed: () {
                Cart.of(context).add(item);
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => const CartScreen()),
                );
              },
              child: Text('${strings.addToCart} · ${formatPrice(item.price)}'),
            ),
          ],
        ),
      ),
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

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    var cart = Cart.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.yourOrder)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: cart.items.isEmpty
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        strings.emptyCart,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
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
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView.separated(
                      itemCount: cart.items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        var item = cart.items[index];
                        return Row(
                          children: [
                            DrinkBadge(item.drink, size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.drink.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              formatPrice(item.price),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const Divider(height: 32),
                  Row(
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
                  const SizedBox(height: 18),
                  TextField(
                    key: ShopKeys.cupName,
                    controller: _name,
                    decoration: InputDecoration(hintText: strings.nameOnCup),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    key: ShopKeys.placeOrder,
                    onPressed: () {
                      var name = _name.text.isEmpty ? '—' : _name.text;
                      cart.clear();
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(
                          builder: (_) => ConfirmationScreen(name: name),
                        ),
                      );
                    },
                    child: Text(strings.placeOrder),
                  ),
                ],
              ),
      ),
    );
  }
}

class ConfirmationScreen extends StatelessWidget {
  const ConfirmationScreen({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    var strings = ShopStrings.of(context);
    var scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_rounded,
                  size: 52,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              MiniMarkdown(
                strings.thanks(name),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                strings.onItsWay,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
              ),
              const Spacer(flex: 3),
              FilledButton(
                key: ShopKeys.backToMenu,
                onPressed: () => backToMenu(context),
                child: Text(strings.backToMenu),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
