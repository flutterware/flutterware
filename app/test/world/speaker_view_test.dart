import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/world.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/message_banner.dart';
import 'package:flutterware_app/src/world/open_world.dart';
import 'package:flutterware_app/src/world/world_files.dart';
import 'package:flutterware_app/src/world/world_focus.dart';
import 'package:flutterware_app/src/world/world_person.dart';
import 'package:flutterware_app/src/world/worlds_memory.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late OpenWorld world;
  late Map<String, WorldPerson> people;

  setUp(() {
    world = OpenWorld(
      file: const WorldFile(package: 'app', path: 'w.dart', name: 'W'),
      worktree: Directory.current.path,
      flutterSdkRoot: '',
      appRoot: '',
      entrypoints: const [],
      guests: (_) => throw StateError('nobody here starts an app'),
    );
    people = {
      'Ana': WorldPerson(
        const Person('Ana', app: Launch('Lab'), on: Studio(Devices.window)),
      ),
      'Leo': WorldPerson(const Person('Leo', app: Launch('Lab'))),
      'Mia': WorldPerson(const Person('Mia')),
    };
  });

  /// Ana in focus, Leo beside her; what the view asked for, in order.
  Future<List<String>> focusOnAna(
    WidgetTester tester, {
    required bool panel,
    Size window = const Size(1400, 800),
  }) async {
    tester.view
      ..physicalSize = window
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: PersonFocus(
          world: world,
          person: people['Ana']!,
          color: Colors.teal,
          run: null,
          reading: null,
          onRead: (_) {},
          onScale: (_, _) {},
          others: [people['Leo']!],
          colorOf: (_) => Colors.orange,
          countsOf: (_) => const {},
          onFocus: (person) => asked.add('focus $person'),
          panel: panel,
          onPanel: (shown) => asked.add(shown ? 'show panel' : 'hide panel'),
        ),
      ),
    );
    return asked;
  }

  /// How large [person]'s screen is drawn, against its own size.
  double drawnAt(WidgetTester tester, String person) {
    var screen = tester.getRect(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is PersonDevice && widget.person.name == person,
        ),
        matching: find.byType(MessageBanners),
      ),
    );
    return screen.width / deviceOf(people[person]!).width;
  }

  testWidgets('the others with an app stand beside the one in focus, and a '
      'click on one moves the focus to them', (tester) async {
    var asked = await focusOnAna(tester, panel: true);

    // Leo is drawn small; Mia has no app and is not.
    expect(drawnAt(tester, 'Leo'), lessThan(0.5));
    expect(find.text('Mia'), findsNothing);

    await tester.tap(find.byTooltip('Show Leo'));
    expect(asked, ['focus Leo']);
  });

  testWidgets('folding the panel gives the device its room, up to its own '
      'size', (tester) async {
    var asked = await focusOnAna(tester, panel: true);
    var beside = drawnAt(tester, 'Ana');
    expect(find.text('Messages'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide the panel'));
    expect(asked, ['hide panel']);

    asked = await focusOnAna(tester, panel: false);
    expect(find.text('Messages'), findsNothing);
    expect(drawnAt(tester, 'Ana'), greaterThan(beside));
    await tester.tap(find.byTooltip("Show Ana's panel"));
    expect(asked, ['show panel']);

    // A window with room to spare draws the device at its own size, no more.
    await focusOnAna(tester, panel: false, window: const Size(2400, 1400));
    expect(drawnAt(tester, 'Ana'), 1);
  });

  test('the studio remembers whether the panel was folded', () {
    var directory = Directory.systemTemp.createTempSync('worlds_memory');
    addTearDown(() => directory.deleteSync(recursive: true));

    expect(WorldsMemory(directory: directory.path).panel, isTrue);
    WorldsMemory(directory: directory.path).panel = false;
    expect(WorldsMemory(directory: directory.path).panel, isFalse);
    WorldsMemory(directory: directory.path).panel = true;
    expect(WorldsMemory(directory: directory.path).panel, isTrue);
  });
}
