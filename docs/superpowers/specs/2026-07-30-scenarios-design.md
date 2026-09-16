# Scenarios — the test-runner revival

**Date:** 2026-07-30
**Status:** Decided with the owner. **Spike S4 ran the same day and
succeeded** — `2026-07-30-s4-flutter-tester-findings.md`. The substrate
decision is confirmed on measured ground (compile 8ms, reload 39-50ms, warm
3-step run 123ms, fonts verified by eye, `enterText` proven); the fallback to
`flutter run -d flutter-tester` is not needed.
**Amends:** `2026-07-25-overhaul-master-plan.md` § M4 — the
"rewrite on `LiveWidgetController`" shape is superseded (amendment in place
there points here).
**Lineage:** dev_studio (`/Users/xavier/projects/dev_studio`, the original) →
the 2026-05 port (`lib/src/test_runner/` + `app/lib/src/test_runner/`, rotted,
unreachable from the shell) → this.
**Evidence:** `2026-07-26-s1-scenario-in-embedder-findings.md`, re-read against
both codebases; the rot inventory and salvage list below.

## The one word

The feature has been called test runner, scenario test, app test, test
visualizer, and `testApp` — across two codebases and three docs. That ends
here. The word is **scenario**, and it is the only word:

| surface | name |
|---|---|
| entry function | `scenario('Onboarding', (s) async { ... })` |
| tester type | `ScenarioTester` |
| directory | `test/scenarios/` |
| plugin id | `flutterware.scenarios` |
| CLI | `fw run scenarios ...` |
| GUI label | Scenarios |
| package config | `ScenariosPackage(directory:)` |

The existing declaration in `lib/src/plugins/first_party.dart`
(`TestRunner` / `TestsPackage`, id `flutterware.tests`) is renamed to
`Scenarios` / `ScenariosPackage`, id `flutterware.scenarios`. Nothing
implements the old id, so the rename is free today and never again.

## Why M4's shape changes

S1 recommended "fork dev_studio's design, rewrite its ~1,400-line runtime on
`LiveWidgetController`". Re-reading S1 against both codebases shows that
recommendation answered a narrower question than it appeared to.

S1's argument was against **dev_studio's architecture**: dev_studio's
`Scenario` class drives the binding *outside* `testWidgets`, and constructing a
`WidgetTester` outside the harness is what forced the vendored 701-line fork of
`widget_tester.dart` — the SDK-bump tax S1 rightly wanted dead. But the 2026-05
port had already eliminated the fork by a cheaper route: **go through
`testWidgets`** and the harness hands you a real `WidgetTester`, zero forked
lines. S1 never evaluated that route; it compared "dev_studio as-is" against
"live binding", and the live binding won *that* comparison.

Meanwhile the owner's actual requirements (2026-07-30) invert S1's premise:

- **"Live" is not wanted.** Runs should be instantaneous, which means
  `FakeAsync` — animations complete in zero wall-clock time, `pumpAndSettle`
  cannot hang on a repeating animation, the clock is frozen. S1 measured the
  live route at ~1.75s for a 4-step scenario, dominated by real-time
  `pumpAndSettle` polling; a suite of 50 scenarios × 3 languages × 2 devices is
  minutes live and seconds faked.
- **Inspection is a tree dump next to the screenshot**, not hovering a live
  frame. Captured per step, over the wire, browsed offline.
- **Auto-write is artifact-driven**: click a node in a *captured screenshot*,
  resolve it through the *captured tree*, insert `tap('<key-or-text>')` into
  the source, hot reload, re-run the whole scenario. Re-running is cheap
  because FakeAsync. No live app is ever clicked.
- **100% flutter_test compatibility** is a goal in itself: an existing
  `testWidgets` file must compile with only its import changed, and `enterText`
  must work — it is `WidgetTester`-only and was S1's "largest API gap" on the
  live route.
- **User CI must run scenarios.** `flutter test` runs everywhere; the embedder
  is `darwin-x64` with no Linux path.

So: **the harness is `flutter_test`'s, under `AutomatedTestWidgetsFlutterBinding`
(FakeAsync), entered through `testWidgets`.** The `LiveWidgetController` route
is not deferred — it is not wanted for this feature. The embedder remains the
catalog's substrate; the two features share the *compiler*, not the engine
(see next section).

## The substrate: `flutter_tester`, spawned by our daemon

Three options were weighed:

| | compile pipeline | reload loop | platforms | C work |
|---|---|---|---|---|
| (a) `flutter run -d flutter-tester --machine` (the 2026-05 port) | the flutter tool's — second, foreign pipeline next to the catalog's | through the tool, ~1s class | all | none |
| **(b) spawn `flutter_tester` directly from our daemon** | **the catalog's resident compiler** | **`reloadSources` with the incremental dill — the 11ms/117ms class loop the catalog already runs** | **all** | **none** |
| (c) port the harness onto our own embedder | the catalog's | same | darwin-x64 only | real (platform task runner, warm-up frames under a test binding) |

