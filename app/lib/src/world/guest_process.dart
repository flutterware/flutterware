import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../embedder/protocol.dart';
import '../embedder/raw_frame.dart';
import '../run/handle.dart';
import '../utils/run_dir.dart';
import '../utils/run_git.dart';
import 'app_guest.dart';

/// One person's app in an embedded guest with nobody looking at it: the
/// process, its control socket, and nothing drawn anywhere — for a tool or a
/// probe. The studio shows a guest through `EmbeddedEngine` instead, which
/// bridges the same socket into a texture.
///
/// [send] is the studio's half of the socket, so a probe that sends pointer and
/// key messages exercises exactly the path a human's input takes.
class GuestProcess {
  GuestProcess._(this.person, this.process, this._socket);

  final String person;
  final Process process;
  final Socket _socket;

  /// The guest's VM service, once it has printed it.
  final vmService = Completer<String>();

  /// When the guest presented its first frame.
  late final DateTime drewAt;

  final _captured = <String, Completer<void>>{};
  final _output = StreamController<String>.broadcast();
  RunHandle? _handle;

  /// Every line the guest printed, as it prints it — its `print`, the engine's
  /// log, and the host's `[platform]` notes.
  Stream<String> get output => _output.stream;

  /// Spawns [person]'s guest over [build]'s kernel and answers once it has
  /// drawn. The home directory is emptied first: a world creates what it
  /// needs every time it opens.
  static Future<GuestProcess> start({
    required AppGuestBuild build,
    required String hostPath,
    required String person,
    required Map<String, Object?> knobs,
    (int, int, double) size = (1179, 2556, 3),
    (double, double, double, double) insets = (0, 0, 0, 0),
    String locales = 'en-US',
  }) async {
    var home = Directory(build.homeOf(person));
    if (home.existsSync()) home.deleteSync(recursive: true);
    home.createSync(recursive: true);
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'world-$pid-$person.sock'),
    );
    if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    var (width, height, ratio) = size;
    var process = await Process.start(
      hostPath,
      [build.assetsDir, build.cache.icuData, socketPath, '$width', '$height'],
      environment: guestEnvironment(
        home: home.path,
        knobs: knobs,
        locales: locales,
      ),
      workingDirectory: build.package,
    );
    // Kept by the guest and closed by [shutdown].
    // ignore: close_sinks
    var socket = await server.first;
    await server.close();
    var guest = GuestProcess._(person, process, socket);
    guest.send(
      ResizeMessage(
        width: width,
        height: height,
        pixelRatio: ratio,
        insetTop: insets.$1 * ratio,
        insetRight: insets.$2 * ratio,
        insetBottom: insets.$3 * ratio,
        insetLeft: insets.$4 * ratio,
      ),
    );

    var drew = Completer<void>();
    var reader = FrameReader();
    socket.listen((chunk) {
      for (var message in reader.addBytes(chunk)) {
        switch (message) {
          case FrameReadyMessage() when !drew.isCompleted:
            guest.drewAt = DateTime.now();
            drew.complete();
          case CapturedMessage(:var path):
            guest._captured.remove(path)?.complete();
          case ErrorMessage(:var message):
            guest._output.add('guest error: $message');
          default:
        }
      }
    });
    for (var stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        guest._output.add(line);
        var uri = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
        if (uri != null && !guest.vmService.isCompleted) {
          guest.vmService.complete(uri.group(1));
        }
      });
    }
    await drew.future.timeout(const Duration(minutes: 1));
    return guest;
  }

  /// Sends one message down the control socket, as the studio would.
  void send(EmbedderMessage message) => _socket.add(encodeMessage(message));

  Future<void> capturePng(String png) async {
    var raw = '$png.raw';
    var done = _captured[raw] = Completer<void>();
    send(CaptureMessage(raw));
    await done.future.timeout(const Duration(seconds: 10));
    File(png).writeAsBytesSync(
      img.encodePng(decodeRawFrame(File(raw).readAsBytesSync())),
    );
    File(raw).deleteSync();
  }

  /// The physical footprint and resident size, as `footprint` and `ps` say.
  Future<String> memory() async {
    var footprint = await Process.run('footprint', ['${process.pid}']);
    var line = LineSplitter.split('${footprint.stdout}')
        .firstWhere((l) => l.contains('Footprint:'), orElse: () => '?');
    var rss = await Process.run('ps', ['-o', 'rss=', '-p', '${process.pid}']);
    var mb = (int.tryParse('${rss.stdout}'.trim()) ?? 0) ~/ 1024;
    return '${line.trim()}, $mb MB resident';
  }

  /// Announces this guest to Run — see [announceGuest].
  Future<RunHandle> announce({
    required String packageRoot,
    required String entrypoint,
    String? package,
  }) async => _handle = await announceGuest(
    person: person,
    pid: process.pid,
    vmService: await vmService.future,
    packageRoot: packageRoot,
    entrypoint: entrypoint,
    package: package,
    startedAt: drewAt,
  );

  Future<void> shutdown() async {
    _handle?.delete();
    send(const ShutdownMessage());
    await _socket.flush();
    await _socket.close();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await _output.close();
  }
}

/// Announces a guest to Run as an app on the device `studio-<person>`, so
/// `act` and `observe` reach inside it like any app Run launched — which only
/// needs its VM service, and the guest carries Run's drive extensions. Reload
/// and restart stay Run's to refuse: they belong to a `flutter run`, and a
/// guest has none. Delete the handle when the guest goes.
Future<RunHandle> announceGuest({
  required String person,
  required int pid,
  required String vmService,
  required String packageRoot,
  required String entrypoint,
  String? package,
  DateTime? startedAt,
}) async {
  var worktree = await _worktreeOf(packageRoot);
  return RunHandle(
    worktree: worktree.$1,
    worktreeName: worktree.$2,
    device: 'studio-${person.toLowerCase()}',
    deviceName: 'Studio · $person',
    entrypoint: entrypoint,
    entrypointName: person,
    package: package,
    launcherPid: pid,
    // As Run stores one: the websocket, where the guest prints the page.
    vmService: '${vmService.replaceFirst('http://', 'ws://')}ws',
    startedAt: startedAt ?? DateTime.now(),
  ).publish(flutterwareRunDir());
}

/// The worktree a handle belongs to, as Run names it: its path, and `~` for
/// the main checkout or its git name for any other.
Future<(String, String)> _worktreeOf(String directory) async {
  var top = await runGit([
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: directory);
  var path = '${top.stdout}'.trim();
  // A directory in the main checkout, a file in a linked worktree.
  var dotGit = File(p.join(path, '.git'));
  if (!dotGit.existsSync()) return (path, '~');
  // `gitdir: <common>/worktrees/<name>`
  var gitdir = dotGit.readAsStringSync().trim().replaceFirst('gitdir: ', '');
  return (path, p.basename(gitdir));
}
