import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/server/inspector.dart' show reassembleExtension;
// ignore: implementation_imports
import 'package:flutterware/src/world/protocol.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../utils/run_dir.dart';

/// A world script while it runs, from its owner's side: the process, and the
/// socket it declares its world on (`package:flutterware/src/world/
/// protocol.dart` has the wire).
///
/// One per opening. A restart closes this one and starts another, rather than
/// asking the script to run its body again: a script whose file changed since
/// it opened would otherwise restart as the old code, and nothing a script
/// kept in a global survives into the next opening by accident.
class WorldScriptProcess {
  WorldScriptProcess._(
    this.process,
    this._socket,
    this.messages,
    this._serviceInfo,
    this._compiler,
    this._said,
  ) {
    process.exitCode.then((code) => _exited = code).ignore();
  }

  final Process process;
  final Socket _socket;

  /// What it reloads through, brought back by [reload] when it has gone.
  final WorldCompiler? _compiler;

  /// Its exit code, once it has exited.
  int? _exited;

  /// The last thing it said that was not a stack frame: what an exit is
  /// quoted with.
  final LastSaid _said;

  /// Where the script's VM says how to reach its service — what [reload]
  /// speaks to.
  final String _serviceInfo;
  Future<VmService>? _service;

  /// Everything the script declares, in order, from `hello` to `closed`.
  final Stream<Map<String, Object?>> messages;

  static var _count = 0;

