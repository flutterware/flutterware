import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// ignore: implementation_imports
import 'package:flutterware/src/inspect/error.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

import '../previews/catalog_entry.dart';
import '../previews/devices.dart';
import '../previews/discovery.dart';
import '../previews/test_runner.dart';
import '../embedder/build_directory.dart';
import 'cancel.dart';
import 'runner.dart';

/// The previews of a checkout, as the runner asks about them.
///
/// One of these serves **both** sides: it is handed a checkout per call, so
/// base and head go through the same scanner, the same generated harness and
/// the same canvases. Two objects with two configs is how the two sides start
/// disagreeing about which directories to scan and which annotations count,
/// and then the comparison reports entries that only ever existed in the
/// asking.
///
/// Renders under `flutter_tester`, the audit's lane, not the embedder.
/// The embedder renders in real time, which is right for a panel somebody is
/// looking at and wrong here twice over: a catalog-wide render pays real
/// seconds per animating entry where fake clock costs microseconds, and a
/// real-time capture lands wherever the clock fell — the old lane had to
/// carry "still animating when it was captured, so this picture is not
/// reproducible" as a complaint. Under FakeAsync the same entry is
/// photographed at the same fake instant every run, which is the property a
/// pixel diff actually needs.
///
/// What the lane cannot do is talk to a network: `flutter_test` answers every
/// HTTP request with 400, so a preview of a remote image renders its error
/// state on both sides. The failure rides along as a complaint — identical on
/// both sides it cancels, like any complaint — but a real change to such a
/// preview's remote half is invisible in this lane.
class PreviewsSide implements ComparisonSide {
  PreviewsSide({
    required this.flutterSdkRoot,
    required this.packagePath,
    required this.root,
    required this.previewAnnotations,
    required this.canvases,
    this.projectClock,
  });

  final String flutterSdkRoot;

  /// The package inside each checkout, relative — `.` for a single-package
  /// project, `fixtures/probe_app` in a workspace.
  @override
  final String packagePath;

  /// The scan root inside the package, and the preview annotations, both taken
  /// from the **head** checkout's config.
  ///
  /// Deliberately not re-read per side. A comparison asks what *this branch*
  /// did, and if the branch moved its previews directory then reading each
  /// side's own config would compare the old directory against the new one and
  /// report every entry as removed and re-added. Asking one question of both
  /// sides is what makes the answer about the code.
  final String root;
  final List<String> previewAnnotations;

  /// How subtrees are framed, from the head config for the same reason as
  /// [root]: a branch that moved a canvas must not see every entry under it
  /// re-photographed on both sides against different stages.
  final List<PreviewCanvas> canvases;

  /// What `clock.now()` reads inside every entry of both renders, or null for
  /// flutterware's own `pinnedClockOrigin`.
  ///
  /// Carried for the reason the scenario half carries it: an entry that reads
  /// the clock is a picture of *when it was taken* unless both sides are told
  /// one instant, and a comparison whose base was cached yesterday then reports
  /// the date as the branch's doing. From the **head** checkout, like [root],
  /// so a branch that changed `fw.clock(...)` is asking one question of both
  /// sides rather than comparing two dates.
  final DateTime? projectClock;

  /// An entry id is `<path>#<symbol>` where the path is relative to the
  /// *package*; a checkout can hold several packages, so the package's own
  /// place in the checkout goes back on the front.
  @override
  String fileOf(String entryId) {
    var hash = entryId.indexOf('#');
    var file = hash < 0 ? entryId : entryId.substring(0, hash);
    return p.normalize(p.join(packagePath, file));
  }

  @override
  Future<List<String>> entries(String checkout) async => [
    for (var entry in _listed(checkout).entries) entry.id,
  ];

  @override
  Future<Map<String, String>> names(String checkout) async => {
    for (var entry in _listed(checkout).entries) entry.id: entry.name,
  };

  /// One scan per checkout for the listing and the names, which are asked
  /// back to back. [render] scans afresh: it is where a checkout that moved
  /// under the comparison has to be noticed.
  ScanResult _listed(String checkout) =>
      _listings[checkout] ??= _scan(checkout);
  final _listings = <String, ScanResult>{};

  ScanResult _scan(String checkout) => CatalogScanner(
    projectRoot: _packageRootIn(checkout),
    roots: [root],
    previewAnnotations: previewAnnotations,
  ).scan();

