import 'dart:async';
import 'dart:collection';

import 'package:flutterware/comparison_report.dart';
import 'package:path/path.dart' as p;

import '../scenarios/runner.dart';
import 'artifact.dart';
import '../embedder/build_directory.dart';
import 'cancel.dart';
import 'closure.dart';
import 'import_graph.dart';
import 'phase_clock.dart';
import 'replay_store.dart';
import 'scenario_diff.dart';
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

/// The real thing: a [ScenariosSide] with live runners bound to each checkout.
///
/// Owns the runners, so a caller cannot forget to dispose one — which is a
/// `flutter_tester` each and a build directory per checkout.
class LiveScenarioSource implements ScenarioSource {
  LiveScenarioSource({
    required this.side,
    required this.headRoot,
    required this.baseRoot,
    this.guests = 1,
  });

  final ScenariosSide side;
  final String headRoot;
  final String baseRoot;

  /// How many guests each checkout may run at once — the most replays of one
  /// side in flight. See [ScenariosRunner.jobs].
  final int guests;

  /// Built on the first ask, because a plan answered from [scan] never asks.
  /// A runner is a claimed build directory before it is anything else, so
  /// making them lazy is what lets a comparison that replays nothing leave
  /// nothing behind in either checkout.
  late final _head = _RunnerPool(() => side.runnerFor(headRoot), size: guests);
  late final _base = _RunnerPool(() => side.runnerFor(baseRoot), size: guests);

  _RunnerPool _pool({required bool base}) => base ? _base : _head;

  @override
  Future<List<String>> list({required bool base}) =>
      side.scenarios(_pool(base: base).leader);

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
  }) => _pool(base: base).use(
    (runner) =>
        side.run(runner, id, outDir: p.join(outDir, base ? 'base' : 'head')),
  );

  @override
  Future<void> dispose() async {
    await _head.dispose();
    await _base.dispose();
  }
}

/// One checkout's guests: the one that compiles, and up to [size] − 1 more
/// spawned from its kernel as replays in flight ask for them.
class _RunnerPool {
  _RunnerPool(this._build, {required this.size});

  final ScenarioRunner Function() _build;
  final int size;

  ScenarioRunner? _leader;
  final _all = <ScenarioRunner>[];
  final _idle = <ScenarioRunner>[];
  final _waiting = Queue<Completer<ScenarioRunner>>();

  ScenarioRunner get leader {
    if (_leader case var leader?) return leader;
    var leader = _leader = _build();
    _all.add(leader);
    _idle.add(leader);
    return leader;
  }

