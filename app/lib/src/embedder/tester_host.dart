import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../previews/asset_bundle.dart';
import '../previews/package_config_locator.dart';
import '../utils/run_dir.dart';
import 'build_directory.dart';
import 'flutter_cache.dart';
import 'frontend_server.dart';
import 'guest_vm_service.dart';
import 'seed_kernel.dart';
import 'source_invalidator.dart';

/// What a [TesterHost] runs: the program it generates, and how to recognise the
/// guest that comes up holding it.
///
/// Everything else about driving a `flutter_tester` — the flag list, the warm
/// compiler, the two refresh lanes, the respawn — is the same whoever is
/// asking, which is why it lives in [TesterHost] and this is all a caller has
/// to say.
abstract class TesterProgram {
  /// Names the artifacts and prefixes the log lines — `scenarios`, `previews`.
  /// The dill is `<name>.dill` and the bundle `<name>_assets`, both under the
  /// package's `build/flutterware/`.
  String get name;

  /// The line the guest prints on stdout once it can be asked questions.
  String get readyLine;

  /// An extension event stream to forward to [TesterHost.onEvent], for a
  /// program that narrates while it works. Null for one that only answers.
  String? get eventStream => null;

  /// Extra frontend-server arguments.
  ///
  /// `--track-widget-creation` by default, and both programs want it: source
  /// locations in a widget tree come from the inspector, which reads them only
  /// when creation tracking is compiled in.
  List<String> get compilerArguments => const ['--track-widget-creation'];

  /// The sources the entrypoint is generated from, sorted.
  ///
  /// A change to this list restarts the guest rather than reloading it: the
  /// generated `main` has already run, and no reload re-runs `main`, so the
  /// program can never grow an import it did not start with.
  List<String> sources();

  /// Writes the generated entrypoint for [sources] and returns its path.
  ///
  /// Must leave the file alone when its content is already right — a touched
  /// mtime makes [SourceInvalidator] recompile for nothing.
  String writeEntrypoint(List<String> sources);
}

/// A `flutter_tester` kept warm, with our own resident `frontend_server` behind
/// it — the arrangement spike S4 proved
/// (`2026-07-30-s4-flutter-tester-findings.md`): the SDK's tester binary,
/// FakeAsync inside, driven over the VM service.
///
/// Deliberately Flutter-free: `fw` links this, and the purity guardrail
/// (`entry_point_purity_test.dart`) holds it to that.
///
/// Not passing `--use-test-fonts` / `--disable-asset-fonts` — the two flags
/// `flutter test` always passes — is what makes this render real fonts, where a
/// program run under `flutter test` measures unstyled text in the test font and
/// reports overflows that never happened. Spawning the tester ourselves is the
/// only way to omit them; the program on top loads `FontManifest.json`.
///
/// A warm host stays honest: [sync] brings it up to date with what is on disk,
/// so a caller never replays code that has since been edited.
class TesterHost {
  TesterHost({
    required this.packageRoot,
    required this.flutterSdkRoot,
    required this.program,
    required this.lane,
    this.followEdits = true,
    this.onLog,
  }) : _leader = null,
       guest = 0;

  /// Another guest of [leader]'s program, started from the kernel [leader]
  /// compiled rather than from a compile of its own.
  ///
  /// What makes running several guests of one checkout affordable: a
  /// `frontend_server` per guest is a compile per guest, where a spawn from a
  /// finished kernel is only the tester's boot. It shares the leader's asset
  /// bundle and build directory, and never compiles — so [leader] must not
  /// [followEdits], or the kernel would be rewritten under the guests reading
  /// it. [guest] numbers this one's log beside the leader's.
  ///
  /// A host rather than a bare [spawnGuest], because what drives it — a
  /// scenario runner, a preview runner — speaks to a host: one turn at a time,
  /// and a guest that comes back when it is gone.
  TesterHost.sharing(TesterHost leader, {required this.guest, this.onLog})
    : assert(guest > 0),
      _leader = leader,
      packageRoot = leader.packageRoot,
      flutterSdkRoot = leader.flutterSdkRoot,
      program = leader.program,
      lane = leader.lane,
      followEdits = false {
    if (leader.followEdits) {
      throw ArgumentError.value(
        leader,
        'leader',
        'a host that follows edits rewrites the kernel it would share',
      );
    }
  }

  final TesterHost? _leader;

