import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/world.dart';
import 'package:logging/logging.dart';
import 'package:world_lab_server/world_lab_server.dart';

/// The lab server, hosted in the world's own process: its edges print into
/// the world's log — until the outbox exists, that is where a text message
/// goes — and still report to the Server panel as they do when it runs alone.
Future<LabServer> startLabServer(World w) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (record) => print('${record.loggerName}: ${record.message}'),
  );
  w.progress('Starting the lab server');
  var server = await startServer(
    port: await w.freePort(),
    sms: _WorldSms(w),
    push: _WorldPush(w),
  );
  w.onClose(server.close);
  return server;
}

/// A user the lab server made through its admin API, and their session.
typedef LabUser = ({String id, String name, String token});

/// Makes a user through the server's own admin API, as the world's seeding
/// always does — never behind the server's back.
Future<LabUser> createUser(
  LabServer server,
  String name, {
  String role = 'customer',
  String? email,
  String? phone,
}) async {
  var json = await call(server, 'POST', '/admin/users', {
    'name': name,
    'role': role,
    'email': ?email,
    'phone': ?phone,
  });
  return (
    id: json['id']! as String,
    name: json['name']! as String,
    token: json['token']! as String,
  );
}

/// One call to the lab server's API, as [token]'s user when given.
Future<Map<String, Object?>> call(
  LabServer server,
  String method,
  String path, [
  Map<String, Object?>? body,
  String? token,
]) async {
  var client = HttpClient();
  try {
    var request = await client.openUrl(method, server.url.resolve(path));
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    var response = await request.close();
    var text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      throw StateError('$method $path: ${response.statusCode} $text');
    }
    return text.isEmpty
        ? const {}
        : (jsonDecode(text) as Map).cast<String, Object?>();
  } finally {
    client.close();
  }
}

class _WorldSms implements SmsService {
  _WorldSms(this.w);

  final World w;

  @override
  Future<void> send(String to, String body) async {
    await ReportedSms().send(to, body);
    w.progress('SMS to $to: $body');
  }
}

class _WorldPush implements PushService {
  _WorldPush(this.w);

  final World w;

  @override
  Future<void> send(
    String userId, {
    required String title,
    required String body,
    String? link,
  }) async {
    await ReportedPush().send(userId, title: title, body: body, link: link);
    w.progress('Push to $userId: $title');
  }
}
