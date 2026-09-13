import 'dart:io';

import 'package:flutterware/comparison_report.dart';
import 'package:path/path.dart' as p;

import '../plugins/native/previews_core.dart';
import '../plugins/native/scenarios_core.dart';
import '../plugins/worktree_session.dart';
import '../utils/flutter_sdk.dart';
import '../utils/run_dir.dart';
import 'artifact.dart';
import 'base_checkout.dart';
import 'base_ref.dart';
import 'cancel.dart';
import 'comparison_controller.dart';
import 'last_run.dart';
import 'last_run_store.dart';
import 'previews_side.dart';
import 'runner.dart';
import 'scenarios_runner.dart';
import 'scenarios_side.dart';
import 'shot_cache.dart';
import 'shot_store.dart';
import 'shot_store_io.dart';
import 'skip.dart';

/// A comparison's world, built from an open worktree.
///
/// The same runners `fw compare` drives, wired to a session instead of a
/// command line. Nothing here decides anything: which entries are new, what
/// nothing touched, what order rows rank in are all the runners' business, and
/// this is the adapter that hands them a checkout, an SDK and a cache. A panel
/// that made any of those calls itself would be a second answer to a question
/// the CLI already answers.
class SessionComparisonEnvironment implements ComparisonEnvironment {
  SessionComparisonEnvironment({
    required this.session,
    required this.flutterSdk,
    required this.appToolDirectory,
    required this.topLevel,
    required this.base,
    this.headCommit,
    String? cacheRoot,
  }) : cacheRoot = cacheRoot ?? flutterwareDir();

  /// Builds one for [session], resolving the repository top level and the base
  /// ref. Returns null when the worktree is not in a git repository at all —
  /// there is nothing to compare against, and no screen to draw.
  static Future<SessionComparisonEnvironment?> open({
    required WorktreeSession session,
    required FlutterSdkPath flutterSdk,
    required String appToolDirectory,
    String? baseRef,
  }) async {
    String topLevel;
    BaseRef base;
    String? headCommit;
    try {
      topLevel = await BaseRef.topLevelOf(session.worktree.path);
      base = await BaseRef.resolve(topLevel, ref: baseRef);
      headCommit = await BaseRef.headOf(topLevel);
    } on Object {
      return null;
    }
    return SessionComparisonEnvironment(
      session: session,
      flutterSdk: flutterSdk,
      appToolDirectory: appToolDirectory,
      topLevel: topLevel,
      base: base,
      headCommit: headCommit,
    );
  }

  final WorktreeSession session;
  final FlutterSdkPath flutterSdk;
  final String appToolDirectory;

  /// The repository top level, which is what a base checkout mirrors. **Not
  /// the package directory**: a comparison run from inside `fixtures/probe_app`
  /// reported every entry as added until this was the checkout root.
  final String topLevel;

  final BaseRef base;
  final String cacheRoot;

  @override
  String get headRoot => topLevel;

  @override
  String get baseLabel => base.against;

  @override
  String get baseSha => base.sha;

  /// Where HEAD sat when this environment was built — the head half of the
  /// "has anything moved since" check against a kept run.
  @override
  final String? headCommit;

  @override
  bool get baseCheckoutReady => BaseCheckout.isReady(base.sha);

  @override
  ShotStore get shotStore => CacheShotStore(shots);

  late final LastRunStore _lastRuns = LastRunStore(
    comparisonDirFor(cacheRoot, session.worktree),
  );

  @override
  Future<LastComparison?> lastRun(ComparisonHalfKind kind) async =>
      _lastRuns.read(kind);

  @override
  Future<LastComparison?> previousRun(ComparisonHalfKind kind) async =>
      _lastRuns.readPrevious(kind);

  @override
  Future<void> saveLastRun(ComparisonHalfKind kind, LastComparison last) async {
    _lastRuns.write(kind, last);
  }

  PreviewsCore? get _previews =>
      session.session.coreById(uiCatalogPluginId) as PreviewsCore?;

  ScenariosCore? get _scenarios =>
      session.session.coreById(scenariosPluginId) as ScenariosCore?;

  @override
  bool get hasPreviews => _previewsPackages.isNotEmpty;

  @override
  bool get hasScenarios => _scenariosPackages.isNotEmpty;

  List<String> get _previewsPackages => _previews?.packages ?? const [];

  List<String> get _scenariosPackages => _scenarios?.packages ?? const [];

