/// The channel protocol's second transport: an inspected **Flutter app**,
/// reached over the VM service from the host.
///
/// The socket transport (`inspector.dart`) can write to a peer whenever it
/// likes. This one cannot: a VM service extension is request/response, and the
/// only thing an app can push is `postEvent`. So the shape here is a hybrid:
///
/// - **the host pulls.** Every call to [channelExtension] hands the core a
///   frame (or nothing) and comes back with whatever that peer has queued —
///   hello, replay, live events, responses.
/// - **the app nudges.** When frames queue up with no call in flight, the app
///   posts one payload-free [channelNudgeKind] event meaning "there is
///   something to pull".
///
/// The nudge is coalesced, and that is the whole trick. At most one is
/// outstanding per peer between drains, so the nudge rate is bounded by how
/// often the host pulls, never by how fast events arrive. A bulk sync writing
/// five thousand rows produces one nudge, not five thousand — which is what
/// makes it safe to put this on the same `Extension` stream Flutter already
/// posts `Flutter.Frame` to on every frame.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import '../channels/panels.dart';
import 'frames.dart';
import 'inspector_core.dart';

/// The one extension. Params: `peer` (host-chosen id), optional `frame` (a
/// JSON-encoded request frame), optional `detach`. Returns
/// `{"frames": [...], "dropped": n}`.
const channelExtension = 'ext.flutterware.channel';

/// The nudge's event kind on the `Extension` stream. Its data is `{"peer": …}`
/// and nothing else: it says *pull*, it does not carry the news.
const channelNudgeKind = 'flutterware.channel';

/// A peer that cannot be written to, only drained.
class _QueuedPeer implements InspectorPeer {
  _QueuedPeer(this.id, this.limit, this._onQueued);

  final String id;
  final int limit;
  final void Function(_QueuedPeer peer) _onQueued;

  final _queue = Queue<Map<String, Object?>>();

  /// Frames the bound threw away since the last drain. Reported so the host
  /// knows its view has a hole and can re-attach — the events themselves are
  /// still in the core's ring, so re-attaching genuinely recovers them.
  var dropped = 0;

  /// A nudge is outstanding; no more until someone drains.
  var nudged = false;
  var closed = false;

  @override
  void send(Map<String, Object?> frame) {
    if (closed) return;
    _queue.add(frame);
    while (_queue.length > limit) {
      _queue.removeFirst();
      dropped++;
    }
    _onQueued(this);
  }

  @override
  void close() {
    closed = true;
    _queue.clear();
  }

  Map<String, Object?> drain() {
    var frames = _queue.toList();
    _queue.clear();
    var lost = dropped;
    dropped = 0;
    nudged = false;
    return {'frames': frames, if (lost > 0) 'dropped': lost};
  }
}

class VmServiceTransport {
  VmServiceTransport({
    required this.core,
    this.queueLimit = 2000,
    void Function(String kind, Map<String, Object?> data)? postEvent,
  }) : _postEvent = postEvent ?? developer.postEvent;

  final InspectorCore core;

  /// How a nudge leaves the process. Injectable because the coalescing rule is
  /// the load-bearing part of this transport and `developer.postEvent` goes
  /// somewhere unobservable from a test.
  final void Function(String kind, Map<String, Object?> data) _postEvent;

  /// Frames held per peer between pulls. Past this the oldest are dropped and
  /// counted — an unbounded queue behind a host that stopped pulling is a
  /// memory leak in someone else's app.
  final int queueLimit;

  final _peers = <String, _QueuedPeer>{};

  /// The peer whose extension call is being served, so the frames that call
  /// produces are answered rather than nudged about. Without this every attach
  /// would post a nudge for the replay it is already returning.
  ///
  /// Per peer, not a bool — found by the database panel, 2026-08-12. An
  /// event broadcast while *another* peer's exchange was in flight (a panel
  /// action invoked over MCP, say) queued on this peer but was never nudged
  /// about, because the global flag said "a call will answer it" when that
  /// call was draining a different queue. The frame then sat unread until the
  /// next unrelated pull — for a cockpit quietly watching a feed, forever.
  _QueuedPeer? _serving;

