# Comparison in CI

`fw compare --report=<dir>` writes what a pull-request comment needs, pictures
included, but doesn't host the files or post the comment. A GitHub comment can
only show an image by URL, so where the files live is up to you: an orphan
branch, GitHub Pages or a bucket. The report is three files with two
placeholders, and the workflow below hosts them and posts the comment.

## What `--report` emits

```
<dir>/
  comment.md    the verdict in the heading, a link to the page at the top, and
                the table of findings folded into a <details>. Each row links
                to its place on the page (`#previews/<entry>`,
                `#scenarios/<flow>/<step>`). Contains the __MOSAIC_URL__ and
                __VIEWER_URL__ placeholders.
  mosaic.png    a grid of the findings (at most 20), base beside head, with the
                changed regions boxed. Written only when something changed.
  web/          the browsable page: viewer, index.json, a PNG per frame.
                Serve it over HTTP: from file:// it can't load its frames.
```

The page resolves every path against its own URL, so it works at a bucket root
or under `…/comparisons/42/` with nothing to configure. The exception is a host
that serves a directory without redirecting to a trailing slash. For that host,
pass `--base-href=/comparisons/42/`.

## A workflow that hosts on an orphan branch

This workflow needs nothing but GitHub. An orphan branch holds the files,
raw.githubusercontent.com serves the **mosaic**, and GitHub Pages serves the
**viewer** from the same branch. The viewer needs Pages because it is a Flutter
web app, and raw.githubusercontent.com serves scripts as `text/plain` with
`nosniff`, which browsers refuse to run. The mosaic is served raw because Pages
takes about a minute to build after a push, and the image in the comment has
to load right away.

One-time setup: Settings → Pages → deploy from a branch →
`comparison-artifacts`, `/ (root)`.

```yaml
comparison:
  runs-on: macos-latest        # anywhere `flutter test` runs
  steps:
    - uses: actions/checkout@v4
      with: { fetch-depth: 0 } # the base is the merge base; a shallow clone has none
    - uses: subosito/flutter-action@v2
    - name: Cache the pictures, the seed kernel and flutterware's own build
      uses: actions/cache@v4
      with:
        # The forty `?` are flutterware's install directory, named by a hash.
        path: |
          ~/.flutterware/shots
          ~/.flutterware/kernels
          ~/.flutterware/????????????????????????????????????????
        key: fw-${{ runner.os }}-${{ hashFiles('**/pubspec.lock') }}
        restore-keys: fw-${{ runner.os }}-
    - name: Compare
      run: dart run flutterware compare --report=comparison-report --frames=changed
    - name: Host the report
      env: { PR: ${{ github.event.number }} }
      run: |
        git fetch origin comparison-artifacts:comparison-artifacts 2>/dev/null \
          && git worktree add site comparison-artifacts \
          || git worktree add --orphan -b comparison-artifacts site
        rm -rf "site/pr-$PR" && mkdir -p "site/pr-$PR"
        cp comparison-report/mosaic.png "site/pr-$PR/" 2>/dev/null || true
        cp -R comparison-report/web "site/pr-$PR/web"
        git -C site add -A
        git -C site -c user.name=fw-compare -c user.email=fw-compare@invalid \
          commit -q -m "comparison for #$PR" || true
        git -C site push origin comparison-artifacts
    - name: Comment
      env:
        GH_TOKEN: ${{ github.token }}
        PR: ${{ github.event.number }}
      run: |
        RAW=https://raw.githubusercontent.com/${{ github.repository }}/comparison-artifacts/pr-$PR
        PAGES=https://${{ github.repository_owner }}.github.io/${{ github.event.repository.name }}
        # `g` matters: a scenario row carries two viewer links on one line.
        sed -e "s|__MOSAIC_URL__|$RAW/mosaic.png|g" \
            -e "s|__VIEWER_URL__|$PAGES/pr-$PR/web/|g" \
            comparison-report/comment.md > comment.md
        # One comment per PR, updated in place and found again by its marker.
        id=$(gh api "repos/${{ github.repository }}/issues/$PR/comments" \
          --jq '[.[] | select(.body | startswith("<!-- fw-compare -->"))][0].id // empty')
        if [ -n "$id" ]; then
          gh api -X PATCH "repos/${{ github.repository }}/issues/comments/$id" -F body=@comment.md
        else
          gh pr comment "$PR" --body-file comment.md
        fi
