import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/world_timeline_view.dart';
import 'package:flutterware_app/src/world/world_trace.dart';

import 'app_theme.dart';

/// The open world's timeline over a recording of the lab's *Pickup order*
/// (2026-09-30): Leo signs up and orders a cortado, Ana makes it, then the
/// world's two actions — Mia orders a flat white, the newsletter goes out.
/// Each event as the world heard it, replayed into a trace.

@Preview(name: 'Timeline', group: 'Worlds', wrapper: wrapInAppTheme)
Widget timeline() => const _Timeline();

@Preview(name: 'Timeline · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget timelineDark() => const _Timeline();

class _Timeline extends StatefulWidget {
  const _Timeline();

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  final _trace = pickupOrder();
  String? _focus;

  static const _people = ['Ana', 'Leo', 'Mia'];

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: WorldTimelineView(
        trace: _trace,
        people: _people,
        actions: true,
        colorOf: (person) => switch (person) {
          worldActionsOwner => colors.ink2,
          var name? when _people.contains(name) => colors.person(
            _people.indexOf(name),
          ),
          _ => colors.mut2,
        },
        focus: _focus,
        onFocus: (focus) => setState(() => _focus = focus),
      ),
    );
  }
}

/// The recording, replayed: every time is from the world's opening.
WorldTrace pickupOrder() {
  var since = DateTime(2026, 9, 30, 10, 56, 30, 949);
  var trace = WorldTrace(since: since)
    ..addPerson('Ana', userId: 'u188r-1', email: 'ana@example.com')
    ..addPerson('Leo', phone: '+447700900000')
    ..addPerson('Mia', userId: 'u188r-2', phone: '+447700900001');
  var id = 0;
  InspectorEvent event(
    int ms,
    String channel,
    Map<String, Object?> payload, [
    String? rid,
  ]) => InspectorEvent(
    channel: channel,
    id: ++id,
    time: since.add(Duration(milliseconds: ms)),
    payload: payload,
    isReplay: false,
    rid: rid,
  );

  void step(String person, String step, int ms, String verb, String target) =>
      trace.addGuestEvent(
        person,
        event(ms, worldStepsChannel, {
          'step': step,
          'verb': verb,
          'target': target,
        }),
      );

  // One request an app sent under [step], and the server's answer to it
  // with what it did within it: [caused] as channel and payload, each a
  // millisecond or so after the one before.
  var rids = 0;
  void call(
    String person,
    String step,
    int ms,
    String method,
    String path, {
    int? status,
    double took = 0.2,
    bool window = false,
    List<(int, String, Map<String, Object?>)> caused = const [],
  }) {
    trace.addGuestEvent(
      person,
      event(ms, worldRequestsChannel, {
        'step': step,
        'method': method,
        'url': 'localhost:59747$path',
        'how': window ? 'window' : 'zone',
      }),
    );
    // A WebSocket upgrade, which the adapter never answers.
    if (status == null) return;
    var rid = 'r${++rids}';
    for (var (after, channel, payload) in caused) {
      trace.addServerEvent(
        'lab',
        event(ms + after, channel, {...payload, 'step': step}, rid),
      );
    }
    trace.addServerEvent(
      'lab',
      event(ms + 1, 'http', {
        'method': method,
        'path': path,
        'status': status,
        'ms': took,
        'step': step,
      }, rid),
    );
  }

  // The two apps start, 2.6 s in.
  step('Leo', 'leo.0', 2550, 'start', 'the app');
  call('Leo', 'leo.0', 3107, 'GET', '/health', status: 200, window: true);
  call('Leo', 'leo.0', 3132, 'GET', '/live', window: true);
  step('Ana', 'ana.0', 2560, 'start', 'the app');
  call('Ana', 'ana.0', 3150, 'GET', '/health', status: 200, window: true);
  call('Ana', 'ana.0', 3174, 'GET', '/live', window: true);
  call('Ana', 'ana.0', 3191, 'GET', '/me', status: 200, window: true);
  call('Ana', 'ana.0', 3193, 'GET', '/orders', status: 200, window: true);

  // Leo signs up with his phone number.
  step('Leo', 'leo.1', 21400, 'tap', '"Send code"');
  call(
    'Leo',
    'leo.1',
    21411,
    'POST',
    '/auth/code',
    status: 204,
    took: 0.8,
    caused: [
      (2, 'sms', {'to': '+447700900000', 'body': 'Your pickup code is 540435'}),
    ],
  );
  step('Leo', 'leo.2', 22462, 'tap', 'at (197, 271)');
  step('Leo', 'leo.3', 39237, 'type', 'the code from the SMS');
  step('Leo', 'leo.4', 50724, 'tap', '"Sign in"');
  call('Leo', 'leo.4', 50742, 'POST', '/auth/verify', status: 200, took: 0.4);
  call(
    'Leo',
    'leo.4',
    50747,
    'GET',
    '/me',
    status: 200,
    caused: [
      (1, 'identify', {'user': 'u188r-3'}),
    ],
  );
  call('Leo', 'leo.4', 50749, 'GET', '/orders', status: 200);
  call('Leo', 'leo.4', 50753, 'GET', '/live');
  step('Leo', 'leo.5', 51013, 'tap', '"Allow notifications"');

  // His order, and Ana making it.
  Map<String, Object?> order(String key, String item, String status) => {
    'table': 'orders',
    'key': key,
    'op': status == 'placed' ? 'insert' : 'update',
    'item': item,
    'status': status,
    'customer': key == 'o1' ? 'u188r-3' : 'u188r-2',
  };
  List<(int, String, Map<String, Object?>)> reached(String what) => [
    (1, 'reach', {'user': 'u188r-1', 'what': what}),
    (1, 'reach', {'user': 'u188r-3', 'what': what}),
  ];
  step('Leo', 'leo.6', 51231, 'tap', '"Order a cortado"');
  call(
    'Leo',
    'leo.6',
    51231,
    'POST',
    '/orders',
    status: 200,
    took: 1.8,
    caused: [
      (0, 'write', order('o1', 'Cortado', 'placed')),
      (
        0,
        'mail',
        {
          'to': 'ana@example.com',
          'subject': 'New order: Cortado for +447700900000',
        },
      ),
      ...reached('order o1 · placed'),
    ],
  );
  step('Ana', 'ana.1', 51721, 'tap', '"Preparing →"');
  call(
    'Ana',
    'ana.1',
    51722,
    'POST',
    '/orders/o1/advance',
    status: 200,
    took: 0.8,
    caused: [
      (0, 'write', order('o1', 'Cortado', 'preparing')),
      ...reached('order o1 · preparing'),
    ],
  );
  step('Ana', 'ana.2', 51944, 'tap', '"Ready →"');
  call(
    'Ana',
    'ana.2',
    51944,
    'POST',
    '/orders/o1/advance',
    status: 200,
    took: 0.7,
    caused: [
      (0, 'write', order('o1', 'Cortado', 'ready')),
      ...reached('order o1 · ready'),
      (
        1,
        'push',
        {
          'to': 'u188r-3',
          'title': 'Your cortado is ready',
          'body': 'Collect it at the counter.',
        },
      ),
    ],
  );

  // The world's actions: the script's own request, then a mail another
  // service sent, which carries no step.
  var mia = since.add(const Duration(milliseconds: 64690));
  trace.addActionStep('world.1', 'Mia orders a flat white', mia);
  for (var (after, channel, payload) in [
    (18, 'identify', {'user': 'u188r-2'}),
    (19, 'write', order('o2', 'Flat white', 'placed')),
    (
      19,
      'mail',
      {'to': 'ana@example.com', 'subject': 'New order: Flat white for Mia'},
    ),
    (20, 'reach', {'user': 'u188r-1', 'what': 'order o2 · placed'}),
    (
      20,
      'http',
      {'method': 'POST', 'path': '/orders', 'status': 200, 'ms': 2.1},
    ),
  ]) {
    trace.addServerEvent(
      'lab',
      event(64690 + after, channel, {...payload, 'step': 'world.1'}, 'rw1'),
    );
  }
  trace.addActionStep(
    'world.2',
    'The newsletter goes out',
    since.add(const Duration(milliseconds: 70203)),
  );
  trace.addServerEvent(
    'lab',
    event(70222, 'mail', {
      'from': 'newsletter',
      'to': 'ana@example.com',
      'subject': 'This week at the lab',
    }),
  );
  return trace;
}
