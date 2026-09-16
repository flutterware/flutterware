import 'dart:convert';
import 'dart:io';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/render_client.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../changes/changes_config_cache.dart';
import '../embedder/flutter_cache.dart';
import '../render_bundle/bundle_builder.dart';
import '../render_bundle/one_shot.dart';
import '../changes/changes_probe.dart';
import '../changes/changes_text.dart';
import '../changes/review_agent.dart';
import '../comparison/artifact.dart';
import '../comparison/compare_command.dart';
import '../comparison/runner.dart';
import '../constants.dart';
import '../plugins/plugin_core.dart';
import '../shell/repo_layout.dart';
import '../shell/worktree_discovery.dart';
import '../utils/base_href.dart';
import '../utils/flutter_sdk.dart';
import '../worktrees/facts.dart';
import '../worktrees/facts_probe.dart';
import '../worktrees/facts_store.dart';
import '../worktrees/facts_text.dart';
import 'action_shapes.generated.dart';
import 'gui.dart';
import 'init.dart';
import 'job.dart';
import 'mcp_server.dart';
import 'session.dart';

/// One `fw` command, as data.
///
/// This list is the only place a command's name, usage and summary are
/// written. `fw help` renders it and so does `docs/capabilities.md`; a command
/// added here appears in both without either being touched, which is the
/// arrangement that stops a document describing a flag that no longer exists.
class FwCommand {
  const FwCommand(
    this.name, {
    required this.usage,
    required this.summary,
    this.details,
  });

  final String name;

  /// How it is spelled, without the leading `fw`.
  final String usage;

  /// One line, for the command list.
  final String summary;

  /// The rest, for `fw help <command>` and for the document.
  final String? details;
}

