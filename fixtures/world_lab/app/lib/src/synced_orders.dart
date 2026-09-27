import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';

import 'api.dart';

/// What the app keeps locally: the orders it may see, as the sync rules hand
/// them out.
const _schema = Schema([
  Table('orders', [
    Column.text('customer_id'),
    Column.text('item'),
    Column.text('status'),
    Column.text('placed_at'),
    Column.text('shop_id'),
  ]),
]);

/// The shop's orders through PowerSync, the way a modern app keeps them: it
/// reads and writes its own local copy, at once, and the sync engine keeps
/// that copy in step with the server's — uploading what the app wrote through
/// the lab server, and bringing down what anybody else did.
class SyncedOrders {
  SyncedOrders._(this.db);

  final PowerSyncDatabase db;

  static Future<SyncedOrders> open(Api api) async {
    var dir = await getApplicationSupportDirectory();
    var db = PowerSyncDatabase(
      schema: _schema,
      path: p.join(dir.path, 'orders.db'),
    );
    await db.initialize();
    await db.connect(connector: _Connector(api));
    return SyncedOrders._(db);
  }

  /// Every order this app may see, newest first, as it changes.
  Stream<List<Order>> watch() => db
      .watch('SELECT * FROM orders ORDER BY placed_at DESC')
      .map(
        (rows) => [
          for (var row in rows)
            Order(
              id: row['id'] as String,
              customerId: row['customer_id'] as String,
              item: row['item'] as String,
              status: row['status'] as String,
            ),
        ],
      );

  Future<void> place(String customerId, String item) => db.execute(
    'INSERT INTO orders (id, customer_id, item, status, placed_at, shop_id) '
    "VALUES (uuid(), ?, ?, 'placed', ?, 'main')",
    [customerId, item, DateTime.now().toUtc().toIso8601String()],
  );

  Future<void> advance(Order order) {
    const statuses = ['placed', 'preparing', 'ready', 'collected'];
    var next = statuses[statuses.indexOf(order.status) + 1];
    return db.execute('UPDATE orders SET status = ? WHERE id = ?', [
      next,
      order.id,
    ]);
  }

  Future<void> close() => db.close();
}

/// How PowerSync reaches the lab: a token from the lab server, and every
/// local change uploaded to it — the server applies its own rules to each.
class _Connector extends PowerSyncBackendConnector {
  _Connector(this.api);

  final Api api;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    var json = await api.syncToken();
    return PowerSyncCredentials(
      endpoint: json['endpoint']! as String,
      token: json['token']! as String,
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    var batch = await database.getCrudBatch();
    if (batch == null) return;
    await api.upload([
      for (var entry in batch.crud)
        {
          'op': entry.op.toJson(),
          'table': entry.table,
          'id': entry.id,
          'data': entry.opData,
        },
    ]);
    await batch.complete();
  }
}
