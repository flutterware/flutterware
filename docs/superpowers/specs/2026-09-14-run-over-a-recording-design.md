# The Run plugin over a recording — the last panel on the web demo, and in the studio's own scenarios

**Date:** 2026-09-14
**Question:** every other entry in the rail runs over a recording of the demo
app (`2026-09-10-studio-over-a-fake-project-design.md`). Run is the one left,
and the original table filed it under *not worth recording: its subject is a
live process*. Is there a seam that lets the cockpit run over recorded data
without lying, that makes the code better on its own, and that stays small?
**Answer:** yes. Most of what the cockpit shows was already written to disk
once by the tool itself — the handle, the launcher's log, the drive journal
with a picture and a tree per step — and the rest is a handful of answers a
recorder can ask a real run for. The seam is not an interface on the core (the
panel reads ~36 of its members; same conclusion as scenarios) but three doors
under it, two of which already exist as test hooks. The recording is a real
session driven on a real simulator, and it costs ~30s warm.
**Decision:** build it in the slices at the end. Refuse everything live with a
sentence; record the four tabs that are files or one reply each; leave the
Network tab live-only.
**Status (2026-09-22):** the demo half is built — slices 1 to 5 in their
demo-facing parts, on one branch. The test-facing cleanup of slices 1 and 2
is not; see *Built* at the end.
**Method:** a read of the plugin, its panel and its tests; the earlier slices'
patterns; and one measured session — the demo app's devbar entry point
launched on an iPhone 16 simulator through the run plugin, driven for five
steps, its panels and device settings read, stopped, and launched again warm.

## What the cockpit reads, and what backs it

| what the panel shows | backed by | live touch |
|---|---|---|
| the rail row, the header, the launching pane | `app-*.json` handles, `*.log` launch logs, failure files | files in the run dir |
| Steps tab | `*.journal.jsonl` and `journal/<key>/<stamp>.{png,tree.json,texts.json,semantics.json,capture.json}` | files, `Image.file` |
| Logs tab | the launch log, tailed with a directory watch and a poll (`FileRefresh`) | files |
| Screen tab | one `InspectRead` per read — tree, screenshot, semantics | VM service websocket |
| App tab | a channel attach — hello, panel list, states, knobs, feeds — plus `flags.json` | VM service, files |
| Network tab | `getHttpProfile` polled, details by id | VM service |
| device strip | `simctl` or `adb` through `NativeSession` | processes |
| the desk, the new-run page | `devices.json`, then a `flutter daemon` lease | file, process |
| Knobs tab, flavors | the entry point's source and `pubspec.yaml` | project files |
| probe | pid liveness and one VM round trip | process, socket |
| Start, reload, restart, stop, boot, apply knobs, the drive verbs | `flutter run --machine`, VM RPCs, the daemon, the guest | processes |

Two readers outside the plugin bypass the core: `DeskButton` in the chrome
scans the run dir on a static path of its own every two seconds, and
`WorktreeHome` scans handles and runs its own `probeRunHandle`.

**The seams already half drawn.** `RunCore` carries a static `runDirProvider`,
a static `debugLive`, and `debugRead`, `debugControl`, `debugAct`,
`debugSetProbe`, `debugEmulators`, `debugNativeAvailable`,
`debugRepoWorktrees`. `NetworkTab` and `PanelsTab` take a `connect:`
function. The panel test stages a run by publishing a handle into a temp run
dir, setting a probe and a read, and turning `debugLive` off in `setUp` — and
resetting three statics in `tearDown`. That is eight doors to four rooms, and
the statics leak across scenarios that share one process.

## The design: three doors under the core, everything else refuses

No interface on the core. The panel keeps calling `RunCore`; the core takes a
`RunSources` — the shape `ChangesSources` has on the shell — with:

- **`files`** — the run dir as an interface: list handles, read text, read
  bytes, an `ImageProvider` for a path, a watch that may be empty. Same move
  as `SplashFiles` and `ChangesFiles`. Every free function that takes a path
  today reads through it: `scanRunHandles`, `DeviceCache.read`,
  `scanRunFailures`, `LaunchLog.read`, `readRunLog`, `RunLogTail`,
  `FileRefresh`, `readJournal`, `FlagMemory`, and the steps tab's
  `Image.file`. The live end is the disk under `flutterwareRunDir`; the
  recorded end is the recording, exactly the `artifacts:` door the scenarios
  panel already has. This kills both static `runDirProvider`s.
