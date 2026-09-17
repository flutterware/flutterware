import 'dart:convert';
import 'dart:io';

import 'package:flutterware/comparison_report.dart';
// ignore: implementation_imports
import 'package:flutterware/src/comparison/channels.dart' show idsNamedIn;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../plugins/native/previews_core.dart';
import '../plugins/native/previews_results.dart';
import '../plugins/native/scenarios_core.dart';
import '../session/session.dart';
import '../utils/base_href.dart';
import '../utils/flutter_sdk.dart';
import '../utils/run_dir.dart';
import 'artifact.dart';
import 'host_facts.dart';
import 'base_checkout.dart';
import 'base_ref.dart';
import 'pr_report.dart';
import 'phase_clock.dart';
import 'previews_side.dart';
import 'runner.dart';
import 'scenarios_runner.dart';
import 'scenarios_side.dart';
import 'sdk_pins.dart';
import 'shot_cache.dart';
import 'skip.dart';
import 'web_export.dart';

/// Why a comparison could not run at all — no previews, no base, a refusal.
///
/// One type for every surface: `fw compare` prints it and exits 64, the
/// `compare` action reports it as the failure, and neither invents its own
/// wording.
class CompareException implements Exception {
  CompareException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What one comparison was asked to do.
class CompareOptions {
  const CompareOptions({
    this.baseRef,
    this.packages = const [],
    this.entries = const [],
    this.export = false,
    this.exportDir,
    this.baseHref = defaultBaseHref,
    this.reportDir,
    this.frames = ExportedFrames.all,
    this.jobs = 1,
  });

  /// Overrides the base — anything git can name. Null resolves the project's
  /// default branch.
  final String? baseRef;

  /// Which packages to compare, worktree-relative. Empty compares **every**
  /// package each half declares.
  ///
  /// Empty used to mean "the first one declared", which is a default nobody
  /// asked for: a repository with previews in two packages and scenarios in
  /// two others had three quarters of itself silently uncompared, and the
  /// scenario half did not read this option at all — so narrowing to the
  /// second previews package compared it against the *first* scenarios one.
  final List<String> packages;

  /// Narrow to these entry or scenario ids. Empty compares everything.
  final List<String> entries;

  /// Write the browsable page.
  final bool export;

  /// Where the page goes. Null and [export] picks
  /// `build/comparison/web` at the repository top level — or `<report>/web`
  /// when a report is being written, so a comment and the page it links are
  /// hosted together.
  final String? exportDir;

  /// What the exported page says it is mounted under — see [defaultBaseHref].
  final String baseHref;

  /// Write `comment.md` + `mosaic.png` here. Implies the page under
  /// `<reportDir>/web`.
  final String? reportDir;

  /// Which frames the exported page carries — see [ExportedFrames].
  ///
  /// [ExportedFrames.all] by default, and deliberately: an export that leaves
  /// out the unchanged rows' pictures cannot show them, and somebody browsing
  /// what a branch *did not* touch is a real reader. A pull-request page has
  /// no such reader, which is why the CI recipe names the other one.
  final ExportedFrames frames;

  /// How many previews render and how many scenarios replay at once, **per
  /// side** — `--jobs`. Each is a `flutter_tester`, so a run with both sides
  /// busy is up to twice this many.
  ///
  /// One is the default and is the serial comparison: one guest per side,
  /// the base's previews before the head's. More compiles each side's harness
  /// once and starts the rest of its guests from that kernel, renders both
  /// sides' previews together, and replays that many scenarios side by side.
  /// Packages still go one at a time.
  final int jobs;
}

/// Everything one comparison concluded, with where it was written.
class CompareOutcome {
  const CompareOutcome({
    required this.artifact,
    required this.indexPath,
    required this.base,
    this.exported,
    this.report,
  });

