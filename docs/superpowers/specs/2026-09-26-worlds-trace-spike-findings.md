# Worlds — the trace spike

**Date:** 2026-09-26
**Question:** can one action on a device, by a person or an agent, be traced
through a Dart server to everything it caused, with what exists plus a few
small primitives? (`2026-09-25-worlds-design.md`, *The system beside the
people*; the canvas rounds that led here are mockups, not code.)
**Answer:** yes, exactly rather than by timing. On the lab world, every request
an app made after a tap carried that tap's step through a Dart zone, and every
event the server reported under it inherited the step with no code of the
project's beyond its adapter. The canvas board drawn from this run holds
nothing invented.
**Status:** a spike on its own branch, not for merging as is.

## What was built

- **The guest** (`app/lib/src/world/app_guest.dart`, the generated entry). The
  binding dispatches each gesture — pointer down to up — inside a zone naming
  a step, `s<ms>-<n>`. An `HttpOverrides` wraps the app's `HttpClient` and
  stamps `x-fw-step` on every request: the zone's step, or the last step if it
  ended under 1.5 s ago (the fallback), counted apart.
- **The server primitives** (`lib/src/server/inspector.dart`): `stepKey`, a
  zone key every event reads into its payload as `step`; `identify(user)`;
  `reach(user, what)`. Twenty-seven lines; nothing new imported.
- **The lab server** (its 25-line adapter plus three lines): the adapter puts
  the header in the zone and names each request's part — its route, ids
  replaced; auth calls `identify`; the WebSocket broadcast calls `reach` per
  listener.

## Measured

One world, two people: Ben signed up and ordered, driven by the agent; Cleo
advanced his order twice, tapped through her guest's engine — the path a
person's mouse takes, and Run logged both as human taps.

| | |
|---|---|
| app requests after a tap | 8, all joined by zone; the time window never used |
| server requests carrying a step | 7 of 14 — the rest were app start-up and the script's own calls |
| events inheriting the step | all of them: identify, reach, sms, push |
| reaches recorded | 7, Ben's order reaching Cleo among them |
| tap to the server receiving its request | ~4 ms |
| the adapter, after the spike | still a snippet: +5 lines |

Signing in is the telling case: one tap, four requests — verify, `/me`,
`/orders` and the WebSocket reconnect — all in the tap's zone, because the app
chains them from its button's callback. A fetch started by a rebuild would
not be, which is what the fallback is for; this app has none.

## Findings

- **Identity is learnt for free.** The script never knew Ben's user id — he
  signed up himself. `identify(u2)` first appeared under Ben's own step, which
  names him; from then on a push `to: u2` lands on Ben's device.
- **A step id must be the device's.** Both guests numbered their steps from 1;
  the millisecond keeps them apart here, but the id should carry the person or
  the run.
- **The script's actions need steps too.** Mia's order, placed by an action,
  is traced to no one. The script is Dart: the same `HttpOverrides`, in its
  process, would stamp an action's requests with the action run.
- **A WebSocket upgrade is not a part.** shelf hands it over by throwing, so
  the adapter never reports `/live`; what travels over it arrives as `reach`.
- **Start-up is not a step.** The apps' first requests carry none; the world
  knows when each person's app started and can name that as a step of its own.

## Next

Draw the canvas from traces like this one rather than from invented ones; add
the script's steps and device-scoped ids; decide the adapter's place in the
guide.

## A sync engine: PowerSync in the lab

Modern apps keep their data in a local database that a sync engine keeps in
step, rather than calling an API. The lab now has one: Postgres and the
PowerSync service in Docker (`fixtures/world_lab/stack/`), the lab server as
its backend — a token endpoint, an upload endpoint, orders in Postgres — and
the app's `sync` knob, under which orders live in a local PowerSync database.
The world *Synced pickup* opens it all in 4.6 s once the stack is up.

A sync trace follows **records**, not calls: a tap writes locally, the SDK
uploads later from its own loop, the service — not ours, not Dart — fans the
change out, and every device's local database applies it. Measured on Ben's
order, record `9f24ab7a`:

| from Ben's tap | |
|---|---|
| +22 ms | his local write |
| +29 ms | the server's write, carrying his step |
| +40 ms | the order on Cleo's phone (op 16) |
| +272 ms | his own write confirmed back (op 15) |

Cleo's two taps ran the same way back; her "ready" was on Ben's phone 34 ms
after she tapped.

**How each hop joined:**

- **The upload, by time.** PowerSync uploads outside the tap's zone, so the
  guest's stamp came from the 1.5 s window — 3 of 3 correct. Exact would be
  the per-write `_metadata` column PowerSync has since 1.13, at the price of a
  line in the app's writes.
- **The server's write, by the step** the upload carried, and by the record's
  key it now reports (`write {table, key, op}`).
- **Each arrival, by the record's key,** read from PowerSync's own tables:
  `ps_crud` is the upload queue, `ps_oplog` the operations per record,
  `ps_buckets` how far each bucket has applied. The Database watch panel
  reads them when the app's adapter says `sync: DatabaseSync.powersync` — a
  `sync` state and a `records` feed, tested against a fake, nothing of
  PowerSync imported.

**Findings:**

- **The sync stream is invisible to the app's HTTP.** PowerSync syncs in its
  own isolate, where the guest's `HttpOverrides` does not apply. Nothing is
  lost: arrivals are read from the local database instead.
- **PowerSync's change notifications leave out its `ps_*` tables,** so the
  panel reads them on the app tables' ticks — which a sync apply does raise.
- **`ps_sync_state.last_synced_at` is in microseconds** in the core 2.4
  ships, not seconds.
- **Ids must be unique across openings,** not only within one. Postgres
  outlives the world; the lab server's `u2` was reused by the next run, and
  the new Ben inherited the last one's orders. Its ids now carry the run.
- **A human tap on one of several identical buttons is named by position**
  (`tap at (307, 249)`), where one unique label was named (`tap "Advance"`).
  The timeline wants the card around it.
- **The service logs every checkpoint per client id,** the same id the
  device's `ps_kv` holds — a source for the service's own node, not used yet.
- **Sync rules** want every bucket parameter used by its data queries:
  "staff see every order" became "staff see their shop's orders", by id.
