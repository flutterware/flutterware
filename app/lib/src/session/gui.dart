import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/build_output.dart';
// ignore: implementation_imports
import 'package:flutterware/src/desktop_gui.dart';
// ignore: implementation_imports
import 'package:flutterware/src/live_region.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';

/// Builds the desktop GUI and runs it.
///
/// Lifted out of the old `app/bin/flutterware.dart`, which was a second
/// `CommandRunner` living beside [FwCli] and reachable only through the
/// launcher. Two entry points meant `dart run flutterware` could start the GUI
/// and could not reach `status` — so the GUI became a command like any other,
/// and that file went away.
///
/// Pure Dart on purpose: this is linked into `bin/fw.dart`, which
/// `entry_point_purity_test.dart` fails if it ever reaches `package:flutter`.
/// Starting the GUI is `Process.start`; nothing here needs a widget.
class GuiLauncher {
  GuiLauncher({
    required String appToolPath,
    required String flutterSdk,
    required this.projectDirectory,
    required this.out,
    required this.err,
    this.editableSources = false,
    this.json = false,
    this.verbose = false,
    bool? interactive,
    this.alreadyBuilt,
    this.describeProject,
    this.extraEnvironment = const {},
  }) : gui = DesktopGui(appPath: appToolPath, flutterSdk: flutterSdk),
       interactive = interactive ?? outputIsInteractive;

  /// Anything else the GUI process should be started with.
  ///
  /// `fw capture` is the only caller: the request it puts here is what turns an
  /// ordinary launch into a launch that navigates, photographs itself and
  /// exits. Deliberately additive rather than a second launcher — a capture
  /// run must come up through exactly the path a human's window does, or it is
  /// photographing something else.
  final Map<String, String> extraEnvironment;

  /// Where the GUI is built from and where the build puts it. Shared with the
  /// launcher, which starts the same build early so that it overlaps the CLI's.
  final DesktopGui gui;

  final Directory projectDirectory;
  final StringSink out;
  final StringSink err;

  /// True when `app/` is the checkout being edited rather than a copy.
  final bool editableSources;

  /// Report a failed build as JSON on [out] instead of prose on [err].
  ///
  /// A build failure is the one thing here an agent cannot act on from a tail
  /// of Xcode output, and `--json` is already how every other command answers.
  final bool json;

  /// Whether the terminal is being watched. See [outputIsInteractive].
  final bool interactive;

  /// `-v`: give the build the terminal instead of capturing it to a log.
  final bool verbose;

  /// The launcher's build result, when the launcher did the build.
  ///
  /// See [guiBuildResultEnvironmentKey]. Non-null means the question is
  /// settled either way and nothing here builds — including under
  /// `--force-compile`, which the launcher already honoured.
  final int? alreadyBuilt;

  /// What this project is, for the lines printed once the window is up.
  ///
  /// Injected rather than computed: it needs a `Session`, which means running
  /// the project's config file, and the point of doing it here is that it
  /// happens *after* the GUI is spawned. Nothing a user is waiting for is
  /// behind it.
  ///
  /// This is the banner the GUI used to print itself, moved to the process that
  /// owns the terminal and knows the answer. Null when there is nothing to say
  /// — a test, or a non-interactive run.
  final Future<List<String>> Function()? describeProject;

  String get appToolPath => gui.appPath;

  /// Runs the GUI, hot either way it can be.
  ///
  /// Two modes, and the difference is not cosmetic:
  ///
  /// - **Editable sources** — `flutter run`, so a change is a keypress rather
  ///   than a 38-second rebuild. It also means nothing here has to decide
  ///   whether the binary is stale: `flutter run` owns that, and it is right.
  /// - **A copy** — build once and spawn the binary. There is nothing to
  ///   reload, and a user should get a release build.
  Future<int> run({bool forceBuild = false, bool release = false}) async {
    if (editableSources && !release) return _runHot();

    if (alreadyBuilt case var exitCode?) {
      // No log under `-v`: the launcher gave that build the terminal and
      // captured nothing, so whatever `gui.log` holds is from an earlier run.
      // Quoting it as this failure's evidence is worse than quoting nothing.
      if (exitCode != 0) {
        return _reportBuildFailure(
          ProcessLog(exitCode, verbose ? null : gui.log),
        );
      }
    } else if (!gui.binary.existsSync() || forceBuild) {
      var code = await _build();
      if (code != 0) return code;
    }

    return _runBuilt();
  }

