import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/world/world_timeline.dart';
import 'package:flutterware_app/src/world/web_snapshot.dart';
import 'package:flutterware_app/src/world/world_timeline_detail.dart';
import 'package:flutterware_app/src/world/world_timeline_view.dart';
import 'package:flutterware_app/src/world/world_trace.dart';

void main() {
  var since = DateTime(2026, 9, 30, 10);
  late WorldTrace trace;
  var nextId = 1;
  const people = ['Ana', 'Leo'];

  InspectorEvent at(
    int ms,
    String channel,
    Map<String, Object?> payload, [
    String? rid,
  ]) => InspectorEvent(
    channel: channel,
    id: nextId++,
    time: since.add(Duration(milliseconds: ms)),
    payload: payload,
    isReplay: false,
    rid: rid,
  );

  void app(String person, int ms, String channel, Map<String, Object?> data) =>
      trace.addGuestEvent(person, at(ms, channel, data));
  void lab(int ms, String channel, Map<String, Object?> data, [String? rid]) =>
      trace.addServerEvent('lab', at(ms, channel, data, rid));
  void tap(String person, String step, int ms, String target) => app(
    person,
    ms,
    worldStepsChannel,
    {'step': step, 'verb': 'tap', 'target': target},
  );
  void request(String person, String step, int ms, String path) =>
      app(person, ms, worldRequestsChannel, {
        'step': step,
        'method': 'POST',
        'url': 'localhost:5040$path',
        'how': 'zone',
      });

  Timeline timeline([TraceLevel level = TraceLevel.product]) => Timeline.of(
    trace.steps(limit: 100),
    people: people,
    servers: trace.servers,
    level: level,
    actions: true,
  );

  /// Each row as `from → to  label`, or `from  label` for a pill.
  List<String> rows(Timeline timeline) => [
    for (var row in timeline.rows)
      [
        row.from,
        if (row.to.isNotEmpty) '→ ${row.to.join(', ')}',
        ' ${row.label}',
      ].join(' '),
  ];

  /// Leo orders: his request, the write, a broadcast to both apps and an
  /// SMS to him, all under the request's id.
  void order() {
    tap('Leo', 'leo.1', 1000, '"Order"');
    request('Leo', 'leo.1', 1002, '/orders');
    lab(1003, 'write', {
      'table': 'orders',
      'key': 'o1',
      'op': 'insert',
      'step': 'leo.1',
    }, 'r1');
    for (var user in ['u1', 'u2']) {
      lab(1004, 'reach', {
        'user': user,
        'what': 'order o1 · placed',
        'step': 'leo.1',
      }, 'r1');
    }
    lab(1005, 'sms', {
      'to': '+447700900001',
      'body': 'Order o1 is placed',
      'step': 'leo.1',
    }, 'r1');
    lab(1006, 'http', {
      'method': 'POST',
      'path': '/orders',
      'status': 201,
      'ms': 3,
      'step': 'leo.1',
    }, 'r1');
  }

  setUp(() {
    trace = WorldTrace(since: since)
      ..addPerson('Ana', userId: 'u1')
      ..addPerson('Leo', userId: 'u2', phone: '+447700900001');
  });

  test('a column for everyone, the world first, then each part of the system '
      'as it first did something — the same at every level', () {
    order();
    var product = timeline();
    expect(
      [for (var column in product.columns) column.name],
      ['World', 'Ana', 'Leo', 'lab', 'SMS'],
    );
    expect(
      [for (var column in timeline(TraceLevel.wire).columns) column.id],
      [for (var column in product.columns) column.id],
    );
    expect(product.columns.first.id, worldActionsOwner);
    expect(product.columns[3].side, TimelineSide.system);
  });

  test('a step is a pill in its column, and what it caused is an arrow from '
      'where it came from to whom it reached', () {
    order();
    expect(rows(timeline()), [
      'Leo  taps "Order"',
      // Leo's own app catching up is not the product's.
      'system/server/lab → Ana  order o1 · placed',
      'system/sent/sms → Leo  SMS: Order o1 is placed',
    ]);
    expect(rows(timeline(TraceLevel.wire)), [
      'Leo  taps "Order"',
      'Leo → system/server/lab  POST /orders  201 in 3.0 ms',
      'system/server/lab  wrote orders/o1 (insert)',
      // One broadcast, one arrow.
      'system/server/lab → Ana, Leo  order o1 · placed',
      'system/sent/sms → Leo  SMS: Order o1 is placed',
    ]);
    var counts = timeline().counts;
    expect(counts, {
      TraceLevel.product: 3,
      TraceLevel.system: 4,
      TraceLevel.wire: 5,
    });
  });

  test("the world's own request starts in its column, and a service that "
      'only sent a message is a column of its own', () {
    trace.addActionStep(
      'world.1',
      'Mia orders',
      since.add(const Duration(seconds: 1)),
    );
    lab(1010, 'http', {
      'method': 'POST',
      'path': '/orders',
      'status': 201,
      'step': 'world.1',
    }, 'r9');
    trace.addServerEvent(
      'lab',
      at(1020, 'mail', {
        'from': 'newsletter',
        'to': 'someone@example.com',
        'subject': 'This week',
      }),
    );
    var mail = 'Mail: someone@example.com: This week, joined by time';
    expect(rows(timeline(TraceLevel.system)), [
      'world  runs "Mia orders"',
      'world → system/server/lab  POST /orders  201',
      // Nobody the world knows: a pill, saying to whom.
      'system/server/newsletter  $mail',
    ]);
  });

  test('three rows alike or more fold into the first, and unfold by their '
      'key', () {
    tap('Ana', 'ana.1', 1000, '"Refresh"');
    for (var n = 1; n <= 4; n++) {
      request('Ana', 'ana.1', 1000 + n, '/orders/o$n/seen');
      lab(1000 + n, 'http', {
        'method': 'POST',
        'path': '/orders/o$n/seen',
        'status': 204,
        'step': 'ana.1',
      }, 'r$n');
    }
    var system = timeline(TraceLevel.system);
    var entries = system.entries();
    expect(entries, hasLength(2));
    var folded = entries.last as TimelineLine;
    expect(folded.folded, isTrue);
    expect(folded.alike, hasLength(4));
    expect(folded.row.label, 'POST /orders/o1/seen  204');
    expect(folded.until, since.add(const Duration(milliseconds: 1004)));

    var unfolded = system.entries(unfolded: {folded.fold!});
    expect(unfolded, hasLength(5));
    expect(
      [for (var entry in unfolded.skip(1)) (entry as TimelineLine).fold],
      [folded.fold, null, null, null],
    );
    expect((unfolded[1] as TimelineLine).folded, isFalse);
  });

  testWidgets('the view switches level, and a column name shows only what '
      'touches it', (tester) async {
    order();
    String? focus;
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) => WorldTimelineView(
              trace: trace,
              people: people,
              colorOf: (_) => Colors.teal,
              focus: focus,
              onFocus: (column) => setState(() => focus = column),
            ),
          ),
        ),
      ),
    );
    expect(find.text('order o1 · placed'), findsOneWidget);
    expect(find.text('wrote orders/o1 (insert)'), findsNothing);

    await tester.tap(find.textContaining('Wire'));
    await tester.pump();
    expect(find.text('wrote orders/o1 (insert)'), findsOneWidget);

    await tester.tap(find.text('SMS'));
    await tester.pump();
    expect(focus, 'system/sent/sms');
    expect(find.text('Only SMS · show everything'), findsOneWidget);
    expect(find.text('wrote orders/o1 (insert)'), findsNothing);
    expect(find.text('SMS: Order o1 is placed'), findsOneWidget);

    await tester.tap(find.text('Only SMS · show everything'));
    await tester.pump();
    expect(focus, isNull);
  });

  testWidgets('a row opens onto what it was, and closes again', (tester) async {
    order();
    await tester.binding.setSurfaceSize(const Size(1300, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: WorldTimelineView(
            trace: trace,
            people: people,
            colorOf: (_) => Colors.teal,
            onFocus: (_) {},
            sources: const _NoApps(),
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('Wire'));
    await tester.pump();

    Future<void> open(String row, String head) async {
      await tester.tap(find.text(row));
      await tester.pump();
      await tester.pump();
      expect(find.text(head), findsOneWidget, reason: row);
    }

    await open('taps "Order"', 'Leo taps "Order" at 1.0 s.');
    expect(
      find.text(
        'It caused one call, one write, 2 updates and one SMS: the rows '
        'under it, in its colour.',
      ),
      findsOneWidget,
    );
    await open(
      'POST /orders  201 in 3.0 ms',
      "Leo's app called POST /orders, answered 201, 3.0 ms of it in the "
          'server.',
    );
    expect(find.text('No app in this test.'), findsOneWidget);
    await open('wrote orders/o1 (insert)', 'The lab server wrote orders/o1.');
    expect(find.text('insert'), findsOneWidget);
    await open(
      'order o1 · placed',
      'The lab server told the apps of Ana and Leo, over the connections '
          'they hold open: order o1 · placed.',
    );
    await open('SMS: Order o1 is placed', 'SMS to Leo: “Order o1 is placed”');
    expect(find.text('+447700900001 (Leo)'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(find.text('SMS to Leo: “Order o1 is placed”'), findsNothing);
  });

  test('a pause of more than two seconds is a gap, and a focus keeps what '
      'touches its column', () {
    order();
    tap('Ana', 'ana.1', 9000, '"Orders"');
    var product = timeline();
    expect(
      [
        for (var entry in product.entries())
          switch (entry) {
            TimelineGap(:var length) => 'gap ${length.inMilliseconds}',
            TimelineLine(:var row) => row.label,
          },
      ],
      [
        'taps "Order"',
        'order o1 · placed',
        'SMS: Order o1 is placed',
        'gap 7995',
        'taps "Orders"',
      ],
    );
    expect(
      [
        for (var entry in product.entries(focus: 'system/sent/sms'))
          (entry as TimelineLine).row.label,
      ],
      ['SMS: Order o1 is placed'],
    );
  });
}

/// Sources with no app to read from.
class _NoApps implements TimelineSources {
  const _NoApps();

  @override
  Future<AppRequest> request(String person, TimelineRow row) async =>
      const AppRequest.missing('No app in this test.');

  @override
  Future<WebSnapshot>? picture(OutboxMessage message) => null;
}
