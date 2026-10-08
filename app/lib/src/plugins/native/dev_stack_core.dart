import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../session/job.dart';
import '../../ui/age.dart';
import '../../utils/run_dir.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'dev_stack_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const devStackPluginId = 'flutterware.dev_stack';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    "The project's local dev stack — docker, the database, whatever the app "
    "talks to locally — read and driven by running the project's own commands.";

/// How much of a command's output to keep. Enough to see why something failed,
/// far short of a log viewer — the command's own terminal has the rest.
const _maxOutput = 8000;

/// The dev stack: docker, the database, whatever the app talks to locally.
///
/// It owns no process. Everything here runs one of the project's own
/// commands and reads what came back — [DevStack.probe] to find out the state,
/// `start` / `stop` to change it. That is the whole difference from a
/// supervisor, and it is what makes a stack brought up in a terminal
/// indistinguishable from one brought up by the button: there is nothing to be
/// the authority *about*.
///
/// Holds to the [PluginCore.computeAll] budget by reading a cache file and
/// nothing else. Probing is a subprocess, so it happens only when something is
/// watching ([watch]) or when a caller named the action.
class DevStackCore extends PluginCore {
  DevStackCore(super.host) {
    var config = host.config;
    var declaredProbe = config['probe'];
    _probe = declaredProbe is Map
        ? Probe.fromJson(declaredProbe.cast<String, Object?>())
        : null;
    _probeDeclared = declaredProbe != null;
    _start = StackRun.fromJson(config['start']);
    _stop = StackRun.fromJson(config['stop']);
    _relativeDirectory = config['workingDirectory'] as String?;
    _stopIsDestructive = config['stopIsDestructive'] == true;
    var poll = config['poll'];
    _poll = Duration(milliseconds: poll is int && poll > 0 ? poll : 10000);
    var commandTimeout = config['commandTimeout'];
    _commandTimeout = Duration(
      milliseconds: commandTimeout is int && commandTimeout > 0
          ? commandTimeout
          : const Duration(minutes: 10).inMilliseconds,
    );
    _commands = [
      for (var entry in (config['commands'] as List? ?? const []))
        if (entry is Map) ?StackCommand.fromJson(entry.cast<String, Object?>()),
    ];
  }

  /// Where the cache lives. A seam for tests, which point it at a temp dir
  /// rather than the developer's real run dir.
  @visibleForTesting
  static String Function() runDirProvider = flutterwareRunDir;

  /// Runs a command and hands back (exitCode, combined output).
  ///
  /// Per instance, not static, and not test-only. A static seam is one
  /// global that every core in the process shares — fine for a test that builds
  /// one at a time, wrong for anything that does not: the catalog draws five
  /// stacks on one screen, each scripted differently, and they would overwrite
  /// each other. The catalog is why this is not `@visibleForTesting`: a plugin
  /// whose whole subject is a docker project cannot be looked at in a repo that
  /// has none, so a preview scripts this and draws the shipping panel over it.
  Future<ProcessResult> Function(
    List<String> command, {
    String? workingDirectory,
  })
  runProcess = defaultRunProcess;

  Probe? _probe;

  /// Whether the config carried a `probe:` entry at all — even one whose
  /// shape [Probe.fromJson] could not read. The difference between "the
  /// project declared nothing" and "this build cannot read what it
  /// declared", which are different sentences with different fixes.
  late final bool _probeDeclared;

  StackRun? _start;
  StackRun? _stop;
  String? _relativeDirectory;
  late final bool _stopIsDestructive;
  late final Duration _poll;
  late final Duration _commandTimeout;
  late final List<StackCommand> _commands;

  StackReading _reading = const StackReading.unknown();
  var _loadedCache = false;
  var _watchers = 0;
  Timer? _timer;

  /// What is in flight, or null. Set while `start` / `stop` runs, which is what
  /// makes [StackState.starting] a state rather than a spinner: the probe
  /// cannot see a compose project that has not finished coming up, and asking
  /// it during a transition would report `down` at the exact moment the user is
  /// watching for `up`.
  String? _busy;

  /// When [_busy] was set.
  ///
  /// Here rather than in the widget because a transition outlives any one
  /// surface: navigating to the panel eight seconds into a bring-up must show
  /// eight seconds, not start counting again. The elapsed number is the only
  /// progress a delegated command can honestly report — nothing here knows what
  /// the project's script is doing, only how long it has been doing it.
  DateTime? _busySince;

