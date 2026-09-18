/// What a comparison wrote down, typed — the reader for `index.json`.
///
/// Every `fw compare` writes its whole verdict to `index.json`: every preview
/// entry and every scenario step, each with what the four channels found —
/// pixels, widget tree, visible texts, app events — and where its two frames
/// are. This library reads that back so a project's `tool/` script — a
/// pull-request gate, a screenshot uploader, a custom comment — is a few lines
/// over typed classes rather than a map walk written once per project:
///
/// * [ComparisonReport.read] takes an exported page's directory and hands back
///   the [ComparisonIndex] with a way to open the frames it names.
/// * [ComparisonIndex.fromJson] takes the file, or the object `fw compare
///   --json` prints, when only the verdict is wanted.
/// * [ComparisonIndex.findings] is the verdict in the order a reader wants it:
///   worst first, both halves merged, the rows that are neither `same` nor
///   `skipped`. [ComparisonIndex.ok] is the gate.
/// * [ComparisonIndex.verdictGap] says when there is no verdict to gate on —
///   a harness that would not build, a half of nothing but both-sides
///   failures — which `ok` alone cannot tell apart from real regressions.
///   `fw compare` exits 1 on exactly this sentence.
///
/// ```dart
/// var report = await ComparisonReport.read('build/comparison/report/web');
/// if (report.index.ok) return;
/// for (var finding in report.index.findings) {
///   print('${finding.state.name} ${finding.half.name} ${finding.id}');
///   if (finding.preview?.shots case var shots?) {
///     if (report.frame(shots.head) case var png?) {
///       await service.upload(png, finding.id);
///     }
///   }
/// }
/// exitCode = 1;
/// ```
///
/// This is published API. A field renamed here breaks somebody's script,
/// which is why [comparisonReportVersion] exists and why
/// [ComparisonIndex.fromJson] refuses a major it does not know rather than
/// handing back a half-decoded object. Added fields do not bump the version —
/// an older reader ignoring a new key is the behaviour that makes adding one
/// cheap.
///
/// **One vocabulary, several careers**, exactly as `scenarios_report.dart`
/// argues: `fw compare` builds these classes, writes them, the studio's own
/// panel renders them, the exported page parses them in a browser, and a
/// consumer's script reads them here. What is *not* here is what never reaches
/// the file — the runner's live frames and the step aligner — because a shape
/// that cannot be written cannot be read, and publishing it would freeze a
/// runner internal.
///
/// Plain Dart on purpose — nothing in the model may import `package:flutter`,
/// and nothing may import `dart:io`: a consumer's script runs under a bare
/// `dart run`, and the exported comparison page parses this very model in a
/// browser. The disk-facing reader lives in `report_io.dart`, and
/// `test/comparison/purity_test.dart` fails the build if either rule is
/// broken.
library;

export 'src/comparison/channels.dart'
    show
        ChannelDelta,
        comparedIdIn,
        ComparedItem,
        ComparedState,
        EventChannel,
        EventDelta,
        EventDeltaKind,
        FoldedDelta,
        foldChannelDeltas,
        maxEventDeltas,
        PixelChannel,
        TextChannel,
        TreeChannel;
export 'src/comparison/frame_ref.dart' show FrameRef;
export 'src/comparison/pixel_diff.dart' show DiffRect, PixelDiff;
export 'src/comparison/report.dart';
export 'src/comparison/report_io.dart';
export 'src/comparison/scenario_comparison.dart'
    show BranchDelta, ScenarioComparison, StepIds;
export 'src/comparison/tree_diff.dart' show TreeDelta, TreeDeltaKind, TreeDiff;