const fwCommands = [
  FwCommand(
    'status',
    usage: 'status [<plugin>] [--brief] [--json]',
    summary: 'what every plugin says about itself',
    details:
        'Loads what each plugin has not loaded yet, then reports. A `fw` '
        'process\nstarts cold every time, so a run that reported only cached '
        'state would\nsay "not computed" for everything, every time.\n\n'
        'Loading is parsing — pubspecs, demo files. Nothing here compiles, '
        'spawns\na daemon or touches the network; that work lives behind '
        '`fw run`.\n\n'
        'Name a plugin — a full id or its last dotted segment — and only '
        'that\none is loaded and reported. `--brief` keeps the status line '
        'and the\nper-package entries and drops the panel projection, which '
        'is nine\ntenths of the reply.',
  ),
  FwCommand(
    'worktrees',
    usage: 'worktrees [--refresh] [--json]',
    summary: 'every checkout of this repo, and what is going on in each',
    details:
        'The CLI rendering of the explorer. Runs no project code — it reads '
        'git,\nagent session files and `gh`/`glab` — so a worktree you have '
        'never\nopened reports as fully as one you are looking at.\n\n'
        'Batched where the tools allow it: one `for-each-ref` covers every '
        'branch,\none `pr list` covers every pull request, and a branch diff '
        'is cached\nunder ~/.flutterware by its two commits, which cannot '
        'change once written.\n\n'
        'Pull requests are the one answer that lives on a server, so they are '
        'kept\nfor five minutes. `--refresh` asks again.\n\n'
        'A column every worktree leaves empty is not printed: no `gh`, no '
        'agent,\nor a format that stopped parsing all read as one column less.',
  ),
  FwCommand(
    'changes',
    usage: 'changes [<worktree>] [--file=<path>] [--json]',
    summary: 'what a checkout has changed, ranked',
    details:
        'The delta from the base branch to the files on disk — committed, '
        "staged,\nunstaged and untracked together. An agent's most "
        'interesting work is the\nwork it has not committed yet, so '
        'committed-ness is a mark on a file rather\nthan what selects one.\n\n'
        'Runs no project code, so a worktree you have never opened reports as '
        'fully\nas the one you are standing in. Name one by directory or '
        'branch; with no\nname it reads the checkout you are in.\n\n'
        "`--file=<path>` prints that file's patch and nothing else — what an "
        'agent\nwants when it already knows which file it is asking about.\n\n'
        'The base is inferred from origin/HEAD, then main, then master. When '
        'none\nof them resolve it says so rather than diffing against a '
        'guess.',
  ),
  FwCommand(
    'review',
    usage:
        'review [--all] [--json] | review resolve <id> [--message=<text>] '
        '| review unresolve <id>',
    summary: 'the notes a human left on this checkout, and answering them',
    details:
        'A note is written on a line of the diff in the GUI, while you keep\n'
        'working — it carries the code it was written about, so nothing here\n'
        'addresses a line that can move.\n'
        '\n'
        'With no arguments: what is still outstanding, as markdown, each note\n'
        'headed by the id you answer it by. `--all` includes what has already\n'
        'been dealt with.\n'
        '\n'
        '  fw review resolve <id> --message="did it, see foo_test.dart"\n'
        '\n'
        'Resolving is recorded as the agent — that is what the human sees\n'
        'beside the note, and it is the difference between *it says it did\n'
        'this* and *I ticked this off*. `unresolve` puts one back.\n'
        '\n'
        'Reads git and a log under ~/.flutterware, so it opens no session and\n'
        'runs no project code. Name a worktree to read that one instead.',
  ),
  FwCommand(
    'actions',
    usage: 'actions [<plugin> [<action>]] [--json]',
    summary: 'what can be invoked, and with what',
    details:
        'The same list the GUI draws buttons from and an agent reads over '
        'MCP.\nThere is no second source for it.\n\n'
        'Name a plugin for that one alone; name an action too for that '
        'action\nin full — parameters documented, and the shape of what '
        'comes back.',
  ),
  FwCommand(
    'run',
    usage: 'run <plugin> <action> [--k=v]',
    summary: 'invoke one action',
    details:
        '`<plugin>` may be a full id or its last dotted segment.\n'
        '\n'
        '  fw run <plugin>                  the actions that plugin has\n'
        '  fw run <plugin> <action> --help  what it takes, and what it '
        'returns\n'
        '\n'
        'An artifact prints as its path, so `fw run … | xargs open` works.\n'
        'Structured results print as JSON. `--json` prints the whole '
        'artifact:\naddress, resolved axes and all.',
  ),
  FwCommand(
    'init',
    usage: 'init',
    summary: 'write the two files this project needs',
    details:
        'A starter tool/flutterware.dart if the project has none, and a\n'
        'flutterware entry in .mcp.json so an agent opening the repo finds '
        'the\ntools without being told.\n'
        '\n'
        'Both are committed, and both describe the project rather than this\n'
        'machine — nothing about your SDK is recorded anywhere. .mcp.json is\n'
        'shared, so it is merged rather than written: another server stays, '
        'and\na flutterware entry someone has edited is left as it is.\n'
        '\n'
        'It runs by itself the first time you use flutterware in a project, '
        'so\nthis is here for scripts and for CI.',
  ),
  FwCommand(
    'app',
    usage: 'app [--release] [--json]',
    summary: 'open the flutterware GUI',
    details:
        'What `dart run flutterware` with no arguments does, spelled out.\n'
        '\n'
        "The first run builds the GUI. That build's output goes to\n"
        '`app/build/gui-build.log` rather than to the terminal; a failure\n'
        'prints the end of it and where the rest is, and `--json` reports the\n'
        'same thing as data. `-v` hands the build the terminal instead, which\n'
        'is the only way to watch it as it goes.\n'
        '\n'
        'The GUI is one renderer of the plugin contract and this is one\n'
        'command of the CLI — it is not a separate program, and there is no\n'
        'capability it has that the commands above do not.\n'
        '\n'
        'When flutterware is a path dependency — when you are working on\n'
        'flutterware itself — this runs the GUI under `flutter run`, so a\n'
        'change is `r` away instead of a rebuild. `--release` takes the built\n'
        'binary instead, which is what an ordinary install always gets.',
  ),
  FwCommand(
    'mcp',
    usage: 'mcp',
    summary: 'serve this project to an agent, over stdio',
    details:
        'Speaks MCP on stdin/stdout, exposing the same plugins and the same\n'
        'actions as the commands above — an agent can do what you can do here.\n'
        '\n'
        'Not a command to type. It is what an MCP client spawns, and what it\n'
        'should be pointed at:\n'
        '\n'
        '    {\n'
        '      "mcpServers": {\n'
        '        "flutterware": {\n'
        '          "command": "dart", "args": ["run", "flutterware", "mcp"]\n'
        '        }\n'
        '      }\n'
        '    }\n'
        '\n'
        '`fw init` writes that entry for you. It names no version manager on\n'
        'purpose: whichever `dart` your client provides is the SDK, resolved\n'
        'when the server is spawned. Prefix it — `fvm dart …` — if that is\n'
        'how your project says which SDK it wants.\n'
        '\n'
        'stdout is the wire. Everything a human might want to read — logs, and\n'
        'whatever this has to build before it can answer — goes to stderr.',
  ),
  FwCommand(
    'compare',
    usage:
        'compare [--base=<ref>] [--package=<path>] [--entry=<id>] '
        '[--export[=<dir>]] [--frames=all|changed] [--base-href=<path>] '
        '[--report=<dir>] [--jobs=<n>] [--json]',
    summary: 'what this worktree did to the pictures, against its base',
    details:
        'Renders previews and replays scenarios on both sides of the branch '
        'and\ndiffs them — pixels, widget tree, visible texts. Nothing is '
        'blessed:\nthere is no golden and no approve button, both sides are '
        'computed from\ngit on demand. The skip rule answers most entries '
        'without rendering\nanything, so a branch that touched no preview '
        'concludes in milliseconds.\n'
        '\n'
        'The verdict is written to `index.json` (the path prints last) and '
        'shown\non the changes panel of the GUI.\n'
        '\n'
        'Exits 1 when a half produced no verdict: its harness would not '
        'build,\nor — on an un-narrowed run — every one of its rows failed '
        'on both\nsides, or every one failed on the base side alone. '
        'Findings alone do\nnot change the exit code: a branch that changed '
        'pictures still exits\n0, a run narrowed with `--entry` to a '
        'pre-broken flow still exits 0,\nand a job gates on `index.json`.\n'
        '\n'
        '`--base` compares against any ref git can name; the default is the '
        "project's\nconfigured base, then the default branch. `--entry` "
        'narrows to named\nentries and may repeat.\n'
        '\n'
        'Every package either half declares is compared, and the whole lot '
        'lands\nin one `index.json`, one comment and one page. `--package` '
        'narrows and\nmay repeat. Where a run covers more than one package a '
        "row's id carries\nits package — "
        '`packages/gallery/demo/card.dart#card` — and every row '
        'carries\nthe package as a field either way. A package that will not '
        "compile is\none package's worth of silence, named in the half's "
        'note; the others\nstill report.\n'
        '\n'
        '`--export` writes the comparison as a browsable page: a viewer, the\n'
        '`index.json`, and a PNG per frame. Serve the directory over HTTP — '
        'a\n`file://` page cannot fetch its own frames. The default directory '
        'is\n`build/comparison/web` at the repository top level.\n'
        '\n'
        'The page resolves everything against its own URL, so it works '
        'wherever\nit is hosted — a bucket root or a per-pull-request prefix '
        '— without\nbeing told. Pass `--base-href=/comparisons/42/` only for '
        'a host that\nserves the directory without redirecting to a trailing '
        'slash.\n'
        '\n'
        "`--frames=changed` puts only the findings' pictures in the page. "
        'The\nverdict is untouched — every row is still there with its state '
        'and its\nchannels — but an unchanged entry has no picture beside it '
        'and says so.\nOn a run where the skip rule did not earn its keep '
        'that is most of the\npage: measured at 18.1MB of unchanged frames '
        'against 1.5MB of findings.\n'
        '\n'
        '`--report` writes what a pull-request comment needs: `comment.md`, '
        'a\n`mosaic.png` of the changed entries, and the exported page under '
        '`web/`.\nThe comment references images by `__MOSAIC_URL__` and '
        '`__VIEWER_URL__`\nplaceholders for the workflow to substitute after '
        'it hosts the files.\n'
        '\n'
        '`--jobs=<n>` renders and replays n at a time on each side, so up to '
        '2n\n`flutter_tester`s at once. Each side compiles its harness once '
        'and starts\nthe other guests from it. The default, 1, is one guest '
        'per side and the\nbase before the head: the shape of a runner '
        'sized for one build. A\nside replayed again to rule out the machine '
        'still replays alone, after\nthe others. `index.json` records the '
        'value under `host`.',
  ),
  FwCommand(
    'capture',
    usage:
        'capture [<address>] -o <file> [--size=WxH] [--theme=light|dark] '
        '[--pixel-ratio=N] [--timeout=<seconds>]',
    summary: 'photograph the GUI window itself, at an address',
    details:
        'Opens the GUI, goes to `<address>`, waits until nothing is still\n'
        'working, writes a PNG and exits. No window is left behind and '
        'nothing\nhas to be clicked, so this is what a documentation script '
        'calls.\n'
        '\n'
        '**This photographs the window, chrome and all** — the rail, the tree,\n'
        'the tab bar with the branch name in it, and the panel somewhere '
        'inside.\nThat is the point when the subject *is* flutterware. It is '
        'the wrong\ntool for looking at a widget you are working on: to '
        'photograph a preview\nitself, at its own size and nothing else '
        'around it, use\n\n'
        "    fw run previews screenshot --entry='<file.dart#symbol>'\n"
        '\n'
        'which renders headlessly in about a second and needs no GUI at all.\n'
        '`fw run previews entries` reports both — the `id` that action takes '
        'and\nthe `address` this one does — so holding an address is not a '
        'reason to\nprefer this.\n'
        '\n'
        'Give `--size` and `--theme` for anything you intend to commit. '
        'Without\nthem the picture is whatever size the window opened at, in '
        "whichever\ntheme the machine's OS is set to — so the same command "
        'produces a\ndifferent file on a different desk, and every '
        'regeneration is a diff.\n'
        '`--size` is the layout size, not the window: it is not bounded by '
        'the\ndisplay, so 1600x1200 works on a laptop that cannot show it.\n'
        '`--pixel-ratio` fixes the density the same way — `2` for the retina\n'
        'screenshots most READMEs want, whatever screen runs the command.\n'
        '\n'
        'This always runs the built GUI, never `flutter run`, because it '
        'needs\nan exit code and nobody is at the keyboard. A built GUI that '
        'already\nexists is not rebuilt — so if you are working on the GUI '
        'itself, pass\n`--force-compile` or you will photograph the previous '
        'build.\n'
        '\n'
        'A panel knows it is being photographed — `CaptureMode.isCapturing` — '
        'and\ndecides for itself what that means. The catalog drops its '
        'compile and\nreload timings, because a number sampled from a clock '
        'is a fact about\nthe run rather than about the project, and a '
        'committed screenshot that\ncarries one is a diff on every '
        'regeneration.\n'
        '\n'
        'An address names the space first, then the worktree, then the '
        'plugin,\nin full: '
        '`fw:///worktrees/<worktree>/flutterware.previews/<package>/<entry>`.\n'
        'The worktree slot is positional, so it cannot be left out — `~` is '
        'the\nmain checkout. With no address at all it photographs the home '
        'screen\n'
        'of the worktree you ran it in.\n'
        '\n'
        'What it waits for is every panel that declares itself busy: a cold\n'
        'catalog compile is the usual one, and the guest showing the entry '
        'that\nwas asked for rather than the one before it is part of the '
        'test.\n'
        '`--timeout` bounds that wait; reaching it still writes the picture '
        'and\nsays what was still running.\n'
        '\n'
        'Embedded views are included. The guest renders in its own process '
        "and\nis not in the window's layer tree, so it is captured "
        'separately and\ncomposited in — see decision 5 of the GUI/CLI/MCP '
        'architecture.',
  ),
  FwCommand(
    'render',
    usage:
        'render <point> [--as=svg|png|pdf] [--args=<json>|@file] '
        '[--size=<w>x<h>] [-o <file>] [--text=<policy>] '
        '[--unsupported=<policy>] '
        '| render bundle [--target=lib/renders.dart] '
        '[--out=build/render-bundle] [--platform=<linux-x64|…>] [--json]',
    summary:
        "one of the app's render points as a file, or all of them "
        'bundled for a server',
    details:
        'A render point is a widget or pw.Document the app binds in a '
        'function\nmarked `@RenderRegistry()` (default `lib/renders.dart`, '
        'or `--target=`).\nBoth forms compile the registrar and run it on '
        'flutter_tester — no\ndevice, no GPU.\n\n'
        '`fw render charts/monthly --as=svg --size=400x200 '
        "--args='{...}'`\nrenders one point to a file and prints the path. "
        'A widget point takes\n`--as=svg|png|pdf` and needs `--size`; a '
        'document point is always pdf.\n`--text` picks vectorize, embedFont '
        'or systemFont; `--unsupported`\npicks rasterize, flatten or skip. '
        'Warnings — raster patches, dropped\neffects — go to stderr, and '
        'ride the reply under `--json`.\n\n'
        '`fw render bundle` builds the one directory a Dart server copies '
        'into\nits image: flutter_tester, the compiled registrar, the asset '
        'bundle\nwith its fonts, and a manifest binding the versions '
        'together. Drive it\nwith `RenderPool` from '
        'package:flutterware/render_client.dart.\n`--platform` crosses, '
        "fetching engine artifacts from Flutter's own\nstorage.\n\n"
        'Design: docs/superpowers/specs/2026-08-31-widget-export-design.md.',
  ),
  FwCommand(
    'version',
    usage: 'version [--json]',
    summary: 'which flutterware this is, and where it came from',
    details:
        'Also `fw --version`. Answered before the project is opened, so it\n'
        'works in a directory flutterware has never been set up in — which is\n'
        'where the question is usually asked.\n'
        '\n'
        'One number: the package your project resolved, which is the code\n'
        'that answers your commands. It used to report two, because a\n'
        'globally installed `fw` drifted from the package it ran. Nothing\n'
        'sits in front of the package now.',
  ),
  FwCommand(
    'help',
    usage: 'help [<command>]',
    summary: 'this, or one command in detail',
  ),
];

/// Closes `fw help`, and the document's CLI section.
const fwHelpFooter =
    '`-v` on any command shows the output of whatever it has to build, '
    'instead of\ncapturing it to a log.\n'
    '\n'
    'Run `fw help <command>` for detail, or `fw actions` for what this '
    'project can do.';

/// What an action whose result carries a verdict means for a caller.
///
/// One sentence, printed by `--help` and by the capability document both.
/// Which actions gate used to be answerable only by breaking something on
/// purpose and reading `$?`, which is a poor way to find out that the check a
/// pipeline runs cannot fail.
const gatingNote =
    'Exits 1 when `ok` is false, so a job can gate on this action.';

