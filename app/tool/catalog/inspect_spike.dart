import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutterware_app/src/previews/package_config_locator.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/guest_vm_service.dart';
import 'package:flutterware_app/src/embedder/protocol.dart' as ipc;
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// Measures two things that were guesses: whether the Flutter inspector is
/// really reachable in the embedder guest, and what a widget tree costs to
/// carry.
///
/// Creation tracking is on by default now that it has been measured; pass
/// `--no-track-widget-creation` to re-measure the baseline it was compared
/// against. Kill this worktree's daemon and remove `app/build/catalog` between
/// runs, or the second inherits the first's warm kernel and its cold compile is
/// a lie. Match the daemon on the *worktree path* — nothing in its command line
/// says "daemon".
///
/// ```sh
/// cd app && dart run tool/catalog/inspect_spike.dart
/// ```
Future<void> main(List<String> args) async {
  var appPackageRoot = p.dirname(
    p.dirname(p.dirname(p.fromUri(Platform.script))),
  );
  var cache = FlutterCache.fromRunningSdk();
  var tracking = !args.contains('--no-track-widget-creation');

  stdout.writeln('[spike] app $appPackageRoot');
  stdout.writeln('[spike] track-widget-creation: $tracking');

  var watch = Stopwatch()..start();
  var (daemon, ready) = await CompilerDaemonClient.connect(
    dartExecutable: p.join(cache.flutterRoot, 'bin', 'dart'),
    config: DaemonConfig(
      appPackageRoot: appPackageRoot,
      projectRoot: appPackageRoot,
      packageConfig: requirePackageConfig(appPackageRoot),
      flutterSdkRoot: cache.flutterRoot,
      roots: ['tool/catalog/demos'],
      trackWidgetCreation: tracking,
    ),
  );
  stdout.writeln(
    '[spike] daemon ready in ${watch.elapsedMilliseconds}ms '
    '(${ready.reused ? 'attached' : 'started'}), '
    'cold compile ${ready.coldCompile.inMilliseconds}ms',
  );
  if (ready.reused) {
    stdout.writeln(
      '[spike] WARNING: attached to a running daemon. '
      'The cold-compile number is inherited, not measured.',
    );
  }

  // The build directory is keyed by a hash of the config, so it is found
  // rather than constructed.
  for (var kernel
      in Directory(p.join(appPackageRoot, 'build', 'catalog'))
          .listSync()
          .whereType<Directory>()
          .map((d) => File(p.join(d.path, 'out', 'kernel_blob.bin')))
          .where((f) => f.existsSync())) {
    stdout.writeln(
      '[spike] prepared kernel '
      '${(kernel.lengthSync() / 1024 / 1024).toStringAsFixed(2)} MB '
      '(${p.basename(kernel.parent.parent.path)})',
    );
  }

  // Ordered so the measurements are comparable run to run.
  var ids = [for (var entry in ready.entries) entry.id]..sort();
  if (ids.isEmpty) {
    stderr.writeln('[spike] no entries under tool/catalog/demos');
    exit(1);
  }
  stdout.writeln('[spike] ${ids.length} entries');

  _Guest? guest;
  try {
    var first = ids.first;
    var compiled = await daemon.select(first, full: true);
    if (!compiled.ok) {
      stderr.writeln('[spike] $first did not compile:\n${compiled.error}');
      exit(1);
    }
    guest = await _Guest.start(
      hostPath: await daemon.hostPath(),
      assetsDir: ready.assetsDir,
      icuData: ready.icuData,
      workDir: p.join(appPackageRoot, 'build', 'catalog'),
    );
    // A headless host draws nothing until a frame is asked for, and the
    // inspector has no tree before the first build.
    await guest.renderScratchFrame();

    await _reportExtensions(guest);

    // Three demos across the size range, rather than whichever sorted first.
    stdout.writeln('\n=== tree size ===');
    for (var wanted in const ['avatar_tile', 'command_palette', 'dashboard']) {
      var id = ids.firstWhere(
        (id) => id.contains(wanted),
        orElse: () => ids.first,
      );
      if (id != first) {
        var compiled = await daemon.select(id);
        if (!compiled.ok || compiled.dill == null) continue;
        await guest.vmService.reload(compiled.dill!);
        await guest.renderScratchFrame();
      }
      await _reportTrees(guest, id);
    }

    await _reportReloads(daemon, guest, ids);
  } finally {
    await guest?.close();
    await daemon.close();
  }
  exit(0);
}

