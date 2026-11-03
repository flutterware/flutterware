import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/world.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/message_banner.dart';
import 'package:flutterware_app/src/world/open_world.dart';
import 'package:flutterware_app/src/world/world_files.dart';
import 'package:flutterware_app/src/world/world_person.dart';
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

  testWidgets('a phone and a window on one stage show their screens at one '
      'scale', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var view = StageView();
    addTearDown(view.dispose);
    var world = OpenWorld(
      file: const WorldFile(package: 'app', path: 'w.dart', name: 'W'),
      worktree: Directory.current.path,
      flutterSdkRoot: '',
      appRoot: '',
      entrypoints: const [],
      guests: (_) => throw StateError('nobody here starts an app'),
    );
    var people = {
      'Leo': WorldPerson(const Person('Leo', app: Launch('Lab'))),
      'Ana': WorldPerson(
        const Person('Ana', app: Launch('Lab'), on: Studio(Devices.window)),
      ),
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: WorldStage(
          people: people.keys.toList(),
          sizeOf: (name) => personSize(people[name]!),
          scales: (_) => true,
          labelHeight: 0,
          view: view,
          onScale: (_) {},
          onGround: () {},
          person: (name, scale, ignores) => ScaledBox(
            size: personSize(people[name]!),
            scale: scale,
            child: PersonDevice(
              world: world,
              person: people[name]!,
              scale: scale,
              ignores: ignores,
            ),
          ),
        ),
      ),
    );

    // The screen as it lands in the window, against its size on the device.
    Size drawnAt(String name) {
      var person = people[name]!;
      var device = deviceOf(person);
      var screen = tester.getRect(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is PersonDevice && widget.person == person,
          ),
          matching: find.byType(MessageBanners),
        ),
      );
      return Size(screen.width / device.width, screen.height / device.height);
    }

    var phone = drawnAt('Leo');
    var window = drawnAt('Ana');
    expect(phone.width, moreOrLessEquals(phone.height, epsilon: 1e-3));
    expect(phone.width, moreOrLessEquals(window.width, epsilon: 1e-3));
    expect(phone.height, moreOrLessEquals(window.height, epsilon: 1e-3));
  });
}