  /// Spawns the built binary and keeps a region under it.
  ///
  /// The binary's stdio is **piped** rather than inherited, which reverses a
  /// decision worth naming rather than quietly overturning: `inheritStdio`
  /// replaced `RemoteLogServer`/`RemoteLogClient` because a websocket carrying
  /// logs between two adjacent processes was absurd. A pipe between those same
  /// two processes is not that — no server, no port, no protocol, and this is
  /// already the parent.
  ///
  /// What it buys is the bottom of the terminal: a place that says the GUI is
  /// up and how to stop it, and later where revealed addresses and job results
  /// arrive. The GUI's own output goes above it, as ordinary scrollback.
  ///
  /// Off a terminal, or under `-v`, none of this happens and the child gets the
  /// terminal exactly as before.
  Future<int> _runBuilt() async {
    if (!interactive || verbose) {
      var process = await Process.start(
        gui.binary.path,
        const [],
        environment: _guiEnvironment,
        workingDirectory: appToolPath,
        mode: ProcessStartMode.inheritStdio,
      );
      return process.exitCode;
    }

    var process = await Process.start(
      gui.binary.path,
      const [],
      environment: _guiEnvironment,
      workingDirectory: appToolPath,
    );

    var watch = Stopwatch()..start();
    var project = p.basename(projectDirectory.path);
    var region = LiveRegion(
      out: out,
      rows: () {
        var badge = Ansi.style('●', Ansi.ok);
        var title = Ansi.style('GUI running', Ansi.bold);
        var aside = Ansi.style(
          '· $project · up ${watch.elapsed.inSeconds}s',
          Ansi.dim,
        );
        return [
          '',
          '  $badge  $title  $aside',
          '  ${Ansi.style('q or ctrl-c to quit', Ansi.dim)}',
        ];
      },
    )..start();

    // Both streams, decoded leniently: a GUI that printed something
    // undecodable has still printed it, and a decoding error must not be what
    // takes the terminal down.
    var drained = Completer<void>();
    void finishDraining() {
      if (!drained.isCompleted) drained.complete();
    }

    var lines = StreamGroup.merge([process.stdout, process.stderr])
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .where((line) => !isEngineChatter(line))
        .listen(
          (line) => region.printAbove(['  $line']),
          onDone: finishDraining,
          onError: (_) => finishDraining(),
        );

    unawaited(_describe(region));

    var quit = _quitOn(process);
    try {
      var exitCode = await process.exitCode;
      // The pipes usually close with the process; the timeout is for the case
      // where a grandchild inherited them and is still holding one open.
      await drained.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      region.stop(
        closing: [
          '',
          '  ${Ansi.style('GUI closed after ${watch.elapsed.inSeconds}s.', Ansi.dim)}',
          '',
        ],
      );
      // Asking to quit is not a failure. Killing the GUI leaves it with
      // SIGTERM, which Dart reports as -15 and the shell sees as 241 — so
      // without this, `fw app && something` never runs `something` and every
      // ordinary quit looks like a crash.
      return quit.requested ? 0 : exitCode;
    } finally {
      await lines.cancel();
      quit.release();
    }
  }

  /// Says what this project is, above the region, once the window exists.
  ///
  /// Unawaited and swallowing everything it can go wrong with, because it is a
  /// courtesy: a project whose config file throws should still get a window and
  /// a working `q`, and find out why from `fw status`.
  Future<void> _describe(LiveRegion region) async {
    if (describeProject case var describe?) {
      try {
        var lines = await describe();
        if (lines.isNotEmpty) {
          region.printAbove([for (var line in lines) '  $line', '']);
        }
      } on Object {
        // Deliberately silent. See above.
      }
    }
  }