  final ComparisonArtifact artifact;
  final String indexPath;
  final BaseRef base;
  final ComparisonWebExport? exported;
  final PrReport? report;
}

/// Runs a whole comparison — both halves, the artifact, and whatever outputs
/// [options] asked for.
///
/// The one orchestration, however it is reached. `fw compare`, the
/// `compare` action an agent invokes, and anything later all call this; the
/// order inside is the design and it is visible in the progress: the SDK check
/// refuses before anything is checked out, the skip rule decides before
/// anything is rendered, and only then does a guest start.
///
/// Refusals throw [CompareException]. Progress lines go to [onProgress]; the
/// halves land in [onPreviews] and [onScenarios] as they complete, because the
/// previews half is the fast one and a caller that waits for both shows a
/// report where it could have shown a wait.
Future<CompareOutcome> runComparison({
  required Session session,
  CompareOptions options = const CompareOptions(),
  void Function(String line)? onProgress,
  void Function(ComparisonResult result)? onPreviews,
  void Function(ScenarioResults results)? onScenarios,
}) async {
  // The page's viewer compiles beside the comparison rather than after it —
  // see [ComparisonWebExporter.prebuild] — and is stopped if the comparison
  // never gets as far as the page: a `flutter build web` outlives the process
  // that started it.
  var exporter = options.export || options.reportDir != null
      ? (ComparisonWebExporter(
          flutterExecutable: session.workspace.flutterSdk.flutter,
          appToolRoot: session.workspace.appContext.appToolDirectory.path,
        )..prebuild())
      : null;
  try {
    return await _runComparison(
      session: session,
      options: options,
      exporter: exporter,
      onProgress: onProgress,
      onPreviews: onPreviews,
      onScenarios: onScenarios,
    );
  } catch (_) {
    await exporter?.cancel();
    rethrow;
  }
}

Future<CompareOutcome> _runComparison({
  required Session session,
  required CompareOptions options,
  required ComparisonWebExporter? exporter,
  void Function(String line)? onProgress,
  void Function(ComparisonResult result)? onPreviews,
  void Function(ScenarioResults results)? onScenarios,
}) async {
  PreviewsCore core;
  try {
    core = session.requireCore(uiCatalogPluginId) as PreviewsCore;
  } on SessionException catch (e) {
    throw CompareException('$e');
  }
  var previewsPackages = wantedPackages(core.packages, options.packages);
  var scenariosCore = _scenariosCore(session);
  var scenariosPackages = wantedPackages(
    scenariosCore?.comparablePackages ?? const [],
    options.packages,
  );
  if (previewsPackages.isEmpty && scenariosPackages.isEmpty) {
    throw CompareException(
      options.packages.isEmpty
          ? 'no package declares previews or scenarios, so there is nothing '
                'to compare.'
          : 'no package matching ${options.packages.join(', ')} declares '
                'previews or scenarios.',
    );
  }
  // Whether a row's id carries the package that declared it. Asked of the
  // **whole comparison** rather than of one half, so that one artifact does
  // not hold qualified previews ids beside bare scenario ones — see
  // [comparedIdIn].
  var qualify = {...previewsPackages, ...scenariosPackages}.length > 1;

  // The two sides are two *checkouts*, not two package directories: a base
  // checkout mirrors the whole worktree, so a package has to be named
  // relative to its top level. Running this from inside `fixtures/probe_app`
  // reported every entry as added until it did.
  var top = await BaseRef.topLevelOf(session.worktree.path);
  String relative(String packageInWorktree) => p.relative(
    p.normalize(p.join(session.worktree.path, packageInWorktree)),
    from: top,
  );
  BaseRef base;
  try {
    base = await BaseRef.resolve(top, ref: options.baseRef);
  } on BaseRefError catch (e) {
    throw CompareException('$e');
  }

  var sdk = session.workspace.flutterSdk;
  onProgress?.call(
    'Comparing against ${base.against} (${abbreviatedSha(base.sha)})…',
  );
  var clock = PhaseClock();
  var checkout = await clock.time<BaseCheckout>(
    'checkout',
    () => BaseCheckout.ensure(
      repoRoot: top,
      sha: base.sha,
      cacheRoot: BaseCheckout.defaultRoot,
      resolve: (path) async {
        // SDK links are machine-made and `.gitignore` hides them, so a fresh
        // checkout has none. The base is given the SDK this session runs under,
        // which is the only SDK flutterware has: the one the invocation named.
        //
        // Nothing makes the base use the one it pinned instead; the verdict
        // says so when the two differ — see `SdkPin.caveat`.
        var link = Link(p.join(path, '.fvm', 'flutter_sdk'));
        if (!link.existsSync()) {
          Directory(p.dirname(link.path)).createSync(recursive: true);
          link.createSync(sdk.root);
        }
        // The base is the same resolution as the head, but it is a *different
        // directory*, and pub resolves per directory.
        onProgress?.call('Resolving the base checkout…');
        var result = await Process.run(sdk.flutter, [
          'pub',
          'get',
        ], workingDirectory: path);
        if (result.exitCode != 0) {
          throw StateError(
            'pub get failed in the base checkout:\n${result.stderr}',
          );
        }
      },
    ),
  );

  var shotCache = ShotCache(p.join(flutterwareDir(), 'shots'));

  // One package at a time, deliberately. Each is two `frontend_server`s and
  // two guests, so a `Future.wait` over four packages is sixteen processes on
  // a runner sized for one build — and since the scenario half stopped
  // building a harness it does not need, a package a branch did not touch now
  // costs milliseconds and there is nothing left to overlap on the runs that
  // matter. A machine with cores to spare says so with `--jobs`, which is
  // spent *inside* a package, where the renders and replays are.
  var jobs = options.jobs < 1 ? 1 : options.jobs;
  var watch = Stopwatch()..start();
  var previews = <ComparisonResult>[];
  var refusals = <String, String>{};
  for (var packageInWorktree in previewsPackages) {
    if (previewsPackages.length > 1) {
      onProgress?.call('Previews in $packageInWorktree…');
    }
    var runner = ComparisonRunner(
      headRoot: top,
      baseRoot: checkout.path,
      baseSha: base.sha,
      cache: shotCache,
      sdk: renderKeyOf(sdk),
      only: options.entries.isEmpty
          ? null
          : idsNamedIn(packageInWorktree, options.entries),
      jobs: jobs,
      clock: clock.within(packageInWorktree, qualify: qualify),
      side: PreviewsSide(
        flutterSdkRoot: sdk.root,
        packagePath: relative(packageInWorktree),
        root: core.rootFor(packageInWorktree),
        previewAnnotations: core.previewAnnotationsFor(packageInWorktree),
        canvases: core.canvasesFor(packageInWorktree),
        projectClock: core.host.projectClock,
      ),
    );
    try {
      previews.add(
        (await runner.run()).inPackage(packageInWorktree, qualify: qualify),
      );
    } on ComparisonRefused catch (e) {
      // One package that will not compile is one package's worth of silence,
      // not the end of the comparison — §11a's argument ("one decision in the
      // source is one row") one level up. It still ends the comparison when
      // it is the *only* package, below, which is what keeps `fw compare`'s
      // exit 64 and its printed diagnostics for a single-package project.
      refusals[packageInWorktree] = '$e';
    }
  }
  if (previews.isEmpty && refusals.isNotEmpty) {
    throw CompareException(refusals.values.first);
  }
  var result = ComparisonResult.merged(
    previews,
    baseSha: base.sha,
    headRoot: top,
    elapsed: watch.elapsed,
    refusals: refusals,
  );
  onPreviews?.call(result);

  var scenarios = await _compareScenarios(
    session: session,
    core: scenariosCore,
    packages: scenariosPackages,
    relative: relative,
    top: top,
    baseRoot: checkout.path,
    sdk: sdk,
    only: options.entries,
    cache: shotCache,
    qualify: qualify,
    jobs: jobs,
    clock: clock,
    onProgress: onProgress,
  );
  if (scenarios != null) onScenarios?.call(scenarios);

  // Read from the first package compared: a pin lives at the top of a
  // repository far more often than beside one of its packages, and the walk
  // up from any of them reaches it.
  var pinned = relative([...previewsPackages, ...scenariosPackages].first);
  // Written once both halves are in. The artifact is the whole verdict, so a
  // file holding only the previews would be a file that answers "did this
  // branch break anything" wrongly.
  var artifact = ComparisonArtifact(
    previews: result,
    scenarios: scenarios,
    caveats: comparisonCaveats(
      previews: result,
      scenarios: scenarios,
      sdk: SdkPin.caveat(
        base: SdkPin.of(checkout.path, packagePath: pinned),
        head: SdkPin.of(top, packagePath: pinned),
        running: sdk.version,
      ),
    ),
    narrowed: options.entries.isNotEmpty,
    // Read once, here, rather than by whoever writes an output: the page and
    // the comment must agree about which push they describe.
    headCommit: await BaseRef.headOf(top),
    at: DateTime.now(),
    host: currentComparisonHost(jobs: jobs),
    clock: clock,
  );
  var index = artifact.writeTo(
    p.join(comparisonDirFor(flutterwareDir(), session.worktree), 'index.json'),
  );

  // The page rides inside the report when both are asked for: a comment that
  // links a viewer wants them hosted together.
  ComparisonWebExport? exported;
  if (exporter != null) {
    var exporting = Stopwatch()..start();
    exported = await exporter.export(
      index: artifact.toJson(),
      cache: shotCache,
      against: base.against,
      output:
          options.exportDir ??
          (options.reportDir != null
              ? p.join(options.reportDir!, 'web')
              : p.join(top, 'build', 'comparison', 'web')),
      baseHref: options.baseHref,
      frames: options.frames,
      onOutput: onProgress,
    );
    if (exporter.viewerCompile case var compile?) clock.add('viewer', compile);
    clock.add('export', exporting.elapsed - exporter.viewerWait);
  }
  PrReport? report;
  if (options.reportDir != null) {
    report = clock.timeSync<PrReport>(
      'report',
      () => writePrReport(
        artifact: artifact,
        cache: shotCache,
        against: base.against,
        head: artifact.headCommit,
        directory: options.reportDir!,
      ),
    );
  }

  // Last, once everything this run wrote has been read back into the outputs:
  // a sweep that ran first would be deciding what to keep without knowing
  // what the run was about to ask for.
  await clock.time<void>(
    'sweep',
    () => sweepComparisonLeftovers(flutterwareDir()),
  );

  // Written again, now that the page, the report and the sweep have a time:
  // the first write had to happen before the page could be built from it.
  artifact.writeTo(index.path);
  if (exported != null) _stampTimings(exported.output, clock.timings);
  onProgress?.call(describeTimings(clock.timings));

  return CompareOutcome(
    artifact: artifact,
    indexPath: index.path,
    base: base,
    exported: exported,
    report: report,
  );
}

/// Puts [timings] into the exported page's own `index.json`, which was
/// written before the page's last steps had a time.
void _stampTimings(String output, ComparisonTimings timings) {
  var file = File(p.join(output, 'index.json'));
  try {
    var index = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, Object?>();
    index['timings'] = timings.toJson();
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(index));
  } on FileSystemException {
    // The page is already whole without it.
  }
}

