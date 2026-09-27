import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
import 'package:flutterware_app/src/plugins/native/worlds_results.dart';
import 'package:flutterware_app/src/world/world_canvas.dart'
    show numberNodes, stepTitle;
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

  test("a world's own action is a step, and what it caused is traced like "
      "a tap's", () {
    trace.addActionStep(
      'world.1',
      'Mia orders a flat white',
      since.add(const Duration(seconds: 1)),
    );
    lab(1005, 'identify', {'user': 'u9', 'step': 'world.1'}, 'req-1');
    lab(1006, 'write', {
      'table': 'orders',
      'key': 'o7',
      'op': 'insert',
      'step': 'world.1',
    }, 'req-1');
    lab(1008, 'http', {
      'method': 'POST',
      'path': '/orders',
      'status': 201,
      'step': 'world.1',
    }, 'req-1');
    app('Cleo', 1030, 'db:main/records', {
      'key': 'o7',
      'table': 'orders',
      'change': 'synced',
      'op': 5,
    });
    expect(traced(), {
      'world.1 action "Mia orders a flat white"': [
        '+5 ms  lab  knows someone as u9',
        '+6 ms  lab  wrote orders/o7 (insert)',
        '+8 ms  lab  POST /orders  201',
        '+30 ms  Cleo  orders/o7 arrived (op 5)',
      ],
    });
    var step = trace.steps().single.step;
    expect(step.person, worldActionsOwner);
    expect(stepTitle(step), 'Ran "Mia orders a flat white"');
    // Whom it signed in as is not the world.
    expect(trace.personOfUser('u9'), isNull);
  });

  group('for the canvas', () {
    /// Cleo's advance, reported the way the lab's adapter reports it: every
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

  group('contents', () {
    (String, String?, String?, String?) row(TraceItem item) =>
        (item.title, item.detail, item.person, item.step);

    test("a route holds every call it answered, the script's own among "
        'them, each by who asked', () {
      lab(10, 'identify', {'user': 'u1'}, 'req-1');
      lab(11, 'http', {'method': 'GET', 'path': '/me', 'status': 200}, 'req-1');
      lab(20, 'http', {'method': 'GET', 'path': '/me', 'status': 401}, 'req-2');
      step('Ben', 'ben.1', 1000, '"Profile"');
      lab(1010, 'http', {
        'method': 'GET',
        'path': '/me',
        'status': 200,
        'ms': 2.5,
        'step': 'ben.1',
      }, 'req-3');
      var contents = trace.contentsOf('lab/part/GET /me')!;
      expect(
        (contents.kind, contents.title, contents.server, contents.earlier),
        (NodeKind.route, 'GET /me', 'lab', 0),
      );
      expect(contents.items.map(row), [
        ('/me', '200 in 2.5 ms', 'Ben', 'ben.1'),
        ('/me', '401', null, null),
        ('/me', '200', 'Cleo', null),
      ]);
    });

    test('a table holds each record once, with its life: every write the '
        'server reported and every phone it reached', () {
      const key = '5cc8e32f-a2bb-4ea1-8363-742901521840';
      void record(String person, int ms, String change, [int? op]) => app(
        person,
        ms,
        'db:main/records',
        {'key': key, 'table': 'orders', 'change': change, 'op': ?op},
      );
      step('Cleo', 'cleo.1', 1000, '"Order"');
      record('Cleo', 1003, 'local insert');
      lab(1010, 'write', {
        'table': 'orders',
        'key': key,
        'op': 'insert',
        'status': 'placed',
        'customer': 'u1',
        'step': 'cleo.1',
      });
      record('Ben', 1040, 'synced', 16);
      record('Cleo', 1250, 'synced', 16);
      step('Ben', 'ben.1', 2000, '"Advance"');
      lab(2010, 'write', {
        'table': 'orders',
        'key': key,
        'op': 'update',
        'status': 'ready',
        'step': 'ben.1',
      });
      record('Cleo', 2040, 'synced', 17);
      // Written before the world opened: Cleo's first sync brings it.
      app('Cleo', 50, 'db:main/records', {
        'key': 'o1',
        'table': 'orders',
        'change': 'synced',
        'op': 3,
      });

      var table = trace.contentsOf('lab/table/orders')!;
      expect((table.kind, table.title), (NodeKind.table, 'orders'));
      var order = table.items.single;
      expect(row(order), ('5cc8e32f', 'update · status ready', 'Ben', 'ben.1'));
      expect(order.life.map(row), [
        ("written on Cleo's phone", 'insert', 'Cleo', 'cleo.1'),
        (
          'lab wrote it',
          'insert · status placed · customer Cleo',
          null,
          'cleo.1',
        ),
        ("arrived on Ben's phone", 'op 16', 'Ben', 'cleo.1'),
        ("back on Cleo's phone", 'op 16', 'Cleo', 'cleo.1'),
        ('lab wrote it', 'update · status ready', null, 'ben.1'),
        ("arrived on Cleo's phone", 'op 17', 'Cleo', 'ben.1'),
      ]);

      var synced = trace.contentsOf(syncNode)!;
      expect(synced.kind, NodeKind.sync);
      expect(synced.items.map(row), [
        ('orders/5cc8e32f', "on Ben's and Cleo's phones", null, 'ben.1'),
      ]);
      expect(synced.items.single.life, hasLength(6));
      expect(synced.unwritten, 1);

      // As an agent reads it, through `worlds contents`.
      var read = WorldContentsResult.fromJson(
        WorldContentsResult.of(table, part: 'orders').toJson(),
      );
      expect(read.items.single.life.take(2), [
        "+0 ms  written on Cleo's phone  insert  (cleo.1)",
        '+7 ms  lab wrote it  insert · status placed · customer Cleo  (cleo.1)',
      ]);
    });

    test('a message sent outside says whom it reached', () {
      lab(10, 'sms', {'to': '+447700900001', 'body': 'Your code is 482913'});
      step('Ben', 'ben.1', 1000, '"Advance"');
      lab(1010, 'push', {
        'to': 'u1',
        'title': 'Your flat white is ready',
        'body': 'Collect it at the counter.',
        'step': 'ben.1',
      });
      lab(1020, 'sms', {'to': '+15550100', 'body': 'Hello'});
      expect(trace.contentsOf('lab/sent/sms')!.items.map(row), [
        ('to +15550100', 'Hello', null, null),
        ('to Ben', 'Your code is 482913', 'Ben', null),
      ]);
      expect(trace.contentsOf('lab/sent/push')!.items.map(row), [
        ('to Cleo', 'Your flat white is ready', 'Cleo', 'ben.1'),
      ]);
    });

    test('keeps the newest, says how many more there were, and knows no '
        'node nothing reported', () {
      for (var n = 0; n < 3; n++) {
        lab(10 + n, 'http', {'method': 'GET', 'path': '/health'}, 'req-$n');
      }
      var contents = trace.contentsOf('lab/part/GET /health', limit: 2)!;
      expect(contents.items, hasLength(2));
      expect(contents.earlier, 1);
      expect(trace.contentsOf('lab/part/GET /nothing')!.items, isEmpty);
      expect(trace.contentsOf('elsewhere/part/GET /health'), isNull);
    });
  });

  group('outbox', () {
    test('each message says whom it reached, and the code and link a '
        'delivery hands their app', () {
      trace.addPerson('Leo', email: 'Leo@example.com');
      lab(10, 'sms', {
        'to': '+447700900001',
        'body': 'Your pickup code is 955046. Valid 10 minutes.',
      });
      step('Cleo', 'cleo.1', 1000, '"Advance"');
      lab(1010, 'push', {
        'to': 'u1',
        'title': 'Your flat white is ready',
        'body': 'Collect it at the counter.',
        'link': 'worldlab://orders/o3',
        'step': 'cleo.1',
      });
      lab(1020, 'mail', {
        'to': 'leo@example.com',
        'subject': 'Your receipt',
        'text': 'See it at https://shop.test/receipts/r9 — order 20260927.',
      });
      var messages = trace.outbox();
      expect(
        [
          for (var m in messages)
            (m.kind, m.person, m.text, m.code, m.link, m.step),
        ],
        [
          // An order number is not a code to type.
          (
            'mail',
            'Leo',
            'Your receipt',
            null,
            'https://shop.test/receipts/r9',
            null,
          ),
          (
            'push',
            'Cleo',
            'Your flat white is ready',
            null,
            'worldlab://orders/o3',
            'cleo.1',
          ),
          (
            'sms',
            'Ben',
            'Your pickup code is 955046. Valid 10 minutes.',
            '955046',
            null,
            null,
          ),
        ],
      );
      expect(trace.outbox(person: 'Cleo').single.kind, 'push');
      expect(trace.messageById(messages.last.id)?.code, '955046');
      expect(trace.messageById('lab/999'), isNull);
      // The SMS card's contents carry the same message.
      expect(
        trace.contentsOf('lab/sent/sms')!.items.single.message?.code,
        '955046',
      );
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
