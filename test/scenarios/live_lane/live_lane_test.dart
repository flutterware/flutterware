import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('the binding is live and http is real', (s) async {
    expect(
      WidgetsBinding.instance,
      isA<LiveTestWidgetsFlutterBinding>(),
      reason: 'a real-time folder runs under the live binding',
    );
    // A server the scenario owns: real sockets, no network weather.
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = 200
        ..write('hello')
        ..close();
    });
    addTearDown(() => server.close(force: true));

    var client = HttpClient();
    var response = await client
        .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
        .then((r) => r.close());
    expect(response.statusCode, 200, reason: 'no 400 mock under real time');
    client.close();
  });

  scenario('a real timer fires on the wall clock', (s) async {
    var sw = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(45));
  });

  scenario('animations are scaled for the body only', (s) async {
    expect(timeDilation, 0.1);
    await s.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('scaled'))),
      ),
    );
    expect(timeDilation, 0.1);
  });
}
