import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutterware/server.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'edges.dart';
import 'orders.dart';
import 'sync_auth.dart';

final _log = Logger('world_lab.server');

/// What the shop sells. Fixed, because nothing in the lab is about the menu.
const menu = ['Flat white', 'Cortado', 'Filter'];

/// A running lab server.
class LabServer {
  LabServer._(this._http);

  final HttpServer _http;

  /// Where it answers — what an app's `server` knob is set to.
  Uri get url => Uri.parse('http://localhost:${_http.port}');

  Future<void> close() => _http.close(force: true);
}

/// Starts the lab server on [port] (0 picks a free one).
///
/// The edges are parameters because they are what a world replaces: the
/// server's own code never learns whether a text message reached a carrier or
/// the studio.
///
/// [orders] is where orders live — in memory unless a world hands it
/// Postgres. With [sync], apps sync them through a sync engine rather than
/// asking this server: it hands each app its token and takes its uploads.
Future<LabServer> startServer({
  int port = 8090,
  required SmsService sms,
  required PushService push,
  OrderStore? orders,
  SyncAuth? sync,
}) async {
  var shop = _Shop(
    sms: sms,
    push: push,
    orders: orders ?? MemoryOrders(),
    sync: sync,
  );
  var handler = const Pipeline()
      .addMiddleware(_inspect())
      .addHandler(shop.handle);
  var http = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
  var server = LabServer._(http);
  _log.info('listening on ${server.url}');
  FlutterwareServer.info(
    ServerInfo(
      baseUrl: '${server.url}',
      environment: 'lab',
      links: [ServerLink('Health', '/health'), ServerLink('Menu', '/menu')],
    ),
  );
  return server;
}

class _User {
  _User({
    required this.id,
    required this.name,
    required this.role,
    this.phone,
    this.email,
  });

  final String id;
  final String name;
  final String role;
  final String? phone;
  final String? email;

  bool get isStaff => role == 'staff';

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'role': role,
    'phone': ?phone,
    'email': ?email,
  };
}

class _Listener {
  _Listener(this.user, this.channel);

  final _User user;
  final WebSocketChannel channel;

  bool wants(Order order) => user.isStaff || order.customerId == user.id;
}

/// The whole shop. Its users live in memory — a restart forgets them, which
/// is the point: a world creates the users it needs every time it opens —
/// and its orders wherever [orders] keeps them.
class _Shop {
  _Shop({
    required this.sms,
    required this.push,
    required this.orders,
    this.sync,
  });

  final SmsService sms;
  final PushService push;
  final OrderStore orders;
  final SyncAuth? sync;

  final _random = Random.secure();
  final _users = <String, _User>{};
  final _sessions = <String, String>{};
  final _codes = <String, String>{};
  final _listeners = <_Listener>{};
  var _nextId = 1;

  /// Ids unique to this server's run, not only within it: orders can
  /// outlive the server — in Postgres — and a `u2` reused by the next run
  /// would inherit the last run's orders.
  late final _run = _random.nextInt(1 << 20).toRadixString(36);
  String _id(String prefix) => '$prefix$_run-${_nextId++}';

  String _token() =>
      base64Url.encode(List.generate(18, (_) => _random.nextInt(256)));

  _User? _userOf(Request request) {
    var header = request.headers['authorization'] ?? '';
    var token = header.startsWith('Bearer ')
        ? header.substring(7)
        : request.url.queryParameters['token'];
    var user = _users[_sessions[token]];
    if (user != null) FlutterwareServer.identify(user.id);
    return user;
  }

