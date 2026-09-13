import 'dart:async';

import 'package:flutterware/comparison_report.dart';
import 'package:flutterware_app/src/comparison/artifact.dart';
import 'package:flutterware_app/src/comparison/cancel.dart';
import 'package:flutterware_app/src/comparison/comparison_controller.dart';
import 'package:flutterware_app/src/comparison/last_run.dart';
import 'package:flutterware_app/src/comparison/runner.dart';
import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:flutterware_app/src/comparison/shot_store.dart';
import 'package:flutterware_app/src/comparison/shot_store_io.dart';
import 'package:test/test.dart';

/// The sequencing: nothing runs on its own, one explicit Compare per half.
///
/// Driven through a fake environment, because none of this needs a compiler, a
/// guest or a git worktree to be wrong.
void main() {
  late _FakeEnvironment environment;
  late ComparisonController controller;

  setUp(() {
    environment = _FakeEnvironment();
    controller = ComparisonController(environment);
  });
  tearDown(() => controller.dispose());

  group('nothing runs on its own', () {
    // The whole reversal of §13.11: the machinery starts on the button, never
    // on a mount, a tab focus or an address arrival.
    test('building it touches nothing', () async {
      await pumpEventQueue();

      expect(environment.prepared, 0);
      expect(environment.ranPreviews, 0);
      expect(environment.ranScenarios, 0);
      expect(controller.baseRoot, isNull);
    });

    test('both halves rest at idle', () {
      expect(controller.previews.stage, HalfStage.idle);
      expect(controller.scenarios.stage, HalfStage.idle);
    });

    test('a half whose plugin is not declared has no tab', () {
      var only = ComparisonController(_FakeEnvironment()..hasScenarios = false);
      addTearDown(only.dispose);

      expect(only.scenarios.stage, HalfStage.undeclared);
      expect(only.declared.map((h) => h.kind), [ComparisonHalfKind.previews]);
    });
  });

  group('the kept run', () {
    // The idle state is never blank: the last answer loads from disk, marked
    // as restored, and the half stays idle — showing is not running.
    test('restores into the half without running anything', () async {
      environment.keptPreviews = LastComparison(
        at: DateTime(2026, 8, 19),
        baseSha: 'abc123',
        against: 'origin/master',
        elapsed: const Duration(seconds: 8),
        items: const [
          ComparedItem(id: 'demo/a.dart#a', state: ComparedState.changed),
        ],
      );
      var restored = ComparisonController(environment);
      addTearDown(restored.dispose);

      await restored.restored;

      expect(restored.previews.stage, HalfStage.idle);
      expect(restored.previews.restored, isTrue);
      expect(restored.previews.rows, hasLength(1));
      expect(restored.previews.lastRun?.baseSha, 'abc123');
      expect(environment.ranPreviews, 0);
    });

    test('a finished run is saved for the next visit', () async {
      environment.streamRows = [
        const ComparedItem(id: 'demo/a.dart#a', state: ComparedState.changed),
      ];

      await controller.compare(ComparisonHalfKind.previews);

      var saved = environment.saved[ComparisonHalfKind.previews];
      expect(saved, isNotNull);
      expect(saved!.items, hasLength(1));
      expect(saved.baseSha, 'abc123');
      expect(saved.headCommit, environment.headCommit);
    });

    test('a restored answer is replaced by pressing Compare', () async {
      environment.keptPreviews = LastComparison(
        at: DateTime(2026, 8, 19),
        baseSha: 'old',
        against: 'origin/master',
        elapsed: Duration.zero,
        items: const [ComparedItem(id: 'gone', state: ComparedState.removed)],
      );
      var restored = ComparisonController(environment);
      addTearDown(restored.dispose);
      await restored.restored;

      await restored.compare(ComparisonHalfKind.previews);

      expect(restored.previews.restored, isFalse);
      expect(restored.previews.rows.map((r) => r.id), isNot(contains('gone')));
    });
  });

  group('compare', () {
    test('runs only the half that was asked', () async {
      await controller.compare(ComparisonHalfKind.previews);

      expect(environment.ranPreviews, 1);
      expect(environment.ranScenarios, 0);
      expect(controller.previews.stage, HalfStage.done);
      expect(controller.scenarios.stage, HalfStage.idle);
    });

    test(
      'prepares the base first, so the button is enough on its own',
      () async {
        await controller.compare(ComparisonHalfKind.scenarios);

        expect(environment.prepared, 1);
        expect(controller.scenarios.scenarioResults, isNotNull);
      },
    );

    test('two halves share one base checkout', () async {
      await controller.compare(ComparisonHalfKind.previews);
      await controller.compare(ComparisonHalfKind.scenarios);

      expect(environment.prepared, 1);
    });

    // Double-clicking the button, or pressing it from two places, must not
    // start two of anything.
    test('a press while running joins the run in flight', () async {
      var gate = Completer<void>();
      environment.previewsGate = gate;

      var first = controller.compare(ComparisonHalfKind.previews);
      var second = controller.compare(ComparisonHalfKind.previews);
      gate.complete();
      await Future.wait([first, second]);

      expect(environment.ranPreviews, 1);
    });

    // The button is also the refresh: a finished half runs again.
    test('a press on a finished half runs it again', () async {
      await controller.compare(ComparisonHalfKind.previews);

      await controller.compare(ComparisonHalfKind.previews);

      expect(environment.ranPreviews, 2);
      expect(controller.previews.stage, HalfStage.done);
    });

    // And the retry: a refusal is not a terminal state any more, because the
    // press that follows it is explicit.
    test('a refused half is attempted again on the next press', () async {
      environment.previewsRunError = 'two checkouts on different SDKs';
      await controller.compare(ComparisonHalfKind.previews);
      expect(controller.previews.stage, HalfStage.refused);
      environment.previewsRunError = null;

      await controller.compare(ComparisonHalfKind.previews);

      expect(environment.ranPreviews, 2);
      expect(controller.previews.stage, HalfStage.done);
    });

    test('a base that will not check out refuses the asking half', () async {
      environment.baseError = 'fatal: invalid reference: nope';

      await controller.compare(ComparisonHalfKind.previews);

      expect(controller.refusal, contains('invalid reference'));
      expect(controller.previews.stage, HalfStage.refused);
      // The half nobody ran was never touched.
      expect(controller.scenarios.stage, HalfStage.idle);
    });

    test('a failed base checkout is retried on the next press', () async {
      environment.baseError = 'fatal: could not read from remote';
      await controller.compare(ComparisonHalfKind.previews);
      environment.baseError = null;

      await controller.compare(ComparisonHalfKind.previews);

      expect(environment.prepared, 2);
      expect(controller.previews.stage, HalfStage.done);
    });

    test('a run that throws becomes the tab reason, not a crash', () async {
      environment.scenariosRunError = 'The scenario harness does not compile';

      await controller.compare(ComparisonHalfKind.scenarios);

      expect(controller.scenarios.stage, HalfStage.refused);
      expect(controller.scenarios.refusal, contains('does not compile'));
    });
  });

  group('the run as it moves', () {
    test('a row is visible before the run finishes', () async {
      var gate = Completer<void>();
      environment
        ..previewsGate = gate
        ..streamRows = [
          const ComparedItem(id: 'demo/a.dart#a', state: ComparedState.changed),
        ];

      var running = controller.compare(ComparisonHalfKind.previews);
      await pumpEventQueue();

      expect(controller.previews.isRunning, isTrue);
      expect(controller.previews.rows, hasLength(1));
      gate.complete();
      await running;
    });

    // The top row should be the thing most likely to be a mistake, whatever
    // order the renders happened to finish in.
    test('rows sort worst first as they arrive', () async {
      environment.streamRows = [
        const ComparedItem(id: 'z', state: ComparedState.same),
        const ComparedItem(id: 'a', state: ComparedState.changed),
        const ComparedItem(id: 'm', state: ComparedState.broke),
      ];

      await controller.compare(ComparisonHalfKind.previews);

      expect(controller.previews.rows.map((r) => r.id), ['m', 'a', 'z']);
    });

    test('scenarios sort worst first too', () async {
      environment.streamScenarios = [
        _scenario('z', ComparedState.same),
        _scenario('a', ComparedState.broke),
      ];

      await controller.compare(ComparisonHalfKind.scenarios);

      expect(controller.scenarios.scenarios.map((s) => s.scenario), ['a', 'z']);
    });

    // The plan is what makes the progress honest: the denominator exists
    // before the first render, and each arriving verdict drains the pending
    // list the ghost rows draw from.
    test('the plan sets the shape and rows drain it', () async {
      var gate = Completer<void>();
      environment
        ..previewsGate = gate
        ..planTotal = 3
        ..planToAnswer = ['a', 'b']
        ..streamRows = [
          const ComparedItem(id: 'a', state: ComparedState.changed),
        ];

      var running = controller.compare(ComparisonHalfKind.previews);
      await pumpEventQueue();

      expect(controller.previews.planTotal, 3);
      expect(controller.previews.pending, ['b']);
      gate.complete();
      await running;
      expect(controller.previews.pending, isEmpty);
    });

    test('progress narration reaches the half', () async {
      var gate = Completer<void>();
      environment
        ..previewsGate = gate
        ..progressLine = 'rendering the base side · 1 of 2';

      var running = controller.compare(ComparisonHalfKind.previews);
      await pumpEventQueue();

      expect(controller.previews.progress, 'rendering the base side · 1 of 2');
      gate.complete();
      await running;
      expect(controller.previews.progress, isNull);
    });
  });

  group('stop', () {
    test('keeps the rows it has and lands idle, marked partial', () async {
      var gate = Completer<void>();
      environment
        ..previewsGate = gate
        ..cancelAtGate = true
        ..streamRows = [
          const ComparedItem(id: 'a', state: ComparedState.changed),
        ];

      var running = controller.compare(ComparisonHalfKind.previews);
      await pumpEventQueue();
      controller.stop(ComparisonHalfKind.previews);
      gate.complete();
      await running;

      expect(controller.previews.stage, HalfStage.idle);
      expect(controller.previews.stopped, isTrue);
      expect(controller.previews.rows, hasLength(1));
    });

    // A receipt for half a run would read as the whole answer next visit.
    test('a stopped run is not saved', () async {
      var gate = Completer<void>();
      environment
        ..previewsGate = gate
        ..cancelAtGate = true;

      var running = controller.compare(ComparisonHalfKind.previews);
      await pumpEventQueue();
      controller.stop(ComparisonHalfKind.previews);
      gate.complete();
      await running;

      expect(environment.saved, isEmpty);
    });
  });

  test('the artifact is both halves once the previews half has run', () async {
    expect(controller.artifact, isNull);

    await controller.compare(ComparisonHalfKind.previews);
    await controller.compare(ComparisonHalfKind.scenarios);

    expect(controller.artifact, isA<ComparisonArtifact>());
    expect(controller.artifact!.scenarios, isNotNull);
  });

  // Both callers reach this *after* the notification that drew the rows, so a
  // silent assignment left the verdict with no previous run to measure against
  // and no way to learn otherwise — and since `newCount` distinguishes *no
  // previous run* from *nothing new*, it went missing rather than wrong.
  group('what the comparison before this one found', () {
    LastComparison run(DateTime at, List<String> ids) => LastComparison(
      at: at,
      baseSha: 'abc123',
      against: 'master',
      elapsed: Duration.zero,
      items: [
        for (var id in ids) ComparedItem(id: id, state: ComparedState.changed),
      ],
    );

    test('learning it reaches the panel', () {
      var half = ComparisonHalf(ComparisonHalfKind.previews);
      var notified = 0;
      half.addListener(() => notified++);

      half.knowPrevious({'demo/a.dart#a'});

      expect(half.previousFindingIds, {'demo/a.dart#a'});
      expect(notified, 1);
    });

    test('a restored half knows what the run before it found', () async {
      environment
        ..keptPreviews = run(DateTime(2026, 8, 31), [
          'demo/a.dart#a',
          'demo/b.dart#b',
        ])
        ..previousPreviews = run(DateTime(2026, 8, 30), ['demo/a.dart#a']);
      var restored = ComparisonController(environment);
      addTearDown(restored.dispose);

      await restored.restored;

      expect(restored.previews.previousFindingIds, {'demo/a.dart#a'});
    });
  });
}

