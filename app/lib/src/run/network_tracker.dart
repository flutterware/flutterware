import 'dart:async';

import 'package:vm_service/vm_service.dart';

import 'connection.dart';

/// One run's HTTP traffic, read from the VM's own profile — the data source
/// behind DevTools' Network page, with no guest code in the read path.
///
/// The profile is an upsert stream, not a feed: `getHttpProfile` with
/// `updatedSince` returns every request *touched* since the cursor, so an
/// in-flight request arrives once with no response and again, same id, when it
/// completes. Rows are therefore keyed by request id. The VM keeps the data,
/// which is what makes this tracker disposable — a fresh attach replays
/// everything since capture was armed (by the run guest, or by [poll]'s
/// re-arm for a guest-less run, which misses startup).
class RunNetworkTracker {
  RunNetworkTracker(this.connection, {this.detailByteCap = 8 << 20});

  final RunConnection connection;

  /// Bound on cached detail bodies. The VM holds the real data until a
  /// restart, so eviction costs a refetch, not a loss.
  final int detailByteCap;

  final _requests = <String, HttpProfileRequestRef>{};
  final _changes = StreamController<void>.broadcast();
  final _details = <String, HttpProfileRequest>{};
  var _detailBytes = 0;

  DateTime? _cursor;
  String? _isolateId;
  Timer? _timer;
  var _failures = 0;

  /// First-seen order, which is start order within a session.
  List<HttpProfileRequestRef> get requests => _requests.values.toList();

  /// Fires after any poll that changed [requests] — including the reset to
  /// empty when a hot restart wiped the profile.
  Stream<void> get changes => _changes.stream;

  /// True once polling gave up after consecutive failures — the app is gone,
  /// not quiet.
  bool get broken => _failures >= _maxFailures;

  /// Reads everything the profile holds that this tracker has not seen.
  ///
  /// Returns how many rows were touched. A hot restart is detected here: the
  /// main isolate's id changes, the VM has wiped the profile, and the tracker
  /// starts a fresh session — rows cleared, cursor dropped, capture re-armed.
  Future<int> poll() async {
    var vm = await connection.service.getVM();
    // The same rule the connection dials with, and for the same reason: the
    // profile belongs to the app's own isolate, and a worker some plugin
    // spawned is not it.
    var isolateId = RunConnection.rootIsolateOf(vm.isolates);
    if (isolateId == null) return 0;
    if (isolateId != _isolateId) {
      var restarted = _isolateId != null;
      _isolateId = isolateId;
      _cursor = null;
      if (restarted) {
        _requests.clear();
        _details.clear();
        _detailBytes = 0;
      }
      // The guest-less fallback, and a no-op 3ms call when the guest already
      // armed capture in `main`.
      await connection.service.httpEnableTimelineLogging(isolateId, true);
      if (restarted) _changes.add(null);
    }
    var profile = await connection.service.getHttpProfile(
      isolateId,
      updatedSince: _cursor,
    );
    _cursor = profile.timestamp;
    for (var request in profile.requests) {
      _requests[request.id] = request;
      // A completed request supersedes whatever detail was fetched while it
      // was in flight.
      var stale = _details.remove(request.id);
      if (stale != null) _detailBytes -= _sizeOf(stale);
    }
    if (profile.requests.isNotEmpty) _changes.add(null);
    return profile.requests.length;
  }

  /// Polls on [interval] until [stop], [dispose], or the app stops answering.
  void start([Duration interval = const Duration(milliseconds: 500)]) {
    if (_timer != null) return;
    _failures = 0;
    var polling = false;
    _timer = Timer.periodic(interval, (_) async {
      if (polling) return;
      polling = true;
      try {
        await poll();
        _failures = 0;
      } on Object {
        _failures++;
        if (_failures >= _maxFailures) {
          stop();
          _changes.add(null);
        }
      } finally {
        polling = false;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The full request — headers, bodies, timing events — fetched on first
  /// look and held under [detailByteCap].
  ///
  /// Null when the VM no longer has it (a restart raced the fetch).
  Future<HttpProfileRequest?> detailsFor(String id) async {
    var cached = _details[id];
    if (cached != null) return cached;
    var isolateId = _isolateId;
    if (isolateId == null) return null;
    HttpProfileRequest detail;
    try {
      detail = await connection.service.getHttpProfileRequest(isolateId, id);
    } on Object {
      return null;
    }
    _details[id] = detail;
    _detailBytes += _sizeOf(detail);
    while (_detailBytes > detailByteCap && _details.length > 1) {
      var oldest = _details.keys.first;
      _detailBytes -= _sizeOf(_details.remove(oldest)!);
    }
    return detail;
  }

  /// Drops the profile on both sides — the VM's copy and this tracker's.
  Future<void> clear() async {
    var isolateId = _isolateId;
    if (isolateId != null) {
      await connection.service.clearHttpProfile(isolateId);
    }
    _requests.clear();
    _details.clear();
    _detailBytes = 0;
    _changes.add(null);
  }

  void dispose() {
    stop();
    unawaited(_changes.close());
  }

  static int _sizeOf(HttpProfileRequest detail) =>
      (detail.requestBody?.length ?? 0) + (detail.responseBody?.length ?? 0);
}

const _maxFailures = 10;

/// What `dart:io` says about a connection it handed off after an upgrade.
///
/// A message, not an API. There is no flag on the profile record that says
/// "this became a WebSocket", and the upgrade path sets the same `error` field
/// a refused connection does — so this string is the only thing separating the
/// two. Matched exactly, and kept here with its reason, because a rename
/// upstream should show up as WebSockets reading `ERR` again rather than as a
/// mystery.
const _detachedSocket = 'Socket has been detached';

/// True when this request is a protocol upgrade rather than a failure.
bool networkIsUpgrade(HttpProfileRequestRef request) =>
    (request.request?.error ?? request.response?.error) == _detachedSocket;

/// The status a row shows: the code, `ERR` for a failed request, null while
/// in flight.
///
/// An upgraded connection is not a failed one. Every WebSocket an app opens
/// goes through `HttpClient`, gets detached at the upgrade, and used to land
/// here as `ERR` — so an app that talks over a socket showed a screen of red
/// where nothing had gone wrong. The server's own answer to an upgrade is 101,
/// and that is what the row says now.
Object? networkStatusOf(HttpProfileRequestRef request) {
  if (networkIsUpgrade(request)) return request.response?.statusCode ?? 101;
  var error = request.request?.error ?? request.response?.error;
  if (error != null) return 'ERR';
  return request.response?.statusCode;
}

/// Start to response end, in milliseconds — the request object's own `endTime`
/// is only the request phase, which reads as sub-millisecond for a slow
/// server. Null while in flight.
num? networkDurationOf(HttpProfileRequestRef request) {
  var end = request.response?.endTime;
  if (end == null) return null;
  return end.difference(request.startTime).inMicroseconds / 1000;
}

/// The response's content length, when the server declared one.
int? networkSizeOf(HttpProfileRequestRef request) {
  var length = request.response?.contentLength;
  return length != null && length >= 0 ? length : null;
}

/// The failure, when there was one. Null for an upgrade — see [networkIsUpgrade].
String? networkErrorOf(HttpProfileRequestRef request) =>
    networkIsUpgrade(request)
    ? null
    : request.request?.error ?? request.response?.error;
