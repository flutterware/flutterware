/// The transport-free half of the inspector: the ring, the channels, the
/// command handlers, the detail store and the attach handshake.
///
/// No `dart:io`, and that is the point. Everything an inspected process
/// does for an attacher — keep the last N events per channel, replay them to
/// whoever attaches, correlate, hold bodies aside until someone asks, run a
/// command where the data is — is the same whether the peer arrived over a
/// unix socket on this machine or over the VM service from a phone. Only
/// *reaching* the peer differs, and that is a transport:
///
/// | transport | for |
/// |---|---|
/// | unix socket + handle file (`inspector.dart`) | a Dart server on the host |
/// | VM service extension + `postEvent` | a Flutter app, on any device |
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'frames.dart';

/// What a command handler receives and returns. A returned map becomes the
/// response payload as-is; anything else is wrapped as `{"value": …}`.
typedef InspectorCommandHandler = FutureOr<Object?> Function(
  Map<String, Object?> params,
);

/// One attached peer, from the core's point of view: somewhere frames go.
///
/// A socket transport writes an encoded line; a VM-service transport posts an
/// extension event. Neither is the core's business — it holds peers in a set,
/// sends them frames, and drops the ones that fail.
abstract class InspectorPeer {
  /// Sends one frame. Throwing is a legitimate way to say "this peer is gone";
  /// the core will [close] and forget it.
  void send(Map<String, Object?> frame);

  /// Releases the peer's resources. Called at most once per peer by the core,
  /// and expected to tolerate a transport that already tore it down.
  void close();
}

/// [map], with anything `jsonEncode` would refuse replaced by its own text.
///
/// Reporting is not allowed to fail, and an unencodable value used to take
/// the whole attachment down. [InspectorCore.send] treats a throw as "this
/// peer is gone", which is right for a dead socket and wrong for a `DateTime`
/// in a bound parameter: the encode threw on the way to a perfectly healthy
/// peer and the peer was destroyed for it. Worse, the event stayed in the ring,
/// so every reattach died the same way inside [InspectorCore.attach]'s replay
/// for as long as it was held — one such value put a server's panel out until
/// the ring rolled over. A reporter cannot be asked to prevent this either: it
/// is a `span` around somebody's query, and it may not throw into the query.
///
/// So every payload passes through here on the way into the ring, and the
/// substitution is the value's own `toString()` rather than a placeholder,
/// because a reporter that bound a date wants to read the date. `<unencodable>`
/// appears only where even that threw.
Map<String, Object?> jsonSafeMap(Map<String, Object?> map) => {
  for (var entry in map.entries) entry.key: _jsonSafe(entry.value, 0),
};

/// How deep the walk goes before it stops describing and starts quoting. Also
/// what terminates a cyclic structure, which `jsonEncode` refuses outright.
const _maxJsonDepth = 20;

Object? _jsonSafe(Object? value, int depth) {
  if (value == null || value is bool || value is String) return value;
  // Non-finite doubles are numbers Dart has and JSON does not.
  if (value is num) return value.isFinite ? value : _text(value);
  if (depth == _maxJsonDepth) return _text(value);
  if (value is List) {
    return [for (var element in value) _jsonSafe(element, depth + 1)];
  }
  if (value is Map) {
    return {
      for (var entry in value.entries)
        entry.key is String ? entry.key as String : _text(entry.key): _jsonSafe(
          entry.value,
          depth + 1,
        ),
    };
  }
  // Anything else might still be encodable: `jsonEncode` calls `toJson()` on
  // an object that has one, and a reporter's own type carrying one is a value
  // worth keeping whole rather than flattening to its text.
  try {
    jsonEncode(value);
    return value;
  } on Object {
    return _text(value);
  }
}

String _text(Object? value) {
  try {
    return '$value';
  } on Object {
    return '<unencodable>';
  }
}

/// An event held in a channel's ring.
class RingEvent {
  RingEvent(this.id, this.channel, this.time, this.rid, this.payload);

  final int id;
  final String channel;
  final DateTime time;
  final String? rid;
  final Map<String, Object?> payload;

