# Publishing flutterware: where we stand, and what a launch would take

*2026-09-09. Everything in §1 is measured; everything from §3 on was an argument
with options.*

**Decided 2026-09-09.** A **quiet republish**: fix the blockers, re-cut the
README, ship 0.6.0, say nothing. No site, no announcement — Layers 3 and 4 below
are deferred, kept because the arguments in them do not expire. **Scenarios
leads** the README.

The reasoning for the small launch is in the numbers: publishing HEAD alone
moves the page from 50/160 and no platform chips to ~130/160 and all six, and
that is most of the available win for hours of work. A site and an announcement
can follow whenever there is an appetite for them; nothing below has to be
redone first.

---

## 1. The finding that reorders the rest

**The flutterware on pub.dev is 24 months old and does not compile against
current Flutter.** Measured today against the live API:

| | |
|---|---|
| Latest published | **0.5.1**, ~24 months ago |
| Score | **50 / 160** |
| Pass static analysis | **0 / 50** |
| Platform support | **0 / 20** — "supports 0 of 6 platforms" |
| Documentation | 10 / 20 — **10.1%** of public API documented, 20% required |
| Up-to-date dependencies | 10 / 40 |
| Likes / 30-day downloads | 3 / 79 |

The analysis failure is exactly what you would expect of a two-year-old package:

- `AccessibilityFeatures` has gained four getters (`autoPlayAnimatedImages`,
  `autoPlayVideos`, `deterministicCursor`, `supportsAnnounce`) that 0.5.1's
  implementation does not have.
- An `@override` misapplied in `lib/src/logs/logger.dart` — a directory this
  repo deleted long ago.

The knock-on is worse than the score. Because pana cannot analyze the package,
pub.dev cannot infer platform support, so the page shows **no platform chips at
all** — no Android, no iOS, no macOS. To anyone browsing, flutterware supports
nothing. And the description it introduces itself with is two products old:

> A collection of GUI tools to help Flutter development. This is a complement to
> your IDE with Flutter specific needs.

Meanwhile HEAD is 0.5.2 plus **56 unreleased changelog entries** — roughly 970
lines of them — covering the run cockpit, agent drive, scenes, comparison,
translations, store screenshots and the whole plugin shell.

**So: the first job is not marketing.** Anybody who hears about flutterware and
looks it up lands on that page, and no README or website is visible from there.
A version pub.dev can analyze is the precondition for every other item below.

### But the code at HEAD is in far better shape than that page implies

Measured by running `pana` locally against this worktree — **130 / 160**, versus
50 for what is published:

| Section | HEAD | Published 0.5.1 |
|---|---|---|
| Follow Dart file conventions | **30 / 30** | 30 / 30 |
| Provide documentation | **20 / 20** | 10 / 20 |
| Platform support | **10 / 20** | 0 / 20 |
| Pass static analysis | **40 / 50** | 0 / 50 |
| Up-to-date dependencies | **30 / 40** | 10 / 40 |

Two of the published failures are already gone. Documentation is at **52.5%**
(2014 of 3838 API elements), not the 10.1% that scored 10 points — well past the
20% threshold, so that item needs nothing. And pana now detects **all six
platforms**, so the pub.dev page will show its chips again the moment a version
that analyzes gets published.

The remaining 30 points are three specific, separable things:

**+10 — `package_config: ^2.0.0`.** The only dependency behind latest (3.0.0).
Widening the constraint is the entire fix.

**+10 — 330 formatting issues, every one of them in `lib/src/third_party/`.**
`dart analyze` is completely clean; all 330 are `dart format` disagreements in
the vendored `device_frame` and `highlight` copies, and **zero** are in
first-party code. This one is awkward rather than hard: `CLAUDE.md` bans bare
`dart format` because it diverges from what CI checks — but pana runs bare
`dart format` regardless, so the points exist only if the vendored tree
satisfies it. Vendored files are edited in place by policy, so reformatting them
once is sanctioned; it just needs to survive the next `vendor.yaml` sync.

**+10 — WASM compatibility, which is really an API question.**
`package:flutterware/comparison_report.dart` is not web-compatible because it
re-exports `src/comparison/report_io.dart`, which imports `dart:io`. The split
that would fix it *already exists and was made on purpose* — `report.dart` is
documented as staying "importable in a browser (the exported comparison page
parses it)" and `report_io.dart` is "the disk-facing half". The public library
then re-exports both and collapses the distinction. `lib/scenarios_report.dart`
does the same. Recovering the points means splitting the public library in two,
which is a change to published API for a cosmetic badge — **worth deciding, not
worth assuming.**

### What `dart pub publish --dry-run` still warns about

1. `sdk: ^3.13.0-0` — a pre-release constraint, so pub asks the package be
   published as a pre-release. Stable is now **Flutter 3.47.2 / Dart 3.13.2**, so
   both floors can simply drop their `-0` (`^3.13.0`, `>=3.47.0`) and the warning
   goes with them. This is the good outcome `CLAUDE.md` predicted: stable caught
   up to the floor on its own, with nobody republishing to make it happen.
2. `docs/` should be `doc/` by pub convention. We have **both**, which is worse
   than having the wrong one — `doc/` holds user docs and `docs/` holds specs.
3. `doc/ideas/cli/design.md` is checked in but gitignored.

Archive size is **8 MB compressed**, which is large but legal, and inherent:
`.pubignore` deliberately keeps `app/` — the whole desktop GUI — in the archive.

---

## 2. What we already have that is good

This is not a project that needs building before it needs launching. The
inventory is unusually strong:

- **A real product.** ~16 plugins: previews, scenarios, run cockpit + agent
  drive, scenes, comparison, store screenshots, translations, dependencies,
  assets, splash, launcher icon, lints, renders, dev stack, server inspection,
  changes.
- **Generated reference docs.** `docs/capabilities.md` is 2722 lines, generated
  from the plugin declarations rather than written by hand — so it cannot go
  stale. That is most of an API reference already paid for.
