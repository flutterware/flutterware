import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/comparison_report.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../utils/base_href.dart';
import '../utils/viewer_bundle.dart';
import 'shot_cache.dart';
import 'shot_png.dart';

/// Writes a comparison out as a browsable page.
///
/// The same two halves as `ScenarioWebExporter`, and only the first is a
/// compile. The **viewer** is the one shared [ViewerBundle] — data-free, it
/// fetches its `index.json` at run time — so it is built from the app package
/// once and reused for every export after that, scenario exports included.
/// The **index** is the comparison the caller just ran, with every frame it
/// names encoded to PNG beside it and every reference rewritten to point at
/// the copy.
///
/// Encoding is the one cost the cache's raw-frames rule pays back here: a
/// hosted page downloading 2.5MB of raw rgba per frame is the worse deal, and
/// an export happens once where a capture happens per entry per run.
///
/// The page must be **served**, not opened off the filesystem: it fetches
/// `index.json` and every frame relative to itself, and a browser refuses
/// those on a `file://` page. Where it is served from is [defaultBaseHref]'s
/// business: a page under a CI prefix is the common case, not the exception.
class ComparisonWebExporter {
  ComparisonWebExporter({
    required String flutterExecutable,
    required String appToolRoot,
  }) : _bundle = ViewerBundle(
         flutterExecutable: flutterExecutable,
         appToolRoot: appToolRoot,
       );

  final ViewerBundle _bundle;

  /// Where the viewer bundle is compiled to. See [ViewerBundle.viewerDir].
  String get viewerDir => _bundle.viewerDir;

  /// Preview frames inside a page, relative to it.
  static const shotsDir = 'shots';

  /// Scenario step frames inside a page, relative to it.
  static const framesDir = 'frames';

  /// Stands in for the `flutter build web` that produces the viewer, so a test
  /// can exercise everything after it — which is where all the logic is —
  /// without a toolchain and a minute of compiling.
  @visibleForTesting
  Future<int> Function(List<String> arguments)? get debugCompile =>
      _bundle.debugCompile;

  @visibleForTesting
  set debugCompile(Future<int> Function(List<String> arguments)? compile) =>
      _bundle.debugCompile = compile;

