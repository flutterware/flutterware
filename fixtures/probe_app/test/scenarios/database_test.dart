import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// The scenario that must load a native library, and the guard that keeps it
/// loading — nothing else in this suite reaches the bundle's native-assets
/// manifest, and previews never will. The platform story (why a missing
/// mapping is masked on macOS and honest on Linux and Windows) is the
/// 2026-08-26 build-hooks design doc, piece 3.
///
/// Two choices are this file's own. The screen shows the version it loaded,
/// because on macOS the fallback would serve the *system's* SQLite and the
/// bundled one is newer — the difference is what makes the manifest lane
/// visible in a picture. And it is the synchronous `package:sqlite3` API,
/// because `sqlite_async` answers from its own isolate and a scenario body
/// may not await a future another zone completes.
void main() {
  scenario('Drinks ledger', (s) async {
    var db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('CREATE TABLE drinks(name TEXT NOT NULL, price REAL NOT NULL)');
    var insert = db.prepare('INSERT INTO drinks(name, price) VALUES(?, ?)');
    for (var (name, price) in [('Flat white', 4.2), ('Cortado', 3.8)]) {
      insert.execute([name, price]);
    }
    insert.close();

    var rows = db.select('SELECT name, price FROM drinks ORDER BY name');
    await s.pumpWidget(
      _Ledger(
        engine: 'SQLite ${sqlite3.version.libVersion}',
        rows: [for (var row in rows) '${row['name']} — ${row['price']}'],
      ),
    );
    await s.screen('Poured from the bundled library');
    expect(find.text('Cortado — 3.8'), findsOneWidget);
  });
}

class _Ledger extends StatelessWidget {
  const _Ledger({required this.engine, required this.rows});

  final String engine;
  final List<String> rows;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text(engine)),
        body: ListView(
          children: [for (var row in rows) ListTile(title: Text(row))],
        ),
      ),
    );
  }
}
