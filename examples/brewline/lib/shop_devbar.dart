/// Brewline with a devbar on it — the sample for driving an app from outside
/// itself.
///
/// What this exists to show. A push notification is the canonical thing
/// you cannot get at: it needs a backend, a registration token and somebody
/// willing to send you one while you are looking at the screen. Here it is one
/// call — from a button in the in-app overlay, from the cockpit's App tab,
/// from `fw`, or from an agent:
///
/// ```sh
/// fw run run panelInvoke --panel=push --action=send \
///   --args='{"title": "Your order is ready", "link": "/cart"}'
/// ```
///
/// The running app shows the banner, which can then be tapped — by a person or
/// by `flutterware_act` — to follow the deep link. None of it reaches around
/// the app: `PushService` is Brewline's own code and the plugin only calls it,
/// so what gets exercised is the real path.
///
/// Run it: the **Brewline (devbar)** entry point in the run panel, or
/// `flutter run -t lib/shop_devbar.dart`.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/devbar.dart';

import 'shop/shop_app.dart';
import 'src/devbar/notifications_panel.dart';
import 'src/notifications/push_banner.dart';
import 'src/notifications/push_service.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

/// Every screen a notification may point at.
///
/// Declared once and used twice: the app routes with it, and the plugin turns
/// it into the `link` parameter's options — so the choices offered to a form,
/// to `fw` and to an agent are the screens that actually exist, and cannot
/// drift from them.
final _links = [
  PushLink('/menu', 'The menu', (_) => const MenuScreen()),
  PushLink('/cart', 'The cart', (_) => const CartScreen()),
  PushLink(
    '/order',
    'Order confirmation',
    (_) => const ConfirmationScreen(name: 'Ada'),
  ),
  for (var drink in drinks)
    PushLink('/drink/${drink.id}', drink.name, (_) => DrinkScreen(drink)),
];

final _push = PushService(navigatorKey: _navigatorKey, links: _links);

void main() {
  runApp(
    Devbar(
      plugins: [NotificationsPlugin.init(service: _push)],
      child: ShopApp(
        navigatorKey: _navigatorKey,
        overlay: PushBanner(service: _push),
      ),
    ),
  );
}
