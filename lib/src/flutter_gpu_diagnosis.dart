/// What a Flutter GPU failure means, said by the process it happened in.
///
/// The engine's own messages are accurate and name nothing a reader can act
/// on: the two gates say "enable Impeller" and "enable Flutter GPU" without
/// saying who was supposed to, and the third — the one that actually bites —
/// is `Failed to initialize ShaderLibrary:` with an empty reason after the
/// colon. A test process can see its own engine flags, so it can finish those
/// sentences.
library;

import 'dart:io';

/// The tester flags that decide whether Flutter GPU works, and how a failure
/// reads.
///
/// Read off `Platform.executableArguments`, which comes back complete inside a
/// test — the whole list the tester was spawned with.
typedef RasterizerFlags = ({bool impeller, bool flutterGpu, String? backend});

/// [executableArguments] as the three facts that matter.
RasterizerFlags readRasterizerFlags(List<String> executableArguments) => (
  impeller: executableArguments.contains('--enable-impeller'),
  flutterGpu: executableArguments.any(
    (a) => a == '--enable-flutter-gpu' || a.startsWith('--enable-flutter-gpu='),
  ),
  backend: executableArguments
      .where((a) => a.startsWith('--impeller-backend='))
      .map((a) => a.substring('--impeller-backend='.length))
      .firstOrNull,
);

/// Whether [failure] is the engine complaining about Flutter GPU rather than
/// about the app.
///
/// Deliberately narrow. A sentence appended to an unrelated failure is worse
/// than no sentence, because the reader spends their first minute on the wrong
/// thing — so these are the three strings only `lib/gpu/` can produce, and a
/// project that does not depend on `package:flutter_gpu` can never see one.
///
/// **`FragmentProgram` is not in this list, on purpose.** Its own backend
/// mismatch — "does not contain appropriate runtime stage data for current
/// backend (Metal). Found stages: …" — comes from
/// `lib/ui/painting/fragment_program.cc` and is nothing to do with Flutter GPU:
/// an ordinary `.frag` in a pubspec's `shaders:` hits it, and enabling Flutter
/// GPU would not move it an inch. It also needs no help. That message already
/// names the asset, the backend in use and the stages actually found, which is
/// everything the reader needs and exactly what `Failed to initialize
/// ShaderLibrary:` fails to give.
bool isFlutterGpuFailure(String failure) =>
    failure.contains('Flutter GPU requires the Impeller rendering backend') ||
    failure.contains('Flutter GPU must be enabled') ||
    failure.contains('Failed to initialize ShaderLibrary');

/// [failure] with what this process knows about it appended, or [failure]
/// unchanged when it is not about Flutter GPU or nothing useful can be added.
///
/// [macOS] is the host, not the device being rendered as: the mismatch this
/// exists for is between the tester's backend and the backend a *build hook*
/// compiled shaders for, and a hook compiles for the machine it runs on.
String withFlutterGpuDiagnosis(
  String failure, {
  required List<String> executableArguments,
  required bool macOS,
}) {
  var note = flutterGpuDiagnosis(
    failure,
    executableArguments: executableArguments,
    macOS: macOS,
  );
  return note == null ? failure : '$failure\n\n$note';
}

/// The sentence, or null when there is nothing to say.
String? flutterGpuDiagnosis(
  String failure, {
  required List<String> executableArguments,
  required bool macOS,
}) {
  if (!isFlutterGpuFailure(failure)) return null;
  var flags = readRasterizerFlags(executableArguments);

  if (!flags.impeller) {
    return 'This harness is rendering with the software rasterizer, and '
        'Flutter GPU only exists on Impeller. Under `flutter test` that is the '
        'default, and no flag combination fixes it for a project whose '
        'shaders were built for this host, so run the scenario through '
        'flutterware instead. Under flutterware it means '
        '`FW_SOFTWARE_RENDERING=1` is set.';
  }

  if (!flags.flutterGpu) {
    return 'Impeller is on but Flutter GPU is not: the engine requires '
        '`--enable-flutter-gpu` as well, and having one without the other '
        'renders nothing. `flutter test` takes both flags.';
  }

  if (flags.backend == null && macOS) {
    return 'Impeller and Flutter GPU are both on, and no `--impeller-backend` '
        'was named, so the engine chose Vulkan, which it does on every host '
        'when nothing names one. That is almost certainly the problem here: a '
        "package's build hook compiles its shaders for the host's *real* "
        'backend, which on macOS is Metal, and a Metal shader bundle cannot be '
        'read by a Vulkan context.\n'
        '`flutter test` has `--enable-impeller` and `--enable-flutter-gpu` but '
        'no `--impeller-backend`, so it cannot get there. flutterware spawns '
        'the tester itself and passes `--impeller-backend=metal`; run the '
        'scenario through it.';
  }

  if (flags.backend != null) {
    return 'Impeller is on with the `${flags.backend}` backend. If the shaders '
        'this failed on came from a build hook, check which backend the hook '
        'compiled them for. A bundle carries one backend, and the others '
        'cannot read it.';
  }

  return null;
}

/// Whether the console has already been told, this process.
///
/// The sentence is about the process's own engine flags, so it is the same
/// sentence every time and a second copy teaches nothing. Public so a test can
/// reset it.
var flutterGpuDiagnosisAnnounced = false;

/// Writes the diagnosis to stderr, once, for a failure that will never pass
/// through the structured report.
///
/// A scenario body that *throws* is reported by the test framework's own
/// failure path, not by `reportTestException` — so amending
/// [ScenarioRunError] reaches flutterware's reader and nobody running
/// `flutter test`, which is precisely the lane the sentence exists for. This
/// is the same escape the `runAsync` watchdog takes, and for the same reason.
void announceFlutterGpuDiagnosis(
  String failure, {
  required List<String> executableArguments,
  required bool macOS,
}) {
  if (flutterGpuDiagnosisAnnounced) return;
  var note = flutterGpuDiagnosis(
    failure,
    executableArguments: executableArguments,
    macOS: macOS,
  );
  if (note == null) return;
  flutterGpuDiagnosisAnnounced = true;
  stderr.writeln('[flutterware] $note');
}
