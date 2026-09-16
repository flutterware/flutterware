import 'scenario_diff.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/comparison_report.dart';
import 'package:path/path.dart' as p;
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/network_mode.dart';

import '../plugins/native/scenarios_core.dart';
import '../scenarios/discovery.dart';
import '../scenarios/harness_entrypoint.dart';
import '../scenarios/runner.dart';
import '../embedder/build_directory.dart';
import 'scenario_alignment.dart';

/// Running one checkout's scenarios and reading back what they captured.
///
/// The scenario twin of `PreviewsSide`, and shaped differently for a reason
/// the design doc argues at length: a preview is one picture and a scenario is
/// a *tree* of them, so there is nothing here that fits the entry-shaped
/// runner. What it produces is what [ScenarioComparison] aligns.
class ScenariosSide {
  ScenariosSide({
    required this.flutterSdkRoot,
    required this.packagePath,
    required this.directory,
    this.projectClock,
    this.projectNetwork,
  });

  /// One of [core]'s packages as a side, run the way the project says its
  /// scenarios run.
  ///
  /// The one way both surfaces build a side. Each used to build its own, and
  /// `fw compare`'s forgot the project's `fw.network(...)`: CI replayed every
  /// scenario with the network off while the studio replayed it as declared,
  /// and a comparison is only as good as its two runs being the same run.
  factory ScenariosSide.of(
    ScenariosCore core, {
    required String package,
    required String packagePath,
    required String flutterSdkRoot,
  }) => ScenariosSide(
    flutterSdkRoot: flutterSdkRoot,
    packagePath: packagePath,
    directory: core.scanRootFor(package),
    projectClock: core.host.projectClock,
    projectNetwork: core.host.projectNetwork,
  );

  final String flutterSdkRoot;

  /// The package inside each checkout, relative to its top level.
  final String packagePath;

  /// The scenario directory inside the package, as the project declares it.
  ///
  /// Taken from the **head** checkout for both sides, like the previews scan
  /// root: a branch that moved its scenarios would otherwise compare the old
  /// directory against the new one and report every scenario as removed and
  /// re-added.
  final String directory;

  /// What `clock.now()` reads inside every scenario of both runs, or null for
  /// flutterware's own `pinnedClockOrigin`.
  ///
  /// Nothing is pinned *here* any more. This used to hold a private copy of
  /// the instant, written separately from the two others that already existed
  /// — which is the argument for the default being the pin rather than
  /// something each consumer remembers. All this carries now is the project's
  /// own `fw.clock(...)`, so both checkouts render at the date the rest of the
  /// project renders at.
  final DateTime? projectClock;

  /// The project's `fw.network(...)`, carried for the reason [projectClock] is:
  /// both sides of a comparison have to reach the same thing, or the diff is
  /// about the network rather than about the branch.
  final ScenarioNetwork? projectNetwork;

  /// [projectClock] and [projectNetwork], as a replay's key spells them: both
  /// decide what every scenario draws, and neither is in any file a closure
  /// reaches.
  Map<String, String> get settings => {
    'clock': projectClock?.toUtc().toIso8601String() ?? 'pinned',
    'network': projectNetwork?.name ?? 'default',
  };

  /// An id is `<file>#<scenario>` — the same grammar a preview entry uses, and
  /// the same reason: the file alone does not name one, since a file holds
  /// several.
  static String idFor({required String file, required String scenario}) =>
      '$file#$scenario';

  /// The `flutter_test_config.dart` that governs [id] in [checkout],
  /// relative to the checkout root — or null where no folder config does.
  ///
  /// The harness imports it, so it decides what the scenario draws as surely
  /// as the scenario's own file does: a theme, the fonts, the device. It is
  /// not in the scenario's import closure — nothing the scenario writes names
  /// it — so without this a change to it, or a bump to a package only it
  /// imports, reached no scenario at all. Found with the same rule the harness
  /// uses, [testConfigFolderFor], so the two cannot disagree about which file
  /// that is.
  String? configOf(String checkout, String id) {
    var hash = id.indexOf('#');
    var file = hash < 0 ? id : id.substring(0, hash);
    var folder = testConfigFolderFor(
      p.normalize(p.join(checkout, packagePath)),
      file,
    );
    if (folder == null) return null;
    return p.normalize(p.join(packagePath, folder, testConfigFileName));
  }

  /// Where a scenario's source lives, relative to a checkout root.
  String fileOf(String id) {
    var hash = id.indexOf('#');
    return p.normalize(
      p.join(packagePath, hash < 0 ? id : id.substring(0, hash)),
    );
  }

  /// Every scenario [checkout] declares, as ids.
  ///
  /// Live rather than scanned: only the running harness knows a scenario's
  /// tags and its folder profile, and this has to start a runner to run
  /// anything anyway.
  Future<List<String>> scenarios(ScenarioRunner runner) async => [
    for (var listing in await runner.list())
      idFor(file: listing.file, scenario: listing.name),
  ];

  /// Every scenario [checkout] declares, read from its **sources**.
  ///
  /// The cheap twin of [scenarios], and the difference is the whole fixed cost
  /// of this half: that one asks a live harness, which has to be generated,
  /// compiled and booted first — on each side, before a single closure has
  /// been looked at. This parses the very files that harness's entrypoint is
  /// generated from, with the same scanner and the same root.
  ///
  /// Null where the scan cannot promise the whole set. A `scenario()` whose
  /// name is *built* rather than written is invisible to a parser and present
  /// in the harness's own listing, and a plan made from a listing one short
  /// would call a scenario nobody removed removed. Tags and `skip:` are
  /// missing from here too and do not matter: they decide what a replay does,
  /// and whoever asks this is deciding whether to replay at all.
  List<String>? scannedScenarios(String checkout) {
    var scan = ScenarioScanner(
      packageRoot: p.normalize(p.join(checkout, packagePath)),
      directory: directory,
    ).scan();
    if (scan.unnamed > 0) return null;
    // Duplicates are kept rather than folded: the harness lists a name
    // declared twice twice, and a listing that disagrees with the one it
    // stands in for is worse than no listing.
    return [
      for (var ref in scan.scenarios) idFor(file: ref.file, scenario: ref.name),
    ];
  }

