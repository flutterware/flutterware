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

final _log = Logger('world_lab.server');

/// What the shop sells. Fixed, because nothing in the lab is about the menu.
const menu = ['Flat white', 'Cortado', 'Filter'];

/// An order's life, in the order it is lived. Staff move it along one step at
/// a time; the customer is told at each step.
const orderStatuses = ['placed', 'preparing', 'ready', 'collected'];

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
Future<LabServer> startServer({
  int port = 8090,
  required SmsService sms,
  required PushService push,
}) async {
  var shop = _Shop(sms: sms, push: push);
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

class _Order {
  _Order({required this.id, required this.customerId, required this.item});

  final String id;
  final String customerId;
  final String item;
  var status = orderStatuses.first;
  final placedAt = DateTime.now().toUtc();

  Map<String, Object?> toJson() => {
    'id': id,
    'customerId': customerId,
    'item': item,
    'status': status,
    'placedAt': placedAt.toIso8601String(),
  };
}

class _Listener {
  _Listener(this.user, this.channel);

  final _User user;
  final WebSocketChannel channel;

  bool wants(_Order order) => user.isStaff || order.customerId == user.id;
}

/// The whole shop, in memory. A restart forgets everything, which is the
/// point: a world creates the users it needs every time it opens.
class _Shop {
  _Shop({required this.sms, required this.push});

  final SmsService sms;
  final PushService push;

  final _random = Random.secure();
  final _users = <String, _User>{};
  final _sessions = <String, String>{};
  final _codes = <String, String>{};
  final _orders = <String, _Order>{};
  final _listeners = <_Listener>{};
  var _nextId = 1;

  String _id(String prefix) => '$prefix${_nextId++}';

  String _token() =>
      base64Url.encode(List.generate(18, (_) => _random.nextInt(256)));

  _User? _userOf(Request request) {
    var header = request.headers['authorization'] ?? '';
    var token = header.startsWith('Bearer ')
        ? header.substring(7)
        : request.url.queryParameters['token'];
    return _users[_sessions[token]];
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
            for (var order in _orders.values.toList().reversed)
              if (user.isStaff || order.customerId == user.id) order.toJson(),
          ],
        });
      case ('POST', ['orders']):
        var item = '${(await _body(request))['item'] ?? ''}';
        if (!menu.contains(item)) return _error(400, 'not on the menu: $item');
        var order = _Order(id: _id('o'), customerId: user.id, item: item);
        _orders[order.id] = order;
        _log.info('${user.name} ordered a $item');
        _broadcast(order);
        return _json(order.toJson());
      case ('POST', ['orders', var id, 'advance']):
        if (!user.isStaff) return _error(403, 'staff only');
        var order = _orders[id];
        if (order == null) return _error(404, 'no order $id');
        var next = orderStatuses.indexOf(order.status) + 1;
        if (next == orderStatuses.length) return _error(409, 'collected');
        order.status = orderStatuses[next];
        _broadcast(order);
        if (order.status == 'ready') {
          await push.send(
            order.customerId,
            title: 'Your ${order.item.toLowerCase()} is ready',
            body: 'Collect it at the counter.',
            link: 'worldlab://orders/${order.id}',
          );
        }
        return _json(order.toJson());
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

  void _broadcast(_Order order) {
    var message = jsonEncode({'type': 'order', 'order': order.toJson()});
    for (var listener in _listeners) {
      if (listener.wants(order)) listener.channel.sink.add(message);
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
    return runZoned(() async {
      var watch = Stopwatch()..start();
      try {
        var response = await inner(request);
        FlutterwareServer.event('http', {
          'method': request.method,
          'path': '/${request.url.path}',
          'status': response.statusCode,
          'ms': watch.elapsedMicroseconds / 1000,
        });
        return response;
      } on HijackException {
        // A websocket upgrade, which shelf reports by throwing. It is the
        // success path.
        rethrow;
      }
    }, zoneValues: {FlutterwareServer.requestIdKey: id});
  };
}
