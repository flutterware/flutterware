import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show pid;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'info.dart';
import 'inspector_core.dart';
import 'protocol.dart';

/// What a command handler receives and returns. A returned map becomes the
/// response payload as-is; anything else is wrapped as `{"value": …}`.
///
/// The server-facing spelling of [InspectorCommandHandler] — the same type,
/// under the name this library has always published.
typedef ServerCommandHandler = InspectorCommandHandler;

/// The primitives a Dart server reports through.
///
/// This is the whole public runtime surface: `event`, `span`/`spanSync`,
/// `handle`, and zone correlation. Adapters — a shelf middleware, a query
/// interceptor, a log listener — are copy-paste snippets over these four,
/// deliberately not code in this package (spec decision 5).
///
/// There is no init call. The first reported event activates the
/// inspector: it binds a unix socket in `~/.flutterware/run`, publishes a
/// `srv-*.json` handle, and replays its ring to whoever attaches. When the
/// gates say no — a release build, a machine without a run dir,
/// `FW_SERVER_INSPECT=0` — every primitive is a cheap no-op and the server
/// runs exactly as if this library were not there.
class FlutterwareServer {
  FlutterwareServer._();

  /// The zone key the correlation id travels under. A request-scoped adapter
  /// (the shelf middleware) runs its handler in
  /// `runZoned(zoneValues: {FlutterwareServer.requestIdKey: id}, …)`, and
  /// every event and span emitted below it is stamped automatically.
  static const Symbol requestIdKey = #fwRequestId;

  /// The correlation id of the current zone, if an adapter installed one.
  static Object? get correlationId => Zone.current[requestIdKey];

  /// The zone key a device's step travels under — the tap, by a person or an
  /// agent, that caused the request. The adapter reads it from the request's
  /// `x-fw-step` header and puts it in the zone beside [requestIdKey]; every
  /// event emitted below it then carries it as `step`, so one tap's
  /// consequences — queries, messages, broadcasts — gather as one trace.
  static const Symbol stepKey = #fwStep;

  /// Says which user the current request is — once auth knows. The world
  /// maps the id to a person.
  static void identify(String user) => event('identify', {'user': user});

  /// Says the server delivered [what] to [user] outside any response to them:
  /// a WebSocket frame, a sync, a push. The one kind of consequence no device
  /// records, because it arrives on a connection nobody asked on.
  static void reach(String user, String what) =>
      event('reach', {'user': user, 'what': what});

  static ServerInspector? _inspector;
  static var _started = false;
  static String? _configuredName;
  static String? _configuredRoot;

  /// Overrides the defaults — the entrypoint basename for the name,
  /// `Directory.current` for the project root. Must run before the first
  /// event: after activation the handle file is already published, and a
  /// silently ignored override would be worse than this error.
  static void configure({String? name, String? root}) {
    if (_started) {
      throw StateError(
        'FlutterwareServer.configure must run before the first event.',
      );
    }
    _configuredName = name ?? _configuredName;
    _configuredRoot = root ?? _configuredRoot;
  }

  /// Reports one event on [channel]. Fire-and-forget and safe everywhere:
  /// when the inspector is inert this is a null check and a return.
  ///
  /// [details] is for the heavy parts — headers, bodies — held server-side
  /// in a byte-capped store and fetched only when an attacher asks
  /// (`meta/detail`, spec decision 11). The event itself stays small, so the
  /// hot path and the ring never carry a body.
  static void event(
    String channel,
    Map<String, Object?> payload, {
    Map<String, Object?>? details,
  }) {
    var step = Zone.current[stepKey];
    _active?.addEvent(
      channel,
      step == null || payload.containsKey('step')
          ? payload
          : {...payload, 'step': '$step'},
      rid: _rid(),
      details: details,
    );
  }

  /// Publishes the server's self-description — base URL, environment, links,
  /// connections, config. Call it once startup knows its facts (after `serve`
  /// returns, so the port is real); call it again any time to update only the
  /// sections the new [value] names ([ServerInfo.fromEvents] merges per
  /// section on the attacher side).
  ///
  /// Like every primitive, this activates the inspector on first use and is a
  /// no-op when the gates say no — an `info` call is safe in code that also
  /// runs in production.
  static void info(ServerInfo value) {
    event(infoChannel, value.toJson());
  }

  /// Runs [body] and reports it as a timed event on [channel] — duration in
  /// fractional milliseconds under `ms`, the error under `error` if it threw.
  /// The error is rethrown; this observes, it never swallows.
  static Future<T> span<T>(
    String channel,
    Map<String, Object?> payload,
    Future<T> Function() body,
  ) async {
    var watch = Stopwatch()..start();
    Object? error;
    try {
      return await body();
    } catch (e) {
      error = e;
      rethrow;
    } finally {
      _spanEvent(channel, payload, watch, error);
    }
  }