  FutureOr<Response> handle(Request request) async {
    var path = request.url.pathSegments;
    switch ((request.method, path)) {
      case ('GET', ['health']):
        return _json({'ok': true});
      case ('GET', ['menu']):
        return _json({'items': menu});
      case ('GET', ['live']):
        return _live(request);
      // The admin API a world seeds through: a user, and a session for it,
      // in one call. Unauthenticated because the lab only listens on
      // loopback; a real server's admin API is where its own rules apply.
      case ('POST', ['admin', 'users']):
        var body = await _body(request);
        var user = _User(
          id: _id('u'),
          name: '${body['name'] ?? 'Someone'}',
          role: body['role'] == 'staff' ? 'staff' : 'customer',
          phone: body['phone'] as String?,
          email: body['email'] as String?,
        );
        _users[user.id] = user;
        var token = _token();
        _sessions[token] = user.id;
        return _json({...user.toJson(), 'token': token});
      case ('POST', ['auth', 'code']):
        var phone = '${(await _body(request))['phone'] ?? ''}';
        if (phone.isEmpty) return _error(400, 'phone is required');
        var code = '${100000 + _random.nextInt(900000)}';
        _codes[phone] = code;
        await sms.send(phone, 'Your pickup code is $code');
        return Response(204);
      case ('POST', ['auth', 'verify']):
        var body = await _body(request);
        var phone = '${body['phone'] ?? ''}';
        if (_codes[phone] == null || _codes[phone] != body['code']) {
          return _error(401, 'wrong code');
        }
        _codes.remove(phone);
        // A phone nobody seeded signs up by signing in — the newcomer.
        var user = _users.values.where((u) => u.phone == phone).firstOrNull;
        if (user == null) {
          user = _User(
            id: _id('u'),
            name: phone,
            role: 'customer',
            phone: phone,
          );
          _users[user.id] = user;
        }
        var token = _token();
        _sessions[token] = user.id;
        return _json({'token': token, 'user': user.toJson()});
    }

    var user = _userOf(request);
    if (user == null) return _error(401, 'sign in first');
    switch ((request.method, path)) {
      case ('GET', ['me']):
        return _json(user.toJson());
      case ('GET', ['orders']):
        return _json({
          'orders': [
            for (var order in await orders.all())
              if (user.isStaff || order.customerId == user.id) order.toJson(),
          ],
        });
      case ('POST', ['orders']):
        var item = '${(await _body(request))['item'] ?? ''}';
        if (!menu.contains(item)) return _error(400, 'not on the menu: $item');
        var order = Order(id: orders.newId(), customerId: user.id, item: item);
        await _write(order, user, 'insert');
        return _json(order.toJson());
      case ('POST', ['orders', var id, 'advance']):
        if (!user.isStaff) return _error(403, 'staff only');
        var order = await orders.find(id);
        if (order == null) return _error(404, 'no order $id');
        var next = orderStatuses.indexOf(order.status) + 1;
        if (next == orderStatuses.length) return _error(409, 'collected');
        order = order.withStatus(orderStatuses[next]);
        await _write(order, user, 'update');
        return _json(order.toJson());
      // What a synced app asks this server, rather than for its orders.
      case ('GET', ['sync', 'token']) when sync != null:
        return _json({
          'token': sync!.token(user.id, user.role),
          'endpoint': '${sync!.endpoint}',
        });
      case ('POST', ['sync', 'upload']) when sync != null:
        return _upload(user, await _body(request));
    }
    return _error(404, 'no route for ${request.method} /${request.url.path}');
  }

  /// A socket per signed-in app, told about every order it may see.
  FutureOr<Response> _live(Request request) {
    var user = _userOf(request);
    return webSocketHandler((WebSocketChannel channel, String? _) {
      if (user == null) {
        // Anonymous sockets are answered once and closed: an app checks it
        // can reach the socket before anybody has signed in.
        channel.sink.add(jsonEncode({'type': 'hello'}));
        unawaited(channel.sink.close());
        return;
      }
      var listener = _Listener(user, channel);
      _listeners.add(listener);
      channel.sink.add(jsonEncode({'type': 'hello', 'user': user.id}));
      channel.stream.listen(
        (_) {},
        onDone: () => _listeners.remove(listener),
        onError: (Object _) => _listeners.remove(listener),
      );
    })(request);
  }

