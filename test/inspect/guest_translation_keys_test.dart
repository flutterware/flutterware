import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware/src/translations/index.dart';

/// Compiled constants, so two keys sharing a value share an object and a
/// literal in the widget below is the same object again — the case the index
/// mints a token to survive.
const catalog = <String, String>{
  'bold_greeting': 'Welcome **back**',
  'common_cancel': 'Cancel',
  'dialog_cancel': 'Cancel',
  'greeting': 'Welcome back',
  'agree_lead': 'I agree with the ',
  'agree_terms': 'Terms of Service',
};

String t(String key) => indexTranslations('app')(key, catalog[key]!);

void main() {
  InspectTree read(WidgetTester tester) => GuestInspector(
    rootOf: () => tester.binding.rootElement,
    entryIdOf: () => null,
  ).read();

  setUp(() {
    TranslationIndex.reset();
    TranslationIndex.recording = true;
  });

  tearDown(() {
    TranslationIndex.reset();
    TranslationIndex.recording = false;
    // Registered for the process rather than the scenario, so `reset` leaves
    // them alone and a test that adds one has to take it away.
    TranslationIndex.sources.clear();
  });

  /// Every occurrence on screen, as the capture writes them.
  Future<List<TranslationOccurrence>> keysOf(
    WidgetTester tester,
    Widget widget,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: widget)),
      ),
    );
    return read(tester).translationKeys();
  }

  /// The same pump, handing back the whole tree — for the unkeyed pile, which
  /// is what the suppression is about.
  Future<InspectTree> treeOf(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: widget)),
      ),
    );
    return read(tester);
  }

  testWidgets('a plain Text carries the key that produced it', (tester) async {
    var keys = await keysOf(tester, Text(t('greeting')));

    expect(keys.map((o) => o.key.key), contains('greeting'));
    expect(keys.first.key.catalog, 'app');
    expect(keys.first.layout, isNotNull, reason: 'the crop needs a box');
  });

  testWidgets('two keys with the same words are told apart', (tester) async {
    var keys = await keysOf(
      tester,
      Column(children: [Text(t('common_cancel')), Text(t('dialog_cancel'))]),
    );

    expect(
      keys.map((o) => o.key.key),
      containsAll(['common_cancel', 'dialog_cancel']),
    );
  });

  testWidgets('a literal that matches a value is not attributed', (
    tester,
  ) async {
    t('common_cancel');
    var keys = await keysOf(tester, const Text('Cancel'));

    expect(keys, isEmpty);
  });

  testWidgets('a Text.rich resolves each span, with its own range', (
    tester,
  ) async {
    var keys = await keysOf(
      tester,
      Text.rich(
        TextSpan(
          children: [
            TextSpan(text: t('agree_lead')),
            TextSpan(text: t('agree_terms')),
          ],
        ),
      ),
    );

    var found = {for (var o in keys) o.key.key: o.key};
    expect(found.keys, containsAll(['agree_lead', 'agree_terms']));
    // The second span starts where the first ends, over the paragraph's plain
    // text — which is what lets an export highlight one of the two.
    expect(found['agree_lead']!.start, 0);
    expect(found['agree_lead']!.end, catalog['agree_lead']!.length);
    expect(found['agree_terms']!.start, catalog['agree_lead']!.length);
  });

  testWidgets('text from outside every catalog is counted, not claimed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Fri, Dec 15'))),
    );
    var tree = read(tester);

    expect(tree.translationKeys(), isEmpty);
    expect(
      _anyNode(tree, (node) => node.unkeyedSpans > 0),
      isTrue,
      reason: 'a hardcoded literal is reportable, not invisible',
    );
  });

  testWidgets('an icon is not text and is neither keyed nor counted', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Icon(Icons.close))),
    );
    var tree = read(tester);

    expect(tree.translationKeys(), isEmpty);
    expect(
      _anyNode(tree, (node) => node.unkeyedSpans > 0),
      isFalse,
      reason: 'an Icon is a RichText over an icon font, in the PUA',
    );
  });

  testWidgets('one paragraph is claimed once, not once per node', (
    tester,
  ) async {
    // A `Text` builds a `RichText` and both report the same `RenderParagraph`,
    // so an undeduped walk records this key two or three times, each with a
    // different box. Measured on a real suite before the fix: 3x the spans the
    // screen actually had.
    var keys = await keysOf(tester, Text(t('greeting')));

    expect(keys.where((o) => o.key.key == 'greeting'), hasLength(1));
  });

  group('a widget that renders its own text is read off its property', () {
    /// Everything the walk cannot follow, in one widget: the source is split
    /// into fresh substrings, and the `**` never reach a glyph at all.
    ///
    /// This is the shape of every markdown package, and of anything that
    /// paints its labels with a `TextPainter` — the string the catalog handed
    /// out survives on the widget and nowhere below it.
    Widget reparsed(String source) => _Reparsing(source);

    testWidgets('the property names the key its spans lost', (tester) async {
      indexTranslationsIn<_Reparsing>((widget) => widget.source);
      var keys = await keysOf(tester, reparsed(t('bold_greeting')));

      expect(keys.map((o) => o.key.key), contains('bold_greeting'));
    });

    testWidgets('the occurrence is the whole node, with no range', (
      tester,
    ) async {
      // An offset into the source would point past the `**` at a character the
      // reader never sees, so there is deliberately no range to mis-highlight.
      indexTranslationsIn<_Reparsing>((widget) => widget.source);
      var keys = await keysOf(tester, reparsed(t('bold_greeting')));
      var found = keys.firstWhere((o) => o.key.key == 'bold_greeting');

      expect(found.key.start, isNull);
      expect(found.key.end, isNull);
      expect(found.layout, isNotNull, reason: 'the crop still needs a box');
    });

    testWidgets('the fragments underneath stop being counted as unkeyed', (
      tester,
    ) async {
      var tree = await treeOf(tester, reparsed(t('bold_greeting')));
      expect(
        tree.unkeyedText().map((u) => u.text),
        contains('Welcome '),
        reason: 'without a source the reparsed pieces are all we can see',
      );

      indexTranslationsIn<_Reparsing>((widget) => widget.source);
      tree = await treeOf(tester, reparsed(t('bold_greeting')));

      expect(tree.unkeyedText(), isEmpty);
    });

    testWidgets('a key below a claimed node is still its own fact', (
      tester,
    ) async {
      // Suppressing the debris must not suppress a second read. A widget with
      // a text property *and* children is ordinary, and the children's keys
      // came from their own lookups.
      indexTranslationsIn<_Reparsing>((widget) => widget.source);
      var keys = await keysOf(
        tester,
        _Reparsing(t('bold_greeting'), child: Text(t('greeting'))),
      );

      expect(
        keys.map((o) => o.key.key),
        containsAll(['bold_greeting', 'greeting']),
      );
    });

    testWidgets('a property holding words no catalog minted claims nothing', (
      tester,
    ) async {
      indexTranslationsIn<_Reparsing>((widget) => widget.source);
      var keys = await keysOf(tester, reparsed('**Welcome** back'));

      expect(keys, isEmpty);
    });

    testWidgets('a source registered for another widget is skipped', (
      tester,
    ) async {
      indexTranslationsIn<Padding>((widget) => null);
      indexTranslationsIn<_Reparsing>((widget) => widget.source);
      var keys = await keysOf(tester, reparsed(t('bold_greeting')));

      expect(keys.map((o) => o.key.key), contains('bold_greeting'));
    });
  });

  testWidgets('nothing is read when the index is not recording', (
    tester,
  ) async {
    var value = t('greeting');
    TranslationIndex.recording = false;
    var keys = await keysOf(tester, Text(value));

    expect(keys, isEmpty);
  });

  testWidgets('a route below an opaque one has no layout, and is read anyway', (
    tester,
  ) async {
    // `RenderTheatre` lays out its onstage children only, so the page under an
    // opaque route is mounted with **no size** — ordinary, and what an app
    // deep-linking straight past its first screen has on its very first
    // capture. Asking such a paragraph `didExceedMaxLines` trips an assertion
    // and takes the whole read down.
    var below = t('greeting');
    var above = t('common_cancel');
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          pages: [
            MaterialPage(child: Scaffold(body: Text(below))),
            MaterialPage(child: Scaffold(body: Text(above))),
          ],
          onDidRemovePage: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    var keys = read(tester).translationKeys();

    // Both are found — the walk goes through offstage subtrees on purpose —
    // and the one with no layout simply has nothing to say about overflowing.
    expect(
      keys.map((k) => k.key.key),
      containsAll(['greeting', 'common_cancel']),
    );
    expect(
      _anyNode(read(tester), (node) => node.textOverflowed == true),
      isFalse,
    );
  });
}

bool _anyNode(InspectTree tree, bool Function(InspectNode) test) {
  bool visit(InspectNode node) => test(node) || node.children.any(visit);
  return switch (tree.root) {
    var root? => visit(root),
    _ => false,
  };
}

/// A widget that renders a string its own way, which is the whole case.
///
/// `substring` allocates, so not one span below here is the object the
/// catalog handed out — and the `**` are gone besides. [source] is untouched.
class _Reparsing extends StatelessWidget {
  const _Reparsing(this.source, {this.child});

  final String source;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    var spans = <InlineSpan>[];
    var bold = false;
    var at = 0;
    while (true) {
      var mark = source.indexOf('**', at);
      if (mark < 0) break;
      if (mark > at) spans.add(_span(source.substring(at, mark), bold));
      bold = !bold;
      at = mark + 2;
    }
    if (at < source.length) spans.add(_span(source.substring(at), bold));
    var text = Text.rich(TextSpan(children: spans));
    return child == null ? text : Column(children: [text, child!]);
  }

  static TextSpan _span(String text, bool bold) => TextSpan(
    text: text,
    style: bold ? const TextStyle(fontWeight: FontWeight.w900) : null,
  );
}
