import 'dart:async';

import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart' show RPCError;

import 'handle.dart';
import 'connection.dart';

/// The drive transaction, as the guest registers it.
const driveExtension = 'ext.flutterware.act';

/// The human's own steps, as the guest registers the collection of them.
const beatsExtension = 'ext.flutterware.beats';

/// JSON-RPC's "Method not found" — what the VM answers for an extension the
/// isolate in the request does not have.
const _methodNotFound = -32601;

/// The app was there and said nothing in time.
///
/// Carries the diagnosis as its whole message: every surface renders a drive
/// error by stringifying it, and "DriveTimeout: …" in front of a sentence
/// written for an agent helps nobody.
class DriveTimeout implements Exception {
  DriveTimeout(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app answers, and what it answers is that it carries no drive guest.
///
/// A conclusion, and it has to be earned. The wire says only `Unknown
/// method "ext.flutterware.act"`, which is what an uninstrumented app returns
/// *and* what any correctly instrumented app returns when the question was put
/// to the wrong isolate (measured: a live app's worker isolate answers exactly
/// that, as does a call with no isolate at all). Saying "launch it through
/// flutterware" on the strength of that alone sends a correctly launched app
/// into a two-minute relaunch. So this is thrown only
/// after the VM has been asked which isolate holds the extension, and it
/// carries the answer.
class DriveNoGuest implements Exception {
  DriveNoGuest({this.census});

  /// The isolates that were asked, `✓` on any that had the extension — null
  /// when the VM could not be asked at all.
  final String? census;

  static const _sentence =
      'This app is running without the drive guest, so it can be inspected '
      'but not driven. Launch it through flutterware (the studio, `fw run '
      'launch` or MCP) to drive it.';

  /// The refusal as every surface renders it: by stringifying.
  static String describe({String? census}) => census == null
      ? _sentence
      : '$_sentence\nAsked the VM which isolate has `ext.flutterware.act` and '
            'none does. Isolates: $census.';

  @override
  String toString() => describe(census: census);
}

/// A held connection for the drive loop.
///
/// `RunCore`'s per-call connect-read-dispose is right for probes and wrong
/// for a loop of act calls: the drive transaction is called in bursts —
/// observe, tap, observe — and paying a fresh websocket and `getVM` per step
/// is pure latency. This holds one [RunConnection] across calls and drops it
/// on any error, so the next call reconnects against whatever the app has
/// become (a hot restart keeps the VM service; a relaunch does not).
///
/// Concurrent actors need no lease: the guest serializes transactions on its
/// side, and the journal is the coordination mechanism — two writers
/// interleave as two actors in one story.
class DriveSession {
  DriveSession(this.handle);

  /// A session over a connection the caller stood up, for a test — there is no
  /// uri to dial, so the handle is only the label in its refusals.
  @visibleForTesting
  factory DriveSession.forTesting(RunHandle handle, RunConnection connection) =>
      DriveSession(handle).._connection = Future.value(connection);

  RunHandle handle;

  /// Re-points the session at the run's current handle.
  ///
  /// The session outlives the snapshot it was created from, and the snapshot
  /// is what goes stale: a run observed mid-build has no VM uri yet, and a
  /// session frozen on that read would refuse "still building" forever after
  /// the app came up. Called on every act, so the dial uses whatever the last
  /// probe read. A connection held against a different uri is dropped, not
  /// reused.
  void refresh(RunHandle next) {
    if (_connection != null && next.vmService != _connectedUri) {
      unawaited(_drop());
    }
    handle = next;
  }

  /// What [_connection] was opened against, so [refresh] can tell a changed
  /// uri from a re-read of the same one.
  String? _connectedUri;

  /// The connect in flight or done — memoized as a future, so two overlapping
  /// acts on a fresh session share one websocket instead of the second
  /// silently orphaning the first.
  Future<RunConnection>? _connection;

  /// One drive transaction: `ext.flutterware.act` with [args], the guest's
  /// bundle back. Throws what the connection threw — the caller owns turning
  /// "no such extension" into "this app runs without the guest".
  ///
  /// Bounded by [_deadlineFor], because the guest's own "never hang" rule only
  /// covers a guest that is *running*. A backgrounded iOS app is suspended by
  /// the OS: it is not scheduled, so the extension is never dispatched and no
  /// answer ever comes. Measured 2026-08-11 — the MCP client gave up at 1800s,
  /// which is the one behavior this surface may not have. On the deadline the
  /// call is diagnosed ([_whyNoAnswer]) and thrown as a [DriveTimeout].
  ///
  /// A suspended app has two doors and both had to be shut. The session is
  /// dropped whenever a probe finds the app unresponsive, so the *next* call
  /// re-connects — and against a suspended process the connect is what times
  /// out, five seconds earlier and with `TimeoutException after 0:00:05` as
  /// its whole message. Measured while fixing the first door: an agent got a
  /// sentence about a future instead of a sentence about its app.
  Future<Map<String, dynamic>> act(Map<String, String> args) async {
    RunConnection connection;
    try {
      connection = await _ensure();
    } on TimeoutException {
      await _drop();
      throw DriveTimeout('Could not reach the app. $_notScheduled');
    }
    var deadline = _deadlineFor(args);
    try {
      return await _call(connection, args, deadline);
    } on RPCError catch (error) {
      if (error.code != _methodNotFound) {
        await _drop();
        rethrow;
      }
      // The isolate this connection picked does not have the extension. That
      // is two different facts — a wrong isolate, or no guest at all — and
      // only the VM can tell them apart, so it is asked before anything is
      // said. A wrong pick is repaired here rather than reported: the next
      // connect would guess the same way and be wrong the same way, which is
      // how one bad guess becomes a run that is permanently undriveable.
      var found = await connection.findIsolateWith(driveExtension);
      if (found.id case var id? when id != connection.isolateId) {
        connection.useIsolate(id);
        try {
          return await _call(connection, args, deadline);
        } on Object {
          await _drop();
          rethrow;
        }
      }
      await _drop();
      throw DriveNoGuest(census: found.census);
    } on TimeoutException {
      var why = await _whyNoAnswer(connection);
      await _drop();
      throw DriveTimeout(
        'The app did not answer in ${deadline.inSeconds}s. $why',
      );
    } on Object {
      await _drop();
      rethrow;
    }
  }

  /// Everything the guest has buffered of what the human did, cleared as it
  /// is handed over.
  ///
  /// Shares [act]'s connection and none of its diagnosis: this is called on a
  /// timer, so an app that is restarting, gone, or was never driveable must
  /// cost one dropped socket and not an isolate census. The caller counts
  /// failures; here they only reconnect.
  Future<List<Map>> beats() async {
    var connection = await _ensure();
    try {
      var response = await connection.service
          .callServiceExtension(beatsExtension, isolateId: connection.isolateId)
          .timeout(const Duration(seconds: 5));
      return (response.json?['human'] as List?)?.cast<Map>() ?? const [];
    } on Object {
      await _drop();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _call(
    RunConnection connection,
    Map<String, String> args,
    Duration deadline,
  ) async {
    var response = await connection.service
        .callServiceExtension(
          driveExtension,
          isolateId: connection.isolateId,
          args: args,
        )
        .timeout(deadline);
    return response.json ?? const {};
  }

  /// How long to wait for a bundle before calling the app unresponsive.
  ///
  /// Derived from what this very call asked the guest to spend rather than
  /// fixed, so raising `settleMs` for a slow screen does not turn into a
  /// timeout: the guest's own budgets, plus slack for the parts that are not
  /// budgeted — the screenshot, the tree walk, the round trip, and another
  /// actor's transaction this one may be queued behind.
  ///
  /// `scrollTo` is the one verb whose work is bounded by a count instead of a
  /// clock: `maxScrolls` drags, each with a pump. It gets an allowance per
  /// scroll on top, so a long list does not read as a hung app.
  Duration _deadlineFor(Map<String, String> args) {
    int ms(String key, int fallback) =>
        int.tryParse(args[key] ?? '') ?? fallback;
    var budget =
        ms('settleMs', 800) + ms('actTimeoutMs', 3000) + ms('waitMs', 0);
    if (args['verb'] == 'scrollTo') budget += ms('maxScrolls', 50) * 500;
    return Duration(milliseconds: budget) + const Duration(seconds: 20);
  }

  /// Why nothing came back, asked of the VM itself.
  ///
  /// The distinction is worth a round trip: if the VM service answers, the
  /// process is being scheduled and something inside the app is slow or stuck;
  /// if it does not, the process is not running at all — which on a phone is
  /// the ordinary case of an app that went to the background, not a fault.
  Future<String> _whyNoAnswer(RunConnection connection) async {
    try {
      await connection.service.getVersion().timeout(const Duration(seconds: 2));
      return 'Its VM service still answers, so the app is running but this '
          'step is slow or stuck: an animation that never ends, or another '
          'step queued ahead of this one. Try again with a larger settleMs, '
          'or use `observe` to see the screen.';
    } on Object {
      return _notScheduled;
    }
  }

  /// The diagnosis both doors share.
  ///
  /// Says what to do rather than what broke, and says the step is not lost
  /// because that is the surprising part: the guest is not gone, it is
  /// unscheduled, and the request it was handed runs the moment the OS gives
  /// it a thread again (measured — a tap sent to a backgrounded app landed on
  /// resume).
  static const _notScheduled =
      'Its VM service does not answer, so the process is not being scheduled: '
      'on iOS the OS suspends a backgrounded app, and it answers nothing until '
      'it is in the foreground again. Bring the app to the front and retry. '
      'The step is not lost: a suspended app runs the request when it '
      'resumes.';

  Future<RunConnection> _ensure() {
    if (_connection case var held?) return held;
    var uri = handle.vmService;
    if (uri == null) {
      throw StateError(
        '${handle.entrypointLabel} is still building. Its progress is in '
        '${handle.logPath}.',
      );
    }
    var connecting = RunConnection.connect(uri);
    _connection = connecting;
    _connectedUri = uri;
    // A failed connect must not stay memoized: the next act should try again,
    // not rethrow a stale failure forever. The caller still sees the error —
    // this side-chain only clears the cache.
    unawaited(
      connecting.then(
        (_) {},
        onError: (Object _) {
          if (_connection == connecting) _connection = null;
        },
      ),
    );
    return connecting;
  }

  Future<void> _drop() async {
    var held = _connection;
    _connection = null;
    if (held != null) {
      try {
        await (await held).close();
      } on Object {
        // Dropped because it was broken; a close that fails too says nothing
        // new.
      }
    }
  }

  Future<void> close() => _drop();
}