**Decision: (b).** This is what `flutter test` itself does — the tool execs
`$SDK/bin/cache/artifacts/engine/<platform>/flutter_tester` with a kernel path;
`flutter run` is the one that wraps it in the resident runner and pays a big
tool-side compile before anything runs. We exec the binary ourselves, feed it
kernels from the same resident `frontend_server` the catalog daemon owns, and
drive reload over the VM service.

Why not (c), given "customize everything" was the original attraction: under a
FakeAsync test binding, almost everything one would customize lives *above* the
embedding. Platform channels never reach the embedder (the test binding's
messenger intercepts them Dart-side — it is why `flutter test` needs no
platform), frames are pumped by the binding rather than vsync, capture is
`toImage` through the same Skia either way, and fonts load Dart-side from the
asset bundle. (c) buys engine-level control the model cannot feel, and costs
Linux.

**The seam is kept deliberately.** The daemon's contract with the runner
process is: *a binary that accepts a kernel, exposes a VM service, and runs our
Dart harness `main`*. `flutter_tester` satisfies it today on three platforms;
the embedder can satisfy it later if a concrete need appears (GPU-accurate
capture, engine flags, view topology). Authored scenarios never see the swap.

This is also the trigger for the deferred daemon-identity split
(`app/lib/src/catalog/daemon_address.dart:25-42`): the scenario service is the
"second service" that must not inherit the compiler's config-derived address.
Coarse process address + per-service config negotiated after connect, as that
note already prescribes.

Unproven, hence spike S4 below: `reloadSources` + FakeAsync re-run in a
*directly spawned* `flutter_tester`, and font fidelity hammered hard.

## The API — three layers

> **Amended 2026-07-31** by `2026-07-31-scenarios-api-gaps.md`: the verbs no
> longer call `pumpAndSettle` — they apply a `Settle` policy, bounded by
> default, because a screen holding a spinner made every verb throw. The verb
> set is nine, not four (`longPress`, `drag`, `scrollTo`, `back`, `wait`
> joined), and targets past text/key/icon/type are a `Target` vocabulary.
> That review also lists what this surface still owes a real app's tests.

### Layer 0 — strict compat

`package:flutterware/flutter_test.dart` re-exports `flutter_test` **1:1,
hiding nothing**. The 2026-05 port hid `testWidgets` and substituted `testApp`;
that broke the "only the import changes" promise (its own docs' snippets did
not compile). Never again:

```dart
import 'package:flutterware/flutter_test.dart';

void main() {
  testWidgets('counter increments', (tester) async {
    await tester.pumpWidget(MyApp());
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });
}
```

### Layer 1 — helpers, explicit capture

Extensions on `WidgetTester`, usable inside any plain `testWidgets`.
Screenshots at this layer are always explicit:

```dart
extension ScenarioHelpers on WidgetTester {
  Future<void> screenshot({String? name, List<String> tags = const []});
  Future<void> tapText(String text);
  Future<void> back(); // BackButton → CupertinoNavigationBarBackButton → CloseButton
}
```

### Layer 2 — the scenario surface

`scenario(name, body)` is `testWidgets(name, (t) => body(ScenarioTester(t)))`
plus the run-args zone (device, locale, text scale, brightness — sent by the
GUI/CLI, defaulted standalone) plus the split-replay loop. `ScenarioTester`
**wraps** the real `WidgetTester` — composition, since its constructor is
private; no fork, ever again.

```dart
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Onboarding', (s) async {
    await s.pumpWidget(MyApp());                    // auto-shot
    for (var i = 0; i < 3; i++) {
      await s.tap('NEXT');                          // auto-shot each
    }
    await s.enterText('Email', 'x@example.com',
        shot: Shot('Filled form'));                 // named → primary node
    await s.tap('Sign up', shot: Shot.skip);        // no capture
    await s.screen('Home');                         // named screen, no action

    await s.split({
      'pay by card': () async {
        await s.tap('Pay');
        await s.screen('Receipt');
      },
      'payment fails': () async {
        await s.tap('Pay');
        await s.screen('Error dialog');
      },
    });

    expect(find.text('Done'), findsOneWidget);      // flutter_test works as-is
    await s.tester.pump(const Duration(seconds: 2)); // escape hatch
  });
}
```

**`dynamic` targets are a deliberate exception.** The house preference is
typed, but `tap(Keys.next)` / `tap('NEXT')` / `tap(FilledButton)` /
`tap(Icons.add)` / `tap(finder)` reads too well to give up, and the auto-write
generator emits exactly the string form. Accepted:
`Finder | String | Key | IconData | Type`; anything else is a `StateError`
naming the type. (Owner-approved exception, 2026-07-30.)

**The wrapper boundary is the auto-screenshot boundary.** Methods on `s`
capture; anything through `s.tester` does not. One rule, no magic.

Because every scenario **is** a widget test, `flutter test test/scenarios/`
runs the whole suite in user CI with no daemon and no GUI — screenshots are
written to disk when a destination is configured
(`SCREENSHOTS_DESTINATION` / `-Dscreenshots-destination`, as the port did) and
skipped otherwise.

