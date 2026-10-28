import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../../run/define_scripts.dart';
import '../../session/job.dart';
import '../../utils/run_dir.dart';
import '../../utils/terminal_environment.dart';
import 'dev_stack_results.dart';
import 'service_handle.dart';
import 'stack_service_core.dart';

/// A process flutterware spawns and holds itself.
///
/// The dev stack began delegated-only, on the grounds that nothing needed
/// more. What changed is the evidence: a monorepo declaring seven local
/// services, of which the delegated kind covered one — the rest were servers,
/// workers and a Python backend that nobody stops except with Ctrl-C.
///
/// **Detached, and that is the whole design.** The process is not a child of
/// the GUI: closing the window leaves the server running, and reopening it
/// finds the same process rather than starting a second one. Everything
/// awkward here follows from that one choice — the handle file, the pid
/// checks, the group signal — and so does everything good about it, because
/// the alternative is a dev server that dies whenever you restart the tool
/// you are developing.
///
/// **It owns the log, so `logs` is free.** stdout and stderr are redirected to
/// a file under the run dir at spawn time. A delegated service has to declare a
/// `logs` command because the output belongs to whoever started the process;
/// here that is us.
class OwnedServiceCore extends StackServiceCore {
  OwnedServiceCore(
    super.host,
    OwnedStackService super.declaration, {
    required super.onChanged,
    required this.runDir,
  }) {
    // A port that is written down is known before anything happens, which is
    // what lets the orphan check and the readiness line work on a core nobody
    // has polled yet. A computed one waits for [_lookUpPort].
    _port = _declaredPort;
  }

  /// Where handles and logs live. A function rather than a string because the
  /// container's test seam is a function, and a core built once must not
  /// capture a directory a later test replaced.
  final String Function() runDir;

  @override
  OwnedStackService get declaration => super.declaration as OwnedStackService;

  /// The handle for the process we believe is running, or null.
  ServiceHandle? _handle;

  /// The reading in flight, so a second caller joins it rather than starting
  /// one — same bargain the delegated probe strikes, for the same reason.
  Future<StackReading>? _inFlight;

  /// Unique within this process, so two starts in one session cannot share a
  /// log file. The pid alone is not enough: the path is needed *before* the
  /// spawn, so it cannot carry the child's number.
  static var _logSequence = 0;

  /// Whether the console is showing the service's own log.
  ///
  /// One console, two things that want it: the log, which is continuous, and a
  /// declared command's output, which is a one-off answer to a button somebody
  /// just pressed. Last writer wins with the log as the resting state — a
  /// command holds the console until the next start, and everything else
  /// leaves the log there. Without the flag the poll would overwrite a
  /// command's output three seconds after it appeared, under a header still
  /// naming the command.
  var _showingLog = true;

  /// Always. There is a command to run and a pid to signal, which is what this
  /// kind is.
  @override
  bool get canStart => true;

  @override
  bool get canStop => true;

  @override
  List<String> get provenance => [
    'start · ${describeRun(declaration.start)}',
    'ready · $readyDescription',
  ];

  /// How readiness is decided, as a line to show a human.
  ///
  /// Names the *source* while the port is unknown, rather than a number it
  /// does not have. That is the honest reading before a start, and it is also
  /// the more useful one: what a reader wants at that point is which tool is
  /// going to be asked.
  String get readyDescription {
    var at = _address;
    return switch (declaration.ready) {
      ProcessAliveReady() => 'the process is alive',
      PortReady() =>
        at == null ? 'the port $_portSourceLabel gives accepts' : '$at accepts',
      HttpReady(:var path) =>
        at == null
            ? 'GET $path answers on the port $_portSourceLabel gives'
            : 'GET $at$path answers',
    };
  }

  // ── the port ─────────────────────────────────────────────────────────────
  //
  // Either written down or computed, and the computed case is the one a
  // monorepo actually has: every worktree gets its own slot, so a literal in a
  // committed file is right for one checkout and silently wrong for the rest.
  //
  // Asked **once per start**, before anything is spawned, and recorded in the
  // handle — so the socket poll after it is free, and a session that reopens
  // onto a running service reads the number that process was started against
  // rather than asking again and getting today's answer about yesterday's
  // process.

  /// The port readiness watches, once known. Null when this service watches no
  /// port, and null when the source has not answered.
  int? _port;

  /// Why there is no [_port], or null. Only ever set for a computed one.
  String? _portProblem;

  /// Whether the source has been asked at all this session.
  var _askedPort = false;

  /// The port as declared, or null when it is computed or absent.
  int? get _declaredPort => switch (declaration.ready) {
    PortReady(:var port) => port,
    HttpReady(:var port) => port,
    ProcessAliveReady() => null,
  };

