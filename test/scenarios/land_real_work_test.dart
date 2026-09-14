import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/real_work/tracker.dart';
import 'package:flutterware/src/scenarios/real_work.dart';
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
