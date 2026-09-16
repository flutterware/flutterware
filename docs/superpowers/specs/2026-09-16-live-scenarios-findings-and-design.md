# Live scenarios — a real clock, real sockets, the same script

*Measured 2026-09-16 on this machine, Flutter 3.48.0-0.4.pre, against a
consumer app with a .NET API, a Dart server and a PowerSync-backed local
database. Every number comes from throwaway copies of that consumer's own
integration tests; nothing was committed there and nothing in this tree
changed.*

## The question

A consumer keeps two suites of the same flows. One is 53 scenarios under
`test/scenarios`, FakeAsync, every API mocked, every run byte-identical. The
other is 13 `testWidgets` bodies under `integration_test/app`, run on a Linux
desktop build under xvfb against the real backend, 11–17 minutes per green
CI run, nothing captured on the way. Registration is written in both.

The owner's ask: a scenario that runs on a real clock against a real server,
captured step by step like the fake one, fast, in the background — and
**not** a device test. The app plus its network is the thing under test;
the phone is not.

## What the substrate answers

The scenario harness already spawns `flutter_tester` itself and picks its
own binding. A `LiveTestWidgetsFlutterBinding` in that process is a real
event loop, real timers and real `dart:io` sockets, headless, from the same
resident compiler and the same kernel. Measured with the consumer's 13
flows copied verbatim under `test/` and run with `fvm flutter test`:

| shape | wall | result |
|---|---|---|
| sequential, one process | 104s | 13/13 |
| 3 files in parallel (`flutter test` default) | 85s | 13/13 |
| sequential, animations at 0.1× (`timeDilation`) | 45.6s | 13/13 — 0.02× gives 44.8s, so the rest is network and tool |
| 3 files in parallel, 0.1× | 37.8s | 13/13 |
| 13 separate `flutter test` invocations at once | 30–39s | 8–10/13: races on `build/native_assets` and `build/unit_test_assets`, PowerSync 401s under load |
| **one build, 13 files, 13 tester processes, 0.1×** | **14.4s** (9s in-harness) | **13/13** |
| one build, 4 tester processes, 0.1× | 22.5s | 13/13 |

The last row is the shape the harness already has for fake time — one
kernel, N testers — so 14 seconds is the lane's natural number, not a
trick.

What it took to get the consumer's bodies green, in the order the failures
arrived, and every one of them is something the scenario lane already
provides:

1. **The binding.** `LiveTestWidgetsFlutterBinding` still installs
   `flutter_test`'s 400 http mock — `overrideHttpClient` is true on the base
   class and only `IntegrationTestWidgetsFlutterBinding` flips it. One
   override.
2. **Method-channel plugins.** `package_info_plus`, `device_info_plus`,
   `flutter_timezone`, `path_provider`, `url_launcher`. All are constructor
   injections or one-line channel stubs, and the consumer's fake-time
   scenarios already do every one of them. PowerSync's native core and
   sqlite load with **no** plugin registrant — the database, expected to be
   the wall, is not one.
3. **Fonts.** Bare `flutter test` draws Ahem boxes; an 8.9px `RenderFlex
   overflowed` on the home page failed two flows until `loadScenarioFonts()`
   ran. Known, solved, must stay in the lane.
4. **A device size.** At 450×1024 three flows fail: a speed-dial button lays
   out at x≈463–511 whatever the width, and a checkbox row's centre is its
   link text, so the tap opens the url and the box stays unticked. At 540
   wide all pass. **Every flake across five full runs was geometry. Real
   time produced none.**

Three traps for the design:

- `flutter test integration_test/<file>` never runs headless: flutter_tools
  routes that directory to a device (77s in `pod install` before refusing
  for a missing `--flavor`, here). The harness spawning the tester is the
  only door.
- **Under a live binding one failure poisons the process.** The binding's
  `!inTest` / `_pendingFrame == null` assertions then fail every later test.
  One scenario per guest is the isolation, and the parallelism.
- `TestWidgetsFlutterBinding` asserts `timeDilation == 1.0` the moment a
  body returns, before any `addTearDown`. Animation scaling must be set and
  reset *around the body* inside `runTest`, by the binding.

