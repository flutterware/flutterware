import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutterware/comparison_report.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../shell/worktree.dart';
import 'runner.dart';
import 'shot_cache.dart';
import 'skip.dart';

/// One worktree's corner of the shared comparisons cache: `index.json` and
/// the `scenarios/` frames it references, together.
///
/// Keyed by the canonical *path*, because the worktree's name is unique only
/// within its repository — every repository's main checkout is named `~` —
/// and this directory is shared by every project on the machine. Two agents
/// comparing in two worktrees used to write the same
/// `comparisons/scenarios/<file>/<scenario>` frames and read back each
/// other's pixels. The directory name keeps the checkout's directory name in
/// front so a human browsing the cache can still tell which is which.
String comparisonDirFor(String cacheRoot, Worktree worktree) => p.join(
  cacheRoot,
  'comparisons',
  '${worktree.directoryName}-'
      '${sha1.convert(utf8.encode(p.canonicalize(worktree.path))).toString().substring(0, 12)}',
);

/// What a reader has to know before believing a verdict: the ways its two
/// sides were measured differently, rather than drawn differently.
///
/// Both come from one fact — the base is rendered by the base checkout's own
/// `package:flutterware`, with whichever SDK this comparison was started
/// with — and both used to surface only as findings nobody could tell from
/// the branch's own:
///
/// - **Trees read by two versions of the walk.** Their differences are
///   carried and do not count (see `TreeChannel.significant`), so a row can
///   read `same` beside tree deltas; this says why, and how many.
/// - **Two pinned SDKs**, from [sdk] — see `SdkPin.caveat`.
List<String> comparisonCaveats({
  required ComparisonResult previews,
  ScenarioResults? scenarios,
  String? sdk,
}) {
  bool uncounted(ComparedItem item) =>
      (item.tree?.skewed ?? false) && item.tree!.changed;
  var rows =
      previews.items.where(uncounted).length +
      [
        for (var scenario in scenarios?.items ?? const <ScenarioComparison>[])
          ...scenario.items,
      ].where(uncounted).length;
  var trees = rows == 0
      ? null
      : 'Widget-tree differences on '
            '${rows == 1 ? '1 row are' : '$rows rows are'} left out of the '
            'verdict: the base read its trees with a different version of '
            'flutterware, so they differ in how widgets are described as well '
            'as in what changed. Pixels and texts still count.';
  return [?trees, ?sdk];
}

/// Trims what comparisons leave under [cacheRoot] — the shot cache and every
/// worktree's [comparisonDirFor] — off this isolate, and says nothing about
/// it.
///
/// Run at the end of every comparison, by both surfaces. Only the studio's
/// panel used to sweep, and only the shots: a CI host runs nothing but
/// `fw compare`, so the store it restores and saves between jobs grew without
/// bound, and so did one comparison directory per checkout path. The third
/// store, the base checkouts, sweeps itself — `BaseCheckout.ensure`.
///
/// Every failure is swallowed: the entries it drops are ones nothing has
/// asked for in a fortnight, and failing to drop them is not news.
Future<void> sweepComparisonLeftovers(String cacheRoot) async {
  try {
    await Isolate.run(() {
      ShotCache(p.join(cacheRoot, 'shots')).sweep();
      sweepComparisonDirs(cacheRoot);
    });
  } on Object {
    // Housekeeping.
  }
}

/// Drops every worktree's comparison directory that nothing has written in
/// [keepFor], and returns how many.
///
/// Judged by the newest file directly inside it, which every run rewrites —
/// `index.json`, a panel's `last-*.json` — rather than by the directory's own
/// mtime, which moves only when an entry is added or removed. A directory
/// with no file of its own is judged by itself.
///
/// Keyed by checkout path, which a runner handing each job a fresh one turns
/// into a directory per job. Two weeks is the same age the other two stores
/// forget at, so a worktree compared once and abandoned leaves nothing behind
/// that outlives its pictures.
int sweepComparisonDirs(
  String cacheRoot, {
  Duration keepFor = const Duration(days: 14),
  DateTime? now,
}) {
  var root = Directory(p.join(cacheRoot, 'comparisons'));
  var cutoff = (now ?? DateTime.now()).subtract(keepFor);
  List<FileSystemEntity> found;
  try {
    found = root.listSync();
  } on FileSystemException {
    return 0;
  }
  var swept = 0;
  for (var entity in found) {
    if (entity is! Directory) continue;
    try {
      DateTime? touched;
      for (var child in entity.listSync()) {
        if (child is! File) continue;
        var modified = child.statSync().modified;
        if (touched == null || modified.isAfter(touched)) touched = modified;
      }
      touched ??= entity.statSync().modified;
      if (!touched.isBefore(cutoff)) continue;
      entity.deleteSync(recursive: true);
      swept++;
    } on FileSystemException {
      // Another comparison sweeping, or writing, the same directory.
    }
  }
  return swept;
}

