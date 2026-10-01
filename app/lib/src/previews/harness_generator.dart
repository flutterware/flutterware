import 'dart:io';

import 'package:path/path.dart' as p;

// The leaf, not the `source_code.dart` barrel: `entrypoint_generator.dart`
// escapes the same way and sits on the compiler daemon's import closure, where
// every library pulled in is one more thing that can reach Flutter.
import '../utils/source_code/escape_dart_string.dart';
import 'catalog_entry.dart';
import 'catalog_wrapper.dart';
import 'devices.dart';
import 'preview_setup.dart';

/// Where the generated preview harness lives, relative to the package.
const previewHarnessPath = 'build/flutterware/previews_harness.dart';

/// Where its per-entry wrappers live. A directory of its own, because relative
/// imports inside a wrapper resolve from wherever it sits.
const previewWrapperDir = 'build/flutterware/previews_harness';

/// The generated test program: one wrapper import per entry, feeding
/// `runPreviewHarness` the table it declares from.
///
/// The third emitter over [CatalogWrapperWriter], beside the guest's entrypoint
/// and the web build — and the sharing is structural rather than tidy. A
/// wrapper encodes the demo's own *scope*: which imports were in it, what a
/// relative URI resolves against, why the file is imported twice. A second copy
/// of those rules goes out of date silently, and the symptom is a preview that
/// renders in the panel and not under the audit.
///
/// [canvases] are emitted as source rather than passed at runtime because the
/// harness is a *program*: nothing hands it arguments, and `deviceById` is how
/// an id becomes the `Device` the test surface is staged from. An id this build
/// has no device for drops out, exactly as `PreviewCanvas.fromJson` drops it —
/// a canvas with fewer devices, never a harness that will not compile.
///
/// [setupImport] is how the harness imports the package's declared setup
/// file, already resolved from where the harness sits; the table is then
/// handed its `previewSetup` to run before any entry builds. Emitted only when
/// one is declared, so a project that declares none compiles against any
/// `package:flutterware` it did before.
String generatePreviewHarness(
  List<CatalogEntry> entries, {
  required List<PreviewCanvas> canvases,
  String harnessPath = previewHarnessPath,
  String? setupImport,
}) {
  var sorted = _sorted(entries);
  var buffer = StringBuffer()
    ..writeln('// GENERATED — flutterware previews harness. Do not edit.')
    ..writeln('//')
    ..writeln('// Run it directly to check the catalog with no flutterware:')
    ..writeln('//')
    ..writeln('//     flutter test $harnessPath')
    ..writeln('//')
    ..writeln("// That lane inherits `flutter test`'s `--use-test-fonts`, so")
    ..writeln('// unstyled text is measured in the approximate Roboto the')
    ..writeln('// harness registers over it — near enough for an overflow')
    ..writeln('// verdict to mean something, never pixel-exact. A close call')
    ..writeln('// belongs to `fw run previews audit`, which spawns its own')
    ..writeln('// tester and needs no approximation.')
    ..writeln("import 'package:flutter/widgets.dart';")
    ..writeln("import 'package:flutter/widget_previews.dart';")
    ..writeln("import 'package:flutterware/flutter_test.dart';")
    ..writeln();
  if (setupImport != null) {
    buffer.writeln('import ${escapeDartString(setupImport)} as fw_setup;');
  }
  for (var (index, _) in sorted.indexed) {
    buffer.writeln(
      "import '${p.basename(previewWrapperDir)}/entry_$index.dart' as fw$index;",
    );
  }
  buffer
    ..writeln()
    ..writeln('void main() => runPreviewHarness(')
    ..writeln('  [');
  // Every field escaped, none of them raw. A raw string cannot escape the quote
  // that delimits it, so one `@Preview(name: "What's new")` emitted a file that
  // does not parse — and the harness is one file for the whole package, so that
  // one name took every entry with it. `id` is derived from `path` and `symbol`
  // unless the annotation pins one, and `path` is a directory a human named;
  // the only reason those had not broken yet is that nobody had put an
  // apostrophe in one.
  for (var (index, entry) in sorted.indexed) {
    buffer
      ..writeln('    PreviewEntry(')
      ..writeln('      id: ${escapeDartString(entry.id)},')
      ..writeln('      path: ${escapeDartString(entry.path)},')
      ..writeln('      name: ${escapeDartString(entry.name)},')
      ..writeln(
        '      build: () => _build(fw$index.fwPreview, fw$index.fwBuilder),',
      )
      ..writeln('    ),');
  }
  buffer
    ..writeln('  ],')
    ..writeln('  canvases: _canvases,');
  if (setupImport != null) {
    buffer.writeln('  setup: fw_setup.$previewSetupFunction,');
  }
  buffer
    ..writeln(');')
    ..writeln()
    ..writeln('final _canvases = <PreviewCanvas>[');
  for (var canvas in canvases) {
    buffer.writeln('  ${_canvasSource(canvas)},');
  }
  buffer
    ..writeln('];')
    ..writeln()
    ..writeln('/// The annotation applied the one way, as the guest entrypoint')
    ..writeln('/// and the web build both apply it.')
    ..writeln('Widget _build(Preview preview, Widget Function() builder) {')
    ..writeln('  var wrapper = preview.transform().wrapper;')
    ..writeln('  var child = builder();')
    ..writeln('  return wrapper == null ? child : wrapper(child);')
    ..writeln('}');
  return buffer.toString();
}