  /// Which guest of a shared program this is: 0 for the one that compiles.
  final int guest;

  /// Whether [sync] brings the guest up to date with the sources on disk.
  ///
  /// Off, the host reads its checkout **once**, when it compiles, and a sync
  /// only replaces a guest that is gone — from that same kernel. That is what
  /// a comparison wants: its replays are filed under keys hashed from the
  /// sources before anything started, so a replay of code edited since would
  /// be filed under the key of code that no longer exists.
  final bool followEdits;

  /// Where every artifact of the default lane lives, relative to the package.
  static const defaultBuildDirectory = defaultBuildRoot;

  final String packageRoot;
  final String flutterSdkRoot;
  final TesterProgram program;

  /// Where this host's artifacts — dill, asset bundle, log — live, relative to
  /// [packageRoot].
  ///
  /// [exclusive] serializes calls *within* one host and says nothing about a
  /// second host on the same package: two of those with one directory are two
  /// `frontend_server`s writing one dill and two generators rewriting one
  /// entrypoint under each other. Which is why this is a [BuildLane] and not a
  /// path — the lane is *taken*, and a host that cannot have the one it wanted
  /// gets a claim of its own rather than a collision. The program's generated
  /// entrypoint must sit under the same directory, which is the owner's job to
  /// arrange by handing it this same lane: this host never sees that path,
  /// only the dill the compiler makes of it.
  final BuildLane lane;

  String get buildDirectory => lane.path;

  final void Function(String line)? onLog;

  /// Called for every event on [TesterProgram.eventStream].
  ///
  /// Mutable rather than constructor-fixed so the owner can attach after the
  /// host exists.
  void Function(Map<String, Object?> event)? onEvent;

  late final FlutterCache _cache = FlutterCache(
    p.join(flutterSdkRoot, 'bin', 'cache'),
  );

  FrontendServer? _compiler;
  Process? _guest;
  GuestVmService? _vm;
  StreamSubscription<Map<String, Object?>>? _events;
  Future<void>? _starting;
  var _disposed = false;

  /// Whether the spawned guest is still running. Watched because a tester that
  /// dies mid-session is otherwise invisible: the VM service simply starts
  /// refusing calls, and every later call fails with a disposed-connection
  /// error instead of a fresh process.
  var _guestAlive = false;

  /// The sources the running program was generated from, sorted.
  var _sources = const <String>[];

  /// Sources edited since the last accepted compile. Kept across a failed
  /// compile — the invalidator's baseline has already consumed their mtimes,
  /// so forgetting them here would make the next sync see nothing to do.
  final _dirty = <Uri>{};

  SourceInvalidator? _invalidator;
  String? _packageConfig;
  String? _assetsDir;

  /// The connected guest. Only valid after [ensureGuest].
  GuestVmService get vm => _vm!;

  /// Whether a guest has already been started, read *before* [ensureGuest] by a
  /// caller deciding whether it also needs to [sync] — a cold start is already
  /// current, and a warm one is what may have gone stale.
  bool get isWarm => _starting != null;

  /// One conversation with the guest at a time: the declarer and the test
  /// binding are not reentrant, so overlapping calls would interleave inside
  /// it.
  Future<void> _turn = Future.value();

  Future<T> exclusive<T>(Future<T> Function() action) {
    var mine = _turn.then((_) => action());
    _turn = mine.then<void>((_) {}).catchError((Object _) {});
    return mine;
  }

  String get _buildDir => p.join(packageRoot, buildDirectory);

  /// Where the guest's console goes, whole. The live pipes feed a one-line
  /// narration (`onLog`), which is the right size for a spinner caption and
  /// the wrong size for a diagnosis — before this file the process's output
  /// was read once for the VM-service URI and discarded. What lands here is
  /// what escapes the harness's structured lanes: engine noise, a crash on
  /// the way up, a print from outside any test zone.
  String get logPath => p.join(
    _buildDir,
    guest == 0 ? '${program.name}.log' : '${program.name}-$guest.log',
  );

  RandomAccessFile? _logFile;

