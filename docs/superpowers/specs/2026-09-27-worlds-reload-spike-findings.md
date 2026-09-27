# Worlds: reloading the world's process — spike findings

2026-09-27. The question (slice 3): can an edit to the server a world hosts,
or to one of its actions, reach the running world without a restart, which
makes new people? The world script runs as a plain `dart run --resident`
process, which is a JIT VM, so the Dart VM's own hot reload is the candidate.

## What was measured

On the lab's *Pickup order* script, started as a world starts it, with three
more flags: `--enable-vm-service=0 --no-dds --write-service-info=<file>`.

| | |
|---|---|
| Start, resident compiler warm | the lab server listening 307 ms after the process started, VM service on |
| A route's body edited, then `reloadSources` on the main isolate | `success: true` in 46 ms, then 34 ms; `/health` answered with the new code at once |
| A new field on a class with a live instance | `success: true` in 32 ms; the live object read the field's initializer |
| A syntax error | an RPC error (-32603) in 11 ms, carrying the compiler's message with file and line; the process kept running the old code |

The VM compiles the reload itself from source (its kernel service), so the
resident compiler plays no part in it, and a restart after a reload still
starts from the resident compiler's kernels.

## What a reload does not reach

A standalone script with a map of callbacks made once at startup, the way
`w.action` keeps an action's body, edited from `v1` to `v2` and reloaded:

| callback made at startup | after the reload |
|---|---|
| a closure literal, `() => 'closure v1'` | **v1**: a closure made before the reload keeps its body |
| a closure that calls a top-level function | v2: what it calls is new |
| a method tear-off, `shop.greet` | v2 |
| a top-level function tear-off | v2 |
| a top-level function with a local function inside | v2: called again, it makes the new one |

And the world's body does not run again: its people, actions and knobs stay
as they were declared, and state the script holds — the server's data, the
sessions it made — survives, which is the point.

## A server's router is the same case

A shelf server builds its router once — `Router()..get('/orders', (req)
{...})`, a pipeline of middleware — and hands the result to `serve`. Every
handler in it is a closure made then: after a reload a handler keeps its old
body, a route added is not in the router, and a middleware edited or added
never runs. Only a method the router calls by tear-off runs new code, which
is why the lab's `switch` in a method reloaded and its middleware did not.

Flutter has the answer: after a reload, `ext.flutter.reassemble` rebuilds
the widgets. Here, `FlutterwareServer.onReassemble(callback)` registers
`ext.flutterware.reassemble` in the isolate, and the world calls it after
`reloadSources`: every callback runs, in order, and rebuilds what the server
built once — its router, or the app object holding it, disposed and made
again over the same state. That is the shape a consumer's own dev entry point
already had (a file watcher, then `app.dispose(); app = appFactory();`), so
the same callback serves both. `FlutterwareServer.reloadable(() =>
routes(store))` is the short form for a handler alone; a build that throws
keeps its last one serving, and the reload says so. Measured on the lab: a
header added in its inspection middleware answered on the next request after
*Reload*, from the same server on the same port. The one thing a rebuild resets is
state the middleware kept in its own closure — the lab's request counter
moved to a top-level variable.

## What it suggests

- **A world reload is the script's VM reload plus the guests' reload**, which
  the world already has (`_Build.reload`): one action, `worlds reload`, and a
  *Reload* beside *Restart*. A compile error refuses with the compiler's
  message and changes nothing.
- **Say what it cannot reach.** A person, an action or a knob added to the
  body needs a restart, and so does an edit inside a closure the body handed
  to `w.action`. The guide says to hand `w.action` a named function, or a
  closure that calls one, when its code is being worked on.
- **The VM service costs the opening nothing measurable** and listens on
  loopback only; its banner is dropped from the world's log.