/// Writes the harness and its wrappers, and returns the harness's path.
///
/// Nothing whose content is already right is touched. A rewritten file is a
/// moved mtime, and a moved mtime is what `SourceInvalidator` reads as an edit —
/// so a generator that rewrote unconditionally would make every sync recompile
/// the whole catalog for nothing.
///
/// [directory] is where the harness and its wrapper directory go, relative to
/// the package — the runner's `buildDirectory`. It matters beyond tidiness:
/// wrapper indices are assigned within *this* entry list, so a harness written
/// for a subset renumbers — and prunes — another harness's wrappers if the two
/// share a directory. That is exactly what a comparison rendering the panel's
/// own worktree would do to the warm audit runner.
///
/// [setup] is checked before anything is written: a harness importing a file
/// that is not there fails its compile in generated code, which names no
/// entry and reads as flutterware's own bug.
String writePreviewHarness(
  String packageRoot,
  List<CatalogEntry> entries, {
  required List<PreviewCanvas> canvases,
  String directory = 'build/flutterware',
  PreviewSetup? setup,
}) {
  setup?.check(packageRoot);
  var sorted = _sorted(entries);
  var wrapperDir = Directory(
    p.join(packageRoot, directory, p.basename(previewWrapperDir)),
  )..createSync(recursive: true);
  var writer = CatalogWrapperWriter(
    outputDir: wrapperDir.path,
    projectRoot: packageRoot,
  );

  var live = <String>{};
  for (var (index, entry) in sorted.indexed) {
    var name = 'entry_$index.dart';
    live.add(name);
    _writeIfDifferent(
      p.join(wrapperDir.path, name),
      writer.source(entry, index),
    );
  }
  // An entry that went away leaves a wrapper behind, and a wrapper the harness
  // no longer imports is unreachable — but it is still a file the invalidator
  // watches and a reader can mistake for live code.
  for (var stale in wrapperDir.listSync()) {
    if (stale is! File) continue;
    var name = p.basename(stale.path);
    if (name.startsWith('entry_') && !live.contains(name)) stale.deleteSync();
  }

  var relative = p.url.join(directory, p.basename(previewHarnessPath));
  var path = p.join(packageRoot, directory, p.basename(previewHarnessPath));
  _writeIfDifferent(
    path,
    generatePreviewHarness(
      sorted,
      canvases: canvases,
      harnessPath: relative,
      // From the harness's own directory, which is where the wrapper writer
      // resolves relative URIs from when it is pointed there.
      setupImport: switch (setup) {
        var declared? => CatalogWrapperWriter(
          outputDir: p.join(packageRoot, directory),
          projectRoot: packageRoot,
        ).uriFor(p.join(packageRoot, declared.path)),
        null => null,
      },
    ),
  );
  return path;
}

/// Indices are assigned by sorted id and nothing else, so regenerating an
/// unchanged catalog produces byte-identical files — and adding one entry
/// renumbers only the wrappers after it rather than all of them.
List<CatalogEntry> _sorted(List<CatalogEntry> entries) =>
    [...entries]..sort((a, b) => a.id.compareTo(b.id));

void _writeIfDifferent(String path, String source) {
  var file = File(path);
  if (file.existsSync() && file.readAsStringSync() == source) return;
  file
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);
}

/// One canvas as the line of Dart that reconstructs it.
///
/// Devices go by id through `deviceById` rather than as literal geometry: the
/// harness compiles against the *project's* `flutterware`, so a table that
/// differs from this build's resolves there rather than here. `?` drops an id
/// this build knows and that one does not, which is a canvas with fewer
/// devices — never a harness that will not compile.
String _canvasSource(PreviewCanvas canvas) {
  var devices = [
    for (var d in canvas.devices) '?deviceById(${escapeDartString(d.id)})',
  ];
  var orientations = [
    for (var o in canvas.orientations)
      '?orientationById(${escapeDartString(o.name)})',
  ];
  var keyboards = [
    for (var k in canvas.keyboards)
      '?keyboardModeById(${escapeDartString(k.name)})',
  ];
  var parts = [
    escapeDartString(canvas.root),
    if (devices.isNotEmpty) 'devices: [${devices.join(', ')}]',
    if (orientations.isNotEmpty) 'orientations: [${orientations.join(', ')}]',
    if (keyboards.isNotEmpty) 'keyboards: [${keyboards.join(', ')}]',
  ];
  return 'PreviewCanvas(${parts.join(', ')})';
}