  /// Where the port comes from, or null when it is written down or absent.
  ValueSource? get _portSource => switch (declaration.ready) {
    PortReady(:var from) => from,
    HttpReady(:var from) => from,
    ProcessAliveReady() => null,
  };

  String? get _address => _port == null ? null : 'localhost:$_port';

  @override
  int? get port => _port;

  @override
  String? get url => switch ((declaration.ready, _port)) {
    (HttpReady(), var port?) => 'http://localhost:$port',
    _ => null,
  };

  String get _portSourceLabel => switch (_portSource) {
    ScriptSource(:var path, :var args) =>
      '`${[p.basename(path), ...args].join(' ')}`',
    _ => 'the declared source',
  };

  String get _dart => p.join(host.workspace.flutterSdk.root, 'bin', 'dart');

  /// Works out the port, if it is not already known.
  ///
  /// [fresh] re-asks a source that has already answered. Only a start does
  /// that: it is the moment the number has to be right, and a slot can have
  /// been reallocated since the panel first looked.
  Future<void> _lookUpPort({bool fresh = false}) async {
    if (_declaredPort case var declared?) {
      _port = declared;
      _portProblem = null;
      return;
    }
    var source = _portSource;
    if (source == null) {
      _port = null;
      _portProblem = null;
      return;
    }
    // Not re-asked on every poll: a `dart run` every three seconds, to learn a
    // number that only changes when a stack comes up, is a subprocess spent on
    // nothing. Asked once, and again whenever a start needs it to be right.
    if (!fresh && _askedPort) return;
    _askedPort = true;
    var (value, problem) = await _oneValue(source, 'a port');
    if (problem != null) {
      _port = null;
      _portProblem = problem;
      return;
    }
    var port = int.tryParse(value!.trim());
    if (port == null || port <= 0) {
      _port = null;
      _portProblem =
          '$_portSourceLabel printed "$value", which is not a port number.';
      return;
    }
    _port = port;
    _portProblem = null;
  }

  /// Asks [source] for exactly one value.
  ///
  /// Returns `(value, null)` or `(null, why not)`. A list is a failure rather
  /// than a first-element guess: a script offering three answers has not
  /// computed the one this needs, and choosing for it is how a service ends up
  /// on a port nobody chose — the whole failure this indirection exists to
  /// prevent.
  Future<(String?, String?)> _oneValue(ValueSource source, String what) async {
    if (source is! ScriptSource) {
      return (
        null,
        'Only ValueSource.script can give $what here. Write a script in '
            'your project that prints it.',
      );
    }
    var outcome = await runDefineScript(
      source,
      dartExecutable: _dart,
      worktreePath: host.worktree.path,
    );
    if (outcome.failed) return (null, outcome.problem);
    if (outcome.value case var value?) return (value, null);
    return (
      null,
      '${source.path} printed ${outcome.options.length} values, and $what '
          'is one value. Make it print only one.',
    );
  }

  /// The environment to start with: the declared literals, plus whatever the
  /// sources answered. `(env, null)` or `(partial, why not)`.
  Future<(Map<String, String>, String?)> _resolveEnv() async {
    var env = {...declaration.env};
    for (var entry in declaration.envFrom.entries) {
      var (value, problem) = await _oneValue(
        entry.value,
        'an environment value',
      );
      if (problem != null) return (env, '${entry.key}: $problem');
      env[entry.key] = value!;
    }
    return (env, null);
  }

  /// The handle of a process that is genuinely there, or null.
  ///
  /// Read off disk rather than only from memory, because the ledger is shared:
  /// a second GUI, a `fw` in a terminal or this same GUI before it was
  /// restarted may have started it. Dead handles are deleted as they are found
  /// — a file claiming a port nothing holds is worse than no file, since the
  /// next start reads it and refuses.
  ServiceHandle? _liveHandle() {
    if (_handle case var known? when known.isAlive) return known;
    _handle = null;
    ServiceHandle? live;
    for (var handle in ServiceHandle.findAll(
      runDir(),
      host.worktree.path,
      id,
    )) {
      if (!handle.isAlive) {
        // Only the process that removes the handle writes the exit down, and
        // not when someone was stopping it: the stopper records that.
        if (handle.delete() && !handle.stopping) _recordExit(handle);
        continue;
      }
      // The newest wins, and a second live one keeps its file: it is holding
      // something, and deleting the only pointer to it is how an orphan is
      // made.
      live ??= handle;
    }
    return _handle = live;
  }