/// One line saying where a comparison's time went: each phase summed over
/// packages and sides, the scenarios whose steps never settled, and those
/// that differed only beside other replays.
///
/// Summed, so it reads as time *spent* rather than as a timeline — the two
/// sides of a render run at once under `--jobs`, and the viewer compiles
/// beside all of it.
@visibleForTesting
String describeTimings(ComparisonTimings timings) {
  var totals = <String, int>{};
  for (var phase in timings.phases) {
    totals[phase.name] = (totals[phase.name] ?? 0) + phase.ms;
  }
  String seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
  var groups = <String, List<String>>{};
  for (var MapEntry(key: name, value: ms) in totals.entries) {
    var dot = name.indexOf('.');
    var group = dot < 0 ? name : name.substring(0, dot);
    var part = dot < 0 ? null : name.substring(dot + 1);
    groups
        .putIfAbsent(group, () => [])
        .add(part == null ? seconds(ms) : '$part ${seconds(ms)}');
  }
  var line =
      'Time spent: '
      '${[for (var MapEntry(:key, :value) in groups.entries) '$key ${value.join(', ')}'].join(' · ')}';
  String nameOf(String id) =>
      id.contains('#') ? id.substring(id.indexOf('#') + 1) : id;
  String listed(Iterable<String> names, int count) =>
      '${names.join(', ')}${count > 3 ? ' and ${count - 3} more' : ''}';
  String scenarios(int count) => '$count scenario${count == 1 ? '' : 's'}';

  var unsettled = timings.unsettledSteps.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  var pooledOnly = timings.pooledOnlyDifferences;
  var lines = [line];
  if (unsettled.isNotEmpty) {
    var named = [
      for (var MapEntry(:key, :value) in unsettled.take(3))
        '${nameOf(key)} ($value${_ticking(timings.stillTicking[key])})',
    ];
    lines.add(
      '${scenarios(unsettled.length)} had steps that never settled, each '
      'running its whole settle budget: ${listed(named, unsettled.length)}',
    );
  }
  if (pooledOnly.isNotEmpty) {
    lines.add(
      '${scenarios(pooledOnly.length)} differed beside other replays and not '
      'alone, so replayed serially: '
      '${listed(pooledOnly.take(3).map(nameOf), pooledOnly.length)}',
    );
  }
  return lines.join('\n');
}

