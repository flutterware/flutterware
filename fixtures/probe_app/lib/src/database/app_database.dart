/// The sample app's own database — the dogfood for the db panel.
///
/// sqlite_async over a real file, so the panel's `changes` ticks and `watch`
/// re-runs come from the same machinery a production app uses. A small
/// ledger is seeded on open, and [record] appends to it, which is what makes
/// the db panel move while the app is being driven.
library;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final SqliteDatabase db;

  static Future<AppDatabase> open() async {
    var directory = await getApplicationSupportDirectory();
    var db = SqliteDatabase(path: p.join(directory.path, 'example.db'));
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ledger(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item TEXT NOT NULL,
        amount REAL NOT NULL,
        recorded_at INTEGER NOT NULL
      )''');
    if ((await db.get('SELECT COUNT(*) AS n FROM ledger'))['n'] == 0) {
      await db.executeBatch(
        'INSERT INTO ledger(item, amount, recorded_at) VALUES(?, ?, ?)',
        [
          for (var (item, amount) in const [
            ('Beans, 1kg', 18.0),
            ('Filters', 4.5),
            ('Oat milk', 2.2),
          ])
            [item, amount, DateTime.now().millisecondsSinceEpoch],
        ],
      );
    }
    return AppDatabase._(db);
  }

  Future<void> record(String item, double amount) => db.execute(
    'INSERT INTO ledger(item, amount, recorded_at) VALUES(?, ?, ?)',
    [item, amount, DateTime.now().millisecondsSinceEpoch],
  );
}