  /// A process that went away with nobody stopping it: crashed, killed from a
  /// terminal, or finished. Dated when it was noticed, which is as close as
  /// anything here can say.
  void _recordExit(ServiceHandle handle) => recordEvent(
    StackEvent(
      at: DateTime.now(),
      service: id,
      name: handle.name ?? label,
      verb: 'exit',
      outcome: StackEventOutcome.exited,
      detail:
          'pid ${handle.pid}, started ${stackAge(handle.startedAt) ?? 'just now'}',
      command: handle.command,
    ),
  );

  @override
  Future<StackReading> refresh() {
    if (isDisposed || busy != null) return Future.value(reading);
    if (_inFlight case var inFlight?) return inFlight;
    probing = true;
    var started = DateTime.now();
    var future = _look().whenComplete(() {
      lastCheckFor = DateTime.now().difference(started);
      probing = false;
      _inFlight = null;
      rescheduleIfWatching();
    });
    return _inFlight = future;
  }

  /// Two questions, in order: is it there, and is it usable.
  ///
  /// They are separate because the answers differ for tens of seconds at a
  /// time, and that gap is where a dev loop loses its afternoon — an app
  /// launched against a server three seconds from binding its port fails in a
  /// way that looks like a bug in the app.
  Future<StackReading> _look() async {
    var handle = _liveHandle();
    if (handle?.readyPort case var recorded?) {
      // **The number this process was started against**, not the one the tool
      // would answer with now. They differ exactly when it matters — a stack
      // torn down and brought back on a different slot — and polling the new
      // one would report a live service as silent.
      _port = recorded;
      _portProblem = null;
      _askedPort = true;
    } else {
      await _lookUpPort();
    }
    var at = DateTime.now();
    if (handle == null) {
      // **Down is not the only thing "we hold no pid" can mean.** The port may
      // be held by this very service started by hand, or by another worktree's
      // copy of it, and reporting `down` there sends someone to press Bring up
      // and read a refusal. Answering it here costs one connect to a local
      // port, which fails instantly when nothing is there.
      // **A port nobody can work out is not the same as a service that is
      // down.** In a monorepo it is the ordering problem stated up front: the
      // stack that allocates the slot has not been brought up, so there is
      // nothing to start against — and saying so here is what stops someone
      // pressing Bring up to find out.
      if (_portProblem case var problem?) {
        return adopt(
          StackReading(
            state: StackState.unavailable,
            at: at,
            detail: 'its port is not known',
            failure:
                'Its port could not be found, so it cannot be started or '
                'checked. $problem',
          ),
        );
      }
      if (_port case var port? when await _accepts(port)) {
        return adopt(
          StackReading(
            state: StackState.unavailable,
            at: at,
            detail: 'localhost:$port is taken',
            failure: switch (_otherCheckoutOn(port)) {
              var holder? =>
                '${_heldBy(holder, start: true)} is listening on '
                    'localhost:$port. ${_onePortTail(holder)}',
              null =>
                'Something flutterware did not start is listening on '
                    'localhost:$port. It may be this service started by hand. '
                    'Run `lsof -nP -iTCP:$port -sTCP:LISTEN` to find it.',
            },
          ),
        );
      }
      // **The console is not cleared.** What a service said on its way down is
      // the only account of why it went down, and blanking it the moment the
      // pid disappears is how a panel manages to show nothing at exactly the
      // moment someone is looking for the reason.
      return adopt(StackReading(state: StackState.down, at: at));
    }
    if (_showingLog) _showLog(handle);
    var ready = await _checkReady();
    if (ready.ok) {
      return adopt(
        StackReading(
          state: StackState.up,
          at: at,
          detail: [
            ?_address,
            'pid ${handle.pid}',
            'up ${_short(handle.uptime)}',
          ].join(' · '),
        ),
      );
    }
    var timeout = declaration.ready.timeout;
    if (timeout != null && handle.uptime < timeout) {
      return adopt(
        StackReading(
          state: StackState.starting,
          at: at,
          detail: 'pid ${handle.pid} · waiting for $readyDescription',
        ),
      );
    }
    // **Running and not answering is a state, not a spinner.** The process is
    // alive, so `down` would be false and `up` would be a lie of the same
    // family as a probe that exits 0 over an empty stack. Saying so is what
    // gets someone to read the log, which is directly below it on the panel.
    return adopt(
      StackReading(
        state: StackState.unavailable,
        at: at,
        detail: 'pid ${handle.pid} · up ${_short(handle.uptime)}',
        failure:
            'It has been running for ${_short(handle.uptime)}, but '
            '${ready.why}. Check its log. If the service works, its `ready:` '
            'in tool/flutterware.dart checks the wrong thing.',
      ),
    );
  }

