import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'daemon_address.dart';
import 'protocol.dart';
import 'catalog_source.dart';

/// Talks to the compiler daemon, which runs as a separate plain-Dart process.
///
/// The daemon is not a workaround. It is where the catalog pipeline lives so
/// that the GUI, `fw`, and an agent are three *drivers* of one pipeline rather
/// than three copies of it: a screenshot must not require a running GUI, and a
/// second consumer must not repeat the first one's work.
///
/// So [connect] connects before it considers spawning. The first caller pays
/// for the scan, the bundle and the cold compile; every one after gets a
/// compiler that already holds the whole catalog in memory. The embedder host
/// is not in that list — see [hostPath].
///
/// (It was once also a containment measure: `package:frontend_server_client`
/// spawns the compiler through `Platform.resolvedExecutable`, which inside a
/// Flutter app is the app binary, so compiling in-process relaunched the app
/// recursively. `FrontendServer` takes an explicit executable, so that class of
/// bug is gone and no longer the reason for anything here.)
/// The shape of [CompilerDaemonClient.connect], for callers that take the
/// connect as a parameter so a test can hold it open.
///
/// The config is a thunk: building one reads the project's package config off
/// the disk, and a connector that answers a catalog compiled into the host
/// never needs it — nor has a disk to read it from.
typedef DaemonConnector = Future<(CatalogSource, DaemonReady)> Function({
  required String dartExecutable,
  required DaemonConfig Function() config,
  void Function(String)? onLog,
  void Function(DaemonProgress)? onProgress,
});