/// `, still ticking: CircularProgressIndicator (lib/orders.dart:42)` — the
/// first two, since the line names three scenarios and has to stay one line
/// a log can be read by.
String _ticking(List<String>? ticking) {
  if (ticking == null || ticking.isEmpty) return '';
  var more = ticking.length > 2 ? ' and ${ticking.length - 2} more' : '';
  return ', still ticking: ${ticking.take(2).join(', ')}$more';
}

String abbreviatedSha(String sha) => sha.length > 8 ? sha.substring(0, 8) : sha;

/// `--frames=` as both surfaces spell it — `all` or `changed` — or null for
/// anything else.
///
/// One parser, because there were two and they disagreed. The CLI mapped
/// `changed` itself; the action handed the string to
/// `ExportedFrames.fromName`, which reads the *file's* vocabulary (`findings`)
/// and answers `all` for anything it does not know. So the action's own
/// documented option silently exported every frame.
ExportedFrames? exportedFramesFromFlag(String? flag) => switch (flag) {
  null || '' || 'all' => ExportedFrames.all,
  'changed' => ExportedFrames.findings,
  _ => null,
};

/// Which of [declared] a run covers, given what it was asked for.
///
/// An empty [asked] is every package the half declares — the whole point of
/// the option's default. A non-empty one is an intersection rather than a
/// lookup, because the two halves declare different sets and `--package=notes`
/// is a legitimate thing to say to a repository whose previews are elsewhere:
/// it narrows the scenario half and empties the previews one, rather than
/// refusing.
@visibleForTesting
List<String> wantedPackages(List<String> declared, List<String> asked) =>
    asked.isEmpty
    ? declared
    : [
        for (var package in declared)
          if (asked.contains(package)) package,
      ];