  /// Puts the log in the console, naming the process it came from.
  ///
  /// The name comes off the **handle** rather than the declaration, because
  /// the two can disagree: a session that reopens onto a process started
  /// before the config was edited should say what is running, not what would
  /// be run now. It is also what makes the console work at all after a
  /// restart, where nothing in this process has run a command.
  void _showLog(ServiceHandle handle) {
    var log = _readLog(handle);
    if (lastCommand == null) {
      recordRun(command: handle.command, output: log);
      notifyChanged();
      return;
    }
    showOutput(log);
  }

  /// A declared command takes the console until the next start.
  @override
  Future<DevStackRunResult> runCommand(String id, {String? argument}) {
    _showingLog = false;
    return super.runCommand(id, argument: argument);
  }

  /// Never `can't tell`.
  ///
  /// For an owned service [StackState.unavailable] covers two things we know
  /// exactly, and they are opposite problems: our own process is alive and
  /// silent, or a process that is not ours has the port. "Can't tell"
  /// understates both, and one word each is what the sidebar has room for.
  @override
  Status statusFor(StackReading reading) {
    if (reading.state != StackState.unavailable) {
      return super.statusFor(reading);
    }
    if (_handle != null) return const Status.error('no answer');
    return _portProblem != null
        ? const Status.error('no port')
        : const Status.error('port taken');
  }

  /// A running-and-silent service is exactly what a teardown must offer to
  /// stop: it is the orphan, and the state where someone most wants the
  /// button. A port held by something we never started is not — there is no
  /// pid here to signal, and a step that could only report "nothing to stop"
  /// is a checkbox lying about what it will do.
  @override
  bool get isTearableDown =>
      super.isTearableDown ||
      (effectiveReading.state == StackState.unavailable && _handle != null);

  @override
  List<ViewNode> extraViewRows() => [
    // **What would be spawned, whether or not anything is.** The projection is
    // what `fw status` and an agent read, and without this a service that is
    // down says only that it is down — the one state where "what is this
    // thing" is the question being asked.
    ViewField('Starts', describeRun(declaration.start)),
    ViewField('Ready when', readyDescription),
    if (_handle case var handle?) ...[
      ViewField('Process', 'pid ${handle.pid}'),
      ViewField('Started', stackAge(handle.startedAt) ?? 'just now'),
      if (handle.logPath case var log?) ViewField('Log', log),
    ],
  ];

  /// True when the project declared a command of its own by this id, which
  /// wins. A built-in is a convenience; a declaration is a decision.
  bool _declares(String id) => commands.any((c) => c.id == id);

  @override
  List<PluginAction> extraActions(String prefix) => [
    if (!_declares('restart'))
      PluginAction(
        '${prefix}restart',
        'Restart',
        returns: DevStackRunResult,
        description:
            'Stops it and starts it again, for after you change what it runs. '
            'If the stop does not finish, it is not started again.',
      ),
    if (!_declares('logs'))
      PluginAction(
        '${prefix}logs',
        'Logs',
        returns: DevStackRunResult,
        description:
            'Shows the end of what it has printed since it was started.',
      ),
  ];

  /// Stops it and starts it again.
  ///
  /// One action rather than two calls, because the two-call version has a real
  /// failure it cannot see: if the stop leaves the process running — a tool
  /// stuck past SIGKILL — the start that follows *adopts* it and reports
  /// success, so the caller believes it is running new code and it is running
  /// the old. Here the stop's outcome decides whether the start happens at all.
  Future<DevStackRunResult> restart() async {
    var stopped = await stop();
    if (!stopped.ok) {
      return DevStackRunResult(
        command: stopped.command,
        exitCode: null,
        ok: false,
        output: stopped.output,
        stderr:
            'It was not started again, because the stop did not finish. The '
            'old process may still be running. Check its log, then stop it '
            'again.',
        reading: stopped.reading,
      );
    }
    return start();
  }

  @override
  Future<Object?>? extraInvoke(
    String actionId,
    Map<String, Object?> arguments,
  ) {
    if (actionId == 'restart' && !_declares('restart')) return restart();
    if (actionId != 'logs' || _declares('logs')) return null;
    var handle = _liveHandle() ?? _handle;
    var log = handle == null ? '' : _readLog(handle);
    // Asking for the logs is asking for the console back.
    _showingLog = true;
    if (handle != null) _showLog(handle);
    return Future.value(
      DevStackRunResult(
        command: handle?.logPath ?? 'no log',
        exitCode: null,
        ok: true,
        output: log.isEmpty
            ? 'Nothing has been logged yet. Either $label has not been '
                  'started, or it has printed nothing.'
            : log,
      ),
    );
  }

  // ── start ────────────────────────────────────────────────────────────────

