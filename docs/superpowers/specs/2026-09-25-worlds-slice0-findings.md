# Worlds slice 0 — the world script, guests only

**Date:** 2026-09-25
**Design:** `2026-09-25-worlds-design.md`, slice 0. The device it runs people
on was settled by the guest experiment (`-guest-phase5-decision.md`).
**Result:** slice 0 is done. A world opens, restarts and closes from the
studio, from `fw` and through the MCP server's core, on the lab's *Pickup
order*: two people signed in against a server the world hosts, one of them
signing up with a code the world printed, and an order placed in one app
reached the other's live. Then the consumer's first world: two colleagues,
each signed in to the real local stack and synced, in 7.3 s — with three new
studio answers and nothing written in the consumer's project.

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
- **The lab's first world**, `fixtures/world_lab/server/tool/worlds/
  pickup_order.dart`, declared in the repo's `tool/flutterware.dart`: Ana, staff, signed in; Leo, a phone number who has
  never used the app; a knob that starts him signed in; an action that has a
  customer with no app order.
- **Run** refuses to change a world person's knobs and names the world's
  restart instead, as decided before the slice.
- **Removed:** the experiment's *World lab* pane and its entry point, which
  the Worlds panel replaces; its harnesses, `app/tool/embedder/run_app.dart`
  and the lab's `tool/cold_open.dart`, which `worlds open` replaces; and
  candidate 1 — the lab's `guest/fakes.dart` and the guest build's door for a
  project's fakes. A guest's plugins are always their own, answered by the
  studio. The findings keep the numbers those harnesses measured.

## Measured

On this machine, warm — the guest host built, the app's kernel seeded:

| | |
|---|---|
| open *Pickup order*, from the script's start to both apps drawn | **3.7 s** headless (`fw`), **4.2 s** in the studio |
| restart it with a knob changed — the script closed and run again, the server started and seeded again, both apps restarted in place | **2.9 s** |
| open the consumer's first world, two people on its local stack, headless | **7.3 s** |
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

### 5. The consumer's first world took three answers

Its project pins a flutterware without `world.dart`, so the world was a
scratch script opened by a scratch harness around the same owner, with the
entry point named there instead of read from its config. Nothing was written
in its repository; the builds went to the scratchpad. Each blocker showed up
as the one thing its app waited on at boot:

| plugin | answer | lines |
|---|---|---|
| `firebase_core` | `initializeApp` answers with the options the app passed; there is no plist to read | 30 |
| `device_info_plus` | the person's device — an iPhone 16 says it is one | 56 |
| `flutter_timezone` | the Mac's zone, as a simulator gives | 17 |

Lines without comments or blanks. With those, both colleagues reached their
home screens with their own data: the first sees four records marked as
theirs, the second none, and the totals differ. The world's isolation held
without the app's help, as it did in the lab.

Two things were wrong in flutterware rather than missing:

- **A Pigeon method with no parameters sends no message at all**, which
  reached the studio as zero bytes and was read as a corrupt message.
  `initializeCore` is such a method; it is answered now.
- **An app asks `dart:io`'s `Platform`, and in a guest that says macOS**,
  whatever the look. The consumer's app asked for macOS device info on an
  iPhone-looking guest. The device info answer carries both shapes, each
  describing the person's device; an app that branches on `Platform.isIOS`
  elsewhere will take its macOS branch in a guest, which is worth knowing
  before its first world.

A guest that never draws used to fail after a minute with
`TimeoutException`. It now says what the app last threw, which is how each of
the three answers above was found.

## Open

- ~~**The consumer opening worlds itself.**~~ Done in round 1 (below). It
  makes fresh users through its public API, about 0.5 s each, so seeding
  needs no debug endpoint until a state the API cannot reach.
- **The rest of its plugins** — about 11 of the 14 — answered as its screens
  reach them; sqflite is still the largest.
- **Its runs are not this session's.** A person's Run handle belongs to the
  checkout their app is in, and the MCP server of one repository lists that
  repository's runs only, so the consumer's people were observed straight
  over their VM services.
- **`worlds` over the MCP server** is the same core `fw` ran. The consumer's
  server predated its pin move and reported the plugin with no actions,
  which round 1 turns into saying the server is older than the project.

## Round 1 — the consumer's first day

The consumer's own session moved its pin to slice 0, declared two worlds and
opened them from `fw` a few dozen times — from nothing in 57.5 s, warm in
~21 s — then handed back what broke and a draft of the system as cards (now
*The system beside the people* in the design). Nothing in flutterware was
patched from its side. What changed here:

- **The script is compiled once.** `dart run` spent 11.9 s of a ~21 s warm
  open compiling the whole server the script imports, and a restart paid it
  again. The script now runs under `dart run --resident`, one compiler per
  opening, shut down on close. Its kernels outlive it on disk, so a fresh
  process starts warm. Measured on a script importing the studio's session
  and the analyzer: plain `dart run` 5.9–7.4 s; resident, cold 3.2 s, warm
  0.22 s, after an edit 0.30 s, with a new compiler after a shutdown 0.76 s —
  and an edit made while no compiler ran was picked up. The lab world now
  opens in 3.5 s and restarts in 0.4 s.
- **Any process reaches a world another owns.** A world held by `fw … --hold`
  refused even `status` from anywhere else, so an agent could drive the
  people but never run an action. The owner now leaves a handle per worktree
  and answers `status`, `invoke`, `restart` and `close` on a socket; every
  other process forwards them. A held `fw` ends when another process closes
  its world — a signal watched with `first` had kept it alive — and the
  studio can close a world another process owns. Opening a second world on
  the worktree is still refused, now naming the owner's pid, which the old
  message took from a person's guest.
- **`worlds list` reads the declarations.** It answered `{"worlds": []}` in
  every fresh process.
- **The log is stamped** with the seconds since the opening, and `dart run`'s
  `Running build hooks...` — no newline, so glued to the script's first line
  — is gone from it.
- **`w.phone(prefix:, digits:)`.** The UK's fictional range fails
  libphonenumber-style validation, so a validating server and app refused
  every number `w.phone()` made. The default stays fictional; the guide says
  a valid number can be somebody's.
- **Each guest runs in its person's own folder.** A dev entry point writing
  under `Directory.current` put every guest's local database in one folder;
  a device's working directory means nothing, so the person's home stands in.
- **`permission_handler`** is answered: nothing granted until the app asks,
  then what it asked for.
- **An older studio or MCP server says so.** Started before the pin moved but
  first called after, the server's check for a changed resolution latched
  onto the new one and stayed quiet, and `flutterware.worlds` came back as a
  plugin with no actions. A first-party plugin missing from a build now
  explains itself as the build being older than the project's flutterware.

Left for later: starting guest builds before the first `w.person` — after
the resident compiler, the script reaches its first person much sooner — and
handing each person's traffic and logs to the script, which the design takes
up as the system's third source of movement.
