import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware_app/src/run/channel_client.dart';
import 'package:flutterware_app/src/run/panel_client.dart';
import 'package:flutterware_app/src/run/connection.dart';
import 'package:vm_service/vm_service.dart';

/// A VM that routes `ext.flutterware.channel` to a **real**
/// [VmServiceTransport] over a real [VmService] client, and delivers the app's
/// nudges on the `Extension` stream.
///
/// The point of going through the generated client rather than stubbing
/// [RunChannelClient]'s calls: what is under test is the pull-plus-nudge
/// handshake, and the halves only meet on the wire. A stub would have proved
/// that two mocks agree.
class _FakeApp {
  _FakeApp({int queueLimit = 2000}) {
    core = InspectorCore(identity: () => {'name': 'demo'});
    // The real transport, with only two things faked: `registerExtension`
    // (a `flutter test` isolate cannot re-register across tests, so the fake
    // VM calls [VmServiceTransport.serve] directly) and `postEvent`, which
    // here becomes a real `Extension` stream notification. Everything the
    // coalescing rule touches is the shipping code.
    transport = VmServiceTransport(
      core: core,
      queueLimit: queueLimit,
      postEvent: (kind, data) {
        nudges.add(data['peer']! as String);
        _notify(kind, data);
      },
    );
    service = VmService(_toClient.stream, _onRequest);
  }

  late final InspectorCore core;
  late final VmServiceTransport transport;
  late final VmService service;
  final _toClient = StreamController<String>();

  var extensionCalls = 0;

  /// Every nudge the transport posted, by peer id.
  final nudges = <String>[];

  final streamListened = <String>[];

  void _onRequest(String message) {
    var request = jsonDecode(message) as Map<String, Object?>;
    var id = request['id'];
    var method = request['method']! as String;
    var params = (request['params'] as Map?)?.cast<String, Object?>() ?? {};

    switch (method) {
      case 'streamListen':
        streamListened.add(params['streamId']! as String);
        _reply({
          'id': id,
          'result': {'type': 'Success'},
        });
      case 'getVM':
        _reply({
          'id': id,
          'result': {
            'type': 'VM',
            'name': 'vm',
            'architectureBits': 64,
            'hostCPU': 'test',
            'operatingSystem': 'test',
            'targetCPU': 'test',
            'version': '3',
            'pid': 1,
            'startTime': 0,
            'isolates': [
              {
                'type': '@Isolate',
                'id': 'isolates/1',
                'number': '1',
                'name': 'main',
                'isSystemIsolate': false,
              },
            ],
            'isolateGroups': <Object?>[],
            'systemIsolates': <Object?>[],
            'systemIsolateGroups': <Object?>[],
          },
        });
      case channelExtension:
        extensionCalls++;
        var args = <String, String>{
          for (var entry in params.entries)
            if (entry.key != 'isolateId') entry.key: '${entry.value}',
        };
        transport
            .exchange(args)
            .then((result) => _reply({'id': id, 'result': result}));
      default:
        _reply({
          'id': id,
          'error': {'code': -32601, 'message': 'no $method', 'data': {}},
        });
    }
  }

  void _notify(String kind, Map<String, Object?> data) => _reply({
    'method': 'streamNotify',
    'params': {
      'streamId': 'Extension',
      'event': {
        'type': 'Event',
        'kind': 'Extension',
        'timestamp': 0,
        'extensionKind': kind,
        'extensionData': data,
      },
    },
  });

  void _reply(Map<String, Object?> message) {
    // A real VM service drops writes to a socket nobody is holding; this fake
    // must too, or a pull still in flight when a test ends throws into the
    // next one.
    if (_toClient.isClosed) return;
    _toClient.add(jsonEncode(message));
  }

  Future<void> dispose() async {
    await _toClient.close();
    await service.dispose();
  }
}