/// Which `ext.flutter.*` extensions the guest actually registered.
///
/// The SDK source says the inspector is registered inside an `assert`; this is
/// the empirical half of that claim.
Future<void> _reportExtensions(_Guest guest) async {
  var isolate = await guest.vmService.service.getIsolate(
    guest.vmService.isolateId,
  );
  var rpcs = (isolate.extensionRPCs ?? const <String>[])..sort();
  var inspector = rpcs.where((r) => r.startsWith('ext.flutter.inspector.'));

  stdout.writeln('\n=== registered extensions ===');
  stdout.writeln(
    'total ext.flutter.*     ${rpcs.where((r) => r.startsWith('ext.flutter.')).length}',
  );
  stdout.writeln('ext.flutter.inspector.* ${inspector.length}');
  for (var name in inspector) {
    stdout.writeln('  $name');
  }
  for (var wanted in const [
    'ext.flutter.inspector.getRootWidgetTree',
    'ext.flutter.inspector.screenshot',
    'ext.flutter.inspector.getLayoutExplorerNode',
    'ext.flutter.inspector.setFlexFactor',
    'ext.flutter.inspector.trackRebuildDirtyWidgets',
    'ext.flutter.inspector.widgetLocationIdMap',
    'ext.flutter.accessibilityEvaluations',
    'ext.flutter.debugPaint',
    'ext.flutterware.knobs',
  ]) {
    stdout.writeln('${rpcs.contains(wanted) ? 'YES' : 'no '}  $wanted');
  }

  var tracked = await guest.vmService.callExtension(
    'ext.flutter.inspector.isWidgetCreationTracked',
  );
  stdout.writeln('isWidgetCreationTracked -> ${tracked?['result']}');
}

