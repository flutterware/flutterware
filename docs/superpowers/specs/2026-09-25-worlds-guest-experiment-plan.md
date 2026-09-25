# Worlds — settling the embedded guest, go or no-go

**Date:** 2026-09-25
**Question:** should a person's app in a world run, by default, in the
studio's embedded guest — live on the canvas, no native build — rather than in
a macOS window, a simulator or a phone? (`2026-09-25-worlds-design.md`, *The
device experiment*.)
**Answer:** not known. This is the plan that finds out: five phases, two kill
points early, a scorecard filled for every candidate, and three possible
outcomes decided before anything is measured.
**Status:** thresholds confirmed; phase 0 done (the bar: 15.8 s from a cold worktree); phase 1 passes for both apps — the lab at 9.1 s, 4.6 s seeded, the consumer signed in and synced; phase 2 passes, both kill points cleared (`2026-09-25-worlds-guest-phase2-findings.md`); phase 3 under way.

## What is actually in question

Previews already proves a guest can render a widget. A world asks four
harder things, and any one can fail on its own:

1. **A real app runs in a guest against a real server** — an app that
   stores a session, keeps a local database, syncs, notifies and opens links,
   not a widget handed its data.
2. **It is faster where it matters.** Every candidate restarts a world the
   same way, by hot restart with new knob values, so restart does not
   discriminate. What does is **opening a world from a cold worktree** —
   nothing resolved, nothing built — timed until every person's screen is
   showing, each candidate on its fastest path. That is the moment somebody
   waits through, and it counts everything a candidate needs on the way:
   resolving, build hooks, a native build or none, installing, starting.
3. **A human can use it all day.** Typing an email address, an accented
   letter through a dead key, pasting a code, selecting text, scrolling, and
   two guests side by side with typing going where focus is.
4. **The studio can stand in for the platform** — answer the native half of
   the common plugins — at a bounded cost per plugin. This is what would make
   isolation per person and control of the device uniform (design, *The
   device as an input*).

And two costs to weigh against the answers: **parity with Run** (logs,
network, inspection, panels, drive, unchanged), and **reach** (the guest runs
on macOS and Linux today; Windows is step 6 of
`2026-09-14-windows-support-plan.md`, not built).

## What exists today

- The guest is an out-of-process host embedding the engine: Metal into shared
  `IOSurface`s on macOS, OpenGL read back through shared memory on Linux, one
  Unix-socket control channel, pointer, key, wheel and trackpad input
  forwarded (`app/lib/src/embedder/README.md`).
- It runs catalog and scene entries, not an app's `main`.
- `app/native/host.c` sets no platform-message callback, so a platform call
  nothing answers **hangs forever** instead of throwing. The July findings
  name the fix: custom task runners so the platform thread is serviced
  (`2026-07-26-s1-scenario-in-embedder-findings.md`).
- Keys and text reach a guest through `GuestKeyboard` and `GuestTextInput`;
  **composition is still missing** — dead keys, CJK
  (`lib/src/ui_catalog/guest_text_input.dart`) — and so is the clipboard.
- The guest's `print` does not reach the studio.
- Run changes knob values by hot restart, 262 ms on macOS
  (`2026-08-12-run-knobs-spike-findings.md`), and drives apps through one
  verb engine that works over any VM service.

## The fixture

The first piece of the lab, `fixtures/world_lab/`, built for this experiment
and kept for the worlds after it:

- **a server** — small, in memory, an HTTP API, a socket for live updates, an
  endpoint that creates users, SMS and push adapters that report to
  flutterware;
- **a customer app** with the plugin profile of a real one, on purpose:
  `path_provider`, `shared_preferences`, `flutter_secure_storage`,
  `app_links`, `flutter_local_notifications`, `url_launcher`,
  `package_info_plus`, `sqlite3` (native library through build hooks), an
  HTTP client and a socket client.

A lab rather than only the consumer because its plugin profile is ours to
choose, plugins can be added to test one thing, and no consumer code enters
this repository. The consumer comes in once, at the end of phase 1, as the
confrontation.

## Phases

Estimates are for one person working through the phase; they are guesses,
recorded so an overrun is visible.

### Phase 0 — Baselines (½–1 day)

**Build:** the fixture, with a macOS and an iOS runner.
**Measure**, through today's Run, for a macOS window and an iOS simulator:
first frame from a clean build; first frame with the build cached; hot
restart; a **second instance of the same app** — on macOS, what the two share;
on the simulator, the time to clone and boot a second device; memory per
instance.
**Output:** the baseline columns of the scorecard.

### Phase 1 — A real app in a guest (≤ 2 days) — first kill point

**Build, the minimum:**
- run an app's `main` in the guest, through the run wrapper;
- `host.c` replies empty to any platform message it cannot route, so an
  unanswered call throws `MissingPluginException` rather than hanging;
- the fixture's plugins faked at their platform interfaces from a
  guest-only entry point — candidate 1, the scenario harness's precedent;
- the guest's `print` forwarded.

**Measure:** does `sqlite3` load through build hooks; does the socket
connect; first frame, cold and warm; hot reload and restart; memory; the
picture against the simulator's — fonts, and the iOS look through a platform
override.

