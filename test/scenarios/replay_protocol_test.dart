import 'package:flutterware/scenario_replay_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ReplayIndex.merge', () {
    var shop = {
      'scenarios': [
        {
          'file': 'test/shop_test.dart',
          'scenario': 'Order',
          'steps': [
            {
              'position': '#10',
              'verb': 'tap',
              'keys': ['shop/total'],
            },
            {
              'position': '#2',
              'verb': 'tap',
              'keys': ['shop/menu', 'shop/title'],
              'point': 'iPhone 16 · en',
              'boxes': [
                ['shop/title', 'p0.1', 120.04, 50, 80, 17],
                ['shop/menu', 'p2.0', 16, 300, 60, 17],
                ['shop/title', 'w0', 0, 400, 393, 40],
              ],
            },
            {
              'position': '#1',
              'verb': 'pumpWidget',
              'keys': ['shop/title'],
            },
          ],
          'assets': ['assets/i18n/en.json'],
        },
        // Declared outside the package: nothing a page can name.
        {'scenario': 'Elsewhere', 'steps': [], 'assets': []},
      ],
      'commonAssets': ['AssetManifest.bin'],
      'fonts': ['Roboto'],
      'faces': ['Roboto:400'],
    };
    var again = {
      'scenarios': [
        {
          'file': 'test/shop_test.dart',
          'scenario': 'Order',
          'steps': [
            {
              'position': '#2',
              'keys': ['shop/cart'],
              'point': 'iPhone SE · fr',
              'boxes': [
                ['shop/cart', 'p0.0', 0, 0, 10, 10],
              ],
            },
          ],
          'assets': ['assets/logo.png'],
        },
      ],
      'fonts': ['MaterialIcons'],
    };

    test('keeps the union of what two processes saw', () {
      var index = ReplayIndex.merge([shop, again]);
      expect(index.scenarios, hasLength(1));
      var order = index.scenarios.single;
      expect(
        [for (var step in order.steps) step.position],
        ['#1', '#2', '#10'],
      );
      expect(order.steps[1].keys, ['shop/cart', 'shop/menu', 'shop/title']);
      expect(order.assets, ['assets/i18n/en.json', 'assets/logo.png']);
      expect(index.fonts, ['MaterialIcons', 'Roboto']);
      expect(index.faces, ['Roboto:400']);
    });

    test('keeps the boxes of the first point to reach a step', () {
      var step = ReplayIndex.merge([shop, again]).scenarios.single.steps[1];
      expect(step.point, 'iPhone 16 · en');
      expect(step.boxes, hasLength(3));
      expect(step.boxes.first.toJson(), [
        'shop/title',
        'p0.1',
        120.0,
        50.0,
        80.0,
        17.0,
      ]);
    });

    test('says where the index found each key at a step', () {
      var index = ReplayIndex.fromJson(ReplayIndex.merge([shop]).toJson());
      expect(index.addressesAt('test/shop_test.dart', 'Order', '#2'), {
        'shop/title': ['p0.1', 'w0'],
        'shop/menu': ['p2.0'],
      });
      expect(index.addressesAt('test/shop_test.dart', 'Order', '#9'), isEmpty);
    });

    test('says which steps show each key', () {
      var keys = ReplayIndex.merge([shop]).keys;
      expect(keys.keys, ['shop/menu', 'shop/title', 'shop/total']);
      expect([for (var ref in keys['shop/title']!) ref.position], ['#1', '#2']);
      expect(keys['shop/total']!.single.toJson(), {
        'file': 'test/shop_test.dart',
        'scenario': 'Order',
        'position': '#10',
      });
    });

    test('round-trips through JSON', () {
      var index = ReplayIndex.merge([shop, again]);
      var read = ReplayIndex.fromJson(index.toJson());
      expect(read.toJson(), index.toJson());
    });

    test('gives the page every asset of a file', () {
      var two = {
        'scenarios': [
          {
            'file': 'test/shop_test.dart',
            'scenario': 'Browse',
            'steps': [],
            'assets': ['assets/menu.svg'],
          },
        ],
      };
      var manifest = ReplayManifest.fromJson(
        ReplayIndex.merge([shop, two]).manifest.toJson(),
      );
      expect(manifest.commonAssets, ['AssetManifest.bin']);
      expect(manifest.assetsOf('test/shop_test.dart', 'Browse'), [
        'assets/menu.svg',
      ]);
      // The first scenario of a file may be the only one to read what the
      // app keeps in a static, and the page may run any of them first.
      expect(manifest.assetsOfFile('test/shop_test.dart'), {
        'assets/i18n/en.json',
        'assets/menu.svg',
      });
    });
  });

  test('positions order by branch, then by step', () {
    var positions = ['1#1', '#10', '0.1#2', '#2', '0#1', '0.1#1', '0.0#3'];
    expect(positions..sort(comparePositions), [
      '#2',
      '#10',
      '0#1',
      '0.0#3',
      '0.1#1',
      '0.1#2',
      '1#1',
    ]);
  });

  group('ReplayRequest', () {
    test('reads the address', () {
      var request = ReplayRequest.fromQuery({
        'file': ['test/shop_test.dart'],
        'scenario': ['Order'],
        'position': ['1#2'],
        'language': ['fr'],
        'draft': ['shop/title=Bonjour = salut', 'broken'],
        'locate': ['shop/title', 'shop/total'],
      })!;
      expect(request.toJson(), {
        'file': 'test/shop_test.dart',
        'scenario': 'Order',
        'position': '1#2',
        'language': 'fr',
        'drafts': {'shop/title': 'Bonjour = salut'},
        'locate': ['shop/title', 'shop/total'],
      });
      expect(ReplayRequest.fromJson(request.toJson()).locate, request.locate);
    });

    test('is none without a step', () {
      expect(
        ReplayRequest.fromQuery({
          'file': ['a'],
          'scenario': ['b'],
        }),
        isNull,
      );
    });

    test('reads a message', () {
      var request = ReplayRequest.fromJson({
        'type': ReplayMessages.run,
        'file': 'f',
        'scenario': 's',
        'position': '#1',
        'drafts': {'shop/title': 'Hallo'},
      });
      expect(request.drafts, {'shop/title': 'Hallo'});
      expect(request.language, isNull);
    });
  });

  test('a scenario picks the point a request asks for', () {
    var scenario = ReplayScenario(
      file: 'f',
      scenario: 's',
      points: const [
        ReplayPoint(
          testName: 's [A · en]',
          label: '',
          device: 'a',
          language: 'en',
        ),
        ReplayPoint(
          testName: 's [A · fr]',
          label: '',
          device: 'a',
          language: 'fr',
        ),
        ReplayPoint(
          testName: 's [B · fr]',
          label: '',
          device: 'b',
          language: 'fr',
        ),
      ],
    );
    expect(scenario.pointFor().testName, 's [A · en]');
    expect(scenario.pointFor(language: 'fr').testName, 's [A · fr]');
    expect(
      scenario.pointFor(language: 'fr', device: 'b').testName,
      's [B · fr]',
    );
    // Nothing in that language: the device still counts.
    expect(
      scenario.pointFor(language: 'nl', device: 'b').testName,
      's [B · fr]',
    );
  });

  test('a fixture that reads the disk says so', () {
    var said = describeReplayFailure(UnsupportedError('_Namespace'));
    expect(said, contains('dart:io'));
    expect(said, contains('_Namespace'));
    expect(describeReplayFailure(StateError('no')), 'Bad state: no');
  });
}