- **Long-form docs that are actually written.** `doc/scenarios.md` (542 lines),
  `doc/server_inspection.md` (379), `doc/database_watch.md` (88).
- **A README that is a genuinely good manual** — 442 lines, dense, precise,
  every claim anchored.
- **Screenshot machinery that photographs the product with the product.**
  `tool/screenshots.dart` drives `fw capture` at a fixed size, density and theme,
  so re-running leaves files untouched unless what they show changed.
- **A demo app with a story** — `examples/example` is a coffee-shop app
  ("Brewline") with scenarios, translations in two languages, flavors, a store
  listing and a devbar. That is a launch demo, already built.
- **The product can generate its own marketing assets.** `previews build-web`
  makes a browsable web page of previews; `fw render` emits SVG/PDF;
  `fw run scene video` exports clips; scenario reels record flows. A site whose
  gallery is *built by the thing it is selling* is a proof no competitor's site
  can copy.

### What is weak

- **The screenshots are stale.** All eight were shot before the plugin rename
  and show a four-item sidebar — Dependencies, Assets, **UI catalog**, Splash
  screen — from a product that now has sixteen. `tool/screenshots.dart` already
  targets `flutterware.previews`, so the fix is to re-run it, but only 6 shots
  are declared for ~16 tools.
- **The tab in every shot reads `claude/viewer-mcp-gui-s…`** — an agent branch
  name. Fine internally; scruffy and slightly baffling on a landing page.
- **`shell.png` is dead** — it shows version 0.1.0+1 and is referenced from
  nowhere.
- **`store_listing.png` shows grey skeletons** where app content should be. It
  is the most differentiated picture we have and it currently reads
  "unfinished".
- **The README covers 7 of ~16 tools.** Absent entirely: the run cockpit and
  agent drive, scenes, comparison, translations, lints, renders, launcher icon,
  dev stack, changes. The three most differentiated features are among them.

---

## 3. Decision one: what is flutterware *for*?

The current answer — "Development tooling for Flutter projects" — is accurate
and inert. Nobody searches for it and nobody repeats it. The options:

**(A) The suite.** *"A workbench for Flutter projects."* Honest. Risk: sixteen
tools from one author reads as a hobby project rather than a product, and it
invites the comparison nobody wins — "so, another DevTools?"

**(B) The bridge.** *"Declare your tools once. Use them from a window, a
terminal, or an agent."* This is the real novelty and nothing else in the
ecosystem ships it: one declaration in `tool/flutterware.dart` producing a GUI,
a CLI and an MCP server over the same cores. It also **turns the breadth from a
liability into a consequence** — each tool is cheap because the surfaces are
shared, so of course there are sixteen.

**(C) The agent story.** *"Your Flutter project, drivable by an agent."*
Sharpest, most of-the-moment, and true — `flutterware_act` drives a live app at
~2s per edit-reload-observe round trip. Risk: AI-tooling fatigue, and it
undersells the GUI, which is the nicest thing here.

**(D) Lead with one tool** and let the rest be discovered. This is the standard
advice — launch a product, not a platform. Widgetbook launched on previews
alone.

**Recommendation: (B) as the identity, (D) as the hook.** The tagline says
"declare once, three surfaces"; the first screenful is one concrete demo with a
picture. They are not in tension — (B) explains why the demo is one of many.

### Which demo leads

- **Scenarios** — *a `flutter_test` that screenshots itself*. Eight lines of
  code, and out comes a picture, a widget tree and the visible texts per step,
  plus a flow diagram. Small code sample, large visible payoff, cross-platform.
- **Store screenshots** — *your App Store listing, generated from your tests, in
  every language, inside a designed frame*. The most uniquely-owned thing here;
  nobody else does it. Blocked on the picture being real rather than skeletons.
- **Previews** — strongest for the widget-catalog crowd, but it competes with
  Flutter's own `@Preview` previewer and with Widgetbook, **and it is macOS
  only**. A hook that half the audience cannot run is the wrong hook.
- **Agent drive** — the most novel, and the hardest to show in a still image.
  This one wants a video.

**Recommendation: lead with Scenarios, second with Store screenshots** (once its
picture is real), and put agent drive in the launch video where motion sells it.

---

## 4. Decision two: how big is the launch?

**(A) Quiet republish.** Fix the blockers, refresh the README, ship 0.6.0, say
nothing. Days of work. Gets the pub.dev page honest, wastes the moment.

**(B) Staged.** Republish first, then the site, then announce — each step
shippable, and the announcement fires only when there is somewhere to send
people. Weeks.

**(C) Big-bang launch.** Site, video, blog post, Show HN, all on one day. Highest
ceiling, highest risk: sixteen tools' worth of first impressions land at once,
and a solo maintainer absorbs the issue traffic.

**Recommendation: (B).** With a hard rule: **do not announce before the docs
site exists.** A 442-line README cannot hold sixteen tools, and the announcement
is the one shot at the audience.

---

## 5. The plan, in five layers

Each layer is independently shippable and useful even if the next never happens.

### Layer 0 — Make the pub.dev page honest ✅ **done 2026-09-09**

Measured after the work: **160 / 160**, from 50 published and 130 at HEAD, with
all six platform tags restored. `flutter analyze` clean, 1457 root tests and
4545 app tests passing, and `pub publish --dry-run` down to a single warning
(uncommitted changes, which a commit clears).

| | before | after |
|---|---|---|
| Follow Dart file conventions | 30/30 | 30/30 |
| Provide documentation | 20/20 | 20/20 |
| Platform support | 10/20 | **20/20** |
| Pass static analysis | 40/50 | **50/50** |
| Up-to-date dependencies | 30/40 | **40/40** |
| Archive size | 8 MB | **7 MB** |

What was done:

1. **Floors lost their `-0`** — `sdk: ^3.13.0`, `flutter: '>=3.47.0'` in both
   shipping pubspecs. The promise did not move; it stopped being spelled as a
   pre-release, because stable is now 3.47.2 / Dart 3.13.2 and has passed it.
   `bump_flutter.dart --check` still agrees with the pin.
