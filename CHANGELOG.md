## Unreleased

- **A comparison that cannot write a picture says so, instead of blaming the
  code.** Any failure while filing a rendered preview — a full disk on a CI
  runner, measured — was reported as "the base checkout does not compile".
  The error now reaches the output as itself.

- **A dependency change no picture can show no longer re-renders the
  package.** A package's `pubspec.yaml` was a whole-file input to every
  preview and scenario in it, so removing one dependency or adding a
  `flutter: config:` flag re-rendered and re-replayed everything — measured on
  one merge request, 420 renders and 258 replays. It is now hashed without its
  dependency lists (the lockfile and the import graph cover what they resolve
  to), `flutter: config:`, and what only pub.dev reads; everything else,
  including keys it does not recognise, still counts. A lockfile entry is no
  longer a change when only its `direct`/`transitive` kind moved. The cache key
  also carries the rasterizer, so pictures drawn by Metal, Vulkan and Skia's
  software backend are no longer served for one another. Cached comparison
  pictures are re-rendered once.

- **A comparison records the machine it ran on, and how long each replay
  took.** `index.json` carries `host` — OS, CPU count and the rasterizer — and
  each scenario its `ms` per side; the pull-request comment's footer names the
  machine.

- **A scenario that breaks while a `split` replays its shared prefix is
  placed on the branch that replay was heading into.** Each branch replays the
  body from the top, and a failure or a timeout before that replay reached its
  `split` was filed as an unlabelled step under the last step it had seen —
  another branch's. That branch grew a step its source does not contain, the
  comparison's aligner stopped walking the flow there, and the branch that
  never ran was missing from both sides. The break is now the first step of
  the branch it belongs to, hanging off the step the split forks from.

- **A scenario step says when its picture depended on how fast the machine
  was.** Work that resolves on the real event loop and announces nothing — a
  `FutureBuilder` on a real future, an untracked read — is found by turning
  the loop a dozen times, and on a slower machine it lands later or not at
  all. A step whose landing found such work now records the turn as
  `guessed`, each outcome counts them as `guessedCount`, and the scenario ends
  with one line naming those steps, under the runner and a plain
  `flutter test` alike. Turns that only delivered a platform reply are not
  counted — a form's clipboard query is the framework's, and was all eight of
  the example suite's. `fw compare` acts on it: a difference in a scenario with
  a guessed landing is replayed on each side once more, alone, and reported as
  not compared when a side does not reproduce itself; a difference that holds
  says beside the step that it may be the machine. A replay with a guessed
  landing is never cached.

- **A scenario's `timeout:` is how long it may go without progress, not how
  long it may take.** It was a wall-clock budget for the whole scenario —
  every `split` replay, every capture, every wait on tracked work — so it
  measured the machine: a flow that passes in five seconds on a quiet machine
  failed thirty on a CI runner shared by three jobs. Under the runner a
  scenario now fails when no verb has returned, no step has been captured and
  no tracked work has been pending for its timeout, on an isolate that sat
  idle. Tracked work is waited for up to two minutes per future, and a
  scenario still going at ten times its timeout is stopped. The stall message
  no longer calls a slow `RealWork` load a dead zone: it names the work and how
  long it had been pending. A bare `flutter test` keeps the timeout as written.

- **`fw compare` replays a failing scenario side again before it believes
  it.** A side that failed, or that the harness gave up on, is replayed once
  more on its own. A failure that reproduces is the verdict — including one on
  a step the other side never took, which used to fold into `changed`, so a
  base that broke read as the branch's change. One that does not reproduce is
  **not compared**: written as `skipped` with an `inconclusive` sentence, named
  in the comment's heading, listed in the CLI and on the page, and never a
  gate failure. A failed replay is cached only once it has reproduced, so one
  bad minute on one runner is no longer served to every later comparison
  against that base. Each scenario carries both sides' errors, and a failed
  step is labelled by what it failed on rather than `step N`.

- **A preview's image provider that sleeps before it decodes is drawn
  loaded.** Between the frames of its settle, the previews lane waited in real
  time for every decode the image cache counted — including one whose provider
  was still sleeping on the fake clock, which cannot move during that wait. The
  whole allowance went on a timer only the next frame could fire, and the entry
  was photographed on its placeholder, then refused by the comparison as still
  waiting. Between frames the lane now waits for tracked work only; decodes and
  asset reads are landed once the clock has run, from the same allowance.

- **A scenario replay whose trees were swept is replayed, not compared
  against nothing.** A replayed step's tree is cached apart from its frame, and
  reading it did not count as using it, so it was the first thing the cache's
  size sweep removed. The replay was then served with its frames and no trees,
  and every step of it was reported as changed: the whole tree on the other
  side read as `added`. A replay missing a tree now reads as absent, like one
  missing a frame, and reading a tree keeps it as fresh as the frames beside
  it.

