/// The orders server's traffic, told as a story through the same calls a
/// real server makes.
///
/// No socket, no shelf, no process: [playOrdersServer] reports into whatever
/// inspector `FlutterwareServer` is attached to, exactly as the copy-paste
/// adapters in a real server do — a zone per request for correlation, an
/// `http` event with lazy details, `sql` and `log` events under it, one
/// channel the panel has never heard of, and a self-description. One of
/// everything the Server panel draws, in an afternoon at a coffee shop.
library;

import 'dart:async';

import 'package:flutterware/server.dart';

/// The query the recorder asks the SQL commands about, so the answers it
/// records are for a shape the panel actually shows.
const ordersByCustomerQuery = 'SELECT * FROM orders WHERE customer_id = ?';

void playOrdersServer() {
  FlutterwareServer.handle('sql', 'explain', (params) {
    return {
      'plan':
          'SEARCH orders USING INDEX idx_orders_customer (customer_id=?)\n'
          '  (toy database, toy plan)',
      'boundTo': ?params['params'],
    };
  });
  FlutterwareServer.handle('sql', 'requery', (params) {
    return {
      'rows': [
        {'id': 'BL-1041', 'customer_id': 7, 'total': 4.6, 'status': 'ready'},
        {'id': 'BL-1042', 'customer_id': 7, 'total': 4.9, 'status': 'brewing'},
      ],
    };
  });

  FlutterwareServer.info(
    ServerInfo(
      baseUrl: 'http://localhost:8090',
      environment: 'dev',
      links: [
        ServerLink('Menu', '/menu', description: 'what the shop sells'),
        ServerLink('Health', '/health', description: 'liveness probe'),
        ServerLink('flutterware', 'https://pub.dev/packages/flutterware'),
      ],
      connections: [
        ServerConnection(
          'postgres',
          'postgres://brewline:s3cret@localhost:5432/brewline',
          label: 'main',
        ),
        ServerConnection('redis', 'redis://localhost:6379/0', label: 'cache'),
      ],
      config: {
        'Feature flags': {'happyHour': true, 'newCheckout': false},
        'Limits': {
          'rate': {'perMinute': 600, 'burst': 50},
          'regions': ['eu-west', 'us-east'],
        },
      },
    ),
  );

  var requestId = 0;
  void request(
    String method,
    String path, {
    required int status,
    required double ms,
    Object? requestBody,
    Object? responseBody,
    void Function()? inside,
  }) {
    var id = 'req-${++requestId}';
    runZoned(() {
      inside?.call();
      FlutterwareServer.event(
        'http',
        {'method': method, 'path': path, 'status': status, 'ms': ms},
        details: {
          'requestHeaders': {
            'accept': ['application/json'],
            'user-agent': ['Brewline/1.0 (iPhone; iOS 19)'],
            if (requestBody != null)
              'content-type': ['application/json; charset=utf-8'],
          },
          'responseHeaders': {
            'content-type': ['application/json; charset=utf-8'],
            'x-powered-by': ['Dart with package:shelf'],
          },
          'requestBody': ?requestBody,
          'responseBody': ?responseBody,
        },
      );
    }, zoneValues: {FlutterwareServer.requestIdKey: id});
  }

  void sql(
    String query, {
    List<Object?>? params,
    required int rows,
    required double ms,
  }) {
    FlutterwareServer.event('sql', {
      'query': query,
      'params': ?params,
      'rows': rows,
      'ms': ms,
    });
  }

  void log(String level, String logger, String message) {
    FlutterwareServer.event('log', {
      'level': level,
      'logger': logger,
      'message': message,
    });
  }

  // The phone opens the shop.
  request('GET', '/health', status: 200, ms: 0.4, responseBody: 'ok\n');
  request(
    'GET',
    '/menu',
    status: 200,
    ms: 6.1,
    responseBody:
        '{"drinks":[{"id":"cappuccino","name":"Cappuccino","price":4.2},'
        '{"id":"flat-white","name":"Flat white","price":4.6},'
        '{"id":"matcha","name":"Matcha latte","price":5.1},'
        '{"id":"chai","name":"Chai latte","price":4.8},'
        '{"id":"cold-brew","name":"Cold brew","price":3.9}]}',
    inside: () {
      FlutterwareServer.event('cache', {'op': 'miss', 'key': 'menu:v3'});
      sql(
        'SELECT * FROM drinks WHERE available = ?',
        params: [true],
        rows: 5,
        ms: 2.3,
      );
      FlutterwareServer.event('cache', {
        'op': 'set',
        'key': 'menu:v3',
        'ttl': 300,
      });
      log('FINE', 'brewline.menu', 'menu served, 5 drinks');
    },
  );

  // An order placed, the way the app does it.
  request(
    'POST',
    '/orders',
    status: 201,
    ms: 14.8,
    requestBody:
        '{"name":"Ada","items":[{"drink":"cappuccino","size":"large"}]}',
    responseBody:
        '{"id":"BL-1042","name":"Ada","total":4.9,"readyInMinutes":4}',
    inside: () {
      sql(
        'SELECT id, price FROM drinks WHERE id = ?',
        params: ['cappuccino'],
        rows: 1,
        ms: 0.8,
      );
      sql(
        'INSERT INTO orders (id, customer_id, total, status) VALUES (?, ?, ?, ?)',
        params: ['BL-1042', 7, 4.9, 'brewing'],
        rows: 1,
        ms: 3.4,
      );
      sql(
        'INSERT INTO order_items (order_id, drink_id, size) VALUES (?, ?, ?)',
        params: ['BL-1042', 'cappuccino', 'large'],
        rows: 1,
        ms: 1.9,
      );
      log(
        'INFO',
        'brewline.orders',
        'order BL-1042 placed, 1 drink, ready in 4 min',
      );
    },
  );
  request(
    'GET',
    '/orders/BL-1042',
    status: 200,
    ms: 3.2,
    responseBody:
        '{"id":"BL-1042","name":"Ada","total":4.9,"status":"brewing"}',
    inside: () {
      sql(
        'SELECT * FROM orders WHERE id = ?',
        params: ['BL-1042'],
        rows: 1,
        ms: 0.9,
      );
    },
  );

  // The barista's screen lists today's orders — and asks one query per row,
  // which is the N+1 the panel badges.
  request(
    'GET',
    '/orders?today=1',
    status: 200,
    ms: 41.7,
    responseBody:
        '[{"id":"BL-1038"},{"id":"BL-1039"},{"id":"BL-1040"},'
        '{"id":"BL-1041"},{"id":"BL-1042"}]',
    inside: () {
      sql(
        'SELECT * FROM orders WHERE placed_at >= ?',
        params: ['2026-01-01'],
        rows: 5,
        ms: 2.7,
      );
      for (var n = 1038; n <= 1042; n++) {
        sql(
          'SELECT * FROM order_items WHERE order_id = ?',
          params: ['BL-$n'],
          rows: 1,
          ms: 1.1 + (n - 1038) * 0.2,
        );
      }
      log('WARNING', 'brewline.orders', 'listing 5 orders took 41ms');
    },
  );

  // A regular reads their own orders — the query the SQL commands answer for.
  request(
    'GET',
    '/customers/7/orders',
    status: 200,
    ms: 5.5,
    responseBody: '[{"id":"BL-1041"},{"id":"BL-1042"}]',
    inside: () {
      sql(ordersByCustomerQuery, params: [7], rows: 2, ms: 1.6);
    },
  );

  // The slow one and the broken one, so the waterfall and the errors list
  // have something to say.
  request(
    'GET',
    '/reports/daily',
    status: 200,
    ms: 1512.0,
    responseBody: '{"orders":42,"revenue":198.4}',
    inside: () {
      sql(
        'SELECT COUNT(*), SUM(total) FROM orders WHERE placed_at >= ?',
        params: ['2026-01-01'],
        rows: 1,
        ms: 1480.2,
      );
      log(
        'WARNING',
        'brewline.reports',
        'daily report took 1.5s; no index on placed_at',
      );
    },
  );
  request(
    'POST',
    '/orders',
    status: 500,
    ms: 8.3,
    requestBody:
        '{"name":"Grace","items":[{"drink":"espresso","size":"small"}]}',
    responseBody: '{"error":"unknown drink espresso"}',
    inside: () {
      sql(
        'SELECT id, price FROM drinks WHERE id = ?',
        params: ['espresso'],
        rows: 0,
        ms: 0.7,
      );
      log('SEVERE', 'brewline.orders', 'order refused: unknown drink espresso');
    },
  );
  request(
    'GET',
    '/menu',
    status: 200,
    ms: 0.9,
    inside: () {
      FlutterwareServer.event('cache', {'op': 'hit', 'key': 'menu:v3'});
    },
  );
  request('GET', '/health', status: 200, ms: 0.3, responseBody: 'ok\n');
}
