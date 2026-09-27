import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/server.dart';
import 'package:flutterware/src/world/protocol.dart';
import 'package:flutterware/src/world/step_names.dart';
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
        email: 'ana.${w.id}@example.com',
        app: const Launch('Shop', knobs: {'port': 8090, 'staff': true}),
        on: const Studio(Devices.iPad),
      );
      w.person('Leo', phone: '+32470000001');
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
    expect(ana.email, 'ana.$id@example.com');
    expect(ana.app!.entrypoint, 'Shop');
    expect(ana.app!.knobs, {'port': 8090, 'staff': true});
    expect((ana.on as Studio).device, same(Devices.iPad));
    expect(leo.phone, '+32470000001');
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

  test('an action runs under the step the owner named its run', () async {
    var owner = _Owner();
    var stepped = <Object?>[];
    var served = owner.serve((w) {
      w.action('Order a flat white', (run) async {
        await Future<void>.delayed(Duration.zero);
        stepped.add(Zone.current[worldStepKey]);
      });
    });
    owner.send(WorldMessage.open);
    await owner.next(WorldMessage.setUp);
    Future<void> ran(int run) => owner._arrived.stream.firstWhere(
      (m) => m['type'] == WorldMessage.actionEnded && m['run'] == run,
    );

    var first = ran(1);
    owner.send(WorldMessage.invoke, {
      'action': 'Order a flat white',
      'run': 1,
      'step': 'world.1',
    });
    await first;
    // An owner that names no step: the action runs under none.
    var second = ran(2);
    owner.send(WorldMessage.invoke, {'action': 'Order a flat white', 'run': 2});
    await second;
    expect(stepped, ['world.1', null]);

    owner.send(WorldMessage.close);
    await served;
  });

  test('an SMTP inbox reports each mail a service sends as its own, on no '
      'step', () async {
    var runDir = await Directory('/tmp').createTemp('fw_world_');
    var inspector = ServerInspector.start(
      runDir: runDir.path,
      projectRoot: runDir.path,
      name: 'world',
    );
    FlutterwareServer.debugAttachInspector(inspector);
    await inspector.published;
    addTearDown(() async {
      await FlutterwareServer.reset();
      await runDir.delete(recursive: true);
    });

    var owner = _Owner();
    late MailInbox inbox;
    var served = owner.serve((w) async {
      inbox = await w.smtp('identity');
    });
    owner.send(WorldMessage.open);
    await owner.next(WorldMessage.setUp);

    // The service, which is not Dart, sends while an action is running: its
    // mail is still nobody's step.
    await runZoned(
      () => _sendMail(inbox.port, 'leo@example.test', [
        'From: Identity <no-reply@example.test>',
        'To: leo@example.test',
        'Subject: Your sign-up code',
        '',
        'Your verification code is 48213.',
      ]),
      zoneValues: {worldStepKey: 'world.1'},
    );
    var client = await ServerAttachClient.connect(
      scanServerHandles(runDir.path).single,
    );
    addTearDown(client.close);
    await _until(() => client.received.isNotEmpty);
    var mail = client.received.single;
    expect(mail.channel, 'mail');
    expect(mail.payload, {
      'to': 'leo@example.test',
      'subject': 'Your sign-up code',
      'text': 'Your verification code is 48213.\n',
      'from': 'identity',
    });

    owner.send(WorldMessage.close);
    await served;
    // Closed with the world.
    await expectLater(
      Socket.connect('127.0.0.1', inbox.port),
      throwsA(anything),
    );
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

/// Sends one mail to an SMTP server on [port], a line at a time.
Future<void> _sendMail(int port, String to, List<String> lines) async {
  var socket = await Socket.connect('127.0.0.1', port);
  var replies = StreamIterator(
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter()),
  );
  Future<void> reply() async {
    // A multi-line reply ends on the line whose code has a space after it.
    while (await replies.moveNext()) {
      if (replies.current.length < 4 || replies.current[3] == ' ') return;
    }
  }

  await reply();
  for (var command in [
    'EHLO test',
    'MAIL FROM:<no-reply@example.test>',
    'RCPT TO:<$to>',
    'DATA',
  ]) {
    socket.write('$command\r\n');
    await reply();
  }
  socket.write('${lines.join('\r\n')}\r\n.\r\n');
  await reply();
  socket.write('QUIT\r\n');
  await reply();
  await socket.close();
}

Future<void> _until(bool Function() condition) async {
  var deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('not reached within 5s');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
