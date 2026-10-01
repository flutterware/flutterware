import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_args.dart';

/// A desktop is pointed at, and a phone is touched: the verbs press with the
/// pointer of the device the scenario is staged on.
///
/// Reported by a consumer driving a desktop admin app through 53 scenarios,
/// whose pictures showed the touch half of every pointer-adaptive widget —
/// and whose films hovered as a mouse and then pressed as a finger.
void main() {
  void stageOn(Device device) => setUp(
    () => scenarioRunArgs = ScenarioRunArgs.forAssignment(
      ScenarioAssignment(device: device),
    ),
  );
  tearDown(() => scenarioRunArgs = null);

  group('on a desktop', () {
    stageOn(Devices.window);

    scenario('every press is the mouse', (s) async {
      var kinds = <String, PointerDeviceKind>{};
      await s.pumpWidget(_Pads(kinds));

      await s.tap('Tap');
      await s.tapAt(s.tester.getCenter(find.text('Tap at')));
      await s.longPress('Long press');
      await s.doubleTap('Double tap');
      await s.drag('Drag', const Offset(0, 60));
      await s.drag(
        'Timed drag',
        const Offset(0, 60),
        duration: const Duration(milliseconds: 300),
      );

      expect(kinds, {
        'Tap': PointerDeviceKind.mouse,
        'Tap at': PointerDeviceKind.mouse,
        'Long press': PointerDeviceKind.mouse,
        'Double tap': PointerDeviceKind.mouse,
        'Drag': PointerDeviceKind.mouse,
        'Timed drag': PointerDeviceKind.mouse,
      });
    });

    // What a finger never leaves behind: the mouse stays where it clicked, so
    // the control it clicked is hovered in the picture that follows.
    scenario('a clicked control is still hovered after the click', (s) async {
      var hovered = false;
      await s.pumpWidget(
        _app(
          TextButton(
            onPressed: () {},
            onHover: (value) => hovered = value,
            child: const Text('Save'),
          ),
        ),
      );

      await s.tap('Save');

      expect(hovered, isTrue);
    });

    // The same gestures as their touch twins, delivered by a mouse.
    scenario('each gesture still lands', (s) async {
      var taps = 0;
      var holds = 0;
      var doubles = 0;
      var value = 0.0;
      await s.pumpWidget(
        _app(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(onTap: () => taps++, child: const Text('Tap')),
              GestureDetector(
                onLongPress: () => holds++,
                child: const Text('Hold'),
              ),
              GestureDetector(
                onDoubleTap: () => doubles++,
                child: const Text('Twice'),
              ),
              StatefulBuilder(
                builder: (context, setState) => SizedBox(
                  width: 400,
                  child: Slider(
                    value: value,
                    onChanged: (v) => setState(() => value = v),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      await s.tap('Tap');
      await s.longPress('Hold');
      await s.doubleTap('Twice');
      await s.drag(Slider, const Offset(150, 0));

      expect((taps, holds, doubles), (1, 1, 1));
      expect(value, greaterThan(0.5));
    });

    // Faithful to the desktop, and the one place that bites: Flutter's
    // default scroll behavior leaves the mouse out of the devices that drag a
    // list. The wheel scrolls it, and `scrollTo` still walks it.
    scenario('a drag does not scroll a list, and the wheel does', (s) async {
      var controller = ScrollController();
      addTearDown(controller.dispose);
      await s.pumpWidget(_List(controller));

      await s.drag(ListView, const Offset(0, -300));
      expect(controller.offset, 0);

      await s.scroll(ListView, const Offset(0, 300));
      expect(controller.offset, 300);

      await s.scrollTo('Row 60');
      expect(find.text('Row 60'), findsOneWidget);
    });
  });

  group('on a phone', () {
    stageOn(Devices.iphone16);

    scenario('every press is a finger', (s) async {
      var kinds = <String, PointerDeviceKind>{};
      await s.pumpWidget(_Pads(kinds));

      await s.tap('Tap');
      await s.longPress('Long press');
      await s.drag('Drag', const Offset(0, 60));

      expect(kinds, {
        'Tap': PointerDeviceKind.touch,
        'Long press': PointerDeviceKind.touch,
        'Drag': PointerDeviceKind.touch,
      });
    });
  });

  // A run staged on nothing — a bare `flutter test` with no profile — is what
  // `flutter_test` itself would do: a finger.
  scenario('staged on nothing, a press is a finger', (s) async {
    var kinds = <String, PointerDeviceKind>{};
    await s.pumpWidget(_Pads(kinds));

    await s.tap('Tap');

    expect(kinds, {'Tap': PointerDeviceKind.touch});
  });
}

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// A column of labelled pads, each writing down the kind of pointer that
/// pressed it.
class _Pads extends StatelessWidget {
  const _Pads(this.kinds);

  final Map<String, PointerDeviceKind> kinds;

  @override
  Widget build(BuildContext context) => _app(
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var label in [
          'Tap',
          'Tap at',
          'Long press',
          'Double tap',
          'Drag',
          'Timed drag',
        ])
          Listener(
            onPointerDown: (event) => kinds[label] = event.kind,
            child: SizedBox(height: 80, child: Center(child: Text(label))),
          ),
      ],
    ),
  );
}

class _List extends StatelessWidget {
  const _List(this.controller);

  final ScrollController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 200,
        itemExtent: 50,
        itemBuilder: (_, i) => Text('Row $i'),
      ),
    ),
  );
}
