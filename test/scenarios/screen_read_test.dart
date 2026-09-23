import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// The tree a step carries is the tree of the frame in its picture.
///
/// A capture is held for one step so a `screen` can name it rather than take a
/// second picture of the same frame. Everything read at hand-over is therefore
/// read one verb late — which is what the tree, the semantics and the
/// translation keys were, from the day the holding landed: a step whose own
/// `texts` said `Count: 0` carried a tree saying `Count: 1`.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
    var inspector = GuestInspector(
      rootOf: () => WidgetsBinding.instance.rootElement,
      entryIdOf: () => null,
    );
    scenarioScreenReader = () => ScenarioScreenRead(tree: inspector.read());
  });
  tearDown(() {
    scenarioRunListener = null;
    scenarioScreenReader = null;
  });

  /// What the tree says the counter reads, out of the descriptions the walk
  /// mints for `Text` — the same words [ScenarioStepCapture.texts] reports.
  String? counterIn(ScenarioStepCapture capture) =>
      RegExp(r'Count: \d')
          .firstMatch('${capture.screen!.tree.toJson()}')
          ?.group(0);

  scenario('every step’s tree is the tree of its own frame', (s) async {
    await s.pumpWidget(const _CounterApp());
    await s.tap('Add');
    await s.tap('Add');
    await s.screen('two');
  });

  tearDown(() {
    expect(
      [for (var capture in captures) capture.texts.first],
      ['Count: 0', 'Count: 1', 'Count: 2'],
    );
    // The projection read at the shutter and the tree read beside it cannot
    // disagree: they are two readings of one frame.
    expect(
      [for (var capture in captures) counterIn(capture)],
      ['Count: 0', 'Count: 1', 'Count: 2'],
    );
  });
}

class _CounterApp extends StatefulWidget {
  const _CounterApp();

  @override
  State<_CounterApp> createState() => _CounterAppState();
}

class _CounterAppState extends State<_CounterApp> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Text('Count: $_count'),
          TextButton(
            onPressed: () => setState(() => _count++),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}
