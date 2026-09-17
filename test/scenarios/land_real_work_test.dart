import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/real_work/tracker.dart';
import 'package:flutterware/src/scenarios/real_work.dart';
import 'package:flutterware/src/scenarios/scenario.dart'
    show guessedLandingNotice;
import 'package:flutterware/src/scenarios/settle.dart';

/// `landed` is what a step says about work it gave up on, so it has to be false
/// whenever the allowance ran out — including when the policy is where it ran
/// out.
///
/// The shape that used to escape: a quiet screen whose untracked read lands in
/// a guessed turn, and whose build then starts a tracked load behind a spinner.
/// The guessed turn schedules a frame, so the policy is applied again and its
/// landings wait on the load; when the allowance runs out there, the spinner
/// leaves the policy unsettled, and the step returned `landed: true` with the
/// load still pending.
void main() {
  tearDown(resetTrackedRealWork);

  testWidgets('a load that outlives the allowance behind a spinner is not '
      'reported as landed', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _ChainedLoad()));

    const policy = Settle.elapse(Duration(milliseconds: 500));
    var budget = RealWorkBudget(trackedWait: const Duration(milliseconds: 100));
    var settled = await policy.apply(
      tester,
      land: () => budget.land(tester, null),
    );
    expect(settled, isTrue, reason: 'nothing has started yet');

    var result = await landRealWork(
      tester,
      policy,
      settled: settled,
      budget: budget,
    );

    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: 'the setup has to reach the spinner for this to test anything',
    );
    expect(RealWork.pendingWork.map((work) => '$work'), ['slow load']);
    expect(result.settled, isFalse);
    expect(result.landed, isFalse);
    expect(pendingRealWork(null), {
      'tracked': ['slow load'],
    });
  });

  // The picture was right, but only because the real loop turned fast enough:
  // the step has to be able to say so, or a slower machine's missing artwork
  // is the first anybody hears of it.
  testWidgets('work only a guessed turn found is reported with its turn', (
    tester,
  ) async {
    // `MaterialApp` tells the platform its title, and under the stock binding
    // those replies come back on the real loop whenever the engine gets to
    // them — on a CI runner, on the very turn the read lands, which reads that
    // turn as a platform reply and drops the guess. Answered here, nothing is
    // pending and the turn is the read's alone; a reply sharing it is
    // `a turn that only delivered a platform reply is not a guess`'s case.
    var messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(const MaterialApp(home: _UntrackedRead()));
    const policy = Settle.standard;
    var budget = RealWorkBudget();
    var settled = await policy.apply(tester);

    expect(messenger.pendingMessageCount, 0);

    var result = await landRealWork(
      tester,
      policy,
      settled: settled,
      budget: budget,
    );

    expect(find.text('read'), findsOneWidget);
    expect(result.guessed, isNotNull);
    expect(result.guessed, inInclusiveRange(1, realWorkTurns));
  });

  testWidgets('work that was announced is not a guess', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _UntrackedRead(tracked: true)),
    );
    const policy = Settle.standard;
    var budget = RealWorkBudget();
    var settled = await policy.apply(
      tester,
      land: () => budget.land(tester, null),
    );

    var result = await landRealWork(
      tester,
      policy,
      settled: settled,
      budget: budget,
    );

    expect(find.text('read'), findsOneWidget);
    expect(result.guessed, isNull);
  });

  // Under the stock binding a plain `flutter test` runs on. A field gaining
  // focus asks the platform about the clipboard and text actions, and those
  // replies land on the turns the landing takes.
  testWidgets('a turn that only delivered a platform reply is not a guess', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField())),
    );
    await tester.tap(find.byType(TextField));
    const policy = Settle.standard;
    var settled = await policy.apply(tester);
    expect(
      tester.binding.defaultBinaryMessenger.pendingMessageCount,
      isPositive,
      reason: 'the setup has to leave a reply for the turns to deliver',
    );

    var result = await landRealWork(
      tester,
      policy,
      settled: settled,
      budget: RealWorkBudget(),
    );

    expect(tester.binding.defaultBinaryMessenger.pendingMessageCount, 0);
    expect(result.guessed, isNull);
  });

  test('the notice names each step and its turn', () {
    expect(guessedLandingNotice('Checkout', const {}), isNull);

    var said = guessedLandingNotice('Checkout', const {'': 2, 'tap "Pay"': 9})!;

    expect(
      said,
      startsWith(
        '"Checkout": `the first frame` (turn 2 of $realWorkTurns), '
        '`s.tap "Pay"` (turn 9 of $realWorkTurns) finished drawing',
      ),
    );
  });
}

/// A read off the fake clock that lands on the real loop — announced to
/// `RealWork` only when [tracked].
class _UntrackedRead extends StatefulWidget {
  const _UntrackedRead({this.tracked = false});

  final bool tracked;

  @override
  State<_UntrackedRead> createState() => _UntrackedReadState();
}

class _UntrackedReadState extends State<_UntrackedRead> {
  var _read = false;

  @override
  void initState() {
    super.initState();
    Future<void> read() =>
        Future<void>.delayed(const Duration(milliseconds: 1));
    var done = widget.tracked
        ? RealWork.run(read, label: 'read')
        : _rootRead(read);
    done.then((_) {
      if (mounted) setState(() => _read = true);
    });
  }

  static Future<void> _rootRead(Future<void> Function() read) {
    var done = Completer<void>();
    Zone.root.run(() => read().then(done.complete));
    return done.future;
  }

  @override
  Widget build(BuildContext context) => Text(_read ? 'read' : 'reading');
}

class _ChainedLoad extends StatefulWidget {
  const _ChainedLoad();

  @override
  State<_ChainedLoad> createState() => _ChainedLoadState();
}

class _ChainedLoadState extends State<_ChainedLoad> {
  var _loading = false;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    // Untracked and off the fake clock, so only a guessed turn lands it.
    var read = Completer<void>();
    Zone.root.run(
      () =>
          Future<void>.delayed(const Duration(milliseconds: 1))
              .then(read.complete),
    );
    read.future.then((_) {
      if (!mounted) return;
      setState(() => _loading = true);
      RealWork.run(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
        label: 'slow load',
      ).then((_) {
        if (mounted) setState(() => _loaded = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) => Center(
    child: _loaded
        ? const Text('Loaded')
        : _loading
        ? const CircularProgressIndicator()
        : const Text('Waiting'),
  );
}