  /// [span] for synchronous work — a sqlite call should not become async just
  /// to be observed.
  static T spanSync<T>(
    String channel,
    Map<String, Object?> payload,
    T Function() body,
  ) {
    var watch = Stopwatch()..start();
    Object? error;
    try {
      return body();
    } catch (e) {
      error = e;
      rethrow;
    } finally {
      _spanEvent(channel, payload, watch, error);
    }
  }

  /// Registers the handler an attacher's `req` frames on [channel]/[method]
  /// reach. This is what makes queries explainable: the handler runs *inside*
  /// the server, against its own live connections.
  static void handle(
    String channel,
    String method,
    ServerCommandHandler handler,
  ) {
    _active?.registerHandler(channel, method, handler);
  }

  static void _spanEvent(
    String channel,
    Map<String, Object?> payload,
    Stopwatch watch,
    Object? error,
  ) {
    event(channel, {
      ...payload,
      'ms': watch.elapsedMicroseconds / 1000,
      if (error != null) 'error': '$error',
    });
  }

  static String? _rid() {
    var id = correlationId;
    return id?.toString();
  }

  static ServerInspector? get _active {
    if (!_started) {
      _started = true;
      _inspector = _tryStart();
    }
    return _inspector;
  }

  /// Never throws: a broken inspector must cost the server nothing but its
  /// observability.
  static ServerInspector? _tryStart() {
    try {
      var runDir = existingRunDir();
      var enabled = serverInspectionEnabled(
        product: const bool.fromEnvironment('dart.vm.product'),
        envOverride: Platform.environment['FW_SERVER_INSPECT'],
        runDirExists: runDir != null,
      );
      if (!enabled || runDir == null) return null;
      return ServerInspector.start(
        runDir: runDir,
        projectRoot: _configuredRoot ?? p.canonicalize(Directory.current.path),
        name: _configuredName ?? _defaultName(),
      );
    } on Object {
      return null;
    }
  }

  static String _defaultName() =>
      p.basenameWithoutExtension(Platform.script.path);

  /// Routes the primitives to [inspector] — a test's temp-dir instance —
  /// instead of letting the gates decide against the real environment.
  @visibleForTesting
  static void debugAttachInspector(ServerInspector inspector) {
    _started = true;
    _inspector = inspector;
  }

  /// Tears down the active inspector and re-arms the gates, so a test can run
  /// several activations in one process. Not part of the server-facing API.
  @visibleForTesting
  static Future<void> reset() async {
    _started = false;
    _configuredName = null;
    _configuredRoot = null;
    var inspector = _inspector;
    _inspector = null;
    await inspector?.stop();
  }
}

/// One attached unix-socket connection.
class _SocketPeer implements InspectorPeer {
  _SocketPeer(this.socket);

  final Socket socket;

  @override
  void send(Map<String, Object?> frame) => socket.write(encodeFrame(frame));

  @override
  void close() => socket.destroy();
}

/// The machinery behind [FlutterwareServer], constructible directly so tests
/// can point it at a temp dir instead of faking the gates.
///
/// This class is now only the transport: a unix socket in the run dir, a
/// `srv-*.json` handle beside it, and the predecessor cleanup that makes a
/// restart self-healing. The ring, the channels, the handlers, the detail
/// store and the attach handshake are [InspectorCore], which knows nothing
/// about sockets and compiles into a Flutter app — see
/// `docs/superpowers/specs/2026-08-11-devbar-run-bridge-design.md`.
class ServerInspector {
  ServerInspector._({
    required this.runDir,
    required this.projectRoot,
    required this.name,
    required this.pid,
    required int ringSize,
    required int detailsByteCap,
  }) {
    _core = InspectorCore(
      ringSize: ringSize,
      detailsByteCap: detailsByteCap,
      identity: () => {
        'name': name,
        'pid': pid,
        'projectRoot': projectRoot,
        'startedAt': startedAt.toUtc().toIso8601String(),
      },
      onEvent: (channel, payload) {
        if (channel == infoChannel) _mirrorInfo(payload);
      },
    );
  }

  /// Starts publishing immediately, but asynchronously: events reported while
  /// the socket is still binding only land in the ring, which is where an
  /// attacher would find them anyway.
  ///
  /// [pid] defaults to this process — overridable so a single-process test
  /// can stage a "restart", which is otherwise invisible: the handle key is
  /// `name-pid`, and two inspectors in one test share a pid.
  factory ServerInspector.start({
    required String runDir,
    required String projectRoot,
    required String name,
    int ringSize = 500,
    int detailsByteCap = 16 * 1024 * 1024,
    int? pid,
  }) {
    var inspector = ServerInspector._(
      runDir: runDir,
      projectRoot: projectRoot,
      name: name,
      ringSize: ringSize,
      detailsByteCap: detailsByteCap,
      pid: pid ?? io.pid,
    );
    unawaited(inspector._publish());
    return inspector;
  }

