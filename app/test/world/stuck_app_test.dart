import 'package:flutterware_app/src/world/app_guest.dart';
import 'package:test/test.dart';

void main() {
  test('a stuck app is shown with what it last said, not its stack', () {
    // What a consumer's app printed in a world: its own zone caught the
    // error, so the world heard of it only through the app's output.
    var zoneError =
        "flutter: Zone error Invalid argument(s): Couldn't resolve native "
        "function 'DOBJC_initializeApi' in 'package:objective_c/"
        "objective_c.dylib' : No asset with id 'package:objective_c/"
        "objective_c.dylib' found. No available native assets.";
    var words = LastWords();
    for (var line in [
      'flutter: The Dart VM service is listening on http://127.0.0.1:53840/',
      '[{"event":"app.started","params":{"appId":"guest-Ana"}}]',
      zoneError,
      '#0      Native._ffi_resolver.#ffiClosure0 (dart:ffi-patch/ffi_patch.dart)',
      '#1      initializeApi (package:objective_c/src/c_bindings_generated.dart)',
      '<asynchronous suspension>',
      '${guestStuckMarker}10 s',
    ]) {
      words.hear(line);
    }

    expect(
      stuckProblem(
        stuckBeforeDrawing('${guestStuckMarker}10 s')!,
        words,
        hooksFailure:
            "objective_c's build hook failed: Can't load Kernel binary: "
            'Invalid SDK hash.',
      ),
      'The app has not called runApp 10 s after it started, so it draws '
      'nothing.\n'
      '\n'
      'Its last lines:\n'
      "Zone error Invalid argument(s): Couldn't resolve native function "
      "'DOBJC_initializeApi' in 'package:objective_c/objective_c.dylib' : No "
      "asset with id 'package:objective_c/objective_c.dylib' found. No "
      'available native assets.\n'
      '\n'
      "objective_c's build hook failed: Can't load Kernel binary: Invalid SDK "
      'hash.',
    );
  });

  test('keeps the last three lines', () {
    var words = LastWords();
    for (var i = 1; i <= 5; i++) {
      words.hear('line $i');
    }
    expect(words.lines, ['line 3', 'line 4', 'line 5']);
  });
}
