import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/devices.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/keyboard.dart';
import 'package:flutterware_app/src/embedder/guest_vm_service.dart';
import 'package:flutterware_app/src/embedder/protocol.dart' as wire;
import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/debug_flags.dart';
import 'package:flutterware_app/src/previews/inspect_client.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// Drives a real catalog guest and checks that **the keyboard follows the
/// app**, rather than following whatever the host last said.
///
/// Not the measurement probe — that one is `tool/device_probe.dart` at the
/// repo root, a Flutter app that runs on a simulator to find out how tall a
/// real keyboard is. This one takes those numbers as given and asks whether
/// the fake one behaves.
///
/// The transcript below is the contract, and every line of it is a thing a
/// screenshot cannot see:
///
/// - a demo that autofocuses a field is already asking for a keyboard before
///   anything has been touched;
/// - a **touch** outside the field on a phone-staged guest does not take it
///   away, because that is the phone rule and the whole reason PR 1 staged the
///   platform;
/// - the dismiss key does — and it does it by making the *app* let go, which
///   is why `requested` is what this asserts rather than `height`;
/// - a forced mode overrules the app without lying about what the app asked
///   for;
/// - a stage with no measurement raises nothing, however hard it is asked.
///
/// Written down because this repo has learned it the expensive way: a smoke
/// test that proves the guest survived a message proves nothing about arrival,
/// which is how keyboard *input* looked implemented for months while every key
/// sat in a framework queue.
///
/// Needs the previews in `fixtures/probe_app/demo/input.dart`, whose first field
/// autofocuses — see `staging_probe.dart`, which shares this harness.
///
/// Usage: `dart run tool/embedder/fake_keyboard_probe.dart [projectRoot]`
Future<void> main(List<String> args) async {
  var packageRoot = Directory.current.path;
  var projectRoot = args.isNotEmpty
      ? args[0]
      : p.normalize(p.join(packageRoot, '..', 'fixtures', 'probe_app'));
  var flutterSdkRoot = p.normalize(
    p.join(p.dirname(Platform.resolvedExecutable), '..', '..', '..', '..'),
  );

  var (daemon, ready) = await CompilerDaemonClient.connect(
    dartExecutable: Platform.resolvedExecutable,
    config: DaemonConfig.forPackage(
      appToolDirectory: packageRoot,
      packageRoot: projectRoot,
      flutterSdkRoot: flutterSdkRoot,
      roots: ['demo'],
    ),
  );

  var failures = <String>[];
  _Guest? guest;
  try {
    var entry = ready.entries
        .firstWhere((e) => e.id.endsWith('#textFields'))
        .id;
    var compiled = await daemon.select(entry, full: true);
    if (!compiled.ok) {
      throw StateError('$entry did not compile: ${compiled.error}');
    }
    guest = await _Guest.start(await daemon.hostPath(), ready);

    void check(String what, bool ok) {
      stdout.writeln('[probe] ${ok ? 'ok  ' : 'FAIL'} $what');
      if (!ok) failures.add(what);
    }

    // An iPhone 16, staged and measured, with the keyboard left to the app.
    await guest.stage(DevicePlatform.ios);
    var state = await guest.keyboard(mode: KeyboardMode.auto, height: 336);
    check('autofocus asks for a keyboard', state.requested);
    check(
      'and the screen loses exactly the measured height',
      state.height == 336,
    );

    // The phone rule. A mouse click here would take the focus — that is what
    // `staging_probe.dart` asserts from the other side — and a finger does not.
    guest.tap(450, 650, touch: true);
    await guest.settle();
    state = await guest.read();
    check('a touch outside the field leaves it up', state.up);

    // The one gesture that takes a keyboard away from outside the app.
    state = await guest.dismiss();
    check('the dismiss key makes the app let go', !state.requested);
    check('so the keyboard comes down', !state.up);

    // Forced, with nothing focused — the layout question, asked without
    // hunting for a field.
    state = await guest.keyboard(mode: KeyboardMode.up, height: 336);
    check('forced up raises it with nothing focused', state.height == 336);
    check('and it still says the app asked for nothing', !state.requested);

    // A stage with no measurement: `Fit`, and every desktop window.
    state = await guest.keyboard(mode: KeyboardMode.up, height: 0);
    check('a stage with no measurement raises nothing', state.height == 0);
  } finally {
    await guest?.close();
    await daemon.close();
  }

  if (failures.isEmpty) {
    stdout.writeln('[probe] PASS: the keyboard follows the app');
    exit(0);
  }
  for (var failure in failures) {
    stdout.writeln('[probe] FAIL: $failure');
  }
  exit(1);
}