```

Change it as you like, as long as it still does two things: replace both
placeholders everywhere they appear (`sed …g`, because `__VIEWER_URL__` appears
once per table row), then post `comment.md`. The comment's first line is
`<!-- fw-compare -->`, so a workflow can find its own comment and update it
instead of adding a new one on every push. The `@<sha>` in the footer says
which push the report was made for.

## Several packages, one comment

`fw compare` covers every package that declares previews or scenarios, say
previews in `app` and `packages/gallery` and scenarios in `app` and
`packages/notes`, and writes one `index.json`, one `comment.md` and one page
for all of them. There is nothing to configure. Don't run it once per package:
you would get one comment per package, and each run would overwrite the
previous run's artifact.

`--package=` narrows it, and you can repeat it:

```sh
dart run flutterware compare --package=app --package=packages/notes
```

When a run covers more than one package, two things change in the output. With
one package, nothing changes.

- **A row's id includes its package**: `packages/gallery/demo/card.dart#card`,
  the file's path plus the name it was declared under. Without it, two packages
  that both declare `demo/card.dart#card` would share one row.
- **A row also has a `package` field**, set whether or not the id includes the
  package, so a script reading `index.json` never has to take an id apart.

If one package's previews or scenarios don't compile against the base, the
other packages still report. The comparison records a note naming the package,
with the compiler's output, and the comment opens with **no verdict** so the
failure can't be read as a pass. `fw compare` still exits non-zero. If that
package is the only one, the command prints the diagnostics and exits 64.

Packages are compared one at a time. Each needs two `frontend_server`s and two
`flutter_tester`s, and a runner sized for one build can't hold several packages'
worth at once. A package the branch didn't touch takes only milliseconds.

## A runner with cores to spare

By default a comparison renders and replays on one `flutter_tester` per side,
first the base's previews and then the head's, which suits a runner sized for
one build. `--jobs=<n>` tells it how much the machine can take:

```sh
dart run flutterware compare --report=comparison-report --frames=changed --jobs=4
```

Each side compiles its harness once and starts `n` testers from that kernel.
The two sides render their previews at the same time, `n` testers each, and `n`
scenarios replay side by side, each on both sides, so up to `2n` testers run at
once. Packages are still compared one at a time. The value is recorded in
`index.json` under `host.jobs` and in the comment's footer, so you can tell a
slow run from a serial one.

How much it saves depends on where the time goes. Measured on flutterware's own
studio package (199 previews and 12 scenarios on both sides, cold caches, a
16-core Mac):

| | total | previews | scenarios |
|---|---|---|---|
| `--jobs=1` | 118s | 46.6s | 27.3s |
| `--jobs=4` | 102s | 21.8s | 34.4s |
| `--jobs=8` | 96s | 22.5s | 28.3s |

- **Previews gain the most.** The sides stop waiting for each other, and each
  side splits its previews across its testers.
- **Scenario replays stop scaling well before the core count**, because a
  tester also rasterizes and collects garbage on threads of its own. The same
  twelve replays took 12.0s one at a time, 7.9s at 4 and 10.0s at 8. Start at
  about a quarter of the cores and measure.
- **Compiling the harness and checking out the base don't get faster.** On a
  small package they are most of the run. (The table was measured before the
  viewer started compiling alongside the comparison and dropped Flutter's Wasm
  dry run, so totals are lower now.)