- **`apps`** — `probe(handle)` and `read(handle)`, replacing `debugRead` and
  `debugSetProbe`. The live end is `probeRunHandle` and `_withInspector`; the
  recorded end answers the probe as *app up, launcher gone* and reads the
  last journal step's artifacts, which are already an `InspectRead` on disk.
  `RunConnection.connect` (`vm_service_io`) and `isProcessCurrent` (`dart:io`)
  move behind the live end, which is where they belong.
- **`channels`** — `attach(handle)` returning the seven members
  `ServerAttachment` already has (`hello`, `received`, `events`,
  `replayComplete`, `done`, `request`, `details`, `close`). `RunChannelClient`
  implements it; the recorded one is a finished replay that answers each
  `channel/method` from a file, the same class the server slice wrote. This
  replaces `PanelsTab`'s `connect:`. `RunPanels` is typed on the interface.

Everything else refuses with a sentence — the same sentence *Compare again*
gives over the recorded branch:

- `launch`, `applyKnobs`, `bootEmulator`: a `launcher`/`devices` that is null
  in the sources. No daemon interface: the desk reads `devices.json` through
  `files` and shows it with its age, which is a state it already draws.
- `control` for reload, restart, stop: the recorded probe says `launcher:
  false`, and the header already renders that as *no launcher — cannot
  reload* with the buttons hidden. That is the surviving half of the two-tier
  split, and it is the truth about a recording: the app can be looked at, not
  reloaded.
- The device strip: `NativeSession` behind a factory that is null in the
  sources, so `_deviceSettingsFor` throws its existing refusal and the strip
  prints it. Not hidden — hiding it is a design change.
- The Network tab: keeps its `connect:`; the recorded panel hands it one that
  throws *this is a recording*, and its existing failure state says so. Not
  recorded, because the demo app makes no HTTP call and there would be
  nothing to show.
- The drive verbs over a recorded run (`act`, `observe` from `fw` or MCP):
  refused. The studio's own scenarios drive the *studio*, not the recorded
  app.

**`debugLive` becomes derivable.** A core whose sources have no daemon, no
launcher and no native factory is what `debugLive = false` meant. The static
goes; the panel test passes a `RunSources` with memory ends. The probe timer
and `FileRefresh` take their interval from the sources, and the recorded ones
say zero — the splash slice's `pollInterval: Duration.zero`, for the same
reason: nothing under a recording moves, and a periodic timer that calls
`setState` is a frame every tick, which a walk under FakeAsync never settles
past. The screen picture's one-second age tick reads the pinned clock and
does not tick under a recording.

**The two outside readers.** `DeskButton` takes the shell's `RunSources.files`
instead of its own static. `WorktreeHome` probes through `core.sources.apps`
instead of calling `probeRunHandle` itself — one prober, not two.

**Why not replay at the VM-service level.** The tabs' tests fake a whole
`VmService` with a JSON-RPC responder, and the server slice recorded the
wire's own shapes on purpose. But the inspector protocol's object groups and
ids are Flutter's framing, not ours: a Flutter upgrade would stale the
recording with nothing to catch it. `InspectRead`, the journal, and the
channel answers are formats this repo owns or already persists.

## The recording

**A real session on a real simulator, driven by the tool's own commands.**
`record.dart --only=run` boots an iPhone 16 with `simctl` (5s), launches the
demo app's devbar entry point through the run plugin, drives it — welcome,
the menu, a cappuccino, the size, the cart — through the real `act`, reads
the devbar panels and the device settings over the real connection, stops
the app, and copies that run's files out of the run dir. Nothing is written
by hand. Measured 2026-09-14 on this machine:

| stage | time |
|---|---|
| boot the simulator | 5s |
| cold launch, iOS build included | 75s |
| warm launch | 21s |
| one drive step, tap and settle | 0.4–0.6s |
| panels read, device settings read | under 1s each |
| stop | 30ms |

About 30s warm, 90s cold, beside the scenario part's 13s. The recorder
drives through the shipped `fw run` actions rather than `RunCore` in-process:
the core is Flutter-typed and the recorder runs under `dart`, and the
scenario recorder already set the precedent of running the tool rather than
its internals.

What it holds, under `run/`:

| file | what | from |
|---|---|---|
| `root.devices.json` | the device list the desk shows, with its age | `devices.json`, verbatim |
| `root.runs.json` | the recorded runs by key | the handles |
| `<key>.handle.json` | the handle | `app-<key>-<pid>.json` |
| `<key>.log` | the launcher's log | the `.log` file, verbatim |
| `<key>.journal.jsonl` | the session | the journal, paths re-rooted |
| `<key>/<stamp>.{png,tree.json,texts.json,semantics.json,capture.json}` | one step's artifacts | copied in |
| `<key>.channels.json` | hello, panel list, states, knobs, feed items, answers by `channel/method` | the `panels` action's replies |
| `<key>.device.json` | the settings list as read | the `device` action's reply |

