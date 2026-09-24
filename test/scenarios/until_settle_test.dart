import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// `Settle.until`: the step waits for what it is about, not for the app to go
/// quiet — because data that arrives without announcing itself looks exactly
/// like an app with nothing left to do.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('a tap waits for the rows it asked for', () {
    scenario('and the step is the list, not its empty state', (s) async {
      await s.pumpWidget(_Orders(load: _later('Order #1042')));
      await s.tap('Orders', settle: Settle.until('Order #1042'));
    });
    tearDown(() {
      expect(captures.last.verb, 'tap');
      expect(captures.last.failure, isNull);
      expect(captures.last.texts, contains('Order #1042'));
      expect(captures.last.texts, isNot(contains('No orders yet')));
    });
  });

  group('an act waits for what arrives on a stream', () {
    var pushes = StreamController<String>.broadcast();
    tearDownAll(pushes.close);
    scenario('whose subscription was open long before', (s) async {
      await s.pumpWidget(_Feed(pushes.stream));
      await s.act(
        'An order placed on the other device reaches this one',
        () =>
            Timer(const Duration(seconds: 2), () => pushes.add('Order #1043')),
        settle: Settle.until('Order #1043'),
      );
    });
    tearDown(() {
      expect(captures.last.name, contains('other device'));
      expect(captures.last.texts, contains('Order #1043'));
    });
  });

  group('a target that never appears fails the step', () {
    scenario('with the screen it gave up on as the picture', (s) async {
      await s.pumpWidget(_Orders(load: Completer<String>().future));
      await expectLater(
        () => s.tap(
          'Orders',
          settle: Settle.until('Order #1042', timeout: Duration(seconds: 3)),
        ),
        throwsA(isA<ScenarioNeverAppeared>()),
      );
    });
    tearDown(() {
      expect(captures.last.verb, 'tap');
      expect(
        captures.last.failure,
        contains('"Order #1042" did not appear within 3s of fake time'),
      );
      expect(captures.last.texts, contains('Loading…'));
    });
  });
}

Future<String> _later(String row) =>
    Future.delayed(const Duration(milliseconds: 1500), () => row);

/// A list that asks for its rows after the tap that opened it, the way a
/// screen over a local database does — no request on the wire, nothing
/// announced.
class _Orders extends StatefulWidget {
  const _Orders({required this.load});

  final Future<String> load;

  @override
  State<_Orders> createState() => _OrdersState();
}

class _OrdersState extends State<_Orders> {
  Future<String>? _rows;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => setState(() {
              _rows = widget.load;
            }),
            child: const Text('Orders'),
          ),
          if (_rows case var rows?)
            FutureBuilder(
              future: rows,
              builder: (context, snapshot) => Text(snapshot.data ?? 'Loading…'),
            )
          else
            const Text('No orders yet'),
        ],
      ),
    ),
  );
}

class _Feed extends StatelessWidget {
  const _Feed(this.pushes);

  final Stream<String> pushes;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: StreamBuilder(
        stream: pushes,
        builder: (context, snapshot) => Text(snapshot.data ?? 'Nothing yet'),
      ),
    ),
  );
}
