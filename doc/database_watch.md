# Database watch — your app's sqlite, on every surface

Hand the devbar a `DatabaseAdapter` and the running app's database becomes a
panel: browse the schema, run a query, pin a live query, follow the writes —
from the cockpit's App tab, from `fw run run`, from an agent over MCP, on any
device the run cockpit reaches. Nothing here needs a rebuild to inspect, and
it works on a physical phone, where the database file itself is sealed inside
the app sandbox (design doc:
`docs/superpowers/specs/2026-08-12-sqlite-watch-design.md`).

flutterware imports no sqlite. The adapter is four function types and a name;
you wire it to whatever database library you use and own those five lines.

## The recipe: sqlite_async (and PowerSync)

`PowerSyncDatabase` implements sqlite_async's interface, so the same lines
cover both. A live version is
[`fixtures/probe_app/lib/devbar_example.dart`](../fixtures/probe_app/lib/devbar_example.dart).

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

- `query` should be a **read path**. sqlite_async's `getAll` runs on the
  read pool, which sqlite itself enforces read-only — a write smuggled into
  a query dies with `attempt to write a readonly database`, measured, not
  assumed.
- `updates` powers the `changes` feed: which tables changed, per write
  transaction, coalesced over 250ms so a sync burst reads as one event
  rather than two hundred.
- `watch` is optional. Without it a watched query re-runs on every coalesced
  tick; with it, sqlite_async re-runs only when the query's own source
  tables change. Pass a `throttle` around 250ms — the library's 30ms default
  produces a dozen snapshots during a burst.
- Two databases are two `DatabasePlugin.init` calls with two
  `DatabaseAdapter(name: ...)`s: panels `db:main` and `db:cache`.

### PowerSync: say so, and see the sync too

One more line tells the panel the database is PowerSync's:

```dart
DatabaseAdapter(
  query: (sql, args) => db.getAll(sql, args),
  updates: db.updates.map((u) => u.tables),
  sync: DatabaseSync.powersync,
)
```

The panel then reads PowerSync's own tables, through the same read-only
`query`, and adds:

- **`sync`** (state): this client's id, the local changes waiting to upload,
  when it last synced, and how far each bucket has applied. The client id is
  the one the PowerSync service logs, so a device and the service's log line
  up.
- **`records`** (feed): every record the app wrote locally, as it joins the
  upload queue (`local put`, `local patch`), and every record a checkpoint
  brought in, with its operation (`synced`, `op 16`) and its bucket. A
  change on one device and its arrival on another share the record's key.
  A bucket the device starts holding, or lets go of, is an entry of its own
  (`subscribed`, `unsubscribed`): what was written to it before arrives
  after it, flagged `newBucket`. The device lists a bucket once it holds
  something, so one subscribed to while empty is reported at its first
  record.

It is said rather than guessed: an app on plain sqlite gets nothing it has no
use for, and flutterware still imports no sync library.

## Writes are opt-in, by existence

There is no flag. Provide `execute` and an `Execute SQL` action exists,
marked danger on every surface; leave it out and no surface — agents
included — can see a write door at all:

```dart
DatabaseAdapter(
  query: (sql, args) => db.getAll(sql, args),
  updates: db.updates.map((u) => u.tables),
  execute: (sql, args) => db.execute(sql, args),  // the whole opt-in
)
```

## What you get on the wire

- **`schema`** (state) — tables *and views*, columns, row counts, read
  live. Each entry carries its `type`, so a database that presents itself
  through views — PowerSync, where every schema table is a view over a
  `ps_data__*` table — reads as itself rather than as its storage.
- **`query`** (action) — one statement, rows inline, capped at `limit`
  (default 100) with a `truncated` flag rather than a silent cut. The cap
  protects the reply, not the fetch: put a `LIMIT` in the SQL to page a big
  table.
- **`changes`** (feed) — coalesced table-level ticks.
- **`watch` / `unwatch`** (actions) + **`watch`** (feed) — every result
  snapshot of every watched query, rows riding in the lazily-fetched
  details; a broken query reports its error on the feed and stops. Each
  snapshot offers **`explain`** — `EXPLAIN QUERY PLAN` for the query the row
  belongs to.

From an agent, one call each:

```sh
fw run run panelInvoke --panel=db:main --action=query \
  --args='{"sql": "SELECT * FROM orders WHERE status = ?", "args": "[\"open\"]"}'
```
