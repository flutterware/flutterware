import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:collection/collection.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/watch.dart';
import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/inspect_client.dart';
import 'package:flutterware_app/src/previews/package_config_locator.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/guest_vm_service.dart';
import 'package:flutterware_app/src/embedder/protocol.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// Measures the two things the watch was not to be built without: whether
/// VM-service events at 60Hz arrive smoothly or batch, and what a per-frame
/// walk of a real tree costs. **Per-frame is allowed only if the measurement
/// says it is free**, and otherwise the watch debounces.
///
/// It measures the real thing rather than a benchmark of something shaped like
/// it: the guest is the real embedder host, the demo is one that genuinely
/// animates, and the numbers come out of the production `GuestWatch` rather
/// than a copy of it. A benchmark that diverges from the code it stands for is
/// worse than no benchmark, because it is believed.
///
/// ```sh
/// cd app && dart run tool/catalog/watch_spike.dart
/// ```
Future<void> main(List<String> args) async {
  var packageRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  var cache = FlutterCache.fromRunningSdk();
  var seconds = int.tryParse(_arg(args, '--seconds') ?? '') ?? 5;

  var config = DaemonConfig(
    appPackageRoot: packageRoot,
    projectRoot: packageRoot,
    packageConfig: requirePackageConfig(packageRoot),
    flutterSdkRoot: cache.flutterRoot,
    roots: const ['tool/catalog'],
    emitProbe: false,
  );

  stdout.writeln('[spike] starting the compiler daemon');
  var (daemon, ready) = await CompilerDaemonClient.connect(
    dartExecutable: p.join(cache.flutterRoot, 'bin', 'dart'),
    config: config,
  );
  stdout.writeln('[spike] ${ready.entries.length} entries');

  var guest = await _Guest.launch(await daemon.hostPath(), ready);
  try {
    // Every entry that renders, so the walk cost is reported against a range of
    // tree sizes rather than against whichever one happened to be first. The
    // cheapest way to be wrong here is to measure the smallest demo in the
    // repo and call the number typical.
    var only = _arg(args, '--only');
    for (var entry in ready.entries) {
      if (only != null && !entry.id.contains(only)) continue;
      var compiled = await daemon.select(entry.id);
      if (!compiled.ok) continue;
      await guest.vmService.reload(compiled.dill!);
      await _measure(guest, entry.id, entry.name, seconds: seconds);
    }
  } finally {
    await guest.shutdown();
    await daemon.close();
  }
}

