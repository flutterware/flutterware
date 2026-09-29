import 'dart:async';

import 'package:flutter/foundation.dart' show SynchronousFuture;

import 'package:app_links/app_links.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutterware/devbar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'menu.dart';
import 'order_cache.dart';
import 'plugin_check.dart';
import 'synced_orders.dart';

class LabApp extends StatefulWidget {
  const LabApp({
    super.key,
    required this.server,
    required this.session,
    required this.person,
    this.sync = false,
  });

  final Uri server;
  final String session;
  final String person;
  final bool sync;

  @override
  State<LabApp> createState() => _LabAppState();
}

class _LabAppState extends State<LabApp> {
  late final _Routes _routes = _Routes(
    (context) => _Home(
      server: widget.server,
      session: widget.session,
      person: widget.person,
      sync: widget.sync,
      routes: _routes,
    ),
  );

  @override
  void dispose() {
    _routes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Headless in a guest: panels for Run and the studio, no overlay.
    return Devbar(
      plugins: const [],
      // Routed, as a real app is: `/orders`, `/orders/o3`. On the web, and
      // in a world's browser, that is the address.
      child: MaterialApp.router(
        title: 'Pickup',
        // A person's phone has no ribbon on it.
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF6F4E37)),
        routerConfig: RouterConfig(
          routeInformationProvider: PlatformRouteInformationProvider(
            initialRouteInformation: RouteInformation(
              uri: Uri(path: '/orders'),
            ),
          ),
          routeInformationParser: const _Paths(),
          routerDelegate: _routes,
          backButtonDispatcher: RootBackButtonDispatcher(),
        ),
      ),
    );
  }
}

/// The app's two places: the orders, and one order picked out on them —
/// what a delivered link, a tapped notification or a typed address opens.
class _Routes extends RouterDelegate<Uri> with ChangeNotifier {
  _Routes(this._home);

  final WidgetBuilder _home;

  /// The order picked out, by id; null for the orders alone.
  String? order;

  void show(String? id) {
    if (id == order) return;
    order = id;
    notifyListeners();
  }

  @override
  Uri get currentConfiguration =>
      Uri(path: order == null ? '/orders' : '/orders/$order');

  @override
  Future<void> setNewRoutePath(Uri configuration) async {
    var segments = configuration.pathSegments;
    show(
      segments.length == 2 && segments.first == 'orders' ? segments[1] : null,
    );
  }

  /// Back from an order to the orders; from the orders, out of the app.
  @override
  Future<bool> popRoute() async {
    if (order == null) return false;
    show(null);
    return true;
  }

  /// One page: the orders are the whole app, and an order is picked out on
  /// them rather than pushed. A navigator still, for the overlay a tooltip
  /// and a menu need.
  @override
  Widget build(BuildContext context) => Navigator(
    pages: [
      MaterialPage<void>(key: const ValueKey('orders'), child: _home(context)),
    ],
    onDidRemovePage: (_) {},
  );
}

class _Paths extends RouteInformationParser<Uri> {
  const _Paths();

  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) =>
      SynchronousFuture(routeInformation.uri);

  @override
  RouteInformation restoreRouteInformation(Uri configuration) =>
      RouteInformation(uri: configuration);
}

class _Home extends StatefulWidget {
  const _Home({
    required this.server,
    required this.session,
    required this.person,
    required this.sync,
    required this.routes,
  });

  final Uri server;
  final String session;
  final String person;
  final bool sync;
  final _Routes routes;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final _api = Api(widget.server);
  final _phone = TextEditingController();
  final _code = TextEditingController();

  List<PluginResult>? _plugins;
  User? _user;
  var _orders = <Order>[];
  var _codeSent = false;
  var _spinning = false;
  String? _error;
  WebSocketChannel? _live;
  SyncedOrders? _synced;

  /// Where the plain app keeps the orders it has seen.
  OrderCache? _cache;

  /// The phone's database as a devbar panel, `db:main`: the synced one's
  /// tables and — being PowerSync — what waits to upload and every record
  /// that arrives; the plain app's cache of the orders it has seen.
  DatabasePanelSource? _databasePanel;
  StreamSubscription<List<Order>>? _watching;
  StreamSubscription<Uri>? _links;
  StreamSubscription<Uri>? _tapped;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    var plugins = await checkPlugins(_api);
    if (!mounted) return;
    setState(() => _plugins = plugins);
    _links = AppLinks().uriLinkStream.listen(_openLink, onError: (Object _) {});
    _tapped = notificationLinks.stream.listen(_openLink);