  /// The last guest of this process still starting its engine.
  ///
  /// Guests start one after the other because the engine's Metal context,
  /// started by several testers in the same instant, can leave one of them
  /// waiting for ever on the lock of the system's shader cache — sampled
  /// 2026-09-16 at sixteen guests starting at once, the one that never came
  /// up was in `flock` under `MTLCompilerFSCache::openSync`, before its VM
  /// had started. The engine's start is a fraction of a second of a guest's;
  /// what follows it, the harness booting, still runs side by side. Shared by
  /// every [spawnGuest], so a live pool's guests queue behind a comparison's.
  static Future<void> _booting = Future.value();

  /// Builds everything and leaves a warm guest behind: sources → generated
  /// entrypoint → asset bundle → compile → spawn → connect. Idempotent, and
  /// concurrent callers share the one startup.
  ///
  /// A **failed** start is forgotten rather than remembered: what it choked on
  /// — a compile error, an empty directory — is exactly what the user goes and
  /// fixes, so memoizing the failure would make every later call replay a
  /// diagnostic that is no longer true.
  Future<void> start() => _starting ??= _startOnce();

  Future<void> _startOnce() async {
    try {
      await _start();
    } catch (_) {
      _starting = null;
      // Whatever the attempt did spawn before it threw goes with it, or the
      // retry would leave a compiler (and possibly a tester) behind.
      await _teardown();
      rethrow;
    }
  }

  /// A live guest, whatever it takes: the one-time cold start, plus a respawn
  /// when the guest is gone. It can be gone two ways — a [restartGuest] that
  /// failed after its teardown but before its compile succeeded, or a process
  /// that died on its own after startup — and both used to leave every later
  /// call dereferencing a dead service until somebody found the restart action.
  ///
  /// Call inside [exclusive].
  Future<void> ensureGuest() async {
    await start();
    if (_vm == null || !_guestAlive) await restartGuest();
  }

  Future<void> _start() async {
    if (_leader case var leader?) {
      await leader.start();
      _packageConfig = leader._packageConfig;
      _assetsDir = leader._assetsDir;
      await _spawnGuest(leader.dillPath);
      return;
    }
    _sources = program.sources();
    var entrypoint = program.writeEntrypoint(_sources);
    var packageConfig = _packageConfig = requirePackageConfig(packageRoot);

    _assetsDir = p.join(_buildDir, '${program.name}_assets');
    await _syncAssetBundle();

    var outputDill = p.join(_buildDir, '${program.name}.dill');
    // Two questions, and they are not the same one. *What seed is on this
    // machine* is what the write below is judged against — whether this program
    // would leave a better one behind. *Should this start use it* is separately
    // no, whenever this package already has a kernel of its own here: the
    // compiler warm starts from its own output dill when nothing says
    // otherwise, and that file is the whole program where a seed is only its
    // shared half. Answered together, a checkout with a kernel would read the
    // machine as having no seed and rebuild one on every start.
    var existing = await _findSeed();
    var seed = File(outputDill).existsSync() ? null : existing;
    if (seed != null) onLog?.call('[${program.name}] starting from a seed');

    var compiler = _compiler = await FrontendServer.start(
      executable: _cache.dartAotRuntime,
      snapshot: _cache.frontendServerSnapshot,
      entrypoint: entrypoint,
      outputDill: outputDill,
      packageConfig: packageConfig,
      sdkRoot: _cache.flutterPatchedSdkDir,
      platformDill: _cache.platformDill,
      initializeFromDill: seed?.kernelPath,
      // What [CompileBlame] resolves a diagnostic against, so it is what the
      // compiler has to be speaking relative to. Stated rather than inherited:
      // this host runs both inside the GUI, whose directory is the worktree,
      // and under a `dart run` from the package, and blame silently attributed
      // nothing in the first case — one unbuildable demo failed the catalog.
      workingDirectory: packageRoot,
      extraArguments: program.compilerArguments,
    );
    // The cold start's long pole, and now its only slow step — narrated
    // because the panel shows the last line the host said, and a silent one
    // reads as a hung one.
    onLog?.call('[${program.name}] compiling the harness');
    var compiled = await compiler.compile();
    if (compiled.errorCount > 0) {
      throw TesterCompileException(program.name, compiled.output);
    }
    // Said afterwards as well as before, because this is the step whose cost
    // anyone asking about a slow start is asking about — and unlike the catalog
    // daemon, which reports its cold compile on the wire, nothing here recorded
    // it anywhere a reader could find.
    onLog?.call(
      '[${program.name}] compiled the harness in '
      '${compiled.elapsed.inMilliseconds}ms',
    );
    compiler.accept();
    // The baseline every later sweep is read against — taken now, so an edit
    // during the guest's startup still counts as an edit.
    _invalidator = SourceInvalidator(ignoredRoots: _immutableRoots)
      ..sweep(compiler.sources);

    // Before the guest, because it hands the compiler back exactly as it found
    // it and the guest is about to be handed the kernel — and after the
    // baseline, because the excursion is not an edit anybody should hear about.
    // **Unconditional**, where this used to run only on a store with nothing in
    // it. What is worth writing is `writeSeedKernel`'s question — a start that
    // found a seed holding everything this program reaches is answered without
    // a file being read — and the old condition is what let the first seed a
    // machine happened to write be the one every project afterwards inherited.
    await _writeSeed(compiler, outputDill, improving: existing);

    await _spawnGuest(compiled.dillOutput ?? outputDill);
  }