Future<void> _measure(
  _Guest guest,
  String entryId,
  String name, {
  required int seconds,
}) async {
  var inspect = InspectClient(
    guest.vmService,
    patience: InspectPatience.headless,
  );

  var tree = await inspect.tree(entryId);
  if (tree?.root == null) {
    stdout.writeln('\n[$name] no tree — skipped');
    return;
  }
  var nodes = tree!.nodes.toList();

  // What the tree read costs today, for the comparison the whole design rests
  // on: if the summary-tree walk were free there would be no reason to hash
  // shapes at all, and the structure tier would just push the tree.
  var pull = Stopwatch()..start();
  for (var i = 0; i < 5; i++) {
    await inspect.tree(entryId);
  }
  var pullMicros = pull.elapsedMicroseconds ~/ 5;

  // A node an animation actually carries, when the demo has one.
  //
  // This is not a detail. The first run of this spike picked the deepest node
  // with a box, got one push out of a demo rendering a clean 180 frames in
  // three seconds, and so measured nothing about the event channel at all.
  // That result is the *right* answer to the cost question and no answer to the
  // cadence one: a spinner repaints without moving anything, and a watch that
  // fires on it would be a watch reporting repaints. So for the cadence
  // question the node has to be one under a transition, which is what moves a
  // box every frame.
  var moving = nodes.where((n) => n.type.endsWith('Transition')).firstOrNull;
  var watched =
      (moving == null
          ? null
          : nodes.lastWhereOrNull(
              (n) => n.id.startsWith('${moving.id}/') && n.layout != null,
            )) ??
      nodes.lastWhere((n) => n.layout != null, orElse: () => nodes.first);

  var arrivals = <int>[];
  var pushes = <WatchPush>[];
  var clock = Stopwatch()..start();
  var subscription = inspect.watches.listen((push) {
    arrivals.add(clock.elapsedMicroseconds);
    pushes.add(push);
  });

  var started = await inspect.watch(nodeId: watched.id);
  await Future<void>.delayed(Duration(seconds: seconds));
  var stats = await inspect.watchStats();
  await inspect.unwatch();
  await subscription.cancel();

  var gaps = [
    for (var i = 1; i < arrivals.length; i++) arrivals[i] - arrivals[i - 1],
  ]..sort();
  var hashes = [for (var push in pushes) push.hashMicros]..sort();
  var geometry = pushes.where((p) => p.geometry != null).length;
  var structure = pushes.where((p) => p.structureChanged).length;

  stdout.writeln('\n[$name] $entryId');
  stdout.writeln(
    '  summary tree: ${nodes.length} reported nodes · '
    'ext.flutterware.tree round trip ${_ms(pullMicros)}',
  );
  stdout.writeln('  watching ${watched.type} (${watched.id})');
  stdout.writeln(
    '  elements walked per frame: ${stats?.nodes ?? started?.nodes} · '
    'id -> render object resolve ${_ms(stats?.resolveMicrosLast ?? 0)}',
  );
  stdout.writeln(
    '  shape hash: mean ${_ms(stats?.hashMicrosMean ?? 0)} · '
    'max ${_ms(stats?.hashMicrosMax ?? 0)} · '
    'p50 ${_ms(_pct(hashes, 50))} · p95 ${_ms(_pct(hashes, 95))}',
  );
  stdout.writeln(
    '  frames ${stats?.frames} · pushes ${pushes.length} '
    '(geometry $geometry, structure $structure) over ${seconds}s',
  );
  if (gaps.isEmpty) {
    // Said as two different things, because they *are* two different things and
    // the first draft of this line called both of them "nothing moves". A demo
    // that drew 180 frames and pushed once is the design working; a demo that
    // drew none is a demo that was never on screen.
    stdout.writeln(
      pushes.isEmpty
          ? '  arrivals: none in ${stats?.frames ?? 0} frames — '
                'nothing this watch cares about moved'
          : '  arrivals: one, in ${stats?.frames ?? 0} frames — '
                'too few to say anything about cadence',
    );
  } else {
    stdout.writeln(
      '  arrivals: ${(pushes.length / seconds).toStringAsFixed(1)}/s · '
      'gap p50 ${_ms(_pct(gaps, 50))} · p95 ${_ms(_pct(gaps, 95))} · '
      'max ${_ms(gaps.last)}',
    );
    // The question behind the question. Events that batch show up as a run of
    // near-zero gaps followed by a long one — a mean that looks like 16ms and
    // a p95 that does not.
    var clustered = gaps.where((g) => g < 2000).length;
    stdout.writeln(
      '  ${(100 * clustered / gaps.length).round()}% of gaps under 2ms '
      '(a high figure with a long tail means the transport is batching)',
    );
  }
}

int _pct(List<int> sorted, int percentile) {
  if (sorted.isEmpty) return 0;
  var at = ((sorted.length - 1) * percentile / 100).round();
  return sorted[at];
}

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(3)}ms';

String? _arg(List<String> args, String name) {
  for (var arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

/// The real embedder host, headless, with its socket drained.
///
/// Draining is not optional: the guest blocks writing frames when nobody is
/// reading, and a guest that has stopped painting is a guest whose per-frame
/// cost measures zero.
class _Guest {
  _Guest._(this._process, this._server, this._socketFile, this.vmService);

  final Process _process;
  final ServerSocket _server;
  final File _socketFile;
  final GuestVmService vmService;

  static Future<_Guest> launch(String hostPath, DaemonReady ready) async {
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'watch_spike.sock'),
    );
    var socketFile = File(socketPath);
    if (socketFile.existsSync()) socketFile.deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    var process = await Process.start(hostPath, [
      ready.assetsDir,
      ready.icuData,
      socketPath,
      '800',
      '600',
    ]);

    var uri = Completer<String>();
    StreamGroup.merge([process.stdout, process.stderr])
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          var match = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
          if (match != null && !uri.isCompleted) uri.complete(match.group(1));
        });

    var connected = await Future.any<Object?>([server.first, process.exitCode]);
    if (connected is! Socket) throw StateError('the guest never connected');
    var frames = 0;
    var reader = FrameReader();
    connected.listen((chunk) {
      for (var message in reader.addBytes(chunk)) {
        if (message is FrameReadyMessage) frames++;
      }
    });

    var vmService = await GuestVmService.connect(await uri.future);
    // Nothing to reload into until the framework is up, and "up" is a frame
    // rather than a connection — reloading before `ext.flutter.reassemble` is
    // registered fails with a "Method not found" that looks nothing like the
    // real cause.
    var waited = Stopwatch()..start();
    while (frames == 0 && waited.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return _Guest._(process, server, socketFile, vmService);
  }

  Future<void> shutdown() async {
    await vmService.close();
    _process.kill();
    await _process.exitCode;
    await _server.close();
    if (_socketFile.existsSync()) _socketFile.deleteSync();
  }
}