/// The scenario half of a comparison, as the artifact records it.
///
/// The twin of [ComparisonResult] and deliberately not the same class: a
/// preview run counts *renders*, because the skip rule is what it is trying to
/// prove, and a scenario run counts whole scenarios, because one of those is a
/// process and the pictures inside it are not the unit anybody thinks in.
class ScenarioResults {
  const ScenarioResults({
    required this.items,
    required this.ran,
    required this.skipped,
    required this.elapsed,
    this.replays = 0,
    this.note,
    this.because = const {},
    this.packages = const [],
  });

  /// Several packages' halves as one — the twin of [ComparisonResult.merged],
  /// and the same rules: rows concatenate and re-rank, counters add, causes
  /// fold, and [elapsed] is the caller's wall clock rather than a sum.
  ///
  /// The notes join with the package that produced each in front, because
  /// "the harness would not build" is not actionable until a reader knows
  /// whose.
  static ScenarioResults merged(
    List<({String package, ScenarioResults results})> halves, {
    required Duration elapsed,
  }) {
    var notes = [
      for (var half in halves)
        if (half.results.note case var note?) '${half.package}: $note',
    ];
    return ScenarioResults.of(
      items: [for (var half in halves) ...half.results.items],
      ran: halves.fold(0, (sum, half) => sum + half.results.ran),
      replays: halves.fold(0, (sum, half) => sum + half.results.replays),
      skipped: halves.fold(0, (sum, half) => sum + half.results.skipped),
      elapsed: elapsed,
      note: notes.isEmpty ? null : notes.join('\n'),
      because: mergeBecause([for (var half in halves) half.results.because]),
      packages: [for (var half in halves) half.package],
    );
  }

  /// Every scenario, worst first — the ones that ran, and the ones that exist
  /// on one side only.
  final List<ScenarioComparison> items;

  /// How many were compared from both sides' frames — replayed, or read back
  /// from the `ReplayStore`.
  final int ran;

  /// How many sides were actually replayed: two per scenario in [ran], plus
  /// one for every side replayed again to confirm what it did the first time,
  /// and none for a side the store already had. The scenario twin of
  /// [ComparisonResult.rendered].
  final int replays;

  final int skipped;
  final Duration elapsed;

  /// Why there is nothing here, when there is nothing here.
  ///
  /// Recorded rather than only printed. A harness that will not build
  /// leaves the same empty list as a project with no scenarios at all, and a
  /// reader who cannot tell those apart will read a silent artifact as a clean
  /// one.
  final String? note;

  /// Why the skip rule could not answer the scenarios it could not answer,
  /// folded — see [foldReasons]. The twin of [ComparisonResult.because].
  final Map<String, int> because;

  /// Which packages this half covered — the twin of
  /// [ComparisonResult.packages].
  final List<String> packages;

  /// This half, with every scenario addressed inside [package] — the twin of
  /// [ComparisonResult.inPackage].
  ScenarioResults inPackage(String package, {required bool qualify}) =>
      ScenarioResults.of(
        items: [
          for (var item in items) item.inPackage(package, qualify: qualify),
        ],
        ran: ran,
        replays: replays,
        skipped: skipped,
        elapsed: elapsed,
        note: note,
        because: because,
        packages: [package],
      );

  int countOf(ComparedState state) =>
      items.where((item) => item.state == state).length;

  /// Assembles the half, ranking it the way the previews half ranks: worst
  /// first, since [ComparedState] is declared in that order.
  static ScenarioResults of({
    required List<ScenarioComparison> items,
    required int ran,
    required int skipped,
    required Duration elapsed,
    int replays = 0,
    String? note,
    Map<String, int> because = const {},
    List<String> packages = const [],
  }) => ScenarioResults(
    items: [...items]
      ..sort((a, b) {
        var byState = a.state.index.compareTo(b.state.index);
        return byState != 0 ? byState : a.scenario.compareTo(b.scenario);
      }),
    ran: ran,
    replays: replays,
    skipped: skipped,
    elapsed: elapsed,
    note: note,
    because: because,
    packages: packages,
  );