  /// True while [refresh] has a probe out.
  ///
  /// Separate from [_busy], which is only for transitions the *user* started.
  /// This exists for the window capture: a panel photographed between mounting
  /// and its first probe returning shows "not checked yet" and is reported as a
  /// success, which is the mid-resolve screenshot `SettleSource` was written
  /// about.
  var _probing = false;

  /// The probe in flight, so a second caller joins it rather than starting one.
  Future<StackReading>? _inFlight;

  /// How long the last probe took, or null before the first one.
  Duration? _probeFor;

  /// The tail of the last command's output, for the panel.
  String _lastOutput = '';
  String? _lastCommand;

  /// How the last command ended, and how long it took.
  ///
  /// Both were already on [DevStackRunResult] and reached the CLI and an agent;
  /// the panel showed the output and nothing about it, so a command that
  /// printed a warning and exited 1 looked exactly like one that worked.
  int? _lastExitCode;
  Duration? _lastRunFor;

  /// The last reading, cache or probe.
  StackReading get reading => _reading;

  /// The declared commands, in declaration order.
  List<StackCommand> get commands => _commands;

  bool get canControl => _start != null || _stop != null;
  bool get stopIsDestructive => _stopIsDestructive;
  bool get canStart => _start != null;
  bool get canStop => _stop != null;
  String? get busy => _busy;

  /// How long the transition in flight has been running, or null.
  Duration? get busyFor =>
      _busySince == null ? null : DateTime.now().difference(_busySince!);

  /// True while a probe is out. Read by the block, which draws a reading it has
  /// not confirmed differently from one it has.
  bool get isProbing => _probing;

  /// True when the reading on hand is old enough that it should be presented as
  /// history rather than as the state.
  ///
  /// Two poll intervals, which a mounted surface can never reach — it polls
  /// every interval. So in practice this is the **cold open**: a cache written
  /// hours ago, read before the first probe of this session comes back. That
  /// case used to render as "not checked yet", which throws away a fact we are
  /// holding; it should say what we last saw and how long ago.
  bool get isStale {
    var at = _reading.at;
    if (at == null || !_reading.isKnown) return false;
    return DateTime.now().difference(at) > effectivePoll * 2;
  }

  /// What this is still working on, or null. Read by the capture settler.
  String? get busyWith => switch ((_busy, _probing)) {
    (var busy?, _) =>
      busy == 'start' ? 'bringing the stack up' : 'tearing the stack down',
    (_, true) => 'checking the stack',
    _ => null,
  };
  String get lastOutput => _lastOutput;
  String? get lastCommand => _lastCommand;
  int? get lastExitCode => _lastExitCode;
  Duration? get lastRunFor => _lastRunFor;

  /// The interval as declared. [effectivePoll] is what actually runs.
  Duration get pollInterval => _poll;

  /// Overrides the derived probe ceiling. A seam for tests, which cannot wait
  /// out a 30-second floor to prove that a hung probe becomes an answer.
  @visibleForTesting
  Duration? probeTimeout;

  /// How long a probe may take before it is reported as failing.
  ///
  /// Derived from the declared interval rather than a constant: a project that
  /// says "check every two minutes" is describing something slow, and a fixed
  /// 30s ceiling would call its probe broken. Floored so a fast declaration
  /// cannot make the ceiling absurdly tight.
  Duration get _probeTimeout {
    if (probeTimeout case var override?) return override;
    var derived = _poll * 3;
    return derived < const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : derived;
  }

  /// How often the probe actually runs — the declaration, or slower when the
  /// probe has proven expensive.
  ///
  /// The declaration is a floor, not a promise, because only the last probe
  /// knows what a probe costs. A `Probe.script` pays a `dart run` every time:
  /// 0.3s on a small workspace, 4.6s measured on a large one with native-asset
  /// build hooks. At the default 10s that second case is a permanently busy
  /// core, and the project's only recourse was to write a bigger number into
  /// `poll:` and explain it in a comment — a fact about the tool's cost model,
  /// in a file where every other line is a fact about the project.
  ///
  /// Four times the last duration, so a probe never occupies more than a
  /// quarter of its own interval. A fast probe never reaches the multiplier and
  /// the declaration stands unchanged, which is the common case and must stay
  /// free.
  Duration get effectivePoll {
    var probeFor = _probeFor;
    if (probeFor == null) return _poll;
    var floor = probeFor * 4;
    return floor > _poll ? floor : _poll;
  }