2. **`package_config` removed, not widened.** It turned out the published
   package does not import it anywhere — only `app/` does, and `app/` declares
   it itself. A dead direct dependency, and the only one holding the score
   down. **+10.**
3. **`repository:` and `issue_tracker:` added.** Neither existed. `repository:`
   is what makes the README's relative links resolve on the pub.dev page, which
   matters more here than usual because the README links `doc/` and `docs/`
   throughout.
4. **`docs/` and `doc/ideas/` excluded from the archive** — 4 MB of internal
   design specs no consumer compiles against, and the README's links to them now
   resolve to GitHub via `repository:`. Archive 8 MB → 7 MB.
5. **`doc/ideas/cli/design.md` moved into the specs tree.** It was a tracked
   file inside a `.gitignore`d directory — the state pub was warning about — and
   its own banner says it is a historical design note superseded by a spec. It
   is now `docs/superpowers/specs/2026-07-31-cli-design-notes-historical.md`.

### 160/160, and the two things that got it there

Decided: **full marks, enforced in CI.** Both remaining deductions were closed,
neither by the route the first pass predicted.

#### Static analysis, 40/50 → 50/50

The first pass claimed the repo's own formatter would fight `dart format`, and
never tested it. It does not:

1. `fvm dart format lib/src/third_party` — 330 files, +14542 / −11572.
2. `fvm dart tool/prepare_submit.dart` — **prints nothing, changes nothing.**
3. `dart format --set-exit-if-changed` — **0 changed.**

Both formatters agree on the reformatted state, so it is a stable fixed point
rather than a standing conflict, and CI (which runs `prepare_submit` and fails on
any diff) is satisfied. One-time, in vendored code, worth 10 points permanently.
**Re-run `dart format` on `lib/src/third_party/` after any `vendor.yaml` sync** —
that is the only ongoing cost.

#### Platform support, 10/20 → 20/20 — by claiming one platform *less*

The obvious route was to make every library WASM-ready. It is not available, and
the reason is worth writing down so nobody attempts it again.

**It is 15 of 27 public libraries, not two.** A transitive import walk finds
`dart:io` reachable from `comparison_report.dart`, `scenarios_report.dart`,
`devbar.dart`, `feature_flag.dart`, `flutter_test.dart`, `previews.dart`,
`previews_guest.dart`, `ui_catalog.dart`, `reel.dart`, `render.dart`,
`render_client.dart`, `scene.dart`, `server.dart`, `store_report.dart` and
`translations.dart`.

**And one of them can never be fixed.** `lib/flutter_test.dart` re-exports
`package:flutter_test`, whose `src/platform.dart` and `src/event_simulation.dart`
both carry an unconditional `import 'dart:io';`. That is an SDK package. The only
way to make that library WASM-ready is to stop re-exporting `package:flutter_test`
— which is the library's entire documented promise.

So the lever is the other end. A minimal probe package
(one library, `export 'package:flutter_test/flutter_test.dart';` and nothing else)
scores **20/20 — "Supports 5 of 6"**, with no WASM section at all. That is the
rule: **pana asks about WASM only of a package that claims web.** Claim five
platforms honestly and the question is never put.

flutterware was claiming web solely because `platforms:` said so, overriding
pana's own analysis, which had already concluded the package is not
web-compatible. Removing `web:` from that block took the score to **160/160**
with no code change at all.

**The price is real and it is the web chip on pub.dev.** It is not a truthfulness
price — the declaration was asserting something pana's analysis contradicted —
but anyone filtering pub.dev by web platform will no longer see flutterware.
Measured the same day: a consumer importing `ui_catalog.dart` builds under both
`flutter build web` and `flutter build web --wasm`, so the libraries a web app
would actually reach for do still work. `platforms:` is metadata; it compiles
nothing and forbids nothing.

The reasoning is written into `pubspec.yaml` above the block, because the
failure mode is somebody helpfully re-adding `web:` and getting a red CI run
whose message does not explain itself.

#### Enforced

`.github/workflows/analyze-and-test.yaml` gains a `pub_score` job: ubuntu,
pana pinned at 0.23.19, asserting **`granted == max`** rather than `>= 160` —
the rubric is pana's and it moves (this package was once scored out of 130), so
"lose no points" is the policy that survives it changing. The per-section
breakdown goes to the step summary; a failure prints the summaries of whatever
did not pass. Both paths were tested against real pana output before landing.

pana is pinned deliberately: an unpinned grader means a release on somebody
else's schedule can turn the repo red on a morning nobody touched it, and the
bump is where a new category gets read and answered.

### Version and changelog ✅ **done 2026-09-09**

**0.6.0**, in *three* places: both pubspecs (`0.6.0` and `0.6.0+1` — `app/`
carries the build number) and `flutterwareVersion` in `lib/src/constants.dart`,
which is compiled in so that `fw --version` is a fact about the build rather
than a read of whichever pubspec happens to sit beside it.
`test/version_test.dart` fails when the three disagree, and it caught the
constant on this bump — the pubspecs alone are not the version.

**The changelog went from 1149 lines to 117.** The `## Unreleased` section alone
was 970 lines of essay across 56 entries, and `## 0.5.2` another 138 — both
written in the register that belongs in a spec, not in a file someone reads to
find out whether an upgrade will break them. The versions below 0.5.2 show the
house style it drifted from: one line per change, no prose.

Two structural decisions:

- **0.5.2 was merged into 0.6.0 rather than kept.** It was never published —
  pub.dev has only ever seen 0.5.1 — so a reader upgrading has one list to read
  instead of two, and the version that never existed does not appear in it.
- **The motion churn is gone entirely.** 0.5.2 introduced
  `package:flutterware/motion.dart` and Unreleased removed it. Nobody on 0.5.1
  ever had it, so telling them it arrived and left is pure noise; only the line
  a git-dependency user needs survives.
  `Run`'s `defines`-then-`knobs` correction collapsed the same way — 0.6.0 just
  says `knobs`.

