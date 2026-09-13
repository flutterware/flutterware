import 'package:flutterware/comparison_report.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:test/test.dart';

/// Why the pixels differ, in words — the channel that turns a heatmap into a
/// sentence an agent can act on.
void main() {
  InspectNode node(
    String type, {
    String? description,
    double x = 0,
    double y = 0,
    double width = 10,
    double height = 10,
    String? widgetKey,
    bool laidOut = true,
    bool offstage = false,
    List<InspectNode> children = const [],
  }) => InspectNode(
    id: '',
    type: type,
    description: description,
    widgetKey: widgetKey,
    createdByLocalProject: true,
    offstage: offstage,
    layout: laidOut
        ? InspectLayout(
            x: x,
            y: y,
            width: width,
            height: height,
            isRepaintBoundary: false,
          )
        : null,
    children: children,
  );

  /// A node built the way a converter builds one — from the framework's own
  /// `type-key` spelling, through the same split both converters call. The
  /// hash goes in raw, exactly as `flutter_tester` minted it.
  InspectNode keyed(
    String type,
    String described, {
    double width = 10,
    double height = 10,
    List<InspectNode> children = const [],
  }) {
    var (:description, :key) = InspectNode.splitKey(described, type);
    return node(
      type,
      description: description == type ? null : description,
      widgetKey: key,
      width: width,
      height: height,
      children: children,
    );
  }

  test('two identical trees have nothing to say', () {
    var tree = node(
      'Card',
      children: [node('Text', description: 'Text("Hi")')],
    );

    expect(TreeDiff.of(tree, tree).isEmpty, isTrue);
  });

  test('a resized node names both sizes', () {
    var deltas = TreeDiff.of(
      node('Card', width: 100, height: 40),
      node('Card', width: 100, height: 64),
    ).deltas;

    expect(deltas, hasLength(1));
    expect(deltas.single.property, 'size');
    expect(deltas.single.base, '100×40');
    expect(deltas.single.head, '100×64');
  });

  // Nested, not as the root pair. The root pair skips signature matching
  // altogether, so a root-only version of this passed while the same rewording
  // one level down came back as a removal plus an addition — the test named
  // behaviour the code did not have anywhere a real tree would reach it.
  test('a re-worded label reads as its description changing', () {
    var deltas = TreeDiff.of(
      node('Card', children: [node('Text', description: 'Text("Save")')]),
      node('Card', children: [node('Text', description: 'Text("Pay")')]),
    ).deltas;

    expect(deltas.single.property, 'description');
    expect(deltas.single.base, 'Text("Save")');
    expect(deltas.single.head, 'Text("Pay")');
  });

  // Two candidates on a side, and nothing says which re-worded into which.
  test('two leftovers of one type stay a removal and an addition', () {
    var deltas = TreeDiff.of(
      node(
        'Column',
        children: [
          node('Text', description: 'Text("Save")'),
          node('Text', description: 'Text("Cancel")'),
        ],
      ),
      node(
        'Column',
        children: [
          node('Text', description: 'Text("Pay")'),
          node('Text', description: 'Text("Back")'),
        ],
      ),
    ).deltas;

    expect(deltas.map((it) => it.kind).toSet(), {
      TreeDeltaKind.added,
      TreeDeltaKind.removed,
    });
    expect(deltas, hasLength(4));
  });

  test('a widget that changed kind is not fused into a description change', () {
    var deltas = TreeDiff.of(
      node('Row', children: [node('Text', description: 'Text("Save")')]),
      node('Row', children: [node('Icon', description: 'Icon(check)')]),
    ).deltas;

    expect(deltas.map((it) => it.kind), [
      TreeDeltaKind.added,
      TreeDeltaKind.removed,
    ]);
  });

  group('a key is identity, not content', () {
    // The defect this channel shipped with: `#acc1d` is an identity hash, the
    // two sides are two processes, and every keyed widget in the tree reported
    // itself as removed and re-added with zero pixels changed.
    test('the same GlobalKey in two processes is the same node', () {
      var base = node(
        'Panel',
        children: [keyed('Form', 'Form-[LabeledGlobalKey<FormState>#acc1d]')],
      );
      var head = node(
        'Panel',
        children: [keyed('Form', 'Form-[LabeledGlobalKey<FormState>#0507e]')],
      );

      expect(TreeDiff.of(base, head).deltas, isEmpty);
    });

    // Worse than the noise: an unmatched node is reported and then not walked,
    // so the false positive was hiding everything underneath it.
    test('a real change under a keyed widget is still reported', () {
      InspectNode form(String hash, double height) => node(
        'Panel',
        children: [
          keyed(
            'Form',
            'Form-[LabeledGlobalKey<FormState>#$hash]',
            children: [node('TextField', height: height)],
          ),
        ],
      );

      var deltas = TreeDiff.of(form('acc1d', 40), form('0507e', 64)).deltas;

      expect(deltas.single.property, 'size');
      expect(deltas.single.base, '10×40');
      expect(deltas.single.head, '10×64');
      expect(deltas.single.path, 'Panel › Form › TextField');
    });

    test('a UniqueKey per row does not report the whole list as replaced', () {
      List<InspectNode> rows(List<String> hashes) => [
        for (var (index, hash) in hashes.indexed)
          keyed(
            'Row',
            'Row-[#$hash]',
            children: [node('Text', description: 'Text("$index")')],
          ),
      ];

      expect(
        TreeDiff.of(
          node('Column', children: rows(['17f35', '20f45', '4fbac'])),
          node('Column', children: rows(['009c2', 'ff198', 'dfeed'])),
        ).deltas,
        isEmpty,
      );
    });

    // The trap the first cut of this fell into: every value-less key spells
    // itself the same way once the hash goes, so letting one displace the
    // description makes two keyed siblings indistinguishable — and a diff
    // that is worse for having keys than for not.
    test('a value-less key does not stand in for the words', () {
      // What the guest hands back for `Text('Save', key: GlobalKey())`: the
      // words as the description, the key beside them with its hash gone.
      InspectNode column(List<String> words) => node(
        'Column',
        children: [
          for (var word in words)
            node(
              'Text',
              description: 'Text("$word")',
              widgetKey: InspectNode.splitKey(
                'Text-[GlobalKey#acc1d]',
                'Text',
              ).key,
            ),
        ],
      );

      var deltas = TreeDiff.of(
        column(['Save', 'Cancel']),
        column(['Cancel']),
      ).deltas;

      expect(deltas.single.kind, TreeDeltaKind.removed);
      expect(
        deltas.single.path,
        'Column › Text("Save")',
        reason: 'the node that went is the one that went',
      );
    });

    // What the split buys beyond the fix: a key the author gave a value is
    // stable, so it outranks the description and a rewording under it reads
    // as the change it is.
    test('a stable key matches through a re-worded label', () {
      var deltas = TreeDiff.of(
        node(
          'Column',
          children: [
            keyed(
              'Chip',
              "Chip-[<'primary'>]",
              children: [node('Text', description: 'Text("Save")')],
            ),
          ],
        ),
        node(
          'Column',
          children: [
            keyed(
              'Chip',
              "Chip-[<'primary'>]",
              children: [node('Text', description: 'Text("Pay")')],
            ),
          ],
        ),
      ).deltas;

      expect(deltas.single.property, 'description');
      expect(deltas.single.path, "Column › Chip-[<'primary'>] › Text(\"Pay\")");
    });

    test('two different stable keys are two different nodes', () {
      var deltas = TreeDiff.of(
        node('Column', children: [keyed('Chip', "Chip-[<'save'>]")]),
        node('Column', children: [keyed('Chip', "Chip-[<'pay'>]")]),
      ).deltas;

      expect(deltas.map((it) => it.kind), [
        TreeDeltaKind.added,
        TreeDeltaKind.removed,
      ]);
    });
  });

  // The whole reason children are aligned rather than zipped: one inserted
  // widget renumbers every sibling after it.
  test('an inserted child is one addition, not a renumbered subtree', () {
    var base = node(
      'Column',
      children: [
        node('Text', description: 'Text("A")'),
        node('Text', description: 'Text("C")'),
      ],
    );
    var head = node(
      'Column',
      children: [
        node('Text', description: 'Text("A")'),
        node('Text', description: 'Text("B")'),
        node('Text', description: 'Text("C")'),
      ],
    );

    var deltas = TreeDiff.of(base, head).deltas;

    expect(deltas, hasLength(1));
    expect(deltas.single.kind, TreeDeltaKind.added);
    expect(deltas.single.path, contains('Text("B")'));
  });

  test('a removed child is one removal', () {
    var base = node(
      'Column',
      children: [
        node('Text', description: 'Text("A")'),
        node('Divider'),
      ],
    );
    var head = node(
      'Column',
      children: [node('Text', description: 'Text("A")')],
    );

    var deltas = TreeDiff.of(base, head).deltas;

    expect(deltas, hasLength(1));
    expect(deltas.single.kind, TreeDeltaKind.removed);
    expect(deltas.single.path, contains('Divider'));
  });

  // A node that moved because something above it grew did not itself change,
  // and reporting it as one buries the node that did.
  test('a child pushed down by a resized parent is demoted, not silenced', () {
    var base = node(
      'Column',
      height: 40,
      children: [node('Text', description: 'Text("A")', y: 20)],
    );
    var head = node(
      'Column',
      height: 64,
      children: [node('Text', description: 'Text("A")', y: 44)],
    );

    var deltas = TreeDiff.of(base, head).deltas;

    expect(deltas.first.property, 'size');
    expect(deltas.first.kind, TreeDeltaKind.changed);
    expect(deltas.last.property, 'offset');
    expect(deltas.last.kind, TreeDeltaKind.shifted);
  });

  // The walk meets a resize root first, so it used to report the widgets
  // carried along — the containers, and the neighbour squeezed to make room —
  // before the leaf that grew, and a report capped at fifty lines could leave
  // the leaf out altogether.
  test('the resize that started it leads, what it carried follows', () {
    InspectNode screen({required double price}) => node(
      'Column',
      width: 300 + price,
      children: [
        node(
          'Row',
          width: 300 + price,
          children: [
            InspectNode(
              id: '',
              type: 'Expanded',
              createdByLocalProject: true,
              layout: InspectLayout(
                x: 0,
                y: 0,
                width: 300 - price,
                height: 10,
                isRepaintBoundary: false,
                constraints: InspectConstraints(
                  minWidth: 300 - price,
                  maxWidth: 300 - price,
                  minHeight: 0,
                  maxHeight: double.infinity,
                ),
              ),
            ),
            node('Text', description: 'Text("4.20 €")', width: price),
          ],
        ),
      ],
    );

    var deltas = TreeDiff.of(screen(price: 30), screen(price: 40)).deltas;
    var changed = [
      for (var delta in deltas)
        if (delta.kind == TreeDeltaKind.changed) delta,
    ];
    String line(TreeDelta delta) =>
        '${delta.path.split(' › ').last} ${delta.property}';

    expect(changed.map(line).first, 'Text("4.20 €") size');
    expect(changed.map(line).skip(1).takeWhile((l) => l.endsWith('size')), [
      'Row size',
      'Column size',
      'Expanded size',
    ], reason: 'the containers it grew, then the neighbour it squeezed');
    expect(changed.map(line).last, 'Expanded constraints');
  });

  test('a node that moved on its own is a change, not a shift', () {
    var base = node('Column', children: [node('Icon', x: 0)]);
    var head = node('Column', children: [node('Icon', x: 12)]);

    var deltas = TreeDiff.of(base, head).deltas;

    expect(deltas.single.property, 'offset');
    expect(deltas.single.kind, TreeDeltaKind.changed);
  });

  test('a whole tree appearing or disappearing is one delta', () {
    expect(
      TreeDiff.of(null, node('Card')).deltas.single.kind,
      TreeDeltaKind.added,
    );
    expect(
      TreeDiff.of(node('Card'), null).deltas.single.kind,
      TreeDeltaKind.removed,
    );
    expect(TreeDiff.of(null, null).isEmpty, isTrue);
  });

  // Most of a summary tree has no box of its own — a provider, a builder —
  // and "it has no box" must not read as "its box is empty".
  test('a node with no box contributes no layout delta', () {
    var deltas = TreeDiff.of(
      node('Provider', laidOut: false),
      node('Provider', laidOut: false),
    ).deltas;

    expect(deltas, isEmpty);
  });

  // A scenario that pushes a screen keeps the one beneath it alive in the
  // tree, offstage. A change there belongs to the step that showed it — not
  // to every step after the push.
  test('a change under a route offstage on both sides says nothing', () {
    var base = node(
      'Navigator',
      children: [
        node(
          'Scaffold',
          offstage: true,
          children: [node('Text', description: 'Text("Old label")')],
        ),
        node('Scaffold', children: [node('Text', description: 'Text("B")')]),
      ],
    );
    var head = node(
      'Navigator',
      children: [
        node(
          'Scaffold',
          offstage: true,
          children: [node('Text', description: 'Text("New label")')],
        ),
        node('Scaffold', children: [node('Text', description: 'Text("B")')]),
      ],
    );

    expect(TreeDiff.of(base, head).isEmpty, isTrue);
  });

  test('a subtree offstage on one side only reads as added or removed', () {
    var visible = node(
      'Stack',
      children: [
        node('Banner', children: [node('Text')]),
      ],
    );
    var hidden = node(
      'Stack',
      children: [
        node('Banner', offstage: true, children: [node('Text')]),
      ],
    );

    var gone = TreeDiff.of(visible, hidden).deltas;
    expect(gone.single.kind, TreeDeltaKind.removed);
    expect(gone.single.path, contains('Banner'));

    var appeared = TreeDiff.of(hidden, visible).deltas;
    expect(appeared.single.kind, TreeDeltaKind.added);
    expect(appeared.single.path, contains('Banner'));
  });

  test('additions and removals outrank property changes', () {
    var base = node(
      'Column',
      children: [node('Text', description: 'Text("A")', width: 10)],
    );
    var head = node(
      'Column',
      children: [
        node('Text', description: 'Text("A")', width: 20),
        node('Badge'),
      ],
    );

    var deltas = TreeDiff.of(base, head).deltas;

    expect(deltas.first.kind, TreeDeltaKind.added);
    expect(deltas.last.property, 'size');
  });

  // Both halves of the same complaint from a consumer: a `key:` added to a
  // `Text` is invisible to any screenshot, so the tree channel is the only
  // one that can report it — and it was reporting it unreadably.
  group('a key is part of a node’s name', () {
    InspectNode text({String? key}) => InspectNode(
      id: '',
      type: 'Text',
      description: 'Text("This code is not valid.")',
      widgetKey: key,
      createdByLocalProject: true,
      children: const [],
    );
    InspectNode column(InspectNode child) => InspectNode(
      id: '',
      type: 'Column',
      createdByLocalProject: true,
      children: [child],
    );

    // The report as filed: `+ Column › Text("…")` over `- Column › Text("…")`,
    // byte-identical, with the one fact that explains them left out.
    test('a keyed child is told apart from an unkeyed one', () {
      var diff = TreeDiff.of(
        column(text()),
        column(text(key: "[<'codeErrorText'>]")),
      );

      var added = diff.deltas.firstWhere(
        (delta) => delta.kind == TreeDeltaKind.added,
      );
      var removed = diff.deltas.firstWhere(
        (delta) => delta.kind == TreeDeltaKind.removed,
      );
      expect(added.path, isNot(removed.path));
      expect(added.path, contains('codeErrorText'));
      expect(removed.path, isNot(contains('codeErrorText')));
    });

    // A key with no value of its own is the same string on every node once
    // its identity hash is gone, so it must not enter a path.
    test('a key that names nothing stays out of the name', () {
      var diff = TreeDiff.of(column(text()), column(text(key: '[#]')));

      for (var delta in diff.deltas) {
        expect(delta.path, isNot(contains('#')));
      }
    });

    // `_signature` and `_fuse` keep two differently-keyed *children* apart, so
    // neither ever runs on the root — which is handed to the walk as a pair
    // whatever its key says.
    test('a key on the root node is a change, not silence', () {
      var diff = TreeDiff.of(text(), text(key: "[<'codeErrorText'>]"));

      expect(diff.deltas, hasLength(1));
      expect(diff.deltas.single.property, 'key');
      expect(diff.deltas.single.base, isNull);
      expect(diff.deltas.single.head, contains('codeErrorText'));
      expect(TreeChannel(diff).changed, isTrue);
    });

    test('two roots that agree about their key say nothing', () {
      var diff = TreeDiff.of(
        text(key: "[<'codeErrorText'>]"),
        text(key: "[<'codeErrorText'>]"),
      );

      expect(diff.deltas, isEmpty);
    });
  });
}
