import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';

/// The properties leg of a node: what the widget's own diagnostics say,
/// filtered to what a detail pane's reader would keep. Measured before being
/// kept — +168µs on the shop tree's 1.5ms read, +6KB on its 37KB JSON — so
/// what these tests pin is the *filter*: the useful survive, the noise and
/// the paragraphs do not.
void main() {
  InspectTree read(WidgetTester tester) => GuestInspector(
    rootOf: () => tester.binding.rootElement,
    entryIdOf: () => null,
  ).read();

  InspectNode node(InspectTree tree, String type) =>
      tree.nodes.firstWhere((n) => n.type == type);

  testWidgets('a widget reports what it was configured with', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Padding(
          padding: EdgeInsets.all(8),
          child: Text('Save', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    var tree = read(tester);

    expect(node(tree, 'Padding').properties['padding'], 'EdgeInsets.all(8.0)');
    var text = node(tree, 'Text').properties;
    expect(text['data'], '"Save"');
    expect(text['maxLines'], '1');
    expect(text['overflow'], 'ellipsis');
    expect(
      text.containsKey('inherit'),
      isFalse,
      reason: 'the resting state of every style distinguishes no node',
    );
  });

  testWidgets('a paragraph of a value is elided, not carried', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Tooltip(
          message: 'a' * 400,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    var tree = read(tester);

    var message = node(tree, 'Tooltip').properties['message']!;
    expect(message.length, lessThan(100));
    expect(message, contains('…'));
  });

  testWidgets('the flag survives the wire', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Padding(padding: EdgeInsets.all(8))),
    );
    var decoded = InspectTree.fromJson(read(tester).toJson());
    expect(
      node(decoded, 'Padding').properties['padding'],
      'EdgeInsets.all(8.0)',
    );
  });

  /// The other half of a node's answer about text: not what the author wrote,
  /// but what the glyphs were painted with. The two are different maps because
  /// they are different questions, and the tests below are mostly about
  /// keeping them from being mistaken for one another again.
  group('the resolved text style', () {
    testWidgets('a text nobody styled still says what it draws', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          // Under a `Scaffold`, because that is where a `Text` picks up the
          // theme's body style — outside a `Material` it falls back to
          // `WidgetsApp`'s 48pt debug default, which is a real answer about
          // an unreal screen.
          home: const Scaffold(body: Text('Save')),
        ),
      );
      var text = node(read(tester), 'Text');

      expect(
        text.properties.keys,
        ['data'],
        reason:
            'the widget was given no style, so it has nothing to report — '
            'which is what made the type ramp blind to most of a themed app',
      );
      expect(text.textStyle['size'], '14.0');
      expect(text.textStyle['weight'], '400');
      expect(text.textStyle['family'], 'Roboto');
      expect(text.textStyle['color'], startsWith('#'));
    });

    testWidgets('the provenance names the slot it came from', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Builder(
            builder: (context) =>
                Text('Heading', style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
      );
      // Loosely: Material writes this string and its wording is not ours to
      // pin. That it carries the slot name is the whole of the promise.
      expect(
        node(read(tester), 'Text').textStyle['debugLabel'],
        contains('titleLarge'),
      );
    });

    testWidgets('an override lands in both maps, so the two can be diffed', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Big', style: TextStyle(fontSize: 30))),
        ),
      );
      var text = node(read(tester), 'Text');

      // The pane marks a resolved row "set here" when the widget's own
      // properties account for it, so the size must be in both and the family
      // — which came from the theme — in only one.
      expect(text.properties['size'], '30.0');
      expect(text.textStyle['size'], '30.0');
      expect(text.properties.containsKey('family'), isFalse);
      expect(text.textStyle['family'], isNotNull);
    });

    testWidgets('a wrapper does not adopt the style of a text buried in it', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(8),
              child: Column(children: [SizedBox(height: 40), Text('deep')]),
            ),
          ),
        ),
      );
      var tree = read(tester);

      expect(node(tree, 'Text').textStyle, isNotEmpty);
      expect(
        node(tree, 'Scaffold').textStyle,
        isEmpty,
        reason:
            'the descend is bounded, or every container would report '
            'whatever text happens to be nearest its root',
      );
      expect(node(tree, 'Column').textStyle, isEmpty);
    });

    testWidgets('the type ramp counts what the theme styled', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(children: [Text('one'), Text('two'), Text('three')]),
          ),
        ),
      );
      var styles = read(tester).styles();

      // Three texts, one style, and before the resolved style existed this
      // was an empty table: none of them was styled by hand, so none of them
      // had a `size` or a `color` to bucket on.
      expect(styles, hasLength(1));
      expect(styles.single.count, 3);
      expect(styles.single.size, '14.0');
      expect(styles.single.color, startsWith('#'));
    });

    testWidgets('an icon reports its size and colour too', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Icon(Icons.star, size: 18, color: Color(0xFF00FF00)),
          ),
        ),
      );
      // Free: an `Icon` is a `RichText` over an icon font, so it arrives by
      // the same route. It stays out of the *ramp* — that gate is words.
      var icon = node(read(tester), 'Icon');
      expect(icon.textStyle['size'], '18.0');
      expect(icon.textStyle['color'], '#00FF00');
      expect(read(tester).styles(), isEmpty);
    });

    testWidgets('the fields no reader acts on are cut', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Save'))),
      );
      var style = node(read(tester), 'Text').textStyle;

      // Every resolved style in a Material app carries these, so a row each
      // is three lines of `alphabetic` / `even` / a colour-and-the-word-none
      // on every text node of every read. Seen in the pane before being cut.
      expect(style.containsKey('baseline'), isFalse);
      expect(style.containsKey('leadingDistribution'), isFalse);
      expect(style.containsKey('inherit'), isFalse);
      expect(
        style.containsKey('decoration'),
        isFalse,
        reason: 'a decoration that decorates nothing, spelled as a colour',
      );
    });

    testWidgets('a decoration that draws is kept', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text(
              'Save',
              style: TextStyle(decoration: TextDecoration.underline),
            ),
          ),
        ),
      );
      expect(
        node(read(tester), 'Text').textStyle['decoration'],
        contains('underline'),
      );
    });

    testWidgets('it survives both spellings of the wire', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Save'))),
      );
      var tree = read(tester);
      for (var compact in [false, true]) {
        var decoded = InspectTree.fromJson(tree.toJson(compact: compact));
        expect(
          node(decoded, 'Text').textStyle['size'],
          '14.0',
          reason: 'compact: $compact',
        );
      }
    });

    testWidgets('the one-line spelling is the four fields worth scanning', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Save'))),
      );
      expect(
        node(read(tester), 'Text').styleLine,
        matches(RegExp(r'^14\.0/400 #[0-9A-F]{6} Roboto$')),
      );
      expect(node(read(tester), 'MaterialApp').styleLine, isNull);
    });

    testWidgets('the ambient style is captured beside the resolved one', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const Scaffold(
            body: Text('Save', style: TextStyle(fontSize: 13)),
          ),
        ),
      );
      var text = node(read(tester), 'Text');

      // The third column: what the theme was offering for a field the widget
      // went on to override. Neither of the other two maps can say it.
      expect(text.textStyle['size'], '13.0');
      expect(text.properties['size'], '13.0');
      expect(text.inheritedStyle['size'], '14.0');
      expect(text.styleReplacesInherited, isFalse);
    });

    testWidgets('a theme slot replaces what was in scope, and says so', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Builder(
              builder: (context) => Text(
                'Heading',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        ),
      );
      var text = node(read(tester), 'Text');

      // Material's ramp entries are `inherit: false`, so the ambient
      // bodyMedium was in scope and contributed nothing. A pane that showed it
      // as inherited would be confidently wrong.
      expect(text.styleReplacesInherited, isTrue);
      expect(text.inheritedStyle['size'], '14.0');
      expect(text.textStyle['size'], '22.0');
    });

    testWidgets('a widget that builds its own paragraph says nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Icon(Icons.star, size: 18))),
      );
      // An `Icon` publishes no style to ask, so the flag stays null rather
      // than guessing — the same tri-state rule as `selected`.
      expect(node(read(tester), 'Icon').styleReplacesInherited, isNull);
    });

    testWidgets('nothing that draws no words pays for any of it', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Padding(padding: EdgeInsets.all(8))),
        ),
      );
      var padding = node(read(tester), 'Padding');
      expect(padding.textStyle, isEmpty);
      expect(padding.inheritedStyle, isEmpty);
      expect(padding.styleReplacesInherited, isNull);
    });

    testWidgets('a style dump no longer starves the widget’s own config', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Builder(
              builder: (context) => Text(
                'Heading',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ),
        ),
      );
      var text = node(read(tester), 'Text');

      // Fifteen info-level properties, eleven of them style fields. Against a
      // flat cap of twelve these two fell off the end — and they are exactly
      // the rows the pane's `widget` block exists to show.
      expect(text.properties['overflow'], 'ellipsis');
      expect(text.properties['maxLines'], '2');
    });

    testWidgets('both new fields survive both spellings of the wire', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Builder(
              builder: (context) => Text(
                'Heading',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        ),
      );
      var tree = read(tester);
      for (var compact in [false, true]) {
        var decoded = InspectTree.fromJson(tree.toJson(compact: compact));
        var text = node(decoded, 'Text');
        expect(
          text.inheritedStyle['size'],
          '14.0',
          reason: 'compact: $compact',
        );
        expect(
          text.styleReplacesInherited,
          isTrue,
          reason: 'compact: $compact',
        );
      }
    });
  });
}