## The live lane (2026-09-16)

A folder may run on the real clock: `runScenarios(time: ScenarioTime.real())`
in its `flutter_test_config.dart`, mirrored on its `ScenariosPackage`. Same
`scenario()`, same verbs, same report; the harness picks a
`LiveTestWidgetsFlutterBinding` instead of FakeAsync, sockets are real,
animations run at a tenth, the network defaults to `live`, `s.setup(...)`
records preparatory work as a beat, and the runner spawns one guest per
scenario from the one kernel (`--jobs`). A live run's pictures are never
compared. Findings, numbers and decisions:
`2026-09-16-live-scenarios-findings-and-design.md`.

## Screenshot policy

- **Auto by default** on every layer-2 action, overridable per call:
  `shot: Shot.skip`, `shot: Shot('Name', tags: [...])`.
- **Per-scenario opt-out** (owner-confirmed 2026-07-30):
  `scenario('X', shots: Shots.manual, ...)` turns auto-capture off for that
  scenario — only named `Shot`s and `screen()` capture. Default is
  `Shots.auto`. This revives the owner's earlier opt-in experiment for long
  scenarios with noisy steps.
- **Per-folder default** (2026-08-20): `runScenarios(testMain, shots: ...)` in
  a folder's `flutter_test_config.dart` sets the policy for every scenario
  under it, beaten by any `scenario()` that names its own. The policy is a
  fact about the folder in the same way the device and language profile
  already is — a folder whose captures feed a document generator wants every
  picture named and nothing else rendered. Measured by a consumer: **65 of
  that folder's 197 steps (33%), 41 MB a pass**, rendered, written and then
  discarded wholesale by the exporter, because the alternative was saying
  `shots:` on every one of sixty scenarios.
- **Named shots and `screen()` are primary flow-graph nodes**; anonymous
  auto-shots fold into their predecessor as collapsible detail. This merges the
  ancestors' philosophies — dev_studio's curated graph, the port's
  post-mortem completeness — instead of choosing.
- **`screen()` names the previous capture rather than duplicating it**
  (2026-08-20, reversing the line below it as originally written). Under
  `Shots.auto` a `screen` following a verb was a second, byte-identical picture
  whose only contribution was the name. Measured by a consumer on a
  125-scenario suite: **666 of 775 named steps (86%)** were duplicates, costing
  **312 MB of the run's 863 MB (36%)** — most of it the motion frames of a
  transition that did not happen.

  Where no frame has been drawn since the previous capture, the name now lands
  on that capture and no step is emitted. One step carries both the authored
  name and the verb that produced the frame, which is also the strongest
  signature `previews compare` has ever had on one node. A `screen` whose frame
  *has* moved on — a `pump`, a completer, a decode landing — still captures,
  which is the whole reason the verb exists.

  The frame counter is what decides, and it is exact rather than approximate:
  the binding draws no frame for a pump with nothing scheduled. It is counted
  from the previous *capture* rather than the previous step (a `Shot.skip` verb
  between them draws like any other) and read after the screen's own settle
  (which is where work the verb before it left in flight actually lands).
  Refusals: a name never overwrites a name, a branch's first capture never
  renames the step before the fork, a failure's picture is never renamed, and
  `screen('X', force: true)` declines outright.

  **`screen()` still settles, and that was re-decided rather than assumed**
  (2026-08-24). A consumer asked for `Settle.none` as its default, on the
  grounds that the verb acts on nothing and that on a screen holding an
  indefinite animation its settle spends a whole five-second budget — which
  under fake time is a clock that *moved*, firing every timer due inside the
  window and finishing the thing the scenario meant to photograph. Both
  observations are true and neither is about this verb: a bounded budget on a
  non-converging screen is spent by *whatever* verb comes next, and a `tap`
  written there instead fires the same timer. What is about this verb is that
  it captures, and a capture wants a screen that has stopped moving. Flipping
  its default would have bought the mid-flight case at the price of the
  invariant the policy exists for — that no author has to know which verb
  waits. Mid-flight is said out loud instead, on the name as well as on the
  verb before it, and the doc example that read as though the verb before it
  were enough has been corrected.

  Two consequences. A capture is handed over **one step late**, because the
  name has to land before any artifact is written — every file stem is built
  from the step's label. And an adopted `screen`'s events move onto the step it
  names rather than rolling forward to a later one.