void main() {
  late _FakeApp app;
  late RunConnection connection;

  setUp(() async {
    app = _FakeApp();
    connection = await RunConnection.forTesting(app.service, 'isolates/1');
  });

  tearDown(() async {
    await app.dispose();
  });

  Future<RunChannelClient> attach({String peer = 'gui'}) =>
      RunChannelClient.attach(connection, peer: peer);

  test('attach replays the app ring and reports its channels', () async {
    app.core.addEvent('sql', {'q': 'select 1'});
    app.core.addEvent('net', {'path': '/one'}, rid: 'r1');

    var client = await attach();
    addTearDown(client.close);

    expect(client.hello['name'], 'demo');
    expect(client.channels, ['net', 'sql']);
    expect(client.replayComplete, isTrue);
    expect(client.received.map((e) => e.channel), ['sql', 'net']);
    expect(client.received.every((e) => e.isReplay), isTrue);
    expect(client.received.last.rid, 'r1');
  });

  test(
    'the Extension stream is subscribed to once, and only on attach',
    () async {
      expect(app.streamListened, isEmpty);

      var gui = await attach(peer: 'gui');
      addTearDown(gui.close);
      var mcp = await attach(peer: 'mcp');
      addTearDown(mcp.close);

      // Once for two attachers: the subscription is per connection, and
      // `streamListen` on an already-listened stream is an error, not a no-op.
      expect(app.streamListened.where((s) => s == 'Extension'), hasLength(1));
    },
  );

  test('a nudge makes the host pull, and the live event arrives', () async {
    var client = await attach();
    addTearDown(client.close);
    var seen = <String>[];
    client.events.listen((event) => seen.add(event.channel));

    app.core.addEvent('sql', {'q': 'select 2'});
    await _until(() => seen.isNotEmpty);

    expect(seen, ['sql']);
    expect(client.received.last.isReplay, isFalse);
  });

  test(
    'a request reaches a handler in the app and the answer comes back',
    () async {
      app.core.registerHandler(
        'sql',
        'explain',
        (params) => {'plan': params['q']},
      );
      var client = await attach();
      addTearDown(client.close);

      expect(await client.request('sql', 'explain', {'q': 'select 1'}), {
        'plan': 'select 1',
      });
    },
  );

  test("an unknown method surfaces the app's refusal, not a hang", () async {
    var client = await attach();
    addTearDown(client.close);

    await expectLater(
      client.request('sql', 'nope'),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'message',
          contains('no handler for sql.nope'),
        ),
      ),
    );
  });

  test('a synchronous handler answers in the same call, with no nudge', () async {
    app.core.registerHandler(
      'sql',
      'explain',
      (params) => {'plan': params['q']},
    );
    var client = await attach();
    addTearDown(client.close);
    app.nudges.clear();

    expect(await client.request('sql', 'explain', {'q': 'x'}), {'plan': 'x'});
    // The answer rode the reply to the call that carried the question. A nudge
    // here would mean a whole extra round trip per command.
    expect(app.nudges, isEmpty);
  });

  test('an async handler answers on a later pull', () async {
    var gate = Completer<void>();
    app.core.registerHandler('slow', 'wait', (_) async {
      await gate.future;
      return {'done': true};
    });
    var client = await attach();
    addTearDown(client.close);

    var pending = client.request('slow', 'wait');
    // The call that carried the request has already returned; the answer is
    // not in it, and only the nudge brings the host back.
    gate.complete();

    expect(await pending, {'done': true});
  });

  test('two peers get their own replay and their own queue', () async {
    app.core.addEvent('sql', {'q': 'shared'});
    var gui = await attach(peer: 'gui');
    addTearDown(gui.close);
    var mcp = await attach(peer: 'mcp');
    addTearDown(mcp.close);

    expect(gui.received, hasLength(1));
    expect(mcp.received, hasLength(1));

    app.core.addEvent('sql', {'q': 'later'});
    await _until(() => gui.received.length == 2);

    // Each peer was nudged for its own queue, and neither drained the other's:
    // both see both events, which one shared queue could not have delivered
    // twice.
    expect(app.nudges, containsAll(['gui', 'mcp']));
    await _until(() => gui.received.length == 2 && mcp.received.length == 2);
    for (var client in [gui, mcp]) {
      expect(client.received.map((e) => e.payload['q']), ['shared', 'later']);
    }
  });

  test('the queue is bounded, and the hole is reported', () async {
    var app2 = _FakeApp(queueLimit: 2);
    addTearDown(app2.dispose);
    var connection2 = await RunConnection.forTesting(
      app2.service,
      'isolates/1',
    );
    var client = await RunChannelClient.attach(connection2, peer: 'gui');
    addTearDown(client.close);

    for (var i = 0; i < 5; i++) {
      app2.core.addEvent('sql', {'i': i});
    }
    await _until(() => client.dropped > 0);

    expect(client.dropped, 3);
    expect(client.received, hasLength(2));
    expect(client.received.last.payload['i'], 4);
  });

  test('a burst of events costs exactly one nudge', () async {
    var client = await attach();
    addTearDown(client.close);
    app.nudges.clear();

    for (var i = 0; i < 500; i++) {
      app.core.addEvent('sql', {'i': i});
    }

    // The whole burst, before the host got back: one nudge, not five hundred.
    // This is the property that makes it safe to share the `Extension` stream
    // with Flutter's per-frame events.
    expect(app.nudges, ['gui']);
    await _until(() => client.received.length == 500);

    // Drained — so the next event nudges again.
    app.core.addEvent('sql', {'i': 500});
    expect(app.nudges, ['gui', 'gui']);
  });

  group('panels', () {
    late RunPanels host;
    late Panel panel;
    late RunChannelClient client;

    setUp(() async {
      var panels = Panels(app.core);
      panel = panels.add('flags', 'Flags')
        ..feed(
          'changes',
          'Changes',
          fields: const [FieldDescriptor('flag', 'Flag', primary: true)],
        );
      client = await attach();
      host = RunPanels(client);
    });

    tearDown(() => client.close());

    test('the cockpit lists what the app declared', () async {
      var listed = await host.list();
      expect(listed.single.id, 'flags');
      expect(listed.single.feeds.single.fields.single.primary, isTrue);
    });

    test('a knob round-trips: read, set, read back what was kept', () async {
      var enabled = false;
      panel.knob(
        const KnobDescriptor(
          name: 'newCheckout',
          kind: KnobKind.boolean,
          value: false,
          defaultValue: false,
        ),
        read: () => enabled,
        write: (v) => enabled = v == true,
      );

      expect((await host.knobs('flags')).single.value, isFalse);
      expect(
        (await host.setKnob('flags', 'newCheckout', true)).single.value,
        isTrue,
      );
      expect(enabled, isTrue, reason: 'the app actually holds it');
      expect((await host.knobs('flags')).single.value, isTrue);
    });

    test('a state snapshot is read on demand', () async {
      var reads = 0;
      panel.state('info', 'Info', read: () => {'reads': ++reads});

      expect(await host.state('flags', 'info'), {'reads': 1});
      expect(await host.state('flags', 'info'), {'reads': 2});
    });

    test('an action runs inside the app', () async {
      Map<String, Object?>? seen;
      panel.action(const PluginAction('reset', 'Reset'), (args) {
        seen = args;
        return {'ok': true};
      });

      expect(await host.invoke('flags', 'reset', {'scope': 'all'}), {
        'ok': true,
      });
      expect(seen, {'scope': 'all'});
    });

    test("feed events arrive as live events on the panel's channel", () async {
      var seen = <String>[];
      client.events
          .where((e) => e.channel == 'flags/changes')
          .listen((e) => seen.add(e.payload['flag']! as String));

      panel.emit('changes', {'flag': 'newCheckout'});
      await _until(() => seen.isNotEmpty);

      expect(seen, ['newCheckout']);
    });

    test('a panel mounting later announces itself', () async {
      var announced = 0;
      host.changed.listen((_) => announced++);

      Panels(app.core).add('late', 'Late');
      await _until(() => announced > 0);

      expect((await host.list()).map((p) => p.id), contains('late'));
    });
  });

  test('an app that declared no panel lists none', () async {
    // Nothing made a `Panels` here, which is every app that mounts no
    // `Devbar`: the transport is installed, `panels.list` is not.
    var client = await attach();
    addTearDown(client.close);

    expect(await RunPanels(client).list(), isEmpty);
  });

  test('the app is gone: in-flight requests fail rather than hang', () async {
    var client = await attach();
    app.core.registerHandler('sql', 'explain', (_) => const {});
    await app.dispose();

    await expectLater(client.request('sql', 'explain'), throwsA(anything));
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition never became true');
}