ScenarioComparison _scenario(String id, ComparedState state) =>
    ScenarioComparison.notRun(scenario: id, state: state);

/// A comparison's world, with nothing behind it.
class _FakeEnvironment implements ComparisonEnvironment {
  @override
  String get headRoot => '/work/head';

  @override
  String get baseLabel => 'master';

  @override
  String get baseSha => 'abc123';

  @override
  String? get headCommit => 'def456';

  @override
  bool get baseCheckoutReady => false;

  @override
  var hasPreviews = true;

  @override
  var hasScenarios = true;

  @override
  final shots = ShotCache('/unused');

  @override
  ShotStore get shotStore => CacheShotStore(shots);

  String? baseError;
  String? previewsRunError;
  String? scenariosRunError;

  /// Held open so a test can look at a half mid-run. With [cancelAtGate], the
  /// run checks its token after the gate — how a Stop lands mid-render.
  Completer<void>? previewsGate;
  var cancelAtGate = false;

  List<ComparedItem> streamRows = const [];
  List<ScenarioComparison> streamScenarios = const [];

  int? planTotal;
  List<String> planToAnswer = const [];
  String? progressLine;

  LastComparison? keptPreviews;
  LastComparison? keptScenarios;
  final saved = <ComparisonHalfKind, LastComparison>{};