What is kept is what a 0.5.1 user has to act on: the `@Demo` → `@Preview` break,
the knobs rename, the previews scan widening, real shadows (with the
`runScenarios(testMain, shadows: false)` escape), and the pinned render date.
Then a compact list of what is new, the handful of fixes worth naming, and the
packaging changes.

`doc/screenshots/shell.png` was deleted with it — version 0.1.0+1, referenced
from nowhere — and `tool/screenshots.dart`'s comment about it corrected.

### Layer 1 — The README ✅ **re-cut 2026-09-09**

442 lines → 587, which is the right direction *because there is no site*: with
Layers 3 and 4 deferred, the README is the documentation home, so the job was
never to amputate it. It was to fix the order and the coverage.

**Order.** The old file spent its first 147 lines on installation, configuration
and the three surfaces before showing anything. It now opens with a hero — one
sentence, one picture, one install line — then the Scenarios sample as the lead
demo, then *why* one declaration buys three surfaces. Installation and
configuration follow, unchanged.

**Coverage.** It described 7 of 16 tools. There is now a 16-row index table at
the top of *The tools*, and new sections for the nine it never mentioned: Run,
Comparison, Scenes, Translations, Lints, Launcher icon, Renders, Dev stack,
Changes. The existing seven sections were kept as they were — the prose was
never the problem.

**Not changed:** the register of the body. The aphoristic voice stays where
`CLAUDE.md` says it belongs. Only the first screenful is written short.

Every anchor and every relative file link was checked; `prepare_submit` is clean.

### Screenshots — regenerated 2026-09-09, and **one blocking step remains**

Re-run from this worktree. The content problem is fixed: the old set showed a
four-item sidebar (Dependencies, Assets, *UI catalog*, Splash screen) from a
product that now has fourteen plugins, and named a panel that has since been
renamed to Previews. The new shots show the real rail, the real entry tree and
the current panel.

`ui_catalog.png`, `ui_catalog_device.png`, `dependencies.png`, `assets.png` and
`splash.png` are the five the script takes. `server.png` and `store_listing.png`
are not in it — see below.

**Blocking before publish: re-capture from `master`.** The window shows the
checkout it is running in, in two places at once — the tab (the branch) and the
address bar (the git worktree directory) — so every new shot currently reads
`claude/flutterware-public…` and
`fw:///worktrees/flutterware-publication-planning-05fe4a/`. That is the same
mistake the previous set shipped with (`claude/viewer-mcp-gui-s…`), and
`tool/screenshots.dart` warns about it in its own header: *"a shot taken on a
feature branch says so, in the README, forever."* `fw capture` has no flag to
suppress the chrome, and the name is read from git rather than passed in, so
there is no way to fake it from here.

After this branch merges:

```sh
fvm dart tool/screenshots.dart
```

From the main checkout the address reads `fw:///worktrees/~` and the tab reads
`master`. It is one command and a few minutes, and it is the last thing between
these pictures and a README anyone can look at.

**The preview and scenario shots are the coffee shop now.** The gap they
exposed was that `examples/example` had **no `@Preview` for any app screen** —
the demo folder was engine probes beside a fixture home page, which is a strange
thing for a previews tool to be missing. `demo/shop.dart` adds one entry per
Brewline screen (Welcome, Menu, Drink, Cart, Order placed), framed on a phone by
one `PreviewCanvas` line.

Two things had to move first:

- **The shop's theme was private to `_ShopAppState`**, so a preview of one
  screen would have rendered under Material's defaults — a picture of a shop
  nobody ships, which is the failure a catalog exists to prevent. It is a public
  `shopTheme(Brightness)` now, read by the app and the previews alike.
- **The screens need `CartScope` and `ShopStrings`**, so a bare widget throws.
  `wrapInShop` supplies both; the Cart entry gets a cart with something in it,
  because an empty one is a picture of the empty state — worth having, but a
  different picture.

`scenarios.png` is new: the section had no picture at all. It needs a run on
disk, because the panel draws the last one — so `fw run scenarios run` first,
noted in the script the way `server.png` documents its own recipe.

**A capture can photograph the loading state, and did.** The first run after
adding `demo/shop.dart` caught *"Building the guest… Compiling the catalog"* —
`fw capture` settles on frames, and the loading screen is a settled screen. Warm
the catalog and re-run, or check the picture. Worth fixing properly in `capture`
one day: settled is not the same as ready.

**A stale screenshot was hiding a documented regression.** The device shot came
back with no device frame: `home_page.dart`'s *On a phone* entry now opens on the
plain rectangle, while the README captioned it *"pinned to an iPhone 13 canvas,
drawn inside a device frame"* and the entry's own doc comment claimed it pinned
one. Neither had been true since `@Demo` → `@Preview` dropped `formFactor:` —
2026-08-01-previews-rename.md § *The regression this accepts* names this exact
entry as the visible casualty, "until form factor returns". Form factor did
return, as `PreviewCanvas`; the sample was never moved onto it, and the
checked-in picture went on asserting the old behaviour because nobody re-ran the
script.

Fixed by using the feature the way the README tells users to: the entry moved to
`demo/home_page_mobile.dart` — a file is a legal `PreviewCanvas` prefix,
*"precisely so one entry can differ from its neighbours"* — and
`tool/flutterware.dart` declares `Devices.iphone16` for that one file. Its
sibling in `home_page.dart` keeps the plain rectangle, so the pair is the
contrast again, and the shared `group:` keeps them in one folder. This is the
argument for regenerating screenshots as a matter of course: the picture is the
only thing that checks the claim.

**The device frame exposed a compositing bug, and the screenshot is how it was
found.** Enlarged 3×, the guest was a hard-edged rectangle sitting *on top* of
the phone: square corners over the frame's rounded bezel, the quad wider than the
screen cutout so it painted across the bezel, and the notch gone.

