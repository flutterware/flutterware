import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/real_work/tracker.dart';
import 'package:flutterware/src/scenarios/progress.dart';

/// A scenario's timeout is how long it may go without progress, not how long
/// it may take. Measured on a consumer's CI host shared by three comparison
/// jobs: scenario time went from ~365s to ~1000s, and a scenario that passes in
/// five seconds on a quiet machine failed a thirty-second wall-clock budget.
void main() {
  late Duration now;
  late int marks;
  late List<TrackedRealWork> pending;
  late ProgressDeadline deadline;
  Object? stall;

  ProgressDeadline watch({Duration timeout = const Duration(seconds: 5)}) {
    stall = null;
    var made = ProgressDeadline(
      timeout: () => timeout,
      tick: const Duration(seconds: 1),
      now: () => now,
      pendingWork: () => pending,
      marks: () => marks,
      ticking: false,
    );
    unawaited(
      made.stalled.then<void>((_) {}, onError: (Object error) => stall = error),
    );
    return made;
  }

  /// Moves time on one tick at a time, checking at each — an idle isolate,
  /// whose timer fires when it should.
  Future<void> idle(int seconds, {void Function()? each}) async {
    for (var i = 0; i < seconds; i++) {
      now += const Duration(seconds: 1);
      each?.call();
      deadline.check();
    }
    await pumpEventQueue();
  }

  setUp(() {
    now = Duration.zero;
    marks = 0;
    pending = [];
    deadline = watch();
  });

  test(
    'a scenario that keeps getting somewhere outlives its timeout',
    () async {
      // A four-path split, each path ten seconds of steps.
      await idle(40, each: () => marks++);

      expect(stall, isNull);
    },
  );

  test('a scenario waiting on nothing fails at its timeout', () async {
    await idle(4);
    expect(stall, isNull);

    await idle(1);

    expect(stall, isA<ScenarioStall>());
    var stalled = stall! as ScenarioStall;
    expect(stalled.kind, ScenarioStallKind.stalled);
    expect(stalled.idle, const Duration(seconds: 5));
  });

  test('a busy isolate is working, not waiting', () async {
    await idle(3);
    // A check that fires twenty seconds late: the isolate was mounting,
    // pumping or encoding the whole time.
    now += const Duration(seconds: 20);
    deadline.check();
    await idle(4);

    expect(stall, isNull);
  });

  // An idle isolate on a starved host gets its timer late on every tick. Read
  // as work, that lateness kept a genuine stall alive until the hard ceiling.
  test('a waiting isolate scheduled late still reaches its deadline', () async {
    for (var i = 0; i < 20 && stall == null; i++) {
      now += const Duration(milliseconds: 1500);
      deadline.check();
      await pumpEventQueue();
    }

    expect(stall, isA<ScenarioStall>());
    expect((stall! as ScenarioStall).kind, ScenarioStallKind.stalled);
    expect(now, lessThanOrEqualTo(const Duration(seconds: 16)));
  });

  test('tracked work pending is waited for past the timeout', () async {
    pending = [TrackedRealWork('3D model', null)];

    await idle(20);
    expect(stall, isNull);

    pending = [];
    await idle(4);
    expect(stall, isNull, reason: 'its completion was progress');
  });

  test('tracked work that never completes fails at its own ceiling', () async {
    var model = TrackedRealWork('3D model', null);
    pending = [model];

    // First seen by the check a tick after it was announced.
    await idle(trackedWorkCeiling.inSeconds + 1);

    var stalled = stall! as ScenarioStall;
    expect(stalled.kind, ScenarioStallKind.trackedWork);
    expect(stalled.work, same(model));
  });

  test('a body that progresses forever meets the hard ceiling', () async {
    await idle(trackedWorkCeiling.inSeconds * 2, each: () => marks++);

    expect((stall! as ScenarioStall).kind, ScenarioStallKind.ceiling);
  });

  test('no timeout is no deadline', () async {
    deadline = ProgressDeadline(
      timeout: () => null,
      tick: const Duration(seconds: 1),
      now: () => now,
      pendingWork: () => pending,
      marks: () => marks,
      ticking: false,
    );
    unawaited(
      deadline.stalled.then<void>(
        (_) {},
        onError: (Object error) => stall = error,
      ),
    );

    await idle(3600);

    expect(stall, isNull);
  });

  test('tracked work knows how long it has been pending', () async {
    resetTrackedRealWork();
    var work = Completer<void>();
    unawaited(RealWork.track(work.future, label: 'import'));

    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      RealWork.pendingWork.single.pendingFor,
      greaterThanOrEqualTo(const Duration(milliseconds: 20)),
    );
    work.complete();
    resetTrackedRealWork();
  });
}
