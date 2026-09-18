# Comparison — what a worktree did to the pictures

**Date:** 2026-08-11
**Status:** **built and landing** (2026-08-11) — steps 1–6 of §12, previews and
scenarios both, driven from `fw compare` and from three tabs on the changes
screen. §12 records which commit did what. The static viewer and the MCP surface
are not built; §12 lists what else is left.

Rebased twice onto master, which shipped work this branch was independently
duplicating each time: `verb`/`target` on the step capture (§7a), then the
changes screen itself (§9), `position` on the capture, and the `fw capture`
landing fix. Every one of those collisions is recorded where it landed, because
the pattern is the interesting part: **two people solving the same problem from
the same codebase converge**, and the merge is then a choice of wording rather
than of design.

Every decision below was taken in the founding conversation and **all of them
are settled** — §13 lists them, including the two this build reversed and why.
§14 is the short list of constants deliberately left for measurement.
**Leans on:** `2026-08-10-worktree-changes-design.md` (the base definition, the
"delta is the unit" rule, the isolate discipline — **merged**, and §9 records
how the two screens became one), `2026-08-10-address-spaces-brief.md`
(the space grammar this consumes), `2026-07-30-scenarios-design.md` (the
artifact triple, FakeAsync determinism), `2026-07-27-compile-pipeline-performance-findings.md`
(every compile/reload number below).
**Prior art in-tree:** `HeadlessCatalog.auditAll` already keeps one guest warm
and reloads per entry — it collects errors where this needs pixels, and that is
most of the difference. `lib/src/scenarios/harness.dart:593` already writes the
per-step artifact triple this diffs.

## The one word

**Comparison.** Not *diff* — the files tab owns that word and the confusion
would be permanent. Not *golden* / *baseline* — nothing here is blessed,
approved, or committed; both sides are computed from git on demand.

| surface | name |
|---|---|
| space | `fw:///comparisons` |
| CLI | `fw compare …` |
| artifact index | `index.json` |
| the two sides | **base** and **head** |
| what a row can be | same · changed · added · removed |

## What this is

Run every preview and every scenario in two places — the worktree as it sits on
disk, and its base — and say what changed. It answers the question the files tab
structurally cannot: *the diff says 200 lines moved; did the app change?*

Two consumers, and the design serves both from one artifact:

- **A human** wants to look. Pixels, a wipe slider, a merged flow tree.
- **An agent** wants to read. A 38%-changed heatmap tells it nothing;
  `Padding.all 12→20` is actionable. The tree channel is also what makes the
  pixel channel *explainable* to the human — "38% changed, because the card got
  24px taller".

## 1. The base, and why the checkout is disposable

**The base is whatever the changes screen says it is** — merge-base with the
default branch, head is the worktree as it sits on disk including staged,
unstaged and untracked. One definition, two tabs; the comparison never computes
its own. Arbitrary refs (`agent-a..agent-b`) fall out of the grammar in §7 and
are deferred, not designed against.

Materialising the base is the only genuinely new expensive thing in the feature,
and the decision that makes it cheap is:

> **The base checkout is a build fixture, not state.** A shared
> `git worktree add --detach` per `(repo, sha)` under `~/.flutterware/bases/<sha>`,
> one `pub get`, render, and it may be garbage-collected at any time. What
> survives is the **shots**, and they are content-addressed.

Consequences worth stating, because each one is a feature nobody has to build:

- Five agents branched off the same master sha share one base checkout **and one
  set of base shots**.
- The explorer already knows every worktree's merge-base. Warming the base in the
  background is a scheduling decision, not new machinery — and in the steady
  state a comparison renders **only the head side**.
- A finished comparison's index is a few KB of JSON pointing into the shared shot
  cache. It survives its worktree for free. **Do not build teardown for
  something that costs nothing to keep.**

## 2. The shot cache

One entry, keyed on everything that can change its pixels:

```
key = sha1(entry closure ‖ asset manifest ‖ pubspec.lock ‖ axes ‖ knobs
           ‖ sdk version ‖ capture settings)
~/.flutterware/shots/<key>.raw      the frame
~/.flutterware/shots/<key>.tree.json
```

The cache is not a base cache. It serves the **head** side by the same key, so
re-running a comparison after an unrelated edit re-renders nothing, and it is
shared across every worktree on the machine.

Scenario granularity is coarser and deliberately so: one run produces a whole
tree of steps, so the key covers the scenario's closure and any app change
invalidates all of its steps. The owner's ruling is **replay all** — per-branch
replay is representable (`advance` bumps the deepest unvisited split) but buys
too little to justify the second code path.

Eviction is LRU by total size. Not designed here beyond that.

## 3. The skip rule — the whole performance story

The frontend_server knows each entry's transitive dependency set. If nothing in
an entry's closure differs between base and head, the entry **cannot** have
changed: skip both renders and report `same` without rendering anything.

This is what turns 213 entries into 14, and it has a second-order effect that
matters more than the wall clock: **the verdict list is complete before any
rendering starts.** Hashing is the whole computation, so within ~100ms the screen
knows all 213 rows' status and exactly which ones need pictures. It draws its
full shape immediately and the thumbnails fill in. No spinner, no blank page.