- **The machine's load never decides a verdict.** If a scenario's replays in
  the pool are not clean and identical on both sides (a side failed or was
  abandoned, or anything at all differs), the scenario is replayed from the
  start once the pool has drained, with nothing running beside it, and judged
  on that replay alone. Any difference counts, including the order of events:
  on a real suite at `--jobs=8`, a stream fed by real I/O fired earlier on one
  side and a step's events changed order with nothing else changing. The three
  runs in the table reached identical verdicts, row for row. The extra replays
  show in the scenarios column, once per finding. That is usually a handful of
  rows, but a change that moves every scenario replays each of them again, one
  at a time. Scenarios that guess at unannounced work are replayed twice, which
  is another reason to start that work with `RealWork.run`.

## Reading a slow run

Every run ends with a line saying where its time went, each phase summed over
packages and sides. This one is from a cold run over flutterware's studio
package at `--jobs=4`:

```text
Time spent: checkout 1.3s · previews plan 1.3s, compile 20.1s, render 15.1s, compare 1.6s · scenarios plan 4.9s, replay 18.2s, compare 0.7s, filing 1.6s · viewer 17.7s · export 2.0s · report 0.9s · sweep 0.0s
```

The same phases, per package and per side, are in `index.json` under `timings`
(`ComparisonIndex.timings` from a script). Phases overlap, so they don't add up
to the total: under `--jobs` both sides render at once, and the page's viewer
compiles alongside everything else from the start.

A second line names the scenarios with steps that gave up waiting for the
screen to settle. Each of those steps uses its whole settle budget on every
replay, usually because of an animation that never ends or a 3D view that
repaints every frame, such as flutter_scene's `SceneView` with its default
`autoTick: true`. It isn't a failure, but it is usually the easiest time to win
back.

