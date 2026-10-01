import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../session/job.dart';
import '../utils/base_href.dart';
import 'catalog_entry.dart';
import 'preview_setup.dart';
import 'web_app_generator.dart';

/// Builds the catalog as a browsable web page.
///
/// Two steps, and the second is just `flutter build web`: [WebAppGenerator]
/// writes an app that browses every entry, and the tool compiles it. Nothing
/// here talks to the compiler daemon or the embedder — a page is not a captured
/// frame, it is the previews themselves running in a browser.
///
/// Built from the target package rather than from a generated package of its own.
/// The package's `web/index.html`, its assets and its fonts are all declared
/// there, and a build run from anywhere else would have to reproduce them —
/// which is how a catalog page ends up missing exactly the images the previews are
/// about.
class WebCatalogBuilder {
  WebCatalogBuilder({
    required this.flutterExecutable,
    required this.packageRoot,
    required this.title,
    this.clock,
    this.setup,
  });

  final String flutterExecutable;

  /// The package whose demos these are. `flutter build web` runs here.
  final String packageRoot;

  final String title;

  /// What `clock.now()` reads on the built page, or null for
  /// `pinnedClockOrigin` — the project's own `fw.clock(...)`.
  final DateTime? clock;

  /// The package's declared setup, run by the page before it builds. See
  /// `PreviewsPackage.setup`.
  final PreviewSetup? setup;

  /// Where the generated app is written. Under `build/`, because it is build
  /// output: regenerated every time and never worth committing.
  String get sourceDir => p.join(packageRoot, 'build', 'catalog', 'web_src');

  /// Where the page goes by default. Package-relative, and spelled with
  /// `/` because it is also what the dialog puts in a text field and what the
  /// action's help says.
  static const defaultOutput = 'build/catalog/web';

  static String defaultOutputIn(String packageRoot) =>
      p.join(packageRoot, 'build', 'catalog', 'web');

  /// Generates the app and compiles it.
  ///
  /// [onOutput] receives the tool's own lines as they arrive — a web build is
  /// tens of seconds and a caller with nothing to show for that is a caller
  /// nobody believes is working.
  Future<WebCatalogBuild> build({
    required List<CatalogEntry> entries,
    String? output,
    String baseHref = defaultBaseHref,
    void Function(String line)? onOutput,
  }) async {
    if (entries.isEmpty) {
      throw ActionRefusal(
        'There are no catalog entries in $packageRoot to build a page from.',
      );
    }
    _requireWebSupport();

    var target = WebAppGenerator(
      outputDir: sourceDir,
      projectRoot: packageRoot,
      title: title,
      clock: clock,
      setup: setup,
    ).generate(entries);

    var outputDir = output == null
        ? defaultOutputIn(packageRoot)
        : (p.isAbsolute(output) ? output : p.join(packageRoot, output));

    var stopwatch = Stopwatch()..start();
    var exitCode = await _run([
      'build',
      'web',
      '--target',
      p.relative(target, from: packageRoot),
      '--output',
      outputDir,
    ], onOutput);
    stopwatch.stop();

    if (_cancelled) {
      // Said plainly rather than as a non-zero exit code: a build that was
      // stopped on purpose is not a build that broke.
      throw ActionRefusal('The web build was cancelled.');
    }
    if (exitCode != 0) {
      throw ActionRefusal(
        'flutter build web failed (exit $exitCode). The generated sources are '
        'in $sourceDir — the error above points into them.',
      );
    }

    // After the build rather than through `--base-href`, for the reason
    // [setBaseHrefIn] gives: that flag cannot say `./`, and `./` is what a
    // page published under a per-pull-request prefix needs.
    var indexHtml = p.join(outputDir, 'index.html');
    setBaseHrefIn(indexHtml, baseHref);

    return WebCatalogBuild(
      output: outputDir,
      indexHtml: indexHtml,
      entryCount: entries.length,
      duration: stopwatch.elapsed,
    );
  }

  /// Refuses early, and with the command that fixes it.
  ///
  /// `flutter build web` needs the package to have a `web/` directory; without
  /// one the tool's own message is about a missing target rather than about
  /// web not being enabled. Creating it here is not this command's business —
  /// it writes four files into the user's project, and a build command that
  /// quietly does that is one you cannot run to find out whether it would.
  void _requireWebSupport() {
    if (Directory(p.join(packageRoot, 'web')).existsSync()) return;
    throw ActionRefusal(
      'This package has no web/ directory, so Flutter cannot build it for the '
      'web. Enable it once with:\n'
      '  cd $packageRoot && flutter create --platforms=web .',
    );
  }

  /// The compile in flight, so it can be cancelled. Null when none is.
  Process? _process;
  var _cancelled = false;

  /// Ends the build, if one is running.
  ///
  /// A `flutter build web` is tens of seconds, and a child started with
  /// `Process.start` is **not** killed when the Dart parent exits on macOS. Left
  /// alone it keeps writing into the user's project after the window is gone —
  /// and the next build calls [WebAppGenerator.generate], which deletes
  /// `web_src` recursively, so the orphan's sources vanish underneath it and it
  /// fails pointing at generated files that no longer exist.
  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
    // SIGTERM only reaches the tool itself; its own children are its business.
    // The tool handles it, which is what `flutter build` does on a ^C.
    _process = null;
  }

  Future<int> _run(
    List<String> arguments,
    void Function(String)? onOutput,
  ) async {
    var process = _process = await Process.start(
      flutterExecutable,
      arguments,
      workingDirectory: packageRoot,
    );
    // Cancelled between the decision to start and the start itself.
    if (_cancelled) process.kill();
    // Both streams, interleaved: the tool writes progress to stdout and its
    // compile errors to stderr, and a caller shown only one of them either
    // watches a build say nothing or reads a failure with no context.
    var lines = <Future<void>>[
      for (var stream in [process.stdout, process.stderr])
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) => onOutput?.call(line)),
    ];
    var exitCode = await process.exitCode;
    await Future.wait(lines);
    _process = null;
    return exitCode;
  }
}

/// What a finished build produced.
class WebCatalogBuild {
  WebCatalogBuild({
    required this.output,
    required this.indexHtml,
    required this.entryCount,
    required this.duration,
  });

  /// The directory to serve. Absolute.
  final String output;

  final String indexHtml;
  final int entryCount;
  final Duration duration;
}
