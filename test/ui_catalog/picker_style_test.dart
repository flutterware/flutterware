import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/axes.dart';
import 'package:flutterware/src/ui_catalog/axes_controls.dart';
import 'package:flutterware/src/ui_catalog/axis.dart';
import 'package:flutterware/src/ui_catalog/guest.dart';
import 'package:flutterware/src/ui_catalog/knob.dart';
import 'package:flutterware/src/ui_catalog/knobs.dart';
import 'package:flutterware/src/ui_catalog/knobs_editor.dart';
import 'package:flutterware/src/ui_catalog/toolbar.dart';

enum _Theme { light, dark }

const _themes = {'Light': _Theme.light, 'Dark': _Theme.dark};

/// Seven: past [maxSegments], so a segmented request draws a dropdown.
const _locales = {
  'en': 'en',
  'fr': 'fr',
  'de': 'de',
  'nl': 'nl',
  'es': 'es',
  'it': 'it',
  'pt': 'pt',
};

/// `style: PickerStyle.segmented`, from the declaration to both renderers
/// that run in the same process as it: the in-app catalog's knob editor and
/// its top bar. The studio's are in `app/test/previews/catalog_view_test.dart`.
void main() {
  group('on the wire', () {
    const segmented = KnobDescriptor(
      name: 'theme',
      kind: KnobKind.picker,
      value: 'Light',
      defaultValue: 'Light',
      options: ['Light', 'Dark'],
      style: PickerStyle.segmented,
    );

    test('a segmented picker says so, and reads back the same', () {
      var json = segmented.toJson();
      expect(json['style'], 'segmented');
      var read = KnobDescriptor.fromJson(json);
      expect(read.style, PickerStyle.segmented);
      expect(read.options, ['Light', 'Dark']);
    });

    test('the default is written as nothing at all', () {
      // So a report from a picker that never asked is byte-for-byte what it
      // was before there was a style to ask for.
      var json = KnobDescriptor(
        name: 'flavor',
        kind: KnobKind.picker,
        value: 'Dev',
        defaultValue: 'Dev',
        options: const ['Dev', 'Prod'],
      ).toJson();
      expect(json.containsKey('style'), isFalse);
    });

    test('absent, or a style this host does not know, is a dropdown', () {
      // Absent is a guest from before the field; unknown is one from after a
      // style this host has never heard of.
      var json = segmented.toJson()..remove('style');
      expect(KnobDescriptor.fromJson(json).style, PickerStyle.dropdown);
      json['style'] = 'carousel';
      expect(KnobDescriptor.fromJson(json).style, PickerStyle.dropdown);
    });

    test('a value chosen in the panel keeps the style', () {
      expect(segmented.withValue('Dark').style, PickerStyle.segmented);
    });
  });

  test('segments only while the options fit, a dropdown past that', () {
    expect(drawsSegments(PickerStyle.segmented, 2), isTrue);
    expect(drawsSegments(PickerStyle.segmented, maxSegments), isTrue);
    expect(drawsSegments(PickerStyle.segmented, maxSegments + 1), isFalse);
    expect(drawsSegments(PickerStyle.dropdown, 2), isFalse);
  });

  group('declared', () {
    test('unhosted, a knob answers its default whatever its style', () {
      expect(
        Knobs.unanswered.picker(
          'theme',
          _themes,
          _Theme.dark,
          style: PickerStyle.segmented,
        ),
        _Theme.dark,
      );
    });

    test('a knob reports the style it was declared with', () {
      var knobs = CatalogKnobs.instance
        ..resetFor('picker-style-${DateTime.now().microsecondsSinceEpoch}');
      knobs.editable.picker(
        'theme',
        _themes,
        _Theme.light,
        style: PickerStyle.segmented,
      );
      knobs.editable.picker('flavor', {'Dev': 0, 'Prod': 1}, 0);

      var report = knobs.describe().knobs;
      expect(report.map((k) => k.style), [
        PickerStyle.segmented,
        PickerStyle.dropdown,
      ]);
    });

    test('an axis reports the style it was declared with', () {
      var catalog = CatalogAxes.instance
        ..resetFor('picker-style-${DateTime.now().microsecondsSinceEpoch}');
      catalog
          .beginShell('style')
          .picker('theme', _themes, _Theme.light, style: PickerStyle.segmented);

      var report = AxisReport.fromJson(catalog.describe().toJson());
      expect(report.axes.single.style, PickerStyle.segmented);
    });
  });

  group('the knob editor', () {
    // Whatever the type argument inference gave it: the editor's dropdown is
    // built through the raw `PickerKnob`, so it is not the one written here.
    var dropdowns = find.byWidgetPredicate((w) => w is DropdownButton);

    Future<EditableKnobs> pumpEditor(
      WidgetTester tester,
      Object? Function(EditableKnobs) declare,
    ) async {
      var knobs = EditableKnobs(onRefresh: () {}, onAdded: () {});
      declare(knobs);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: KnobsEditor(knobs))),
      );
      return knobs;
    }

    testWidgets('draws a segmented picker as segments, and a tap sets it', (
      tester,
    ) async {
      var knobs = await pumpEditor(
        tester,
        (knobs) => knobs.picker(
          'theme',
          _themes,
          _Theme.light,
          style: PickerStyle.segmented,
        ),
      );

      expect(find.byType(ToolbarSegmented<Object?>), findsOneWidget);
      expect(dropdowns, findsNothing);
      // Both on show, which is the whole point of asking for it.
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);

      await tester.tap(find.text('Dark'));
      expect(knobs.knobs['theme']!.value, _Theme.dark);
    });

    testWidgets('leaves an undeclared style a dropdown', (tester) async {
      await pumpEditor(
        tester,
        (knobs) => knobs.picker('theme', _themes, _Theme.light),
      );
      expect(find.byType(ToolbarSegmented<Object?>), findsNothing);
      expect(dropdowns, findsOneWidget);
    });

    testWidgets('falls back to a dropdown past five options', (tester) async {
      await pumpEditor(
        tester,
        (knobs) => knobs.picker(
          'locale',
          _locales,
          'en',
          style: PickerStyle.segmented,
        ),
      );
      expect(find.byType(ToolbarSegmented<Object?>), findsNothing);
      expect(dropdowns, findsOneWidget);
    });
  });

  group('the top bar', () {
    var entry = 0;

    setUp(() {
      CatalogAxes.instance
        ..apply({
          'app': {'theme': null},
        })
        ..resetFor('picker-style-bar-${entry++}');
    });

    testWidgets(
      'draws a segmented axis as segments, and a tap moves the shell',
      (tester) async {
        var built = <_Theme>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const AxesControls(),
                  PreviewShell(
                    'app',
                    builder: (context, axes) {
                      built.add(
                        axes.picker(
                          'theme',
                          _themes,
                          _Theme.light,
                          style: PickerStyle.segmented,
                        ),
                      );
                      return const SizedBox();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
        // One frame to declare, one for the bar to read what was declared.
        await tester.pump();

        expect(find.byType(ToolbarSegmented<String?>), findsOneWidget);
        expect(find.byType(DropdownButton<String>), findsNothing);

        await tester.tap(find.text('Dark'));
        await tester.pumpAndSettle();
        expect(built.last, _Theme.dark);
      },
    );
  });
}
