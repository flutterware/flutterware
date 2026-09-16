import 'package:flutterware/scenarios_report.dart';
import 'package:test/test.dart';

ScenarioRunStep _step(
  String position, {
  String? digest,
  String? name,
  String? statusBrightness,
  String? navBrightness,
  double? keyboard,
  bool settled = true,
  bool landed = true,
}) => ScenarioRunStep(
  index: 1,
  position: position,
  auto: name == null,
  name: name,
  digest: digest,
  statusBrightness: statusBrightness,
  navBrightness: navBrightness,
  keyboard: keyboard,
  settled: settled,
  landed: landed,
);

ScenarioRunResult _run(
  List<ScenarioRunStep> steps, {
  Map<String, String>? axes,
  String output = 'build/out',
  String time = 'fake',
}) => ScenarioRunResult(
  packages: [
    ScenarioRunPackage(
      path: 'packages/app',
      output: output,
      axes: axes,
      time: time,
      scenarios: [
        ScenarioRunOutcome(
          file: 'test/scenarios/shop_test.dart',
          name: 'Order a cappuccino',
          ok: true,
          steps: steps,
        ),
      ],
    ),
  ],
);

/// Two runs of one suite, compared — the check that a green suite is also a
/// deterministic one.
void main() {
  test('a suite that does not move reports nothing', () {
    var drift = compareScenarioRuns(
      _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'bbbb')]),
      _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'bbbb')]),
    );

    expect(drift.isEmpty, isTrue);
    expect(drift.compared, 2);
    expect(drift.summary, isNull);
  });

  test('two runs on the real clock never differ by pixels', () {
    var drift = compareScenarioRuns(
      _run([
        _step('#1', digest: 'aaaa', name: 'Menu', settled: true),
      ], time: 'real'),
      _run([
        _step('#1', digest: 'bbbb', name: 'Menu', settled: false),
      ], time: 'real'),
    );

    expect(drift.compared, 1);
    expect(drift.changed.single.what, [ScenarioDriftFacet.settled]);
    expect(drift.pixelsIgnored, isTrue);
    expect(drift.summary, contains('pictures not compared (real clock)'));
    expect(ScenarioRunDrift.fromJson(drift.toJson()).pixelsIgnored, isTrue);
  });

  test('a step whose pixels moved is named, with its shot name', () {
    var drift = compareScenarioRuns(
      _run([
        _step('#1', digest: 'aaaa', name: 'Menu'),
        _step('#2', digest: 'bbbb', name: 'Cart'),
      ]),
      _run([
        _step('#1', digest: 'aaaa', name: 'Menu'),
        _step('#2', digest: 'cccc', name: 'Cart'),
      ]),
    );

    expect(drift.changed.single.label, 'Order a cappuccino · Cart');
    expect(drift.changed.single.what, [ScenarioDriftFacet.pixels]);
    expect(drift.summary, '1 of 2 steps differ');
    expect(drift.nameMatched, 2);
    expect(drift.unanchored, 0);
  });

  group('pairing', () {
    test('a shot name holds its step still when one is inserted above it', () {
      // The whole reason a position is not enough. `position` counts captures
      // since its branch began, so the inserted step renumbers both the ones
      // below it — and matching on that answers with a cascade: every step
      // below the cut reported changed, added and removed at once. On a suite
      // that had genuinely moved in 51 places it read as 122 changed, 22
      // added and 46 removed, essentially all of it phantom.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart'),
          _step('#2', digest: 'bbbb', name: 'Checkout'),
        ]),
        _run([
          _step('#1', digest: 'nnnn'),
          _step('#2', digest: 'aaaa', name: 'Cart'),
          _step('#3', digest: 'bbbb', name: 'Checkout'),
        ]),
      );

      expect(drift.changed, isEmpty);
      expect(drift.removed, isEmpty);
      expect(drift.added.single.position, '#1');
    });

    test('an unnamed step rides the name above it', () {
      // It has no name of its own, but it does not need one: it is pinned to
      // the last shot plus its distance from it, so an insertion before that
      // shot moves neither.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart'),
          _step('#2', digest: 'bbbb'),
        ]),
        _run([
          _step('#1', digest: 'nnnn'),
          _step('#2', digest: 'aaaa', name: 'Cart'),
          _step('#3', digest: 'bbbb'),
        ]),
      );

      expect(drift.changed, isEmpty);
      expect(drift.removed, isEmpty);
      expect(drift.added.single.position, '#1');
      // The inserted step is the only one with no name above it at all.
      expect(drift.nameMatched, 1);
      expect(drift.unanchored, 0);
    });

    test('a name repeated in a loop still names one step each pass', () {
      // Shot names are not unique within a scenario. Two passes of the same
      // loop carry the same name, and collapsing them would compare the first
      // pass against the second.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'Row'),
          _step('#2', digest: 'bbbb', name: 'Row'),
        ]),
        _run([
          _step('#1', digest: 'aaaa', name: 'Row'),
          _step('#2', digest: 'zzzz', name: 'Row'),
        ]),
      );

      expect(drift.compared, 2);
      expect(drift.changed.single.position, '#2');
    });

    test('a branch carries the name it forked under', () {
      // A `split` gives one parent several children. Each child continues from
      // the anchor the trunk had reached, so its first unnamed step is pinned
      // rather than loose — and the two children do not collide, because the
      // branch path is part of the key.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart'),
          _step('0#1', digest: 'bbbb'),
          _step('1#1', digest: 'cccc'),
        ]),
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart'),
          _step('0#1', digest: 'bbbb'),
          _step('1#1', digest: 'dddd'),
        ]),
      );

      expect(drift.compared, 3);
      expect(drift.unanchored, 0);
      expect(drift.changed.single.position, '1#1');
    });

    test('a suite with no shot names says so', () {
      // Every step matched on an ordinal an insertion would shift. The counts
      // are still the counts; the line says which regime produced them.
      var drift = compareScenarioRuns(
        _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'bbbb')]),
        _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'cccc')]),
      );

      expect(drift.nameMatched, 0);
      expect(drift.unanchored, 2);
      expect(
        drift.summary,
        '1 of 2 steps differ · 2 matched by position alone',
      );
    });
  });

  group('facets', () {
    test('a status bar that stopped being tinted is drift', () {
      // The capture is the app's surface and the status bar is drawn around
      // it, so the digest cannot see this. A screenshot-invisible behaviour
      // change reading as "nothing moved" is the most dangerous answer here.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart', statusBrightness: 'light'),
        ]),
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart', statusBrightness: 'dark'),
        ]),
      );

      expect(drift.changed.single.what, [ScenarioDriftFacet.statusBrightness]);
      expect(drift.changed.single.isPixelsOnly, isFalse);
      // Named in the one line anybody reads: "1 of 1 steps differ" alone reads
      // as a screenshot that moved, and nothing here moved a pixel.
      expect(drift.summary, '1 of 1 steps differ (1 statusBrightness)');
    });

    test('a keyboard that stopped opening is drift', () {
      var drift = compareScenarioRuns(
        _run([_step('#1', digest: 'aaaa', name: 'Name', keyboard: 291)]),
        _run([_step('#1', digest: 'aaaa', name: 'Name')]),
      );

      expect(drift.changed.single.what, [ScenarioDriftFacet.keyboard]);
    });

    test('a drift that is only settles does not read as only regressions', () {
      // The dangerous shape: one facet, and not the one the sentence implies.
      // Breaking down only when *several* facets moved would leave this
      // saying "2 of 2 steps differ" about two settles that ran out of budget.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'A'),
          _step('#2', digest: 'bbbb', name: 'B'),
        ]),
        _run([
          _step('#1', digest: 'aaaa', name: 'A', settled: false),
          _step('#2', digest: 'bbbb', name: 'B', settled: false),
        ]),
      );

      expect(drift.summary, '2 of 2 steps differ (2 settled)');
    });

    test('the summary breaks the count down once more than pixels moved', () {
      // "51 steps differ" reads as 51 regressions when some of them are a
      // settle that ran out of budget on a loaded machine.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'A'),
          _step('#2', digest: 'bbbb', name: 'B'),
          _step('#3', digest: 'cccc', name: 'C'),
        ]),
        _run([
          _step('#1', digest: 'zzzz', name: 'A'),
          _step('#2', digest: 'yyyy', name: 'B'),
          _step('#3', digest: 'cccc', name: 'C', settled: false),
        ]),
      );

      expect(drift.byFacet, {
        ScenarioDriftFacet.pixels: 2,
        ScenarioDriftFacet.settled: 1,
      });
      expect(drift.summary, '3 of 3 steps differ (2 pixels · 1 settled)');
    });

    test('a step that moved in two facets is named under both', () {
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa', name: 'Cart', navBrightness: 'light'),
        ]),
        _run([
          _step('#1', digest: 'bbbb', name: 'Cart', navBrightness: 'dark'),
        ]),
      );

      expect(drift.changed.single.what, [
        ScenarioDriftFacet.pixels,
        ScenarioDriftFacet.navBrightness,
      ]);
      expect(
        drift.changed.single.label,
        'Order a cappuccino · Cart · (pixels, navBrightness)',
      );
    });

    test('a step with no digest is compared on nothing at all', () {
      // The digest is the eligibility gate, not just one of the facets: a run
      // written before digests existed carries none, and comparing its steps
      // on the fields that default would report a suite that never ran.
      var drift = compareScenarioRuns(
        _run([
          _step('#1', digest: 'aaaa'),
          _step('#2', statusBrightness: 'light'),
        ]),
        _run([
          _step('#1', digest: 'aaaa'),
          _step('#2', statusBrightness: 'dark'),
        ]),
      );

      expect(drift.isEmpty, isTrue);
      expect(drift.compared, 1);
    });
  });

  test('unnamed steps are still matched by position, not by index', () {
    // A step appended at the end shifts every index below it and no position
    // but its own siblings'. Matching by index would report the whole scenario
    // as moved.
    var drift = compareScenarioRuns(
      _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'bbbb')]),
      _run([
        _step('#1', digest: 'aaaa'),
        _step('#2', digest: 'bbbb'),
        _step('#3', digest: 'cccc'),
      ]),
    );

    expect(drift.changed, isEmpty);
    expect(drift.added.single.position, '#3');
    expect(drift.removed, isEmpty);
    expect(drift.summary, '1 new · 2 matched by position alone');
  });

  test('a step that stopped being captured is reported gone', () {
    var drift = compareScenarioRuns(
      _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'bbbb')]),
      _run([_step('#1', digest: 'aaaa')]),
    );

    expect(drift.removed.single.position, '#2');
    expect(drift.compared, 1);
  });

  test('one point of a matrix is never compared against another', () {
    var drift = compareScenarioRuns(
      _run([_step('#1', digest: 'aaaa')], axes: {'language': 'en'}),
      _run([_step('#1', digest: 'zzzz')], axes: {'language': 'fr'}),
    );

    expect(drift.isEmpty, isTrue);
    expect(drift.compared, 0);
  });

  test('a scenario only one of the runs executed is out of scope', () {
    // One of the two was a selective run — one file, one name, one tag. A
    // scenario the other never executed did not move; it was not looked at.
    var whole = ScenarioRunResult(
      packages: [
        ScenarioRunPackage(
          path: 'packages/app',
          output: 'build/out',
          scenarios: [
            ScenarioRunOutcome(
              file: 'test/scenarios/shop_test.dart',
              name: 'Order a cappuccino',
              ok: true,
              steps: [_step('#1', digest: 'aaaa')],
            ),
            ScenarioRunOutcome(
              file: 'test/scenarios/shop_test.dart',
              name: 'Around the shop',
              ok: true,
              steps: [_step('#1', digest: 'bbbb')],
            ),
          ],
        ),
      ],
    );
    var drift = compareScenarioRuns(whole, _run([_step('#1', digest: 'aaaa')]));

    expect(drift.isEmpty, isTrue);
    expect(drift.compared, 1);
  });

  test('a step with no digest is not compared — a beat, or an old run', () {
    // A notification beat captured no bytes, and a run written before digests
    // existed carries none at all. Neither is drift.
    var drift = compareScenarioRuns(
      _run([_step('#1', digest: 'aaaa'), _step('#2')]),
      _run([_step('#1', digest: 'aaaa'), _step('#2')]),
    );

    expect(drift.isEmpty, isTrue);
    expect(drift.compared, 1);
  });

  test('a run from before digests existed is not a suite that moved', () {
    // Every step of the newer run would otherwise read as added, which is a
    // loud answer to a question nothing could ask.
    var drift = compareScenarioRuns(
      _run([_step('#1'), _step('#2')]),
      _run([_step('#1', digest: 'aaaa'), _step('#2', digest: 'bbbb')]),
    );

    expect(drift.isEmpty, isTrue);
    expect(drift.compared, 0);
  });

  group('the baseline', () {
    test('names the run it compared against', () {
      var drift = compareScenarioRuns(
        _run([_step('#1', digest: 'aaaa')], output: 'build/runs/1756'),
        _run([_step('#1', digest: 'bbbb')], output: 'build/runs/1757'),
      );

      expect(drift.baseline, 'build/runs/1756');
      expect(drift.toJson()['baseline'], 'build/runs/1756');
    });

    test('is what the caller says it is, where the caller knows better', () {
      // The run this side read off disk is not always the run it was written
      // to: a baseline picked by walking backwards past panel sessions is not
      // one a reader could guess.
      var drift = compareScenarioRuns(
        _run([_step('#1', digest: 'aaaa')], output: '/abs/tmp/base'),
        _run([_step('#1', digest: 'bbbb')]),
        baseline: 'build/flutterware/scenario_runs/1756',
      );

      expect(drift.baseline, 'build/flutterware/scenario_runs/1756');
    });
  });

  group('the wire', () {
    test('counts whole and lists capped', () {
      var drift = compareScenarioRuns(
        _run([for (var i = 0; i < 30; i++) _step('#$i', digest: 'a$i')]),
        _run([for (var i = 0; i < 30; i++) _step('#$i', digest: 'b$i')]),
      );
      var back = ScenarioRunDrift.fromJson(drift.toJson());

      expect(drift.toJson()['changed'], 30);
      expect(back.changed, hasLength(20));
      expect(back.compared, 30);
      expect(back.changed.first.scenario, 'Order a cappuccino');
    });

    test('writes every step when nothing caps it', () {
      // What `drift.json` holds. The counts were always honest; the names are
      // what an agent chasing the regression actually reads, so the file that
      // keeps them has to keep all of them.
      var drift = compareScenarioRuns(
        _run([for (var i = 0; i < 30; i++) _step('#$i', digest: 'a$i')]),
        _run([for (var i = 0; i < 30; i++) _step('#$i', digest: 'b$i')]),
      );
      var back = ScenarioRunDrift.fromJson(drift.toJson(maxSteps: null));

      expect(back.changed, hasLength(30));
    });

    test('carries the facets and the file the whole of it is in', () {
      var drift = compareScenarioRuns(
        _run([_step('#1', digest: 'aaaa', name: 'Cart', keyboard: 291)]),
        _run([_step('#1', digest: 'aaaa', name: 'Cart')]),
      ).inFile('build/out/drift.json');
      var back = ScenarioRunDrift.fromJson(drift.toJson());

      expect(back.file, 'build/out/drift.json');
      expect(back.nameMatched, 1);
      expect(back.changed.single.what, [ScenarioDriftFacet.keyboard]);
      expect(drift.toJson()['byFacet'], {ScenarioDriftFacet.keyboard: 1});
    });
  });
}