- **Adoption's second chance is the bytes, and a no-op `scrollTo` skips its
  shot** (2026-08-21, both reported by a consumer suite migrating from
  dev_studio). The frame counter above is a *prediction* that the pixels did
  not move, and two ordinary patterns defeat it while the pixels end up
  provably identical: extra settling between a verb and its name — the
  migrated idiom is `tap → pumpAndSettle → screen` — and a periodic timer
  repainting an identical screen around the capture, or leaving it
  `settled: false`. Measured on a 125-scenario suite: 50 named `screen`s
  still emitted as duplicates, 35 of them sitting directly on an anonymous
  verb capture with an equal digest.

  So where the frame count says no and the pending capture is still
  anonymous, fresh and captured in this branch segment, the render the step
  was about to pay anyway is compared against the held one — dimensions,
  overlay style, the visible words, the shutter's tree-and-semantics read,
  and the bytes, each there because the ones before it cannot vouch for it
  (raw bytes carry no dimensions, a box-glyph test font rasters two
  different strings identically, a semantics-only change touches no pixel).
  Equal means adopt: the name lands on the pending step, nothing new is
  written, and the stretch's *facts* merge onto it — settled/landed combine
  as ANDs, strays and swallowed overflows stay counted, and the recording is
  sifted against the frame it ended on so a flash that came and went on
  provably identical end pixels keeps its movie while a quiet interval's
  identical stills stay out. "The pre-fork refusal" is enforced by stamping
  each capture with its branch segment rather than by the branch *label*,
  which a branch-opening `document`/`notification` beat consumes while the
  pre-fork capture is still the one pending — the label proxy let a
  branch-local name land on the shared step. A pixel-less probe pass never
  byte-adopts — every probe capture holds the same empty bytes, which prove
  nothing — so a `format=none` run emits steps a pixel run merges: step
  *indices* diverge between such passes by design, and anything joining
  passes must key on `position` (the max-length survey's sighting cells and
  screen-break dedup do, since this change; `compareScenarioRuns` always
  has).

  The same suite's other half: 67 of its 135 `unchanged` steps were
  `scrollTo` on a target already on screen — the verb's own documented
  advice, called defensively before taps, becoming a warned byte-identical
  duplicate on every page that happens not to scroll on this device. A
  `scrollTo` that drew nothing now skips its automatic capture — but
  **consumes its position**, mapping it to the chain's head exactly as an
  adoption does. That is the load-bearing half: the decision is exactly what
  varies — with the device, with expanded text making a page scroll, with a
  frame a real-async decode lands on one pass and not another — and a skip
  that consumed no position turned every flip into a misalignment of
  everything after it (drift reporting a segment tail as changed, split
  replays mis-recognising their own steps). Consumed, a flip costs one
  step's presence and nothing else. The skip also discards the recorder's
  banked stills — provably identical, and otherwise padding the next step's
  movie and its frame cap — while events keep riding as a skipped shot's
  always have. An explicit shot still captures, and a call that moved pixels
  — the trailing alignment nudging even a visible target to the viewport's
  edge — captures as ever. Deliberately `scrollTo` only: an unchanged `tap`
  is the stall diagnostic — seven identical captures passing as seven pages
  — and skipping it would hide the very thing the flag exists to expose.

  One more hardening from the same review: the render runs inside
  `tester.runAsync`, which swallows a thrown capture (reported, run
  continues) — the emit now burns a step index on that path, so the consumed
  position can never alias a live step and a later replay cannot mis-recognise
  it.

- **Not every beat is a screen** (2026-08-20). `s.attach` is replaced by
  `await s.document(name, bytes, …)` and `await s.notification(body, …)`, and
  both are **steps** — positioned, parented, carrying the events that led to
  them — rather than files bolted onto somebody else's step.

  The old model attached a file to a step and then needed a boolean, `after`,
  to say whether the screen it belonged to was that step or its parent. That
  boolean was provably redundant: a riding attachment on step N occupied the
  same canvas position, over the same backdrop, as a trailing one on step N−1.
  It existed only because `attach` was synchronous and so could not anchor at
  its own moment. And it served exactly one mimeType — the document sheet
  never read the backdrop at all, only the notification banner did.

  So: a document is a step whose picture is the document, with no frame,
  because there was no screen showing it. A notification is a step whose
  picture is the push, also with no frame — a viewer draws it over the nearest
  screen before it, which is what a real banner does. `ScenarioRunStep.kind`
  says which; `image`, `format`, `width`, `height` and `tree` are null on
  anything that is not a screen, and a reader written before there were other
  kinds reads a screen correctly by ignoring the key.

  Neither renders, so neither costs a capture, and neither draws — which is
  why a `screen` after a beat still names the frame before it. The one trap:
  an adopted `screen` must record the chain's **head** as what the next step
  parents to, not the step its name landed on. Recording the latter gives one
  node two children with no branch between them, and the comparison aligner's
  chain walk (`_chainFrom`) follows only one of them — silently dropping the
  other from every diff.

  Gone with it: `after`, the riding/trailing split in the flow canvas, the
  attachment level of the plugin's address (`…/<n>/<i>`), the trailing-flush
  listener, and `scenarioAttachmentBackground`. Gained: a document has a name,
  so `previews compare` aligns it at the top trust tier — where attachments
  were invisible to a diff entirely.
- On failure, the dev_studio post-mortem pair: the frame before the error, then
  the rendered error, then the stack. This is the artifact an agent reads.

## Determinism — is it the same suite twice? (2026-08-20)

