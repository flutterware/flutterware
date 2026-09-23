import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/inspect/pick_region.dart';

/// The picker grammar, tested once for both hosts: sweep previews, click
/// commits and disarms, esc leaves — the contract the catalog and the step
/// page each used to carry a private copy of.
void main() {
  testWidgets('a sweep previews, leaving clears', (tester) async {
    var log = _Log();
    await tester.pumpWidget(_host(log));

    var gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(SizedBox)));
    await tester.pump();

    expect(log.swept, isNotEmpty);
    expect(log.cleared, 0);

    await gesture.moveTo(const Offset(-20, -20));
    await tester.pump();
    expect(log.cleared, greaterThan(0));
  });

  testWidgets('a click commits at the point, then disarms and clears', (
    tester,
  ) async {
    var log = _Log();
    await tester.pumpWidget(_host(log));

    await tester.tapAt(tester.getCenter(find.byType(SizedBox)));
    await tester.pump();

    expect(log.picked, hasLength(1));
    expect(log.disarmed, 1, reason: 'one pick per arming');
    expect(log.cleared, greaterThan(0));
  });

  testWidgets('esc leaves the mode without picking', (tester) async {
    var log = _Log();
    await tester.pumpWidget(_host(log));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(log.picked, isEmpty);
    expect(log.disarmed, 1);
    expect(log.cleared, greaterThan(0));
  });
}

class _Log {
  final swept = <Offset>[];
  final picked = <Offset>[];
  var cleared = 0;
  var disarmed = 0;
}

Widget _host(_Log log) => MaterialApp(
  home: Center(
    child: InspectPickRegion(
      onSweep: log.swept.add,
      onClear: () => log.cleared++,
      onPick: log.picked.add,
      onDisarm: () => log.disarmed++,
      child: const SizedBox(width: 100, height: 100),
    ),
  ),
);