  Map<String, Object?> toJson() => {
    'ran': ran,
    'replayed': replays,
    'skipped': skipped,
    'because': ?(because.isEmpty ? null : because),
    'packages': ?(packages.isEmpty ? null : packages),
    'ms': elapsed.inMilliseconds,
    'note': ?note,
    'counts': {
      for (var state in ComparedState.values)
        if (countOf(state) > 0) state.name: countOf(state),
    },
    'items': [for (var item in items) item.toJson()],
  };
}

/// Everything one comparison concluded, both halves, as one file.
///
/// One artifact, not two. The GUI, an agent and a static page all read this
/// rather than each computing their own, and a reader asking "did this branch
/// break anything" is asking about the branch — not about previews and then
/// separately about scenarios. Which is also why the halves are named rather
/// than merged: they are compared by different machinery and a row from one is
/// not interchangeable with a row from the other.
class ComparisonArtifact {
  const ComparisonArtifact({
    required this.previews,
    this.scenarios,
    this.narrowed = false,
    this.headCommit,
    this.at,
    this.caveats = const [],
  });

  final ComparisonResult previews;

  /// What a reader has to know before believing the verdict, one sentence
  /// each — see [comparisonCaveats].
  final List<String> caveats;

  /// Absent when the project declares no scenarios at all. A run that tried
  /// and could not is present, with a [ScenarioResults.note].
  final ScenarioResults? scenarios;

  /// Where HEAD sat when this ran, and when that was.
  ///
  /// Neither is a fact about the comparison; both are facts about *this*
  /// comparison, which is what a reader arriving from a pull-request comment
  /// needs before anything else — is this still the branch I am looking at,
  /// and is it still today. The page could not say either: `head` records the
  /// worktree's **path**, which means nothing off the machine that ran it.
  final String? headCommit;

  final DateTime? at;

  /// Whether the run was narrowed to named entries (`--entry`).
  ///
  /// In the artifact rather than only in the command's hand, because the
  /// all-failed gap rule reads it — see [verdictGapOf] — and a consumer's
  /// script reading `index.json` has to apply that rule the way the writer
  /// did.
  final bool narrowed;

  /// Every row either half produced, counted by state.
  ///
  /// The header a reader wants first — one preview that broke and one scenario
  /// that broke is two broken things, and asking which half they came from is
  /// the second question, not the first.
  Map<ComparedState, int> get counts {
    var counts = <ComparedState, int>{};
    for (var state in [
      for (var item in previews.items) item.state,
      for (var item in scenarios?.items ?? const <ScenarioComparison>[])
        item.state,
    ]) {
      counts[state] = (counts[state] ?? 0) + 1;
    }
    return counts;
  }

  /// The scenarios replayed and not compared — see
  /// [ScenarioComparison.inconclusive].
  List<ScenarioComparison> get notCompared => [
    for (var scenario in scenarios?.items ?? const <ScenarioComparison>[])
      if (!scenario.compared) scenario,
  ];

  /// True when nothing either half looked at came out worse than [same].
  bool get clean => !counts.keys.any(
    (state) => state != ComparedState.same && state != ComparedState.skipped,
  );

  Map<String, Object?> toJson() => {
    'version': comparisonReportVersion,
    'base': previews.baseSha,
    'head': previews.headRoot,
    'headCommit': ?headCommit,
    'at': ?at?.toUtc().toIso8601String(),
    'ms':
        previews.elapsed.inMilliseconds +
        (scenarios?.elapsed.inMilliseconds ?? 0),
    'counts': {
      for (var state in ComparedState.values)
        if ((counts[state] ?? 0) > 0) state.name: counts[state],
    },
    // Named halves rather than one flat list: `items` at the top of a file
    // holding both would mean previews to whoever wrote it and everything to
    // whoever reads it.
    // Where the frames are, said rather than left to be guessed at from
    // whether a path looks absolute. This file names `ShotCache` keys and
    // paths under `~/.flutterware`; the export rewrites both and overwrites
    // this. See [ComparisonFrames].
    'frames': ComparisonFrames.local.name,
    if (narrowed) 'narrowed': true,
    'caveats': ?(caveats.isEmpty ? null : caveats),
    'previews': previews.toJson(),
    'scenarios': ?scenarios?.toJson(),
  };

  /// Writes the artifact, creating its directory.
  File writeTo(String path) {
    var file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    return file;
  }
}