A suite can be entirely green while a third of its screenshots move every
pass. Every scenario passes, every assertion holds, and the pictures
underneath are different pictures — and nothing in the report said so. A
consumer reached byte-reproducibility on a 125-scenario suite only after three
fixes of their own (a fixture chosen by hashing a freshly-minted id, generated
ids drawn on screen as text, and two production writes taking `DateTime.now()`
instead of the injectable clock), and finding them by eye took a day.

So every step that captures bytes records a **digest** of them —
`ScenarioRunStep.digest`, the pixels for a screen and the payload for a
document — and `compareScenarioRuns(before, after)` answers which steps moved.
The `run` action reads the baseline's report *before* it starts (a fixed
`output` is about to be overwritten; otherwise the newest earlier run of the
same matrix point, unless `baseline=` names one) and reports the answer as
`ScenarioRunPackage.drift`. `drift.json` beside the report carries every moved
step where the answer's lists are capped, and the `diff` action asks the same
question about two runs a caller names — which is the form a CI gate needs,
because "whatever ran last in this directory" is not a base it can depend on.

**The digest is not the whole step.** The status and nav bar tints, the soft
keyboard's height and whether a step settled are recorded beside the capture
and drawn *around* it, so no digest of the app's own surface can see them
change. They are compared too, and each moved step says which facets moved in
`what` — a behaviour change reading as "nothing moved" is the most dangerous
answer this can give.

Rules that keep it from crying wolf:

- **Paired by the `Shot` name, then by branch, and only then by position.** A
  position's ordinal counts captures since its branch began, so an inserted
  step renumbers every step after it — matched on that, one insertion answers
  with a cascade of changed/added/removed per step below the cut. A name does
  not move. An unnamed step is pinned to the nearest name above it plus its
  distance from it, so an insertion disturbs only the unnamed steps between two
  names; `nameMatched` and `unanchored` report which regime a comparison ran
  in.
- **Only scenarios both runs captured bytes for.** One of them may have been a
  selective run, and a scenario the other never executed did not move.
- **A run with no digests anywhere is a run with nothing to compare**, not a
  suite that moved entirely — which is what a report written before this
  existed looks like. The digest is the eligibility gate, so a step with no
  pixels is not compared on its other facets either.

It matters beyond tidiness: a comparison against a base checkout is only as
useful as the suite's determinism, because a suite that moves on its own
drowns the change that was actually asked about.

## Discovery

Follows the catalog's posture exactly — one scanner, three sources:

- **Config**: `ScenariosPackage(directory:)` in `tool/flutterware.dart`,
  default `test/scenarios/`.
- **Syntactic scan** for `scenario('string literal', ...)` calls gives the
  report/badges a scenario count without compiling anything. Provisional; the
  runtime listing over the protocol is ground truth; disagreement is a
  diagnostic.
- **Generated entrypoint** (the daemon needs one `main` importing every
  scenario file), committed and guarded by the regeneration-produces-no-diff
  check, like `catalog.g.dart`.

No nested-map registry. dev_studio's `Map<String, dynamic>` closure is the same
central-registration pattern the catalog just killed, and it stays dead.

## The plugin

Standard shape per the plugin contract (core / results / address / panel /
both registries / capability regeneration):

- **Core** `ScenariosCore`: report = scan (scenario count, last-run status per
  scenario); `track` = scan only; the daemon+runner start when the panel mounts
  or an action needs them.
- **Actions**: `list` (scenarios, steps, named screens — from scan + last run),
  `run` (params: `scenario`, `language`, `device`, `text-scale`,
  `brightness`; returns a `PluginResult` with per-step artifacts).
  *Shipped as four, 2026-07-31: `restart` drops the warm harness, and `new`
  writes a runnable scenario file. `new` exists because everything else here
  operates scenarios that already exist — an agent could run them and could
  not find out how to write one, since the only statement of the API was the
  panel's empty state, which no other surface can see. `docs/capabilities.md`
  is the current list; this paragraph is the intent it grew out of.*
- **Artifacts, the step triple**: PNG + widget-tree JSON + extracted texts,
  each an `Artifact` with an address. The tree format is `lib/src/inspect/`'s
  node model — the same vocabulary an agent already reads from the catalog,
  already token-lean.
- **Address**:
  `fw:///worktrees/<worktree>/flutterware.scenarios/<pkg>/<file>/<scenario>/<step-id>?language=fr&device=iphone-se`
  — language / device / text scale / brightness are **axes**, applied
  assignments recorded on every artifact, per the catalog's rule that a
  screenshot is under-specified without them.
