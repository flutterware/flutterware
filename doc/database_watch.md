# Database watch

Give the devbar a `DatabaseAdapter` and your app's database shows up as a
panel while the app runs. You can browse the schema, run queries, keep a
query live and follow writes, from the run's **App** tab, from `fw run run` or
from an agent over MCP. It needs no rebuild, and it works on a physical
phone, where the database file is inside the app sandbox and out of reach.

flutterware doesn't depend on any SQLite package. The adapter is four function
types and a name, which you connect to the database library you already use.

## The recipe: sqlite_async (and PowerSync)

`PowerSyncDatabase` implements sqlite_async's interface, so the same code works
for both.
[`fixtures/probe_app/lib/devbar_example.dart`](../fixtures/probe_app/lib/devbar_example.dart)
has a working version.

```dart
import 'package:flutterware/devbar.dart';

Devbar(
  plugins: [
    DatabasePlugin.init(
      database: DatabaseAdapter(
        query: (sql, args) => db.getAll(sql, args),
        updates: db.updates.map((u) => u.tables),
        watch: (sql) =>
            db.watch(sql, throttle: const Duration(milliseconds: 250)),
      ),
    ),
  ],
  child: ...,
)
```

- `query` should only read. sqlite_async's `getAll` runs on its read pool,
  which SQLite keeps read-only, so a write sent through `query` fails with
  `attempt to write a readonly database`.
- `updates` feeds `changes`: which tables each write transaction changed,
  grouped over 250ms so a burst of sync writes shows as one event instead of
  two hundred.
- `watch` is optional. Without it, a watched query runs again on every
  `changes` event. With it, sqlite_async runs the query again only when the
  tables it reads from change. Pass a `throttle` of around 250ms, because the
  library's 30ms default produces a dozen results during a burst.
- For two databases, call `DatabasePlugin.init` twice, with a different
  `DatabaseAdapter(name: ...)` in each. The name (`main` by default) gives the
  panel its id, so `main` and `cache` become the panels `db:main` and
  `db:cache`.

### PowerSync

Add one line to tell the panel the database is PowerSync's:

```dart
DatabaseAdapter(
  query: (sql, args) => db.getAll(sql, args),
  updates: db.updates.map((u) => u.tables),
  sync: DatabaseSync.powersync,
)
```

The panel then reads PowerSync's own tables through the same read-only
`query`, and adds:

- **`sync`** (state): this client's id, the local changes waiting to upload,
  when it last synced, and how far each bucket has applied. The client id is
  the one the PowerSync service logs, so you can match a device to the
  service's log lines.
- **`records`** (feed): every record the app wrote locally, as it joins the
  upload queue (`local put`, `local patch`), and every record a checkpoint
  brought in, with its operation (`synced`, `op 16`) and its bucket. A change
  made on one device and its arrival on another have the same record key.
  When the device starts or stops holding a bucket, that is an entry of its
  own (`subscribed`, `unsubscribed`), and the records already in a new bucket
  arrive after it, flagged `newBucket`. The device lists a bucket only once it
  holds something, so a bucket subscribed to while empty is reported with its
  first record.

The panel doesn't detect PowerSync by itself. Without `sync:`, an app on plain
SQLite gets none of this, and flutterware depends on no sync library either
way.

## Writes are opt-in

Provide `execute` and an **Execute SQL** action appears, marked as dangerous
everywhere it is shown. Leave it out and nothing can write to the database
through the panel, from the studio, the command line or an agent:

```dart
DatabaseAdapter(
  query: (sql, args) => db.getAll(sql, args),
  updates: db.updates.map((u) => u.tables),
  execute: (sql, args) => db.execute(sql, args),  // this line turns writes on
)
```

## What the panel offers

- **`schema`** (state): tables and views, with their columns and row counts,
  read live. Each entry has a `type`, table or view. In PowerSync every table
  of your schema is a view over a `ps_data__*` table, and the panel lists the
  views you query.
- **`query`** (action): runs one statement and returns its rows, at most
  `limit` of them (default 100), with `truncated` set when there were more.
  The limit only shortens the answer, and the query still reads every row, so
  put a `LIMIT` in the SQL to page through a big table.
- **`changes`** (feed): which tables changed, grouped as described above.
- **`watch`** and **`unwatch`** (actions), and the **`watch`** feed: every new
  result of every watched query, with the rows in its details, which are
  fetched when you open them. A query that fails reports its error on the feed
  and stops. Each result offers **`explain`**, which runs
  `EXPLAIN QUERY PLAN` for its query.

From the command line, each is one call. An agent makes the same calls over
MCP.

```sh
fw run run panelInvoke --panel=db:main --action=query \
  --args='{"sql": "SELECT * FROM orders WHERE status = ?", "args": "[\"open\"]"}'
```
