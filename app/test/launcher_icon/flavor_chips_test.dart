import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/launcher_icon/model/scan.dart';
import 'package:flutterware_app/src/launcher_icon/ui/flavor_chips.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The row that says which flavors there are and which are worth opening.
void main() {
  Future<void> pump(
    WidgetTester tester,
    List<IconFlavor> flavors, {
    String? selected,
    ValueChanged<String?>? onSelect,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: FlavorChips(
          flavors: flavors,
          selected: selected,
          onSelect: onSelect,
        ),
      ),
    ),
  );

  IconFlavor flavor(String name, Set<IconFlavorSource> sources) =>
      IconFlavor(name, sources);

  testWidgets('the default leads, whatever the flavors are called', (
    tester,
  ) async {
    await pump(tester, [
      flavor('alpha', {IconFlavorSource.androidSourceSet}),
    ]);

    var texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.textSpan?.toPlainText() ?? t.data)
        .where((text) => text == 'main' || text == 'alpha')
        .toList();
    expect(texts.first, 'main');
  });

  testWidgets('the row does not call these the project’s flavors', (
    tester,
  ) async {
    // The word was a claim the panel cannot back: these names come from files,
    // and a project wiring its own Gradle source sets can share one set across
    // several flavors — or have flavors with no set of their own at all.
    await pump(tester, [
      flavor('alpha', {IconFlavorSource.androidSourceSet}),
    ]);

    expect(find.text('Icon sets'), findsOneWidget);
    expect(find.textContaining('Gradle and Xcode'), findsOneWidget);
  });

  testWidgets('a flavor with nothing generated says so on the chip', (
    tester,
  ) async {
    // Not a border treatment: the first attempt muted the label and thinned
    // the border, and in a rendering of the row it was indistinguishable from
    // the chip beside it.
    await pump(tester, [
      flavor('dev', {IconFlavorSource.config}),
      flavor('prod', IconFlavorSource.values.toSet()),
    ]);

    expect(find.textContaining('not generated'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.textContaining('not generated'))
          .textSpan!
          .toPlainText(),
      contains('dev'),
    );
    expect(find.textContaining('prod'), findsOneWidget);
    expect(
      tester.widget<Text>(find.textContaining('prod')).textSpan!.toPlainText(),
      isNot(contains('not generated')),
    );
  });

  testWidgets('every chip names the files it was discovered from', (
    tester,
  ) async {
    // Evidence on all of them, unlike the caution below, which is still only
    // on the chips that have something to caution about.
    await pump(tester, [
      flavor('whole', IconFlavorSource.values.toSet()),
      flavor('half', {
        IconFlavorSource.config,
        IconFlavorSource.androidSourceSet,
      }),
    ]);

    var messages = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message!)
        .toList();
    expect(messages, hasLength(3), reason: 'main, whole, half');
    expect(messages.first, contains('android/app/src/main/res/'));
    expect(
      messages[1],
      allOf(
        contains('android/app/src/whole/'),
        contains('AppIcon-whole.appiconset'),
        isNot(contains('falls back')),
      ),
    );
    expect(
      messages[2],
      allOf(
        contains('no AppIcon-half.appiconset'),
        contains('falls back to the unflavored set'),
      ),
    );
  });

  testWidgets('every chip goes somewhere, the default one included', (
    tester,
  ) async {
    // The row shipped as a report: it named the flavors and left the address
    // bar as the only way to open one.
    var picked = <String?>[];
    await pump(
      tester,
      [
        flavor('kiosk', {
          IconFlavorSource.androidSourceSet,
          IconFlavorSource.iosCatalog,
        }),
      ],
      selected: 'kiosk',
      onSelect: picked.add,
    );

    await tester.tap(find.textContaining('kiosk'));
    await tester.tap(find.text('main'));
    expect(picked, ['kiosk', null]);
  });

  testWidgets('an ungenerated flavor is still worth opening', (tester) async {
    var picked = <String?>[];
    await pump(tester, [
      flavor('dev', {IconFlavorSource.config}),
    ], onSelect: picked.add);

    await tester.tap(find.textContaining('dev'));
    expect(picked, ['dev']);
  });

  group('the hint', () {
    test('names the missing platform, and what happens instead', () {
      expect(
        flavorHint(
          flavor('a', {
            IconFlavorSource.config,
            IconFlavorSource.androidSourceSet,
          }),
        ),
        contains('no AppIcon-a.appiconset'),
      );
      expect(
        flavorHint(
          flavor('b', {IconFlavorSource.config, IconFlavorSource.iosCatalog}),
        ),
        contains('no android/app/src/b/'),
      );
    });

    test('says only what was found for a flavor that is entirely there', () {
      var hint = flavorHint(flavor('c', IconFlavorSource.values.toSet()))!;
      expect(hint, contains('flutter_launcher_icons-c.yaml'));
      expect(hint, isNot(contains('only')));
    });

    test('sends an unbuilt flavor to the config it does have', () {
      expect(
        flavorHint(flavor('d', {IconFlavorSource.config})),
        contains('flutter_launcher_icons-d.yaml'),
      );
    });
  });
}
