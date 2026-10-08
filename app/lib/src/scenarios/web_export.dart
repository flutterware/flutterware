import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../session/job.dart';
import '../utils/base_href.dart';
import '../utils/viewer_bundle.dart';
import 'web_report.dart';

/// Writes a run out as a browsable page.
///
/// Two halves, and only the first is a compile. The **viewer** is the one
/// shared [ViewerBundle] — data-free, it fetches its report at run time — so
/// it is built from the app package once and reused for every export after
/// that, comparison exports included. The **report** is the run the caller
/// just did, with every artifact copied in beside it and every path rewritten
/// to point at the copy.
///
/// So an export is: build the viewer if the build system says it is stale, copy
/// a few hundred kilobytes, and write one JSON file. The compile is the
/// exception rather than the cost.
///
/// The page must be **served**, not opened off the filesystem: it fetches
/// `report.json` and every artifact relative to itself, and a browser refuses
/// those on a `file://` page. `CatalogWebServer` is what the GUI and
/// `--serve` put in front of it.
class ScenarioWebExporter {
  ScenarioWebExporter({
    required String flutterExecutable,
    required String appToolRoot,
    required this.worktreeRoot,
  }) : _bundle = ViewerBundle(
         flutterExecutable: flutterExecutable,
         appToolRoot: appToolRoot,
       );

  final ViewerBundle _bundle;

  /// What the run's artifact paths are relative to.
  final String worktreeRoot;

  /// Where the page goes by default. Package-relative, and spelled with
  /// `/` because it is also what the dialog puts in a text field and what the
  /// action's help says.
  static const defaultOutput = 'build/scenarios/web';

  static String defaultOutputIn(String packageRoot) =>
      p.join(packageRoot, 'build', 'scenarios', 'web');

  /// Where the viewer bundle is compiled to. See [ViewerBundle.viewerDir].
  String get viewerDir => _bundle.viewerDir;

  /// The artifact directory inside a page, relative to it.
  static const artifactsDir = 'artifacts';

  /// Stands in for the `flutter build web` that produces the viewer, so a test
  /// can exercise everything after it — which is where all the logic is —
  /// without a toolchain and a minute of compiling.
  @visibleForTesting
  Future<int> Function(List<String> arguments)? get debugCompile =>
      _bundle.debugCompile;

  @visibleForTesting
  set debugCompile(Future<int> Function(List<String> arguments)? compile) =>
      _bundle.debugCompile = compile;

  Future<ScenarioWebExport> export({
    required ScenarioWebReport report,
    required String output,
    String baseHref = defaultBaseHref,
    bool offline = false,
    void Function(String line)? onOutput,
  }) async {
    var stopwatch = Stopwatch()..start();
    await _bundle.build(offline: offline, onOutput: onOutput);
    if (_bundle.cancelled) throw ActionRefusal('The export was cancelled.');

    var outputDir = Directory(output);
    // Cleared rather than merged into: a scenario deleted since the last export
    // would otherwise keep its screenshots in the page's artifact tree, where
    // nothing links to them and nothing ever removes them.
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
    outputDir.createSync(recursive: true);

    onOutput?.call('[export] copying the viewer');
    _bundle.copyTo(output, offline: offline);
    setBaseHrefIn(p.join(output, 'index.html'), baseHref);

    onOutput?.call('[export] collecting the artifacts');
    // Through the encoder and back rather than `toJson()` alone: the model's
    // literals hand nested objects to `jsonEncode`'s `toEncodable`, and the
    // path rewriting below walks plain maps.
    var json = (jsonDecode(jsonEncode(report)) as Map).cast<String, Object?>();
    var copied = _collect(
      (json['run']! as Map).cast<String, Object?>(),
      output,
    );

    File(p.join(output, scenarioWebReportFile))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

    return ScenarioWebExport(
      output: output,
      indexHtml: p.join(output, 'index.html'),
      scenarios: report.outcomes.length,
      steps: report.outcomes.fold(0, (n, entry) => n + entry.$2.steps.length),
      artifacts: copied,
      duration: stopwatch.elapsed,
    );
  }