Measured on the five-step session: 324 KB of artifacts (screenshots 15–35 KB,
trees 12–58 KB, semantics ~2 KB each), a 7 KB log of 85 lines.

**What varies between two recordings, and how each is pinned.** This part is
handled more carefully than the scans, because it is a session on a machine:

- Timestamps in the handle, the journal and the log — re-rooted to the
  project clock, as the server ring is.
- Pids and the VM service URI — replaced with fixed values; nothing in the
  recording dials them.
- The simulator's udid, which is the device id everywhere — replaced with the
  device's name.
- Absolute paths in the journal, the handle and the log — re-rooted under
  `/recording`, as the scenario run's are. The log is rewritten for its
  paths only; its lines stay the tool's.
- The log's first fifty lines are a `pub get` narration listing every package
  with a newer version available. That text tracks pub.dev, so a log never
  re-records byte-identical.
- The screenshots — real device pixels, stable on one machine and one Xcode,
  not across them.

So this is a **pixels part**: recorded from one machine, committed, and never
re-recorded by CI — the status store, translations and the scenario run
already have. The recorder boots the simulator itself, so the prerequisite is
a Mac with Xcode, which the pixels parts effectively require already.

**The recorded manifest** declares `Run` with the two entry points the demo
app declares, so `computeAll` never walks `lib/`. `defaultFlavorOf` reads
`pubspec.yaml` and the knob reader parses the entry point's source; both
answer nothing on `UnsupportedError` rather than throw, and the Knobs tab
shows only declared knobs over a recording — which is all the demo app has.

## What it shows, and how it is tested

**The web demo.** Run in the rail with one row, *Brewline (devbar) · iPhone
16*, landing on the Screen tab: the cart on a phone, the elements tree, the
semantics. Steps: the five-step session, each with its shot. Logs: the real
launcher log. App: the push panel — its inbox, registration, permission knob
and send action, with the action refused. Knobs: the declared knobs. The
device strip prints its refusal. The header says *no launcher — cannot
reload*.

**The studio scenario** (`app/test/scenarios/studio/studio_test.dart`): *A
recorded run* — open Run, the run's row, Steps, one step opened, Logs, App.
Under FakeAsync over the file end, which is why no timer may run.

**The browser walk** (`app/integration_test/web_demo_test.dart`): one stop —
Run, the run, Steps, a step — checking the picture loaded and no request
failed.

**The panel tests** (`app/test/plugins/run_panel_test.dart`,
`run_core_test.dart`, `run_steps_test.dart`, `run_act_test.dart`) move from
the statics and `debug*` hooks to a `RunSources` with memory ends. The channel
client's own tests keep their fake `VmService`.

## Slices

Each slice is one PR, green on its own, and the first three improve the tree
with no recording behind them.

1. **`RunFiles`.** The interface, the live end, every path-taking read
   routed through it, both static `runDirProvider`s deleted, `DeskButton` on
   the shell's sources, `FileRefresh` and the probe timer on intervals the
   sources set. Tests: the panel and core tests on a memory end; the existing
   suite green. *Buys:* the rail row, header, Steps, Logs, the failure page and
   the desk over any `files` — but nothing recorded yet.
2. **`RunApps` and `RunChannels`.** The two doors, `debugRead` /
   `debugSetProbe` / `PanelsTab.connect` deleted, `debugLive` deleted,
   `WorktreeHome` probing through the core, `RunPanels` on the attachment
   interface. Tests: the same, over fakes of the two doors. *Buys:* the Screen
   and App tabs over any source.
3. **Refusals.** Null `launcher`, `devices` and `native` in the sources;
   `launch`, `applyKnobs`, `bootEmulator`, `control` and the drive actions
   refuse with a sentence; the Network tab's connect refuses. Tests: one per
   refusal.
4. **The recording.** `record.dart --only=run` as described; `RecordedRunSources`
   in `app/lib/src/demo/recorded_run.dart`; the recorded manifest declares
   `Run`; the fixture committed. Tests: `recorded_project_test` opens the run.
5. **The scenario and the browser stop.** *A recorded run* in the studio
   scenario, the walk's stop, the CI job unchanged (a pixels part is not
   re-recorded).

## Not in this design

