import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../run/define_scripts.dart';
import '../../session/caller.dart';
import '../../session/job.dart';
import '../../ui/age.dart';
import '../../utils/terminal_environment.dart';
import '../plugin_host.dart';
import 'dev_stack_results.dart';
import 'stack_history.dart';

/// How much of a command's output to keep. Enough to see why something failed,
/// far short of a log viewer — the command's own terminal has the rest.
const maxStackOutput = 8000;

/// One declared service's lifecycle — the machinery behind a single row of the
/// dev stack panel.
///
/// **Not a `PluginCore`.** One plugin holds several of these, so the things a
/// core owes its shell — the report, the action dispatch, the change stream —
/// belong to [DevStackCore], which assembles them from every service it holds.
/// What is here is the half that is genuinely per-service.
///
/// **Two kinds, one surface.** [DelegatedServiceCore] owns no process and asks
/// the project's own CLI everything; [OwnedServiceCore] holds a pid and a log.
/// Almost everything a renderer touches is here rather than in either of them,
/// which is what lets one block widget draw both — the panel does not ask which
/// kind a row is, and neither does the CLI.
///
/// The cache is the same story: this never touches the file. A worktree has one
/// cache for all its services, so a service that wrote its own would clobber
/// its neighbours; it announces a new reading through [onChanged] and the
/// container persists the lot.
abstract class StackServiceCore {
  StackServiceCore(this.host, this.declaration, {required this.onChanged});

  final PluginHost host;

  /// What `tool/flutterware.dart` declared for this service.
  final StackService declaration;

  /// Announces that [reading], [busy] or anything else a renderer draws has
  /// changed. The container turns this into a `notifyChanged` and a cache
  /// write.
  final void Function() onChanged;

  /// Stable within the plugin — what an action and a teardown step are keyed
  /// on, and the key this service's reading is cached under.
  String get id => declaration.id;

  /// What to call it on screen. The id when the declaration named nothing,
  /// because a row has to say which service it is even when nobody wrote a
  /// label.
  String get label => declaration.name ?? declaration.id;

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

  var _disposed = false;
  bool get isDisposed => _disposed;

  void notifyChanged() => onChanged();

  StackReading _reading = const StackReading.unknown();
  var _watchers = 0;
  Timer? _timer;

  /// What is in flight, or null. Set while `start` / `stop` runs, which is what
  /// makes [StackState.starting] a state rather than a spinner: nothing can see
  /// a service that has not finished coming up, and reading it during a
  /// transition would report `down` at the exact moment the user is watching
  /// for `up`.
  String? _busy;

  /// When [_busy] was set.
  ///
  /// Here rather than in the widget because a transition outlives any one
  /// surface: navigating to the panel eight seconds into a bring-up must show
  /// eight seconds, not start counting again.
  DateTime? _busySince;

  /// True while a state check is out.
  ///
  /// Separate from [_busy], which is only for transitions the *user* started.
  /// This exists for the window capture: a panel photographed between mounting
  /// and its first probe returning shows "not checked yet" and is reported as a
  /// success, which is the mid-resolve screenshot `SettleSource` was written
  /// about.
  @protected
  var probing = false;

  /// How long the last check took, or null before the first one. Only a
  /// delegated probe is expensive enough for this to matter — see
  /// [effectivePoll].
  @protected
  Duration? lastCheckFor;

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

  /// The last reading, cache or check.
  StackReading get reading => _reading;

  /// The declared commands, in declaration order.
  List<StackCommand> get commands => declaration.commands;

  /// Whether this service offers anything but a status.
  bool get canControl => canStart || canStop;

  /// Whether `start` is on offer. False for a service this machine only
  /// observes — a shared server, a system postgres — which is a complete
  /// declaration and gets a panel with a status and no controls.
  bool get canStart;

  /// Whether `stop` is on offer.
  bool get canStop;

  /// Whether `stop` destroys data. Renderers make the control distinct and ask
  /// first.
  bool get stopIsDestructive => false;

