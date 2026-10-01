// Declared as a setup only by `app/test/previews/preview_setup_render_test.dart`,
// for the case of a setup that throws.

/// Fails the way a setup expecting a bundled font that is not there would.
Future<void> previewSetup() async {
  await Future<void>.delayed(Duration.zero);
  throw StateError('no font is bundled under assets/fonts/');
}
