import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
import 'package:flutterware_app/src/inspect/screen_read.dart';

/// The one shaping the three surfaces share. Run reads a live app's tree,
/// previews a tree it just rendered, scenarios one off disk — and from here
/// on there is a single implementation.
void main() {
  /// A screen with two rows of controls under a scaffold's worth of wrappers,
  /// so the filtered and unfiltered readings differ.
  InspectTree fixture() => InspectTree.fromJson({
    'root': {
      'id': '',
      'type': 'MaterialApp',
      'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
      'children': [
        {
          'id': '0',
          'type': 'Padding',
          'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
          'children': [
            {
              'id': '0/0',
              'type': 'Column',
              'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 800},
              'children': [
                {
                  'id': '0/0/0',
                  'type': 'Text',
                  'description': 'Text("Basket")',
                  'layout': {'x': 0, 'y': 0, 'width': 400, 'height': 24},
                },
                {
                  'id': '0/0/1',
                  'type': 'ElevatedButton',
                  'label': 'Pay',
                  'layout': {'x': 0, 'y': 40, 'width': 200, 'height': 48},
                },
                {
                  'id': '0/0/2',
                  'type': 'Checkbox',
                  'label': 'Gift wrap',
                  'selected': false,
                  'layout': {'x': 0, 'y': 100, 'width': 40, 'height': 40},
                },
              ],
            },
          ],
        },
      ],
    },
  });

  ScreenRead read(Map<String, Object?> arguments, {bool tree = false}) =>
      ScreenRead.of(
        fixture(),
        arguments,
        wantsTree: tree,
        wantsStyles: arguments['styles'] == true,
      );

  test('the screen is what comes back when nothing is asked', () {
    var result = read(const {});

    expect(result.screen, isNotNull);
    expect(result.tree, isNull, reason: 'the expensive one stays opt-in');
    expect(result.find, isNull);
    expect(result.at, isNull);
    expect(result.styles, isNull);
    // The node count rides free either way — it is what says whether asking
    // for the tree is affordable.
    expect(result.nodes, greaterThan(0));
    expect(result.reported(wantsShot: false), ['screen']);
  });

  test('screen: false leaves the queries and nothing else', () {
    var result = read(const {'screen': false, 'find': 'Pay'});

    expect(result.screen, isNull);
    expect(result.find, hasLength(1));
    expect(result.reported(wantsShot: true), ['find', 'screenshot']);
  });

  test('find matches a type, a description or a label', () {
    expect(read(const {'find': 'ElevatedButton'}).find, hasLength(1));
    expect(read(const {'find': 'basket'}).find, hasLength(1));
    expect(
      read(const {'find': 'gift'}).find!.single['type'],
      'Checkbox',
      reason: 'the semantics label is searchable, not only the widget text',
    );
  });

  test('a found node is flat: a child count, never a subtree', () {
    var found = read(const {'find': 'MaterialApp'}).find!.single;

    expect(found['children'], 3, reason: 'a count, not the children');
    expect(found.values.whereType<List>().where((v) => v.length > 4), isEmpty);
    // Measured: a node serialised whole came back as 36,512 tokens.
    expect(found.toString().length, lessThan(400));
  });

  test('at is innermost-last, and skips the wrappers', () {
    var chain = read(const {'at': '10,10'}).at!;

    expect(chain.last['type'], 'Text');
    expect(
      chain.map((n) => n['type']),
      isNot(contains('Padding')),
      reason: 'the noise filter runs before the chain is cut',
    );
  });

  test('at answers empty when the point missed', () {
    expect(read(const {'at': '500,900'}).at, isEmpty);
  });

  test('a point that is not one rides the note — the verb still landed', () {
    var result = read(const {'at': 'the button'});

    expect(result.at, isNull);
    expect(result.screen, isNotNull);
    expect(result.note, contains('not a point'));
  });

  test('the tree is scoped, and a bad root is a note rather than a throw', () {
    expect(read(const {}, tree: true).tree, isNotNull);

    var refused = read(const {'treeRoot': '9/9/9'}, tree: true);
    expect(refused.tree, isNull);
    expect(refused.screen, isNotNull, reason: 'the rest of the read stands');
    expect(refused.note, contains('9/9/9'));
  });

  test('no tree at all is an empty read, not a crash', () {
    var result = ScreenRead.of(
      null,
      const {'find': 'Pay'},
      wantsTree: true,
      wantsStyles: true,
    );

    expect(result.screen, isNull);
    expect(result.find, isNull);
    expect(result.reported(wantsShot: false), isEmpty);
  });

  test('a hit says what it renders as, in one line rather than ten', () {
    var node = InspectNode.fromJson({
      'id': '0',
      'type': 'Text',
      'description': 'Text("Save")',
      'style': {
        'debugLabel': '(englishLike bodyMedium 2021).merge(…)',
        'color': '#1D1B20',
        'family': 'Roboto',
        'size': '14.0',
        'weight': '400',
        'letterSpacing': '0.3',
        'height': '1.4x',
      },
    });

    // The whole map is ~70 tokens and thirty hits of it is most of a reply.
    // What a reader scans a list *for* is the four fields.
    expect(ScreenRead.describe(node, null)['style'], '14.0/400 #1D1B20 Roboto');
  });

  test('a hit that draws no text says nothing about style', () {
    var node = InspectNode.fromJson({'id': '0', 'type': 'Padding'});
    expect(ScreenRead.describe(node, null).containsKey('style'), isFalse);
  });

  test('the offer names the drill-down, because a schema is read once', () {
    expect(
      ScreenRead.offer,
      allOf(
        contains('find'),
        contains('at'),
        contains('styles'),
        contains('lens'),
      ),
    );
  });
}