  @override
  Future<DevStackRunResult> performStart() async {
    if (Platform.isWindows) {
      // The child has to outlive this process with its output going to a file,
      // and that is done here with a shell redirect this platform has no
      // equivalent of. Said plainly rather than failing somewhere less legible
      // — the same refusal `launch.dart` makes for the same reason.
      throw UnsupportedError(
        'flutterware can start $label itself only on macOS and Linux. On '
        'Windows, declare it with StackService.delegated and your own start '
        'and stop commands.',
      );
    }
    // **Claimed before the first await.** Everything below has to go and ask
    // something — the port's source, the shell, the port itself — and every
    // one of those is a window in which a second `start` sees nothing in
    // flight. Two copies of one server is the mistake this whole handle
    // mechanism exists to prevent, and it must not be reintroduced by the
    // resolution step. Released again on every path that does not spawn.
    beginBusy('start');
    try {
      return await _start();
    } on Object {
      if (busy != null) {
        endBusy();
        notifyChanged();
      }
      rethrow;
    }
  }

  Future<DevStackRunResult> _start() async {
    // **Adopt rather than duplicate.** The moment this would happen is a
    // second press of Bring up — from this window, from another one, or from a
    // session that restarted while the process kept running.
    if (_liveHandle() case var live?) {
      var reading = await refresh();
      var up = reading.state == StackState.up;
      return DevStackRunResult(
        command: live.command,
        exitCode: null,
        // **Adopted is not the same as up.** A process that is alive and not
        // answering would report success here, and the caller — who asked for
        // the service to be usable, not for a pid to exist — would go and use
        // it. What `ok` means for a start is whether the thing is up.
        ok: up,
        nothingToDo: true,
        output:
            'Already running as pid ${live.pid}, started '
            '${stackAge(live.startedAt) ?? 'just now'}. Nothing new was '
            'started.',
        stderr: up ? '' : (reading.failure ?? ''),
        reading: reading,
      );
    }
    if (problemWith(declaration.start) case var problem?) {
      throw ActionRefusal(problem);
    }
    // **Every value is resolved before anything is spawned**, and a source
    // that cannot answer refuses the start rather than letting it fall back.
    // A service started against a port nobody chose does not fail — it works,
    // against whatever is on that port, which in a monorepo is the checkout
    // next door. That failure has no symptom until someone notices their data
    // in somebody else's database.
    await _lookUpPort(fresh: true);
    if (_portProblem case var problem?) {
      throw ActionRefusal(
        'Cannot start $label: its port could not be found. '
        '${_sentence(problem)}\n'
        'If your stack gives out the port, bring the stack up first.',
      );
    }
    var (declaredEnv, envProblem) = await _resolveEnv();
    if (envProblem != null) {
      throw ActionRefusal(
        'Cannot start $label: ${_sentence(envProblem)} Nothing was started.',
      );
    }
    // `argvOf` is where a StackRun.tool is looked up, and a tool that cannot
    // be found is a refusal rather than a failed transition.
    var argv = await argvOf(declaration.start);
    var environment = await terminalEnvironmentToRun(argv.first);

    // **The orphan check.** A port held by something we did not start is the
    // one failure that reads as nonsense otherwise: the spawn succeeds, the
    // process dies on `EADDRINUSE` a moment later, and the panel says `down`
    // with a stack trace in the log. Naming the port and how to find what
    // holds it turns that into one sentence.
    if (_port case var port?) {
      if (await _accepts(port)) {
        if (_otherCheckoutOn(port) case var holder?) {
          throw ActionRefusal(
            'Cannot start $label: ${_heldBy(holder)} is already listening on '
            'localhost:$port. ${_onePortTail(holder)}',
          );
        }
        throw ActionRefusal(
          'Cannot start $label: something flutterware did not start is '
          'already listening on localhost:$port. Run '
          '`lsof -nP -iTCP:$port -sTCP:LISTEN` to find it, then stop it or '
          'give $label another port.',
        );
      }
    }

    _showingLog = true;
    var line = argv.join(' ');
    notifyChanged();
    var logPath = p.join(
      runDir(),
      '${serviceHandleKey(host.worktree.path, id)}-$pid-${_logSequence++}.log',
    );
    ServiceHandle handle;
    try {
      Directory(runDir()).createSync(recursive: true);
      // Created eagerly so a reader arriving before the shell's redirect sees
      // an empty log rather than a missing one.
      File(logPath).writeAsStringSync('');
      // `exec "$@"` replaces the shell with the service, so the pid recorded
      // here *is* the service's — which is what every liveness check and the
      // stop ladder depend on. The log path travels in the environment rather
      // than in the script, so no amount of punctuation in a path can turn
      // into shell syntax.
      var process = await Process.start(
        '/bin/sh',
        ['-c', r'exec "$@" > "$FW_RUN_LOG" 2>&1 < /dev/null', 'sh', ...argv],
        workingDirectory: workingDirectory,
        // The environment of a new terminal window, whichever way this
        // process was started — see [terminalEnvironment]. The shell below
        // resolves the executable against it, so `['uv', 'run', …]` works
        // from a studio opened in the Dock, and a Dart service finds its build
        // hooks as a terminal's `dart run` left them. A declaration's `env:`
        // goes on top.
        environment: {...environment, ...declaredEnv, 'FW_RUN_LOG': logPath},
        includeParentEnvironment: false,
        mode: ProcessStartMode.detached,
      );
      handle = ServiceHandle(
        worktree: host.worktree.path,
        service: id,
        name: declaration.name,
        pid: process.pid,
        command: line,
        workingDirectory: workingDirectory,
        logPath: logPath,
        ready: readyDescription,
        readyPort: _port,
        startedAt: DateTime.now(),
      ).publish(runDir());
      _handle = handle;
    } on Object catch (e) {
      recordRun(command: line, output: '$e', ranFor: endBusy());
      notifyChanged();
      rethrow;
    }
    notifyChanged();

    var outcome = await _waitForReady(handle);
    // Read once and carried, rather than re-read off [lastOutput] afterwards:
    // the handle may have just been deleted by a process that died, and this
    // is the last moment anything knows where its log was.
    var log = _readLog(handle);
    recordRun(command: line, output: log, ranFor: endBusy());
    notifyChanged();
    var reading = await refresh();
    return DevStackRunResult(
      command: line,
      // No exit code: the process has deliberately not exited. What `ok` means
      // for a start is whether the thing is now usable, which is the only
      // question the caller asked.
      exitCode: null,
      ok: reading.state == StackState.up,
      output: log,
      stderr: outcome ?? '',
      reading: reading,
    );
  }

