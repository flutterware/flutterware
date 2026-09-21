import 'dart:convert';

import 'package:flutterware/src/inspect/error.dart';
import 'package:flutterware/src/inspect/node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The wire format, which is the half of inspection that needs no guest.
///
/// Worth its own tests because the one defect that took a whole read down was
/// here rather than in the walk: `jsonEncode` throws on `double.infinity`, and
/// an unbounded `maxWidth` is what most of a real tree is laid out under. A
/// live check caught it only because somebody ran it; this catches it in
/// milliseconds, on every push, without an SDK or a GPU.
void main() {
  _ambientSentinel();
  group('InspectNode.splitKey', () {
    test('leaves an unkeyed description alone', () {
      var split = InspectNode.splitKey('Text("Save")', 'Text');
      expect(split.description, 'Text("Save")');
      expect(split.key, isNull);
    });

    test('takes the key off, leaving the bare type behind', () {
      var split = InspectNode.splitKey("Form-[<'draft'>]", 'Form');
      expect(split.description, 'Form');
      expect(split.key, "[<'draft'>]");
    });

    // The whole defect: `#acc1d` is `hashCode`, minted per allocation, so the
    // same key in two `flutter_tester` processes never spells itself twice.
    test('elides the identity hash a value-less key stringifies through', () {
      for (var pair in const [
        ('Form-[LabeledGlobalKey<FormState>#acc1d]', 'Form'),
        ('Form-[LabeledGlobalKey<FormState>#0507e]', 'Form'),
      ]) {
        expect(
          InspectNode.splitKey(pair.$1, pair.$2).key,
          '[LabeledGlobalKey<FormState>#]',
        );
      }
      expect(
        InspectNode.splitKey('Card-[GlobalKey#04a2f]', 'Card').key,
        '[GlobalKey#]',
      );
      expect(InspectNode.splitKey('Row-[#a1b2c]', 'Row').key, '[#]');
      expect(
        InspectNode.splitKey('Tile-[GlobalObjectKey Item#1234f]', 'Tile').key,
        '[GlobalObjectKey Item#]',
      );
    });

    // A hash-shaped *value* is the author's, is stable, and is the only thing
    // telling two of these apart.
    test('keeps a ValueKey whose value merely looks like a hash', () {
      expect(
        InspectNode.splitKey("Chip-[<'#abc12'>]", 'Chip').key,
        "[<'#abc12'>]",
      );
    });

    test('balances brackets rather than taking the last one', () {
      var split = InspectNode.splitKey('Row-[<[1, 2]>]', 'Row');
      expect(split.key, '[<[1, 2]>]');
      expect(split.description, 'Row');
    });

    test('keeps whatever the description said after the key', () {
      var split = InspectNode.splitKey(
        "SizedBox-[<'gap'>](width: 8.0)",
        'SizedBox',
      );
      expect(split.key, "[<'gap'>]");
      expect(split.description, 'SizedBox(width: 8.0)');
    });

    test('says nothing about a description that is not type-then-key', () {
      expect(InspectNode.splitKey(null, 'Padding').key, isNull);
      expect(InspectNode.splitKey('Padding', 'Padding').key, isNull);
      expect(InspectNode.splitKey('Form-[unclosed', 'Form').key, isNull);
      expect(InspectNode.splitKey('OtherForm-[<%27a%27>]', 'Form').key, isNull);
    });

    test('rides the wire in both spellings', () {
      var tree = InspectTree(
        entryId: 'e',
        root: const InspectNode(
          id: '',
          type: 'Form',
          widgetKey: '[GlobalKey#]',
        ),
      );
      for (var compact in [false, true]) {
        expect(
          InspectTree.fromJson(tree.toJson(compact: compact)).root?.widgetKey,
          '[GlobalKey#]',
          reason: 'compact: $compact',
        );
      }
    });
  });

  group('InspectSource', () {
    test('prints a file URI as a path relative to the worktree', () {
      var source = const InspectSource(
        file: 'file:///repo/app/demo/tile.dart',
        line: 12,
        column: 5,
      );
      expect(source.describe(relativeTo: '/repo'), 'app/demo/tile.dart:12:5');
    });

    test('leaves a path outside the worktree absolute', () {
      var source = const InspectSource(
        file: 'file:///sdk/flutter/widgets.dart',
        line: 1,
        column: 1,
      );
      expect(
        source.describe(relativeTo: '/repo'),
        '${_absolute(['sdk', 'flutter', 'widgets.dart'])}:1:1',
      );
    });

    /// What a VM-service tree is full of above the user's code, and the whole
    /// reason the pane wrapped an SDK path over six lines.
    test('folds a Flutter SDK path to a package URI', () {
      var source = const InspectSource(
        file:
            'file:///Users/x/.flutterware/sdks/3.47.0-0.1.pre/packages/'
            'flutter/lib/src/widgets/binding.dart',
        line: 1673,
        column: 24,
      );
      expect(
        source.describe(relativeTo: '/repo'),
        'package:flutter/src/widgets/binding.dart:1673:24',
      );
    });

    test('folds a pub cache path, version stamp and all', () {
      var source = const InspectSource(
        file:
            'file:///Users/x/.pub-cache/hosted/pub.dev/provider-6.1.2%2B1/'
            'lib/src/provider.dart',
        line: 4,
        column: 2,
      );
      expect(
        source.describe(relativeTo: '/repo'),
        'package:provider/src/provider.dart:4:2',
      );
    });

    test('folds a git cache path', () {
      var source = InspectSource(
        file:
            'file:///Users/x/.pub-cache/git/some_dep-${'a1b2c3d4' * 5}/'
            'lib/some_dep.dart',
        line: 1,
        column: 1,
      );
      expect(
        source.describe(relativeTo: '/repo'),
        'package:some_dep/some_dep.dart:1:1',
      );
    });

    /// A path dependency beside the worktree looks like any other directory.
    /// Naming it `package:something` would be a confident guess about a real
    /// file, so it stays as it is.
    test('leaves a lib/ path with no cache marker alone', () {
      var source = const InspectSource(
        file: 'file:///Users/x/projects/sibling/lib/thing.dart',
        line: 9,
        column: 3,
      );
      expect(
        source.describe(relativeTo: '/repo'),
        '${_absolute(['Users', 'x', 'projects', 'sibling', 'lib', 'thing.dart'])}:9:3',
      );
    });

    /// Both could apply to a vendored copy. The checkout wins: it is the path
    /// the reader can open.
    test('prefers the worktree over a package URI', () {
      var source = const InspectSource(
        file: 'file:///repo/packages/inner/lib/thing.dart',
        line: 2,
        column: 1,
      );
      expect(
        source.describe(relativeTo: '/repo'),
        'packages/inner/lib/thing.dart:2:1',
      );
    });

    /// The web export has no checkout to shorten against and passes `''`.
    /// Every path starts with the empty string, so the old branch matched,
    /// stripped nothing, and took the leading slash with it.
    test('an empty root folds packages and keeps the path whole', () {
      expect(
        const InspectSource(
          file: 'file:///sdk/packages/flutter/lib/src/widgets/binding.dart',
          line: 1,
          column: 1,
        ).describe(relativeTo: ''),
        'package:flutter/src/widgets/binding.dart:1:1',
      );
      expect(
        const InspectSource(
          file: 'file:///a/b.dart',
          line: 1,
          column: 1,
        ).describe(relativeTo: ''),
        '${_absolute(['a', 'b.dart'])}:1:1',
      );
    });
  });

  group('InspectConstraints', () {
    test('an unbounded edge survives jsonEncode', () {
      var constraints = const InspectConstraints(
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: 700,
      );
      // The assertion is that this does not throw. It did.
      var encoded = jsonEncode(constraints.toJson());
      // Left out rather than written as null — the same thing to the reader
      // below, and sixteen characters cheaper on every node of a real tree.
      expect(encoded, isNot(contains('maxWidth')));
      expect(encoded, contains('"maxHeight":700'));
    });

    test('and comes back unbounded rather than zero', () {
      var round = InspectConstraints.fromJson(
        jsonDecode(
          jsonEncode(
            const InspectConstraints(
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 8,
              maxHeight: double.infinity,
            ).toJson(),
          ),
        ) as Map<String, Object?>,
      );
      expect(round.maxWidth, double.infinity);
      expect(round.maxHeight, double.infinity);
      expect(round.minHeight, 8);
    });

    test('describes infinity as something a terminal can print', () {
      expect(
        const InspectConstraints(
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: 0,
          maxHeight: 700,
        ).describe(),
        'w 0..∞, h 0..700',
      );
    });

    /// The detail pane prints this two lines under `size 573 × 101`, which
    /// drops the `.0`. Two notations for one measurement read as two kinds of
    /// number.
    test('drops the .0, and keeps a real fraction', () {
      expect(
        const InspectConstraints(
          minWidth: 0,
          maxWidth: 573,
          minHeight: 47.5,
          maxHeight: 100,
        ).describe(),
        'w 0..573, h 47.5..100',
      );
    });
  });

  group('InspectLayout', () {
    test('a non-finite size does not take the encode down', () {
      var layout = const InspectLayout(
        x: 0,
        y: double.nan,
        width: double.infinity,
        height: 40,
      );
      expect(() => jsonEncode(layout.toJson()), returnsNormally);
    });

    test('carries flex both ways round', () {
      var round = InspectLayout.fromJson(
        jsonDecode(
          jsonEncode(
            const InspectLayout(
              x: 1,
              y: 2,
              width: 3,
              height: 4,
              flex: InspectFlex(
                direction: 'horizontal',
                mainAxisAlignment: 'start',
              ),
              flexFactor: 2,
              flexFit: 'tight',
            ).toJson(),
          ),
        ) as Map<String, Object?>,
      );
      expect(round.flex?.direction, 'horizontal');
      expect(round.flexFactor, 2);
      expect(round.flexFit, 'tight');
    });
  });

  group('InspectTree', () {
    var tree = InspectTree(
      entryId: 'demo/a.dart#a',
      root: const InspectNode(
        id: '',
        type: 'Column',
        children: [
          InspectNode(id: '0', type: 'Padding'),
          InspectNode(
            id: '1',
            type: 'Row',
            children: [InspectNode(id: '1/0', type: 'Text')],
          ),
        ],
      ),
    );

    test('walks depth first, root included', () {
      expect([for (var node in tree.nodes) node.id], ['', '0', '1', '1/0']);
    });

    test('resolves a node by its id', () {
      expect(tree.nodeAt('1/0')?.type, 'Text');
    });

    test('answers null for an id that no longer names anything', () {
      // Deliberately not a nearest match: a caller that edited the demo
      // between two reads is asking about a position that may now hold
      // something else, and answering with whatever moved into it would be a
      // confident wrong answer.
      expect(tree.nodeAt('1/9'), isNull);
    });

    test('resolve takes a name as well as an id', () {
      // The whole point of it: `screenshot --node=Text` is a thing somebody
      // has in their hand, where an id is a thing they have to go and read a
      // tree for first.
      expect([for (var node in tree.resolve('Text')) node.id], ['1/0']);
      expect([for (var node in tree.resolve('1/0')) node.id], ['1/0']);
    });

    test('resolve prefers the exact id over a name that also matches', () {
      // The two vocabularies do not collide in practice — no widget is called
      // `1/0` — but if one ever did, exact wins.
      expect(tree.resolve('1').single.type, 'Row', reason: 'the id, not a hit');
    });

    test(
      'resolve reports every match, and leaves the choosing to the caller',
      () {
        var twice = InspectTree(
          entryId: 'demo/a.dart#a',
          root: const InspectNode(
            id: '',
            type: 'Column',
            children: [
              InspectNode(id: '0', type: 'ElevatedButton'),
              InspectNode(id: '1', type: 'ElevatedButton'),
            ],
          ),
        );
        // Not one node: a crop refuses on this and a tree read narrows to the
        // outermost, and neither answer belongs in here.
        expect(
          [for (var node in twice.resolve('ElevatedButton')) node.id],
          ['0', '1'],
        );
      },
    );

    test('resolve answers empty for a name nothing carries', () {
      expect(tree.resolve('Nonesuch'), isEmpty);
    });

    test('an unbuilt entry is an empty answer, not a broken one', () {
      var empty = InspectTree.fromJson(
        const InspectTree(entryId: 'x', root: null).toJson(),
      );
      expect(empty.root, isNull);
      expect(empty.nodes, isEmpty);
      expect(empty.entryId, 'x');
    });

    test('survives a round trip whole', () {
      var round = InspectTree.fromJson(
        jsonDecode(jsonEncode(tree.toJson())) as Map<String, Object?>,
      );
      expect([for (var n in round.nodes) n.id], ['', '0', '1', '1/0']);
      expect(round.entryId, 'demo/a.dart#a');
    });
  });

  group('InspectError', () {
    test('two reports of one fault share a key', () {
      const a = InspectError(
        exception: 'overflowed by 4 pixels',
        library: 'rendering library',
        context: 'during layout',
      );
      const b = InspectError(
        exception: 'overflowed by 4 pixels',
        library: 'rendering library',
        // Deliberately different: the same overflow reported during layout and
        // while painting is one bug.
        context: 'while painting',
      );
      expect(a.key, b.key);
    });

    test('a count of one is left off the wire', () {
      expect(
        const InspectError(exception: 'x').toJson().containsKey('count'),
        isFalse,
      );
      expect(const InspectError(exception: 'x', count: 7).toJson()['count'], 7);
    });

    test('an entry with nothing to say is empty rather than absent', () {
      var report = InspectErrors.fromJson(
        const InspectErrors(entryId: 'x', errors: []).toJson(),
      );
      expect(report.isEmpty, isTrue);
      expect(report.entryId, 'x');
    });
  });

  group('nodeAtPoint', () {
    InspectNode box(
      String id,
      String type,
      double x,
      double y,
      double w,
      double h, {
      List<InspectNode> children = const [],
    }) => InspectNode(
      id: id,
      type: type,
      layout: InspectLayout(x: x, y: y, width: w, height: h),
      children: children,
    );

    // Column(0,0 200x100) > [ Padding(0,0 200x50) > Text(8,8 40x16),
    //                         Button(0,50 80x50) ]
    var tree = InspectTree(
      entryId: 'e',
      root: box(
        '',
        'Column',
        0,
        0,
        200,
        100,
        children: [
          box(
            '0',
            'Padding',
            0,
            0,
            200,
            50,
            children: [box('0/0', 'Text', 8, 8, 40, 16)],
          ),
          box('1', 'Button', 0, 50, 80, 50),
        ],
      ),
    );

    test('takes the deepest box over the point', () {
      expect(tree.nodeAtPoint(10, 10)?.type, 'Text');
    });

    test('and its ancestor where the child does not reach', () {
      expect(tree.nodeAtPoint(100, 10)?.type, 'Padding');
    });

    test('a point outside everything is null, not the root', () {
      expect(tree.nodeAtPoint(500, 500), isNull);
    });

    test('boxes are half-open, so an edge lands in exactly one', () {
      // Text spans x 8..48. The left edge is inside it and the right edge is
      // not, which is the rule everywhere else a rectangle is tested.
      expect(tree.nodeAtPoint(8, 10)?.type, 'Text');
      expect(tree.nodeAtPoint(47.9, 10)?.type, 'Text');
      expect(tree.nodeAtPoint(48, 10)?.type, 'Padding');
    });

    test('a node with no box is skipped, and its child is found', () {
      // A provider or a builder lays nothing out; the thing under the cursor
      // is its child.
      var withBuilder = InspectTree(
        entryId: 'e',
        root: InspectNode(
          id: '',
          type: 'Builder',
          children: [box('0', 'Text', 0, 0, 20, 20)],
        ),
      );
      expect(withBuilder.nodeAtPoint(5, 5)?.type, 'Text');
    });

    test('a child laid out beyond its parent is still found', () {
      // Which is what an overflow is — and an overflowing widget is exactly
      // the one somebody is pointing at.
      var overflowing = InspectTree(
        entryId: 'e',
        root: box(
          '',
          'Row',
          0,
          0,
          50,
          20,
          children: [box('0', 'Wide', 0, 0, 500, 20)],
        ),
      );
      expect(overflowing.nodeAtPoint(300, 10)?.type, 'Wide');
    });

    test('an empty tree answers nothing', () {
      expect(InspectTree.empty.nodeAtPoint(0, 0), isNull);
    });

    test('an offstage subtree is never the answer', () {
      // The shape a push leaves behind: the covered route's widgets keep
      // their old rects, which overlap the new screen — and sit *deeper*, so
      // before the flag they beat the widget actually on the picture.
      var pushed = InspectTree(
        entryId: 'e',
        root: box(
          '',
          'App',
          0,
          0,
          200,
          100,
          children: [
            InspectNode(
              id: '0',
              type: 'MenuScreen',
              offstage: true,
              layout: const InspectLayout(x: 0, y: 0, width: 200, height: 100),
              children: [
                // Deeper than anything on the new screen, and deliberately
                // not flagged itself: the walk prunes at the flagged top, so
                // a tree marked only there is still cut whole.
                box(
                  '0/0',
                  'Card',
                  0,
                  0,
                  200,
                  40,
                  children: [box('0/0/0', 'Text', 8, 8, 40, 16)],
                ),
              ],
            ),
            box('1', 'DrinkScreen', 0, 0, 200, 100),
          ],
        ),
      );
      expect(pushed.nodeAtPoint(10, 10)?.type, 'DrinkScreen');
    });
  });

  group('nodesFoldingOffstage', () {
    // App > [ Menu*(offstage) > Card* > Text*, Drink ] — the walk marks whole
    // subtrees, as the capture does.
    var root = InspectNode(
      id: '',
      type: 'App',
      children: [
        InspectNode(
          id: '0',
          type: 'Menu',
          offstage: true,
          children: [
            InspectNode(
              id: '0/0',
              type: 'Card',
              offstage: true,
              children: [
                const InspectNode(id: '0/0/0', type: 'Text', offstage: true),
              ],
            ),
          ],
        ),
        const InspectNode(id: '1', type: 'Drink'),
      ],
    );

    test('folds a hidden subtree to its top node', () {
      expect(root.nodesFoldingOffstage.map((n) => n.type), [
        'App',
        'Menu',
        'Drink',
      ]);
    });

    test('a walk started at hidden content reports all of it', () {
      // Whoever names the folded node has asked for what is inside.
      expect(root.children.first.nodesFoldingOffstage.map((n) => n.type), [
        'Menu',
        'Card',
        'Text',
      ]);
    });
  });
}

