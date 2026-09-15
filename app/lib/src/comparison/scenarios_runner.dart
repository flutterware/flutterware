import 'scenario_diff.dart';

import 'package:flutterware/comparison_report.dart';
import 'package:path/path.dart' as p;

import '../scenarios/runner.dart';
import 'artifact.dart';
import '../embedder/build_directory.dart';
import 'cancel.dart';
import 'closure.dart';
import 'import_graph.dart';
import 'replay_store.dart';
import 'scenarios_side.dart';
import 'shot_cache.dart';
import 'shot_key.dart';
import 'skip.dart';

/// One side-pair of scenarios, as the runner needs to talk to them.
///
/// The twin of `ComparisonSide`, and it exists for the same reason that one
/// does: the orchestration — which scenario is new, what the closure says
/// nothing touched, what order rows rank in — is most of the risk here and
/// none of it needs a `flutter_tester`, a harness build or a Flutter SDK to be
/// wrong. A fake source makes all of that testable in milliseconds, which the
/// version of this that lived inside `fw compare` never was.
abstract interface class ScenarioSource {
  /// Every scenario id one side declares.
  Future<List<String>> list({required bool base});

  /// Every scenario id one side declares, read from its sources instead of
  /// from a running harness — or null where the sources cannot answer for the
  /// whole set.
  ///
  /// Synchronous and nearly free, which is the entire point of its existing
  /// beside [list]. [list] costs a harness build and a boot **on each side**,
  /// and that is what a comparison spends its fixed time on: measured
  /// 2026-09-09 on this repo, a run whose every scenario was skipped spent
  /// 60.5 of its 63 seconds getting two harnesses up to ask them a question
  /// the sources had already answered.
  List<String>? scan({required bool base});

  /// Where a scenario's source lives, relative to a checkout root.
  String fileOf(String id);

  /// The folder config that governs [id] on one side, relative to a checkout
  /// root — or null where none does. See `ScenariosSide.configOf`.
  String? configOf(String id, {required bool base});

  /// What every replay runs under that no source file says — the project's
  /// clock and network — as a cache key spells it.
  Map<String, String> get settings;

  /// Replays [id] on one side and reads back every step it captured.
  Future<ScenarioReplay> shots(
    String id, {
    required bool base,
    required String outDir,
  });

  /// Releases both harnesses.
  Future<void> dispose();
}

/// The real thing: a [ScenariosSide] with a live runner bound to each checkout.
///
/// Owns the two runners, so a caller cannot forget to dispose one — which is
/// two `flutter_tester` processes and a build directory each.
class LiveScenarioSource implements ScenarioSource {
  LiveScenarioSource({
    required this.side,
    required this.headRoot,
    required this.baseRoot,
  });

  final ScenariosSide side;
  final String headRoot;
  final String baseRoot;

  /// Built on the first ask, because a plan answered from [scan] never asks.
  /// A runner is a claimed build directory before it is anything else, so
  /// making them lazy is what lets a comparison that replays nothing leave
  /// nothing behind in either checkout.
  ScenarioRunner? _head;
  ScenarioRunner? _base;

  ScenarioRunner _runner({required bool base}) => base
      ? _base ??= side.runnerFor(baseRoot)
      : _head ??= side.runnerFor(headRoot);

  @override
  Future<List<String>> list({required bool base}) =>
      side.scenarios(_runner(base: base));

  @override
  List<String>? scan({required bool base}) =>
      side.scannedScenarios(base ? baseRoot : headRoot);

  @override
  String fileOf(String id) => side.fileOf(id);

  @override
  String? configOf(String id, {required bool base}) =>
      side.configOf(base ? baseRoot : headRoot, id);

  @override
  Map<String, String> get settings => side.settings;

  @override
  Future<ScenarioReplay> shots(
    String id, {
    required bool base,
    required String outDir,
  }) => side.run(
    _runner(base: base),
    id,
    outDir: p.join(outDir, base ? 'base' : 'head'),
  );

