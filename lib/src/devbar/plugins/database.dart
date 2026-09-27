/// The app's database, on every surface — the panel half of
/// `docs/superpowers/specs/2026-08-12-sqlite-watch-design.md`.
///
/// flutterware never imports sqlite_async, powersync or sqlite3: the seam is
/// [DatabaseAdapter], four function types and a name, and the recipe the app
/// pastes is five lines (§ Decision 1 of the design). Everything here is pure
/// Dart; the devbar wrapper lives in `database_plugin.dart`.
library;

import 'dart:async';
import 'dart:convert';

import '../../app_events/events.dart' show foldSql;
import '../../channels/descriptor.dart';
import '../../channels/panels.dart';
import '../../plugins/action.dart';
import '../panel_source.dart';

/// Runs one statement and answers with its rows. The adapter's `query` should
/// be wired to a read path (sqlite_async's `getAll` runs on the read pool, so
/// a write smuggled into it dies at the sqlite layer); `execute` is the write
/// door and exists only when the app provides it.
typedef DatabaseQuery = Future<List<Map<String, Object?>>> Function(
  String sql,
  List<Object?> args,
);

/// A live query: emits the result rows now and again on every relevant
/// change — sqlite_async's `watch` is the reference implementation.
typedef DatabaseWatch = Stream<List<Map<String, Object?>>> Function(String sql);

/// One database, described by what flutterware may do with it.
///
/// ```dart
/// DatabaseAdapter(
///   query: (sql, args) => db.getAll(sql, args),
///   updates: db.updates.map((u) => u.tables),
///   watch: (sql) => db.watch(sql),
/// )
/// ```
///
/// ## A database that is not open yet
///
/// Plenty of apps have no database at `runApp`: it is opened at login, closed
/// at logout, and replaced when the user switches environment. There is
/// nothing to hand this constructor at the moment the devbar is built.
///
/// The adapter is the shape; the session is the data. Close over the
/// lookup rather than over the database, and resolve it inside each function:
///
/// ```dart
/// DatabaseAdapter(
///   query: (sql, args) => _db().getAll(sql, args),
///   watch: (sql) => _db().watch(sql),
///   updates: _updates.stream,
/// )
///
/// Database _db() {
///   var db = session?.database;
///   if (db == null) {
///     throw DatabaseUnavailable('No session is open — sign in to reach the '
///         'database.');
///   }
///   return db;
/// }
/// ```
///
/// Two things about that are not optional. **Presence is read once**, when the
/// panel is described: an adapter that leaves [execute] null while logged out
/// declares an app with no write door, permanently, and the same goes for
/// [watch] and [updates]. Pass every function the app will ever offer, and let
/// the ones with nothing to work on throw. And [updates] is the one field that
/// cannot be resolved late — it is a stream, handed over once, not a
/// function called per query. Own a broadcast controller that outlives every
/// session and forward the current database into it:
///
/// ```dart
/// final _updates = StreamController<Set<String>>.broadcast();
/// StreamSubscription<void>? _forwarding;
///
/// void _sessionChanged(Session? session) {
///   unawaited(_forwarding?.cancel());
///   _forwarding = session?.database.updates
///       .listen((update) => _updates.add(update.tables));
/// }
/// ```
///
/// Why a panel that answers rather than one that disappears. The other
/// shape — declaring the panel only while a session is open, which
/// `AddDevbarPanel` and `DevbarPanels` make possible — leaves the absence
/// unexplained. Ask for
/// `db:main` when it is gone and every surface says the same thing, *"this app
/// declares no panel db:main"*, whether the app has no database at all or the
/// user is one tap from opening one. A panel that is always listed and answers
/// [DatabaseUnavailable] tells those apart, and it is the same call flutterware
/// makes for an app that never reached `runApp`: say what is wrong, do not go
/// missing.
class DatabaseAdapter {
  DatabaseAdapter({
    this.name = 'main',
    required this.query,
    this.updates,
    this.watch,
    this.execute,
    this.sync,
  });