  var _registered = false;

  void registerExtensions() {
    if (_registered) return;
    _registered = true;
    developer.registerExtension(channelExtension, (method, params) async {
      Object? result;
      try {
        result = await exchange(params);
      } catch (e, stack) {
        result = {'error': '$e', 'stack': '$stack'};
      }
      return developer.ServiceExtensionResponse.result(jsonEncode(result));
    });
  }

  /// Serves one exchange: apply the incoming frame, if any, and drain that
  /// peer's queue. Public because it *is* the transport — a host that reaches
  /// the app some other way (an embedder, a test) drives this directly instead
  /// of going through the service extension.
  ///
  /// The pause before draining is not a hedge, it is the common case.
  /// `InspectorCore` answers a request from an `async` method, so even a
  /// handler that returns a value immediately enqueues its response one
  /// microtask after `handleFrame` returns. Draining synchronously would send
  /// every command's caller away empty-handed and make it wait for a nudge and
  /// a second round trip — measured on a real VM service before this existed:
  /// `EXPLAIN -> {"frames":[]}`. A genuinely async handler still misses this
  /// window and still answers on a later pull, which is the case the nudge is
  /// for.
  Future<Map<String, Object?>> exchange(Map<String, String> params) async {
    var id = params['peer'] ?? 'default';
    if (params['detach'] == 'true') {
      var peer = _peers.remove(id);
      if (peer != null) core.detach(peer);
      return const {'frames': <Object?>[], 'detached': true};
    }
    var peer = _peers.putIfAbsent(
      id,
      () => _QueuedPeer(id, queueLimit, _onQueued),
    );
    // Held across the pause, so a frame that lands during it is answered by
    // this call rather than nudged about and then drained anyway.
    _serving = peer;
    try {
      var encoded = params['frame'];
      if (encoded != null) {
        var frame = tryDecodeFrame(encoded);
        if (frame != null) core.handleFrame(peer, frame);
      }
      await Future<void>.delayed(Duration.zero);
      return peer.drain();
    } finally {
      _serving = null;
    }
  }

  void _onQueued(_QueuedPeer peer) {
    if (identical(peer, _serving) || peer.nudged) return;
    peer.nudged = true;
    _postEvent(channelNudgeKind, {'peer': peer.id});
  }

  /// Forgets every peer — what a hot restart means for attachments made to the
  /// isolate that no longer exists.
  void detachAll() {
    for (var peer in _peers.values.toList()) {
      core.detach(peer);
    }
    _peers.clear();
  }
}

/// The app-side singleton: one core for the whole process, installed by the
/// run guest, filled with channels by whoever has something to report.
///
/// A core with no channels is not a wasted one — it answers `meta/attach` with
/// an empty channel list, which is exactly how the cockpit distinguishes
/// "an app with nothing to say" from "an app too old to ask".
class GuestChannels {
  GuestChannels._();

  /// Extra facts for the `meta/attach` reply. Whoever knows something the host
  /// should see on attach — an app's name, a devbar's plugin list — puts it
  /// here; it is read per attach, so late arrivals still show up.
  static final describe = <String, Object?>{};

  static final InspectorCore core = InspectorCore(
    identity: () => {'protocol': protocolVersion, ...describe},
  );

  /// The panels being served on [core]. Created on first use, so an app that
  /// declares none pays nothing.
  static final Panels panels = Panels(core);

  static VmServiceTransport? _transport;

  /// Whether anything can reach this app's channels — true once the run guest
  /// has installed the transport.
  ///
  /// What the devbar reads to decide it is being watched: outside flutterware
  /// nothing is listening, so mirroring panels would be work for no reader,
  /// and the overlay is the only surface there is.
  static bool get installed => _transport != null;

  /// Registers [channelExtension]. Call once, before `runApp`.
  static void install() {
    (_transport ??= VmServiceTransport(core: core)).registerExtensions();
  }
}
