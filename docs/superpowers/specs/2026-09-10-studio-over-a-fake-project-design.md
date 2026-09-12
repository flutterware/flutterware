# The studio over a fake project — scenario tests of flutterware itself, and a web demo

**Date:** 2026-09-10
**Question:** two ideas that feel connected. (1) Scenario tests for the studio
itself — the same harness users get, pointed at our own GUI, to catch
regressions and iterate on UI. (2) A web demo of the studio, linked from the
README, over fake read-only data, so a reader sees what it looks like before
installing anything. Both seem to need an abstraction that can be faked. Is
there a place to put that hook, and does the abstraction make the code better
on its own — the only condition under which it is worth having?
**Answer:** yes to both, and they share one hook. Most of that hook already
exists: the shell has run over fake cores since the first shell test. The gap is
one level down — panels are typed on their concrete cores — and closing it is a
per-plugin interface extraction, not a generic provider layer. The web half
looked fatal (138 files importing `dart:io` in the shell's closure) and is not:
a real `flutter build web` of that closure fails on exactly one thing.
**Decision:** none yet. This is the investigation, written up for the decision.
The recommendation is at the end: scenarios first, as the go/no-go.
**Method:** read of the plugin layer, the two headline panels and their tests;
an import-closure walk over `app/lib`; one throwaway `flutter build web` of an
entry point importing the shell (deleted afterwards). No changes to this tree.

## What is already there

**The shell already runs over a fake project.** `ShellController`
(`app/lib/src/shell/shell_controller.dart`) takes every outside dependency as a
constructor argument: `coreRegistry`, `registry` (panels), `manifestLoader`,
`discovery`, `worktreeFacts`, `worktreeWatcher`, `watchEvents`.
`app/test/shell/shell_view_test.dart` pumps the entire studio over a
`_FakeCore` per plugin, a `_StubLoader` that hands back a manifest without
spawning anything, and a `WorktreeDiscovery` whose `runProcess` returns a
canned `git worktree list`. No process, no disk, no daemon. The rail, the
band, the badges, the teardown dialog and the ⌘K palette read nothing but
`PluginReport`, which is plain data — that was master-plan decision 2, and it
held.

So "the studio over fake data" is built today, down to the panel boundary.

**Below that boundary, the seams sit at the process edge.** Each core keeps
the real machine behind something a test can replace:

| plugin | seam | used by |
|---|---|---|
| scenarios | `ScenariosCore.debugInstallRunner(path, ScenarioRunner)` | `app/test/scenarios/panel_test.dart` — real core, real panel, fake runner that writes real files |
| scenarios | `ScenarioArtifacts` with `_io` and `_http` ends | the panel (io) and the exported page (http) |
| previews | `CatalogSession.connectToDaemon` | daemon client tests |
| previews | `PreviewThumbnails(PreviewRender)` — a function | thumbnail tests |
| previews | `InspectClient` over a fake guest | `app/test/previews/show_entry_test.dart` |
| export | `ViewerBundle.debugCompile` | export tests |
| shell | `WorktreeDiscovery.runProcess` | every shell test |

These are the right seams for core tests, and they stay. They are the wrong
seams for a web demo, because a core with a fake runner still walks the disk
to *list* scenarios, and a session with a fake daemon still owns an embedded
engine.

**The gap: a panel is typed on its concrete core.** `NativePlugin<C extends
PluginCore>` hands the panel `core` as `C`, and the panel calls it directly —
by design, since a run dialog streaming output for thirty seconds is not a
shape `Session.invoke` can express. Counted by grep over the two headline
panels:

| panel | distinct core members touched | core size |
|---|---|---|
| `scenarios_plugin.dart` | ~25 (`scanResultFor`, `panelRunFor`, `startRun`, `branchDelta`, `offeredDevicesFor`, `renderVideo`, …) | 4,521 lines |
| `previews_plugin.dart` | ~15 (`sessionFor`, `thumbnailsFor`, `entriesFor`, `canvasesFor`, `testRunnerFor`, …) | 3,423 lines |

A fake at this level means an interface per plugin: what the panel reads,
and the verbs it fires. That interface is the abstraction the question was
about.

## The web, measured

The shell's import closure, walked over relative and `package:flutterware_app`
imports from `app/lib/src/shell/shell_view.dart`:

| | files |
|---|---|
| closure of `shell_view.dart` | 399 |
| of which import `dart:io` | 138 |
| `dart:isolate` | 12 |
| `package:vm_service` | 10 |
| `package:watcher` | 2 |
| `package:hooks_runner` / `package:code_assets` | 3 (`assets/build_hooks.dart`, `previews/asset_bundle.dart`, `plugins/manifest_loader.dart`) |

For comparison, the closure of `main_export_web.dart` — the viewer that already
ships — is 105 files, and `scenarios/flow_view.dart` alone is 44.

Then the experiment: a throwaway `lib/main_web_probe.dart` importing
`shell_view.dart` and running an empty app, built with `fvm flutter build web`
on the pinned SDK. It fails in 29s on **exactly one thing**:

```
Error: Dart library 'dart:ffi' is not available on this platform.
  main.dart => package:flutterware_app => package:hooks_runner => dart:ffi
  main.dart => package:flutterware_app => package:code_assets => dart:ffi
```

Nothing else. dart2js ships `dart:io` and `dart:isolate` as libraries that
compile and throw `UnsupportedError` at run time, so 138 imports are not 138
problems. The app itself imports no `dart:ffi`; the embedder reaches native
code by other means. `package:vm_service` is pure Dart over a socket and
compiles.

So the web has two prices, and they are different in kind:

- **Compile:** fence the three files that reach `hooks_runner`/`code_assets`
  behind a conditional import. Small, and the `url_fragment.dart` shim in
  `app/lib/src/utils/` is the pattern already in the tree.
- **Run time:** whatever the demo *executes* must never touch `dart:io`. A
  recorded core guarantees that for the plugin's behaviour; what remains is the
  chrome's own touches, which are few because the shell was kept thin:
  `Platform.isMacOS` in two build methods (`shell_view.dart:448`,
  `catalog_view.dart:3024` — a `defaultTargetPlatform` check is the better
  spelling anyway), `Workspace.exists` (short-circuits on `discovered`),
  `AppContext.appToolDirectory` and `PackageRef.directory`, which construct a
  `Directory` eagerly.

One thing is **unverified**: whether `Directory(path)` can be *constructed* on
dart2js without throwing. If it cannot, those two fields become paths, which
they arguably should be — nothing reads them as a `Directory` at the shell
level.

## Where the guess was half right

The question assumed scenarios and previews are the hardest to fake. Half of
that is backwards.

**Scenarios are the easy half.** The fake data is a real run's export, and the
export is the published, version-gated format (`report.json` with its typed
reader; see `2026-08-11-scenario-web-export-design.md`). `main_export_web.dart`
already draws the flow view, the step page, the inspect dock and the beat view
in a browser from that file over `HttpScenarioArtifacts`; the panel's
`_ScenarioPage` draws the same `ScenarioFlowView`. A recorded scenarios core is
"a core over a `ScenarioWebReport` plus a listing", and every widget below it
exists.

The one wrinkle is the tell that this abstraction pays: the panel hard-wires
`IoScenarioArtifacts` at `scenarios_plugin.dart:372`, where the web viewer
installs the HTTP one. *Where a run's artifacts are read from* is a fact about
the run, not about the panel drawing it. It belongs on the core, and moving it
is the first line of code this work forces.

**Previews are the hard half.** The panel's centre is not data: it is
`CatalogSession`, which owns an `EmbeddedEngine` (a texture), a compiler
daemon client, a live session and an inspect client. A recorded core has to
replace each with its still form:

| live | recorded |
|---|---|
| `GuestTexture(textureId)` on the stage | a still picture — `catalog_view.dart:928` already branches on `engine.textureId == null`, so the picture becomes something the session provides rather than something the view builds |
| `PreviewThumbnails` rendering through `flutter_tester` | PNGs on disk / over HTTP, through the existing `PreviewRender` function |
| `InspectClient` walking the guest | a recorded tree and semantics, the `_FakeGuest` shape `show_entry_test.dart` already has |
| knobs and axes round-tripping to the guest | read-only; a change shows nothing, and the demo says so |
| the compile loop, `SwitchReport`, the startup strip | absent; the status bar reads "recorded" |

This is where the interface gets leaky, and it is the part to budget for. The
comparison's exported page already draws preview *shots* on the web
(`comparison/ui/previews_tab.dart` over `shot_store_http.dart`), which is
evidence the still form is enough for a reader.

## Does the abstraction make the code better?

Yes in three specific ways, and no in one.

**It turns a doc rule into a type.** `native_plugin.dart` says a panel may hold
no capability its core does not have, and must not itself spawn what an action
spawns. With a concrete core in hand nothing enforces that — `web_build_dialog`
calling `core.buildWeb` is fine today only because someone checked. An
interface of reads plus verbs makes the drift a compile error.

**It names what a panel actually depends on.** Twenty-five members of a
hundred-odd. The rest is the machine — build lanes, tester hosts, digests,
watchers — and drawing the line between the two is the refactor. It also
answers the question every panel bug has come with since 2026-08-13 (see the
config-reload findings: a panel tracking a core in `initState` only): what a
panel needs from a core is small enough to be written down.

**Whole panels become previewable in the studio's own catalog.**
`app/tool/catalog/demos/` shows pieces — the comparison stage, the verdict, the
device strip — because a whole panel needs a core, and the sessions that built
those demos each hand-rolled a stage set. A recorded core is the stage set,
made once and shared by three consumers.

**No, if it is done as a generic provider.** The data differs per plugin and
there is no common shape to abstract; a `Provider` with a `get(key)` would be a
map with a fancier name. And **no** if the seam is pushed to `FileSystem` /
`ProcessManager` injection across 138 files — `package:file` is a dependency
already, but threading it everywhere is a large diff whose only beneficiary is
the demo, and the process seams already exist for core tests.

## The design

### One fixture, three consumers

A **fixture** is a directory the real tool produced from `examples/example`:

```
app/demo/fixture/
  status.json            fw status --json — every plugin's PluginReport
  scenarios/
    listing.json         what the panel's list pane draws
    report.json          one run's export, artifacts beside it
    artifacts/…
  previews/
    entries.json         the scan
    thumbnails/…         previews screenshot, one per entry
    trees/…              inspect json per entry
```

Produced by a script (`app/tool/demo/record.dart`), not by hand, so the fixture
is only ever an output of the shipped formats and cannot silently drift from
the readers — every file has a typed reader with a version gate already. A
fixture that stops loading is a format change that needs a note, which is the
right time to find out.

The three consumers:

1. **Catalog demos of whole panels** — a `@Preview` per panel, staged at
   `Devices.window`, light and dark. The thing the studio UI pass kept
   wanting.
2. **Scenario tests of the studio** — `app/test/scenarios/*.dart`, run by the
   same harness users run.
3. **The web demo** — `app/lib/main_demo_web.dart`, the shell over the recorded
   registry, fetching the fixture over HTTP.

### Per plugin: an interface, a live core, a recorded core

```dart
abstract class ScenariosCore extends PluginCore {      // what the panel sees
  ScanResult? scanResultFor(String package);
  ScenarioPanelRun? panelRunFor(…);
  ScenarioArtifacts artifactsFor(…);                    // moved here from the panel
  Future<void> startRun(…);
  …
}
class LiveScenariosCore extends ScenariosCore { … }     // today's class, renamed
class RecordedScenariosCore extends ScenariosCore { … } // reads the fixture
```

`panelFor<ScenariosCore>(ScenariosPlugin.new)` in `native/registry.dart` does
not change. `defaultCoreRegistry()` maps the id to the live core; the demo's
registry maps it to the recorded one. Verbs on the recorded core do nothing
and say so — a run button in the demo shows "this is a recording" rather than
disappearing, because a demo whose controls vanish shows less of the product
than a demo whose controls explain themselves.

The other twelve plugins get one generic `RecordedCore` over their
`PluginReport` from `status.json` — enough for the rail, the badges and search
— and a panel that says "not in this demo". `MissingPlugin` is that shape
already; the demo registers a sibling with kinder words. Dependencies is the
candidate for a third real panel later, since its panel is nearly all table
over `PubDepsStore` output.

### Scenario tests of the studio

Declare `app` in the root manifest's `Scenarios(packages:)`. A test builds a
`ShellController` over the recorded registry, exactly as `shell_view_test.dart`
does, and pumps `ShellApp(shell)`:

```dart
scenario('Open a scenario run', (s) async {
  var shell = demoShell();                     // recorded registry, stub loader
  await shell.start('/demo');
  await s.pumpWidget(ShellApp(shell), shot: Shot('Overview'));
  await s.tap('Scenarios', shot: Shot('Scenarios'));
  await s.tap('Around the shop', shot: Shot('Flow'));
});
```

Two facts make this work without new machinery. `IoScenarioArtifacts` returns
`SynchronousFuture`s over sync file APIs precisely so that a widget test under
FakeAsync does not hang (found 2026-08-11), and neither headline core arms a
`Timer` at construction — the grep found none — so the walk settles. What the
harness draws with is its own font, not the platform's: the pictures are
deterministic, and they are not pixel-identical to a macOS window. For
regression that is the property wanted.

### The web demo

`main_demo_web.dart` = `main_dev.dart` with the recorded registry, an
`HttpScenarioArtifacts`-style fixture source, `setUrlStrategy(null)` as the
export entry point already does, and none of the dock-icon or window-title
calls. Built by the same `ViewerBundle` machinery, hosted where the viewer
already is (the GitHub Pages workflow from PR #306). The README link points at
it.

## Rejected

- **A generic fake data provider.** No shared shape to provide; see above.
- **`FileSystem` / `ProcessManager` injection through the cores.** Right for a
  library, wrong at 138 files for one consumer; the process seams exist and
  serve core tests better.
- **Faking at the runner level for the web.** A fake runner leaves a real core
  that lists scenarios by walking `test/` on disk. The demo needs the core not
  to *want* a disk.
- **Building the demo from the live export route** (the 0×0 iframe design from
  2026-08-11). It makes the user's app compile for web, and the studio is the
  app here — that is the 399-file closure, running for real, in a browser. The
  recorded route needs none of it.
- **Recording the fixture by hand.** A hand-written `report.json` is a second
  spelling of the format that nothing keeps honest.

## Unproven

- `Directory(path)` construction on dart2js — a throw there turns two fields
  into strings, which is a small change but a real one.
- That the previews interface comes out narrow. Fifteen members is the count
  of *calls*; `sessionFor` returns a `CatalogSession`, and how much of that
  object the view reads is the real width. Measure it by doing scenarios first.
- Whether a scenario of the shell settles cleanly with the shell's
  `_RebuildsWhen` filters and the facts controller stubbed. `shell_view_test`
  says yes under `flutter test`; the harness's `Settle` is stricter.

## The angle of attack: one small plugin, the whole slice

Before scenarios, a vertical slice through a plugin small enough that the
slice is mostly the *shared* work — the fixture, the stage set, the harness
on the studio, the web fence — and hardly any plugin work at all. Measured
over the simpler panels (distinct core members the panel touches / files in
the panel's import closure / of which `dart:io`):

| plugin | core members | closure | `dart:io` |
|---|---|---|---|
| launcher icon | 2 in the panel + 4 in the screen (`scanFor`, `failureFor`, `isScanning`, `reload`) | 47 | 8 |
| assets | 2 | 61 | 13 |
| splash | 3 | 63 | 11 |
| dependencies | 5 | 63 | 13 |
| lints | 12 | 48 | 11 |
| store | 6 | 65 | 25 + hooks_runner |
| translations | 19 | 105 | 44 |

**Launcher icon is the one.** Everything its screen reads is a pass-through of
one `ScanCache<(package, flavor), IconScan>`, and `ScanCache` takes its loader
in the constructor. So the recorded core is the *live* core with a canned
loader — `LauncherIconCore(host, scan: recorded)` — and no interface is
extracted at all. Of its 8 `dart:io` files, 5 are the shell's own
(`context.dart`, `package_ref.dart`, `workspace.dart`, `repo_layout.dart`,
`flutter_sdk.dart`) — the shims the web demo needs regardless — and the
plugin's own three are the scan (never run on web) and one leak in the screen:
`FileImage(File(file.absolutePath))` at `launcher_icon/screen.dart:177` and
`:251`. That leak becomes an `ImageProvider Function(IconFile)` the core
supplies, which is the only plugin-specific change. The fixture is real:
`examples/example` carries five Android source sets and three iOS icon sets,
put there as fixtures for this very viewer.

The same loader hook covers assets, splash, scene and translations, whose
listings also sit on `ScanCache`. It does **not** cover scenarios or previews
— their listings are their own — which is why those keep the interface plan
above.

The slice, and what each step proves:

1. `LauncherIconCore` takes an optional `scan` and `image`; `IconScan` and its
   five model types gain `fromJson` (they have `toJson` projections already,
   and the package uses `json_serializable`). *Proves nothing yet; ~50 lines.*
2. `app/tool/demo/record.dart` runs `scanIcons` on `examples/example` for
   every flavor and writes `app/demo/fixture/launcher_icon/*.json` with the
   PNGs beside. *Proves the fixture is an output of the real tool.*
3. The `_FakeCore` / `_StubLoader` / canned-`git` trio moves out of
   `shell_view_test.dart` into `app/lib/src/demo/` as the recorded project:
   a `ShellController` over `status.json` for every plugin and the recorded
   icon core for one. *Proves the stage set is shared, not per-test.*
4. `app/tool/catalog/demos/launcher_icon_panel.dart`: the whole panel, light
   and dark, at `Devices.window`. *Proves a whole panel previews.*
5. Declare `app` in the root manifest's `Scenarios`; write
   `app/test/scenarios/studio_test.dart` — open the shell, go to Launcher
   icon, switch flavor, three shots. *Proves the harness walks the studio
   under FakeAsync and settles.*
6. Fence the three `hooks_runner`/`code_assets` files, shim the two
   `Platform.isMacOS`, resolve the `Directory` question on `AppContext` and
   `PackageRef`, add `main_demo_web.dart`, build and open it. *Proves the
   shell renders in a browser at all.*

At the end of step 6 every shared question is answered on fact and the only
thing left to decide is the interface for the two big plugins — which is
then a decision about those two plugins, not about the idea.

### Two decisions the slice needed, settled on evidence

**Record the scan, not the projection.** The core already emits a JSON
inventory for `fw` (`IconInventoryResult`), so the cheap-looking move is to
record that and draw from it. It is lossy in exactly the places the screen
reads: the projection drops `IconFile.inherited` and `absolutePath`, re-roots
every path to the worktree, keeps `declaredSize` only on a mismatch, omits
empty roles, and reduces `AndroidWiring` to `minSdk` and its source — while
the screen reads `file.inherited`, `file.absolutePath`, every role, and the
wiring. Drawing from the projection means a second screen. So `IconScan` and
its model types (`IconFile`, `IconRoleScan`, `IconFinding`, `IconFlavor`,
`AndroidWiring`, `AdaptiveXml`; the enums by name, `IconRole` by id) gain
`fromJson`/`toJson` with `json_serializable`, which the package already runs.
The fixture is then the scan itself, with the referenced PNGs beside it and
`absolutePath` rewritten to a fixture-relative path the image provider
resolves. The 60-line `_inventory` projection stays as the agent surface;
folding it into `scan.toJson()` is a follow-up, not a prerequisite.

**Keep `Directory` on `AppContext` and `PackageRef`; pass the root, never
read it.** Measured with a `dart compile js` probe run under node:

| on dart2js | result |
|---|---|
| `Directory('/demo/app')` | constructs, `.path` reads |
| `Directory.current` | throws `Unsupported operation: _Namespace` |
| `.absolute.path` | throws `Unsupported operation: Platform._operatingSystem` |
| `.existsSync()` | throws `_Namespace` |
| `Platform.isMacOS` | throws |

So the two fields are fine as they are. What must hold on the web is that
nothing *reaches* the throwing members: `AppContext`'s `Directory.current`
default is not taken when the demo passes a root; `PackageRef.absolutePath`
is read only inside live scan loaders, which the recorded core replaces;
`Workspace.exists` short-circuits on `discovered`, which the recorded project
fills; `worktree_discovery.dart:103` takes `.absolute` only on the not-a-repo
branch, which a valid canned listing avoids. The two `Platform.isMacOS` reads
in build methods move to `defaultTargetPlatform`, which was the better
spelling anyway. No type changes, no diff outside the demo path.

## What was built (2026-09-10, same day)

The launcher-icon slice, all six steps, in one session. Every shared question
above is now answered on fact:

- **The recording.** `app/tool/demo/record.dart` scans `examples/example` as
  `.` and writes `app/demo/fixture/launcher_icon/`: five scans (main, beta,
  kiosk, partner, pro), 89 files copied flat, 295 KB, declared as two asset
  directories. `IconScan` and its six model types round-trip through JSON;
  a role is spelled by its id on the wire.
- **The doors.** `LauncherIconCore(scan:)` takes an `IconScanner`;
  `LauncherIconScreen(image:)` and `LauncherIconPlugin(image:)` take an
  `IconImage`. The live core over the recorded reader is the recorded core.
- **The stage set.** `app/lib/src/demo/recorded_project.dart`: a
  `ShellController` over canned git, an in-process manifest written with the
  same `FlutterwareConfig` classes a project uses, inert facts probes, empty
  watch streams, a quiet `RecordedCore` and a `NotRecordedPlugin` panel for
  the five plugins with nothing recorded. `test/demo/recorded_project_test.dart`
  opens it end to end.
- **Whole-panel catalog entries.** Three in `launcher_icon_panel.dart`,
  photographed through `previews screenshot` under `flutter_tester` with the
  recording read from assets — light, dark, and the kiosk flavor showing
  "4 not overridden" over main's art.
- **The studio scenario.** `app` declared in the root manifest's `Scenarios`
  (narrowed to `test/scenarios`); `studio_test.dart` opens the shell, walks to
  the panel, switches flavor and lands on a not-recorded plugin. Four shots,
  1.4s, green under the harness at `window`.
- **The web.** `lib/main_demo_web.dart` builds in 27s and runs: rail, tabs,
  overview, the launcher-icon panel with its pictures fetched from the asset
  bundle. What it took beyond the compile fence:

  | touch on the run-time path | fix |
  |---|---|
  | `hooks_runner`/`code_assets` import `dart:ffi` | `build_hooks.dart` is a conditional export over `_io` and `_stub`; the kernel-asset types route through it |
  | `Platform.isMacOS` in two build methods | `defaultTargetPlatform` |
  | `flutterwareDir()` reads `HOME` from the environment; `flutterwareRunDir()` creates it | both answer a nominal path on `UnsupportedError` |
  | `WorktreeWatcher` defaults `agentRoot` and `runDir` from the environment at construction | the recorded shell passes both |
  | `scanRunHandles` lists the run directory from the desk button's `initState` | returns nothing on `UnsupportedError`, beside the existing `FileSystemException` case |
  | `ConfigWatcher.watching` and `WorktreeWatcher.start` stat the disk | answer nothing on `UnsupportedError` |
  | `changesConfigKey` stats the config file after every load | null on `UnsupportedError` |
  | `findRepoRoot` and `discoverPackages` walk the disk | null / empty on `UnsupportedError` |

  Every one of these is also the right answer on a desktop whose filesystem
  refuses: the change makes a hostile disk a quiet screen rather than a red
  one. None touched a plugin.

- **A trap worth recording.** The file end of a recording hands back
  `SynchronousFuture`s, and a throw *after* awaiting one escapes the `async`
  function into the zone instead of failing its future — no caller can catch
  it. `recordedIconScanner` awaits through `Future.value(...)` so the resume
  is a microtask. The reverse trap (a real future never landing under
  FakeAsync) is why the file end is synchronous in the first place; the two
  together are the rule: a recording's readers resume on a microtask, never
  inline.

- **CI.** A `studio_demo` job on Ubuntu re-records and expects no diff (the
  recorder pins every mtime to the project clock, so a fresh checkout records
  the same bytes), runs the studio scenario through `fw` on the harness
  lane, and builds the web page with the repository's Pages path as its base
  href. A `deploy_demo` job publishes that build to GitHub Pages on every push
  to master through the Actions flow (`upload-pages-artifact` +
  `deploy-pages`). One-time repository setting: Settings → Pages → Source:
  GitHub Actions. The README link lands once the page is live.

### Hardened the same day: the page is tested, the recording is not shipped

Three things the first deploy left open, closed before the next plugin:

- **The compiled page is opened in a browser, in CI.** `flutter build web`
  proves the shell compiles without a filesystem; every one of the eight
  runtime guards above was a read that compiled fine and threw when a frame
  reached it, and every one was found by clicking. A `flutter test
  --platform chrome` lane was measured first and rejected: it compiles with
  DDC rather than dart2js, serves no app assets (`rootBundle` hangs, not
  404s), and never touches `index.html`, the base href or the fetch of the
  recording. `app/integration_test/web_demo_test.dart` instead takes the
  directory the deploy job is about to publish, serves it with shelf under
  the same path as Pages, and drives it with puppeteer's own Chrome: a
  JavaScript error, a failed request, a response at 400 or above, or a
  screen that never shows what the recording holds fails the test with the
  list. The demo turns semantics on at boot (`ensureSemantics`), which is
  what a screen reader gets and the only DOM a browser test can find a tab
  by. Measured: Chrome download 24s once (cached by CI on the lockfile), the
  walk 13s. Removing the recording from the build fails it with the 404 and
  the panel's own "no launcher icon scan" message on screen.
- **The recording lives in one place.** It was in three: git, the pub
  archive (`.pubignore` had no line for it) and every desktop build of the
  studio (declared as assets). Now `app/demo/` is in `.pubignore`, the asset
  declaration is gone with the asset end of `Recording`, and the two ends
  that remain are the file end (scenario, widget test, catalog demo — the
  previews guest runs with the package as its working directory) and the
  HTTP end (the page, resolving `demo/fixture/` against the document's
  `<base href>`). `tool/demo/build_web.dart` is the one place that knows the
  page and the recording go together: it builds and copies. Found on the
  way: `.pubignore` also lets `app/test/` into the archive, 364 files.
- **Facts and pictures, when the recording grows.** What grows is not
  scans. It is rendered output — previews thumbnails, scenario frames and
  trees, scene renders — and rendered pixels are not byte-stable across
  operating systems (the 3D probe showed it). The rule for the next plugins:
  *facts* (what the tool scans, and the small source files a panel draws)
  are committed and freshness-checked; *pictures* (anything rendered on
  `flutter_tester`) are never committed — the `studio_demo` job produces
  them before it builds, and a developer runs the same recorder once. A
  studio scenario over pictures then has a prerequisite step, which is a
  decision for when previews arrive.

And the rule the guards need, so they do not spread: **an `UnsupportedError`
guard lives on the shell path only.** A plugin on the web is either recorded,
so it never touches `dart:io`, or not recorded, so its panel is never built.
The same `try/on UnsupportedError` inside a plugin core would hide a real
desktop bug. Add an `ambient_sdk_test`-style check the day it ships twice.

### The scenarios slice (same day): the runner was the seam, not the core

The go/no-go the plan set for scenarios came out as a *no interface on the
core at all*. The panel reads twenty-six members of `ScenariosCore`, which
looked like the width of an interface — but what the core does that a
recording cannot is only two things: parse the disk (`Isolate.run` over
`ScenarioScanner`) and run a `flutter_tester` (`ScenarioRunner`). Both were
already behind one call each. So the core gained two constructor doors,
`scan:` and `runner:`, exactly like the launcher icon's, and the runner
gained a five-member interface, `ScenarioRunSource` — `list`, `run`,
`logPath`, `onStep`, `dispose` — which is everything the core ever calls on
it. `ScenarioRunner` implements it; `RecordedScenarioRunner` answers the
same five from files. The core does not know which it has.

**The recording of a run is the harness's own report.** `record.dart` runs
`ScenarioRunner` on two files of the example — the coffee shop on a phone
and in a window, three scenarios, 31 steps — and keeps the raw report per
file with every artifact copied in beside it and its seven path fields
spelled relative to the recording. On the way out the recorded runner puts
them under `/recording`, the recorded project's root, so the core's own
relativising hands the panel a recording-relative path and the panel's
artifact source — the recording itself, through a new `artifacts:` door on
`ScenariosPlugin` — reads it. Opening a scenario runs it, in the panel's
model; over a recording that run is a read, which is what lets the studio's
own scenario of the scenarios panel settle under FakeAsync. Measured:
recording 13s; the fixture 3.3 MB, of which 2.4 MB is trees and 1 MB
pictures; the studio scenario 1.3s for six steps.

**What the browser test caught on its first run.** Opening a scenario threw
`_Namespace` on the web: the panel stats the folder's
`flutter_test_config.dart` to know which *pool* a scenario belongs to — the
scope a remembered device is valid in. That is a fact about the project,
not the machine, so the scan now records every governing config folder
(`ScenarioScanResult.configFolders`, by the harness's own rule) and the
panel answers the pool from the scan. One consequence: the pool is known
when the scan lands rather than synchronously, so the panel follows it on
every core change and not only on an address change, and the test that
remembers a device per pool lets the scan land first. The panel's other
disk read, the banner's app icon, became an `appIcon:` door.

**Two doors, one interface, no guard.** Nothing in the scenarios plugin
catches `UnsupportedError`. The one place a superseded run directory was
deleted with a narrow catch now goes through the same housekeeping rule the
sweep already had — a delete that cannot happen is not worth failing a
finished run over — which is a rule about housekeeping, not about the web.

### Previews, step 1 (same day): the guest drawn inline, two seams

Previews is not recorded. It runs: the entry is a widget, and a widget can
be drawn inside the studio as well as in an embedder process. The plan's
four steps ("The cut, in order", decided the same day) start with the two
seams, proven on the desktop before any web work, and this is them.

Measured first, and the measurement settled the shape. The panel reads
about forty members of `CatalogSession`, which looked like the interface
the spec feared. But the session reaches the *guest* through exactly three
things: seven members of `EmbeddedEngine` (the picture), fourteen
`ext.flutterware.*` extension calls through one `callGuestExtension` (the
channel), and the compiler daemon (the catalog). The first two became
interfaces; the third is step 2.

- **`GuestSurface`** (`app/lib/src/embedder/guest_surface.dart`): phase,
  pixel ratio, resize, cancel pointer, `picture()`, `input()`, capture.
  `EmbeddedEngine` implements it — the texture and the input region moved
  behind two methods — and `InlineGuestSurface` *is* the widget, laid out at
  the size the stage asks for under the media query an embedder would
  report, with the same `CatalogHost` root the generated entrypoint runs.
  `catalog_view.dart` draws either and does not know which.
- **`GuestChannel`** (`app/lib/src/embedder/guest_channel.dart`): call,
  require, events, log, reload, close. `GuestVmService` implements it;
  `InProcessGuestChannel` calls the guest's handlers directly. For that the
  published half gained `GuestExtensions` (`lib/src/guest_extensions.dart`),
  a registry every guest handler now registers through — it stores the
  handler and registers it with the VM service too, so a host in another
  process notices nothing. `installInlineGuest` sets a guest up in-process:
  everything a panel asks, minus the key and text-input shims, the error
  hook and the log zone, which would take over the host's.
- **The launcher** (`CatalogSession(launchGuest:)`): the session's `start`
  hands a `GuestLaunch` to a launcher and gets a channel back; the default
  builds the embedder process as before. `debugInstallGuest` installs a
  surface and a channel without `start`, which is what the test uses until
  step 2 puts the catalog behind a seam too.

**Proven by `app/test/previews/inline_guest_test.dart`**: the panel over a
real entry with a knob, in-process. The stage draws it; the inspector walks
it and finds `_Alpha` but not `CatalogView` — the walk starts at the demo
root; a point under the text finds the `Text`; a knob set through the
address rebuilds it. Four tests, no process.

**What the inline guest found.** The walker measured every box against the
*window* (`getTransformTo(null)`) and hit-tested in window coordinates.
In an embedder guest the demo root is the window, so nothing noticed; inline
the boxes were on the studio. Both now measure against the demo root, which
is the same answer for a process and the right one inline. Checked the other
way too: `previews screenshot --engine=guest --node=<id>` through a real
embedder crops exactly the plate it names.

**Also on the way.** The studio's own scenarios moved to
`app/test/scenarios/studio/` with a profile that frames them as a window:
under `flutter test` they ran at 800×600 and the address bar overflowed by
15px on a step's deep address. That overflow is real at that width and is
left as a finding.

### Previews, step 2 (same day): the catalog seam, and the panel on the web

The third thing the session reached the daemon for — entries, a compiled
selection, changes — is `CatalogSource` now, which `CompilerDaemonClient`
implements and `InlinePreviewsGuest` answers from a table. With that,
`CatalogSession.start` runs with no daemon and no process: the inline test
opens the panel through `start`, and the recorded shell declares previews
over `InlinePreviewsGuest(previews)` — two doors on `PreviewsPlugin`
(`connectToDaemon`, `launchGuest`), a scan door on `PreviewsCore`, and
thumbnails off, since they render on `flutter_tester`.

**One fact the two seams share.** An embedder guest is told which entry
to show by a *regenerated entrypoint* whose file entry moved, hot-reloaded
over it; `showEntry` is the fast path when the guest is already up. The
panel's first switch after start races the picture's mount, and when the
show arrives before it the session falls to the compile path — which for
the inline catalog was a no-op, so the page kept showing the first entry
under the header for the second. `select` now records the entry the way
the entrypoint would, and the inline root rebuilds with it as its file
entry: the guest lands on the selection whether or not it was mounted to be
told. Found on the browser walk, pinned by the test.

**Where the entries come from.** The web demo is its own workspace
package now, `web_demo/`, never published: it has to import both the
studio and the example's previews; the studio cannot depend on an example;
and the example must not depend on the studio — tried, and a dev
dependency that way put the studio's file picker and URL launcher into the
example app's macOS plugin registrant. Its entry point is
`web_demo/demo/main.dart`, and beside it `entries.g.dart` and one wrapper
per entry, generated by `tool/demo/web_entries.dart` with the same
`CatalogWrapperWriter` the guest entrypoint uses — the annotation
evaluated in the demo's own scope, the builder reached by name — so an
entry is staged in the browser exactly as in a process. Outside `lib/`,
like the example's own previews: a file under `lib/` is addressed by a
`package:` URI and a relative import from one cannot leave the package,
and the wrappers reach the example's demos, which have no `package:` URI,
by relative path. Nine of the example's 27 entries survive the filter: not
`dart:ffi` anywhere, not the GPU or the scene libraries, and not `dart:io`
in the example's own files (the studio's libraries carry `dart:io` to
stubs everywhere and never call it from an entry). `build_web.dart`
regenerates the table and builds the demo package into `app/build/web`;
CI regenerates and expects no diff.

**And one thing it caught in the dependencies plugin.** `pub deps` was
cached against the lockfile and the package config, on the claim that pub
reads nothing else. An edge between two workspace members is in neither
— a member is not locked — so the example gaining a dev dependency served
the answer from before it. The workspace's pubspecs are in the stamp now.

**What the browser walk caught this time.** An entry wrapped in its own
`MaterialApp` brings a navigator whose modal barrier blocks the semantics
of everything painted before it, up to the nearest semantic boundary. In a
process the boundary is the window; inline, without one, it was the
studio: the rail, the tabs and the entry list vanished from the
accessibility tree the moment Buttons mounted, and the walk could not find
Dependencies any more. The inline picture is a boundary now, the way a
window is. Pinned by a test that paints a text before the stage and reads
its semantics after an app-wrapped entry opens.

### Previews, closing (same day): the demo as a scenario, and no thumbnails

**Thumbnails in-process were not built, on purpose.** The landing's
pictures come from the tester lane with a content-keyed disk cache; an
in-process version means mounting every entry hidden in the studio's own
tree, waiting a frame each, capturing, and keeping a second pipeline in
step with the first — a duplicate serving one page. What was wrong was
smaller: with thumbnails off and nothing selected, the stage drew whichever
entry the guest held, a demo nobody asked for. That state is a plain "pick
a demo" now.

**The web demo is a scenario.** `web_demo/test/scenarios/web_demo_test.dart`
walks the page's own shell, recording and compiled-in previews under the
harness: the catalog, an entry live, staged as a phone, its tree, another
entry on the phone — seven steps, 2.8s, framed as a window by the folder's
profile, and CI runs it beside the studio's own. The demo package is the
one place the recorded shell and the example's entries meet, which is why
the scenario lives there and not in the app.

**The isolation cost, seen.** The example's column of buttons is 384
points tall; at "Fit" into the half-height stage the Elements tab leaves,
it overflows by 99. An embedder guest keeps that overflow to itself and
its Problems tab; a guest drawn inline raises it in the studio's own
tree, where the harness reports it as the studio's failure and the browser
walk would count it as a console error. The walk stages the phone before
it opens the tree. This is the one thing the inline guest gives up, and it
is worth writing down: an entry's layout error is the page's. A per-guest
error sink is possible — `FlutterError.onError` is global, but the details
name the element chain — and is left until it is needed twice.

### One subject for every fixture (same day): the coffee shop

The demo's three recorded or compiled-in plugins now show one app — the
example's coffee shop, which the scenarios already walked.

- **Previews are curated, not "everything a browser can compile".** The
  shop had no previews; `demo/shop.dart` gives it five, one per screen,
  under a `PreviewShell` that is the shop itself — `ShopApp` takes the
  screen as its home, so a preview reads the shop's theme, strings and a
  sample cart, and the two axes are the app's own (dark, and its two
  languages). `web_entries.dart` takes an explicit list of ids and keeps
  the fitness check as a guard that fails the script rather than dropping
  an entry quietly. One packaging fact surfaced: the shop reads its
  strings from `assets/i18n/` at its own root, and inside another package
  that asset is addressed under `packages/flutterware_example/` — a knob
  on `ShopStrings` the demo's entry point and scenario set.
- **The launcher icon is the shop's, drawn by the studio.** The sets on
  disk are fixtures with deliberate *shapes* — a partial override, an
  iOS-only set, a config never generated, a themed layer dropped — that
  the example's README explains and the panel's cases depend on. So
  `flutter_launcher_icons` was not put in the loop: it has one mode, and
  the README already says why a config per set cannot work. Instead
  `demo/brand.dart` draws the icon: `appIcon` is a sheet of every variant,
  a row per set (told apart by tint) and a column per role (icon, adaptive
  foreground, monochrome), and `appIconVariant` is one cell filling the
  canvas, chosen by two knobs. `previews screenshot` photographs the
  variant at 1024 into `assets/brand/`, and `app/tool/demo/brand_icons.dart`
  writes those into every existing file at the size it already has, never
  adding or removing one. The sheet is the first entry of the web demo;
  the confirmation screen (a `name` knob) is where a reader meets knobs,
  and `shopBadges` — one component at three sizes — is the entry that is
  not a screen. The example declares `device: Devices.iphone16`, in its
  own manifest and in the recorded one, so every shop preview opens on a
  phone.

  Found while doing this: picking a knob in the inline guest emptied the
  knob list. `CatalogGuest` rebuilt once more than the demo did, began a
  declaration pass the demo never took part in, and the pass ended with
  nothing declared. A pass now begins only for a new `(entry, revision)`;
  `inline_guest_test.dart` pins it.

### The recording and the scenario, in that order

The scenario does not record. It opens `app/demo/fixture/` through the file
end of the recording — synchronous reads, which is what a walk under
FakeAsync needs — so the recording has to be committed before the scenario
means anything, and CI's freshness check is what keeps a committed recording
honest. The order is deliberate: recording is a real read of a real project
(a directory listing, XML, PNG headers) and belongs to a tool run someone
chose; a scenario is a deterministic walk and must not depend on the disk it
happens to run on.

### Which plugins the recording system reaches

The *system* — a recording directory the tool writes, a `Recording` source
with file, asset and HTTP ends, the recorded shell, the freshness check — is
plugin-agnostic. What differs per plugin is the door and the data:

| plugin | door | recording | cost |
|---|---|---|---|
| launcher icon | `scan:` on the core (built) | scan JSON + files | done |
| assets, splash, scene, translations | the same `ScanCache` loader injection | their scan models, made JSON-serialisable, plus any files the panel draws | a day each, mostly serialisation |
| dependencies | `PubDepsStore` already caches pub's answer as JSON keyed by the lockfile | that cache entry | small |
| lints | `rules.json` at the SDK tag + issue counts | both are files already | small |
| scenarios | interface extraction (see above) | a run's export — the format that ships | the go/no-go for the interface plan |
| previews | interface extraction; the still picture | entries JSON + thumbnails + inspect trees | the hard one |
| run, server, dev stack | none that helps: their subject is a live process | at best a snapshot — a run's log and inspect tree frozen — and the demo would show a cockpit that cannot move | not worth recording; a "not in this recording" panel is honest |

So: mostly yes for the plugins whose subject is the project on disk, which is
nine of fourteen. The three whose subject is a running process are where a
recording stops being a demo and starts being a lie, and the panel that says
so is the right answer there.

### The server slice (2026-09-12): the source was the seam, and no server

The table above put the Server plugin with the live processes, not worth
recording. That was half right: a *run* cannot be recorded without lying,
because its subject moves. A server's subject, as the panel sees it, is a
ring of events it received once — and a ring received is a ring that can be
written down.

**The seam.** `ServerCore` did two things itself: scan the run dir for
handles, attach over a unix socket. Both now go through a `ServerSource`,
and what an attachment hands back is a `ServerAttachment` interface with the
seven members the core and the panel read. `LiveServerSource` is the run
dir and the socket, unchanged in behaviour; `RecordedServerSource` is one
file per server — handle, hello, the ring, the details behind each event,
the answers to the SQL commands — and an attachment that is a completed
replay which never closes. Nothing above the seam changed; the panel is the
panel.

**No server was recorded.** `record.dart --only=server` starts the real
`ServerInspector` in-process, `tool/demo/server_traffic.dart` reports the
coffee shop's afternoon into it through the same calls a server's adapters
make — a zone per request, `http` with lazy details, `sql` and `log` under
it, a `cache` channel the panel has never heard of, an `info` — and the
recorder attaches over the real protocol and keeps what came back. The
shapes are the wire's; a format change breaks the recording at the right
time. Times are re-rooted to the pinned clock and spaced evenly, the
identity is the recorded project's, so re-recording is byte-identical and
CI checks it beside the icon part.

**What it bought.** The page shows the Server panel with a full timeline —
request list, waterfall, SQL tab, details — and the studio's own scenario
walks it: a request opened to its queries, then the listing the panel
badges as an N+1. The demo's clonable app has no such server; the traffic
is fake data by design, and the timeline script is what a real server in
brewline would replace.

**The dev stack, the same afternoon.** Its core already took the process
runner as a value — the catalog scripts five stacks on one screen that way
— so the recording is one more runner: `tool/demo/stack_traffic.dart` is
what the stack script prints for each verb, in each state, and
`RecordedStack` hands it back while `up` and `down` move the state the
probe then reports. The panel's controls therefore do what they say over
the recording. The declaration uses `StackRun.command` rather than
`StackRun.script`, because a script is checked for on disk before it runs
and there is no disk. One trap for the scenario: `FwActionButton` reads
`Done` for 1.4s after a success, and under fake time that is forever until
the walk waits it out.

### The translations slice (2026-09-12): three reads, one source

The plugin reads three things and nothing else: the catalog files, the last
export's `keys.json`, and the pictures that export names. `TranslationsCore`
did the first two itself through `dart:io` and the panel did the third,
opening a `File` in four places. All four now go through a
`TranslationSource` on the core — `catalogsUnder`, `exportDirectoryIn`,
`readExport`, `readShot` — which `LiveTranslationSource` answers from the
package's directory exactly as before. The panel puts the source's
`readShot` in the tree once (`_Shots`, an inherited widget, re-provided
inside the full-screen dialog because a dialog is built above the panel)
and the shared frame decoder reads through it, so a picture is a path and a
reader rather than a file.

**What the recording holds.** `record.dart --only=translations` runs the
live catalog reader over each declared glob and keeps its answer per glob —
a recording cannot walk a glob, so it keeps the walk's result — and then
runs the real action, `fw run translations export`, over the demo app by
the CLI, and copies the export verbatim: `keys.json` and the `shots/` tree.
The recorded source names that directory as the export's own, so the panel
joins shot paths under it exactly as it does on disk and what it builds is
a recording path. The declared catalogs live in `recorded_config.dart`,
pure Dart, because the recorder and the recorded manifest both need them
and neither can import the other's world.

**Not deterministic, by nature.** The export's pictures are `flutter_tester`
frames, which differ across platforms, so this part joins the scenarios
part outside CI's re-record check. On one machine it re-records
byte-identical.

**What it bought.** The page and the studio's own scenario show the panel
with every key's English, its French, its picture in place — the demo app's
two catalogs, thirty keys, twenty photographed — then a key opened to its
frame, the switch to French, and the filter to the two keys French still
lacks. One fix fell out: the panel dated the export with `DateTime.now()`,
which no scenario can pin, so the studio's shot would have read a day older
every day; it reads `clock.now()` now.

### The store slice (2026-09-12): a manifest read once, and pictures a third the size

The store core read three things from disk — the package's pubspec for
its name and one line, the export's manifest by mtime on every rebuild,
and nothing else; the panel opened the images as files in three places
and the viewers took `File`s. The core now takes a `StoreSource` —
`pubspecOf`, `defaultRootIn`, `manifestOf`, `readManifest` — and the panel
a `StorePlugin(image:)` door; the viewers take image providers. The
manifest is the one read that could not stay synchronous over a
recording fetched from a server, so `manifestOf` may answer null for
*not read yet*, the core starts the read once and notifies when it lands,
and the live source never answers null.

**The fixture cannot carry the export.** The demo app's listing exported
whole is 42 MB of PNG — four sets, sixty shots at a store's own canvas —
and the whole recording was five. So this part bends the rule that a
recording is the tool's bytes, in two declared ways: the export is
narrowed by the action's own `--class` to the iPhone sets, and the
recorder keeps each shot at a third of its canvas through `package:image`,
while the manifest keeps the canvas the store receives. 2.7 MB. The iPad
cards draw as any set that has not been exported yet, which is a state
the panel has and the page now shows. Not deterministic across machines,
so it joins the scenario and translations parts outside CI's check.

**Two bugs fell out.** Both viewers — a shot at the store's size, the
listing on its stage — opened nothing on a live project: the manifest's
second version put the app's name at the head of a set's key and the
panel's lookup still matched from the store on. And `ageOf`, which the
panel dates the export with, read the wall clock; it reads `clock.now()`
now, for the reason the translations slice gave.

## What to do next

0. ~~The launcher-icon slice.~~ Built; see above.
1. ~~**Scenarios next, as the go/no-go for the interface.**~~ Built — see
   above. No interface on the core; the runner was the seam. Left for later:
   a whole-panel catalog demo of the scenarios panel over the recording.
2. ~~**Previews, inline.**~~ Built — see above. Thumbnails in-process
   were declined; the demo is a scenario of its own package.
3. ~~**The demo entry point, the record script as a documented command, the
   Pages deploy.**~~ Built; the README link remains.

Related: `2026-08-11-scenario-web-export-design.md` (the viewer this rides
on), `2026-07-29-config-reload-findings.md` (why a panel's dependence on its
core is worth writing down), `2026-07-27-gui-cli-mcp-architecture.md`
(decision 2 — the report is data, only the panel forks).