  /// Copies every artifact the run names into the page and rewrites its paths
  /// in place. [run] is the serialized [ScenarioRunResult] — the envelope's
  /// `run`, not the envelope.
  ///
  /// The rewrite is done on the JSON rather than on the model because that is
  /// the whole of it: five path fields per step, and a page whose paths point
  /// at the copies beside it instead of at a worktree the reader does not have.
  ///
  /// Laid out one directory per scenario, keeping each file's own name — a
  /// human opening `artifacts/` should recognise what they are looking at, and
  /// the harness already names steps after the shot that took them.
  int _collect(Map<String, Object?> run, String output) {
    var copied = 0;
    var scenarioIndex = 0;
    for (var package in (run['packages'] as List? ?? const [])) {
      for (var outcome
          in ((package as Map)['scenarios'] as List? ?? const [])) {
        var into = 's${scenarioIndex++}';
        var taken = <String>{};

        /// A page-relative name under this scenario's directory that no
        /// sibling has taken.
        String claim(String source) {
          var name = p.basename(source);
          for (var n = 2; !taken.add(name); n++) {
            name =
                '${p.basenameWithoutExtension(source)}-$n'
                '${p.extension(source)}';
          }
          return name;
        }

        for (var step in ((outcome as Map)['steps'] as List? ?? const [])) {
          // `file` is a document beat's payload — the same treatment its
          // siblings get, because the page has to be able to open it too.
          for (var key in const [
            'image',
            'tree',
            'semantics',
            'events',
            'file',
          ]) {
            var source = (step as Map)[key];
            if (source is! String) continue;
            var from = File(p.join(worktreeRoot, source));
            if (!from.existsSync()) {
              // The report keeps naming it, and the page says the file is
              // gone — which is the truth, and better than a path that
              // resolves to nothing with no explanation.
              continue;
            }
            var name = claim(source);
            var destination = p.join(output, artifactsDir, into, name);
            Directory(p.dirname(destination)).createSync(recursive: true);
            from.copySync(destination);
            step[key] = p.url.join(artifactsDir, into, name);
            copied++;
          }

          // What the flow produced, on the same terms as the four above: a
          // page a reviewer downloads is exactly where a generated document
          // is worth having, and it is the one artifact that is the point of
          // the step rather than a description of it.
          for (var attachment
              in ((step as Map)['attachments'] as List? ?? const [])) {
            var source = (attachment as Map)['file'];
            if (source is! String) continue;
            var from = File(p.join(worktreeRoot, source));
            if (!from.existsSync()) continue;
            var name = claim(source);
            var destination = p.join(output, artifactsDir, into, name);
            Directory(p.dirname(destination)).createSync(recursive: true);
            from.copySync(destination);
            attachment['file'] = p.url.join(artifactsDir, into, name);
            copied++;
          }

          // The recorded transition is **not** exported (owner, 2026-08-11:
          // "this would be too big"). A recording is by far the bulkiest thing
          // a run produces — every frame of every transition, against five
          // small files for the step itself — and a page is a thing people
          // download.
          //
          // Stripped rather than merely not copied: a run that recorded is
          // reachable (the panel records by default), and a step that kept its
          // frame fields with no frames beside them would put a play button on
          // the page that fetches nothing and never moves. The viewer asks
          // `hasMotion`, and this is the answer.
          for (var key in const [
            'frames',
            'frameCount',
            'frameWidth',
            'frameHeight',
            'frameIntervalMs',
            'framesDropped',
          ]) {
            step.remove(key);
          }
        }
      }
    }
    return copied;
  }

  /// Ends the export, if one is running.
  Future<void> cancel() => _bundle.cancel();
}

/// What a finished export produced.
class ScenarioWebExport {
  ScenarioWebExport({
    required this.output,
    required this.indexHtml,
    required this.scenarios,
    required this.steps,
    required this.artifacts,
    required this.duration,
  });

  /// The directory to serve. Absolute.
  final String output;

  final String indexHtml;
  final int scenarios;
  final int steps;

  /// Files copied in beside the page — screenshots, trees, semantics, events.
  final int artifacts;

  final Duration duration;
}
