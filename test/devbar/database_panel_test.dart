import 'dart:async';

import 'package:flutterware/channels.dart';
import 'package:flutterware/src/devbar/plugins/database.dart';
import 'package:test/test.dart';

/// A scripted database: no sqlite anywhere, per the design's build step 2.
class _FakeDb {
  /// Answers every query. Tests swap it to script results or to throw.
  Future<List<Map<String, Object?>>> Function(String sql, List<Object?> args)
  onQuery = (_, _) async => const [];

  final executed = <(String, List<Object?>)>[];
  final queried = <(String, List<Object?>)>[];

  /// Sync, so a test's `updates.add` lands before the next line runs.
  final updates = StreamController<Set<String>>.broadcast(sync: true);

  Future<void> close() => updates.close();

  DatabaseAdapter adapter({
    bool withUpdates = true,
    bool writable = false,
    DatabaseWatch? watch,
    DatabaseSync? sync,
  }) => DatabaseAdapter(
    sync: sync,
    query: (sql, args) {
      queried.add((sql, args));
      return onQuery(sql, args);
    },
    updates: withUpdates ? updates.stream : null,
    watch: watch,
    execute: writable
        ? (sql, args) async {
            executed.add((sql, args));
            return const [];
          }
        : null,
  );
}

void main() {
  late InspectorCore core;
  late Panels panels;
  late _FakeDb db;

  setUp(() {
    core = InspectorCore(identity: () => const {});
    panels = Panels(core);
    db = _FakeDb();
    addTearDown(() => db.close());
  });

  /// Mounts [adapter] the way the bridge does, with a zero coalescing window
  /// so a test turn of the event loop is a full window.
  (Panel, DatabasePanelSource) mount(DatabaseAdapter adapter) {
    var source = DatabasePanelSource(adapter, coalesceWindow: Duration.zero);
    addTearDown(source.dispose);
    var panel = panels.add(source.panelId, source.panelLabel);
    source.describePanel(panel);
    return (panel, source);
  }

  /// The feed events a fresh attacher would replay, payloads only.
  List<Map<String, Object?>> ringed(String channel) {
    var peer = _Peer();
    core.attach(peer, 1);
    return [
      for (var frame in peer.frames)
        if (frame['t'] == 'event' && frame['ch'] == channel)
          (frame['p']! as Map).cast<String, Object?>(),
    ];
  }

  Map<String, Object?> details(int eventId) {
    var peer = _Peer();
    core.handleFrame(peer, {
      'ch': 'meta',
      't': 'req',
      'id': 1,
      'm': 'detail',
      'p': {'event': eventId},
    });
    var payload = (peer.frames.single['p']! as Map).cast<String, Object?>();
    return (payload['details']! as Map).cast<String, Object?>();
  }

  group('PowerSync', () {
    /// Its tables, as a checkpoint and the app leave them.
    var crud = <Map<String, Object?>>[];
    var oplog = <Map<String, Object?>>[];

    /// The buckets the phone holds, empty ones too.
    var held = <String>[];

    setUp(() {
      crud = [];
      oplog = [
        {'t': 'orders', 'k': 'o1', 'op': 3, 'bucket': 'shop_orders["main"]'},
      ];
      held = ['shop_orders["main"]', 'profile["u2"]'];
      db.onQuery = (sql, args) async => switch (sql) {
        'SELECT name FROM ps_buckets' => [
          for (var name in held) {'name': name},
        ],
        _ when sql.contains("key = 'client_id'") => [
          {'value': 'client-7'},
        ],
        _ when sql.startsWith('SELECT count(*) FROM ps_crud') => [
          {'count(*)': crud.length},
        ],
        _ when sql.contains('ps_sync_state') => [
          {'max(last_synced_at)': 1790448958000000},
        ],
        _ when sql.startsWith('SELECT name, last_applied_op') => [
          {'name': 'shop_orders["main"]', 'last_applied_op': 8, 'last_op': 8},
        ],
        _ when sql.contains('FROM ps_crud WHERE id >') => [
          for (var row in crud)
            if ((row['id']! as int) > (args.single! as int)) row,
        ],
        _ when sql.contains('FROM ps_oplog') => oplog,
        _ => const [],
      };
    });

    test('is said, not guessed: a plain database gets no sync surface', () {
      var (panel, _) = mount(db.adapter());
      expect(panel.descriptor.states.map((s) => s.id), ['schema']);
      expect(
        panel.descriptor.feeds.map((f) => f.id),
        isNot(contains('records')),
      );
    });

    test("reads the engine's own tables into a sync state", () async {
      var (panel, _) = mount(db.adapter(sync: DatabaseSync.powersync));
      expect(panel.descriptor.states.map((s) => s.id), ['schema', 'sync']);
      crud = [
        {'id': 4, 'data': '{}'},
      ];
      expect(await panel.readState('sync'), {
        'engine': 'powersync',
        'clientId': 'client-7',
        'pendingUploads': 1,
        'lastSyncedAt': '2026-09-26T18:55:58.000Z',
        'buckets': [
          {'name': 'shop_orders["main"]', 'appliedOp': 8, 'lastOp': 8},
        ],
      });
    });

    test('reports a local write, then what a checkpoint brought, record by '
        'record', () async {
      mount(db.adapter(sync: DatabaseSync.powersync));
      await pumpEventQueue();
      // What was there at the start is one line.
      expect(ringed('db:main/records'), [
        {'key': '1 records', 'change': 'present'},
      ]);

      crud = [
        {'id': 1, 'data': '{"op":"PUT","type":"orders","id":"o2","data":{}}'},
      ];
      db.updates.add({'orders'});
      await pumpEventQueue();
      held = [...held, 'profile["u1"]'];
      oplog = [
        {'t': 'orders', 'k': 'o1', 'op': 3, 'bucket': 'shop_orders["main"]'},
        {'t': 'orders', 'k': 'o2', 'op': 9, 'bucket': 'shop_orders["main"]'},
        // Written long ago, arriving now: the app has just subscribed.
        {'t': 'profiles', 'k': 'u1', 'op': 2, 'bucket': 'profile["u1"]'},
        // The first record of a bucket the phone held, empty, from the
        // start: late in coming, not new to it.
        {'t': 'profiles', 'k': 'u2', 'op': 10, 'bucket': 'profile["u2"]'},
      ];
      db.updates.add({'orders'});
      await pumpEventQueue();
      // A later record of the bucket just subscribed to is not new either.
      oplog = [
        ...oplog,
        {'t': 'profiles', 'k': 'u3', 'op': 11, 'bucket': 'profile["u1"]'},
      ];
      db.updates.add({'profiles'});
      await pumpEventQueue();

      expect(ringed('db:main/records').skip(1), [
        {'key': 'o2', 'table': 'orders', 'change': 'local put'},
        // The bucket it came in: why a record can arrive after a newer one.
        {
          'key': 'o2',
          'table': 'orders',
          'change': 'synced',
          'op': 9,
          'bucket': 'shop_orders["main"]',
        },
        {
          'key': 'u1',
          'table': 'profiles',
          'change': 'synced',
          'op': 2,
          'bucket': 'profile["u1"]',
          'newBucket': true,
        },
        {
          'key': 'u2',
          'table': 'profiles',
          'change': 'synced',
          'op': 10,
          'bucket': 'profile["u2"]',
        },
        {
          'key': 'u3',
          'table': 'profiles',
          'change': 'synced',
          'op': 11,
          'bucket': 'profile["u1"]',
        },
      ]);
    });
  });

  group('descriptor', () {
    test('declares only what the adapter can answer', () {
      var (panel, _) = mount(db.adapter(withUpdates: false));
      var descriptor = panel.descriptor;
      expect(descriptor.id, 'db:main');
      expect(descriptor.states.single.id, 'schema');
      expect(descriptor.actions.map((a) => a.id), ['query']);
      expect(descriptor.feeds, isEmpty, reason: 'no updates, no feeds');
    });

    test('updates unlock the changes feed and the watch surface', () {
      var (panel, _) = mount(db.adapter());
      var descriptor = panel.descriptor;
      expect(descriptor.feeds.map((f) => f.id), ['changes', 'watch']);
      expect(descriptor.actions.map((a) => a.id), [
        'query',
        'watch',
        'unwatch',
      ]);
      expect(descriptor.feeds.last.itemActions.single.id, 'explain');
    });

    test('execute exists only when the app provided the function', () async {
      var (bare, _) = mount(db.adapter());
      expect(
        bare.descriptor.actions.map((a) => a.id),
        isNot(contains('execute')),
      );
      await expectLater(
        () => bare.run('execute', {'sql': 'x'}),
        throwsArgumentError,
      );

      db = _FakeDb();
      var writable = DatabasePanelSource(db.adapter(writable: true));
      addTearDown(writable.dispose);
      var panel = panels.add(writable.panelId, writable.panelLabel);
      writable.describePanel(panel);
      var execute = panel.descriptor.actions.singleWhere(
        (a) => a.id == 'execute',
      );
      expect(execute.danger, isTrue);
      await panel.run('execute', {'sql': 'DELETE FROM todos'});
      expect(db.executed.single.$1, 'DELETE FROM todos');
    });

    test('a second database is a second panel', () {
      var one = DatabasePanelSource(db.adapter());
      var two = DatabasePanelSource(
        DatabaseAdapter(name: 'cache', query: (_, _) async => const []),
      );
      expect(one.panelId, 'db:main');
      expect(one.panelLabel, 'Database');
      expect(two.panelId, 'db:cache');
      expect(two.panelLabel, 'Database (cache)');
    });
  });

  group('query', () {
    test('answers rows with the fixed reply shape', () async {
      db.onQuery = (_, _) async => [
        {'id': 1, 'title': 'first'},
        {'id': 2, 'title': 'second'},
      ];
      var (panel, _) = mount(db.adapter());
      var reply =
          (await panel.run('query', {'sql': 'SELECT * FROM todos'}))! as Map;
      expect(reply['columns'], ['id', 'title']);
      expect(reply['rowCount'], 2);
      expect((reply['rows']! as List).length, 2);
      expect(reply.containsKey('truncated'), isFalse);
    });

    test('truncates loudly at the limit', () async {
      db.onQuery = (_, _) async => [
        for (var i = 0; i < 10; i++) {'id': i},
      ];
      var (panel, _) = mount(db.adapter());
      var reply =
          (await panel.run('query', {'sql': 'SELECT 1', 'limit': 3}))! as Map;
      expect((reply['rows']! as List).length, 3);
      expect(reply['rowCount'], 10);
      expect(reply['truncated'], isTrue);
    });

    test('binds args given as a list or as a JSON string', () async {
      var (panel, _) = mount(db.adapter());
      await panel.run('query', {
        'sql': 'SELECT ?',
        'args': [42],
      });
      await panel.run('query', {'sql': 'SELECT ?', 'args': '[43]'});
      expect(db.queried.map((q) => q.$2), [
        [42],
        [43],
      ]);
    });

    test('blobs and exotic values survive as markers', () async {
      db.onQuery = (_, _) async => [
        {
          'blob': [1, 2, 3],
          'when': DateTime.utc(2026),
          'n': 1.5,
          'null': null,
        },
      ];
      var (panel, _) = mount(db.adapter());
      var reply = (await panel.run('query', {'sql': 'x'}))! as Map;
      var row = (reply['rows']! as List).single as Map;
      expect(row['blob'], '<blob 3 bytes>');
      expect(row['when'], '2026-01-01 00:00:00.000Z');
      expect(row['n'], 1.5);
      expect(row['null'], isNull);
    });

    test('refuses missing sql and a bad limit with a sentence', () async {
      var (panel, _) = mount(db.adapter());
      await expectLater(() => panel.run('query'), throwsArgumentError);
      await expectLater(
        () => panel.run('query', {'sql': 'x', 'limit': 'lots'}),
        throwsArgumentError,
      );
    });
  });

  test('schema reads sqlite_master, columns and counts', () async {
    db.onQuery = (sql, _) async {
      if (sql.contains('sqlite_master')) {
        return [
          {'name': 'ps_data__todos', 'type': 'table'},
          {'name': 'todos', 'type': 'view'},
        ];
      }
      if (sql.startsWith('PRAGMA')) {
        return [
          {'name': 'id', 'type': 'INTEGER'},
          {'name': 'title', 'type': 'TEXT'},
        ];
      }
      return [
        {'c': 12},
      ];
    };
    var (panel, _) = mount(db.adapter());
    var schema = await panel.readState('schema');
    expect(schema, {
      'tables': [
        {
          'name': 'ps_data__todos',
          'type': 'table',
          'rows': 12,
          'columns': 'id INTEGER, title TEXT',
        },
        {
          'name': 'todos',
          'type': 'view',
          'rows': 12,
          'columns': 'id INTEGER, title TEXT',
        },
      ],
    });
  });

  test('schema asks sqlite_master for views as well as tables', () async {
    db.onQuery = (sql, _) async => sql.contains('sqlite_master')
        ? const []
        : const [
            {'c': 0},
          ];
    var (panel, _) = mount(db.adapter());
    await panel.readState('schema');
    var listing = db.queried
        .map((q) => q.$1)
        .firstWhere((sql) => sql.contains('sqlite_master'));
    expect(listing, contains("type IN ('table', 'view')"));
  });

  group('changes', () {
    test('first tick speaks immediately, a burst coalesces', () async {
      var (_, _) = mount(db.adapter());
      db.updates.add({'todos'});
      db.updates.add({'todos', 'tags'});
      db.updates.add({'tags'});
      await Future<void>.delayed(Duration.zero);

      var events = ringed('db:main/changes');
      expect(events.first, {'tables': 'todos', 'transactions': 1});
      expect(events.last, {'tables': 'tags todos', 'transactions': 2});
      expect(events, hasLength(2), reason: 'three transactions, two events');
    });

    test('nothing is emitted after dispose', () async {
      var (_, source) = mount(db.adapter());
      source.dispose();
      db.updates.add({'todos'});
      await Future<void>.delayed(Duration.zero);
      expect(ringed('db:main/changes'), isEmpty);
    });
  });

  group('watch', () {
    test('fallback: initial snapshot, then one per coalesced tick', () async {
      var rows = [
        {'id': 1},
      ];
      db.onQuery = (_, _) async => rows;
      var (panel, _) = mount(db.adapter());

      var reply =
          (await panel.run('watch', {'sql': 'SELECT * FROM todos'}))! as Map;
      expect(reply['watch'], 1);
      await Future<void>.delayed(Duration.zero);

      rows = [
        {'id': 1},
        {'id': 2},
      ];
      db.updates.add({'todos'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      var events = ringed('db:main/watch');
      expect(events.map((e) => e['rows']), [1, 2]);
      expect(events.first['sql'], 'SELECT * FROM todos');
      expect(events.first['watch'], 1);
    });

    test('the snapshot rows ride in the details', () async {
      db.onQuery = (_, _) async => [
        {'id': 7, 'title': 'x'},
      ];
      var (panel, _) = mount(db.adapter());
      await panel.run('watch', {'sql': 'SELECT * FROM todos'});
      await Future<void>.delayed(Duration.zero);

      var peer = _Peer();
      core.attach(peer, 1);
      var event = peer.frames.singleWhere(
        (f) => f['t'] == 'event' && f['ch'] == 'db:main/watch',
      );
      var detail = details(event['e']! as int);
      expect(detail['rowCount'], 1);
      expect(((detail['rows']! as List).single as Map)['id'], 7);
    });

    test('a native watch is delegated to, not re-implemented', () async {
      var controller = StreamController<List<Map<String, Object?>>>();
      String? watched;
      var (panel, _) = mount(
        db.adapter(
          watch: (sql) {
            watched = sql;
            return controller.stream;
          },
        ),
      );
      await panel.run('watch', {'sql': 'SELECT count(*) FROM t'});
      expect(watched, 'SELECT count(*) FROM t');
      controller.add([
        {'c': 5},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(ringed('db:main/watch').single['rows'], 1);
      expect(db.queried, isEmpty, reason: 'the adapter watch served it');
      await controller.close();
    });

    test('unwatch stops the snapshots and refuses an unknown id', () async {
      db.onQuery = (_, _) async => const [];
      var (panel, _) = mount(db.adapter());
      var id =
          ((await panel.run('watch', {'sql': 'SELECT 1'}))! as Map)['watch'];
      await Future<void>.delayed(Duration.zero);

      expect(await panel.run('unwatch', {'id': id}), {'stopped': id});
      db.updates.add({'todos'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ringed('db:main/watch'), hasLength(1), reason: 'only the initial');

      await expectLater(
        () => panel.run('unwatch', {'id': 99}),
        throwsA(
          isA<ArgumentError>().having((e) => '$e', 'message', contains('99')),
        ),
      );
    });

    test('a failing watch reports the error on the feed and stops', () async {
      db.onQuery = (_, _) async => throw StateError('no such table: nope');
      var (panel, _) = mount(db.adapter());
      await panel.run('watch', {'sql': 'SELECT * FROM nope'});
      await Future<void>.delayed(Duration.zero);

      var event = ringed('db:main/watch').single;
      expect(event['error'], contains('no such table'));
      expect(event['watch'], 1);
    });

    test('explain runs the plan for the snapshot the row belongs to', () async {
      db.onQuery = (sql, _) async => sql.startsWith('EXPLAIN')
          ? [
              {'detail': 'SCAN todos'},
            ]
          : const [];
      var (panel, _) = mount(db.adapter());
      await panel.run('watch', {'sql': 'SELECT * FROM todos'});
      await Future<void>.delayed(Duration.zero);

      var peer = _Peer();
      core.attach(peer, 1);
      var event = peer.frames.singleWhere(
        (f) => f['t'] == 'event' && f['ch'] == 'db:main/watch',
      );
      var reply = (await panel.run('explain', {'event': event['e']}))! as Map;
      expect(reply['sql'], 'SELECT * FROM todos');
      expect(((reply['rows']! as List).single as Map)['detail'], 'SCAN todos');
      expect(db.queried.last.$1, 'EXPLAIN QUERY PLAN SELECT * FROM todos');

      await expectLater(
        () => panel.run('explain', {'event': 12345}),
        throwsArgumentError,
      );
    });
  });

  group('a database that is not open yet', () {
    /// The sentence an app hands [DatabaseUnavailable]. Written once here so
    /// the test reads as "exactly this, nowhere altered".
    const reason = 'No session is open — sign in to reach the database.';

    /// Sends one request the way an attached host does, and answers with the
    /// error frame it got — the only path the panel's own `run` cannot show,
    /// because the point is what the message looks like after it crosses.
    Future<Map<String, Object?>> requestError(
      Panel panel,
      String method, [
      Map<String, Object?> params = const {},
    ]) async {
      var peer = _Peer();
      core.handleFrame(peer, {
        'ch': panel.id,
        't': 'req',
        'id': 7,
        'm': method,
        'p': params,
      });
      await pumpEventQueue();
      return (peer.frames.singleWhere((f) => f['t'] == 'err')['p']! as Map)
          .cast<String, Object?>();
    }

    test('the sentence crosses the wire with nothing in front of it', () async {
      db.onQuery = (_, _) async => throw DatabaseUnavailable(reason);
      var (panel, _) = mount(db.adapter());

      expect(await requestError(panel, 'query', {'sql': 'SELECT 1'}), {
        'message': reason,
      });
    });

    test('a StateError would not — which is why the type exists', () async {
      db.onQuery = (_, _) async => throw StateError(reason);
      var (panel, _) = mount(db.adapter());

      expect(
        (await requestError(panel, 'query', {'sql': 'SELECT 1'}))['message'],
        'Bad state: $reason',
      );
    });

    test('the panel stays listed, with everything it declared', () async {
      db.onQuery = (_, _) async => throw DatabaseUnavailable(reason);
      var (panel, _) = mount(db.adapter(writable: true));
      // Reading the schema is the first thing the cockpit does, and it fails
      // like everything else — without taking the declaration with it.
      expect(await requestError(panel, 'fw:state', {'id': 'schema'}), {
        'message': reason,
      });

      var descriptor = panels.descriptors.single;
      expect(descriptor.id, 'db:main');
      expect(
        descriptor.actions.map((a) => a.id),
        containsAll(['query', 'execute']),
      );
    });
  });
}

class _Peer implements InspectorPeer {
  final frames = <Map<String, Object?>>[];

  @override
  void send(Map<String, Object?> frame) => frames.add(frame);

  @override
  void close() {}
}