    // The knob wins over what was stored, so a world can hand every person's
    // app its session without anybody typing a code.
    var session = widget.session.isNotEmpty
        ? widget.session
        : await secureStorage
              .read(key: 'session')
              .catchError((Object _) => null);
    if (session == null) return;
    _api.token = session;
    await _signedIn();
  }

  void _openLink(Uri link) {
    // worldlab://orders/o12 — what the server's push carries.
    if (link.host != 'orders') return;
    widget.routes.show(
      link.pathSegments.isNotEmpty ? link.pathSegments.first : null,
    );
    // Opened from outside, the board may be behind: fetch it afresh, as a
    // phone that was asleep would. A synced board is never behind.
    if (widget.sync || _user == null) return;
    unawaited(
      _run(() async {
        var orders = await _api.orders();
        _cache?.keep(orders);
        if (mounted) setState(() => _orders = orders);
      }),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _signedIn() => _run(() async {
    var user = await _api.me();
    if (widget.sync) {
      // Synced: the local copy is the truth the screen shows, and a change
      // anybody made arrives in it — no socket of the app's own.
      var synced = _synced ??= await SyncedOrders.open(_api);
      _databasePanel ??= DatabasePanelSource(
        DatabaseAdapter(
          query: (sql, args) => synced.db.getAll(sql, args),
          updates: synced.db.updates.map((u) => u.tables),
          watch: (sql) =>
              synced.db.watch(sql, throttle: const Duration(milliseconds: 250)),
          sync: DatabaseSync.powersync,
        ),
      );
      await _watching?.cancel();
      _watching = synced.watch().listen((orders) {
        var before = {for (var o in _orders) o.id: o.status};
        for (var order in orders) {
          if (before[order.id] != order.status) _notifyIfReady(order);
        }
        setState(() => _orders = orders);
      });
      setState(() => _user = user);
      return;
    }
    var orders = await _api.orders();
    var cache = _cache ??= await OrderCache.open();
    _databasePanel ??= DatabasePanelSource(cache.adapter);
    cache.keep(orders);
    await _live?.sink.close();
    var live = _api.live();
    _api.orderUpdates(live).listen(_onOrder, onError: (Object _) {});
    setState(() {
      _user = user;
      _orders = orders;
      _live = live;
    });
  });

  void _onOrder(Order order) {
    _cache?.keep([order]);
    setState(() {
      _orders = [order, ..._orders.where((o) => o.id != order.id)];
    });
    _notifyIfReady(order);
  }

  void _notifyIfReady(Order order) {
    if (order.status == 'ready' && _user?.id == order.customerId) {
      unawaited(
        notifications
            .show(
              id: order.id.hashCode,
              title: 'Your ${order.item.toLowerCase()} is ready',
              body: 'Collect it at the counter.',
              payload: 'worldlab://orders/${order.id}',
            )
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _signOut() async {
    await secureStorage.delete(key: 'session').catchError((Object _) {});
    await _live?.sink.close();
    _api.token = null;
    setState(() {
      _user = null;
      _orders = [];
      _codeSent = false;
      _code.clear();
    });
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    unawaited(_tapped?.cancel());
    unawaited(_live?.sink.close());
    unawaited(_watching?.cancel());
    _databasePanel?.dispose();
    unawaited(_synced?.close());
    _cache?.close();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.routes,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        // A counter in a browser: the board, as wide as the window.
        if (_user case var user? when user.isStaff) {
          if (constraints.maxWidth >= 900) return _counter(user);
        }
        return _phoneLayout(context);
      },
    ),
  );

  Widget _phoneLayout(BuildContext context) {
    var who =
        _user?.name ?? (widget.person.isEmpty ? 'signed out' : widget.person);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Pickup · $who'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Orders'),
              Tab(text: 'Plugins'),
            ],
          ),
          actions: [
            if (_user != null)
              IconButton(
                tooltip: 'Sign out',
                onPressed: _signOut,
                icon: const Icon(Icons.logout),
              ),
          ],
        ),
        body: switch (_databasePanel) {
          var panel? => AddDevbarPanel(
            source: panel,
            child: TabBarView(children: [_ordersTab(), _pluginsTab()]),
          ),
          null => TabBarView(children: [_ordersTab(), _pluginsTab()]),
        },
      ),
    );
  }

  Widget _ordersTab() {
    var user = _user;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error case var error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (user == null)
          ..._signIn()
        else ...[
          if (!user.isStaff)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var item in menu)
                  FilledButton(
                    onPressed: () => _run(() async {
                      if (_synced case var synced?) {
                        return synced.place(user.id, item);
                      }
                      _onOrder(await _api.order(item));
                    }),
                    child: Text('Order a ${item.toLowerCase()}'),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          if (_orders.isEmpty) const Text('No orders yet.'),
          for (var order in _orders)
            Card(
              color: order.id == widget.routes.order
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: ListTile(
                title: Text(order.item),
                subtitle: Text('${order.status} · ${order.id}'),
                trailing: user.isStaff && order.status != 'collected'
                    ? TextButton(
                        onPressed: () => _run(() async {
                          if (_synced case var synced?) {
                            return synced.advance(order);
                          }
                          _onOrder(await _api.advance(order.id));
                        }),
                        child: const Text('Advance'),
                      )
                    : null,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: () => _run(() async {
                  var granted = await notifications
                      .resolvePlatformSpecificImplementation<
                        MacOSFlutterLocalNotificationsPlugin
                      >()
                      ?.requestPermissions(alert: true);
                  granted ??= await notifications
                      .resolvePlatformSpecificImplementation<
                        IOSFlutterLocalNotificationsPlugin
                      >()
                      ?.requestPermissions(alert: true);
                  setState(() => _error = 'Notifications allowed: $granted');
                }),
                child: const Text('Allow notifications'),
              ),
              TextButton(
                onPressed: () =>
                    launchUrl(Uri.parse('https://flutterware.dev')),
                child: const Text('Open the shop’s page'),
              ),
            ],
          ),
        ],
        // An animation that never ends, so a world can measure what one
        // moving app costs beside still ones, and whether pausing it stops it.
        SwitchListTile(
          title: const Text('Spin'),
          value: _spinning,
          onChanged: (on) => setState(() => _spinning = on),
          secondary: _spinning ? const CircularProgressIndicator() : null,
        ),
      ],
    );
  }

  /// The counter, in a browser: the orders on the board by where they are,
  /// each with the step that moves it on, the one a link picked out ringed.
  Widget _counter(User user) {
    var theme = Theme.of(context);
    var colors = theme.colorScheme;
    var order = widget.routes.order;
    const columns = [
      ('placed', 'Placed'),
      ('preparing', 'Preparing'),
      ('ready', 'Ready'),
    ];
    String next(String status) => switch (status) {
      'placed' => 'Preparing',
      'preparing' => 'Ready',
      _ => 'Collected',
    };
    return Title(
      title: 'Pickup · Counter',
      color: colors.primary,
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: colors.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Text('Pickup · Counter', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  Text(user.name, style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 8),
                  const Icon(Icons.account_circle_outlined),
                  IconButton(
                    tooltip: 'Sign out',
                    onPressed: _signOut,
                    icon: const Icon(Icons.logout),
                  ),
                ],
              ),
            ),
            if (_error case var error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                child: Text(error, style: TextStyle(color: colors.error)),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var (i, (status, label)) in columns.indexed) ...[
                      if (i > 0) const SizedBox(width: 20),
                      Expanded(
                        child: ListView(
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: label.toUpperCase()),
                                  TextSpan(
                                    text:
                                        '  ${_orders.where((o) => o.status == status).length}',
                                    style: TextStyle(color: colors.onSurface),
                                  ),
                                ],
                              ),
                              style: theme.textTheme.labelMedium?.copyWith(
                                letterSpacing: 0.8,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (var each in _orders)
                              if (each.status == status)
                                Card(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: each.id == order
                                        ? BorderSide(
                                            color: colors.primary,
                                            width: 3,
                                          )
                                        : BorderSide.none,
                                  ),
                                  child: ListTile(
                                    title: Text(
                                      each.customer == null
                                          ? each.item
                                          : '${each.item} for ${each.customer}',
                                    ),
                                    subtitle: Text(each.id),
                                    onTap: () => widget.routes.show(each.id),
                                    trailing: TextButton(
                                      onPressed: () => _run(() async {
                                        _onOrder(await _api.advance(each.id));
                                      }),
                                      child: Text('${next(status)} →'),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _signIn() => [
    TextField(
      controller: _phone,
      decoration: const InputDecoration(labelText: 'Phone'),
      keyboardType: TextInputType.phone,
    ),
    const SizedBox(height: 8),
    if (!_codeSent)
      FilledButton(
        onPressed: () => _run(() async {
          await _api.sendCode(_phone.text);
          setState(() => _codeSent = true);
        }),
        child: const Text('Send code'),
      )
    else ...[
      TextField(
        controller: _code,
        decoration: const InputDecoration(labelText: 'Code'),
        keyboardType: TextInputType.number,
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: () => _run(() async {
          await _api.verify(_phone.text, _code.text);
          await secureStorage
              .write(key: 'session', value: _api.token)
              .catchError((Object _) {});
          await _signedIn();
        }),
        child: const Text('Sign in'),
      ),
    ],
  ];

  Widget _pluginsTab() {
    var plugins = _plugins;
    if (plugins == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        for (var result in plugins)
          ListTile(
            leading: Icon(result.ok ? Icons.check_circle : Icons.error),
            title: Text('${result.name} · ${result.ms} ms'),
            subtitle: Text(result.detail),
          ),
      ],
    );
  }
}
