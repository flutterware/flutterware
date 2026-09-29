import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/embedder/embedded_engine.dart';
import 'package:flutterware_app/src/embedder/input_region.dart';
import 'package:flutterware_app/src/embedder/protocol.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late _Engine engine;
  late FocusNode focus;
  setUp(() {
    engine = _Engine();
    focus = FocusNode();
  });
  tearDown(() => focus.dispose());

  /// A guest at [size], drawn at a third of it, whose events the host keeps
  /// while [keeps] says so.
  Future<Offset> stage(
    WidgetTester tester, {
    bool Function(PointerEvent event)? keeps,
  }) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 131,
          height: 284,
          child: FittedBox(
            child: SizedBox(
              width: 393,
              height: 852,
              child: EmbedderInputRegion(
                engine: engine,
                focusNode: focus,
                shouldIgnorePointer: keeps,
                // Something to hit, as the guest's texture is.
                child: const ColoredBox(color: Color(0xFFFFFFFF)),
              ),
            ),
          ),
        ),
      ),
    );
    return tester.getCenter(find.byType(EmbedderInputRegion));
  }

  testWidgets('a trackpad pan over a guest drawn at a third of its size '
      'moves it as far as the fingers went on screen', (tester) async {
    var centre = await stage(tester);
    var pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(centre));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centre, pan: const Offset(-40, 0)),
    );

    // 40 on screen is 120 of the guest's own, at its ratio of 2.
    expect(engine.pans, [const Offset(-240, 0)]);
  });

  testWidgets('a swipe the host keeps never reaches the guest, not even as '
      'a start and an end', (tester) async {
    var centre = await stage(tester, keeps: (_) => true);
    var pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(centre));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centre, pan: const Offset(-40, 0)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());

    expect(engine.phases, isEmpty);
  });

  testWidgets('a swipe the host takes over halfway still ends in the guest', (
    tester,
  ) async {
    var taken = false;
    var centre = await stage(tester, keeps: (_) => taken);
    var pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(centre));
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centre, pan: const Offset(-40, 0)),
    );
    // Two fingers that start converging: the stage's zoom now.
    taken = true;
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(centre, pan: const Offset(-40, 0), scale: 2),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());

    expect(engine.phases, [
      PointerPhase.panZoomStart,
      PointerPhase.panZoomUpdate,
      PointerPhase.panZoomEnd,
    ]);
  });
}

class _Engine extends Fake implements EmbeddedEngine {
  final phases = <PointerPhase>[];
  final pans = <Offset>[];

  @override
  double get pixelRatio => 2;

  @override
  void sendPointer({
    required PointerPhase phaseKind,
    required double x,
    required double y,
    int buttons = 0,
    double scrollDeltaX = 0,
    double scrollDeltaY = 0,
    double panX = 0,
    double panY = 0,
    double scale = 1,
    double rotation = 0,
    bool touch = false,
  }) {
    phases.add(phaseKind);
    if (phaseKind == PointerPhase.panZoomUpdate) pans.add(Offset(panX, panY));
  }
}
