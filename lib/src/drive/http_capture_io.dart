import 'dart:io';

/// Arms `dart:io`'s HTTP profiler before the app's first request.
///
/// The profile records nothing retroactively — enabling from the host over the
/// VM service loses whatever fired during startup. One assignment before
/// `runApp` is the whole capture story; the host reads the result with
/// `ext.dart.io.getHttpProfile`.
void armHttpCapture() {
  HttpClient.enableTimelineLogging = true;
}
