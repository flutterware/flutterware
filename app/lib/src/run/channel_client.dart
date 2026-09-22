import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';

// The protocol, shared with the socket attacher rather than forked: one wire,
// one correlation model, one replay boundary.
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/vm_transport.dart';

import 'connection.dart';

final _logger = Logger('run_channels');

/// The cockpit's end of an app's channels — the host half of
/// `lib/src/server/vm_transport.dart`.
///
/// Pull, plus a nudge. Every exchange is one `ext.flutterware.channel`
/// call: it carries at most one outgoing frame and returns whatever the app
/// had queued. Between calls the app posts a payload-free nudge on the
/// `Extension` stream, and this pulls. Nothing streams; nothing polls.
///
/// Calls are serialized. Two overlapping calls against one peer id would race
/// for the same queue, and the drain that lost would return frames the winner
/// had already taken.
/// One attachment to a running app's channels — everything the App tab and
/// the `panels` actions read and ask. [RunChannelClient] is the live one; a
/// recording answers the same from what an app once said.
abstract class RunAttachment {
  /// Every event seen — the replay, then the live tail.
  List<InspectorEvent> get received;

  Stream<InspectorEvent> get events;

  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params,
  ]);

  Future<Map<String, Object?>?> details(int eventId);

  Future<void> close();
}

class RunChannelClient implements RunAttachment {
  RunChannelClient._(this.connection, this.peerId, this._ownsConnection) {
    _session = AttachSession(sendFrame: _enqueue);
  }

  /// Attaches, or throws. [peer] distinguishes two attachers against one app —
  /// the GUI and an MCP call each get their own queue and their own replay.
  ///
  /// With [ownsConnection], closing the client closes [connection] too — for
  /// a caller that opened it only to attach.
  static Future<RunChannelClient> attach(
    RunConnection connection, {
    required String peer,
    Duration timeout = const Duration(seconds: 5),
    bool ownsConnection = false,
  }) async {
    var client = RunChannelClient._(connection, peer, ownsConnection);
    await connection.listenExtensions();
    client._nudges = connection.extensionEvents
        .where(
          (event) =>
              event.extensionKind == channelNudgeKind &&
              event.extensionData?.data['peer'] == peer,
        )
        .listen((_) => client._pull());
    try {
      client._hello = await client._session.attach().timeout(timeout);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  final RunConnection connection;

  final bool _ownsConnection;

  /// This attachment's queue on the app side.
  final String peerId;

  late final AttachSession _session;
  StreamSubscription<Event>? _nudges;

  Map<String, Object?>? _hello;

  /// What the app answered `meta/attach` with — `protocol`, `channels`,
  /// `events`, plus whatever it chose to describe itself with.
  Map<String, Object?> get hello => _hello ?? const {};

  List<String> get channels => [
    for (var channel in hello['channels'] as List? ?? const [])
      channel.toString(),
  ];

  @override
  List<InspectorEvent> get received => _session.received;

  @override
  Stream<InspectorEvent> get events => _session.events;

  bool get replayComplete => _session.replayComplete;

  /// Frames the app's queue bound threw away. Non-zero means this view has a
  /// hole and a re-attach would fill it from the ring.
  int get dropped => _dropped;
  var _dropped = 0;

  @override
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) => _session.request(channel, method, params);

  @override
  Future<Map<String, Object?>?> details(int eventId) =>
      _session.details(eventId);

  var _queue = Future<void>.value();
  var _closed = false;

  void _enqueue(Map<String, Object?> frame) => _call(jsonEncode(frame));

  void _pull() => _call(null);

  void _call(String? frame) {
    if (_closed) return;
    _queue = _queue.then((_) async {
      if (_closed) return;
      Response response;
      try {
        response = await connection.service.callServiceExtension(
          channelExtension,
          isolateId: connection.isolateId,
          args: {'peer': peerId, 'frame': ?frame},
        );
      } on Object catch (e) {
        // The app is gone, or was never listening. Either way every in-flight
        // request must fail rather than hang.
        _logger.fine('$channelExtension failed: $e');
        _session.closed('the app is not answering $channelExtension');
        _closed = true;
        return;
      }
      _receive(response.json ?? const {});
    });
  }

  void _receive(Map<String, Object?> reply) {
    var dropped = reply['dropped'];
    if (dropped is int) _dropped += dropped;
    for (var frame in reply['frames'] as List? ?? const []) {
      if (frame is Map) _session.receive(frame.cast<String, Object?>());
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _nudges?.cancel();
    _session.closed('detached');
    try {
      await connection.service.callServiceExtension(
        channelExtension,
        isolateId: connection.isolateId,
        args: {'peer': peerId, 'detach': 'true'},
      );
    } on Object {
      // Detaching from an app that already left is the same outcome.
    }
    if (_ownsConnection) await connection.close();
  }
}
