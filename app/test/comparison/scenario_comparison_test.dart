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

  // Two identical pictures are the *reason* a retarget is worth saying, not a
  // reason to stay quiet: the same step now names something else.
  test('a retargeted step is reported even when nothing moved', () {
    var result = compare(
      [shot(1, verb: 'tap', target: "key 'pay'")],
      [shot(1, verb: 'tap', target: "key 'pay_now'")],
    );

    expect(result.items.single.state, ComparedState.changed);
    expect(result.items.single.note, contains("key 'pay' → key 'pay_now'"));
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