  Future<T> use<T>(Future<T> Function(ScenarioRunner runner) action) async {
    var runner = await _take();
    try {
      return await action(runner);
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete(runner);
      } else {
        _idle.add(runner);
      }
    }
  }

  Future<ScenarioRunner> _take() {
    var leader = this.leader;
    if (_idle.isNotEmpty) return Future.value(_idle.removeLast());
    if (_all.length < size) {
      var guest = ScenarioRunner.sharing(leader, guest: _all.length);
      _all.add(guest);
      return Future.value(guest);
    }
    var waiter = Completer<ScenarioRunner>();
    _waiting.add(waiter);
    return waiter.future;
  }

  Future<void> dispose() async {
    // Only what was built. A run answered from the scan alone made nothing,
    // and there is nothing to tear down or release.
    var leader = _leader;
    if (leader == null) return;
    // The guests before the leader: they run its kernel, from its directory.
    for (var runner in _all.reversed) {
      await runner.dispose();
    }
    // The leader built in a claimed directory — `runnerFor` says why — and
    // the claim ends with the runner that held it.
    releaseBuildDirectory(
      leader.packageRoot,
      leader.buildDirectory,
      root: comparisonBuildRoot,
    );
    // Not cleared. A null leader here means "never built", and a pool that
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
    this.jobs = 1,
    this.clock,
  });

  /// Where this half records its phases — see [PhaseClock].
  final PhaseClock? clock;

  /// Every comparison of two replays, and every filing of one, this run made.
  final _comparing = PhaseTally();
  final _filing = PhaseTally();

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

  /// How many scenarios replay at once, each on both sides — so up to twice
  /// this many testers.
  ///
  /// One by default, which is the shape a runner sized for one build wants.
  /// More never lets load decide a verdict. A scenario whose replays in the
  /// pool are anything but clean and the same on both sides — a side that
  /// failed or was abandoned, or any difference at all — is replayed from the
  /// start after the pool has drained, with nothing beside it, and judged
  /// from that alone. Findings are usually the rare rows, so this costs
  /// little; a change that moves every scenario pays for it serially. The
  /// rows keep the plan's order whatever order the replays finish in.
  final int jobs;

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
        _filing.time<List<ScenarioStepShot>>(
          () => _store.write(key, replay.steps, errors: replay.errors),
        ),
        errors: replay.errors,
        ms: replay.ms,
      ),
    );
  }

  /// How many sides this run replayed a second time — see [_confirm].
  var _retries = 0;

  /// Scenarios deferred by [_conclude] because their pool replays differed,
  /// as opposed to because a side was not clean.
  final _differedInPool = <String>{};

  /// Both sides' first replay of [id], or what the store already filed for a
  /// side.
  Future<_FirstReplays> _firstReplays(
    String id, {
    required ({String base, String head})? key,
    required String count,
    required String outDir,
  }) async {
    var filedBase = key == null ? null : _store.readReplay(key.base);
    var filedHead = key == null ? null : _store.readReplay(key.head);
    var where = switch ((filedBase, filedHead)) {
      (null, null) => 'on both sides',
      (null, _) => 'on the base',
      (_, null) => 'on this side',
      _ => null,
    };
    var name = _nameOf(id);
    onProgress?.call(
      where == null
          ? 'reading "$name" from the cache · $count'
          : 'replaying "$name" $where · $count',
    );
    var firsts = await Future.wait([
      filedBase == null
          ? source.shots(id, base: true, outDir: outDir)
          : Future.value(filedBase),
      filedHead == null
          ? source.shots(id, base: false, outDir: outDir)
          : Future.value(filedHead),
    ]);
    for (var replay in firsts) {
      clock?.unsettled(id, replay.unsettled);
    }
    return _FirstReplays(
      id: id,
      key: key,
      count: count,
      filedBase: filedBase,
      filedHead: filedHead,
      base: firsts[0],
      head: firsts[1],
    );
  }

  /// The row [first] makes, replaying whatever has to be believed first — or
  /// null, when that takes a replay and this is not [alone].
  ///
  /// Three things replay again, and all are asking whether the machine was the
  /// cause: a side that failed or was abandoned ([_confirm]), a difference
  /// drawn by work nothing announced, and a difference that is only events
  /// changing order. None is asked beside other replays.
  ///
  /// Beside other replays, nothing different is believed either. Load moves
  /// more than a guessed landing: a stream fed by real I/O fires earlier on a
  /// busy host, and the events it logs change order with nothing else
  /// changing. So a pool replay that finds anything is not concluded from, and
  /// it is compared **before** [_confirm] files it — filed, the replay taken
  /// alone would read it back instead of replaying it.
  Future<({ScenarioComparison comparison, int replayed})?> _conclude(
    _FirstReplays first, {
    required bool alone,
    required String outDir,
  }) async {
    var _FirstReplays(:id, :key, :count, :filedBase, :filedHead) = first;
    var name = _nameOf(id);
    var sides = [first.base, first.head];
    if (sides.any((side) => !side.clean)) {
      if (!alone) return null;
      onProgress?.call('replaying "$name" again, alone, to confirm · $count');
    } else if (!alone) {
      var pooled = _comparing.time<ScenarioComparison>(
        () => compareScenarioReplays(
          scenario: id,
          base: first.base,
          head: first.head,
        ),
      );
      if (pooled.state.isFinding) {
        _differedInPool.add(id);
        return null;
      }
    }
    var retriesBefore = _retries;
    // One after the other, never together: see [_confirm]. A filed side is
    // a result already and is not confirmed again.
    var baseSide = filedBase != null
        ? ConfirmedSide.result(filedBase)
        : await _confirm(id, key?.base, first.base, base: true, outDir: outDir);
    var headSide = filedHead != null
        ? ConfirmedSide.result(filedHead)
        : await _confirm(
            id,
            key?.head,
            first.head,
            base: false,
            outDir: outDir,
          );
    var replayed = _retries - retriesBefore;

    if (baseSide.replay case var base? when headSide.replay != null) {
      var head = headSide.replay!;
      var compared = _comparing.time<ScenarioComparison>(
        () => compareScenarioReplays(scenario: id, base: base, head: head),
      );
      // Two differences are not believed until each side has done the same
      // thing twice: one in a scenario whose pictures depended on the
      // machine, and one that is only events changing order — see
      // [reorderedEvents]. This is alone: a finding in the pool was deferred
      // above.
      var hazardous = base.hazards.isNotEmpty || head.hazards.isNotEmpty;
      var reordered = compared.state.isFinding
          ? reorderedEvents(compared)
          : null;
      if (compared.state.isFinding && (hazardous || reordered != null)) {
        onProgress?.call(
          hazardous
              ? 'replaying "$name" again, alone: it drew work nothing '
                    'announced · $count'
              : 'replaying "$name" again, alone: only its events changed '
                    'order · $count',
        );
        var unstable = <String>[];
        var unsteady = <String>{};
        var unsteadySides = <String>[];
        for (var (isBase, replay) in [(true, base), (false, head)]) {
          // A side with hazards is never filed, so a filed side is skipped
          // only for them. An order a filed side recorded may be the load of
          // the run that filed it, and is asked again like a fresh one.
          if (reordered == null && (isBase ? filedBase : filedHead) != null) {
            continue;
          }
          var again = await source.shots(id, base: isBase, outDir: outDir);
          replayed++;
          if (!replaysAgree(replay, again)) {
            var side = isBase ? 'the base' : 'this branch';
            if (reordered != null) {
              var drift = reorderedEvents(
                _comparing.time<ScenarioComparison>(
                  () => compareScenarioReplays(
                    scenario: id,
                    base: replay,
                    head: again,
                  ),
                ),
              );
              if (drift != null) {
                unsteady.addAll(unsteadyEvents(replay, again));
                unsteadySides.add(side);
                continue;
              }
            }
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
          return (
            comparison: ScenarioComparison.notCompared(
              scenario: id,
              inconclusive: unstable.map(_capitalized).join(' '),
              baseErrors: base.failures,
              headErrors: head.failures,
              baseMs: base.ms,
              headMs: head.ms,
            ),
            replayed: replayed,
          );
        }
        if (unsteady.isNotEmpty) {
          return (
            comparison: withUnsteadyOrder(
              compared,
              base: base,
              head: head,
              unsteady: unsteady,
              sides: unsteadySides,
            ),
            replayed: replayed,
          );
        }
      }
      return (comparison: compared, replayed: replayed);
    }
    return (
      comparison: ScenarioComparison.notCompared(
        scenario: id,
        inconclusive: [
          ?baseSide.inconclusive,
          ?headSide.inconclusive,
        ].map(_capitalized).join(' '),
        baseErrors: first.base.failures,
        headErrors: first.head.failures,
        baseMs: first.base.ms,
        headMs: first.head.ms,
      ),
      replayed: replayed,
    );
  }

  static String _nameOf(String id) =>
      id.contains('#') ? id.substring(id.indexOf('#') + 1) : id;

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
  /// One scenario on both sides before the next, or [jobs] of them. A
  /// scenario is a process; replaying the whole head side and then the whole
  /// base side would double the time before the first row could be answered,
  /// and the first row is what a reader is waiting for.
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
    Future<ScenariosPlan> planning() => this.plan(graph: graph);
    var plan =
        from ??
        await (clock?.time<ScenariosPlan>('scenarios.plan', planning) ??
            planning());
    onPlan?.call(plan);
    var replaying = Stopwatch()..start();

    var settled = <ScenarioComparison>[];
    for (var scenario in plan.settled) {
      settled.add(scenario);
      onScenario?.call(scenario);
    }

    var toRun = plan.toRun;
    var answered = List<ScenarioComparison?>.filled(toRun.length, null);
    var deferred = <int>[];
    var started = 0;
    var replays = 0;

    Future<void> first(int index) async {
      cancel?.check();
      var id = toRun[index];
      var count = '${++started} of ${toRun.length}';
      var replay = await _firstReplays(
        id,
        key: plan.keys[id],
        count: count,
        outDir: outDir,
      );
      replays += replay.replayed;
      // With one lane, nothing is ever beside it.
      var row = await _conclude(replay, alone: jobs <= 1, outDir: outDir);
      if (row == null) {
        deferred.add(index);
        return;
      }
      replays += row.replayed;
      answered[index] = row.comparison;
      onScenario?.call(row.comparison);
    }

    // Lanes taking the next scenario in plan order, so the first rows are
    // still the first answered.
    var next = 0;
    Future<void> lane() async {
      while (next < toRun.length) {
        await first(next++);
      }
    }

    await Future.wait([
      for (var i = 0; i < toRun.length && (i == 0 || i < jobs); i++) lane(),
    ]);

    // What could not be believed from a replay taken beside others, replayed
    // from the start with nothing beside it — see [jobs]. From the start, and
    // not only its second replay: a first replay slowed by its neighbours
    // compared against a second one that was not is two machines, and would
    // call a scenario unstable that a serial run finds steady.
    clock?.add('scenarios.replay', replaying.elapsed);
    var alone = Stopwatch()..start();
    deferred.sort();
    for (var index in deferred) {
      cancel?.check();
      var id = toRun[index];
      var replay = await _firstReplays(
        id,
        key: plan.keys[id],
        count: 'again, alone',
        outDir: outDir,
      );
      replays += replay.replayed;
      var row = (await _conclude(replay, alone: true, outDir: outDir))!;
      replays += row.replayed;
      answered[index] = row.comparison;
      onScenario?.call(row.comparison);
      if (_differedInPool.contains(id) && !row.comparison.state.isFinding) {
        clock?.pooledOnly(id);
      }
    }
    var items = [...settled, ...answered.nonNulls];
    if (deferred.isNotEmpty) clock?.add('scenarios.alone', alone.elapsed);
    clock
      ?..add('scenarios.compare', _comparing.elapsed)
      ..add('scenarios.filing', _filing.elapsed);

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

/// One scenario's first replay on each side, or what the store filed for a
/// side.
class _FirstReplays {
  _FirstReplays({
    required this.id,
    required this.key,
    required this.count,
    required this.filedBase,
    required this.filedHead,
    required this.base,
    required this.head,
  });

  final String id;
  final ({String base, String head})? key;

  /// `3 of 12`, as the progress says it.
  final String count;

  /// What the store already held for a side, which is never replayed again.
  final ScenarioReplay? filedBase;
  final ScenarioReplay? filedHead;

  final ScenarioReplay base;
  final ScenarioReplay head;

  /// How many of these were replays rather than read from the store.
  int get replayed =>
      [filedBase, filedHead].where((side) => side == null).length;
}