  /// Names the panel — `db:main` — and nothing else. Two databases are two
  /// adapters with two names.
  final String name;

  final DatabaseQuery query;

  /// Table names touched, per write transaction. Feeds the `changes` feed and
  /// the watch fallback; without it neither exists.
  final Stream<Set<String>>? updates;

  /// Optional native live query. When absent, a watch falls back to re-running
  /// its SQL on every coalesced [updates] tick — correct, just wasteful.
  final DatabaseWatch? watch;

  /// Presence is the write opt-in. No function, no `execute` action, on
  /// any surface — an agent cannot even see it (§ Decision 3 of the design).
  final DatabaseQuery? execute;

  /// The sync engine that keeps this database, when one does. Said, not
  /// guessed: an app on plain sqlite gets nothing it has no use for.
  final DatabaseSync? sync;
}

/// A sync engine the panel reads beyond the tables — what the app wrote that
/// has not left yet, what arrived, and when — from the engine's own tables,
/// through the same read-only [DatabaseAdapter.query] as everything else.
enum DatabaseSync {
  /// `PowerSyncDatabase`: its `ps_crud` upload queue, its `ps_oplog`
  /// operations and its `ps_buckets` checkpoints.
  powersync,
}

/// What a database function throws when there is no database to reach — no one
/// is signed in, the session is closing, the environment is switching.
///
/// It exists for its [toString]. An error crossing the channel travels as its
/// message and nothing else, and lands verbatim in the cockpit's error pane
/// and in an MCP reply, so `StateError` puts *"Bad state:"* in front of a
/// sentence somebody has to read and `ArgumentError` does worse. This puts
/// nothing in front of it.
///
/// The message is for whoever hits it, which is often an agent that cannot see
/// the screen: say what is missing **and what would fix it** — *"No session is
/// open — sign in to reach the database"* rather than *"no database"*.
class DatabaseUnavailable implements Exception {
  DatabaseUnavailable(this.reason);

  /// A sentence, shown exactly as written.
  final String reason;

  @override
  String toString() => reason;
}

/// How many rows an inline `query`/`execute` reply carries by default. The
/// reply travels whole in the frame — there is no lazy fetch for action
/// results — so truncation is visible, never silent.
const databaseQueryDefaultLimit = 100;

/// How many rows one watch snapshot keeps in its details. Details are fetched
/// lazily and byte-capped by the core's ring, so this can be generous.
const databaseWatchDetailRows = 500;

/// How long `changes` accumulates before it speaks. The first tick after a
/// quiet spell is emitted immediately; a burst then costs one merged event per
/// window rather than one per transaction.
const databaseCoalesceWindow = Duration(milliseconds: 250);

/// Serves one [DatabaseAdapter] as a panel. Pure Dart — the tests drive this
/// against a fake adapter with no sqlite anywhere; `DatabasePlugin` is the
/// thin devbar wrapper that mounts it.
class DatabasePanelSource implements DevbarPanelSource {
  DatabasePanelSource(this.adapter, {this.coalesceWindow});

  final DatabaseAdapter adapter;

  /// Overrides [databaseCoalesceWindow], for tests.
  final Duration? coalesceWindow;

  @override
  String get panelId => 'db:${adapter.name}';

  @override
  String get panelLabel =>
      adapter.name == 'main' ? 'Database' : 'Database (${adapter.name})';

  Panel? _panel;
  StreamSubscription<Set<String>>? _updatesSubscription;

  /// Ticks after coalescing — what fallback watches re-query on, so a burst
  /// costs them one query per window too.
  final _coalescedTicks = StreamController<void>.broadcast();

  final _pendingTables = <String>{};
  var _pendingTransactions = 0;
  Timer? _changesTimer;

  final _watches = <int, StreamSubscription<List<Map<String, Object?>>>>{};
  var _nextWatch = 1;

  /// Ring event id → the SQL its snapshot ran. `explain` is invoked with the
  /// event id and nothing else, so this is what ties the row back to a query.
  final _sqlByEvent = <int, String>{};