  /// The trees whose contents no checkout owns: the SDK and the pub cache. See
  /// [SeedStore] — and note that the invalidator reads the same list, because
  /// "nobody edits it" and "everybody can share it" are the same claim.
  late final _immutableRoots = [flutterSdkRoot, ...pubCacheRoots()];

  late final SeedStore _seedStore = SeedStore(
    engineRevision: _cache.engineRevision,
    flavor: seedFlavor(program.compilerArguments),
  );

  /// The shared half of this program, compiled by whichever checkout — or
  /// whichever *lane* — got here first.
  ///
  /// The catalog daemon compiles under the same flags against the same
  /// resolution, so the two lanes reach the same file and whichever runs first
  /// pays for both.
  Future<SeedKernel?> _findSeed() async {
    try {
      return _seedStore.find(
        await loadPackageConfigUri(Uri.file(_packageConfig!)),
      );
    } catch (e) {
      onLog?.call('[${program.name}] no seed kernel: $e');
      return null;
    }
  }

  Future<void> _writeSeed(
    FrontendServer compiler,
    String outputDill, {
    SeedKernel? improving,
  }) async {
    try {
      await writeSeedKernel(
        compiler: compiler,
        outputDill: outputDill,
        store: _seedStore,
        resolution: await loadPackageConfigUri(Uri.file(_packageConfig!)),
        immutableRoots: _immutableRoots,
        improving: improving,
        log: (line) => onLog?.call('[${program.name}] $line'),
      );
    } catch (e) {
      // A cache nobody could write costs the next checkout its head start,
      // which is what it would have cost anyway.
      onLog?.call('[${program.name}] no seed written: $e');
      // The kernel is not optional in the same way: the guest is spawned from
      // the output dill, and a failed excursion may have left the seed's own
      // program — an empty `main` — sitting there. Put this program back, and
      // let a failure to do that end the start, because a harness that came up
      // holding the wrong program answers every question wrongly.
      compiler.reset();
      var back = await compiler.compile();
      if (!back.ok) throw TesterCompileException(program.name, back.output);
      compiler.accept();
    }
  }

  Future<void> _spawnGuest(String dill) async {
    // Before this process adds one of its own, and once in the life of the
    // isolate: whatever is out there was left by a process that is not coming
    // back to kill it. See [sweepOrphanedGuests].
    var swept = sweepOrphanedGuestsOnce(
      log: (line) => onLog?.call('[fw] $line'),
    );
    if (swept > 0) onLog?.call('[fw] ended $swept orphaned harness processes');

    _guestAlive = true;
    _logFile?.closeSync();
    // Truncated per process, so the file is the current guest's life — and
    // written synchronously line by line, because the lines that matter most
    // arrive right before a run report is read and a buffered sink would
    // still be holding them.
    var log = File(logPath)..parent.createSync(recursive: true);
    var logSink = _logFile = log.openSync(mode: FileMode.write);
    void tee(String line) {
      try {
        logSink.writeStringSync('$line\n');
      } on FileSystemException {
        // The guest outlived its log: teardown closed the file first.
      }
    }

    var guest = await spawnGuest(
      dill,
      tee: tee,
      // Handed over the moment the process exists, so a `dispose` landing
      // while the guest is still booting finds something to kill.
      onStarted: (process) => _guest = process,
    );
    _vm = guest.vm;
    _events = guest.events;
    _lastDill = dill;
    unawaited(
      guest.process.exitCode.then((_) {
        // Identity-checked: a later guest's life is not this listener's to
        // end.
        if (identical(_guest, guest.process)) _guestAlive = false;
      }),
    );
  }

