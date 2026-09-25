import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'menu.dart';
import 'plugin_check.dart';

class LabApp extends StatelessWidget {
  const LabApp({
    super.key,
    required this.server,
    required this.session,
    required this.person,
  });

  final Uri server;
  final String session;
  final String person;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pickup',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6F4E37)),
      home: _Home(server: server, session: session, person: person),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home({
    required this.server,
    required this.session,
    required this.person,
  });

  final Uri server;
  final String session;
  final String person;

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
  String? _highlight;
  WebSocketChannel? _live;
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
    if (link.host == 'orders' && link.pathSegments.isNotEmpty) {
      setState(() => _highlight = link.pathSegments.first);
    }
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
    var orders = await _api.orders();
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
    setState(() {
      _orders = [order, ..._orders.where((o) => o.id != order.id)];
    });
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
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        body: TabBarView(children: [_ordersTab(), _pluginsTab()]),
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
                      var order = await _api.order(item);
                      _onOrder(order);
                    }),
                    child: Text('Order a ${item.toLowerCase()}'),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          if (_orders.isEmpty) const Text('No orders yet.'),
          for (var order in _orders)
            Card(
              color: order.id == _highlight
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: ListTile(
                title: Text(order.item),
                subtitle: Text('${order.status} · ${order.id}'),
                trailing: user.isStaff && order.status != 'collected'
                    ? TextButton(
                        onPressed: () => _run(() async {
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