  StreamSubscription<void>? _recordsSubscription;

  /// The last upload-queue entry reported, and the last operation reported
  /// per record: what `records` has already said.
  var _lastCrud = 0;
  final _seenOps = <String, int>{};
  var _recordsRead = false;

  /// Every bucket a record has arrived in: one that is not is new to this
  /// phone — a stream it has just subscribed to — which is why a record
  /// written long ago can arrive now.
  final _buckets = <String>{};
  Future<void>? _reading;
  var _readAgain = false;

  @override
  void describePanel(Panel panel) {
    _panel = panel;
    var watchable = adapter.watch != null || adapter.updates != null;

    panel.state(
      'schema',
      'Schema',
      description:
          'Every table and view, its columns and its row count, read live '
          'from sqlite_master.',
      read: _schema,
    );

    panel.action(
      PluginAction(
        'query',
        'Run a query',
        description:
            'Runs one statement and answers with its rows, inline. The reply '
            'is capped at `limit` rows and says so when it truncates — put a '
            'LIMIT in the SQL to page through a big table.',
        parameters: [
          const ActionParameter('sql', 'SQL'),
          const ActionParameter(
            'args',
            'Bind values',
            required: false,
            description: 'A JSON array, bound to the ? placeholders in order.',
          ),
          ActionParameter(
            'limit',
            'Row cap',
            kind: ActionParameterKind.integer,
            required: false,
            defaultValue: '$databaseQueryDefaultLimit',
            description: 'How many rows the reply carries at most.',
          ),
        ],
      ),
      _query,
    );

    if (adapter.updates != null) {
      panel.feed(
        'changes',
        'Changes',
        description:
            'Which tables changed, per write transaction, coalesced over '
            '${(coalesceWindow ?? databaseCoalesceWindow).inMilliseconds}ms '
            'so a burst reads as one event.',
        fields: const [
          FieldDescriptor('tables', 'Tables', primary: true),
          FieldDescriptor(
            'transactions',
            'Transactions',
            kind: FieldKind.number,
          ),
        ],
      );
      _updatesSubscription = adapter.updates!.listen(_onTick);
    }

    if (watchable) {
      panel.feed(
        'watch',
        'Watched queries',
        description:
            'Every result snapshot of every watched query — the history of '
            'what the query answered, not a mutating table. Rows ride in the '
            'details.',
        fields: const [
          FieldDescriptor('sql', 'SQL', primary: true),
          FieldDescriptor('watch', 'Watch', kind: FieldKind.number),
          FieldDescriptor('rows', 'Rows', kind: FieldKind.number),
          FieldDescriptor('error', 'Error'),
        ],
      );
      panel.itemAction(
        'watch',
        const PluginAction(
          'explain',
          'Explain',
          description: "EXPLAIN QUERY PLAN for this snapshot's query.",
        ),
        _explain,
      );
      panel.action(
        const PluginAction(
          'watch',
          'Watch a query',
          description:
              'Re-runs the query on every relevant change and reports each '
              'result on the `watch` feed. Answers with the watch id '
              '`unwatch` takes.',
          parameters: [ActionParameter('sql', 'SQL')],
        ),
        _watch,
      );
      panel.action(
        const PluginAction(
          'unwatch',
          'Stop watching',
          parameters: [
            ActionParameter(
              'id',
              'Watch id',
              kind: ActionParameterKind.integer,
            ),
          ],
        ),
        _unwatch,
      );
    }

    if (adapter.sync == DatabaseSync.powersync) {
      panel.state(
        'sync',
        'Sync',
        description:
            'PowerSync, from its own tables: this client, what waits to '
            'upload, when it last synced, and how far each bucket is.',
        read: _powerSyncState,
      );
      if (adapter.updates != null) {
        panel.feed(
          'records',
          'Records',
          description:
              'Every record this app wrote locally, as it joins the upload '
              'queue, and every record a checkpoint brought in, with its '
              'operation — what joins a change on one device to its arrival '
              'on another.',
          fields: const [
            FieldDescriptor('key', 'Record', primary: true),
            FieldDescriptor('table', 'Table'),
            FieldDescriptor('change', 'Change'),
            FieldDescriptor('op', 'Operation', kind: FieldKind.number),
            FieldDescriptor('bucket', 'Bucket'),
          ],
        );
        _recordsSubscription = _coalescedTicks.stream.listen(
          (_) => _readRecords(),
        );
        unawaited(_readRecords());
      }
    }

    if (adapter.execute != null) {
      panel.action(
        const PluginAction(
          'execute',
          'Execute SQL',
          danger: true,
          description:
              'Runs a write statement against the live database. Exists only '
              'because this app opted in by providing an execute function.',
          parameters: [
            ActionParameter('sql', 'SQL'),
            ActionParameter(
              'args',
              'Bind values',
              required: false,
              description:
                  'A JSON array, bound to the ? placeholders in order.',
            ),
          ],
        ),
        _execute,
      );
    }
  }

