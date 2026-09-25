# Worlds guest experiment — phase 4: parity and scale

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 4. Before it:
`2026-09-25-worlds-guest-phase3-findings.md`.
**Result:** phase 4 passes, with one gap to decide. Four guests at rest take
**949 MB together at 0.4 % CPU**, against 2 GB and 10 %. Every Run tab and
verb works on a guest with no change to Run. Two things make that so: the
guest is registered as a device, and its owner registers the two services
`flutter run` registers. That brings hot reload (all guests from one compile)
and hot restart (in the same process). **Changing a guest's knobs** is the gap:
Run changes them by rewriting a wrapper that a guest does not have (finding
5). One more gap looked like a guest's but is not: every app without a devbar
gets it, on every device.

## What was built

- **Logs.** Each guest's output goes to a file in the format Run's Logs tab
  reads: the app's lines as `flutter:` lines, and an `app.started` event.
  That event is what tells Run that a guest ended rather than failed to
  start. Announcing a guest also clears old failures under its key, as a
  launch does. Stopped guests used to show as *failed*; now they simply go.
- **A launcher for each guest** (`app/lib/src/world/guest_launcher.dart`).
  The world pane registers `reloadSources` and `hotRestart` on each guest's
  VM service, under the alias `flutter run` uses. Run finds them the way it
  finds `flutter run`'s, and cannot tell the difference.
- **Background and front.** A control beside each phone sends the app the
  lifecycle a phone sends an app it stops showing.
- **A spinner on demand.** A *Spin* switch in the lab app, so one person's
  app can animate while the others rest.

## Parity

| Run | on a guest | through |
|---|---|---|
| Logs, errors | yes | the guest's log file; a layout overflow arrives as an error, as it does anywhere |
| Network | yes | the VM's HTTP profile — nothing added |
| Screen, `observe`, `act` | yes | the run guest the entry already mounts (phase 2) |
| Steps | yes | the run's journal |
| Hot reload | yes — **171–211 ms, every guest from one delta** | the owner's launcher |
| Hot restart | yes — **330 ms, in the same process** | `_flutter.runInView` (finding 2) |
| App (panels) | as on every device | an app without a devbar gets `no handler for panels.list` on a macOS window too; filed separately |
| Device settings | no — like a macOS window | Run has no mechanism for either; *background* is in the pane |
| Changing knobs | **no** | finding 5 |

Drive round trips: the median of 20 calls, made straight to the VM service,
with the same arguments Run sends, against the lab app signed in as the same
person:

| | guest (393×852 @2x) | macOS window (800×600 @2x) |
|---|---|---|
| `observe`, with a screenshot | 50 ms | 82 ms |
| `observe`, without | 27 ms | 33 ms |
| `tap` a tab, with a screenshot | 442 ms | 471 ms |

The guest is not slower anywhere. Part of the screenshot gap is size: the
window has 43 % more pixels. Most of a tap is the tab animation settling.

## Scale

A process's *footprint* is its physical footprint as `footprint` reports it.
CPU is `top`'s mean over 12–16 s, first sample dropped. The world is the
*World lab* window, one compiler, and one host process per person.

| world | each guest | the studio | its compiler | CPU |
|---|---|---|---|---|
| 2 at rest | 242–243 MB | 324 MB | 822 MB | 0 % each |
| **4 at rest** | **235–239 MB (949 MB together)** | 333 MB | 840 MB | **0.1 % each, studio 0 %** |
| 2, one spinning | the spinner 677 MB | 635 MB | 822 MB | spinner 11.3 %, studio 8.5 % |
| 4, one spinning | the spinner 673 MB | 633 MB | 827 MB | spinner 8.6 %, studio 6.7 % |
| 4, two spinning | 673 and 663 MB | 648 MB | 827 MB | 12.2 % and 12.5 %, studio 9.6 % |
| a spinner sent to the background | 245–264 MB | 345–352 MB | — | **0 %**, studio 0 % |

Against the same app, one person each:

