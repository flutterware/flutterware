import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/world/guest_steps.dart';
import 'package:flutterware/src/world/step_http.dart';
import 'package:flutterware/src/world/step_names.dart';

void main() {
  group('step names', () {
    test('are the person, made fit for a header', () {
      expect(worldStepPrefix('Ben'), 'ben');
      expect(worldStepPrefix('Dr Kay'), 'dr-kay');
      expect(worldStepPrefix('  Zoë!'), 'zo');
      expect(worldStepPrefix('—'), 'guest');
    });

    test('say whose a step is', () {
      expect(worldStepOwner('ben.3'), 'ben');
      expect(worldStepOwner('dr-kay.12'), 'dr-kay');
      expect(worldStepOwner('s12'), isNull);
    });
  });

  group('dispatch', () {
    late List<(String, Map<String, Object?>)> reported;
    late WorldSteps steps;
    Object? tappedIn;

    setUp(() {
      reported = [];
      tappedIn = null;
      steps = WorldSteps(
        person: 'Ben',
        report: (channel, payload) => reported.add((channel, payload)),
      );
    });

    Future<Offset> pumpButton(WidgetTester tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: GestureDetector(
              onTap: () => tappedIn = Zone.current[worldStepKey],
              child: const Text('Order'),
            ),
          ),
        ),
      );
      return tester.getCenter(find.text('Order'));
    }

    void send(PointerEvent event) =>
        steps.dispatch(event, GestureBinding.instance.handlePointerEvent);

    testWidgets('a tap runs in its step and is named by what it hit', (
      tester,
    ) async {
      var at = await pumpButton(tester);
      send(PointerDownEvent(position: at));
      send(PointerUpEvent(position: at));
      expect(tappedIn, 'ben.1');
      var (channel, payload) = reported.single;
      expect(channel, worldStepsChannel);
      expect(payload, {'step': 'ben.1', 'verb': 'tap', 'target': '"Order"'});

      send(PointerDownEvent(position: at));
      send(PointerUpEvent(position: at));
      expect(tappedIn, 'ben.2');
    });

    testWidgets('a held press is a long press, a moved one a drag', (
      tester,
    ) async {
      var at = await pumpButton(tester);
      send(PointerDownEvent(position: at));
      send(PointerUpEvent(position: at, timeStamp: const Duration(seconds: 1)));
      send(PointerDownEvent(position: at));
      send(PointerMoveEvent(position: at + const Offset(0, 60)));
      send(PointerUpEvent(position: at + const Offset(0, 60)));
      expect(
        [for (var (_, payload) in reported) payload['verb']],
        ['longPress', 'drag'],
      );
    });

    testWidgets('a second finger belongs to the step the first began', (
      tester,
    ) async {
      var at = await pumpButton(tester);
      send(PointerDownEvent(position: at));
      send(PointerDownEvent(pointer: 1, position: at + const Offset(40, 0)));
      send(PointerUpEvent(position: at));
      expect(reported, isEmpty);
      send(PointerUpEvent(pointer: 1, position: at + const Offset(40, 0)));
      expect([for (var (_, payload) in reported) payload['step']], ['ben.1']);
    });

    testWidgets('after a step, a request with none joins it for a while', (
      tester,
    ) async {
      expect(steps.stepFor(), isNull);
      var at = await pumpButton(tester);
      send(PointerDownEvent(position: at));
      send(PointerUpEvent(position: at));
      expect(steps.stepFor(), ('ben.1', 'window'));
      expect(runZoned(steps.stepFor, zoneValues: {worldStepKey: 'ben.9'}), (
        'ben.9',
        'zone',
      ));

      var brief = WorldSteps(person: 'Ben', window: Duration.zero)
        ..dispatch(PointerDownEvent(position: at), (_) {})
        ..dispatch(PointerUpEvent(position: at), (_) {});
      expect(brief.stepFor(), isNull);
    });

    testWidgets('a delivery is the next step: what it runs is in it, and '
        'what follows joins it', (tester) async {
      var at = await pumpButton(tester);
      send(PointerDownEvent(position: at));
      send(PointerUpEvent(position: at));
      var typedIn = steps.deliver(
        'type',
        'the code from the SMS',
        (step) => (step, Zone.current[worldStepKey]),
      );
      expect(typedIn, ('ben.2', 'ben.2'));
      expect(reported.last.$2, {
        'step': 'ben.2',
        'verb': 'type',
        'target': 'the code from the SMS',
      });
      // A link arrives on the plugin's own stream, outside the step: what it
      // starts joins the delivery, not the tap before it.
      expect(steps.stepFor(), ('ben.2', 'window'));
    });
  });

  group('requests', () {
    late HttpServer server;
    late List<String?> headers;

    setUp(() async {
      headers = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        headers.add(request.headers.value(worldStepHeader));
        await request.response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = null;
      await server.close(force: true);
    });

    test('carry their step in the header, and are reported with it', () async {
      var reported = <Map<String, Object?>>[];
      WorldSteps(
        person: 'Ben',
        report: (channel, payload) {
          if (channel == worldRequestsChannel) reported.add(payload);
        },
      ).install();
      var url = Uri.parse('http://127.0.0.1:${server.port}/orders');

      Future<void> get() async {
        var client = HttpClient();
        try {
          await (await client.getUrl(url)).close();
        } finally {
          client.close();
        }
      }

      await get();
      await runZoned(get, zoneValues: {worldStepKey: 'ben.4'});
      expect(headers, [null, 'ben.4']);
      expect(reported, [
        {
          'step': 'ben.4',
          'method': 'GET',
          'url': '127.0.0.1:${server.port}/orders',
          'how': 'zone',
        },
      ]);
    });

    test("a world script's requests carry the step of the action they run "
        'under, and only that', () async {
      HttpOverrides.global = StepStamping(StepStamping.zoneStep);
      var url = Uri.parse('http://127.0.0.1:${server.port}/orders');
      Future<void> post() async {
        var client = HttpClient();
        try {
          await (await client.postUrl(url)).close();
        } finally {
          client.close();
        }
      }

      await post();
      await runZoned(post, zoneValues: {worldStepKey: 'world.2'});
      await post();
      expect(headers, [null, 'world.2', null]);
    });
  });
}