/// What `fw` exits with — here because the document lists them too.
const fwExitCodes = {
  0: 'success',
  1: 'the action failed, or what it ran did not pass',
  64: 'a usage error: unknown plugin, bad argument, malformed command line',
};

/// Which flutterware is answering, and where its code is.
///
/// One number, because there is one. The package the project resolved is
/// the only flutterware in play: it is reached through `dart run flutterware`,
/// so nothing sits in front of it that could carry a version of its own. This
/// used to report two — a globally installed `fw` was installed once and never
/// refreshed, so it drifted from the package it ran, and the pair had to be
/// printed to say which was which. There is no such binary now.
///
/// Where the package is, spelled as the launcher decided it: a path dependency
/// runs in the checkout, a hosted one from a copy under `~/.flutterware`. That
/// is the distinction that explains why an edit did or did not take effect, so
/// it is on the line rather than left to be inferred from the path.
///
/// Built from an environment map rather than reading [Platform] itself, because
/// the interesting case — the two versions disagreeing — is one only the
/// environment can produce.
class FwVersion {
  const FwVersion({required this.version, this.source, this.packageRoot});

  factory FwVersion.of(Map<String, String> environment) {
    var appToolPath = environment[appPathEnvironmentKey];
    return FwVersion(
      version: flutterwareVersion,
      // Both absent together: they are the launcher's word for where it put
      // this install, and nothing else knows.
      source: appToolPath == null
          ? null
          : environment[editableSourcesEnvironmentKey] == 'true'
          ? 'path dependency'
          : 'unpacked from the pub cache',
      packageRoot: appToolPath == null ? null : p.dirname(appToolPath),
    );
  }

  /// The flutterware package that is answering — the one that matters.
  final String version;

  /// How that package got here: `path dependency`, or `unpacked from the pub
  /// cache`.
  final String? source;

  final String? packageRoot;

  Map<String, Object?> toJson() => {
    'version': version,
    'source': ?source,
    'packageRoot': ?packageRoot,
  };

  List<String> get lines => [
    ['flutterware $version', ?source, ?packageRoot].join(' · '),
  ];
}

/// The CLI renderer of the plugin contract — `fw`, minus the process.
///
/// A class rather than a `main`, and its output goes to injected sinks rather
/// than to `stdout`, for one reason: **what `fw` does has to be testable
/// against what MCP does.** The parity rule is only checkable if both surfaces
/// can be driven by the same test over the same session, and a `bin/` file
/// nothing can import cannot be.
///
/// `bin/fw.dart` is what remains: an `exitCode` and one call.
class FwCli {
  FwCli({
    required this.openSession,
    required this.out,
    required this.err,
    this.launchGui,
    this.serveMcp,
  });

  /// How to get a session. A function rather than a session, because `help`
  /// and a bad command line must not open one — running the project's config
  /// file to be told the command was misspelled is a second's wait for nothing.
  final Future<Session> Function() openSession;

  final StringSink out;
  final StringSink err;

  /// Opens the GUI. Injected so a test can drive `app` without a window and
  /// without an SDK; the default reads what the launcher recorded in the
  /// environment.
  final Future<int> Function({required bool forceBuild})? launchGui;

  /// Serves MCP on this process's stdio. Injected for the same reason
  /// [launchGui] is: the real one takes stdin and does not give it back until
  /// the client disconnects, and a test that called it would hand the test
  /// runner's console to a JSON-RPC server and hang.
  final Future<void> Function()? serveMcp;

  Future<int> run(List<String> arguments) async {
    // The global flags come out of the whole line before anything reads it,
    // rather than out of what follows the command. They are global, so they
    // have to work where one is naturally typed — `fw -v run …` reads better
    // than `fw run … -v` and was an unknown command until this stopped
    // slicing the command off first.
    //
    // `-v` needs it twice over: one dash, so `_run`'s "does not start with
    // --, therefore positional" test would otherwise take it for a plugin
    // name. The cost is that an action can no longer have a parameter spelled
    // `--verbose` or `--json`, which is the trade `--json` already made.
    var argv = arguments.toList();
    var json = argv.remove('--json');
    var verbose = argv.remove('--verbose') | argv.remove('-v');

    // No arguments opens the GUI, because that is what `dart run flutterware`
    // has always done and the point of this CLI is that it is the same
    // program, not a different one with different habits. A leading flag is
    // the same command: `fw --force-compile` is `fw app --force-compile`, not
    // a command named "--force-compile" — which is what it dispatched as
    // until this test existed, after the launcher had already paid the forced
    // rebuild the flag asked for. Help flags stay commands.
    var first = argv.firstOrNull;
    var leadingFlag =
        first != null &&
        first.startsWith('-') &&
        first != '--help' &&
        first != '-h' &&
        // `fw --version` used to dispatch as `app --version` and be refused
        // with `unknown argument "--version" for app` — the flag every CLI
        // answers, reported as a mistake, by the one command that opens a
        // window. Not `-v`: that is `--verbose`, taken above.
        first != '--version';
    var command = argv.isEmpty || leadingFlag ? 'app' : argv.first;
    var rest = leadingFlag ? argv : argv.skip(1).toList();

    try {
      // Initializing is not a step someone should have to be told about: this
      // process already knows everything `init` records. `help` is excluded so
      // that reading the help for a project you have not adopted yet does not
      // write to it, and `version` for the stronger reason that it has to
      // answer in a directory that is not a project at all.
      if (command != 'help' &&
          command != 'init' &&
          command != 'version' &&
          command != '--version') {
        await _autoInit();
      }

      return switch (command) {
        'init' => await _init(),
        'version' || '--version' => _version(json: json),
        'status' => await _status(rest, json: json),
        'worktrees' => await _worktrees(
          json: json,
          refresh: rest.remove('--refresh'),
        ),
        'changes' => await _changes(rest, json: json),
        'review' => await _review(rest, json: json),
        'actions' => await _actions(rest, json: json),
        'run' => await _run(rest, json: json),
        'app' => await _app(
          forceBuild: rest.remove('--$forceCompileOption'),
          release: rest.remove('--release'),
          json: json,
          verbose: verbose,
          extra: rest,
        ),
        'mcp' => await _mcp(),
        'capture' => await _capture(rest, json: json, verbose: verbose),
        'compare' => await _compare(rest, json: json),
        'render' => await _render(rest, json: json),
        'help' || '--help' || '-h' => _help(rest.firstOrNull),
        _ => fail('unknown command "$command". Try `fw help`.'),
      };
    } on SessionException catch (e) {
      err.writeln('fw: $e');
      return 1;
    }
  }

  /// Compares this worktree's previews against its base.
  ///
  /// The orchestration lives in `runComparison` — shared with the `compare`
  /// action an agent invokes — and this is its terminal rendering: parse the
  /// flags, stream the halves as they land, print where things were written.
  Future<int> _compare(List<String> arguments, {required bool json}) async {
    String? baseRef;
    var packagePaths = <String>[];
    var only = <String>[];
    var export = false;
    String? exportDir;
    var baseHref = defaultBaseHref;
    String? reportDir;
    var frames = ExportedFrames.all;
    var jobs = 1;
    for (var argument in arguments) {
      if (argument.startsWith('--base=')) {
        baseRef = argument.substring('--base='.length);
      } else if (argument.startsWith('--package=')) {
        // Repeatable, like `--entry=`. Naming none compares every package
        // either half declares.
        packagePaths.add(argument.substring('--package='.length));
      } else if (argument.startsWith('--entry=')) {
        only.add(argument.substring('--entry='.length));
      } else if (argument == '--export') {
        export = true;
      } else if (argument.startsWith('--export=')) {
        export = true;
        exportDir = argument.substring('--export='.length);
      } else if (argument.startsWith('--frames=')) {
        var named = argument.substring('--frames='.length);
        var parsed = exportedFramesFromFlag(named);
        if (parsed == null) {
          return fail('--frames takes `all` or `changed`, not "$named".');
        }
        frames = parsed;
      } else if (argument.startsWith('--base-href=')) {
        baseHref = argument.substring('--base-href='.length);
      } else if (argument.startsWith('--report=')) {
        reportDir = argument.substring('--report='.length);
      } else if (argument.startsWith('--jobs=')) {
        var named = argument.substring('--jobs='.length);
        var parsed = int.tryParse(named);
        if (parsed == null || parsed < 1) {
          return fail('--jobs takes a whole number from 1, not "$named".');
        }
        jobs = parsed;
      } else if (argument.startsWith('-')) {
        return fail('unknown option "$argument". Try `fw help compare`.');
      }
    }
    if (baseHrefProblem(baseHref) case var problem?) {
      return fail('--base-href $problem.');
    }

    var session = await openSession();
    try {
      CompareOutcome outcome;
      try {
        outcome = await runComparison(
          session: session,
          options: CompareOptions(
            baseRef: baseRef,
            packages: packagePaths,
            entries: only,
            export: export,
            exportDir: exportDir,
            baseHref: baseHref,
            reportDir: reportDir,
            frames: frames,
            jobs: jobs,
          ),
          // Progress belongs to a terminal, not to a document: a `--json` run
          // has to be one parseable object from its first byte.
          onProgress: json ? null : out.writeln,
          // Printed before the scenarios start rather than with them at the
          // end: the previews half is the fast one, and a terminal that shows
          // it while the slow half runs is the difference between a report
          // and a wait.
          onPreviews: json ? null : printPreviews,
          onScenarios: json ? null : printScenarios,
        );
      } on CompareException catch (e) {
        return fail('$e');
      }

      var exported = outcome.exported;
      var report = outcome.report;
      if (json) {
        out.writeln(
          const JsonEncoder.withIndent('  ').convert({
            ...outcome.artifact.toJson(),
            'export': ?(exported == null
                ? null
                : {'output': exported.output, 'frames': exported.frames}),
            'report': ?(report == null
                ? null
                : {
                    'comment': report.commentPath,
                    'mosaic': ?report.mosaicPath,
                  }),
          }),
        );
      } else {
        for (var caveat in outcome.artifact.caveats) {
          out.writeln('  note: $caveat');
        }
        if (exported != null) {
          out.writeln(
            '  exported ${exported.frames} frame'
            '${exported.frames == 1 ? '' : 's'} to ${exported.output} '
            '(serve it over HTTP)',
          );
        }
        if (report != null) {
          out.writeln('  report in $reportDir');
        }
        out.writeln('  ${outcome.indexPath}');
      }
      // A half that could not run is not a clean half. The artifact, the
      // export and the `--json` document are all written and printed above —
      // the record is whole — and only the exit code is left to say the
      // verdict is not. See [verdictGap].
      if (verdictGap(outcome.artifact) case var gap?) {
        err.writeln('fw: $gap');
        return 1;
      }
      return 0;
    } finally {
      session.dispose();
    }
  }

