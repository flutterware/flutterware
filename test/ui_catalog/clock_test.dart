import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/clock.dart';

/// The clock a preview renders under. Pinned so that two pictures of one entry
/// differ only when somebody changed something.
void main() {
  test('the origin is a round, obviously-fixed instant', () {
    expect(pinnedClockOrigin.hour, 9);
    expect(pinnedClockOrigin.minute, 41);
    expect(pinnedClockOrigin.isUtc, isFalse);
  });

  test('the pin covers whatever runs inside it', () {
    var inside = withPreviewClock(() => clock.now());

    expect(inside, pinnedClockOrigin);
    expect(withPreviewClock(() => clock.now()), inside);
  });

  testWidgets('a widget reading the clock while it builds sees the pin', (
    tester,
  ) async {
    DateTime? read;
    await withPreviewClock(
      () => tester.pumpWidget(
        Builder(
          builder: (context) {
            read = clock.now();
            return const SizedBox();
          },
        ),
      ),
    );

    expect(read, pinnedClockOrigin);
  });

  // The whole reason the pin exists: two runs of one entry, separated by real
  // time, produce the same picture.
  testWidgets('two builds a day apart agree on the date', (tester) async {
    var dates = <String>[];
    Widget probe() => Builder(
      builder: (context) {
        var now = clock.now();
        dates.add(
          '${now.year}-${now.month}-${now.day} ${now.hour}:${now.minute}',
        );
        return const SizedBox();
      },
    );

    await withPreviewClock(() => tester.pumpWidget(probe()));
    await withClock(
      Clock(() => DateTime(2030, 6, 15, 22, 3)),
      () => withPreviewClock(() => tester.pumpWidget(probe())),
    );

    expect(dates, hasLength(2));
    expect(dates.first, dates.last);
  });
}
