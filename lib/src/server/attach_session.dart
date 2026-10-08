/// The attacher's half of the protocol, with no transport in it: correlate
/// requests, collect the replay, notice the replay/live boundary.
///
/// The mirror of `inspector_core.dart`. Whoever is *reading* an inspected
/// process does the same bookkeeping whether the frames arrive as lines off a
/// unix socket (`attach_client.dart`) or as batches drained from a VM service
/// extension (`app/lib/src/run/channel_client.dart`) — so it is written once
/// here and both feed it.
library;

import 'dart:async';

import 'frames.dart';

/// One event received from an inspected process — replayed from its ring or
/// live off its tail.
class InspectorEvent {
  InspectorEvent({
    required this.channel,
    required this.id,
    required this.time,
    required this.payload,
    required this.isReplay,
    this.rid,
  });

  final String channel;
  final int id;
  final DateTime time;

  /// The correlation id an adapter stamped — the HTTP request this event
  /// happened under, for everything the shelf middleware wraps.
  final String? rid;

  final Map<String, Object?> payload;

  /// True for events that predate this attachment.
  final bool isReplay;
}

class InspectorRequestException implements Exception {
  InspectorRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AttachSession {
  AttachSession({required this.sendFrame});

  /// Hands one frame to the transport. Synchronous by contract — a transport
  /// that has to await something queues it and returns.
  final void Function(Map<String, Object?> frame) sendFrame;

  /// Every event this attachment has seen — the replay, then the live tail.
  ///
  /// A retained list rather than a bare stream, deliberately: the inspected
  /// process replays in the same flush as the hello, so by the time an attach
  /// returns the replay has already been read — a broadcast stream would have
  /// dropped it before the caller could subscribe. Bounded by the far side's
  /// ring plus this attachment's lifetime.
  List<InspectorEvent> get received => List.unmodifiable(_received);
  final _received = <InspectorEvent>[];

  /// Fires after each event is appended to [received] — a change signal, not
  /// the storage.
  Stream<InspectorEvent> get events => _events.stream;
  final _events = StreamController<InspectorEvent>.broadcast();

  /// Flips when the replay boundary passes; events after this are live.
  bool get replayComplete => _replayComplete;
  var _replayComplete = false;

  /// Resolves when the far side goes away.
  Future<void> get done => _done.future;
  final _done = Completer<void>();

  final _pending = <int, Completer<Map<String, Object?>>>{};
  var _nextRequestId = 1;

  /// Sends `meta/attach` and returns the hello payload. What is *in* that
  /// payload is the inspected process's business — a server names its pid and
  /// project root, an app names something else — so it comes back raw.
  Future<Map<String, Object?>> attach() => request(metaChannel, metaAttach);

  /// Sends a `req` frame and returns the response payload; throws
  /// [InspectorRequestException] when the far side answers `err` — a missing
  /// handler, or the handler itself throwing.
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    var id = _nextRequestId++;
    var completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    sendFrame({
      frameChannel: channel,
      frameType: typeRequest,
      frameRequestId: id,
      frameMethod: method,
      framePayload: params,
    });
    return completer.future;
  }

  /// The lazily-held details of one event — headers, bodies — or null when the
  /// far side never captured them or has since evicted them.
  Future<Map<String, Object?>?> details(int eventId) async {
    var response = await request(metaChannel, metaDetail, {'event': eventId});
    var details = response['details'];
    return details is Map ? details.cast<String, Object?>() : null;
  }

  /// Feeds one decoded frame in. Anything unrecognised is dropped.
  void receive(Map<String, Object?> frame) {
    switch (frame[frameType]) {
      case typeEvent:
        _onEvent(frame);
      case typeResponse || typeError:
        var id = frame[frameRequestId];
        var completer = id is int ? _pending.remove(id) : null;
        if (completer == null) return;
        var payload = frame[framePayload];
        var map = payload is Map
            ? payload.cast<String, Object?>()
            : <String, Object?>{};
        if (frame[frameType] == typeError) {
          completer.completeError(
            InspectorRequestException(map['message']?.toString() ?? 'error'),
          );
        } else {
          completer.complete(map);
        }
    }
  }

  void _onEvent(Map<String, Object?> frame) {
    var channel = frame[frameChannel];
    if (channel is! String) return;
    var payload = frame[framePayload];
    var map = payload is Map
        ? payload.cast<String, Object?>()
        : <String, Object?>{};
    if (channel == metaChannel && map['type'] == metaReplayDone) {
      _replayComplete = true;
      return;
    }
    var ts = frame[frameTimestamp];
    var event = InspectorEvent(
      channel: channel,
      id: frame[frameEventId] is int ? frame[frameEventId]! as int : 0,
      time: ts is int
          ? DateTime.fromMillisecondsSinceEpoch(ts)
          : DateTime.now(),
      rid: frame[frameCorrelation] as String?,
      payload: map,
      isReplay: !_replayComplete,
    );
    _received.add(event);
    _events.add(event);
  }

  /// The far side is gone: every in-flight request fails rather than hanging
  /// forever, which is the difference between a dead app and a slow one.
  void closed([String reason = 'disconnected']) {
    if (!_done.isCompleted) _done.complete();
    for (var completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(InspectorRequestException(reason));
      }
    }
    _pending.clear();
    unawaited(_events.close());
  }
}
