/// The comparison strip over a recording: a comparison already run, kept.
///
/// A comparison builds the base checkout and renders both sides, which
/// nothing but a real checkout can do. What it leaves behind is one index —
/// the published report, every finding with its verdict and its pictures —
/// and that is what the recorder kept, as `fw compare --export` writes it.
/// Here the strip's two halves restore from it the way they restore a kept
/// run on a real checkout, and the pictures come from the recording instead
/// of the machine's shot cache. Pressing Compare again refuses, and says why.
library;

import 'dart:convert';

import 'package:flutterware/comparison_report.dart';
// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';

import '../comparison/artifact.dart';
import '../comparison/cancel.dart';
import '../comparison/compare_command.dart' show CompareException;
import '../comparison/comparison_controller.dart';
import '../comparison/last_run.dart';
import '../comparison/runner.dart' show ComparisonResult;
import '../comparison/shot_cache.dart';
import '../comparison/shot_store.dart';
import 'recording.dart';

class RecordedComparisonEnvironment implements ComparisonEnvironment {
  RecordedComparisonEnvironment._(this.recording, this.index);

  /// The recorded comparison, or null when the recording has none.
  static Future<RecordedComparisonEnvironment?> open(
    Recording recording,
  ) async {
    // Through `Future.value`, so a synchronous end still resumes this
    // function on a microtask — see `recordedIconScanner`.
    var text = await Future.value(
      recording.readString(recordedComparisonIndexPath),
    );
    if (text == null) return null;
    var index = ComparisonIndex.fromJson(
      (jsonDecode(text) as Map).cast<String, Object?>(),
    );
    return RecordedComparisonEnvironment._(recording, index);
  }

  final Recording recording;
  final ComparisonIndex index;

  @override
  String get headRoot => recordedProjectRoot;

  @override
  String get baseLabel => index.against;

  @override
  String get baseSha => index.base;

  @override
  String? get headCommit => index.headCommit;

  /// Nothing is checked out anywhere: the offer to compare again is priced
  /// as a full run, and refused when taken.
  @override
  bool get baseCheckoutReady => false;

  @override
  Future<String> prepareBase({void Function(String phase)? onProgress}) async {
    throw CompareException(
      'This is a recording: the base was checked out and compared on the '
      'machine that recorded it, and nothing here can build one.',
    );
  }

  @override
  bool get hasPreviews => true;

  @override
  bool get hasScenarios => index.scenariosHalf != null;

  /// Never read — every picture comes from [shotStore] — but the interface
  /// names a cache, and a path that is not there is the honest one.
  @override
  ShotCache get shots => ShotCache('$recordedProjectRoot/shots');

  @override
  ShotStore get shotStore => RecordedShotStore(recording);

  @override
  Future<LastComparison?> lastRun(ComparisonHalfKind kind) async =>
      switch (kind) {
        ComparisonHalfKind.previews => LastComparison(
          at: index.at ?? pinnedClockOrigin,
          baseSha: index.base,
          against: index.against,
          headCommit: index.headCommit,
          elapsed: Duration(milliseconds: index.previewsHalf.ms),
          items: index.previewItems,
          rendered: index.previewsHalf.worked,
        ),
        ComparisonHalfKind.scenarios => switch (index.scenariosHalf) {
          null => null,
          var half => LastComparison(
            at: index.at ?? pinnedClockOrigin,
            baseSha: index.base,
            against: index.against,
            headCommit: index.headCommit,
            elapsed: Duration(milliseconds: half.ms),
            scenarios: index.scenarios,
            ran: half.worked,
            note: half.note,
          ),
        },
      };

  @override
  Future<LastComparison?> previousRun(ComparisonHalfKind kind) async => null;

  @override
  Future<void> saveLastRun(
    ComparisonHalfKind kind,
    LastComparison last,
  ) async {}

  @override
  Future<ComparisonResult> runPreviews(
    String baseRoot, {
    required void Function(ComparedItem row) onRow,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  }) => throw StateError('A recording compares nothing.');

  @override
  Future<ScenarioResults> runScenarios(
    String baseRoot, {
    required void Function(ScenarioComparison scenario) onScenario,
    void Function(int total, List<String> toAnswer)? onPlan,
    void Function(String phase)? onProgress,
    CancelToken? cancel,
  }) => throw StateError('A recording compares nothing.');
}

/// The pictures, from the export's PNGs: a shot by the path the export
/// rewrote its key into, a step's frame by the path its reference carries.
///
/// A key the export did not rewrite — an added entry's base side, a removed
/// one's head — names a frame this recording never had, and is not asked
/// for: the row says there is no picture, which is the truth, and nothing
/// fetches a file that is not there.
class RecordedShotStore implements ShotStore {
  const RecordedShotStore(this.recording);

  final Recording recording;

  @override
  Future<Shot?> byKey(String key, {int? width}) async {
    if (!key.endsWith('.png')) return null;
    var bytes = await Future.value(
      recording.readBytes(recordedComparisonFilePath(key)),
    );
    return bytes == null ? null : decodeEncodedShot(bytes, targetWidth: width);
  }

  @override
  Future<Shot?> byRef(FrameRef ref, {int? width}) async {
    if (!ref.path.endsWith('.png')) return null;
    var bytes = await Future.value(
      recording.readBytes(recordedComparisonFilePath(ref.path)),
    );
    return bytes == null ? null : decodeEncodedShot(bytes, targetWidth: width);
  }
}
