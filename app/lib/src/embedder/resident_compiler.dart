import 'dart:io';

import 'package:package_config/package_config.dart';

import 'flutter_cache.dart';
import 'frontend_server.dart';
import 'seed_kernel.dart';

/// The result of one [ResidentCompiler.compile] call.
class CompileOutcome {
  CompileOutcome({
    required this.dillOutput,
    required this.errorCount,
    required this.output,
    required this.elapsed,
    required this.newSourceCount,
  });

  /// The kernel written for this compile — a full dill on the first call, an
  /// incremental delta afterwards. Null when the compiler produced nothing.
  final String? dillOutput;

  final int errorCount;

  /// The compiler's own diagnostics, which is where an error's text lives.
  final List<String> output;

  final Duration elapsed;

  /// How many libraries this compile added, which is ~0 when revisiting an
  /// entry the compiler has already seen.
  final int newSourceCount;

  bool get ok => errorCount == 0 && dillOutput != null;
}

/// A `frontend_server` kept alive across compiles, so the first call is cold
/// and every later one is an incremental recompile of just what changed.
///
/// This is the difference between a catalog that recompiles the world per entry
/// and one that switches in milliseconds.
///
/// The *first* compile is warm too when a `warmDill` is given: the compiler
/// loads a kernel an earlier session produced. Measured against
/// `app/tool/catalog/demos`, that is 2396ms cold against 341ms warm.
///
/// It does **not** recompile what changed since that kernel was written, and
/// this doc used to claim it did. `recompile` drops exactly the libraries it is
/// named and serves every other one from the state it was initialised with, so
/// a file edited between one session saving a warm kernel and the next starting
/// from it is served stale until somebody says otherwise. [startedFrom] is who
/// says: stat it, and anything newer has to be invalidated by hand. See
/// `SourceInvalidator.sweep`'s `compiledAt`.
class ResidentCompiler {
  ResidentCompiler._(
    this._server,
    this.outputDill,
    this._warmDill,
    this.startedFrom,
  );

  final FrontendServer _server;

  /// Where the first, full kernel is written. The guest loads this at startup.
  final String outputDill;

  /// Where that kernel is kept for the *next* session to start warm from, or
  /// null when warm starts are off.
  final String? _warmDill;

  /// The kernel this compiler was initialised from, or null when the compile
  /// was genuinely cold.
  ///
  /// The program this holds is as old as this file, which is the only thing
  /// that says which sources its state can still be trusted for.
  final String? startedFrom;

  /// When [startedFrom] was written, or null for a cold compile.
  DateTime? get startedFromStamp => switch (startedFrom) {
    var path? when File(path).existsSync() => File(path).statSync().modified,
    _ => null,
  };

  /// Every file the compiled program is made of, which is what a
  /// `SourceInvalidator` stats to answer "what did the user edit".
  Set<Uri> get sources => _server.sources;

  static Future<ResidentCompiler> start({
    required String entrypoint,
    required String outputDill,
    required String packageConfig,
    required FlutterCache cache,

    /// What the compiler's diagnostic paths are relative to — see
    /// [FrontendServer.start]. Whatever reads them back has to resolve them
    /// against this same directory, and the daemon's blame does.
    required String workingDirectory,

    /// Persist the cold kernel and start from it next time.
    ///
    /// Off by default because it costs a file copy and a correctness
    /// assumption: the cached kernel must have been produced by the same SDK
    /// against the same package config. The daemon owns that decision.
    String? warmDill,

    /// A kernel of the *shared* half of the program — the SDK, the framework
    /// and the resolved dependencies — to start from when there is no
    /// [warmDill] for this checkout yet.
    ///
    /// It holds none of the project's own sources, so unlike [warmDill] it is
    /// worktree-independent and every checkout on one machine can start from
    /// the same file. Measured on this repo's catalog in a freshly created
    /// worktree: **5.5s cold against 1.5s seeded**. Ranked below [warmDill],
    /// which is the whole program rather than its shared half.
    String? seedDill,

    /// Stamp every widget with the source location that built it.
    ///
    /// See `DaemonConfig.trackWidgetCreation` for why this is on and what it
    /// was measured to cost. A caller that changes it must not hand the
    /// compiler a [warmDill] produced under the other setting.
    bool trackWidgetCreation = true,
  }) async {
    File(outputDill).parent.createSync(recursive: true);
    var warm = warmDill != null && File(warmDill).existsSync()
        ? warmDill
        : seedDill != null && File(seedDill).existsSync()
        ? seedDill
        : null;
    stderr.writeln(
      warm == null
          ? '[compiler] no warm kernel; this compile is cold'
          : '[compiler] starting from $warm',
    );
    var server = await FrontendServer.start(
      executable: cache.dartAotRuntime,
      snapshot: cache.frontendServerSnapshot,
      entrypoint: entrypoint,
      outputDill: outputDill,
      packageConfig: packageConfig,
      sdkRoot: cache.flutterPatchedSdkDir,
      platformDill: cache.platformDill,
      workingDirectory: workingDirectory,
      initializeFromDill: warm,
      extraArguments: argumentsFor(trackWidgetCreation: trackWidgetCreation),
    );
    return ResidentCompiler._(server, outputDill, warmDill, warm);
  }

