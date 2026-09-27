import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/server.dart';
import 'package:flutterware/src/server/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A run dir short enough that `srv-*.sock` stays under the 104-byte
/// `sun_path` cap — `Directory.systemTemp` on macOS is deep enough to blow it.
Future<Directory> shortTempDir() {
  var base = Directory.systemTemp;
  if (p.join(base.path, 'x' * 45).length > maxProbePathLength) {
    base = Directory('/tmp');
  }
  return base.createTemp('fw_srv_');
}

const maxProbePathLength = 90;

void main() {
  group('gates', () {
    bool enabled({bool product = false, String? env, bool runDir = true}) =>
        serverInspectionEnabled(
          product: product,
          envOverride: env,
          runDirExists: runDir,
        );

    test('JIT with a run dir is on', () {
      expect(enabled(), isTrue);
    });

    test('product builds are inert', () {
      expect(enabled(product: true), isFalse);
    });

    test('no run dir is inert, even under JIT', () {
      expect(enabled(runDir: false), isFalse);
    });

    test('FW_SERVER_INSPECT=1 overrides product and the run dir', () {
      expect(enabled(product: true, env: '1', runDir: false), isTrue);
    });

    test('FW_SERVER_INSPECT=0 wins over everything', () {
      expect(enabled(env: '0'), isFalse);
    });
  });

  group('handle names', () {
    test('are filename- and length-safe', () {
      expect(sanitizeServerName('bin/my server.dart'), 'bin-my-server-dart');
      expect(sanitizeServerName(''), 'server');
      expect(sanitizeServerName('x' * 60).length, 24);
    });

    test('scan matches by containment, not equality', () async {
      var dir = await shortTempDir();
      addTearDown(() => dir.delete(recursive: true));
      var handle = ServerHandle(
        projectRoot: '/repo/server_pkg',
        name: 'api',
        socketPath: '${dir.path}/x.sock',
        pid: 1,
        startedAt: DateTime.now(),
      );
      File(p.join(dir.path, 'srv-00000000-api-1.json'))
          .writeAsStringSync(jsonEncode(handle.toJson()));

      expect(scanServerHandles(dir.path, underRoot: '/repo'), hasLength(1));
      expect(
        scanServerHandles(dir.path, underRoot: '/repo/server_pkg'),
        hasLength(1),
      );
      expect(scanServerHandles(dir.path, underRoot: '/elsewhere'), isEmpty);
    });
  });

  group('inspector', () {
    late Directory runDir;
    late ServerInspector inspector;

    setUp(() async {
      runDir = await shortTempDir();
      inspector = ServerInspector.start(
        runDir: runDir.path,
        projectRoot: '/repo/app',
        name: 'api',
        ringSize: 5,
      );
      await inspector.published;
    });

    tearDown(() async {
      await inspector.stop();
      await FlutterwareServer.reset();
      if (runDir.existsSync()) await runDir.delete(recursive: true);
    });

    Future<ServerAttachClient> attach() async {
      var handles = scanServerHandles(runDir.path);
      expect(handles, hasLength(1));
      return ServerAttachClient.connect(handles.single);
    }

    test('publishes a handle that describes the socket', () async {
      var handle = scanServerHandles(runDir.path).single;
      expect(handle.projectRoot, '/repo/app');
      expect(handle.name, 'api');
      expect(handle.pid, pid);
      expect(File(handle.socketPath).existsSync(), isTrue);
    });

    test('replays the ring on attach, then streams live', () async {
      inspector.addEvent('http', {'path': '/one'});
      inspector.addEvent('http', {'path': '/two'}, rid: 'r1');

      var client = await attach();
      addTearDown(client.close);
      List<ServerEvent> events() => client.received;

      expect(client.hello.name, 'api');
      expect(client.hello.eventCount, 2);
      await _until(() => events().length == 2);
      expect(events()[0].payload, {'path': '/one'});
      expect(events()[0].isReplay, isTrue);
      expect(events()[1].rid, 'r1');
      expect(client.replayComplete, isTrue);

      inspector.addEvent('log', {'message': 'live'});
      await _until(() => events().length == 3);
      expect(events()[2].channel, 'log');
      expect(events()[2].isReplay, isFalse);
    });

    test('the ring drops oldest beyond its size', () async {
      for (var i = 0; i < 8; i++) {
        inspector.addEvent('http', {'i': i});
      }
      var client = await attach();
      addTearDown(client.close);
      await _until(() => client.replayComplete);
      expect(client.received, hasLength(5));
      expect(client.received.first.payload['i'], 3);
    });

    test(
      'details are held lazily, fetched by id, and evict by bytes',
      () async {
        inspector.addEvent(
          'http',
          {'path': '/big'},
          details: {'respBody': 'x' * 100},
        );
        var client = await attach();
        addTearDown(client.close);
        await _until(() => client.replayComplete);
        var id = client.received.single.id;

        expect((await client.details(id))!['respBody'], 'x' * 100);
        expect(
          await client.details(999),
          isNull,
          reason: 'never captured reads as absent, not as an error',
        );

        // A small cap: stashing more evicts the oldest.
        var tight = ServerInspector.start(
          runDir: runDir.path,
          projectRoot: '/repo/app',
          name: 'tight',
          detailsByteCap: 200,
        );
        addTearDown(tight.stop);
        await tight.published;
        tight.addEvent('http', {'i': 1}, details: {'body': 'a' * 150});
        tight.addEvent('http', {'i': 2}, details: {'body': 'b' * 150});
        var tightClient = await ServerAttachClient.connect(
          scanServerHandles(runDir.path).singleWhere((h) => h.name == 'tight'),
        );
        addTearDown(tightClient.close);
        await _until(() => tightClient.replayComplete);
        var ids = [for (var e in tightClient.received) e.id];
        expect(await tightClient.details(ids[0]), isNull, reason: 'evicted');
        expect((await tightClient.details(ids[1]))!['body'], 'b' * 150);
      },
    );

    test('requests reach handlers; unknown methods answer with err', () async {
      inspector.registerHandler('sql', 'explain', (params) {
        return {'plan': 'SCAN ${params['table']}'};
      });
      var client = await attach();
      addTearDown(client.close);

      var response = await client.request('sql', 'explain', {'table': 'users'});
      expect(response, {'plan': 'SCAN users'});

      expect(
        () => client.request('sql', 'nope'),
        throwsA(isA<ServerRequestException>()),
      );
    });

    test('a handler throwing answers err, not a dead socket', () async {
      inspector.registerHandler('sql', 'explain', (_) {
        throw StateError('no such table');
      });
      var client = await attach();
      addTearDown(client.close);
      await expectLater(
        () => client.request('sql', 'explain'),
        throwsA(
          isA<ServerRequestException>().having(
            (e) => e.message,
            'message',
            contains('no such table'),
          ),
        ),
      );
      // The connection survived the failed request.
      inspector.addEvent('http', {'path': '/after'});
      await _until(() => client.replayComplete);
    });

    test('a knock — connect and close without attaching — is free', () async {
      var handle = scanServerHandles(runDir.path).single;
      var probe = await Socket.connect(
        InternetAddress(handle.socketPath, type: InternetAddressType.unix),
        0,
      );
      probe.write('garbage that is not json\n');
      await probe.flush();
      probe.destroy();

      // The server still accepts a real attachment afterwards.
      var client = await attach();
      addTearDown(client.close);
      expect(client.hello.pid, pid);
    });

    test('a peer that asks to attach and hangs up before the answer costs '
        'the server nothing', () async {
      FlutterwareServer.debugAttachInspector(inspector);
      // Enough history that the replay is still being written when the
      // write finds the peer gone.
      for (var n = 0; n < 5; n++) {
        FlutterwareServer.event('http', {'path': '/${'x' * 20000}$n'});
      }
      var handle = scanServerHandles(runDir.path).single;
      for (var n = 0; n < 20; n++) {
        var peer = await Socket.connect(
          InternetAddress(handle.socketPath, type: InternetAddressType.unix),
          0,
        );
        peer.write(
          encodeFrame({
            frameChannel: metaChannel,
            frameType: typeRequest,
            frameMethod: metaAttach,
            frameRequestId: 1,
          }),
        );
        await peer.flush();
        peer.destroy();
      }
      // Let every broken write land where it lands.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      var client = await attach();
      addTearDown(client.close);
      expect(client.hello.pid, pid);
    });

    test('stop deletes the handle and the socket', () async {
      var handle = scanServerHandles(runDir.path).single;
      await inspector.stop();
      expect(scanServerHandles(runDir.path), isEmpty);
      expect(File(handle.socketPath).existsSync(), isFalse);
    });

    test(
      'a dead handle is deleted on the way past by attachToServer',
      () async {
        var dead = ServerHandle(
          projectRoot: '/repo/app',
          name: 'gone',
          socketPath: p.join(runDir.path, 'srv-dead.sock'),
          pid: 999999,
          startedAt: DateTime.now(),
          handlePath: p.join(runDir.path, 'srv-00000000-gone-999999.json'),
        );
        File(dead.handlePath!).writeAsStringSync(jsonEncode(dead.toJson()));

        expect(await attachToServer(dead), isNull);
        expect(File(dead.handlePath!).existsSync(), isFalse);
      },
    );

    test('a mute listener keeps its handle — slow is not dead', () async {
      // Accepts the connection and never answers the hello: what a live
      // server swamped past the handshake window looks like. Deleting its
      // handle here is what once made a busy server vanish from every list
      // until restart.
      var socketPath = p.join(runDir.path, 'srv-mute.sock');
      var mute = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(mute.close);
      mute.listen((socket) {});

      var busy = ServerHandle(
        projectRoot: '/repo/app',
        name: 'mute',
        socketPath: socketPath,
        pid: 999999,
        startedAt: DateTime.now(),
        handlePath: p.join(runDir.path, 'srv-00000000-mute-999999.json'),
      );
      File(busy.handlePath!).writeAsStringSync(jsonEncode(busy.toJson()));

      bool? reportedDeleted;
      var client = await attachToServer(
        busy,
        timeout: const Duration(milliseconds: 300),
        onFailure: (_, {required bool deleted}) => reportedDeleted = deleted,
      );
      expect(client, isNull);
      expect(reportedDeleted, isFalse);
      expect(File(busy.handlePath!).existsSync(), isTrue);
    });

    test('activation cleans up a dead predecessor of the same server', () async {
      var stale = ServerHandle(
        projectRoot: '/repo/app',
        name: 'api',
        socketPath: p.join(runDir.path, 'stale.sock'),
        pid: 999999,
        startedAt: DateTime.now(),
      );
      var stalePath = p.join(
        runDir.path,
        '${serverHandleBaseName(projectRoot: '/repo/app', name: 'api', pid: 999999)}.json',
      );
      File(stalePath).writeAsStringSync(jsonEncode(stale.toJson()));

      var successor = ServerInspector.start(
        runDir: runDir.path,
        projectRoot: '/repo/app',
        name: 'api',
      );
      addTearDown(successor.stop);
      await successor.published;

      expect(File(stalePath).existsSync(), isFalse);
      // The still-answering sibling (`inspector` from setUp, same name but a
      // live socket) must not be touched — pid differs, but it answers.
      expect(scanServerHandles(runDir.path).map((h) => h.pid), contains(pid));
    });
  });

  group('primitives', () {
    late Directory runDir;
    late ServerInspector inspector;

    setUp(() async {
      runDir = await shortTempDir();
      inspector = ServerInspector.start(
        runDir: runDir.path,
        projectRoot: '/repo/app',
        name: 'api',
      );
      FlutterwareServer.debugAttachInspector(inspector);
      await inspector.published;
    });

    tearDown(() async {
      await FlutterwareServer.reset();
      if (runDir.existsSync()) await runDir.delete(recursive: true);
    });

    Future<List<ServerEvent>> replayed() async {
      var client = await ServerAttachClient.connect(
        scanServerHandles(runDir.path).single,
      );
      addTearDown(client.close);
      await _until(() => client.replayComplete);
      return client.received;
    }

    test('span times the body and stamps the zone correlation id', () async {
      var result = await runZoned(
        () => FlutterwareServer.span('sql', {'query': 'select 1'}, () async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 42;
        }),
        zoneValues: {FlutterwareServer.requestIdKey: 'req-7'},
      );
      expect(result, 42);

      var events = await replayed();
      expect(events, hasLength(1));
      expect(events.single.rid, 'req-7');
      expect(events.single.payload['query'], 'select 1');
      expect(events.single.payload['ms'], greaterThan(1));
    });

    test('work handed off keeps the step it was queued under', () async {
      // A request queues a job, keeping the step with it; the job runs later,
      // outside the request's zone, and re-enters the step.
      String? queued;
      runZoned(
        () => queued = FlutterwareServer.step,
        zoneValues: {FlutterwareServer.stepKey: 'ana.3'},
      );
      expect(queued, 'ana.3');
      expect(FlutterwareServer.step, isNull);

      FlutterwareServer.inStep(queued, () {
        FlutterwareServer.event('write', {'table': 'jobs', 'key': 'j1'});
      });
      FlutterwareServer.inStep(null, () {
        FlutterwareServer.event('write', {'table': 'jobs', 'key': 'j2'});
      });

      var events = await replayed();
      expect(events.map((e) => e.payload['step']), ['ana.3', null]);
    });

    test('a job runs under the step that queued it, as a request of its '
        'own, and says when it started and ended', () async {
      var result = await FlutterwareServer.job(
        'thumbnail',
        () async {
          FlutterwareServer.event('write', {'table': 'files', 'key': 'f1'});
          return 'done';
        },
        step: 'ana.3',
        id: 54,
        queue: 'jobs',
      );
      expect(result, 'done');
      await expectLater(
        FlutterwareServer.job('resize', () => throw StateError('no file')),
        throwsStateError,
      );

      var events = await replayed();
      var [started, write, ended, failedStart, failed] = events;
      expect(started.payload, {
        'name': 'thumbnail',
        'id': '54',
        'queue': 'jobs',
        'step': 'ana.3',
      });
      expect((write.rid, write.payload['step']), (started.rid, 'ana.3'));
      expect(ended.rid, started.rid);
      expect(ended.payload['ms'], isA<double>());
      // A second job is a request of its own, and says what it threw.
      expect(failed.rid, allOf(failedStart.rid, isNot(started.rid)));
      expect(failed.payload['error'], contains('no file'));
    });

    test(
      'a reloadable handler is built again on reassemble, from the code '
      'it has then; a build that throws leaves the last one serving',
      () async {
        // A reload changes the code; the test changes what the build reads.
        var version = 1;
        var builds = 0;
        String Function(String) routes() {
          builds++;
          var built = version;
          if (built == 3) throw StateError('routes do not build');
          return (path) => '$path v$built';
        }

        var handler = FlutterwareServer.reloadable(routes);
        expect(handler('/health'), '/health v1');
        version = 2;
        expect(await FlutterwareServer.reassemble(), isEmpty);
        expect(handler('/health'), '/health v2');
        version = 3;
        expect(
          (await FlutterwareServer.reassemble()).single,
          isA<StateError>(),
        );
        expect(handler('/health'), '/health v2');
        expect(builds, 3);
      },
    );

    test('onReassemble runs each callback in turn, awaited, after one that '
        'throws too', () async {
      var ran = <String>[];
      FlutterwareServer.onReassemble(() async {
        await Future<void>.delayed(Duration.zero);
        ran.add('dispose the old app, build the new one');
      });
      FlutterwareServer.onReassemble(() => throw StateError('bad routes'));
      FlutterwareServer.onReassemble(() => ran.add('after'));
      var errors = await FlutterwareServer.reassemble();
      expect(ran, ['dispose the old app, build the new one', 'after']);
      expect(errors.whereType<StateError>(), hasLength(1));
    });

    test('a failing span reports the error and rethrows', () async {
      await expectLater(
        () => FlutterwareServer.spanSync('sql', {'query': 'boom'}, () {
          throw StateError('bad SQL');
        }),
        throwsStateError,
      );
      var events = await replayed();
      expect(events.single.payload['error'], contains('bad SQL'));
    });

    test('configure after activation throws instead of silently ignoring', () {
      FlutterwareServer.event('log', {'message': 'activates'});
      expect(() => FlutterwareServer.configure(name: 'late'), throwsStateError);
    });
  });
}

Future<void> _until(bool Function() condition) async {
  var deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within 5s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