  /// Applies a synced app's changes, as its connector uploads them — the
  /// server's own rules still decide: a customer only places, staff only
  /// move an order along.
  Future<Response> _upload(_User user, Map<String, Object?> body) async {
    for (var raw in body['ops'] as List? ?? const []) {
      var op = (raw as Map).cast<String, Object?>();
      if (op['table'] != 'orders') continue;
      var id = op['id']! as String;
      var data = (op['data'] as Map? ?? const {}).cast<String, Object?>();
      switch (op['op']) {
        case 'PUT':
          var item = '${data['item'] ?? ''}';
          if (!menu.contains(item)) {
            return _error(400, 'not on the menu: $item');
          }
          await _write(
            Order(id: id, customerId: user.id, item: item),
            user,
            'insert',
          );
        case 'PATCH':
          var order = await orders.find(id);
          var status = data['status'];
          if (order == null || status is! String) continue;
          if (!user.isStaff) return _error(403, 'staff only');
          if (!orderStatuses.contains(status)) {
            return _error(400, 'no status $status');
          }
          await _write(order.withStatus(status), user, 'update');
        case 'DELETE':
          await orders.delete(id);
          FlutterwareServer.event('write', {
            'table': 'orders',
            'key': id,
            'op': 'delete',
          });
      }
    }
    return _json({'ok': true});
  }

  /// Every change to an order, wherever it came from: stored, reported as
  /// the record it touched, told to the apps listening, and pushed when it
  /// is ready.
  Future<void> _write(Order order, _User by, String op) async {
    await orders.put(order);
    FlutterwareServer.event('write', {
      'table': 'orders',
      'key': order.id,
      'op': op,
      'status': order.status,
    });
    if (op == 'insert') _log.info('${by.name} ordered a ${order.item}');
    _broadcast(order);
    if (op == 'update' && order.status == 'ready') {
      await push.send(
        order.customerId,
        title: 'Your ${order.item.toLowerCase()} is ready',
        body: 'Collect it at the counter.',
        link: 'worldlab://orders/${order.id}',
      );
    }
  }

  void _broadcast(Order order) {
    var message = jsonEncode({'type': 'order', 'order': order.toJson()});
    for (var listener in _listeners) {
      if (!listener.wants(order)) continue;
      listener.channel.sink.add(message);
      FlutterwareServer.reach(
        listener.user.id,
        'order ${order.id} · ${order.status}',
      );
    }
  }
}

Future<Map<String, Object?>> _body(Request request) async {
  var text = await request.readAsString();
  if (text.isEmpty) return {};
  return (jsonDecode(text) as Map).cast<String, Object?>();
}

Response _json(Object body) => Response.ok(
  jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _error(int status, String message) => Response(
  status,
  body: jsonEncode({'error': message}),
  headers: {'content-type': 'application/json'},
);

/// Reports each request to the Server panel. A trimmed copy of the adapter in
/// `fixtures/probe_app/bin/example_server.dart`, which says what the full one
/// adds.
Middleware _inspect() {
  var next = 1;
  return (inner) => (request) {
    var id = 'req-${next++}';
    return runZoned(
      () async {
        var watch = Stopwatch()..start();
        try {
          var response = await inner(request);
          FlutterwareServer.event('http', {
            'method': request.method,
            'path': '/${request.url.path}',
            // The part of the API it touched: the route, not the URL.
            'part':
                '/${request.url.pathSegments.map((s) => _anId.hasMatch(s) ? ':id' : s).join('/')}',
            'status': response.statusCode,
            'ms': watch.elapsedMicroseconds / 1000,
          });
          return response;
        } on HijackException {
          // A websocket upgrade, which shelf reports by throwing. It is the
          // success path.
          rethrow;
        }
      },
      zoneValues: {
        FlutterwareServer.requestIdKey: id,
        // The device's step, when it sent one: the tap this request came from.
        FlutterwareServer.stepKey: ?request.headers['x-fw-step'],
      },
    );
  };
}

/// A path segment that is an id — `o3`, `u3kx9-12` or a UUID — rather than a
/// word.
final _anId = RegExp(
  r'^([a-z]?\d+|[a-z][a-z0-9]*-\d+|[0-9a-f]{8}-[0-9a-f-]{27})$',
);
