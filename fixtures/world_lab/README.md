# The worlds lab

A small server and a customer app, built to answer one question — should a
person's app in a world run in the studio's embedded guest by default — and
kept to host the worlds after it. The plan is
`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`; what has
been measured is beside it, one findings file per phase.

- **`server/`** — a coffee shop's pickup orders, in memory. Its edges — SMS
  and push — report to flutterware instead of reaching a carrier, naming who
  each message reached.
- **`app/`** — the customer app, with the plugin profile of a real one on
  purpose. At boot it touches every plugin once and prints how each answered,
  and it prints the time of its first frame, so a runner that cannot carry a
  plugin says which, and a launch can be timed from outside.

## Running it

```sh
cd fixtures/world_lab/server && fvm dart run bin/server.dart   # :8090
```

Then launch *Lab · Ana* or *Lab · Leo* from Run — the repo root's
`tool/flutterware.dart` declares both. The app's knobs are `server`, `session`
(a token from the admin API, which signs it in without a code) and `person`.

Seed a user and get their session:

```sh
curl -s -XPOST localhost:8090/admin/users -d '{"name":"Ben","role":"staff"}'
```

A user who signs in with a code reads it from the server's log, where the SMS
edge writes it.