class CompilerDaemonClient implements CatalogSource {
  CompilerDaemonClient._(
    this._socket,
    this.address,
    this._onLog,
    this._onProgress,
  ) {
    _lines = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: _onGone, onDone: _onGone);
    // **The death arrives twice, and the second copy has no owner.** A daemon
    // that dies with a request still unread in its receive buffer resets the
    // connection instead of closing it — Linux does, macOS does not — and the
    // reset is delivered both to the stream above and to the sink's [done],
    // which nothing awaits. An unowned error there is an unhandled error in
    // whatever zone the client was built in: the GUI's, or a test's, where it
    // fails a test that the stream half had already handled correctly.
    // [_onGone] is idempotent, so whichever copy arrives first is the one that
    // tells everybody and the other is dropped.
    unawaited(_socket.done.then((_) {}, onError: _onGone));
  }

  final Socket _socket;
  final DaemonAddress address;
  final void Function(String)? _onLog;

  /// Where a [DaemonProgress] goes.
  ///
  /// A callback taken at [connect] rather than a stream on the client, because
  /// every message it carries arrives *before* [connect] returns: a caller that
  /// waited for a client and then subscribed would have missed the whole start
  /// it was trying to narrate.
  final void Function(DaemonProgress)? _onProgress;

  late final StreamSubscription<String> _lines;

  var _nextRequestId = 0;

  /// The reply each in-flight [select] is waiting for, by request id.
  ///
  /// Futures rather than a filtered stream. This used to be
  /// `_responses.where(…).first` over `socket.asBroadcastStream()`, and a
  /// broadcast stream *drops* what arrives while nobody is listening — verified,
  /// not assumed. Registering a completer before the request is written closes
  /// that window by construction, and gives the two things a filtered stream
  /// could not: somewhere to put a timeout, and somewhere to deliver "the daemon
  /// died" to every caller waiting on it.
  final _pending = <int, Completer<DaemonCompiled>>{};

  /// The same, for [hostPath]'s requests. Its own map because the two replies
  /// are different types, and a `Completer<DaemonResponse>` shared between
  /// them would put the cast back at every call site.
  final _hostPending = <int, Completer<HostReady>>{};

  /// The daemon's first word, which is either [DaemonReady] or [DaemonFailed].
  final _handshake = Completer<DaemonResponse>();

  final _changes = StreamController<CatalogChanged>.broadcast();

  /// An event and not a value, unlike [lastChange]: this message carries no
  /// snapshot to catch up on — a client attaching after assets moved reads a
  /// bundle that already moved with them.
  final _assetsChanges = StreamController<AssetsChanged>.broadcast();

  /// The most recent [CatalogChanged], whether or not anything was listening.
  ///
  /// State rather than a replayed event, and the distinction matters.
  /// This message is a snapshot — the servable set and the quarantine — so a
  /// caller that subscribed after one landed does not need the event, it needs
  /// the value. There is a real window between [connect] returning and a caller
  /// reaching `.listen`, and a panel that missed the only notice it was going to
  /// get would go on offering an entry the daemon cannot build.
  ///
  /// Injecting it into [catalogChanges] instead was tried and was worse: the
  /// generator that did it subscribed to the live stream one microtask after the
  /// caller listened, so a change arriving inside *that* window went to the held
  /// value and was never delivered to the stream already waiting for it. Only a
  /// real daemon caught it — the announcement checks in
  /// `integration_test/compiler_daemon_test.dart` are what stand there now. A
  /// stream that is only a stream, and a value that is only a value, has no such
  /// window.
  @override
  CatalogChanged? get lastChange => _lastChange;
  CatalogChanged? _lastChange;

  /// Why the connection ended, once it has.
  String? _gone;

  /// Connects to the daemon for [config], starting one if none is serving.
  ///
  /// [dartExecutable] must be a real Dart VM — pass the Flutter SDK's `dart`.
  /// [connect], in the shape of a [DaemonConnector].
  static Future<(CatalogSource, DaemonReady)> connector({
    required String dartExecutable,
    required DaemonConfig Function() config,
    void Function(String)? onLog,
    void Function(DaemonProgress)? onProgress,
  }) => connect(
    dartExecutable: dartExecutable,
    config: config(),
    onLog: onLog,
    onProgress: onProgress,
  );

  static Future<(CompilerDaemonClient, DaemonReady)> connect({
    required String dartExecutable,
    required DaemonConfig config,
    void Function(String)? onLog,
    void Function(DaemonProgress)? onProgress,
    Duration readyTimeout = const Duration(minutes: 5),
  }) async {
    // Compiled before the address is derived, not after: the daemon's own build
    // is part of the config, and so part of the address, so a client never
    // attaches to a daemon compiled from different sources than it expects.
    var launch = await _ensureCompiled(
      dartExecutable: dartExecutable,
      appPackageRoot: config.appPackageRoot,
      onLog: onLog,
    );
    try {
      return await _launch(
        launch,
        config: config,
        onLog: onLog,
        onProgress: onProgress,
        readyTimeout: readyTimeout,
      );
    } on _RejectedKernel catch (rejection) {
      // The snapshot on disk is not loadable by this Dart. Recompiling is the
      // whole remedy — see [_RejectedKernel] for why that is a cache decision
      // rather than something to report — and the second attempt goes through
      // [_ensureCompiled] rather than reusing the first launch so that the
      // address is re-derived from whatever the recompile actually produced.
      onLog?.call(rejection.rebuilding);
      var rebuilt = await _ensureCompiled(
        dartExecutable: dartExecutable,
        appPackageRoot: config.appPackageRoot,
        onLog: onLog,
        force: true,
      );
      try {
        return await _launch(
          rebuilt,
          config: config,
          onLog: onLog,
          onProgress: onProgress,
          readyTimeout: readyTimeout,
        );
      } on _RejectedKernel catch (again) {
        throw StateError(again.fatal(previously: rejection.compiledBy));
      }
    }
  }

  /// Derives the address for [launch] and gets a client onto it.
  ///
  /// Split out of [connect] because the retry above re-runs all of it: a
  /// recompile can move [_DaemonLaunch.revision], and a revision that moved is a
  /// different daemon at a different socket.
  static Future<(CompilerDaemonClient, DaemonReady)> _launch(
    _DaemonLaunch launch, {
    required DaemonConfig config,
    required Duration readyTimeout,
    void Function(String)? onLog,
    void Function(DaemonProgress)? onProgress,
  }) async {
    config = config.withDaemonRevision(launch.revision);
    var address = DaemonAddress(config);
    address.ensureRunDir();

    return _shakeHands(
      await _attachOrSpawn(
        address: address,
        launch: launch,
        config: config,
        onLog: onLog,
      ),
      address: address,
      onLog: onLog,
      onProgress: onProgress,
      readyTimeout: readyTimeout,
    );
  }

  /// Attaches to the daemon already serving [address], and fails if none is.
  ///
  /// [connect] minus everything with a side effect: no snapshot, no lock, no
  /// spawn. For a caller that knows a daemon is up and does not want to be the
  /// one that starts one — and for a test, which is the only present user.
  static Future<(CompilerDaemonClient, DaemonReady)> attach({
    required DaemonAddress address,
    void Function(String)? onLog,
    void Function(DaemonProgress)? onProgress,
    Duration readyTimeout = const Duration(minutes: 5),
  }) async {
    var socket = await _connect(address);
    if (socket == null) {
      throw StateError('nothing is serving ${address.socketPath}');
    }
    return _shakeHands(
      socket,
      address: address,
      onLog: onLog,
      onProgress: onProgress,
      readyTimeout: readyTimeout,
    );
  }

  /// Waits for the daemon's first word, which is what decides whether there is a
  /// client at all.
  ///
  /// The client is built *before* the handshake rather than after, because it is
  /// what reads the socket: constructing it is how the pump starts, and the ready
  /// message is just the first thing the pump delivers. The socket is never held
  /// in a local of its own past here — the client owns it from the moment it
  /// exists, and [close] is the only thing that ends it.
  static Future<(CompilerDaemonClient, DaemonReady)> _shakeHands(
    Socket socket, {
    required DaemonAddress address,
    required Duration readyTimeout,
    void Function(String)? onLog,
    void Function(DaemonProgress)? onProgress,
  }) async {
    var client = CompilerDaemonClient._(socket, address, onLog, onProgress);
    var first = await client._handshake.future.timeout(
      readyTimeout,
      onTimeout: () => throw StateError(
        'the compiler daemon did not become ready within '
        '${readyTimeout.inSeconds}s. See ${address.logPath}',
      ),
    );

    switch (first) {
      case DaemonReady():
        return (client, first);
      case DaemonFailed(:var message, :var stackTrace):
        await client.close();
        throw StateError('the compiler daemon failed: $message\n$stackTrace');
      case DaemonCompiled():
      case CatalogChanged():
      case AssetsChanged():
      case HostReady():
      // Unreachable: progress does not complete the handshake. Listed because
      // the switch is exhaustive over the sealed response, which is what makes
      // another message a compile error here rather than a silent drop.
      case DaemonProgress():
        await client.close();
        throw StateError('the daemon spoke before it was ready: $first');
    }
  }

  /// Sorts one line from the daemon to whoever is waiting for it.
  ///
  /// The whole reason this is a method rather than a chain of stream operators:
  /// a reply goes to *its* caller's future, an event goes to the event stream or
  /// is held for the first subscriber, and a line that is not protocol at all is
  /// a log. Three destinations, one of which has to be reliable.
  void _onLine(String line) {
    var json = tryDecodeLine(line);
    // Anything the daemon writes that is not protocol is a log, not a reason to
    // fail.
    if (json == null) {
      _onLog?.call(line);
      return;
    }
    DaemonResponse response;
    try {
      response = DaemonResponse.decode(json);
    } on FormatException catch (e) {
      // An older client against a newer daemon. Symmetrical with the daemon's
      // own guard, and for the same reason: one unreadable line must not take
      // down a connection that is otherwise working.
      _onLog?.call('unreadable line from the daemon: $e');
      return;
    }

    switch (response) {
      case DaemonReady():
      case DaemonFailed():
        if (!_handshake.isCompleted) _handshake.complete(response);
      case DaemonCompiled(:var requestId):
        // Matched on the id, not on "the next compiled message". Absent means a
        // reply that arrived after its caller gave up — dropped, not an error.
        _pending.remove(requestId)?.complete(response);
      case HostReady(:var requestId):
        _hostPending.remove(requestId)?.complete(response);
      case CatalogChanged():
        _lastChange = response;
        if (!_changes.isClosed) _changes.add(response);
      case AssetsChanged():
        if (!_assetsChanges.isClosed) _assetsChanges.add(response);
      case DaemonProgress():
        _onProgress?.call(response);
    }
  }

  /// The connection ended. Everyone waiting on it has to be told, once.
  void _onGone([Object? error]) {
    if (_gone != null) return;
    _gone =
        'the compiler daemon closed the connection'
        '${error == null ? '' : ': $error'}\n${_tailLog(address)}';
    var reason = StateError(_gone!);
    if (!_handshake.isCompleted) _handshake.completeError(reason);
    for (var completer in _pending.values.toList()) {
      if (!completer.isCompleted) completer.completeError(reason);
    }
    _pending.clear();
    for (var completer in _hostPending.values.toList()) {
      if (!completer.isCompleted) completer.completeError(reason);
    }
    _hostPending.clear();
    if (!_changes.isClosed) _changes.close();
    if (!_assetsChanges.isClosed) _assetsChanges.close();
  }

  /// Fires whenever the set of servable entries moves — an entry quarantined
  /// because it stopped compiling, or brought back because it was fixed.
  ///
  /// Pushed rather than polled: a panel sitting idle while someone edits a demo
  /// would otherwise keep offering an entry the daemon can no longer build.
  ///
  /// A plain broadcast stream, so listening subscribes synchronously and there
  /// is no window between the two. For what landed *before* a caller got here,
  /// read [lastChange] once after subscribing.
  @override
  Stream<CatalogChanged> get catalogChanges => _changes.stream;

  /// Fires when a refresh rebuilt the shared asset bundle and it differed —
  /// the notice a session turns into evicting its guest's caches.
  @override
  Stream<AssetsChanged> get assetsChanges => _assetsChanges.stream;

  /// Makes [id] the active entry and compiles it into the entrypoint.
  ///
  /// [full] asks for a whole kernel rather than a delta — needed when the
  /// result will be loaded by a guest spawned from scratch. [ifChanged] asks
  /// the daemon to answer `unchanged` instead of working, when nothing on disk
  /// has moved and this entry is already the compiled one.
  ///
  /// [timeout] is generous on purpose, and is a deadlock guard rather than a
  /// service-level expectation: the daemon serialises every client's work on one
  /// compiler, so a legitimate wait here is another client's cold compile plus
  /// this one. What it rules out is the case it exists for — a daemon that is
  /// alive, holding the queue, and never going to answer — which without it hangs
  /// the caller, and with it hangs the GUI's catalog panel forever.
  @override
  Future<DaemonCompiled> select(
    String id, {
    bool full = false,
    bool ifChanged = false,
    Duration timeout = const Duration(minutes: 5),
  }) {
    if (_gone case var reason?) return Future.error(StateError(reason));

    var requestId = _nextRequestId++;
    var completer = Completer<DaemonCompiled>();
    // Registered *before* the write. The reply cannot be missed for the same
    // reason it cannot be misdelivered: there is somewhere for it to go before
    // the daemon has been asked.
    _pending[requestId] = completer;
    try {
      _socket.writeln(
        encodeLine(
          SelectRequest(requestId, id, full: full, ifChanged: ifChanged),
        ),
      );
    } on Object catch (e) {
      _pending.remove(requestId);
      return Future.error(
        StateError('could not reach the compiler daemon: $e'),
      );
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(requestId);
        throw StateError(
          'the compiler daemon did not answer "$id" within '
          '${timeout.inSeconds}s. See ${address.logPath}',
        );
      },
    );
  }

  /// Where the embedder host is, built from the sources as they are now.
  ///
  /// **Not in the handshake, deliberately.** The host is a framework download
  /// and a `cmake` build, and only a caller that launches a guest — a panel, a
  /// screenshot — needs one at all; a compile, a catalog listing or an `audit`
  /// never does. It used to be built before the daemon would answer anybody,
  /// which made every client wait for it and, where the guest does not build,
  /// made every client fail with it.
  ///
  /// **Asked every time, and memoised nowhere.** A client held by a panel or
  /// an MCP server lives for hours, and a memo here would hand every guest it
  /// launches the binary from before the last edit to `native/`. The daemon
  /// runs `cmake` for each request — ~0.1s when nothing changed — and one
  /// build at a time, so a panel and its screenshot asking at once cost a
  /// build and a no-op rather than a race. A failure is not kept either: a
  /// caller that fixes a missing toolchain just asks again.
  ///
  /// [timeout] covers a cold framework download as well as the build.
  @override
  Future<String> hostPath({Duration timeout = const Duration(minutes: 5)}) {
    if (_gone case var reason?) return Future.error(StateError(reason));

    var requestId = _nextRequestId++;
    var completer = Completer<HostReady>();
    // Registered before the write, for the reason [_pending] is.
    _hostPending[requestId] = completer;
    try {
      _socket.writeln(encodeLine(HostRequest(requestId)));
    } on Object catch (e) {
      _hostPending.remove(requestId);
      return Future.error(
        StateError('could not reach the compiler daemon: $e'),
      );
    }

    return completer.future
        .timeout(
          timeout,
          onTimeout: () {
            _hostPending.remove(requestId);
            throw StateError(
              'the compiler daemon did not build the embedder host within '
              '${timeout.inSeconds}s. See ${address.logPath}',
            );
          },
        )
        .then((reply) {
          if (reply.hostPath case var path?) return path;
          throw StateError(
            'the embedder host could not be built: ${reply.error}',
          );
        });
  }

  /// Asks the daemon to look for entries that appeared or disappeared.
  ///
  /// Fire and forget: what it finds arrives on [catalogChanges], to every
  /// client, which is also how this client hears about somebody else's.
  @override
  void refresh() {
    try {
      _socket.writeln(encodeLine(const RefreshRequest()));
    } catch (_) {
      // A daemon on its way out is not worth reporting over a poll.
    }
  }

  /// Tells the daemon this client's guest is showing [id] now, having switched
  /// to it by itself — see [ShownRequest].
  ///
  /// Fire and forget, like [refresh], and tolerant of a daemon that has never
  /// heard of it: an older one logs the line as unreadable and carries on, and
  /// all that costs is the compile and reload this exists to avoid.
  @override
  void shown(String id) {
    try {
      _socket.writeln(encodeLine(ShownRequest(id)));
    } catch (_) {
      // Same as [refresh]: nothing here is worth reporting over a socket that
      // is going away.
    }
  }

  /// Leaves the daemon running for whoever else wants it.
  @override
  Future<void> close() async {
    _onGone();
    await _lines.cancel();
    try {
      await _socket.close();
    } catch (_) {
      // Falls through to the destroy below.
    }
    _socket.destroy();
  }

  /// Stops the daemon process, disconnecting every other client too.
  ///
  /// For tooling that wants a clean slate. Ordinary consumers call [close].
  Future<void> stopDaemon() async {
    try {
      _socket.writeln(encodeLine(const StopDaemonRequest()));
      await _socket.flush();
    } catch (_) {
      // The daemon may already be gone.
    }
    await close();
    // Give it a moment to unlink its socket, so an immediately following
    // connect does not attach to a daemon on its way out.
    for (var i = 0; i < 50; i++) {
      if (!File(address.socketPath).existsSync()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The socket for [address] — the one already being served, or one belonging
  /// to a daemon this starts.
  static Future<Socket> _attachOrSpawn({
    required DaemonAddress address,
    required _DaemonLaunch launch,
    required DaemonConfig config,
    void Function(String)? onLog,
  }) async {
    if (await _connect(address) case var existing?) {
      onLog?.call('attached to the daemon already serving ${address.key}');
      return existing;
    }
    return _spawnAndConnect(
      address: address,
      launch: launch,
      config: config,
      onLog: onLog,
    );
  }

  static Future<Socket?> _connect(DaemonAddress address) async {
    if (!File(address.socketPath).existsSync()) return null;
    try {
      return await Socket.connect(
        InternetAddress(address.socketPath, type: InternetAddressType.unix),
        0,
      );
    } on SocketException {
      // The file is there but nobody is listening: a daemon that died without
      // unlinking. The caller holds the lock before cleaning it up.
      return null;
    }
  }

  /// Starts a daemon under a lock, so several clients racing produce one.
  static Future<Socket> _spawnAndConnect({
    required DaemonAddress address,
    required _DaemonLaunch launch,
    required DaemonConfig config,
    void Function(String)? onLog,
  }) async {
    var lock = File(address.lockPath).openSync(mode: FileMode.write);
    try {
      lock.lockSync(FileLock.blockingExclusive);

      // Someone may have won the race while we waited for the lock.
      var existing = await _connect(address);
      if (existing != null) {
        onLog?.call('attached to a daemon started while we waited');
        return existing;
      }

      var stale = File(address.socketPath);
      if (stale.existsSync()) stale.deleteSync();

      // Before the spawn, under the lock: a marker left by a previous run must
      // never be read as this one's answer. The daemon we are about to start
      // may well succeed where the last one failed — somebody has usually just
      // fixed the thing it complained about.
      var marker = File(address.failurePath);
      if (marker.existsSync()) marker.deleteSync();

      // Under the daemon's own key: two clients spawning at once would
      // otherwise overwrite one another's config before either daemon read it.
      var configFile = File(
        p.join(
          config.appPackageRoot,
          'build',
          'catalog',
          address.key,
          'daemon_config.json',
        ),
      );
      configFile.parent.createSync(recursive: true);
      configFile.writeAsStringSync(jsonEncode(config.toJson()));

      // Opened before the spawn: a VM that refuses the kernel says so in the
      // log and nowhere else, and this is what reads only what *this* daemon
      // writes. See [_DaemonLog].
      var log = DaemonLog(address.logPath);

      // Detached, so the daemon outlives whoever happened to start it — that is
      // the whole point of sharing it. Its output goes to a log file rather
      // than to our pipes, which would break the moment we exit; the shell is
      // how a detached process gets a redirect it did not open itself, and so
      // catches VM-level failures too.
      await Process.start(
        '/bin/sh',
        [
          '-c',
          r'exec "$@" >> "$FW_DAEMON_LOG" 2>&1',
          'sh',
          launch.executable,
          ...launch.arguments,
          configFile.path,
        ],
        workingDirectory: config.appPackageRoot,
        mode: ProcessStartMode.detached,
        environment: {'FW_DAEMON_LOG': address.logPath},
      );
      onLog?.call('started a daemon for ${address.key}');

      // The daemon binds before it prepares, so this waits only for the bind —
      // *when preparing succeeds*. When it does not, the daemon is gone again
      // before the first poll and leaves its reason in a file, which is the
      // other thing this loop watches for. Without that check the quickest
      // failure in the system produced the slowest feedback: 30 seconds of
      // polling a deleted socket, then a timeout naming no cause.
      var deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        var socket = await _connect(address);
        if (socket != null) return socket;
        if (_recordedFailure(address) case var failure?) {
          throw StateError('the compiler daemon failed: $failure');
        }
        // Before the daemon has run a line of its own code, so it leaves no
        // failure marker and never binds: the VM rejects the kernel and exits.
        // Watched for here for the same reason the marker is — otherwise the
        // fastest failure in the system produces the slowest feedback.
        if (log.lineContaining(_kernelRejected) case var complaint?) {
          throw _RejectedKernel(
            complaint: complaint,
            snapshot: launch.snapshot?.path,
            runBy: launch.sdk,
            compiledBy: launch.snapshot == null
                ? null
                : _snapshotSdk(launch.snapshot!),
            logPath: address.logPath,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw StateError(
        'the compiler daemon never started listening on '
        '${address.socketPath}\n${_tailLog(address)}',
      );
    } finally {
      try {
        lock.unlockSync();
      } catch (_) {
        // Already released by the close below.
      }
      lock.closeSync();
    }
  }

  /// The failure a daemon recorded on its way out, if it left one.
  ///
  /// Read once. The file is deleted as it is read, so it answers the client
  /// that was waiting for it and nothing else — a marker left lying around
  /// would be found by the next connect and reported as that daemon's
  /// failure.
  ///
  /// A marker that cannot be parsed is still a failure, and its raw text is
  /// more useful than silence: something wrote it, and whatever it says is
  /// closer to the cause than "never started listening" is.
  static DaemonFailed? _recordedFailure(DaemonAddress address) {
    var file = File(address.failurePath);
    if (!file.existsSync()) return null;
    String contents;
    try {
      contents = file.readAsStringSync();
      file.deleteSync();
    } on FileSystemException {
      return null;
    }
    try {
      return DaemonFailed.fromJson(
        jsonDecode(contents) as Map<String, dynamic>,
      );
    } catch (_) {
      return DaemonFailed(message: contents);
    }
  }

  /// The last of whatever the daemon managed to say before it died.
  static String _tailLog(DaemonAddress address) {
    var log = File(address.logPath);
    if (!log.existsSync()) return '(no daemon log at ${address.logPath})';
    var lines = log.readAsLinesSync();
    return lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n');
  }
}

/// What the Dart VM prints when it will not load a kernel it was handed.
///
/// The prefix rather than `Invalid SDK hash`, which is only the commonest of a
/// family: a snapshot from a Dart far enough away fails the *format version*
/// check first (verified across 3.13.0-282.1.beta and 3.12.2 — `Invalid kernel
/// binary format version (expected 130, found 138)`), and one truncated by a
/// killed compile fails on its indicated size. All of them mean the same thing
/// here and take the same remedy.
const _kernelRejected = "Can't load Kernel binary";

/// Reads the daemon log forward, from wherever the last read stopped.
///
/// A cursor rather than a function of the whole tail, because the poll loop
/// that uses this runs every 25ms for up to 30 seconds: re-reading, re-decoding
/// and re-splitting everything the daemon has written so far, on every one of
/// up to 1200 iterations, is quadratic in how much it writes while starting.
/// Reading only what is new makes it linear, and the log is append-only, so
/// there is nothing behind the cursor that can change.
///
/// Constructed *before* the spawn, so it opens at the end of whatever previous
/// daemons left behind. The file is appended to across runs, and a refusal that
/// bricked the last start, read as this one's, would tear down a working daemon
/// over a problem already fixed.
///
/// Public for the same reason [readDaemonDepfile] is: what can go wrong here is
/// the bookkeeping — a cursor measured in the wrong units, a line split across
/// two reads — and none of it is visible from the outcome, which is a daemon
/// that starts either way and a self-heal that quietly stops happening.
class DaemonLog {
  DaemonLog(this.path) : _at = _lengthOf(path);

  final String path;

  /// How far this has consumed. Advanced only past complete lines: the daemon
  /// is writing as this reads, and half of the line that matters matches
  /// nothing.
  int _at;

  /// The byte this will read from next.
  ///
  /// Exposed because it is the only way to see the bug it exists to prevent.
  /// Advancing by character count instead of byte count leaves the cursor
  /// *behind* where it should be, and behind is harmless to every outcome —
  /// the re-read text still contains the line, so a match is still found and
  /// every assertion about matching still passes. What it costs is the reason
  /// this class was written: the lag grows with every non-ASCII line, and the
  /// scan slides back toward re-reading the whole log on each of up to 1200
  /// polls.
  int get position => _at;

  static int _lengthOf(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  /// The first line since the last call containing [needle], if any.
  ///
  /// A trailing partial line is searched, so a process that dies without a
  /// final newline is still heard — but consumed only if it matched, so an
  /// unmatched fragment is re-examined once the rest of it lands and a matched
  /// one is never reported twice.
  String? lineContaining(String needle) {
    RandomAccessFile handle;
    try {
      handle = File(path).openSync();
    } on FileSystemException {
      return null;
    }
    try {
      var length = handle.lengthSync();
      if (length <= _at) return null;
      handle.setPositionSync(_at);
      var text = utf8.decode(
        handle.readSync(length - _at),
        allowMalformed: true,
      );

      String? found;
      for (var line in const LineSplitter().convert(text)) {
        if (line.contains(needle)) {
          found = line.trim();
          break;
        }
      }
      if (found != null) {
        // Everything read is spent. The caller acts on a match and does not
        // come back, and consuming is what keeps that from being load-bearing.
        _at = length;
      } else if (text.lastIndexOf('\n') case var end when end >= 0) {
        // Bytes, not characters: the cursor is a file position, and the two
        // part company the moment anything in the log is not ASCII.
        _at += utf8.encode(text.substring(0, end + 1)).length;
      }
      return found;
    } on FileSystemException {
      return null;
    } finally {
      handle.closeSync();
    }
  }
}

/// The VM refused to load the daemon's kernel snapshot.
///
/// A cache to invalidate, not a failure to report, and the distinction is
/// the whole reason this has a type of its own. A kernel carries the identity
/// of the SDK that produced it and the VM checks it on the way in, so "refused"
/// says nothing about the daemon or the project — it says the bytes on disk are
/// not bytes this Dart can run, whether because another Dart wrote them or
/// because nothing wrote all of them. Either way the remedy is to compile them
/// again, which [CompilerDaemonClient.connect] does once before it gives up.
///
/// That it can happen at all is [DartSdkIdentity]'s subject: the snapshot
/// outlives the project that compiled it, and for a hosted install it outlives
/// that project's Flutter version too.
class _RejectedKernel implements Exception {
  _RejectedKernel({
    required this.complaint,
    required this.snapshot,
    required this.runBy,
    required this.compiledBy,
    required this.logPath,
  });

  /// The VM's own line — `Can't load Kernel binary: Invalid SDK hash.`
  final String complaint;

  /// The snapshot it was given, or null when the launch ran from source and the
  /// refusal is therefore about something else.
  final String? snapshot;

  /// The SDK asked to run it.
  final DartSdkIdentity runBy;

  /// The SDK that produced it, as recorded beside it when it was compiled.
  final DartSdkIdentity? compiledBy;

  final String logPath;

  /// Logged on the way into the retry, because a 3-second recompile that
  /// happens silently reads as a hang.
  String get rebuilding =>
      'the Dart VM would not load the daemon snapshot, so it is being '
      'recompiled.\n${_both()}';

  /// The message when recompiling did not help either.
  ///
  /// Both SDKs are named because neither one alone identifies the problem: a
  /// version is only wrong relative to another version, and the report this
  /// replaces — 30 seconds of polling, then "the compiler daemon never started
  /// listening on" a socket path — named neither, nor the snapshot, nor the
  /// fact that a cache was involved at all.
  String fatal({DartSdkIdentity? previously}) {
    var was =
        previously != null &&
            previously.key != runBy.key &&
            previously.key != compiledBy?.key
        ? '\n  before this rebuilt it  ${previously.description}'
        : '';
    return 'the compiler daemon could not start: the Dart VM would not load '
        'its kernel snapshot, and recompiling it did not help.\n'
        '${_both()}$was\n\nSee $logPath';
  }

  String _both() =>
      '\n  $complaint\n\n'
      '  snapshot                ${snapshot ?? '(none — running from source)'}\n'
      '  compiled by             ${compiledBy?.description ?? '(unrecorded)'}\n'
      '  run by                  ${runBy.description}';
}

/// Which Dart SDK compiled a kernel snapshot — the half of a snapshot's
/// identity that its path used to leave out.
///
/// A kernel is loadable only by the SDK that produced it. For a path
/// dependency that is invisible, because `appPackageRoot` is one checkout used
/// by one project. For a hosted or git-pinned install it is not: the copy lives
/// at `~/.flutterware/<sha1(packageRoot)>/app/`, which is keyed on the
/// *flutterware* revision and is therefore the same directory for every project
/// on the machine pinning that revision — while each of those projects brings
/// its own Flutter, and so its own Dart.
///
/// Keyed only by mtime, one snapshot then had to serve all of them, and two
/// projects on two Flutter betas took turns bricking each other: whichever
/// compiled last owned the file, and the other one got a daemon that died
/// before it could bind, 30 seconds of polling a socket that would never
/// appear, and `Can't load Kernel binary: Invalid SDK hash.` in a log nothing
/// pointed at. Permanently, because the snapshot stayed newer than the sources
/// that were never the problem. Deleting it fixed one project and broke the
/// other.
///
/// [key] is what keeps them apart. It is the SDK's own version and revision
/// rather than its path, because two checkouts of one SDK produce
/// interchangeable kernels and splitting on the path would compile the same
/// bytes twice.
class DartSdkIdentity {
  DartSdkIdentity({required this.dartExecutable, this.version, this.revision});

  /// Reads the identity of the SDK [dartExecutable] belongs to.
  ///
  /// Off the SDK's own files rather than `dart --version`, because this sits on
  /// the path whose entire purpose is to be cheap: the snapshot exists to turn
  /// a 3214ms start into a 121ms one, and a process spawn to ask the SDK its
  /// name would hand a third of that back on every connect.
  factory DartSdkIdentity.of(String dartExecutable) {
    for (var dir in _dartSdkDirs(dartExecutable)) {
      if (_readTrimmed(p.join(dir, 'version')) case var version?) {
        return DartSdkIdentity(
          dartExecutable: dartExecutable,
          version: version,
          revision: _readTrimmed(p.join(dir, 'revision')),
        );
      }
    }
    return DartSdkIdentity(dartExecutable: dartExecutable);
  }

  factory DartSdkIdentity.fromJson(Map<String, Object?> json) =>
      DartSdkIdentity(
        dartExecutable: json['dartExecutable'] as String? ?? '(unrecorded)',
        version: json['version'] as String?,
        revision: json['revision'] as String?,
      );

  final String dartExecutable;

  /// The `version` file's contents — `3.13.0-282.1.beta`.
  final String? version;

  /// The `revision` file's contents: the SDK's git commit.
  ///
  /// Read alongside [version] rather than instead of it because a version
  /// string is not unique on its own — `.dev` builds and local engines share
  /// one — and it is the build, not the number, that has to match.
  final String? revision;

  /// A short digest of whatever was legible: the version and revision when they
  /// were, the executable's path when they were not.
  ///
  /// The fallback splits per path rather than per SDK, which over-compiles
  /// instead of under-compiling. That is the right way round — an extra 3.2s
  /// once is not the failure this exists to prevent.
  late final String key = sha1
      .convert(
        utf8.encode(
          version == null ? 'dart $dartExecutable' : 'sdk $version $revision',
        ),
      )
      .toString()
      .substring(0, 16);

  /// How this SDK is named in a message — which is why [version] is kept around
  /// after [key] has hashed it away.
  String get description {
    if (version == null) return dartExecutable;
    var short = switch (revision) {
      String r when r.length >= 8 => ' (${r.substring(0, 8)})',
      String r => ' ($r)',
      _ => '',
    };
    return '$version$short at $dartExecutable';
  }

  Map<String, Object?> toJson() => {
    'dartExecutable': dartExecutable,
    if (version != null) 'version': version,
    if (revision != null) 'revision': revision,
  };
}

/// Where the Dart SDK's version files might be, given [dartExecutable].
///
/// Two layouts are in use here and only the second is `<sdk>/bin/dart`: callers
/// hand over `<flutter>/bin/dart` — the wrapper — as readily as
/// `<flutter>/bin/cache/dart-sdk/bin/dart`, which is what [FlutterCache] points
/// at. Both are tried rather than either being required, so a caller passing
/// the wrapper gets a real identity instead of quietly falling back to the path.
///
/// The bundled SDK is offered first, and the order is the whole correctness
/// of this. `bin/cache/dart-sdk` exists only where it means what it says,
/// whereas the other candidate is `<flutter>` itself for a wrapper path — and a
/// Flutter checkout shipped a `version` file of its own until recently. Asking
/// the vaguer question first read that file on any older checkout and returned
/// the *Flutter* version with no revision: still a discriminator, but a coarser
/// one than the build hash the VM actually checks, arrived at silently.
Iterable<String> _dartSdkDirs(String dartExecutable) sync* {
  var bin = p.dirname(dartExecutable);
  yield p.join(bin, 'cache', 'dart-sdk');
  yield p.dirname(bin);
}

String? _readTrimmed(String path) {
  try {
    var text = File(path).readAsStringSync().trim();
    return text.isEmpty ? null : text;
  } on FileSystemException {
    return null;
  }
}

/// Where the daemon's kernel snapshot for [sdk] lives.
///
/// The key is a directory rather than part of the filename so that the snapshot
/// and the depfile describing it cannot come from different SDKs — the depfile
/// decides the daemon's revision, and one written by somebody else's compile is
/// a wrong answer to a question this file asks on every connect.
String daemonSnapshotPath(String appPackageRoot, DartSdkIdentity sdk) => p.join(
  appPackageRoot,
  'build',
  'catalog',
  'daemon',
  sdk.key,
  'daemon.dill',
);

/// Beside the snapshot, naming the SDK that produced it.
///
/// Redundant with the path's [DartSdkIdentity.key] right up to the moment it is
/// needed, which is when a VM refuses the kernel: the key is a hash, and a hash
/// cannot say "3.47.0-0.4.pre compiled this and you are 3.47.0-0.1.pre" — which
/// is the only sentence that makes the failure actionable, because the project
/// that has to move is the *other* one.
File _snapshotSdkFile(File snapshot) => File('${snapshot.path}.sdk');

/// Removes the snapshot from before the path was keyed, which nothing can reach
/// any more.
///
/// 32MB, and for a hosted install it sits in a directory shared by every
/// project on the machine — so it is one file per *install* rather than per
/// checkout, and nothing else would ever come back for it. Delete once the
/// installs that predate the keying are gone.
void _discardUnkeyedSnapshot(String appPackageRoot) => _discard([
  for (var name in ['daemon.dill', 'daemon.dill.d'])
    File(p.join(appPackageRoot, 'build', 'catalog', name)),
]);

/// Deletes what is there and says nothing about what is not.
///
/// Every caller is cleaning up after itself on a path that already has a real
/// outcome — a compile that failed, a layout that moved — and none of them has
/// anything to gain from a second failure raised on the way out.
void _discard(Iterable<File> files) {
  for (var file in files) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Reclaiming disk is not worth failing a compile over.
    }
  }
}

/// Removes a staging directory and whatever the compiler left in it.
void _discardStaging(Directory staging) {
  try {
    staging.deleteSync(recursive: true);
  } on FileSystemException {
    // The same bargain as [_discard]: reclaiming disk is not worth failing a
    // compile over.
  }
}

/// How long a staging directory has to sit before [_discardAbandonedStaging]
/// reads it as abandoned.
///
/// The compile it covers is 3.2s, so this is three orders of magnitude of slack
/// — and slack is the whole point, because the cost of being early is deleting
/// a directory another process is that moment compiling into, which is the race
/// staging exists to avoid.
const _stagingIsAbandonedAfter = Duration(hours: 1);

/// Removes staging directories no process is still using.
///
/// [_discardStaging] covers the three ways [_ensureCompiled] returns; it cannot
/// cover the fourth, which is the process dying outright — a Ctrl-C on
/// `dart test`, or quitting the GUI, inside the compile. The name that
/// preceded these directories was `<snapshot>.$pid.tmp` and reclaimed itself:
/// the next process holding that pid wrote over it. An OS-unique name never
/// comes round again, so without this each interrupted compile would leave a
/// ~32MB kernel in a directory nothing would ever look at.
///
/// A directory's mtime moves with every file written inside it, so one being
/// compiled into is fresh however long the compile takes.
void _discardAbandonedStaging(Directory parent) {
  var cutoff = DateTime.now().subtract(_stagingIsAbandonedAfter);
  List<FileSystemEntity> entries;
  try {
    entries = parent.listSync();
  } on FileSystemException {
    return;
  }
  for (var entity in entries) {
    if (entity is! Directory) continue;
    if (!p.basename(entity.path).startsWith('staging.')) continue;
    try {
      if (entity.statSync().modified.isAfter(cutoff)) continue;
    } on FileSystemException {
      continue;
    }
    _discardStaging(entity);
  }
}

DartSdkIdentity? _snapshotSdk(File snapshot) {
  var recorded = _readTrimmed(_snapshotSdkFile(snapshot).path);
  if (recorded == null) return null;
  try {
    return DartSdkIdentity.fromJson(
      jsonDecode(recorded) as Map<String, Object?>,
    );
  } catch (_) {
    return null;
  }
}

/// A **guess** at the daemon's closure, used only until a depfile exists.
///
/// Kept deliberately coarse: it is the first run's answer, and the compile it
/// triggers replaces it with the compiler's own list. See [_newestSource] for why
/// a hand-maintained version of this could not stay right.
const _daemonSources = [
  'tool/catalog/compiler_daemon.dart',
  'lib/src/catalog',
  'lib/src/embedder',
];

/// Returns how to launch the daemon: a **kernel snapshot** when one is present,
/// fresh, and this SDK's, else `dart run` on the source.
///
/// `dart run` re-compiles the daemon and everything it imports — analyzer,
/// image, vm_service — on **every** start. Measured at 3214ms against 121ms
/// from a snapshot: the single largest cost in bringing a catalog up, and none
/// of it the user's project.
///
/// A kernel snapshot rather than `dart compile exe` only because AOT costs
/// about the same to build and saves ~80ms at startup; the snapshot rebuilds
/// far more often than it runs during development. Nothing forbids AOT now that
/// `FrontendServer` is handed its executable.
/// How to launch the daemon, and which build of it that is.
class _DaemonLaunch {
  _DaemonLaunch(
    this.executable,
    this.arguments,
    this.revision, {
    required this.sdk,
    this.snapshot,
  });

  final String executable;
  final List<String> arguments;

  /// Changes whenever the daemon's own sources change, or the SDK does. Part of
  /// the daemon's address, so a newer client starts a newer daemon rather than
  /// attaching to one running yesterday's code.
  final String revision;

  /// The SDK this runs on — and, when [snapshot] is set, the one that compiled
  /// it.
  final DartSdkIdentity sdk;

  /// The kernel snapshot being run, or null when the snapshot could not be
  /// built and the daemon is running from source instead.
  final File? snapshot;
}

/// The daemon build's identity: its sources *and* its SDK.
///
/// The SDK belongs here for the reason the rest of [DaemonConfig] does — a
/// daemon that outlives the thing it was built against has to be replaced, and
/// nothing else notices an SDK upgraded in place, which keeps its path and so
/// keeps `flutterSdkRoot` and the whole address unchanged. Two projects on
/// SDKs at *different* paths already forked here; this covers the one project
/// that moved.
String _revision(DartSdkIdentity sdk, DateTime newest) =>
    '${sdk.key}-${newest.millisecondsSinceEpoch}';

Future<_DaemonLaunch> _ensureCompiled({
  required String dartExecutable,
  required String appPackageRoot,
  void Function(String)? onLog,
  bool force = false,
}) async {
  var script = p.join(
    appPackageRoot,
    'tool',
    'catalog',
    'compiler_daemon.dart',
  );
  // Checked rather than assumed, because the way this goes wrong is silent and
  // slow: `dart compile kernel` on a missing file fails, `onLog` is null on the
  // headless path so nobody sees it, the fallback spawns `dart run` on the same
  // missing file into a detached process, and the client then polls a socket
  // that will never appear for 30 seconds before reporting that the daemon
  // "never started listening". Which is true, and says nothing.
  //
  // The cause is always the same: `appPackageRoot` is not flutterware's `app/`.
  // See [DaemonConfig.forPackage], which is what stops a caller getting here.
  if (!File(script).existsSync()) {
    throw StateError(
      'No daemon script at $script.\n'
      "DaemonConfig.appPackageRoot must be flutterware's own app/ directory, "
      'not the package being cataloged — it is where the daemon script, the '
      'embedder framework and the native host live.',
    );
  }
  var sdk = DartSdkIdentity.of(dartExecutable);
  var snapshot = File(daemonSnapshotPath(appPackageRoot, sdk));
  var depfile = File('${snapshot.path}.d');

  var newest = _newestSource(appPackageRoot, depfile);
  // [force] is the retry after a VM refused this file. Nothing about it looks
  // stale — a snapshot the VM will not load has a perfectly good mtime — so the
  // check below would answer "fresh" forever, which is exactly how one project
  // used to stay broken until somebody deleted the file by hand.
  //
  // A *file*, specifically. `FileSystemEntityType.notFound` is the tempting
  // test and it is the wrong one: `statSync` reports a directory at this path
  // as `directory` with a non-zero size, so anything but an equality check on
  // `file` hands the launcher a directory to run — whose error is not one the
  // VM phrases as a rejected kernel, so it is missed and waited out for the
  // full 30 seconds. `File.existsSync`, which this replaced, was false there.
  //
  // Empty counts as absent, and has to be checked separately from the refusal
  // above: a file with no kernel magic is not a kernel the VM rejects, it is
  // *Dart source* the VM compiles, so a compile killed before it wrote a byte
  // comes back as a syntax error rather than as anything this could recognise.
  var stat = snapshot.statSync();
  if (!force &&
      stat.type == FileSystemEntityType.file &&
      stat.size > 0 &&
      stat.modified.isAfter(newest)) {
    return _DaemonLaunch(
      dartExecutable,
      [snapshot.path],
      _revision(sdk, newest),
      sdk: sdk,
      snapshot: snapshot,
    );
  }

  snapshot.parent.createSync(recursive: true);
  _discardUnkeyedSnapshot(appPackageRoot);
  _discardAbandonedStaging(snapshot.parent);
  var watch = Stopwatch()..start();
  // Compiled somewhere of its own and moved into place at the end, because
  // nothing serialises two clients arriving here at once — the spawn lock is
  // taken further down, inside `_spawnAndConnect`, and by then the damage would
  // be written. `dart compile kernel` writes its output in place and not
  // atomically, so two overlapping compiles interleave into one file that
  // neither of them would recognise.
  //
  // Overlapping is not the exotic case either, now that a refused snapshot is
  // recompiled: the projects that share an install hit the same bad file and
  // all rebuild it at once, which is exactly the situation this whole change is
  // about. A rename is atomic, so the loser wastes 3.2s and nobody reads a
  // half-written kernel.
  //
  // The name is the OS's rather than ours. It was `<snapshot>.$pid.tmp`, on the
  // reading that a process compiles this once — and `dart test` disproves it,
  // because suites are isolates of the *runner's* process. Two of them
  // connecting at once staged to the same path, the first rename pulled the
  // file out from under the second, and the loser failed its connect with
  // `PathNotFoundException` on `daemon.dill.<pid>.tmp.d`. A counter would not
  // have helped: separate isolates get separate copies of it, both starting at
  // zero. `createTempSync` is the only name here nothing else can be handed.
  var staging = snapshot.parent.createTempSync('staging.');
  var staged = File(p.join(staging.path, p.basename(snapshot.path)));
  var stagedDepfile = File('${staged.path}.d');
  ProcessResult result;
  try {
    result = await Process.run(dartExecutable, [
      'compile',
      'kernel',
      script,
      '-o',
      staged.path,
      // The compiler's own account of what it read. See [_newestSource].
      '--depfile',
      stagedDepfile.path,
    ], workingDirectory: appPackageRoot);
  } on Object {
    _discardStaging(staging);
    rethrow;
  }
  if (result.exitCode != 0) {
    // Not fatal: the daemon still runs from source, just slower.
    _discardStaging(staging);
    onLog?.call('could not snapshot the daemon: ${result.stderr}');
    return _DaemonLaunch(
      dartExecutable,
      ['run', script],
      _revision(sdk, newest),
      sdk: sdk,
    );
  }
  // The depfile first, so that the instant the snapshot appears the list of
  // sources it was built from is already the matching one. The reverse order
  // leaves a window where a second client reads this compile's kernel against
  // the previous compile's dependencies, and so computes a revision for it that
  // nothing else will agree with.
  stagedDepfile.renameSync(depfile.path);
  // Written before the snapshot lands rather than after, for the same reason:
  // the sidecar is what names the producer when a VM refuses these bytes, and a
  // snapshot that is readable for even a moment without one is a snapshot that
  // can be refused without one.
  //
  // Best-effort, like [_discardUnkeyedSnapshot]. It carries nothing the daemon
  // needs — only a name for a message — and a read-only build directory or a
  // full disk must not fail a connect whose kernel compiled perfectly well.
  try {
    _snapshotSdkFile(snapshot).writeAsStringSync(jsonEncode(sdk.toJson()));
  } on FileSystemException {
    // The refusal message says "(unrecorded)" instead. See [_RejectedKernel].
  }
  staged.renameSync(snapshot.path);
  _discardStaging(staging);
  onLog?.call('snapshotted the daemon in ${watch.elapsedMilliseconds}ms');
  // Read again, against the depfile this compile just wrote. The reading above
  // may have been the guessed list, which is what a new import is missing from —
  // so without this, the first run after adding one keeps yesterday's revision.
  return _DaemonLaunch(
    dartExecutable,
    [snapshot.path],
    _revision(sdk, _newestSource(appPackageRoot, depfile)),
    sdk: sdk,
    snapshot: snapshot,
  );
}

/// The most recently modified file the daemon is built from.
///
/// The compiler's list, not ours. `dart compile kernel --depfile` writes
/// exactly what it read, so the closure is maintained by the thing that knows
/// it. The hand-written [_daemonSources] guess missed
/// `lib/src/utils/run_dir.dart` and `lib/src/assets/model/asset_catalog.dart` —
/// both genuinely in the closure — which meant editing either one neither
/// rebuilt the snapshot nor moved the revision. A stale daemon then went on
/// serving, and a stale daemon is precisely what `daemonRevision` exists to
/// prevent: it decides what goes into a hot-reload delta, and an older one hands
/// a guest a delta missing a library the guest never had.
///
/// Cheaper than the guess, too: the depfile names ~756 files, of which ~21 are
/// ours, against a recursive walk of two directory trees.
///
/// Ours means under the workspace root, and the root is taken from the
/// depfile itself — the `package_config.json` it lists is by definition at the
/// root of the resolution that built the daemon. Everything outside is the SDK
/// or the pub cache: immutable by construction, since the way you change one is
/// to resolve differently, which rewrites that same `package_config.json`. Which
/// is in the list, so a re-resolution moves the revision on its own.
///
/// Falls back to [_daemonSources] when there is no depfile — the first run, or a
/// compile that failed.
DateTime _newestSource(String appPackageRoot, File depfile) {
  var files = readDaemonDepfile(depfile) ?? _guessedSources(appPackageRoot);
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  for (var file in files) {
    try {
      var modified = File(file).statSync().modified;
      if (modified.isAfter(newest)) newest = modified;
    } on FileSystemException {
      // A dependency that has since been deleted. Its absence will show up as a
      // failed compile, which is a better place to report it than here.
    }
  }
  return newest;
}

/// The workspace-local dependencies named in a Ninja depfile, or null when there
/// is none to read.
///
/// Public so the escaping can be tested. It is the one piece of parsing in this
/// file, and the cases it has to get right — a space inside a path, a
/// `\`-continued line — are ones this machine will never produce and somebody
/// else's will.
List<String>? readDaemonDepfile(File depfile) {
  if (!depfile.existsSync()) return null;
  String text;
  try {
    text = depfile.readAsStringSync();
  } on FileSystemException {
    return null;
  }

  // `<output>: <dep> <dep> …`, with `\ ` for a space in a path and `\`-newline
  // for a continuation.
  var separator = text.indexOf(': ');
  if (separator < 0) return null;
  var deps = <String>[];
  var current = StringBuffer();
  for (var i = separator + 2; i < text.length; i++) {
    var char = text[i];
    if (char == r'\' && i + 1 < text.length) {
      var next = text[i + 1];
      if (next == '\n') {
        i++;
        continue;
      }
      if (next == ' ') {
        current.write(' ');
        i++;
        continue;
      }
    }
    if (char == ' ' || char == '\n') {
      if (current.isNotEmpty) deps.add(current.toString());
      current.clear();
      continue;
    }
    current.write(char);
  }
  if (current.isNotEmpty) deps.add(current.toString());

  var config = deps.firstWhere(
    (dep) => p.basename(dep) == 'package_config.json',
    orElse: () => '',
  );
  if (config.isEmpty) return null;
  // Never empty: the config that defines the root is itself within it, and it is
  // a dependency worth watching in its own right — a re-resolution rewrites it,
  // and a daemon linked against the old resolution has to be replaced.
  var root = p.dirname(p.dirname(config));
  return [
    for (var dep in deps)
      if (p.isWithin(root, dep)) dep,
  ];
}

Iterable<String> _guessedSources(String appPackageRoot) {
  var files = <String>[];
  for (var relative in _daemonSources) {
    var path = p.join(appPackageRoot, relative);
    var entities = FileSystemEntity.isDirectorySync(path)
        ? Directory(path).listSync(recursive: true)
        : <FileSystemEntity>[File(path)];
    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.dart')) {
        files.add(entity.path);
      }
    }
  }
  return files;
}