  String? get busy => _busy;

  /// How long the transition in flight has been running, or null.
  Duration? get busyFor =>
      _busySince == null ? null : DateTime.now().difference(_busySince!);

  /// True while a check is out. Read by the block, which draws a reading it has
  /// not confirmed differently from one it has.
  bool get isProbing => probing;

  /// True when the reading on hand is old enough that it should be presented as
  /// history rather than as the state.
  ///
  /// Two poll intervals, which a mounted surface can never reach — it polls
  /// every interval. So in practice this is the **cold open**: a cache written
  /// hours ago, read before the first check of this session comes back. That
  /// case used to render as "not checked yet", which throws away a fact we are
  /// holding; it should say what we last saw and how long ago.
  bool get isStale {
    var at = _reading.at;
    if (at == null || !_reading.isKnown) return false;
    return DateTime.now().difference(at) > effectivePoll * 2;
  }

  /// What this is still working on, or null. Read by the capture settler.
  String? get busyWith => switch ((_busy, probing)) {
    (var busy?, _) => busyDescription(busy),
    (_, true) => 'checking $label',
    _ => null,
  };

  /// One fragment naming a transition, for the settler and the rail.
  @protected
  String busyDescription(String busy) => switch (busy) {
    'start' => 'bringing $label up',
    'stop' => 'tearing $label down',
    _ => '$busy on $label',
  };

  String get lastOutput => _lastOutput;
  String? get lastCommand => _lastCommand;
  int? get lastExitCode => _lastExitCode;
  Duration? get lastRunFor => _lastRunFor;

  /// Replaces what the console shows without there having been a command —
  /// which is how an owned service's own log gets there.
  @protected
  void showOutput(String text) {
    if (_lastOutput == text) return;
    _lastOutput = text;
    notifyChanged();
  }

  /// The interval as declared. [effectivePoll] is what actually runs.
  Duration get pollInterval => declaration.poll;

  /// How often the state is actually read — the declaration, or slower when
  /// reading it has proven expensive.
  ///
  /// The declaration is a floor, not a promise, because only the last check
  /// knows what a check costs. A `Probe.script` pays a `dart run` every time:
  /// 0.3s on a small workspace, 4.6s measured on a large one with native-asset
  /// build hooks. At the default 10s that second case is a permanently busy
  /// core, and the project's only recourse was to write a bigger number into
  /// `poll:` and explain it in a comment — a fact about the tool's cost model,
  /// in a file where every other line is a fact about the project.
  ///
  /// Four times the last duration, so a check never occupies more than a
  /// quarter of its own interval. A fast one never reaches the multiplier and
  /// the declaration stands unchanged, which is the common case — every owned
  /// service, and every delegated one whose probe is a binary — and must stay
  /// free.
  Duration get effectivePoll {
    var checkFor = lastCheckFor;
    if (checkFor == null) return pollInterval;
    var floor = checkFor * 4;
    return floor > pollInterval ? floor : pollInterval;
  }

  /// Where the state on screen came from, as `label · value` fragments — the
  /// last thing anyone reads, and the first thing they need when the thing
  /// being reported on is the broken part.
  List<String> get provenance;

