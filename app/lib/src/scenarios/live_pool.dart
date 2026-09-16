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

    Future<TesterGuest> spawn() =>
        host.spawnGuest(dill, label: 'tester#${++spawned}');

    Future<void> worker() async {
      var guest = await spawn();
      try {
        while (queue.isNotEmpty) {
          var next = queue.removeFirst();
          var reply = await guest.vm.requireExtension(
            'ext.flutterware.scenarios.run',
            args: argsFor(next),
          );
          var answer = (reply ?? const <String, Object?>{})
              .cast<String, Object?>();
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
}
