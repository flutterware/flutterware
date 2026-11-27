import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/daemon_address.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// How a client sorts what the daemon says, against a real socket and a fake
/// daemon.
///
/// Three properties, each of which the previous plumbing got wrong. It read the
/// socket through `asBroadcastStream()` and matched replies with
/// `.where(…).first`, which means:
///
/// - **a reply could be missed**, because a broadcast stream drops what arrives
///   while nobody is listening — verified below, so the fix is measured against
///   the real behaviour rather than an assumption about it;
/// - **a reply could never arrive**, and `select` would wait for it forever;
/// - **a pushed event could be dropped** in the window between `connect`
///   returning and a caller reaching `.listen`.
///
/// The fake daemon is the point: these are all cases a real daemon does not
/// produce on demand. It speaks the same line protocol over the same kind of unix
/// socket, and says only what each test needs said.
///
/// `CompilerDaemonClient.connect` cannot be used — it compiles a snapshot and
/// spawns a process — so these go through `attach`, which is `connect` minus the
/// side effects and is the same code from the socket onwards.
///
/// The fake binds the address a real client would *derive* for its config, rather
/// than a path of the test's choosing. That keeps `DaemonAddress` in the loop and
/// means the attach is the real one; the config is rooted in a temp directory, so
/// the key cannot collide with a daemon the developer is actually running.
/// Polls until [condition] holds. What the daemon says crosses a real socket,
/// so its arrival is on the kernel's schedule, not the event queue's —
/// `pumpEventQueue` alone was a bet that delivery had already happened, and on
/// a loaded CI runner it loses.
Future<void> _waitUntil(bool Function() condition) async {
  var deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within 10s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late _FakeDaemon daemon;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('fw-client-');
    File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"configVersion": 2, "packages": []}');
    var address = DaemonAddress(
      DaemonConfig.forPackage(
        appToolDirectory: root.path,
        packageRoot: root.path,
        flutterSdkRoot: '/flutter',
        roots: const ['demo'],
      ),
    );
    address.ensureRunDir();
    daemon = await _FakeDaemon.start(address);
  });

  tearDown(() async {
    await daemon.stop();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('the hazard this replaced', () {
    test('a broadcast stream drops what arrives with no listener', () async {
      // Not a test of our code — a test of the premise. If this ever stops being
      // true the demux is no longer earning its keep, and the comment in
      // `CompilerDaemonClient` explaining it would be wrong.
      var controller = StreamController<int>();
      addTearDown(controller.close);
      var stream = controller.stream.asBroadcastStream();
      controller.add(1);
      expect(await stream.first, 1);

      controller
        ..add(2)
        ..add(3);
      await pumpEventQueue();

      var seen = <int>[];
      var sub = stream.listen(seen.add);
      await pumpEventQueue();
      addTearDown(sub.cancel);

      expect(
        seen,
        isEmpty,
        reason:
            'Events 2 and 3 were dropped, not buffered — which is why replies '
            'are futures registered before the request is written.',
      );
    });
  });

  group('replies', () {
    test('a reply reaches the caller that asked for it', () async {
      daemon.answerSelects();
      var client = await daemon.attach();
      addTearDown(client.close);

      var compiled = await client.select('demo/a.dart#a');
      expect(compiled.id, 'demo/a.dart#a');
      expect(compiled.requestId, 0);
    });

    test('two in flight are not confused with each other', () async {
      // Answered out of order on purpose. Matching on "the next compiled
      // message" would hand each caller the other's answer — and the daemon
      // genuinely reorders, because it serialises on a queue that other clients
      // are also in.
      daemon.answerSelectsReversed();
      var client = await daemon.attach();
      addTearDown(client.close);

      var first = client.select('demo/a.dart#a');
      var second = client.select('demo/b.dart#b');
      expect((await first).id, 'demo/a.dart#a');
      expect((await second).id, 'demo/b.dart#b');
    });

    test('a daemon that never answers times out, naming the log', () async {
      // The property: a daemon that is alive, holding its queue, and never going
      // to answer used to hang the caller — and so the GUI's catalog panel —
      // forever.
      daemon.answerNothing();
      var client = await daemon.attach();
      addTearDown(client.close);

      await expectLater(
        client.select('demo/a.dart#a', timeout: const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('did not answer'), contains('demo/a.dart#a')),
          ),
        ),
      );
    });

    test('a daemon that dies mid-request fails it, rather than hanging', () async {
      daemon.answerNothing();
      var client = await daemon.attach();
      addTearDown(client.close);

      // Awaited *before* the daemon dies, which is both what a real caller does
      // and what the test needs: an error delivered to a future nobody is
      // listening to yet is reported unhandled, whoever listens afterwards.
      var pending = expectLater(
        client.select('demo/a.dart#a'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed the connection'),
          ),
        ),
      );
      await daemon.dropConnections();
      await pending;
    });

    test(
      'a line the client cannot read is a log, not a broken connection',
      () async {
        // Symmetrical with the daemon's own guard. An unknown response type — a
        // newer daemon, or a stray line — must not cost the connection.
        daemon.answerSelects();
        var logs = <String>[];
        var client = await daemon.attach(onLog: logs.add);
        addTearDown(client.close);

        daemon.say('{"type":"a-response-from-the-future"}');
        daemon.say('not json at all');
        await pumpEventQueue();

        expect(
          (await client.select('demo/a.dart#a')).id,
          'demo/a.dart#a',
          reason: 'the connection still works',
        );
        expect(logs, isNotEmpty);
      },
    );
  });

  group('events', () {
    test('one that landed before anyone subscribed is kept as state', () async {
      // `CatalogChanged` is a snapshot — the servable set and the quarantine —
      // so a caller that arrived after one does not need the event, it needs the
      // value. Injecting it into the stream instead was tried, and dropped
      // changes for listeners that *were* subscribed.
      daemon.answerNothing();
      var client = await daemon.attach();
      addTearDown(client.close);

      expect(client.lastChange, isNull, reason: 'nothing has changed yet');

      daemon.say(
        encodeLine(const CatalogChanged(entries: [], quarantined: [])),
      );
      await _waitUntil(() => client.lastChange != null);

      expect(client.lastChange, isA<CatalogChanged>());
    });

    test('a listener already subscribed is never overtaken by that', () async {
      // The regression the state/event split exists to prevent: a generator that
      // replayed the held value subscribed to the live stream one microtask
      // late, so a change arriving in that gap went to the value and never
      // reached the stream waiting for it.
      daemon.answerNothing();
      var client = await daemon.attach();
      addTearDown(client.close);

      var seen = <CatalogChanged>[];
      var sub = client.catalogChanges.listen(seen.add);
      addTearDown(sub.cancel);
      // Deliberately no pump: the change is sent in the same turn the listener
      // was attached in, which is the window that broke.
      daemon.say(
        encodeLine(const CatalogChanged(entries: [], quarantined: [])),
      );
      await _waitUntil(() => seen.isNotEmpty);
      // One more drain, so a duplicate would have landed before the count.
      await pumpEventQueue();

      expect(seen, hasLength(1));
    });

    test('changes arriving while subscribed are delivered in order', () async {
      daemon.answerNothing();
      var client = await daemon.attach();
      addTearDown(client.close);

      var seen = <CatalogChanged>[];
      var sub = client.catalogChanges.listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      for (var i = 0; i < 3; i++) {
        daemon.say(
          encodeLine(const CatalogChanged(entries: [], quarantined: [])),
        );
      }
      await _waitUntil(() => seen.length >= 3);

      expect(seen, hasLength(3));
    });

    test('the stream closes when the daemon goes away', () async {
      daemon.answerNothing();
      var client = await daemon.attach();
      addTearDown(client.close);

      var done = Completer<void>();
      var sub = client.catalogChanges.listen((_) {}, onDone: done.complete);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await daemon.dropConnections();
      await expectLater(done.future, completes);
    });
  });
}

