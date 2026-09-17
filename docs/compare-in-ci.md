# Comparison in CI — a PR comment with pictures

`fw compare --report=<dir>` emits everything a pull-request comment needs;
what it deliberately does not do is host or post. A GitHub comment can only
show images by URL, and where those URLs live — an orphan branch, GitHub
Pages, a bucket — is the repository's business. So the report is three files
with two placeholders, and the workflow below is the fifteen lines that
finish the job.

## What `--report` emits

```
<dir>/
  comment.md    the verdict in the heading, the viewer link up top, and the
                table of findings folded into a <details> whose rows
                deep-link into the page (`#previews/<entry>`,
                `#scenarios/<flow>/<step>`) — with __MOSAIC_URL__ and
                __VIEWER_URL__ placeholders
  mosaic.png    a grid of the findings (capped at 20), base beside head,
                changed regions boxed — only written when something changed
  web/          the browsable page: viewer, index.json, a PNG per frame.
                Serve over HTTP; file:// cannot fetch its own frames.
```

The page resolves everything against its own URL, so it runs at a bucket root
and under `…/comparisons/42/` alike with nothing to configure. The one host
that needs telling is one that serves a directory without redirecting to a
trailing slash — give it `--base-href=/comparisons/42/`.

## A workflow that hosts on an orphan branch

One self-contained way to do it, on stock GitHub and nothing else. An orphan
branch holds the files; raw.githubusercontent serves the **mosaic** and
GitHub Pages serves the **viewer** from that same branch. Two hosts on
purpose: the viewer is a Flutter web app and raw serves scripts as
`text/plain` with nosniff, which browsers refuse — while Pages takes a
minute to build after a push, which the click on "Open the full comparison"
can afford and the inline image cannot.

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
        # One comment per PR, updated in place — found again by its marker.
        id=$(gh api "repos/${{ github.repository }}/issues/$PR/comments" \
          --jq '[.[] | select(.body | startswith("<!-- fw-compare -->"))][0].id // empty')
        if [ -n "$id" ]; then
          gh api -X PATCH "repos/${{ github.repository }}/issues/comments/$id" -F body=@comment.md
        else
          gh pr comment "$PR" --body-file comment.md
        fi
```

Adapt freely — the contract is only: substitute the two placeholders
everywhere they appear (`sed …g` — `__VIEWER_URL__` is once per table row),
then post `comment.md`. The comment's first line is `<!-- fw-compare -->`
precisely so a workflow can find its own comment and update it rather than
stack a new one per push; the footer's `@<sha>` says which push the report
still describes.

## Several packages, one comment

`fw compare` covers **every** package either half declares — previews in
`app` and `packages/gallery`, scenarios in `app` and `packages/notes` — and
writes one `index.json`, one `comment.md` and one page for all of them. There
is nothing to configure and no reason to run it once per package; doing so
would produce a comment each, and each run would overwrite the last one's
artifact.

`--package=` narrows, and it is repeatable:

```sh
dart run flutterware compare --package=app --package=packages/notes
```

Two things change in the output when a run covers more than one package, and
nothing changes when it covers one:

- **A row's id carries its package** — `packages/gallery/demo/card.dart#card`,
  which is the file's path plus the name it was declared under. Without it two
  packages that both declare `demo/card.dart#card` are one row.
- **A row also carries a `package` field**, recorded whether or not the id was
  qualified, so a script over `index.json` never has to take an id apart.

A package whose catalog or harness will not compile against the base is one
package's worth of silence, not the end of the run: the others still report,
the half records a note naming the package and the compiler's output, and the
comment leads with **no verdict** so the failure cannot read as a pass. `fw
compare` still exits non-zero. When it is the *only* package, it is still the
whole comparison — the command prints the diagnostics and exits 64.

Packages are compared one at a time. Each is two `frontend_server`s and two
guests, and a runner sized for one build will not hold four of those at once;
since the scenario half stopped building harnesses it does not need, a package
a branch did not touch costs milliseconds anyway.

## A runner with cores to spare

By default a comparison renders and replays on one `flutter_tester` per side —
the base's previews, then the head's — which is the shape of a runner sized
for one build. `--jobs=<n>` tells it what the machine can take:

```sh
dart run flutterware compare --report=comparison-report --frames=changed --jobs=4
```

