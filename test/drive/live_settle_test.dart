import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/live_settle.dart';

/// What the settle counts, which is what a reply's `frames` claims.
///
/// A test binding draws a frame only when the test pumps one, so inside
/// [WidgetTester.runAsync] it is exactly the engine an iOS simulator with no
/// window is: frames enabled, frames asked for, none ever drawn.
void main() {
  testWidgets('a frame the engine never draws is unanswered, not drawn', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());

    var result = await tester.runAsync(() {
      tester.binding.scheduleFrame();
      return settleLive(
        budget: const Duration(milliseconds: 120),
        frameTimeout: const Duration(milliseconds: 30),
      );
    });

    expect(result!.frames, 0);
    expect(result.unansweredFrames, greaterThan(0));
    expect(result.settled, isFalse);
    expect(result.toJson(), containsPair('unansweredFrames', greaterThan(0)));
  });

  testWidgets('a frame the engine draws is counted as one', (tester) async {
    await tester.pumpWidget(const SizedBox());

    var result = await tester.runAsync(() {
      tester.binding.scheduleFrame();
      Timer(const Duration(milliseconds: 10), () {
        tester.binding.handleBeginFrame(Duration.zero);
        tester.binding.handleDrawFrame();
      });
      return settleLive(
        budget: const Duration(milliseconds: 500),
        frameTimeout: const Duration(milliseconds: 200),
      );
    });

    expect(result!.frames, 1);
    expect(result.unansweredFrames, 0);
    expect(result.settled, isTrue);
    expect(
      result.toJson().containsKey('unansweredFrames'),
      isFalse,
      reason: 'absent on every step that drew what it asked for',
    );
  });
}
