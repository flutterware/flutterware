import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/semantics_capture.dart';

/// The semantics serializer: logical rects, traversal order, merged folding,
/// names instead of bitmasks.
void main() {
  testWidgets('captures labels, flags and actions, rects in logical pixels', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Semantics(
                label: 'Add to cart',
                child: IconButton(
                  icon: const Icon(Icons.add_shopping_cart),
                  onPressed: () {},
                ),
              ),
              const Text('Cappuccino'),
            ],
          ),
        ),
      ),
    );

    var tree = captureSemanticsTree();
    expect(tree, isNotNull);

    // The root is the screen, in logical pixels — the test binding's surface
    // is 800x600 at a device pixel ratio of 3, and physical coordinates
    // leaking through would read 2400x1800.
    var rect = (tree!['rect']! as Map).cast<String, num>();
    expect(rect['width'], 800);
    expect(rect['height'], 600);

    var flat = _flatten(tree);
    // The wrapper node wears the label; the IconButton inside is the node
    // wearing the button flag and the tap action.
    expect(flat.map((n) => n['label']), contains('Add to cart'));
    var button = flat.singleWhere(
      (n) => (n['flags'] as List?)?.contains('isButton') ?? false,
    );
    expect(button['actions'], contains('tap'));
    // The button is 48x48 logical near the top of the screen; its rect must
    // be in the same space as the root's, not in physical pixels.
    var buttonRect = (button['rect']! as Map).cast<String, num>();
    expect(buttonRect['height'], lessThan(100));

    expect(flat.map((n) => n['label']), contains('Cappuccino'));
  });

  testWidgets('children come in traversal order, merged nodes are folded', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Text('First'),
              const Text('Second'),
              // A button merges its descendants: one node wearing the label,
              // no child node for the Text inside.
              TextButton(onPressed: () {}, child: const Text('Third')),
            ],
          ),
        ),
      ),
    );

    var flat = _flatten(captureSemanticsTree()!);
    var labels = [
      for (var node in flat)
        if (node['label'] case String label) label,
    ];
    expect(labels, containsAllInOrder(['First', 'Second', 'Third']));
    // 'Third' is the merged button node, not a text child under it.
    var third = flat.singleWhere((n) => n['label'] == 'Third');
    expect(third['flags'], contains('isButton'));
    expect(third['children'], isEmpty);
  });
}

List<Map<String, Object?>> _flatten(Map<String, Object?> node) => [
  node,
  for (var child in node['children']! as List)
    ..._flatten((child as Map).cast<String, Object?>()),
];