  /// The probe as declared, joined — what the panel names when it explains
  /// where the state on screen came from.
  String? get declaredProbeCommand =>
      _probe == null ? null : describeRun(_probe!.run);

  /// What to actually spawn for [run].
  ///
  /// A [CommandRun] is its own answer. A [ScriptRun] becomes `<dart> <path>`
  /// with **the SDK flutterware is running under** — the one thing a config file
  /// cannot name, which is the whole reason the kind exists. Same resolution
  /// `RunCore` uses for a [ScriptSource], because two answers to "which dart"
  /// would be two behaviours for one word.
  ///
  /// `dart <path>`, not `dart run <path>`, which is what a person would type.
  /// `run` re-resolves the package graph and executes every build hook in it on
  /// every invocation — measured here at 0.33s against 0.28s for the direct
  /// form, and the gap is the hooks, so it grows with the project rather than
  /// staying constant. A probe pays it on every poll.
  ///
  /// It is the smaller half of the win, though, and worth not overstating: a
  /// consumer re-measured their own probe idle and got 0.70s for `dart run`
  /// against 0.58s direct. The 4.4s this line used to quote was `fvm dart` on a
  /// loaded machine — `fvm dart --version`, doing nothing at all, was 4.3–7.7s
  /// there. What took their probe from ~5s to 0.58s was resolving the SDK here
  /// and spawning it directly instead of going through a version manager, which
  /// is the same decision as [ScriptSource]'s and the reason a config file
  /// cannot name an interpreter.
  ///
  /// The price is that build hooks do *not* run, so a script whose imports need
  /// native assets built will not find them, and a stale `package_config.json`
  /// is an error here where `run` would have fixed it. Both are loud, and
  /// neither is a shape a stack-control script tends to have.
  ///
  /// The path is passed as declared, unresolved: it is relative to
  /// [workingDirectory], which is the directory the process is spawned in.
  List<String> _argvFor(StackRun run) => switch (run) {
    CommandRun(:var command) => command,
    ScriptRun(:var path, :var args) => [
      p.join(host.workspace.flutterSdk.root, 'bin', 'dart'),
      path,
      ...args,
    ],
  };

  /// Why [run] cannot be run, or null when it can.
  ///
  /// Only a script can be checked in advance, and it is worth checking: a
  /// missing file comes back from `dart run` as a page of compiler output, and
  /// the useful sentence — *there is no such file* — is one line of it. A
  /// command names an executable resolved by the OS, and guessing at that here
  /// would only be a second, worse PATH lookup.
  String? _problemWith(StackRun run) {
    if (run is! ScriptRun) return null;
    var file = File(p.join(workingDirectory, run.path));
    if (file.existsSync()) return null;
    return '${run.path} does not exist in $workingDirectory';
  }

  /// The `workingDirectory:` as declared, or null when commands run at the
  /// worktree root. Shown rather than the absolute path where the point is
  /// *whose* CLI is in charge rather than where it lives.
  String? get declaredDirectory => _relativeDirectory;

  /// Absolute, and the one place the declared relative path is resolved.
  String get workingDirectory => _relativeDirectory == null
      ? host.worktree.path
      : p.join(host.worktree.path, _relativeDirectory);

  @override
  Future<void> computeAll() async => _loadCache();

  /// Starts polling, and stops when the last watcher leaves.
  ///
  /// Reference-counted, unlike the other cores' `track()`. Those start work
  /// that runs until the worktree closes, which is right for a file watch that
  /// costs nothing to leave running. This spawns a subprocess every
  /// [pollInterval], so leaving it on for a worktree nobody is looking at would
  /// be a `docker compose ps` every ten seconds, forever, per open tab. Two
  /// surfaces watch — the panel and the worktree home — and either may be
  /// mounted without the other, which is what the count is for.
  void watch() {
    _watchers++;
    if (_watchers > 1 || isDisposed) return;
    _loadCache();
    unawaited(refresh());
    _rescheduleIfWatching();
  }

