import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The one data-free viewer bundle: `lib/main_export_web.dart`, compiled once
/// into a fixed directory and copied beside whatever data file an export just
/// wrote.
///
/// One bundle for both exports, not one each. The page decides what it is at
/// run time, from which file sits beside it — `index.json` is a comparison,
/// `report.json` a scenario run — so the scenario and comparison exporters
/// share the compile and its cache, and exporting the second kind after the
/// first is a file copy rather than another minute of `flutter build web`.
///
/// Both exporters are this plus their own data collection, and the half in
/// here is the half that was identical twice: build the bundle if the build
/// system says it is stale, copy it, and be killable, because a
/// `flutter build web` is tens of seconds and a child started with
/// `Process.start` is not killed when the Dart parent exits on macOS.
class ViewerBundle {
  ViewerBundle({required this.flutterExecutable, required this.appToolRoot});

  final String flutterExecutable;

  /// Where `flutterware_app` lives — this checkout's `app/`, or the unpacked
  /// copy under `~/.flutterware/` for a hosted install. `flutter build web`
  /// runs here.
  final String appToolRoot;

  /// The entry point, relative to [appToolRoot].
  static const target = 'lib/main_export_web.dart';

  /// Where the viewer bundle is compiled to.
  ///
  /// A fixed directory under the app package, so `flutter build web`'s own
  /// incremental build decides whether a rebuild is needed. Hand-rolling that
  /// question — hashing a version, stamping a manifest — would be a second
  /// answer to it, and the one that goes stale is always the hand-rolled one.
  ///
  /// Fixed also means shared: two exports building at the very same moment
  /// would race on it, exactly as they already race on the package's build
  /// caches — a hazard that predates the shared bundle and has yet to be
  /// observed outside this sentence.
  String get viewerDir => p.join(appToolRoot, 'build', 'export_web_viewer');

  /// Stands in for the `flutter build web` that produces the viewer, so a test
  /// can exercise everything after it — which is where all the logic is —
  /// without a toolchain and a minute of compiling. Reached through the owning
  /// exporter's own `@visibleForTesting` member, which is why this one is not
  /// annotated.
  Future<int> Function(List<String> arguments)? debugCompile;

  /// Compiles the viewer, or lets the build system decide it need not.
  Future<void> build({
    required bool offline,
    void Function(String line)? onOutput,
  }) async {
    onOutput?.call('[export] building the viewer (this is cached after once)');
    var exitCode = await _run([
      'build',
      'web',
      '--release',
      '--target',
      target,
      '--output',
      viewerDir,
      // No service worker. An exported page is read once from a link, and the
      // caching worker Flutter is retiring only delayed that read: the page
      // loaded nothing until the worker had fetched its files and activated.
      // With this the build still writes the file, empty.
      '--pwa-strategy=none',
      // No Wasm dry run. `flutter build web` otherwise compiles the whole
      // program a second time, to Wasm, only to print whether it could have
      // been — advice about flutterware's own code that nobody reading an
      // export can act on. Measured 2026-09-16: 22 of the 24 seconds of a
      // rebuild with nothing changed, and 24.2s → 17.8s cold. dart2js itself
      // is skipped when nothing moved; the dry run never was.
      '--no-wasm-dry-run',
      // Offline makes the page carry its own CanvasKit rather than fetch it
      // from Google's CDN — for an artifact read behind a firewall, or after
      // the engine revision it was built against stops being hosted. Without
      // it the engine still lands in the build output and [copyTo] leaves it
      // there, because the page will never ask for it.
      if (offline) '--no-web-resources-cdn',
    ], onOutput);
    if (cancelled) return;
    if (exitCode != 0) {
      throw StateError(
        'The export page viewer did not compile (exit $exitCode). It is '
        "flutterware's own code in $appToolRoot — the error above is a bug in "
        'the tool, not in your project.',
      );
    }
  }

  /// What `flutter build web` leaves behind whether or not the page will ever
  /// ask for it.
  ///
  /// **38MB, and on a CDN page not one byte of it is fetched.** Measured on an
  /// exported comparison 2026-09-10: `canvaskit/` was 37.9MB of a 66.7MB page,
  /// and the browser loaded the engine from `www.gstatic.com` instead — which
  /// is what a build without `--no-web-resources-cdn` tells it to do. The
  /// directory is emitted regardless; it is only *used* by an offline build.
  static const _localEngine = 'canvaskit';

  /// Copies the compiled bundle into [output].
  ///
  /// [offline] must be the value [build] was given: it decided whether the
  /// page loads its engine from beside itself or from the CDN, and this
  /// decides whether the engine is put there. They are one call apart in both
  /// exporters for exactly that reason.
  void copyTo(String output, {required bool offline}) => _copyDirectory(
    Directory(viewerDir),
    Directory(output),
    skip: offline ? const {} : const {_localEngine},
  );

  static void _copyDirectory(
    Directory source,
    Directory destination, {
    Set<String> skip = const {},
  }) {
    for (var entity in source.listSync()) {
      var name = p.basename(entity.path);
      var target = p.join(destination.path, name);
      if (entity is Directory) {
        if (skip.contains(name)) continue;
        Directory(target).createSync(recursive: true);
        _copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      }
    }
  }

  Process? _process;
  var _cancelled = false;

  /// Whether [cancel] was called — what an exporter checks between its steps.
  bool get cancelled => _cancelled;

  /// Ends the build, if one is running.
  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
    _process = null;
  }

  Future<int> _run(
    List<String> arguments,
    void Function(String)? onOutput,
  ) async {
    if (debugCompile case var compile?) return compile(arguments);
    var process = _process = await Process.start(
      flutterExecutable,
      arguments,
      workingDirectory: appToolRoot,
    );
    if (_cancelled) process.kill();
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
