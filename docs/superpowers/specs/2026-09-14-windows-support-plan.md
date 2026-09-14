# Windows support: where it stands, and the order to fix it in

*2026-09-14. Measured on Windows 11 x64 (24H2, build 26100 — the machine moved
to 25H2 the same afternoon) with the pinned SDK (3.48.0-0.2.pre)
and fvm 4.3.1. §1 is measured on that machine; §2 is read from the code and
ranked, with every measured item marked **(M)**; §3 is the plan; §4 records
the decisions and the evidence for each.*

**Decided 2026-09-14.**
- **State:** `%USERPROFILE%\.flutterware`.
- **Paths:** a relative path that names something is POSIX.
- **Launch:** a detached Dart shim.
- **Scope:** the embedder guest is in (step 6). A Windows native layer
  (UI Automation) is later.

The shape of the problem is better than "never ran on Windows" suggests.
Everything flutterware does **headlessly** already works: plugin status,
device discovery, preview rendering, scenario runs, and 99% of the root test
suite. Previews and scenarios have had a Windows CI job since 2026-08-26, and
it shows.

What does not work is concentrated in one layer: **anything that keeps a
process alive.** The run stack's liveness check terminates the process it is
checking. Launch refuses outright, the catalog daemon detaches through
`/bin/sh`, and `fw app` crashes watching a signal Windows cannot deliver. Fix
that layer and the agent loop, the studio and the catalog panel open up
together. Nearly everything else is paths being used as names, plus test
harnesses that spawn `sh`.

---

## 1. Measured

| What | Result on Windows |
|---|---|
| MCP server (`.mcp.json`) | **Did not start** — `.mcp.json` ran `sh tool/mcp_server.sh`, and `sh` is not on the Windows PATH (the client spawns through `cmd.exe`). Now `fvm dart run flutterware mcp`: **3.5s** warm, **~25s** after an edit under `app/` or `lib/`. |
| `flutterware_status` | Works. |
| `run/devices` | Works — `windows`, `chrome`, `edge`. |
| `run/entrypoints` | Works. The SDK knob default comes back lowercased (`c:\users\…`) by `p.canonicalize`. |
| `run/launch` | **Refuses**: *"Launching is implemented for macOS and Linux hosts"* (`app/lib/src/run/launch.dart:103`). There is no attach, so observe/act/reload/stop are all unreachable. |
| `previews screenshot` (harness) | Works, real fonts. |
| `scenarios run` (brewline, one file) | Passes in 5s, real text in the captures. |
| Root test suite | **1471 passed, 15 failed**, 1 skipped, 1.8 min. Six files — see §2.4 and §2.6. |
| App test suite | **Partial**: 1661 passed, 210 failed across the first ~40% of test files, then the machine bugchecked (§5). |
| `tool/prepare_submit.dart` | **Never finishes** — one core pegged, no output after 10 min. Diagnosed in §2.6. |
| `Process.killPid(pid, ProcessSignal.sigcont)` | **Terminates the process** (exit -1). |
| `ProcessSignal.sigterm.watch()` | **Unhandled `SignalException`** — *"The request is not supported"* — which escapes a `try`. |
| `AF_UNIX` sockets | **Work**: bind, connect and a round trip at a 52-char path. A 108-char path fails on length, the same class of limit as macOS. Not a blocker. |
| Launcher, warm | Rebuilt the CLI on **every** run: it looked for `build/cli/bundle/bin/fw`, and Windows writes `fw.exe`. Fixed with the MCP change. The CLI build takes ~21s here against the ~10s its progress line promises. |
| `git status` after `pub get` or a test run | 16 generated registrants, `.fvmrc` and a regenerated `fixtures/probe_app/demo/scene_args.dart` show as modified with **no content change** — line endings. |
| Detached launch, three candidates | Only a **Dart shim** works; see §4.3. A console program under a detached `cmd.exe` writes nothing to its redirect, and `Start-Process` blocks its caller for the child's whole life. |
| Liveness without a signal | `OpenProcess(SYNCHRONIZE \| PROCESS_QUERY_LIMITED_INFORMATION)` + `WaitForSingleObject(h, 0)` over `dart:ffi`: true while running, false the instant it exits. |
| Build toolchain | **No Visual Studio and no CMake** on the measuring machine, so no Windows GUI build (`flutter build windows`, `run/launch` on `windows`) can happen there yet. `curl.exe` and `tar.exe` ship in `System32`. |

