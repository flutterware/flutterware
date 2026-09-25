# Worlds guest experiment — phase 1: a real app in a guest

**Date:** 2026-09-25
**Plan:** `2026-09-25-worlds-guest-experiment-plan.md`, phase 1. Baselines:
`2026-09-25-worlds-guest-phase0-findings.md`.
**Result:** phase 1 passes — the first kill point is cleared by both apps.
The lab's customer app runs its own `main` in embedded guests, signed in
against the real server, live updates over its socket, all ten plugins
answering; it opens a two-person world **9.1 s** from a cold worktree
(**4.6 s** with the machine's seed kernel), against 31.6 s for macOS windows,
so the speed clause holds with room to spare. The consumer's mobile app,
unchanged, signs in against its local server and shows its home screen with
data its sync library pulled — **3.9 s** after the worktree's work started,
signed in and synced about a second later — from a guest entry point and 89
lines of fakes.

## What was built

- **`app/native/host.c`** — the fix the July findings named. A platform task
  runner of the host's own: the main loop polls the socket and a wake pipe
  with a timeout of "until the next platform task is due", and runs the
  engine's platform tasks on time. Every platform message is then answered
  empty, which Dart reads as `MissingPluginException`, and each channel is
  named on stdout the first time it is used. The host also tells the engine
  the device's locales (`FW_GUEST_LOCALES`, else `en-US`).
- **`app/tool/embedder/run_app.dart`** — the harness. It builds a package's
  assets (build hooks included), compiles one kernel for a generated entry,
  and starts one guest per person, timing each step. `--hold` keeps them up;
  `kill -USR1` photographs every guest, `kill -USR2` recompiles what changed
  and hot-reloads every guest from the one delta.
- **The generated entry** — Run's own `runGuest` around the app's real
  `main`, so a guest carries the same drive, inspection and log extensions as
  an app Run launched, plus Previews' guest keyboard and text input. Around
  them, a binding of the guest's own, created inside the log zone `runGuest`
  opens (it does not nest, so any flutterware with the guest plumbing takes
  it). Knobs come from the environment at run time and reach `main` by name.
- **`fixtures/world_lab/app/guest/fakes.dart`** — the lab's plugins,
  replaced at their platform interfaces: 70 lines for 7 plugins.
- **`cold_open.dart guest`** — the cold-worktree measure, with this
  checkout's harness standing in for the studio.

## The lab, measured

| | guest | macOS windows | simulators |
|---|---|---|---|
| **two-person world, cold worktree** | **9.1 s**; **4.6 s** seeded | 31.6 s | 43.2 s |
| of which: resolve, hooks, build or compile | 1.0 + 1.8 + 5.5 s (seeded: 1.2 s compile) | 1.3 + 27.4 s | 1.4 + 37.4 s |
| of which: start both until drawn | 0.7 s | 2.8 s | 4.3 s |
| two-person world, warm worktree | 1.6 s | 11.2 s a person through Run | 15.2 s a person through Run |
| hot reload after an edit | **150–160 ms for both people**, one 35–40 ms compile | — | — |
| hot restart | — | 318–359 ms | 303–324 ms |
| memory, at rest | 285 MB a person + 837 MB for the one compiler | 305 MB + ~430 MB of tool a person | 270 MB + ~430 MB of tool + ~2.8 GB a simulator |
| CPU at rest | 0 % | 0 % | 1.8 % |
| plugins answering (of 10) | 10 — 7 faked, the rest real | 9 | 10 |
| signed in against the real server | yes, by the `session` knob; an order advanced by staff arrived live | yes | yes |
| isolation per person | complete: a home directory each, in-memory preferences and keychain | none by default | complete |

`sqlite3` loaded its native library through its build hook with nothing
done for it; HTTP and the socket are `dart:io` and simply work. A seed is the
studio's own machine-level kernel of the half of a program under the SDK and
the pub cache (`app/lib/src/embedder/seed_kernel.dart`) — what a machine that
has opened the project before holds.

## Findings

### 1. An unanswered platform call now fails at once, and says where

With a platform task runner serviced, the host sees every platform message,
and answering empty turns a missing plugin into a `MissingPluginException`
with a stack — the consumer's first boot stopped at
`PackageInfo.fromPlatform` inside its system-info loader, named, in under a
second. Before, it hung. The framework's own messages (`flutter/isolate`,
`platform`, `navigation`, `processtext`) get the same empty answer, which it
tolerates — **but not `flutter/keyboard`**, corrected in phase 2: the
framework asks `getKeyboardState` at start and, on any answer, takes key
handling back from the guest keyboard, so every key from the studio was
lost. The host now leaves that one channel unanswered, as it effectively
always had, until the guest keyboard takes its handler back itself
(`2026-09-25-worlds-guest-phase2-findings.md`, finding 1). The smoke, unit
and integration embedder tests passed on the new host; they do not type.

### 2. One kernel serves every person

