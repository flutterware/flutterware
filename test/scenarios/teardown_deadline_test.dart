import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/teardown_deadline.dart';
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/live_test.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/test.dart';

/// A client that does its work on the zone it was opened in, the way a
/// stream subscription runs its callbacks: opened in a scenario's body, its
/// `close` starts a timer on the scenario's fake clock even when a teardown
/// calls it.
class _Client {
  _Client() : _zone = Zone.current;

  final Zone _zone;

  Future<void> close() =>
      _zone.run(() => Future<void>.delayed(const Duration(milliseconds: 10)));

  /// Work that has already finished, handing its result back through the
  /// zone the client was opened in.
  Future<void> flush() => _zone.run(() => Future<void>.microtask(() {}));
}

/// Declares [body] the way a test file's `main` would, and loads its one
/// test to run here, inside this test.
LiveTest _load(void Function() body) {
  var declarer = Declarer();
  declarer.declare(body);
  var root = declarer.build();
  var suite = Suite(root, SuitePlatform(Runtime.vm));
  var test = root.entries.single as Test;
  return test.load(suite, groups: [root]);
}

/// The line of this file that holds [text], as a stack frame names it.
String _lineOf(String text) {
  var path = 'test/scenarios/teardown_deadline_test.dart';
  var lines = File(path).readAsLinesSync();
  return '$path:${lines.indexWhere((line) => line.contains(text)) + 1}';
}

void main() {
  group('a scenario', () {
    var budget = scenarioTeardownBudget;
    setUp(() => scenarioTeardownBudget = const Duration(milliseconds: 300));
    tearDown(() => scenarioTeardownBudget = budget);

    test('a teardown that awaits the fake clock fails instead of hanging the '
        'run', () async {
      var done = false;
      var live = _load(() {
        scenario('Closes on its own clock', (s) async {
          await s.pumpWidget(const SizedBox());
          var client = _Client();
          addTearDown(() async {
            await client.close();
            done = true;
          });
        });
      });

      // Before the deadline this never returned: `test_api` waited on the
      // teardown's future for good, whatever the test's timeout said.
      await live.run().timeout(const Duration(seconds: 20));

      expect(live.state.result.isPassing, isFalse);
      var error = '${live.errors.single.error}';
      expect(
        error,
        startsWith(
          '"Closes on its own clock": a teardown was still running 300ms after '
          "the scenario's body returned",
        ),
      );
      // The teardown by its line, and the work by the line that started it.
      expect(
        error,
        contains(
          'The teardown at `${_lineOf('await client.close();')}` is waiting '
          'on a 10ms timer from `_Client.close.<anonymous closure> '
          '(${_lineOf('_zone.run(() => Future<void>.delayed')})`.',
        ),
      );
      expect(error, contains("on the scenario's fake clock"));
      expect(error, contains('It probably needs pumping.'));
      expect(error, contains('`s.act('));
      expect(error, contains('`s.runAsync`'));
      // The clock was moved so the teardown could finish, which is what let
      // the run go on.
      expect(done, isTrue);
    });

    test('a teardown waiting on a queued microtask says so', () async {
      var live = _load(() {
        scenario('Flushes on its own zone', (s) async {
          await s.pumpWidget(const SizedBox());
          var client = _Client();
          addTearDown(client.flush);
        });
      });

      await live.run().timeout(const Duration(seconds: 20));

      var error = '${live.errors.single.error}';
      expect(
        error,
        contains("1 microtask is queued in the scenario's fake zone"),
      );
      expect(error, contains('It probably needs pumping.'));
    });

    test('a teardown that finishes in time passes', () async {
      var live = _load(() {
        scenario('Closes for real', (s) async {
          await s.pumpWidget(const SizedBox());
          addTearDown(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        });
      });

      await live.run().timeout(const Duration(seconds: 20));

      expect(live.errors, isEmpty);
      expect(live.state.result.isPassing, isTrue);
    });
  });

  test('the budget is half of what the scenario declares', () {
    expect(
      teardownBudgetFor(const Timeout(Duration(seconds: 4))),
      const Duration(seconds: 2),
    );
    expect(
      teardownBudgetFor(const Timeout(Duration(minutes: 2))),
      const Duration(minutes: 1),
    );
    // Nothing declared: the default, kept under half of the harness's own
    // deadline so this one fires first.
    expect(teardownBudgetFor(null), scenarioTeardownBudget);
    expect(
      teardownBudgetFor(null, progress: const Timeout(Duration(seconds: 2))),
      const Duration(seconds: 1),
    );
    expect(
      teardownBudgetFor(null, progress: const Timeout(Duration(minutes: 5))),
      scenarioTeardownBudget,
    );
    // `Timeout.none` turns this deadline off with the others.
    expect(teardownBudgetFor(Timeout.none), isNull);
  });

  test('a teardown waiting on nothing the clock holds says what to check', () {
    var message = teardownStallMessage(
      'Signs out',
      budget: const Duration(seconds: 10),
      microtasks: 0,
    );
    expect(message, contains('a teardown was still running 10s'));
    expect(
      message,
      contains("Nothing is waiting on the scenario's fake clock"),
    );
    expect(message, contains('longer `timeout:`'));
    expect(message, isNot(contains('pumping')));

    var real = teardownStallMessage(
      'Signs out',
      budget: const Duration(seconds: 10),
      fakeClock: false,
    );
    expect(real, isNot(contains('fake')));
    expect(real, contains('longer `timeout:`'));
  });

  test('a teardown is found by the frame that called it', () {
    var trace = StackTrace.fromString('''
#0      recordingTimers.<anonymous closure> (package:flutterware/src/scenarios/fake_timers.dart:76:72)
#1      Zone.createTimer (dart:async/zone.dart:690:7)
#2      new Future.delayed (dart:async/future.dart:442:5)
#3      Client.close (package:shop/client.dart:11:13)
#4      main.<anonymous closure>.<anonymous closure> (file:///work/shop/test/scenarios/checkout_test.dart:26:24)
#5      new Future.sync (dart:async/future.dart:325:27)
#6      Invoker.runTearDowns.<anonymous closure>.<anonymous closure> (package:test_api/src/backend/invoker.dart:296:18)
#7      Invoker._waitForOutstandingCallbacks.<anonymous closure> (package:test_api/src/backend/invoker.dart:318:17)
''');
    expect(teardownSiteOf(trace), 'test/scenarios/checkout_test.dart:26');

    // Started past an await, the teardown's frame is gone: no site rather
    // than a wrong one.
    var resumed = StackTrace.fromString('''
#0      recordingTimers.<anonymous closure> (package:flutterware/src/scenarios/fake_timers.dart:76:72)
#1      Client.close (package:shop/client.dart:11:13)
<asynchronous suspension>
''');
    expect(teardownSiteOf(resumed), isNull);
  });
}