  @override
  Future<void> dispose() async {
    // Only the ones that were built. A run answered from the scan alone made
    // neither, and there is nothing to tear down or release.
    for (var runner in [_head, _base]) {
      if (runner == null) continue;
      await runner.dispose();
      // The runners built in claimed directories — `runnerFor` says why — and
      // the claim ends with the runner that held it.
      releaseBuildDirectory(
        runner.packageRoot,
        runner.buildDirectory,
        root: comparisonBuildRoot,
      );
    }
    // Not cleared. A null field here means "never built", and a source that
    // forgot it had been disposed would answer the next ask by building a
    // fresh runner in a fresh claim rather than by failing.
  }
}

/// What the scenario half already knows before it replays anything.
///
/// The twin of `ComparisonPlan`, and it costs the same nothing: two harness
/// listings and a sha1 per file in each scenario's closure.
class ScenariosPlan {
  const ScenariosPlan({
    required this.settled,
    required this.toRun,
    required this.total,
    this.keys = const {},
    this.because = const {},
  });

  /// Scenarios answered without replaying: added, removed, skipped.
  final List<ScenarioComparison> settled;

  /// The ids that have to be compared from both sides' frames — replayed, or
  /// read from the [ReplayStore] under [keys].
  final List<String> toRun;

  /// Each of [toRun]'s replays, as the store files it on either side.
  final Map<String, ({String base, String head})> keys;

  final int total;

  /// Why [toRun] has to be replayed, folded — see [foldReasons].
  final Map<String, int> because;
}

/// Runs the scenario half: decide, replay what is left, align, report.
///
/// Lifted out of `fw compare`, where it was the only copy. The GUI needs
/// the same decisions the CLI makes, and a second implementation of those in a
/// panel is two answers to one question. It mirrors `ComparisonRunner`
/// deliberately, down to [plan] and [run], because a caller holding both halves
/// should not have to hold two shapes.
class ScenariosRunner {
  ScenariosRunner({
    required this.headRoot,
    required this.baseRoot,
    required this.source,
    required this.cache,
    required this.locks,
    required this.sdk,
    this.pixels,
    this.only,
    this.onScenario,
    this.onPlan,
    this.onProgress,
    this.cancel,
  });

  final String headRoot;
  final String baseRoot;
  final ScenarioSource source;
  final ShotCache cache;

  /// The SDK both sides replay under — `ComparisonRunner.sdk`, and for the
  /// same reason: it is in every replay's key.
  final String sdk;

  late final _store = ReplayStore(cache);

  /// The base checkout's import graph, read the first time a scenario needs a
  /// key — a run that skips everything never reads it — and then kept: a plan
  /// can decide twice, and the base does not move in between.
  late final _baseImports = ImportGraph.read(
    root: baseRoot,
    packageConfig: p.join(baseRoot, '.dart_tool', 'package_config.json'),
  );

  /// One side's replay key: its closure — the scenario, its folder config and
  /// everything they import on that side — with the pixel inputs and the lock
  /// slice folded in, the SDK, and the settings no file says.
  ///
  /// The rule `ShotKey` states for a picture holds for a replay: **if it can
  /// change a pixel, it is in the key.** That is what makes serving a filed
  /// replay the same answer as replaying it.
  String _keyFor(
    String id,
    ImportGraph graph,
    String root,
    String file,
    String? config,
    LockReach? lock,
    DigestCache digests,
  ) => ShotKey.of(
    kind: 'scenario',
    entryId: id,
    closure: SourceClosure.of(
      {
        ...graph.closureOf(file),
        if (config != null) ...graph.closureOf(config),
      },
      root: root,
      digests: digests,
    ).merge(pixels?.inRoot(root)).merge(lock?.inRoot(root)).fingerprint,
    sdk: sdk,
    extra: source.settings,
  );

