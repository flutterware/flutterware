import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/scenario_diff.dart';
import 'package:flutterware_app/src/comparison/scenario_alignment.dart';
import 'package:test/test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

/// One scenario's two runs, compared: the alignment on top, the channels
/// underneath, and pass/fail outranking both.
void main() {
  Uint8List frame(int value) =>
      Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, value);

  ScenarioStepShot shot(
    int index, {
    String? name,
    String? verb,
    String? target,
    int? parent,
    String? branch,
    String? position,
    int pixels = 0,
    List<String> texts = const [],
    List<Map<String, Object?>> events = const [],
    String? failure,
    String? description,
  }) => ScenarioStepShot(
    step: AlignableStep(
      index: index,
      position: position ?? '#$index',
      parent: parent,
      branch: branch,
      name: name,
      verb: verb,
      target: target,
      failure: failure,
    ),
    rgba: frame(pixels),
    width: 8,
    height: 8,
    tree: InspectNode(
      id: '',
      type: 'Screen',
      description: description,
      createdByLocalProject: true,
      children: const [],
    ),
    texts: texts,
    events: events,
    failure: failure,
  );

  ScenarioComparison compare(
    List<ScenarioStepShot> base,
    List<ScenarioStepShot> head,
  ) => compareScenarioSteps(
    scenario: 'test/checkout.dart#Checkout',
    base: base,
    head: head,
  );

  test('two identical runs say nothing changed', () {
    var run = [shot(1, name: 'Cart'), shot(2, name: 'Pay', parent: 1)];

    var result = compare(run, run);

    expect(result.state, ComparedState.same);
    expect(result.items.every((i) => i.state == ComparedState.same), isTrue);
  });

  test('a step whose picture moved is the one row that changed', () {
    var base = [shot(1, name: 'Cart'), shot(2, name: 'Pay', parent: 1)];
    var head = [
      shot(1, name: 'Cart'),
      shot(2, name: 'Pay', parent: 1, pixels: 255),
    ];

    var result = compare(base, head);

    expect(result.state, ComparedState.changed);
    expect(result.items.first.state, ComparedState.same);
    expect(result.items.last.state, ComparedState.changed);
  });

  test('an inserted step is added, and the rest still match', () {
    var base = [shot(1, name: 'Cart'), shot(2, name: 'Pay', parent: 1)];
    var head = [
      shot(1, name: 'Cart'),
      shot(2, name: 'Consent', parent: 1),
      shot(3, name: 'Pay', parent: 2),
    ];

    var result = compare(base, head);

    expect(result.items.map((i) => '${i.id}:${i.state.name}'), [
      'Cart:same',
      'Consent:added',
      'Pay:same',
    ]);
  });

  // `added` outranks `changed`, so carrying a step's own word up sorted a flow
  // that gained one line above a flow that genuinely came out different — and
  // called a scenario that has existed for months new.
  test('a scenario that gained a step changed, it was not added', () {
    var result = compare(
      [shot(1, name: 'Cart')],
      [shot(1, name: 'Cart'), shot(2, name: 'Pay', parent: 1)],
    );

    expect(result.items.last.state, ComparedState.added);
    expect(result.state, ComparedState.changed);
  });

  // A new split branch is one decision in the source; listing its steps as N
  // additions describes that decision N times.
  test('a branch that appeared is a row of its own, not N rows', () {
    var base = [
      shot(1, name: 'Cart'),
      shot(2, name: 'Address', parent: 1, branch: 'guest', position: '0#1'),
    ];
    var head = [
      ...base,
      shot(3, name: 'Sheet', parent: 1, branch: 'apple pay', position: '1#1'),
      shot(4, name: 'Done', parent: 3, position: '1#2'),
    ];

    var result = compare(base, head);

    expect(result.branches, hasLength(1));
    expect(result.branches.single.label, 'apple pay');
    expect(result.branches.single.steps, 2);
    expect(result.state, ComparedState.changed);
    expect(result.items.every((i) => i.state == ComparedState.same), isTrue);
  });

  group('the channels', () {
    test('the tree explains a step whose pixels moved', () {
      var base = [shot(1, name: 'Cart', description: 'Text("Save")')];
      var head = [
        shot(1, name: 'Cart', pixels: 255, description: 'Text("Pay")'),
      ];

      var result = compare(base, head);

      expect(result.items.single.tree!.diff.deltas.single.head, 'Text("Pay")');
    });

    // The channel that catches what no picture can: a duplicated request, a
    // new analytics call, an N+1 that appeared.
    test('an extra request is a change with no changed pixel', () {
      var base = [
        shot(
          1,
          name: 'Cart',
          events: [
            {'channel': 'network', 'title': 'GET /cart'},
          ],
        ),
      ];
      var head = [
        shot(
          1,
          name: 'Cart',
          events: [
            {'channel': 'network', 'title': 'GET /cart'},
            {'channel': 'network', 'title': 'GET /cart'},
          ],
        ),
      ];

      var result = compare(base, head);

      expect(result.items.single.state, ComparedState.changed);
      expect(result.items.single.events!.added, ['network GET /cart']);
      expect(result.items.single.pixels!.changed, isFalse);
    });

    // An id in a path is how one request finds the other; it is not a reason
    // to call them the same request.
    //
    // This used to read `same`, on the reasoning that an id is the commonest
    // way a run differs from itself for no reason at all. Under a pinned clock
    // and FakeAsync there is no such way: an order id that moves between two
    // runs of one commit is the app minting it nondeterministically, which is
    // a bug worth reporting, and between two commits it is the flow hitting a
    // different record, which is the finding. Masking both away was the same
    // hole that let a status flip pass as no change.
    //
    // The masking still does its real job — the two events *pair*, so this is
    // one line saying which id moved rather than one request vanishing and
    // another arriving.
    test('an id in a url pairs the two requests, and names what moved', () {
      List<Map<String, Object?>> events(String url) => [
        {'channel': 'network', 'title': 'GET $url'},
      ];

      var result = compare(
        [shot(1, name: 'Cart', events: events('/order/8814'))],
        [shot(1, name: 'Cart', events: events('/order/9921'))],
      );

      var events_ = result.items.single.events!;
      expect(result.items.single.state, ComparedState.changed);
      expect(events_.added, isEmpty);
      expect(events_.removed, isEmpty);
      expect(events_.deltas.single.property, 'title');
      expect(events_.deltas.single.base, 'GET /order/8814');
      expect(events_.deltas.single.head, 'GET /order/9921');
    });

    test('a request that was not made before is named', () {
      var result = compare(
        [shot(1, name: 'Cart')],
        [
          shot(
            1,
            name: 'Cart',
            events: [
              {'channel': 'analytics', 'title': 'checkout_started'},
            ],
          ),
        ],
      );

      expect(result.items.single.events!.added, ['analytics checkout_started']);
    });

    test('texts carry a finding on their own', () {
      var result = compare(
        [
          shot(1, name: 'Cart', texts: ['Save']),
        ],
        [
          shot(1, name: 'Cart', texts: ['Pay']),
        ],
      );

      expect(result.items.single.texts!.added, ['Pay']);
    });
  });

  group('failure outranks everything', () {
    test('a scenario that stopped completing is the verdict', () {
      var base = [shot(1, name: 'Cart'), shot(2, name: 'Pay', parent: 1)];
      var head = [
        shot(1, name: 'Cart'),
        shot(2, name: 'Pay', parent: 1, failure: 'nothing matches "Pay"'),
      ];

      var result = compare(base, head);

      expect(result.state, ComparedState.broke);
      expect(result.items.last.note, contains('nothing matches'));
      expect(result.items.last.pixels, isNull);
    });

    test('a step that already failed on base says so quietly', () {
      var result = compare(
        [shot(1, name: 'Cart', failure: 'boom')],
        [shot(1, name: 'Cart')],
      );

      expect(result.state, ComparedState.wasBroken);
    });

    // A consumer's base replay failed in its body, between verbs, on a step
    // the head never took. It was a removed step, removed steps fold into
    // `changed`, and a broken baseline read as the branch's change with its
    // error nowhere on the page.
    test('a base failure on a step head never took is the base breaking', () {
      var result = compare(
        [
          shot(1, name: 'Form'),
          shot(2, parent: 1, failure: 'Expected: "Saved"\nActual: <none>'),
        ],
        [shot(1, name: 'Form'), shot(2, name: 'Saved', parent: 1)],
      );

      expect(result.state, ComparedState.wasBroken);
      expect(result.baseErrors, ['Expected: "Saved"']);
      var failed = result.items.singleWhere((i) => i.note != null);
      expect(failed.state, ComparedState.wasBroken);
      expect(failed.label, 'failed: Expected: "Saved"');
      expect(failed.note, contains('Actual: <none>'));
    });

    test('a head failure on a step base never took is the branch breaking', () {
      var result = compare(
        [shot(1, name: 'Cart'), shot(2, name: 'Pay', parent: 1)],
        [
          shot(1, name: 'Cart'),
          shot(2, parent: 1, failure: 'did not finish within 30s'),
        ],
      );

      expect(result.state, ComparedState.broke);
      expect(result.headErrors, ['did not finish within 30s']);
      expect(
        result.items.singleWhere((i) => i.note != null).state,
        ComparedState.broke,
      );
    });

    test('both sides failing carries both messages', () {
      var result = compare(
        [shot(1, name: 'Cart', failure: 'base broke')],
        [shot(1, name: 'Cart', failure: 'head broke')],
      );

      expect(result.state, ComparedState.failed);
      expect(result.items.single.note, 'head: head broke\nbase: base broke');
      expect(result.toJson()['errors'], {
        'base': ['base broke'],
        'head': ['head broke'],
      });
    });

    test('a failure with no step at all still decides the verdict', () {
      var result = compareScenarioSteps(
        scenario: 'test/checkout.dart#Checkout',
        base: [shot(1, name: 'Cart')],
        head: const [],
        headErrors: const ['setUpAll threw'],
      );

      expect(result.state, ComparedState.broke);
      expect(result.headErrors, ['setUpAll threw']);
    });
  });

  // A slow host may make a run inconclusive; it must never make it different.
  group('a side is believed only once it is a result', () {
    ScenarioReplay replay({String? failure, bool complete = true}) =>
        ScenarioReplay([
          shot(1, name: 'Cart'),
          if (failure != null) shot(2, parent: 1, failure: failure),
        ], complete: complete);

    test('a clean replay is believed the first time', () {
      var side = confirmSide(replay(), null, side: 'the base');

      expect(side.isResult, isTrue);
    });

    test('a failure that reproduces is a result', () {
      var second = replay(failure: 'nothing matches "Pay" in _Widget#1a2b3');

      var side = confirmSide(
        replay(failure: 'nothing matches "Pay" in _Widget#9f8e7'),
        second,
        side: 'the base',
      );

      expect(side.replay, same(second));
    });

    test('a failure that passes when replayed again is not a result', () {
      var side = confirmSide(
        replay(failure: 'an error dialog was showing'),
        replay(),
        side: 'the base',
      );

      expect(side.isResult, isFalse);
      expect(
        side.inconclusive,
        allOf(
          startsWith('the base failed once and passed when replayed again'),
          contains('an error dialog was showing'),
          contains('racing real time'),
        ),
      );
    });

    test('a failure that changes when replayed again is not a result', () {
      var side = confirmSide(
        replay(failure: 'first'),
        replay(failure: 'second'),
        side: 'this branch',
      );

      expect(side.inconclusive, contains('failed differently'));
    });

    // A deadline says nothing about what a scenario draws, only about how
    // long the machine took to draw it.
    test(
      'a replay abandoned once and finished the second time is the second',
      () {
        var second = replay();

        var side = confirmSide(
          replay(failure: 'did not finish within 30s', complete: false),
          second,
          side: 'this branch',
        );

        expect(side.replay, same(second));
      },
    );

    // The deadline is a progress deadline, which a slow machine stretches
    // without firing: stalling twice is the scenario hanging.
    test('a replay abandoned twice is a result: the scenario hangs', () {
      var second = replay(
        failure: 'made no progress for 30s (for 31.2s)',
        complete: false,
      );

      var side = confirmSide(
        replay(
          failure: 'made no progress for 30s (for 30.4s)',
          complete: false,
        ),
        second,
        side: 'this branch',
      );

      expect(side.replay, same(second));
    });

    test('a replay abandoned, then failing, is not a result', () {
      var side = confirmSide(
        replay(failure: 'made no progress for 30s', complete: false),
        replay(failure: 'Expected: "Saved"'),
        side: 'the base',
      );

      expect(side.inconclusive, contains('did not finish, then failed'));
    });
  });

  group('two replays of one side', () {
    ScenarioReplay replay({
      String? failure,
      bool complete = true,
      int px = 0,
    }) => ScenarioReplay([
      shot(1, name: 'Cart', pixels: px),
      if (failure != null) shot(2, parent: 1, failure: failure),
    ], complete: complete);

    test('agree when they fail the same way', () {
      expect(
        replaysAgree(
          replay(failure: 'nothing matches "Pay" in _W#1a2b3'),
          replay(failure: 'nothing matches "Pay" in _W#9f8e7'),
        ),
        isTrue,
      );
    });

    test('agree when they both hang, whatever the sentence says', () {
      expect(
        replaysAgree(
          replay(failure: 'no progress (for 30.2s)', complete: false),
          replay(failure: 'no progress (for 31.9s)', complete: false),
        ),
        isTrue,
      );
    });

    test('disagree when they fail differently, or draw differently', () {
      expect(replaysAgree(replay(failure: 'a'), replay(failure: 'b')), isFalse);
      expect(replaysAgree(replay(), replay(failure: 'a')), isFalse);
      expect(replaysAgree(replay(), replay(px: 255)), isFalse);
    });
  });

  test('a scenario not compared travels as skipped, with its sentence', () {
    var json = const ScenarioComparison.notCompared(
      scenario: 'test/checkout.dart#Checkout',
      inconclusive: 'The base failed once and passed when replayed again.',
      baseErrors: ['boom'],
    ).toJson();

    expect(json['state'], 'skipped');
    var back = ScenarioComparison.fromJson(json);
    expect(back.compared, isFalse);
    expect(back.inconclusive, startsWith('The base failed once'));
    expect(back.baseErrors, ['boom']);
  });

  // The channels decide the state and the retarget only explains it: two
  // identical pictures are the proof the step did the same thing, so it is a
  // fact about the test file. Counted as a change, one helper that went from
  // an index to a key put four whole flows of a real suite among the findings.
  test('a step found another way that drew the same thing is the same', () {
    var result = compare(
      [shot(1, verb: 'tap', target: "key 'pay'")],
      [shot(1, verb: 'tap', target: "key 'pay_now'")],
    );

    var step = result.items.single;
    expect(result.state, ComparedState.same);
    expect(step.state, ComparedState.same);
    expect(step.note, contains('the test finds its target another way'));
    expect(step.note, contains("key 'pay' → key 'pay_now'"));
    expect(step.retargeted, (base: "key 'pay'", head: "key 'pay_now'"));
  });

  // Here it earns its place: the difference may be the widget it now reaches.
  test('a step found another way that also changed says both', () {
    var result = compare(
      [shot(1, verb: 'tap', target: "key 'pay'")],
      [shot(1, verb: 'tap', target: "key 'pay_now'", pixels: 255)],
    );

    var step = result.items.single;
    expect(step.state, ComparedState.changed);
    expect(step.pixels!.changed, isTrue);
    expect(step.note, contains('can be the widget it reached'));
    expect(step.retargeted, isNotNull);
  });

  // A `Shot` name taken away moves the signature and leaves the target where
  // it was: "aimed at something else: X → X" is what this used to print.
  test('a renamed step with the same target is not called retargeted', () {
    var result = compare(
      [shot(1, name: 'Pay', verb: 'tap', target: "key 'pay'")],
      [shot(1, verb: 'tap', target: "key 'pay'")],
    );

    var step = result.items.single;
    expect(step.retargeted, isNull);
    expect(step.note, contains('names this step another way'));
    expect(step.note, contains("Pay → tap key 'pay'"));
  });

  test('a retarget survives the json, as a field', () {
    var result = compare(
      [shot(1, verb: 'tap', target: "key 'pay'")],
      [shot(1, verb: 'tap', target: "key 'pay_now'")],
    );

    var read = ScenarioComparison.fromJson(result.toJson());

    expect(read.items.single.retargeted, (
      base: "key 'pay'",
      head: "key 'pay_now'",
    ));
  });

  group('differingPart', () {
    test('leaves out the words two long targets share', () {
      var (:base, :head) = differingPart(
        'widget with type "Chip" descending from widget with type "Question" '
            '(ignoring all but index 10) (ignoring all but first)',
        'widget with type "Chip" descending from widget with key [GlobalKey#] '
            '(ignoring all but first)',
      );

      expect(base, '… type "Question" (ignoring all but index 10) …');
      expect(head, '… key [GlobalKey#] …');
    });

    // By words: `_now` alone would be the character-wise answer.
    test('prints a short target whole', () {
      expect(differingPart("key 'pay'", "key 'pay_now'"), (
        base: "key 'pay'",
        head: "key 'pay_now'",
      ));
    });

    // Words only one side has would leave the other side printing nothing.
    test('gives an insertion the words either side of it', () {
      var shared = 'widget with type "Chip" descending from widget with type';
      var (:base, :head) = differingPart(
        '$shared "Question" (first)',
        '$shared "Question" (index 3) (first)',
      );

      expect(base, '… "Question" (first)');
      expect(head, '… "Question" (index 3) (first)');
    });
  });

  // Measured on a real 54-scenario suite: 51 repeated a step id, and one flow
  // had 17 of them for its 101 steps. *Next* walked in a circle, a link to any
  // repeat opened the first, and every step of a group showed one picture.
  group('step ids', () {
    FrameRef ref(String path) => FrameRef(path: path, width: 8, height: 8);

    ScenarioStepShot next(int index, {int? parent}) => ScenarioStepShot(
      step: AlignableStep(
        index: index,
        position: '#$index',
        parent: parent,
        verb: 'tap',
        target: '"Next"',
      ),
      rgba: frame(0),
      width: 8,
      height: 8,
      tree: null,
      frame: ref('frames/$index.rgba'),
    );

    test('a repeated step gets an id of its own, and its own frames', () {
      var run = [next(1), next(2, parent: 1), next(3, parent: 2)];

      var result = compare(run, run);

      expect(
        [for (var item in result.items) item.id],
        ['tap "Next"', 'tap "Next" (2)', 'tap "Next" (3)'],
      );
      // The label is what a reader sees, and it does not grow a number.
      expect({for (var item in result.items) item.label}, {'tap "Next"'});
      expect(
        [for (var item in result.items) result.frames[item.id]!.head!.path],
        ['frames/1.rgba', 'frames/2.rgba', 'frames/3.rgba'],
      );
    });

    test('survive the json', () {
      var run = [next(1), next(2, parent: 1)];

      var read = ScenarioComparison.fromJson(compare(run, run).toJson());

      expect(
        [for (var item in read.items) item.id],
        ['tap "Next"', 'tap "Next" (2)'],
      );
      expect(read.frames['tap "Next" (2)']!.head!.path, 'frames/2.rgba');
    });

    // A file written before ids were unique: a reader that trusts it loops.
    test('are claimed again when a file repeats them', () {
      var read = ScenarioComparison.fromJson({
        'id': 'test/checkout.dart#Checkout',
        'state': 'same',
        'steps': [
          for (var path in ['frames/1.rgba', 'frames/2.rgba'])
            {
              'id': 'tap "Next"',
              'state': 'same',
              'frames': {
                'head': {'path': path, 'width': 8, 'height': 8},
              },
            },
        ],
      });

      expect(
        [for (var item in read.items) item.id],
        ['tap "Next"', 'tap "Next" (2)'],
      );
      expect(read.frames['tap "Next"']!.head!.path, 'frames/1.rgba');
      expect(read.frames['tap "Next" (2)']!.head!.path, 'frames/2.rgba');
    });

    // An authored name can end in a number of its own.
    test('never hand out one a step already has', () {
      var ids = StepIds();

      expect(
        [
          for (var path in ['Next', 'Next (2)', 'Next']) ids.claim(path),
        ],
        ['Next', 'Next (2)', 'Next (3)'],
      );
    });
  });

  test('the json carries the steps, the branches and the verdict', () {
    var base = [shot(1, name: 'Cart')];
    var head = [
      shot(1, name: 'Cart'),
      shot(2, name: 'Extra', parent: 1, branch: 'new', position: '0#1'),
    ];

    var json = compare(base, head).toJson();

    expect(json['id'], 'test/checkout.dart#Checkout');
    expect(json['state'], 'changed');
    expect((json['branches']! as List).single, containsPair('label', 'new'));
    expect(json['steps']! as List, hasLength(1));
  });
}