  /// The previews half, in a terminal.
  @visibleForTesting
  void printPreviews(ComparisonResult result) {
    for (var item in result.items) {
      if (item.state == ComparedState.same ||
          item.state == ComparedState.skipped) {
        continue;
      }
      out.writeln(
        '  ${item.state.name.padRight(10)} ${item.id}'
        '${item.note == null ? '' : '  — ${item.note}'}',
      );
      for (var delta in item.tree?.diff.deltas.take(3) ?? const <TreeDelta>[]) {
        out.writeln('             ${_nearest(delta)}');
      }
    }
    out.writeln(
      '${result.items.length} entries, ${result.rendered} rendered, '
      '${result.countOf(ComparedState.skipped)} skipped '
      'in ${result.elapsed.inMilliseconds}ms',
    );
    _printBecause(result.because, unit: 'entry', plural: 'entries');
  }

  /// Why the skip rule could not answer what it could not answer.
  ///
  /// The counterpart of the `n rendered` in the line above, and the only
  /// thing that makes that number actionable. A branch that touched no widget
  /// and rendered everything anyway is not a slow comparison, it is a path
  /// the two checkouts disagree about — a lockfile the base's `pub get`
  /// rewrote, a generated file only one side has — and naming it is the
  /// difference between a three-minute mystery and one line.
  ///
  /// Capped, because on a real branch the reasons are per entry and the
  /// summary would be as long as the catalog. Folded first, so the cap almost
  /// never bites: one shared cause is one line however many entries carry it.
  void _printBecause(
    Map<String, int> because, {
    required String unit,
    required String plural,
  }) {
    const cap = 3;
    for (var entry in because.entries.take(cap)) {
      out.writeln(
        '  because ${entry.key} — ${entry.value} '
        '${entry.value == 1 ? unit : plural}',
      );
    }
    if (because.length > cap) {
      out.writeln('  … and ${because.length - cap} more reasons');
    }
  }

  /// The scenario half, in a terminal.
  ///
  /// Nested one level deeper than the previews half because a scenario *is*
  /// one level deeper: the row is the flow, and the lines under it are what
  /// happened inside it.
  ///
  /// **The note is printed, and it is printed first.** A half that could not
  /// run leaves the same empty list as a project with no scenarios, and the
  /// summary line it prints — `0 scenarios, 0 run, 0 skipped` — reads as a
  /// clean verdict either way. The note is the only thing that separates
  /// them, and it was recorded in the artifact and shown to nobody.
  @visibleForTesting
  void printScenarios(ScenarioResults results) {
    if (results.note case var note?) {
      out.writeln('  scenarios: $note');
    }
    for (var scenario in results.items) {
      // Not a finding, and never silent: a scenario whose output depended on
      // the machine is the one line in a job log its author most needs.
      if (scenario.inconclusive case var reason?) {
        out
          ..writeln('  ${'no result'.padRight(10)} ${scenario.scenario}')
          ..writeln('             not compared — $reason');
        continue;
      }
      if (scenario.state == ComparedState.same ||
          scenario.state == ComparedState.skipped) {
        continue;
      }
      out.writeln('  ${scenario.state.name.padRight(10)} ${scenario.scenario}');
      // The outcome's own errors, when no step carries them: a scenario can
      // fail before it captures anything, and then this is the only place a
      // job log says why.
      if (!scenario.items.any((step) => step.note != null)) {
        for (var (side, errors) in [
          ('base', scenario.baseErrors),
          ('head', scenario.headErrors),
        ]) {
          for (var error in errors) {
            out.writeln('             $side failed — $error');
          }
        }
      }
      for (var branch in scenario.branches) {
        out.writeln(
          '             ${branch.added ? '+' : '-'} branch '
          '"${branch.label}" (${branch.steps} steps)',
        );
      }
      for (var step in scenario.items) {
        if (step.state == ComparedState.same) continue;
        out.writeln(
          '             ${step.state.name.padRight(9)} ${step.id}'
          '${step.note == null ? '' : '  — ${step.note}'}',
        );
      }
    }
    // The replays beside the runs, as the previews line puts renders beside
    // entries: a side the store already had costs nothing, and this is the
    // number that says whether it did.
    var notCompared = results.items.where((item) => !item.compared).length;
    out.writeln(
      '${results.items.length} scenarios, ${results.ran} run'
      '${results.ran == 0 ? '' : ' (${results.replays} replayed)'}, '
      '${results.skipped} skipped'
      '${notCompared == 0 ? '' : ', $notCompared not compared'} '
      'in ${results.elapsed.inMilliseconds}ms',
    );
    _printBecause(results.because, unit: 'scenario', plural: 'scenarios');
  }

  /// A tree delta with the top of its path cut off.
  ///
  /// The path is every widget from the entry's root down, which in a terminal
  /// is one line of chrome per finding — `KeyedSubtree › PreviewShell ›
  /// ValueListenableBuilder › MaterialApp › Scaffold › …` before anything that
  /// changed. The last two names are the ones that changed and what holds it;
  /// the whole path stays in `index.json` for a reader with room for it.
  String _nearest(TreeDelta delta) {
    var parts = delta.path.split(' › ');
    var tail = parts.length <= 2 ? parts : parts.sublist(parts.length - 2);
    return switch (delta.kind) {
      TreeDeltaKind.added => '+ ${tail.join(' › ')}',
      TreeDeltaKind.removed => '- ${tail.join(' › ')}',
      _ =>
        '${tail.join(' › ')} ${delta.property} '
            '${delta.base}→${delta.head}',
    };
  }

  /// Serves MCP until the client hangs up.
  ///
  /// Opens no session of its own: a client connects once and then asks
  /// questions for as long as it is alive, so the session belongs to the
  /// request rather than to the process — which is also what makes a tool call
  /// describe the project as it is now rather than as it was at startup.
  Future<int> _mcp() async {
    // Checked once at startup, purely so a machine where no session can open
    // — an fw running under a bare Dart, the one seen in the field — says so
    // in the client's server log at connect time. It used to say nothing
    // anywhere and exit 0, which reads as "connected" right up until the
    // first tool call fails. Checked directly rather than by opening a
    // session: a session load logs to stdout, which from here on is the
    // wire. And serve regardless — every tool call opens its own session and
    // answers the same sentence, shaped, so a half-set-up machine gets an
    // MCP that explains itself rather than a dead one.
    if (await FlutterSdkPath.findSdk() == null) {
      err.writeln(
        'fw mcp: no Flutter SDK above the dart running flutterware — every '
        'tool call will answer this until fw is started with the dart from a '
        'Flutter SDK.',
      );
    }
    if (serveMcp case var serve?) {
      await serve();
    } else {
      await serveMcpOnStdio();
    }
    return 0;
  }

  /// Records the SDK and the rest of `.flutterware/`.
  Future<int> _init({bool quiet = false}) async {
    var init = _projectInit();
    if (init == null) {
      return fail(
        'not inside a project: ${Directory.current.path}\n'
        'Run this from a Flutter project — one with a pubspec.yaml.',
      );
    }
    return init.run(quiet: quiet);
  }

  /// Brings the project up to whatever `init` writes, before every command
  /// rather than once, so no command has to begin by refusing.
  ///
  /// It used to skip everything when `.flutterware/sdk` existed, which made
  /// one artifact stand for all of them: anything `init` learned to write later
  /// never reached a project that had run it once already, and each addition
  /// arrived needing a migration. Every step of [ProjectInit.run] is its own
  /// check and does nothing when its own thing is there, so that gate was the
  /// only part of this that could go stale.
  ///
  /// It costs a few stats, plus one `git check-ignore` until the line is
  /// written — 14ms against the ~3s a command already spends running the
  /// project's config file in a subprocess.
  ///
  /// Only when the launcher told us which `dart` it used. A test driving
  /// [FwCli] directly has no launcher, and must not have its working directory
  /// written to as a side effect of calling a command.
  Future<void> _autoInit() async {
    var init = _projectInit();
    if (init == null) return;
    await init.run(quiet: true);
  }