  /// The pixel inputs the closure does not name — see [PixelInputs]. A
  /// parameter rather than derived here because [source] deliberately hides
  /// where the package lives.
  final PixelInputs? pixels;

  /// Both sides' lockfiles, read per package — see [LockSides]. Passed for
  /// the same reason [pixels] is, and used the same way: a scenario carries
  /// the resolution of the packages it reaches and no others.
  ///
  /// **Required, and nullable on purpose.** It was optional, and both callers
  /// forgot it: the lockfile had just left the pixel inputs to come in through
  /// here, so a runner built without it hashed no lockfile at all and a
  /// dependency bump replayed nothing. Null is still a legal answer — a test's
  /// fake checkout has no lock — but it has to be said.
  final LockSides? locks;

  /// Compare only these scenario ids.
  final List<String>? only;

  /// Called as each scenario is decided, so a panel can fill a list in rather
  /// than wait for the slowest replay.
  final void Function(ScenarioComparison scenario)? onScenario;

  /// Called once the plan is made — how many scenarios there are, and which
  /// still owe a replay.
  final void Function(ScenariosPlan plan)? onPlan;

  /// One sentence of what the run is doing right now, replaced as it moves.
  final void Function(String phase)? onProgress;

  /// Checked between replays — a scenario is a process, and stopping takes
  /// effect at the next one.
  final CancelToken? cancel;

  /// What has to be replayed, decided without starting anything where the
  /// sources can say.
  ///
  /// Two listings answer "which scenarios does each side declare", and they
  /// cost wildly different amounts. [ScenarioSource.scan] parses the files;
  /// [ScenarioSource.list] builds and boots a harness on **each** side, which
  /// is the whole fixed cost of this half and is paid before a single closure
  /// has been hashed. So the scan goes first, and the listing is asked for
  /// only when something has to be replayed — at which point a harness is
  /// starting anyway and the plan is remade from the answer that knows about
  /// `skip:` and about names no parser can read.
  ///
  /// The scan is therefore never trusted to *decide* a replay, only to decide
  /// that there is none — either because nothing changed, or because every
  /// replay the change needs is already filed in the [ReplayStore]. What it can
  /// get wrong on that path is `added` and `removed` — and only on a run where
  /// nothing is replayed, since the next run that replays anything re-asks the
  /// harness.
  Future<ScenariosPlan> plan({ImportGraph? graph}) async {
    cancel?.check();
    var imports =
        graph ??
        ImportGraph.read(
          root: headRoot,
          packageConfig: p.join(headRoot, '.dart_tool', 'package_config.json'),
        );
    // One pass's digests, so the library every scenario imports is hashed
    // once rather than once per scenario — and once across both decisions
    // below, on the runs that make two. Scoped to this plan and no longer:
    // see [DigestCache].
    var digests = DigestCache();

    onProgress?.call('reading the scenarios on both sides');
    var scannedHead = source.scan(base: false);
    var scannedBase = source.scan(base: true);
    // Both sides empty is not an answer, it is the absence of one: a package
    // whose scenarios the scan cannot see at all is exactly the case where
    // the harness's refusal to build is the message, and short-circuiting
    // here would replace it with a clean, silent, empty half.
    if (scannedHead != null &&
        scannedBase != null &&
        (scannedHead.isNotEmpty || scannedBase.isNotEmpty)) {
      var provisional = _decide(
        headIds: scannedHead,
        baseIds: scannedBase,
        imports: imports,
        digests: digests,
      );
      if (provisional.toRun.isEmpty) return provisional;
      // A second push whose inputs did not move: every replay the change
      // needs is filed, so no harness has to start to answer it.
      if (provisional.keys.values.every(
        (key) => _store.has(key.base) && _store.has(key.head),
      )) {
        return provisional;
      }
    }

    // Both at once, because they are two harnesses: a separate checkout, a
    // separate build directory and a separate `flutter_tester` each, sharing
    // nothing but the machine. Asking one and then the other spent the base
    // side's build waiting on this side's.
    onProgress?.call('listing the scenarios on both sides');
    var listed = await Future.wait([
      source.list(base: false),
      source.list(base: true),
    ]);
    cancel?.check();
    return _decide(
      headIds: listed[0],
      baseIds: listed[1],
      imports: imports,
      digests: digests,
    );
  }

