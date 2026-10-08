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
    summary: 'what every plugin reports about this project',
    details:
        'Loads every plugin, then prints what each one reports. Loading only\n'
        'reads files such as pubspecs and previews: nothing is compiled, no\n'
        'daemon starts and nothing goes to the network. `fw run` does that\n'
        'work.\n'
        '\n'
        'Name a plugin, by its full id or the part after its last dot, to\n'
        'load and report only that one. `--brief` keeps the status line and\n'
        'the per-package entries and leaves out the panel view, which is most\n'
        'of the output.',
  ),
  FwCommand(
    'worktrees',
    usage: 'worktrees [--refresh] [--json]',
    summary: 'every checkout of this repo, and what is going on in each',
    details:
        'Lists every checkout of this repository, like the Worktrees screen\n'
        'in the GUI. It runs no project code: it reads git, agent session\n'
        'files and `gh` or `glab`, so a worktree you have never opened shows\n'
        'as much as the one you are in.\n'
        '\n'
        'One `git for-each-ref` covers every branch and one `pr list` covers\n'
        'every pull request. A branch diff is cached under ~/.flutterware by\n'
        'its two commits. Pull requests are kept for five minutes;\n'
        '`--refresh` fetches them again.\n'
        '\n'
        'A column that is empty for every worktree is left out, for example\n'
        'when `gh` is not installed, no agent has run here, or the agent\n'
        'session files could not be read.',
  ),
  FwCommand(
    'changes',
    usage: 'changes [<worktree>] [--file=<path>] [--json]',
    summary: 'what a checkout has changed, important files first',
    details:
        'Lists the files a checkout has changed since its base branch, with\n'
        'the ones the project marks as important first. Committed, staged,\n'
        'unstaged and untracked changes are listed together, and each file\n'
        'shows whether it is committed.\n'
        '\n'
        'It runs no project code, so a worktree you have never opened shows\n'
        'as much as the one you are in. Name a worktree by its directory or\n'
        'branch; with no name it reads the checkout you are in.\n'
        '\n'
        "`--file=<path>` prints only that file's patch.\n"
        '\n'
        'The base is origin/HEAD, then main, then master. If none of them\n'
        'exists, it says so and shows only uncommitted work. Set another base\n'
        'with `ChangesConfig(base: …)` in tool/flutterware.dart.',
  ),
  FwCommand(
    'review',
    usage:
        'review [--all] [--json] | review resolve <id> [--message=<text>] '
        '| review unresolve <id>',
    summary: 'read and resolve the review notes on this checkout',
    details:
        'You write a note on a line of the diff in the GUI. The note keeps\n'
        'the code it was written about, so it still makes sense after the\n'
        'line moves.\n'
        '\n'
        'With no arguments, prints the open notes as markdown, each headed by\n'
        'the id you resolve it with. `--all` includes resolved notes.\n'
        '\n'
        '  fw review resolve <id> --message="did it, see foo_test.dart"\n'
        '\n'
        'A note resolved here is marked as resolved by the agent, and the GUI\n'
        'shows that beside the note. `unresolve` reopens a note.\n'
        '\n'
        'It reads git and a log under ~/.flutterware, and runs no project\n'
        'code.',
  ),
  FwCommand(
    'actions',
    usage: 'actions [<plugin> [<action>]] [--json]',
    summary: 'the actions you can run, and their parameters',
    details:
        'Lists the actions each plugin offers. The GUI and agents over MCP\n'
        'read the same list.\n'
        '\n'
        'Name a plugin to list only its actions. Name an action too to see it\n'
        'in full: its parameters and the shape of what it returns.',
  ),
  FwCommand(
    'run',
    usage: 'run <plugin> <action> [--k=v]',
    summary: 'run one action',
    details:
        '`<plugin>` is a full id or the part after its last dot.\n'
        '\n'
        '  fw run <plugin>                  the actions that plugin has\n'
        '  fw run <plugin> <action> --help  what it takes, and what it '
        'returns\n'
        '\n'
        'An action that produces a file prints its path, so\n'
        '`fw run … | xargs open` works. Other results print as JSON.\n'
        '`--json` prints the whole result, including its address and the\n'
        'axes it resolved.',
  ),
  FwCommand(
    'init',
    usage: 'init',
    summary: 'write the two files this project needs',
    details:
        'Writes a starter tool/flutterware.dart if the project has none, and\n'
        'adds a flutterware entry to .mcp.json so an agent that opens the\n'
        'repository finds the tools.\n'
        '\n'
        'Commit both files. Neither records anything about your machine or\n'
        'your SDK. .mcp.json is merged: other servers stay, and a flutterware\n'
        'entry you have edited is left as it is.\n'
        '\n'
        'It runs by itself the first time you use flutterware in a project,\n'
        'so you only need it in scripts and CI.',
  ),
  FwCommand(
    'app',
    usage: 'app [--release] [--json]',
    summary: 'open the flutterware GUI',
    details:
        'What `dart run flutterware` does with no arguments.\n'
        '\n'
        'The first run builds the GUI. The build output goes to\n'
        '`app/build/gui-build.log`. If the build fails, fw prints the end of\n'
        'the log and its path, and `--json` reports the same as data. `-v`\n'
        'shows the build output in the terminal as it runs.\n'
        '\n'
        'Everything the GUI does is also available from the other commands.\n'
        '\n'
        'When flutterware is a path dependency, as when you work on\n'
        'flutterware itself, the GUI runs under `flutter run`, so `r` reloads\n'
        'a change without a rebuild. `--release` runs the built binary\n'
        'instead, as a normal install always does.',
  ),
  FwCommand(
    'mcp',
    usage: 'mcp',
    summary: 'serve this project to an agent, over stdio',
    details:
        'Serves MCP on stdin and stdout, with the same plugins and actions as\n'
        'the commands above, so an agent can do what you can do here.\n'
        '\n'
        'You do not type this command: an MCP client starts it. Point the\n'
        'client at it like this:\n'
        '\n'
        '    {\n'
        '      "mcpServers": {\n'
        '        "flutterware": {\n'
        '          "command": "dart", "args": ["run", "flutterware", "mcp"]\n'
        '        }\n'
        '      }\n'
        '    }\n'
        '\n'
        '`fw init` writes that entry for you. The server uses whichever\n'
        '`dart` the client starts it with. If your project pins its SDK with\n'
        'a version manager, prefix the command, as in `fvm dart …`.\n'
        '\n'
        'stdout carries the protocol. Logs, and the output of anything the\n'
        'server has to build before it can answer, go to stderr.',
  ),
  FwCommand(
    'compare',
    usage:
        'compare [--base=<ref>] [--package=<path>] [--entry=<id>] '
        '[--export[=<dir>]] [--frames=all|changed] [--base-href=<path>] '
        '[--report=<dir>] [--jobs=<n>] [--json]',
    summary: "compare this worktree's previews and scenarios with its base",
    details:
        'Renders previews and replays scenarios on the base and on this\n'
        'worktree, then compares them: pixels, widget tree and visible text.\n'
        'There are no golden files to approve; both sides are computed from\n'
        'git when you run it. Entries the branch cannot have changed are\n'
        'skipped without rendering, so a branch that touched no preview\n'
        'finishes in milliseconds.\n'
        '\n'
        'The result is written to `index.json` (its path prints last) and\n'
        'shown on the Changes screen in the GUI.\n'
        '\n'
        'Exits 1 when the previews or the scenarios produced no result: the\n'
        'harness would not build or, on a run not narrowed with `--entry`,\n'
        'every row failed on both sides or every row failed on the base side.\n'
        'Differences do not change the exit code: a branch that changed\n'
        'pictures still exits 0, and so does a run narrowed with `--entry` to\n'
        'a flow that was already broken. To fail a job on differences, read\n'
        '`index.json`.\n'
        '\n'
        '`--base` compares against any ref git can name. The default is the\n'
        "project's configured base, then the default branch. `--entry` limits\n"
        'the run to the named entries and can be repeated.\n'
        '\n'
        'Every package either side declares is compared, and the results go\n'
        'into one `index.json`, one comment and one page. `--package` limits\n'
        'the run and can be repeated. When a run covers more than one\n'
        "package, a row's id starts with its package\n"
        '(`packages/gallery/demo/card.dart#card`), and every row has the\n'
        'package as a field either way. A package that does not compile has\n'
        'no rows and is named in the note; the other packages still report.\n'
        '\n'
        '`--export` writes the comparison as a page you can browse: a viewer,\n'
        'the `index.json` and a PNG per frame. Serve the directory over HTTP;\n'
        'opened as a `file://` page it cannot load its frames. The default\n'
        'directory is `build/comparison/web` at the top of the repository.\n'
        '\n'
        'The page loads everything relative to its own URL, so it works at a\n'
        'bucket root or under a per-pull-request prefix. Pass\n'
        '`--base-href=/comparisons/42/` only for a host that serves the\n'
        'directory without redirecting to a trailing slash.\n'
        '\n'
        '`--frames=changed` puts only the pictures of changed entries in the\n'
        'page. Every row is still listed with its state, but an unchanged\n'
        'entry shows no picture and says so. Unchanged frames are often most\n'
        'of the page: 18.1MB against 1.5MB of changed ones on one run.\n'
        '\n'
        '`--report` writes what a pull-request comment needs: `comment.md`, a\n'
        '`mosaic.png` of the changed entries, and the exported page under\n'
        '`web/`. The comment refers to images through the `__MOSAIC_URL__`\n'
        'and `__VIEWER_URL__` placeholders, which your workflow replaces once\n'
        'it has uploaded the files.\n'
        '\n'
        '`--jobs=<n>` renders and replays n at a time on each side, so up to\n'
        '2n `flutter_tester` processes run at once. Each side compiles its\n'
        'harness once and starts the others from it. The default, 1, runs one\n'
        'per side and the base before the head, which suits a CI runner sized\n'
        'for one build. A side that is replayed a second time, to check that\n'
        'the machine did not cause a difference, replays alone after the\n'
        'others. `index.json` records the value under `host`.\n'
        '\n'
        'The run ends with a line saying where the time went, and names the\n'
        'scenarios whose steps never settled. `index.json` has the same\n'
        'timings, per package and side, under `timings`.',
  ),
  FwCommand(
    'capture',
    usage:
        'capture [<address>] -o <file> [--size=WxH] [--theme=light|dark] '
        '[--pixel-ratio=N] [--timeout=<seconds>]',
    summary: 'screenshot the GUI window at an address',
    details:
        'Opens the GUI, goes to `<address>`, waits until nothing is still\n'
        'loading, writes a PNG and exits. No window stays open and nothing\n'
        'needs to be clicked, so a documentation script can call it.\n'
        '\n'
        'It captures the whole window: the rail, the tree, the tab bar with\n'
        'the branch name, and the panel. Use it when the subject is\n'
        'flutterware itself. To capture a preview on its own, at its own\n'
        'size, use\n'
        '\n'
        "    fw run previews screenshot --entry='<file.dart#symbol>'\n"
        '\n'
        'which renders without the GUI in about a second.\n'
        '`fw run previews entries` lists both the `id` that action takes and\n'
        'the `address` this command takes.\n'
        '\n'
        'Give `--size` and `--theme` for any picture you commit. Without them\n'
        "the picture has the window's size and the OS theme, so it changes\n"
        'from one machine to the next. `--size` is the layout size, not the\n'
        'window, and the display does not limit it: 1600x1200 works on a\n'
        'laptop that cannot show it. `--pixel-ratio` sets the density the\n'
        'same way: `2` gives the retina screenshots most READMEs want, on any\n'
        'screen.\n'
        '\n'
        'It always runs the built GUI, never `flutter run`, because it needs\n'
        'an exit code and nobody is at the keyboard. An existing build is not\n'
        'rebuilt, so if you are working on the GUI itself, pass\n'
        '`--force-compile` or you will capture the previous build.\n'
        '\n'
        'A panel can tell it is being captured (`CaptureMode.isCapturing`)\n'
        'and leave out what changes on every run. The previews panel hides\n'
        'its compile and reload timings, so a committed screenshot stays the\n'
        'same when you regenerate it.\n'
        '\n'
        'An address names the space, then the worktree, then the plugin, in\n'
        'full:\n'
        '`fw:///worktrees/<worktree>/flutterware.previews/<package>/<entry>`.\n'
        'The worktree is required; `~` is the main checkout. With no address\n'
        'it captures the home screen of the worktree you ran it in.\n'
        '\n'
        'It waits for every panel that reports itself busy, usually the first\n'
        'compile of the previews, and for the preview on screen to be the one\n'
        'that was asked for. `--timeout` limits the wait; when it runs out,\n'
        'the picture is still written, with a note of what was still running.\n'
        '\n'
        'Embedded views are included: a preview renders in its own process,\n'
        'so it is captured separately and drawn into the picture.',
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
        "render one of the app's render points to a file, or bundle them all "
        'for a server',
    details:
        'A render point is a widget or `pw.Document` that the app registers\n'
        'in a function marked `@RenderRegistry()` (`lib/renders.dart` by\n'
        'default, or `--target=`). Both forms compile that function and run\n'
        'it on flutter_tester, with no device and no GPU.\n'
        '\n'
        "`fw render charts/monthly --as=svg --size=400x200 --args='{...}'`\n"
        'renders one point to a file and prints the path. A widget point\n'
        'takes `--as=svg|png|pdf` and needs `--size`; a document point is\n'
        'always pdf. `--text` is vectorize, embedFont (the default) or\n'
        'systemFont; `--unsupported` is rasterize (the default), flatten or\n'
        'skip. Warnings, such as rasterized patches or dropped effects, go to\n'
        'stderr, and into the output under `--json`.\n'
        '\n'
        '`fw render bundle` builds the directory a Dart server copies into\n'
        'its image: flutter_tester, the compiled registry, the asset bundle\n'
        'with its fonts, and a manifest of the versions they need. Drive it\n'
        'with `RenderPool` from package:flutterware/render_client.dart.\n'
        '`--platform` builds for another platform, downloading the engine\n'
        "files from Flutter's own storage.",
  ),
  FwCommand(
    'version',
    usage: 'version [--json]',
    summary: 'the flutterware version, and where it is installed',
    details:
        'Also `fw --version`. Works in any directory, including one\n'
        'flutterware has not been set up in. Prints the version of the\n'
        'flutterware package your project resolved, and where it runs from:\n'
        'your checkout for a path dependency, or a copy under ~/.flutterware\n'
        'for a hosted one.',
  ),
  FwCommand(
    'help',
    usage: 'help [<command>]',
    summary: 'this list, or one command in detail',
  ),
];