  /// What to actually spawn for [run].
  ///
  /// A [CommandRun] is its own answer. A [ScriptRun] becomes `<dart> run <path>`
  /// with **the SDK flutterware is running under** — the one thing a config file
  /// cannot name, which is the whole reason the kind exists. Same resolution
  /// `RunCore` uses for a [ScriptSource], because two answers to "which dart"
  /// would be two behaviours for one word.
  ///
  /// `run`, because it is what builds the package's native assets: a server
  /// that depends on a package with native code does not start without it.
  /// The price is that it resolves the package graph and checks every build
  /// hook each time — measured at about 0.3s on a small project, and growing
  /// with the project — which is nothing for a start or a button and too much
  /// for something polled. So a delegated service's status check, the one
  /// script that runs on a timer, is [polled] and runs as `dart <path>`:
  /// no hooks, and a stale `package_config.json` is an error there where `run`
  /// would have fixed it. Both are loud, and neither is a shape a status
  /// script tends to have.
  ///
  /// The path is passed as declared, unresolved: it is relative to
  /// [workingDirectory], which is the directory the process is spawned in.
  @protected
  List<String> argvFor(StackRun run, {bool polled = false}) => switch (run) {
    CommandRun(:var command) => command,
    // Unreachable through [argvOf], which resolves a tool before it gets here.
    // Present so the switch is exhaustive and a caller reaching for the sync
    // form gets a sentence rather than a crash.
    ToolRun(:var name) => throw StateError(
      '`$name` has to be looked up before it can be spawned — use argvOf.',
    ),
    ScriptRun(:var path, :var args) => [
      p.join(host.workspace.flutterSdk.root, 'bin', 'dart'),
      if (!polled) 'run',
      path,
      ...args,
    ],
  };

  /// [argvFor], with an executable this process has to go and find first.
  ///
  /// Async because a [ToolRun] is looked up on the terminal's PATH, and the
  /// first lookup in a session has to read it from a shell. Every other kind
  /// is already known, so this is a no-op for them and the extra `await` is
  /// free.
  ///
  /// Throws rather than falling back to the bare name. Spawning `uv` and
  /// hoping is how you get an `ENOENT` reported from inside a health check
  /// three states later; naming the executable here is the whole point of the
  /// kind.
  @protected
  Future<List<String>> argvOf(StackRun run, {bool polled = false}) async {
    if (run is! ToolRun) return argvFor(run, polled: polled);
    var found = await findTool(run.name);
    if (found == null) {
      throw ActionRefusal(
        '`${run.name}` is not on the PATH a new terminal window has, so '
        'nothing was run. Install it, or name its full path with '
        'StackRun.command.',
      );
    }
    return [found, ...run.args];
  }

  /// Where [name] lives on the terminal's PATH, or null.
  ///
  /// Cached for the process rather than per service: PATH is a property of the
  /// machine, and five services asking about `uv` is one question.
  @protected
  Future<String?> findTool(String name) => lookUpTool(name);

  /// Why [run] cannot be run, or null when it can.
  ///
  /// Only a script can be checked in advance, and it is worth checking: a
  /// missing file comes back from `dart run` as a page of compiler output, and
  /// the useful sentence — *there is no such file* — is one line of it. A
  /// command names an executable resolved by the OS, and guessing at that here
  /// would only be a second, worse PATH lookup.
  @protected
  String? problemWith(StackRun run) {
    if (run is! ScriptRun) return null;
    var file = File(p.join(workingDirectory, run.path));
    if (file.existsSync()) return null;
    return '${run.path} does not exist in $workingDirectory';
  }

  /// The `workingDirectory:` as declared, or null when commands run at the
  /// worktree root. Shown rather than the absolute path where the point is
  /// *whose* CLI is in charge rather than where it lives.
  String? get declaredDirectory => declaration.workingDirectory;

  /// Absolute, and the one place the declared relative path is resolved.
  String get workingDirectory => declaration.workingDirectory == null
      ? host.worktree.path
      : p.join(host.worktree.path, declaration.workingDirectory!);

  /// Adopts a reading the container read off the cache file, if nothing better
  /// is known yet.
  ///
  /// Silent — no [onChanged] — because the container is mid-load and will
  /// announce the whole set once. A reading already taken this session always
  /// wins: the cache is the *last* thing anyone saw, and this session has
  /// looked more recently than that by definition.
  void adoptCached(StackReading reading) {
    if (_reading.isKnown || !reading.isKnown) return;
    _reading = reading;
  }

  /// Takes [reading] as the state and announces it.
  @protected
  StackReading adopt(StackReading reading) {
    if (isDisposed) return reading;
    _reading = reading;
    notifyChanged();
    return reading;
  }