  /// Waits until readiness answers, the process dies, or the declared timeout
  /// expires. Returns null when it came up, and one sentence when it did not.
  ///
  /// **Nothing is killed on a timeout.** The process may simply be slower than
  /// the declaration said, and killing it would take the log with it — the one
  /// artefact that explains which of the two it is.
  Future<String?> _waitForReady(ServiceHandle handle) async {
    var timeout = declaration.ready.timeout;
    var deadline = DateTime.now().add(timeout ?? Duration.zero);
    if (declaration.ready is ProcessAliveReady) {
      // **A pid that has existed for two milliseconds is not evidence.** With
      // nothing to poll, this check is true the instant the fork returns — so
      // a command with a typo in it, which dies on its own error a moment
      // later, would be reported as up and only contradicted by the next poll.
      // One short settle is the difference between "it started" and "it did
      // not immediately fall over", which is the whole of what this kind of
      // readiness can honestly claim.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    while (true) {
      if (!isProcessAlive(handle.pid)) {
        handle.delete();
        _handle = null;
        return 'It exited ${_short(handle.uptime)} after it was started. '
            'Check its output.';
      }
      var ready = await _checkReady();
      if (ready.ok) return null;
      if (!DateTime.now().isBefore(deadline)) {
        return 'It is running as pid ${handle.pid}, but ${ready.why} after '
            '${_short(handle.uptime)}. It was left running. Check its log, '
            'or give `ready:` a longer `timeout:`.';
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  // ── stop ─────────────────────────────────────────────────────────────────

  /// Signals the process *group*, escalating.
  ///
  /// The group rather than the pid, because a spawn is routinely a launcher
  /// wrapping the thing that holds the port — `uv run` around an interpreter,
  /// a wrapper script around a JVM — and signalling only the number we
  /// recorded leaves the port held by a process nothing is tracking. The
  /// detached spawn puts the child in a session of its own, so the group is
  /// exactly the service and its children and nothing else. Where that cannot
  /// be confirmed, only the pid is signalled — see [_signalTarget].
  @override
  Future<DevStackRunResult> performStop() async {
    var handle = _liveHandle();
    if (handle == null) {
      // The reading comes from a look rather than from an assumption: there
      // may be nothing running, or there may be something on the port that we
      // never started — and telling someone "nothing is running" while their
      // port is held is the sentence that sends them looking in the wrong
      // place.
      var reading = await refresh();
      var taken = reading.state == StackState.unavailable;
      return DevStackRunResult(
        command: 'stop $label',
        exitCode: null,
        ok: !taken,
        nothingToDo: true,
        output: taken
            ? 'Nothing to stop: flutterware did not start what is running. '
                  '${reading.failure ?? ''}'
            : 'Nothing to stop: $label is not running.',
        reading: reading,
      );
    }
    beginBusy('stop');
    // Before the first signal, so a process that looks between the pid going
    // and the handle going does not take the stop for an exit.
    handle = _handle = handle.markStopping();
    // What was pressed was `stop`, so what the console should answer with is
    // what stopping did.
    _showingLog = false;
    var target = _signalTarget(handle.pid);
    var said = <String>[];
    var stopped = false;
    for (var signal in const ['INT', 'TERM', 'KILL']) {
      _signal(target, signal);
      said.add('kill -$signal $target');
      if (await _waitForGone(target, handle.pid, declaration.stopGrace)) {
        stopped = true;
        break;
      }
    }
    handle.delete();
    _handle = null;
    var ranFor = endBusy();
    var ending = stopped
        ? 'pid ${handle.pid} is gone.'
        : 'pid ${handle.pid} survived SIGKILL, which should not be possible '
              'unless it is stuck in the kernel. Its handle has been removed, '
              'so flutterware is no longer claiming it.';
    var output = [...said, ending].join('\n');
    // The last rung, not `kill <target>`: it is what actually stopped it, it
    // is runnable as it stands, and `kill -70734` in a console header reads as
    // a signal number rather than as a process group.
    recordRun(command: said.last, output: output, ranFor: ranFor);
    var reading = await refresh();
    return DevStackRunResult(
      command: said.last,
      exitCode: null,
      ok: stopped,
      output: output,
      reading: reading,
    );
  }

  /// What to pass to `kill`: `-<pgid>` for the group, or the bare pid.
  ///
  /// **The guard is not optional.** If the child somehow shares this process's
  /// group, signalling the group would signal the GUI — so a pgid that is ours,
  /// or that cannot be read at all, falls back to the pid alone. Losing a
  /// grandchild is recoverable; killing the tool that was asked to stop a
  /// server is not.
  int _signalTarget(int servicePid) {
    var group = _pgidOf(servicePid);
    if (group == null || group <= 1) return servicePid;
    if (group == _pgidOf(pid)) return servicePid;
    return -group;
  }

  void _signal(int target, String signal) {
    try {
      // Through `sh` because `kill` is a builtin there, so it needs no PATH —
      // and a GUI started from the Dock does not have your shell's. `target`
      // is an integer this code parsed, so there is nothing to quote.
      Process.runSync('/bin/sh', ['-c', 'kill -$signal $target']);
    } on Object {
      // The process is already gone, or is not ours. The wait below decides
      // which, and neither is worth failing a stop over.
    }
  }

  /// Whether there is anything left to signal.
  ///
  /// **The group, not the pid, and this is not a detail.** Measured here on
  /// macOS: `sh -c 'sleep 60 & wait'` spawned detached leaves two processes in
  /// the group, and `SIGINT` reaps only the shell — because POSIX has a
  /// non-interactive shell set `SIGINT` to *ignored* in a background command,
  /// so the child of a start script routinely survives the first rung. A
  /// ladder that stopped when the recorded pid was gone would therefore stop
  /// one rung early and leave the port held by the grandchild, which is the
  /// exact orphan group-signalling exists to prevent. `SIGTERM` cleared it.
  Future<bool> _waitForGone(int target, int servicePid, Duration grace) async {
    bool gone() => target < 0
        ? _groupMembers(-target).isEmpty
        : !isProcessAlive(servicePid);
    var deadline = DateTime.now().add(grace);
    while (DateTime.now().isBefore(deadline)) {
      if (gone()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return gone();
  }

  static int? _pgidOf(int of) {
    if (Platform.isWindows) return null;
    try {
      var result = Process.runSync('ps', ['-o', 'pgid=', '-p', '$of']);
      if (result.exitCode != 0) return null;
      return int.tryParse('${result.stdout}'.trim());
    } on Object {
      return null;
    }
  }

  /// Every pid still in [pgid].
  ///
  /// The whole table filtered here rather than `ps -g`, whose meaning is not
  /// the same on every platform — on BSD it selects by session leader. `pid`
  /// and `pgid` in two columns is the reading no `ps` disagrees about. This
  /// runs only while a stop is in flight, a few times a second at most.
  static List<int> _groupMembers(int pgid) {
    if (Platform.isWindows) return const [];
    try {
      var result = Process.runSync('ps', ['-A', '-o', 'pid=,pgid=']);
      if (result.exitCode != 0) return const [];
      var found = <int>[];
      for (var line in const LineSplitter().convert('${result.stdout}')) {
        var parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        if (int.tryParse(parts[1]) != pgid) continue;
        if (int.tryParse(parts[0]) case var member?) found.add(member);
      }
      return found;
    } on Object {
      return const [];
    }
  }

  // ── readiness ────────────────────────────────────────────────────────────

  Future<_Readiness> _checkReady() async {
    switch (declaration.ready) {
      case ProcessAliveReady():
        // The caller has already established that the pid is there, and that
        // is the whole of what this check claims.
        return const _Readiness.ok();
      case PortReady():
        if (_port case var port?) {
          return await _accepts(port)
              ? const _Readiness.ok()
              : _Readiness.no('nothing is accepting on localhost:$port');
        }
        return _Readiness.no('its port is not known');
      case HttpReady(:var path):
        if (_port case var port?) return _get(port, path);
        return _Readiness.no('its port is not known');
    }
  }

  /// The service another checkout started on [port], or null.
  ServiceHandle? _otherCheckoutOn(int port) =>
      ServiceHandle.holding(runDir(), port, exceptWorktree: host.worktree.path);

  /// [holder] as the subject of a sentence: `the API server from
  /// /src/shop-main`, or its own name when it is another service. Capitalised
  /// when it [start]s one.
  String _heldBy(ServiceHandle holder, {bool start = false}) {
    var name = holder.service == id
        ? '${start ? 'The' : 'the'} $label'
        : (holder.name ?? holder.service);
    return '$name from ${holder.worktree}';
  }

  /// What to do about [holder]: stop it in its checkout, or stop sharing one
  /// port between checkouts.
  String _onePortTail(ServiceHandle holder) => holder.service == id
      ? 'With a fixed port, one checkout at a time can run it. Stop it with '
            'Tear down in that checkout, or give each checkout its own port '
            'with `Ready.httpFrom` in tool/flutterware.dart.'
      : 'Stop it with Tear down in that checkout, or give $label another '
            'port.';

  Future<bool> _accepts(int port) async {
    try {
      var socket = await Socket.connect(
        'localhost',
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  Future<_Readiness> _get(int port, String path) async {
    var client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      var request = await client
          .get('localhost', port, path)
          .timeout(const Duration(seconds: 3));
      var response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain<void>();
      // 2xx and 3xx. Anything else is a server that is listening and saying
      // no — a 503 from a health check that knows its database is not up is
      // the case this distinction is for, and it is exactly the one a bare
      // port check gets wrong.
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return const _Readiness.ok();
      }
      return _Readiness.no(
        'GET localhost:$port$path answered ${response.statusCode}',
      );
    } on Object {
      return _Readiness.no('GET localhost:$port$path did not answer');
    } finally {
      client.close(force: true);
    }
  }

  // ── log ──────────────────────────────────────────────────────────────────

  /// The tail of the file the process is writing to.
  ///
  /// Read from the end rather than whole: a server left up overnight writes a
  /// log this is called on every poll, and reading all of it to show the last
  /// screenful is how a panel becomes the most expensive thing in the process.
  String _readLog(ServiceHandle handle) {
    var path = handle.logPath;
    if (path == null) return '';
    try {
      var file = File(path);
      var length = file.lengthSync();
      if (length <= maxStackOutput) {
        return tailOf(withoutDartChatter(file.readAsStringSync()));
      }
      var raf = file.openSync();
      try {
        raf.setPositionSync(length - maxStackOutput);
        var bytes = raf.readSync(maxStackOutput);
        var text = utf8.decode(bytes, allowMalformed: true);
        return '…\n${tailOf(withoutDartChatter(text))}';
      } finally {
        raf.closeSync();
      }
    } on Object {
      // A log that cannot be read is a log with nothing in it, as far as a
      // panel is concerned.
      return '';
    }
  }

  /// [text] ending in a full stop, for a script's own words quoted mid-message.
  static String _sentence(String text) {
    var trimmed = text.trimRight();
    return trimmed.endsWith('.') ? trimmed : '$trimmed.';
  }

  @override
  String get statusDescription =>
      'Checks that the process flutterware started is still running and '
      'answering: $readyDescription.';

  @override
  String get startDescription =>
      'Starts `${describeRun(declaration.start)}` and waits until '
      '$readyDescription. If it is already running, it is left as it is.';

  @override
  String get stopDescription =>
      'Stops the process and everything it started: SIGINT, then SIGTERM, '
      'then SIGKILL, ${_short(declaration.stopGrace)} apart.';
}

/// Whether the thing is usable, and one fragment saying why not.
class _Readiness {
  const _Readiness.ok() : ok = true, why = '';
  const _Readiness.no(this.why) : ok = false;

  final bool ok;
  final String why;
}

/// A duration in the shortest form that is still true, for a sentence.
String _short(Duration elapsed) {
  if (elapsed.inSeconds < 60) return '${elapsed.inSeconds}s';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h';
  return '${elapsed.inDays}d';
}