  ProjectInit? _projectInit() {
    // Still gated on the launcher having run, though nothing here needs the
    // path any more: it is the one signal that says a real invocation is
    // happening rather than a test driving [FwCli] in a directory it would not
    // want written to.
    if (Platform.environment[dartExecutableEnvironmentKey] == null) return null;
    var root = findRepoRoot(Directory.current.path);
    if (root == null) return null;
    return ProjectInit(root: root, out: out, err: err);
  }

  /// Builds the GUI if it is missing, then runs it.
  ///
  /// The context comes from the environment because this process is an AOT
  /// binary: `Platform.resolvedExecutable` is this executable, so the SDK
  /// cannot be found by walking up from it. The launcher ran under `dart run`
  /// and therefore knew — it is the invocation, passed on rather than guessed
  /// at from this side.
  Future<int> _app({
    required bool forceBuild,
    required bool release,
    required bool json,
    required bool verbose,
    List<String> extra = const [],
  }) async {
    // Anything left after the known flags is a typo, and a typo'd flag that
    // silently opened a window would be worse than the unknown-command error
    // it used to be.
    if (extra.isNotEmpty) {
      return fail('unknown argument "${extra.first}" for app. Try `fw help`.');
    }
    if (launchGui case var launch?) return launch(forceBuild: forceBuild);

    var appToolPath = Platform.environment[appPathEnvironmentKey];
    var dartExecutable = Platform.environment[dartExecutableEnvironmentKey];
    if (appToolPath == null || dartExecutable == null) {
      return fail(
        'the GUI has to be started through the launcher, which is what '
        'knows\nwhich SDK and which copy to use:\n\n    dart run flutterware',
      );
    }

    var sdk = await FlutterSdkPath.tryFind(dartExecutable);
    if (sdk == null) {
      return fail(
        'no Flutter SDK above $dartExecutable.\n'
        'Run flutterware with the `dart` from a Flutter SDK, not a standalone '
        'one.',
      );
    }

    return GuiLauncher(
      appToolPath: appToolPath,
      flutterSdk: sdk.root,
      projectDirectory: Directory.current,
      out: out,
      err: err,
      editableSources:
          Platform.environment[editableSourcesEnvironmentKey] == 'true',
      json: json,
      verbose: verbose,
      // Null unless the launcher built the GUI beside the CLI, which is the
      // ordinary first run. Non-null settles the question either way: there is
      // nothing left to build, and a failure is reported from its log rather
      // than by running it again.
      alreadyBuilt: int.tryParse(
        Platform.environment[guiBuildResultEnvironmentKey] ?? '',
      ),
      describeProject: _describeProject,
    ).run(forceBuild: forceBuild, release: release);
  }

  /// Opens the GUI, photographs it and lets it exit.
  ///
  /// Always the built binary, never `flutter run`. On a path dependency
  /// `fw app` hands the terminal to `flutter run` so `r` works, and that is
  /// exactly wrong here: this needs the *app's* exit code, and there is no
  /// human to press anything. `release: true` and `interactive: false` are the
  /// two lines that make an ordinary launch a scriptable one.
  Future<int> _capture(
    List<String> arguments, {
    required bool json,
    required bool verbose,
  }) async {
    String? output;
    String? address;
    String? theme;
    double? width;
    double? height;
    double? pixelRatio;
    var timeout = 180.0;
    var argv = arguments.toList();
    // **Needed here in a way it is not for `fw app`.** On a path dependency
    // `fw app` runs `flutter run`, which decides for itself whether the binary
    // is stale. This forces `release`, and a release binary that already
    // exists is never rebuilt — so while working on the GUI itself, a capture
    // silently photographs the previous build.
    var forceBuild = argv.remove('--$forceCompileOption');
    for (var i = 0; i < argv.length; i++) {
      var argument = argv[i];
      if (argument == '-o' || argument == '--output') {
        if (++i >= argv.length) return fail('$argument needs a file.');
        output = argv[i];
      } else if (argument.startsWith('--output=')) {
        output = argument.substring('--output='.length);
      } else if (argument.startsWith('--size=')) {
        var value = argument.substring('--size='.length).split('x');
        width = value.length == 2 ? double.tryParse(value.first) : null;
        height = value.length == 2 ? double.tryParse(value.last) : null;
        if (width == null || height == null) {
          return fail('--size takes <width>x<height>, as `--size=1440x900`.');
        }
      } else if (argument.startsWith('--pixel-ratio=')) {
        pixelRatio = double.tryParse(
          argument.substring('--pixel-ratio='.length),
        );
        if (pixelRatio == null || pixelRatio <= 0) {
          return fail('--pixel-ratio takes a positive number, as `2`.');
        }
      } else if (argument.startsWith('--theme=')) {
        theme = argument.substring('--theme='.length);
        if (theme != 'light' && theme != 'dark') {
          return fail('--theme takes `light` or `dark`.');
        }
      } else if (argument.startsWith('--timeout=')) {
        var seconds = double.tryParse(argument.substring('--timeout='.length));
        if (seconds == null) {
          return fail('--timeout takes a number of seconds.');
        }
        timeout = seconds;
      } else if (argument.startsWith('-')) {
        return fail('unknown option "$argument". Try `fw help capture`.');
      } else if (address == null) {
        address = argument;
      } else {
        return fail('capture takes one address, and got a second: "$argument"');
      }
    }

    if (output == null) {
      return fail('capture needs somewhere to write: `-o <file>`.');
    }
    if (address != null && Address.tryParse(address) == null) {
      return fail('"$address" is not an address. Try `fw help capture`.');
    }

    var appToolPath = Platform.environment[appPathEnvironmentKey];
    var dartExecutable = Platform.environment[dartExecutableEnvironmentKey];
    if (appToolPath == null || dartExecutable == null) {
      return fail(
        'capture has to be started through the launcher, which is what '
        'knows\nwhich SDK and which copy to use:\n\n    dart run flutterware',
      );
    }
    var sdk = await FlutterSdkPath.tryFind(dartExecutable);
    if (sdk == null) {
      return fail(
        'no Flutter SDK above $dartExecutable.\n'
        'Run flutterware with the `dart` from a Flutter SDK, not a standalone '
        'one.',
      );
    }

    return GuiLauncher(
      appToolPath: appToolPath,
      flutterSdk: sdk.root,
      projectDirectory: Directory.current,
      out: out,
      err: err,
      json: json,
      verbose: verbose,
      interactive: false,
      extraEnvironment: {
        captureRequestKey: jsonEncode({
          'address': ?address,
          'width': ?width,
          'height': ?height,
          'pixelRatio': ?pixelRatio,
          'theme': ?theme,
          // **Absolute.** The GUI is spawned with the app directory as its
          // working directory, so a relative path here would write the
          // screenshot into the flutterware install rather than next to the
          // README that is going to reference it.
          'output': p.absolute(output),
          'settleTimeout': timeout,
        }),
      },
    ).run(forceBuild: forceBuild, release: true);
  }

  /// What this project has, for the terminal the GUI is running in.
  ///
  /// The banner `main.dart` used to print itself, from the process that can
  /// actually answer it. The GUI had to hard-code the list — "Pub dependencies
  /// manager, Previews" — because a `runApp` has no session to ask; here it
  /// is read from the same reports `fw status` prints, so a project that
  /// declares something else says so.
  ///
  /// Labels only. This runs beside a window the user is already looking at, and
  /// the detail is one `fw status` away.
  Future<List<String>> _describeProject() async {
    var session = await openSession();
    try {
      if (session.reports.isEmpty) {
        return const [
          'No plugins declared in tool/flutterware.dart.',
          '`fw help init` to see what that file is for.',
        ];
      }
      return [
        'Tools declared in tool/flutterware.dart:',
        for (var report in session.reports) '  · ${report.label}',
        '',
        '`fw status` for what each one says · `fw actions` for what they do.',
      ];
    } finally {
      session.dispose();
    }
  }

  /// Everything every plugin says about itself.
  ///
  /// Computes first. Reading a report never starts work — that rule protects
  /// the GUI, where a sidebar row reads one per frame — but a `fw` process has
  /// no such history: it opens a session, reads, and exits. Reporting only
  /// cached state here would print "not computed" for every package on every
  /// run, which is the config file read back rather than a status.
  Future<int> _status(List<String> arguments, {required bool json}) async {
    // The narrowing the MCP tool has had all along, on the command line: a
    // plugin name loads and reports that one, `--brief` drops the panel
    // projection. Anything unrecognised is refused — a flag accepted and
    // ignored reads as "the flag did nothing useful" rather than "the flag
    // does not exist", which is the more expensive misreading.
    var brief = arguments.remove('--brief');
    String? only;
    for (var argument in arguments) {
      if (argument.startsWith('-')) {
        return fail('unknown option "$argument". Try `fw help status`.');
      }
      if (only != null) {
        return fail(
          'status reports one plugin or all of them — got "$only" and '
          '"$argument".',
        );
      }
      only = argument;
    }

    var session = await openSession();
    try {
      List<PluginReport> reports;
      if (only != null) {
        PluginCore core;
        try {
          core = session.requireCore(only);
        } on SessionException catch (e) {
          return fail('$e');
        }
        await core.computeAll();
        reports = [core.report];
      } else {
        await computeAllCores(session.cores);
        reports = session.reports;
      }

      if (json) {
        _printJson({
          'root': session.root,
          'worktree': session.worktree.branch ?? session.worktree.path,
          // See the same line in the MCP server: notes are a shell feature, so
          // no plugin report would ever mention them.
          'review': reviewStatusJson(session.worktree.path),
          'plugins': [
            for (var report in reports) report.toJson(includeView: !brief),
          ],
        });
        return 0;
      }

      var waiting =
          reviewStatusJson(session.worktree.path)['unresolved']! as int;
      if (waiting > 0) {
        out.writeln(
          '$waiting review ${waiting == 1 ? 'note' : 'notes'} outstanding — '
          '`fw review`',
        );
        out.writeln();
      }

      if (session.cores.isEmpty) {
        out.writeln('No plugins declared in tool/flutterware.dart.');
        return 0;
      }
      for (var report in reports) {
        out.writeln(report.toText(includeView: !brief));
        out.writeln();
      }
      return 0;
    } finally {
      session.dispose();
    }
  }