---

## 2. What breaks, by layer

Ranked by how much each unblocks. **(M)** measured; everything else read.

### 2.1 Process lifecycle — blocks run, drive, the catalog panel and `fw app`

The one layer that must be redesigned rather than patched.

- **The liveness probe kills.** `isProcessAlive` sends SIGCONT
  (`app/lib/src/utils/run_dir.dart:324`), and on Windows `killPid` ignores the
  signal and calls `TerminateProcess` **(M)**. Its callers therefore kill
  what they check:
  - the launch wait loops (`launch.dart:768`, `:793`), so a launch would die
    on its first poll;
  - the run-dir sweep after every publish (`run_dir.dart:302`), which kills
    **other worktrees'** live runs;
  - every handle probe (`handle.dart:435`), stop (`run_core.dart:3276`), and
    the guest sweep's owner check (`run_dir.dart:573–583`).
- **The recycled-pid guard is off.** `processElapsed` returns null on Windows
  (`run_dir.dart:358`), so a stale handle can stop an unrelated process that
  inherited the pid.
- **Detached-with-a-log uses `/bin/sh -c 'exec "$@" > "$FW_RUN_LOG"'`**, for
  launch (`launch.dart:164`, refused at `:103` **(M)**) and for the catalog
  compiler daemon (`app/lib/src/previews/compiler_daemon_client.dart:646`).
  Windows has no `exec`, and the handle's `launcherPid` has to be the
  process whose death means reload is gone.
- **No process-tree kill.** Every `.bat` child is really `cmd.exe` with a
  `dart.exe` under it, and `kill()` ends only the `cmd.exe`: measured for the
  MCP server, where killing the top process left six live children until
  their pipes closed **(M)**. Affected: stop (`run_core.dart:3276`),
  `run/inventory.dart` (flutter daemon lease), `utils/flutter_run_process.dart`,
  `previews/web_build.dart`, `utils/viewer_bundle.dart`,
  `plugins/manifest_loader.dart:147`.
- **`fw app` crashes on start.** `app/lib/src/session/gui.dart:285` watches
  `[sigint, sigterm]`, and the SIGTERM watch throws uncatchably **(M)**.

### 2.2 SDK executables spelled the POSIX way

`FlutterSdkPath` already spells `flutter.bat` and `dart.bat`
(`app/lib/src/utils/flutter_sdk.dart:39–42`). These bypass it with
`p.join(sdk, 'bin', 'dart')`, which names a bash script Windows cannot start:

- `previews/catalog_session.dart:1559`, `plugins/native/previews_core.dart:2956`
  — the catalog daemon and its snapshot compile
- `plugins/native/run_core.dart:2212` — knob scripts
- `plugins/native/dev_stack_core.dart:281` — every `StackRun.script`, which is
  all of this repo's own Example server
- `plugins/native/splash_core.dart:718` — Generate splash
- `embedder/embedded_engine.dart:143` — the embedder guest

Beside them:

- **The GUI product path is out of date.** `lib/src/desktop_gui.dart:85` says
  `build/windows/runner/Release`, but Flutter has built to
  `build\windows\x64\runner\Release` since 3.15. So the launcher never finds
  the GUI, rebuilds it every run, and `fw app` spawns a file that is not
  there.