  /// Runs [file] in the package at [packageRoot] with [dart] — `dart run`, so
  /// it resolves and runs its build hooks as any script of that package does,
  /// through [compiler] — and opens the world with [knobs]. [onOutput] gets
  /// what it prints: its server's log, usually.
  static Future<WorldScriptProcess> start({
    required String dart,
    required String packageRoot,
    required String file,
    required Map<String, Object?> knobs,
    WorldCompiler? compiler,
    void Function(String line)? onOutput,
    Duration connectTimeout = const Duration(minutes: 2),
  }) async {
    var name = 'world-$pid-${_count++}';
    var socketPath = checkSocketPath(p.join(flutterwareRunDir(), '$name.sock'));
    var serviceInfo = p.join(flutterwareRunDir(), '$name.service.json');
    if (File(serviceInfo).existsSync()) File(serviceInfo).deleteSync();
    if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    Process process;
    try {
      process = await Process.start(
        dart,
        [
          'run',
          ...?compiler?.runArguments,
          // A service on loopback, for [reload] alone.
          '--enable-vm-service=0',
          '--no-dds',
          '--write-service-info=$serviceInfo',
          file,
        ],
        workingDirectory: packageRoot,
        environment: {worldSocketVariable: socketPath},
      );
    } on Object {
      await server.close();
      rethrow;
    }
    var said = LastSaid();
    for (var stream in [process.stdout, process.stderr]) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map(withoutToolNoise)
          .where((line) => line != null)
          .cast<String>()
          .listen((line) {
            said.add(line);
            onOutput?.call(line);
          });
    }
    // Refused before it connects — a compile error, a missing dependency —
    // the script exits, and what it printed is the reason. Kept by the script
    // and destroyed by [close].
    // ignore: close_sinks
    Socket socket;
    try {
      socket = await Future.any([
        server.first,
        process.exitCode.then<Socket>((code) => throw WorldScriptExited(code)),
      ]).timeout(connectTimeout);
    } finally {
      await server.close();
      if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    }
    var messages = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(decodeWorldMessage)
        .asBroadcastStream();
    var script = WorldScriptProcess._(
      process,
      socket,
      messages,
      serviceInfo,
      compiler,
      said,
    );
    script.send(WorldMessage.open, {'knobs': knobs});
    return script;
  }

  void send(String type, [Map<String, Object?> fields = const {}]) {
    try {
      _socket.writeln(encodeWorldMessage(type, fields));
    } on Object {
      // The script is gone; its exit says so.
    }
  }

  /// Hot-reloads the script from the source on disk, as the VM does: every
  /// function and method runs its new code from its next call — the server
  /// the script hosts, what its actions call — while the state it holds
  /// stays. Its body does not run again, and a closure made before the
  /// reload keeps its old body; so every `FlutterwareServer.onReassemble`
  /// callback then runs ([reassembleExtension]), and a server builds its
  /// router and middleware again from the new code.
  ///
  /// Answers how long the code took to reload, and how long the reassemble
  /// callbacks then took to rebuild on it — and, when its compiler had gone
  /// and a fresh one was started for it, why ([WorldCompiler.revive]).
  ///
  /// Throws a [WorldScriptReloadFailed] with the compiler's words when the
  /// source does not compile, and the script runs on as it was; with the
  /// VM's when it refused to reload at all; or with what a reassemble
  /// callback threw, once the code is in.
  ///
  /// A reload the VM will not run — the script already reloading, from a
  /// hot reloader of the project's own running inside it, or its compiler
  /// tripping over that reload's — waits and goes after it, for up to
  /// [busyFor]. A script that exits meanwhile is said to have, with its exit
  /// code and the last thing it said: all a reload is left with otherwise is
  /// a connection refused by a VM that is not there.
  Future<({Duration code, Duration reassemble, String? compiler})> reload({
    Duration busyFor = const Duration(seconds: 10),
  }) async {
    var watch = Stopwatch()..start();
    try {
      // First: without its compiler, the VM refuses every reload.
      var revived = await _compiler?.revive();
      var took = await _reload(watch, busyFor);
      return (code: took.code, reassemble: took.reassemble, compiler: revived);
    } on Object catch (error) {
      // The source is the source, whatever became of the script since; any
      // other failure may be the VM going, its connection with it.
      if (error case WorldScriptReloadFailed(
        exited: null,
        refused: false,
        reloaded: false,
      )) {
        rethrow;
      }
      if (error is! WorldScriptReloadFailed || error.exited == null) {
        if (await _exitedWithin(const Duration(seconds: 1)) case var code?) {
          throw _exitFailure(code);
        }
      }
      rethrow;
    }
  }

  Future<({Duration code, Duration reassemble})> _reload(
    Stopwatch watch,
    Duration busyFor,
  ) async {
    var isolates =
        (await (await _live()).getVM()).isolates ?? const <IsolateRef>[];
    // One reload per isolate group: the isolates of a group share code.
    var groups = <String>{};
    for (var isolate in isolates) {
      if (!groups.add(isolate.isolateGroupId ?? isolate.id!)) continue;
      var report = await reloadWhenFree(
        // Asked for again each time: a connection that dropped is made
        // again.
        () async => (await _live()).reloadSources(isolate.id!),
        busyFor: busyFor,
      );
      if (report.success != true) {
        var notices = [
          for (var notice in report.json?['notices'] as List? ?? const [])
            if (notice case {'message': String message}) message,
        ];
        var said = notices.join('\n');
        // Not every failed report is the source: a script open long enough
        // was answered `Kernel service was not set up for incremental
        // compilation`, which only a restart cleared.
        throw WorldScriptReloadFailed(
          notices.isEmpty ? 'The VM refused the reload.' : said,
          refused: !_compilerError.hasMatch(said),
        );
      }
    }
    var code = watch.elapsed;
    var service = await _live();
    for (var ref in isolates) {
      var isolate = await service.getIsolate(ref.id!);
      if (!(isolate.extensionRPCs ?? const []).contains(reassembleExtension)) {
        continue;
      }
      try {
        await service.callServiceExtension(
          reassembleExtension,
          isolateId: ref.id,
        );
      } on RPCError catch (error) {
        throw WorldScriptReloadFailed(
          error.details ?? error.message,
          reloaded: true,
        );
      }
    }
    return (code: code, reassemble: watch.elapsed - code);
  }

  /// The connection to the script's VM, made again once one has dropped.
  Future<VmService> _live() {
    if (_service case var live?) return live;
    var live = _service = _connect();
    live.then((service) => service.onDone).then((_) {
      if (identical(_service, live)) _service = null;
    }).ignore();
    return live;
  }

  Future<VmService> _connect() async {
    // The file a script that died leaves names a port nothing listens on.
    if (_exited case var code?) throw _exitFailure(code);
    // The VM creates the file before it writes it: empty, or half written,
    // is not there yet.
    var uri = _serviceUri();
    for (var waited = 0; uri == null; waited++) {
      if (waited == 100) {
        throw WorldScriptReloadFailed(
          'The world script has no VM service to reload it through.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      uri = _serviceUri();
    }
    return vmServiceConnectUri(
      '${uri.replace(scheme: 'ws', path: '${uri.path}ws')}',
    );
  }

  /// Where the script's VM service is, once the VM has written it.
  Uri? _serviceUri() {
    try {
      return switch (jsonDecode(File(_serviceInfo).readAsStringSync())) {
        {'uri': String uri} => Uri.parse(uri),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  Future<int?> _exitedWithin(Duration wait) async =>
      _exited ??
      await process.exitCode
          .then<int?>((code) => code)
          .timeout(wait, onTimeout: () => null);

  WorldScriptReloadFailed _exitFailure(int code) => WorldScriptReloadFailed(
    [
      'The world script exited ($code) during the reload.',
      if (_said.line case var line?) 'It last said: $line',
    ].join(' '),
    exited: code,
  );

  /// Asks the script to close — its `onClose` callbacks run — and waits for
  /// it to go, killing it if it has not after [timeout].
  Future<void> close({Duration timeout = const Duration(seconds: 15)}) async {
    _service?.then((service) => service.dispose()).ignore();
    if (File(_serviceInfo).existsSync()) File(_serviceInfo).deleteSync();
    send(WorldMessage.close);
    await _socket.flush().catchError((Object _) {});
    await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    _socket.destroy();
  }
}

/// A reload the world script's source did not survive — a compile error —
/// with what the compiler said.
/// Runs [reload] — one `reloadSources` — and again while the VM will not
/// run it, for up to [busyFor]: already reloading, from a hot reloader of the
/// project's own inside the script, or its compiler tripping over that
/// reload's (`Bad state: No element`). A compile error is not that, and is
/// thrown at once: the compiler says what is wrong where, a line of the
/// source. Nor is a compiler that is gone — two reloads compiling at once
/// can take it down — which no wait brings back.
@visibleForTesting
Future<T> reloadWhenFree<T>(
  Future<T> Function() reload, {
  Duration busyFor = const Duration(seconds: 10),
  Duration pause = const Duration(milliseconds: 200),
}) async {
  var waited = Stopwatch()..start();
  while (true) {
    try {
      return await reload();
    } on RPCError catch (error) {
      var said = [error.message, ?error.details].join('\n');
      if (_compilerError.hasMatch(said)) {
        throw WorldScriptReloadFailed(error.details ?? error.message);
      }
      // Nothing to wait for: the compiler the script reloads through went
      // down under this reload, and only the next one starts a fresh one.
      if (_compilerGone.hasMatch(said)) {
        throw WorldScriptReloadFailed(
          "The script's compiler stopped during this reload. Two reloads "
          'compiling at once can stop it, for example when the script runs a '
          'hot reloader of its own. Reload again, and a new compiler compiles '
          'it.\n$said',
          refused: true,
        );
      }
      if (waited.elapsed < busyFor) {
        await Future<void>.delayed(pause);
        continue;
      }
      throw WorldScriptReloadFailed(
        [
          error.code == RPCErrorKind.kIsolateIsReloading.code
              ? 'The script was still reloading after ${busyFor.inSeconds} s. '
                    'Most likely another reloader is running inside it.'
              : 'The VM would not reload the script, and still would not '
                    'after ${busyFor.inSeconds} s.',
          '${error.message} (${error.code})',
          ?error.details,
        ].join('\n'),
        refused: true,
      );
    }
  }
}

/// How the compiler names a mistake: `lib/world.dart:17:22: Error: …`.
final _compilerError = RegExp(r':\d+:\d+: Error: ');

/// What the VM says when the resident compiler it reloads through is gone.
final _compilerGone = RegExp(
  r'SocketException: (Connection refused|Connection reset)',
);

class WorldScriptReloadFailed implements Exception {
  WorldScriptReloadFailed(
    this.message, {
    this.reloaded = false,
    this.refused = false,
    this.exited,
  });

  final String message;

  /// The script's exit code, when it exited during the reload.
  final int? exited;

  /// Whether the code reloaded and a handler then failed to build again,
  /// rather than the code not compiling.
  final bool reloaded;

  /// Whether the VM would not reload at all — the script already reloading,
  /// in no state to — rather than the code not compiling.
  final bool refused;

  @override
  String toString() => message;
}

/// A world script that ended before it said anything.
class WorldScriptExited implements Exception {
  WorldScriptExited(this.exitCode);

  final int exitCode;

  @override
  String toString() => 'The world script exited ($exitCode) before it started.';
}

/// The last line a script said that was not a stack trace: of an uncaught
/// error, the error rather than its bottom frame; of the VM aborting, its
/// reason — `kernel_loader.cc: 352: error: Invalid kernel binary` — rather
/// than the native stack it dumps after it, which ends
/// `-- End of DumpStackTrace`.
@visibleForTesting
class LastSaid {
  String? line;

  void add(String said) {
    var trimmed = said.trim();
    if (trimmed.isEmpty || _trace.hasMatch(trimmed)) return;
    line = trimmed;
  }

  static final _trace = RegExp(
    // A Dart frame, and the gap between two.
    r'^(#\d+\s|<asynchronous suspension>$'
    // The VM's crash dump: its header, a native frame, its end.
    r'|=+ CRASH =+$|(version|pid|thread|os|isolate_instructions|fp|si_signo)='
    r'|pc 0x|-- End of DumpStackTrace)',
  );
}

/// [line] without what `dart run` says about itself, or null when that was
/// all of it. `Running build hooks...` ends in no newline, so it arrives glued
/// to the start of the script's own first line, sometimes twice. The VM's
/// banner about its service is the world's business, not the script's.
String? withoutToolNoise(String line) {
  if (line.startsWith('The Dart VM service is listening on') ||
      line.startsWith('The Dart DevTools debugger')) {
    return null;
  }
  var own = line.replaceFirst(_toolNoise, '');
  return own.isEmpty && own.length != line.length ? null : own;
}

final _toolNoise = RegExp(r'^(Running build hooks\.\.\.)+');

/// The resident compiler a world script is compiled by — `dart run
/// --resident` — so an opening after the first, and every restart, starts
/// the script in a fraction of a second rather than compiling it whole: a
/// script that hosts a large server spends most of an opening there.
///
/// One per `OpenWorld`, shut down when it closes: the compiler keeps its
/// kernels on disk, keyed on the script's path, so the next process's
/// compiler starts from them — measured on a heavy script, 0.76 s against 6 s
/// for a plain `dart run` — and nothing is left running after the world.
class WorldCompiler {
  WorldCompiler(this.dart)
    : infoFile = p.join(
        flutterwareRunDir(),
        'world-compiler-$pid-${_count++}.info',
      );

  /// The `dart` it belongs to: a compiler serves the SDK that started it.
  final String dart;

  /// How `dart` finds this compiler; it starts one if the file names none.
  final String infoFile;

  static var _count = 0;

  List<String> get runArguments => [
    '--resident',
    '--quiet',
    '--resident-compiler-info-file=$infoFile',
  ];

  /// Stops the compiler, if one started.
  Future<void> shutdown() => _shutdown(dart, infoFile);

  /// Starts a fresh compiler at [infoFile] when the one there has gone, and
  /// says why it had to; null when the one there answers.
  ///
  /// A script's VM reloads through whichever compiler the file names, and
  /// with none there it refuses every reload — `Kernel service was not set
  /// up for incremental compilation when started` — until something starts
  /// one at that path. A compiler goes two ways: it stops itself after
  /// 30 minutes without a request and deletes the file, or it dies — two
  /// reloads compiling at once can do that — and leaves the file naming a
  /// port nothing listens on.
  Future<String?> revive() async {
    var file = File(infoFile);
    String why;
    if (!file.existsSync()) {
      why =
          "The script's compiler had stopped, as it does after 30 minutes "
          'without a reload';
    } else if (await _answers(file.readAsStringSync())) {
      return null;
    } else {
      why = "The script's compiler had died";
      try {
        file.deleteSync();
      } on FileSystemException {
        // Gone meanwhile; starting one is all that is left to do.
      }
    }
    var started = await Process.run(dart, [
      'compilation-server',
      'start',
      '--resident-compiler-info-file=$infoFile',
    ]);
    return started.exitCode == 0 && file.existsSync()
        ? '$why; a fresh one compiled this reload'
        : '$why, and a fresh one did not start: ${started.stderr}'.trim();
  }

  /// Whether the compiler [info] names takes a connection:
  /// `address:127.0.0.1 sdkHash:… port:65447`.
  static Future<bool> _answers(String info) async {
    var address = RegExp(r'address:(\S+)').firstMatch(info)?[1];
    var port = int.tryParse(RegExp(r'port:(\d+)').firstMatch(info)?[1] ?? '');
    if (address == null || port == null) return false;
    try {
      var socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  /// Stops the compilers of processes that ended without closing their world
  /// — killed, or crashed. Housekeeping: nothing fails over it.
  static Future<void> sweep(String dart, {String? directory}) async {
    try {
      for (var entity in Directory(
        directory ?? flutterwareRunDir(),
      ).listSync()) {
        var match = _infoName.firstMatch(p.basename(entity.path));
        if (match == null || isProcessAlive(int.parse(match[1]!))) continue;
        await _shutdown(dart, entity.path);
      }
    } on Object {
      // A run directory that is not there has nothing to sweep.
    }
  }

  static final _infoName = RegExp(r'^world-compiler-(\d+)-\d+\.info$');

  static Future<void> _shutdown(String dart, String infoFile) async {
    if (!File(infoFile).existsSync()) return;
    try {
      await Process.run(dart, [
        'compilation-server',
        'shutdown',
        '--resident-compiler-info-file=$infoFile',
      ]);
    } on Object {
      // Gone already, or never started: the file is all that is left.
    }
    try {
      File(infoFile).deleteSync();
    } on FileSystemException {
      // `shutdown` removed it.
    }
  }
}