  /// Every checkout of the repository, and what is going on in each.
  ///
  /// Opens no session, and deliberately. A session is per worktree and
  /// costs running that worktree's config; this command is about all of them,
  /// most of which are not open. The facts layer exists precisely so that a
  /// checkout nobody has opened still reports — see the explorer design, §1.
  Future<int> _worktrees({required bool json, bool refresh = false}) async {
    var root = findRepoRoot(Directory.current.path);
    if (root == null) {
      return fail('not inside a project: ${Directory.current.path}');
    }

    var worktrees = await WorktreeDiscovery().discover(root);

    // **The main checkout, not the one we are standing in.** Branch diffs are
    // repository-wide — a sha pair means the same thing from every worktree —
    // so a cache keyed by the current directory would be one copy per checkout,
    // each of them cold, each of them recomputing what its neighbour just did.
    // Discovery always reports the main checkout first.
    var repoRoot = worktrees.firstOrNull?.path ?? root;
    var store = WorktreeFactsStore.open(repoRoot);
    var facts = await WorktreeFactsProbe(
      repoRoot: repoRoot,
      store: store,
    ).probe(worktrees, refreshForge: refresh);

    // Most recently touched first, which is the same order the explorer opens
    // on and for the same reason: it answers "which one was I in".
    //
    // **By the age it prints, then by path** — the same total order the GUI
    // uses, and for a reason that shows up there rather than here: two rows
    // that read `now` must not trade places. Sharing the rule keeps two
    // renderings of one list from disagreeing about which worktree is second.
    var now = DateTime.now();
    var ordered = worktrees.toList()
      ..sort((a, b) {
        var byAge = activityAge(
          facts[a.path] ?? const WorktreeFacts(),
          now,
        ).compareTo(activityAge(facts[b.path] ?? const WorktreeFacts(), now));
        return byAge != 0 ? byAge : a.path.compareTo(b.path);
      });

    if (json) {
      _printJson({
        'root': root,
        'worktrees': [
          for (var worktree in ordered)
            {
              'name': worktree.name,
              'path': worktree.path,
              'branch': worktree.branch,
              'isMain': worktree.isMain,
              ...?facts[worktree.path]?.toJson(),
            },
        ],
      });
      return 0;
    }

    for (var line in worktreeTable([
      for (var worktree in ordered)
        (worktree, facts[worktree.path] ?? const WorktreeFacts()),
    ], now: DateTime.now())) {
      out.writeln(line);
    }
    return 0;
  }

  /// One worktree's delta, from the base branch to the files on disk.
  ///
  /// Opens no session: like `worktrees`, this is the facts layer's posture —
  /// git only, so a checkout nobody has opened answers as fully as this one.
  Future<int> _changes(List<String> rest, {required bool json}) async {
    var file = _optionValue(rest, '--file');
    var named = rest.where((a) => !a.startsWith('--')).firstOrNull;

    var probe = ChangesProbe();
    var directory = Directory.current.path;

    if (named != null) {
      var root = findRepoRoot(directory);
      if (root == null) {
        return fail('not inside a project: $directory');
      }
      var worktrees = await WorktreeDiscovery().discover(root);
      // Identity first, then branch — the same forgiving-input rule the
      // address uses, so a name that is one worktree's directory and another's
      // branch resolves to the directory.
      var found =
          worktrees.where((w) => w.name == named).firstOrNull ??
          worktrees.where((w) => w.branch == named).firstOrNull;
      if (found == null) {
        return fail(
          'no worktree "$named". Known: '
          '${worktrees.map((w) => w.name).join(', ')}',
        );
      }
      directory = found.path;
    }

    var root = await probe.worktreeRoot(directory);
    if (root == null) {
      return fail('not inside a git repository: $directory');
    }

    // The same one reader the GUI uses: whatever last executed this worktree's
    // config wrote the rules, and `fw changes` opens no session to run it
    // again. A checkout nobody has opened ranks by the built-in defaults, and
    // says so rather than claiming otherwise.
    var config = await _changesConfigFor(root, directory);

    if (file != null) {
      // The configured base too, or `--file` would diff one file against a
      // different commit from the one every other line of this command used.
      var patch = await probe.patchFor(root, file, base: config.config?.base);
      if (patch == null || patch.isEmpty) {
        return fail('no changes to $file against the base.');
      }
      out.writeln(patch);
      return 0;
    }

    var changes = await probe.probe(
      root,
      config: config.config,
      configState: config.state,
    );
    if (json) {
      _printJson(changes.toJson());
      return 0;
    }
    for (var line in changesReport(changes)) {
      out.writeln(line);
    }
    return 0;
  }

  /// The notes left on a checkout, and answering them.
  ///
  /// Opens no session, for the same reason `changes` does not: the log is
  /// keyed by the worktree path and nothing in it needs the project's config
  /// run. A checkout whose plugins will not load still reports its notes, which
  /// matters — a note about a broken config is exactly the note you would leave.
  Future<int> _review(List<String> rest, {required bool json}) async {
    var words = rest.where((a) => !a.startsWith('--')).toList();
    var verb = switch (words.firstOrNull) {
      'resolve' => true,
      'unresolve' => false,
      _ => null,
    };

    var directory = Directory.current.path;
    var root = await ChangesProbe().worktreeRoot(directory);
    if (root == null) {
      return fail('not inside a git repository: $directory');
    }

    if (verb != null) {
      var id = words.elementAtOrNull(1);
      if (id == null) {
        return fail('which note? `fw review` lists them with their ids.');
      }
      var result = reviewResolveJson(
        root,
        id,
        message: _optionValue(rest, '--message'),
        resolve: verb,
      );
      if (result['error'] case String error) {
        if (json) {
          _printJson(result);
          return 1;
        }
        return fail(error);
      }
      if (json) {
        _printJson(result);
        return 0;
      }
      var left = result['unresolved']! as int;
      out.writeln(
        '${verb ? 'Resolved' : 'Reopened'} ${result['note']} — '
        '$left outstanding',
      );
      return 0;
    }

    var worktrees = await WorktreeDiscovery().discover(
      findRepoRoot(directory) ?? root,
    );
    var name =
        worktrees.where((w) => w.path == root).firstOrNull?.name ??
        p.basename(root);
    var result = reviewListJson(
      root,
      worktree: name,
      base: (await _changesConfigFor(root, directory)).config?.base,
      all: rest.contains('--all'),
    );
    if (json) {
      _printJson(result);
      return 0;
    }
    if (result['notes'] case String notes) {
      out.writeln(notes);
    } else {
      // Not a failure: an empty review is the normal state of a checkout, and
      // an exit code would make "nothing to do" indistinguishable from a log
      // that could not be read.
      out.writeln('No notes on this checkout.');
    }
    return 0;
  }

  /// The ranking rules for [worktreePath], out of the repository's cache.
  Future<ResolvedChangesConfig> _changesConfigFor(
    String worktreePath,
    String directory,
  ) async {
    var project = findRepoRoot(directory);
    if (project == null) return ResolvedChangesConfig.defaults;
    var worktrees = await WorktreeDiscovery().discover(project);
    // Main first, matching how the explorer keys the same file.
    var main = worktrees.firstOrNull?.path ?? project;
    return resolveChangesConfig(worktreePath, WorktreeFactsStore.open(main));
  }

  /// Reads `--name=value` out of the remaining arguments.
  static String? _optionValue(List<String> rest, String name) {
    for (var argument in rest) {
      if (argument.startsWith('$name=')) {
        return argument.substring(name.length + 1);
      }
    }
    return null;
  }