  /// The kernel the host's guest was last spawned from — what a pool spawns
  /// its own guests from, so every one of them runs the one build.
  String get dillPath =>
      _lastDill ??
      (throw StateError('no kernel yet — ensureGuest() builds one'));
  String? _lastDill;

  /// One more `flutter_tester` from [dill], connected and ready — the same
  /// spawn the host's own guest gets, minus the host's bookkeeping: its
  /// life is the caller's, which is what a pool of guests running one
  /// scenario each needs. Step events still reach [onEvent], so a panel
  /// filling a flow in does not care which guest produced it; [onGuestEvent]
  /// hears this guest's alone, which is what a caller needs to know what a
  /// guest had done by the time it died.
  Future<TesterGuest> spawnGuest(
    String dill, {
    void Function(String line)? tee,
    void Function(Process process)? onStarted,
    void Function(Map<String, Object?> event)? onGuestEvent,
    String label = 'tester',
  }) async {
    // The tail the guest has printed, in hand: a connect that finds a service
    // with no isolate asks for it, and pointing that failure at a file it
    // would have to be told to open is one step more than it needs. A guest
    // that dies mid-scenario is asked for it too, and an uncaught error's
    // stack is longer than a failed connect's, so more is kept than a connect
    // failure shows.
    var printed = <String>[];
    void keep(String line) {
      printed.add(line);
      if (printed.length > TesterGuest.outputKept) printed.removeAt(0);
      tee?.call(line);
    }

    // One engine start at a time — see [_booting]. Held until the guest has
    // said where its VM service is, which it says only after the engine is up.
    var booted = Completer<void>();
    void release() {
      if (!booted.isCompleted) booted.complete();
    }

    var turn = _booting;
    _booting = booted.future;
    await turn;

    var starting = Process.start(
      _cache.flutterTester,
      [
        '--vm-service-port=0',
        '--disable-service-auth-codes',
        '--icu-data-file-path=${_cache.icuData}',
        '--enable-checked-mode',
        '--verify-entry-points',
        ...rasterizerArguments(
          macOS: Platform.isMacOS,
          environment: Platform.environment,
        ),
        '--enable-dart-profiling',
        '--non-interactive',
        // The engine exits with `main` otherwise — S4's discovered flag.
        '--run-forever',
        '--packages=$_packageConfig',
        '--flutter-assets-dir=$_assetsDir',
        dill,
      ],
      // Deliberately *not* `UNIT_TEST_ASSETS`, which is how `flutter test`
      // makes an asset read complete under FakeAsync — it installs a handler
      // that answers `flutter/assets` from Dart. Measured on a real suite:
      // that deadlocks any `tester.runAsync` that itself loads an asset, and
      // is why `flutter test` hangs on a scenario that generates a PDF. The
      // program gives the boot a real-async turn instead.
      //
      // **And not inherited either**, which is why the parent's environment is
      // copied by hand rather than taken. `flutter test` sets that variable in
      // the process it runs a test in, so a guest spawned from inside one — an
      // integration test, this repo's own film dump — used to inherit a path
      // to the *host* package's bundle and answer every asset read from it:
      // the app under test then fails with "the asset does not exist" for
      // files that are sitting in its own bundle.
      includeParentEnvironment: false,
      environment: {
        ...Platform.environment,
        'FLUTTER_TEST': 'true',
        // Windows resolves a loaded DLL's *own* dependencies through the
        // executable's directory and PATH, not through the directory the DLL
        // was loaded from — so a hook-built DLL that links a second one needs
        // the bundle's native directory on PATH. The same line `flutter test`
        // adds, for the same reason; everywhere else the loader searches
        // beside the library and needs nothing.
        if (Platform.isWindows)
          'PATH':
              '${p.join(_assetsDir!, nativeAssetsDirName)};'
              '${Platform.environment['PATH'] ?? ''}',
      }..remove('UNIT_TEST_ASSETS'),
      // `flutter test` runs the tester from the package root, so a fixture
      // read at a relative path resolves there. Inherited, this would be
      // wherever `fw` happened to be started from.
      workingDirectory: packageRoot,
    );
    Process process;
    try {
      process = await starting;
    } catch (_) {
      release();
      rethrow;
    }
    onStarted?.call(process);
    recordSpawnedGuest(pid: process.pid, what: program.name);

    // **The window this closes.** A cold start is tens of seconds long and
    // every step of it is an await, so a `dispose` — a config reload swapping
    // the plugin graph, a worktree closing — can land after [_teardown] has
    // killed a guest that did not exist yet. The spawn then completes into a
    // host nobody will tear down again, and the guest is orphaned with its
    // owner still running. Checked here rather than at every await above,
    // because this is the only step that leaves something behind.
    if (_disposed) {
      release();
      process.kill();
      forgetSpawnedGuest(process.pid);
      _guestAlive = false;
      throw StateError('the harness was disposed while it was starting');
    }

    var stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          keep(line);
          onLog?.call('[$label] $line');
        })
        .asFuture<void>();

    var vmServiceUri = Completer<String>();
    var ready = Completer<void>();
    var stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          keep(line);
          onLog?.call('[$label] $line');
          var match = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
          if (match != null && !vmServiceUri.isCompleted) {
            vmServiceUri.complete(match.group(1));
            release();
          }
          if (line.contains(program.readyLine) && !ready.isCompleted) {
            ready.complete();
          }
        })
        .asFuture<void>();
    unawaited(
      process.exitCode.then((code) {
        // Every way a guest ends — teardown, a restart, `killGuest`, or the
        // engine falling over on its own — passes through this one line.
        forgetSpawnedGuest(process.pid);
        release();
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('flutter_tester exited with $code before ready'),
          );
        } else {
          onLog?.call('[${program.name}] the harness exited ($code)');
        }
      }),
    );

    try {
      await ready.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => throw TimeoutException(
          'the ${program.name} harness never became ready',
        ),
      );
    } finally {
      release();
    }
    var vm = await GuestVmService.connect(
      await vmServiceUri.future,
      describeGuest: () =>
          printed.skip(math.max(0, printed.length - 20)).join('\n'),
    );
    // `dart:developer` logs beside stdout, marked, so a dependency's own
    // failure report reaches the same line stream the guest's prints do.
    unawaited(
      vm
          .developerLog()
          .forEach((line) => onLog?.call('[$label] log: $line'))
          .catchError((Object _) {}),
    );
    return TesterGuest(
      process: process,
      vm: vm,
      output: printed,
      // Only ever a signal: a pipe that ended in an error has still ended.
      outputDone: Future.wait([stdoutDone, stderrDone])
          .then((_) {}, onError: (Object _) {}),
      // Cancelled by `TesterGuest.kill`, whose caller owns the guest.
      events: switch (program.eventStream) {
        var stream? => vm.extensionEvents(stream).listen((event) {
          onEvent?.call(event);
          onGuestEvent?.call(event);
        }),
        null => null,
      },
    );
  }

  /// The asset directory the guest reads, assembled by [AssetBundleBuilder] —
  /// manifests written, payloads symlinked, framework shaders compiled once per
  /// engine revision.
  ///
  /// Not `flutter build bundle`, which this used to shell out to. That command
  /// builds a *program*, so it insists on an entrypoint — and a package whose
  /// tests are its only entry (a library, a package whose app lives elsewhere)
  /// has no `lib/main.dart` to give it, which is where scenarios stopped with
  /// `Target file "lib/main.dart" not found`. The bundle wanted nothing from
  /// that kernel: the harness's own dill is what the tester is handed.
  ///
  /// Returns whether the directory changed, which is what decides a restart:
  /// the builder rebuilds in place under a live guest by design, but a guest
  /// registers `FontManifest.json` when it starts, so a changed bundle reaches
  /// one only through a fresh process.
  Future<bool> _syncAssetBundle() async {
    var sync = await AssetBundleBuilder(
      cache: _cache,
      rootPackageRoot: packageRoot,
      packageConfigPath: _packageConfig!,
    ).build(_assetsDir!);
    if (sync.changed) onLog?.call('[${program.name}] the asset bundle changed');
    return sync.changed;
  }

  /// Brings a warm guest up to date with the sources on disk, taking the turn.
  Future<void> refresh() => exclusive(sync);

  /// [refresh] for a caller that already holds the turn.
  ///
  /// Body edits take the fast lane: an incremental compile of what changed,
  /// pushed with `reloadSources` — and **never `ext.flutter.reassemble`**,
  /// which awaits a frame that never comes under a test binding outside a test
  /// (the S4 rule). The next call re-declares and rebuilds from scratch anyway,
  /// which is everything reassemble would have been for.
  ///
  /// A changed *source set* restarts the guest instead: the generated
  /// entrypoint's `main` has already run, and no reload re-runs `main`, so its
  /// table can never grow an import it did not start with.
  Future<void> sync() async {
    await start();
    if (!followEdits) {
      if (_vm == null || !_guestAlive) await restartGuest();
      return;
    }
    var sources = program.sources();
    var sourcesChanged = !const ListEquality<String>().equals(
      sources,
      _sources,
    );
    if (sourcesChanged) {
      _sources = sources;
      program.writeEntrypoint(sources);
    }
    // A changed asset — edited, added to a declared directory, or a pubspec
    // edit — restarts too: what the running engine registered at startup is
    // what it keeps. So does a guest that is simply gone (see [ensureGuest]) —
    // the reload lane below would talk to a dead service.
    var guestGone = _vm == null || !_guestAlive;
    var assetsChanged = await _syncAssetBundle();
    if (sourcesChanged || guestGone || assetsChanged) {
      await restartGuest();
      return;
    }

    _dirty.addAll(_invalidator!.sweep(_compiler!.sources));
    if (_dirty.isEmpty) return;

    onLog?.call(
      '[${program.name}] reloading ${_dirty.length} edited source(s)',
    );
    var compiled = await _compiler!.compile(_dirty.toList());
    if (compiled.errorCount > 0 || compiled.dillOutput == null) {
      await _compiler!.reject();
      throw TesterCompileException(program.name, compiled.output);
    }
    _compiler!.accept();
    _dirty.clear();
    _invalidator!.sweep(_compiler!.sources);

    var report = await _vm!.service.reloadSources(
      _vm!.isolateId,
      rootLibUri: compiled.dillOutput,
    );
    if (report.success != true) {
      // A delta the VM cannot apply — a changed field shape, usually. The
      // restart recovers everything the reload cannot.
      onLog?.call(
        '[${program.name}] hot reload refused, restarting the harness',
      );
      await restartGuest();
    }
  }

  /// Kills the guest and starts a fresh one from a full kernel, reusing the
  /// warm compiler and the asset bundle. Call inside [exclusive].
  Future<void> restartGuest() async {
    // A host that does not follow edits respawns what it compiled: the same
    // program, whatever is on disk now. It has no compiler of its own when it
    // shares one.
    if (!followEdits) {
      await start();
      await _stopGuest();
      await _spawnGuest(_leader?.dillPath ?? dillPath);
      return;
    }
    // From what is on disk *now*: a restart is the lane that rebuilds the
    // program, and it is reachable without a preceding sync (a dead guest, the
    // restart action), so compiling the previous source set would fail on a
    // file deleted since — or silently omit one added.
    _sources = program.sources();
    program.writeEntrypoint(_sources);

    await _stopGuest();

    // The fresh guest reads what is on disk now. ~15ms when nothing moved,
    // which is why every path here re-syncs rather than tracking whether the
    // caller already did.
    await _syncAssetBundle();

    var compiler = _compiler!;
    _dirty.addAll(_invalidator!.sweep(compiler.sources));
    // A launched guest reads a file, and a delta is not a program.
    compiler.reset();
    var compiled = await compiler.compile(_dirty.toList());
    if (compiled.errorCount > 0 || compiled.dillOutput == null) {
      await compiler.reject();
      throw TesterCompileException(program.name, compiled.output);
    }
    compiler.accept();
    _dirty.clear();
    _invalidator!.sweep(compiler.sources);

    await _spawnGuest(compiled.dillOutput!);
  }

  Future<void> _stopGuest() async {
    await _events?.cancel();
    _events = null;
    await _vm?.close();
    _vm = null;
    if (_guest case var guest?) {
      guest.kill();
      await guest.exitCode;
    }
    _guest = null;
  }

  /// Kills the guest without replacing it, leaving the compiler warm.
  ///
  /// Exists for the recovery test — an owner exposes it as its own
  /// `@visibleForTesting` seam — so that a test can assert the next call
  /// notices and respawns rather than talking to a dead service. Awaits the
  /// exit, so what follows is testing the recovery rather than racing the kill.
  Future<void> killGuest() async {
    if (_guest case var guest?) {
      guest.kill();
      await guest.exitCode;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardown();
  }

  /// Everything this host spawned, gone. Shared with the failed-start path,
  /// which has the same job and no business marking the host disposed.
  Future<void> _teardown() async {
    await _events?.cancel();
    _events = null;
    await _vm?.close();
    _vm = null;
    if (_guest case var guest?) {
      guest.kill();
      await guest.exitCode;
    }
    _guest = null;
    _guestAlive = false;
    _logFile?.closeSync();
    _logFile = null;
    if (_compiler case var compiler?) await compiler.shutdown();
    _compiler = null;
  }
}

