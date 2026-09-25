/// Runs the lab server on its own, with its edges reporting to flutterware.
///
/// ```sh
/// fvm dart run bin/server.dart          # port 8090
/// WORLD_LAB_PORT=0 fvm dart run bin/server.dart
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutterware/server.dart';
import 'package:logging/logging.dart';
import 'package:world_lab_server/world_lab_server.dart';

Future<void> main() async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(record);
    (record.zone ?? Zone.current).run(() {
      FlutterwareServer.event('log', {
        'level': record.level.name,
        'logger': record.loggerName,
        'message': record.message,
      });
    });
  });
  var port = int.parse(Platform.environment['WORLD_LAB_PORT'] ?? '8090');
  await startServer(port: port, sms: ReportedSms(), push: ReportedPush());
}
