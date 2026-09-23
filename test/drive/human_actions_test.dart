import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/human_actions.dart';

/// The guest-side recorder: real pointer events in, named `actor: human`
/// records out. Injected agent gestures arrive on the same global route, so
/// the suppression flag is load-bearing — without it every drive tap would
/// journal twice.
void main() {
  testWidgets('a tap is recorded with the nearest nameable widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: TextButton(onPressed: () {}, child: const Text('Pay')),
        ),
      ),
    );
    var actions = HumanActions()..install();

    await tester.tap(find.text('Pay'));

    var taken = actions.take();
    expect(taken, hasLength(1));
    expect(taken.single['verb'], 'tap');
    expect(taken.single['target'], '"Pay"');
    expect(actions.take(), isEmpty, reason: 'a take clears the buffer');
  });

  testWidgets('a keyed but textless control is named by its key', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: IconButton(
            key: const ValueKey('cart'),
            onPressed: () {},
            icon: const Icon(Icons.shopping_cart),
          ),
        ),
      ),
    );
    var actions = HumanActions()..install();

    await tester.tap(find.byKey(const ValueKey('cart')));

    expect(actions.take().single['target'], "key 'cart'");
  });

  testWidgets('a drag is not a tap, and records nothing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(children: [for (var i = 0; i < 50; i++) Text('Row $i')]),
      ),
    );
    var actions = HumanActions()..install();

    await tester.drag(find.text('Row 3'), const Offset(0, -200));

    expect(actions.take(), isEmpty);
  });

  testWidgets('suppressed events — an agent verb in flight — are dropped', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: TextButton(onPressed: () {}, child: const Text('Pay')),
        ),
      ),
    );
    var actions = HumanActions()..install();

    actions.suppress = true;
    await tester.tap(find.text('Pay'));
    actions.suppress = false;

    expect(actions.take(), isEmpty);
  });

  testWidgets('past the cap, the drop is visible rather than silent', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: TextButton(onPressed: () {}, child: const Text('Pay')),
        ),
      ),
    );
    var actions = HumanActions(cap: 2)..install();

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Pay'));
    }

    var taken = actions.take();
    expect(taken, hasLength(3));
    expect(taken.last['verb'], 'dropped');
    expect(taken.last['target'], contains('2 more'));
    expect(actions.take(), isEmpty, reason: 'the drop count resets too');
  });

  testWidgets('nothing nameable falls back to the position', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ColoredBox(color: Colors.white)),
    );
    var actions = HumanActions()..install();

    await tester.tapAt(const Offset(11, 22));

    expect(actions.take().single['target'], 'at (11, 22)');
  });

  testWidgets('a held press is a longPress', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: TextButton(onPressed: () {}, child: const Text('Pay')),
        ),
      ),
    );
    var actions = HumanActions()..install();

    // Explicit timestamps: the recorder reads the engine's event clock, and
    // test-injected events default to zero.
    var gesture = await tester.startGesture(tester.getCenter(find.text('Pay')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up(
      timeStamp: kLongPressTimeout + const Duration(milliseconds: 100),
    );

    expect(actions.take().single['verb'], 'longPress');
  });

  group('the burst window', () {
    Future<void> pumpRows(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var label in ['One', 'Two', 'Three'])
              TextButton(onPressed: () {}, child: Text(label)),
          ],
        ),
      ),
    );

    HumanCapture shot([String base64 = 'xxxxxxxx']) =>
        HumanCapture(picture: {'base64': base64}, texts: const ['Pay']);

    /// Past the window, then far enough for the capture's own futures.
    Future<void> closeBurst(WidgetTester tester) async {
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
    }

    testWidgets('a burst of taps takes one picture, on its last tap', (
      tester,
    ) async {
      await pumpRows(tester);
      var taken = 0;
      var actions = HumanActions(
        capture: () async {
          taken++;
          return shot();
        },
      )..install();
      addTearDown(actions.dispose);

      await tester.tap(find.text('One'));
      await tester.tap(find.text('Two'));
      await tester.tap(find.text('Three'));
      await closeBurst(tester);

      expect(taken, 1, reason: 'one picture for the burst, not one per tap');
      var records = actions.take();
      expect(records, hasLength(3), reason: 'every tap still lands');
      expect(records[0]['screenshot'], isNull);
      expect(records[1]['screenshot'], isNull);
      expect(
        records[2]['screenshot'],
        isNotNull,
        reason: 'the frame belongs to the gesture that ended the burst',
      );
      expect(records[2]['texts'], ['Pay']);
    });

    testWidgets('a picture is abandoned when a newer tap beats it home', (
      tester,
    ) async {
      await pumpRows(tester);
      var pending = Completer<HumanCapture?>();
      var calls = 0;
      var actions = HumanActions(
        capture: () => calls++ == 0 ? pending.future : Future.value(null),
      )..install();
      addTearDown(actions.dispose);

      await tester.tap(find.text('One'));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      // The capture is in flight, and the human keeps going.
      await tester.tap(find.text('Two'));
      pending.complete(shot());
      await closeBurst(tester);

      expect(
        actions.take().map((e) => e['screenshot']),
        everyElement(isNull),
        reason: 'that frame is not what the first tap produced',
      );
    });

    testWidgets('over budget, the oldest picture goes and its tap stays', (
      tester,
    ) async {
      await pumpRows(tester);
      var actions = HumanActions(pictureBytes: 10, capture: () async => shot())
        ..install();
      addTearDown(actions.dispose);

      await tester.tap(find.text('One'));
      await closeBurst(tester);
      await tester.tap(find.text('Two'));
      await closeBurst(tester);

      var records = actions.take();
      expect(records, hasLength(2), reason: 'no gesture is dropped for bytes');
      expect(records[0]['screenshot'], isNull, reason: 'the oldest let go');
      expect(records[1]['screenshot'], isNotNull);
    });

    testWidgets('a take cancels the burst it would have photographed', (
      tester,
    ) async {
      await pumpRows(tester);
      var taken = 0;
      var actions = HumanActions(
        capture: () async {
          taken++;
          return shot();
        },
      )..install();
      addTearDown(actions.dispose);

      await tester.tap(find.text('One'));
      expect(actions.take(), hasLength(1));
      await closeBurst(tester);

      expect(taken, 0, reason: 'nothing is left for the picture to attach to');
    });
  });
}
