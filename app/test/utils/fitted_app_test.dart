import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/utils/fitted_app.dart';

/// The responsive policy in five assertions: above the minimum nothing happens,
/// below it the child still lays out at the minimum, the MediaQuery it reads
/// agrees with the box it is in, it scales rather than overflowing, and the
/// tree keeps its shape across the minimum so nothing below it is remounted.
void main() {
  const minimum = Size(1000, 800);

  /// Lays out a probe under [FittedApp] at a window of [window], and reports
  /// what the child saw.
  Future<({Size box, Size media})> mount(
    WidgetTester tester,
    Size window,
  ) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Size media;
    var probeKey = GlobalKey();
    await tester.pumpWidget(
      FittedApp(
        minimumSize: minimum,
        child: Builder(
          builder: (context) {
            media = MediaQuery.sizeOf(context);
            return SizedBox.expand(
              child: ColoredBox(color: const Color(0xFF000000), key: probeKey),
            );
          },
        ),
      ),
    );
    return (box: tester.getSize(find.byKey(probeKey)), media: media);
  }

  testWidgets('a window at the minimum is left alone', (tester) async {
    var r = await mount(tester, minimum);
    expect(r.box, minimum);
    expect(r.media, minimum);
  });

  testWidgets('a window above the minimum is left alone', (tester) async {
    var r = await mount(tester, const Size(1600, 1200));
    expect(r.box, const Size(1600, 1200));
    expect(r.media, const Size(1600, 1200));
  });

  testWidgets('a narrow window still lays out at the minimum width', (
    tester,
  ) async {
    // Width binds: 500/1000 = 0.5, against 600/800 = 0.75.
    var r = await mount(tester, const Size(500, 600));
    expect(r.box.width, minimum.width);
    // Taller than the minimum, because the window is proportionally taller —
    // the scale is uniform, so the extra height is real space, not letterbox.
    expect(r.box.height, 1200);
  });

  testWidgets('a short window still lays out at the minimum height', (
    tester,
  ) async {
    // Height binds: 400/800 = 0.5, against 1500/1000 = 1.5.
    var r = await mount(tester, const Size(1500, 400));
    expect(r.box.height, minimum.height);
    expect(r.box.width, 3000);
  });

  testWidgets('MediaQuery reports the size the child is actually laid out at', (
    tester,
  ) async {
    var r = await mount(tester, const Size(500, 600));
    expect(
      r.media,
      r.box,
      reason:
          'anything positioning itself against the viewport measures the box '
          'it is in, not the window behind the scale',
    );
  });

  testWidgets('scaling down does not overflow', (tester) async {
    await mount(tester, const Size(320, 240));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a change of minimum lands as a zoom, not a jump', (
    tester,
  ) async {
    // The shell drops the rail's share of the minimum when the rail leaves the
    // layout, which at this window is the difference between scaling and not.
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var probeKey = GlobalKey();
    Future<void> pumpMinimum(Size value) => tester.pumpWidget(
      FittedApp(
        minimumSize: value,
        child: SizedBox.expand(
          child: ColoredBox(key: probeKey, color: const Color(0xFF000000)),
        ),
      ),
    );

    await pumpMinimum(const Size(1080, 700));
    expect(
      tester.getSize(find.byKey(probeKey)).width,
      moreOrLessEquals(1080, epsilon: 0.01),
    );

    await pumpMinimum(const Size(848, 700));
    await tester.pump(const Duration(milliseconds: 50));
    var midway = tester.getSize(find.byKey(probeKey)).width;
    expect(midway, lessThan(1080));
    expect(midway, greaterThan(900), reason: 'still on its way, not arrived');

    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(probeKey)).width, 900);
  });

  testWidgets('publishes the scale, for whatever must not take it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late double published;
    await tester.pumpWidget(
      FittedApp(
        minimumSize: minimum,
        child: Builder(
          builder: (context) {
            published = AppScale.of(context);
            return const SizedBox.expand();
          },
        ),
      ),
    );

    expect(published, 0.5, reason: 'width binds: 500 of the 1000 asked for');
  });

  testWidgets('crossing the minimum keeps the child mounted', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const child = _Probe();
    Future<void> resizeTo(Size window) async {
      tester.view.physicalSize = window;
      await tester.pumpWidget(
        const FittedApp(minimumSize: minimum, child: child),
      );
    }

    await resizeTo(const Size(1600, 1200));
    var state = tester.state<_ProbeState>(find.byType(_Probe));

    await resizeTo(const Size(500, 600));
    expect(
      tester.state<_ProbeState>(find.byType(_Probe)),
      same(state),
      reason:
          'the same element, scaled — a window dragged across the minimum '
          'would otherwise rebuild everything below it from nothing',
    );

    await resizeTo(const Size(1600, 1200));
    expect(tester.state<_ProbeState>(find.byType(_Probe)), same(state));
  });
}

/// Something below [FittedApp] with state to lose.
class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
