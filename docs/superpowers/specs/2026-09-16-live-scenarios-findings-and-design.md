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

One thing the probe could not show and the first end-to-end run did: **a
request out on the wire is not announced work.** A `FutureBuilder` over an
API call schedules no frame while the call is out, so a step settled in
115ms with the spinner on screen and a 400ms answer still coming. Under the
fake clock the same body is impossible — nothing is on the wire — and on a
device the consumer's hand-rolled `waitFor` polled for it. The funnel every
live request goes through now counts requests from open until their headers
are in, and `landRealWork` waits on that count the way it waits on a tracked
future: for as long as it takes, up to the scenario's deadline. Measured:
the step now returns after the answer, and their `waitFor` has nothing left
to do.

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
   real seconds". `landRealWork` stays, and learns one more kind of announced
   work: a live request between open and headers-in, waited for like a
   tracked future (measured, see above). The pinned clock stays pinnable
   independently of the timers.
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

## The second round: the consumer's own suite through the lane (2026-09-16)

The first round measured copies under `flutter test`. This one pointed the
consumer at this checkout, declared a second folder beside their fake-time
one, ported three of the registration flows to the scenario grammar and ran
them through the CLI and the studio. What it took:

- **Two folders, one package.** The plugin keys everything by a *folder
  key*: the package path for the first declaration, `path/directory` for
  every further one — `mobile_app/test/integration` — so the addresses and
  `--package=` a project already has keep meaning what they meant. The
  manifest, which refuses a package declared twice, admits it for a plugin
  whose config says `folders: true` and whose entries each name their own
  directory. Each folder has its own scan, listing, runner and **build
  lane** (`build/flutterware/folders/<directory>`), because two hosts on one
  directory are two compilers writing one dill. The rail lists both; the
  live one wears its pill.
- **The live binding's surface was not the view.**
  `LiveTestWidgetsFlutterBinding` lays the tree out on an 800×600 surface
  and paints it into the view through a fit-and-centre matrix — written for
  a test watched on a device. Staged at a phone size, every capture came
  back 800×600 with the app shrunk into its lower half, and a tap at a
  widget's centre landed where the matrix put it, refused as "would not
  reach". The harness binding now takes the view's own configuration, as the
  automated binding does; the capture test asserts the phone's pixels.
- **A setup beat's duration was dropped** between the harness record and the
  report (`locate` copied every field but that one), and the flow view drew
  it as a blank document. It is now a card: the name, `174 ms · 4 exchanges`,
  and the exchanges themselves — which is what a reader wants from work
  that had no screen.
- **The bodies changed only where the grammar is stricter than a raw
  tester**, and each refusal named the fix: a checkbox *row*'s centre is its
  link text (tap the `Checkbox`), a hint belongs to a field's decoration (tap
  the field), `textContaining` on a button's label matched more than the
  button (use the exact string, as the fake-time suite already does). Their
  hand-rolled `waitFor` reduces to a settle plus an expectation.

Measured: three flows, one kernel, three guests, **12.7s in-harness, 15.7s
wall** from the CLI with a warm lane, and a single scenario re-run in
**4s** end to end. The studio runs the same folder from its panel.

The other ten followed. **All thirteen: 23.5s in-harness, 28.7s wall, six
guests**, 222 steps captured — against 11–17 minutes on the device build.
Every label in the port is a translation key, as the fake-time suite's are
(the original mixed keys with English literals, which held only because it
ran English only); the country name is the picker's own data. Two more
grammar findings on the way: a dropdown pre-filled by an invitation makes
its label a floating decoration (tap the field's widget), and its menu
repeats the selected value, so the menu entry is the *last* match. The
folder keeps `Shots.auto`: the app's first frame is a step like every
verb's, and a `screen()` only names the moments worth a name — it adopts
the picture the verb before it already took, so it costs nothing.

Three rules settled after the port, each from watching it used:

- **The folder lives under `integration_test/`**, not `test/`: by their
  convention `test/` is what runs with no setup, and this needs a stack.
  The plugin takes any directory; `flutter test` on that path routes to a
  device, which is exactly the convention saying so.
- **A live scenario runs when asked.** Opening its page, or walking the
  list, does not run it — that is somebody's backend, an account made, an
  email sent. The page says *Runs against your backend* and the Run button
  is the door. Fake-time pages still run on open.
- **A live run is on the wall clock.** The fake lane pins every run to a
  date so two runs compare; a live run compares with nothing and its
  backend answers with today, so neither the default pin nor the project's
  `fw.clock` applies, only a clock the run itself names. The report and the
  header carry none otherwise.
- **A comparison never runs a live folder.** Both doors take the fake-time
  folders only.

## Open after the second round

- **`--time` on a run.** A runner is built for one clock (the generated
  entrypoint says it), so overriding a folder's clock per run means a second
  harness for the same path. Not built until someone needs it; the folder
  and the package say the clock, and they must agree.

## What this buys the consumer

Their 13 flows, unchanged in body, in 14 seconds from the studio or MCP
with no device attached, each step a picture with its texts and its
exchanges, a setup failure as a step, and one grammar for both suites so
that registration is written once and promoted with two words.
