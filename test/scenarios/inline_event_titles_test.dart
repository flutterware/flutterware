import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/app_events.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scenarios/harness.dart';

/// The one-line summaries that ride inline on a step.
///
/// Two jobs, and the second is why this file exists. They keep a step's
/// summary small enough to read without opening anything — and where they
/// cannot, they have to *say so*. Twelve titles handed back out of forty read
/// as "the app did twelve things", and the arithmetic that would disprove it
/// needs the `system` exclusion to be known first.
void main() {
  List<AppEvent> events(int count, {String channel = AppChannel.analytics}) => [
    for (var i = 0; i < count; i++)
      AppEvent.custom(channel: channel, title: 'event $i'),
  ];

  test('a quiet step has none at all, rather than an empty list', () {
    expect(inlineEventTitles([]), isNull);
  });

  test('the detail rides beside the title', () {
    expect(
      inlineEventTitles([
        AppEvent.request(method: 'POST', url: '/login', status: 401),
      ]),
      ['POST /login → 401'],
    );
  });

  test('system is left out — it is the volume and none of the signal', () {
    var titles = inlineEventTitles([
      AppEvent.custom(channel: AppChannel.system, title: 'flutter/textinput'),
      AppEvent.analytics('checkout'),
    ]);

    expect(titles, ['checkout']);
  });

  test('a step under the cap is handed back whole', () {
    expect(inlineEventTitles(events(12)), hasLength(12));
    expect(inlineEventTitles(events(12))!.last, 'event 11');
  });

  test('over the cap it says how many it kept back, and how to get them', () {
    var titles = inlineEventTitles(events(40))!;

    expect(titles, hasLength(13), reason: 'twelve, and the marker');
    expect(titles.take(12), everyElement(startsWith('event ')));
    expect(titles.last, '… 28 more (scenarios read events: true)');
  });

  test('the count that is marked is of the titles, not of the events', () {
    // 30 events, 20 of them system: the marker has to describe what a reader
    // would otherwise think it was seeing all of, which is the 10 that are
    // left after the exclusion — not the 30 the step recorded.
    var titles = inlineEventTitles([
      ...events(20, channel: AppChannel.system),
      ...events(18),
    ])!;

    expect(titles.last, '… 6 more (scenarios read events: true)');
  });

  group('a title too wide for a summary', () {
    /// What a folded db title looks like now: a whole statement, ordinary
    /// rather than pathological.
    var statement =
        'select t.*, count(te.id) as error_count from task as t '
        'left join task_error as te on t.id = te.task_id '
        'where t.completed_at is null and t.version >= 3';

    test('is cut, and says it was', () {
      var title = inlineEventTitles([
        AppEvent.custom(channel: AppChannel.db, title: statement),
      ])!.single;

      expect(title.length, 121, reason: '120 and the ellipsis');
      expect(title, endsWith('…'));
      expect(title, startsWith('select t.*, count(te.id) as error_count'));
    });

    test('one that fits is left exactly alone', () {
      var title = inlineEventTitles([AppEvent.analytics('checkout_started')])!
          .single;

      expect(title, 'checkout_started');
    });

    test('the detail survives the cut', () {
      // A status code is a handful of characters and most of what the line is
      // read for; losing `→ 500` to a long URL would be the wrong half to
      // drop, so the detail is appended after the cut rather than inside it.
      var title = inlineEventTitles([
        AppEvent.request(
          method: 'POST',
          url: 'https://api.example.com/${'segment/' * 40}',
          status: 500,
        ),
      ])!.single;

      expect(title, contains('…'));
      expect(title, endsWith(' → 500'));
    });

    test('the whole summary is bounded whatever the app reports', () {
      // The point of the second cap: rows times width, both known.
      var titles = inlineEventTitles([
        for (var i = 0; i < 40; i++)
          AppEvent.custom(channel: AppChannel.db, title: 'x' * 5000),
      ])!;

      expect(titles, hasLength(13));
      for (var title in titles.take(12)) {
        expect(title.length, 121);
      }
      expect(
        titles.join().length,
        lessThan(1600),
        reason: '12 × 121 plus the count marker, and nothing else is possible',
      );
    });
  });
}
