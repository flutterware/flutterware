import 'dart:async';
import 'dart:collection';

import '../embedder/tester_host.dart';

/// One scenario to run: its file and its exact name.
typedef LiveScenarioRef = ({String file, String scenario});

/// K guests from one kernel, one scenario per request.
///
/// Under a live binding one failure poisons the process — the binding's
/// `!inTest` assertion then fails every later test — so a guest that
/// answered a red scenario is killed and a fresh one takes its slot. A boot
/// is ~135ms; a poisoned guest is every remaining scenario red.
///
/// A guest can also die without answering: an error that escapes every zone
/// the scenario owns takes `flutter_tester` down with it. That is one red
/// scenario too, not a run that reports nothing — see [_diedDuring].
class LiveScenarioPool {
  LiveScenarioPool({required this.host, required this.jobs});

  final TesterHost host;

  /// How many guests run at once. Clamped to the number of scenarios.
  final int jobs;

  /// Runs every scenario in [selection], [jobs] at a time, and hands back the
  /// harness replies in the order they completed. [argsFor] is the request
  /// one guest gets for one scenario — the run's own arguments with `file`
  /// and `scenario` narrowed to that one.
  Future<List<Map<String, Object?>>> run(
    List<LiveScenarioRef> selection,
    Map<String, String> Function(LiveScenarioRef ref) argsFor,
  ) async {
    if (selection.isEmpty) return const [];
    var queue = Queue.of(selection);
    var results = <Map<String, Object?>>[];
    var dill = host.dillPath;
    var spawned = 0;

    Future<void> worker() async {
      // What the current scenario has captured so far, heard as it happens —
      // the only record of it left if the guest never answers.
      var captured = <Map<String, Object?>>[];
      Future<TesterGuest> spawn() => host.spawnGuest(
        dill,
        label: 'tester#${++spawned}',
        onGuestEvent: captured.add,
      );

      var guest = await spawn();
      try {
        while (queue.isNotEmpty) {
          var next = queue.removeFirst();
          captured.clear();
          var watch = Stopwatch()..start();
          Map<String, Object?> answer;
          try {
            var reply = await guest.vm.requireExtension(
              'ext.flutterware.scenarios.run',
              args: argsFor(next),
            );
            answer = (reply ?? const <String, Object?>{})
                .cast<String, Object?>();
          } catch (error) {
            answer = await _diedDuring(
              next,
              guest,
              error,
              captured: List.of(captured),
              ms: watch.elapsedMilliseconds,
            );
          }
          results.add(answer);
          // A red scenario, or one that blew its deadline and is still
          // holding the binding: this guest is spent, the queue is not.
          var outcomes = (answer['scenarios'] as List?) ?? const [];
          var red = outcomes.any((o) => (o as Map)['ok'] != true);
          if (red || answer['abandoned'] == true || answer['error'] != null) {
            await guest.kill();
            if (queue.isEmpty) return;
            guest = await spawn();
          }
        }
      } finally {
        await guest.kill();
      }
    }

    await Future.wait([
      for (var i = 0; i < jobs.clamp(1, selection.length); i++) worker(),
    ]);
    return results;
  }

  /// The reply a guest would have given for [ref] had it lived: the scenario
  /// red, with the steps it had [captured] before it went and the end of what
  /// the process printed on the way down.
  ///
  /// Measured on a real suite before this: an uncaught `SocketException`
  /// killed a guest, the run failed with `Service connection disposed` and
  /// nothing else, and `run.json` held no scenario, no step and no error. The
  /// pictures of the steps before the crash were on disk with nothing
  /// pointing at them, and what named the exception was the guest's console,
  /// which only a re-run under plain `flutter test` showed.
  static Future<Map<String, Object?>> _diedDuring(
    LiveScenarioRef ref,
    TesterGuest guest,
    Object error, {
    required List<Map<String, Object?>> captured,
    required int ms,
  }) async {
    var code = await guest.process.exitCode
        .then<int?>((code) => code)
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    // The service connection drops the moment the process does; its last
    // lines are still in the pipes.
    await guest.outputDone.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    var output = guest.output.join('\n').trim();
    var what = code == null
        ? 'The harness stopped answering while this scenario ran ($error).'
        : 'The harness process died while this scenario ran '
              '(flutter_tester exited with $code).';
    return {
      'scenarios': [
        {
          'file': ref.file,
          'name': ref.scenario,
          'ok': false,
          'device': ?captured
              .map((event) => event['device'])
              .whereType<String>()
              .lastOrNull,
          'ms': ms,
          'steps': [
            for (var event in captured)
              if (event['step'] case Map<String, Object?> step) step,
          ],
          'errors': [
            {
              'error':
                  '$what The steps are the ones it captured before that, and '
                  'the scenarios after it ran in a fresh process. '
                  '${output.isEmpty ? 'It printed nothing.' : 'The last of what it printed:\n\n$output'}',
            },
          ],
        },
      ],
    };
  }
}