  var prepared = 0;
  var ranPreviews = 0;
  var ranScenarios = 0;

  @override
  Future<String> prepareBase({void Function(String phase)? onProgress}) async {
    prepared++;
    onProgress?.call('checking out abc123');
    if (baseError case var error?) throw StateError(error);
    return '/work/base';
  }

  @override
  Future<LastComparison?> lastRun(ComparisonHalfKind kind) async =>
      kind == ComparisonHalfKind.previews ? keptPreviews : keptScenarios;

  /// What the run before the kept one found, for *new since you last looked*.
  LastComparison? previousPreviews;
  LastComparison? previousScenarios;

  @override
  Future<LastComparison?> previousRun(ComparisonHalfKind kind) async =>
      kind == ComparisonHalfKind.previews
      ? previousPreviews
      : previousScenarios;

  @override
  Future<void> saveLastRun(ComparisonHalfKind kind, LastComparison last) async {
    saved[kind] = last;
  }

  @override
  Future<ComparisonResult> runPreviews(
    String baseRoot, {
    required void Function(ComparedItem row) onRow,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  }) async {
    ranPreviews++;
    if (previewsRunError case var error?) throw StateError(error);
    if (planTotal case var total?) onPlan?.call(total, planToAnswer);
    if (progressLine case var line?) onProgress?.call(line);
    for (var row in streamRows) {
      onRow(row);
    }
    await previewsGate?.future;
    if (cancelAtGate) cancel?.check();
    return ComparisonResult(
      items: streamRows,
      baseSha: baseSha,
      headRoot: headRoot,
      elapsed: Duration.zero,
      rendered: 0,
    );
  }

  @override
  Future<ScenarioResults> runScenarios(
    String baseRoot, {
    required void Function(ScenarioComparison scenario) onScenario,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  }) async {
    ranScenarios++;
    if (scenariosRunError case var error?) throw StateError(error);
    for (var scenario in streamScenarios) {
      onScenario(scenario);
    }
    return ScenarioResults.of(
      items: streamScenarios,
      ran: 0,
      skipped: 0,
      elapsed: Duration.zero,
    );
  }
}
