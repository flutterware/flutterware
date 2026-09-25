import 'package:flutterware/server.dart';
import 'package:logging/logging.dart';

final _log = Logger('world_lab.edges');

/// Where a text message goes. A deployed server would hand it to a carrier;
/// the lab never has one.
abstract interface class SmsService {
  Future<void> send(String to, String body);
}

/// Where a push notification goes, addressed to a user rather than to a
/// device token — the lab has no push provider to register tokens with.
abstract interface class PushService {
  Future<void> send(
    String userId, {
    required String title,
    required String body,
    String? link,
  });
}

/// The lab's SMS edge: every message becomes an `sms` event on the server's
/// inspection channel, and a log line for whoever started it by hand.
///
/// The event carries the resolved recipient, which is what the worlds design
/// asks of an adapter (*An adapter reports who a message reached*): the world
/// routes a message by the person it reached, not by parsing the body.
class ReportedSms implements SmsService {
  @override
  Future<void> send(String to, String body) async {
    _log.info('sms to $to: $body');
    FlutterwareServer.event('sms', {'to': to, 'body': body});
  }
}

/// The lab's push edge, reported the same way as [ReportedSms].
class ReportedPush implements PushService {
  @override
  Future<void> send(
    String userId, {
    required String title,
    required String body,
    String? link,
  }) async {
    _log.info('push to $userId: $title — $body');
    FlutterwareServer.event('push', {
      'to': userId,
      'title': title,
      'body': body,
      'link': ?link,
    });
  }
}
