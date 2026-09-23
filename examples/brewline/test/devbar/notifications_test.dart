import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/devbar.dart';
import 'package:brewline/shop/shop_app.dart';
import 'package:brewline/src/devbar/notifications_panel.dart';
import 'package:brewline/src/notifications/push_banner.dart';
import 'package:brewline/src/notifications/push_service.dart';

/// The command plugin, from a call on the wire to the screen the app ends up
/// on — step 7 of the devbar/run bridge.
///
/// Everything below goes through [InspectorCore.handleFrame] rather than
/// calling the plugin, because the claim being tested is that an outside
/// caller can reach the feature. A test that called `service.deliver` would
/// prove the app works and say nothing about the bridge.
void main() {
  late GlobalKey<NavigatorState> navigatorKey;
  late PushService push;

  setUp(() {
    GuestChannels.install();
    for (var panel in GuestChannels.panels.descriptors) {
      GuestChannels.panels.remove(panel.id);
    }
    // The core is one object for the whole process; without this a feed test
    // reads what the test before it emitted.
    GuestChannels.core.debugClearEvents();
    navigatorKey = GlobalKey<NavigatorState>();
    push = PushService(
      navigatorKey: navigatorKey,
      links: [
        PushLink('/cart', 'The cart', (_) => const CartScreen()),
        PushLink('/menu', 'The menu', (_) => const MenuScreen()),
      ],
    );
  });

  PanelDescriptor panel() =>
      GuestChannels.panels.descriptors.singleWhere((p) => p.id == 'push');

  Future<Object?> call(
    WidgetTester tester,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    var peer = _Peer();
    GuestChannels.core.handleFrame(peer, {
      'ch': 'push',
      't': 'req',
      'id': 1,
      'm': method,
      'p': params,
    });
    await tester.pumpAndSettle();
    var frame = peer.frames.single;
    if (frame['t'] == 'err') {
      throw _Refusal('${(frame['p']! as Map)['message']}');
    }
    return frame['p'];
  }

  /// The sentence the app refused with. Fails the test if it did not refuse —
  /// a push that quietly does nothing is the failure being guarded against.
  Future<String> refusal(
    WidgetTester tester,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    try {
      await call(tester, method, params);
    } on Object catch (e) {
      return '$e';
    }
    fail('$method was not refused');
  }

  /// What the ring replays on one channel, read the way a cockpit reads it —
  /// by attaching — rather than by reaching into the core.
  List<Map<String, Object?>> replayed(String channel) {
    var peer = _Peer();
    GuestChannels.core.attach(peer, 99);
    GuestChannels.core.detach(peer);
    return [
      for (var frame in peer.frames)
        if (frame['t'] == 'event' && frame['ch'] == channel) frame,
    ];
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      Devbar(
        plugins: [NotificationsPlugin.init(service: push)],
        headless: true,
        child: ShopApp(
          navigatorKey: navigatorKey,
          overlay: PushBanner(service: push),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Object?> grant(WidgetTester tester) => call(
    tester,
    panelSetKnobMethod,
    {'id': 'permission', 'value': PushPermission.granted.label},
  );

  testWidgets('the plugin declares what it can be asked to do', (tester) async {
    await pump(tester);

    var described = panel();
    expect(described.label, 'Push');
    expect(described.actions.map((a) => a.id), ['send', 'clear']);
    expect(described.states.map((s) => s.id), ['registration']);
    expect(described.feeds.single.id, 'inbox');
    expect(described.feeds.single.itemActions.map((a) => a.id), ['open']);
    expect(described.knobs.single.name, 'permission');

    var link = described.actions.first.parameters.singleWhere(
      (p) => p.id == 'link',
    );
    expect(link.options.map((o) => o.value), [
      '/cart',
      '/menu',
    ], reason: 'the choices are the screens the app actually has');
  });

  /// The refusal is the app's, in the app's words — not the bridge inventing
  /// one, and not a silent no-op.
  testWidgets('a push is refused until permission is granted', (tester) async {
    await pump(tester);

    expect(
      await refusal(tester, 'send', {'title': 'Your order is ready'}),
      contains('not determined'),
    );
    expect(push.inbox, isEmpty);
  });

  testWidgets('a link the app does not have is refused, and names the ones it '
      'does', (tester) async {
    await pump(tester);
    await grant(tester);

    expect(
      await refusal(tester, 'send', {'title': 'Hi', 'link': '/nowhere'}),
      contains('/cart'),
    );
  });

  testWidgets('the knob is what grants permission, and the app holds it', (
    tester,
  ) async {
    await pump(tester);

    var reply = (await grant(tester))! as Map;

    expect(push.permission, PushPermission.granted);
    expect((reply['knobs']! as List).single, containsPair('value', 'Granted'));
  });

  /// The whole point, in one test: an outside caller reaches a code path that
  /// otherwise needs a backend, and the app really shows it.
  testWidgets('a push sent over the wire appears on the running app', (
    tester,
  ) async {
    await pump(tester);
    await grant(tester);

    var reply =
        (await call(tester, 'send', {
              'title': 'Your order is ready',
              'body': 'Cappuccino, medium',
              'link': '/cart',
            }))!
            as Map;
    await tester.pumpAndSettle();

    expect(reply['delivered'], isTrue);
    expect(find.text('Your order is ready'), findsOneWidget);
    expect(find.text('Cappuccino, medium'), findsOneWidget);
    expect(find.byKey(PushKeys.banner), findsOneWidget);
  });

  testWidgets('tapping the banner follows the deep link', (tester) async {
    await pump(tester);
    await grant(tester);
    await call(tester, 'send', {'title': 'Order ready', 'link': '/cart'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(PushKeys.open));
    await tester.pumpAndSettle();

    expect(find.byType(CartScreen), findsOneWidget);
    expect(
      find.byKey(PushKeys.banner),
      findsNothing,
      reason: 'a notification that has been followed stops asking',
    );
  });

  /// The feed's item action, which is what needed `Panel.emit` to return the
  /// event id: `open` is invoked with nothing but that id.
  testWidgets('the inbox feed carries the event, and open navigates from it', (
    tester,
  ) async {
    await pump(tester);
    await grant(tester);
    await call(tester, 'send', {'title': 'Order ready', 'link': '/menu'});
    await tester.pumpAndSettle();

    var event = replayed(panel().feedChannel('inbox')).single;
    expect((event['p']! as Map)['title'], 'Order ready');
    expect(event['rid'], 'push-1', reason: 'correlated to the message');

    await call(tester, 'open', {'event': event['e']});
    await tester.pumpAndSettle();

    expect(find.byType(MenuScreen), findsOneWidget);
    expect(push.inbox.single.opened, isTrue);
  });

  /// Both halves of what the live drive caught on 2026-08-11, and neither was
  /// reachable without clearing first: the feed stopped recording for the rest
  /// of the run, and the id it had already published came back attached to a
  /// different notification — so `open` on the first row followed the second
  /// one's link.
  testWidgets('clearing the inbox does not silence the feed or reuse an id', (
    tester,
  ) async {
    await pump(tester);
    await grant(tester);
    await call(tester, 'send', {'title': 'Before', 'link': '/cart'});
    await tester.pumpAndSettle();
    var before = replayed(panel().feedChannel('inbox')).single;

    await call(tester, 'clear');
    await call(tester, 'send', {'title': 'After', 'link': '/menu'});
    await tester.pumpAndSettle();

    var events = replayed(panel().feedChannel('inbox'));
    expect(
      [for (var event in events) (event['p']! as Map)['title']],
      ['Before', 'After'],
      reason: 'the feed keeps recording once the inbox has been emptied',
    );
    expect(
      events.map((event) => event['rid']).toSet(),
      hasLength(2),
      reason: 'an id in the feed must not name two notifications',
    );

    // And the row that says /cart still opens /cart.
    expect(
      await refusal(tester, 'open', {'event': before['e']}),
      contains('push-1'),
      reason: 'the cleared message is gone, and says so rather than aliasing',
    );
  });

  testWidgets('open without an event id says what it needed', (tester) async {
    await pump(tester);

    expect(await refusal(tester, 'open'), contains('event'));
  });

  /// The feed follows the *service*, not the command — so a notification the
  /// app delivers to itself shows up too.
  testWidgets('a push the app sends itself reaches the feed', (tester) async {
    await pump(tester);
    await grant(tester);

    push.deliver(title: 'From inside');
    await tester.pumpAndSettle();

    var event = replayed(panel().feedChannel('inbox')).single;
    expect((event['p']! as Map)['title'], 'From inside');
  });

  testWidgets('the registration state answers what a backend would be told', (
    tester,
  ) async {
    await pump(tester);

    var snapshot =
        (await call(tester, panelStateMethod, {'id': 'registration'}))! as Map;

    expect(snapshot['token'], PushService.token);
    expect(snapshot['permission'], 'Not determined');
    expect(snapshot['links'], '/cart /menu');
  });
}

class _Peer implements InspectorPeer {
  final frames = <Map<String, Object?>>[];

  @override
  void send(Map<String, Object?> frame) => frames.add(frame);

  @override
  void close() {}
}

class _Refusal implements Exception {
  _Refusal(this.message);

  final String message;

  @override
  String toString() => message;
}