  /// Whether a row's id carries the package that declared it — the same
  /// question `runComparison` asks, and it has to be asked the same way: the
  /// panel and `fw compare` write into the same `index.json`, so an id that
  /// means one thing here and another there is a deep link that lands
  /// nowhere.
  bool get _qualify => {..._previewsPackages, ..._scenariosPackages}.length > 1;

  /// A package's path relative to the checkout top level.
  String _relative(String packageInWorktree) => p.relative(
    p.normalize(p.join(session.worktree.path, packageInWorktree)),
    from: topLevel,
  );

  @override
  late final ShotCache shots = ShotCache(p.join(cacheRoot, 'shots'));

  ShotCache get _cache => shots;

  @override
  Future<String> prepareBase({void Function(String phase)? onProgress}) async {
    var sha7 = base.sha.length > 7 ? base.sha.substring(0, 7) : base.sha;
    onProgress?.call(
      baseCheckoutReady
          ? 'reusing the base checkout of $sha7'
          : 'checking out $sha7',
    );
    var checkout = await BaseCheckout.ensure(
      repoRoot: topLevel,
      sha: base.sha,
      cacheRoot: BaseCheckout.defaultRoot,
      resolve: (path) async {
        // SDK links are machine-made and `.gitignore` hides them, so a fresh
        // checkout has none. The base is given the SDK this session runs
        // under, which is the only SDK flutterware has: the one the invocation
        // named.
        //
        // Nothing makes the base use the one it pinned instead — see
        // `ComparisonRunner.sdk`.
        var link = Link(p.join(path, '.fvm', 'flutter_sdk'));
        if (!link.existsSync()) {
          Directory(p.dirname(link.path)).createSync(recursive: true);
          link.createSync(flutterSdk.root);
        }
        onProgress?.call(
          'resolving dependencies in the base checkout (flutter pub get)',
        );
        var result = await Process.run(flutterSdk.flutter, [
          'pub',
          'get',
        ], workingDirectory: path);
        if (result.exitCode != 0) {
          throw StateError('pub get failed in the base checkout');
        }
      },
    );
    return checkout.path;
  }