  /// Views are listed alongside tables, and both carry their `type`. A schema
  /// that lists only tables is wrong for anything that presents itself through
  /// views — PowerSync is the case that found this: every table in its schema
  /// is a view over a `ps_data__*` table of opaque JSON, so a table-only list
  /// shows the storage and hides the data. `PRAGMA table_info` and `count(*)`
  /// answer for a view exactly as they do for a table.
  Future<Map<String, Object?>> _schema() async {
    var tables = await adapter.query(
      "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      const [],
    );
    var result = <Map<String, Object?>>[];
    for (var table in tables) {
      var name = '${table['name']}';
      var quoted = '"${name.replaceAll('"', '""')}"';
      var columns = await adapter.query('PRAGMA table_info($quoted)', const []);
      var count = await adapter.query(
        'SELECT count(*) AS c FROM $quoted',
        const [],
      );
      result.add({
        'name': name,
        'type': '${table['type']}',
        'rows': count.isEmpty ? null : count.first['c'],
        'columns': [
          for (var column in columns)
            '${column['name']} ${column['type']}'.trim(),
        ].join(', '),
      });
    }
    return {'tables': result};
  }

  Future<Map<String, Object?>> _powerSyncState() async {
    Future<Object?> one(String sql) async {
      var rows = await adapter.query(sql, const []);
      return rows.isEmpty ? null : rows.first.values.first;
    }

    var client = await one("SELECT value FROM ps_kv WHERE key = 'client_id'");
    var pending = await one('SELECT count(*) FROM ps_crud');
    var synced = await one('SELECT max(last_synced_at) FROM ps_sync_state');
    var buckets = await adapter.query(
      'SELECT name, last_applied_op, last_op FROM ps_buckets ORDER BY name',
      const [],
    );
    return {
      'engine': 'powersync',
      'clientId': ?client,
      'pendingUploads': pending ?? 0,
      // Microseconds in the core that ships with powersync 2.4 — measured;
      // seconds are read too, should an older core be what wrote it.
      'lastSyncedAt': ?switch (synced) {
        num time => DateTime.fromMicrosecondsSinceEpoch(
          time > 1e14 ? time.toInt() : time.toInt() * 1000000,
          isUtc: true,
        ).toIso8601String(),
        String text => text,
        _ => null,
      },
      'buckets': [
        for (var bucket in buckets)
          {
            'name': bucket['name'],
            'appliedOp': bucket['last_applied_op'],
            'lastOp': bucket['last_op'],
          },
      ],
    };
  }

  /// Reads what changed since the last read, one at a time — ticks arriving
  /// mid-read ask for one more, not for one each.
  Future<void> _readRecords() async {
    if (_reading != null) {
      _readAgain = true;
      return;
    }
    do {
      _readAgain = false;
      _reading = _readRecordsOnce();
      try {
        await _reading;
      } on Object {
        // Not open yet, or closing: the next tick tries again, and the `sync`
        // state says what is wrong to whoever asks.
      } finally {
        _reading = null;
      }
    } while (_readAgain && _panel != null);
  }

