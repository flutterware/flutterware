# Contributing

## Development setup

The Flutter SDK is pinned in `.fvmrc` and installed by [fvm](https://fvm.app).
The `flutter`/`dart` on PATH are usually older than the pin and fail the
workspace's SDK constraints — always go through `fvm flutter ...` /
`fvm dart ...`, from any directory.

```sh
fvm install                      # a no-op once the version is cached
fvm flutter pub get
git config core.hooksPath hooks  # once per clone; worktrees inherit it
```

`core.hooksPath hooks` points git at the version-controlled `hooks/` directory.
The value is relative, so it resolves against each worktree's own root — added
worktrees inherit it from the shared config and need no extra step.

## Pre-commit hook

`hooks/pre-commit` formats staged Dart files (and re-stages them) before each
commit, so unformatted code never reaches CI. It compiles
`tool/format_pre_commit.dart` to a cached AOT binary on first use — subsequent
commits are near-instant.

The hook uses the same formatter configuration as `tool/prepare_submit.dart`
(which CI runs); keep the two in sync. Code style beyond formatting (analyzer
lints) is still enforced by CI, not the hook.

If dependencies aren't resolved yet, or the pinned SDK isn't installed, the
hook skips itself gracefully and lets the commit through — run
`fvm install && fvm flutter pub get` to enable it.

## Screenshots

Every picture of the studio in `README.md` and in `doc/` is a named step of
one of the studio's own scenarios, run over a recording of the demo app. CI
renders them on each push to master and publishes them to the
[`media`](https://github.com/flutterware/flutterware/tree/media) branch, one
folder per version; to look at them locally:

```sh
fvm dart tool/screenshots.dart   # writes build/screenshots/media/
```

## Windows

Windows support is in progress.
[The plan](docs/superpowers/specs/2026-09-14-windows-support-plan.md) says
what works, what does not yet, and the order it gets fixed in. What a
contributor needs today:

- **Developer Mode** (Settings → System → For developers). `flutter pub get`
  links each plugin's Windows sources into
  `windows/flutter/ephemeral/.plugin_symlinks`, and Windows creates symlinks
  only for an elevated process or with Developer Mode on.
- **fvm from Git Bash is `fvm.bat`.** PowerShell and cmd find `fvm` by its
  bare name; Git Bash does not run a batch file that way. SDKs land in
  `%USERPROFILE%\fvm\versions`, which is where the pre-commit hook looks.
- **Line endings are LF.** `.gitattributes` checks every file out LF whatever
  `core.autocrlf` says — Git for Windows defaults it to `true`. A clone made
  before that file existed still has CRLF files on disk; with nothing
  uncommitted, `git rm -rq --cached . && git reset --hard` rewrites them once.
- **The pre-commit hook** runs under Git for Windows' bash unchanged; set
  `core.hooksPath` as above.
- **Building the studio** is a Windows desktop build, so it needs Visual Studio
  with the *Desktop development with C++* workload. The tests, the formatter
  and the MCP server do not.
- **Tests.** The root suite is green on Windows, and CI's *Suites on Windows*
  job blocks on it. The app suite still has known Windows failures, which the
  same job reports without blocking — run the app test files you touch one by
  one.

## Releasing

A release is a GitHub release. Its version is the one master already names:

1. `fvm dart tool/release.dart 0.6.1` moves the version everywhere it is
   written and adds an empty `## 0.6.1` to `CHANGELOG.md`. Write that entry,
   run `fvm flutter pub get`, and merge it as an ordinary PR.
2. On GitHub, create a release tagged `v0.6.1`, from master.

The tag starts `.github/workflows/publish-on-pub.yaml`, which does the rest. It
checks that the tag matches master's version and that master's CI passed on
that commit, then installs the package from exactly what pub would upload. It
renders the pictures for `media/v0.6.1/`, publishes to pub.dev, syncs
[flutterware_example](https://github.com/flutterware/flutterware_example), and
installs a fresh clone of it from pub.dev.

Two things are set up once, outside this repository:

- **pub.dev**: under the package's *Admin* tab, automated publishing from
  GitHub Actions is enabled for `flutterware/flutterware`, with the tag pattern
  `v{{version}}`.
- **The demo's deploy key**: `flutterware_example` has a deploy key with write
  access, and its private half is this repository's `EXAMPLE_DEPLOY_KEY`
  secret.
