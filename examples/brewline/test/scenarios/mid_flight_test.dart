import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// A flow photographed while it is still moving, and moved on by something
/// that is not a finger.
///
/// Parking mid-flight is said out loud, on both halves: the verb that gets
/// there and the name put on it. Every verb settles by default, so a `screen`
/// left on the scenario's policy would undo the `Settle.none` above it — and
/// on a screen holding an indefinite animation that is not free, since a
/// bounded settle never sees a quiet frame there and spends its whole budget,
/// which under fake time is a clock that moved.
///
/// The confirmation then arrives from the backend rather than from a button,
/// which is what `act` puts a sentence on: the screen changes, and the run
/// says why.
void main() {
  scenario('Confirming an order', (s) async {
    var backend = _Backend();
    await s.pumpWidget(_OrderApp(backend));

    await s.tap('Place order', settle: Settle.none);
    // The tap left a spinner turning, so this step reports `settled: false`
    // and the run's `unsettledCount` counts it. The name lands on the tap's
    // own frame rather than on a second picture of it — the frame count
    // cannot promise a spinner held still, but the bytes of a pump that moved
    // no clock can.
    await s.screen('Confirming', settle: Settle.none);

    await s.act('The barista confirms the order', () {
      backend.confirm('Counter 3');
    });
    expect(find.text('Counter 3'), findsOneWidget);

    await s.notification(
      'Your cappuccino is ready — counter 3',
      title: 'Brewline',
    );
  });
}

/// The half of the app that is not the widget tree — what [ScenarioTester.act]
/// exists to reach.
class _Backend extends ValueNotifier<String?> {
  _Backend() : super(null);

  void confirm(String counter) => value = counter;
}

class _OrderApp extends StatefulWidget {
  const _OrderApp(this.backend);

  final _Backend backend;

  @override
  State<_OrderApp> createState() => _OrderAppState();
}

class _OrderAppState extends State<_OrderApp> {
  var _placed = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: ValueListenableBuilder(
          valueListenable: widget.backend,
          builder: (context, confirmed, _) {
            if (confirmed != null) return Text(confirmed);
            if (_placed) return const CircularProgressIndicator();
            return TextButton(
              onPressed: () => setState(() => _placed = true),
              child: const Text('Place order'),
            );
          },
        ),
      ),
    ),
  );
}