  /// The plan two id listings imply — added, removed, skipped, and what is
  /// left to replay.
  ///
  /// Pure and synchronous: whichever listing it is given, the deciding is the
  /// same, which is what lets [plan] run it twice for the price of one digest
  /// pass.
  ScenariosPlan _decide({
    required List<String> headIds,
    required List<String> baseIds,
    required ImportGraph imports,
    required DigestCache digests,
  }) {
    if (only case var only?) {
      headIds = [
        for (var id in headIds)
          if (only.contains(id)) id,
      ];
      baseIds = [
        for (var id in baseIds)
          if (only.contains(id)) id,
      ];
    }

    var settled = <ScenarioComparison>[];
    var toRun = <String>[];
    var keys = <String, ({String base, String head})>{};
    var reasons = <String>[];
    for (var id in headIds) {
      if (!baseIds.contains(id)) {
        settled.add(
          ScenarioComparison.notRun(scenario: id, state: ComparedState.added),
        );
        continue;
      }
      // The scenario's own file and the folder config the harness wraps it
      // in. Both decide what it draws, and only the first is named by
      // anything the scenario imports — so both the closure and the reach
      // are taken over the pair.
      var file = source.fileOf(id);
      var config = source.configOf(id, base: false);
      cache.memo.remember(id, {
        ...imports.closureOf(file),
        if (config != null) ...imports.closureOf(config),
      });
      var lock = locks?.forPackages({
        ...imports.packagesOf(file),
        if (config != null) ...imports.packagesOf(config),
      });
      var decision = SkipDecision.of(
        entryId: id,
        memo: cache.memo,
        baseRoot: baseRoot,
        headRoot: headRoot,
        pixels: pixels,
        digests: digests,
        lock: lock,
      );
      if (decision.skip) {
        settled.add(
          ScenarioComparison.notRun(scenario: id, state: ComparedState.skipped),
        );
        continue;
      }
      toRun.add(id);
      // Each side keyed over its **own** closure, as a preview's shot is:
      // the base draws what the base imports, and a key taken over the
      // head's imports would miss a file only the base still reads — two
      // bases differing there would share one replay. The reach stays the
      // head's, as it is everywhere a lock is sliced.
      keys[id] = (
        base: _keyFor(
          id,
          _baseImports,
          baseRoot,
          file,
          source.configOf(id, base: true),
          lock,
          digests,
        ),
        head: _keyFor(id, imports, headRoot, file, config, lock, digests),
      );
      if (decision.reason case var reason?) reasons.add(reason);
    }
    for (var id in baseIds) {
      if (!headIds.contains(id)) {
        settled.add(
          ScenarioComparison.notRun(scenario: id, state: ComparedState.removed),
        );
      }
    }

    return ScenariosPlan(
      settled: settled,
      toRun: toRun,
      total: settled.length + toRun.length,
      keys: keys,
      because: foldReasons(reasons),
    );
  }

