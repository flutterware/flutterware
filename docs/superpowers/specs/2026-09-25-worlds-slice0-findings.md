# Worlds slice 0 — the world script, guests only

**Date:** 2026-09-25
**Design:** `2026-09-25-worlds-design.md`, slice 0. The device it runs people
on was settled by the guest experiment (`-guest-phase5-decision.md`).
**Result:** a world opens, restarts and closes from the studio, from `fw` and
through the MCP server's core, on the lab's *Pickup order*. Two people signed
in against a server the world hosts, one of them signing up with a code the
world printed, and an order placed in one app reached the other's live. Not
yet done: the consumer's first world, which closes the slice.

## What was built

- **`package:flutterware/world.dart`** — `World.run`, `w.person` with any
  subset of email, phone, user id and password, `w.email`, `w.phone`,
  `w.unique`, `w.progress`, `w.action` with progress and cancellation,
  `w.knob`, `w.onClose`, `w.ready`, `w.freePort`. Pure Dart. A script run on
  its own prints what it declares, so its setup can be debugged without
  launching anything.
- **The owner** (`app/lib/src/world/open_world.dart`) — runs the script, builds
  each app its people use once, starts a guest per person, announces each to
  Run with the world's name on its handle, and stands in for their
  `flutter run`. Flutter-free: only where a guest draws differs between the
  studio (a live texture) and `fw` or the MCP server (headless).
- **The `worlds` plugin** — `list`, `open`, `status`, `restart`, `invoke`,
  `close`, the same for `fw`, the MCP server and the studio. In the studio, a
  *Worlds* panel: the worlds a project declares, then the open one's people
  side by side, its knobs as pickers and its actions as buttons.
- **The lab's first world**, `fixtures/world_lab/server/worlds/
  pickup_order.dart`: Ana, staff, signed in; Leo, a phone number who has
  never used the app; a knob that starts him signed in; an action that has a
  customer with no app order.
- **Run** refuses to change a world person's knobs and names the world's
  restart instead, as decided before the slice.
- **Removed:** the experiment's *World lab* pane and its entry point. The
  Worlds panel does what it did.

## Measured

On this machine, warm — the guest host built, the app's kernel seeded:

| | |
|---|---|
| open *Pickup order*, from the script's start to both apps drawn | **3.7 s** headless (`fw`), **4.2 s** in the studio |
| restart it with a knob changed — the script closed and run again, the server started and seeded again, both apps restarted in place | **2.9 s** |
| close it | nothing left: no script, no guest, no Run handle, the server's port free |

A world restart runs the script in a new process rather than asking the old
one to run its body again: a script whose file changed since it opened would
otherwise restart as the old code. The new process costs little next to the
seed; a script with no server opens, restarts and closes in under a second in
the owner's test.

## Findings

### 1. The first flow across people worked unchanged

Opened headless through `fw`, then driven through the MCP server's `act`:

- Leo typed his phone number and asked for a code;
- the world's log printed the SMS the lab's edge sent — the stand-in for the
  outbox until slice 1;
- Leo typed the code and was signed up;
- he ordered, and Ana's board showed the order at once, through the server's
  live socket.

Every app in it is a Run app: the drive layer needed nothing new.

### 2. Two worlds on one worktree collide in Run

A person's device is `studio-<name>`, so two worlds — or the experiment's old
lab, still running — give two apps the same device, and every `act` on it
must name a run key. Hence one world per worktree: opening a second is
refused, and so is opening one while another process owns one, which each
person's handle now says. The design's rule, *whoever opens a world owns it*,
is what the panel shows for a world another process holds: its people are in
Run, in pictures, and only that process restarts or closes it.

### 3. A world's knobs are words; an app's are typed

A `Launch`'s knobs are JSON values the script chose, and `main` declares
types. The owner reads `main`'s signature, as Run does, and converts what
converts — `'8090'` to an int for an `int` parameter — and refuses the rest by
name: a knob `main` does not take lists the ones it does. An enum parameter is
refused for now; the guest's entry would have to import the enum's type, as
Run's wrapper does.

### 4. `fw` has to hold a world open

The world lives in the process that opened it, and `fw` exits when the action
returns. `open --hold=true` keeps it until Ctrl-C and prints the world's log
as it comes, which is the only way to read a code a server texted when
nothing else shows the world.

## Open

- **The consumer's first world**, which the slice ends with. Its app needs
  studio answers it does not have yet — about 14 plugins, sqflite the largest
  — and its project pins flutterware to a commit that has no `world.dart`.
- **`worlds` over the MCP server** is the same core `fw` ran, but the server
  connected to this session predates the plugin, so no call has gone through
  it yet. The next session's server has it.