  /// What can be invoked, and what each action needs to be told.
  ///
  /// The same list the GUI draws buttons from and an agent reads — there is no
  /// second source for it.
  Future<int> _actions(List<String> arguments, {required bool json}) async {
    // The MCP tool's narrowing, spelled the way `fw run` already spells it:
    // `fw actions scenarios` for one plugin, `fw actions scenarios run` for
    // one action. Unknown options are refused rather than ignored.
    var positional = <String>[];
    for (var argument in arguments) {
      if (argument.startsWith('-')) {
        return fail('unknown option "$argument". Try `fw help actions`.');
      }
      positional.add(argument);
    }
    if (positional.length > 2) {
      return fail(
        'actions takes a plugin and optionally one of its actions — '
        'got ${positional.length} arguments. Try `fw help actions`.',
      );
    }

    var session = await openSession();
    try {
      if (positional.isNotEmpty) {
        PluginCore core;
        try {
          core = session.requireCore(positional.first);
        } on SessionException catch (e) {
          return fail('$e');
        }
        var actions = core.report.actions;
        if (positional.length == 2) {
          var declared = actions
              .where((action) => action.id == positional[1])
              .firstOrNull;
          if (declared == null) {
            return fail(
              'no action "${positional[1]}" on ${core.id}. It has: '
              '${actions.map((a) => a.id).join(', ')}.',
            );
          }
          actions = [declared];
        }
        if (json) {
          _printJson({
            'plugins': [
              {
                'id': core.report.id,
                'actions': [for (var a in actions) a.toJson()],
              },
            ],
          });
          return 0;
        }
        return positional.length == 2
            ? _describeAction(core, actions.single)
            : _describePlugin(core);
      }

      if (json) {
        _printJson({
          'plugins': [
            for (var report in session.reports)
              {
                'id': report.id,
                'actions': [for (var a in report.actions) a.toJson()],
              },
          ],
        });
        return 0;
      }
      for (var report in session.reports) {
        out.writeln(report.id);
        if (report.actions.isEmpty) {
          out.writeln('  (no actions)');
        }
        for (var action in report.actions) {
          var flags = [
            for (var p in action.parameters)
              p.required ? '--${p.id}=<${p.kind.name}>' : '[--${p.id}=…]',
          ].join(' ');
          out.writeln(
            '  ${action.id}${flags.isEmpty ? '' : ' $flags'}'
            '${action.description == null ? '' : '   ${action.description}'}',
          );
        }
        out.writeln();
      }
      return 0;
    } finally {
      session.dispose();
    }
  }

  /// `fw run <plugin> <action> [--param=value]`
  ///
  /// Arguments are keyed by `ActionParameter.id`, which is the same map the GUI
  /// builds from a form and an agent passes directly.
  Future<int> _run(List<String> arguments, {required bool json}) async {
    var wantsHelp = arguments.contains('--help') || arguments.contains('-h');
    var positional = arguments.where((a) => !a.startsWith('--')).toList();
    // Nothing named and nothing to describe: this is someone asking how.
    if (positional.isEmpty) return _help('run');

    var session = await openSession();
    try {
      PluginCore core;
      try {
        core = session.requireCore(positional.first);
      } on SessionException catch (e) {
        // Naming a plugin that does not exist is a usage error, not a failed
        // run — nothing ran, so it exits like a bad command line.
        return fail('$e');
      }

      // `fw run <plugin>` is a question, not a mistake. Answering it with the
      // plugin's own actions beats repeating a usage line already read.
      if (positional.length < 2) return _describePlugin(core);

      var declared = core.report.actions
          .where((action) => action.id == positional[1])
          .firstOrNull;
      if (wantsHelp) {
        if (declared == null) {
          return fail(
            'no action "${positional[1]}" on ${core.id}. '
            'Try `fw run ${_short(core)}`.',
          );
        }
        return _describeAction(core, declared);
      }

      Job job;
      try {
        job = session.invoke(
          positional[0],
          positional[1],
          arguments: parseArguments(
            arguments,
            declared: declared?.parameters ?? const [],
          ),
        );
      } on SessionException catch (e) {
        return fail('$e');
      } on FormatException catch (e) {
        return fail(e.message);
      }

      var result = await job.done;
      if (!result.ok) return _failed(result);

      // An artifact prints as its path, so `fw run … | xargs open` works and a
      // shell script does not have to parse anything. Everything else it knows
      // — the address, the resolved axes — is a `--json` away rather than noise
      // on a line something is piping.
      //
      // The *value*, not `result.artifacts`: a result that merely carries one
      // (a run, with its failing frame) is still data, and printing that path
      // instead of the run would throw away the answer to keep the footnote.
      if (result.value case Artifact artifact) {
        if (json) {
          _printJson(artifact.toJson());
        } else {
          out.writeln(artifact.path ?? artifact.text);
        }
        return 0;
      }

      // Structured data prints as JSON whether or not `--json` was asked for.
      // A query returns whatever shape the plugin chose, and the framework
      // cannot invent a table for it; JSON is the one rendering that is always
      // honest and always pipes into `jq`. A plugin that wants prose has
      // `PluginView` for that.
      //
      // Switched on the type, not on `is Map || is List`: that test asked
      // "did somebody build a map" and went false the moment a core returned
      // something typed, quietly degrading the output to `toString()`.
      var value = result.value;
      if (value is PluginResult) {
        _printJson(value.toJson());
      } else if (value is Map || value is List) {
        // An action that has not adopted a result type yet. Still data, still
        // prints as data.
        _printJson(value);
      } else if (value != null) {
        out.writeln(json ? jsonEncode(value) : value);
      }
      // The action ran; what it ran did not pass. The data above is the answer
      // and still prints in full — this only decides what a shell sees, so
      // `fw run scenarios run && deploy` stops on a red suite.
      return value is ReportsFailure && !value.ok ? 1 : 0;
    } finally {
      session.dispose();
    }
  }

  /// Flags to the argument map an action is invoked with.
  ///
  /// `--flag=value` and `--flag value` both give the value; a bare `--flag` is
  /// `true`. Anything else is a string the plugin parses according to its
  /// declared `ActionParameterKind` — a shell has no types to pass, so this is
  /// where the CLI stops and the plugin's own contract starts.
  ///
  /// The separated form is the one everyone types, and it used to be
  /// dropped: `--entry demo/buttons.dart#buttons` set `entry` to `true` and
  /// left the value to be counted as a positional, which came back as
  /// `required (entry): true` — or, where the action cast it, as a type error
  /// with a stack trace. Found by typing it.
  ///
  /// [declared] is what keeps the greed in check: a parameter declared boolean
  /// never eats what follows it, so `--annotate --entry=x` still means two
  /// flags. A value that begins with `--` is a flag too, and so is the end of
  /// the line; both leave the bare flag as `true`, which the coercion then
  /// refuses for a parameter that needed a value.
  static Map<String, Object?> parseArguments(
    List<String> arguments, {
    List<ActionParameter> declared = const [],
  }) {
    var kinds = {for (var parameter in declared) parameter.id: parameter.kind};
    var repeatable = {
      for (var parameter in declared)
        if (parameter.repeatable) parameter.id,
    };
    var parsed = <String, Object?>{};
    // A flag given twice is both values, comma-joined, for a parameter that
    // reads a comma-separated list — `--file=a --file=b` is `--file=a,b`.
    // For any other it is refused: last-wins made the second silently
    // discard the first, and joining would hand `--output=a --output=b` to
    // the action as a directory called `a,b`.
    void put(String key, String value) {
      parsed[key] = switch (parsed[key]) {
        String earlier when repeatable.contains(key) => '$earlier,$value',
        String earlier => throw FormatException(
          '--$key given twice ("$earlier" and "$value") and it takes one '
          'value. Say it once.',
        ),
        _ => value,
      };
    }

    for (var i = 0; i < arguments.length; i++) {
      var argument = arguments[i];
      if (!argument.startsWith('--')) continue;
      var body = argument.substring(2);
      var equals = body.indexOf('=');
      if (equals >= 0) {
        put(body.substring(0, equals), body.substring(equals + 1));
        continue;
      }
      var next = i + 1 < arguments.length ? arguments[i + 1] : null;
      if (kinds[body] == ActionParameterKind.boolean ||
          next == null ||
          next.startsWith('--')) {
        parsed[body] = true;
        continue;
      }
      put(body, next);
      i++;
    }
    return parsed;
  }

  /// Reports a job that ran and came back with an error.
  ///
  /// A bad argument is the user's mistake and gets the usage exit code and no
  /// stack; anything else is ours, and dropping the stack there would make a
  /// plugin bug unreportable from the one surface that has a terminal to print
  /// it in.
  int _failed(JobResult result) {
    var error = result.error;
    if (error is ArgumentError) return fail(describeJobError(error));
    err.writeln('fw: ${describeJobError(error!)}');
    // A [ProjectFault] is not ours, so it gets no stack — see that type. It
    // still exits 1 rather than the usage code: the caller typed nothing
    // wrong, and their app really did fail.
    if (error is! ProjectFault) {
      if (result.stackTrace case var stackTrace?) err.writeln(stackTrace);
    }
    return 1;
  }

  /// The whole surface, or one command of it.
  ///
  /// Rendered from [fwCommands] rather than typed out, because the capability
  /// document renders the same list — and two copies of a command summary is
  /// how a document ends up describing a flag that no longer exists.
  int _version({required bool json}) {
    var report = FwVersion.of(Platform.environment);
    if (json) {
      out.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      report.lines.forEach(out.writeln);
    }
    return 0;
  }

  int _help([String? command]) {
    if (command != null) {
      var found = fwCommands.where((c) => c.name == command).firstOrNull;
      if (found == null) return fail('no command "$command". Try `fw help`.');
      out.writeln('fw ${found.usage}');
      out.writeln();
      out.writeln('  ${found.summary}');
      if (found.details case var details?) {
        out.writeln();
        out.writeln(details);
      }
      return 0;
    }

    out.writeln('fw — the CLI renderer of the flutterware plugin contract.');
    out.writeln();
    var width = fwCommands
        .map((c) => c.usage.length)
        .reduce((a, b) => a > b ? a : b);
    for (var entry in fwCommands) {
      out.writeln('  fw ${entry.usage.padRight(width)}  ${entry.summary}');
    }
    out.writeln();
    out.writeln(fwHelpFooter);
    return 0;
  }

