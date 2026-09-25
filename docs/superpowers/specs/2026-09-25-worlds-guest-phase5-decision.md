# Worlds guest experiment — phase 5: the decision

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 5. The
evidence is in the findings of phases 0 to 4, next to it.
**Outcome: go.** A person's app in a world runs, by default, in the studio's
embedded guest, with the studio answering its plugins' platform calls
(candidate 2). People whose app needs something a guest cannot carry run on a
simulator, a phone or a macOS window: a camera, a native capture SDK, a view
the OS draws, or Bluetooth.

## The rule, applied

The rule was fixed before measuring (the plan, *The rule*). **Go** needs two
things: phases 1 to 4 pass, and a guest opens a two-person world from a cold
worktree at least twice as fast as the faster of macOS windows and simulators.

- **Phases 1 to 4 pass.**
  - Phase 1: both apps reached a signed-in screen against their real servers,
    sync included for the consumer.
  - Phase 2: all eight checklist items work.
  - Phase 3: 35 lines per plugin on average, and isolation per person without
    the app's help.
  - Phase 4: four guests at rest in 949 MB and 0.4 % CPU, and parity through
    the guest's registration alone.
- **The speed holds.** macOS windows are the faster native candidate, at
  31.6 s. A guest opened the same world in 9.1 s in phase 1 (4.6 s with the
  machine's seed kernel). Re-timed today, with the studio answering, it took
  **11.3 s** (8.6 s seeded). That is **2.8×** faster at the slowest figure,
  against the 2× the rule asks.
  - Today's figures ran on a loaded machine: four guests, two studios and a
    separate session were running. That load only slows the guest, since the
    macOS figure came from a quieter machine, so the ratio is a floor.
  - Candidate 1 was re-timed the same way on its own fresh worktree and took
    the same 11.3 s. Answering the plugins costs nothing at open.

Narrow go would have needed phase 3 to fail; it passed. No-go would have
needed a failed phase 1 or 2, or too little speed; neither happened.

## The scorecard

Filled from the phase findings. A dash means the row does not apply; *not
run* means it applies and nobody measured it.

| | 1 · guest, fakes | 2 · guest, studio answers | 4 · macOS window | 5 · simulator |
|---|---|---|---|---|
| first frame, clean build | ≈ 8–10 s: hooks, one compile, start — no native build | the same | 28.9 s | 40.9 s |
| first frame, build cached | 1.6 s, both people | 1.9–2.6 s, both people, in the pane | 11.2 s through Run; 0.6–1.3 s launched directly | 15.2 s through Run; 0.6–0.9 s directly |
| **open a two-person world from a cold worktree** | **9.1 s** (4.6 s seeded); 11.3 s under load | **11.3 s** (8.6 s seeded), under load | 31.6 s | 43.2 s, both devices booted |
| add a person while it runs | 0.7–1.7 s to draw, one more process on the same kernel; adding to a running world is not built | the same | 15.8 s through Run; about 1.9 s directly, with a bundle copied for isolation | 20.4 s on a booted second device; boot adds 15.1 s |
| hot restart | the same path as 2 | **330 ms**; **347 ms with new knob values**, 851 ms the first time | 318–359 ms | 303–324 ms |
| memory per person | 285 MB, plus one ~830 MB compiler per world | 235–243 MB, plus the same compiler | 304 MB; 1.3 GB with the `flutter run` that reloads it | 2.9 GB of device, plus 0.94 GB of `flutter run` |
| signed in against a real server, sync included | yes: the lab, and the consumer's app with its sync library | the lab, yes; the consumer's app not run, since it needs about 14 more answers first | the lab, yes; the consumer's app has a macOS runner but was not run | the lab, yes; the consumer's app not run |
| the human checklist (of 8) | **8** | **8**: the input path is the host's, the same for both | not run: the Mac's own input | not run |
| isolation per person | complete, through the project's fakes | **complete, without the app's help** | none by default; 0.06 s per person to buy, not built | complete: one device each |
| device controls: location, network, background | none built | background built; location one answer away; network not built | none | location and background through `simctl`; network machine-wide only |
| Run parity | as 2 | every tab and verb; reload and restart through the world. Run cannot change a guest's knobs | full | full |
| project-side lines | 70 for the lab's 7 plugins; 89 for the consumer's 8, and more per plugin after | **0** | a signing team, or a fake for secure storage | 0 |
| flutterware-side lines | the shared guest: about 1,800 lines of Dart, the lab pane and the harness among them, and 200 of C | that, plus the forwarding (96 C), the platform core (115), the registrant (61), and **18–60 per plugin** | 0 today; the strip and bundle copies not built | 0 today; a device per person not built |
| reach: macOS, Linux, Windows | macOS; Linux renders but is untried here; Windows not built | the same, and the clipboard is macOS only | macOS | macOS; Android emulators everywhere |

## What the decision says, and what it does not

**It says: the guest is the default device.** It is the only candidate
where all of these hold at once:

- a world opens in seconds from a cold worktree;
- every person is live on the canvas;
- people are isolated without the app's help;
- the studio sees and drives the platform: notifications posted and tapped,
  links opened, URLs caught, background.

The macOS window was the candidate the owner liked as a fallback. It keeps
that role for people on a Mac whose app has macOS support and a plugin no
answer covers yet.

**It does not say the guest carries every app.** Three limits are measured,
not guessed:

- **A plugin with a native half needs an answer.** It is written once, in
  flutterware, at 18–60 lines. The consumer's app reaches 21 such plugins;
  the lab's work answers 7. The biggest of the rest is sqflite, which needs
  the studio to run SQLite behind sqflite's own protocol.
- **Some things have no honest answer.** The camera, capture SDKs and
  Bluetooth are the design's *device as an input*, and a person who needs
  them runs on a device.
- **The picture is the Mac's.** Layout matches a simulator's; text renders
  in the Mac's system font. That is good enough to use a world, not good
  enough to review a design.

**Where it leaves open questions.**

- **Changing a guest's knobs from Run** (phase 4, finding 5). The world does
  not need it: it owns each person's knobs, and it restarts a person's app
  with new ones in place (below). Recommended: leave Run's `setKnobs`
  refusing a guest, and have its sentence name the world's restart; add a
  knobs door for launchers only when something outside a world needs one.
  The owner agreed, before slice 0.
- **A guest on Linux and Windows.** On Linux the host renders (Previews
  uses it) but no phase ran a world there. Linux needs two things before it
  can: a clipboard, and a home per person through the XDG variables rather
  than `CFFIXED_USER_HOME`. Windows waits for its embedder host.

## Measured in this phase

Two scorecard rows would have rested on assumptions without these.

### A guest restarts with new knob values

The plan assumed every candidate restarts a world "by hot restart with new
knob values", so restart would not discriminate. A guest could not do that
yet: it read its knobs from its environment at start, and a restart keeps the
environment. Now the generated entry reads them from a file of that person's
each time `main` runs (`AppGuestBuild.writeKnobs`). The world writes new
values, and restarts that person's app in place through the same
`_flutter.runInView` as phase 4.

Driven in the lab, a world restart works:

- the server's admin API made a new user;
- Leo's app restarted as that user, signed in with the new session, with no
  orders — **851 ms**, including bringing the other three people to the same
  code first;
- Sam's app restarted as "Samuel" in **347 ms**;
- the others were untouched throughout.

The *World lab* pane has a knobs field and *Restart with these knobs* beside
each phone for this.

### Candidate 2 opens as fast as candidate 1

`cold_open.dart guest --studio-answers` times candidate 2 on a fresh
worktree, as phase 1 timed candidate 1. Same steps, same result (above).
Registering the plugins' real Dart halves adds nothing measurable to the
compile.

## What changes

- **The design** (`2026-09-25-worlds-design.md`) is amended:
  - its decision line;
  - where a person's app runs, and what a guest costs and cannot do;
  - restart for a guest;
  - the canvas's promise about off-screen guests, which the canvas must
    keep by pausing them (phase 4, finding 4);
  - the slices: the guest moves into slice 0 as the default, and slice 5
    becomes the live canvas.
- **The plan** records the outcome and carries the filled scorecard.
- **Kept, as the plan promised whatever the outcome:** `host.c` failing fast,
  the clipboard, the lab's server and app, and the baselines.
- **Cleaned up since:** `host.c` left `flutter/keyboard` unanswered until
  the guest keyboard reclaimed its handler itself. That fix landed on master
  (#386); with master taken, the exception is gone and the input probe
  passes — typing, backspace, the caret and the wheel.
