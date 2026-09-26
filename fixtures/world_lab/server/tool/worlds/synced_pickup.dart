import 'dart:io';

import 'package:flutterware/world.dart';
import 'package:postgres/postgres.dart';
import 'package:world_lab_server/world_lab_server.dart';

import 'src/lab.dart';

/// Pickup order, synced: the same barista and regular, but their apps keep
/// the orders in a local database that PowerSync keeps in step with the
/// server's Postgres — the way a modern app works offline first.
///
/// Needs Docker: the world starts the lab's stack (`../stack/compose.yaml`) —
/// Postgres and the PowerSync service — and leaves it up for the next time.
void main(List<String> args) => World.run(args, (w) async {
  w.progress('Starting the sync stack');
  var up = await Process.run('docker', [
    'compose',
    '-f',
    '../stack/compose.yaml',
    'up',
    '-d',
    '--wait',
  ]);
  if (up.exitCode != 0) {
    throw StateError('The sync stack did not start:\n${up.stderr}');
  }
  var orders = await PostgresOrders.open(
    Endpoint(
      host: 'localhost',
      port: 55432,
      database: 'shop',
      username: 'postgres',
      password: 'postgres',
    ),
  );
  w.onClose(orders.close);
  var server = await startLabServer(
    w,
    orders: orders,
    sync: SyncAuth(
      endpoint: Uri.parse('http://localhost:58080'),
      secret: 'world-lab-development-secret',
    ),
  );

  var cleo = await createUser(
    server,
    'Cleo',
    role: 'staff',
    email: 'cleo.${w.id}@example.com',
  );
  w.person(
    'Cleo',
    email: 'cleo.${w.id}@example.com',
    userId: cleo.id,
    app: Launch(
      'Lab',
      knobs: {
        'server': '${server.url}',
        'session': cleo.token,
        'person': 'Cleo',
        'sync': true,
      },
    ),
  );
  var phone = newPhone();
  var ben = await createUser(server, 'Ben', phone: phone);
  w.person(
    'Ben',
    phone: phone,
    userId: ben.id,
    app: Launch(
      'Lab',
      knobs: {
        'server': '${server.url}',
        'session': ben.token,
        'person': 'Ben',
        'sync': true,
      },
    ),
  );

  w.action(
    'Mia orders a flat white',
    (run) async {
      var mia = await createUser(server, 'Mia', phone: newPhone());
      await call(server, 'POST', '/orders', {'item': 'Flat white'}, mia.token);
    },
    description:
        'A customer with no app, through the API: synced to the counter',
  );
});