The cause is in `app/lib/src/capture/window_capture.dart`. A guest is not in the
host's layer tree — `Texture(textureId:)` is resolved by the platform compositor
at raster time — so a window picture is *two* captures composited, the guest's
own frame going into the hole the host raster leaves. The function's doc comment
said it "composites every live guest **under** it into the hole it left", and the
code called `img.compositeImage(host, guest, …)`, which is src-*over*.

Inside the hole the two are indistinguishable, which is why it read as correct
for so long. They differ only where the host draws something *above* the texture
— and a device frame is exactly that: a rounded screen inside an opaque bezel
with a notch over it, while the texture's rect is the full screen rectangle.

Fixed by making "under" literal: the guests are composited onto an empty canvas
and the host raster goes over them, so the host's own alpha decides where a guest
shows — the rule the compositor would have applied had the texture been in the
layer tree. `package:image` has no `dstOver`, hence a canvas rather than a blend
mode.

It affects every window capture with a guest in it, not just this screenshot:
`fw capture`, and any drive `observe` of the studio with a preview panel open.

**Still unfixed, both hand-taken and outside the script:**

- **`store_listing.png` shows grey skeletons** where app content should be. It is
  the most differentiated picture in the README — nobody else generates store
  listings from tests — and it currently reads "unfinished". Fixing it means the
  sample shop rendering real content in its store frame, not a capture change.
- **`server.png`** needs a live instrumented server with traffic, and its pids
  and timings make byte-identical output impossible, which is why the script
  cannot own it. Retake per the recipe in `tool/screenshots.dart`.

**Five shots for sixteen tools.** Run, Scenarios, Comparison, Translations and
Scenes have no picture, and each is a `Shot` entry plus an address. The README
sections for them are written to stand without one, so this is an improvement
rather than a gap — but they are the most differentiated tools and they are the
ones a reader cannot see.

`doc/screenshots/shell.png` was deleted: version 0.1.0+1, referenced from
nowhere, and `tool/screenshots.dart`'s comment about it corrected.

### The demo repo — published 2026-09-09

**https://github.com/xvrh/flutterware_example** — public, and it is a
*projection*. The source of truth is `examples/brewline/` in this repository;
`fvm dart tool/publish_example.dart` rebuilds the public tree from it. Nothing
is ever edited over there — the script deletes what it does not copy, so a
commit made on the public repo is lost on the next run.

Developed here, beside the tool it demonstrates, so a plugin change and the
change to the project that shows it off land in one commit and one review.

**Why not `examples/example`.** That package is a workspace member resolving
through the root pubspec with a path dependency, so it cannot be cloned and
run. And it is flutterware's *fixture*: most of its previews are engine probes
— Fox probe, GPU smoke, Compute probe, Model probe, Vector smoke — beside a
home page whose UI reads `FW_MARKER: <none>`. Published as-is, a stranger's
first impression of the product is a debug harness.

**Naming.** The repository is `flutterware_example`; the Dart package inside it
stays `brewline`, because `examples/example` already *is* the package
`flutterware_example` and two packages of one name in this monorepo would
confuse resolution.

#### The script publishes what `git` tracks, and that is the whole rule

The first version kept a list of things to leave out. **A list is always one
leak behind.** It already had `.dart_tool`, `build`, `.idea` and
`pubspec_overrides.yaml` on it, and it would still have published
`ios/Flutter/flutter_export_environment.sh` — which `flutter create` fills with
absolute paths to the machine that ran it — along with
`ios/Flutter/ephemeral/`, the same.

Asking git inverts the default: a file reaches the public repository only by
being deliberately added to this one, and every `.gitignore` already written is
enforced for free — including the per-platform ones Flutter generates, which are
precisely what keeps those two out. Verified after staging: 109 tracked files,
and a grep for absolute paths over the staged tree comes back empty.

Two other things the pre-publish check caught, both of the same family:

- The scenario typed the maintainer's own first name into the cup-name field.
  A public demo says `Ada`.
- The copied `analysis_options.yaml` began `include: ../../analysis_options.yaml`
  — a path out of the repo, which breaks the moment it is cloned. It includes
  `package:flutter_lints` now.

#### Keeping it honest

`pubspec.yaml` names `flutterware: ^0.6.0`, **hosted** — what a stranger
resolves. Development against this checkout goes through a gitignored
`pubspec_overrides.yaml`, so the committed pubspec never has to be edited to
publish, and the script refuses outright if it ever finds a `path:` dependency
in it. That guard is the one that matters: a demo pinned to a path is a demo
nobody can clone, and it fails silently until a stranger tries.

**Note it cannot resolve until 0.6.0 is published.** `^0.6.0` names a version
pub.dev does not have yet, so a clone today fails at `pub get`. That is the
right ordering — publish the package, then the demo is true — but it means the
repository is live and not yet usable.

### Moved to the `flutterware` organisation, 2026-09-09

Both repositories now live under the org, which was already owned and empty
(created 2022-06-15, zero repos):

- **github.com/flutterware/flutterware** — 6 stars and 3 issues carried across
- **github.com/flutterware/flutterware_example**

Transferred with `gh api -X POST repos/<owner>/<repo>/transfer -f
new_owner=flutterware`. Issues, PRs, stars, watchers, webhooks, **Actions
secrets** and deploy keys all come with it, and the old paths redirect for both
git and the web.

**The redirects are why this needs care rather than none.** Everything keeps
working, so a stale path is invisible until the day the redirect is not there.
Updated in the same pass:

- `pubspec.yaml` — `repository:` and `issue_tracker:`. This one is not cosmetic:
  pub.dev shows a verified-repository link by comparing that URL against where
  the package was published from, and a redirect is not the same URL.
- `tool/publish_example.dart` — the `remote` constant, **and** the success
  message, which turned out to hardcode the URL a second time.
- `examples/brewline/README.md` — the clone URL and the flutterware link.
- The local `origin`, and the publish script now runs `git remote set-url` on
  its working clone rather than relying on the redirect it had been silently
  using.

