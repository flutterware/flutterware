import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/app_events/events.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Recording once and replaying forever, against a real socket and a real
/// directory.
///
/// The server counts its hits, which is the whole assertion: `record` reaches
/// it, `replay` does not, and what the two runs draw is the same.
void main() {
  late HttpServer server;
  late String base;
  late Directory store;
  var hits = <String>[];
  var captures = <ScenarioStepCapture>[];
  var body = '["one","two"]';

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      hits.add('${request.method} ${request.uri.path}');
      if (request.uri.path.endsWith('.png')) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('image', 'png')
          ..add(scenarioPlaceholderPng(width: 8, height: 8, red: 0xC0));
      } else if (request.uri.path == '/api/gone') {
        request.response.statusCode = 404;
      } else if (request.uri.path == '/api/page') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'json')
          ..headers.set('link', '<$base/api/page?p=2>; rel="next"')
          ..headers.set('etag', 'W/"abc"')
          ..headers.set('set-cookie', 'session=secret; HttpOnly')
          ..headers.set('authorization', 'Bearer nope')
          ..write('[]');
      } else {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'json')
          ..write(body);
      }
      await request.response.close();
    });
  });
  tearDownAll(() => server.close(force: true));

  setUp(() {
    hits = [];
    captures = [];
    body = '["one","two"]';
    scenarioRunListener = captures.add;
    appEventBuffer = AppEventBuffer();
    store = Directory.systemTemp.createTempSync('fw_network_store');
    scenarioNetworkStorePath = store.path;
  });
  tearDown(() {
    scenarioRunListener = null;
    appEventBuffer = null;
    scenarioNetworkStorePath = null;
    if (store.existsSync()) store.deleteSync(recursive: true);
  });

  List<String> storeFiles() =>
      [for (var file in store.listSync()) p.basename(file.path)]..sort();

  group('record', () {
    scenario(
      'goes out, and writes what came back',
      network: ScenarioNetwork.record,
      (s) async {
        await s.pumpWidget(_Blank());
        var answer = await s.runAsync(
          () async => (await http.get(Uri.parse('$base/api/messages'))).body,
        );
        expect(answer, '["one","two"]');
        expect(hits, ['GET /api/messages']);
        expect(s.network.requests.single.outcome, 'record');

        // Two files: the metadata a human reads, and the body with the
        // extension its content type earned.
        var files = storeFiles();
        expect(files, hasLength(2));
        var metaFile = files.singleWhere((name) => !name.contains('.body.'));
        var bodyFile = files.singleWhere((name) => name.contains('.body.'));
        expect(bodyFile, endsWith('.body.json'));
        expect(metaFile, startsWith('get-127-0-0-1-api-messages-'));

        var meta = jsonDecode(
          File(p.join(store.path, metaFile)).readAsStringSync(),
        ) as Map<String, Object?>;
        expect(meta['method'], 'GET');
        expect(meta['url'], '$base/api/messages');
        expect(meta['status'], 200);
        expect(meta['contentType'], startsWith('application/json'));
        expect(meta['bytes'], body.length);
        // The request's own headers are never part of a recording — they are
        // not part of the key, so keeping them would write an `Authorization`
        // into a committed file for nothing.
        expect(meta.keys, isNot(contains('requestHeaders')));

        // The body is the exact bytes, in a file an editor opens as JSON.
        expect(File(p.join(store.path, bodyFile)).readAsStringSync(), body);
      },
    );

    scenario(
      'a status a scenario is about is recorded too',
      network: ScenarioNetwork.record,
      (s) async {
        await s.pumpWidget(_Blank());
        await s.runAsync(() => http.get(Uri.parse('$base/api/gone')));
        // 404, empty body: metadata only, no body file.
        expect(storeFiles(), hasLength(1));
        var meta = jsonDecode(
          File(p.join(store.path, storeFiles().single)).readAsStringSync(),
        ) as Map<String, Object?>;
        expect(meta['status'], 404);
        expect(meta['bytes'], 0);
      },
    );

    scenario(
      'the caller is handed the bytes that were written',
      network: ScenarioNetwork.record,
      (s) async {
        await s.pumpWidget(_Avatar(url: '$base/avatars/1.png'));
        await s.screen('the avatar');
      },
    );
  });

  group('headers', () {
    // A screen that paginates off `Link` works under `live` and would render
    // one page forever after being recorded, if a recording kept only the
    // content type.
    scenario(
      'a recording keeps what an app reads',
      network: ScenarioNetwork.record,
      (s) async {
        await s.pumpWidget(_Blank());
        var link = await s.runAsync(
          () async =>
              (await http.get(Uri.parse('$base/api/page'))).headers['link'],
        );
        expect(link, contains('rel="next"'));

        var meta = jsonDecode(
          File(
            p.join(
              store.path,
              storeFiles().singleWhere((n) => !n.contains('.body.')),
            ),
          ).readAsStringSync(),
        ) as Map<String, Object?>;
        var headers = meta['headers']! as Map<String, Object?>;
        expect(headers['link'], isNotNull);
        expect(headers['etag'], ['W/"abc"']);
        // Credentials never reach a committed file.
        expect(headers.keys, isNot(contains('set-cookie')));
        expect(headers.keys, isNot(contains('authorization')));
        // Nor does anything describing a transfer whose bytes are not stored.
        expect(headers.keys, isNot(contains('content-encoding')));
        expect(headers.keys, isNot(contains('content-length')));
        expect(headers.keys, isNot(contains('content-type')));
      },
    );

    scenario('and replay hands them back', (s) async {
      s.network.store.write(
        ScenarioRecording(
          method: 'GET',
          url: Uri.parse('$base/api/page'),
          status: 200,
          contentType: 'application/json',
          headers: const {
            'link': ['<https://api.example.com/page?p=2>; rel="next"'],
          },
          body: utf8.encode('[]'),
        ),
      );
      await s.pumpWidget(_Blank());
      var link = await s.runAsync(
        () async =>
            (await http.get(Uri.parse('$base/api/page'))).headers['link'],
      );
      expect(link, contains('rel="next"'));
    }, network: ScenarioNetwork.replay);
  });

  group('replay', () {
    scenario('answers from the store, with no socket', (s) async {
      // Recorded by hand rather than by a previous scenario: a body must not
      // depend on what another body left behind.
      s.network.store.write(
        ScenarioRecording(
          method: 'GET',
          url: Uri.parse('$base/api/messages'),
          status: 200,
          contentType: 'application/json',
          body: utf8.encode('["recorded"]'),
        ),
      );
      await s.pumpWidget(_Blank());
      var answer = await s.runAsync(
        () async => (await http.get(Uri.parse('$base/api/messages'))).body,
      );
      expect(answer, '["recorded"]');
      expect(hits, isEmpty);
    }, network: ScenarioNetwork.replay);

    scenario('a miss names the url and what the store does hold', (s) async {
      s.network.store.write(
        ScenarioRecording(
          method: 'GET',
          url: Uri.parse('$base/api/messages'),
          status: 200,
          body: utf8.encode('[]'),
        ),
      );
      await s.pumpWidget(_Blank());
      var refusal = await s.runAsync(() async {
        try {
          await http.get(Uri.parse('$base/api/other'));
          return 'answered';
        } on ScenarioNetworkRefusal catch (error) {
          return '$error';
        }
      });
      expect(refusal, contains('no recording for this request'));
      expect(refusal, contains('$base/api/other'));
      expect(refusal, contains('It holds 1 request for 127.0.0.1'));
      expect(refusal, contains('GET $base/api/messages'));
      expect(refusal, contains('--network=record'));
      expect(s.network.requests.single.outcome, 'not-recorded');
    }, network: ScenarioNetwork.replay);

    scenario('an empty store says so rather than listing nothing', (s) async {
      await s.pumpWidget(_Blank());
      var refusal = await s.runAsync(() async {
        try {
          await http.get(Uri.parse('$base/api/other'));
          return 'answered';
        } on ScenarioNetworkRefusal catch (error) {
          return '$error';
        }
      });
      expect(refusal, contains('Nothing has been recorded yet'));
    }, network: ScenarioNetwork.replay);

    scenario('the query string is part of the identity', (s) async {
      s.network.store.write(
        ScenarioRecording(
          method: 'GET',
          url: Uri.parse('$base/api/items?page=1'),
          status: 200,
          body: utf8.encode('["page one"]'),
        ),
      );
      await s.pumpWidget(_Blank());
      var answers = await s.runAsync(() async {
        var one = (await http.get(Uri.parse('$base/api/items?page=1'))).body;
        try {
          await http.get(Uri.parse('$base/api/items?page=2'));
          return [one, 'answered'];
        } on ScenarioNetworkRefusal {
          return [one, 'refused'];
        }
      });
      expect(answers, ['["page one"]', 'refused']);
    }, network: ScenarioNetwork.replay);

    scenario('a stub still beats the store', (s) async {
      s.network.store.write(
        ScenarioRecording(
          method: 'GET',
          url: Uri.parse('$base/api/messages'),
          status: 200,
          body: utf8.encode('["recorded"]'),
        ),
      );
      s.network.get('/api/messages', json: ['stated']);
      await s.pumpWidget(_Blank());
      var answer = await s.runAsync(
        () async => (await http.get(Uri.parse('$base/api/messages'))).body,
      );
      expect(jsonDecode(answer!), ['stated']);
    }, network: ScenarioNetwork.replay);
  });

  group('the round trip', () {
    // The claim the whole feature rests on: what a `record` run drew and what
    // every `replay` run after it draws are the same picture, and only the
    // first one needed a network. So this group keeps **one** store across its
    // two scenarios — the outer setUp's fresh temp directory would throw away
    // the very thing under test.
    late Directory shared;
    var digests = <String>[];
    var sockets = <int>[];
    setUpAll(() {
      shared = Directory.systemTemp.createTempSync('fw_network_round_trip');
    });
    tearDownAll(() => shared.deleteSync(recursive: true));
    setUp(() => scenarioNetworkStorePath = shared.path);

    scenario('records', network: ScenarioNetwork.record, (s) async {
      await s.pumpWidget(_Avatar(url: '$base/avatars/round.png'));
      await s.screen('the avatar');
    });

    scenario('replays what the record wrote', network: ScenarioNetwork.replay, (
      s,
    ) async {
      await s.pumpWidget(_Avatar(url: '$base/avatars/round.png'));
      await s.screen('the avatar');
    });

    tearDown(() {
      digests.add(captures.last.digestOfBytes);
      // `hits` is emptied by the outer setUp, so this is *this* scenario's.
      sockets.add(hits.length);
      expect(captures.last.texts, isNot(contains('ERR')));
      expect(captures.last.landed, isTrue);
    });
    tearDownAll(() {
      expect(digests, hasLength(2));
      expect(
        digests.first,
        digests.last,
        reason: 'a recorded run and a replayed run draw the same picture',
      );
      // One socket for the record, none for the replay.
      expect(sockets, [1, 0]);
    });
  });
}

extension on ScenarioStepCapture {
  /// Enough of the frame to tell two pictures apart without a hasher.
  String get digestOfBytes {
    var pixels = bytes;
    if (pixels == null) return 'none';
    var sum = 0;
    for (var i = 0; i < pixels.length; i++) {
      sum = (sum * 31 + pixels[i]) & 0x7FFFFFFF;
    }
    return '${pixels.length}:$sum';
  }
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