/// A daemon that speaks the protocol and nothing else.
class _FakeDaemon {
  _FakeDaemon(this._server, this.address);

  static Future<_FakeDaemon> start(DaemonAddress address) async {
    var stale = File(address.socketPath);
    if (stale.existsSync()) stale.deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(address.socketPath, type: InternetAddressType.unix),
      0,
    );
    var daemon = _FakeDaemon(server, address);
    server.listen(daemon._accept);
    return daemon;
  }

  final ServerSocket _server;
  final DaemonAddress address;
  final _clients = <Socket>[];

  /// Every connection, including the ones whose client has hung up and so
  /// left [_clients]: this end stays open until it is destroyed, and closing
  /// the listener does not close it.
  final _opened = <Socket>[];
  void Function(Socket, SelectRequest)? _onSelect;

  void _accept(Socket socket) {
    _clients.add(socket);
    _opened.add(socket);
    // Ready before anything else, because that is the handshake every client
    // waits on.
    socket.writeln(
      encodeLine(
        const DaemonReady(
          sessionId: 'session-0',
          assetsDir: '/assets',
          icuData: '/icu',
          coldCompile: Duration.zero,
          entries: [],
        ),
      ),
    );
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            var json = tryDecodeLine(line);
            if (json == null) return;
            var request = DaemonRequest.decode(json);
            if (request is SelectRequest) _onSelect?.call(socket, request);
          },
          onError: (_) {},
          onDone: () => _clients.remove(socket),
        );
  }

  void answerSelects() =>
      _onSelect = (socket, request) => socket.writeln(_replyTo(request));

  /// Holds each request until a second arrives, then answers the second first.
  void answerSelectsReversed() {
    SelectRequest? held;
    _onSelect = (socket, request) {
      if (held == null) {
        held = request;
        return;
      }
      socket
        ..writeln(_replyTo(request))
        ..writeln(_replyTo(held!));
      held = null;
    };
  }

  void answerNothing() => _onSelect = null;

  /// Says one raw line to every connected client.
  void say(String line) {
    for (var client in _clients) {
      client.writeln(line);
    }
  }

  static String _replyTo(SelectRequest request) => encodeLine(
    DaemonCompiled(
      requestId: request.requestId,
      id: request.id,
      compile: const Duration(milliseconds: 1),
      newSourceCount: 0,
      dill: '/kernel.dill',
    ),
  );

  /// A daemon dying under its clients' feet.
  Future<void> dropConnections() async {
    for (var client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await pumpEventQueue();
  }

  /// Destroys every connection before the socket file is deleted. On
  /// Windows, a connection left open on a deleted socket file, beside the
  /// next tests' own sockets, froze the whole machine's networking: no test
  /// failed and the CI runner stopped answering.
  Future<void> stop() async {
    await dropConnections();
    for (var socket in _opened) {
      socket.destroy();
    }
    _opened.clear();
    await _server.close();
    var socket = File(address.socketPath);
    if (socket.existsSync()) socket.deleteSync();
  }

  /// A real [CompilerDaemonClient], attached the way one attaches to a daemon
  /// that is already serving.
  Future<CompilerDaemonClient> attach({void Function(String)? onLog}) async {
    var (client, _) = await CompilerDaemonClient.attach(
      address: address,
      onLog: onLog,
      readyTimeout: const Duration(seconds: 5),
    );
    return client;
  }
}