  /// Replays one side of [id] until it is believed, and files it under [key]
  /// when it can be served again.
  ///
  /// A clean replay is believed at once. One that failed or was abandoned is
  /// replayed a second time before anything is concluded from it — see
  /// [confirmSide]. That second replay is taken **alone**: the caller has
  /// already let the pair's first replays finish, because the host is the
  /// suspect and running the other side's tester beside it is load.
  ///
  /// Only a result is filed, and not every result. Five are not: one that
  /// did not finish, one with a step that landed work by guessing, an empty
  /// one, one whose requests reached the network, and — by construction —
  /// anything [confirmSide] did not call a result. Everything else a replay
  /// reads is in its key — under `FakeAsync`, with the clock pinned and the
  /// network off or answered from a committed recording, two replays of one
  /// key draw the same frames. A `live` request is the one input nothing can
  /// hash: filing it would hand the next push today's answer from yesterday's
  /// server. And a failure is filed only once it has reproduced, which is the
  /// one moment "same key, same frames" can be checked rather than assumed.
  Future<ConfirmedSide> _confirm(
    String id,
    String? key,
    ScenarioReplay first, {
    required bool base,
    required String outDir,
  }) async {
    var second = first.clean
        ? null
        : await source.shots(id, base: base, outDir: outDir);
    if (second != null) _retries++;
    var side = confirmSide(
      first,
      second,
      side: base ? 'the base' : 'this branch',
    );
    var replay = side.replay;
    if (replay == null ||
        key == null ||
        // A hang that reproduced is a result to report and not one to serve:
        // the harness abandoned the rest of the file with it.
        !replay.complete ||
        // Pictures that depended on the machine's speed. Served to a later
        // comparison on a slower machine, they would be the fast answer beside
        // a slow one, and never replayed to find out.
        replay.hazards.isNotEmpty ||
        replay.steps.isEmpty ||
        replay.steps.any(_reachedNetwork)) {
      return side;
    }
    return ConfirmedSide.result(
      ScenarioReplay(
        _store.write(key, replay.steps, errors: replay.errors),
        errors: replay.errors,
        ms: replay.ms,
      ),
    );
  }

  /// How many sides this run replayed a second time — see [_confirm].
  var _retries = 0;

  /// Whether a step's requests went out to a real network — `live` or
  /// `record`, as the funnel answers on each request's event.
  ///
  /// Only the funnel's word counts. Every request that can leave a scenario
  /// passes through it, and it has labelled each one since it existed; before
  /// it, `flutter_test` answered every request with a 400 and none left at
  /// all. A network event with no `answered` is the app's own logging — an
  /// interceptor, a fake client — and counting it as live kept the replays of
  /// every scenario that logs its requests out of the store.
  static bool _reachedNetwork(ScenarioStepShot step) =>
      step.events.any((event) {
        if (event['channel'] != 'network') return false;
        var answered = switch (event['data']) {
          Map data => data['answered'],
          _ => null,
        };
        return answered == 'live' || answered == 'record';
      });

  static String _capitalized(String sentence) => sentence.isEmpty
      ? sentence
      : '${sentence[0].toUpperCase()}${sentence.substring(1)}';

