import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware/plugins.dart' show Address;
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/inspect/elements_view.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// What the tree pane opens on.
///
/// It used to open on the raw tree, which in a real app is a dozen or more
/// wrappers before the first widget anybody wrote — while the drive verbs had
/// been handing agents a filtered tree since the noise filter landed. Two
/// surfaces, one app, two different shapes. These pin the pane to the agent's
/// reading, and pin the way back.
void main() {
  /// A button under the kind of scaffolding a real tree carries: each wrapper
  /// shares its only child's box, which is exactly what the filter drops.
  InspectNode fixture() => InspectTree.fromJson({
    'root': {
      'id': '',
      'type': 'MaterialApp',
      'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
      'children': [
        {
          'id': '0',
          'type': 'MouseRegion',
          'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
          'children': [
            {
              'id': '0/0',
              'type': 'GestureDetector',
              'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
              'children': [
                {
                  'id': '0/0/0',
                  'type': 'ElevatedButton',
                  'label': 'Pay',
                  // Its own box, unlike the wrappers above it — which is
                  // precisely what makes them wrappers and it a widget.
                  'layout': {'x': 0, 'y': 40, 'width': 200, 'height': 48},
                },
              ],
            },
          ],
        },
      ],
    },
  }).root!;

  Widget host(InspectNode root) {
    var address = ValueNotifier(Address(worktree: 'wt'));
    return MaterialApp(
      theme: appTheme,
      home: AddressRoot(
        address: address,
        onChanged: (a) => address.value = a,
        child: Scaffold(
          body: ElementsView(
            root: root,
            placeholder: 'nothing',
            highlight: ValueNotifier<String?>(null),
            displayRoot: '/tmp',
            readsWidgets: true,
          ),
        ),
      ),
    );
  }

  testWidgets('the wrappers are hidden, and the count says how many', (
    tester,
  ) async {
    await tester.pumpWidget(host(fixture()));
    await tester.pumpAndSettle();

    expect(find.text('ElevatedButton'), findsOneWidget);
    expect(find.text('MouseRegion'), findsNothing);
    expect(find.text('GestureDetector'), findsNothing);
    expect(find.textContaining('wrappers hidden'), findsOneWidget);
  });

  testWidgets('Show all brings them back, and the label inverts', (
    tester,
  ) async {
    await tester.pumpWidget(host(fixture()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();

    expect(find.text('MouseRegion'), findsOneWidget);
    expect(find.text('GestureDetector'), findsOneWidget);
    expect(find.textContaining('wrappers shown'), findsOneWidget);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(find.text('MouseRegion'), findsNothing);
  });

  testWidgets('a tree with nothing to drop offers no toggle at all', (
    tester,
  ) async {
    var bare = InspectTree.fromJson({
      'root': {
        'id': '',
        'type': 'ElevatedButton',
        'label': 'Pay',
        'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
      },
    }).root!;

    await tester.pumpWidget(host(bare));
    await tester.pumpAndSettle();

    expect(find.textContaining('wrappers'), findsNothing);
  });

  /// The style block, after the badge came out of it.
  ///
  /// What these pin is mostly *absence*: a value said once rather than twice,
  /// and one divider where there used to be a badge per row.
  group('the style block', () {
    /// A label written the way this app writes them — a whole `TextStyle`
    /// literal — which is the shape that produced four duplicated rows and
    /// four identical badges.
    InspectNode styled({Map<String, String>? properties}) =>
        InspectTree.fromJson({
          'root': {
            'id': '',
            'type': 'Text',
            'description': 'Text("Overview")',
            'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 20},
            'properties':
                properties ??
                {
                  'data': '"Overview"',
                  'color': '#15181D',
                  'size': '13.0',
                  'weight': '400',
                  'letterSpacing': '0.0',
                  'overflow': 'ellipsis',
                },
            'style': {
              'debugLabel':
                  '((englishLike bodyMedium 2021).merge((blackRedwoodCity '
                  'bodyMedium).apply)).merge(unknown)',
              'color': '#15181D',
              'family': '.AppleSystemUIFont',
              'size': '13.0',
              'weight': '400',
              'letterSpacing': '0.0',
              'height': '1.4x',
            },
            'inherited': {
              'debugLabel': '(englishLike bodyMedium 2021)',
              'color': '#1D1B20',
              'family': '.AppleSystemUIFont',
              'size': '14.0',
              'weight': '400',
              'letterSpacing': '0.3',
              'height': '1.4x',
            },
            'styleReplaces': false,
          },
        }).root!;

    /// The same label, but the widget asked for the value the theme was
    /// already giving it.
    InspectNode redundant() => InspectTree.fromJson({
      'root': {
        'id': '',
        'type': 'Text',
        'description': 'Text("Overview")',
        'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 20},
        'properties': {'weight': '400'},
        'style': {
          'debugLabel': '(englishLike bodyMedium 2021)',
          'weight': '400',
          'size': '14.0',
        },
        'inherited': {'weight': '400', 'size': '14.0'},
        'styleReplaces': false,
      },
    }).root!;

    /// A Material ramp slot: `inherit: false`, so the ambient style was in
    /// scope and contributed nothing.
    InspectNode replaced() => InspectTree.fromJson({
      'root': {
        'id': '',
        'type': 'Text',
        'description': 'Text("Heading")',
        'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 30},
        'properties': {'size': '22.0'},
        'style': {
          'debugLabel': '(englishLike titleLarge 2021).merge(x)',
          'size': '22.0',
        },
        'inherited': {'size': '14.0'},
        'styleReplaces': true,
      },
    }).root!;

    Future<void> open(WidgetTester tester, InspectNode root) async {
      await tester.pumpWidget(host(root));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text').first);
      await tester.pumpAndSettle();
    }

    testWidgets('a value the style block shows is not repeated below it', (
      tester,
    ) async {
      await open(tester, styled());

      // Four of the widget's own properties are style fields with identical
      // values. Each used to appear in both blocks.
      for (var repeated in ['#15181D', '13.0', '400', '0.0']) {
        expect(
          find.text(repeated),
          findsOneWidget,
          reason: '$repeated was in both the style and the widget block',
        );
      }
      // What is genuinely the widget's own configuration stays.
      expect(find.text('ellipsis'), findsOneWidget);
      expect(find.text('"Overview"'), findsOneWidget);
    });

    testWidgets('what the widget set and what it inherited are divided once', (
      tester,
    ) async {
      await open(tester, styled());

      expect(find.text('set here'), findsNothing);
      expect(find.text('inherited'), findsOneWidget);
    });

    testWidgets('a widget that set everything gets no divider', (tester) async {
      await open(
        tester,
        styled(
          properties: {
            'color': '#15181D',
            'family': '.AppleSystemUIFont',
            'size': '13.0',
            'weight': '400',
            'letterSpacing': '0.0',
            'height': '1.4x',
          },
        ),
      );

      // The case the badge could not express: it fired on every row and so
      // said nothing. Here the missing rule is the answer.
      expect(find.text('inherited'), findsNothing);
      expect(find.text('.AppleSystemUIFont'), findsOneWidget);
    });

    testWidgets('the origin is the slot name, not the whole chain', (
      tester,
    ) async {
      await open(tester, styled());

      expect(find.text('bodyMedium'), findsOneWidget);
      expect(find.textContaining('englishLike'), findsNothing);
    });

    testWidgets('a style nobody labelled says so', (tester) async {
      await open(
        tester,
        InspectTree.fromJson({
          'root': {
            'id': '',
            'type': 'Text',
            'description': 'Text("x")',
            'layout': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
            'style': {'size': '11.0'},
          },
        }).root!,
      );

      expect(find.textContaining('nothing labelled it'), findsOneWidget);
    });

    testWidgets('a value the renderer overruled is spelled as an arrow', (
      tester,
    ) async {
      await open(
        tester,
        InspectTree.fromJson({
          'root': {
            'id': '',
            'type': 'Text',
            'description': 'Text("x")',
            'layout': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
            // The OS bold-text setting: the widget asked for 300 and the
            // glyphs came out at 700. The rarest row in the pane and the most
            // valuable one, so it must not be subtracted away.
            'properties': {'weight': '300'},
            'style': {'weight': '700'},
          },
        }).root!,
      );

      expect(find.text('300 → 700'), findsOneWidget);
    });

    testWidgets('the origin opens the merge, and the merge has three columns', (
      tester,
    ) async {
      await open(tester, styled());
      await tester.tap(find.text('bodyMedium'));
      await tester.pumpAndSettle();

      expect(find.text('inherited'), findsWidgets);
      expect(find.text('this widget'), findsOneWidget);
      expect(find.text('renders as'), findsOneWidget);
      // The whole chain, which the row itself deliberately does not show.
      expect(find.textContaining('englishLike'), findsOneWidget);
    });

    testWidgets('the merge shows what the theme offered for a field the '
        'widget overrode', (tester) async {
      await open(tester, styled());
      await tester.tap(find.text('bodyMedium'));
      await tester.pumpAndSettle();

      // The one thing neither the pane nor the other two maps can say: the
      // ambient value for a field the widget went on to set.
      expect(find.text('14.0'), findsOneWidget);
      expect(find.text('#1D1B20'), findsOneWidget);
    });

    testWidgets('an override that changed nothing is called out', (
      tester,
    ) async {
      await open(tester, redundant());
      await tester.tap(find.text('bodyMedium'));
      await tester.pumpAndSettle();

      expect(find.text('same'), findsOneWidget);
    });

    testWidgets('a replaced ambient style says so rather than posing as '
        'inherited', (tester) async {
      await open(tester, replaced());
      await tester.tap(find.text('titleLarge'));
      await tester.pumpAndSettle();

      expect(find.textContaining('replaced what'), findsOneWidget);
      expect(find.text('was in scope'), findsOneWidget);
      expect(find.text('inherited'), findsNothing);
    });

    testWidgets('a reading with no ambient style offers no popover at all', (
      tester,
    ) async {
      await open(
        tester,
        InspectTree.fromJson({
          'root': {
            'id': '',
            'type': 'Text',
            'description': 'Text("x")',
            'layout': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
            'style': {'size': '11.0', 'debugLabel': '(a bodyMedium 2021)'},
          },
        }).root!,
      );
      await tester.tap(find.text('bodyMedium'));
      await tester.pumpAndSettle();

      // An older artifact, or a reader that never had one. The card would be
      // one column of what the pane already shows.
      expect(find.text('renders as'), findsNothing);
    });

    testWidgets('a widget that set nothing gets one heading, not two rules', (
      tester,
    ) async {
      await open(
        tester,
        InspectTree.fromJson({
          'root': {
            'id': '',
            'type': 'Text',
            'description': 'Text("Count: 0")',
            'layout': {'x': 0, 'y': 0, 'width': 60, 'height': 20},
            'properties': {'data': '"Count: 0"'},
            'style': {
              'debugLabel': '(englishLike bodyMedium 2021)',
              'size': '14.0',
              'weight': '400',
            },
            'inherited': 'same',
          },
        }).root!,
      );

      // Everything is inherited, so the rule had nothing above it and sat
      // directly under the block header — two micro headings four pixels
      // apart. The header carries it instead.
      expect(find.text('style · all inherited'), findsOneWidget);
      expect(find.text('style'), findsNothing);
      expect(find.text('inherited'), findsNothing);
      expect(find.text('14.0'), findsWidgets);
    });

    testWidgets('a split still gets the plain header and the rule', (
      tester,
    ) async {
      await open(tester, styled());

      expect(find.text('style'), findsOneWidget);
      expect(find.text('inherited'), findsOneWidget);
      expect(find.text('style · all inherited'), findsNothing);
    });

    testWidgets('the sentinel still opens the merge card', (tester) async {
      await open(
        tester,
        InspectTree.fromJson({
          'root': {
            'id': '',
            'type': 'Text',
            'description': 'Text("Count: 0")',
            'layout': {'x': 0, 'y': 0, 'width': 60, 'height': 20},
            'style': {
              'debugLabel': '(englishLike bodyMedium 2021)',
              'size': '14.0',
            },
            'inherited': 'same',
          },
        }).root!,
      );
      await tester.tap(find.text('bodyMedium'));
      await tester.pumpAndSettle();

      // `"same"` means captured, so the card opens — unlike an absent
      // `inherited`, which means nobody looked.
      expect(find.text('renders as'), findsOneWidget);
    });
  });
}
