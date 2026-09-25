import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../embedder/embedded_engine.dart';
import 'open_world.dart';

/// A person's guest drawn live in the studio: the process, bridged into a
/// texture the Worlds panel shows and hands the mouse and keyboard to.
///
/// Drawn at the studio's own pixel ratio rather than the device's — a phone
/// on a Retina Mac renders at 2× where the device would at 3× — so the
/// picture is sharp at the size it is shown and nothing is resampled.
class LiveWorldGuest implements WorldGuest {
  LiveWorldGuest({
    required this.appRoot,
    required this.flutterSdkRoot,
    required this.pixelRatio,
  });

  final String appRoot;
  final String flutterSdkRoot;

  /// The studio's, read when the guest starts.
  final double Function() pixelRatio;

  /// What the panel draws. Null until [start].
  EmbeddedEngine? engine;

  /// Who has the keyboard: the phone that was clicked last.
  final focus = FocusNode();

  @override
  Future<void> start(WorldGuestStart start) async {
    var build = (
      hostPath: start.hostPath,
      assetsDir: start.assetsDir,
      icuData: start.icuData,
    );
    var engine = this.engine = EmbeddedEngine(
      appPackageRoot: appRoot,
      flutterSdkRoot: flutterSdkRoot,
      buildGuest: () async => build,
      workingDirectory: start.workingDirectory,
      environment: start.environment,
      platform: start.platform,
      onOutput: start.onOutput,
      name: 'world-${start.person}',
    );
    var device = start.device;
    var ratio = pixelRatio();
    var width = (device.width * ratio).round();
    var height = (device.height * ratio).round();
    await engine.start(width: width, height: height);
    // Not before the guest has announced its surfaces: until then the engine
    // drops what it is asked to send, and the guest keeps the ratio 1 it
    // started with — a phone twice its size, with no safe areas, that every
    // click lands on at double the coordinates.
    await _running(engine);
    if (engine.phase == EmbeddedEnginePhase.error) {
      throw StateError('${engine.errorMessage}');
    }
    engine.resize(
      width,
      height,
      ratio,
      insets:
          EdgeInsets.fromLTRB(
            device.insetLeft,
            device.insetTop,
            device.insetRight,
            device.insetBottom,
          ) *
          ratio,
    );
  }

  @override
  int? get pid => engine?.guestPid;

  @override
  Future<String> get vmService => engine!.vmServiceUri;

  @override
  void sendPlatform(String channel, Uint8List bytes) =>
      engine?.sendPlatform(channel, bytes);

  @override
  Future<void> stop() async {
    engine?.dispose();
    engine = null;
    focus.dispose();
  }

  static Future<void> _running(EmbeddedEngine engine) {
    if (engine.phase != EmbeddedEnginePhase.building) return Future.value();
    var done = Completer<void>();
    void check() {
      if (engine.phase == EmbeddedEnginePhase.building) return;
      engine.removeListener(check);
      done.complete();
    }

    engine.addListener(check);
    return done.future;
  }
}
