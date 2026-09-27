import 'dart:math';

import 'package:postgres/postgres.dart';

/// An order's life, in the order it is lived. Staff move it along one step at
/// a time; the customer is told at each step.
const orderStatuses = ['placed', 'preparing', 'ready', 'collected'];

class Order {
  Order({
    required this.id,
    required this.customerId,
    required this.item,
    this.status = 'placed',
    DateTime? placedAt,
  }) : placedAt = (placedAt ?? DateTime.now()).toUtc();

  final String id;
  final String customerId;
  final String item;
  final String status;
  final DateTime placedAt;

  Order withStatus(String status) => Order(
    id: id,
    customerId: customerId,
    item: item,
    status: status,
    placedAt: placedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'customerId': customerId,
    'item': item,
    'status': status,
    'placedAt': placedAt.toIso8601String(),
  };
}

/// Where the shop keeps its orders: in memory, which a restart forgets, or in
/// Postgres — where a sync engine replicates them to every app that may see
/// them.
abstract class OrderStore {
  Future<List<Order>> all();
  Future<Order?> find(String id);

  /// Inserts [order], or replaces the one with its id.
  Future<void> put(Order order);
  Future<void> delete(String id);
  Future<void> close();

  /// A new order's id. A synced app makes its own, offline, so ids are UUIDs
  /// wherever a sync engine is; in memory they stay short.
  String newId();
}

class MemoryOrders implements OrderStore {
  final _orders = <String, Order>{};
  var _next = 1;

  @override
  Future<List<Order>> all() async => _orders.values.toList().reversed.toList();

  @override
  Future<Order?> find(String id) async => _orders[id];

  @override
  Future<void> put(Order order) async => _orders[order.id] = order;

  @override
  Future<void> delete(String id) async => _orders.remove(id);

  @override
  Future<void> close() async {}

  @override
  String newId() => 'o${_next++}';
}

/// The orders in Postgres, in the one table the sync engine publishes.
class PostgresOrders implements OrderStore {
  PostgresOrders._(this._db);

  final Connection _db;
  static final _random = Random.secure();

  /// Opens [endpoint] and makes sure the table and the publication the sync
  /// engine replicates from are there.
  static Future<PostgresOrders> open(Endpoint endpoint) async {
    var db = await Connection.open(
      endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS orders (
        id text PRIMARY KEY,
        customer_id text NOT NULL,
        item text NOT NULL,
        status text NOT NULL,
        placed_at timestamptz NOT NULL DEFAULT now(),
        shop_id text NOT NULL DEFAULT 'main'
      )''');
    var published = await db.execute(
      "SELECT 1 FROM pg_publication WHERE pubname = 'powersync'",
    );
    if (published.isEmpty) {
      await db.execute('CREATE PUBLICATION powersync FOR TABLE orders');
    }
    return PostgresOrders._(db);
  }

  @override
  Future<List<Order>> all() async => [
    for (var row in await _db.execute(
      'SELECT * FROM orders ORDER BY placed_at DESC',
    ))
      _order(row.toColumnMap()),
  ];

  @override
  Future<Order?> find(String id) async {
    var rows = await _db.execute(
      Sql.named('SELECT * FROM orders WHERE id = @id'),
      parameters: {'id': id},
    );
    return rows.isEmpty ? null : _order(rows.first.toColumnMap());
  }

  @override
  Future<void> put(Order order) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO orders (id, customer_id, item, status, placed_at)
        VALUES (@id, @customer, @item, @status, @placed)
        ON CONFLICT (id) DO UPDATE SET status = excluded.status'''),
      parameters: {
        'id': order.id,
        'customer': order.customerId,
        'item': order.item,
        'status': order.status,
        'placed': order.placedAt,
      },
    );
  }

  @override
  Future<void> delete(String id) async {
    await _db.execute(
      Sql.named('DELETE FROM orders WHERE id = @id'),
      parameters: {'id': id},
    );
  }

  @override
  Future<void> close() => _db.close();

  @override
  String newId() {
    var bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static Order _order(Map<String, dynamic> row) => Order(
    id: row['id'] as String,
    customerId: row['customer_id'] as String,
    item: row['item'] as String,
    status: row['status'] as String,
    placedAt: row['placed_at'] as DateTime,
  );
}