- **MCP is a first-class consumer, not a port.** The agent loop the design
  serves: edit the scenario file → `flutterware_invoke {plugin: scenarios,
  action: run}` → explicit compile-and-run barrier (the catalog's "watching is
  for humans, an explicit reload is for agents" — no watch-mode races) → steps
  return with images inline (`ImageContent`), trees, texts → failures return
  the post-mortem pair. `fw run scenarios run --scenario=onboarding` is the
  same door.
  *Shipped 2026-07-31 as: every step's PNG and tree on the wire as
  worktree-relative paths, and the frame before each failure inline as
  `ImageContent`. Not every step inline — fifty pictures per call is context
  an agent pays for and did not ask for.*

The panel is dev_studio's proven GUI shape — flow graph (splits fan out into a
DAG), step detail with tree/text overlays, language/device/accessibility
toolbar driving re-runs — rebuilt on `AddressScope` and the design tokens.

## Fidelity — parity requirements, not deferrables

The past font experience was bad enough that this section exists. At parity:

- Load the app's own `FontManifest.json` from the built asset bundle.
- Ship Roboto + SF Pro fallbacks so Material/Cupertino defaults render real
  glyphs, never Ahem boxes.
- `debugDisableShadows = false` during the run, restored after.
- Frozen clock (`package:clock`), fake status bar reading the app's declared
  `SystemUiOverlayStyle` brightness.