  /// A runner for [checkout], building in a claimed directory of its own.
  ///
  /// Never the default `build/flutterware`: the head checkout is the very
  /// worktree the panel's warm runner lives on, the base checkout is shared
  /// by every comparison on the machine, and `TesterHost.exclusive`
  /// serializes nothing across hosts. Whoever disposes the runner releases
  /// the claim — `LiveScenarioSource.dispose` does.
  ScenarioRunner runnerFor(String checkout) {
    var packageRoot = p.normalize(p.join(checkout, packagePath));
    return ScenarioRunner(
      packageRoot: packageRoot,
      directory: directory,
      flutterSdkRoot: flutterSdkRoot,
      buildDirectory: claimBuildDirectory(
        packageRoot,
        root: comparisonBuildRoot,
      ),
      projectClock: projectClock,
      projectNetwork: projectNetwork,
      // A comparison reads each checkout once: its replays are filed under
      // keys hashed before the first one started. And it is what lets further
      // guests share this one's kernel.
      followEdits: false,
    );
  }

  /// Runs [id] and reads back every step it captured.
  ///
  /// Raw captures, never PNG, and not for the 31% it happens to be worth
  /// here: the diff reads every pixel, and `fw compare` is a CLI command, so
  /// the decode PNG would force has no engine codec to do it with. It would
  /// fall to `package:image` in pure Dart, on every frame of both sides, to
  /// undo an encode this had just paid for. See `ScenarioRunArgs.captureRaw`.
  ///
  /// The clock is pinned so two runs a day apart produce the same pictures —
  /// by the runner now, from [projectClock] or the default, so there is
  /// nothing to pass here.
  Future<ScenarioReplay> run(
    ScenarioRunner runner,
    String id, {
    required String outDir,
  }) async {
    var hash = id.indexOf('#');
    var response = await runner.run(
      outDir: outDir,
      file: hash < 0 ? id : id.substring(0, hash),
      scenario: hash < 0 ? null : id.substring(hash + 1),
      captureRaw: true,
    );
    // A scenario that blew its deadline: the report is what it reached.
    var complete = response['abandoned'] != true;
    var scenarios = (response['scenarios'] as List?) ?? const [];
    var outcome = scenarios.firstOrNull;
    if (outcome is! Map) return ScenarioReplay(const [], complete: complete);
    return ScenarioReplay(
      [
        for (var step in (outcome['steps'] as List?) ?? const [])
          if (step is Map) _shotOf(step.cast<String, Object?>()),
      ],
      complete: complete,
      ms: outcome['ms'] as int?,
      // The outcome's own word, not only its steps': a scenario can fail
      // without capturing anything, and a replay read as steps alone called
      // that an empty run.
      errors: [
        for (var error in (outcome['errors'] as List?) ?? const [])
          if (error is Map && error['error'] is String)
            firstLineOf(error['error'] as String),
      ],
    );
  }

  static ScenarioStepShot _shotOf(Map<String, Object?> step) {
    var image = step['image'] as String?;
    var tree = _tree(step['tree'] as String?);
    return ScenarioStepShot(
      step: AlignableStep(
        index: step['index']! as int,
        position: step['position'] as String? ?? '',
        parent: step['parent'] as int?,
        branch: step['branch'] as String?,
        name: step['name'] as String?,
        verb: step['verb'] as String?,
        target: step['target'] as String?,
        failure: step['failure'] as String?,
      ),
      // Only a raw capture is comparable as pixels. A PNG here would mean the
      // run was asked for one, which this never does — and decoding it to
      // compare would undo the reason raw exists.
      rgba: step['format'] == 'raw' && image != null ? _bytes(image) : null,
      width: step['width'] as int? ?? 0,
      height: step['height'] as int? ?? 0,
      tree: tree?.root,
      treeFormat: tree?.format,
      texts: (step['texts'] as List?)?.cast<String>() ?? const [],
      events: _events(step['events'] as String?),
      failure: step['failure'] as String?,
      guessed: step['guessed'] as int?,
      frame: step['format'] == 'raw' && image != null
          ? FrameRef(
              path: image,
              width: step['width'] as int? ?? 0,
              height: step['height'] as int? ?? 0,
            )
          : null,
    );
  }

  static Uint8List? _bytes(String path) {
    var file = File(path);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  /// The tree the harness wrote beside a frame, with the format it was read
  /// in — see [InspectTree.format].
  static InspectTree? _tree(String? path) {
    if (path == null) return null;
    var file = File(path);
    if (!file.existsSync()) return null;
    try {
      var json = jsonDecode(file.readAsStringSync());
      return json is Map<String, Object?> ? InspectTree.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  static List<Map<String, Object?>> _events(String? path) {
    if (path == null) return const [];
    var file = File(path);
    if (!file.existsSync()) return const [];
    try {
      var json = jsonDecode(file.readAsStringSync());
      var list = json is Map ? json['events'] : json;
      return [
        for (var event in list as List? ?? const [])
          if (event is Map) event.cast<String, Object?>(),
      ];
    } on FormatException {
      return const [];
    }
  }
}
