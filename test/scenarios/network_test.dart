import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/app_events/events.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';
import 'package:http/http.dart' as http;

/// What a scenario's http requests reach, end to end.
///
/// The server is a real one on the loopback interface, because the whole
/// question is whether a socket is reachable from inside FakeAsync — a fake
/// server would answer it by construction and prove nothing.
void main() {
  late HttpServer server;
  late String base;
  late int closedPort;
  var hits = <String>[];
  var agents = <String>[];
  var captures = <ScenarioStepCapture>[];

  setUpAll(() async {
    // Bound and released here, outside every scenario's fake zone, like the
    // server: a port nothing listens on.
    var closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    closedPort = closed.port;
    await closed.close();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      hits.add('${request.method} ${request.uri.path}');
      agents.add(request.headers.value('user-agent') ?? '');
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'png')
        ..add(scenarioPlaceholderPng(width: 8, height: 8));
      await request.response.close();
    });
  });
  tearDownAll(() => server.close(force: true));

  late Directory store;

  setUp(() {
    hits = [];
    agents = [];
    captures = [];
    // A recording written by a test belongs in a temporary directory, never in
    // the package's own committed store.
    store = Directory.systemTemp.createTempSync('fw_network_test');
    scenarioNetworkStorePath = store.path;
    scenarioRunListener = captures.add;
    // The harness's, in a real run. Here the test is the harness.
    appEventBuffer = AppEventBuffer();
  });
  tearDown(() {
    scenarioRunListener = null;
    appEventBuffer = null;
    scenarioNetworkStorePath = null;
    store.deleteSync(recursive: true);
  });

  group('off — the default', () {
    scenario('refuses a request nothing stated, and names it', (s) async {
      await s.pumpWidget(_Blank());
      var refusal = await s.runAsync(() async {
        try {
          await http.get(Uri.parse('$base/api/messages'));
          return 'no refusal';
        } on ScenarioNetworkRefusal catch (error) {
          return '$error';
        }
      });
      expect(refusal, contains('refused — the network is off'));
      expect(refusal, contains('$base/api/messages'));
      expect(refusal, contains("s.network.get('/api/messages'"));
      expect(hits, isEmpty);
      expect(s.network.requests.single.outcome, 'off');
    });

    scenario('does not hang on https, where flutter_test does', (s) async {
      // Under `flutter_test`'s own mock this url opens a real TLS connection
      // whose timers are armed under FakeAsync and never fire — the step
      // reports a blank frame and nothing else. Here it is answered at once.
      await s.pumpWidget(_Blank());
      var refused = await s.runAsync(() async {
        try {
          await http.get(Uri.parse('https://example.invalid/logo.png'));
          return false;
        } on ScenarioNetworkRefusal {
          return true;
        }
      });
      expect(refused, isTrue);
    });

    // Asserted in a tearDown because a capture is held pending until the body
    // returns — a named step adopts the one before it, and nothing can be
    // adopted after somebody has been handed the picture.
    group('reports the refusal on the step', () {
      scenario('as a network event, marked as an error', (s) async {
        await s.pumpWidget(_Blank());
        await s.runAsync(() async {
          try {
            await http.get(Uri.parse('$base/api/me'));
          } on ScenarioNetworkRefusal {
            // The event is the assertion.
          }
        });
        await s.screen('after');
      });
      tearDown(() {
        var events = captures.expand((c) => c.events).toList();
        var refusal = events.singleWhere(
          (e) => e.channel == AppChannel.network,
        );
        expect(refusal.title, endsWith('/api/me'));
        expect(refusal.error, isTrue);
        expect(
          refusal.detail,
          'refused — the network is off for this scenario',
        );
        expect(refusal.body, contains('was not made'));
      });
    });
  });

  group('stubs', () {
    scenario('a stated json answer beats the mode', (s) async {
      s.network.get('/api/messages', json: ['one', 'two']);
      await s.pumpWidget(_Blank());
      var body = await s.runAsync(
        () async => (await http.get(Uri.parse('$base/api/messages'))).body,
      );
      expect(jsonDecode(body!), ['one', 'two']);
      expect(hits, isEmpty, reason: 'a stub answers without a socket');
      expect(s.network.requests.single.outcome, 'stub');
      expect(s.network.requests.single.status, 200);
    });

    scenario('a status with no body', (s) async {
      s.network.get('/api/messages', status: 503);
      await s.pumpWidget(_Blank());
      var status = await s.runAsync(
        () async =>
            (await http.get(Uri.parse('$base/api/messages'))).statusCode,
      );
      expect(status, 503);
    });

    scenario('throws: is what an app catches', (s) async {
      s.network.any(throws: const SocketException('Network is unreachable'));
      await s.pumpWidget(_Blank());
      var caught = await s.runAsync(() async {
        try {
          await http.get(Uri.parse('$base/anything'));
          return 'nothing';
        } on SocketException catch (error) {
          return error.message;
        }
      });
      expect(caught, 'Network is unreachable');
    });

    scenario('a fallback never swallows a stub after it', (s) async {
      s.network.any(status: 500);
      s.network.get('/api/me', json: {'name': 'Ada'});
      await s.pumpWidget(_Blank());
      var answers = await s.runAsync(
        () async => [
          (await http.get(Uri.parse('$base/api/me'))).statusCode,
          (await http.get(Uri.parse('$base/api/other'))).statusCode,
        ],
      );
      expect(answers, [200, 500]);
    });

    scenario('re-stating a url changes what it answers from there on', (
      s,
    ) async {
      s.network.get('/api/items', json: []);
      await s.pumpWidget(_Blank());
      var before = await s.runAsync(
        () async => (await http.get(Uri.parse('$base/api/items'))).body,
      );
      s.network.get('/api/items', json: ['new']);
      var after = await s.runAsync(
        () async => (await http.get(Uri.parse('$base/api/items'))).body,
      );
      expect(jsonDecode(before!), isEmpty);
      expect(jsonDecode(after!), ['new']);
    });

    scenario('a path stub does not match by substring', (s) async {
      s.network.get('/api/me', json: {'name': 'Ada'});
      await s.pumpWidget(_Blank());
      var refused = await s.runAsync(() async {
        try {
          await http.get(Uri.parse('$base/api/messages'));
          return false;
        } on ScenarioNetworkRefusal {
          return true;
        }
      });
      expect(refused, isTrue);
    });

    group('a stubbed image decodes and paints', () {
      scenario('with no socket opened', (s) async {
        s.network.image(
          '/avatars/1.png',
          scenarioPlaceholderPng(width: 32, height: 32, red: 0xE0, green: 0x40),
        );
        await s.pumpWidget(_Avatar(url: '$base/avatars/1.png'));
        await s.screen('the avatar');
      });
      tearDown(() {
        expect(captures.last.texts, isNot(contains('ERR')));
        expect(captures.last.landed, isTrue);
        expect(hits, isEmpty);
      });
    });
  });

  group('live', () {
    scenario('reaches a real socket', network: ScenarioNetwork.live, (s) async {
      await s.pumpWidget(_Blank());
      var status = await s.runAsync(
        () async =>
            (await http.get(Uri.parse('$base/api/messages'))).statusCode,
      );
      expect(status, 200);
      expect(hits, ['GET /api/messages']);
      expect(s.network.requests.single.outcome, 'live');
    });

    // It used to reach the root zone as an uncaught error and take
    // `flutter_tester` down, catch or no catch.
    scenario(
      'a refused connection is an error the app can catch',
      network: ScenarioNetwork.live,
      (s) async {
        await s.pumpWidget(_Blank());
        var caught = await s.runAsync(() async {
          try {
            await http.get(Uri.parse('http://127.0.0.1:$closedPort/'));
            return null;
          } on Object catch (error) {
            return error;
          }
        });
        expect(caught, isA<SocketException>());
        expect(
          s.network.requests.single.refusal,
          startsWith('SocketException'),
        );
      },
    );

    // The measurement this whole file is about: a request the *widget tree*
    // made — not the body — completing inside the step that mounted it, under
    // fake time, with no extra pumping asked for.
    group('an image the widget tree asked for', () {
      scenario(
        'lands in the step that mounts it',
        network: ScenarioNetwork.live,
        (s) async {
          await s.pumpWidget(_Avatar(url: '$base/avatars/live.png'));
          await s.screen('the avatar');
        },
      );
      tearDown(() {
        expect(hits, ['GET /avatars/live.png']);
        expect(captures.last.texts, isNot(contains('ERR')));
        expect(captures.last.landed, isTrue);
      });
    });

    scenario('a stub still beats the mode', network: ScenarioNetwork.live, (
      s,
    ) async {
      s.network.get('/api/me', json: {'name': 'Ada'});
      await s.pumpWidget(_Blank());
      await s.runAsync(() async {
        await http.get(Uri.parse('$base/api/me'));
        await http.get(Uri.parse('$base/api/other'));
      });
      expect(hits, ['GET /api/other']);
    });
  });

  group('splits', () {
    // A body runs once per path through its splits, from the top. Each path
    // states its own answers, and must not see the ones the path before it
    // stated — nor the requests it made.
    var seen = <String, List<int>>{};
    scenario('each branch states its own answers', (s) async {
      s.network.get('/api/items', status: 200);
      await s.pumpWidget(_Blank());
      await s.split({
        'plenty': () async {
          s.network.get('/api/items', json: ['a', 'b']);
          seen['plenty'] = await _statuses(s, base);
        },
        'nothing': () async {
          // States nothing of its own past the prefix, so the prefix's 200
          // stands and the branch before it is nowhere.
          seen['nothing'] = await _statuses(s, base);
        },
      });
    });
    tearDown(() {
      expect(seen['plenty'], [200]);
      expect(seen['nothing'], [200]);
    });
  });

  group('what a scenario ever asked for', () {
    // `resetForReplay` empties the requests log between branches, because a
    // branch asserting on what it asked for must not see the branch before
    // it. The count a *mode* is judged against is the other question and must
    // outlive the reset: a scenario that fetched in one branch has fetched,
    // whatever the last path through it did.
    var counted = <String, ({int here, int ever})>{};
    scenario('outlives the branch that asked', network: ScenarioNetwork.live, (
      s,
    ) async {
      await s.pumpWidget(_Blank());
      await s.split({
        'fetches': () async {
          await _statuses(s, base);
          counted['fetches'] = (
            here: s.network.requests.length,
            ever: s.network.requestsEver,
          );
        },
        'quiet': () async {
          counted['quiet'] = (
            here: s.network.requests.length,
            ever: s.network.requestsEver,
          );
        },
      });
    });
    tearDown(() {
      expect(counted['fetches'], (here: 1, ever: 1));
      // The branch asked for nothing, and the scenario still asked for
      // something. Reading `requests` here is what made a split scenario
      // report its stated mode as inert.
      expect(counted['quiet'], (here: 0, ever: 1));
    });
  });

  group('a refusal is reported, not fatal', () {
    // An `Image.network` with no `errorBuilder` has no error listener of its
    // own, so the throw reaches `FlutterError.reportError` — which in a test
    // binding is what turns a test red. Left alone, `off` would fail every
    // scenario with an unguarded network image on it, including the https
    // ones that used to hang and pass.
    scenario('an image with no errorBuilder still passes', (s) async {
      await s.pumpWidget(
        const _BareImage(url: 'https://example.invalid/a.png'),
      );
      await s.screen('the broken avatar');
      // Nothing pending: the binding never saw it, so nothing is going to fail
      // this scenario when the body returns.
      expect(s.tester.takeException(), isNull);
      expect(s.network.requests.single.outcome, 'off');
    });

    // And only a refusal: an author who wrote `throws:` is injecting an error
    // on purpose and wants it to behave like one, so it reaches the binding
    // and `takeException` is what has to clear it.
    scenario("a stub's own throws: is an error like any other", (s) async {
      s.network.any(throws: const FormatException('boom'));
      await s.pumpWidget(
        const _BareImage(url: 'https://example.invalid/b.png'),
      );
      await s.screen('the broken avatar');
      expect(s.tester.takeException(), isA<FormatException>());
    });
  });

  group('the shape of the funnel', () {
    scenario('an app that builds its own client goes through it too', (
      s,
    ) async {
      s.network.get('/api/me', json: {'name': 'Ada'});
      // Built under fake time, the way an app builds one at boot.
      var client = HttpClient();
      await s.pumpWidget(_Blank());
      var status = await s.runAsync(() async {
        var request = await client.getUrl(Uri.parse('$base/api/me'));
        var response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      });
      // Closing "its" client must not take the shared pool with it.
      client.close();
      expect(status, 200);
    });

    // `record` reaches the network as surely as `live` does, so a setting an
    // app makes on "its" client has to reach the pool in both — an app pointed
    // at a self-signed staging API would otherwise record fine under one and
    // fail to record at all under the other.
    for (var mode in [ScenarioNetwork.live, ScenarioNetwork.record]) {
      scenario(
        'a client setting reaches the pool under ${mode.name}',
        network: mode,
        (s) async {
          var client = HttpClient()..userAgent = 'fw-probe/1';
          await s.pumpWidget(_Blank());
          var seen = await s.runAsync(() async {
            var response = await (await client.getUrl(
              Uri.parse('$base/api/agent'),
            )).close();
            await response.drain<void>();
            return agents.last;
          });
          client.close();
          expect(seen, 'fw-probe/1');
        },
      );
    }

    // The one setting that is deliberately *not* forwarded — forwarding it
    // would let a recording hold gzipped bytes with no header left to explain
    // them. The getter says so rather than echoing what it was handed.
    scenario('autoUncompress reports what is true, not what it was told', (
      s,
    ) async {
      var client = HttpClient()..autoUncompress = false;
      expect(client.autoUncompress, isTrue);
      await s.pumpWidget(_Blank());
      client.close();
    });

    scenario('the requests log is what the body can assert on', (s) async {
      s.network.post('/api/orders', json: {'id': 7}, status: 201);
      await s.pumpWidget(_Blank());
      await s.runAsync(() => http.post(Uri.parse('$base/api/orders')));
      expect(s.network.requests.last.method, 'POST');
      expect(s.network.requests.last.url.path, '/api/orders');
      expect(s.network.requests.last.status, 201);
    });
  });
}

Future<List<int>> _statuses(ScenarioTester s, String base) async {
  await s.runAsync(
    () async => (await http.get(Uri.parse('$base/api/items'))).statusCode,
  );
  return [for (var request in s.network.requests) request.status ?? 0];
}

class _BareImage extends StatelessWidget {
  const _BareImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(child: Image(image: NetworkImage(url), width: 32)),
    ),
  );
}

class _Blank extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('ready'))),
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Image.network(
          url,
          width: 32,
          height: 32,
          errorBuilder: (context, error, stack) => const Text('ERR'),
        ),
      ),
    ),
  );
}