  /// Writes the page: the viewer bundle, the rewritten `index.json`, and a
  /// PNG per frame the index names.
  ///
  /// [index] is the artifact's JSON — `ComparisonArtifact.toJson()`, which is
  /// fresh maps on every call, so rewriting it in place mutates nobody else's
  /// state. [against] is what the page's header says the comparison is
  /// against; the artifact records only the sha.
  Future<ComparisonWebExport> export({
    required Map<String, Object?> index,
    required ShotCache cache,
    required String against,
    required String output,
    String baseHref = defaultBaseHref,
    bool offline = false,
    ExportedFrames frames = ExportedFrames.all,
    void Function(String line)? onOutput,
  }) async {
    var stopwatch = Stopwatch()..start();
    await _bundle.build(offline: offline, onOutput: onOutput);
    if (_bundle.cancelled) throw StateError('The export was cancelled.');

    var outputDir = Directory(output);
    // Cleared rather than merged into: an entry renamed since the last export
    // would otherwise keep its frames in the page's tree, where nothing links
    // to them and nothing ever removes them.
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
    outputDir.createSync(recursive: true);

    onOutput?.call('[export] copying the viewer');
    _bundle.copyTo(output, offline: offline);
    setBaseHrefIn(p.join(output, 'index.html'), baseHref);

    onOutput?.call('[export] encoding the frames');
    var encoding = Stopwatch()..start();
    index['against'] = against;
    // Said before the frames are collected, because the collection reads it:
    // a reader has to be able to tell a row whose picture was left out from a
    // row that never had one.
    if (frames != ExportedFrames.all) index['exported'] = frames.name;
    var encoded = _collect(index, cache: cache, output: output, only: frames);
    // Every reference has just been rewritten to a PNG beside this file, so
    // the dialect the artifact declared is no longer true of the copy being
    // written. Stamped after `_collect` rather than before, because a reader
    // is entitled to take this as a promise the frames are there.
    index['frames'] = ComparisonFrames.relative.name;

    File(p.join(output, 'index.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(index));
    // Timed to the end of the index, which is the other thing this step
    // writes: a run with nothing to encode still has a whole verdict to put
    // beside the page.
    onOutput?.call(
      '[export] encoded $encoded frames and wrote the index in '
      '${encoding.elapsedMilliseconds}ms',
    );

    return ComparisonWebExport(
      output: output,
      indexHtml: p.join(output, 'index.html'),
      frames: encoded,
      duration: stopwatch.elapsed,
    );
  }

  /// Encodes every frame the index names into the page and rewrites the
  /// references in place: a preview row's cache keys become `shots/<key>.png`,
  /// a scenario step's absolute frame paths become `frames/s<i>/<name>.png`.
  ///
  /// The rewrite is done on the JSON rather than on the model for the same
  /// reason the scenario export's is: this is the whole of it, and a page
  /// whose names point at the copies beside it instead of a cache the reader
  /// does not have.
  int _collect(
    Map<String, Object?> index, {
    required ShotCache cache,
    required String output,
    ExportedFrames only = ExportedFrames.all,
  }) {
    var encoded = 0;

    /// Whether a row in [state] gets its pictures written into the page.
    bool wanted(Object? state) =>
        only == ExportedFrames.all ||
        isComparedFinding(
          ComparedState.values.asNameMap()['$state'] ?? ComparedState.skipped,
        );

    // The same key twice — the unchanged side of two rows, say — is one file.
    var byKey = <String, String?>{};
    String? shot(String key) => byKey.putIfAbsent(key, () {
      var bytes = cache.read(key);
      var record = cache.meta(key);
      if (bytes == null || record == null) return null;
      var name = p.url.join(shotsDir, '$key.png');
      var file = File(p.join(output, shotsDir, '$key.png'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(
        encodeRgbaPng(bytes, width: record.width, height: record.height),
      );
      encoded++;
      return name;
    });

    var previews = index['previews'] as Map<String, Object?>? ?? const {};
    for (var item in previews['items'] as List? ?? const []) {
      var shots = (item as Map)['shots'] as Map?;
      if (shots == null) continue;
      // The keys stay in the file even when the pictures do not: they are what
      // a run *on this machine* would open them with, and `exported` above is
      // what tells a page reading this copy that they are not beside it.
      if (!wanted(item['state'])) continue;
      for (var side in const ['base', 'head']) {
        var key = shots[side];
        if (key is! String) continue;
        // A key whose frame is gone — evicted mid-export — stays a key: the
        // page 404s on it and the stage says nothing rendered, which is
        // nearer the truth than dropping the reference altogether.
        var name = shot(key);
        if (name != null) shots[side] = name;
      }
    }

    var byPath = <String, String?>{};
    var scenarios = index['scenarios'] as Map<String, Object?>?;
    var scenarioIndex = 0;
    for (var scenario in scenarios?['items'] as List? ?? const []) {
      var into = 's${scenarioIndex++}';
      var taken = <String>{};
      // Whole flows, not whole *steps*. A scenario is a picture per step laid
      // out as one graph, and dropping the unchanged steps out of a flow that
      // is a finding would leave the reader panning across holes — so the
      // question is asked of the scenario and answered for all of it.
      if (!wanted((scenario as Map)['state'])) continue;
      for (var step in scenario['steps'] as List? ?? const []) {
        var frames = (step as Map)['frames'] as Map?;
        if (frames == null) continue;
        for (var side in const ['base', 'head']) {
          var frame = frames[side];
          if (frame is! Map) continue;
          var ref = FrameRef.fromJson(frame.cast<String, Object?>());
          if (ref == null || !ref.isDrawable) continue;
          var name = byPath.putIfAbsent(ref.path, () {
            var source = File(ref.path);
            if (!source.existsSync()) return null;
            var base = p.basenameWithoutExtension(ref.path);
            var claimed = '$base.png';
            for (var n = 2; !taken.add(claimed); n++) {
              claimed = '$base-$n.png';
            }
            var file = File(p.join(output, framesDir, into, claimed));
            file.parent.createSync(recursive: true);
            file.writeAsBytesSync(
              encodeRgbaPng(
                source.readAsBytesSync(),
                width: ref.width,
                height: ref.height,
              ),
            );
            encoded++;
            return p.url.join(framesDir, into, claimed);
          });
          if (name != null) frame['path'] = name;
        }
      }
    }

    return encoded;
  }

  /// Ends the export, if one is running.
  Future<void> cancel() => _bundle.cancel();
}

/// What a finished export produced.
class ComparisonWebExport {
  ComparisonWebExport({
    required this.output,
    required this.indexHtml,
    required this.frames,
    required this.duration,
  });

  /// The directory to serve. Absolute.
  final String output;

  final String indexHtml;

  /// PNGs encoded in beside the page.
  final int frames;

  final Duration duration;
}