- Real network images: parked-completer `HttpOverrides`, resolved at
  `waitForAssets` time (dev_studio's mechanism).

Deferred: email/PDF/JSON screens, the poeditor/Confluence/Firebase deep links
(company-specific; extension points at most), the virtual keyboard overlay.

## Salvage and delete

From the 2026-05 port (~6,600 handwritten LOC): **keep** the runtime shape
(`testWidgets`-entry, run-args zone, `PathTracker`, screenshot extension), the
protocol model (steps/screens/splits/parent-rects), and the GUI screens
migrated onto the shell. **Delete**: the web/iframe path (cannot compile —
unconditional `dart:io` on the core path), `runtime/fonts.dart` (resolves a
directory that does not exist), `mockup.dart`, `virtual_keyboard.dart`,
`browser.dart`, the `flutter_markdown` help screen, both stale example layouts
(`test_app/`).

From dev_studio: the flow-graph collapse model, translation-capture *hooks*
(overridable, no vendor links), network-image mocking, the status bar,
device presets, split-path replay.

## Known gaps in the flutter_test superset (review 2026-07-31, consumers 2026-08-14 and 2026-08-17)

The API promises a strict superset: an existing widget-test file compiles and
runs with only its import changed. Four things broke that promise, and every
one of them failed **silently** — which is what makes them worth writing down
rather than leaving to be rediscovered. The first two are constructs the
superset re-exports that the harness's own walk did not honour; the last two
are fake time meeting work that does not run on it.

1. ~~**`scenario()` inside a `group()` cannot be run individually.**~~ **Fixed
   2026-07-31.** The scan and the harness's `list` report the *leaf* name,
   while `_run` used to filter with
   `Declarer(fullTestName: '<file> <scenario>')` — and `test_api` composes the
   full name as `<file> <group> <scenario>`, so the filter matched nothing,
   zero tests were declared, and the panel reported "The harness ran nothing
   named …, renamed since this page was opened?". Running the whole file
   worked, so the listing looked healthy while every per-scenario run — the
   panel's only run path — failed. The declarer no longer filters at all;
   the walk does, against the same leaf name the listing shows, which also
   drops our dependency on `test_api`'s name composition. Two scenarios
   sharing a leaf name in one file both run, the honest reading of a request
   that names only what the panel displays.

2. ~~**`setUpAll`/`tearDownAll` never execute.**~~ **Fixed 2026-07-31.**
   `test_api` stores them as `Group` fields outside `entries`, and the engine
   runs them around the group's tests; our walk iterated `entries` only.
   Per-test `setUp`/`tearDown` were unaffected (the declarer folds those into
   each test body), which made the divergence harder to spot: the same file
   passed under `flutter test` and captured wrong screens under the runner.
   The walk now mirrors `test_core`'s engine — `setUpAll` before the group's
   entries, entries only if it passed, `tearDownAll` afterwards whatever
   happened — with two adaptations recorded in
   `2026-07-31-scenarios-api-gaps.md`: the filter is consulted *first*, so
   running one scenario does not start every other file's fixtures, and the
   hooks run inside a zone of their own, because `test_api` builds them
   unguarded and their failures would otherwise vanish into the harness's
   outermost guard while the LiveTest stayed green.

3. ~~**An asset read twice deadlocks the run, silently, for ten minutes.**~~
   **Fixed 2026-08-14.** `rootBundle` is a `CachingAssetBundle`, which memoizes
   the *future* of a read rather than the value. Under fake time that future
   completes only when a pump flushes the fake microtask queue — and no pump
   can run inside `tester.runAsync`, so a key the app read while building, still
   in flight, wedges a `runAsync` that reads it again. Neither half is exotic: a
   screen showing an SVG and a step reading the same SVG is the whole recipe,
   and `runAsync` is what the blank-screen hint recommends. Reported by a
   consumer whose report scenario hit it and cost a day.

   Three things, because each covers a case the others cannot. A
   `ScenarioAssetBundle` (`lib/src/scenarios/asset_bundle.dart`) extends
   `AssetBundle` and caches *values*: a hit is a `SynchronousFuture`, which
   resolves in whichever zone asks, and a miss inside `runAsync` reads on the
   real event loop. It is installed as the `DefaultAssetBundle` over whatever
   `s.pumpWidget` pumps, and reachable as `s.assets`. `rootBundle.clear()` at
   the top of every scenario, because a future left in flight when a scenario
   ends belongs to a FakeAsync zone nothing will ever flush again — the next
   scenario awaiting it waits for the rest of the run, and app code that reads
   `rootBundle` directly is out of the bundle's reach. And a watchdog
   (`async_watchdog.dart`) on every `runAsync`, at `s.runAsync` and at the
   harness binding both: a real-time timer that cannot break the deadlock —
   the body is suspended inside it — but names it, on stderr in seconds and in
   the timeout the run reports.

   Found while proving that last part: the harness's 30s scenario deadline was
   dead letter. `testWidgets` stamps the binding's ten minutes on any test that
   names no timeout, and `Timeout.apply` honours it, so `_defaultScenarioTimeout`
   never applied — measured at 600s on a deliberately wedged scenario, which is
   exactly the ten minutes of silence the report describes. The harness now
   declares its default (`scenarioDefaultTimeout`) as the scenario is declared,
   rather than trying to read one back it cannot tell from an author's. Same
   probe after: 30s, with the diagnosis.

4. ~~**The step that mounts a screen photographs the frame before its
   artwork.**~~ **Fixed 2026-08-17.** Reported by a consumer whose every
   `vector_graphics` illustration was missing from the capture of the step that
   mounted it and present in the next one — so every flow that photographs each
   screen as it arrives, which is every flow anyone writes, lost its artwork on
   every screen.

   A `Settle` policy follows frames, and that is all any of them can do. Work
   that resolves on the **real** event loop — the engine's answer to an asset
   read, and the decode on the other end of it — schedules no frame while it is
   in flight, so `upTo` and `frames` see a tree that looks finished and `elapse`
   advances a clock the work does not read. All three produced a byte-identical
   broken capture. Then the capture itself opened `tester.runAsync` to
   rasterise, the read completed *inside* that turn, and the picture had already
   been taken: hence one more step always fixing it and more pumping inside the
   step never doing so. `pumpWidget` was the one verb immune, because it already
   took a real turn for boot.

   `landRealWork` (`lib/src/scenarios/real_work.dart`) is the fix, applied by
   every verb after its policy and before its capture. A turn of the real loop
   is the detector: a frame scheduled on a tree that was quiet before it was
   scheduled by work that just landed, and the policy is then re-applied to draw
   it. Skipped where the policy already gave up, since a screen holding a
   spinner has a frame scheduled for its own reasons. Measured on the example
   suite: 41 of 48 steps had nothing pending and paid 678µs each, the deepest of
   the other seven needed seven turns, and the whole suite paid 57ms of 2.29s.

   ~~**A twelve-turn bound is a wall-clock budget in disguise, so a big enough
   decode falls off it.**~~ **Fixed 2026-08-17.** The same consumer, with
   `Image.asset` where the SVG had been: the mounting step missing its
   illustration again, and — the useful half of the report — passing for a small
   asset and failing for a large one. Reproduced here with `Image.memory`: under
   the twelve-turn bound 8×8 and 780×609 landed and 1500×1200 did not, and a
   recorded run (which pumps at 33ms and photographs every frame, so a decode
   gets several times the wall clock) held out to 5000×4000. The bound was never
   counting the work: a turn is a yield, not a wait, and the engine decodes on
   another thread, so twelve turns buy however much wall time twelve yields
   happen to cost on the machine. Raising the number moves the cliff and nothing
   else.

   So the loop now asks rather than guesses, wherever anything answers.
   `ImageCache.pendingImageCount` is non-zero for the whole of an
   `ImageProvider`'s decode — measured at 1 from the moment the tree mounted to
   the turn the frame appeared — and `ScenarioAssetBundle.readsInFlight` counts
   what the app is reading through the scenario's own bundle, which is where
   `SvgPicture.asset` and `Lottie.asset` go. While either is non-zero the loop
   **waits**, in real milliseconds, until it is not: the wait ends when the work
   ends, so a 780×609 PNG and a 2400×1800 one need the same condition rather
   than a bigger number, on a fast machine and a slow one alike. Twelve turns
   remain for work that announces nothing — a `FutureBuilder` on a real future —
   and are now spent again from zero after any turn that produces a frame, since
   a decode arrives in links. Idle cost is unchanged (the example scenario suite
   measured 3.8–4.0s either way), because a step with nothing pending takes the
   same twelve free turns it always did.

   The announced half also made a missed landing visible, which is what cost two
   reports a day each: a wait that runs out against `realWorkWait` (one second,
   a deadlock ceiling rather than a budget) records `landed: false` on the step,
   and the GUI says so above the picture. There is no such flag for the guessed
   half and there cannot be — not knowing whether anything is coming is why
   those turns are spent.

   ~~**A still that is right does not make the movie behind it right.**~~
   **Fixed 2026-08-17.** Reported against the fix above, and a genuinely
   different bug wearing the same clothes: the recording the GUI plays when you
   hover a step showed no artwork in any frame. Counting pixels rather than
   comparing frames — which is the whole lesson — a tap whose ripple runs 21
   recorded frames gave `[0, 0, 0, …, 0, present]`. A landing that happens
   *after* the settle loop can only fill in the last frame, and a movie with one
   good frame at the end plays as never having decoded. The equality assertion
   written for the still was blind to it: two captures both missing the artwork
   are equal.

   Fake time is why the app never catches up. A transition of several hundred
   fake milliseconds is spent in a few real ones, so a decode that a device
   would have finished inside the first frame cannot finish inside any of them.
   The fix is a `land` hook on `Settle.apply`, awaited before every pump, so the
   loop lets announced work land *between* its frames — a scenario passes one,
   a policy applied by hand gets none and keeps meaning what it says, and
   `settle.dart` stays free of any dependency on `real_work.dart`. The wait is
   one `RealWorkBudget` per step, shared with the landing after it: per call and
   a step could pay the ceiling twice, per run and one wedged read would leave
   nothing for the rest of the scenario. Frames now read `[0, 0, present, …]` —
   the screen before the verb, the pump that mounts the widget and so starts the
   decode, then every frame after. Cost is a two-integer read per pump; the
   example scenario suite measures 3.6–3.9s against 3.8–4.0s before.

   `previews audit` had the same blind spot in a milder form — it turns the real
   loop once at boot, so an entry whose load starts *during* the settle was
   judged with it in flight. Measured: an entry pointing at an asset that does
   not exist was reported clean. It now calls the same helper. `previews
   screenshot` does not, and needs nothing: it renders on a real engine in real
   time.

The remaining divergence is not a gap but a rule worth knowing: a `split`
replays the body, and `setUp` runs once per *test*, so state built in `setUp`
carries from one path into the next. Per-path setup belongs in the body, which
is what re-runs. Documented on `split` itself.

## Post-parity roadmap

1. **Per-step inspector** — the tree dump is captured anyway; the GUI renders
   it beside the screenshot with hover-highlighting via recorded rects
   (resurrects what the port let die).
2. **Auto-write** — click a node in a captured screenshot → resolve through
   the captured tree → insert `await s.tap('<key-or-text>')` at the
   right source location → hot reload → re-run the scenario. Instant because
   FakeAsync; headless because artifact-driven.
3. **Baseline diffing** — neither ancestor had it: run-over-run or committed
   baselines keyed on the step address (which already carries the axis
   assignment), turning the flow graph into a visual-regression surface.

## Spike S4 — `flutter_tester` as our guest

**Question.** Can our daemon spawn `flutter_tester` directly with a
resident-compiler kernel, hot-reload it via `reloadSources`, re-run a FakeAsync
scenario after reload, and capture screenshots whose **fonts are actually
right**?

**Why it matters.** It is the substrate decision. Everything above assumes the
catalog's compile loop extends to a second guest type with no flutter-tool
middleman.

**Success.**
- Spawn `flutter_tester` with a kernel from the resident `frontend_server`,
  VM service enabled; a two-step scenario runs under
  `AutomatedTestWidgetsFlutterBinding` and streams two PNGs + tree dumps.
- Edit the scenario, `compile` + `reloadSources` + re-run without restarting
  the process; measure the loop against the catalog's 11ms/117ms class.
- **Font hammering**, the explicit non-negotiable: app fonts from
  `FontManifest.json`, `MaterialIcons` glyphs, Cupertino/SF text, a
  non-Latin string (e.g. Japanese) and an emoji — every one verified by eye in
  the captured PNG, no Ahem boxes, no tofu, correct weights. On macOS and, in
  the same spike if cheap, Linux.
- App state resets between re-runs (fresh-key remount or equivalent — hot
  reload preserves state; the runner owns the reset, per S1 constraint 1).

**Kill criteria.** If directly-spawned `flutter_tester` cannot be reloaded and
re-run reliably within ~2 days, fall back to (a):
`flutter run -d flutter-tester --machine`, which the 2026-05 port proved,
and accept the foreign compile pipeline. The API and plugin design above are
unchanged by the fallback — that is what the seam is for.

**Do not** build the plugin, the panel, or the protocol. Hardcode everything.

## Open questions

1. **Step identity.** Auto-shots are positional (`PathTracker` trail + index);
   inserting a step renumbers successors. Fine for transient runs; becomes
   real the day baseline diffing (roadmap 3) keys on step addresses. Named
   screens are the stable anchors — possibly the rule is that baselines may
   only key on named screens.
3. **Where the runner's Dart harness `main` lives** — generated per project
   (like the catalog entrypoint) vs. a fixed `package:flutterware` entry taking
   the scenario list. Falls out of S4.
