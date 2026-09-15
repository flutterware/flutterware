# A comparison compares results — determinism, checked rather than assumed

A consumer's merge request changed no scenario and one unrelated app file. Its
comparison reported **2 failed · 3 changed** out of 129 scenarios. Three
`fw compare` jobs had shared one GPU-less Linux runner, and scenario time had
gone from ~365s to ~1000s. Every one of those five rows was the host, not the
branch.

That report came with nine precise findings, and they are not nine bugs. They
are one missing rule:

> **A slow host may make a run *inconclusive*. It must never make it
> *different*.**

And its corollary, which is what keeps the tool useful rather than merely
quiet: when a scenario is *not* deterministic, that is a finding about the
**scenario**, owed to its author — on their machine, with the fix — before it
is ever a row in somebody else's merge request.

## 1. Where real time gets in

Scenarios run under `FakeAsync`, with the clock pinned and the network off or
recorded. The design's promise is that one key draws the same frames. Read
against the code, real time still reaches a run through five doors:

1. **The deadline is wall-clock.** `harness.dart` wraps the whole of
   `live.run()` — setUp, every replay of every `split` path, every capture,
   every wait on tracked real work, tearDown — in one `timeout(30s)`. A
   five-path split that imports a model on each path passes in 5s on a quiet
   Mac and fails on a busy CI host. The deadline measures the host.
2. **Unannounced real-loop work is raced.** `landRealWork` has two halves.
   What announces itself — image decodes, the scenario bundle's asset reads,
   `RealWork.track` — is *waited for*, and between a policy's frames the wait
   holds the fake clock still. That half is deterministic by construction.
   What does not announce itself — a `FutureBuilder` on a real future,
   untracked IO — gets `realWorkTurns` (12) turns of the real loop. On a
   slower host it has not landed by then, and meanwhile settle policies move
   the fake clock, so the app's *own* timeouts can fire in fake time while its
   real work is still running.
3. **The 1s ceiling on announced decodes** (`realWorkWait`) is a deadlock
   ceiling on a fast machine and a budget on a software rasterizer under load.
   Hitting it says `landed: false` on the step.
4. **`settled` and `landed` flip under load.** `drift.dart` names both as
   load-sensitive facets. The comparison reads neither.
5. **The comparison assumes every replay is a result.** `ScenariosSide.run`
   reads `steps` and `abandoned` and drops `ok`, `errors` and `ms`; a failure
   reaches the verdict only as a step field on a *matched* pair; every
   complete replay is filed in the `ReplayStore` and served to every later
   comparison against that base; nothing is ever re-run.

The fifth door is what turned the first four into false findings. The first
four are what make a run depend on its host at all.

## 2. The model

### 2a. A replay is a result or it is inconclusive

Every side of every compared scenario ends in one of three conditions:

- **Clean** — complete, no failure.
- **Failed** — complete, with a failure the scenario raised.
- **Inconclusive** — it did not produce a result: the harness abandoned it at a
  deadline, or its outcome did not reproduce.

Only clean and failed sides are *results*, and only two results are compared.

### 2b. A result is confirmed before it is believed

A side that failed or was abandoned is **replayed once more, alone** — after
the pair, never beside the other side, because the host is the suspect and a
second tester is load. Then:

| first run | second run | the side is |
|---|---|---|
| failed | failed, same first line | **failed** — a result, and fileable |
| failed | clean, or failed differently | **inconclusive** — unstable |
| abandoned | clean | **the second replay** — a deadline says how long the machine took, not what the scenario draws |
| abandoned | abandoned | **failed** — under a progress deadline (§3) a stall that reproduces is the scenario hanging; reported, never filed |
| abandoned | failed | **inconclusive** |

Cost is proportional to what went wrong, not to the size of the suite. A clean
pair is never replayed twice.

### 2c. Verdicts, once both sides are results

- head failed, base clean → `broke`
- base failed, head clean → `wasBroken`
- both failed → `failed`, carrying both messages
- both clean → the step alignment and channels, as today

These hold whether or not the failing step lines up with a step on the other
side. Today a failure on an unmatched step is `added`/`removed`, which
`_verdict` folds into `changed` — that is how a base that broke read as the
branch's change.

A failure step is labelled by its message's first line, never `step N` — `N`
is a run-wide index and means nothing to a reader.

### 2d. Not compared

A scenario with an inconclusive side is **not compared**. It is written with
state `skipped` and an `inconclusive` sentence saying which side, what happened
and what to do about it.

`skipped` rather than a new state, deliberately. `index.json` is published and
versioned, and an unknown state name decodes as `skipped` in every reader
already shipped — so a new state would read as `skipped` anyway, with no
sentence, in exactly the readers that most need one. As `skipped` with a
sentence, an old reader's `ok` agrees with a new one's, because **not compared
does not fail a gate**: it is not a verdict about the branch. It is counted and
named in the comment's headline, so it is never silent either.

The mass case is a gap, as `failed` and `wasBroken` already are: a half in
which *every* replayed scenario is inconclusive produced no verdict, and
`verdictGapOf` says so.