/// The ambient style is written as `"same"` when it would repeat the resolved
/// one — most texts, since most set no style of their own.
void _ambientSentinel() {
  group('the ambient style on the wire', () {
    InspectNode nodeWith({
      required Map<String, String> style,
      required Map<String, String> inherited,
    }) => InspectNode(
      id: '',
      type: 'Text',
      description: 'Text("Save")',
      textStyle: style,
      inheritedStyle: inherited,
    );

    const resolved = {'size': '14.0', 'weight': '400', 'color': '#1D1B20'};

    test('a style nobody overrode is not written twice', () {
      var json = nodeWith(style: resolved, inherited: resolved).toJson();

      expect(json['inherited'], 'same');
      expect(
        InspectNode.fromJson(json).inheritedStyle,
        resolved,
        reason: 'the sentinel resolves back to the resolved style',
      );
    });

    test('an ambient style that differs is written in full', () {
      var json = nodeWith(
        style: resolved,
        inherited: {...resolved, 'size': '22.0'},
      ).toJson();

      expect(json['inherited'], isA<Map<String, String>>());
      expect(InspectNode.fromJson(json).inheritedStyle['size'], '22.0');
    });

    test('nothing captured stays different from captured-and-identical', () {
      // The distinction the sentinel exists to keep: a reader that never
      // looked has no merge to show, and the detail pane offers no card.
      var none = InspectNode.fromJson({'id': '', 'type': 'Text'});
      expect(none.inheritedStyle, isEmpty);

      var same = InspectNode.fromJson({
        'id': '',
        'type': 'Text',
        'style': resolved,
        'inherited': 'same',
      });
      expect(same.inheritedStyle, resolved);
    });

    test('both spellings read the sentinel', () {
      var tree = InspectTree(
        entryId: null,
        root: nodeWith(style: resolved, inherited: resolved),
      );
      for (var compact in [false, true]) {
        var decoded = InspectTree.fromJson(tree.toJson(compact: compact));
        expect(
          decoded.root!.inheritedStyle,
          resolved,
          reason: 'compact: $compact',
        );
      }
    });
  });
}

/// An absolute path as this platform spells it: `/a/b.dart` on macOS and
/// Linux, `\a\b.dart` on Windows. A relative path is a name and reads with `/`
/// everywhere; an absolute one is for opening, so it stays native.
String _absolute(List<String> segments) =>
    p.joinAll([p.separator, ...segments]);