- The Network tab over a recording — nothing to show for the demo app.
- A daemon interface — the cache with its age is the honest desk.
- A native interface — the strip's refusal is the honest strip.
- Driving a recorded app — the verbs refuse.
- The source-parsed knobs over a recording — the demo app declares none.

Related: `2026-09-10-studio-over-a-fake-project-design.md` (the recording
system, and the server slice this follows), `2026-07-31-run-cockpit-panel-design.md`
(the tab strip), `2026-08-11-run-drive-design.md` (the journal this replays).

## Built (2026-09-22)

The web page and the studio's own scenario both open the recorded run: the
rail row *Brewline (devbar) · iPhone 16*, the header's *no launcher — cannot
reload*, the Screen tab on the session's last picture with its elements and
semantics, eight steps with their pictures, the App tab's push inbox, and
the launcher's log. The studio scenario *A recorded run* takes 1.8s for seven
steps; the browser walk has a stop for it; all thirteen studio scenarios, the
app suite and the walk pass.

**Where the build departed from the design, and why.**

- **`RunFiles` has no image in it.** The cores run under `fw`, in plain
  Dart, so the store is bytes, text, a listing, a write and a change stream.
  The panel takes a `RunImage` function instead — the launcher icon, store
  and splash panels' pattern — and the recorded one is the recording's own
  `encodedImage`. The store also took `FileRefresh`'s job: `changes(path)`
  is the watch-and-poll on the disk and an empty stream over a recording,
  which is what keeps a studio scenario settling. `file_refresh.dart` is
  gone.
- **The recorded store preloads.** The readers are synchronous and the
  recording's HTTP end is not, so `RecordedRunFiles` fetches the whole run
  dir once (`ready`, which `computeAll` awaits). 44 files, 696 KB.
- **One read-only door rather than null doors.** `RunSources.readOnly` is a
  sentence; the core's action dispatch refuses every action that launches,
  reloads, boots, drives or dials with it, and `launch`, `applyKnobs`,
  `control`, `bootEmulator`, `refreshDesk` and the device settings refuse
  on their own. A recorded core probes once, through the apps door, and
  polls nothing.
- **The chrome and the overview read runs through the same sources.**
  `ShellController.runs` carries them; the device button and the worktree
  home used to read the machine's run dir, which put the recording
  machine's own runs into the studio's shots. Over a recording neither
  re-reads on a timer.
- **The web page runs at the recording's moment.** `runWebDemo` enters a
  `package:clock` zone pinned to `pinnedClockOrigin` and moving from there,
  before the binding exists so every frame runs in it. Without it the run
  read *started 264d ago*; every recorded panel that prints an age
  benefits.
- **The Screen tab's decode is announced.** `RealWork.track` around the
  screenshot decode, through `package:flutterware/real_work.dart`: it lands
  on the engine's threads and schedules no frame, so a scenario would have
  photographed *Reading the app…*.

**What the recorder does that the design did not say.** Measured runs:
1m32s, most of it seven `fw` processes compiling (~7s each) and a warm
launch.

- It asks every step for a picture (`--screenshot=true --maxSide=1000`). A
  step nobody asked a picture of archives a 277×600 one.
- `enterText` targets `{"label": "Name on the cup"}`: the drive layer
  refuses the label's own text, and says to use this.
- It pushes the notification over its own channel attachment, after the
  order, then observes once more — the last picture is the banner over
  *Thanks, Ada!*.
- **Personal data is dropped, not only rewritten.** The device cache named
  two phones plugged into the recording machine, by their owner's name and
  serial. The recorder keeps the simulator and the host targets, and drops
  every log line that names any other device.
- Times are written as local times, like `pinnedClockOrigin`, so an age
  reads the same in every zone. The inbox event's `receivedAt` is moved
  with them.
- The entry points live in `recorded_config.dart`, shared by the manifest
  and the recorder.

**Not built yet.**

- The statics. `RunCore.runDirProvider`, `RunCore.debugLive`,
  `DeskButton.runDirProvider`, `debugRead` and `debugSetProbe` are still
  there and still what the panel tests use; `RunSources` sits beside them.
  Moving those tests onto sources with memory ends is the cleanup the
  design promised, and until it lands there are two ways to stage a run.
- The device strip over a recording prints the refusal. The recorder could
  keep `run device`'s answer and a fourth door could show it.
- The launcher's log is mostly `pub get` naming packages with newer
  versions, which tracks pub.dev. Honest, and noisy.
- The drive path's two direct reads — the item lookup and `awaitLaunch` —
  still use the disk; both are refused over a recording before they run.

