import 'dart:convert';
import 'dart:io';

import 'package:flutterware/src/server/frames.dart';
import 'package:flutterware/src/server/inspector_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A peer that keeps what it was sent, and can be told to start failing.
///
/// It encodes, because the real ones do. `_SocketPeer.send` is
/// `socket.write(encodeFrame(frame))`, so a frame the encoder refuses throws
/// out of `send` — which the core reads as a dead peer. A fake that merely
/// stored the map could not fail that way, and that is why an unencodable
/// payload reached a release.
class FakePeer implements InspectorPeer {
  final frames = <Map<String, Object?>>[];
  var closed = false;
  var broken = false;

  @override
  void send(Map<String, Object?> frame) {
    if (broken) throw StateError('peer is gone');
    encodeFrame(frame);
    frames.add(frame);
  }

  @override
  void close() => closed = true;

  List<Map<String, Object?>> ofType(String type) => [
    for (var frame in frames)
      if (frame[frameType] == type) frame,
  ];
}

void main() {
  /// The whole point of the split: an inspector that runs inside a Flutter app
  /// on a phone cannot bind a socket or write a handle file, so the core and
  /// the wire vocabulary must not reach for `dart:io` — nor, transitively, for
  /// anything that does. Checked as an import walk rather than trusted to
  /// review, because the day this regresses is the day the VM-service
  /// transport stops compiling for a reason nobody will connect to this file.
  test('the core and the frames reach nothing platform-bound', () {
    var forbidden = {'dart:io', 'dart:ffi', 'dart:isolate'};
    var seen = <String>{};
    var queue = <String>[p.join('lib', 'src', 'server', 'inspector_core.dart')];
    var offences = <String>[];

    while (queue.isNotEmpty) {
      var path = queue.removeLast();
      if (!seen.add(path)) continue;
      var source = File(path).readAsStringSync();
      var directive = RegExp(
        r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
        multiLine: true,
      );
      for (var match in directive.allMatches(source)) {
        var uri = match.group(1)!;
        if (forbidden.contains(uri) || uri.startsWith('package:flutter/')) {
          offences.add('$path imports $uri');
        } else if (!uri.startsWith('dart:') && !uri.startsWith('package:')) {
          queue.add(p.normalize(p.join(p.dirname(path), uri)));
        }
      }
    }

    expect(seen, contains(p.join('lib', 'src', 'server', 'frames.dart')));
    expect(offences, isEmpty);
  });

  group('core', () {
    late InspectorCore core;

    setUp(() {
      core = InspectorCore(identity: () => {'name': 'app'}, ringSize: 3);
    });

    void attach(FakePeer peer, {int id = 1}) => core.handleFrame(peer, {
      frameChannel: metaChannel,
      frameType: typeRequest,
      frameRequestId: id,
      frameMethod: metaAttach,
    });

    test('attach answers identity plus channels, replays, then marks the '
        'boundary', () {
      core.addEvent('http', {'path': '/one'});
      core.addEvent('sql', {'q': 'select 1'}, rid: 'r1');

      var peer = FakePeer();
      attach(peer);

      var hello = peer.frames.first;
      expect(hello[frameType], typeResponse);
      expect(hello[frameRequestId], 1);
      expect(hello[framePayload], {
        'name': 'app',
        'channels': ['http', 'sql'],
        'events': 2,
      });

      var events = peer.ofType(typeEvent);
      expect(events[0][framePayload], {'path': '/one'});
      expect(events[1][frameCorrelation], 'r1');
      expect(events.last[framePayload], {'type': metaReplayDone});
    });

    test('an attached peer gets live events; an unattached one gets none', () {
      var attached = FakePeer();
      var knocking = FakePeer();
      attach(attached);
      var before = attached.frames.length;

      core.addEvent('log', {'message': 'live'});

      expect(attached.frames.length, before + 1);
      expect(attached.frames.last[framePayload], {'message': 'live'});
      expect(knocking.frames, isEmpty);
    });

    test('a peer that fails a write is dropped, not retried', () {
      var peer = FakePeer();
      attach(peer);
      peer.broken = true;

      core.addEvent('log', {'message': 'one'});
      expect(peer.closed, isTrue);

      // Un-break it: a dropped peer must stay dropped because the core forgot
      // it, not because it would still refuse the write.
      peer.broken = false;
      var delivered = peer.frames.length;
      core.addEvent('log', {'message': 'two'});
      expect(peer.frames, hasLength(delivered));
    });

    test('handlers run and answer; unknown methods answer err', () async {
      core.registerHandler('sql', 'explain', (params) => {'plan': params['q']});
      var peer = FakePeer();

      core.handleFrame(peer, {
        frameChannel: 'sql',
        frameType: typeRequest,
        frameRequestId: 7,
        frameMethod: 'explain',
        framePayload: {'q': 'select 1'},
      });
      core.handleFrame(peer, {
        frameChannel: 'sql',
        frameType: typeRequest,
        frameRequestId: 8,
        frameMethod: 'nope',
      });

      await Future<void>.delayed(Duration.zero);
      expect(peer.ofType(typeResponse).single[framePayload], {
        'plan': 'select 1',
      });
      expect(peer.ofType(typeError).single[framePayload], {
        'message': 'no handler for sql.nope',
      });
    });

    test('details are held aside and fetched by event id', () {
      core.addEvent('http', {'path': '/one'}, details: {'body': 'hello'});
      var peer = FakePeer();

      core.handleFrame(peer, {
        frameChannel: metaChannel,
        frameType: typeRequest,
        frameRequestId: 3,
        frameMethod: metaDetail,
        framePayload: {'event': 1},
      });
      core.handleFrame(peer, {
        frameChannel: metaChannel,
        frameType: typeRequest,
        frameRequestId: 4,
        frameMethod: metaDetail,
        framePayload: {'event': 99},
      });

      var responses = peer.ofType(typeResponse);
      expect(responses[0][framePayload], {
        'details': {'body': 'hello'},
      });
      expect(responses[1][framePayload], {'evicted': true});
    });

    test('onEvent sees every event, before any peer does', () {
      var seen = <String>[];
      var reducing = InspectorCore(
        identity: () => const {},
        onEvent: (channel, payload) => seen.add('$channel:${payload['n']}'),
      );

      reducing.addEvent('a', {'n': 1});
      reducing.addEvent('b', {'n': 2});

      expect(seen, ['a:1', 'b:2']);
    });

    test('a stopped core takes no more events', () {
      var peer = FakePeer();
      attach(peer);
      var delivered = peer.frames.length;
      core.stop();

      core.addEvent('log', {'message': 'after'});

      expect(core.isStopped, isTrue);
      expect(peer.closed, isTrue);
      expect(peer.frames, hasLength(delivered));
      // And the event was not merely undeliverable — it never entered the
      // ring, so a peer attaching to the corpse would not see it either.
      var later = FakePeer();
      attach(later, id: 2);
      expect(later.ofType(typeEvent).single[framePayload], {
        'type': metaReplayDone,
      });
    });

    test('an unencodable payload value costs the value, not the peer', () {
      var peer = FakePeer();
      attach(peer);
      var before = peer.frames.length;

      core.addEvent('sql', {
        'query': 'select * from t where at > @1',
        'params': [DateTime.utc(2026), 'ok'],
      });

      expect(peer.closed, isFalse);
      expect(peer.frames, hasLength(before + 1));
      expect(peer.frames.last[framePayload], {
        'query': 'select * from t where at > @1',
        'params': ['2026-01-01 00:00:00.000Z', 'ok'],
      });
    });

    test('and it does not poison the attaches that come after', () {
      core.addEvent('sql', {
        'params': {'when': DateTime.utc(2026)},
      });

      var later = FakePeer();
      attach(later);

      expect(later.closed, isFalse);
      expect(later.ofType(typeEvent).first[framePayload], {
        'params': {'when': '2026-01-01 00:00:00.000Z'},
      });
    });

    test('a value with a toJson stays structured; a cycle stops', () {
      var peer = FakePeer();
      attach(peer);
      var cyclic = <Object?>[1];
      cyclic.add(cyclic);

      core.addEvent('log', {
        'point': _Point(3, 4),
        'nan': double.nan,
        'cyclic': cyclic,
      });

      expect(peer.closed, isFalse);
      var payload = peer.frames.last[framePayload]! as Map<String, Object?>;
      expect(payload['point'], isA<_Point>());
      expect(payload['nan'], 'NaN');
      expect(jsonEncode(payload), contains('"x":3'));
    });

    test('details a peer could not have taken are kept, minus the value', () {
      core.addEvent(
        'http',
        {'path': '/one'},
        details: {
          'requestHeaders': {'x-when': DateTime.utc(2026)},
        },
      );
      var peer = FakePeer();
      attach(peer);
      core.handleFrame(peer, {
        frameChannel: metaChannel,
        frameType: typeRequest,
        frameRequestId: 9,
        frameMethod: metaDetail,
        framePayload: {'event': 1},
      });

      var answer = peer.frames.last[framePayload]! as Map<String, Object?>;
      expect(answer['details'], {
        'requestHeaders': {'x-when': '2026-01-01 00:00:00.000Z'},
      });
    });

    test('frames survive a JSON round trip', () {
      var peer = FakePeer();
      core.addEvent('http', {'path': '/one'});
      attach(peer);

      for (var frame in peer.frames) {
        expect(tryDecodeFrame(encodeFrame(frame)), frame);
      }
      expect(jsonDecode(jsonEncode(peer.frames.first)), isA<Map>());
    });
  });
}

/// A reporter's own type that knows how to encode itself — `jsonEncode` calls
/// `toJson()`, so the sanitizer must leave it alone rather than flatten it.
class _Point {
  _Point(this.x, this.y);

  final int x;
  final int y;

  Map<String, Object?> toJson() => {'x': x, 'y': y};
}