/// Closes `fw help`, and the document's CLI section.
const fwHelpFooter =
    '`-v` on any command shows the output of whatever it builds, instead of\n'
    'writing it to a log.\n'
    '\n'
    'Run `fw help <command>` for details, or `fw actions` for what this '
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
        'fw mcp: no Flutter SDK above the dart running flutterware. Every '
        'tool call will fail with this until fw is started with the dart from '
        'a Flutter SDK.',
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
        'Run this from a Flutter project, one with a pubspec.yaml.',
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
        'start the GUI through the launcher, which knows which SDK and '
        'which\ncopy to use:\n\n    dart run flutterware',
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
        'start capture through the launcher, which knows which SDK and '
        'which\ncopy to use:\n\n    dart run flutterware',
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
          'Run `fw help init` to see what that file is for.',
        ];
      }
      return [
        'Tools declared in tool/flutterware.dart:',
        for (var report in session.reports) '  · ${report.label}',
        '',
        'Run `fw status` to see what each one reports.',
        'Run `fw actions` to see what they can do.',
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
          'status takes one plugin name, and got two: "$only" and '
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
          '$waiting open review ${waiting == 1 ? 'note' : 'notes'}. Run '
          '`fw review` to read ${waiting == 1 ? 'it' : 'them'}.',
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
  /// checkout nobody has opened still reports.
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
        '${verb ? 'Resolved' : 'Reopened'} ${result['note']}. '
        '$left still open.',
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
        'actions takes a plugin and, optionally, one of its actions, and '
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
          // What the producer wants a person to know about the file — a
          // picture taken of an entry that complained while it rendered. On
          // stderr, so the line a pipe reads is still the path alone.
          if (artifact.meta['note'] case String note) err.writeln('fw: $note');
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
          '--$key given twice ("$earlier" and "$value"), but it takes one '
          'value.',
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

    out.writeln('fw: the flutterware command line.');
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
        return fail(
          'render bundle takes no other arguments, and got "$argument".',
        );
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
