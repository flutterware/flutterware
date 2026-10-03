import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
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

  void push(int ms, {String? step}) => trace.addServerEvent(
    'lab',
    at(ms, 'push', {
      'to': 'u1',
      'title': 'Your flat white is ready',
      'body': 'Collect it at the counter.',
      'step': ?step,
    }),
  );

  setUp(() => trace = WorldTrace(since: since)..addPerson('Leo', userId: 'u1'));

  test('a message says what caused it in the words of its step', () {
    trace
      ..addActionStep('world.1', 'The regulars order', since)
      ..addGuestEvent(
        'Leo',
        at(500, worldStepsChannel, {
          'step': 'leo.2',
          'verb': 'tap',
          'target': '"Order a flat white"',
        }),
      );
    push(1000, step: 'world.1');
    push(2000, step: 'leo.2');
    push(3000, step: 'leo.9');
    push(4000);

    expect(
      [for (var message in trace.outbox()) causeOf(message, trace)],
      [
        null,
        // A step the trace no longer holds is still named, by its id.
        'leo.9',
        'Leo tapped "Order a flat white"',
        'The regulars order',
      ],
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