  /// Replays what [plan] left and aligns the two runs.
  ///
  /// One scenario on both sides before the next. A scenario is a process;
  /// replaying the whole head side and then the whole base side would double
  /// the time before the first row could be answered, and the first row is what
  /// a reader is waiting for.
  ///
  /// The two sides of one scenario run **together**. They are two harnesses on
  /// two checkouts with a build directory each, so there is nothing to
  /// serialize them for — and a replay is where a comparison spends its time.
  /// `Future.wait` rather than a record's `.wait`: a side that fails is
  /// usually a compile error, and the message a reader needs is that error
  /// itself rather than a `ParallelWaitError` wrapping it.
  Future<ScenarioResults> run({
    required String outDir,
    ScenariosPlan? from,
    ImportGraph? graph,
  }) async {
    var watch = Stopwatch()..start();
    cancel?.check();
    var plan = from ?? await this.plan(graph: graph);
    onPlan?.call(plan);

    var items = <ScenarioComparison>[];
    void report(ScenarioComparison scenario) {
      items.add(scenario);
      onScenario?.call(scenario);
    }

    for (var settled in plan.settled) {
      report(settled);
    }
    var done = 0;
    var replays = 0;
    for (var id in plan.toRun) {
      cancel?.check();
      done++;
      var name = id.contains('#') ? id.substring(id.indexOf('#') + 1) : id;
      var count = '$done of ${plan.toRun.length}';
      var key = plan.keys[id];
      var filedBase = key == null ? null : _store.readReplay(key.base);
      var filedHead = key == null ? null : _store.readReplay(key.head);
      var where = switch ((filedBase, filedHead)) {
        (null, null) => 'on both sides',
        (null, _) => 'on the base',
        (_, null) => 'on this side',
        _ => null,
      };
      onProgress?.call(
        where == null
            ? 'reading "$name" from the cache · $count'
            : 'replaying "$name" $where · $count',
      );
      var retriesBefore = _retries;
      var firsts = await Future.wait([
        filedBase == null
            ? source.shots(id, base: true, outDir: outDir)
            : Future.value(filedBase),
        filedHead == null
            ? source.shots(id, base: false, outDir: outDir)
            : Future.value(filedHead),
      ]);
      if (firsts.any((first) => !first.clean)) {
        onProgress?.call('replaying "$name" again, alone, to confirm · $count');
      }
      // One after the other, never together: see [_confirm]. A filed side is
      // a result already and is not confirmed again.
      var baseSide = filedBase != null
          ? ConfirmedSide.result(filedBase)
          : await _confirm(
              id,
              key?.base,
              firsts[0],
              base: true,
              outDir: outDir,
            );
      var headSide = filedHead != null
          ? ConfirmedSide.result(filedHead)
          : await _confirm(
              id,
              key?.head,
              firsts[1],
              base: false,
              outDir: outDir,
            );
      replays +=
          [filedBase, filedHead].where((side) => side == null).length +
          (_retries - retriesBefore);
      if (baseSide.replay case var base? when headSide.replay != null) {
        var head = headSide.replay!;
        var compared = compareScenarioReplays(
          scenario: id,
          base: base,
          head: head,
        );
        // A difference in a scenario whose pictures depended on the machine
        // is not believed until each side has done the same thing twice.
        // Every side here is fresh: a side with hazards is never filed.
        if (compared.state.isFinding &&
            (base.hazards.isNotEmpty || head.hazards.isNotEmpty)) {
          onProgress?.call(
            'replaying "$name" again, alone: it drew work nothing announced '
            '· $count',
          );
          var unstable = <String>[];
          for (var (isBase, replay) in [(true, base), (false, head)]) {
            if ((isBase ? filedBase : filedHead) != null) continue;
            var again = await source.shots(id, base: isBase, outDir: outDir);
            replays++;
            if (!replaysAgree(replay, again)) {
              var side = isBase ? 'the base' : 'this branch';
              unstable.add(
                replay.hazards.isNotEmpty
                    ? unstableHazardSentence(side, replay)
                    : again.hazards.isNotEmpty
                    ? unstableHazardSentence(side, again)
                    : '$side did not replay the same way twice.',
              );
            }
          }
          if (unstable.isNotEmpty) {
            report(
              ScenarioComparison.notCompared(
                scenario: id,
                inconclusive: unstable.map(_capitalized).join(' '),
                baseErrors: base.failures,
                headErrors: head.failures,
                baseMs: base.ms,
                headMs: head.ms,
              ),
            );
            continue;
          }
        }
        report(compared);
      } else {
        report(
          ScenarioComparison.notCompared(
            scenario: id,
            inconclusive: [
              ?baseSide.inconclusive,
              ?headSide.inconclusive,
            ].map(_capitalized).join(' '),
            baseErrors: firsts[0].failures,
            headErrors: firsts[1].failures,
            baseMs: firsts[0].ms,
            headMs: firsts[1].ms,
          ),
        );
      }
    }

    return ScenarioResults.of(
      items: items,
      ran: plan.toRun.length,
      replays: replays,
      skipped: plan.settled
          .where((s) => s.state == ComparedState.skipped)
          .length,
      elapsed: watch.elapsed,
      because: plan.because,
    );
  }
}
