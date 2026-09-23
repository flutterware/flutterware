import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// The example project's first scenario — and the proof that a scenario is an
/// ordinary widget test: `flutter test test/scenarios` runs it with no daemon
/// and no GUI.
void main() {
  scenario('Counter', (s) async {
    await s.pumpWidget(const _CounterApp());

    await s.tap('Add');
    await s.tap('Add', shot: Shot('Counted to two'));
    expect(find.text('Count: 2'), findsOneWidget);

    await s.enterText(TextField, 'a label');
    await s.screen('Labelled');
    expect(find.text('a label'), findsOneWidget);
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
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Text('Count: $_count'),
            TextButton(
              onPressed: () => setState(() => _count++),
              child: const Text('Add'),
            ),
            const TextField(),
          ],
        ),
      ),
    );
  }
}
