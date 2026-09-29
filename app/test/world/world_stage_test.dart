import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/world_stage.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('the stage says whose device is in view: everyone at rest, '
      'and only those a zoom leaves on screen', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var view = StageView();
    addTearDown(view.dispose);
    var drawn = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: WorldStage(
          people: const ['Ana', 'Leo', 'Mia'],
          sizeOf: (_) => const Size(100, 200),
          // Mia has no app: a card, never drawn as one.
          scales: (person) => person != 'Mia',
          labelHeight: 20,
          view: view,
          onScale: (_) {},
          onGround: () {},
          onDrawn: (people) => drawn = people,
          person: (person, scale, ignores) => const SizedBox.expand(),
        ),
      ),
    );
    expect(drawn, {'Ana', 'Leo'});

    // Zoomed on the left: Ana's device fills the stage, Leo's is past it.
    view.zoomBy(StageView.maxZoom, const Offset(-400, 0));
    await tester.pump();
    expect(drawn, {'Ana'});

    view.reset();
    await tester.pump();
    expect(drawn, {'Ana', 'Leo'});
  });
}