  /// Makes `q` quit, and gives the terminal back however this ends.
  ///
  /// Only safe because the built GUI wants no input at all — unlike
  /// `flutter run`, which owns an interactive console, which is why [_runHot]
  /// does none of this.
  ///
  /// Raw mode is why `ctrl-c` is handled here as a byte rather than as a
  /// signal: with the line discipline off, the terminal driver no longer turns
  /// `0x03` into SIGINT. The signal watches are for a `kill` that arrives from
  /// somewhere else, and they exist because the one unforgivable failure of
  /// this method is exiting without giving the echo back.
  _Quit _quitOn(Process process) {
    if (!stdin.hasTerminal) return _Quit(() {});
    var echo = stdin.echoMode;
    var line = stdin.lineMode;
    stdin
      ..echoMode = false
      ..lineMode = false;
    var restored = false;
    void restore() {
      if (restored) return;
      restored = true;
      try {
        stdin
          ..lineMode = line
          ..echoMode = echo;
      } on StdinException {
        // Nothing useful to do, and this runs on the way out: a terminal that
        // needs `stty sane` is bad, and an unhandled exception on top of it is
        // worse. The ordering below is what stops this happening at all.
      }
    }

    var quit = _Quit(() {});
    var keys = stdin.listen((bytes) {
      if (bytes.any((byte) => byte == 0x71 /* q */ || byte == 0x03 /* ^C */)) {
        quit.requested = true;
        process.kill();
      }
    }, onError: (_) {});
    var signals = [
      for (var signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((_) {
          quit.requested = true;
          restore();
          process.kill();
        }),
    ];

    // Restore *first*. Cancelling a subscription on `stdin` closes the
    // underlying descriptor, and setting the line mode afterwards then throws
    // `StdinException: Bad file descriptor` — which, being on the way out of
    // `_runBuilt`, surfaced as an unhandled exception right after the user
    // pressed `q`.
    return quit
      ..release = () {
        restore();
        unawaited(keys.cancel());
        for (var signal in signals) {
          unawaited(signal.cancel());
        }
      };
  }

  /// Hands the terminal to `flutter run`.
  ///
  /// [ProcessStartMode.inheritStdio] is the whole implementation of hot reload
  /// here: `flutter run` already has an interactive console — `r`, `R`, `q`,
  /// the DevTools URL — and giving it the terminal means every key works at
  /// full fidelity with nothing forwarding them. Two processes cannot both own
  /// stdin, and the one that swallowed the `r` would make reload silently do
  /// nothing — which is exactly why [_runBuilt]'s region is not used here.
  ///
  /// Nothing is built on top of this. When we need reload to be *requested*
  /// rather than typed — an agent asking "apply my edit, tell me when the
  /// frame is ready" — this becomes `--machine` and a daemon client, and the
  /// only thing thrown away is the mode argument.
  Future<int> _runHot() async {
    out.writeln(
      'Starting the GUI with hot reload. Press r to reload, q to '
      'quit.',
    );
    var process = await Process.start(
      gui.flutter,
      ['run', '-d', Platform.operatingSystem],
      environment: _guiEnvironment,
      workingDirectory: appToolPath,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  Map<String, String> get _guiEnvironment => {
    projectDefineKey: projectDirectory.absolute.path,
    appToolPathKey: appToolPath,
    flutterSdkDefineKey: gui.flutterSdk,
    ...extraEnvironment,
  };

  /// Builds the GUI, with the build's own output in a file rather than in the
  /// terminal.
  ///
  /// Normally the launcher has already done this, beside the CLI build. This
  /// remains for every other way in: `--force-compile`, a deleted binary, a
  /// `fw app` whose launcher predicted no GUI.
  /// Deliberately does **not** call `trimWorkingCopy`, though this is a copy's
  /// build like the launcher's.
  ///
  /// The launcher trims under `withBuildLock`, which is what stops it deleting
  /// intermediates from under another process's `flutter build` — two projects
  /// share a working copy whenever they resolve the same flutterware version.
  /// This build runs inside the CLI, after the launcher has released that lock,
  /// so a trim here would have no such protection. What it leaves behind is
  /// reclaimed by the next launcher pass instead, which costs a warm run
  /// microseconds and is the one place the lock is held.
  Future<int> _build() async {
    var result = await Step(
      'Building the flutterware GUI',
      out: out,
      // Under `-v` the build owns the terminal, so the step announces
      // itself on one line and stops drawing.
      interactive: interactive && !verbose,
      budget: const Duration(seconds: 30),
      note: 'first run only',
    ).run(() => gui.build(verbose: verbose), ok: (result) => result.ok);

    return result.ok ? 0 : _reportBuildFailure(result);
  }

  /// The one place a failed GUI build is described, whoever ran it.
  int _reportBuildFailure(ProcessLog result) {
    if (json) {
      out.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'error': 'gui_build_failed',
          'exitCode': result.exitCode,
          'log': result.file?.path,
          'tail': result.tail(),
        }),
      );
    } else {
      describeFailure(err, 'the GUI build failed.', result);
    }
    return result.exitCode;
  }
}

/// The terminal handed back, and whether the user is why the GUI stopped.
///
/// Two things rather than one because the exit code depends on the difference:
/// a GUI that crashed and a GUI that was asked to stop both end as a dead
/// process, and only this says which.
class _Quit {
  _Quit(this.release);

  void Function() release;
  var requested = false;
}

/// Whether a line is the Flutter engine talking to itself.
///
/// The engine logs as `[<LEVEL>:<source file>(<line>)] <message>`, and at
/// startup it says which rendering backend it picked — every launch, identical,
/// unactionable, and now the first thing a user reads under "ready".
///
/// Only `IMPORTANT`. That is the engine's *informational* level despite the
/// name; `ERROR` and `FATAL` use the same shape and are the reason this is a
/// named predicate with one level in it rather than a prefix match. A filter
/// that swallowed a real engine error would make the GUI undebuggable from the
/// only surface that shows its output.
///
/// Not applied under `-v` or off a terminal — those paths hand the child the
/// terminal and this function never runs.
bool isEngineChatter(String line) =>
    RegExp(r'^\[IMPORTANT:[^\]]*\.(mm|cc|h)\(\d+\)\]').hasMatch(line);

/// The two output streams as one, in order of arrival.
///
/// `package:async`'s `StreamGroup` would do, and is not a dependency of this
/// package. Six lines is cheaper than a dependency for the CLI's import
/// closure, which `entry_point_purity_test.dart` exists to keep small.
abstract final class StreamGroup {
  static Stream<List<int>> merge(List<Stream<List<int>>> streams) {
    var controller = StreamController<List<int>>();
    var open = streams.length;
    for (var stream in streams) {
      stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          if (--open == 0) controller.close();
        },
      );
    }
    return controller.stream;
  }
}
