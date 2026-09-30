import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The two verbs for a cause that is not a finger.
///
/// Half of what moves a real app never touches the widget tree: a push
/// arrives, a socket pushes a row, a completer the scenario is holding
/// resolves. `act` is the step that says so — the waiting was never the gap,
/// the *report* was, and a screen that changes for no stated reason is a flow
/// a reader has to reverse-engineer. `runAsync` is the same argument from the
/// other end: real work landing is exactly when the tree repaints, and it was
/// the one method on this surface that sat among `tap` and `drag` and settled
/// like neither.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  List<String> shape() => [
    for (var capture in captures) capture.name ?? '${capture.verb}',
  ];

  group('act', () {
    scenario('names the cause, and captures what it did to the screen', (
      s,
    ) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend));
      await s.act('A photo-ready push arrives', () {
        backend.value = 'Your cappuccino is ready';
      });
      expect(s.visibleTexts(), contains('Your cappuccino is ready'));
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'A photo-ready push arrives']);
      // The verb is on the step, so a reader of the flow gets the sentence
      // and a comparison gets something to key on.
      expect(captures.last.verb, 'act');
      expect(captures.last.settled, isTrue);
    });
  });

  group('act with a body that answers', () {
    scenario('hands the answer back', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend));
      var id = await s.act('The backend books the order', () {
        backend.value = 'Order #412';
        return 412;
      });
      expect(id, 412);
      // And an async body is the same verb, awaited.
      var next = await s.act('And the one after it', () async {
        backend.value = 'Order #413';
        return 413;
      });
      expect(next, 413);
    });
    tearDown(
      () => expect(shape(), [
        'pumpWidget',
        'The backend books the order',
        'And the one after it',
      ]),
    );
  });

  group('act that throws', () {
    scenario('captures the frame it broke on, and the failure travels', (
      s,
    ) async {
      await s.pumpWidget(_Board(ValueNotifier('Empty')));
      await expectLater(
        s.act('The push is malformed', () => throw StateError('no payload')),
        throwsStateError,
      );
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'act']);
      expect(captures.last.failure, contains('no payload'));
    });
  });

  group('act awaiting the fake clock', () {
    scenario('moves the clock until the body completes', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend));
      var before = s.tester.binding.clock.now();
      var id = await s.act('The backend answers after its latency', () async {
        await Future<void>.delayed(const Duration(seconds: 2));
        backend.value = 'Order #412';
        return 412;
      }, settle: Settle.none);
      expect(id, 412);
      expect(s.visibleTexts(), contains('Order #412'));
      expect(
        s.tester.binding.clock.now().difference(before),
        const Duration(seconds: 2),
      );
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'The backend answers after its latency']);
      expect(captures.last.failure, isNull);
    });
  });

  group('act whose body calls a verb once the clock fired', () {
    // The timer's callback completes the body's future on its own stack,
    // inside the pump that fired it: resumed there, the tap would have been
    // a pump inside a pump.
    scenario('runs the verb where a verb may run', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend, action: 'Confirm'));
      // Started by the app before the act, outside the body's own zone.
      var poll = Completer<void>();
      Timer(const Duration(milliseconds: 700), poll.complete);
      await s.act('The poll answers, and the user confirms', () async {
        await poll.future;
        backend.value = 'Polled';
        await s.tap('Confirm');
      });
      expect(s.visibleTexts(), contains('Confirmed'));
    });
    tearDown(() {
      expect(shape(), [
        'pumpWidget',
        'tap',
        'The poll answers, and the user confirms',
      ]);
      expect(captures.last.failure, isNull);
    });
  });

  group('act whose body pumps the moment its delay is over', () {
    // No await between the timer and the pump: the body resumes on the
    // timer's own stack, and only a callback held until the clock stopped
    // keeps that out of the act's pump.
    scenario('pumps outside the act’s own pump', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend, action: 'Confirm'));
      await s.act('The code arrives, and is confirmed', () async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        backend.value = 'Code 1234';
        await s.tester.pump();
        await s.tap('Confirm');
      });
      expect(s.visibleTexts(), contains('Confirmed'));
    });
    tearDown(() => expect(captures.last.failure, isNull));
  });

  group('act awaiting an animation it started', () {
    scenario('pumps the frames the animation needs', (s) async {
      var key = GlobalKey<_FadeState>();
      await s.pumpWidget(_Fade(key: key));
      await s.act('The banner fades in', () async {
        await key.currentState!.controller.forward();
        await s.tap('Dismiss');
      });
      expect(key.currentState!.controller.value, 1);
      expect(key.currentState!.dismissed, isTrue);
    });
    tearDown(() => expect(captures.last.failure, isNull));
  });

  group('act whose body needs no time', () {
    scenario('moves none, whatever the clock holds', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend));
      // A clock with something on it, so only the body decides.
      var ticking = Timer.periodic(const Duration(seconds: 1), (_) {});
      var before = s.tester.binding.clock.now();
      await s.act('The cache answers at once', () async {
        await Future<void>.value();
        backend.value = 'Cached';
      }, settle: Settle.none);
      expect(s.tester.binding.clock.now(), before);
      expect(s.visibleTexts(), contains('Cached'));
      ticking.cancel();
    });
  });

  group('act with real work inside its body', () {
    scenario('waits for it rather than pumping under it', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend));
      var ticking = Timer.periodic(const Duration(seconds: 1), (_) {});
      await s.act('A file is read', () async {
        var rows = await s.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 3;
        });
        backend.value = '$rows rows';
      });
      expect(s.visibleTexts(), contains('3 rows'));
      ticking.cancel();
    });
  });

  group('act still waiting when its timeout is spent', () {
    scenario('fails the step with what the clock still held', (s) async {
      await s.pumpWidget(_Board(ValueNotifier('Empty')));
      await expectLater(
        s.act(
          'The nightly sync',
          () => Future<void>.delayed(const Duration(seconds: 30)),
        ),
        throwsA(isA<ScenarioStillWaiting>()),
      );
      // The body's timer is still the test's to fire.
      await s.tester.pump(const Duration(seconds: 30));
    });
    tearDown(() {
      var failure = captures.last.failure!;
      expect(failure, contains('"The nightly sync" was still waiting'));
      expect(failure, contains('after 10s of fake time'));
      expect(failure, contains('a 30s timer from'));
      expect(failure, contains('act_test.dart'));
      expect(failure, contains('s.act(…, timeout: …)'));
    });
  });

  group('act given longer', () {
    scenario('waits that long', (s) async {
      await s.pumpWidget(_Board(ValueNotifier('Empty')));
      await s.act(
        'The nightly sync',
        () => Future<void>.delayed(const Duration(seconds: 30)),
        timeout: const Duration(minutes: 1),
      );
    });
    tearDown(() => expect(captures.last.failure, isNull));
  });

  group('runAsync that lands something on screen', () {
    scenario('settles and captures it, without a settle by hand', (s) async {
      var backend = ValueNotifier('Empty');
      await s.pumpWidget(_Board(backend));
      var rows = await s.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        backend.value = 'Three rows';
        return 3;
      });
      expect(rows, 3);
      // The step above is the repaint. Before this verb was a step, the tree
      // still showed 'Empty' here and the site had to settle for itself.
      expect(s.visibleTexts(), contains('Three rows'));
    });
    tearDown(() => expect(shape(), ['pumpWidget', 'runAsync']));
  });

  group('runAsync that lands nothing on screen', () {
    scenario('takes no step — there is no second picture to take', (s) async {
      await s.pumpWidget(_Board(ValueNotifier('Empty')));
      var bytes = await s.runAsync(() async => [1, 2, 3]);
      expect(bytes, [1, 2, 3]);
      await s.document('receipt', bytes!, fileName: 'receipt.pdf');
    });
    // The `generatePdf` shape from the doc: the work is real, the screen did
    // not move, and the flow reads as the export and its document rather
    // than as the export, a duplicate of the export, and its document.
    tearDown(() => expect(shape(), ['pumpWidget', 'receipt']));
  });
}

class _Board extends StatelessWidget {
  const _Board(this.line, {this.action});

  final ValueNotifier<String> line;

  /// A button that writes `Confirmed` on the board, when given a label.
  final String? action;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder(
        valueListenable: line,
        builder: (context, value, _) => Column(
          children: [
            Text(value),
            if (action case var label?)
              TextButton(
                onPressed: () => line.value = 'Confirmed',
                child: Text(label),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Fade extends StatefulWidget {
  const _Fade({super.key});

  @override
  State<_Fade> createState() => _FadeState();
}

class _FadeState extends State<_Fade> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  var dismissed = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: FadeTransition(
        opacity: controller,
        child: TextButton(
          onPressed: () => setState(() => dismissed = true),
          child: const Text('Dismiss'),
        ),
      ),
    ),
  );
}
