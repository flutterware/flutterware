// Pure Dart on purpose: the fw CLI imports this to generate the bundle's
// entrypoint, and the CLI must never reach package:flutter.
import 'package:path/path.dart' as p;

/// The name of the function marked `@RenderRegistry()` in [source], or null
/// when the file declares no registrar.
///
/// A textual scan, not an analyzer pass: the registrar is one annotated
/// top-level `void` function, and the bundle command refuses loudly when the
/// pattern is absent rather than guessing. Line-anchored so the annotation in
/// a doc comment or a string never binds (`/// @RenderRegistry()` does not
/// start a line with the annotation), and the function must follow the
/// annotation directly — whitespace only — so an annotation on something
/// else cannot adopt a later, unannotated function.
String? findRenderRegistrarName(String source) {
  var match = RegExp(
    r'^[ \t]*@RenderRegistry\(\)\s*void\s+(\w+)\s*\(',
    multiLine: true,
  ).firstMatch(source);
  return match?.group(1);
}

/// Whether [source] carries the annotation at all — for the refusal message
/// when [findRenderRegistrarName] finds no *usable* registrar: an annotated
/// `Future<void>` function, say, is a different mistake from a missing one.
bool mentionsRenderRegistrar(String source) =>
    RegExp(r'^[ \t]*@RenderRegistry\(\)', multiLine: true).hasMatch(source);

/// The generated main compiled into a render bundle: imports the app's
/// registrar and hands it to the driver.
///
/// [registrarFile] and [directory] are both package-root-relative;
/// [directory] is where the generated file will sit, so the import can be
/// spelled relative to it.
String generateRenderBundleEntrypoint({
  required String registrarFile,
  required String registrarName,
  required String directory,
}) {
  var import = p.url.relative(
    p.url.joinAll(p.split(registrarFile)),
    from: p.url.joinAll(p.split(directory)),
  );
  return '''
// GENERATED — flutterware render bundle harness. Do not edit.
import 'package:flutterware_render/flutterware_render.dart' as render;
import '$import' as renders;

void main() => render.runRenderDriver(renders.$registrarName);
''';
}