  Future<void> _readRecordsOnce() async {
    var panel = _panel;
    if (panel == null) return;
    for (var row in await adapter.query(
      'SELECT id, data FROM ps_crud WHERE id > ? ORDER BY id',
      [_lastCrud],
    )) {
      _lastCrud = row['id']! as int;
      var entry = (jsonDecode('${row['data']}') as Map).cast<String, Object?>();
      panel.emit('records', {
        'key': entry['id'],
        'table': entry['type'],
        'change': 'local ${'${entry['op']}'.toLowerCase()}',
      });
    }
    // An operation counts once its checkpoint is applied: before that it is
    // downloaded, not visible to the app. The bucket is the one the newest
    // operation came in — SQLite takes a bare column from the row `max`
    // chose — and says why a record can arrive after a newer one: its
    // bucket reached this phone later.
    var applied = await adapter.query(
      'SELECT o.row_type AS t, o.row_id AS k, max(o.op_id) AS op, '
      'b.name AS bucket '
      'FROM ps_oplog o JOIN ps_buckets b ON b.id = o.bucket '
      'WHERE o.op_id <= b.last_applied_op GROUP BY o.row_type, o.row_id',
      const [],
    );
    var first = !_recordsRead;
    _recordsRead = true;
    var arrived = 0;
    var known = {..._buckets};
    for (var row in applied) {
      var key = '${row['t']}/${row['k']}';
      var op = row['op']! as int;
      var bucket = row['bucket'] as String?;
      if (bucket != null) _buckets.add(bucket);
      if ((_seenOps[key] ?? -1) >= op) continue;
      _seenOps[key] = op;
      arrived++;
      // What was there when the panel started is one line, not one per row.
      if (first) continue;
      panel.emit('records', {
        'key': row['k'],
        'table': row['t'],
        'change': 'synced',
        'op': op,
        'bucket': ?bucket,
        if (bucket != null && !known.contains(bucket)) 'newBucket': true,
      });
    }
    if (first && arrived > 0) {
      panel.emit('records', {'key': '$arrived records', 'change': 'present'});
    }
  }

  Future<Map<String, Object?>> _query(Map<String, Object?> args) async =>
      _rowsReply(
        await adapter.query(_sqlArg(args, 'query'), _bindArgs(args['args'])),
        _limitArg(args),
      );

  Future<Map<String, Object?>> _execute(Map<String, Object?> args) async =>
      _rowsReply(
        await adapter.execute!(
          _sqlArg(args, 'execute'),
          _bindArgs(args['args']),
        ),
        _limitArg(args),
      );

  Map<String, Object?> _watch(Map<String, Object?> args) {
    var sql = _sqlArg(args, 'watch');
    var id = _nextWatch++;
    var watch = adapter.watch;
    var stream = watch != null ? watch(sql) : _pollOnTick(sql);
    _watches[id] = stream.listen(
      (rows) => _emitSnapshot(id, sql, rows),
      onError: (Object error) {
        _panel?.emit('watch', {
          'watch': id,
          'sql': foldSql(sql),
          'error': '$error',
        });
        unawaited(_watches.remove(id)?.cancel());
      },
    );
    return {'watch': id, 'sql': sql};
  }

  Map<String, Object?> _unwatch(Map<String, Object?> args) {
    var raw = args['id'];
    var id = raw is int ? raw : int.tryParse('$raw');
    var subscription = id == null ? null : _watches.remove(id);
    if (subscription == null) {
      throw ArgumentError('no watch $raw — active: ${_watches.keys.toList()}');
    }
    unawaited(subscription.cancel());
    return {'stopped': id};
  }

  Future<Map<String, Object?>> _explain(Map<String, Object?> args) async {
    var event = args['event'];
    var sql = event is int ? _sqlByEvent[event] : null;
    if (sql == null) {
      throw ArgumentError(
        'explain is an item action — it needs the `event` id of a watch '
        'snapshot still in the ring',
      );
    }
    var plan = await adapter.query('EXPLAIN QUERY PLAN $sql', const []);
    return {'sql': sql, ..._rowsReply(plan, databaseQueryDefaultLimit)};
  }