  /// Arms the next poll at [effectivePoll], replacing any timer already set.
  ///
  /// A one-shot re-armed after every probe rather than a `Timer.periodic`,
  /// because the interval is not known until the probe it follows has been
  /// timed. Called from [refresh]'s completion, so the clock starts when a probe
  /// *finishes* — with a periodic timer the gap between probes shrinks by
  /// however long each one took, which is the opposite of what a slow probe
  /// needs.
  void _rescheduleIfWatching() {
    _timer?.cancel();
    _timer = null;
    if (_watchers == 0 || isDisposed) return;
    _timer = Timer(effectivePoll, () => unawaited(refresh()));
  }

  /// The inverse of [watch]. Idempotent past zero, because a widget disposing
  /// twice must not turn polling off for the surface still showing.
  void unwatch() {
    if (_watchers == 0) return;
    _watchers--;
    if (_watchers > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  bool get isWatching => _watchers > 0;

  /// Runs the probe and adopts what it says. Does nothing while a transition is
  /// in flight — see [_busy].
  ///
  /// One probe at a time, and a second caller joins the first. The poll
  /// timer used to fire regardless of whether the last probe had come back, so
  /// a probe slower than the interval — which a `dart run` on a big workspace
  /// can be, measured at 4.6s where the default interval is 10s — left two
  /// subprocesses racing to write [_reading], and the panel showed whichever
  /// finished last. Joining rather than skipping is what keeps the `status`
  /// action honest: asked to go and look while a poll is out, it returns *that*
  /// look rather than the cache it was trying to refresh.
  Future<StackReading> refresh() {
    if (isDisposed || _busy != null) return Future.value(_reading);
    if (_inFlight case var inFlight?) return inFlight;
    var probe = _probe;
    if (probe == null) {
      // Not cached: the cache file is shared by every process on this
      // worktree, and this sentence is a fact about *this build's* reading
      // of the config, not a fact about the stack. Persisted, one process
      // that could not read the probe poisons the reading for all of them —
      // seen in the field as a status surface saying "No probe is declared"
      // 22 seconds after another process probed the same config fine.
      return Future.value(
        _adopt(
          StackReading(
            state: StackState.unavailable,
            at: DateTime.now(),
            failure: _probeDeclared
                ? 'The config declares a probe this version of flutterware '
                      'cannot read, perhaps one written for a newer version. '
                      'Run `dart run flutterware` again, or simplify the '
                      'declaration.'
                : 'No probe is declared, so flutterware cannot tell what '
                      'state this stack is in.',
          ),
          cache: false,
        ),
      );
    }
    _probing = true;
    var started = DateTime.now();
    var future = _probeOnce(probe).whenComplete(() {
      _probeFor = DateTime.now().difference(started);
      _probing = false;
      _inFlight = null;
      _rescheduleIfWatching();
    });
    return _inFlight = future;
  }

  Future<StackReading> _probeOnce(Probe probe) async {
    if (_problemWith(probe.run) case var problem?) {
      return _adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure: problem,
        ),
      );
    }
    var argv = _argvFor(probe.run);
    try {
      var result = await runProcess(
        argv,
        workingDirectory: workingDirectory,
      ).timeout(_probeTimeout);
      return _adopt(_read(probe, result));
    } on TimeoutException {
      // **A probe that never returns has to become an answer.** Before the
      // in-flight guard a hung one merely leaked a process per interval; with
      // it, the guard would hand every later caller the same dead future and
      // the panel would sit on one reading forever.
      return _adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure:
              'The probe did not answer within ${_probeTimeout.inSeconds}s: '
              '${describeRun(probe.run)}',
        ),
      );
    } on Object catch (e) {
      // A command that could not be spawned at all — a missing binary, a
      // working directory that is not there. That is the probe failing, not
      // the stack being down.
      return _adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure: '${argv.first}: $e',
        ),
      );
    }
  }

  /// Turns one probe run into a reading.
  StackReading _read(Probe probe, ProcessResult result) {
    var at = DateTime.now();
    var out = _combined(result);
    if (probe.shape == ProbeShape.json) {
      Object? decoded;
      try {
        // **stdout alone**, which is what [Probe.json] asks the command for.
        // Almost nothing that prints structured output has stderr to itself:
        // `dart` announces `Running build hooks...` there, docker writes
        // deprecation warnings, and a shell wrapper's `set -x` writes every
        // line it runs. Folding those in makes a probe that works for a
        // fortnight and then reports `unavailable` because a tool started
        // mentioning something.
        decoded = jsonDecode('${result.stdout}'.trim());
      } on FormatException catch (e) {
        // **The command's own words, when it left any.** A health check that
        // cannot reach the docker daemon says so on stderr and exits non-zero;
        // it does not print JSON about it. Reporting the parse error there
        // buries the one sentence that explains the problem under a complaint
        // about the format — the same reason the worktree remover prints git's
        // refusal rather than paraphrasing it.
        var said = _firstLine(out);
        return StackReading(
          state: StackState.unavailable,
          at: at,
          failure:
              said ??
              'The probe printed something that is not JSON: ${e.message}',
        );
      }
      if (decoded is! Map) {
        return StackReading(
          state: StackState.unavailable,
          at: at,
          failure: 'The probe printed JSON that is not an object.',
        );
      }
      var json = decoded.cast<String, Object?>();
      var read = StackReading.fromJson(json);
      return StackReading(
        state: read.state,
        at: at,
        detail: read.detail,
        services: read.services,
        // **`detail` is the reason when a probe reports `unavailable` without
        // a `failure`.** Two fields for one sentence is a distinction a script
        // author has no reason to make: they write one line explaining what is
        // wrong and put it where they put every other line. Insisting on the
        // other key here just loses the sentence and renders "the check could
        // not be run" over a probe that said exactly what was wrong.
        failure:
            read.failure ??
            (read.state == StackState.unavailable ? read.detail : null),
      );
    }
    // Exit code: zero is up, anything else is down. It cannot tell `down` from
    // `broken` — see [Probe.exitCode] — so it never reports `unavailable`, and
    // a project that needs that distinction moves to a JSON probe.
    return StackReading(
      state: result.exitCode == 0 ? StackState.up : StackState.down,
      at: at,
      detail: _lastLine(out),
    );
  }

  StackReading _adopt(StackReading reading, {bool cache = true}) {
    if (isDisposed) return reading;
    _reading = reading;
    if (cache) _writeCache(reading);
    notifyChanged();
    return reading;
  }

  /// Brings the stack up, then re-probes.
  Future<DevStackRunResult> start() => _transition(_start, 'start');

  /// Takes it down, then re-probes.
  Future<DevStackRunResult> stop() => _transition(_stop, 'stop');

  /// `async` so the refusal arrives through the future rather than out of the
  /// call. A method whose type says `Future` and which throws synchronously is
  /// one a caller can only guard by wrapping the call site as well as awaiting
  /// it.
  Future<DevStackRunResult> _transition(StackRun? run, String what) async {
    if (run == null) {
      throw ActionRefusal(
        'No `$what` is declared for this stack, so flutterware can only watch '
        'it. Add one to tool/flutterware.dart, or run it yourself.',
      );
    }
    if (_problemWith(run) case var problem?) throw ActionRefusal(problem);
    return _run(_argvFor(run), busy: what, thenProbe: true);
  }

  /// Runs one of the declared [commands].
  Future<DevStackRunResult> runCommand(String id, {String? argument}) {
    var command = _commands.where((c) => c.id == id).firstOrNull;
    if (command == null) {
      var declared = [for (var c in _commands) c.id];
      throw ArgumentError.value(
        id,
        'command',
        declared.isEmpty
            ? 'this stack declares no commands.'
            : 'no such command. Declared: ${declared.join(', ')}',
      );
    }
    if (_problemWith(command.run) case var problem?) {
      throw ActionRefusal(problem);
    }
    return _run(
      [
        ..._argvFor(command.run),
        if (command.argument != null && argument != null && argument.isNotEmpty)
          argument,
      ],
      busy: command.label,
      timeout: command.timeout,
    );
  }

  /// Runs [command], holding the stack while it does.
  ///
  /// The timeout is on the wait, and it exists because the wait is a claim.
  /// `_busy` is what makes the next `start` refuse, so a command that never
  /// returns did not merely fail — it took every later command with it, for the
  /// rest of the session, and the panel's controls with them. `logs --follow`
  /// declared as an ordinary command is exactly that, and it is the shape a
  /// consumer reported: they added `--no-follow` to their own CLI to avoid it,
  /// which a project whose `logs` is someone else's binary cannot.
  ///
  /// Nothing is killed when it expires. A `docker compose up` interrupted half
  /// way leaves a stack in a state nobody chose, and this plugin owns nothing —
  /// so the process is left running and said to be running, the claim is
  /// released, and the probe afterwards reports whatever it finds. That is also
  /// what [Probe]'s own timeout already does.
  Future<DevStackRunResult> _run(
    List<String> command, {
    required String busy,
    Duration? timeout,
    bool thenProbe = false,
  }) async {
    if (_busy != null) {
      throw ActionRefusal('"$_busy" is still running. Wait for it to finish.');
    }
    _busy = busy;
    _busySince = DateTime.now();
    _lastCommand = command.join(' ');
    _lastOutput = '';
    _lastExitCode = null;
    _lastRunFor = null;
    notifyChanged();
    var waited = timeout ?? _commandTimeout;
    ProcessResult result;
    try {
      result = await runProcess(
        command,
        workingDirectory: workingDirectory,
      ).timeout(waited);
    } on TimeoutException {
      _lastRunFor = busyFor;
      _busy = null;
      _busySince = null;
      _lastExitCode = null;
      _lastOutput =
          'Still running after ${waited.inSeconds}s. flutterware stopped '
          'waiting but has not stopped the command, so check on it yourself if '
          'it should have finished. For a command meant to keep running, set a '
          'shorter `timeout:` on its StackCommand.';
      notifyChanged();
      var reading = thenProbe ? await refresh() : null;
      return DevStackRunResult(
        command: _lastCommand!,
        // No exit code, because it has not exited. Zero would say it worked.
        exitCode: null,
        timedOut: true,
        stderr: _lastOutput,
        output: _lastOutput,
        reading: reading,
      );
    } on Object catch (e) {
      _lastRunFor = busyFor;
      _busy = null;
      _busySince = null;
      _lastOutput = '$e';
      notifyChanged();
      rethrow;
    }
    _lastOutput = _tail(_combined(result));
    _lastExitCode = result.exitCode;
    _lastRunFor = busyFor;
    _busy = null;
    _busySince = null;
    notifyChanged();
    // Probing *after* the flag clears, so [refresh] is not skipped by its own
    // transition guard.
    var reading = thenProbe ? await refresh() : null;
    return DevStackRunResult(
      command: _lastCommand!,
      exitCode: result.exitCode,
      stdout: _tail('${result.stdout}'),
      stderr: _tail('${result.stderr}'),
      output: _lastOutput,
      reading: reading,
    );
  }

  // ── cache ────────────────────────────────────────────────────────────────
  //
  // Kept so the sidebar and `fw status` say something true the moment a GUI
  // opens, without either of them spawning anything. A reading with an age is
  // the same bargain `RunCore` strikes with `devices.json`: the fact happened,
  // it gets old, it does not become wrong.
  //
  // `stack-*.json` is not swept by [sweepRunDir] — it matches none of its
  // rules — which is right for the same reason `devices.json` is spared: there
  // is one per worktree, it is tiny, and deleting it would only make a cold
  // read answer "nothing has ever looked" about a stack that had a state a
  // minute ago.

  String get _cachePath => stackCachePath(runDirProvider(), host.worktree.path);

  void _loadCache() {
    if (_loadedCache || _reading.isKnown) return;
    _loadedCache = true;
    try {
      var file = File(_cachePath);
      if (!file.existsSync()) return;
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return;
      _reading = StackReading.fromJson(json.cast<String, Object?>());
      notifyChanged();
    } on Object {
      // A cache that will not parse is a cache that was never written properly.
      // Nothing here is worth reporting: the next probe replaces it.
    }
  }

  void _writeCache(StackReading reading) {
    if (!reading.isKnown) return;
    try {
      File(_cachePath).writeAsStringSync(jsonEncode(reading.toJson()));
    } on Object {
      // Best effort. A read-only home directory costs freshness on the next
      // cold start, not correctness now.
    }
  }

  // ── report ───────────────────────────────────────────────────────────────

  @override
  PluginReport get report {
    var reading = _effectiveReading;
    return PluginReport(
      id: id,
      label: label,
      description: _pluginDescription,
      status: _statusFor(reading),
      badge: _badgeFor(reading),
      actions: _actions,
      teardown: _teardown(reading),
      view: _view(reading),
    );
  }

  /// The reading as a renderer should see it: a transition in flight wins over
  /// whatever the last probe said, because during those seconds the probe is
  /// the stale one.
  StackReading get _effectiveReading => switch (_busy) {
    'start' => StackReading(state: StackState.starting, at: _reading.at),
    'stop' => StackReading(state: StackState.stopping, at: _reading.at),
    _ => _reading,
  };

  /// A word, not a sentence. The sidebar clamps a status to 100 logical
  /// pixels, so anything longer than about a dozen characters arrives
  /// ellipsised — and an ellipsis always eats the *end*, which is where the
  /// information was. `up · localhost:8080 · pid 493` rendered as
  /// `up · local…`: eleven characters spent restating the one word that was
  /// never in doubt. The address has a home on the panel, where there is room
  /// for it.
  ///
  /// `up 3/4` is the one exception, and earns it by being shorter than `up`
  /// plus a space and by saying the thing you would otherwise have to open the
  /// panel to learn.
  Status _statusFor(StackReading reading) => switch (reading.state) {
    // Silent, not `not checked`: nothing has looked yet, and a row narrating
    // its own ignorance on every cold sidebar is noise. The block says
    // `checking` because the block is the surface that actually goes and
    // looks.
    StackState.unknown => Status.none,
    StackState.down => const Status.neutral('down'),
    StackState.starting => const Status.info('bringing up'),
    StackState.up when reading.isPartial => Status.warn(
      'up ${reading.serviceCount!.$1}/${reading.serviceCount!.$2}',
    ),
    StackState.up => const Status.good('up'),
    StackState.stopping => const Status.info('tearing down'),
    StackState.unavailable => const Status.error("can't tell"),
  };

  /// A badge only when something needs you.
  ///
  /// A stack that is up is the normal state and gets no dot: a tab lit green
  /// every day is a tab you stop reading. Down is not a badge either — a
  /// checkout you are not working in *should* have its stack down. What is left
  /// is the probe failing, which is the only one you cannot infer and cannot
  /// ignore.
  StatusBadge _badgeFor(StackReading reading) =>
      reading.state == StackState.unavailable
      ? const StatusBadge.dot(Tone.error)
      : StatusBadge.none;

  List<PluginAction> get _actions => [
    PluginAction(
      'status',
      'Check',
      returns: StackReading,
      description:
          'Runs the declared probe and reports what state the stack is in, '
          'with the time it was read. Every other surface shows a cached '
          'reading and how old it is; this is the one that goes and looks.',
    ),
    if (_start != null)
      PluginAction(
        'start',
        'Bring up',
        returns: DevStackRunResult,
        description:
            'Runs the declared start command and re-probes when it returns. '
            'Idempotent by contract — a stack that is already up should come '
            'back up as a no-op, which is what makes this safe to call when '
            'you only want to be sure.',
      ),
    if (_stop != null)
      PluginAction(
        'stop',
        'Tear down',
        returns: DevStackRunResult,
        danger: _stopIsDestructive,
        confirm: _stopIsDestructive,
        description: _stopIsDestructive
            ? 'Runs the declared stop command, which this project has marked '
                  'as destroying data — volumes go with it and the next '
                  'bring-up starts from empty.'
            : 'Runs the declared stop command and re-probes when it returns.',
      ),
    for (var command in _commands)
      PluginAction(
        command.id,
        command.label,
        returns: DevStackRunResult,
        danger: command.danger,
        confirm: command.danger,
        description:
            command.description ?? 'Runs `${describeRun(command.run)}`.',
        parameters: [
          if (command.argument case var argument?)
            ActionParameter(argument, argument, required: false),
        ],
      ),
  ];

  /// The stack's contribution to closing a worktree.
  ///
  /// Offered only when there is something to do: a stack that is already down,
  /// or one with no `stop` declared, has no step rather than a disabled one.
  /// The detail line is what makes the checkbox decidable — "4 containers"
  /// beats the bare label, and "destroys the database" is the difference
  /// between an informed tick and a regretted one.
  List<TeardownStep> _teardown(StackReading reading) {
    if (_stop == null) return const [];
    var isUp = reading.state == StackState.up || reading.state.isMoving;
    if (!isUp) return const [];
    var detail = [
      if (reading.detail case var d?)
        if (d.isNotEmpty) d,
      if (_stopIsDestructive) 'destroys the database',
    ].join(' · ');
    return [
      TeardownStep(
        'stop',
        'Tear down $label',
        detail: detail.isEmpty ? null : detail,
        checked: true,
        danger: _stopIsDestructive,
        phase: TeardownPhase.infra,
      ),
    ];
  }

  PluginView _view(StackReading reading) => PluginView([
    ViewField('State', reading.state.name),
    if (reading.detail case var detail?)
      if (detail.isNotEmpty) ViewField('Detail', detail),
    if (reading.failure case var failure?) ViewText(failure, tone: Tone.error),
    ViewField('Checked', stackAge(reading.at) ?? 'never'),
    // Reading the report never runs the probe — it takes seconds, and loading
    // spawns nothing — so only the studio's polling fills this in on its own.
    // `fw` and the MCP server would otherwise say `unknown` on a cold worktree
    // forever, with nothing in the answer to say how to get a better one.
    if (reading.state == StackState.unknown)
      ViewText(
        'Not checked yet. `fw run dev_stack status` runs the probe, and '
        'every surface shows its answer from then on.',
      ),
    ViewField('Working directory', workingDirectory),
    if (reading.services.isNotEmpty)
      ViewSection('Services', [
        ViewItems([
          for (var service in reading.services)
            ViewItem(
              service.name,
              detail: [
                if (service.port != null) ':${service.port}',
                if (service.state != null) service.state!.name,
              ].join(' · '),
              tone: service.state == StackState.up ? Tone.good : Tone.neutral,
            ),
        ]),
      ]),
  ]);

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async => switch (actionId) {
    'status' => await refresh(),
    'start' => await start(),
    'stop' => await stop(),
    _ =>
      _commands.any((c) => c.id == actionId)
          ? await runCommand(
              actionId,
              argument: _argumentFor(actionId, arguments),
            )
          : await super.invoke(actionId, arguments: arguments),
  };

  String? _argumentFor(String id, Map<String, Object?> arguments) {
    var command = _commands.firstWhere((c) => c.id == id);
    var name = command.argument;
    if (name == null) return null;
    var value = arguments[name];
    return value == null ? null : '$value';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _watchers = 0;
    super.dispose();
  }
}

