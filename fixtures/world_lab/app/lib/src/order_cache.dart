import 'dart:async';

import 'package:flutterware/devbar.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'api.dart';

/// The orders this app has seen, kept in a SQLite file on the phone the way
/// an app that works offline keeps what it fetched: every order the server's
/// list or its live updates bring is written here as it arrives.
///
/// The synced worlds keep theirs in PowerSync's database instead
/// (`SyncedOrders`); this is the plain app's, so that every world's phones
/// have a database for the studio to show.
class OrderCache {
  OrderCache._(this._db);

  final Database _db;

  static Future<OrderCache> open() async {
    var dir = await getApplicationSupportDirectory();
    var db = sqlite3.open(p.join(dir.path, 'orders_cache.db'));
    db.execute(
      'CREATE TABLE IF NOT EXISTS orders ('
      'id TEXT PRIMARY KEY, customer_id TEXT, item TEXT, status TEXT, '
      'seen_at TEXT)',
    );
    return OrderCache._(db);
  }

  /// Writes [orders] as they are now, in one transaction.
  void keep(Iterable<Order> orders) {
    var now = DateTime.now().toUtc().toIso8601String();
    _db.execute('BEGIN');
    try {
      for (var order in orders) {
        _db.execute(
          'INSERT INTO orders (id, customer_id, item, status, seen_at) '
          'VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
          'status = excluded.status, seen_at = excluded.seen_at',
          [order.id, order.customerId, order.item, order.status, now],
        );
      }
      _db.execute('COMMIT');
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// What the studio reads it through: its tables, its rows, and a tick for
  /// each change — the updates of one transaction told once.
  DatabaseAdapter get adapter => DatabaseAdapter(
    query: (sql, args) async => _select(sql, args),
    updates: _changes(),
    watch: (sql) => _changes(now: true).map((_) => _select(sql, const [])),
  );

  List<Map<String, Object?>> _select(String sql, List<Object?> args) => [
    for (var row in _db.select(sql, args)) Map.of(row),
  ];

  /// The tables written, a burst of row updates told as one change — and,
  /// [now], once at the start, for a watch that shows what there is.
  Stream<Set<String>> _changes({bool now = false}) {
    late StreamController<Set<String>> changes;
    StreamSubscription<SqliteUpdate>? rows;
    Timer? told;
    var tables = <String>{};
    changes = StreamController(
      onListen: () {
        if (now) changes.add({'orders'});
        rows = _db.updates.listen((update) {
          tables.add(update.tableName);
          told ??= Timer(const Duration(milliseconds: 250), () {
            changes.add(tables);
            tables = {};
            told = null;
          });
        });
      },
      onCancel: () async {
        told?.cancel();
        await rows?.cancel();
        await changes.close();
      },
    );
    return changes.stream;
  }

  void close() => _db.close();
}
