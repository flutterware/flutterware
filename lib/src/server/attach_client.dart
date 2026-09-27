import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'attach_session.dart';
import 'protocol.dart';

export 'attach_session.dart' show InspectorEvent, InspectorRequestException;

/// One event received from an inspected server — replayed from its ring or
/// live off its tail.
///
/// The server-facing spelling of [InspectorEvent]: the same type, under the
/// name this library has always published.
typedef ServerEvent = InspectorEvent;

/// What the server answered `meta/attach` with.
class ServerHello {
  ServerHello({
    required this.name,
    required this.pid,
    required this.projectRoot,
    required this.startedAt,
    required this.channels,
    required this.eventCount,
  });

  final String name;
  final int pid;
  final String projectRoot;
  final DateTime startedAt;
  final List<String> channels;

  /// How many ring events the replay will deliver.
  final int eventCount;
}

/// The attacher's half of the protocol — what the GUI core, `fw` and MCP use
/// to read a live server.
///
/// [connect] performs the `meta/attach` handshake, so constructing one of
/// these is an *attachment*: the ring replays into [events] (marked
/// [ServerEvent.isReplay]), then the live tail follows. A liveness probe that
/// wants no replay should just `Socket.connect` and destroy — the server
/// writes nothing to a connection that has not attached.
class ServerAttachClient {
  ServerAttachClient._(this.handle, this._socket) {
    // A request written to a server that just went fails on `done`, not in
    // the write: the read side's end is what says it went.
    _socket.done.ignore();
    _session = AttachSession(
      sendFrame: (frame) => _socket.write(encodeFrame(frame)),
    );
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onClosed, onError: (Object _) => _onClosed());
  }

  /// Connects and attaches, or throws — on refused connect, on timeout, on a
  /// hello that never comes. The caller decides whether a failure means
  /// "delete the handle" ([attachToServer] does).
  static Future<ServerAttachClient> connect(
    ServerHandle handle, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    // Closed by [close] / [_onClosed]; the analyzer cannot follow the handoff.
    // ignore: close_sinks
    var socket = await Socket.connect(
      InternetAddress(handle.socketPath, type: InternetAddressType.unix),
      0,
    ).timeout(timeout);
    var client = ServerAttachClient._(handle, socket);
    try {
      client._hello = await client._session
          .attach()
          .then(_decodeHello)
          .timeout(timeout);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  final ServerHandle handle;
  final Socket _socket;

  /// The protocol bookkeeping — correlation, replay boundary, event list —
  /// shared with every other attacher. This class is only the socket.
  late final AttachSession _session;

  ServerHello? _hello;

  /// Available once [connect] returned.
  ServerHello get hello => _hello!;

  /// Every event this attachment has seen — the replay, then the live tail.
  List<ServerEvent> get received => _session.received;

  /// Fires after each event is appended to [received] — a change signal, not
  /// the storage.
  Stream<ServerEvent> get events => _session.events;

  /// Flips when the replay boundary passes; events after this are live.
  bool get replayComplete => _session.replayComplete;

  /// Resolves when the server goes away.
  Future<void> get done => _session.done;

  /// Sends a `req` frame and returns the response payload; throws
  /// [ServerRequestException] when the server answers with `err` — a missing
  /// handler, or the handler itself throwing.
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) => _session.request(channel, method, params);

  /// The lazily-held details of one event — headers, bodies — or null when
  /// the server never captured them or has since evicted them.
  Future<Map<String, Object?>?> details(int eventId) =>
      _session.details(eventId);

  void _onLine(String line) {
    var frame = tryDecodeFrame(line);
    if (frame != null) _session.receive(frame);
  }

  void _onClosed() => _session.closed('server disconnected');

  Future<void> close() async {
    _socket.destroy();
    _onClosed();
  }

  static ServerHello _decodeHello(Map<String, Object?> payload) => ServerHello(
    name: payload['name']?.toString() ?? '?',
    pid: payload['pid'] is int ? payload['pid']! as int : 0,
    projectRoot: payload['projectRoot']?.toString() ?? '',
    startedAt:
        DateTime.tryParse(payload['startedAt']?.toString() ?? '') ??
        DateTime.now(),
    channels: [
      for (var channel in payload['channels'] as List? ?? const [])
        channel.toString(),
    ],
    eventCount: payload['events'] is int ? payload['events']! as int : 0,
  );
}

/// The server-facing spelling of [InspectorRequestException].
typedef ServerRequestException = InspectorRequestException;

/// [ServerAttachClient.connect] with `attachToLiveSession`'s cleanup rule: a
/// handle whose socket nobody is listening on is deleted on the way past, and
/// null comes back instead of an error. This is what keeps the published list
/// truthful — dead servers disappear the first time anything tries to reach
/// them.
///
/// Only that, though. The rule used to be "any failure deletes", and the 2s
/// timeout is a failure — so a server that was merely too busy to finish the
/// handshake had its handle destroyed and vanished from every list until it
/// was restarted. A refused connect is evidence of death; a slow answer is
/// evidence of life. [onFailure] tells the caller which happened, since a
/// bare null cannot.
Future<ServerAttachClient?> attachToServer(
  ServerHandle handle, {
  Duration timeout = const Duration(seconds: 2),
  void Function(Object error, {required bool deleted})? onFailure,
}) async {
  try {
    return await ServerAttachClient.connect(handle, timeout: timeout);
  } on SocketException catch (e) {
    // Refused, or the socket file is gone: nothing is listening, the server
    // is dead, the handle is litter.
    deleteServerHandle(handle);
    onFailure?.call(e, deleted: true);
    return null;
  } on Object catch (e) {
    onFailure?.call(e, deleted: false);
    return null;
  }
}
