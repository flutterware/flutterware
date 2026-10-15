import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The store as a store: what a file is called, what it holds, and what it
/// stops holding.
void main() {
  late Directory directory;
  late ScenarioNetworkStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('fw_store');
    store = ScenarioNetworkStore(directory.path);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  List<String> files() =>
      [for (var file in directory.listSync()) p.basename(file.path)]..sort();

  ScenarioRecording recording({
    String url = 'https://api.example.com/v1/profile',
    String contentType = 'application/json',
    String body = '{}',
  }) => ScenarioRecording(
    method: 'GET',
    url: Uri.parse(url),
    status: 200,
    contentType: contentType,
    body: utf8.encode(body),
  );

  test('re-recording with a new content type leaves no orphan body', () {
    store.write(recording(contentType: 'application/json', body: '{"a":1}'));
    expect(files().where((name) => name.contains('.body.')), hasLength(1));
    expect(files().singleWhere((n) => n.contains('.body.')), endsWith('.json'));

    // The endpoint starts answering an error page instead — a login redirect,
    // a CDN in the way, a server that changed its mind.
    store.write(recording(contentType: 'text/html', body: '<h1>nope</h1>'));

    var bodies = files().where((name) => name.contains('.body.')).toList();
    expect(bodies, hasLength(1), reason: 'the old .body.json is gone');
    expect(bodies.single, endsWith('.body.html'));
    expect(
      store.read('GET', Uri.parse('https://api.example.com/v1/profile'))!.body,
      utf8.encode('<h1>nope</h1>'),
    );
  });

  test('a body that becomes empty takes its file with it', () {
    store.write(recording(body: '{"a":1}'));
    expect(files().where((name) => name.contains('.body.')), hasLength(1));
    store.write(recording(body: ''));
    expect(files().where((name) => name.contains('.body.')), isEmpty);
  });

  // A `.body.json` is a recorded *body*. Parsed as a recording it would put an
  // exchange the store does not hold into the refusal that lists them, and
  // send whoever read it looking for a matcher bug.
  test('a recorded body is not mistaken for a recording', () {
    store.write(
      ScenarioRecording(
        method: 'GET',
        url: Uri.parse('https://api.example.com/v1/hooks'),
        status: 200,
        contentType: 'application/json',
        // The shape a webhook, audit-log or request-log endpoint answers with.
        body: utf8.encode(
          jsonEncode({'method': 'POST', 'url': 'https://api.example.com/x'}),
        ),
      ),
    );
    expect(store.keys(), ['GET https://api.example.com/v1/hooks']);
  });

  test('what is kept, and what a committed file may not hold', () {
    for (var name in ['link', 'etag', 'x-total-count', 'retry-after']) {
      expect(ScenarioNetworkStore.keptHeader(name), isTrue, reason: name);
    }
    for (var name in [
      'Set-Cookie',
      'set-cookie2',
      'Authorization',
      'www-authenticate',
      'proxy-authenticate',
      'proxy-authorization',
      // Describing a transfer whose bytes are not what is stored.
      'content-encoding',
      'Content-Length',
      'transfer-encoding',
      'connection',
      'keep-alive',
      // Held as a field of its own.
      'content-type',
      // Different on every fetch of the same bytes.
      'Date',
      'age',
      'x-amz-request-id',
      'x-amz-id-2',
      'x-amz-cf-id',
      'x-request-id',
      'cf-ray',
    ]) {
      expect(ScenarioNetworkStore.keptHeader(name), isFalse, reason: name);
    }
  });

  test('a name is readable and unique', () {
    store.write(recording(url: 'https://api.example.com/v1/users/1'));
    store.write(recording(url: 'https://api.example.com/v1/users/2'));
    var metas = files().where((name) => !name.contains('.body.')).toList();
    expect(metas, hasLength(2), reason: 'two urls, two files');
    for (var name in metas) {
      expect(name, startsWith('get-api-example-com-v1-users-'));
    }
  });

  test('a long url keeps the end of its path in the name', () {
    // A content-addressed folder on a CDN: one host, one folder, and a hash
    // per file. Cut from the start, every name in it was the same 60 chars.
    String nameOf(String hash) {
      var url =
          'https://media-bucket-for-the-app.s3.eu-central-1.amazonaws.com'
          '/demo-media/$hash.jpg';
      directory.listSync().forEach((file) => file.deleteSync());
      store.write(recording(url: url, contentType: 'image/jpeg'));
      return files().singleWhere((name) => !name.contains('.body.'));
    }

    var one = nameOf('3fa9c1e2b4d5a6f7${'0' * 48}');
    var two = nameOf('9b8e7d6c5a4f3e2d${'0' * 48}');
    expect(one, startsWith('get-media-bucket-for-the-app-demo-media-3fa9c1e2'));
    expect(two, startsWith('get-media-bucket-for-the-app-demo-media-9b8e7d6c'));
  });

  test('a recording made under the old name replays and moves on', () {
    var url = Uri.parse(
      'https://media-bucket-for-the-app.s3.eu-central-1.amazonaws.com'
      '/demo-media/3fa9c1e2b4d5a6f7.jpg',
    );
    // What a store written before the rename holds: the slug cut at 60 from
    // the start, then the same digest.
    var digest = sha1.convert(utf8.encode('GET $url')).toString();
    var legacy =
        'get-media-bucket-for-the-app-s3-eu-central-1-amazonaws-com-d-'
        '${digest.substring(0, 8)}';
    File(p.join(directory.path, '$legacy.body.json')).writeAsStringSync('{}');
    File(p.join(directory.path, '$legacy.json')).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'method': 'GET',
        'url': '$url',
        'status': 200,
        'contentType': 'application/json',
        'bytes': 2,
        'body': '$legacy.body.json',
        'recorded': '2026-09-01T00:00:00.000Z',
      }),
    );

    expect(store.read('GET', url)?.body, utf8.encode('{}'));

    store.write(recording(url: '$url', body: '{"moved":true}'));
    expect(files().where((name) => name.startsWith(legacy)), isEmpty);
    expect(files(), hasLength(2));
    expect(store.read('GET', url)?.body, utf8.encode('{"moved":true}'));
  });

  test('re-recording what is already held writes nothing', () {
    store.write(recording(body: '{"a":1}'));
    var meta = File(
      p.join(directory.path, files().singleWhere((n) => !n.contains('.body.'))),
    );
    // A mark nothing but a rewrite would remove.
    meta.writeAsStringSync('${meta.readAsStringSync()}\n');
    var marked = meta.readAsStringSync();

    store.write(recording(body: '{"a":1}'));
    expect(meta.readAsStringSync(), marked, reason: 'the same bytes');

    store.write(recording(body: '{"a":2}'));
    expect(meta.readAsStringSync(), isNot(marked), reason: 'a new body');
  });

  test('a file that says it is something else answers for nothing', () {
    store.write(recording());
    var meta = File(
      p.join(directory.path, files().firstWhere((n) => !n.contains('.body.'))),
    );
    var json = jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
    json['url'] = 'https://api.example.com/v1/something-else';
    meta.writeAsStringSync(jsonEncode(json));
    expect(
      store.read('GET', Uri.parse('https://api.example.com/v1/profile')),
      isNull,
    );
  });
}
