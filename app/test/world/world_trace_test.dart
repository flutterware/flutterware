import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
import 'package:flutterware_app/src/plugins/native/worlds_results.dart';
import 'package:flutterware_app/src/world/world_canvas.dart' show numberNodes;
import 'package:flutterware_app/src/world/world_trace.dart';

void main() {
  var since = DateTime(2026, 9, 26, 21);
  late WorldTrace trace;
  var nextId = 1;

  InspectorEvent at(
    int ms,
    String channel,
    Map<String, Object?> payload, [
    String? rid,
  ]) => InspectorEvent(
    channel: channel,
    id: nextId++,
    time: since.add(Duration(milliseconds: ms)),
    payload: payload,
    isReplay: false,
    rid: rid,
  );

  void app(String person, int ms, String channel, Map<String, Object?> data) =>
      trace.addGuestEvent(person, at(ms, channel, data));
  void lab(int ms, String channel, Map<String, Object?> data, [String? rid]) =>
      trace.addServerEvent('lab', at(ms, channel, data, rid));

  void step(String person, String id, int ms, String target) => app(
    person,
    ms,
    worldStepsChannel,
    {'step': id, 'verb': 'tap', 'target': target},
  );

  Map<String, List<String>> traced({String? person}) => {
    for (var step in WorldTraceResult.of(
      trace.steps(person: person, limit: 20),
    ).steps)
      '${step.step} ${step.did}': step.then,
  };

  setUp(() {
    trace = WorldTrace(since: since)
      ..addPerson('Ben', phone: '+447700900001')
      ..addPerson('Cleo', userId: 'u1');
  });

  test('joins one order from the tap to both phones', () {
    step('Ben', 'ben.1', 1000, '"Order"');
    app('Ben', 1004, worldRequestsChannel, {
      'step': 'ben.1',
      'method': 'POST',
      'url': 'localhost:5040/orders',
      'how': 'zone',
    });
    lab(1005, 'identify', {'user': 'u2', 'step': 'ben.1'});
    lab(1006, 'write', {
      'table': 'orders',
      'key': 'o5',
      'op': 'insert',
      'step': 'ben.1',
    });
    lab(1007, 'reach', {
      'user': 'u1',
      'what': 'order o5 · placed',
      'step': 'ben.1',
    });
    lab(1008, 'http', {
      'method': 'POST',
      'path': '/orders',
      'status': 201,
      'ms': 13.2,
      'step': 'ben.1',
    });
    app('Ben', 1020, 'db:main/records', {
      'key': 'o5',
      'table': 'orders',
      'change': 'local insert',
    });
    app('Cleo', 1040, 'db:main/records', {
      'key': 'o5',
      'table': 'orders',
      'change': 'synced',
      'op': 16,
    });
    app('Ben', 1270, 'db:main/records', {
      'key': 'o5',
      'table': 'orders',
      'change': 'synced',
      'op': 15,
    });

    step('Cleo', 'cleo.1', 3000, '"Advance"');
    lab(3010, 'write', {
      'table': 'orders',
      'key': 'o5',
      'op': 'update',
      'step': 'cleo.1',
    });
    app('Ben', 3040, 'db:main/records', {
      'key': 'o5',
      'table': 'orders',
      'change': 'synced',
      'op': 17,
    });

    expect(traced(), {
      'ben.1 tap "Order"': [
        '+4 ms  Ben → lab  POST /orders  201 in 13 ms',
        '+5 ms  lab  knows Ben as u2',
        '+6 ms  lab  wrote orders/o5 (insert)',
        '+7 ms  lab → Cleo  order o5 · placed',
        '+20 ms  Ben  wrote orders/o5 locally',
        '+40 ms  Cleo  orders/o5 arrived (op 16)',
        '+270 ms  Ben  orders/o5 confirmed (op 15)',
      ],
      'cleo.1 tap "Advance"': [
        '+10 ms  lab  wrote orders/o5 (update)',
        '+40 ms  Ben  orders/o5 arrived (op 17)',
      ],
    });
    expect(traced(person: 'Cleo').keys, ['cleo.1 tap "Advance"']);
    expect(trace.personOfUser('u2'), 'Ben');
  });

  test('a request no server reported is named by its host, or by the server '
      'that answers there', () {
    step('Ben', 'ben.1', 1000, '"Sign in"');
    for (var (ms, path) in [(1001, '/live'), (1002, '/me')]) {
      app('Ben', ms, worldRequestsChannel, {
        'step': 'ben.1',
        'method': 'GET',
        'url': 'localhost:5040$path',
        'how': 'zone',
      });
    }
    lab(1003, 'http', {
      'method': 'GET',
      'path': '/me',
      'status': 200,
      'ms': 0.42,
      'step': 'ben.1',
    });
    expect(traced()['ben.1 tap "Sign in"'], [
      '+1 ms  Ben → lab  GET /live',
      '+2 ms  Ben → lab  GET /me  200 in 0.4 ms',
    ]);
  });

  test('a request no server reported names its host, and how it joined', () {
    step('Ben', 'ben.1', 1000, '"Refresh"');
    app('Ben', 1300, worldRequestsChannel, {
      'step': 'ben.1',
      'method': 'GET',
      'url': 'api.example.com:443/feed',
      'how': 'window',
    });
    expect(traced()['ben.1 tap "Refresh"'], [
      '+300 ms  Ben → api.example.com:443  GET /feed, joined by time',
    ]);
  });

  test('a message reaches the person its number or user is', () {
    step('Ben', 'ben.1', 1000, '"Send code"');
    lab(1010, 'sms', {
      'to': '+447700900001',
      'body': 'Your code is 1234',
      'step': 'ben.1',
    });
    lab(1020, 'push', {'to': 'u1', 'title': 'New order', 'step': 'ben.1'});
    expect(traced()['ben.1 tap "Send code"'], [
      '+10 ms  lab → Ben by SMS  Your code is 1234',
      '+20 ms  lab → Cleo by push  New order',
    ]);
  });

  test('says who a user is once, on the step that taught it, and never of a '
      'user the script named', () {
    step('Ben', 'ben.1', 1000, '"Sign in"');
    lab(1010, 'identify', {'user': 'u2', 'step': 'ben.1'});
    lab(1020, 'identify', {'user': 'u2', 'step': 'ben.1'});
    step('Ben', 'ben.2', 2000, '"Menu"');
    lab(2010, 'identify', {'user': 'u2', 'step': 'ben.2'});
    step('Cleo', 'cleo.1', 3000, '"Orders"');
    lab(3010, 'identify', {'user': 'u1', 'step': 'cleo.1'});
    expect(traced(), {
      'ben.1 tap "Sign in"': ['+10 ms  lab  knows Ben as u2'],
      'ben.2 tap "Menu"': <String>[],
      'cleo.1 tap "Orders"': <String>[],
    });
  });

  test("leaves out a scroll that caused nothing, another world's steps, and "
      "a server's history from before this opening", () {
    app('Ben', 1000, worldStepsChannel, {
      'step': 'ben.1',
      'verb': 'drag',
      'target': 'at (10, 20)',
    });
    step('Ben', 'ben.2', 2000, '"Order"');
    lab(-500, 'write', {
      'table': 'orders',
      'key': 'o1',
      'op': 'insert',
      'step': 'ben.2',
    });
    lab(2010, 'write', {
      'table': 'orders',
      'key': 'o2',
      'op': 'insert',
      'step': 'zed.2',
    });
    expect(traced(), {'ben.2 tap "Order"': <String>[]});
  });

  test('the newest steps, as many as asked for', () {
    for (var n = 1; n <= 5; n++) {
      step('Ben', 'ben.$n', n * 1000, '"Next"');
    }
    expect(
      [for (var (:step, beats: _) in trace.steps(limit: 2)) step.id],
      ['ben.4', 'ben.5'],
    );
    expect(
      [for (var (:step, beats: _) in trace.steps(step: 'ben.2')) step.id],
      ['ben.2'],
    );
  });

  group('for the canvas', () {
    /// Ana's advance, reported the way the lab's adapter reports it: every
    /// event under the request's id, the request itself last.
    void advance() {
      step('Cleo', 'cleo.1', 1000, '"Advance"');
      app('Cleo', 1002, worldRequestsChannel, {
        'step': 'cleo.1',
        'method': 'POST',
        'url': 'localhost:5040/orders/o3/advance',
        'how': 'zone',
      });
      lab(1003, 'write', {
        'table': 'orders',
        'key': 'o3',
        'op': 'update',
        'step': 'cleo.1',
      }, 'req-7');
      lab(1004, 'reach', {
        'user': 'u1',
        'what': 'order o3 · ready',
        'step': 'cleo.1',
      }, 'req-7');
      lab(1005, 'push', {
        'to': 'u1',
        'title': 'Your flat white is ready',
        'step': 'cleo.1',
      }, 'req-7');
      lab(1006, 'http', {
        'method': 'POST',
        'path': '/orders/o3/advance',
        'part': '/orders/:id/advance',
        'status': 200,
        'step': 'cleo.1',
      }, 'req-7');
    }

    test('each beat names the part it touched, and the ones that crossed '
        'between a phone and the system say so', () {
      advance();
      var beats = trace.steps().single.beats;
      expect(
        [
          for (var beat in beats)
            (beat.person, beat.node, beat.line, beat.inbound),
        ],
        [
          (
            'Cleo',
            'lab/part/POST /orders/:id/advance',
            'POST /orders/o3/advance',
            false,
          ),
          (null, 'lab/table/orders', null, false),
          (
            'Cleo',
            'lab/part/POST /orders/:id/advance',
            'order o3 · ready',
            true,
          ),
          ('Cleo', 'lab/sent/push', 'Your flat white is ready', true),
        ],
      );
      expect(numberNodes(trace.steps().single), {
        'lab/part/POST /orders/:id/advance': 1,
        'lab/table/orders': 2,
        'lab/sent/push': 3,
      });
    });

    test('an arrival crosses from the sync engine to the phone, a local '
        'write stays on it', () {
      step('Ben', 'ben.1', 1000, '"Order"');
      app('Ben', 1003, 'db:main/records', {
        'key': 'o5',
        'table': 'orders',
        'change': 'local insert',
      });
      lab(1010, 'write', {
        'table': 'orders',
        'key': 'o5',
        'op': 'insert',
        'step': 'ben.1',
      });
      app('Cleo', 1040, 'db:main/records', {
        'key': 'o5',
        'table': 'orders',
        'change': 'synced',
        'op': 16,
      });
      var beats = trace.steps().single.beats;
      expect(
        [for (var beat in beats) (beat.person, beat.node, beat.inbound)],
        [
          ('Ben', null, false),
          (null, 'lab/table/orders', false),
          ('Cleo', syncNode, true),
        ],
      );
    });

    test("a server's summary counts everything it reported since the world "
        'opened, whoever caused it', () {
      lab(-10, 'http', {'method': 'GET', 'path': '/old'}, 'req-0');
      lab(10, 'http', {'method': 'POST', 'path': '/admin/users'}, 'req-1');
      lab(20, 'http', {'method': 'POST', 'path': '/admin/users'}, 'req-2');
      advance();
      var server = trace.servers.single;
      expect(server.name, 'lab');
      expect(server.parts, {
        'POST /admin/users': 2,
        'POST /orders/:id/advance': 1,
      });
      expect(server.tables, {
        'orders': {'o3'},
      });
      expect(server.sent, {'push': 1});
      expect(server.reached, 1);
    });

    test('says when it heard something', () async {
      var heard = 0;
      trace.changed.listen((_) => heard++);
      step('Ben', 'ben.1', 1000, '"Order"');
      lab(1010, 'http', {'method': 'GET', 'path': '/me'});
      app('Ben', 1020, 'something/else', {});
      expect(heard, 2);
    });
  });

  group('syncLine', () {
    var now = DateTime.utc(2026, 9, 26, 21, 0, 30);

    test('says when it synced and what waits', () {
      expect(
        syncLine({
          'engine': 'powersync',
          'pendingUploads': 2,
          'lastSyncedAt': '2026-09-26T21:00:28.000Z',
        }, now: now),
        'PowerSync: synced 2 s ago, 2 to upload',
      );
      expect(
        syncLine({
          'engine': 'powersync',
          'pendingUploads': 0,
          'lastSyncedAt': '2026-09-26T20:55:00.000Z',
        }, now: now),
        'PowerSync: synced 5 min ago',
      );
      expect(
        syncLine({'engine': 'powersync', 'pendingUploads': 0}, now: now),
        'PowerSync: not synced yet',
      );
    });
  });
}