`homepage:` was pointed at `https://flutterware.dev` and then put back. The
domain is bought but serves nothing, and a dead *Homepage* link on the pub.dev
page is worse than none — the comment above the field says to move it when there
is a site.

Two git dependencies still point at the personal account —
`xvrh/project_tools.dart` and `xvrh/pub-scores`. They work through redirects;
whether they move is a separate decision.

### pub.dev: publisher and publishing are two different things

Worth writing down because they are constantly conflated, and only one is
affected by the move.

**A verified publisher is keyed to a domain, not to a GitHub organisation.**
`flutterware.dev` is bought, which is what unblocks it: pub.dev verifies the
domain once, through Google Search Console, at creation. Verification does not
recur — losing the domain later does not revoke the publisher, and buying one
does not grant rights to an existing publisher. The package currently reports
`publisherId: null`: individual uploaders, no publisher.

**Automated publishing does not require a publisher** — only uploader or admin
on the package. It is configured in the package's Admin tab as a repository
(`<org>/<repo>`), a tag pattern containing `{{version}}`, and optionally a
deployment environment; a matching tag then publishes with a short-lived OIDC
token. **This is the piece the transfer breaks**, since the repository is a
literal path — so configure it after the move, not before.

#### The publish workflow now uses OIDC

`.github/workflows/publish-on-pub.yaml` was the legacy path: it wrote a
`pub-credentials.json` from `OAUTH_ACCESS_TOKEN` / `OAUTH_REFRESH_TOKEN` with a
hardcoded expiry of **2023-08-08**. Rewritten — GitHub mints a short-lived
token for the run, pub.dev checks its claims against the repository and tag
pattern configured on the package, and nothing is stored. **Both secrets are now
read by nothing and can be deleted.**

Not the reusable workflow. `dart-lang/setup-dart/.github/workflows/publish.yml@v1`
is what the documentation recommends and it would do the exchange for us, but it
publishes with a bare Dart SDK — and this package depends on `flutter` from the
SDK, so resolution fails before publishing is attempted. So the job installs the
pinned Flutter (read from `.fvmrc`, like every other job) and performs the
exchange itself: one `curl` against `ACTIONS_ID_TOKEN_REQUEST_URL` with
`audience=https://pub.dev`, then `dart pub token add --env-var PUB_TOKEN`, which
stores *the name of the variable* rather than the token, so the secret never
reaches `pub-tokens.json` on disk.

**Corrected 2026-09-25: the reusable workflow is what publishes now.** Its
current `@v1` installs a Flutter SDK (`flutter-actions/setup-flutter`, newest
stable) before `dart pub get`, so the objection above no longer holds. On
Flutter 3.47.5 its three steps run clean against this package: `pub get` leaves
the tree unchanged, and the dry run reports 0 warnings. The hand-written
exchange is gone. `media.dart check`, which ran inside the old job, now runs at
the end of the pictures job.

The trigger is `v[0-9]+.[0-9]+.[0-9]+*` — the trailing `*` is what lets
`v0.7.0-beta.1` through. **On pub.dev's Admin tab this pairs with repository
`flutterware/flutterware` and tag pattern `v{{version}}`**; without that
configuration the token is refused and nothing publishes.

`tool/publish/check_version.dart` still gates it, and was tidied while it was
being read: it had a leftover `print(args)`, and it failed by throwing, which
buries the reason in a stack trace. It now writes a `::error::` line naming both
versions and exits 1. Verified both ways — a matching tag exits 0, a wrong one
exits 1 with the message.

### README, second pass — 2026-09-10

**588 → 254 lines**, and the order inverted: what flutterware *offers* now comes
before how to install it. The old file spent its first third on `pub add`, the
SDK story and the three surfaces before naming a single tool.

Sixteen tools, grouped into five things a reader might want — *See your widgets*,
*Test and get pictures for free*, *Run it and drive it*, *Know what is in the
box*, *Ship it* — each two or three sentences. The long passages on canvases,
group naming, scan bounding and `PreviewCanvas` prefixes are gone from here;
they are the per-feature documentation still to be written, and the README is
not where they belong.

Five pictures instead of eight. `dependencies`, `assets` and `splash` are still
generated — the documentation will want them — they are simply not in the README
any more.

### The screenshots are taken from a clone of the demo

Not from `examples/example`, and — after one failed attempt — **not from
`examples/brewline` either**.

`fw` refused every shot with `no worktree matches "brewline"`. The shell
addresses projects by *git worktree*, and the demo is a directory inside this
repository rather than a checkout of its own, so it is not in the list. That
`fw run previews entries` had happily printed
`fw:///worktrees/brewline/...` is a small inconsistency worth remembering: the
address a plugin *generates* is not proof the router can resolve it.

The answer was already on disk. `tool/publish_example.dart` maintains a clone at
`build/flutterware_example` — a real repository, nested where git ignores it —
and it opens as `~` like any main checkout. So the pictures are now taken from a
clone of the published demo, opened the way a reader will open it, with a
`pubspec_overrides.yaml` pointing `flutterware` at this checkout so the shots
show the code under review.

Two things fall out of that for free:

- **The branch name is gone.** The blocking item on every previous pass —
  every shot carrying `claude/flutterware-public…` and a worktree path — no
  longer applies: the clone's worktree is `~`. Screenshots no longer have to be
  regenerated from `master`.
- **The rail is a real project's.** One app with the tools an app declares,
  rather than this monorepo's sixteen plugins and three packages, which is a
  case no reader has.

`splash` stays on `examples/example`: the demo declares no splash, and this
repository's sample has a real `flutter_native_splash.yaml` with real warnings.

### The flow canvas has an addressable zoom

`?zoom=` on a scenario address, applied once on arrival and then the canvas is
the user's. There is no fit-to-content — a flow opens at half size wherever it
is — so how far back to stand is a property of the *link* rather than of the
run, and at 0.5 a scenario that splits shows three phones and no shape.