/// What a tree costs, full versus summary.
Future<void> _reportTrees(_Guest guest, String entryId) async {
  stdout.writeln('  ${p.basename(entryId)}');
  for (var (label, summary, details) in const [
    ('full,  lean   ', false, false),
    ('summary,lean  ', true, false),
    ('summary,details', true, true),
  ]) {
    var watch = Stopwatch()..start();
    Map<String, dynamic>? json;
    try {
      json = await guest.vmService.callExtension(
        'ext.flutter.inspector.getRootWidgetTree',
        args: {
          'groupName': 'spike',
          'isSummaryTree': '$summary',
          'withPreviews': 'false',
          'fullDetails': '$details',
        },
      );
    } catch (e) {
      stdout.writeln('  $label: FAILED $e');
      continue;
    }
    var elapsed = watch.elapsedMilliseconds;
    var result = json?['result'];
    if (result == null) {
      stdout.writeln('  $label: no result');
      continue;
    }
    var encoded = jsonEncode(result);
    stdout.writeln(
      '  $label: '
      '${_countNodes(result)} nodes, '
      '${(encoded.length / 1024).toStringAsFixed(1)} KB, '
      '~${(encoded.length / 4).round()} tokens, '
      '${elapsed}ms',
    );
    // How much of the depth is the catalog's own chrome rather than the demo.
    if (!summary) stdout.writeln('  root chain: ${_rootChain(result)}');
    // The payoff of creation tracking is a file:line per node, so look for one
    // rather than trusting the flag.
    if (details) {
      var locations = <String>[];
      _collectLocations(result, locations);
      stdout.writeln(
        '  creationLocation: ${locations.length}/${_countNodes(result)} nodes'
        '${locations.isEmpty ? '' : '\n    e.g. ${locations.take(3).join('\n         ')}'}',
      );
      var dump = Platform.environment['FW_DUMP_TREE'];
      if (dump != null) {
        File(
          dump,
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
        stdout.writeln('  dumped to $dump');
      }
    }
  }
  await guest.vmService.callExtension(
    'ext.flutter.inspector.disposeGroup',
    args: {'objectGroup': 'spike'},
  );
}

void _collectLocations(Object? node, List<String> into) {
  if (node is! Map) return;
  var location = node['creationLocation'];
  if (location is Map) {
    into.add(
      '${node['description']}  '
      '${p.basename('${location['file']}')}:${location['line']}:${location['column']}',
    );
  }
  var children = node['children'];
  if (children is List) {
    for (var child in children) {
      _collectLocations(child, into);
    }
  }
}

int _countNodes(Object? node) {
  if (node is! Map) return 0;
  var total = 1;
  var children = node['children'];
  if (children is List) {
    for (var child in children) {
      total += _countNodes(child);
    }
  }
  return total;
}

/// The types from the root down to the first branch, to show where the demo
/// actually starts.
String _rootChain(Object? node) {
  var names = <String>[];
  var current = node;
  while (current is Map && names.length < 14) {
    names.add('${current['description'] ?? current['type']}');
    var children = current['children'];
    if (children is! List || children.isEmpty) break;
    current = children.first;
  }
  return names.join(' > ');
}

/// Hot reload, which is the felt latency and the number that decides whether
/// creation tracking can be on by default.
Future<void> _reportReloads(
  CompilerDaemonClient daemon,
  _Guest guest,
  List<String> ids,
) async {
  stdout.writeln('\n=== reload (switch entry) ===');
  var samples = <int>[];
  // Round-trips through the whole list twice, so the second lap measures
  // revisits — the case the performance findings quote as ~12ms of compile.
  for (var lap = 0; lap < 2; lap++) {
    for (var id in ids) {
      var watch = Stopwatch()..start();
      var compiled = await daemon.select(id);
      if (!compiled.ok || compiled.dill == null) continue;
      var compile = watch.elapsedMilliseconds;
      await guest.vmService.reload(compiled.dill!);
      var total = watch.elapsedMilliseconds;
      samples.add(total);
      stdout.writeln(
        '  lap$lap ${p.basename(id).padRight(34)} '
        'compile ${compile}ms  reload ${total - compile}ms  total ${total}ms',
      );
    }
  }
  if (samples.isEmpty) return;
  samples.sort();
  stdout.writeln(
    '  n=${samples.length}  min ${samples.first}ms  '
    'median ${samples[samples.length ~/ 2]}ms  max ${samples.last}ms',
  );
}

/// A live embedder guest — the `_GuestSession` dance from `headless_catalog`,
/// reduced to what a spike needs.
class _Guest {
  _Guest._(
    this._process,
    this._connection,
    this._server,
    this.vmService,
    this._workDir,
  );

  final Process _process;
  final Socket _connection;
  final ServerSocket _server;
  final GuestVmService vmService;
  final String _workDir;

  final _reader = ipc.FrameReader();
  final _captures = <String, Completer<void>>{};

  static Future<_Guest> start({
    required String hostPath,
    required String assetsDir,
    required String icuData,
    required String workDir,
    CaptureViewport viewport = CaptureViewport.panel,
  }) async {
    var key = sha1.convert(utf8.encode(workDir)).toString().substring(0, 12);
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'spike-$key.sock'),
    );
    var socket = File(socketPath);
    if (socket.existsSync()) socket.deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );

    var process = await Process.start(hostPath, [
      assetsDir,
      icuData,
      socketPath,
      '${viewport.width}',
      '${viewport.height}',
    ]);
    var vmServiceUri = Completer<String>();
    process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          var match = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
          if (match != null && !vmServiceUri.isCompleted) {
            vmServiceUri.complete(match.group(1));
          }
          if (line.startsWith('FW-ERROR:')) stdout.writeln('  [guest] $line');
        });
    unawaited(process.stderr.drain<void>());

    var connected = await Future.any<Object?>([server.first, process.exitCode]);
    if (connected is! Socket) {
      throw StateError('the guest exited before connecting');
    }

    var guest = _Guest._(
      process,
      connected,
      server,
      await GuestVmService.connect(await vmServiceUri.future),
      workDir,
    );
    connected.listen(guest._onData);
    connected.add(
      ipc.encodeMessage(
        ipc.ResizeMessage(
          width: viewport.width,
          height: viewport.height,
          pixelRatio: viewport.pixelRatio,
        ),
      ),
    );
    return guest;
  }

  void _onData(List<int> chunk) {
    for (var message in _reader.addBytes(chunk)) {
      if (message is ipc.CapturedMessage) {
        _captures.remove(message.path)?.complete();
      } else if (message is ipc.ErrorMessage) {
        for (var pending in _captures.values) {
          if (!pending.isCompleted) {
            pending.completeError(StateError(message.message));
          }
        }
        _captures.clear();
      }
    }
  }

  /// Draws one frame nobody looks at, so the demo has built and the inspector
  /// has a tree to answer with.
  Future<void> renderScratchFrame() async {
    var path = p.join(_workDir, 'spike-scratch.raw');
    File(path).parent.createSync(recursive: true);
    var done = Completer<void>();
    _captures[path] = done;
    _connection.add(ipc.encodeMessage(ipc.CaptureMessage(path)));
    await done.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() async {
    _connection.add(ipc.encodeMessage(const ipc.ShutdownMessage()));
    await vmService.close();
    await _connection.close();
    await _server.close();
    _process.kill();
    await _process.exitCode;
  }
}
