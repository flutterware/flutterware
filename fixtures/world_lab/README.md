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
its server's log, and the SMS edge prints every text message there — which is
where Leo's sign-up code is until the outbox exists.

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
