import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/previews/asset_bundle.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/compile_blame.dart';
import 'package:flutterware_app/src/previews/daemon_address.dart';
import 'package:flutterware_app/src/previews/discovery.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/previews/entrypoint_generator.dart';
import 'package:flutterware_app/src/embedder/embedder_build.dart';
import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/resident_compiler.dart';
import 'package:flutterware_app/src/embedder/seed_kernel.dart';
import 'package:flutterware_app/src/embedder/source_invalidator.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

/// The catalog's build and compile half, as a plain Dart process shared by
/// every client that wants the same catalog.
///
/// It runs outside the GUI so that a screenshot, a `fw` command and an agent
/// reach the same pipeline the panel does, without a window open — and it is
/// *one* process rather than one per consumer, so the second consumer pays for
/// none of the scanning, bundling, host-building or compiling the first already
/// did. [DaemonAddress] is how they find each other.
///
/// Usage — clients spawn this themselves; the address is derived from the
/// config, so this is only ever run by hand for debugging:
///
/// ```sh
/// dart run tool/catalog/compiler_daemon.dart <config.json>
/// ```
/// Guarded, because this process is **shared**.
///
/// An error nobody catches, in the root zone, kills the isolate — and every
/// client's compiler with it. That is the wrong blast radius for a daemon whose
/// whole purpose is that a panel, a `fw` command and an agent lean on one
/// process: a single malformed line from one of them would take down the other
/// two, and the surviving evidence would be a socket that stopped answering.
///
/// So the escape hatch is closed at the top rather than only at each call site.
/// The zone logs and keeps serving; the alternative — dying quietly — is the one
/// outcome a shared daemon cannot afford. Errors that genuinely make the daemon
/// useless still exit through [_Daemon.serve]'s own failure path, which tells
/// its clients why first.
Future<void> main(List<String> args) async {
  await runZonedGuarded(() => _main(args), (error, stackTrace) {
    stderr.writeln('[catalog] uncaught: $error\n$stackTrace');
  });
}

Future<void> _main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: compiler_daemon.dart <config.json>');
    exit(64);
  }

  var config = DaemonConfig.fromJson(
    jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>,
  );
  var address = DaemonAddress(config);
  address.ensureRunDir();

  ServerSocket server;
  try {
    server = await ServerSocket.bind(
      InternetAddress(address.socketPath, type: InternetAddressType.unix),
      0,
    );
  } on SocketException catch (e) {
    // Another daemon holds the address. That is a correct outcome of two
    // clients racing, not a failure — the loser exits and the winner serves.
    stderr.writeln('[catalog] address already served, exiting: ${e.message}');
    exit(0);
  }

  // After binding, so this daemon's own socket is already there to be spared,
  // and before preparing, so the sweep is not racing a compile for the disk.
  //
  // Here because daemons are what leave the litter: a key moves whenever the
  // daemon's sources change, so a developer generates a set of orphans per edit.
  // A client could sweep instead, but a client runs far more often for far less
  // reason — and the process that made the mess is the honest place to clear it.
  var swept = await sweepRunDir();
  if (swept > 0) stderr.writeln('[catalog] swept $swept stale run files');

  // The same argument, applied to the far larger mess: a build directory is
  // named by the address, so every change to the config orphans one whole —
  // measured at 3.6 GB across 30 of them on one worktree. See
  // [sweepCatalogBuildDirs] for what it spares.
  var dropped = sweepCatalogBuildDirs(
    catalogDir: p.join(config.appPackageRoot, 'build', 'catalog'),
    liveKey: address.key,
  );
  if (dropped > 0) {
    stderr.writeln('[catalog] dropped $dropped abandoned build directories');
  }

  var daemon = _Daemon(config, address, server);
  for (var signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) => daemon.stop());
  }
  await daemon.serve();
}

class _Daemon {
  _Daemon(this.config, this.address, this._server)
    // Keyed by address, so two daemons never share a working directory. They
    // all run out of the *GUI's* package — one catalog per project, but one
    // `app/build/catalog` — and everything in here is per-daemon state: the
    // generated entrypoint, the compiler's output, the published kernel, the
    // session directories. Sharing it meant two catalogs generating wrappers
    // over each other and compiling to the same file, which resolves a name to
    // whichever project wrote last.
    : _buildDir = p.join(
        config.appPackageRoot,
        'build',
        'catalog',
        address.key,
      );

  final DaemonConfig config;
  final DaemonAddress address;
  final ServerSocket _server;
  final String _buildDir;

  late final FlutterCache _cache;
  late final EntrypointGenerator _generator;
  late final CatalogScanner _scanner;

  /// Bumped whenever the compiler *accepts* anything — a fresh library from a
  /// rescan, an edit, or the entrypoint rewrite a select is.
  ///
  /// A delta is relative to that accepted state, not to any particular guest:
  /// once a change has been compiled in, a later delta no longer carries it —
  /// it is unchanged — and a guest that never took the delta it arrived in
  /// reloads nothing and stays on the old code. Sessions that are behind get
  /// the whole program instead. `EntrypointGenerator.registerAll` avoids the
  /// startup case by registering everything before anyone connects; changes
  /// that land later cannot be handled that way.
  var _baseline = 0;
  ResidentCompiler? _compiler;

  /// Bumped whenever a select sweeps up real changes — edited sources or a
  /// changed scan. `ifChanged` compares a session's own mark against this,
  /// because edits are *consumed* by whichever session's sweep sees them
  /// first: without the generation, client A's sweep would eat the edit and
  /// client B's next `ifChanged` would see a clean world and keep rendering
  /// the stale build.
  var _changeGeneration = 0;

  /// What turns an edit into a recompile. Every request sweeps: the daemon has
  /// no watcher, so a client asking for something is the only moment it can
  /// notice the files moved — which is exactly what a client's reload button
  /// is for.
  late final _invalidator = SourceInvalidator(
    ignoredRoots: [
      ..._immutableRoots,
      // Generated, and already invalidated by name when the generator rewrites
      // them. Statting them would only report what we just did ourselves.
      _generator.outputDir,
    ],
  );

  /// The trees whose contents no checkout owns: the SDK and the pub cache.
  ///
  /// One list for two readers, because they are asking the same question. The
  /// invalidator skips them because nobody edits them; the seed keeps only
  /// them, because a library nobody edits is one every worktree can share. A
  /// root added to one and not the other would be a file statted forever or a
  /// seed that goes stale without saying so.
  late final _immutableRoots = [config.flutterSdkRoot, ...pubCacheRoots()];

  /// Everything discovery found, in tree order. Fixed until a rescan.
  var _discovered = <CatalogEntry>[];

  /// Entries the compiler could not build, by id. See [_compileServingWhatWorks].
  final _quarantine = <String, _Quarantined>{};

  /// Set when a compile **failed** before one succeeded, which is what makes
  /// the success a delta on top of a broken whole-program kernel.
  ///
  /// Not the same question as "is the quarantine non-empty", and the difference
  /// is the point of persisting it: a daemon that starts already knowing which
  /// demos are broken generates an entrypoint without them, so round zero
  /// succeeds and there is no delta to repair. Testing the quarantine instead
  /// would pay the whole-program rebuild on every start precisely to undo a
  /// failure that no longer happens.
  var _blamedWhilePreparing = false;

  /// What the daemon will actually serve.
  List<CatalogEntry> get _entries => [
    for (var entry in _discovered)
      if (!_quarantine.containsKey(entry.id)) entry,
  ];

  CatalogEntry? _active;

  final _sessions = <_Session>[];
  final _timings = <String, int>{};

  /// Phases started and not yet finished, in the order they started.
  ///
  /// Kept so a client that connects *during* the start is caught up: the
  /// phases already running are the ones it is about to wait for, and a strip
  /// that stayed blank until the next one began would say nothing for as long
  /// as the longest one takes — which on a cold start is the whole wait.
  final _running = <String>[];
  var _sessionCounter = 0;
  Duration _coldCompile = Duration.zero;
  List<String> _diagnostics = const [];

