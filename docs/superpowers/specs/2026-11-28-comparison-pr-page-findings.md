# The comparison's pull-request page: what makes it hard to use

Findings only, no code changed. The surface is what `fw compare --export` and
`--report` write (page, `comment.md`, `mosaic.png`), plus what an agent gets
from the same run.

## The short answer

The page does not answer "does this branch change what a user sees, and where?"
on its first screen.

- `changed` covers both a screen that moved and a screen that looks the same.
  Most of the time it is the second.
- The list is ordered by state, then by id. Nothing puts a visible change first.
- One cause is reported once per screen it touches, and nothing on the landing
  tab says they are one.
- When there is a visible change, it is drawn too small to read.

## How this was measured

- The kept runs in `~/.flutterware/comparisons/` from real projects: 7 runs,
  858 changed units (preview entries and scenario steps). Numbers only here.
- Three `fw compare --base=HEAD --report=…` runs on `examples/brewline` with
  scratch changes, walked in a browser at 1280×800.
- Two kept runs re-hosted as local pages (most of their frames had been swept,
  so placeholders), to see the page at real size.

| channels that fired on a changed unit | units | share |
|---|---|---|
| tree only (no pixel moved) | 587 | 68% |
| pixels and tree | 191 | 22% |
| pixels only | 78 | 9% |
| events only | 2 | 0.2% |

Per run:

| run | changed | what it is | how many causes |
|---|---|---|---|
| A | 551 | all tree only | one widget swapped for another explains 533 |
| B | 48 | all tree only | one |
| C | 180 | a resize, pixels and tree | 752 distinct tree shapes on its steps; median size change 2px, 53% at 2px or less |
| D | 77 | pixels only, icon-sized regions | 27 distinct changed rectangles |
| E | 2 | events only (db) | one flow |

Two other runs had nothing changed.

Of the 269 units whose pixels moved, the median change covers 0.83% of the
frame and 33% cover under 0.1%.

## Ranked problems

Sizes: S is a small single-file change, M a few hundred lines with tests, L
more than that or a change of what a run does.

### 1. "Changed" does not say whether anything looks different (M)

**Reproduce.** On brewline, change an icon, a word and one padding, and wrap a
screen in a pass-through widget. Open the exported page.

**Got.** 12 findings, all `changed`. The first screen holds four rows sorted by
id; two of them look identical. The 12% Menu change is fifth. The Findings tab
has no summary at all. In a flow, every node carries the same amber ring and
chip whether the picture moved or not.

**With a wrapper only** (no visible change at all): `12 changed (tree only)`,
67 changed steps, 0 with a changed pixel.

**Fix.** Show two groups everywhere: *looks different* (pixels moved, added,
removed, broke) and *looks the same* (only tree, texts or events). Visible
first, largest change first; the rest folded under one line with its count.
Say it in the heading: `9 look different · 3 look the same`. `showsInPicture`
in `finding_face.dart` already answers the question, so this is app-only and
`index.json` does not change.

### 2. A wrapper or replaced widget hides every tree change under it (M)

**Reproduce.** The same branch. Open the Menu step.

**Got.** The tree channel holds two lines: `+ CartScope › _ShopFrame` and
`- CartScope › MenuScreen`. It reads as the screen having been deleted. The
padding change and the icon swap under it are not in the tree channel at all.

**Why.** `TreeDiff` only walks matched pairs. A wrapper or a swapped widget
type is an unmatched removal plus an unmatched addition, and neither subtree is
compared. This is the shape of runs A and B.

**Fix.** In `lib/src/comparison/tree_diff.dart`, when an added and a removed
node hold the same children (wrapped, unwrapped, or one type replaced by
another), report one `changed` delta saying so and keep walking. No schema
change. It alters what `index.json` says, so it needs careful tests.

### 3. One cause is reported hundreds of times (M, plus S for the agent reply)

**Got.**
- The landing tab and the comment group nothing. Run A is 77 rows.
- The Previews and Scenarios tabs have a `same change in N of M` line, but:
  it groups on the full widget path, which starts with the entry id for a
  preview, so previews never group (six brewline previews with one identical
  wrapper showed no line); it only looks at the first shape, not the largest;
  an added and a removed widget are two shapes, so **Hide** removes nothing
  from the list and then offers the other half, drawn `removed Column →` with
  nothing after the arrow.

**Fix.** Group on the changed node and its parent, not the whole path; treat a
replacement as one cause; order groups by how many findings they explain; show
them on the Findings tab and in the comment.

**Agents (S, do first).** The `compare` action's reply takes the first 12
shapes in list order. On run A (77 findings, 116 shapes) the shape covering 47
findings is 82nd, and each of the 12 sent covers one finding. Checked with the
published `foldChannelDeltas` and `ComparisonIndex`. Sort by findings covered
before the cap, and trim paths in the reply: its per-finding deltas alone are
161k characters on that run.

`index.json` itself reaches 13MB on run C, 12.9MB of it tree deltas with paths
up to 1,900 characters, and it holds no grouping. A `causes` key there would
serve the page, the comment and an agent from one place. It is additive, but
`comparison_report.dart` is published (M).

