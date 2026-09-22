import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/node.dart';

/// Holds [GuestInspector.treeFormat] to what the walk actually writes.
///
/// A comparison stops counting tree differences between two sides whose
/// formats differ, so a walk that changes its reading without moving the
/// format makes a dependency bump report every affected widget as changed —
/// which is what a consumer measured before the format existed: 109 rows
/// changed, 0 pixels moved.
///
/// The reading is what `TreeDiff` compares, less the layout: the layout is
/// the framework's numbers, and the format is about how this walk names what
/// it finds.
void main() {
  testWidgets('the walk reads the way its format says', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            const Text('Plain'),
            const Text.rich(
              TextSpan(
                text: 'Rich ',
                children: [TextSpan(text: 'span')],
              ),
            ),
            RichText(text: const TextSpan(text: 'Painted')),
            Padding(
              key: const ValueKey('padded'),
              padding: const EdgeInsets.all(4),
              child: const _Local(),
            ),
            const Offstage(child: Text('Hidden')),
          ],
        ),
      ),
    );
    var tree = GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => null,
    ).read();

    expect(tree.format, GuestInspector.treeFormat);
    expect(
      _reading(tree.root!),
      _readings[GuestInspector.treeFormat],
      reason:
          'The walk reads these widgets differently now. Bump '
          'GuestInspector.treeFormat and add this reading under the new '
          'number, keeping the old ones: a comparison whose two sides were '
          'captured by different flutterware versions tells a changed walk '
          'from a changed widget by that number alone.',
    );
  });

  test('the format survives both spellings of the file', () {
    var tree = InspectTree(
      entryId: 'a#b',
      format: 3,
      root: InspectNode(id: '', type: 'Text'),
    );

    expect(InspectTree.fromJson(tree.toJson()).format, 3);
    expect(InspectTree.fromJson(tree.toJson(compact: true)).format, 3);
    expect(
      InspectTree.fromJson(const {'entry': 'a#b', 'root': null}).format,
      isNull,
      reason: 'a tree read before formats were recorded says nothing',
    );
  });
}

/// Every reading the walk has had, by format. Kept, not replaced: the history
/// is what shows a reviewer that a bump happened with the change that needed
/// it.
const _readings = {
  1: '''
MaterialApp
  Column
    Text: Text("Plain")
    Text: Text("Rich span")
    RichText: RichText("Painted")
    Padding key [<'padded'>]
      _Local
        Text: Text("Local")
    Offstage
      Text: Text("Hidden") (offstage)
''',
  // The same words: 2 moved the boxes of a view-rooted walk into logical
  // pixels, which `guest_layout_test.dart` holds.
  2: '''
MaterialApp
  Column
    Text: Text("Plain")
    Text: Text("Rich span")
    RichText: RichText("Painted")
    Padding key [<'padded'>]
      _Local
        Text: Text("Local")
    Offstage
      Text: Text("Hidden") (offstage)
''',
};

String _reading(InspectNode root) {
  var buffer = StringBuffer();
  void walk(InspectNode node, int depth) {
    buffer
      ..write('  ' * depth)
      ..write(node.type);
    if (node.description case var description?) buffer.write(': $description');
    if (node.widgetKey case var key?) buffer.write(' key $key');
    if (node.offstage) buffer.write(' (offstage)');
    buffer.writeln();
    for (var child in node.children) {
      walk(child, depth + 1);
    }
  }

  walk(root, 0);
  return '$buffer';
}

class _Local extends StatelessWidget {
  const _Local();

  @override
  Widget build(BuildContext context) => const Text('Local');
}
