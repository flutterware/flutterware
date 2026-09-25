# Worlds guest experiment — phase 0: baselines

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 0.
**Machine:** Apple M4 Max, 64 GB, macOS 26.2, Xcode 26.2, Flutter
3.48.0-0.2.pre (the `.fvmrc` pin). The iOS simulator is an iPhone 16 on iOS
18.1.
**Result:** the baseline columns are filled, and the speed bar is set: a
guest goes only if it shows a two-person world within **15.8 s** of a cold
worktree, half of macOS windows' 31.6 s.

## What was built

`fixtures/world_lab/`, two workspace members:

- **`server/`** — a coffee shop's pickup orders, in memory, on shelf. An admin
  endpoint creates users with a session in one call; sign-in is by a code
  sent through an SMS edge; staff move an order along and the customer is
  told through a push edge. Both edges report to flutterware as `sms` and
  `push` events and name the resolved recipient. A socket at `/live` pushes
  order changes to every app allowed to see them.
- **`app/`** — the customer app, with macOS and iOS runners and the plugin
  profile the plan chose. `lib/src/plugin_check.dart` touches all ten plugins
  once at boot, times each, and prints how it went; `main` prints the absolute
  time of its first frame. Knobs: `server`, `session`, `person`.

The root config declares the app twice, *Lab · Ana* and *Lab · Leo*: a run is
keyed by its entry point, so two people on one device need two names.

Checked end to end on a simulator, by drive: Leo signs in with the code the
SMS edge carried, orders a flat white, a staff user seeded through the admin
API advances it twice, Leo's screen shows `ready` without a refresh, and the
push edge reports `push to u3`.

## How it was timed

Run writes the moment it spawns `flutter run` into the handle as `startedAt`
(`app/lib/src/run/launch.dart`), and the app prints the wall-clock time of its
first rasterized frame. The difference is the launch as a person would feel
it, with no clock of flutterware's own in between. Hot restart is the `ms` the
`restart` action reports. Launches outside Run were timed from `exec` (macOS)
or `simctl launch` (simulator) to the same printed frame. Memory is the
physical footprint (`footprint`), with resident size beside it.

## The baseline columns

| | 4 · macOS window | 5 · simulator |
|---|---|---|
| **open a two-person world from a cold worktree** | **31.6 s** | **43.2 s**, both devices already booted |
| first frame, clean build | **28.9 s** | **40.9 s** (26.7 s of it Xcode) |
| first frame, build cached, nothing changed | **11.2 s** | **15.2 s** (7.7 s of it an Xcode build with nothing to do) |
| first frame, build cached, after a Dart edit | 14.8 s, 14.8 s | — |
| first frame, build cached, the other person built last | 15.8 s, 16.1 s | 17.8 s |
| add a person while it runs, through Run | **15.8 s** | **20.4 s** on a second simulator already booted |
| add a person, built app launched directly | **0.6–1.3 s** from `exec` | **0.6–0.9 s** from process start, on a booted device |
| a second simulator, made and booted | — | create 0.2 s, boot to ready **15.1 s**, install 3.4 s |
| hot restart | 359, 357, 318 ms | 324, 308, 303 ms |
| memory per person, the app | 303–327 MB (362–482 MB resident) | 270 MB (595 MB resident) |
| memory per person, the rest | ~430 MB for its `flutter run` and frontend server | the same, plus ~2.8 GB for a second booted simulator (the rise in used memory, rough) |
| CPU at rest | 0 % | 1.8 % |
| signed in against a real server | yes — HTTP and socket | yes, end to end, above |
| plugins answering (of 10) | **9** — secure storage cannot work, below | **10** |
| isolation per person | **none**, by default; 0.06 s to buy, below | complete: one device each |
| project-side lines | secure storage, below | 0 |
| flutterware-side lines | 0 | 0 |
| reach | macOS hosts | macOS hosts |

Not measured in phase 0: the human checklist (phase 2), device controls, and
Run parity beyond launch, restart and drive, which all worked. The sync
library is the consumer's and comes in with phase 1's confrontation; the lab
has none.

## The cold-worktree measure

Added after phase 0 first reported, when the owner fixed the speed clause:
from a worktree where nothing is resolved and nothing is built, how long
until both people's screens are showing, each candidate on its fastest path.
`fixtures/world_lab/app/tool/cold_open.dart` times it, on a worktree checked
out fresh; phase 1 adds the guest to the same script.

| step | macOS windows | simulators |
|---|---|---|
| resolve (`flutter pub get`, the whole workspace) | 1.3 s | 1.4 s |
| build, debug, one for both people | 27.4 s | 37.4 s |
| a bundle id for the second person | 0.1 s | — |
| start both, until both have drawn | 2.8 s | 4.3 s, installing included |
| **both screens showing** | **31.6 s** | **43.2 s** |

The machine is warm: the pub cache, the SDK's artifacts and, for the
simulators, both devices booted — a shut-down one adds its 15 s. The fastest
path is a build and then direct launches, not a `flutter run` per person, so
neither person can hot restart until something attaches the tool; the guest
column is measured with the same allowance.

**The bar this sets:** macOS windows are the faster native candidate, so the
guest goes only if it shows both screens within **15.8 s** of a cold
worktree.

## Findings

### 1. Almost all of a launch is the tool, not the app