For each scenario, the line says what was still ticking when the budget ran
out, read from the framework's debug stacks: `Orders (4, still ticking:
CircularProgressIndicator (lib/src/orders/status_cell.dart:42))`. A framework
widget is named by the line of your app that built it, and an animation your
app started is named by the frame that started it. `index.json` lists every
name under `timings.stillTicking`, and each scenario's outcome has its own
under `stillTicking`.

A third line, with `--jobs`, names the scenarios that differed when replayed
beside others and not when replayed alone (`timings.pooledOnlyDifferences`).
Their rows carry the verdict of the replay alone, so the report is correct; the
line shows which scenarios the machine's load affected. Such a scenario records
work that runs on the real event loop, such as a stream fed by real I/O or an
untracked read, and it costs a serial replay on every comparison that runs it
with `--jobs`. The time those serial replays took is under `scenarios.alone`,
separate from `scenarios.replay`.

## Why `--frames=changed`

The page has to include every picture it shows, because the people reading it
don't have the shot cache. On a run that skipped few entries, almost all of
those pictures are of rows that came out **identical**. On one export, the
frames of 220 unchanged entries took 18.1MB, and those of the 24 findings
1.5MB.

`--frames=changed` writes only the findings' frames. The verdict doesn't
change: every row is still in `index.json` with its state and its channels, so
a script reading the file sees what it saw before. An unchanged entry opens on
a sentence saying its picture was left out. A scenario that is a finding keeps
all of its steps.

The default is `all`. Keep it when people browse the page rather than gate on
it: without those frames, the page can't show what the branch didn't touch.

## What to know before turning it on

- **A busy runner can leave a scenario not compared.** A scenario side that
  failed, or that the harness gave up on, is replayed once more on its own
  before anything is concluded from it. If the failure happens again, that is
  the verdict. If it doesn't (it failed once and passed the second time), the
  scenario is listed as **not compared**, with what happened, because its
  outcome depended on the machine rather than on the branch. Not compared is
  named in the comment's heading and never fails the check.

  The fix is in the scenario. It usually has real work that nothing announced,
  and `RealWork.run` makes the scenario wait for it. A scenario run already
  shows where that work is: each step that found it only by turning the real
  event loop records the turn as `guessed`, and the run ends with a line naming
  those steps. When a comparison finds a difference in one of those scenarios,
  it replays both sides once more before reporting it.

  It does the same when the only difference is the order of events. If a
  side's two replays log some events in a different order, that order is
  timing, and a step whose events only moved among those is reported as
  unchanged, with a note naming them. If both sides keep their order on every
  replay, a different order is a change.

  A scenario's `timeout:` is how long it may go without progress, not how long
  it may take in total, so a slow runner makes a scenario slower without
  failing it.

- **The three caches.**
  - `~/.flutterware/shots` holds the rendered pictures and the scenario
    replays, stored by content. Without it, a runner renders and replays both
    sides of every row on every run. With it, a push whose inputs didn't change
    replays nothing, and a base is replayed once however many pull requests
    compare against it. A replay that sent requests to a live network, or that
    the harness gave up on, is never stored, and a failed replay is stored only
    once its failure has reproduced. `fw compare` trims the cache at the end of
    every run (anything unread for two weeks, then the oldest past 2GB), so a
    restored cache stays bounded without a cleanup step of your own. It trims
    the base checkouts too, keeping the five most recently used for up to two
    weeks, and the comparison directory of each checkout.
  - `~/.flutterware/kernels` holds the **seed kernel**: a compiled kernel of
    the SDK and the pub cache, the part of the program that no checkout owns. A
    cold harness compile starts from it instead of from nothing. On
    flutterware's own repository, a scenario harness compiled cold took 60s;
    starting from a seed, the whole scenarios phase took 9s.
  - The directory named by a forty-character hash is flutterware itself,
    unpacked from the pub cache, with the `fw` command and the page's viewer
    built inside it. With it restored, a run skips unpacking and building the
    command (about 14s) and rebuilds the viewer in about 2s instead of 18s. A
    new flutterware version or SDK gets a new stamp and is rebuilt. Copies of
    versions the project no longer uses are deleted by the first launch that
    finds them unused for a month, so a cache carried across versions doesn't
    pile them up.

  Keep the `restore-keys` line: after a lockfile change, the run starts from
  the previous cache and saves a new one instead of starting empty.

- **Do not cache `~/.flutterware/bases`.** The base checkout is a real
  `git worktree`, registered inside the repository's `.git`. A fresh CI
  checkout doesn't have that registration, so git doesn't recognize a restored
  one as a worktree. It is also quick to recreate: checking it out again takes
  seconds, and the pictures that took the time are in the shot cache.

- **Both sides are rendered with the SDK you run `fw compare` under**, and the
  base with its own `package:flutterware`. A branch that changes either one
  compares two toolchains as well as two commits, and the report says so, so
  you don't need a check of your own. Widget-tree differences between two
  versions of flutterware's reader are listed but not counted. A base whose
  `.fvmrc` (or `.fvm/fvm_config.json`, or `.tool-versions`) pins a different
  Flutter from this branch's gets a sentence saying its pixel differences may
  come from the SDK. Both appear under the comment's heading, on the page, and
  in `index.json` as `caveats`.

- **`fetch-depth: 0`.** The base is the merge base with the default branch. A
  shallow clone has no common commit, and the compare refuses, naming the ref.

- **The first comment in a repository may link to a page that isn't there
  yet.** Pages builds after the push, in about a minute. Later runs update a
  site that already exists. A downloaded artifact opens on `file://`, which
  can't run the page: it has to be served, and the branch serves it.

- **Old directories stay until you delete them.** Nothing links to a closed
  pull request's `pr-N/` on the branch, so delete them whenever the branch
  gets heavy.

- **The page loads its rendering engine from `www.gstatic.com`**, so on a
  network that blocks it the page is blank. The engine is about 38MB and is
  not copied into the export. No flag of `fw compare` changes that; the
  scenario export's *Offline* toggle is the one place that does.