  /// The embedder framework's directory, fetched at most once and only when
  /// somebody asks for a host.
  Future<String>? _engine;

  /// The latest host build, in flight or finished — not a memo but the lock:
  /// each build waits for this one before it starts, so two clients opening a
  /// panel at the same moment never race two builds into the same `cmake`
  /// output directory. See [_ensureHost].
  Future<String>? _host;

  /// Whether this start began from a previous daemon's kernel — see
  /// [DaemonReady.warmStart].
  var _startedWarm = false;

  /// Completes when [prepare] has run — successfully or not. Sessions that
  /// connect while it is pending wait on it rather than being turned away.
  final _prepared = Completer<void>();

  /// Every request runs through here. The compiler, the entrypoint on disk and
  /// the generated wrappers are one shared, mutable thing; interleaving two
  /// clients' selects would mean compiling a file the other client is midway
  /// through rewriting.
  Future<void> _queue = Future.value();

  Timer? _idle;

  /// How long the daemon outlives its last client. Long enough that closing a
  /// panel and running `fw screenshot` costs nothing, short enough that a
  /// forgotten daemon does not hold a compiler open overnight.
  static const _idleTimeout = Duration(minutes: 10);

  /// The bundle every session symlinks, including a `kernel_blob.bin` for the
  /// entry [_prepare] compiled.
  ///
  /// Nothing writes here after [_prepare] returns. The compiler's output goes
  /// to [_outputDill] instead, so a session that has asked for nothing can
  /// still launch a guest against a kernel no later compile can move under it.
  String get _sharedAssetsDir => p.join(_buildDir, 'assets');

  /// The shared bundle's directory, made if it is not there.
  ///
  /// Both readers below list it, and a `flutter clean` — or anyone deleting
  /// `build/` under a running daemon — takes it away without the daemon
  /// noticing. Listing it blind then throws a `PathNotFoundException` out of
  /// `sendReady`, and every session that attaches afterwards fails with "the
  /// guest could not start" until the daemon is restarted. An empty bundle is
  /// a valid state, since the next compile refills it, so creating beats
  /// throwing.
  Directory get _sharedAssets =>
      Directory(_sharedAssetsDir)..createSync(recursive: true);

  String get _outputDill => p.join(_buildDir, 'out', 'kernel_blob.bin');

  /// Re-runs discovery when the files under the roots have moved, so an entry
  /// added, renamed or deleted while the catalog is open shows up.
  ///
  /// Runs the scan every time and lets it answer "nothing moved" — it keeps
  /// each file's result and re-reads only what changed, so a scan that finds
  /// nothing costs what asking whether to scan used to. Asking first was a
  /// second walk of the whole package on exactly the reloads that had work to
  /// do; see [ScanResult.changed].
  ///
  /// A scan that comes back with errors is *reported and dropped* — the entry
  /// set stays as it was. Refusing to serve is right at startup, where nothing
  /// is on screen yet and a catalog that lies is worse than none; mid-session
  /// it would take away a working panel because someone was midway through
  /// typing a duplicate id.
  /// What a rescan changed and the next compile has to invalidate.
  ///
  /// Held rather than returned, because a rescan is no longer always part of a
  /// compile: a refresh rescans and stops there, and the files it rewrote
  /// still have to reach the compiler whenever the next one happens.
  final _pending = <Uri>{};

  void _rescanIfNeeded() {
    var watch = Stopwatch()..start();
    var scan = _scanner.scan();
    if (!scan.changed) return;
    if (!scan.ok) {
      stderr.writeln(
        '[catalog] rescan found errors, keeping the previous entries:\n'
        '${scan.diagnostics.where((d) => d.isError).join('\n')}',
      );
      return;
    }

    var before = {for (var entry in _discovered) entry.id: entry};
    var after = {for (var entry in scan.entries) entry.id: entry};
    var gone = <CatalogEntry>[
      for (var entry in _discovered)
        if (!after.containsKey(entry.id)) entry,
    ];
    var fresh = <CatalogEntry>[
      for (var entry in scan.entries)
        // Rewritten as well as added: the wrapper bakes in the annotation and
        // the demo file's imports, so an entry whose declaration changed needs
        // a new one even though its id did not.
        if (!before.containsKey(entry.id) || _differs(before[entry.id]!, entry))
          entry,
    ];
    if (gone.isEmpty && fresh.isEmpty) return;

    _discovered = scan.entries;
    _diagnostics = [
      for (var d in scan.diagnostics)
        if (!d.isError) '$d',
    ];
    // A quarantine is about a build that no longer describes these entries.
    for (var entry in [...gone, ...fresh]) {
      _quarantine.remove(entry.id);
    }

    // Dropped before they are registered again: a changed entry needs a fresh
    // wrapper, and the generator never reuses an index, so this is what makes
    // the entrypoint point at the new one.
    _pending.addAll([
      ..._generator.drop([...gone, ...fresh]),
      ..._generator.registerAll([
        for (var entry in _entries)
          if (fresh.any((f) => f.id == entry.id)) entry,
      ]),
    ]);
    // The entrypoint imports what is registered, so it is rewritten last —
    // after the new wrappers exist and whatever went away is gone.
    if (_entries.isNotEmpty) {
      var active = _active;
      _pending.addAll(
        _makeActive(
          active != null && after.containsKey(active.id)
              ? _entryById(active.id)
              : _entries.first,
        ),
      );
    }

    if (fresh.isNotEmpty) _baseline++;
    stderr.writeln(
      '[catalog] rescanned in ${watch.elapsedMilliseconds}ms: '
      '${fresh.length} new or changed, ${gone.length} gone',
    );
    _catalogChanged();
  }

  /// Whether the generated wrapper for [before] would be written differently
  /// for [after] — everything the wrapper or the entrypoint reads.
  static bool _differs(CatalogEntry before, CatalogEntry after) =>
      before.annotation != after.annotation ||
      before.name != after.name ||
      before.group != after.group ||
      before.symbol != after.symbol;

  /// Looked up among everything discovered, not only what is servable: an entry
  /// that does not compile has to stay selectable, because selecting it is how
  /// a client retries it.
  CatalogEntry _entryById(String id) => _discovered.firstWhere(
    (e) => e.id == id,
    orElse: () => throw ArgumentError.value(id, 'id', 'no such entry'),
  );

  Future<void> serve() async {
    _server.listen(_accept);
    _armIdleTimer();
    try {
      await _prepare();
      _prepared.complete();
    } catch (e, s) {
      var failure = DaemonFailed(message: '$e', stackTrace: '$s');
      stderr.writeln(failure);
      for (var session in [..._sessions]) {
        session.send(failure);
      }
      // For everybody else — which on a quick failure is *everybody*. Preparing
      // can fail in a millisecond, well before the client that spawned us has
      // connected, so the sends above routinely reach an empty list and the
      // socket is unlinked below. Without this the client polls a path that
      // will never come back and reports a timeout instead of the reason.
      // See [DaemonAddress.failurePath].
      _recordFailure(failure);
      _prepared.completeError(e, s);
      await _shutdown();
      exit(1);
    }
    for (var session in [..._sessions]) {
      unawaited(session.sendReady());
    }
  }

  /// Leaves [failure] where a client that never connected will find it.
  ///
  /// Best effort by construction: this runs on the way out of a process that is
  /// already failing, and a run directory that cannot be written is not worth a
  /// second exception on top of the first.
  void _recordFailure(DaemonFailed failure) {
    try {
      File(address.failurePath).writeAsStringSync(jsonEncode(failure.toJson()));
    } catch (e) {
      stderr.writeln('[catalog] could not record the failure: $e');
    }
  }

