import 'dart:convert';
import 'dart:io';

/// A guest's output, written as `flutter run` writes a launch's log — so Run
/// reads a guest like any launch: its Logs tab shows the app's prints, and a
/// guest that goes away after starting is a run that ended, not one that
/// failed.
///
/// Two conversions are all it takes. The host prints the app's `print` as
/// `[embedder] …`, which becomes `flutter: …`, the prefix Run files under the
/// app; and the first frame writes the `app.started` event, which is what Run
/// reads to tell a run that ended from one that never came up.
class GuestLog {
  GuestLog(this.path) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');
  }

  final String path;
  static const _appPrefix = '[embedder] ';

  void line(String output) => _append(
    output.startsWith(_appPrefix)
        ? 'flutter: ${output.substring(_appPrefix.length)}'
        : output,
  );

  void started(String appId) => _append(
    jsonEncode([
      {
        'event': 'app.started',
        'params': {'appId': appId},
      },
    ]),
  );

  // Written through: Run reads this file from another process while it grows.
  void _append(String text) =>
      File(path)
          .writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
}
