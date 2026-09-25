import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'src/lab_app.dart';

/// The lab's customer app.
///
/// Its optional parameters are its knobs (see the repo root's
/// `tool/flutterware.dart`): a world hands each person's app its server, its
/// session and its name through them, and changing one costs a hot restart
/// rather than a build.
///
/// It prints when its first frame reached the screen, as an absolute time, so
/// a launch can be timed against the moment the launcher started it — the run
/// handle's `startedAt` — with no clock of its own.
void main({
  String server = 'http://localhost:8090',
  String session = '',
  String person = '',
}) {
  var mainAt = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LabApp(server: Uri.parse(server), session: session, person: person));
  unawaited(
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      var now = DateTime.now();
      print(
        'world_lab: first frame at ${now.toUtc().toIso8601String()}, '
        '${now.difference(mainAt).inMilliseconds} ms after main',
      );
    }),
  );
}