/// [run] as a line to show a human — the panel's "where this came from", a
/// command's fallback description, the console's header.
///
/// A script is described as `dart …`, not with the absolute path to the SDK's
/// binary. The interpreter is 80 characters of `~/fvm/versions/…` that answer a
/// question nobody reading a panel is asking; what they want to know is which
/// script ran with which arguments. The absolute path is what gets *spawned*, and
/// that is a different question from what gets shown.
String describeRun(StackRun run) => switch (run) {
  CommandRun(:var command) => command.join(' '),
  ScriptRun(:var path, :var args) => ['dart', path, ...args].join(' '),
};

/// How long ago [at] was, in the shortest form that is still true.
///
/// Shared with the panel: a reading's age is part of what the reading *means*,
/// so the two surfaces must not word it differently.
String? stackAge(DateTime? at) => ageOf(at);

/// The real thing, and the value [DevStackCore.runProcess] is restored to.
Future<ProcessResult> defaultRunProcess(
  List<String> command, {
  String? workingDirectory,
}) => Process.run(
  command.first,
  command.skip(1).toList(),
  workingDirectory: workingDirectory,
);

String _combined(ProcessResult result) {
  var out = '${result.stdout}'.trimRight();
  var err = '${result.stderr}'.trimRight();
  if (out.isEmpty) return err;
  if (err.isEmpty) return out;
  return '$out\n$err';
}

/// A health check writes for a terminal, so its output is full of colour codes
/// that would otherwise land verbatim in a sidebar.
final _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

String? _lastLine(String text) {
  for (var line in const LineSplitter().convert(text).reversed) {
    var stripped = line.replaceAll(_ansi, '').trim();
    if (stripped.isNotEmpty) return stripped;
  }
  return null;
}

String? _firstLine(String? text) {
  if (text == null) return null;
  for (var line in const LineSplitter().convert(text)) {
    var stripped = line.replaceAll(_ansi, '').trim();
    if (stripped.isNotEmpty) return stripped;
  }
  return null;
}

String _tail(String text) {
  var stripped = text.replaceAll(_ansi, '');
  if (stripped.length <= _maxOutput) return stripped;
  return '…\n${stripped.substring(stripped.length - _maxOutput)}';
}

PluginCore devStackCoreFactory(PluginHost host) => DevStackCore(host);