ScenariosCore? _scenariosCore(Session session) {
  try {
    return session.requireCore(scenariosPluginId) as ScenariosCore;
  } on SessionException {
    // No scenarios plugin at all: the artifact says nothing about scenarios
    // rather than saying there are none, which are different claims.
    return null;
  }
}

/// Why [artifact]'s verdict is incomplete, or null when it is whole — the
/// exit-code question, asked of the writer's shape.
///
/// The rule itself is the published [verdictGapOf], deliberately: `fw
/// compare`'s exit code, the compare reply an agent reads and a consumer's
/// script over `index.json` may not answer this question differently, which
/// is the same argument `rankComparedFindings` already makes below. What is
/// local here is only pulling the note and the states out of the artifact.
String? verdictGap(ComparisonArtifact artifact) => verdictGapOf(
  scenariosNote: artifact.scenarios?.note,
  previewsNote: artifact.previews.note,
  scenarioStates:
      artifact.scenarios?.items.map((item) => item.state) ?? const [],
  previewStates: artifact.previews.items.map((item) => item.state),
  inconclusiveScenarios: artifact.notCompared.length,
  narrowed: artifact.narrowed,
);

/// The `compare` action, as the previews core invokes it.
///
/// The core cannot run this itself — a comparison spans the previews and
/// scenarios plugins, and a core cannot see its siblings — so the session
/// installs this closure on construction. One orchestration behind every
/// surface: `fw compare`, `fw run previews compare`, and the MCP invoke are
/// all [runComparison].
Future<ComparisonCompareResult> runCompareAction({
  required Session session,
  required Map<String, Object?> arguments,
}) async {
  var entry = arguments['entry'] as String?;
  var export = arguments['export'];
  var frames = exportedFramesFromFlag(arguments['frames'] as String?);
  if (frames == null) {
    throw CompareException(
      '`frames` takes `all` or `changed`, not "${arguments['frames']}".',
    );
  }
  var baseHref = switch (arguments['base-href'] as String?) {
    var given? when given.isNotEmpty => given,
    _ => defaultBaseHref,
  };
  if (baseHrefProblem(baseHref) case var problem?) {
    throw CompareException('`base-href` $problem.');
  }
  var jobs = switch (arguments['jobs']) {
    null || '' => 1,
    int n => n,
    var named => int.tryParse('$named') ?? 0,
  };
  if (jobs < 1) {
    throw CompareException(
      '`jobs` takes a whole number from 1, not "${arguments['jobs']}".',
    );
  }
  var outcome = await runComparison(
    session: session,
    options: CompareOptions(
      baseRef: arguments['base'] as String?,
      // One package narrows; nothing compares every package either half
      // declares. A repeatable argument is `fw compare --package=`'s, and an
      // action takes one value.
      packages: [?arguments['package'] as String?],
      entries: [?entry],
      export: export == true || export == 'true',
      baseHref: baseHref,
      reportDir: arguments['report'] as String?,
      frames: frames,
      jobs: jobs,
    ),
  );

  var artifact = outcome.artifact;
  // Ranked by the published reader's own function rather than here. Two
  // implementations of "which rows are worth attention, and in what order"
  // is two answers to one question, and this surface and a consumer's script
  // reading the same `index.json` may not give different ones.
  var ranked = rankComparedFindings(
    previews: artifact.previews.items,
    scenarios: artifact.scenarios?.items ?? const [],
  );

  var report = outcome.report;
  return ComparisonCompareResult(
    against: outcome.base.against,
    baseSha: outcome.base.sha,
    counts: {
      for (var entry in artifact.counts.entries) entry.key.name: entry.value,
    },
    channels: _channelCounts(ranked),
    eventChannels: _eventChannelCounts(ranked),
    shapes: [
      for (var row in foldChannelDeltas(ranked.map(_deltasOf)).take(_maxShapes))
        _wireDelta(row),
    ],
    findings: [
      for (var finding in ranked)
        () {
          var deltas = foldChannelDeltas([_deltasOf(finding)]);
          return ComparisonFinding(
            id: finding.id,
            half: finding.half.name,
            state: finding.state.name,
            note: finding.note,
            delta: finding.preview == null
                ? _scenarioDelta(finding.scenario!)
                : _pixelsDelta(finding.preview!),
            deltas: [
              for (var row in deltas.take(_maxDeltasPerFinding))
                _wireDelta(row),
            ],
            deltasDropped: deltas.length > _maxDeltasPerFinding
                ? deltas.length - _maxDeltasPerFinding
                : 0,
          );
        }(),
    ],
    index: outcome.indexPath,
    export: outcome.exported?.output,
    report: report == null ? null : p.dirname(report.commentPath),
    scenariosNote: artifact.scenarios?.note,
    verdictGap: verdictGap(artifact),
  );
}

