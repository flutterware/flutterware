import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/network.dart' show storedZlib;
import 'package:flutterware/src/scenarios/replay_hooks.dart';
import 'package:flutterware/src/scenarios/replay_index.dart';

/// What the replay page and its index stand on: a hook at every step, named
/// by position, and a run that can be aimed at one branch of a split.
void main() {
  var steps = <String>[];
  setUp(() {
    steps = [];
    scenarioStepHook = (step) => steps.add('${step.position} ${step.verb}');
  });
  tearDown(() {
    scenarioStepHook = null;
    scenarioAimedBranches = null;
  });

  group('the hook sees every step, by position', () {
    scenario('across a split', (s) async {
      await s.pumpWidget(const _Menu());
      await s.split({
        'tea': () async {
          await s.tap('Tea');
        },
        'coffee': () async {
          await s.tap('Coffee');
          await s.tap('Back');
        },
      });
    });
    tearDown(() {
      // Each branch replays the trunk from the top, so its steps come round
      // again, under the same positions.
      expect(steps, [
        '#1 pumpWidget',
        '0#1 tap',
        '#1 pumpWidget',
        '1#1 tap',
        '1#2 tap',
      ]);
    });
  });

  group('an aimed run takes the branch it names and no other', () {
    setUp(() => scenarioAimedBranches = [1]);
    scenario('straight to the second branch', (s) async {
      await s.pumpWidget(const _Menu());
      await s.split({
        'tea': () async {
          await s.tap('Tea');
        },
        'coffee': () async {
          await s.tap('Coffee');
        },
      });
    });
    tearDown(() {
      expect(steps, ['#1 pumpWidget', '1#1 tap']);
    });
  });

  group('the running hook brackets each body', () {
    var running = <String?>[];
    setUp(() {
      running = [];
      scenarioRunningHook = running.add;
    });
    tearDown(() {
      scenarioRunningHook = null;
      expect(running, ['bracketed', null]);
    });
    scenario('bracketed', (s) async {
      await s.pumpWidget(const _Menu());
    });
  });

  group('a step shows what is on screen', () {
    late ({Set<String> keys, Set<String> fonts, Set<String> faces}) shown;
    setUp(() {
      TranslationIndex.recording = true;
      scenarioStepHook = (step) {
        if (step.position == '#2') shown = readShownStep(step.tester);
      };
    });
    tearDown(() {
      TranslationIndex.recording = false;
      TranslationIndex.reset();
      // The menu is still in the tree under the details page, and it is not
      // what this step shows.
      expect(shown.keys, {'shop/details'});
      expect(shown.faces, contains('Lobster:700'));
    });
    scenario('and not what a covered route keeps', (s) async {
      var t = indexTranslations('shop');
      await s.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: Text(
                        t('details', 'Details'),
                        style: const TextStyle(
                          fontFamily: 'Lobster',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                child: Text(t('menu', 'Menu')),
              ),
            ),
          ),
        ),
      );
      await s.tap('Menu');
    });
  });

  group('a draft is shown in place of the catalog', () {
    setUp(() => TranslationIndex.drafts['shop/title'] = 'Bienvenue {name}');
    tearDown(() => TranslationIndex.drafts.clear());
    scenario('placeholders and all', (s) async {
      var t = indexTranslations('shop');
      await s.pumpWidget(
        MaterialApp(
          home: Text(t('title', 'Welcome {name}').replaceAll('{name}', 'Ada')),
        ),
      );
      expect(find.text('Bienvenue Ada'), findsOneWidget);
    });
  });

  group('a key is located where it is drawn', () {
    late Map<String, List<Rect>> boxes;
    setUp(() {
      TranslationIndex.recording = true;
      TranslationIndex.drafts['shop/total'] = 'Grand total';
      scenarioStepHook = (step) {
        if (step.position == '#2') {
          boxes = locateKeys(step.tester, [
            'shop/title',
            'shop/total',
            'shop/menu',
            'shop/missing',
          ]);
        }
      };
    });
    tearDown(() {
      TranslationIndex.recording = false;
      TranslationIndex.drafts.clear();
      TranslationIndex.reset();
      // Found by the index, inside the paragraph it shares with other words.
      var title = boxes['shop/title']!.single;
      expect(title.left, greaterThan(100));
      expect(title.top, closeTo(50, 5));
      expect(title.height, closeTo(14, 4));
      // Found by its words: the draft.
      expect(boxes['shop/total']!.single.top, closeTo(200, 5));
      // On the route underneath, so not on screen.
      expect(boxes.containsKey('shop/menu'), isFalse);
      expect(boxes.containsKey('shop/missing'), isFalse);
    });
    scenario('in the view, in logical pixels', (s) async {
      var t = indexTranslations('shop');
      await s.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Material(
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            top: 50,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(text: 'Welcome to '),
                                  TextSpan(text: t('title', 'Brewline')),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top: 200,
                            child: Text(t('total', 'Total')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: Text(t('menu', 'Menu')),
              ),
            ),
          ),
        ),
      );
      await s.tap(const Key('open'));
    });
  });

  group('the index records where each key is, placeholders included', () {
    late List<({String key, String at, Rect rect})> recorded;
    late Map<String, List<Rect>> again;
    setUp(() {
      TranslationIndex.recording = true;
      scenarioStepHook = (step) {
        recorded = keyBoxes(step.tester);
        var thanks = recorded.firstWhere((box) => box.key == 'shop/thanks');
        // Found by address alone, as a page does where words cannot name
        // the key: the name asked for is not one the text knows.
        again = locateKeys(
          step.tester,
          ['shop/elsewhere'],
          addresses: {
            'shop/elsewhere': [thanks.at],
          },
        );
      };
    });
    tearDown(() {
      TranslationIndex.recording = false;
      TranslationIndex.reset();
      expect(
        [for (var box in recorded) box.key],
        ['shop/title', 'shop/thanks'],
      );
      var thanks = recorded.last;
      expect(thanks.at, 'p1.0');
      expect(thanks.rect.top, closeTo(100, 5));
      expect(again['shop/elsewhere'], [thanks.rect]);
    });
    scenario('in the run that writes it', (s) async {
      var t = indexTranslations('shop');
      var expand = indexExpansions('shop');
      await s.pumpWidget(
        MaterialApp(
          home: Material(
            child: Stack(
              children: [
                Positioned(top: 20, child: Text(t('title', 'Brewline'))),
                Positioned(
                  top: 100,
                  child: Text(
                    expand(
                      'thanks',
                      t('thanks', 'Thanks {name}').replaceAll('{name}', 'Ada'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  });

  test('the web placeholder PNG is a zlib stream any decoder reads', () {
    for (var size in [0, 10, 0xFFFF, 0xFFFF + 1, 200000]) {
      var data = [for (var i = 0; i < size; i++) i * 7 % 256];
      expect(ZLibDecoder().convert(storedZlib(data)), data, reason: '$size');
    }
  });

  test('a position names its branches', () {
    expect(branchesOfPosition('#3'), isEmpty);
    expect(branchesOfPosition('1.0#2'), [1, 0]);
    expect(branchesOfPosition('3'), isNull);
    expect(branchesOfPosition('a#2'), isNull);
    expect(branchesOfPosition('1#x'), isNull);
  });
}

class _Menu extends StatelessWidget {
  const _Menu();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(onPressed: () {}, child: const Text('Tea')),
          TextButton(onPressed: () {}, child: const Text('Coffee')),
          TextButton(onPressed: () {}, child: const Text('Back')),
        ],
      ),
    ),
  );
}
