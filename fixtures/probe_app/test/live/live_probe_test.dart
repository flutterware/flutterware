import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

/// Three scenarios, each owning a server that answers slowly, so running
/// them one after another is measurably slower than three at once — and a
/// fourth that fails on purpose, to prove a red guest takes nobody with it.
Future<HttpServer> _serve(String body) async {
  var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    request.response
      ..write(body)
      ..close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

Future<String> _fetch(HttpServer server) async {
  var client = HttpClient();
  var response = await client
      .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
      .then((r) => r.close());
  var body = await response.transform(const SystemEncoding().decoder).join();
  client.close();
  return body;
}

void main() {
  for (var word in ['one', 'two', 'three']) {
    scenario('fetches $word', (s) async {
      var server = await _serve(word);
      await s.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FutureBuilder<String>(
              future: _fetch(server),
              builder: (_, snap) => Text(snap.data ?? 'loading'),
            ),
          ),
        ),
      );
      await s.screen(word);
      expect(find.text(word), findsOneWidget);
    });
  }

  scenario('a failing scenario does not poison its neighbours', (s) async {
    await s.pumpWidget(MaterialApp(home: Text('about to fail')));
    throw StateError('deliberate');
  });
}
