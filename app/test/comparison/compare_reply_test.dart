import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/compare_command.dart';
import 'package:flutter_test/flutter_test.dart';

ComparedFinding _finding(
  String id, {
  List<TreeDelta> tree = const [],
  List<String> events = const [],
}) => ComparedFinding(
  id: id,
  half: ComparedHalfKind.previews,
  state: ComparedState.changed,
  preview: ComparedItem(
    id: id,
    state: ComparedState.changed,
    tree: TreeChannel(TreeDiff(tree)),
    events: EventChannel(added: events, removed: const []),
  ),
);

TreeDelta _added(String path) =>
    TreeDelta(kind: TreeDeltaKind.added, path: path, head: 'Frame');

void main() {
  test(
    'the shape the most findings wear comes first, whatever came before',
    () {
      var shapes = replyShapes([
        // A first finding with more shapes of its own than the reply carries.
        _finding(
          'a',
          tree: [for (var i = 0; i < 20; i++) _added('Column › Only$i')],
        ),
        for (var id in ['b', 'c', 'd'])
          _finding(id, tree: [_added('Scope › Frame')]),
      ]);

      expect(shapes, hasLength(12));
      expect(shapes.first.subject, 'Scope › Frame');
      expect(shapes.first.items, 3);
      // Between equals the fold's own order stands.
      expect(shapes[1].subject, 'Column › Only0');
    },
  );

  test('system events go after everything else', () {
    var shapes = replyShapes([
      for (var id in ['a', 'b', 'c'])
        _finding(id, events: ['system flutter/textinput setClient']),
      _finding('d', tree: [_added('Scope › Frame')]),
    ]);

    expect([for (var shape in shapes) shape.channel], ['tree', 'events']);
    expect(shapes.last.subchannel, 'system');
    expect(shapes.last.items, 3);
  });

  test('a long path keeps its end, and two screens then share the shape', () {
    var shapes = replyShapes([
      for (var screen in ['menu', 'cart'])
        _finding(
          screen,
          tree: [_added('$screen › Shell › App › Theme › Scope › Frame')],
        ),
    ]);

    expect(shapes.single.subject, '… › App › Theme › Scope › Frame');
    expect(shapes.single.items, 2);
  });
}
