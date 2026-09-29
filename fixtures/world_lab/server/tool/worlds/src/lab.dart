import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/server.dart';
import 'package:flutterware/world.dart';
import 'package:logging/logging.dart';
import 'package:world_lab_server/world_lab_server.dart';

/// The lab server, hosted in the world's own process: its edges print into
/// the world's log — until the outbox exists, that is where a text message
/// goes — and still report to the Server panel as they do when it runs alone.
///
/// [orders] and [sync] are the server's own: hand them for a synced world.
Future<LabServer> startLabServer(
  World w, {
  OrderStore? orders,
  SyncAuth? sync,
  bool kitchen = false,
}) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (record) => print('${record.loggerName}: ${record.message}'),
  );
  w.progress('Starting the lab server');
  // Hosted here, it would go by the script's file name.
  FlutterwareServer.configure(name: 'lab');
  var server = await startServer(
    orders: orders,
    sync: sync,
    kitchen: kitchen,
    port: await w.freePort(),
    sms: _WorldSms(w),
    push: _WorldPush(w),
    mail: _WorldMail(w),
  );
  w.onClose(server.close);
  return server;
}

/// A phone number no other person of this process has had. The lab server
/// takes any number, so a counter is enough; a project writes numbers its
/// own server accepts — flutterware cannot know that rule.
String newPhone() => '+44770090${(_phones++).toString().padLeft(4, '0')}';
var _phones = 0;

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

class _WorldMail implements MailService {
  _WorldMail(this.w);

  final World w;

  @override
  Future<void> send(
    String to, {
    required String subject,
    required String text,
    required String html,
  }) async {
    await ReportedMail().send(to, subject: subject, text: text, html: html);
    w.progress('Mail to $to: $subject');
  }
}

/// What a service that is not Dart does when it mails someone — an identity
/// provider's sign-up code, a newsletter tool's digest — stood in for by a
/// few lines of SMTP to the world's inbox ([World.smtp]).
Future<void> sendNewsletter({required int port, required String to}) async {
  var socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  var replies = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  Future<void> reply() async {
    while (await replies.moveNext()) {
      var line = replies.current;
      if (line.length < 4 || line[3] == ' ') return;
    }
  }

  await reply();
  for (var command in [
    'EHLO newsletter.example.com',
    'MAIL FROM:<news@example.com>',
    'RCPT TO:<$to>',
    'DATA',
  ]) {
    socket.write('$command\r\n');
    await reply();
  }
  socket.write(
    [
      'From: The Lab <news@example.com>',
      'To: $to',
      'Subject: This week at the lab',
      'MIME-Version: 1.0',
      'Content-Type: text/html; charset=utf-8',
      '',
      '<html><body style="font-family:-apple-system,sans-serif;margin:24px">',
      '<h2>This week at the lab</h2>',
      '<p>A new single origin on the board, and the counter opens at 7.</p>',
      '<p><a href="https://flutterware.dev">Read it on the web</a> &middot;',
      '<a href="worldlab://orders">See the board</a></p>',
      '</body></html>',
      '.',
      'QUIT',
    ].join('\r\n'),
  );
  socket.write('\r\n');
  await reply();
  await reply();
  await socket.close();
}

/// A customer with no app orders a flat white, through the API: what the
/// worlds' *Mia orders a flat white* does — as [mia], the person a world
/// declared, or as a new customer each time.
Future<void> miaOrders(LabServer server, ActionRun run, {LabUser? mia}) async {
  mia ??= await createUser(server, 'Mia', phone: newPhone());
  run.progress('Mia is ${mia.id}');
  await call(server, 'POST', '/orders', {'item': 'Flat white'}, mia.token);
}

/// Rush hour: a dozen customers with no app walk in and order, a few
/// hundred milliseconds apart, and the kitchen works through the queue they
/// make — what the worlds' *Rush hour* does.
Future<void> rushHour(
  LabServer server,
  ActionRun run, {
  int walkIns = 12,
}) async {
  for (var i = 1; i <= walkIns; i++) {
    if (run.cancelled) return;
    var customer = await createUser(server, 'Walk-in $i', phone: newPhone());
    await call(server, 'POST', '/orders', {
      'item': menu[i % menu.length],
    }, customer.token);
    run.progress('$i of $walkIns ordered', fraction: i / walkIns);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