/// One running `flutter_tester` from a kernel a [TesterHost] compiled.
///
/// The host's own guest is one of these under the hood; a live scenario pool
/// holds several, one scenario each, and ends them itself.
class TesterGuest {
  TesterGuest({
    required this.process,
    required this.vm,
    this.output = const [],
    Future<void>? outputDone,
    this.events,
  }) : outputDone = outputDone ?? Future.value();

  final Process process;
  final GuestVmService vm;

  /// The last [outputKept] lines the process printed, stdout and stderr as
  /// they arrived — live, so it keeps growing until [outputDone].
  final List<String> output;

  static const outputKept = 60;

  /// Completes when both pipes have closed, which is after the process has
  /// exited: the last thing a dying guest prints can still be on its way when
  /// the VM service connection has already dropped.
  final Future<void> outputDone;

  /// The step events forwarded to the host's `onEvent`, cancelled with the
  /// guest.
  final StreamSubscription<Map<String, Object?>>? events;

  Future<void> kill() async {
    await events?.cancel();
    await vm.close();
    process.kill();
    await process.exitCode;
  }
}

/// The generated program did not compile, with the compiler's own diagnostics.
///
/// Carries [output] rather than only a message because a caller may be able to
/// do something with it: `CompileBlame` reads these lines to work out which
/// entries to drop and serve the rest, where a plain string could only be
/// reported.
class TesterCompileException implements Exception {
  TesterCompileException(this.program, this.output);