  /// Starts polling, and stops when the last watcher leaves.
  ///
  /// Reference-counted, unlike the other cores' `track()`. Those start work
  /// that runs until the worktree closes, which is right for a file watch that
  /// costs nothing to leave running. This can spawn a subprocess every
  /// [pollInterval], so leaving it on for a worktree nobody is looking at would
  /// be a `docker compose ps` every ten seconds, forever, per open tab. Two
  /// surfaces watch — the panel and the worktree home — and either may be
  /// mounted without the other, which is what the count is for.
  void watch() {
    _watchers++;
    if (_watchers > 1 || isDisposed) return;
    unawaited(refresh());
    rescheduleIfWatching();
  }

  /// Arms the next poll at [effectivePoll], replacing any timer already set.
  ///
  /// A one-shot re-armed after every check rather than a `Timer.periodic`,
  /// because the interval is not known until the check it follows has been
  /// timed. Called from [refresh]'s completion, so the clock starts when a check
  /// *finishes* — with a periodic timer the gap between checks shrinks by
  /// however long each one took, which is the opposite of what a slow one needs.
  @protected
  void rescheduleIfWatching() {
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

  /// Goes and reads what state this service is in, and adopts the answer.
  Future<StackReading> refresh();

  /// Brings it up, and writes down who asked and how it went.
  ///
  /// Every way of starting a service comes through here — the studio's
  /// button, an action from `fw` or an agent, `ensure`, a restart — so the
  /// history has each start exactly once.
  Future<DevStackRunResult> start() => _recorded('start', performStart);

  /// Takes it down, and writes down who asked and how it went.
  Future<DevStackRunResult> stop() => _recorded('stop', performStop);

  /// What [start] does for this kind.
  @protected
  Future<DevStackRunResult> performStart();

  /// What [stop] does for this kind.
  @protected
  Future<DevStackRunResult> performStop();

  /// Where starts and stops are written down. Set by the container; null
  /// writes nothing.
  StackHistoryStore? history;

  /// Writes [event] down, if anything is listening.
  @protected
  void recordEvent(StackEvent event) {
    history?.record(event);
    notifyChanged();
  }

  /// Runs [perform] — which claims the service before its first await, so the
  /// claim still lands in the caller's turn — and records the outcome.
  Future<DevStackRunResult> _recorded(
    String verb,
    Future<DevStackRunResult> Function() perform,
  ) async {
    var at = DateTime.now();
    StackEvent event({
      required StackEventOutcome outcome,
      String? detail,
      String? failure,
      String? command,
    }) => StackEvent(
      at: at,
      service: id,
      name: label,
      verb: verb,
      outcome: outcome,
      by: currentCaller.name,
      took: DateTime.now().difference(at),
      detail: detail,
      failure: failure,
      command: command,
    );
    DevStackRunResult result;
    try {
      result = await perform();
    } on Object catch (e) {
      // Refused because another start or stop holds the service: a second
      // press, not something that happened to it. Its own refusals release
      // the claim before they get here.
      if (busy == null) {
        recordEvent(
          event(
            outcome: StackEventOutcome.refused,
            failure: e is ActionRefusal ? e.message : '$e',
          ),
        );
      }
      rethrow;
    }
    var starting = verb == 'start';
    recordEvent(
      event(
        outcome: switch ((result.ok, result.nothingToDo)) {
          (true, true) =>
            starting
                ? StackEventOutcome.alreadyUp
                : StackEventOutcome.alreadyDown,
          (true, false) =>
            starting ? StackEventOutcome.up : StackEventOutcome.down,
          (false, _) => StackEventOutcome.failed,
        },
        detail: result.reading?.detail,
        failure: result.ok ? null : failureOf(result, verb),
        command: result.command,
      ),
    );
    return result;
  }

  /// The port it answers on, when flutterware knows it: an owned service
  /// with a port or HTTP readiness check, or a delegated one whose
  /// [Probe.json] reports it.
  int? get port => null;

  /// Where it answers: `http://localhost:<port>` for an owned service whose
  /// readiness check is an HTTP request, or what a delegated one's probe
  /// reports.
  String? get url => null;

  /// Claims the service for a transition, so the next one refuses rather than
  /// racing it.
  @protected
  void beginBusy(String what) {
    if (_busy != null) {
      throw ActionRefusal(
        '"$_busy" is still running on $label. Wait for it to finish.',
      );
    }
    _busy = what;
    _busySince = DateTime.now();
    notifyChanged();
  }

  /// Releases the claim and hands back how long it was held. Silent — the
  /// caller announces the outcome along with it.
  @protected
  Duration? endBusy() {
    var held = busyFor;
    _busy = null;
    _busySince = null;
    return held;
  }

  /// Records what a command did, for the console.
  @protected
  void recordRun({
    required String command,
    required String output,
    int? exitCode,
    Duration? ranFor,
  }) {
    _lastCommand = command;
    _lastOutput = output;
    _lastExitCode = exitCode;
    _lastRunFor = ranFor;
  }

  /// Runs one of the declared [commands].
  Future<DevStackRunResult> runCommand(String id, {String? argument}) {
    var command = commands.where((c) => c.id == id).firstOrNull;
    if (command == null) {
      var declared = [for (var c in commands) c.id];
      throw ArgumentError.value(
        id,
        'command',
        declared.isEmpty
            ? 'this service declares no commands.'
            : 'no such command. Declared: ${declared.join(', ')}',
      );
    }
    if (problemWith(command.run) case var problem?) {
      throw ActionRefusal(problem);
    }
    return _runCommand(command, argument);
  }

  /// Split out so [runCommand]'s refusals stay synchronous: a caller guarding
  /// an unknown id with a `try` around the call, rather than around the await,
  /// is guarding the shape this has always had.
  Future<DevStackRunResult> _runCommand(
    StackCommand command,
    String? argument,
  ) => runDeclared(
    argvOf(command.run).then(
      (argv) => [
        ...argv,
        if (command.argument != null && argument != null && argument.isNotEmpty)
          argument,
      ],
    ),
    busy: command.label,
    timeout: command.timeout,
  );

  /// Runs [command] to completion, holding the service while it does.
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
  /// way leaves a stack in a state nobody chose, and a delegated service owns
  /// nothing — so the process is left running and said to be running, the claim
  /// is released, and the next reading reports whatever it finds. That is also
  /// what [Probe]'s own timeout already does.
  ///
  /// [argv] may still be resolving — a [StackRun.tool] has to be looked up —
  /// and it is deliberately **not** awaited by the caller. The claim has to
  /// happen in the caller's own turn: an `await` before it opens a window in
  /// which a second `start` sees nothing in flight and spawns a second copy,
  /// which for a server is the one mistake that is not recoverable by
  /// pressing the button again.
  @protected
  Future<DevStackRunResult> runDeclared(
    FutureOr<List<String>> argv, {
    required String busy,
    Duration? timeout,
    bool thenProbe = false,
  }) async {
    beginBusy(busy);
    List<String> command;
    try {
      command = await argv;
    } on Object catch (e) {
      recordRun(command: '', output: '$e', ranFor: endBusy());
      notifyChanged();
      rethrow;
    }
    var line = command.join(' ');
    recordRun(command: line, output: '');
    notifyChanged();
    var waited = timeout ?? declaration.commandTimeout;
    ProcessResult result;
    try {
      result = await runProcess(
        command,
        workingDirectory: workingDirectory,
      ).timeout(waited);
    } on TimeoutException {
      var output =
          'Still running after ${waited.inSeconds}s. flutterware stopped '
          'waiting, but the command is still running. If it should have '
          'finished, check on it. For a command that keeps running, set a '
          'shorter `timeout:` on its StackCommand.';
      recordRun(command: line, output: output, ranFor: endBusy());
      notifyChanged();
      var reading = thenProbe ? await refresh() : null;
      return DevStackRunResult(
        command: line,
        // No exit code, because it has not exited. Zero would say it worked.
        exitCode: null,
        timedOut: true,
        stderr: output,
        output: output,
        reading: reading,
      );
    } on Object catch (e) {
      recordRun(command: line, output: '$e', ranFor: endBusy());
      notifyChanged();
      rethrow;
    }
    recordRun(
      command: line,
      output: tailOf(combinedOutput(result)),
      exitCode: result.exitCode,
      ranFor: endBusy(),
    );
    notifyChanged();
    // Reading *after* the flag clears, so [refresh] is not skipped by its own
    // transition guard.
    var reading = thenProbe ? await refresh() : null;
    return DevStackRunResult(
      command: line,
      exitCode: result.exitCode,
      stdout: tailOf('${result.stdout}'),
      stderr: tailOf('${result.stderr}'),
      output: lastOutput,
      reading: reading,
    );
  }

  // ── report ───────────────────────────────────────────────────────────────
  //
  // The pieces, not a `PluginReport`: one plugin holds several services and
  // there is only one report between them. [DevStackCore] assembles these.

  /// A word for the sidebar. See [statusFor].
  Status get status => statusFor(effectiveReading);

  StatusBadge get badge => badgeFor(effectiveReading);

  /// The reading as a renderer should see it: a transition in flight wins over
  /// whatever the last check said, because during those seconds the check is
  /// the stale one.
  StackReading get effectiveReading => switch (_busy) {
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
  @protected
  Status statusFor(StackReading reading) => switch (reading.state) {
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
  /// A service that is up is the normal state and gets no dot: a tab lit green
  /// every day is a tab you stop reading. Down is not a badge either — a
  /// checkout you are not working in *should* have its stack down. What is left
  /// is the check failing, which is the only one you cannot infer and cannot
  /// ignore.
  @protected
  StatusBadge badgeFor(StackReading reading) =>
      reading.state == StackState.unavailable
      ? const StatusBadge.dot(Tone.error)
      : StatusBadge.none;

  /// What this service can be told to do, with [prefix] on every id.
  ///
  /// **The service is in the id, not in an argument.** [prefix] is empty for a
  /// project that declares one service — so `fw run dev_stack start` still
  /// means what it always meant — and `<id>.` when there are several, giving
  /// `server.start` beside `stack.start`. A caller listing the actions sees
  /// every service it can address without a second lookup, which a single
  /// `start` taking a free-text `service` would not give it.
  ///
  /// It is also the only spelling that works. Both configs in evidence declare
  /// a `logs` command whose own `argument:` is called `service`; a selector by
  /// that name could not coexist with it.
  List<PluginAction> actions({String prefix = ''}) => [
    PluginAction(
      '${prefix}status',
      'Check',
      returns: StackReading,
      description: statusDescription,
    ),
    if (canStart)
      PluginAction(
        '${prefix}start',
        'Bring up',
        returns: DevStackRunResult,
        description: startDescription,
      ),
    if (canStop)
      PluginAction(
        '${prefix}stop',
        'Tear down',
        returns: DevStackRunResult,
        danger: stopIsDestructive,
        confirm: stopIsDestructive,
        description: stopDescription,
      ),
    ...extraActions(prefix),
    for (var command in commands)
      PluginAction(
        '$prefix${command.id}',
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

  /// Anything this kind offers that a declaration did not have to ask for.
  @protected
  List<PluginAction> extraActions(String prefix) => const [];

  @protected
  String get statusDescription;

  @protected
  String get startDescription;

  @protected
  String get stopDescription;

  /// The service's contribution to closing a worktree.
  ///
  /// Offered only when there is something to do: one that is already down, or
  /// one with no way to stop it, has no step rather than a disabled one. The
  /// detail line is what makes the checkbox decidable — "4 containers" beats
  /// the bare label, and "destroys the database" is the difference between an
  /// informed tick and a regretted one.
  List<TeardownStep> teardown({String prefix = ''}) {
    if (!canStop || !isTearableDown) return const [];
    var detail = [
      if (effectiveReading.detail case var d?)
        if (d.isNotEmpty) d,
      if (stopIsDestructive) 'destroys the database',
    ].join(' · ');
    return [
      TeardownStep(
        '${prefix}stop',
        'Tear down $label',
        detail: detail.isEmpty ? null : detail,
        checked: true,
        danger: stopIsDestructive,
        phase: TeardownPhase.infra,
      ),
    ];
  }

  /// Whether there is anything left running to take down.
  @protected
  bool get isTearableDown {
    var state = effectiveReading.state;
    return state == StackState.up || state.isMoving;
  }

  /// What this service says about itself, as projection rows.
  ///
  /// Rows rather than a whole [PluginView], because the container nests them
  /// under a section per service when there is more than one — and hands them
  /// back flat when there is one, so a project declaring a single stack sees
  /// exactly the projection it saw before.
  ///
  /// [prefix] is the one the actions carry, so a hint naming an action names
  /// the one that exists — `server.status` where there are several services.
  List<ViewNode> viewRows({String prefix = ''}) {
    var reading = effectiveReading;
    return [
      ViewField('State', reading.state.name),
      if (reading.detail case var detail?)
        if (detail.isNotEmpty) ViewField('Detail', detail),
      if (reading.failure case var failure?)
        ViewText(failure, tone: Tone.error),
      ViewField('Checked', stackAge(reading.at) ?? 'never'),
      // Reading the report never checks anything — a probe takes seconds, and
      // loading spawns nothing — so only the studio's polling fills this in on
      // its own. `fw` and the MCP server would otherwise say `unknown` on a
      // cold worktree forever, with nothing in the answer to say how to get a
      // better one.
      if (reading.state == StackState.unknown)
        ViewText(
          'Not checked yet. Run `fw run dev_stack ${prefix}status` to check '
          'it.',
        ),
      ViewField('Working directory', workingDirectory),
      ...extraViewRows(),
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
    ];
  }

  /// Rows only one kind has — a pid and an uptime mean nothing for a service
  /// nothing here owns.
  @protected
  List<ViewNode> extraViewRows() => const [];

  /// Runs one of this service's actions. [actionId] has had any prefix
  /// stripped by the container, so it is `status`, `start`, `stop` or a
  /// declared command's own id.
  ///
  /// Null for an id this service does not declare, which is what lets the
  /// container tell "no such action anywhere" from "not on this one".
  Future<Object?>? invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) {
    switch (actionId) {
      case 'status':
        return refresh();
      case 'start':
        return start();
      case 'stop':
        return stop();
    }
    if (extraInvoke(actionId, arguments) case var run?) return run;
    if (commands.any((c) => c.id == actionId)) {
      return runCommand(actionId, argument: _argumentFor(actionId, arguments));
    }
    return null;
  }

  /// The other half of [extraActions].
  @protected
  Future<Object?>? extraInvoke(
    String actionId,
    Map<String, Object?> arguments,
  ) => null;

  String? _argumentFor(String id, Map<String, Object?> arguments) {
    var command = commands.firstWhere((c) => c.id == id);
    var name = command.argument;
    if (name == null) return null;
    var value = arguments[name];
    return value == null ? null : '$value';
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _watchers = 0;
  }
}

/// [run] as a line to show a human — the panel's "where this came from", a
/// command's fallback description, the console's header. [polled] as for
/// [StackServiceCore.argvFor].
///
/// A script is described as `dart …`, not with the absolute path to the SDK's
/// binary. The interpreter is 80 characters of `~/fvm/versions/…` that answer a
/// question nobody reading a panel is asking; what they want to know is which
/// script ran with which arguments. The absolute path is what gets *spawned*, and
/// that is a different question from what gets shown.
String describeRun(StackRun run, {bool polled = false}) => switch (run) {
  CommandRun(:var command) => command.join(' '),
  ToolRun(:var name, :var args) => [name, ...args].join(' '),
  ScriptRun(:var path, :var args) => [
    'dart',
    if (!polled) 'run',
    path,
    ...args,
  ].join(' '),
};

/// Every tool this process has looked up, and what it found — null for one it
/// looked for and could not find, which is worth remembering too: a missing
/// executable does not appear halfway through a session.
final _tools = <String, String?>{};

/// Where [name] lives on the PATH a new terminal window has.
///
/// The same PATH the tool is then spawned with — see [terminalEnvironment] —
/// so what is found here is what runs. Resolved to an absolute path anyway,
/// so the command a reader sees names the executable that ran.
@visibleForTesting
Future<String?> lookUpTool(String name) async {
  if (_tools.containsKey(name)) return _tools[name];
  var environment = await terminalEnvironment();
  return _tools[name] = executableOnPath(name, environment['PATH'] ?? '');
}

/// Forgets what [lookUpTool] found. For tests, and for nothing else — a PATH
/// does not change under a running session.
@visibleForTesting
void debugResetToolLookups() => _tools.clear();

/// How long ago [at] was, in the shortest form that is still true.
///
/// Shared with the panel: a reading's age is part of what the reading *means*,
/// so the two surfaces must not word it differently.
String? stackAge(DateTime? at) => ageOf(at);

/// The real thing, and the value [StackServiceCore.runProcess] is restored to.
///
/// In the environment a new terminal window has, so a command that works when
/// typed works here, and a `dart run` in it finds its build hooks as the
/// terminal left them.
Future<ProcessResult> defaultRunProcess(
  List<String> command, {
  String? workingDirectory,
}) async => Process.run(
  command.first,
  command.skip(1).toList(),
  workingDirectory: workingDirectory,
  environment: await terminalEnvironmentToRun(command.first),
  includeParentEnvironment: false,
);

/// Why [result] — of a `start` or a `stop` — did not do what was asked, in one
/// sentence.
String failureOf(DevStackRunResult result, String verb) {
  if (result.reading?.failure case var failure?) return failure;
  if (result.timedOut) return result.stderr;
  if (result.exitCode case var code? when code != 0) {
    return 'Its $verb command exited with code $code.';
  }
  // An owned start or stop has no exit code, and says what went wrong here.
  if (result.exitCode == null && result.stderr.trim().isNotEmpty) {
    return result.stderr.trim();
  }
  var state = result.reading?.state.name;
  return state == null
      ? 'Its $verb did not finish.'
      : 'It is $state after its $verb.';
}

String combinedOutput(ProcessResult result) {
  var out = '${result.stdout}'.trimRight();
  var err = withoutDartChatter('${result.stderr}').trimRight();
  if (out.isEmpty) return err;
  if (err.isEmpty) return out;
  return '$out\n$err';
}

/// A health check writes for a terminal, so its output is full of colour codes
/// that would otherwise land verbatim in a sidebar.
final _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

String? lastLineOf(String text) {
  for (var line in const LineSplitter().convert(text).reversed) {
    var stripped = line.replaceAll(_ansi, '').trim();
    if (stripped.isNotEmpty) return stripped;
  }
  return null;
}

String? firstLineOf(String? text) {
  if (text == null) return null;
  for (var line in const LineSplitter().convert(text)) {
    var stripped = line.replaceAll(_ansi, '').trim();
    if (stripped.isNotEmpty) return stripped;
  }
  return null;
}

String tailOf(String text) {
  var stripped = text.replaceAll(_ansi, '');
  if (stripped.length <= maxStackOutput) return stripped;
  return '…\n${stripped.substring(stripped.length - maxStackOutput)}';
}