  @override
  Future<ComparisonResult> runPreviews(
    String baseRoot, {
    required void Function(ComparedItem row) onRow,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  }) async {
    var packages = _previewsPackages;
    if (packages.isEmpty) throw StateError('no package declares previews');
    var qualify = _qualify;
    var watch = Stopwatch()..start();
    var results = <ComparisonResult>[];
    var refusals = <String, String>{};
    // Serial, and `runComparison` says why at length: a package is two
    // compilers and two guests, and the packages a branch did not touch are
    // nearly free now anyway.
    // The total accumulates, because it sizes a bar that spans every package.
    // The ids owed an answer do **not**: `ComparisonHalf.plan` replaces its
    // pending list rather than adding to it, and by the time the next package
    // plans the previous one has answered everything it owed — so handing the
    // running list over put every finished row back under STILL RENDERING
    // beside itself until the whole half ended.
    var total = 0;
    for (var package in packages) {
      if (packages.length > 1) onProgress?.call('previews in $package');
      var runner = _previewsRunner(
        baseRoot,
        package: package,
        onItem: (row) => onRow(row.inPackage(package, qualify: qualify)),
        onPlan: onPlan == null
            ? null
            : (plan) {
                total += plan.total;
                onPlan(total, [
                  for (var id in plan.toRender)
                    qualify ? comparedIdIn(package, id) : id,
                ]);
              },
        onProgress: onProgress,
        cancel: cancel,
      );
      try {
        results.add((await runner.run()).inPackage(package, qualify: qualify));
      } on ComparisonRefused catch (e) {
        refusals[package] = '$e';
      }
    }
    if (results.isEmpty && refusals.isNotEmpty) {
      throw ComparisonRefused(refusals.values.first);
    }
    return ComparisonResult.merged(
      results,
      baseSha: base.sha,
      headRoot: topLevel,
      elapsed: watch.elapsed,
      refusals: refusals,
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
    var packages = _scenariosPackages;
    if (packages.isEmpty) throw StateError('no package declares scenarios');
    var qualify = _qualify;
    var watch = Stopwatch()..start();
    var halves = <({String package, ScenarioResults results})>[];
    var failures = <(Object, StackTrace)>[];
    var total = 0;
    for (var package in packages) {
      if (packages.length > 1) onProgress?.call('scenarios in $package');
      var side = _scenariosSide(package);
      // Nothing is narrated per side any more. This used to promise a harness
      // per side before the runner had decided whether it needed one, and the
      // run that needs none now never builds one — see `ScenariosRunner.plan`.
      var source = LiveScenarioSource(
        side: side,
        headRoot: topLevel,
        baseRoot: baseRoot,
      );
      try {
        var results =
            await ScenariosRunner(
              headRoot: topLevel,
              baseRoot: baseRoot,
              source: source,
              cache: _cache,
              sdk: flutterSdk.identity,
              pixels: PixelInputs.ofScenarios(
                packagePath: side.packagePath,
                roots: [topLevel, baseRoot],
              ),
              locks: LockSides(
                packagePath: side.packagePath,
                roots: [topLevel, baseRoot],
              ),
              onScenario: (scenario) =>
                  onScenario(scenario.inPackage(package, qualify: qualify)),
              onPlan: onPlan == null
                  ? null
                  : (plan) {
                      // This package's ids only — see `runPreviews`.
                      total += plan.total;
                      onPlan(total, [
                        for (var id in plan.toRun)
                          qualify ? comparedIdIn(package, id) : id,
                      ]);
                    },
              onProgress: onProgress,
              cancel: cancel,
            ).run(
              // Per package: two packages' `test/scenarios/shop_test.dart` are two
              // different files, and one directory would have them writing each
              // other's frames.
              outDir: p.join(
                comparisonDirFor(cacheRoot, session.worktree),
                'scenarios',
                side.packagePath,
              ),
            );
        halves.add((
          package: package,
          results: results.inPackage(package, qualify: qualify),
        ));
      } on ComparisonCancelled {
        // Stop is the controller's to handle, and it must reach it: swallowed
        // here it would read as a package that failed.
        rethrow;
      } on Object catch (error, stack) {
        // A package whose harness will not build is that package's silence,
        // exactly as `fw compare` records it — the two surfaces answer one
        // comparison, and the panel used to refuse the whole half over one
        // package the CLI reported a note for. Still thrown when it is the
        // *only* failure mode on offer, below.
        failures.add((error, stack));
        halves.add((
          package: package,
          results: ScenarioResults.of(
            items: const [],
            ran: 0,
            skipped: 0,
            elapsed: Duration.zero,
            note: '$error',
          ),
        ));
      } finally {
        // Two `flutter_tester` processes and a build directory each, where
        // one was built. A panel that navigated away mid-run would leak both
        // without this.
        await source.dispose();
      }
    }
    // Every package failed: there is no half to show, and the panel's
    // refusal — what a single broken package always produced — is still the
    // right answer. The previews half makes the same call.
    if (failures.length == packages.length) {
      var (error, stack) = failures.first;
      Error.throwWithStackTrace(error, stack);
    }
    return ScenarioResults.merged(halves, elapsed: watch.elapsed);
  }

  ComparisonRunner _previewsRunner(
    String baseRoot, {
    required String package,
    void Function(ComparedItem)? onItem,
    void Function(ComparisonPlan)? onPlan,
    void Function(String)? onProgress,
    CancelToken? cancel,
  }) {
    var core = _previews!;
    return ComparisonRunner(
      headRoot: topLevel,
      baseRoot: baseRoot,
      baseSha: base.sha,
      cache: _cache,
      sdk: flutterSdk.identity,
      onItem: onItem,
      onPlan: onPlan,
      onProgress: onProgress,
      cancel: cancel,
      side: PreviewsSide(
        flutterSdkRoot: flutterSdk.root,
        packagePath: _relative(package),
        root: core.rootFor(package),
        previewAnnotations: core.previewAnnotationsFor(package),
        canvases: core.canvasesFor(package),
        projectClock: core.host.projectClock,
      ),
    );
  }

  ScenariosSide _scenariosSide(String package) => ScenariosSide.of(
    _scenarios!,
    package: package,
    packagePath: _relative(package),
    flutterSdkRoot: flutterSdk.root,
  );

  /// Writes the artifact where `fw compare` writes it, so the GUI and the CLI
  /// leave one file rather than two.
  File writeIndex(ComparisonArtifact artifact) => artifact.writeTo(
    p.join(comparisonDirFor(cacheRoot, session.worktree), 'index.json'),
  );
}