### 4. The pictures are too small to judge the change (M)

**Got.**
- Step page at 1280 wide: each landscape frame is about 600px wide, so a
  1600px frame is drawn at 37%.
- **Enlarge does nothing for landscape frames.** Same width, more blank space.
- There is no zoom and no way to jump to a changed region.
- Findings thumbnails are 64 to 220px wide. A removed word is a few pixels.
- Flow nodes have no change boxes.
- The mosaic draws whole frames. A desktop frame ends up near a quarter of its
  size in a GitHub comment.

**Fix.** Wheel zoom and pan on the stage with base and head locked together,
next/previous region, and an Enlarge that stacks landscape frames or goes to
1:1. Crop thumbnails and mosaic cells to the changed region with some context.
Cropping alone is not enough: changed regions are often sparse and wide (a
common one in run D is 413×6px holding 36 changed pixels), and cropping to the
largest region gains 2× or more on only 39% of the 269 units.

### 5. Places with no picture where one is expected (S, then M to L)

- **A new scenario is never replayed.** The page shows an icon and "Only on
  this branch". No frame anywhere: page, comment table row with an empty Δ, no
  mosaic cell. `index.json` has `"steps": []`. (L: replay the head side, which
  costs run time.)
- **A new split branch** is an empty green box reading `added, 3 steps`. The
  branch's name is not shown and no step has a frame. (Name: S. Frames: M.)
- **Findings rows past the 20th** have no thumbnails and nothing says why.
  That was 57 of 77 rows on run A. (S: load them as they scroll into view.)
- A step that changed only underneath shows one small frame and `Show frames`.
  This is deliberate and right once problem 1 says why.

### 6. The pull-request comment and the mosaic (S to M)

- The mosaic shows pairs of identical screenshots. A wrapper-only branch posts
  a 1292×1812 picture of 12 identical pairs.
- The same pair repeats: 6 copies of the Menu change out of 12 cells.
- No `base` / `head` labels.
- Captions are ids cut from the left (`...rt#Brewline in twenty seconds`), not
  names, and do not say which step is pictured.
- The table's Δ is empty for every row whose pixels did not move, and names one
  step for a flow.
- The table is ordered by id, not with visible changes first.

**Fix.** Only changes a picture shows go in the mosaic, each distinct picture
once with `and 5 more like it`; label the sides; use names; say what changed in
every Δ. No mosaic when nothing looks different.

### 7. Smaller page defects (S each)

| did | expected | got |
|---|---|---|
| clicked the `pixels · 39 steps` chip | only pixel changes | the chip is struck through: it hides pixels. Nothing else moved, because those steps also have tree lines |
| clicked **Hide** on `same change in 498 of 528` | the list shrinks | same rows; a second line about the other half |
| clicked a flow on the Findings tab | the step that changed | the flow from its first step |
| stepped with the arrows on a step page | the next change | the next step, changed or not |

## Checked, and not a problem

- **System events** (text-input geometry and the like) cannot make a finding
  on their own. 189 of the 195 event deltas in the kept runs are `system`, and
  179 of the 191 units carrying any are `same`. Nothing to demote.
- The 13MB index loads without trouble from a local server.
- Deep links to a step and to a preview open the right page.
- An added **preview** does get its picture.

## Already done by earlier passes, not to redo

`2026-08-30-comparison-ui-pass-design.md` added the verdict strip and channel
filters. `2026-08-31-comparison-detail-page-design.md` made the detail page
lead with what changed, and listed severity and inert rows as weak. Commit
69a4a485 gave portrait frames the room, added Enlarge and 140px thumbnails,
and ordered tree lines cause-first within one finding. None of them grouped
across findings, ranked visible changes, or added zoom.

## Suggested order

1. Agent reply: sort shapes before the cap (S, no design choice).
2. Look different / look the same, on the page (problem 1).
3. Comment and mosaic (problem 6).
4. Tree diff through wrappers (problem 2).
5. Grouping by cause (problem 3).
6. Zoom and crop (problem 4).
7. Missing pictures (problem 5).
8. The small defects (problem 7).

## Decisions that are the user's

- Does a difference no picture shows still count as `changed`? Suggested: keep
  the state in `index.json` as it is, and show and count it apart.
- Should a new scenario be replayed for its pictures, at the cost of run time?
  Suggested: yes, head side only.

## Reproducing the demo branch

Uncommitted changes on brewline, compared with `--base=HEAD --report=<dir>`:

- `ShopApp`'s builder wraps `child` in a pass-through `_ShopFrame` widget;
- the Menu app bar's bag icon becomes `shopping_basket_outlined`;
- `pickupFrom` in `en.json` says `St` for `Street`;
- `DrinkTile`'s padding goes from 12 to 13;
- `MenuScreen.initState` records an analytics event;
- for problem 5: a new scenario, a new `split` branch in `Around the shop`, and
  a new preview.

Serve `<dir>/web` over HTTP.
