import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware_app/src/run/connection.dart';
import 'package:flutterware_app/src/run/flag_memory.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/panels_tab.dart';
import 'package:flutterware_app/src/run/run_sources.dart';
import 'package:vm_service/vm_service.dart';

/// A real [VmServiceTransport] serving a real [Panels] registry, reached over a
/// real [VmService] client. Only `registerExtension` and `postEvent` are faked
/// — the halves under test meet on the wire.
class _FakeApp {
  _FakeApp() {
    core = InspectorCore(identity: () => {'name': 'demo'});
    panels = Panels(core);
    transport = VmServiceTransport(
      core: core,
      postEvent: (kind, data) => _notify(kind, data),
    );
    service = VmService(_toClient.stream, _onRequest);
  }

  late final InspectorCore core;
  late final Panels panels;
  late final VmServiceTransport transport;
  late final VmService service;
  final _toClient = StreamController<String>();

  void _onRequest(String message) {
    var request = jsonDecode(message) as Map<String, Object?>;
    var id = request['id'];
    var method = request['method']! as String;
    var params = (request['params'] as Map?)?.cast<String, Object?>() ?? {};
    if (method == 'streamListen') {
      _reply({
        'id': id,
        'result': {'type': 'Success'},
      });
      return;
    }
    if (method == channelExtension) {
      var args = <String, String>{
        for (var entry in params.entries)
          if (entry.key != 'isolateId') entry.key: '${entry.value}',
      };
      transport.exchange(args).then((r) => _reply({'id': id, 'result': r}));
      return;
    }
    _reply({
      'id': id,
      'error': {'code': -32601, 'message': 'no $method', 'data': {}},
    });
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
    if (_toClient.isClosed) return;
    _toClient.add(jsonEncode(message));
  }

  Future<void> dispose() async {
    await _toClient.close();
    await service.dispose();
  }
}

void main() {
  late Directory dir;
  late _FakeApp app;
  late FlagMemory memory;
  late bool enabled;

  var handle = RunHandle(
    worktree: '/repo',
    worktreeName: '~',
    device: 'macos',
    entrypoint: 'lib/main.dart',
    launcherPid: 1,
    startedAt: DateTime(2026, 8, 11),
    vmService: 'ws://fake/ws',
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fw-panels-tab-');
    memory = FlagMemory(dir.path);
    app = _FakeApp();
    enabled = false;
    app.panels
        .add('flags', 'Feature flags')
        .knob(
          const KnobDescriptor(
            name: 'newCheckout',
            kind: KnobKind.boolean,
            value: false,
            defaultValue: false,
          ),
          read: () => enabled,
          write: (value) => enabled = value == true,
        );
  });

  tearDown(() async {
    await app.dispose();
    dir.deleteSync(recursive: true);
  });

  /// A wire round trip the app started, then the frames it causes.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelsTab(
            handle: handle,
            memory: memory,
            channels: LiveRunChannels(
              connect: (_) =>
                  RunConnection.forTesting(app.service, 'isolates/1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the app own panel is listed and rendered', (tester) async {
    await pump(tester);

    expect(find.text('Controls'), findsOneWidget);
    expect(find.text('newCheckout'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  /// A panel is not only declared at startup. `AddDevbarPanel` serves one
  /// for as long as a subtree is mounted, so an app signing in halfway through
  /// a run grows a panel while the cockpit is looking at it. Nothing pushes
  /// the panel itself: the app announces that its list moved and the tab
  /// re-reads it.
  testWidgets('a panel the app adds mid-run appears, and going takes it away', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Database'), findsNothing);

    app.panels
        .add('db:main', 'Database')
        .action(const PluginAction('query', 'Run a query'), (_) => {});
    // The app announced that its list moved; the tab's re-read is a round trip
    // over the wire, which needs the real event loop rather than more frames.
    await settle(tester);

    // Two panels now, so the strip that chooses between them is there too.
    expect(find.text('Database'), findsOneWidget);
    expect(find.text('Feature flags'), findsOneWidget);

    app.panels.remove('db:main');
    await settle(tester);

    expect(find.text('Database'), findsNothing);
    // The one that is left is showing, rather than a pane for a panel that
    // signed out.
    expect(find.text('newCheckout'), findsOneWidget);
  });

  testWidgets('toggling a knob reaches the app and is remembered as a wish', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(enabled, isTrue, reason: 'the app holds it');
    expect(memory.wishes(FlagMemory.keyFor(handle)), {
      'newCheckout': true,
    }, reason: 'and the host remembers it for the next run');
  });

  /// The other half of Decision 4: what the host remembered is pushed before
  /// anything is read, so the first list already shows it.
  testWidgets('a remembered wish is applied on attach', (tester) async {
    // A flag nothing has declared: only `preset` can carry it.
    var seen = <String, Object?>{};
    app.panels['flags']!.action(
      const PluginAction(
        'preset',
        'Pre-set',
        parameters: [
          ActionParameter('name', 'Name'),
          ActionParameter('value', 'Value'),
        ],
      ),
      (args) {
        seen = args;
        return {'preset': args['name']};
      },
    );
    memory.wish(FlagMemory.keyFor(handle), 'notYetDeclared', true);

    await pump(tester);

    expect(seen['name'], 'notYetDeclared');
  });

  testWidgets('every knob the app showed is remembered for next time', (
    tester,
  ) async {
    await pump(tester);

    expect(memory.seen(FlagMemory.keyFor(handle)).single.name, 'newCheckout');
  });

  testWidgets('an app with no channels says so instead of spinning', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PanelsTab(
            handle: handle,
            memory: memory,
            channels: LiveRunChannels(
              connect: (_) => Future.error(StateError('no vm service')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('not reporting'), findsOneWidget);
  });
}
