import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class User {
  User.fromJson(Map<String, Object?> json)
    : id = json['id']! as String,
      name = json['name']! as String,
      role = json['role']! as String;

  final String id;
  final String name;
  final String role;

  bool get isStaff => role == 'staff';
}

class Order {
  Order.fromJson(Map<String, Object?> json)
    : id = json['id']! as String,
      customerId = json['customerId']! as String,
      item = json['item']! as String,
      status = json['status']! as String;

  final String id;
  final String customerId;
  final String item;
  final String status;
}

/// The lab server's API, as the app speaks it.
class Api {
  Api(this.base, {this.token});

  final Uri base;
  String? token;
  final _client = http.Client();

  Future<Map<String, Object?>> _send(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    var request = http.Request(method, base.resolve(path));
    if (token case var token?) {
      request.headers['authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    var response = await http.Response.fromStream(await _client.send(request));
    var decoded = response.body.isEmpty
        ? <String, Object?>{}
        : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode >= 400) {
      throw ApiException('${decoded['error'] ?? response.statusCode}');
    }
    return decoded;
  }

  Future<void> health() => _send('GET', '/health');

  Future<void> sendCode(String phone) =>
      _send('POST', '/auth/code', {'phone': phone});

  /// Signs in with the code the server texted, and keeps the session.
  Future<User> verify(String phone, String code) async {
    var json = await _send('POST', '/auth/verify', {
      'phone': phone,
      'code': code,
    });
    token = json['token']! as String;
    return User.fromJson((json['user']! as Map).cast());
  }

  Future<User> me() async => User.fromJson(await _send('GET', '/me'));

  Future<List<Order>> orders() async {
    var json = await _send('GET', '/orders');
    return [
      for (var order in json['orders']! as List)
        Order.fromJson((order as Map).cast()),
    ];
  }

  Future<Order> order(String item) async =>
      Order.fromJson(await _send('POST', '/orders', {'item': item}));

  Future<Order> advance(String id) async =>
      Order.fromJson(await _send('POST', '/orders/$id/advance'));

  /// The server's socket: its greeting, then every order this user may see
  /// as it changes. Without a session the server greets and hangs up.
  WebSocketChannel live() => WebSocketChannel.connect(
    base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/live',
      queryParameters: {'token': ?token},
    ),
  );

  Stream<Order> orderUpdates(WebSocketChannel channel) => channel.stream
      .map(
        (message) =>
            (jsonDecode(message as String) as Map).cast<String, Object?>(),
      )
      .where((json) => json['type'] == 'order')
      .map((json) => Order.fromJson((json['order']! as Map).cast()));
}