### 2e. What is filed

The `ReplayStore` files **results** only: a clean side, or a failed side whose
failure reproduced. An abandoned or unstable side is never filed. This keeps
the store's own argument — one key, one set of frames — true by checking it at
the only moment it can be checked, instead of serving one host's bad minute to
every branch on that base.

## 3. The deadline measures stalls, not speed

`scenario(timeout:)` becomes **the longest a scenario may go without
progress** — which is what an author means when they write it. Progress is:

- a step recorded,
- a verb returning,
- a tracked real-work future completing,
- **the isolate being busy**: the check is a periodic real-zone timer, and a
  check that fires late fired late because the isolate was working. A stall is
  an *idle* isolate waiting on something that never comes.

Frames are not progress. A spinner draws them forever.

Two ceilings keep "progress" honest:

- **tracked work** pending longer than its own ceiling fails, naming the work
  and how long it had been pending;
- a **hard ceiling** of ten times the timeout, against a body that makes
  progress forever.

Under the harness, `testWidgets` is given `Timeout.none` and the declared value
travels beside it, or test_api's own heartbeat timer fires first and fails the
scenario with no diagnosis and without abandoning it.

With a progress deadline, a slow host no longer produces stalls, so a stall is
evidence again: a side that stalls again on its retry is a failed result — a
head that hangs beside a base that does not is `broke`, with the stall's
diagnosis as its note. It is still never filed: the harness abandoned the rest
of the file with it.

The stall diagnosis stops saying "this is not slowness" when the body was
waiting on tracked work inside `RealWorkBudget.land`. It leads with the work,
how long it had been pending, and whether it landed after the deadline.

## 4. The author hears first

The comparison is the last place a non-deterministic scenario should be
discovered. Each step records **how its real work landed**:

- nothing to land,
- announced — waited for, deterministic,
- **guessed** — a turn of the real loop produced a frame nothing announced,
- **ceiling** — a wait ran out.

Guessed and ceiling are **hazards**: the picture depended on the host. They are
reported where the author already looks — the scenario run's answer and the
studio's step — with the fix: *"this step drew work nothing announced; it
landed on guessed turn 9 of 12, and on a slower host it will not. Wrap it in
`RealWork.run`."* A folder or scenario may make hazards failures, the way
`Settle.strict` makes an unsettled step one. By default they warn.

Built 2026-09-15 with one refinement measured into it: a guessed turn that
delivered a platform reply is not a hazard. Every one of the example suite's
eight guessed steps was a `TextField` asking the platform about the clipboard,
Live Text and text actions — the framework's traffic, on every form, and
nothing a scenario can hand to `RealWork`. With replies counted (all channels,
not only the ones the stall diagnosis records), the example suite reports
none, and flutterware's own studio suite reports nine, each a panel reading a
recorded project's files off the fake clock — genuine.

**Deferred, and why.** Two pieces of this section were not built:

- *Strict hazards.* A folder or scenario that turns a guessed landing into a
  failure. Worth having once the warning has been lived with; building it now
  would fix a public name before the signal has earned one.
- *A slow-host run.* Turning guessing off makes a guessed landing miss, but
  nothing flutterware controls can slow the engine's own real-loop work, and a
  run that only removes the guessing reports exactly what `guessed` already
  says. What it would add — work that lands during a policy's frames, before
  any guessing starts — has no reproduction yet. Revisit with one.

The comparison uses hazards as a trigger: a difference on a hazard step
re-runs that side once, and a side that disagrees with itself is not compared,
with the hazard's fix as its sentence.

## 5. Supporting work

Not stability, but load and legibility — the pressure that exposes the rest:

- `pubspec.yaml` stops being a whole-file pixel input; only the parts that can
  change a pixel are hashed (keeping `hooks:`), and the lock digest stops
  carrying `dependency:` — removing a direct dependency that stays transitive
  moves no pixel.
- `index.json` records the host (OS, CPU count, backend) and per-scenario
  `ms` per side, so a run that took three times its usual time says so.
- `ShotKey` carries the rasterizer backend.

## 6. Build order

1. **The comparison compares results** (§2), from signals that already exist.
   Alone, this removes all five false findings in the report that started
   this.
2. **Progress deadline** and the stall diagnosis (§3).
3. **Hazards** in the run and the author's messages (§4). Built; strict and
   the slow-host run deferred, as §4 says.
4. **The comparison acts on hazards** (§4, last paragraph). Built: a finding
   in a scenario with a hazard on either side replays each side once more,
   alone; a side that does not reproduce itself makes the scenario not
   compared; a difference that holds carries a note on the step. A replay with
   a hazard is never filed.
5. **A timeout inside a `split` is placed on the branch that was running**, and
   so is a failure in a later replay's shared prefix — today both become an
   unlabelled second child of a trunk step, and the aligner stops walking
   there. Then §5.

## 7. Decided

2026-09-15, with Xavier:

- `timeout:` changes meaning to "no progress for this long".
- Hazards warn by default; strict is opt-in; the comparison acts on them
  either way.
- Not compared does not fail a gate, and is named in the headline.