  void _accept(Socket socket) {
    _idle?.cancel();
    // The daemon's own pid is in the id because clients use it to name files
    // in the shared run directory (`g-<id>.sock`, `cap-<id>`). A counter alone
    // is unique within one daemon; two projects' daemons would both hand their
    // first client `session-0` and the clients' guests would fight over one
    // socket path.
    var session = _Session(this, socket, 'session-$pid-${_sessionCounter++}');
    _sessions.add(session);
    try {
      session.start();
      if (_prepared.isCompleted) {
        unawaited(session.sendReady());
      } else {
        // What it has walked into. See [_running].
        for (var what in _running) {
          session.send(DaemonProgress(phase: what, done: false));
        }
      }
    } catch (e, s) {
      // One client that cannot be served is not a reason to drop the others.
      stderr.writeln('[catalog] could not serve ${session.id}: $e\n$s');
      session.send(DaemonFailed(message: '$e', stackTrace: '$s'));
      _detach(session);
    }
  }

  void _detach(_Session session) {
    _sessions.remove(session);
    session.dispose();
    if (_sessions.isEmpty) _armIdleTimer();
  }

  void _armIdleTimer() {
    _idle?.cancel();
    _idle = Timer(_idleTimeout, () {
      if (_sessions.isEmpty) stop();
    });
  }

  Future<void> stop() async {
    await _shutdown();
    exit(0);
  }

  Future<void> _shutdown() async {
    _idle?.cancel();
    for (var session in [..._sessions]) {
      session.dispose();
    }
    await _compiler?.shutdown();
    await _server.close();
    var socket = File(address.socketPath);
    if (socket.existsSync()) socket.deleteSync();
  }

  /// Everything slow and one-time: the asset bundle and the first compile.
  /// Paid once per daemon, not once per client. The embedder host is not here
  /// — see [_ensureHost].
  Future<void> _prepare() async {
    var phase = Stopwatch()..start();
    // Announced on the way *out* only. These are the phases measured as "time
    // since the last mark", so there is no moment at which one is known to have
    // begun — and a start that had to be guessed at would be a claim rather
    // than the fact the wire carries.
    void mark(String what) {
      _timings[what] = phase.elapsedMilliseconds;
      stderr.writeln('[catalog] $what ${phase.elapsedMilliseconds}ms');
      _announce(
        DaemonProgress(
          phase: what,
          done: true,
          elapsedMs: phase.elapsedMilliseconds,
        ),
      );
      phase.reset();
    }

    _cache = FlutterCache(p.join(config.flutterSdkRoot, 'bin', 'cache'));

    _scanner = CatalogScanner(
      projectRoot: config.projectRoot,
      roots: config.roots,
      previewAnnotations: config.previewAnnotations,
    );
    var scan = _scanner.scan();
    if (!scan.ok) {
      // A duplicate id or an uncallable target means an entry would be missing
      // or unreachable; refusing beats starting a catalog that lies.
      throw StateError(
        'discovery failed:\n'
        '${scan.diagnostics.where((d) => d.isError).join('\n')}',
      );
    }
    mark('scan');
    _discovered = scan.entries;
    _diagnostics = [
      for (var d in scan.diagnostics)
        if (!d.isError) '$d',
    ];
    if (_discovered.isEmpty) {
      // Names the directories absolutely and says which of them are even there.
      // The old message named `demo` — a bare relative root — so it answered
      // neither "where did you look" nor "does that place exist", which are the
      // only two questions a reader has. The GUI no longer gets this far (its
      // own scan gates the session), so whoever reads this is on the CLI or is
      // an agent, and has no panel to look at instead.
      var looked = [
        for (var root in config.roots)
          [
            '  ${p.join(config.projectRoot, root)}',
            if (!Directory(p.join(config.projectRoot, root)).existsSync())
              '  (does not exist)',
          ].join(),
      ].join('\n');
      throw StateError(
        'no catalog entries found. Looked for '
        '${config.previewAnnotations.map((a) => '@$a').join(' and ')} in every '
        '.dart file under:\n$looked\n'
        'Previews live in `demo/` unless the project says otherwise — set '
        r"`Previews(packages: [.new(app, directory: '...')])` in "
        'tool/flutterware.dart, or run `fw run previews new '
        r"--name='Buttons'` to write the first one.",
      );
    }
    // **Before** the quarantine is read, not merely before the compiler starts.
    // Resolving the warm kernel is also what decides whether the last run's
    // knowledge still applies, and it clears the quarantine file when it does
    // not — so leaving it to `_startCompiler` would delete the file after this
    // had already loaded it, and the daemon would hold entries back on evidence
    // it had just thrown away.
    // Reported by whether the file is *there*, not by whether a path was
    // derived: `_resolveWarmDill` answers with where this run will save one,
    // which on a first start is a path nothing has written yet.
    var warm = _warmDill;
    var starting = _startedWarm = warm != null && File(warm).existsSync();
    stderr.writeln('[catalog] warm kernel: ${starting ? warm : 'none'}');

    // Looked up even when a warm kernel makes it unnecessary *here*: the answer
    // also decides whether this run has to leave one behind, and the worktree
    // that benefits from a seed is never the one that built it.
    await _resolveSeed();

    // Before the entrypoint is generated, so the first compile is already the
    // one that works. Rediscovering a broken demo costs three compiles — the
    // one that fails, the one that succeeds without it, and the whole-program
    // rebuild that follows — and measured on this repo's own catalog that is
    // 4.5s against 0.6s. Paid on every start, for a fact the last run knew.
    _loadQuarantine();
    mark('quarantine');

    _generator = EntrypointGenerator(
      outputDir: p.join(_buildDir, 'entrypoint'),
      projectRoot: config.projectRoot,
      emitProbe: config.emitProbe,
      clock: config.clock,
    );
    _generator.registerAll(_entries);
    _makeActive(_entries.first);

    // **Two lanes, not one queue.** What is left divides into two chains that
    // need nothing from each other: the asset bundle, and the compiler. Run in
    // sequence the start costs their sum; overlapped, it costs the longer one.
    //
    // The only ordering that survives is the one that is real: the kernel is
    // published into the asset bundle, so that copy waits for both.
    //
    // **The embedder host used to be a third lane here, and is now [_ensureHost]
    // instead.** Being a lane made it a condition of starting at all: it is a
    // ~93MB framework download and a `cmake` build, and a client that only
    // wanted a kernel waited for both — then, where the guest does not build,
    // got a `DaemonFailed` about Objective-C instead of the compiler it asked
    // for. What that lane bought was overlap on a first-ever run, and the
    // download is cached per engine revision, so what moved is one wait, once
    // per machine, onto the first client that actually launches a guest.
    //
    // `Future.wait` rather than two bare awaits, because the lanes are
    // started before either is awaited: a lane that fails while the other is
    // still running would otherwise become an unhandled async error. `wait`
    // observes both and rethrows the first, which `serve` turns into the
    // `DaemonFailed` a client is waiting for.
    await Future.wait([
      _timed('asset bundle', _ensureAssetBundle),
      _compileLane(),
    ]);

    // Its own stopwatch, not `mark`: `mark` measures the gap since the last
    // one, and the last one is now on the far side of three concurrent lanes —
    // so it would report the whole overlapped section as the cost of a copy.
    var publish = Stopwatch()..start();
    File(_outputDill).copySync(p.join(_sharedAssetsDir, 'kernel_blob.bin'));
    _timings['publish prepared kernel'] = publish.elapsedMilliseconds;

    // Sessions from a previous daemon are meaningless now.
    var sessions = Directory(p.join(_buildDir, 'sessions'));
    if (sessions.existsSync()) sessions.deleteSync(recursive: true);
  }