  Map<String, Object?> toFrame() => {
    frameChannel: channel,
    frameType: typeEvent,
    frameEventId: id,
    frameTimestamp: time.millisecondsSinceEpoch,
    if (rid != null) frameCorrelation: rid,
    framePayload: payload,
  };
}

class InspectorCore {
  InspectorCore({
    required this.identity,
    this.ringSize = 500,
    this.detailsByteCap = 16 * 1024 * 1024,
    this.onEvent,
  });

  /// What the `meta/attach` reply says about the inspected process, over and
  /// above the `channels` and `events` this core adds. A server names itself,
  /// its pid and its project root; an app will name something else. Called per
  /// attach, so a transport that learns its facts late still reports them.
  final Map<String, Object?> Function() identity;

  /// Kept events per channel; the oldest fall off first.
  final int ringSize;

  /// Bytes of encoded details kept; the oldest evict first. Bounded in bytes
  /// rather than entries because one body can outweigh a thousand headers.
  final int detailsByteCap;

  /// Every event, before it is ringed — the hook a transport reduces with.
  ///
  /// The socket transport mirrors `baseUrl` and `environment` from the `info`
  /// channel into its handle file this way. The core stays ignorant of what
  /// any channel *means*, which is what keeps a new channel from being a
  /// change here.
  final void Function(String channel, Map<String, Object?> payload)? onEvent;

  final _ring = <String, Queue<RingEvent>>{};
  final _details = <int, String>{};
  var _detailsBytes = 0;
  final _handlers = <String, Map<String, InspectorCommandHandler>>{};
  final _attached = <InspectorPeer>{};
  var _nextEventId = 1;
  var _stopped = false;

  bool get isStopped => _stopped;

  /// The channels anything has been said on or registered for.
  List<String> get channels =>
      {..._ring.keys, ..._handlers.keys}.toList()..sort();

  /// Rings one event and returns **its id** — the handle an item action is
  /// invoked with, and the only way a reporter can tie a row back to whatever
  /// it was reporting on. Zero when the core has stopped and nothing was
  /// ringed.
  int addEvent(
    String channel,
    Map<String, Object?> payload, {
    String? rid,
    Map<String, Object?>? details,
  }) {
    if (_stopped) return 0;
    var safe = jsonSafeMap(payload);
    var event = RingEvent(_nextEventId++, channel, DateTime.now(), rid, safe);
    if (details != null) _stashDetails(event.id, details);
    var ring = _ring.putIfAbsent(channel, Queue.new);
    ring.add(event);
    while (ring.length > ringSize) {
      ring.removeFirst();
    }
    onEvent?.call(channel, safe);
    if (_attached.isNotEmpty) _broadcast(event.toFrame());
    return event.id;
  }

  /// Insertion order is the eviction order: [_details] is a plain map, and
  /// Dart maps iterate in insertion order, so `keys.first` is the oldest.
  void _stashDetails(int eventId, Map<String, Object?> details) {
    String encoded;
    try {
      encoded = jsonEncode(jsonSafeMap(details));
    } on Object {
      return;
    }
    _details[eventId] = encoded;
    _detailsBytes += encoded.length;
    while (_detailsBytes > detailsByteCap && _details.length > 1) {
      var oldest = _details.keys.first;
      _detailsBytes -= _details.remove(oldest)!.length;
    }
  }

  void registerHandler(
    String channel,
    String method,
    InspectorCommandHandler handler,
  ) {
    _handlers.putIfAbsent(channel, () => {})[method] = handler;
  }

  /// Empties the ring and the held details, leaving handlers and attachments
  /// alone.
  ///
  /// For tests. `GuestChannels.core` is one object for the whole process, so
  /// without this a test reads the events the test before it emitted — which
  /// is exactly how the first feed test failed.
  @visibleForTesting
  void debugClearEvents() {
    _ring.clear();
    _details.clear();
    _detailsBytes = 0;
  }