class _Guest {
  _Guest._(this._process, this._connection, this._server, this._vm)
    : _inspect = InspectClient(_vm, patience: InspectPatience.headless);

  final Process _process;
  final Socket _connection;
  final ServerSocket _server;
  final GuestVmService _vm;
  final InspectClient _inspect;

  static Future<_Guest> start(String hostPath, DaemonReady ready) async {
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'keyboard-${ready.sessionId}.sock'),
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
      '393',
      '852',
    ]);
    var vmUri = Completer<String>();
    process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!line.startsWith('FW-PROBE')) stdout.writeln('[guest] $line');
          var match = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
          if (match != null && !vmUri.isCompleted) {
            vmUri.complete(match.group(1));
          }
        });
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((line) => stdout.write('[guest:err] $line'));

    // ignore: close_sinks
    var connection = await server.first;
    // **Drained, even though this probe reads nothing.** The host writes a
    // frame-ready message per rendered frame; an unread socket fills, its
    // `send` blocks the raster thread, and the guest simply stops producing
    // frames — which looks exactly like a demo that will not rebuild.
    connection.listen((_) {});
    var guest = _Guest._(
      process,
      connection,
      server,
      await GuestVmService.connect(await vmUri.future),
    );
    await guest.settle();
    return guest;
  }

  Future<void> settle() => Future.delayed(const Duration(seconds: 2));

  Future<void> stage(DevicePlatform? platform) async {
    await stageGuestPlatform(_vm, platform);
    await settle();
  }

  /// Through [InspectClient], which is the *panel's own* call — a probe that
  /// spelled the extension itself would go on passing after the panel stopped
  /// using it, which is exactly what happened to `staging_probe.dart`.
  Future<KeyboardState> keyboard({
    required KeyboardMode mode,
    required double height,
  }) async {
    var state = await _inspect.setKeyboard(mode: mode, height: height);
    return state ?? (throw StateError('the guest has no keyboard extension'));
  }

  Future<KeyboardState> read() async =>
      await _inspect.keyboard() ??
      (throw StateError('the guest has no keyboard extension'));

  Future<KeyboardState> dismiss() async {
    var state = await _inspect.dismissKeyboard();
    return state ?? (throw StateError('the guest has no keyboard extension'));
  }

  void tap(double x, double y, {required bool touch}) {
    var now = DateTime.now().microsecondsSinceEpoch;
    for (var phase in [
      if (touch) wire.PointerPhase.add,
      wire.PointerPhase.down,
      wire.PointerPhase.up,
      if (touch) wire.PointerPhase.remove,
    ]) {
      _connection.add(
        wire.encodeMessage(
          wire.PointerEventMessage(
            phase: phase,
            x: x,
            y: y,
            buttons: phase == wire.PointerPhase.down ? 1 : 0,
            scrollDeltaX: 0,
            scrollDeltaY: 0,
            timestampMicros: now,
            touch: touch,
          ),
        ),
      );
    }
  }

  Future<void> close() async {
    _connection.add(wire.encodeMessage(const wire.ShutdownMessage()));
    await _connection.flush();
    _process.kill();
    await _vm.close();
    await _server.close();
  }
}