- **A preview waits for the work it announced, and a capture taken without
  it is not compared.** The previews lane gave work handed to
  `RealWork.track` one second of real time, so a picture depended on how busy
  the machine was: a model import that fit on an idle machine was
  photographed on its spinner on a loaded one, and `fw compare` reported the
  difference as a change. The lane now waits up to thirty seconds, the
  scenario deadline. A still that is captured with announced work in flight
  carries it as `pending`, and the comparison refuses that frame with the work
  named instead of diffing it or caching it. Cached comparison pictures are
  re-rendered once.

  `landRealWork` no longer reports `landed: true` for a step whose allowance
  ran out while a spinner kept the screen moving.

- **A project's own shaders load, and scene text can be painted with one.**
  The shaders a pubspec declares under `flutter: shaders:` were never in the
  bundle flutterware renders from, so `FragmentProgram.fromAsset` failed with
  *"Asset not found"* in every lane — previews, scenarios, scene video, the
  studio's canvases. They are compiled and bundled now, and a `.frag` saved
  while a preview or a scene is open is reloaded in place.

  A scene text layer takes `ShaderPaint('shaders/foil.frag', uniforms: …)`:
  the pass is painted by the shader through the glyphs, over the whole text
  or once per line, with `uSize`, `uColor` and `uTime` set by the renderer
  when the shader declares them. A pass paints nothing until its program has
  loaded. The lanes wait for that themselves; a plain widget test does not,
  so it loads them first with
  `await tester.runAsync(() => precacheSceneShaders(scene));`.

- **A comparison's tree changes lead with the one that started it.** A layout
  change reports every widget it carried along, and the list used to open on
  the containers and the neighbours squeezed to make room — root first, the
  order the walk met them — so a report capped at fifty lines could leave out
  the widget that actually grew. Within a finding, the changes now read from
  the cause outwards: what a widget is, then a size change under unchanged
  constraints (deepest first), then an offset, then a size its parent forced,
  then constraints. The same lines, in `fw compare`, MCP and `index.json`.

- **A compared preview carries its name.** `index.json` rows for previews now
  have the `label` their `@Preview(name:)` declares, as scenario steps already
  did, and the comparison page titles rows by it — `Order placed` rather than
  `shopConfirmation`. A flow's row says which of its steps changed, and a
  step's page names its flow and walks to the steps either side.

- **An exported page loads without a service worker, and says what it is.**
  The comparison and scenario pages registered Flutter's retiring caching
  worker and loaded nothing until it had fetched the page's files and
  activated — on a local server, long enough to hit the template's
  four-second fallback on every load. They load through `flutter_bootstrap.js`
  now, show a loading line until the first frame, carry a description that fits them rather than the web demo's,
  and name the tab after the verdict — `7 changed — fe642dc against
  origin/master`. Semantics are on, so a screen reader can read them.

## 0.6.0

Development tooling for Flutter projects: a desktop app, a command line and an
MCP server over one set of tools you declare once.

```sh
dart pub add flutterware
dart run flutterware
```

That opens the studio. It also scaffolds `tool/flutterware.dart` and registers
the MCP server in `.mcp.json`. Declare the tools you want in that file and each
one becomes a panel, an `fw` command and an MCP action — the three surfaces run
the same code, so an agent can do what you can do from the window.

- **Previews** — your `@Preview` widgets on real device frames, live, with
  knobs, screenshots and inspection. macOS only for now; everything else runs
  everywhere.
- **Scenarios** — a `flutter_test` that screenshots itself, and draws its flow.
- **Run** — launch an entry point on any device, then drive and inspect it: by
  hand, from `fw`, or from an agent.
- **Store screenshots** — the images a store listing is uploaded from, taken
  from scenarios, per locale and display class.
- **Comparison** — `fw compare` reports what this branch did to the pictures,
  against its base.
- **Scenes** — a scene and its motion in one file, rendered by your app and
  exportable to video.
- Also: dependencies, assets, translations, lints, renders, native splash,
  launcher icon, server inspection, a dev stack and a changes view.

Every capability of every surface: [docs/capabilities.md](docs/capabilities.md).
Needs Flutter 3.47.

## 0.5.1

- Upgrade dependencies

## 0.5.0

- Add Figma integration to `ui_catalog`

## 0.4.2

- Move the devbar button slightly

## 0.4.1

- Increase test_api constraint

## 0.4.0

- Improve `package:flutterware/devbar.dart`

## 0.3.0

- Rename `widget_book` to `ui_book`

## 0.2.1

- Add search field to up-coming `storybook` feature

## 0.2.0

- Support Flutter 3.13

## 0.1.2

- Internal maintenance to improve pub's score.

## 0.1.1

- Allow to start the app from pub cache.

## 0.1.0

- Test runner with screenshots & hot-reload
- Pub dependencies manager
- Launcher icon manager