Knobs read at run time rather than written into the source (phase 0,
finding 4) make a second person a second process over the same kernel: 0.7 s
for both, in parallel. A reload compiles once and reloads every guest from
the same delta.

### 3. A guest has no safe areas unless something puts them there

`FlutterWindowMetricsEvent` has only `physical_view_inset_*` — no padding
field, in the vendored header or in the engine the SDK ships — and the
engine hands those to Dart as *view insets*, the keyboard's. Previews
already converts them above each entry. An app's own `runApp` has no such
place, so the guest's binding does it in `wrapWithDefaultView`, and the
app's title then sits below the status bar as on the simulator.

### 4. A real app needs the device's locales

The host never sent any, so the app saw the undetermined locale `und`, found
no localizations, and its first frame was the red error screen. The lab app
has no localizations and never showed it.

### 5. A plugin with no platform interface can still be faked — through the messenger

`flutter_timezone` and a support-chat SDK call a `MethodChannel` directly,
so no Dart fake can take their place. The guest binding's messenger answers
channels a project names (`answerChannel('flutter_timezone', …)`) and passes
everything else to the platform. This keeps candidate 1 — fakes in Dart —
viable for them; what it cannot reach is a plugin whose Dart side needs a
native implementation to exist at all (finding 7).

### 6. The picture

Once safe areas are padding, the layout matches the simulator's, compared
by eye at full resolution. The text does not: the guest renders the Mac's system font
through the Mac's text stack, and tab labels read semibold where the
simulator's read medium. Good enough to use a world; not a design review.

### 7. The consumer's app, first run

Its mobile entry point, unchanged, with its knobs, on its own flutterware:

1. My harness passed a `person` knob its `main` does not declare — knobs are
   now passed only when named.
2. Package info, device info (on a Mac it asks for the Mac's), the time zone
   (no interface — a channel answer), Firebase core, paths, preferences (the
   legacy store and the async one) and secure storage: 74 lines of fakes for
   7 plugins, all before `runApp`.
3. The locale (finding 4).
4. Its first screen, onboarding, drawn **1.4 s** after the guest started.

Three more plugins go unanswered after the first frame without blocking it:
app links' event channel and the support-chat SDK, both a few lines each;
and sqflite, which an image cache opens a database through. Its Dart side
only exists once its native plugin has registered, and the project depends
on no FFI implementation to put in its place. That one is candidate 2's to
answer (phase 3), or a dev dependency.

Costs on the way: its build hooks took **51 s** the first time — any
candidate pays that on a cold worktree, native builds included — and a cold
compile 17.2 s (the lab's: 5.5 s), 2.5 s warm.

Three things this run showed about the plan itself:

- **The consumer's scenario fakes do not transfer.** Its scenario harness
  replaces services by constructor — authentication, API clients, the
  database — which is a fake backend, not a fake platform. A world runs the
  real `main` against the real server, so the fakes were written anew at the
  platform interfaces; only the package-info mock was in common.
- **The current flutterware breaks it.** Pointed at this checkout, its devbar
  panels failed to compile: the devbar now takes `material_ui`'s `Tab`, and
  they pass Flutter's. So the guest ran on the project's own, older
  flutterware — which the entry is written to allow.
- **Its SDK is newer than the guest's engine.** It pins 3.48.0-0.5.pre; the
  harness ran it on this checkout's 0.2.pre engine. It compiled and ran.

### 8. The consumer's app, signed in and synced

With its own stack up — containers, then its Dart server, both by its own
tooling — the guest ran its *local* mobile entry point, the one its Run
config already declares with knobs for the server's host and port and a
seeded account to start signed in as. Those knobs went in exactly as Run
passes them, read at run time. Two more things stood in the way:

- **The server refused the app** — `510: App update required: 1.0.0 <
  5.2.0` — because the package-info fake reported `1.0.0`. A fake that
  stands in for the platform has to tell the truth the server checks: the
  version came from the app's own pubspec. A studio-supplied package-info
  answer should read it from there.
- App links' event channel, answered by a fake like the lab's.

Then: the account loaded, the session database opened, the sync library's
native core — loaded through its build hook, as the lab's `sqlite3` was —
validated and applied its first checkpoint, and the home screen showed the
synced data. 89 lines of fakes for 8 plugins, a scratch file outside this
repository; no line of the app changed. The guest held 889 MB a few seconds
after start, twice the lab's — a larger app, not yet at rest.

## Open

- ~~Typing is broken in guests, before this work.~~ **Wrong, and corrected in
  phase 2.** The input probe's "master host" was a stale binary: the catalog
  compiler daemon builds the host once and serves it for its whole life, so
  reverting `host.c` changed nothing it ran. Typing broke because this
  phase's host answered `flutter/keyboard` (finding 1).

## Phase 2 starts from

The harness, the lab and its fakes, and the consumer's fakes kept outside
this repository. A guest now carries Run's drive extensions, so phase 2's
checklist can be run by the agent as well as by hand once the guest is
shown in a pane.