/// How much of a finding's detail rides in the reply.
///
/// A cap, because the artifact is the record and this is the summary: an agent
/// asking what a branch did should not be handed four hundred lines of system
/// chatter to reach the two that matter, and `index` has every one of them.
const _maxDeltasPerFinding = 8;

/// How many distinct shapes the verdict names before it stops.
///
/// Larger than the per-finding cap because this is the summary a reader
/// actually reads, and folding has already collapsed the repetition that made
/// a cap necessary in the first place.
const _maxShapes = 12;

/// A folded row on the wire. `count` and `items` are omitted at one, the way
/// `deltasDropped` is omitted at zero.
ComparisonDelta _wireDelta(FoldedDelta row) => ComparisonDelta(
  channel: row.delta.channel,
  subchannel: row.delta.subchannel,
  subject: row.delta.subject,
  property: row.delta.property,
  base: row.delta.base,
  head: row.delta.head,
  origin: row.delta.origin,
  count: row.count > 1 ? row.count : null,
  items: row.items > 1 ? row.items : null,
);

/// A finding's differences, whichever half it came from.
///
/// A preview is one item; a scenario is a tree of them, and its steps carry
/// the channels. Flattening both to the same faceted list is what lets a
/// reader filter a comparison without first asking which half a row is in.
List<ChannelDelta> _deltasOf(ComparedFinding finding) {
  if (finding.preview case var preview?) return preview.deltas;
  return [
    for (var step in finding.scenario?.items ?? const <ComparedItem>[])
      if (isComparedFinding(step.state)) ...step.deltas,
  ];
}

