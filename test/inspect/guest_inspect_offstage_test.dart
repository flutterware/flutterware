import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';

/// The offstage flag: content that is in the tree but not on the screen.
///
/// The summary tree keeps the user's widgets and drops the framework's — and
/// the framework's is where the hiding happens, so what survives into a
/// capture is the hidden *content* with no marker over it, wearing rects from
/// the last time it was laid out. These tests pin the oracle
/// (`visitChildrenForSemantics` over the render chain) to the cases that
/// matter: the route a push covered must be flagged, the screen under a
/// dialog must not be, and semantics-excluded-but-painted content must never
/// be mistaken for hidden.
void main() {
  group('offstage detection', () {
    testWidgets('a pushed-under route is flagged, the pushed one is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  const Text('the menu'),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const Scaffold(body: Text('the detail')),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      var tree = _read(tester);
      expect(_textNode(tree, 'the menu').offstage, isTrue);
      expect(_textNode(tree, 'the detail').offstage, isFalse);
    });

    testWidgets('the screen under a dialog stays on stage', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  const Text('the menu'),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const AlertDialog(content: Text('are you sure')),
                    ),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // A dialog's route is not opaque, so the theater keeps the screen under
      // it on stage — it is right there, dimmed behind the barrier.
      var tree = _read(tester);
      expect(_textNode(tree, 'the menu').offstage, isFalse);
      expect(_textNode(tree, 'are you sure').offstage, isFalse);
    });

    testWidgets('Offstage and Visibility(visible: false) are flagged', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Text('shown'),
                Offstage(child: Text('offstage')),
                Visibility(
                  visible: false,
                  maintainState: true,
                  child: Text('invisible'),
                ),
              ],
            ),
          ),
        ),
      );

      var tree = _read(tester);
      expect(_textNode(tree, 'shown').offstage, isFalse);
      expect(_textNode(tree, 'offstage').offstage, isTrue);
      expect(_textNode(tree, 'invisible').offstage, isTrue);
    });

    testWidgets('an IndexedStack shows one child and the flag says which', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: IndexedStack(
              index: 0,
              children: [Text('first'), Text('second')],
            ),
          ),
        ),
      );

      var tree = _read(tester);
      expect(_textNode(tree, 'first').offstage, isFalse);
      expect(_textNode(tree, 'second').offstage, isTrue);
    });

    testWidgets('semantics-excluded content is painted, so it is not flagged', (
      tester,
    ) async {
      // The three classes that skip the semantics walk *without* hiding
      // anything — the exact false positives the exemption list exists for.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const ExcludeSemantics(child: Text('decorative')),
                const IgnorePointer(child: Text('untouchable')),
                Semantics(
                  label: 'a picture of a cat',
                  excludeSemantics: true,
                  child: const Text('cat'),
                ),
              ],
            ),
          ),
        ),
      );

      var tree = _read(tester);
      expect(_textNode(tree, 'decorative').offstage, isFalse);
      expect(_textNode(tree, 'untouchable').offstage, isFalse);
      expect(_textNode(tree, 'cat').offstage, isFalse);
    });

    testWidgets('the flag survives the wire', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Offstage(child: Text('offstage'))),
        ),
      );

      var decoded = InspectTree.fromJson(_read(tester).toJson());
      expect(_textNode(decoded, 'offstage').offstage, isTrue);
    });
  });
}

InspectTree _read(WidgetTester tester) => GuestInspector(
  rootOf: () => tester.binding.rootElement,
  entryIdOf: () => null,
).read();

/// The node carrying `Text("[text]")`, found by the preview the walker adds.
InspectNode _textNode(InspectTree tree, String text) => tree.nodes.singleWhere(
  (node) => node.description == 'Text("$text")',
  orElse: () => fail('No Text("$text") in the tree'),
);
