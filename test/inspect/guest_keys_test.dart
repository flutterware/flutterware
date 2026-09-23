import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';

/// A widget's key, which the framework spells into the same string as its
/// description and which `InspectNode.splitKey` takes back out.
///
/// These are the ones that need a real inspector rather than a fixture: that
/// `Widget.toStringShort()` is `'$type-$key'` and reaches the walk that way is
/// an assumption about the framework, and the identity hash it puts in there
/// is the reason a previews comparison called 21 unchanged entries changed.
void main() {
  InspectTree read(WidgetTester tester) => GuestInspector(
    rootOf: () => tester.binding.rootElement,
    entryIdOf: () => null,
  ).read();

  InspectNode node(InspectTree tree, String type) =>
      tree.nodes.firstWhere((n) => n.type == type);

  testWidgets('an unkeyed widget carries no key at all', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Placeholder()));

    expect(node(read(tester), 'Placeholder').widgetKey, isNull);
  });

  testWidgets('a value-less key comes back without its hash', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Form(key: GlobalKey<FormState>(), child: Container()),
      ),
    );
    var form = node(read(tester), 'Form');

    expect(form.widgetKey, '[LabeledGlobalKey<FormState>#]');
    expect(
      form.description,
      isNull,
      reason: 'the key was the only thing it said beyond its type',
    );
  });

  testWidgets('a UniqueKey keeps nothing but the fact of itself', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: Placeholder(key: UniqueKey())));

    expect(node(read(tester), 'Placeholder').widgetKey, '[#]');
  });

  testWidgets('a ValueKey keeps every character of its value', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Placeholder(key: ValueKey('draft'))),
    );

    expect(node(read(tester), 'Placeholder').widgetKey, "[<'draft'>]");
  });

  // The defect, end to end: two builds of one widget in one process already
  // disagree, because each `GlobalKey()` is a fresh allocation.
  testWidgets('two builds of the same keyed widget agree', (tester) async {
    Future<InspectNode> build() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Form(key: GlobalKey<FormState>(), child: const Placeholder()),
        ),
      );
      return node(read(tester), 'Form');
    }

    var first = await build();
    await tester.pumpWidget(const SizedBox());
    var second = await build();

    expect(first.widgetKey, second.widgetKey);
    expect(first.description, second.description);
  });

  testWidgets('a key on a Text does not cost the words', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Text('Save', key: ValueKey('save'))),
    );
    var text = node(read(tester), 'Text');

    expect(text.description, 'Text("Save")');
    expect(text.widgetKey, "[<'save'>]");
  });
}
