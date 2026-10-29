import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
import 'package:flutterware_app/src/world/open_world.dart';
import 'package:flutterware_app/src/world/platform/studio_platform.dart';
import 'package:flutterware_app/src/world/world_messages.dart';
import 'package:flutterware_app/src/world/world_person.dart';
import 'package:flutterware_app/src/world/world_trace.dart';

void main() {
  var since = DateTime(2026, 9, 28, 23);
  var nextId = 1;
  late WorldTrace trace;

  InspectorEvent at(int ms, String channel, Map<String, Object?> payload) =>
      InspectorEvent(
        channel: channel,
        id: nextId++,
        time: since.add(Duration(milliseconds: ms)),
        payload: payload,
        isReplay: false,
      );

  setUp(() => trace = WorldTrace(since: since)..addPerson('Leo', userId: 'u1'));

  test('what a person received is listed newest first, a push the app '
      'showed a notification for once, as the notification', () {
    trace.addServerEvent(
      'lab',
      at(0, 'sms', {'to': '+447700900000', 'body': 'Your code is 428500'}),
    );
    // Sent now, so the notification the app posts for it now is its own.
    trace.addServerEvent(
      'lab',
      InspectorEvent(
        channel: 'push',
        id: nextId++,
        time: DateTime.now(),
        payload: {'to': 'u1', 'title': 'Your flat white is ready'},
        isReplay: false,
      ),
    );
    trace.addServerEvent(
      'lab',
      InspectorEvent(
        channel: 'push',
        id: nextId++,
        time: DateTime.now(),
        payload: {'to': 'u1', 'title': 'Your table is ready'},
        isReplay: false,
      ),
    );
    var posted = [
      GuestNotification(7, 'Your flat white is ready', 'At the counter', null),
    ];

    var received = receivedBy(trace.outbox(), posted);
    expect(
      [for (var each in received) (each.kind, linesOf(each, app: 'Lab').text)],
      [
        ('notification', 'Your flat white is ready'),
        ('push', 'Your table is ready'),
        ('sms', 'Your code is 428500'),
      ],
    );
  });

  test('a phone shows who a message is from, what it says and a line more', () {
    OutboxMessage sent(String kind, {String? body, String? sender}) =>
        OutboxMessage(
          id: 'lab/1',
          at: since,
          kind: kind,
          to: 'ana@example.com',
          text: 'New order',
          body: body,
          sender: sender,
        );
    ({String from, String text, String? more}) lines(OutboxMessage message) =>
        linesOf(Received.message(message), app: 'Lab');

    expect(lines(sent('sms')), (from: 'lab', text: 'New order', more: null));
    // A push is the app's, as a phone shows it.
    expect(lines(sent('push', body: 'Collect it at the counter.')), (
      from: 'Lab',
      text: 'New order',
      more: 'Collect it at the counter.',
    ));
    // A mail's preview is its first line with words on it.
    expect(
      lines(
        sent('mail', body: '\n  Flat white for Mia\nOrder o1', sender: 'shop'),
      ),
      (from: 'shop', text: 'New order', more: 'Flat white for Mia'),
    );
    expect(
      linesOf(
        Received.notification(GuestNotification(1, 'Ready', 'Come by', null)),
        app: 'Lab',
      ),
      (from: 'Lab', text: 'Ready', more: 'Come by'),
    );
  });

  test('a push is shown when the app posted a notification with its title '
      'around when it was sent', () {
    /// The push, sent at [time].
    OutboxMessage sentAt(DateTime time) {
      var trace = WorldTrace(since: time.subtract(const Duration(seconds: 1)))
        ..addPerson('Leo', userId: 'u1')
        ..addServerEvent(
          'lab',
          InspectorEvent(
            channel: 'push',
            id: nextId++,
            time: time,
            payload: {'to': 'u1', 'title': 'Your flat white is ready'},
            isReplay: false,
          ),
        );
      return trace.outbox().single;
    }

    // A notification is stamped as the app posts it: now.
    GuestNotification posted(String title) =>
        GuestNotification(1, title, 'Collect it at the counter.', null);

    var now = sentAt(DateTime.now());
    expect(wasShown(now, [posted('Your flat white is ready')]), isTrue);
    expect(wasShown(now, [posted('Your cortado is ready')]), isFalse);
    // An hour before: another push with the same words.
    var earlier = sentAt(DateTime.now().subtract(const Duration(hours: 1)));
    expect(wasShown(earlier, [posted('Your flat white is ready')]), isFalse);
  });

  test("a card names the world's actions that name its person", () {
    expect(
      actionsFor('Mia', [
        'Mia orders a flat white',
        'Rush hour',
        'Miami opens',
        'The newsletter goes out to mia',
      ]),
      ['Mia orders a flat white', 'The newsletter goes out to mia'],
    );
  });

  test("a line the script printed is its logger's, and the world's own "
      "lines are the world's", () {
    var at = const Duration(milliseconds: 41200);
    var edges = WorldLogLine.of(
      at,
      'world_lab.edges: mail to ana@example.com: New order',
      printed: true,
    );
    expect(
      (edges.source, edges.text),
      ('world_lab.edges', 'mail to ana@example.com: New order'),
    );
    expect(
      edges.line,
      '41.2s  world_lab.edges: mail to ana@example.com: New order',
    );
    expect(
      WorldLogLine.of(at, 'Error: the socket closed', printed: true).source,
      'script',
    );
    expect(WorldLogLine.of(at, 'Built Lab', printed: false).source, 'world');
  });
}