/// How many findings each channel had something to say about.
///
/// Per finding, not per delta: a step whose `system` chatter moved four
/// hundred times is one finding with something to say about events, and
/// counting the deltas here would make the events channel look like the whole
/// branch. The per-delta breakdown that *is* worth having is
/// [_eventChannelCounts], where the volume is the point.
Map<String, int> _channelCounts(List<ComparedFinding> findings) {
  var counts = <String, int>{};
  for (var finding in findings) {
    for (var channel in {for (var delta in _deltasOf(finding)) delta.channel}) {
      counts[channel] = (counts[channel] ?? 0) + 1;
    }
  }
  return counts;
}

Map<String, int> _eventChannelCounts(List<ComparedFinding> findings) {
  var counts = <String, int>{};
  for (var finding in findings) {
    for (var delta in _deltasOf(finding)) {
      if (delta.channel != 'events') continue;
      var key = delta.subchannel ?? 'unknown';
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  return Map.fromEntries(
    counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
  );
}

String? _pixelsDelta(ComparedItem item) {
  var pixels = item.pixels?.diff;
  if (pixels == null || !pixels.changed) return null;
  return '${(pixels.fraction * 100).toStringAsFixed(2)}% · '
      '${pixels.clusters.length} '
      'region${pixels.clusters.length == 1 ? '' : 's'}';
}

String? _scenarioDelta(ScenarioComparison scenario) {
  for (var step in scenario.items) {
    if (isComparedFinding(step.state)) return 'step `${step.id}`';
  }
  if (scenario.branches.isNotEmpty) {
    return '${scenario.branches.length} '
        'branch${scenario.branches.length == 1 ? '' : 'es'}';
  }
  return null;
}

/// The scenario half of a comparison.
///
/// Separate from the previews half rather than folded into the same runner,
/// and the design doc argues why at length: a preview is one picture and a
/// scenario is a *tree* of them. What they share is the kernel — the same
/// pixel, tree and text channels — and the skip rule, which asks the same
/// question of a scenario's closure that it asks of an entry's.
Future<ScenarioResults?> _compareScenarios({
  required Session session,
  required ScenariosCore? core,
  required List<String> packages,
  required String Function(String packageInWorktree) relative,
  required String top,
  required String baseRoot,
  required FlutterSdkPath sdk,
  required List<String> only,
  required ShotCache cache,
  required bool qualify,
  required int jobs,
  required PhaseClock clock,
  void Function(String line)? onProgress,
}) async {
  if (core == null || packages.isEmpty) return null;
  var watch = Stopwatch()..start();
  var halves = <({String package, ScenarioResults results})>[];
  for (var package in packages) {
    if (packages.length > 1) onProgress?.call('Scenarios in $package…');
    halves.add((
      package: package,
      results: await _comparePackageScenarios(
        session: session,
        core: core,
        package: package,
        // The key names a folder; the checkout path is its package's.
        packagePath: relative(core.packagePathFor(package)),
        top: top,
        baseRoot: baseRoot,
        sdk: sdk,
        only: idsNamedIn(package, only),
        cache: cache,
        qualify: qualify,
        jobs: jobs,
        clock: clock.within(package, qualify: qualify),
        onProgress: onProgress,
      ),
    ));
  }
  return ScenarioResults.merged(halves, elapsed: watch.elapsed);
}

/// One package's scenarios, on both sides.
Future<ScenarioResults> _comparePackageScenarios({
  required Session session,
  required ScenariosCore core,
  required String package,
  required String packagePath,
  required String top,
  required String baseRoot,
  required FlutterSdkPath sdk,
  required List<String> only,
  required ShotCache cache,
  required bool qualify,
  required int jobs,
  required PhaseClock clock,
  void Function(String line)? onProgress,
}) async {
  var watch = Stopwatch()..start();
  var side = ScenariosSide.of(
    core,
    package: package,
    packagePath: packagePath,
    flutterSdkRoot: sdk.root,
  );
  var source = LiveScenarioSource(
    side: side,
    headRoot: top,
    baseRoot: baseRoot,
    guests: jobs,
  );
  try {
    try {
      var results =
          await ScenariosRunner(
            headRoot: top,
            baseRoot: baseRoot,
            source: source,
            cache: cache,
            sdk: renderKeyOf(sdk),
            pixels: PixelInputs.ofScenarios(
              packagePath: side.packagePath,
              roots: [top, baseRoot],
            ),
            locks: LockSides(
              packagePath: side.packagePath,
              roots: [top, baseRoot],
            ),
            only: only.isEmpty ? null : only,
            jobs: jobs,
            clock: clock,
          ).run(
            // Per package, because two packages' `test/scenarios/shop_test.dart`
            // are two different files and one directory would have them writing
            // each other's frames.
            outDir: p.join(
              comparisonDirFor(flutterwareDir(), session.worktree),
              'scenarios',
              packagePath,
            ),
          );
      return results.inPackage(package, qualify: qualify);
    } on Object catch (error) {
      // A side whose harness will not build is a side, not a crash — the same
      // rule the previews half follows, and the same skew causes it. It goes
      // into the artifact too: an empty list is what a project with no
      // scenarios leaves behind, and a reader has to be able to tell the two
      // apart.
      //
      // **Whole, not the first line**, for the reason the previews half
      // already learned: the compiler puts its summary on the first line and
      // its diagnostics on the ones after, and a note naming neither the file
      // nor the symbol is a refusal nobody can act on. A progress line is one
      // line by definition, so that one still gets the head of it.
      var note = '$error';
      onProgress?.call('scenarios: ${note.split('\n').first}');
      return ScenarioResults.of(
        items: const [],
        ran: 0,
        skipped: 0,
        elapsed: watch.elapsed,
        note: note,
      );
    }
  } finally {
    await source.dispose();
  }
}