Two things measured on the hand-rolled probe did **not** reproduce in the
harness, tested in `test/scenarios/live_lane/live_capture_test.dart` on
2026-09-16: a capture at a phone size through the harness's own `_emit` is
not blank (the probe's `setSurfaceSize` + `debugLayer.toImage` was the
artefact, not the engine), and `landRealWork` needs no bypass — its
announced-work wait on `ImageCache.pendingImageCount` is exactly what lands a
network image inside the step that mounts it under the real clock too.
`pumpAndSettle` on a real binding still follows frames only, which is why the
tester's bounded policies, not `pumpAndSettle`, are the settle in this lane.

## Decisions

1. **A scenario is a script; a lane is where it runs.** Same `scenario()`,
   same verbs, same report, same flow view. The lane is a property of the
   **folder**, said once in its `flutter_test_config.dart` —
   `runScenarios(time: ScenarioTime.real)` — and mirrored on the
   `ScenariosPackage` so the runner knows before it spawns anything. A
   folder that says one thing and a package that says another is refused at
   probe, naming both. A developer who wants one kind of test has one
   folder and never sees the other lane.
2. **Time is an altitude with two values, not a knob per scenario.** A lane
   is a process, and a body written for fake time (`Settle.elapse(5s)`)
   costs five real seconds under the other one, so a `scenario(time: …)`
   would be a trap. Package, folder, run (`--time=real`, `FW_TIME=real` for
   the bare lane) — nearest wins, and a run overriding a folder is stamped
   in the report.
3. **Real time scales animations by default.** `ScenarioTime.real` carries
   `animations: 0.1`; a folder that films a transition says
   `animations: 1.0`. A step's picture is taken after settle, so the default
   loses nothing and pays for it: 104s → 45s alone. The scale is on the
   report.
4. **A real-time folder's network defaults to `live`.** The determinism the
   `off` default protects is already gone once the clock is real. `replay`
   and `record` stay available and stay useful — a live folder can replay
   for speed — and a scenario's `s.network` stubs still beat the mode.
5. **One guest per scenario, K at once, one kernel.** The runner compiles
   once and spawns a pool; each guest answers one `scenarios.run` request at
   a time; a guest whose scenario failed is killed and respawned (135ms
   boot). `--jobs` sets K; the default is the smaller of the scenario count
   and half the cores. Fake-time packages keep today's single guest.
6. **Existing settle policies keep their meaning, in real seconds.** Under
   the live binding `tester.pump(interval)` waits a real interval and a real
   frame, so `Settle.upTo(5s)` already reads "until quiet, at most five
   real seconds". `landRealWork` stays: its wait on announced work is what
   lands a network image inside its step whichever the clock (measured, see
   above). The pinned clock stays pinnable independently of the timers.
7. **A plugin with no host is a named refusal.** A `MissingPluginException`
   under real time fails the scenario with the channel, the method, and the
   two fixes — inject the value, or answer the channel — not with a stack
   trace three frames deep in `platform_channel.dart`.
8. **Setup is a beat.** `await s.setup('fresh account', () => …)` runs the
   body in-process, so the network funnel already sees its exchanges, and
   lands on the flow as a step with a duration and no picture. A consumer's
   `createAccountAndConfirmWithApi` becomes visible without changing.
9. **Comparison keeps its hands off live pictures.** A run whose data came
   off a real server differs from the run before it by weather. A live
   run's self-drift compares status, settle and shape, never pixels; the
   report says why.
10. **Not in this round:** the dev stack as a precondition of a run (the
    owner: "scenarios having to check for an up stack is weird"); a
    `fresh-user` stack command (liked, unrelated); a device lane (the same
    file on `run/launch`, for plugin-bound flows; later); a `waitFor` verb
    (the verbs already settle; `s.settle()` is the bridge).

## What this buys the consumer

Their 13 flows, unchanged in body, in 14 seconds from the studio or MCP
with no device attached, each step a picture with its texts and its
exchanges, a setup failure as a step, and one grammar for both suites so
that registration is written once and promoted with two words.