  /// The compiler flags a [start] with these settings passes.
  ///
  /// Named here rather than spelled inline so that the flags and the
  /// [seedFlavor] derived from them cannot drift apart: a seed compiled with
  /// creation locations must never prime a compiler running without them, and
  /// nothing but this list knows which of the two this is.
  static List<String> argumentsFor({required bool trackWidgetCreation}) => [
    if (trackWidgetCreation) '--track-widget-creation',
  ];

  /// Whether this compiler holds an accepted state to roll back *to*.
  ///
  /// The first compile of a process has none, and that is the difference
  /// between a rollback and a rebuild: `reject` on nothing recompiles the whole
  /// program's outlines to arrive back where it already was. Measured on this
  /// repo's catalog, where one demo is a deliberately broken fixture: the
  /// failing compile cost 6.1s and the reject after it another **5.5s**, of an
  /// 11.6s cold start.
  var _accepted = false;

  /// Compiles, invalidating [invalidated] first.
  ///
  /// A failed compile is **rejected and swallowed**: the caller keeps its guest
  /// and can compile again. A broken demo must not end the session — S3
  /// measured that the guest survives, and this is what preserves it.
  ///
  /// Rejected only once there is something to reject to — see [_accepted].
  /// Nothing is given up by skipping it: a caller whose first compile failed
  /// goes on to change the program (the catalog drops the entry it blamed) and
  /// compile again, and until an `accept` the next compile is a whole program
  /// either way.
  Future<CompileOutcome> compile([List<Uri> invalidated = const []]) =>
      _compile(_server.compile(invalidated));

  Future<CompileOutcome> _compile(Future<FrontendServerResult> pending) async {
    var result = await pending;
    if (result.ok) {
      _server.accept();
      _accepted = true;
    } else if (_accepted) {
      await _server.reject();
    }
    return CompileOutcome(
      dillOutput: result.dillOutput,
      errorCount: result.errorCount,
      output: result.output,
      elapsed: result.elapsed,
      newSourceCount: result.newSources.length,
    );
  }

  /// Makes the next [compile] emit a whole program at [outputDill], which is
  /// what a guest launched from scratch loads.
  void reset() => _server.reset();

  /// Leaves the shared half of this program behind for the next checkout that
  /// has never compiled it, or that would otherwise start from less of it than
  /// this one could leave. See [writeSeedKernel], which owns that decision —
  /// hand it [improving], the seed this start used, and it answers.
  Future<String?> writeSeed({
    required SeedStore store,
    required PackageConfig resolution,
    required List<String> immutableRoots,
    SeedKernel? improving,
    void Function(String)? log,
  }) => writeSeedKernel(
    compiler: _server,
    outputDill: outputDill,
    store: store,
    resolution: resolution,
    immutableRoots: immutableRoots,
    improving: improving,
    log: log,
  );

  /// Saves the full kernel at [outputDill] as the next session's warm start.
  ///
  /// Only meaningful right after a successful *full* compile — an incremental
  /// delta is not a program. Copied rather than pointed at, because the
  /// compiler rewrites [outputDill] and would otherwise be reading the file it
  /// is initialising from.
  ///
  /// Written beside itself and renamed into place, because this file now
  /// outlives the process that wrote it *and* is shared by processes that are
  /// not each other's: two daemons of different revisions serving one package
  /// hold the same kernel. A reader must see a whole kernel or none; a copy
  /// straight onto the path lets it see half of one.
  void saveWarmStart() {
    var warm = _warmDill;
    if (warm != null) saveKernelTo(warm);
  }

  /// Copies the kernel at [outputDill] to [destination], atomically.
  ///
  /// Best effort, and silent: everything written this way is a cache, and a
  /// destination that cannot be written costs the next start its head start
  /// rather than costing this one anything.
  void saveKernelTo(String destination) =>
      copyKernelAtomically(outputDill, destination);

  Future<void> shutdown() => _server.shutdown();
}