| | memory | CPU at rest | spinning |
|---|---|---|---|
| guest | ~240 MB, plus a share of one compiler per world | 0.1 % | ~670 MB, ~10 % + the studio's ~7 % |
| macOS window | 304 MB; **1.3 GB** with the `flutter run` that reloads it (compiler 881 MB, tool 118 MB) | 0.1 % | 564 MB, 27.4 % |
| simulator | **2.9 GB** for the device's 149 processes (the app 241 MB), plus 0.94 GB of `flutter run` | 3.3 % | — |

## Findings

### 1. Reload and restart needed nothing from Run

`flutter run` does not do reloads for Run. It registers two services on the
app's VM service, and Run calls whoever registered them. So the world pane
registers them too, and Run's reload, restart, the Run tab's buttons, and
anything else that looks for those two services all reach a guest unchanged.
What happens behind them is the world's: a reload asked of any person's app
compiles once and reloads *everyone's*, because they run one program. If one
copy were left behind, the next delta would be wrong for it. Two guests
reload in about 200 ms. Each world pays for one compile, where a macOS window
or a simulator pays one per person.

### 2. A restart stays in the process

The engine's shell answers `_flutter.runInView` in every embedder. It restarts
the root isolate from a kernel file, in the same process, the same view and
the same surfaces. The owner compiles the whole program and hands it over. In
330 ms `main` runs again: the plugins register again, and the app's disk
survives, as it does in a hot restart on a phone (*launch 2*, *2 launches* in
SQLite). The other guests are untouched. Before compiling, a restart first
reloads everyone else, because the later deltas build on the whole program it
compiles.

### 3. Animation costs a texture pool, and a macOS window pays it too

While anything moves, the process that renders it keeps Impeller's pool of
render targets:

- the guest: about **430 MB** more, as *owned physical footprint (graphics)*;
- the studio, which composites what the guest renders: about **310 MB** more,
  paid once however many guests animate.

A macOS window of the same app pays the same kind of cost, **260 MB** more.
Both return as soon as frames stop. So the guest's architecture renders twice
(guest and studio) and pays the pool twice. But the studio's pool is shared,
and the per-guest CPU (about 10 %, plus the studio's 7–10 %) is below one
macOS window's 27 %. That window is larger; the comparison is not
like-for-like in pixels.

### 4. Off screen is not paused. Paused is.

With four people, Mia was scrolled out of the window and still rendered at
12.5 % while spinning. The pane does not draw her, but her app does not know
that. Sending her app to the background is what stops it:

- the framework reports `lifecycle: paused, framesEnabled: false`;
- CPU goes to 0, and the pool is given back.

So the canvas's promise ("a person drawn as a card produces no frames")
needs one thing the lab does not do: pause what it is not drawing live, and
resume on zoom. Drive still reaches a paused app: it forces the frames it
needs, and its reply says so.

### 5. Changing knobs is the one parity gap

Run changes a running app's knobs by rewriting the wrapper it compiled around
the entry point, then hot restarting. A guest has no such wrapper. It reads
its knobs from its environment when it starts, and a restart keeps the
environment. Run refuses plainly (*launched without a package, so there is no
wrapper to rewrite*). The fix is the same shape as finding 1, and it is a
choice to make rather than a patch:

- Run's `setKnobs` calls a knobs service when the app's launcher registered
  one;
- the world answers it by writing the person's knobs where the entry reads
  them, then restarting that person's app in place.

That would be the first change to Run this experiment needs, and it would be
open to any launcher, not only the world's. The world script itself does not
need it: it owns each person's knobs and can restart their app itself.

### 6. The compiler is the biggest process in a world

At 820–840 MB, the frontend server outweighs three guests together. A world
has one. A macOS window reloadable through `flutter run` brings its own (881
MB), and so does a simulator's. Per person, that is the difference between
roughly 0.24 GB plus a share, 1.3 GB and 3.8 GB.

## Open

- **Changing knobs** (finding 5). Decide in phase 5 whether Run gets a
  launcher door for knobs.
- **Pausing on visibility** (finding 4): canvas work, not the experiment's.
- The scorecard's **memory per person** and **Run parity** rows can be filled
  from the tables here, and **hot restart** from finding 2.