  final String program;
  final List<String> output;

  @override
  String toString() =>
      'The $program harness does not compile:\n${output.join('\n')}';
}

/// Which rasterizer the harness draws with, and with which backend.
///
/// **Naming the backend is correctness, not speed.** A package's build hook
/// compiles its shaders for the host's *real* backend — measured on
/// `flutter_scene` across the three runners: Metal alone on macOS, SPIR-V and
/// GLES elsewhere. `flutter_tester` handed `--enable-impeller` and nothing
/// else falls through to its Vulkan branch on **every** host, so on macOS the
/// shaders a hook has just produced are unloadable and the library throws
/// before anything renders. Naming `metal` there is what makes them load;
/// elsewhere the default already is what the hook targeted, so nothing is
/// named and the engine's own choice stands.
///
/// This is also the line `flutter test` cannot cross: it offers
/// `--enable-impeller` and `--enable-flutter-gpu` but no `--impeller-backend`,
/// which is why a scenario that renders through Flutter GPU runs here and not
/// there. Spawning the tester ourselves is what buys the third flag — the same
/// reason we omit `--use-test-fonts`.
/// What [rasterizerArguments] makes the tester draw with, by name:
/// `skia-software`, `impeller-metal` or `impeller-vulkan`.
///
/// Vulkan is whatever adapter the host offers the tester, which on a CI runner
/// with no GPU is a CPU rasterizer — slower by a wide margin, and the first
/// thing to know about a comparison that took three times its usual length.
String rasterizerName({
  required bool macOS,
  required Map<String, String> environment,
}) => environment[softwareRenderingKey] == '1'
    ? 'skia-software'
    : macOS
    ? 'impeller-metal'
    : 'impeller-vulkan';

/// [rasterizerName] for this process's own host.
String hostRasterizer() =>
    rasterizerName(macOS: Platform.isMacOS, environment: Platform.environment);

List<String> rasterizerArguments({
  required bool macOS,
  required Map<String, String> environment,
}) {
  if (environment[softwareRenderingKey] == '1') {
    return const [
      '--enable-software-rendering',
      '--skia-deterministic-rendering',
    ];
  }
  return [
    '--enable-impeller',
    if (macOS) '--impeller-backend=metal',
    '--enable-flutter-gpu',
  ];
}