  /// Forgets a channel's handlers — what a panel being torn down means.
  ///
  /// The ring is left alone: the events happened, and a history that vanished
  /// because the thing reporting it unmounted would be worse than one that is
  /// merely no longer queryable.
  void unregisterHandlers(String channel) => _handlers.remove(channel);

  /// Dispatches one decoded frame from [peer]. Anything that is not a
  /// well-formed request is ignored, which is what makes a liveness knock —
  /// connect, say nothing, close — cost a read loop and nothing else.
  void handleFrame(InspectorPeer peer, Map<String, Object?> frame) {
    if (frame[frameType] != typeRequest) return;
    var channel = frame[frameChannel];
    var method = frame[frameMethod];
    var id = frame[frameRequestId];
    if (channel is! String || method is! String || id is! int) return;
    if (channel == metaChannel && method == metaAttach) {
      attach(peer, id);
      return;
    }
    if (channel == metaChannel && method == metaDetail) {
      var params = frame[framePayload];
      var eventId = params is Map ? params['event'] : null;
      var encoded = eventId is int ? _details[eventId] : null;
      send(peer, {
        frameChannel: metaChannel,
        frameType: typeResponse,
        frameRequestId: id,
        framePayload: encoded == null
            // Honest about the difference between "never captured" and
            // "captured and evicted": the attacher words them differently.
            ? {'evicted': true}
            : {'details': jsonDecode(encoded)},
      });
      return;
    }
    var handler = _handlers[channel]?[method];
    if (handler == null) {
      send(peer, {
        frameChannel: channel,
        frameType: typeError,
        frameRequestId: id,
        framePayload: {'message': 'no handler for $channel.$method'},
      });
      return;
    }
    var params = frame[framePayload];
    unawaited(
      _respond(
        peer,
        channel,
        id,
        handler,
        params is Map ? params.cast<String, Object?>() : const {},
      ),
    );
  }

  Future<void> _respond(
    InspectorPeer peer,
    String channel,
    int id,
    InspectorCommandHandler handler,
    Map<String, Object?> params,
  ) async {
    try {
      var result = await handler(params);
      send(peer, {
        frameChannel: channel,
        frameType: typeResponse,
        frameRequestId: id,
        framePayload: result is Map
            ? result.cast<String, Object?>()
            : {'value': result},
      });
    } catch (e) {
      send(peer, {
        frameChannel: channel,
        frameType: typeError,
        frameRequestId: id,
        framePayload: {'message': '$e'},
      });
    }
  }

  /// The handshake that makes connection ≠ attachment: nothing is written to a
  /// peer that has not asked, so a probe that connects and closes is free.
  void attach(InspectorPeer peer, int requestId) {
    var events = _ring.values.expand((q) => q).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    send(peer, {
      frameChannel: metaChannel,
      frameType: typeResponse,
      frameRequestId: requestId,
      framePayload: {
        ...identity(),
        'channels': channels,
        'events': events.length,
      },
    });
    for (var event in events) {
      send(peer, event.toFrame());
    }
    send(peer, {
      frameChannel: metaChannel,
      frameType: typeEvent,
      framePayload: {'type': metaReplayDone},
    });
    _attached.add(peer);
  }

  /// Sends one frame, dropping [peer] if it cannot take it.
  void send(InspectorPeer peer, Map<String, Object?> frame) {
    try {
      peer.send(frame);
    } on Object {
      detach(peer);
    }
  }

  void _broadcast(Map<String, Object?> frame) {
    for (var peer in _attached.toList()) {
      send(peer, frame);
    }
  }

  /// Forgets [peer] and closes it. Idempotent, because both ends can decide a
  /// peer is gone: the transport's read loop and a failed write.
  void detach(InspectorPeer peer) {
    _attached.remove(peer);
    peer.close();
  }

  /// Drops every attachment. The transport keeps whatever else it owns — a
  /// listening socket, a handle file — and decides separately what to do
  /// with it.
  void detachAll() {
    for (var peer in _attached.toList()) {
      detach(peer);
    }
  }

  /// After this the core takes no more events and holds no peers. A transport
  /// calls it from its own shutdown.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    detachAll();
  }
}
