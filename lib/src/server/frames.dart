/// The wire vocabulary shared by an inspected process and its attachers
/// (GUI, `fw`, MCP).
///
/// One frame shape in both directions, newline-delimited JSON:
///
///     {"ch": "sql", "t": "event", "e": 12, "ts": 1690000000000, "p": {…}}
///     {"ch": "sql", "t": "req",  "id": 7, "m": "explain", "p": {…}}
///     {"ch": "sql", "t": "res",  "id": 7, "p": {…}}
///     {"ch": "sql", "t": "err",  "id": 7, "p": {"message": "…"}}
///
/// `ch` is a sub-protocol name. New feature = new channel name; the envelope
/// itself is expected to stay at [protocolVersion] indefinitely.
///
/// Pure Dart, and deliberately free of `dart:io`. These frames travel over
/// a unix socket to a Dart server on the host *and* over the VM service to a
/// Flutter app on a phone; only the rendezvous half — finding a server on this
/// machine, `protocol.dart` — needs a filesystem. Splitting the two is what
/// lets `inspector_core.dart` compile into an app.
library;

import 'dart:convert';

const protocolVersion = 1;

/// Frame keys, spelled once.
const frameChannel = 'ch';
const frameType = 't';
const framePayload = 'p';
const frameMethod = 'm';
const frameRequestId = 'id';
const frameEventId = 'e';
const frameTimestamp = 'ts';
const frameCorrelation = 'rid';

const typeEvent = 'event';
const typeRequest = 'req';
const typeResponse = 'res';
const typeError = 'err';

/// The built-in channel. `meta/attach` is the handshake that turns a
/// connection into an attachment; `replay-done` marks the ring/live boundary;
/// `meta/detail` fetches an event's lazily-held details (headers, bodies) by
/// event id. Events stay small, and the heavy parts are fetched when someone
/// actually looks.
const metaChannel = 'meta';
const metaAttach = 'attach';
const metaReplayDone = 'replay-done';
const metaDetail = 'detail';

String encodeFrame(Map<String, Object?> frame) => '${jsonEncode(frame)}\n';

/// Decodes one line into a frame, or null for anything that is not a JSON
/// object — a probe's noise, a partial line from a dying peer. The read loops
/// on both sides ignore null rather than erroring: tolerating garbage is what
/// makes a connect-and-close liveness knock free.
Map<String, Object?>? tryDecodeFrame(String line) {
  try {
    var decoded = jsonDecode(line);
    if (decoded is! Map) return null;
    return decoded.cast<String, Object?>();
  } on FormatException {
    return null;
  }
}
