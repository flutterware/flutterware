import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/app_events/events.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// What the app did between two captured steps, and which step it lands on.
///
/// The buffer these exercise is the harness's in a real run; here the test is
/// the harness, which is also what a bare `flutter test` looks like to the
/// code under test.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
    appEventBuffer = AppEventBuffer();
  });
  tearDown(() {
    scenarioRunListener = null;
    appEventBuffer = null;
  });

  List<String> titles(ScenarioStepCapture capture) => [
    for (var event in capture.events) event.title,
  ];

  group('an event lands on the step that follows it', () {
    scenario('not on the one it was recorded after', (s) async {
      await s.pumpWidget(const _App());

      recordAppEvent(AppEvent.analytics('checkout_started'));
      await s.tap('Save');
    });
    tearDown(() {
      expect(titles(captures[0]), isEmpty);
      expect(titles(captures[1]), ['checkout_started']);
    });
  });

  group('the transition names the verb and its target', () {
    scenario('one entry per step', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Save');
      await s.enterText(TextField, 'hello');
      // Forced, so there is a step here whose verb is `screen` at all: left to
      // adopt, this would put its name on the `enterText` step instead.
      await s.screen('Done', force: true);
    });
    tearDown(
      () => expect(
        [for (var c in captures) '${c.verb} ${c.target ?? ''}'.trim()],
        ['pumpWidget _App', 'tap "Save"', 'enterText TextField', 'screen'],
      ),
    );
  });

  group('a screen that adopts keeps the verb that drew the frame', () {
    scenario('so the merged step still says what happened', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Save');
      await s.screen('Saved');
    });
    // Two steps, not three. The name is the author's, the verb is the line of
    // code — a comparison keys on the first and reads the second, and the
    // merged step is the one place both have ever been available at once.
    tearDown(() {
      expect(captures, hasLength(2));
      var merged = captures.last;
      expect(merged.name, 'Saved');
      expect('${merged.verb} ${merged.target}', 'tap "Save"');
    });
  });

  group('events recorded before the first step', () {
    scenario('land on it', (s) async {
      recordAppEvent(AppEvent.log('booting'));
      await s.pumpWidget(const _App());
    });
    tearDown(() => expect(titles(captures.single), ['booting']));
  });

  group('a skipped shot passes its events to the next capture', () {
    scenario('which is the next step that captures at all', (s) async {
      await s.pumpWidget(const _App(), shot: Shot.skip);
      recordAppEvent(AppEvent.log('during'));

      await s.tap('Save');
    });
    tearDown(() => expect(titles(captures.single), ['during']));
  });

  group('a screen that adopts hands its events to the step it names', () {
    scenario('rather than rolling them on to a later one', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Save');
      recordAppEvent(
        AppEvent.request(method: 'POST', url: '/receipt', status: 200),
      );
      await s.screen('Receipt');
      await s.tap('Save');
    });
    // The request happened on the way to the frame `Receipt` names, so it
    // belongs to `Receipt`. Rolled forward — what a non-capturing verb does
    // with its events — it would have landed on the tap after it.
    tearDown(() {
      expect(
        [for (var c in captures) c.name ?? 'auto'],
        ['auto', 'Receipt', 'auto'],
      );
      expect(titles(captures[1]), ['POST /receipt']);
      expect(titles(captures[2]), isEmpty);
    });
  });

  // A scenario's replays share one capture list, and only the test that
  // follows sees all of them — the last replay is still running when the body
  // ends for the last time.
  var branched = <ScenarioStepCapture>[];
  scenario('every branch records its own events', (s) async {
    await s.pumpWidget(const _App());
    recordAppEvent(AppEvent.log('on the shared prefix'));
    await s.tap('Save');

    await s.split({
      'left': () async {
        recordAppEvent(AppEvent.log('left only'));
        await s.screen('Left');
      },
      'right': () async {
        recordAppEvent(AppEvent.log('right only'));
        await s.screen('Right');
      },
    });
    branched = captures;
  });

  test('the split above recorded its prefix once, not once per branch', () {
    // Four steps: the two shared ones, then one per branch. The prefix's event
    // is on step 2 exactly once — the second replay walks the same positions
    // and its buffer is discarded rather than appended.
    expect(
      [for (var c in branched) c.name ?? 'auto'],
      ['auto', 'auto', 'Left', 'Right'],
    );
    expect(titles(branched[1]), ['on the shared prefix']);
    expect(titles(branched[2]), ['left only']);
    expect(titles(branched[3]), ['right only']);
  });

  scenario('the failing step carries the events that led to it', (s) async {
    await s.pumpWidget(const _App());
    recordAppEvent(AppEvent.request(method: 'POST', url: '/pay', status: 500));
    try {
      await s.tap('Nothing here');
    } on ScenarioTargetError {
      // The verb fails, the failure step captures, and the request that
      // preceded it is the reason a reader opens that step at all.
    }

    expect(captures.last.failure, isNotNull);
    expect(titles(captures.last), ['POST /pay']);
    expect(captures.last.events.single.error, isTrue);
  });

  group('an adopted screen does not carry two steps’ worth of events', () {
    scenario('the overflow is counted, like the buffer counts its own', (
      s,
    ) async {
      await s.pumpWidget(const _App());
      for (var i = 0; i < maxAppEventsPerStep; i++) {
        recordAppEvent(AppEvent.log('before $i'));
      }
      await s.tap('Save');
      for (var i = 0; i < 10; i++) {
        recordAppEvent(AppEvent.log('after $i'));
      }
      await s.screen('Saved');
    });
    // The merged step is one step and keeps one step's worth: the tap's drain
    // already filled it, so the ten the screen brings are counted rather than
    // appended.
    tearDown(() {
      var merged = captures.last;
      expect(merged.name, 'Saved');
      expect(merged.events, hasLength(maxAppEventsPerStep));
      expect(merged.eventsDropped, 10);
    });
  });

  group('events past the per-step cap', () {
    scenario('are counted, not silently lost', (s) async {
      await s.pumpWidget(const _App());
      for (var i = 0; i < maxAppEventsPerStep + 5; i++) {
        recordAppEvent(AppEvent.log('$i'));
      }
      await s.tap('Save');
    });
    tearDown(() {
      expect(captures.last.events, hasLength(maxAppEventsPerStep));
      expect(captures.last.eventsDropped, 5);
    });
  });

  testWidgets('recording outside a run is a no-op', (tester) async {
    appEventBuffer = null;
    expect(
      () => recordAppEvent(AppEvent.log('nobody is listening')),
      returnsNormally,
    );
  });

  test('a request event reads as a line, and 4xx is an error', () {
    var event = AppEvent.request(method: 'POST', url: '/login', status: 401);
    expect(event.title, 'POST /login');
    expect(event.detail, '401');
    expect(event.error, isTrue);
    expect(AppEvent.request(method: 'GET', url: '/me').error, isFalse);
  });

  test('a query event summarises to one line and keeps the whole SQL', () {
    var event = AppEvent.query(
      sql: 'SELECT *\nFROM items\nWHERE id = ?',
      args: [42],
      rows: 1,
    );
    // Folded, not cut at the first newline: that titled every
    // hand-formatted statement `SELECT …` and told a reader nothing.
    expect(event.title, 'SELECT * FROM items WHERE id = ?');
    expect(event.detail, '1 row');
    expect(event.body, contains('WHERE id = ?'));
    expect(event.data, {
      'args': [42],
    });
  });

  test('a payload the encoder cannot take does not break the artifact', () {
    // A fake reports whatever it had in hand, and a channel's decoded
    // arguments are whatever the plugin sent. The harness writes these with a
    // `toEncodable` fallback for exactly this reason: a value JSON cannot take
    // must degrade to what it prints as, never throw out of the step listener
    // that was only describing it.
    var event = AppEvent.custom(
      channel: 'network',
      title: 'GET /me',
      data: {'when': DateTime(2026), 'who': Object()},
    );
    expect(
      () => jsonEncode([event.toJson()], toEncodable: (value) => '$value'),
      returnsNormally,
    );
    expect(() => jsonEncode([event.toJson()]), throwsA(anything));
  });

  test('an oversized body is truncated with a marker', () {
    var event = AppEvent.custom(
      channel: 'network',
      title: 'GET /big',
      body: 'x' * 5000,
    );
    var body = event.toJson()['body']! as String;
    expect(body, contains('more characters'));
    expect(body.length, lessThan(5000));
  });

  group('a folded title is what makes a db event legible', () {
    /// The shape a formatter produces and a person reads: the keyword alone
    /// on the first line. It titled `select …` and nothing else.
    var handWritten = [
      'select',
      '  t.*,',
      '  count(te.id) as error_count',
      'from task as t',
      'left join task_error as te',
      '  on t.id = te.task_id',
      'where t.completed_at is null',
    ].join('\n');

    test('the statement reads, rather than its first keyword', () {
      expect(
        AppEvent.query(sql: handWritten).title,
        'select t.*, count(te.id) as error_count from task as t '
        'left join task_error as te on t.id = te.task_id '
        'where t.completed_at is null',
      );
    });

    test('two hand-formatted statements no longer share a title', () {
      // The one with teeth. The comparison channel keys an event on its
      // channel and its title, so while every multi-line `select` titled
      // `select …` they were one key — and a branch that swapped one query
      // for another reported no difference at all.
      var tasks = AppEvent.query(sql: handWritten).title;
      var users = AppEvent.query(
        sql: 'select\n  u.id,\n  u.email\nfrom users as u',
      ).title;

      expect(tasks, isNot(users));
    });

    test('the literals stay — a title is read, not only grouped', () {
      expect(
        AppEvent.query(sql: 'select * from t\nwhere version >= 3').title,
        endsWith('version >= 3'),
        reason: "blanking them is normalizeSql's job, and that is for grouping",
      );
    });

    test('a statement already on one line is unchanged', () {
      expect(
        AppEvent.query(sql: 'SELECT "id" FROM "task" WHERE "id" = (?1)').title,
        'SELECT "id" FROM "task" WHERE "id" = (?1)',
      );
    });

    test('leading and trailing whitespace goes', () {
      expect(AppEvent.query(sql: '\n  SELECT 1\n  ').title, 'SELECT 1');
    });

    test('a title too long for the wire is still capped', () {
      var wide = 'select ${List.filled(200, 'column_name').join(', ')} from t';
      var json = AppEvent.query(sql: wide).toJson();

      expect((json['title']! as String).length, lessThan(360));
      expect(json['title'], contains('more characters'));
      expect(json['body'], wide, reason: 'the whole statement is still here');
    });
  });
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(onPressed: () {}, child: const Text('Save')),
          const TextField(),
        ],
      ),
    ),
  );
}