  void _emitSnapshot(int id, String sql, List<Map<String, Object?>> rows) {
    var panel = _panel;
    if (panel == null) return;
    var eventId = panel.emit('watch', {
      'watch': id,
      'sql': foldSql(sql),
      'rows': rows.length,
    }, details: _rowsReply(rows, databaseWatchDetailRows));
    _sqlByEvent[eventId] = sql;
  }

  /// The fallback live query: the result now, then again after every
  /// coalesced tick. Wasteful next to a native `watch` — it cannot know which
  /// tables the SQL reads — but correct.
  Stream<List<Map<String, Object?>>> _pollOnTick(String sql) async* {
    yield await adapter.query(sql, const []);
    await for (var _ in _coalescedTicks.stream) {
      yield await adapter.query(sql, const []);
    }
  }

  void _onTick(Set<String> tables) {
    _pendingTables.addAll(tables);
    _pendingTransactions++;
    if (_changesTimer == null) {
      _flushChanges();
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    _changesTimer = Timer(coalesceWindow ?? databaseCoalesceWindow, () {
      _changesTimer = null;
      if (_pendingTransactions > 0) {
        _flushChanges();
        _scheduleFlush();
      }
    });
  }

  void _flushChanges() {
    var tables = _pendingTables.toList()..sort();
    var transactions = _pendingTransactions;
    _pendingTables.clear();
    _pendingTransactions = 0;
    _panel?.emit('changes', {
      'tables': tables.join(' '),
      'transactions': transactions,
    });
    _coalescedTicks.add(null);
  }

  /// `{columns, rows, rowCount, truncated}` — the shape the design fixes for
  /// every inline result, so truncation is a fact in the reply rather than a
  /// silent edit.
  Map<String, Object?> _rowsReply(List<Map<String, Object?>> rows, int limit) {
    var kept = rows.length <= limit ? rows : rows.sublist(0, limit);
    return {
      'columns': rows.isEmpty ? const <String>[] : rows.first.keys.toList(),
      'rows': [
        for (var row in kept)
          {for (var entry in row.entries) entry.key: _jsonSafe(entry.value)},
      ],
      'rowCount': rows.length,
      if (kept.length < rows.length) 'truncated': true,
    };
  }

  /// A cell must survive jsonEncode: blobs become a marker rather than a
  /// wall of bytes, and anything exotic becomes its toString.
  Object? _jsonSafe(Object? value) => switch (value) {
    null || num() || String() || bool() => value,
    List<int>() => '<blob ${value.length} bytes>',
    _ => '$value',
  };

  String _sqlArg(Map<String, Object?> args, String action) {
    var sql = args['sql'];
    if (sql is! String || sql.trim().isEmpty) {
      throw ArgumentError('$action needs `sql`');
    }
    return sql;
  }

  List<Object?> _bindArgs(Object? raw) {
    if (raw == null) return const [];
    if (raw is List) return raw;
    if (raw is String) {
      if (raw.trim().isEmpty) return const [];
      var decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    }
    throw ArgumentError(
      '`args` must be a JSON array of bind values, got: $raw',
    );
  }

  int _limitArg(Map<String, Object?> args) {
    var raw = args['limit'];
    if (raw == null) return databaseQueryDefaultLimit;
    var limit = raw is int ? raw : int.tryParse('$raw');
    if (limit == null || limit < 1) {
      throw ArgumentError('`limit` must be a positive integer, got: $raw');
    }
    return limit;
  }

  void dispose() {
    unawaited(_updatesSubscription?.cancel());
    unawaited(_recordsSubscription?.cancel());
    for (var subscription in _watches.values) {
      unawaited(subscription.cancel());
    }
    _watches.clear();
    _changesTimer?.cancel();
    _changesTimer = null;
    unawaited(_coalescedTicks.close());
    _panel = null;
  }
}