  @override
  Future<Map<String, String>> render({
    required String checkout,
    required List<String> entryIds,
    required Future<void> Function(RenderedEntry frame) onFrame,
  }) async {
    var packageRoot = _packageRootIn(checkout);
    var byId = {for (var entry in _scan(checkout).entries) entry.id: entry};
    var failed = <String, String>{};
    // The runner only asks for ids both sides declare, so a miss here means
    // the checkout moved under the comparison — say so rather than render a
    // neighbour.
    var wanted = <CatalogEntry>[];
    for (var id in entryIds) {
      if (byId[id] case var entry?) {
        wanted.add(entry);
      } else {
        failed[id] = 'no longer declared in this checkout';
      }
    }
    if (wanted.isEmpty) return failed;

    // The generated harness imports exactly the entries being rendered, so
    // the compile pays for this render's closure rather than the whole
    // catalog's. In a claimed directory of its own, and that subset is one
    // reason why: written into the warm audit runner's directory it would
    // renumber and prune that harness's wrappers — the head checkout *is* the
    // panel's worktree — and the base checkout is shared by every comparison
    // on the machine.
    var buildDirectory = claimBuildDirectory(
      packageRoot,
      root: comparisonBuildRoot,
    );
    var runner = PreviewTestRunner(
      packageRoot: packageRoot,
      flutterSdkRoot: flutterSdkRoot,
      read: () => (entries: wanted, canvases: canvases),
      buildDirectory: buildDirectory,
    );
    var outDir = Directory.systemTemp.createTempSync('fw_comparison_previews');
    try {
      await runner.capture(
        entryIds: [for (var entry in wanted) entry.id],
        outDir: outDir.path,
        clock: projectClock,
        onRow: (row) async {
          if (row.compileError case var error?) {
            failed[row.id] = error;
            return;
          }
          // An entry that compiled and then threw *while building* is a
          // picture of Flutter's error screen. Two of those compared say
          // nothing, and one of them compared against a working screen says
          // "97% changed" when the finding is "this throws now".
          //
          // **But only a build error replaces the picture.** A layout
          // overflow is a complaint about the frame, not the absence of one —
          // `InspectError.library` is there to tell those apart without
          // reading the message, and says so.
          var errors = [
            for (var error in row.errors) InspectError.fromJson(error),
          ];
          if (errors.where(_replacesTheFrame).firstOrNull case var fatal?) {
            failed[row.id] = fatal.exception;
            return;
          }
          var image = row.image;
          if (image == null) {
            failed[row.id] = row.failure ?? 'did not render';
            return;
          }
          var tree = _tree(row.tree);
          await onFrame(
            RenderedEntry(
              entryId: row.id,
              rgba: File(image).readAsBytesSync(),
              width: row.width,
              height: row.height,
              tree: tree?.root,
              treeFormat: tree?.format,
              // The framework's word first: a failure with errors beside it
              // is usually the test runner restating one of them.
              complaint: errors.firstOrNull?.exception ?? row.failure,
            ),
          );
        },
      );
    } on ComparisonCancelled {
      // A stop is not a compile failure. The runner's cancel check throws
      // from inside `onFrame`, which unwinds through the capture loop — the
      // finally below reaps the tester — and must reach the controller as
      // itself.
      rethrow;
    } on Object catch (error) {
      // **A side that cannot start is one finding.** The harness refuses as a
      // whole when the generated entrypoint does not compile past blame — one
      // way that happens is version skew, because the base is rendered with
      // the *head's* tooling (see the design doc's §11a). Nothing about that
      // is per entry, and reporting it per entry produced twenty-four rows of
      // one sentence.
      // **Whole, not the first line.** A refusal you cannot act on is barely
      // better than the twenty-four rows it replaced, and the compiler puts
      // its diagnostics on the lines after the summary.
      throw SideDidNotCompile('$error');
    } finally {
      // A `flutter_tester` and its compiler are child processes; nothing else
      // reaps them.
      await runner.dispose();
      releaseBuildDirectory(
        packageRoot,
        buildDirectory,
        root: comparisonBuildRoot,
      );
      try {
        outDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Captures the cache already copied; losing the sweep is not worth a
        // second failure on top of whatever ended the render.
      }
    }
    return failed;
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

  /// Whether this error replaced what would have been on screen.
  ///
  /// A build that throws is caught by the widgets library and the subtree
  /// becomes an `ErrorWidget`: there is no picture left of the thing you asked
  /// for, and comparing one is comparing error screens. A layout overflow is
  /// reported by the rendering library and **paints anyway**, with a stripe
  /// over the part that did not fit — a picture, plus a complaint, and the
  /// complaint is not a reason to refuse to compare it.
  static bool _replacesTheFrame(InspectError error) =>
      error.library == 'widgets library';

  String _packageRootIn(String checkout) =>
      p.normalize(p.join(checkout, packagePath));
}