  /// What one plugin can do — the answer to `fw run <plugin>`.
  int _describePlugin(PluginCore core) {
    var report = core.report;
    out.writeln('${report.label} — ${report.id}');
    out.writeln();
    if (report.actions.isEmpty) {
      out.writeln('  This plugin declares no actions.');
      return 0;
    }
    for (var action in report.actions) {
      out.writeln('  ${usageLine(_short(core), action)}');
      if (action.description case var description?) {
        out.writeln('      $description');
      }
    }
    out.writeln();
    out.writeln(
      'Run `fw run ${_short(core)} <action> --help` for what one takes and '
      'what it returns.',
    );
    return 0;
  }

  /// One action: what it takes, and what comes back.
  ///
  /// Every line is read from the declaration — the same parameters an agent
  /// gets over MCP, and the result shape extracted from the class the action
  /// returns. Nothing here is written a second time.
  int _describeAction(PluginCore core, PluginAction action) {
    out.writeln(usageLine(_short(core), action));
    out.writeln();
    if (action.description case var description?) {
      out.writeln('  $description');
      out.writeln();
    }

    if (action.parameters.isNotEmpty) {
      out.writeln('Parameters:');
      for (var parameter in action.parameters) {
        var flag = '--${parameter.id}=<${parameter.kind.name}>';
        var fallback = parameter.defaultValue;
        out.writeln(
          '  ${flag.padRight(28)}'
          '${parameter.required ? 'required' : 'optional'}'
          '${fallback == null ? '' : ', default $fallback'}',
        );
        var pad = ' ' * 30;
        if (parameter.description case var description?) {
          out.writeln('$pad$description');
        }
        if (parameter.optionsFrom case var from?) {
          out.writeln('${pad}values: `fw run ${_short(core)} $from`');
        } else if (parameter.options.isNotEmpty) {
          out.writeln(
            '${pad}values: '
            '${parameter.options.map((o) => o.value).take(6).join(', ')}'
            '${parameter.options.length > 6 ? ', …' : ''}',
          );
        }
      }
      out.writeln();
    }

    if (action.returnsName case var returns?) {
      if (resultShapes[returns] case var shape?) {
        out.writeln('Returns $returns:');
        out.write(shape.toText(indent: '  '));
        if (shape.gates) {
          out.writeln();
          out.writeln(gatingNote);
        }
      } else {
        out.writeln('Returns $returns.');
      }
    }
    return 0;
  }

  static String _short(PluginCore core) => core.id.split('.').last;

  /// How an action is spelled on a command line.
  ///
  /// Shared with the capability document, so the two cannot disagree about
  /// which parameters are optional.
  static String usageLine(String plugin, PluginAction action) =>
      'fw run $plugin ${action.id}'
      '${[for (var parameter in action.parameters) parameter.required ? ' --${parameter.id}=<${parameter.kind.name}>' : ' [--${parameter.id}=…]'].join()}';

  void _printJson(Object? value) =>
      out.writeln(const JsonEncoder.withIndent('  ').convert(value));

  /// `fw render bundle …` packages; `fw render <point> …` renders one.
  Future<int> _render(List<String> arguments, {required bool json}) async {
    // The subject is the first positional that is not the value of a
    // separated `-o <file>` — otherwise `fw render -o out.svg charts/monthly`
    // reads the output file as the point.
    String? subject;
    var rest = arguments.toList();
    for (var i = 0; i < rest.length; i++) {
      var argument = rest[i];
      if (argument == '-o' || argument == '--output') {
        i++;
        continue;
      }
      if (!argument.startsWith('-')) {
        subject = argument;
        rest.removeAt(i);
        break;
      }
    }
    return switch (subject) {
      'bundle' => await _renderBundle(rest, json: json),
      String point => await _renderPoint(point, rest, json: json),
      null => fail(
        'render takes a point (`fw render charts/monthly --as=svg '
        '--size=400x200`)\nor `fw render bundle`. Try `fw help render`.',
      ),
    };
  }

  Future<int> _renderPoint(
    String point,
    List<String> arguments, {
    required bool json,
  }) async {
    var target = 'lib/renders.dart';
    var format = 'svg';
    var argsJson = <String, Object?>{};
    RenderSize? size;
    String? output;
    var text = TextPolicy.embedFont;
    var unsupported = UnsupportedPolicy.rasterize;
    var pixelRatio = 3.0;
    for (var i = 0; i < arguments.length; i++) {
      var argument = arguments[i];
      if (argument.startsWith('--target=')) {
        target = argument.substring('--target='.length);
      } else if (argument.startsWith('--as=')) {
        format = argument.substring('--as='.length);
        if (!const {'svg', 'png', 'pdf'}.contains(format)) {
          return fail('--as takes svg, png or pdf.');
        }
      } else if (argument.startsWith('--args=')) {
        try {
          argsJson = parseRenderArgs(argument.substring('--args='.length));
        } catch (e) {
          return fail('$e');
        }
      } else if (argument.startsWith('--size=')) {
        var value = argument.substring('--size='.length).split('x');
        var width = value.length == 2 ? double.tryParse(value.first) : null;
        var height = value.length == 2 ? double.tryParse(value.last) : null;
        if (width == null || height == null) {
          return fail('--size takes <width>x<height>, as `--size=400x200`.');
        }
        size = RenderSize(width, height);
      } else if (argument == '-o' || argument == '--output') {
        if (++i >= arguments.length) return fail('$argument needs a file.');
        output = arguments[i];
      } else if (argument.startsWith('--output=')) {
        output = argument.substring('--output='.length);
      } else if (argument.startsWith('--text=')) {
        var value = argument.substring('--text='.length);
        var policy = TextPolicy.values
            .where((p) => p.name == value)
            .firstOrNull;
        if (policy == null) {
          return fail('--text takes vectorize, embedFont or systemFont.');
        }
        text = policy;
      } else if (argument.startsWith('--unsupported=')) {
        var value = argument.substring('--unsupported='.length);
        var policy = UnsupportedPolicy.values
            .where((p) => p.name == value)
            .firstOrNull;
        if (policy == null) {
          return fail('--unsupported takes rasterize, flatten or skip.');
        }
        unsupported = policy;
      } else if (argument.startsWith('--pixel-ratio=')) {
        var value = double.tryParse(
          argument.substring('--pixel-ratio='.length),
        );
        if (value == null || value <= 0) {
          return fail('--pixel-ratio takes a positive number, as `2`.');
        }
        pixelRatio = value;
      } else if (argument.startsWith('-')) {
        return fail('unknown option "$argument". Try `fw help render`.');
      } else {
        return fail('render takes one point, and got a second: "$argument".');
      }
    }
    var sdk = await FlutterSdkPath.findSdk();
    if (sdk == null) {
      return fail(
        'no Flutter SDK above this process.\n'
        'Run flutterware with the `dart` from a Flutter SDK, not a '
        'standalone one.',
      );
    }
    try {
      var result = await renderOneShot(
        packageRoot: Directory.current.path,
        target: target,
        point: point,
        format: format,
        args: argsJson,
        size: size,
        options: RenderOptions(text: text, unsupported: unsupported),
        pixelRatio: pixelRatio,
        output: output,
        cache: FlutterCache(p.join(sdk.root, 'bin', 'cache')),
        log: (line) => err.writeln('[render] $line'),
      );
      for (var warning in result.warnings) {
        err.writeln('[render] warning: $warning');
      }
      if (json) {
        out.writeln(
          jsonEncode({
            'output': result.outputPath,
            'warnings': [for (var w in result.warnings) w.toJson()],
          }),
        );
      } else {
        out.writeln(result.outputPath);
      }
      return 0;
    } on StateError catch (e) {
      return fail(e.message);
    } on RenderException catch (e) {
      err.writeln('fw: render failed: ${e.message}');
      if (e.remoteStack != null) err.writeln(e.remoteStack);
      return 1;
    }
  }

  Future<int> _renderBundle(
    List<String> arguments, {
    required bool json,
  }) async {
    var target = 'lib/renders.dart';
    var output = 'build/render-bundle';
    String? platform;
    for (var argument in arguments) {
      if (argument.startsWith('--target=')) {
        target = argument.substring('--target='.length);
      } else if (argument.startsWith('--out=')) {
        output = argument.substring('--out='.length);
      } else if (argument.startsWith('--platform=')) {
        platform = argument.substring('--platform='.length);
      } else if (argument.startsWith('-')) {
        return fail('unknown option "$argument". Try `fw help render`.');
      } else {
        return fail('render bundle takes no positional, got "$argument".');
      }
    }
    var sdk = await FlutterSdkPath.findSdk();
    if (sdk == null) {
      return fail(
        'no Flutter SDK above this process.\n'
        'Run flutterware with the `dart` from a Flutter SDK, not a '
        'standalone one.',
      );
    }
    try {
      var manifest = await buildRenderBundle(
        packageRoot: Directory.current.path,
        target: target,
        output: output,
        cache: FlutterCache(p.join(sdk.root, 'bin', 'cache')),
        platform: platform,
        log: (line) => err.writeln('[render] $line'),
      );
      if (json) {
        out.writeln(jsonEncode(manifest.toJson()));
      } else {
        out.writeln(
          'render bundle written to $output '
          '(${manifest.platform}, engine ${manifest.engineVersion}, '
          '${manifest.fonts.length} font file(s))',
        );
      }
      return 0;
    } on StateError catch (e) {
      return fail(e.message);
    }
  }

  int fail(String message) {
    err.writeln('fw: $message');
    return usageExit;
  }

  /// `EX_USAGE`. What a bad command line exits with, as opposed to an action
  /// that ran and failed.
  static const usageExit = 64;
}