The screenshot is at `zoom=0.22`, where the fan-out is legible: one run
branching per drink, each branch running through to the confirmation. That it is
in the address rather than in a click is also what makes the picture
reproducible.

### Open bug: the previews panel paints a black phone for the demo

**The same preview entry renders in `examples/example` and comes back a black
phone from the demo project.** Same file — `demo/shop.dart`, copied — same
entry, same declared device.

Established, in this order:

- Not staleness or a cold catalog: three captures, all black, after the catalog
  had been compiled.
- Not the pixel ratio: black at 1 as well as at 2.
- Not the location: black from `examples/brewline`, from the clone under
  `build/`, and from a clone outside `build/`.
- **Not the guest.** `fw run previews screenshot` of that entry in the demo
  produces the correct picture — mean brightness 0.95, the coffee menu. So the
  entry compiles and paints; it is the *panel's* embedded engine that puts
  nothing in the texture.
- Not the compositing change made earlier for the device frame: a control
  capture of the same panel in `examples/example` renders correctly (phone-area
  mean 0.90).

The one thread not pulled: the demo's capture log says
`[catalog] attached to the daemon already serving <key>`, where
`examples/example` spawns its own. Whether a panel that *attaches* to an
existing daemon gets a guest that never paints into its texture is the question
to answer next. It was not answered here because the other daemons on this
machine belong to other sessions and killing them to test is not this branch's
business.

**Why it matters beyond a screenshot**: the demo is the shape of an ordinary
consumer project — a standalone app, not a member of this pub workspace — and
previews is the tool most likely to be tried first.

**Resolved on master** (#327, *Previews: wait for the guest's first frame
before a capture settles*): the capture settled before the guest's first frame,
so it photographed a texture nothing had painted yet. After rebasing onto it
both shots come from the demo again, and the copy of the shop previews that
had been added to `examples/example` as a workaround is gone.

### The store listing is real captures now

It was grey skeletons because the picture came from a *preview* of the frame,
which feeds it placeholders. The frame itself has always drawn a real
`Image` — so the fix was to give it real ones: `StoreShots` declared in the
demo (frame, copy catalog, both locales), `fw run store export` run for real —
**60 framed captures, zero failures** — and the shot taken of the store panel
rather than of a preview.

One trap on the way: the export and the scenario run have to happen **in the
clone**, which has its own build output. Running them in `examples/brewline` left
the panel saying *never exported* and drawing dashed placeholders — the same
picture as before, for a different reason. The shot list says so now.

### README, third pass — 2026-09-10

The second pass still read as generated: an em dash in most sentences, bold
lead-ins on every paragraph, headings that were slogans. The third is written
plainly, and it is shorter — 150 lines against 261 — because each tool now
gets a line where it had a paragraph.

- **The hero is a composition, not a capture.** One window says one thing;
  the top of a README has to say several. `app/tool/catalog/readme/hero.dart`
  is a preview entry that lays three of the window shots out on one board —
  the scenario flow as the window, the previews phone, the store strip and a
  card of the commands — and `tool/screenshots.dart` renders it with
  `previews screenshot` after taking the shots it is made of. Byte-identical
  across two renders.
- **The four feature pictures are a 2×2 table, cropped.** A markdown table of
  images is the usual README trick for halving their width, and it works on
  both GitHub and pub.dev (plain markdown images, so pub.dev's relative-URL
  rewrite applies). At half width a whole window is unreadable, so each card is
  another entry in the same file that crops one window shot to its panel, all
  at 4:3 so a row lines up.
- **Translations replaced the server shot.** `server.png` was hand-taken on a
  branch before the rail was redesigned and needs a live instrumented server to
  retake. Translations comes from the demo like everything else, once its
  export has run — and the order of the exports matters: see the note in the
  shot list.
- `assets`, `dependencies`, `splash` and `server` are deleted: nothing links
  them any more, and they rode in the pub archive. The per-feature docs can
  bring back the ones they need.
- The web studio (`flutterware.github.io/flutterware`, the studio compiled for
  the web over a recorded project, built in another session) is the first way
  in under "Try it", and the hero links to it.
- Not done: pubspec `screenshots:`, pub.dev's own gallery. pana processes
  those images itself, and whether the `pub_score` job still reads 160 with
  them declared is unmeasured — worth a try on its own, not folded into this.
