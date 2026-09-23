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
  const _Board(this.line);

  final ValueNotifier<String> line;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder(
        valueListenable: line,
        builder: (context, value, _) => Center(child: Text(value)),
      ),
    ),
  );
}
