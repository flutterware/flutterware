import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/devbar.dart';
import 'package:flutterware/devbar_plugins/log_analytics.dart';
import 'package:flutterware/devbar_plugins/log_network.dart';
import 'package:flutterware/devbar_plugins/log_queries.dart';
import 'package:flutterware/devbar_plugins/logger.dart';
import 'package:flutterware/src/app_events/events.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

/// One report, two surfaces.
///
/// The app calls [recordAppEvent] once; a mounted devbar shows it on its tabs
/// and a capturing scenario shows it on the step's Events pane. These are the
/// devbar half — the scenario half is `test/scenarios/events_test.dart`.
void main() {
  tearDown(() {
    appEventBuffer = null;
  });

  Future<DevbarState> pumpDevbar(
    WidgetTester tester, {
    List<DevbarPluginFactory>? plugins,
  }) async {
    await tester.pumpWidget(
      Devbar(
        headless: true,
        plugins:
            plugins ??
            [
              LogNetworkPlugin.init(),
              LogAnalyticsPlugin.init(),
              LogQueriesPlugin.init(),
              LoggerPlugin.init(),
            ],
        child: const MaterialApp(home: Scaffold(body: Text('app'))),
      ),
    );
    await tester.pumpAndSettle();
    return Devbar.instances.single;
  }

  group('a mounted devbar hears what the app reported', () {
    testWidgets('a request lands on the Network tab', (tester) async {
      var devbar = await pumpDevbar(tester);

      recordAppEvent(
        AppEvent.request(method: 'POST', url: '/login', status: 401),
      );

      var request = devbar.network.requests.value.single;
      expect(request.httpMethod, 'POST');
      expect(request.path, '/login');
      expect(request.errorResponse?.code, 401);
      // Nothing watched this one go out, so there is no duration to show.
      expect(request.watch, isNull);
    });

    testWidgets('an analytics event lands on the Analytics tab', (
      tester,
    ) async {
      var devbar = await pumpDevbar(tester);

      recordAppEvent(
        AppEvent.analytics('sign_in', params: {'method': 'password'}),
      );

      var event = devbar.analytics.events.value.single;
      expect(event.name, 'sign_in');
      expect(event.parameters, {'method': 'password'});
    });

    testWidgets('an analytics event with no parameters has no subtitle', (
      tester,
    ) async {
      // The regression: the route always passed a map, and the tile renders
      // its subtitle on `parameters != null` — so every parameterless event
      // printed a literal "{}" under its name.
      var devbar = await pumpDevbar(tester);

      recordAppEvent(AppEvent.analytics('Open popup event'));

      expect(devbar.analytics.events.value.single.parameters, isNull);
    });

    testWidgets('a JSON body is decoded so the Response tab can show it', (
      tester,
    ) async {
      // The regression: the body went in as text, and `JsonViewer` encodes
      // what it is given — so a reported response came back as one escaped
      // line instead of the tree the same tab shows for a watched exchange.
      var devbar = await pumpDevbar(tester);

      recordAppEvent(
        AppEvent.request(
          method: 'GET',
          url: '/me',
          status: 200,
          body: '{"email":"nobody@example.com"}',
        ),
      );

      expect(devbar.network.requests.value.single.response, {
        'email': 'nobody@example.com',
      });
    });

    testWidgets('a body that is not JSON is kept as it was written', (
      tester,
    ) async {
      var devbar = await pumpDevbar(tester);

      recordAppEvent(
        AppEvent.request(
          method: 'GET',
          url: '/me',
          status: 200,
          body: '<html>gateway timeout</html>',
        ),
      );

      expect(
        devbar.network.requests.value.single.response,
        '<html>gateway timeout</html>',
      );
    });

    testWidgets('a query lands on the Queries tab, whole', (tester) async {
      var devbar = await pumpDevbar(tester);

      recordAppEvent(
        AppEvent.query(
          sql: 'SELECT *\nFROM sessions\nWHERE email = ?',
          args: ['nobody@example.com'],
          rows: 3,
        ),
      );

      var query = devbar.queries.queries.value.single;
      // The list shows one line; the dialog shows the statement entire.
      expect(query.summary, 'SELECT * FROM sessions WHERE email = ?');
      expect(query.sql, 'SELECT *\nFROM sessions\nWHERE email = ?');
      expect(query.rows, '3 rows');
      expect(query.args, ['nobody@example.com']);
      expect(query.failed, isFalse);
    });
  });

  testWidgets('a log record is not shown twice', (tester) async {
    // LoggerPlugin listens on Logger.root itself, so a reported log event must
    // not be routed to it as well — that is the whole reason the routing is
    // per-channel rather than "everything the app said".
    var devbar = await pumpDevbar(tester);
    var logger = Logger('subject');
    Logger.root.level = Level.ALL;

    var seen = <String>[];
    var unsubscribe = addAppEventListener((e) => seen.add(e.title));
    addTearDown(unsubscribe);

    // The plugin only filters while its tab is looking; nothing reaches
    // `visibles` until something listens.
    var shown = <String>[];
    var subscription = devbar.plugin<LoggerPlugin>().visibles.stream.listen(
      (records) => shown = [for (var record in records) record.message],
    );
    addTearDown(subscription.cancel);

    logger.info('one record');
    await tester.pump();

    expect(shown, ['one record']);
    // The record reached the plugin at its source, not through the report.
    expect(seen, isEmpty);
  });

  testWidgets('a channel whose plugin is absent is dropped, not thrown', (
    tester,
  ) async {
    await pumpDevbar(tester, plugins: [LogAnalyticsPlugin.init()]);

    expect(
      () => recordAppEvent(AppEvent.query(sql: 'SELECT 1')),
      returnsNormally,
    );
  });

  testWidgets('a disposed devbar stops hearing', (tester) async {
    var devbar = await pumpDevbar(tester);
    await tester.pumpWidget(const SizedBox.shrink());

    recordAppEvent(AppEvent.analytics('after'));

    expect(devbar.analytics.events.value, isEmpty);
  });

  group('a devbar torn down while its plugins are still loading', () {
    // The regression: the listener was registered in `_loadPlugins`' `finally`
    // with nothing checking the widget was still there. `dispose` had already
    // run its half of the teardown, so the registration outlived the devbar —
    // one leaked listener per mount, each routing into plugins that had been
    // disposed. A plugin factory that awaits is the ordinary case, not a
    // contrived one: the example's `VariablesPlugin.init` waits on a directory.

    Widget devbarWith(List<DevbarPluginFactory> plugins) => Devbar(
      headless: true,
      plugins: plugins,
      child: const MaterialApp(home: Scaffold(body: Text('app'))),
    );

    Future<LogAnalyticsPlugin> slowAnalytics(DevbarState devbar) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return LogAnalyticsPlugin(devbar);
    }

    testWidgets('registers no listener at all', (tester) async {
      LogAnalyticsPlugin? orphan;
      await tester.pumpWidget(
        devbarWith([(devbar) async => orphan = await slowAnalytics(devbar)]),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      recordAppEvent(AppEvent.analytics('after the devbar died'));

      expect(Devbar.instances, isEmpty);
      expect(
        orphan?.events.value ?? const [],
        isEmpty,
        reason: 'the listener outlived the devbar that registered it',
      );
    });

    testWidgets('and never routes into a plugin dispose already closed', (
      tester,
    ) async {
      // The same leak, one step worse: a plugin that *did* land in `_plugins`
      // before the teardown gets disposed, so the leaked listener wrote to a
      // closed `ValueStream` and the `StateError` came back out of the app's
      // own `recordAppEvent`.
      await tester.pumpWidget(
        devbarWith([
          LogAnalyticsPlugin.init(),
          (devbar) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return LogQueriesPlugin(devbar);
          },
        ]),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(
        () => recordAppEvent(AppEvent.analytics('into a closed stream')),
        returnsNormally,
      );
    });
  });

  group('DevbarHttpClient reports to both, and the project wires neither', () {
    test('a response fills the scenario buffer', () async {
      var buffer = appEventBuffer = AppEventBuffer();
      var client = DevbarHttpClient(
        MockClient(
          (request) async => Response(
            '{"ok":false}',
            401,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await client.post(
        Uri.parse('https://api.example.com/login'),
        headers: {'content-type': 'application/json'},
        body: '{"email":"nobody@example.com"}',
      );

      var event = buffer.drain().$1.single;
      expect(event.channel, AppChannel.network);
      expect(event.title, 'POST https://api.example.com/login');
      expect(event.detail, '401');
      expect(event.error, isTrue);
    });

    test(
      'a client that throws is reported as an error, not swallowed',
      () async {
        var buffer = appEventBuffer = AppEventBuffer();
        var client = DevbarHttpClient(
          MockClient(
            (request) async => throw const SocketException('no route'),
          ),
        );

        await expectLater(
          client.get(Uri.parse('https://api.example.com/me')),
          throwsA(isA<SocketException>()),
        );

        var event = buffer.drain().$1.single;
        expect(event.channel, AppChannel.network);
        expect(event.title, 'GET https://api.example.com/me');
        // No status — the exchange never got one — but still a problem.
        expect(event.error, isTrue);
      },
    );

    test('a listener the project registered sees it too', () async {
      // The regression: this client wrote straight to `appEventBuffer`, so it
      // was invisible to every listener except the devbar it was dodging —
      // including one a project registered for a surface of its own. It goes
      // through `recordAppEvent` now, tagged, and only the devbar skips it.
      var seen = <String>[];
      addTearDown(addAppEventListener((e) => seen.add(e.title)));

      await DevbarHttpClient(MockClient((request) async => Response('{}', 200)))
          .get(Uri.parse('https://api.example.com/me'));

      expect(seen, ['GET https://api.example.com/me']);
    });

    test('a listener may ignore it the same way the devbar does', () async {
      var seen = <String>[];
      addTearDown(
        addAppEventListener(
          (e) => seen.add(e.title),
          ignoreSource: devbarHttpClientSource,
        ),
      );

      await DevbarHttpClient(MockClient((request) async => Response('{}', 200)))
          .get(Uri.parse('https://api.example.com/me'));

      expect(seen, isEmpty);
    });

    testWidgets('the devbar gets the pair, the buffer gets one event', (
      tester,
    ) async {
      var buffer = appEventBuffer = AppEventBuffer();
      var devbar = await pumpDevbar(tester);
      var client = DevbarHttpClient(
        MockClient((request) async => Response('{}', 200)),
      );

      await client.get(Uri.parse('https://api.example.com/me'));

      // One row, not two: the client hands the devbar its own copy, so the
      // report must not be routed back into the same tab.
      var request = devbar.network.requests.value.single;
      expect(request.path, 'https://api.example.com/me');
      expect(request.watch, isNotNull, reason: 'this one was watched go out');
      expect(buffer.drain().$1, hasLength(1));
    });
  });

  group('the two surfaces are independent', () {
    testWidgets('both fill from one call', (tester) async {
      var buffer = appEventBuffer = AppEventBuffer();
      var devbar = await pumpDevbar(tester);

      recordAppEvent(AppEvent.analytics('checkout'));

      expect(devbar.analytics.events.value, hasLength(1));
      expect(buffer.drain().$1.single.title, 'checkout');
    });

    test('with no devbar, a listener-less report still reaches the buffer', () {
      var buffer = appEventBuffer = AppEventBuffer();

      recordAppEvent(AppEvent.analytics('checkout'));

      expect(buffer.drain().$1.single.title, 'checkout');
    });

    test('an unsubscribed listener hears nothing more', () {
      var seen = <String>[];
      addAppEventListener((e) => seen.add(e.title))();

      recordAppEvent(AppEvent.analytics('after'));

      expect(seen, isEmpty);
    });

    test('a listener that unsubscribes while being called does not throw', () {
      late void Function() unsubscribe;
      var seen = <String>[];
      unsubscribe = addAppEventListener((e) {
        seen.add(e.title);
        unsubscribe();
      });

      expect(() => recordAppEvent(AppEvent.analytics('once')), returnsNormally);
      expect(seen, ['once']);
    });

    test('and does not cost its neighbour the event', () {
      // The regression: walking the live list by index made the removal shift
      // the next listener into the slot just read, so it was skipped — two
      // mounted devbars, one disposing mid-report, and the survivor silently
      // missed it. Dispatch walks a copy.
      var seen = <String>[];
      late void Function() first;
      first = addAppEventListener((e) {
        seen.add('first');
        first();
      });
      var second = addAppEventListener((e) => seen.add('second'));
      var third = addAppEventListener((e) => seen.add('third'));
      addTearDown(() {
        second();
        third();
      });

      recordAppEvent(AppEvent.analytics('once'));

      expect(seen, ['first', 'second', 'third']);
    });

    test('a listener registered mid-report does not hear that same event', () {
      var seen = <String>[];
      var late = <String>[];
      var first = addAppEventListener((e) {
        seen.add('first');
        addTearDown(addAppEventListener((e) => late.add(e.title)));
      });
      addTearDown(first);

      recordAppEvent(AppEvent.analytics('once'));

      expect(seen, ['first']);
      expect(late, isEmpty, reason: 'it was not listening when this was sent');
    });

    test('a listener that throws does not reach the app', () {
      // `recordAppEvent` is documented as safe to leave in shared fakes
      // forever. A surface that breaks may not break the line reporting to it.
      var errors = <Object>[];
      var reached = false;
      var bad = addAppEventListener((e) => throw StateError('surface broke'));
      var good = addAppEventListener((e) => reached = true);
      addTearDown(() {
        bad();
        good();
      });

      runZonedGuarded(
        () => recordAppEvent(AppEvent.analytics('once')),
        (error, stack) => errors.add(error),
      );

      expect(reached, isTrue, reason: 'a later listener still gets it');
      expect(errors, hasLength(1), reason: 'and the breakage is reported');
      expect(errors.single, isA<StateError>());
    });
  });
}