Each side compiles its harness **once** and starts `n` guests from that
kernel. The two sides' previews render together, `n` guests each, and `n`
scenarios replay side by side, each on both sides — so up to `2n` testers at
once. Packages still go one at a time. The value lands in `index.json` under
`host.jobs` and in the comment's footer, so a slow run can be told from a
serial one.

What it buys depends on where the time goes, and not all of it moves. Measured
2026-09-16 on this repository's studio package — 199 previews and 12 scenarios
on both sides, cold caches, a 16-core Mac:

| | total | previews | scenarios |
|---|---|---|---|
| `--jobs=1` | 118s | 46.6s | 27.3s |
| `--jobs=4` | 102s | 21.8s | 34.4s |
| `--jobs=8` | 96s | 22.5s | 28.3s |

- **Previews gain most.** Two things happen at once: the sides stop waiting
  for each other, and each side's entries are dealt across its guests.
- **A tester is not one core.** It rasterizes and collects on threads of its
  own, so replays stop scaling well before the core count: the same twelve
  replays took 12.0s serial, 7.9s at 4 and 10.0s at 8. Start around a quarter
  of the cores and measure.
- **Compiling the harness and checking out the base do not move.** On a small
  package they are most of the run. (The table predates two changes to the
  viewer: it now compiles beside the comparison instead of after it, and
  without Flutter's Wasm dry run.)
- **Load never decides a verdict.** A scenario whose replays in the pool are
  not clean and identical on both sides — a side that failed or was
  abandoned, or any difference at all — is replayed from the start after the
  pool has drained, with nothing beside it, and judged from that alone. Any
  difference, and not only one in pictures that depended on the machine: on a
  real suite at `--jobs=8`, a stream fed by real I/O fired earlier on one side
  and the step's events changed order with nothing else changing. The
  verdicts above are identical row for row. The price is paid in the scenarios
  column, once per finding: usually a handful of rows, but a change that moves
  every scenario replays each of them again, serially. And a suite whose
  scenarios guess at unannounced work replays those twice, which is one more
  reason to hand that work to `RealWork.run`.

## Reading a slow run

Every run ends with one line saying where its time went, each phase summed
over packages and sides — this one from a cold run over this repository's
studio package at `--jobs=4`:

```text
Time spent: checkout 1.3s · previews plan 1.3s, compile 20.1s, render 15.1s, compare 1.6s · scenarios plan 4.9s, replay 18.2s, compare 0.7s, filing 1.6s · viewer 17.7s · export 2.0s · report 0.9s · sweep 0.0s
```

The same phases, per package and per side, are in `index.json` under
`timings` — `ComparisonIndex.timings` for a script. Phases overlap, so they do
not add up to the run: under `--jobs` both sides render at once, and the
page's viewer compiles beside everything else from the start.

A second line names the scenarios whose steps gave up waiting for the screen
to settle. Each such step runs its whole settle budget on every replay — an
animation that never ends, or a 3D view left repainting every frame, such as
flutter_scene's `SceneView` with its default `autoTick: true`. It is not a
failure, but it is usually the cheapest time to win back.

A third line, under `--jobs`, names the scenarios that differed when replayed
beside others and not when replayed alone — `timings.pooledOnlyDifferences`.
Their rows are the alone replay's verdict, so nothing is wrong in the report;
the line says what the machine's load reached. Such a scenario records work
that lands on the real event loop — a stream fed by real I/O, an untracked
read — and it pays a serial replay on every comparison that runs it with
`--jobs`. The time those serial replays took is `scenarios.alone`, apart from
`scenarios.replay`.

## Why `--frames=changed`

The page has to carry every picture it shows, because it is read where nobody
has the shot cache — and on a run where the skip rule did not earn its keep,
almost all of them are pictures of rows that came out **identical**. Measured
on one export: 18.1MB of frames for 220 unchanged entries against 1.5MB for
the 24 findings.

`--frames=changed` writes the findings' frames only. The verdict is untouched
— every row is still in `index.json` with its state and its channels, and a
script over the file sees exactly what it saw before — and an unchanged entry
opens on a sentence saying its picture was left out rather than pretending
nothing rendered. A scenario that *is* a finding keeps every one of its steps,
holes and all being worse than weight.

Leave it off for a page somebody browses rather than gates on: without the
frames it cannot show you what a branch did not touch, which is a real thing
to want to see. That is why the default is `all`.

## What to know before turning it on

- **A loaded runner can make a scenario inconclusive, never different.** A
  scenario side that failed, or that the harness gave up on, is replayed once
  more on its own before anything is concluded from it. A failure that
  reproduces is the verdict; one that does not — failed once, passed the second
  time — is listed as **not compared**, with what happened, because its outcome
  depended on the machine rather than on the branch. Not compared is named in
  the comment's heading and never fails the check: it is a finding about the
  scenario, and the fix is in the scenario — usually real work nothing
  announced, which `RealWork.run` makes the scenario wait for. A scenario run
  already says where that is: each step that found such work only by turning
  the real event loop records the turn as `guessed`, and the run ends with a
  line naming those steps. A comparison that finds a difference in one of
  those scenarios replays both sides once more before it believes it, and so
  does a difference that is only events changing order: a side whose two
  replays log them in a different order is timing, and a step whose events
  only moved among those is reported the same, with a note naming them. An
  order both sides keep is a change. A scenario's
  `timeout:` is how long it may go without progress, not how long it may take,
  so a slow runner stretches a scenario without failing it.

- **The three caches, and what each buys.** `~/.flutterware/shots` holds the
  rendered pictures and the scenario replays, content-addressed: without it a
  runner renders and replays *both sides of every row, every run*, and with it
  a push whose inputs did not move replays nothing, and a base is replayed
  once however many pull requests compare against it. A replay whose requests
  went out to a live network, or one the harness gave up on, is never filed,
  and a replay that failed is filed only once its failure has reproduced.
  `fw compare` trims it at the end of every run — anything unread for two
  weeks, then the oldest past 2GB — so a restored cache stays bounded without
  a cleanup step of your own; so do the base checkouts and each checkout
  path's comparison directory. `~/.flutterware/kernels` holds the **seed kernel** —
  a compiled kernel of the half of the program no checkout owns, the SDK and
  the pub cache — and it is what a cold harness compile starts from instead of
  starting from nothing. Measured on this repository, a scenario harness
  compiled cold took 60s and the same one starting from a seed came up inside
  a 9s half. The directory named by a forty-character hash is flutterware
  itself, unpacked from the pub cache, with the `fw` command and the page's
  viewer built inside it. Restored, a run skips unpacking and building the
  command (about 14s) and rebuilds the viewer in about 2s instead of 18s;
  a new flutterware version or SDK is a new stamp, and it is rebuilt. The
  `restore-keys` line matters: a lockfile change should reuse the previous
  run's cache and write a new one, not start empty.
- **Do not cache `~/.flutterware/bases`.** The base checkout is a real
  `git worktree`, registered inside the repository's own `.git` — which a
  fresh CI checkout does not have, so a restored one is a directory git does
  not believe in. It is also disposable by design: it gets checked out again
  in seconds, and the pictures that took the time are in the shot cache.
- **Both sides are rendered with the SDK you run `fw compare` under**, and the
  base with its own `package:flutterware`. A branch that moves either compares
  two instruments as well as two commits, and the verdict says so rather than
  leaving you a guard to write: widget-tree differences between two versions
  of flutterware's reader are listed but not counted, and a base whose
  `.fvmrc` (or `.fvm/fvm_config.json`, or `.tool-versions`) pins a different
  Flutter from this branch's gets a sentence saying its pixels may be the
  SDK's. Both land under the comment's heading, on the page, and in
  `index.json` as `caveats`.
- **`fetch-depth: 0`.** The base is the merge base with the default branch; a
  shallow clone has no common commit and the compare refuses, naming the ref.
- **The very first comment of a repository may briefly 404 its page link**:
  Pages builds after the push, in about a minute. Every later run updates a
  site that already exists. A downloaded artifact opens on `file://`, which
  cannot run the page — it has to be served, and the branch is the serving.
- **Old directories are just directories.** A closed pull request's `pr-N/`
  on the branch is linked by nothing; delete whenever the branch feels heavy.
- **The page fetches its rendering engine from `www.gstatic.com`**, so a
  runner behind a firewall that blocks it gets a blank page. The engine is
  ~38MB and is *not* copied into the export for exactly that reason; there is
  no flag here that changes it, and the scenario export's *Offline* toggle is
  the one place that does.