The trap is the inputs you forget. Assets, `FontManifest.json`, `pubspec.lock`,
l10n `.arb`, the SDK pin are all in the key. **Over-invalidate on doubt** — a
false "changed" costs one render, a false "same" is a lie the tool cannot detect.

## 3a. Correction — the compiler cannot answer the closure

§3 says "the frontend_server knows each entry's transitive dependency set".
**It does not, and cannot be made to.** Its program is the *generated
entrypoint*, which imports a wrapper for every entry visited so far
(`EntrypointGenerator._entrypoint`), so the source set it reports is the union
of all of them; `FrontendServerResult.newSources` is a delta against whatever
was already loaded, not a closure. Only a fresh daemon per entry gives a
per-entry answer, and that is a cold compile each — the cost the skip rule
exists to avoid.

`ImportGraph` follows imports instead, and that is the better shape rather than
a concession: **no daemon, no guest, no compile**, so the skip decision runs
before anything is started, which is what §3's second-order claim actually
requires. Measured on this repo: first entry 171ms across 118 files
(its own, its shell's, and `package:flutterware`'s — a path dependency inside
the checkout, so a change to the framework package correctly invalidates the
example's previews); ~1ms per entry after that, since closures overlap and each
file is parsed once.

It over-approximates deliberately: both branches of a conditional import,
`part`s, exports, unused imports. A file wrongly included costs one render; a
file wrongly left out reports a regression as clean, and nothing downstream can
detect that.

## 4. The diff kernel

Pure Dart, `package:image` is already a dependency, and it runs in `Isolate.run`
— the same discipline the changes scanner is held to.

**Raw in, raw out.** Previews' guest is already spawned with `--capture-raw`, and
`ScenarioRunArgs.captureRaw` exists for the same reason: PNG encoding is ~80% of
a 1× capture's cost. So the pipeline captures raw, diffs raw against raw, and
encodes PNG **only for what is displayed**.

**Threshold, no re-render.** The owner's ruling: both sides run on the same
machine against the same binaries, so a self-diff calibration pass is not worth
its cost. A pixel counts as changed when its maximum channel delta exceeds a
small epsilon; an entry is `changed` above a small fraction of changed pixels or
any cluster above a minimum size. The exact constants are to be tuned on real
branches, not decided here.

**Clusters are computed on the same pass** — connected components over the
changed mask, emitted as rects. One computation, three consumers: the agent's
coordinates, the UI's jump-to-next-change, and the crop for a zoomed thumbnail.

Shipped with one addition the first real text diff forced: **components are
grouped when there are too many boxes to read**. A font change moves every
glyph rather than a block, so a paragraph comes back as a box per word — 70 of
them drawn over the text they point at. Changes within a radius of each other
are taken as one region and the radius widens until few enough boxes are left.
Two numbers rather than one, because they answer different questions: nothing
is grouped at all below a dozen regions — five changed rows down a form are
five findings — and a tangle past that is grouped down to a handful. The
paragraph becomes one box; a second change across the frame is still its own,
because the radii stop widening. The radius is a fraction of the frame, because the same screen at 3× has
its word gaps three times as wide in pixels.

### Alignment, because a naive pixel diff is mostly noise

A card that grows 24px taller makes an unaligned diff report most of the screen.
Two answers, both wanted:

- **Tree-anchored**: match nodes by identity, diff their rects and properties,
  and let the pixel diff *illustrate* a delta already named.
- **Scanline LCS** on the two images: an inserted band reads as an inserted band,
  and everything below it stays `same`.

## 5. Channels

A step or entry is not "a picture plus extras". It is a set of **named channels,
each with its own differ and its own normalise/ignore rules**:

| channel | source | rules it needs |
|---|---|---|
| `pixels` | the raw frame | epsilon + minimum cluster |
| `tree` | `.tree.json` | node identity; property allow-list |
| `semantics` | `.semantics.json` | traversal order is significant |
| `texts` | `capture.texts` | none |
| `events` | ✅ `08db2c68` — network, analytics, logs, platform channels, captured between steps | channel + title, digits masked |

`events` is the reason to build the seam now rather than later. Tokens,
timestamps and request ids will make every event diff 100% noise without field
masks, and retrofitting a mask concept into a kernel that assumes "pixels have a
threshold and everything else is exact" means reopening it. It is also the
highest-value non-visual channel in the system: a duplicated request, a new
analytics call, an N+1 that appeared because a fetch moved into a builder — none
of it changes a pixel. FakeAsync makes the ordering deterministic, so alignment
is `(method, url-template, ordinal)`.

**Visual stays first.** The other channels are available, not promoted.

## 6. Previews

**Default axes, default knobs.** A specific value may be requested for a run; the
cross-product is not offered. Two devices × three languages is six times the cost
and six times the rows, and nobody asked the question that way.

### The clock is a gap, not a setting

`ScenarioRunArgs.clockOrigin` exists and its doc comment already names this
feature as its purpose. **Previews have no equivalent** — verified by grep. The
ruling is that previews should *always* pin dates, so this is a change to the
preview guest: render the entry body under `withClock(Clock.fixed(…))`, with the
same honest caveat the scenarios doc states — it reaches `package:clock` only,
and a raw `DateTime.now()` cannot be intercepted by anything, in any test.

Worth doing regardless of comparison: it makes every preview screenshot
reproducible.

### 6a. Corrected (2026-08-20) — the render lane is `flutter_tester`

As built, and as this doc originally assumed, the previews half rendered both
sides through the embedder (`HeadlessCatalog.captureAll`, since deleted): real
engine, real time, the settle waiting on a wall clock. Switched to the audit's
`flutter_tester` lane (`PreviewTestRunner.capture`, riding the
`2026-08-15-previews-audit-on-flutter-tester.md` harness) for the property a
pixel diff actually needs: under FakeAsync the shutter falls on the same fake
instant every run, so the same entry is **byte-identical** across renders —
animations, spinners and all — and the *still animating when captured*
complaint the embedder lane had to carry is structurally gone. The speed
argument rides along (an entry that animates for ever costs fake clock, not
real seconds), and §10's daemon numbers now describe only the single-entry
`previews screenshot` path.

What the lane gives up: `flutter_test` answers every HTTP request with 400, so
a preview of a remote image renders its error state on both sides — identical,
so it cancels, but a change to the remote half of such a preview is invisible
here. The audit has the same blind spot and sets it aside the same way.

### 6b. Corrected (2026-08-20) — a comparison runner builds in a claimed directory

Sharing the audit's lane surfaced what the scenario half had carried since the
start: a `TesterHost`'s artifacts — generated entrypoint, wrapper directory,
dill, asset bundle, log — are named by program under one `build/flutterware`,
and `exclusive` serializes nothing across *hosts*. The comparison's head
checkout **is** the worktree the panel's warm runners live on, so the two
collide by construction, and for previews destructively: the comparison
generates a *subset* harness whose wrapper indices are assigned within its own
list, so writing it into the shared directory renumbers — and prunes — the
warm harness's wrappers, which the warm compiler then picks up as an edit and
hot-reloads the wrong program into the panel's guest. Two `frontend_server`s
on one output dill can tear the file outright.

A constant second name (`previews_compare`) is not enough, because the base
checkout is shared machine-wide per sha (§ `BaseCheckout`) and only its
creation is locked — two comparisons against the same base render in it
concurrently on purpose. So each runner a comparison spawns builds in a
**claimed** directory, `build/flutterware/comparison/<pid>-<n>` inside its
checkout (`build_directory.dart`), released when the runner is disposed;
claiming sweeps day-old claims a crashed run left behind. Both halves,
both sides, GUI and `fw compare` — everything goes through
`PreviewsSide.render` and `ScenariosSide.runnerFor`, which is where the claim
lives.

### Identity and renames

Entries are keyed by id, and **a moved file reads as removed + added. That is
accepted.** The changes screen's `--name-status -M -z` pairing could fix it, and
deliberately will not: a rename produces two rows that are individually correct
and sit next to each other, which is a small cost against a second identity
scheme running underneath the first one.

## 7. Scenarios

### 7a. Auto steps get a derived label

Today an unnamed capture is `step 3` — an index-derived label that breaks the
moment anything is inserted. `_resolve(target, 'tap')` already knows the verb and
`finderForTarget` already knows the target kind, so a derived label costs
nothing to produce.

**Emit it structured, not as a baked string:**

```jsonc
"action": { "verb": "tap", "target": "pay", "kind": "key" }
```

Three reasons it must not be the string `tap(#pay)`:

1. The aligner can then distinguish *same verb, different target* from
   *different verb*.
2. It can rank stability by kind — `key > type > icon > tooltip/label > text`.
3. **A text target's label changes across the language axis.** `tap("Pay")` and
   `tap("Payer")` are the same step; a flat string cannot know that, and a
   structured one lets the aligner downweight `kind: text` and match on position
   instead.

`auto` stays as it is and `name` is not overwritten — which steps the author
named is real information. `action` sits beside them.

**Master shipped `verb` and `target` while this was being written** (`#87`,
rebased 2026-08-11), so the plan's `action: {verb, target, kind}` became
master's two flat fields plus one addition — `targetKind`, the trust rank,
which is what the aligner reads before deciding how far a label can be trusted.
Master's own test caught the rest: the richer per-`Target` descriptions this
proposed broke the rule that the error a verb throws and the step it records
use *one* spelling. A target reads back as what the author wrote, everywhere.

**Write `position` down.** `_capture` already computes
`'${_state.plan.path}#${_ordinal}'` — the split choice path plus the ordinal
since the last split — uses it for replay dedup, and throws it away. Putting it
in the step record is nearly free and gives the aligner a branch-scoped anchor,
so an insertion shifts positions within one branch segment instead of globally.

Built 2026-08-11, and building it corrected one thing: a choice in that path is
a branch's **index** in its `split`, not its label — `'0.1#3'`, not
`'guest.express#3'`. So renaming a branch leaves every position beneath it
untouched, and *reordering the map* moves them all. That is the right way round
for §7b, and it is why the two keys divide the work the way they do: branches
match by label, and positions only ever match *within* an already-matched
branch.

This change is **independent of comparison and should ship ahead of it**: the
flow view, `fw run scenarios list`, the MCP surface and the auto-write generator
all currently say `step 3`.

### 7b. Split makes it a tree

`split(Map<String, Future<void> Function()>)` replays the whole body per branch
and dedups the shared prefix by position, so what lands on disk is a tree: every
step carries `parent`, and a branch's first step wears the `branch` label. Splits
nest.

**Two trees side by side stop being readable at the first added branch** — the
entire right side shifts. The primary view is therefore **one merged tree, drawn
once, each node carrying an A/B state**; side-by-side is a per-node drill-down.

Alignment:

1. **Match branches by label.** Split map keys are authored strings — the most
   stable identifier in the system.
2. **LCS within each branch's linear run**, over the label sequence
   (authored name → action → position → content hash). It must be an LCS and not
   a map lookup, so that `tap(#next)` three times aligns correctly and a fourth
   inserted in the middle is one insertion, not three renames.
3. **A second pass pairs leftovers by content hash** within the same branch
   segment, reported as its own delta kind — *step retargeted*. This is what
   stops a `#pay` → `#pay_now` key rename reading as removed + added over an
   identical picture.

Delta kinds that exist only because of splits, and which must each report as
**one** delta rather than N steps:

| kind | reads as |
|---|---|
| branch added | "new branch: apple pay, 4 steps" |
| branch removed | one collapsed row, expandable |
| split introduced | the fork itself is the delta |
| split collapsed | likewise |

A removed branch's steps exist only on the base side. **Render them lazily on
expand** — rendering them eagerly costs a full base run the skip rule would
otherwise avoid.

When a scenario is mostly auto steps with `kind: text` targets, say so in the
header — *"6 unnamed steps, alignment is a guess"* — rather than producing a
confident-looking wrong diff.

### 7b-bis. What building the aligner corrected

Two things reasoning had wrong (`08db2c68`):

- **A linear scenario is a chain of single-child nodes, not a list of
  siblings.** Aligning sibling lists compares one step against one at each
  level and recognises no insertion at all. The run has to be flattened —
  every step until one forks — before the LCS can see it.
- **A retarget claim needs a verb on both sides.** Two steps that merely lack
  one share nothing but a gap; pairing them on that turns a renamed `Shot`
  into a claim about what the app did.

### 7b-ter. What a real suite corrected

Measured on a consumer's 54-scenario suite, on a branch where one test helper
went from finding a form's question by index to finding it by key:

- **A retarget is a fact about the test, so it is not a state.** It was
  `changed` whatever the channels found, on the reasoning that two identical
  pictures are the reason to speak. They are also the proof the step did the
  same thing. Counted as a change, that one helper put 221 steps and four whole
  flows among the findings, around the one flow that had changed. The channels
  decide the state now; the retarget is a note under it and a `retargeted`
  field in `index.json` — and it is said on a step that *did* change too, where
  it matters most: the difference may be the widget the step now reaches.
- **A step's path is not an id.** `tap "Next"` three times is one path, and a
  finder with its identity hash taken out — `widget with key [GlobalKey#]` — is
  every question of a form under one: 51 of the 54 scenarios repeated an id,
  and one flow had 17 for 101 steps. Everything addresses a step by its id, so
  *Next* walked in a circle, a link opened the first of the group, and the
  frames map kept one picture per group. Ids are claimed once each now —
  `tap "Next" (2)` — by the writer, and again by the reader for a file that
  predates it.
- **Print what differs.** Two 150-character finder descriptions that differ in
  the middle, printed whole in a failure's red, read as an error nobody could
  parse. The note prints the words that differ, and a note is red only under a
  failure.

### 7c. Axes — always the default

A scenario's folder profile offers devices and languages, and a comparison takes
**the first of each**, exactly as a bare run does. Never "whatever the last
manual run used": a comparison that inherits transient UI state is not
reproducible from its address, and two people looking at the same `<id>` would
see different pictures.

### 7d. Ranking

`pass → fail` outranks every pixel delta and sorts to the top. A scenario that
now fails is the single most valuable output of the feature.

## 8. The artifact

```
~/.flutterware/comparisons/<id>/
  index.json          the whole verdict; a few KB
  <rev>/              per-revision deltas — diff PNGs, cluster rects
```

As built (`ComparisonArtifact`):

```jsonc
{
  "base": "0c05335f…", "head": "/Users/…/worktree", "ms": 4575,
  "counts": { "added": 1, "changed": 4, "skipped": 6 },   // both halves
  "previews":  { "rendered": 0, "ms": 178, "counts": {…}, "items": [ … ] },
  "scenarios": { "ran": 4, "skipped": 0, "ms": 4397, "counts": {…},
                 "note": "…",                             // only if it refused
                 "items": [ … ] }
}
```

A previews item, and a scenario's step, are the same row:

```jsonc
{ "id": "demo/card.dart#card", "state": "changed", "label": "tap \"Accept\"",
  "channels": {
    "pixels": { "changed": 0.0038, "sizeChanged": false, "width": 390,
                "height": 844, "clusters": [{"x":12,"y":40,"w":180,"h":64}] },
    "tree":   { "deltas": [ … ] },
    "texts":  { "added": ["We use cookies"], "removed": [] },
    "events": { "added": ["network GET /order/#"], "removed": [] }
  } }
```

A scenario adds `branches` and holds its rows under `steps` instead of
`channels`.

**Two named halves, never one flat list.** `items` at the top of a file holding
both means previews to whoever wrote it and everything to whoever reads it. The
counts *are* merged, because "did this branch break anything" is a question
about the branch: one preview that broke and one scenario that broke is two
broken things, and which half they came from is the second question.

**Everything is precomputed in Dart** — diff images, cluster rects, tree deltas,
alignment. The GUI panel, the MCP tools and (later) a static HTML page are all
dumb viewers over the same `index.json`. Three hosts, one artifact, which is the
pattern the inspect kit already proved. The HTML page only gets expensive if it
is made to do the comparing.

### 8a. What folding the scenario half in corrected

Both found by reading the file the CLI had been printing all along (`f7f8…`):

- **A scenario that gained a step was reported as `added`.** The verdict took
  the worst state among its steps, and `added` outranks `changed` — so a flow
  that has existed for months read as new, and sorted above one that genuinely
  came out different. A step's own word does not carry up: at scenario level,
  `added`/`removed` mean the scenario exists on one side only.
- **A rename above a `split` reported every branch under it twice.** The LCS
  drops the renamed step's pair, orphaning each branch on *both* sides — once
  as gone, once as new, over a flow whose shape did not change at all. Orphans
  are now matched by label before being reported, which also aligns their
  bodies; what has no counterpart is the case that handling was written for.

Rows that were never run — skipped, or present on one side — are **in** the
list. A missing row tells a reader nothing; "skipped" tells them the tool looked
and found no reason to run it. Same reason a harness that would not build
records a `note`: an empty list is also what a project with no scenarios leaves
behind, and a reader who cannot tell those apart reads silence as a clean bill.

### 8b. The artifact is API (2026-08-28)

The first consumer to host one asked for a typed reader, which is the moment a
file stops being an internal format. `package:flutterware/comparison_report.dart`
is it, and the shape of the answer is the one `scenarios_report.dart` already
argued: **the model moves, it is not copied.** A second reader written beside
the writer is two hand-kept copies that drift one field apart; the model these
classes describe already had three careers — `fw compare` builds it, the
studio's panel renders it, the exported page parses it in a browser — and a
consumer's script is the fourth, not a new format.

**What is published is the file's vocabulary.** The rule that decided every
case: *a type is published iff it appears in `index.json`, or produces
something that does, from inputs that are themselves public.* So `PixelDiff`
and `TreeDiff` are published including their `of` — they **are** the serialized
channel payloads, and you cannot export a class while hiding a static. So are
`ComparedItem`, the four channels, `ScenarioComparison`, `BranchDelta`,
`FrameRef`. What fails the last clause stays in `app/`: `ScenarioStepShot`
holds live rgba and a live tree straight out of the runner, `AlignableStep` and
the aligner compute step identity and never reach the file. That split is why
`scenario_comparison.dart` came apart — it was doing two jobs — and why
`compareScenarioSteps` is a function in `app/` rather than a static on the
model.

**Versioned, and the gate is refuse-don't-guess.** `comparisonReportVersion`
goes in the file; a reader handed a higher major throws rather than decoding
half of it. Added fields never bump it — an older reader ignoring a new key is
what makes adding one cheap, and every field the widened `ComparisonIndex`
carries was added to a file that shipped without it.

**Two dialects, and the file says which.** There are two `index.json`s and the
verdict in them is identical; only the frames differ.

| | previews `shots` | scenario step `frames` |
|---|---|---|
| cache — `~/.flutterware/comparisons/<id>/` | `ShotCache` keys | absolute paths to headerless `.raw` |
| export — `<out>/web/` | `shots/<key>.png` | `frames/s<i>/<name>.png` |

Only the export is portable, and it cannot be otherwise: a cache key is
computed from a closure fingerprint nothing outside the runner reproduces, and
a raw frame needs an encoder the consumer does not have. So the reader parses
**both** — refusing the cache dialect would break `fw compare --json | parse`,
the cheapest CI hook there is, for a reason that has nothing to do with the
verdict — and only frame *resolution* is dialect-specific:
`ComparisonReport.frame` refuses on a local report and names `--report=` as the
fix. The dialect is written down (`"frames": "local" | "relative"`, absent
meaning local) rather than sniffed from whether a path looks absolute, because
a reader that guesses wrong hands back paths that do not exist. It is stamped
*after* the export rewrites every reference, so it is a promise the frames are
there.

**One ranking, not one per surface.** `rankComparedFindings` is published and
`runCompareAction` calls it, because the CLI, the MCP action and a consumer's
script reading the same file may not have different ideas of which rows are
worth attention or in what order.

The one thing nothing asserted before and does now: the model is parsed **in a
browser**, so `test/comparison/purity_test.dart` fails the build if anything
under `lib/src/comparison/` reaches `package:flutter`, `dart:ui` or `dart:io`.
`report_io.dart` is the single seam that may, exported alongside the model and
imported by none of it. Without the guard that breaks at `flutter build web`
time in `app/`, a long way from the import that caused it.

### Revisions

Latest is enough, **except while a re-run is in flight**: the previous revision
stays browsable, and the running one is browsable as it fills. So the index
carries `latest` and `running` pointers, and a row shows the new result the
moment it lands, the old one marked stale until then.

The revision is **not in the address**. It is two states of one comparison, and
an address naming a revision would be pasted into agent output and go stale
within a minute. A segmented *previous · running* control in the header is where
something that transient belongs.

## 9. Where it lives — corrected (2026-08-11)

**Not its own space. Three tabs on the worktree's changes panel**, alongside the
file diff. **Merged with that panel on 2026-08-11**, when #88 landed it — which
had independently chosen the same `changes` slot, the same reservation shape,
and the same `fw capture` fix (`shownScreenId`). What differs is that its screen
reads git and so renders for a worktree **nobody has opened**, which these two
halves cannot: they need the previews and scenarios cores, and those need a
resolved config. So the files tab stands alone there and the other two say to
open the checkout.

```
[ files ][ previews · 14 of 213 ][ scenarios · 5 ]
```

This reverses §13.8, and the reversal is worth writing down because the original
was argued from the wrong thing. "A comparison spans two plugins and needs a
session on both sides" is a fact about the *runner* — and `fw compare` already
disproves it, running with no session on the base at all, materialising a
checkout and driving its own. What a comparison spans is not what a screen
belongs to. The case that matters is *this work against its base*, which is a
fact about one worktree.

**Files, previews and scenarios are three renderings of one delta** — same base,
same scope, same question. The argument for putting them together is not
tidiness: **files is free and instant while the other two cost seconds.** Behind
tabs on the panel you already open to read a diff, the expensive halves get
discovered. In their own space they have to be remembered, and a feature that
has to be remembered is used twice.

The address falls out of the existing grammar for free, since a plugin owns
everything after its own segment:

```
fw:///worktrees/<name>/<changes>/previews/demo/card.dart#card
fw:///worktrees/<name>/<changes>/scenarios/test/shop.dart#Checkout/signed in/3
```

The base is **the project's**, not a second answer: `fw.changes(base:)` is read
before anything is inferred, because a comparison against `master` on a screen
whose other tab says `develop` is exactly what §1's one-definition rule forbids.
The inference *fallback* still differs in detail between the two — both take the
default branch, by slightly different routes — and that is the remaining gap.

`fw:///comparisons/…` is **not** spent. It is where the deferred `agent-a..agent-b`
case goes — the one that genuinely has no worktree to live in — so the space
slot stays reserved for the case that needs it.

**A tab exists only if its plugin is declared.** A previews tab that always says
"no previews here" should not be there; the explorer already drops a column
every worktree leaves empty.

### The screens

~~**Entering a tab runs that tab.**~~ **Reversed 2026-08-20 — nothing runs on
its own; one explicit Compare per half.** The original said no Run button
because "a tool that asks permission to do the only thing it does is a tool
nobody opens" — but that argument leaned on the other half of the pair, the
per-tab estimate that made the cost visible before the click, and the estimate
was built, measured at four minutes on a real catalog, and removed. What
shipped was the worst of both: a tab tap (reachable four ways, drive `navigate`
included) started git checkouts, `pub get` and compilers behind one line of
centred text, with no way to watch, stop or aim it. The measured effect was
reluctance to open the panel at all — a tool nobody opens, by the other road.

The model now: **the tab always shows for free** (the last run, kept on disk
per half under the worktree's comparisons directory, marked *moved since* when
HEAD or the base has), and one **Compare** press per half starts the machinery
— the same button is the re-run, the retry and the refresh. While it runs, a
strip narrates the phase (checkout, pub get, hashing, *rendering n of m*) with
an elapsed counter and a **Stop**; the plan's totals drive a determinate bar,
ghost rows hold the place of every verdict still owed, and each verdict lands
the moment it is answerable rather than in one burst at the end. The base is a
control on the strip (default · HEAD~1 · any ref), not a caption. Files still
runs nothing and needs no button; a run already in flight is joined, never
restarted.

**The header** names both sides and carries the counts (broke · changed ·
added · removed · skipped) and, once a half has run, its receipt — wall clock
and recency. Lists are sorted by **severity**, not by name — head-broke, then
scenario failed, then branch removed, then percent changed. The top row should
be the thing most likely to be a mistake.

**Getting there from the live panels.** Previews and scenarios each offer
*compare against base* on the entry you are looking at, and a comparison row
offers *open live* back. A **jump, not a toggle**: the previews panel is live —
a running guest with knobs and axes you can turn — and a comparison is two
frozen shots. `ShellController.goToWorktree` is the same move already argued for
("the same place, in another checkout").

**A preview.** The two frames in one stage with five modes — *side by side ·
slider · onion · blink · pixels*. Under it, the tree channel as prose:
`Padding.all 12→20`, `FilledButton.background #1A1A18→#378ADD`, and the height
delta called out because it explains the pixel percentage.

**A scenario.** The merged tree of §7b: a shared trunk, branch lanes, each node a
thumbnail with a state ring, added and removed branches collapsed to a single
labelled row.

## 10. Budget

Measured elsewhere, cited here; the totals are arithmetic on those and are
**estimates, not measurements**:

| | measured | source |
|---|---|---|
| daemon, first client connect → ready | 2313ms | compile-pipeline findings |
| daemon, second client | 19ms | ditto |
| entry switch | 6–16ms compile + 66–130ms reload | ditto |
| scenario warm 3-step run | 123ms | S4 findings |
| PNG capture | a few ms each | S4 findings |
| `fw run scenarios run` process | ~2.5s | scenarios agent-surface memo |

So a preview costs ~80–150ms warm per side. 200 previews ≈ 20s per side cold;
both sides in parallel ≈ one side's wall clock; **and with the skip rule a
typical branch is a handful of entries, so seconds.** Watch mode is then close to
free — the head guest is already warm, so a save re-renders only the affected
entries.

## 11. Failure, tolerantly

| situation | reported as |
|---|---|
| head renders, base does not | "already broken on base" — head-only, not an error |
| base renders, head does not | the loudest row in the report; this is a regression you introduced |
| neither renders | one muted line |
| scenario passes on one side only | outranks every pixel delta |

### 11a. The base is rendered with the head's tooling

Found by running it (`f554fced`). The generated entrypoint, the scanner and the
daemon all come from the checkout the command was typed in; only the *sources*
come from the base. So a generator that emits a call into `package:flutterware`
meets whatever version the base checkout resolves — and comparing this repo
against master fails to compile the base entirely, because `withPreviewClock`
does not exist there.

It is not self-hosting-specific: any project whose base commit pins an older
flutterware can meet the same skew, and a branch that *moves the pin* meets it
by definition — which is the branch where seeing what moved in the pictures is
worth the most. Rendering each side with its own tooling would mean running
two versions of the tool, which is a much larger call than this feature; the
honest position for now is that a base too old to build with today's generator
cannot be compared, and says so.

**Corrected in the building (2026-08-28): one refusal, not a row per entry.**
This section used to promise a per-entry result — every entry reported as
"this side could not render it", landing on the severity ladder rather than
ending the comparison. Measured against a base whose catalog did not compile,
that produced twenty-four identical rows each saying one sentence, burying
everything else the run found. It is the argument the split branches already
settled: one decision in the source is one row, however many things hang off
it. So the previews half throws `SideDidNotCompile` → `ComparisonRefused`, and
`fw compare` prints the compiler's whole output — head *and* diagnostics,
because a refusal naming neither the file nor the symbol is barely better than
the twenty-four rows — and **exits 64**. Reproduced 2026-08-28 by comparing
this repo against `acfd5fcd`, a commit before `runPreviewHarness` existed.

The scenario half absorbs the same skew differently, and deliberately: it is
not the whole comparison, so it records a `note` on its half and lets the
previews verdict stand. That note is the *only* thing separating "the harness
would not build" from "this project has no scenarios" — both leave an empty
list and both print `0 scenarios, 0 run, 0 skipped` — so it is written into
`index.json` and printed above that summary line. It was neither, for a while,
and a consumer read the silence as a pass.

**SDK mismatch hard-fails**, for now. If base and head pin different Flutter
versions, every pixel differs for reasons that are not yours. Detect it by
comparing `.fvmrc` and the resolved `flutter --version` between the two
checkouts *before* rendering anything, and refuse with both versions named. This
is a real gap and it is accepted deliberately: it gets revisited when `fw`
handles SDK management.

**Reversed twice since; what holds on 2026-09-11.** The refusal went when
flutterware stopped discovering SDKs — a detector that resolved one from the
base's pin was discovery by another name — and for a while a cross-version
comparison ran unwarned. It now runs *and says so*: `SdkPin` reads each
checkout's pin as text, never to choose an SDK, and the verdict carries a
caveat naming both pins and the SDK that drew both sides. The same verdict
field carries the sibling skew this section did not foresee: the base is
captured by the base's own `package:flutterware`, so a bump to it changes how
widget trees are *read*. `GuestInspector.treeFormat` stamps each tree, and
tree differences between two formats are carried without counting — measured
on a consumer's bump that touched only docs and the pubspec, 109 rows had
been reported changed with not one pixel moved.

## 12. Build order

1. ✅ **Derived step labels** (§7a) — `c7bb9d9c`. Independent, improves four
   existing surfaces, and the aligner is worthless without it.
2. ✅ **Preview clock pin** (§6) — `9e29155d`, smoke-tested through a real
   guest — and the **SDK-mismatch detector** (§11) — `bbc2ac6f`.
3. ✅ **Shot cache + skip rule** (§2, §3) — `55207ba6`; **base checkout**
   (§1) — `b396d464`; **the closure** — `1445faf8`, and it corrects §3: the
   compiler cannot answer it. See §3a.
4. ✅ **The diff kernel** (§4, §5) — `9b8379fd`. Pixels, tree, texts, the
   severity ladder. Not yet run in an isolate: it has no caller to be off the
   UI thread of.
5. ✅ **`fw compare` + `index.json`** (§8) — previews in `f554fced`
   (prerequisites in `1445faf8`), scenarios in `08db2c68`, **both halves in one
   artifact** after that. Measured on this repo against `origin/master`: 6
   entries, 0 rendered, 6 skipped, 142ms; change one label and it renders that
   entry alone on both sides. Scenarios run per-scenario on a warm runner,
   skipped by the same closure rule. MCP is not wired. Corrections these forced
   are in their commit messages; the structural ones are in §8a and §11a.
6. ✅ **The screen** (§9) — three tabs on the worktree's changes panel rather
   than a space of its own; the reversal and its reasoning are in §9. The
   previews tab is master/detail with the five-mode stage; the scenarios tab is
   the merged tree on the scenarios panel's own graph, with a step **pushed over
   the flow** rather than banded under it — a phone frame is portrait and a band
   is landscape, so two of them side by side came out postage-stamp sized.
   Estimates ride the tabs; a half runs when its tab is opened.
7. ✅ **The static viewer** — dumb as promised: it reads `index.json` and
   renders, with no diffing logic of its own. **Corrected in the building
   (2026-08-11): it is not a hand-rolled HTML page.** #92 had already
   established the house pattern — a data-free Flutter web bundle
   (`lib/main_comparison_web.dart`) reusing the panel's own widgets, built
   once into `app/build/comparison_web_viewer` and copied per export — so the
   five-mode stage and the merged tree came for free instead of being
   rewritten worse in JS. What made it possible is a seam the panel needed
   anyway: `ShotStore` (cache-backed on the panel, URL-backed on the page),
   plus `fromJson` mirrors for every row type, which had only ever been
   written. The export (`fw compare --export`) encodes the raw cached frames
   to PNG — the one place that pays the encoding cost the cache exists to
   avoid, because a hosted page downloading 2.5MB of raw rgba per frame is
   the worse deal. The page must be served; `file://` cannot fetch beside
   itself.
8. ✅ **The PR report** (`fw compare --report=<dir>`) — `comment.md` with a
   findings table, a `mosaic.png` (one row per finding, capped at 20, base
   beside head, clusters boxed), and the page under `web/`. fw emits, the
   workflow hosts and posts: the comment carries `__MOSAIC_URL__` /
   `__VIEWER_URL__` placeholders because where images live is the
   repository's business. Recipe in `docs/compare-in-ci.md`. Also the run
   `compare` was, until now, dispatched but absent from `fwCommands` — it is
   in `fw help` and the capability document from here on.
9. ✅ **The MCP surface** — `fw run previews compare`, one orchestration
   behind all three surfaces: `runComparison` in
   `app/lib/src/comparison/compare_command.dart` is what `fw compare`, the
   action, and MCP invoke all call. The action lives on the previews core but
   spans both plugins, which a core cannot do — so the *session* installs the
   runner on construction, the same hook-not-dependency move as
   `busyStatusFor`. Returns counts, ranked findings and the `index.json`
   path; `export`/`report` parameters produce the artifacts above.
10. Later: `events` channel, arbitrary A/B, and the three below.

### What is left, in the order it would bite

1. ✅ **A refresh control** — subsumed by the explicit-start reversal
   (2026-08-20): the Compare button re-runs a finished half, retries a refused
   one, and `refresh()` is gone.
2. ✅ **A base selector** — built 2026-08-20 as the strip's base control
   (project default · HEAD~1 · any ref), which rebuilds the environment so the
   one-definition rule holds.
3. **Two live revisions** (§8's *previous · running*), which nothing needs until
   a comparison is slow enough to browse the old one during. The kept last run
   (2026-08-20) is the between-runs half of this; browsing it *while* the next
   run works is still not built — Compare clears the rows.
4. **Serving the exported page from `fw`.** The scenario page has
   `CatalogWebServer` in front of it in the GUI; the comparison page is
   export-only and says "serve it over HTTP" without offering to.

### What a comparison of *this* repository still reports, and why

The shape changes with the tooling, and it is §11a every time. The embedder
era's version: four teardown-dialog previews `changed` with *on base: this
side cannot tell whether anything was still animating*, because the base's
`package:flutterware` predated the animation-settling fix. The tester-lane
switch (§6a) replaced that with its own: every re-rendered entry `wasBroken`
with *this checkout's package:flutterware predates preview capture*, because
the base's harness does not know the `output` argument and renders without
photographing. Both self-resolve the moment the change lands on the base
branch; the row's job is to name the skew rather than read as a broken entry.

## 13. Decided — do not relitigate

1. Head is the worktree as it sits on disk, uncommitted and untracked included.
2. The base checkout is disposable; the shots are what persist, content-addressed.
3. Threshold, no confirmation re-render — same machine, same binaries.
4. Default axes and default knobs; no cross-product.
5. Previews pin the clock, always.
6. Replay a whole scenario; no per-branch replay.
7. Merged tree is the primary scenario view; side-by-side is a drill-down.
8. ~~Its own space, not a plugin.~~ **Reversed 2026-08-11** — three tabs on the
   worktree's changes panel. `fw:///comparisons` is kept for the deferred
   two-worktree case. See §9.
9. Latest revision is enough, plus the running one while it runs.
10. SDK mismatch hard-fails until `fw` owns the SDK.
11. ~~Entering a **tab** runs that half; there is no Run button.~~ **Reversed
    2026-08-20** — nothing runs on its own; each half runs on its own explicit
    Compare, the tab shows the kept last run for free, and Stop exists. The
    original was argued from a per-tab estimate that had already been removed;
    see §9's *The screens* for the full reasoning.
12. Scenario axes are the profile's first of each — never the last manual run's.
13. A renamed preview entry reads as removed + added. No rename pairing.
14. The static viewer ships in v1 and stays a dumb reader of `index.json`.

## 14. Left unset on purpose

The pixel epsilon and minimum cluster size (§4) and the shot cache's eviction
policy (§2). All three are constants that want a real branch and a full disk to
tune against, and picking them from an armchair would only make them look
decided. Measure, then write the numbers here.