A built macOS debug app reaches its first frame 0.6–1.3 s after `exec`; the
same app through `flutter run`, with nothing changed, takes 11.2 s. The
simulator is the same shape: under a second from process start, 15.2 s
through Run. The difference is a dependency resolve (0.9 s), an Xcode build
that finds nothing to do (7.7 s on the simulator), the install, the attach
and the first sync of the Dart code.

So *adding a person* is cheap on both candidates **if a world launches a
built app itself** rather than asking `flutter run` once per person. Such a
person is still drivable — a debug app prints its VM service address with or
without the tool — but reload and restart belong to the tool, and what
`flutter attach` costs to win them back is not measured yet.

### 2. Two macOS windows of one app share everything

A sandboxed macOS app's container is keyed by its bundle id, so every
instance reads and writes the same preferences, files and database. Measured:
Ana's window, Leo's window and three direct launches all reported the same
install id, one launch counter that counted across them, and one SQLite file.
Two people signed in as two users would overwrite each other's session.

Buying isolation is cheap. A copy of the built bundle — an APFS clone — with
its `CFBundleIdentifier` rewritten and an ad-hoc re-signature took **0.06 s**;
it got its own container (a new install id, launch 1, its own database) and a
first frame 1.85 s after `exec`, the extra second being macOS creating that
container. Two things follow: links by URL scheme reach whichever copy
LaunchServices picks, so the world has to route them itself (as the design
already says); and notification permission is per bundle id, so per person.

The simulator needs none of this: one device per person is complete isolation,
paid for in a 15 s boot and ~2.8 GB.

### 3. Secure storage cannot work in a macOS window without a signing team

The plugin's macOS default is the data-protection keychain, which needs a
`keychain-access-groups` entitlement that only a provisioning profile grants.
A `flutter create` runner is signed to run locally, so every call fails at once
with `-34018`. The alternative, `usesDataProtectionKeychain: false`, works
once and then binds the item to the app's ad-hoc signature — which every
rebuild changes. On the next launch after an edit, the read never answered,
and the `SecurityAgent` process — the one that draws keychain prompts —
started the same second; the screen could not be captured from the shell, so
the prompt itself was not seen. Nobody can live with that in a loop.

The lab keeps the default and fails fast; the app signs in through its
`session` knob anyway. For a project, this is the first entry in the
macOS-window column's *project-side lines*: a signing team, or a fake for
secure storage on macOS. It is also what a guest would face if its
secure-storage calls reached the real keychain; phase 3 answers them in the
studio instead.

### 4. Run bakes knob values into the wrapper, so switching person rebuilds

The generated `.dart_tool/flutterware/run/main_guest.dart` passes the knobs
as literals (`entry.main(person: r'Ana')`). Two people on one app therefore
compile two different programs into one build folder, and each launch after
the other person's rebuilds the app: 15.8–16.1 s on macOS against 11.2 s
unchanged, 17.8 s against 15.2 s on the simulator. A world where every person
runs the same app pays it on every launch. Knobs read at run time — from
arguments or the environment — would remove it, and would also be what a
directly launched person (finding 1) needs.

### 5. Two runs of one file on one device share a report id

*Lab · Ana* and *Lab · Leo* on macOS both appear as `app-544f2d57fb1c` in
Run's report and in their capture addresses
(`fw:///…/flutterware.run/app-544f2d57fb1c/steps/…`), though their run keys,
journals and screenshots are separate. Selecting by entry-point name works:
restart and drive each reached the right window. The collision will matter
the moment a canvas addresses people by that id.

### 6. Every person through Run carries its own tool

Five runs were up at the end — four lab apps and the studio — with 17
`flutter_tools` and frontend-server processes between them, 2.2 GB resident:
about 430 MB a person before the app itself. A world of four people on macOS
windows is about 1.2 GB of apps and 1.7 GB of tooling.

## What this changes

*Resolved:* the owner chose the cold-worktree measure above, which compares
every candidate on the moment a person actually waits through. The paragraph
below is kept as the reason the question was asked.

**The rule's speed clause needs its macOS baseline named.** The confirmed
rule says *go* if a guest opens a two-person world at least twice as fast as
macOS windows, or adds a person in under 3 s against 10 s or more. Through
Run, macOS windows take 11–16 s a person, and the guest would clear both bars
easily. Launched directly from one build (finding 1), they add a person in
about a second, and no guest will be twice as fast as that. Which macOS
path the guest is measured against decides the speed question before phase 1
runs. The honest one is the direct path, since a world would use it; that
moves the guest's case from speed to what the direct path does not give — a
screen live on the canvas, isolation and device control without a copied
bundle, and no signing team.

**The macOS window got both better and worse.** Better: a person costs about a
second and 0.06 s of isolation. Worse: a project whose app never shipped on
macOS has to make its plugins work there, and secure storage cannot without a
team (finding 3).

**Two Run changes serve every candidate**: knobs read at run time (finding
4), and a report id that includes the entry point (finding 5).

## Phase 1 starts from

- `fixtures/world_lab/`, and its server on :8090 (`fvm dart run bin/server.dart`
  in `server/`).
- The macOS build folder and the iOS simulator build, both current.
- A second simulator, *Lab Leo* (`7291195E-B56C-4677-84EA-11ADA83D1942`), shut
  down and kept for the side-by-side cases.