- **`embedder_build.dart:193`** runs `/usr/bin/which`, which throws. The engine
  download then needs `unzip` (`:103`, also `render_bundle/bundle_builder.dart:157`)
  where Windows ships `tar.exe`, and it expects `libflutter_engine.so` where
  Windows has `flutter_engine.dll` (`:30–32`).

`test/ambient_sdk_test.dart` is the natural place for a rule against a bare
`'bin', 'dart'` join.

### 2.3 Where flutterware keeps its state

Three conventions on one machine:

| Code | Root on Windows |
|---|---|
| `lib/src/working_copy.dart:222` (`userHomePath`) — working copy, build locks | `%APPDATA%` (roaming profile, for a ~1.5 GB tree) |
| `app/lib/src/utils/run_dir.dart:33` (`flutterwareDir`), `lib/src/server/protocol.dart:28` — run dir, journals, handles | `HOME ?? USERPROFILE`, so Git Bash moves it |
| `app/lib/src/dependencies/model/pub_dev_api.dart:214` | `%APPDATA%` |

And `bin/flutterware.dart:412` looks for the pub cache at `%APPDATA%\Pub\Cache`.
The default is `%LOCALAPPDATA%\Pub\Cache` (this machine's), so **a hosted
install is taken for a checkout**: no unpack, the GUI under `flutter run`
rather than the release build. `app/lib/src/embedder/seed_kernel.dart:261–266`
already has it right.

Decided in §4.1: all of it moves to `%USERPROFILE%\.flutterware`.

### 2.4 Paths used as names

The biggest group by count. A relative path leaves the file system with
backslashes and then gets compared with, keyed against or shown beside a
forward-slash one from git, a `package:` or `file:` URI, an `fw://` address or
a test expectation.

- **Comparison.** `comparison/import_graph`, `skip`, `runner` and
  `scenarios_side_scan` produce `demo\card.dart` where git says
  `demo/card.dart`. At least one is behavioural, not cosmetic: *"a file that
  is gone on one side is a change"* gets `null` **(M)**.
- **Reports and ids.** Launcher icon findings (`android\app\src\…`), scene
  actions (`lib\scenes\…`), identity (`packages\real_app`), `scenarios read`
  (`build\flutterware\scenario_runs\…`), asset catalog mixed separators
  (`dep\lib/images/logo.png`) **(M)**.
- **A drive letter read as a separator.** `plugins/manifest_loader.dart:328`
  parses the compiler's depfile at the first `:`, which on Windows is the
  one in `C:`. The output joins the inputs, the stamp never matches, and
  **`tool/flutterware.dart` recompiles on every load** — every `fw` command,
  every MCP status. The suite's *"compiles once, then reuses the kernel"*
  gets 2 **(M)**.
- **Case.** `lib/src/scenarios/fonts.dart:91` matches `Roboto-` exactly, and
  the Windows SDK cache holds `roboto-*.ttf`. `loadDefaultScenarioFonts`
  silently does nothing, so default-family text is boxes in the
  `flutter test` lane **(M)**. `p.canonicalize` lowercases, and raw string
  equality misses: `shell/worktree.dart:89`, `shell_controller.dart:622` (git
  porcelain says `C:/…`, the fallback says `C:\…`).
- **Encoded names.** `worktrees/providers/agent.dart:144` builds
  `c:-users-…` for an agent's session directory that is really
  `C--Users-…`, so the agent column is always empty.
- **Frames and URIs.** `test/inspect/node_test.dart` (8) and
  `test/scenarios/declaring_file_test.dart` (1) **(M)** — fixture URIs are POSIX.
  Whether the product folds a real `file:///C:/…` correctly is the thing to
  check before deciding these are test-only.

**The rule this wants** — decided, see §4.2: a path that is a *name* —
compared, keyed, reported, addressed — is POSIX, and the conversion to a
native path happens at the edge where a file is opened. The expectations in
these tests are already right.

### 2.5 Line endings

No `.gitattributes`, and Git for Windows defaults to `core.autocrlf=true`:
2620 working files are CRLF.

- Generated files rewritten with LF show as modified: the 16 registrants,
  `.fvmrc`, `scene_args.dart` **(M)**.
- `hooks/pre-commit` is checked out CRLF (`i/lf w/crlf`) **(M)**, and bash
  fails on `set -e\r` the moment `core.hooksPath hooks` is set.
- `app/test/tools/capabilities_test.dart:22` compares the rendered
  capabilities (LF) with `docs/capabilities.md` on disk (CRLF).

`* text=auto eol=lf`, with `*.bat`/`*.cmd` as `eol=crlf`, and one
renormalising commit.

### 2.6 Tooling and test harnesses

- **`prepare_submit` is an infinite loop.** `project_tools`'
  `_upperGitIgnores` walks up from a subproject until `current.path ==
  gitRoot.path`. `gitRoot` comes from `git rev-parse` as `C:/Users/…`,
  `current` from `Platform.script` as `C:\Users\…`, so the strings never
  match and the walk sticks at `C:\`. Workaround here: `DartProject.find(root,
  gitRoot: root)` in `tool/prepare_submit.dart:9`. Fix upstream: `p.equals`,
  and stop when a directory is its own parent.
- **Test helpers find `dart-sdk/bin/dart` without `.exe`** and fall back to
  `flutter_tester`: `test/build_output_test.dart`, `test/build_lock_test.dart`
  (4 of the root failures) **(M)**.
- **Fakes that are shell.** `true`, `sleep 60`, `chmod +x` (102 failures in
  `run_core_test` alone **(M)**), `#!/bin/sh` fake SDKs
  (`previews_plugin_test.dart:888`, `web_build_command_test.dart:104`,
  `asset_bundle_test.dart:669`), `touch -m -t` (`run_dir_test.dart:121` and 3
  more), POSIX literals used as fake-process keys (`dev_stack_core_test.dart:597`).
- **Symlinks.** Previews asset bundling links assets rather than copying, and
  the fallback reports a change on every rebuild **(M)**. Creating file
  symlinks needs Developer Mode.
- **Open handles block deletion.** Temp directories in `assets_screen_test`
  fail with *"being used by another process"* **(M)**. The same class risks
  `git worktree remove` under the recursive watcher (`worktrees/watchers.dart:331`)
  and renaming over a snapshot a daemon has open
  (`compiler_daemon_client.dart:1356`).

### 2.7 The studio itself (gaps, not crashes)

- **Native runner.** `app/windows/runner` is the stock template. macOS has
  channels for the window title and icon, image clipboard and the embedder
  texture; the Dart side gates them, so Windows just goes without.
- **Chrome.** The 78px traffic-light inset (`shell/shell_view.dart:63`)
  applies on every platform, under Windows' own title bar.
- **Shortcuts.** ⌘-only chords with no Ctrl twin — scene save, undo, redo,
  duplicate, select all; the database panel's ⌘↵ — and hard-coded ⌘ labels.
  Plenty of the shell already has twins (`shell_view.dart:195–254`).
- **Encoding.** git and adb output is decoded with `systemEncoding`
  (`utils/run_git.dart:59`), which is the ANSI code page on Windows, so
  non-ASCII branch names and labels probably garble.
- **Native layer.** No Windows driver (UI Automation). It refuses cleanly;
  every non-adb branch is gated on `Platform.isMacOS`.
- **Plugins.** All of `app/pubspec.yaml`'s declare Windows. No gaps.

### 2.8 CI and docs

- **One Windows job**, `previews_audit_windows`
  (`.github/workflows/analyze-and-test.yaml:274`): pub get, previews audit,
  scenarios, two preview test files. Not analyze, the suites, `prepare_submit`
  or `bump_flutter --check`.
- **`README.md`** still says live previews are macOS-only.
- **`CLAUDE.md`** gives `-d macos` and `$(which flutter)` as the way to run the
  studio, and the MCP loop hard-codes `device: macos`.
- **No Windows contributor notes**: Developer Mode, the Visual Studio C++
  workload, Git Bash, `core.longpaths`, `fvm.bat`.
- **`examples/brewline` has no `windows/` runner.**

---

## 3. The plan

Ordered so each step gives the next one a signal. Each is PR-sized.

### Step 1 — The repo is workable on Windows

- Land the MCP launch change: `.mcp.json` → `fvm dart run flutterware mcp`,
  `tool/mcp_server.sh` deleted, `fw.exe` in the launcher, CLAUDE.md. **Written
  and verified, uncommitted.**
- `.gitattributes`, renormalised.
- The `prepare_submit` workaround, and the fix sent to `project_tools`.

**Done when** `prepare_submit` completes on Windows and `git status` is clean
after `pub get` and a test run.

### Step 2 — The suites tell the truth on Windows

- `.exe` in the test helpers that locate `dart`.
- Replace shell fakes (`true`, `sleep`, `chmod`, `touch`, `#!/bin/sh`) with
  Dart scripts spawned through the real `dart`, so one fake serves every OS.
- POSIX literals that become process keys or expectations → `p.join`, except
  where the expectation is a name (§2.4) — those stay, and the product moves.
- Lanes that are genuinely macOS-only (the `gpu` tag, the embedder guest) say
  so with a skip reason.

**Done when** the root suite is green and every remaining app-suite failure
is one of the product bugs in steps 3–6. Run the app suite on CI or file by
file; see §5.

### Step 3 — Paths as names

- Lift the helper pair out of `list_files.dart` (§4.2), and move comparison,
  launcher icon, scene, assets, identity and `scenarios read` onto it. Audit
  the rest of the 77 `p.relative(` calls.
- The depfile parser (`manifest_loader.dart:328`), the font match
  (`fonts.dart:91`), case-insensitive worktree equality, and the agent
  directory encoding.

**Done when** those app tests pass with their expectations unchanged, and
`tool/flutterware.dart` compiles once.

### Step 4 — Process lifecycle: the unlock

- **Liveness without a signal.** `OpenProcess(SYNCHRONIZE |
  PROCESS_QUERY_LIMITED_INFORMATION)` + `WaitForSingleObject(h, 0)` over
  `dart:ffi`, with no dependency; measured correct. Restore the recycled-pid
  guard with the creation time from `GetProcessTimes`.
- **Tree kill.** `taskkill /PID <pid> /T /F` left nothing of the shim's tree
  **(M)**. Use it for stop and every `.bat`-wrapped child. A Job Object inside
  the shim is the stronger version: kill-on-close is safe there, because the
  shim lives exactly as long as the run.
- **Detached with a log: the Dart shim** (§4.3). `launchApp` on Windows starts
  `dart.exe <shim> <log> <flutter.bat> run --machine …` detached, and the
  shim's pid is the handle's `launcherPid`. The shim:
  - starts flutter with pipes;
  - copies both streams into the one log;
  - exits with flutter's exit code.

  It uses `dart:io` only, so it runs under the SDK flutterware itself runs
  under, with no package resolution. The same shim starts the catalog daemon.
- **Signals.** Watch only SIGINT (and SIGBREAK) on Windows in `gui.dart:285`.
- **SDK executables.** Route the §2.2 joins through `FlutterSdkPath`, and add
  the `ambient_sdk_test` rule.

**Done when** `run/launch` of *Studio (dev)* on `windows` reaches observe,
act, reload and stop over MCP; the catalog panel opens; and two worktrees'
runs coexist through a sweep. This needs Visual Studio's C++ workload on the
machine that checks it.

### Step 5 — `dart run flutterware` for a Windows user

- The GUI product path with `x64`.
- The pub cache under `%LOCALAPPDATA%`.
- One state root, `%USERPROFILE%\.flutterware`, behind one function (§4.1).
- A missing C++ toolchain refused before the GUI build, naming the Visual
  Studio workload, rather than an MSBuild error 40 seconds in.
- Rebuilding `fw.exe` or `Flutterware.exe` while one is running: Windows
  refuses to overwrite a running image, so build to a temp name and rename
  the old one aside.
- Check `fw init`'s `"command": "dart"` against MCP clients that spawn without
  a shell. Claude Code goes through `cmd.exe` and finds `.bat`; not every
  client does.

**Done when** a scratch project with a hosted dependency opens the GUI from
`dart run flutterware`, and `fw mcp` connects.

### Step 6 — The embedder guest

The guest is a native `host` built with CMake from `app/native/` against the
engine's embedder API. It connects to the GUI over the `g-<name>.sock` AF_UNIX
socket and hands frames to a runner texture plugin through the
`flutterware/embedder_texture` channel (`createTexture`, `updateSurfaces`,
`markFrameAvailable`, `disposeTexture`). macOS renders Metal into IOSurfaces.
Linux reads back a surfaceless-EGL FBO into `/dev/shm`. Everything that is
not macOS is treated as Linux today.

- **Engine artifact.** `windows-x64-embedder.zip` already resolves, and the
  engine build lists only `flutter_embedder.h`, `flutter_engine.dll` and its
  `.lib` — **no ANGLE**. Make `flutter_engine.dll` the completion marker
  (`embedder_build.dart:30`). Replace `/usr/bin/which`, `curl` and `unzip`
  with `System32`'s `curl.exe` and `tar.exe` (`:102–111`, `:193`).
- **Host build.** An `elseif(WIN32)` in `app/native/CMakeLists.txt` that
  links `flutter_engine.dll.lib` and `ws2_32`, and copies the DLL beside
  `host.exe`. `buildHost` builds `--config Release` and returns the `.exe`.
  Find CMake and MSVC for a GUI-launched build (no `vcvars` environment
  there).
- **Native portability.** `ipc.c` and `host.c` move from `sys/socket.h`,
  `sys/un.h` and pthread to Winsock with `afunix.h` and SRWLOCK. The
  `__APPLE__`/else splits become three-way. Wide-character file APIs, or a
  UTF-8 manifest, so a non-ASCII profile path works.
- **Frames: a shared-memory copy first, as Linux does.** A `surface_win.c`
  behind the existing `surface.h`, with `CreateFileMappingW` in place of
  `shm_open`. On the GUI side, a runner plugin maps the view and serves it
  as a `PixelBufferTexture`. Its RGBA upload order matches the Linux ring,
  so the raw-frame decoder is unchanged. A zero-copy DXGI shared handle
  (`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`) comes later, as an
  upgrade the guest offers under its own handle prefix. It needs both
  processes on one adapter and a flush before `FrameReady`.
- **Renderer — spike first.** The zip ships no ANGLE, so an OpenGL ES guest
  must bring its own `libEGL`/`libGLESv2`. The alternative is to run
  Impeller on Vulkan and read back from a staging buffer. The spike answers:
  - Does `flutter_engine.dll` run headless on Vulkan on an Intel iGPU?
  - Is there a redistributable ANGLE build to fetch?
  - Does `windows-latest` bring either up without a GPU?
- **Dart gating.** Lift the macOS/else splits in `embedder_build.dart`,
  `guest_texture.dart:74`, `rasterizerArguments` and
  `guest_texture_test.dart:75`. `_dartExecutable` goes through
  `FlutterSdkPath`.

**Done when** a preview renders through the guest in the studio on Windows,
resizes, captures, and leaves no mapping or process behind when the panel
closes.

### Step 7 — Studio parity

- Ctrl twins and platform-aware labels.
- The title-bar inset on macOS only.
- UTF-8 decoding for git and adb.
- Runner channels for the window title/icon and image clipboard.
- A UI Automation native driver: **later**, by decision.

### Step 8 — CI keeps it

- Grow the Windows job into analyze, the root suite, the app suite (with
  `timeout-minutes`) and the `prepare_submit` check.
- Non-blocking until green, then blocking.
- Fold the six copies of the pin-reading step into one composite action.

### Step 9 — Docs

- A Windows section in CONTRIBUTING.
- PowerShell and `-d windows` forms in CLAUDE.md.
- The README's macOS-only claim.

---

## 4. Decisions

### 4.1 State lives in `%USERPROFILE%\.flutterware`

Candidates were `%USERPROFILE%\.flutterware` and `%LOCALAPPDATA%\flutterware`.
Whichever it is, it sits behind one function. On Windows that function reads
`USERPROFILE` and never `HOME`: Git Bash sets `HOME`, and some managed
machines point it at a network drive, so a server started from PowerShell and
a CLI started from Git Bash would not find each other. Every current caller
moves to it, including the published `lib/src/server/protocol.dart`.

- **The socket budget decides it.** Every AF_UNIX socket lives in the run
  dir, and `checkSocketPath` caps a socket path at 103 bytes on every OS
  (`app/lib/src/utils/run_dir.dart:705`). The longest name is a published
  server's, `srv-<8 hex>-<name ≤24>-<pid>.sock`, about 50 characters. That
  leaves room for a Windows user folder name of about **26 characters** under
  `C:\Users\<name>\.flutterware\run\`, but only about **13** under
  `C:\Users\<name>\AppData\Local\flutterware\run\`. Domain accounts run to 20
  characters and pick up a `.DOMAIN` suffix on collision. Under
  `%LOCALAPPDATA%`, a server socket would quietly stay unpublished for a real
  share of users.
- **It is where the state already is.** `flutterwareDir` resolves there today:
  175 MB of kernels, run handles, shaders and transformed assets on the
  measuring machine. Only the working copy's locks (`userHomePath`, in
  Roaming) and the pub.dev cache live elsewhere. Nobody has a working Windows
  install to migrate.
- **Every doc path stays true.** `~/.flutterware/run/<key>.journal.jsonl`
  expands correctly in both PowerShell and Git Bash, which are the two shells
  a Windows contributor or agent has.
- **It is the neighbourhood.** fvm (`~\fvm`), `.android`, `.vscode` and
  `.claude` sit in the same place on this machine.
- **It moves the working copy out of Roaming,** which is where
  `userHomePath` puts a ~1.5 GB tree today, and the one choice that is
  plainly wrong.
- **Against: roaming profiles** sync everything under the profile except
  `AppData\Local`, so `.flutterware` would roam there. That is a managed-fleet
  configuration an admin can exclude a folder from. If it ever bites, the
  working copy alone can move to `%LOCALAPPDATA%` without touching the run
  dir, whose length is the one that matters.
- **Also:** `checkSocketPath` measures UTF-16 units, not bytes. A non-ASCII
  user name overflows the cap it thinks it is keeping, on every OS.

### 4.2 A relative path that names something is POSIX

**The rule:**
1. A **relative** path that is compared, keyed, reported, addressed or
   serialized is POSIX (`/`) on every OS.
2. An **absolute** path stays native, and is compared with `p.equals` and
   `p.isWithin`, never `==`. `p.canonicalize` is a comparison key only: it
   lowercases on Windows, so it is never shown.
3. The conversion happens once, at the edge where a file is opened.

**One helper pair** carries it: POSIX name from a native path, and native
path from a root plus a name. It is lifted from the two private closures in
`lib/src/utils/list_files.dart:69–74` that already do exactly this.

**Why:**
- **It is already the convention where Windows works.** Scenario discovery
  (`app/lib/src/scenarios/discovery.dart:167`), scene args
  (`scene/args_generate.dart:216`), lints (`lints/model/options_scan.dart:234`,
  `issue_counts.dart:285`) and the file walker all spell names this way.
  Preview entry ids and scenario files came back POSIX on Windows and
  worked **(M)**.
- **Every other source of names is already POSIX:** git output, `pubspec.yaml`
  asset declarations, `package:` and `file:` URIs, `fw://` addresses, and JSON
  artifacts that travel between machines (a run's `run.json` and journal, a
  comparison produced on a Linux runner).
- **The suites already assert it.** The app-suite failures in §2.4 are
  expectations of `/`. A Windows CI job running them (step 8) is the
  enforcement, with no new machinery.
- **The failure modes are lopsided in its favour.** Windows file APIs accept
  `/`, so a conversion missed at the open edge still opens the file and costs
  a cosmetic mixed separator. A conversion missed on the name side breaks
  equality, as in the comparison bug.
- **The audit is bounded:** 77 `p.relative(` calls, 72 of them in `app/lib`.
  Each one is either a name (helper) or a path about to be opened (leave it).

**Rejected:**
- **A `ProjectPath` extension type.** The compile-time guarantee is real, but
  it churns every model and JSON signature for a class of bug the Windows job
  already catches. Revisit if the drift recurs, per the `ambient_sdk_test`
  rule of adding a check once a pattern ships twice.
- **Native separators for display on Windows.** Two spellings of one name is
  the bug being fixed. Git, pubspec and editors' relative paths all show `/`
  on Windows already.
- **Also required:** parsers of native tool output must not treat `:` as a
  separator — the depfile.

### 4.3 Launch detaches through a Dart shim

Measured on the pinned SDK. The same batch-file stand-in for `flutter.bat`
started each way from a folder with a space in its path, printing a tick
every 200ms for 8s:

| | `cmd.exe /d /c` + redirect, detached | **Dart shim, detached** | `Start-Process -WindowStyle Hidden` |
|---|---|---|---|
| Launcher returns | 262ms | **244ms** | 10.4s — blocked on a pipe the grandchild inherited |
| First output in the log | **never** | **0.76s** | only after the launcher returned |
| Console | — | **none** | hidden console |
| Recorded pid dies with the work | — | **same instant** | yes |
| stdout + stderr | — | **one log** | two files |
| `taskkill /T /F` leaves | — | **nothing** | — |

The `cmd.exe` failure is not quoting. With the command passed through the
environment, the same line works attached, and a detached `cmd` can redirect
its own `echo`. But a console program under it — through the batch file, or
`dart.exe` directly — writes nothing to the redirect. Passing the command in
the environment was still needed: Dart quotes arguments for the C runtime,
which `cmd` does not read, so a path with a space cannot travel as an
argument.

The shim is plain `dart:io`, so it runs under the SDK flutterware is already
running under, and it does not contradict the ambient-SDK rule. It is the
launcher pid, so reload's "is the tool still alive" question keeps its
meaning. And it is the natural owner of a Job Object and an exit-code marker
later.

### 4.4 Scope

The embedder guest is in: step 6. A Windows native layer (UI Automation) is
later: step 7 names it and nothing depends on it.

---

## 5. How this was measured, and what to watch for

- **The app suite is partial on purpose.** The measuring machine bugchecked
  twice (`0xD1`, `DRIVER_IRQL_NOT_LESS_OR_EQUAL`) while it ran. Both times
  followed a firmware and driver update, and the root suite and every single
  action ran clean. A kernel driver fault is not something a test process can
  cause, but the app suite's parallel load triggered it twice, so the
  remaining 60% was not rerun there.
- **Corrected during the survey.** Unix domain sockets were read as
  unsupported on Windows. Measured, they work on this SDK; only socket path
  length matters.
- **No Windows GUI was built.** The measuring machine has no Visual Studio,
  so nothing in this document compiles the Windows runner. Step 4's exit
  criterion is the first thing that will.
- **Already fixed, uncommitted:**
  - the MCP server launch
  - the launcher's `fw.exe` freshness check: a warm start went from ~25s to 3.5s