**Confront:** the consumer's client app, locally and read-only — its
scenario harness's plugin fakes, its real sync library loading through build
hooks, against its local server. Count what blocks its first signed-in
screen.

**Passes if** both apps reach a signed-in screen against a real server, sync
included, with no change to app code beyond a guest entry point.
**If not: no-go.** Write the findings; keep the `host.c` fix, which Previews
wants anyway.

### Phase 2 — Can a human use it? (≤ 2 days) — second kill point

**Build:** a guest in a Run-like pane — no canvas needed yet.

**The checklist,** by hand and then by the agent through drive:
- type an email address;
- type *é* and *ü* through dead keys;
- paste a code with ⌘V, and copy text out;
- select text with the mouse;
- scroll with a wheel and with a trackpad;
- move between fields with Tab;
- two guests side by side: typing goes to the focused one;
- the app's shortcuts reach the app, not the studio.

**The two known gaps, and their likely fixes:** the clipboard, by answering
the clipboard's platform calls from the studio (a narrow case of phase 3's
forwarding); composition, by passing the studio's own input-method state —
the marked text its text field already receives — into the guest's text
client as a composing range.

**Passes if** every item works, or has its fix built inside the phase.
**If not: no-go as the default.** A world in which you cannot type *é* or
paste a code is not one people will open twice. Whatever input fixes landed
stay, for Previews.

### Phase 3 — The studio as the platform (≤ 3 days) — narrows

**Build:** `host.c` forwards platform messages over its socket; the studio
answers each channel with a Dart handler, through the standard codecs. Six
plugins — `path_provider`, `shared_preferences`, `flutter_secure_storage`,
`app_links`, `flutter_local_notifications`, `url_launcher` — plus the
clipboard and app lifecycle.

**Record, per plugin:** whether its macOS side speaks over a channel or calls
Apple frameworks directly (a direct call simply runs in the guest — and then
writes where the guest process writes, which breaks isolation per person);
lines; hours; whether the plugin's real Dart code ran unmodified; what the
studio can now show or control — a notification on the canvas, a link on the
plugin's own event channel, a permission switch, a directory per person.

**Passes if** the average is under ~150 lines and half a day per plugin, and
isolation per person comes without the app's help.
**If not: narrows** to candidate 1 — fakes only.

### Phase 4 — Parity and scale (≤ 1 day)

**Parity:** Run's Logs, Network, Screen, App and Steps tabs on a guest; drive
`act` and `observe` round trips against the macOS window's.
**Scale:** 2 and 4 guests — memory, CPU at rest and with one animating; a
guest off screen or drawn as a card stops producing frames, as the canvas
promises.

**Passes if** parity needs nothing beyond registering the guest as a device,
and 4 guests at rest stay under 2 GB together and 10 % CPU.

### Phase 5 — Decide (½ day)

Fill the scorecard; pick the outcome by the rule below; write the findings
next to this plan; amend the design — the default device, and the slices.

## The scorecard

| | 1 · guest, fakes | 2 · guest, studio answers | 4 · macOS window | 5 · simulator |
|---|---|---|---|---|
| first frame, clean build | | | | |
| first frame, build cached | | | | |
| open a two-person world from a cold worktree | | | | |
| add a person while it runs | | | | |
| hot restart | | | | |
| memory per person | | | | |
| signed in against a real server, sync included | | | | |
| the human checklist (of 8) | | | | |
| isolation per person | | | | |
| device controls: location, network, background | | | | |
| Run parity | | | | |
| project-side lines | | | | |
| flutterware-side lines | | | | |
| reach: macOS, Linux, Windows | | | | |

Candidate 3 — a macOS app rendering off screen into the studio — has no
column. It is measured only if the macOS window disappoints *and* candidate 2
fails.

## The rule, set before measuring

The owner confirmed these thresholds on 2026-09-25, before phase 0, and after
it fixed the speed clause's measure: a cold worktree, every candidate on its
fastest path. Phase 0 had shown that a clause with builds cached, or one about
adding a person, is decided by which native path it is compared against — a
built app starts in about a second, and through `flutter run` in eleven.

- **Go** — the guest is the default for every person whose app it can carry:
  phases 1 to 4 pass, and it opens a two-person world from a cold worktree at
  least twice as fast as the faster of macOS windows and simulators.
- **Narrow go** — phases 1 and 2 pass, phase 3 does not: the guest with Dart
  fakes, for people whose app carries few plugins — a dashboard, a console —
  and macOS windows for the rest.
- **No-go** — phase 1 or 2 fails, or the speed is not there: macOS windows
  with the strip are the default; the guest stays with Previews and the scene
  canvas; the canvas draws every person as a picture, which its layout
  already allows.

## Kept whatever the outcome

- `host.c` failing fast, and any clipboard and composition fixes — Previews
  has wanted them since July.
- The baselines, which slices 0 to 2 of the design use as they are.
- The lab's server and app, which host the worlds from
  `2026-09-25-worlds-paper-cases.md` next.

## Not in this experiment

Candidate 3 unless triggered; the guest on Windows; people in a browser; the
canvas itself.

**Total:** 7 to 9 days, with the first kill point at about day 3 and the
second at about day 5.
