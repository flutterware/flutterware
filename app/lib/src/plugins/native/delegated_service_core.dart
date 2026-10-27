import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:meta/meta.dart';

import '../../session/job.dart';
import 'dev_stack_results.dart';
import 'stack_service_core.dart';

/// A service the project's own CLI owns.
///
/// It owns nothing. Everything here runs one of the project's own commands and
/// reads what came back — the declaration's probe to find out the state,
/// `start` / `stop` to change it. That is the whole difference from a
/// supervisor, and it is what makes a stack brought up in a terminal
/// indistinguishable from one brought up by the button: there is nothing to be
/// the authority *about*.
class DelegatedServiceCore extends StackServiceCore {
  DelegatedServiceCore(
    super.host,
    DelegatedStackService super.declaration, {
    required super.onChanged,
  });

  @override
  DelegatedStackService get declaration =>
      super.declaration as DelegatedStackService;

  /// The probe in flight, so a second caller joins it rather than starting one.
  Future<StackReading>? _inFlight;

  @override
  bool get canStart => declaration.start != null;

  @override
  bool get canStop => declaration.stop != null;

  @override
  bool get stopIsDestructive => declaration.stopIsDestructive;

  /// The probe as declared, joined — what the panel names when it explains
  /// where the state on screen came from.
  ///
  /// Never null now that a probe is required to declare a delegated service at
  /// all; a config whose probe could not be read never becomes one of these.
  String get declaredProbeCommand =>
      describeRun(declaration.probe.run, polled: true);

  @override
  List<String> get provenance => ['probe · $declaredProbeCommand'];

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
    var derived = pollInterval * 3;
    return derived < const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : derived;
  }

  /// Runs the probe and adopts what it says. Does nothing while a transition is
  /// in flight — see [StackServiceCore.busy].
  ///
  /// One probe at a time, and a second caller joins the first. The poll
  /// timer used to fire regardless of whether the last probe had come back, so
  /// a probe slower than the interval — which a `dart run` on a big workspace
  /// can be, measured at 4.6s where the default interval is 10s — left two
  /// subprocesses racing to write the reading, and the panel showed whichever
  /// finished last. Joining rather than skipping is what keeps the `status`
  /// action honest: asked to go and look while a poll is out, it returns *that*
  /// look rather than the cache it was trying to refresh.
  @override
  Future<StackReading> refresh() {
    if (isDisposed || busy != null) return Future.value(reading);
    if (_inFlight case var inFlight?) return inFlight;
    probing = true;
    var started = DateTime.now();
    var future = _probeOnce(declaration.probe).whenComplete(() {
      lastCheckFor = DateTime.now().difference(started);
      probing = false;
      _inFlight = null;
      rescheduleIfWatching();
    });
    return _inFlight = future;
  }

  Future<StackReading> _probeOnce(Probe probe) async {
    if (problemWith(probe.run) case var problem?) {
      return adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure: problem,
        ),
      );
    }
    List<String> argv;
    try {
      argv = await argvOf(probe.run, polled: true);
    } on Object catch (e) {
      // A tool the shell cannot find. That is the probe failing, not the stack
      // being down — and the sentence names the executable.
      return adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure: '$e',
        ),
      );
    }
    try {
      var result = await runProcess(
        argv,
        workingDirectory: workingDirectory,
      ).timeout(_probeTimeout);
      return adopt(_read(probe, result));
    } on TimeoutException {
      // **A probe that never returns has to become an answer.** Before the
      // in-flight guard a hung one merely leaked a process per interval; with
      // it, the guard would hand every later caller the same dead future and
      // the panel would sit on one reading forever.
      return adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure:
              'The probe did not answer within ${_probeTimeout.inSeconds}s: '
              '${describeRun(probe.run, polled: true)}',
        ),
      );
    } on Object catch (e) {
      // A command that could not be spawned at all — a missing binary, a
      // working directory that is not there. That is the probe failing, not
      // the stack being down.
      return adopt(
        StackReading(
          state: StackState.unavailable,
          at: DateTime.now(),
          failure:
              'Could not run `${argv.first}`: '
              '${e is ProcessException ? e.message : e}',
        ),
      );
    }
  }

  /// Turns one probe run into a reading.
  StackReading _read(Probe probe, ProcessResult result) {
    var at = DateTime.now();
    var out = combinedOutput(result);
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
        var said = firstLineOf(out);
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
      detail: lastLineOf(out),
    );
  }

  /// Brings the stack up, then re-probes.
  @override
  Future<DevStackRunResult> performStart() =>
      _transition(declaration.start, 'start');

  /// Takes it down, then re-probes.
  @override
  Future<DevStackRunResult> performStop() =>
      _transition(declaration.stop, 'stop');

  /// `async` so the refusal arrives through the future rather than out of the
  /// call. A method whose type says `Future` and which throws synchronously is
  /// one a caller can only guard by wrapping the call site as well as awaiting
  /// it.
  Future<DevStackRunResult> _transition(StackRun? run, String what) async {
    if (run == null) {
      throw ActionRefusal(
        'No `$what` command is declared for $label, so flutterware can only '
        'check it. Add one in tool/flutterware.dart, or run it yourself.',
      );
    }
    if (problemWith(run) case var problem?) throw ActionRefusal(problem);
    // The future, unawaited: `runDeclared` claims the service before it waits
    // on it, and that claim has to land in this turn.
    return runDeclared(argvOf(run), busy: what, thenProbe: true);
  }

  @override
  String get statusDescription =>
      'Runs the probe now and reports the state, with when it was checked.';

  @override
  String get startDescription =>
      'Runs the start command, then checks the state. On a service that is '
      'already up, the command should do nothing.';

  @override
  String get stopDescription => stopIsDestructive
      ? 'Runs the stop command, which this project marks as deleting data. '
            'The next start begins from empty.'
      : 'Runs the stop command, then checks the state.';
}
