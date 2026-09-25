import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/world/protocol.dart';
import 'package:flutterware/world.dart';

/// An owner on the other end of [World.serve]: sends what it is told to and
/// keeps every message the script sends.
class _Owner {
  final _input = StreamController<String>();
  final messages = <Map<String, Object?>>[];
  final _arrived = StreamController<Map<String, Object?>>.broadcast();

  Future<void> serve(FutureOr<void> Function(World w) body) =>
      World.serve(_input.stream, (line) {
        var message = decodeWorldMessage(line);
        messages.add(message);
        _arrived.add(message);
      }, body);

  void send(String type, [Map<String, Object?> fields = const {}]) =>
      _input.add(encodeWorldMessage(type, fields));

  Future<Map<String, Object?>> next(String type) async {
    for (var message in messages) {
      if (message['type'] == type) return message;
    }
    return _arrived.stream.firstWhere((message) => message['type'] == type);
  }

  List<Map<String, Object?>> of(String type) => [
    for (var message in messages)
      if (message['type'] == type) message,
  ];
}

void main() {
  test('declares people as the script makes them, then is set up', () async {
    var owner = _Owner();
    var served = owner.serve((w) async {
      w.progress('Starting the server');
      w.person(
        'Ana',
        email: w.email('Ana Lopez'),
        app: const Launch('Shop', knobs: {'port': 8090, 'staff': true}),
        on: const Studio(Devices.iPad),
      );
      w.person('Leo', phone: w.phone());
    });
    owner.send(WorldMessage.open);
    var hello = await owner.next(WorldMessage.hello);
    await owner.next(WorldMessage.setUp);

    var id = hello['id']! as String;
    expect(id, hasLength(6));
    var [ana, leo] = [
      for (var message in owner.of(WorldMessage.person))
        personFromJson(message),
    ];
    expect(ana.email, 'ana.lopez.$id@example.com');
    expect(ana.app!.entrypoint, 'Shop');
    expect(ana.app!.knobs, {'port': 8090, 'staff': true});
    expect((ana.on as Studio).device, same(Devices.iPad));
    expect(leo.phone, matches(RegExp(r'^\+447700900\d{3}$')));
    expect(leo.app, isNull);

    owner.send(WorldMessage.close);
    await served;
    expect(owner.messages.last['type'], WorldMessage.closed);
  });

  test('a knob answers what the world was opened with', () async {
    var owner = _Owner();
    String? language;
    String? network;
    var served = owner.serve((w) {
      language = w.knob('language', options: ['en', 'fr'], initial: 'en');
      network = w.knob('network', initial: 'online');
    });
    owner.send(WorldMessage.open, {
      'knobs': {'language': 'fr'},
    });
    await owner.next(WorldMessage.setUp);
    expect(language, 'fr');
    expect(network, 'online');
    expect(owner.of(WorldMessage.knob).first, {
      'type': WorldMessage.knob,
      'name': 'language',
      'value': 'fr',
      'options': ['en', 'fr'],
    });
    owner.send(WorldMessage.close);
    await served;
  });

  test('a body that throws reports it, and still closes', () async {
    var owner = _Owner();
    var closed = false;
    var served = owner.serve((w) {
      w.onClose(() => closed = true);
      throw StateError('the server did not start');
    });
    owner.send(WorldMessage.open);
    var failed = await owner.next(WorldMessage.failed);
    expect(failed['error'], contains('the server did not start'));
    owner.send(WorldMessage.close);
    await served;
    expect(closed, isTrue);
  });

  test(
    'onClose runs last first, and a failing one does not stop the rest',
    () async {
      var owner = _Owner();
      var order = <String>[];
      var served = owner.serve((w) {
        w.onClose(() => order.add('server'));
        w.onClose(() => throw StateError('boom'));
        w.onClose(() => order.add('users'));
      });
      owner.send(WorldMessage.open);
      await owner.next(WorldMessage.setUp);
      owner.send(WorldMessage.close);
      await served;
      expect(order, ['users', 'server']);
      expect(
        owner.of(WorldMessage.progress).single['message'],
        contains('boom'),
      );
    },
  );

  test('an action reports progress, ends, and can be cancelled', () async {
    var owner = _Owner();
    var served = owner.serve((w) {
      w.action('Order a flat white', (run) {
        run.progress('Ordering', fraction: 0.5);
      });
      w.action('Walk to the shop', (run) => run.whenCancelled);
    });
    owner.send(WorldMessage.open);
    await owner.next(WorldMessage.setUp);
    expect(
      [for (var a in owner.of(WorldMessage.action)) a['name']],
      ['Order a flat white', 'Walk to the shop'],
    );

    owner.send(WorldMessage.invoke, {'action': 'Order a flat white', 'run': 1});
    expect(await owner.next(WorldMessage.actionEnded), {
      'type': WorldMessage.actionEnded,
      'run': 1,
    });
    expect(owner.of(WorldMessage.actionProgress).single, {
      'type': WorldMessage.actionProgress,
      'run': 1,
      'message': 'Ordering',
      'fraction': 0.5,
    });

    owner.send(WorldMessage.invoke, {'action': 'Walk to the shop', 'run': 2});
    owner.send(WorldMessage.cancel, {'run': 2});
    await owner._arrived.stream.firstWhere(
      (m) => m['type'] == WorldMessage.actionEnded && m['run'] == 2,
    );

    owner.send(WorldMessage.invoke, {'action': 'Fly', 'run': 3});
    var unknown = await owner._arrived.stream.firstWhere(
      (m) => m['type'] == WorldMessage.actionEnded && m['run'] == 3,
    );
    expect(unknown['error'], contains('no action "Fly"'));

    owner.send(WorldMessage.close);
    await served;
  });

  test('ready completes when the owner says every app is up', () async {
    var owner = _Owner();
    var ready = false;
    var served = owner.serve((w) async {
      await w.ready;
      ready = true;
    });
    owner.send(WorldMessage.open);
    await owner.next(WorldMessage.hello);
    expect(ready, isFalse);
    owner.send(WorldMessage.ready);
    await owner.next(WorldMessage.setUp);
    expect(ready, isTrue);
    owner.send(WorldMessage.close);
    await served;
  });

  test('two people with one name are refused', () async {
    var owner = _Owner();
    var served = owner.serve((w) {
      w.person('Ana');
      w.person('Ana');
    });
    owner.send(WorldMessage.open);
    var failed = await owner.next(WorldMessage.failed);
    expect(failed['error'], contains('Two people have this name'));
    owner.send(WorldMessage.close);
    await served;
  });

  test('a knob value an app cannot take is refused by name', () async {
    var owner = _Owner();
    var served = owner.serve((w) {
      w.person('Ana', app: Launch('Shop', knobs: {'when': DateTime(2026)}));
    });
    owner.send(WorldMessage.open);
    var failed = await owner.next(WorldMessage.failed);
    expect(failed['error'], contains("Ana's knob when"));
    owner.send(WorldMessage.close);
    await served;
  });

  test('closes when the owner goes away without a word', () async {
    var owner = _Owner();
    var closed = false;
    var served = owner.serve((w) => w.onClose(() => closed = true));
    owner.send(WorldMessage.open);
    await owner.next(WorldMessage.setUp);
    await owner._input.close();
    await served;
    expect(closed, isTrue);
  });

  test('a device the table does not have travels by its geometry', () {
    var device = const Device(
      'kiosk',
      'Kiosk',
      kind: DeviceKind.tablet,
      platform: DevicePlatform.android,
      group: 'Shop',
      width: 800,
      height: 1280,
      pixelRatio: 2,
      insetTop: 24,
    );
    var back = deviceFromJson(deviceToJson(device));
    expect(back.label, 'Kiosk');
    expect((back.width, back.height, back.pixelRatio), (800.0, 1280.0, 2.0));
    expect(back.insetTop, 24);
    expect(back.platform, DevicePlatform.android);
  });
}
