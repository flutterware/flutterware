import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware/src/inspect/screen.dart';

/// Words drawn by spans rather than by a string — `Text.rich` and a
/// hand-written `RichText` — reach `find` and `screen` the way a plain
/// `Text`'s do.
///
/// Reported on a captured scenario step: a message bubble's text was in the
/// picture and matched by nothing. The bubble here is tappable and merges its
/// semantics, which is what took away the label a bare `RichText` would
/// otherwise have been found by.
void main() {
  InspectTree read(WidgetTester tester) => GuestInspector(
    rootOf: () => tester.binding.rootElement,
    entryIdOf: () => null,
  ).read();

  Widget bubble(Widget child) => MergeSemantics(
    child: GestureDetector(onTap: () {}, child: child),
  );

  testWidgets('a RichText bubble is found by its words', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            bubble(
              RichText(
                text: const TextSpan(
                  text: 'Ada: ',
                  style: TextStyle(color: Colors.black),
                  children: [TextSpan(text: 'see you at noon')],
                ),
              ),
            ),
            const Text('Unrelated'),
          ],
        ),
      ),
    );
    var tree = read(tester);

    expect(
      tree.matching('see you at noon').map((n) => n.type),
      contains('RichText'),
    );
    expect(
      Screen.of(tree).items.map((i) => i.words),
      contains('Ada: see you at noon'),
    );
  });

  testWidgets('a Text.rich bubble is found by its words', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: bubble(
          const Text.rich(
            TextSpan(
              text: 'Ada: ',
              children: [TextSpan(text: 'on my way')],
            ),
          ),
        ),
      ),
    );
    var tree = read(tester);

    expect(tree.matching('on my way').map((n) => n.type), contains('Text'));
    expect(
      Screen.of(tree).items.map((i) => i.words),
      contains('Ada: on my way'),
    );
  });

  testWidgets('the drawn words, not the spoken ones', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RichText(
          text: const TextSpan(
            text: '3 min',
            semanticsLabel: 'three minutes',
            style: TextStyle(color: Colors.black),
          ),
        ),
      ),
    );

    expect(
      read(tester).nodes.firstWhere((n) => n.type == 'RichText').description,
      'RichText("3 min")',
    );
  });
}