  DaemonReady readyFor(_Session session) => DaemonReady(
    sessionId: session.id,
    assetsDir: session.assetsDir,
    icuData: _cache.icuData,
    coldCompile: _coldCompile,
    entries: _entries,
    quarantined: [
      for (var q in _quarantine.values)
        QuarantinedEntry(entry: q.entry, error: q.error),
    ],
    reused: session.arrivedAfterPrepare,
    timings: _timings,
    diagnostics: _diagnostics,
    seed: _seed == null
        ? null
        : SeedReport(packages: _seed!.packages.length, path: _seed!.kernelPath),
    warmStart: _startedWarm,
  );

  /// Looks for entries or assets that appeared or disappeared. Compiles
  /// nothing.
  Future<void> refresh() {
    var result = _queue.then((_) async {
      _rescanIfNeeded();
      await _refreshAssets();
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Looks for entries alone, for a client that has just arrived.
  ///
  /// Queued like everything else, because a rescan rewrites the generated
  /// wrappers and the entrypoint that a compile in flight is reading.
  Future<void> rescan() {
    var result = _queue.then((_) => _rescanIfNeeded());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Compiles [id] for [session], one request at a time.
  Future<DaemonCompiled> select(
    _Session session,
    int requestId,
    String id, {
    required bool full,
    required bool ifChanged,
  }) {
    var result = _queue.then(
      (_) => _select(session, requestId, id, full: full, ifChanged: ifChanged),
    );
    // The queue must survive a failed request, or one bad select wedges every
    // client behind it.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<DaemonCompiled> _select(
    _Session session,
    int requestId,
    String id, {
    required bool full,
    required bool ifChanged,
  }) async {
    // Before the id is resolved: it may be an entry that only exists now, or
    // one that has just stopped existing. Assets for the same reason — a
    // select is how a reload arrives, and a reload is when a user expects the
    // file they just added to exist.
    _rescanIfNeeded();
    await _refreshAssets();
    var rescanned = _pending.toList();
    _pending.clear();
    var entry = _entryById(id);

    // Then: what the user edited. Re-selecting the entry that
    // is already active is how a client asks for a reload, and without this it
    // would recompile an entrypoint whose imports all resolve to the state the
    // compiler is already holding — a switch that reports success and changes
    // nothing on screen.
    var edited = _invalidator.sweep(_compiler!.sources);
    if (edited.isNotEmpty) {
      stderr.writeln(
        '[catalog] ${edited.length} of ${_invalidator.watched} sources edited '
        '(swept in ${_invalidator.lastSweep.inMilliseconds}ms)',
      );
    }
    if (rescanned.isNotEmpty || edited.isNotEmpty) _changeGeneration++;

    // Nothing has moved since *this session's* guest last took a kernel, and
    // the entry asked for is the one it is already rendering. Saying so is the
    // whole value of `ifChanged`: the caller is a reflex, not a decision, and
    // a reload it did not need still reassembles the guest and resets the
    // demo's state.
    //
    // Judged per session, not against [_active]: the entrypoint may have been
    // rewritten for another client since — an agent screenshotting beside an
    // open panel — without this guest's picture going stale. Comparing against
    // the daemon's own state made every focus reload after any other client's
    // activity a state-resetting recompile.
    if (ifChanged &&
        session.lastSelected == id &&
        session.currentAt == _changeGeneration &&
        !_quarantine.containsKey(id)) {
      return DaemonCompiled(
        requestId: requestId,
        id: id,
        compile: Duration.zero,
        newSourceCount: 0,
        unchanged: true,
      );
    }

    // Asking for a quarantined entry *is* the retry: let it back into the
    // entrypoint and let the compile decide again. Answering from the
    // quarantine instead would leave an entry that only some other file's edit
    // could ever bring back — and would report the stale error even when the
    // compile below succeeds.
    if (_quarantine.remove(id) != null) _catalogChanged();

    var invalidated = {...rescanned, ...edited, ..._makeActive(entry)};
    // Whole program, not a delta: this guest is missing libraries that entered
    // the baseline while it was elsewhere, and a delta would leave them out.
    var behind = session.baseline != _baseline;
    if (full || behind) {
      // A guest spawned from scratch loads kernel_blob.bin off disk, and a
      // delta is not a program. `reset` makes the next compile emit the whole
      // thing without restarting the compiler — which matters because the
      // compiler is shared, and one client's launch must not throw away
      // another's warm state.
      _compiler!.reset();
    }
    var compiled = await _compileServingWhatWorks(invalidated.toList());
    // Whatever the compiler just accepted is absent from every later delta,
    // so no other session's guest can be caught up by one any more. Move the
    // baseline; their next select takes a whole program. Before the
    // quarantine check below, because the compile advanced the accepted state
    // whether or not the requested entry survived it.
    if (compiled.ok && invalidated.isNotEmpty) _baseline++;

    // The requested entry may be exactly what the compile just quarantined, in
    // which case the compile "succeeded" — without it. Say so rather than hand
    // back a kernel rendering something else.
    var quarantined = _quarantine[id];
    if (quarantined != null) {
      return DaemonCompiled(
        requestId: requestId,
        id: id,
        compile: compiled.elapsed,
        newSourceCount: 0,
        editedCount: edited.length,
        error: 'this entry does not compile:\n${quarantined.error}',
      );
    }

    if (compiled.ok) {
      session.baseline = _baseline;
      session.lastSelected = id;
      session.currentAt = _changeGeneration;
    }
    return DaemonCompiled(
      requestId: requestId,
      id: id,
      dill: compiled.ok
          ? session.takeKernel(compiled.dillOutput!, requestId, full: full)
          : null,
      compile: compiled.elapsed,
      newSourceCount: compiled.newSourceCount,
      editedCount: edited.length,
      error: compiled.ok ? null : compiled.output.join('\n'),
    );
  }

  /// Rebuilds the whole program at [_outputDill].
  ///
  /// Only a compile that has not failed leaves a valid program there — the
  /// compiler writes deltas elsewhere, and a failed compile leaves its own
  /// broken output behind. Anything that publishes [_outputDill] must be sure
  /// the last thing to write it succeeded and was whole.
  Future<CompileOutcome> _fullCompile() async {
    _compiler!.reset();
    return _compiler!.compile();
  }

  /// Makes [entry] the one the entrypoint renders, remembering it so a
  /// quarantine can tell when it needs to pick another.
  List<Uri> _makeActive(CatalogEntry entry) {
    _active = entry;
    return _generator.select(entry);
  }

  /// Compiles, and on failure drops whatever it can blame rather than failing
  /// the whole catalog.
  ///
  /// The entrypoint imports every entry — that is what makes one compiler safe
  /// to share — so a single demo mid-edit fails the compile for all of them.
  /// This reads the compiler's own diagnostics, quarantines the entries
  /// declared in the files it reported, and tries again with the rest.
  ///
  /// Errors nobody declares an entry in — a shared helper, the app itself —
  /// cannot be fixed by dropping anything, so they stay fatal. The caller gets
  /// the failed outcome and reports it.
  Future<CompileOutcome> _compileServingWhatWorks([
    List<Uri> invalidated = const [],
  ]) async {
    var pending = [..._readmitRepairedEntries(), ...invalidated];

    // Bounded: each round quarantines at least one entry, and errors in one
    // file routinely hide errors in the next.
    late CompileOutcome outcome;
    for (var round = 0; round < 10; round++) {
      outcome = await _compiler!.compile(pending);
      if (outcome.ok) return outcome;

      var blame = CompileBlame.of(
        outcome.output,
        entries: _entries,
        projectRoot: config.projectRoot,
        // Diagnostics name paths relative to the compiler's working directory,
        // which is the daemon's.
        workingDirectory: config.appPackageRoot,
      );
      if (blame.isEmpty) {
        stderr.writeln(
          '[catalog] compile failed and nothing could be blamed; errors in '
          '${blame.unattributed.join(', ')}',
        );
        return outcome;
      }

      var broken = [
        for (var entry in _entries)
          if (blame.entryIds.contains(entry.id)) entry,
      ];
      var error = outcome.output.join('\n');
      for (var entry in broken) {
        _quarantine[entry.id] = _Quarantined(
          entry: entry,
          error: error,
          sourceModified: _sourceModified(entry),
        );
      }
      _blamedWhilePreparing = !_prepared.isCompleted;
      _catalogChanged();
      _saveQuarantine();

      pending = _generator.drop(broken);
      if (_entries.isEmpty) return outcome;
      if (_active == null || _quarantine.containsKey(_active!.id)) {
        pending.addAll(_makeActive(_entries.first));
      }
    }
    return outcome;
  }

  /// Times one phase and records it under [what].
  ///
  /// Replaced the shared reset-on-every-mark stopwatch for the phases that now
  /// overlap: with three lanes in flight, "time since the last mark" measures
  /// the gap between two unrelated events rather than the cost of either.
  Future<T> _timed<T>(String what, Future<T> Function() body) async {
    var watch = Stopwatch()..start();
    _began(what);
    try {
      var result = await body();
      _timings[what] = watch.elapsedMilliseconds;
      stderr.writeln('[catalog] $what ${watch.elapsedMilliseconds}ms');
      return result;
    } finally {
      _ended(what, watch.elapsedMilliseconds);
    }
  }

  /// Tells every connected client that [what] has started.
  ///
  /// In a `finally`'s partner rather than beside the success path: a phase that
  /// threw is a phase that stopped, and a strip still counting the seconds of
  /// something that failed is the one reading worse than saying nothing.
  void _began(String what) {
    _running.add(what);
    _announce(DaemonProgress(phase: what, done: false));
  }

  void _ended(String what, int elapsedMs) {
    _running.remove(what);
    _announce(DaemonProgress(phase: what, done: true, elapsedMs: elapsedMs));
  }

  void _announce(DaemonProgress progress) {
    for (var session in [..._sessions]) {
      session.send(progress);
    }
  }

  /// The C host, built for **every** [HostRequest] — never handed out from a
  /// memo.
  ///
  /// It used to be built on the first request and never again, and a daemon
  /// outlives its last client by [_idleTimeout]: an edit to `native/host.c`
  /// went unbuilt for up to ten minutes while every probe and panel ran the
  /// binary from before it. A revert did the same in reverse, which is how a
  /// probe once blamed an unchanged host for a failure only the edited one
  /// had. So each request asks `cmake`, whose own dependency check is the one
  /// that knows a header or a `CMakeLists.txt` moved. With nothing changed
  /// that is a reconfigure and a no-op build: 110–140ms, measured 2026-09-25
  /// on macOS, against ~0.2s for a real rebuild of `host.c`.
  ///
  /// Chained on [_host], so builds into the one directory never overlap: each
  /// waits for the one before it and then runs its own — which, right behind
  /// it, is the no-op. Nothing is shared between requests, so a failure is not
  /// cached either: a client that fixes whatever the build was missing — an
  /// SDK, a compiler — can ask again without restarting a healthy daemon.
  Future<String> _ensureHost() {
    var previous = _host;
    return _host = () async {
      // Waited for, not shared: its own caller was told how it went.
      await previous?.then((_) {}, onError: (Object _) {});
      var engineDir = await _ensureEngine();
      return _timed(
        'host build',
        () => buildHost(
          nativeSourceDir: p.join(config.appPackageRoot, 'native'),
          nativeBuildDir: p.join(_buildDir, 'native'),
          engineDir: engineDir,
        ),
      );
    }();
  }

  /// The embedder framework the host links against, fetched once: it is keyed
  /// by the engine revision, which a daemon never changes.
  ///
  /// A failure is **not** cached as a failure the daemon then repeats forever:
  /// [_engine] is cleared on the way out, so the next request tries again.
  Future<String> _ensureEngine() => _engine ??= () async {
    try {
      return await _timed('engine framework', () async {
        var dir = await ensureEmbedderEngine(_cache);
        // Only once the shared copy is known good, so a failed download never
        // leaves an install with neither.
        removeLegacyEngineDir(config.appPackageRoot);
        return dir;
      });
    } on Object {
      _engine = null;
      rethrow;
    }
  }();

  /// Everything the compiler owns: start, compile what works, and record what
  /// the next daemon can start from.
  Future<void> _compileLane() async {
    var watch = Stopwatch()..start();
    var began = DateTime.now();
    // Assigned through a local so the type stays non-null: `_compiler` is
    // nullable, and the value of an assignment carries the field's type.
    var compiler = await _timed('compiler start', _startCompiler);
    _compiler = compiler;
    var cold = await _timed('cold compile', _compileServingWhatWorks);
    if (!cold.ok) {
      throw StateError(
        'the catalog did not compile, and no single entry could be blamed:\n'
        '${cold.output.join('\n')}',
      );
    }
    if (_blamedWhilePreparing) {
      stderr.writeln(
        '[catalog] quarantined ${_quarantine.length} entries that do not '
        'compile: ${_quarantine.keys.join(', ')}',
      );
      // The successful compile was a *recompile* — round zero failed — so it
      // wrote a delta, and the whole-program file still holds the kernel of
      // the compile that failed. Publishing that gives every guest an
      // incomplete program: reloads then fail to resolve libraries it never
      // had, and appear to heal as later deltas patch them in one by one.
      cold = await _timed('rebuild after quarantine', _fullCompile);
      if (!cold.ok) {
        throw StateError(
          'the catalog compiled, but rebuilding it whole did not:\n'
          '${cold.output.join('\n')}',
        );
      }
    }
    _coldCompile = watch.elapsed;
    // The baseline every later sweep reads against. Taken here rather than on
    // the first request: a file edited between startup and that request would
    // otherwise be recorded *as* the baseline, and the edit would never compile.
    //
    // `compiledAt` is what makes the baseline honest after a **warm** start.
    // The compile above began from a kernel an earlier session wrote, and
    // `frontend_server` recompiles nothing it is not named — so every file
    // edited since that kernel was saved is in the program, stale, and
    // invisible. Recording it as the baseline is what made it invisible
    // *forever*: the mtime matched from then on, so no later sweep reported it
    // either. Measured on this repo: a values file edited between two daemons
    // rendered the previous version through every capture, while the panel's
    // own scan showed the new one.
    //
    // A cold start has the same hole, only narrower: a file edited while the
    // cold compile ran may have been read before the edit, so it is compared
    // against when the compile began.
    var sweep = Stopwatch()..start();
    var stale = _invalidator.sweep(
      compiler.sources,
      compiledAt: compiler.startedFromStamp ?? began,
    );
    _timings['source baseline (${_invalidator.watched} files)'] =
        sweep.elapsedMilliseconds;
    if (stale.isNotEmpty) {
      stderr.writeln(
        '[catalog] ${stale.length} sources were edited after the compiler '
        'read them; recompiling them',
      );
      // Whole program, not a delta: the kernel at `_outputDill` is what a guest
      // loads from disk and what `saveWarmStart` is about to publish, and a
      // delta is not a program.
      compiler.reset();
      cold = await _timed(
        'start repair (${stale.length} edited)',
        () => _compileServingWhatWorks(stale),
      );
      if (!cold.ok) {
        throw StateError(
          'the catalog compiled, but recompiling the ${stale.length} sources '
          'edited after the compiler read them did not:\n'
          '${cold.output.join('\n')}',
        );
      }
    }
    compiler.saveWarmStart();
    // Written beside the kernel it belongs to: the warm kernel and the
    // quarantine describe the same compile, and a quarantine recorded against a
    // kernel that was never saved would be read next to a stale one.
    _saveQuarantine();
    // Last, because it takes the compiler on an excursion and gives it back:
    // everything above wants the kernel at `_outputDill` to be this program's,
    // and it is again by the time this returns.
    //
    // **Unconditional**, where this used to run only on `_seed == null`.
    // Whether there is anything to write is `writeSeedKernel`'s question and it
    // answers a start that found a big enough seed without reading a file — and
    // asking it every time is what stops the first seed a machine ever wrote
    // from being the one every project afterwards is stuck with.
    await _timed('seed kernel', () => _writeSeed(compiler));
  }

  /// Where the last run's quarantine is kept, beside the kernel it produced.
  ///
  /// Not under [_buildDir]: both outlive this daemon's revision — see
  /// [DaemonAddress.kernelKey].
  String get _quarantinePath => address.quarantinePath;

  /// Restores what the previous daemon learned, for entries it still applies to.
  ///
  /// An entry is only held back again when its **source is byte-for-byte as old
  /// as it was when it failed**. Anything edited since is left servable and
  /// gets compiled like any other — so fixing a demo and restarting shows it
  /// working, and this can never wedge a repaired entry out of the catalog.
  /// That is the same rule [_readmitRepairedEntries] applies mid-session; this
  /// is only the door it comes through at startup.
  ///
  /// Validity beyond the mtimes is [_resolveWarmDill]'s business: it deletes
  /// this file whenever the engine, the package resolution or the
  /// creation-location setting moved, because a demo that failed against one
  /// toolchain has said nothing about another. The two are one fact — what the
  /// last compile learned — and are discarded together.
  ///
  /// A quarantine covering *everything* is dropped rather than applied. It
  /// leaves nothing to generate an entrypoint from, and the honest recovery is
  /// to compile and find out rather than to start from a claim that the whole
  /// catalog is broken.
  void _loadQuarantine() {
    var file = File(_quarantinePath);
    if (!file.existsSync()) return;

    List<Object?> recorded;
    try {
      recorded = jsonDecode(file.readAsStringSync()) as List<Object?>;
    } catch (e) {
      // The delete is inside the guard too. This is a cache, and the recovery
      // for a cache we cannot read must not be an exception that escapes into
      // `_prepare` and fails the daemon start — a read-only build directory
      // would then stop the catalog working over a file it was free to ignore.
      stderr.writeln('[catalog] ignoring an unreadable quarantine: $e');
      try {
        file.deleteSync();
      } catch (_) {
        // Left where it is; the next run reads it and lands here again.
      }
      return;
    }

    var byId = {for (var entry in _discovered) entry.id: entry};
    var restored = <String, _Quarantined>{};
    for (var row in recorded) {
      if (row is! Map) continue;
      var entry = byId[row['id']];
      if (entry == null) continue; // Deleted or renamed since.
      var was = row['sourceModified'];
      if (was is! int) continue;
      var now = _sourceModified(entry);
      if (now == null || now.millisecondsSinceEpoch != was) continue;
      restored[entry.id] = _Quarantined(
        entry: entry,
        error: row['error'] is String
            ? row['error']! as String
            : 'did not compile',
        sourceModified: now,
      );
    }

    if (restored.isEmpty) return;
    if (restored.length == _discovered.length) {
      stderr.writeln(
        '[catalog] the recorded quarantine covers every entry; compiling '
        'instead of trusting it',
      );
      return;
    }
    _quarantine.addAll(restored);
    stderr.writeln(
      '[catalog] holding back ${restored.length} unchanged entries the last '
      'run could not compile: ${restored.keys.join(', ')}',
    );
  }

  /// Records the quarantine for the next daemon.
  ///
  /// Best effort: this is a cache, and a run directory that cannot be written
  /// costs a slow start rather than a wrong one.
  void _saveQuarantine() {
    try {
      var file = File(_quarantinePath);
      if (_quarantine.isEmpty) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      file.parent.createSync(recursive: true);
      _writeAtomically(
        file,
        jsonEncode([
          for (var q in _quarantine.values)
            {
              'id': q.entry.id,
              'error': q.error,
              'sourceModified': q.sourceModified?.millisecondsSinceEpoch,
            },
        ]),
      );
    } catch (e) {
      stderr.writeln('[catalog] could not record the quarantine: $e');
    }
  }

  /// Brings back quarantined entries whose source has been edited since it
  /// failed, so fixing a demo is enough to get it back.
  ///
  /// Cheap to attempt: if it still does not compile it is quarantined again,
  /// with the new timestamp, so this cannot loop.
  List<Uri> _readmitRepairedEntries() {
    var repaired = <CatalogEntry>[];
    for (var quarantined in _quarantine.values.toList()) {
      var modified = _sourceModified(quarantined.entry);
      if (modified == null || modified == quarantined.sourceModified) continue;
      _quarantine.remove(quarantined.entry.id);
      repaired.add(quarantined.entry);
    }
    if (repaired.isEmpty) return [];
    _catalogChanged();
    // The recorded quarantine is now wrong by exactly these entries.
    _saveQuarantine();
    return _generator.registerAll(repaired);
  }

  DateTime? _sourceModified(CatalogEntry entry) {
    var file = File(p.join(config.projectRoot, entry.path));
    return file.existsSync() ? file.statSync().modified : null;
  }

  /// Tells every client the servable set moved under it.
  void _catalogChanged() {
    if (!_prepared.isCompleted) return;
    var message = CatalogChanged(
      entries: _entries,
      quarantined: [
        for (var q in _quarantine.values)
          QuarantinedEntry(entry: q.entry, error: q.error),
      ],
    );
    for (var session in [..._sessions]) {
      session.send(message);
    }
  }

  Future<ResidentCompiler> _startCompiler() => ResidentCompiler.start(
    entrypoint: _generator.entrypointPath,
    outputDill: _outputDill,
    packageConfig: config.packageConfig,
    cache: _cache,
    // The same directory `_blame` resolves the compiler's paths against. They
    // were only ever the same by whoever happened to spawn this daemon.
    workingDirectory: config.appPackageRoot,
    warmDill: _warmDill,
    seedDill: _seed?.kernelPath,
    trackWidgetCreation: config.trackWidgetCreation,
  );

  SeedStore? _seedStore;
  PackageConfig? _resolution;

  /// The shared half of the program, compiled by whichever checkout got here
  /// first. Null when nothing on this machine has one for this resolution yet
  /// — which is what [_writeSeed] then fixes, for the next one.
  SeedKernel? _seed;

  Future<void> _resolveSeed() async {
    try {
      _resolution = await loadPackageConfigUri(Uri.file(config.packageConfig));
      var store = _seedStore = SeedStore(
        engineRevision: _cache.engineRevision,
        flavor: seedFlavor(
          ResidentCompiler.argumentsFor(
            trackWidgetCreation: config.trackWidgetCreation,
          ),
        ),
      );
      _seed = store.find(_resolution!);
    } catch (e) {
      // A resolution we cannot parse is not a reason to fail a start: the
      // compiler reads the same file itself and will say so far better than a
      // cache lookup can.
      stderr.writeln('[catalog] no seed kernel: $e');
      _seedStore = null;
    }
    // The package count with the path, because the two questions a slow start
    // raises are *was there a seed* and *was it this project's* — and a seed
    // holding a fraction of what the program reaches answers the second on
    // sight. Without it the difference between a good seed and a useless one is
    // an identical line.
    stderr.writeln(
      _seed == null
          ? '[catalog] seed kernel: none'
          : '[catalog] seed kernel: ${_seed!.kernelPath} '
                '(${_seed!.packages.length} packages)',
    );
  }

  /// Leaves the shared half of this program behind for the next checkout.
  ///
  /// Runs only when the start did not find one, and costs the emit of a program
  /// the compiler is already holding — see [ResidentCompiler.asideAt]. Measured
  /// on this repo's catalog: **~300ms of compiler time plus the copy**, once
  /// per resolution per machine, against the 4s it saves every worktree opened
  /// afterwards.
  Future<void> _writeSeed(ResidentCompiler compiler) async {
    var store = _seedStore;
    var resolution = _resolution;
    if (store == null || resolution == null) return;
    try {
      await compiler.writeSeed(
        store: store,
        resolution: resolution,
        immutableRoots: _immutableRoots,
        improving: _seed,
        log: (line) => stderr.writeln('[catalog] $line'),
      );
    } catch (e) {
      // **A cache write may not fail a start.** Everything above this line has
      // already succeeded — the catalog compiled, the warm kernel is saved, the
      // clients are waiting — and this is a head start for some other checkout.
      // Left unguarded, a compiler that dies while emitting the seed reaches
      // `Future.wait` in `_prepare` and the whole daemon answers `DaemonFailed`
      // over work nobody asked for.
      stderr.writeln('[catalog] no seed written: $e');
      // What is *not* optional is which program sits at the output dill:
      // `_prepare` copies it into the asset bundle and every guest loads it. A
      // failed excursion may have left the seed's own program there, or half of
      // one, so this rebuilds rather than trusting it — and a rebuild that
      // fails is fatal, because the alternative is publishing a kernel that is
      // not the catalog.
      var rebuilt = await _timed('rebuild after seeding', _fullCompile);
      if (!rebuilt.ok) {
        throw StateError(
          'the catalog compiled, but rebuilding it after the seed did not:\n'
          '${rebuilt.output.join('\n')}',
        );
      }
    }
  }

  late final String? _warmDill = _resolveWarmDill();

  /// The kernel a previous daemon left behind, for the compiler to start from.
  ///
  /// Discarded when the stamp says it was produced under different conditions.
  /// The compiler tolerates a stale *source* — that is the whole point, it
  /// recompiles what changed — but a kernel built against another engine or
  /// another package resolution is not a starting point, it is a wrong answer.
  String? _resolveWarmDill() {
    var dill = address.warmDillPath;
    var stamp = File('$dill.stamp');
    // Where both used to live, before they were keyed apart from the daemon's
    // revision. Left behind they are ~95MB per revision that nobody reads.
    for (var stale in [
      File(p.join(_buildDir, 'warm.dill')),
      File(p.join(_buildDir, 'warm.dill.stamp')),
    ]) {
      if (stale.existsSync()) {
        try {
          stale.deleteSync();
        } catch (_) {
          // A build directory we cannot write is not this function's problem.
        }
      }
    }
    var current = [
      _cache.engineRevision,
      config.packageConfig,
      '${File(config.packageConfig).statSync().modified.millisecondsSinceEpoch}',
      // A kernel is compiled with creation locations or without them, and the
      // two are not interchangeable starting points.
      'twc:${config.trackWidgetCreation}',
    ].join(' ');

    if (stamp.existsSync() && stamp.readAsStringSync() == current) return dill;
    if (File(dill).existsSync()) File(dill).deleteSync();
    // The quarantine goes with it. A demo that failed against one engine, one
    // package resolution or one creation-location setting has said nothing
    // about another, and holding it back on that evidence would keep a working
    // demo out of the catalog until somebody happened to edit it.
    if (File(_quarantinePath).existsSync()) File(_quarantinePath).deleteSync();
    stamp.parent.createSync(recursive: true);
    _writeAtomically(stamp, current);
    return dill;
  }

  /// Writes [contents] beside [file] and renames it into place.
  ///
  /// Everything under [DaemonAddress.learnedDir] is shared by daemons of
  /// different revisions now, so a reader can arrive mid-write. A rename is the
  /// only write that has no middle.
  static void _writeAtomically(File file, String contents) {
    var staged = File('${file.path}.$pid.tmp');
    try {
      staged.writeAsStringSync(contents);
      staged.renameSync(file.path);
    } catch (_) {
      if (staged.existsSync()) {
        try {
          staged.deleteSync();
        } catch (_) {
          // Nothing left to try; the next run overwrites it.
        }
      }
      rethrow;
    }
  }

  /// The asset directory the guest reads: manifests written here, payloads
  /// symlinked. Milliseconds, against seconds for `flutter build bundle` —
  /// see [AssetBundleBuilder]. Rebuilt every start, since it is cheap and a
  /// stale manifest is worse than a rebuild.
  Future<BundleSync> _ensureAssetBundle() {
    return AssetBundleBuilder(
      cache: _cache,
      // The *project's* package owns the unprefixed asset keys: a demo saying
      // `AssetImage('assets/logo.png')` means its own project's file, not the
      // GUI's. These were the same package until the catalog started running
      // against somebody else's project.
      rootPackageRoot: config.projectRoot,
      packageConfigPath: config.packageConfig,
    ).build(_sharedAssetsDir);
  }

  /// Rebuilds the bundle mid-session and tells clients when it moved.
  ///
  /// Runs wherever a rescan runs — the refresh request and every select —
  /// because they answer the same question about different halves of the
  /// project: a rescan notices the previews moved, this notices the assets did.
  /// ~30ms measured when nothing changed, against a picture that is wrong.
  Future<void> _refreshAssets() async {
    if (!_prepared.isCompleted) return;
    var sync = await _ensureAssetBundle();
    if (!sync.changed) return;
    _refreshSessionMirrors();
    var message = AssetsChanged(
      fontsChanged: sync.fontsChanged,
      shaders: [...sync.shaders],
    );
    for (var session in [..._sessions]) {
      session.send(message);
    }
  }

  /// Reconciles every session's top-level mirror with the shared bundle.
  ///
  /// A session dir is made once, at attach — see `_prepareAssetsDir` — so a
  /// top-level entry that appears later (the first `packages/` asset, say)
  /// has no link in it, and the session's guest would miss what the shared
  /// bundle plainly has. The kernel is the one name never touched: it is the
  /// session's own, whether still the shared link or a compiled file.
  void _refreshSessionMirrors() {
    var shared = <String>{
      for (var entity in _sharedAssets.listSync()) p.basename(entity.path),
    };
    for (var session in [..._sessions]) {
      var dir = Directory(session.assetsDir);
      if (!dir.existsSync()) continue;
      for (var entity in dir.listSync(followLinks: false)) {
        var name = p.basename(entity.path);
        if (name == 'kernel_blob.bin') continue;
        if (entity is Link && !shared.contains(name)) entity.deleteSync();
      }
      for (var name in shared) {
        if (name == 'kernel_blob.bin') continue;
        var at = p.join(session.assetsDir, name);
        if (FileSystemEntity.typeSync(at, followLinks: false) ==
            FileSystemEntityType.notFound) {
          Link(at).createSync(p.join(_sharedAssetsDir, name));
        }
      }
    }
  }
}

/// An entry held back because it does not compile.
class _Quarantined {
  _Quarantined({
    required this.entry,
    required this.error,
    required this.sourceModified,
  });

  final CatalogEntry entry;
  final String error;

  /// The demo file's timestamp when it was quarantined. A newer one means
  /// somebody has been editing, which is grounds for trying again.
  final DateTime? sourceModified;
}

/// One connected client.
///
/// Owns the only things a client may not share: the kernel its guest loads and
/// the deltas its guest reloads. Both are files the compiler rewrites in place,
/// so handing two clients the same path would let one decide what the other
/// renders — the failure mode that once produced byte-identical screenshots of
/// the wrong entry.
class _Session {
  _Session(this._daemon, this._socket, this.id)
    : arrivedAfterPrepare = _daemon._prepared.isCompleted;

  final _Daemon _daemon;
  final Socket _socket;
  final String id;

  /// Whether this client attached to an already-prepared daemon, and so paid
  /// nothing for it.
  final bool arrivedAfterPrepare;

  /// The compiler baseline this session's guest has been fed up to. Behind the
  /// daemon's own means the next kernel it is given has to be a whole program.
  int baseline = 0;

  /// The entry this session last took a kernel for, and the change generation
  /// that kernel was current at. Together they are what `ifChanged` answers
  /// from — a fact about this client's guest, not about the daemon.
  String? lastSelected;
  int currentAt = -1;

  String get _dir => p.join(_daemon._buildDir, 'sessions', id);
  String get assetsDir => p.join(_dir, 'assets');

  final _deltas = <String>[];

  void start() {
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: (_) => _daemon._detach(this),
          onDone: () => _daemon._detach(this),
        );
  }

  /// A directory that looks exactly like the shared bundle to the engine.
  ///
  /// Entirely symlinks, so it costs microseconds — including `kernel_blob.bin`,
  /// which points at the prepared kernel until this session asks for one of its
  /// own. That is what lets a client that has just attached launch a guest
  /// immediately, without a compile.
  void _prepareAssetsDir() {
    var target = Directory(assetsDir);
    if (target.existsSync()) target.deleteSync(recursive: true);
    target.createSync(recursive: true);
    for (var entity in _daemon._sharedAssets.listSync()) {
      Link(p.join(assetsDir, p.basename(entity.path))).createSync(entity.path);
    }
  }

  /// Moves the compiler's output somewhere only this session reads.
  ///
  /// A [full] kernel becomes this session's `kernel_blob.bin`, which its guest
  /// loads at launch. A delta gets a per-request name, because the compiler
  /// writes every delta to the same path and the next client's compile would
  /// otherwise land there before this client's guest had reloaded.
  String takeKernel(String produced, int requestId, {required bool full}) {
    if (full) {
      var kernel = p.join(assetsDir, 'kernel_blob.bin');
      // Replaces the symlink to the prepared kernel; copying onto it would
      // write through to the shared bundle every other session reads.
      var link = Link(kernel);
      if (link.existsSync()) link.deleteSync();
      File(produced).copySync(kernel);
      return kernel;
    }
    var delta = p.join(_dir, 'deltas', '$requestId.dill');
    Directory(p.dirname(delta)).createSync(recursive: true);
    File(produced).copySync(delta);
    _deltas.add(delta);
    // The guest only ever reloads the newest; a couple of predecessors are kept
    // in case one is still in flight.
    while (_deltas.length > 4) {
      var stale = File(_deltas.removeAt(0));
      if (stale.existsSync()) stale.deleteSync();
    }
    return delta;
  }

  Future<void> sendReady() async {
    try {
      await _daemon._prepared.future;
    } catch (_) {
      return; // The failure was already sent.
    }
    if (arrivedAfterPrepare) {
      // **The handshake is a snapshot, and for a client attaching to a warm
      // daemon it was a snapshot of whenever that daemon happened to start.**
      // Nothing else rescans on this path: a headless capture checks the id it
      // was given against these entries and refuses before it ever reaches the
      // `select` whose rescan would have found it — so a preview written after
      // the daemon started was invisible to every later client, permanently,
      // and re-running only re-read the same stale list. Measured: `fw run
      // previews entries` listed a new entry that `screenshot` called "no such
      // entry" for the daemon's whole ten-minute idle life.
      //
      // Only for a client that arrived after preparing. The one that spawned
      // the daemon is already answered by [_prepare]'s own scan, which ran
      // after it asked.
      try {
        await _daemon.rescan();
      } catch (e, s) {
        // A rescan that failed leaves the previous entries, which is what this
        // client would have got anyway. Not a reason to refuse to serve it.
        stderr.writeln('[catalog] rescan for $id failed: $e\n$s');
      }
    }
    try {
      // After preparing, not on connect: the shared bundle this mirrors does
      // not exist until then, and a client may well connect before it does.
      _prepareAssetsDir();
      send(_daemon.readyFor(this));
    } catch (e, s) {
      // This runs off the accept callback, so an escape here would be an
      // unhandled async error and take the whole daemon with it.
      stderr.writeln('[catalog] could not serve $id: $e\n$s');
      send(DaemonFailed(message: '$e', stackTrace: '$s'));
      _daemon._detach(this);
    }
  }

  Future<void> _onLine(String line) async {
    var json = tryDecodeLine(line);
    if (json == null) return;

    // `tryDecodeLine` only proves the line was a JSON object, so anything that
    // is not a request this build knows arrives here — a newer client's request
    // type, or a stray JSON line on the wire. Decoding is therefore fallible,
    // and this is where a client's mistake must stop being the daemon's: it
    // used to throw out of this callback, which is an unhandled async error and
    // so the death of every other client's compiler.
    //
    // Logged rather than answered. Only `select` has a reply contract, and a
    // line that did not decode as one carries no request id to echo — so there
    // is nobody waiting and nothing to say. `DaemonFailed` would be the wrong
    // shape: clients read it as terminal.
    DaemonRequest request;
    try {
      request = DaemonRequest.decode(json);
    } on FormatException catch (e) {
      stderr.writeln('[catalog] $id sent something unreadable: $e');
      return;
    }

    switch (request) {
      case SelectRequest(:var requestId, :var id, :var full, :var ifChanged):
        try {
          send(
            await _daemon.select(
              this,
              requestId,
              id,
              full: full,
              ifChanged: ifChanged,
            ),
          );
        } catch (e, s) {
          send(
            DaemonCompiled(
              requestId: requestId,
              id: id,
              compile: Duration.zero,
              newSourceCount: 0,
              error: '$e\n$s',
            ),
          );
        }
      case ShownRequest(id: var shown):
        // **Not through the queue, and nothing sent back.** It touches no file
        // and starts no compile; it corrects one fact about this session — see
        // [ShownRequest]. The guest's program holds every entry, so this
        // client's panel can move between them with a message and a frame, and
        // without hearing about it the next `ifChanged` would recompile and
        // reassemble to arrive where the guest already is.
        //
        // The generation is left alone on purpose: a runtime switch says
        // nothing about the files.
        lastSelected = shown;
      case RefreshRequest():
        // Through the queue like any other work: a rescan rewrites the
        // generated wrappers and the entrypoint, which a compile in flight is
        // reading. Nothing is sent back — whatever it finds goes out as a
        // CatalogChanged, to every client rather than just this one.
        //
        // Caught here rather than left to the zone: a refresh has no reply to
        // fail, so without this the only trace of a broken rescan is a generic
        // uncaught line that does not say which client asked.
        try {
          await _daemon.refresh();
        } catch (e, s) {
          stderr.writeln('[catalog] refresh for $id failed: $e\n$s');
        }
      case HostRequest(:var requestId):
        // Answered off the queue: the build shells out to `cmake` and touches
        // nothing the compiler owns, so making a panel's host build wait behind
        // another client's cold compile would buy nothing.
        //
        // The failure is reported to the client that asked and to nobody else.
        // It is not a `DaemonFailed`: the compiler is still up and still
        // serving, and this client can go on compiling without a guest.
        try {
          send(
            HostReady(
              requestId: requestId,
              hostPath: await _daemon._ensureHost(),
            ),
          );
        } catch (e, s) {
          send(HostReady(requestId: requestId, error: '$e\n$s'));
        }
      case StopDaemonRequest():
        await _daemon.stop();
    }
  }

  /// Writes one response, or drops it if the client is not there to read it.
  ///
  /// Every failure mode of a departed client, not just [SocketException]. A
  /// closed `IOSink` throws `StateError`, and this is called while iterating
  /// every session to broadcast a [CatalogChanged] — so one client that left
  /// between the compile and the broadcast used to abort the broadcast for
  /// everyone behind it in the list.
  void send(DaemonResponse message) {
    try {
      _socket.writeln(encodeLine(message));
    } on Object {
      // The client left mid-request; _detach will follow.
    }
  }

  void dispose() {
    try {
      _socket.destroy();
    } catch (_) {}
    var dir = Directory(_dir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