- Known: the store and translations panels print relative times ("exported 27s
  ago"), so those two shots differ on every regeneration even when nothing
  moved — the one place the script's byte-identical contract does not hold.
  `CaptureMode.isCapturing` is the hook the catalog already uses for its
  timings.

### Docs: both, from one source — decided 2026-09-10

Per-tool guides live in `doc/`, markdown, reviewed with the code they describe;
`doc/README.md` is the index. A flutterware.dev site comes later and is built
*from those same files* — not a second copy that drifts. `docs/` stays the
design specs and the generated `capabilities.md`, which the guides link into
rather than repeat.

Written first, because they lead the README: Previews, Scenarios (its existing
page got the new opening; the detailed body is unchanged apart from dropping
the shadows and 3D/GPU sections, which are not what a reader comes for), Store
screenshots and Run. Then the rest the same day: Translations, Comparison,
Changes, Dependencies, Assets, Lints, Native splash, Launcher icon, Dev stack,
Scenes (marked early — its API says it is not yet a supported consumer
surface) and Renders. The index groups all of them.

Pictures only where the demo can take them honestly: it declares no Lints, Dev
stack, Scenes or Renders and has no splash config, so those pages have none
rather than a shot of this repository with a branch name in the tab.

Checking the pages found two things worth their own work, both flagged as
separate tasks: `scene video` on the example's `BannerScene` sat idle for ten
minutes and never finished, and ordinary refusals (`splash describe` with no
config, `scene video` on a still scene) print a `StateError` stack instead of
a one-line refusal.

The shape every page follows: a paragraph on what it's for, one picture, *Turn
it on* (the `tool/flutterware.dart` snippet), how it looks in the studio, the
commands, then a link into the reference. Every code snippet was compiled
against the demo, and every command run against it, before it went in — the
old README's scenario snippet tapped *Place order* from a screen that has no
such button, which is what not doing that costs.

The Run page has no picture: a capture of it needs a launched app, whose logs
and timings make a byte-identical picture impossible. It is the first candidate
for scenarios of flutterware itself over a recorded project, being explored in
another session — which is also why doc images are referenced by what they
show, so their source can change without touching a page.

### Two leaks the demo publish nearly shipped

- **`examples/brewline/pubspec.lock` was tracked**, and it pins `flutterware` to
  `path: "../.."`. It never reached the remote — the `.gitignore` the publish
  script writes into the published repo excludes locks, so `git add -A` there
  skipped it — but it was copied, and depending on a second line of defence is
  not the same as being right. It is gitignored here now.
- **The `path:` guard only read `pubspec.yaml`.** It now checks the lock too,
  for `source: path` rather than the word `path:`, which a hosted lock also
  contains. And it checks only files `git ls-files` reports, because the lock
  still exists on disk here and has to — it is the local resolution the demo is
  developed against.

### Layer 2 — Documentation (medium)

Mostly a routing job, not a writing job — the material exists.

- **Getting started** — new. The one thing genuinely missing: a first-15-minutes
  path.
- **A page per tool** — sixteen. Some exist (`scenarios.md`,
  `server_inspection.md`); most are a README section plus a screenshot plus what
  is already in `capabilities.md`.
- **Reference** — `capabilities.md`, published as-is and regenerated in CI.
- **Guides** — the agent loop, CI recipes (`compare-in-ci.md` exists),
  monorepo setups.
- **API docs** — `dart doc` output, free on pub.dev, currently at 10%.

### Layer 3 — The website (medium; the real decision)

Options:

| Option | Cost | Notes |
|---|---|---|
| **No site** — README is the front door | none | Fails the "sixteen tools" test |
| **GitHub Pages, one landing page** | low | Buys a domain and a picture, no docs home |
| **VitePress** | low | Markdown-first, excellent defaults, fast |
| **Astro Starlight** | low-medium | Best docs defaults, Pagefind search, i18n, and a bespoke landing page in the same project |
| **Docusaurus / Nextra** | medium | Heavier; versioning we do not need yet |
| **mkdocs-material** | low | Excellent, but Python in a Dart shop |

**Recommendation: Starlight**, on Cloudflare Pages or GitHub Pages. Markdown
in, so `doc/*.md` moves across nearly unchanged; and a hand-designed landing
page lives in the same repo without a second toolchain.

**And the thing that makes it ours:** generate parts of the site with
flutterware. `previews build-web` publishes a live catalog page; screenshots
come from `tool/screenshots.dart`; the agent-drive demo is a `scene video`
export. A docs site whose gallery is built by the product is an argument no
amount of copy makes.

**Domain.** `flutterware.io` is available (verified). `flutterware.dev` and
`flutterware.app` returned no records but the registry blocked whois, so treat
them as unknown, not free — check at a registrar. `flutterware.com` is
registered.

### Layer 4 — The announcement (small, once Layers 0–3 land)

- **A demo video, 60–90 seconds.** The single highest-leverage asset, and the
  only way agent drive reads at all. Flutterware can film most of it.
- **A clonable demo repo** — `examples/example` is a workspace member and
  cannot be cloned alone. A standalone repo makes "see it in 30 seconds" into
  `git clone && fw`.
- **Channels**, roughly in order: r/FlutterDev · Flutter Discord · X/Bluesky ·
  the Flutter newsletters · a dev.to or Medium write-up · Show HN (optional, and
  the one with real downside).
- **A written piece.** The best angle is not "here is my tool" but the argument
  underneath it: *one declaration, three surfaces, and why an agent should get
  exactly what you get*. That is a post people link to.

---

## 6. Risks worth naming now

1. **Breadth reads as unfocus.** Sixteen tools, one author. Framing (B) is the
   mitigation — breadth as a consequence of shared surfaces, not scatter.
2. **Previews are macOS only.** It caps which demo can lead. Decide before the
   README is cut: fix it, or lead with something cross-platform and say the
   limitation plainly.
3. **8 MB and a desktop app inside the package.** Unusual enough that a careful
   reviewer will ask. Pre-empt it in one README sentence.
4. **Prose register.** The writing is good and the density is wrong for a first
   screen. This is a re-cut, not a rewrite — and the register stays exactly as
   it is in the docs, where it works.
5. **Support load.** A launch that works produces issues, and there is one
   maintainer. Worth writing down in advance what is supported and what is
   "interesting, not promised".
6. **Flutter ships its own previewer.** flutterware already rides Flutter's
   `@Preview` rather than competing with it — that is a strong position, and the
   site should state it outright rather than leaving people to wonder.
7. **The floor/pin discipline holds only if nobody relaxes it.** Publishing
   pressure is exactly the moment somebody sets the floor to the pin. The
   `--check` in CI guards one direction only.

---

## 7. What I need from you

**Cheap and unblocking, whatever else you decide:**

1. **Ship Layer 0 now?** Publishing HEAD takes the pub.dev page from 50/160 and
   zero platform chips to ~130/160 and all six. It is hours of work and it is
   wrong today.

**Genuine forks:**

2. **Launch size** — (A) quiet republish, (B) staged, (C) big bang.
3. **The hook** — which tool leads the README and the site. My vote: Scenarios,
   with Store screenshots second and agent drive in the video.
4. **Previews on Linux/Windows** — pre-launch fix, or a stated limitation? This
   decides whether Previews can ever be the hook.
5. **The WASM split** — 10 pub points for splitting `comparison_report.dart` and
   `scenarios_report.dart` into model and IO halves at the public boundary. A
   real API change for a cosmetic badge; I would defer it.
6. **Domain** — is `flutterware.dev` worth checking at a registrar, or is `.io`
   (verified available) good enough?

Layer 0 is worth starting whatever the answers to 2–6 are: the page is wrong
today, and every other layer is invisible until it is not.
