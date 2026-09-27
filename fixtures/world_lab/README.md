# The worlds lab

A small server and a customer app, built to answer one question — should a
person's app in a world run in the studio's embedded guest by default (it
should: `docs/superpowers/specs/2026-09-25-worlds-guest-phase5-decision.md`)
— and kept to host the worlds after it.

- **`server/`** — a coffee shop's pickup orders, in memory. Its edges — SMS
  and push — report to flutterware instead of reaching a carrier, naming who
  each message reached.
- **`server/tool/worlds/`** — the lab's worlds, one a file, each declared in
  the repo root's `tool/flutterware.dart`. They host the server in their own
  process and seed it through its admin API.
- **`app/`** — the customer app, with the plugin profile of a real one on
  purpose. At boot it touches every plugin once and prints how each answered,
  and it prints the time of its first frame, so a runner that cannot carry a
  plugin says which, and a launch can be timed from outside.

## Opening a world

In the studio: *Worlds* in the rail, then *Open* beside *Pickup order*. From a
terminal, held open until Ctrl-C:

```sh
fvm dart run flutterware run worlds open --world=pickup_order --hold=true
```

Either way each person's app is a Run app on the device `studio-<name>`, so
`flutterware_act` with `device: "studio-leo"` drives Leo's. The world prints
its server's log, and the SMS edge prints every text message there too.

Every tap is a step the world follows through the lab server — whose adapter
reads the `x-fw-step` header — and, in the synced world, through each phone's
database. So is each run of the world's actions: *Mia orders a flat white*
is `world.1`. `fw run worlds trace` answers with the newest steps and what each
one caused, and `fw run worlds contents --part=orders` what the orders table
holds, each order with its life from the tap to both phones.

Leo's sign-up code is in his drawer: tap his code field, then *Type it* — or
`fw run worlds deliver` with the message's id from `fw run worlds outbox`.

A world script also runs on its own, which is how to debug its setup without
launching any app: it prints what it declares, and `name=value` arguments are
its knob values.

```sh
cd fixtures/world_lab/server && fvm dart run tool/worlds/pickup_order.dart 'Leo=signed in'
```

## The server and the app alone

```sh
cd fixtures/world_lab/server && fvm dart run bin/server.dart   # :8090
```

Then launch *Lab* from Run — the repo root's `tool/flutterware.dart` declares
it. The app's knobs are `server`, `session` (a token from the admin API, which
signs it in without a code) and `person`.

Seed a user and get their session:

```sh
curl -s -XPOST localhost:8090/admin/users -d '{"name":"Ben","role":"staff"}'
```

A user who signs in with a code reads it from the server's log, where the SMS
edge writes it.

## The synced world

*Synced pickup* is the same shop, offline first: each person's app keeps its
orders in a local database that PowerSync keeps in step with Postgres, the way
a modern app works. It needs Docker, and starts the lab's stack itself:

- **`stack/`** — Postgres (with logical replication) and the PowerSync service,
  on ports 55432 and 58080. `init.sql` makes the orders table and its
  publication; `powersync.yaml` holds the sync rules — a customer sees their
  own orders, staff see the shop's. The stack is left up between openings;
  `docker compose -f fixtures/world_lab/stack/compose.yaml down` forgets it.
- **The server** keeps its orders in that Postgres (`PostgresOrders`), hands
  each app a token for the sync service (`GET /sync/token`) and applies what
  it uploads (`POST /sync/upload`) under its own rules. Every change it makes
  is reported as a `write` event naming the record.
- **The app** runs with the knob `sync: true`: orders come from its local
  database, a tap writes there at once, and PowerSync uploads it through the
  server. Its devbar serves that database as `db:main`, PowerSync's sync state
  and every record's arrival included.