  final String runDir;
  final String projectRoot;
  final String name;

  final startedAt = DateTime.now();

  /// The ring, the channels, the handlers — everything that is not a socket.
  /// Private: [ServerInspector]'s published surface does not change because
  /// its insides were split.
  late final InspectorCore _core;

  var _stopped = false;

  ServerSocket? _socket;
  String? _socketPath;
  String? _handlePath;

  /// Resolves when the handle is on disk — what tests await. A publish that
  /// failed resolves too: the server must not care.
  Future<void> get published => _published.future;
  final _published = Completer<void>();

  String get _baseName =>
      serverHandleBaseName(projectRoot: projectRoot, name: name, pid: pid);

  final int pid;

  /// Destroys every attached connection without touching the handle or the
  /// socket — a transient drop, as a test stages it.
  @visibleForTesting
  void debugDropConnections() => _core.detachAll();

  void addEvent(
    String channel,
    Map<String, Object?> payload, {
    String? rid,
    Map<String, Object?>? details,
  }) => _core.addEvent(channel, payload, rid: rid, details: details);

  String? _mirroredBaseUrl;
  String? _mirroredEnvironment;

  /// Copies `baseUrl` and `environment` from an `info` publish into the
  /// handle file, so scan-only readers see them. Before [_publish] finishes
  /// there is no file yet — the values are held and land in the initial
  /// write, which matters because the very first event of a server's life
  /// is often the `info` call that activates it.
  void _mirrorInfo(Map<String, Object?> payload) {
    var baseUrl = payload['baseUrl'];
    var environment = payload['environment'];
    var changed = false;
    if (baseUrl is String && baseUrl != _mirroredBaseUrl) {
      _mirroredBaseUrl = baseUrl;
      changed = true;
    }
    if (environment is String && environment != _mirroredEnvironment) {
      _mirroredEnvironment = environment;
      changed = true;
    }
    if (changed && _handlePath != null) {
      try {
        _writeHandle(_handlePath!);
      } on Object {
        // The mirror is decoration; failing to refresh it must not cost the
        // server anything.
      }
    }
  }

  void _writeHandle(String handlePath) {
    var handle = ServerHandle(
      projectRoot: projectRoot,
      name: name,
      socketPath: _socketPath!,
      pid: pid,
      startedAt: startedAt,
      baseUrl: _mirroredBaseUrl,
      environment: _mirroredEnvironment,
    );
    File(handlePath).writeAsStringSync(jsonEncode(handle.toJson()));
  }

  void registerHandler(
    String channel,
    String method,
    ServerCommandHandler handler,
  ) => _core.registerHandler(channel, method, handler);

  Future<void> _publish() async {
    try {
      await _cleanUpPredecessors();
      var socketPath = p.join(runDir, '$_baseName.sock');
      // The 104-byte `sun_path` cap, checked here so a pathological home
      // directory degrades to "inert" rather than to an OS error mid-request.
      if (socketPath.length > 103) throw StateError('socket path too long');
      _socketPath = socketPath;
      _socket = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      _socket!.listen(_onConnection);
      var handlePath = p.join(runDir, '$_baseName.json');
      _writeHandle(handlePath);
      _handlePath = handlePath;
    } on Object {
      await stop();
    } finally {
      if (!_published.isCompleted) _published.complete();
    }
  }

  /// Deletes dead handles this same server left behind — same project root
  /// and name, different pid, socket answering nothing. Restarts self-clean
  /// instead of waiting a day for the sweep.
  Future<void> _cleanUpPredecessors() async {
    var prefix =
        'srv-${projectRootHash(projectRoot)}-${sanitizeServerName(name)}-';
    for (var handle in scanServerHandles(runDir)) {
      var fileName = p.basename(handle.handlePath!);
      if (!fileName.startsWith(prefix) || handle.pid == pid) continue;
      if (await _answers(handle.socketPath)) continue;
      deleteServerHandle(handle);
    }
  }

  static Future<bool> _answers(String socketPath) async {
    try {
      var socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(milliseconds: 300));
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  /// A connection is not an attachment: the peer is created here so replies
  /// have somewhere to go, and only [InspectorCore.attach] — reached by a
  /// `meta/attach` request — puts it on the broadcast list.
  void _onConnection(Socket socket) {
    var peer = _SocketPeer(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            var frame = tryDecodeFrame(line);
            if (frame != null) _core.handleFrame(peer, frame);
          },
          onDone: () => _core.detach(peer),
          onError: (Object _) => _core.detach(peer),
          cancelOnError: true,
        );
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _core.stop();
    await _socket?.close();
    for (var path in [_handlePath, _socketPath]) {
      if (path == null) continue;
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // Already gone — a sweep or a successor got there first.
      }
    }
  }
}
