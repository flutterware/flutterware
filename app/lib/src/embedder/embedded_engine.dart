import 'guest_surface.dart';
import 'guest_texture.dart';
import 'input_region.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

import '../utils/run_dir.dart';
import '../previews/catalog_picture.dart';
import 'frame_capture.dart';
import 'protocol.dart';

enum EmbeddedEnginePhase { building, running, error }

/// Drives an out-of-process Flutter-engine guest and bridges its rendered
/// frames into a host external texture.
typedef GuestBuild = ({String hostPath, String assetsDir, String icuData});

class EmbeddedEngine extends ChangeNotifier implements GuestSurface {
  EmbeddedEngine({
    required this.appPackageRoot,
    required this.flutterSdkRoot,
    this.buildGuest,
    this.workingDirectory,
    this.environment,
    this.platform,
    this.name = 'gui',
  });

  /// Distinguishes this engine's guest socket from any other's.
  ///
  /// A fixed name meant a second GUI deleted the first one's socket and bound
  /// its own. Pass the daemon's session id: two clients of one daemon are now
  /// an ordinary case — a panel open while an agent screenshots — rather than
  /// something to refuse.
  final String name;

  /// Produces the guest's binary and assets. Defaults to running
  /// `tool/embedder/build_guest.dart`, which compiles the fixed harness scene;
  /// a caller with its own entrypoint and resident compiler supplies its own.
  final Future<GuestBuild> Function()? buildGuest;

  /// Absolute path to the `flutterware_app` package root (the `app/` dir).
  final String appPackageRoot;

  /// Absolute path to the Flutter SDK checkout root.
  final String flutterSdkRoot;

  /// The directory the guest process runs in, or null to inherit this one's.
  ///
  /// A preview reading a fixture at a relative path resolves it here, so the
  /// catalog passes the project's package root: that is where `flutter test`
  /// and the tester lane already run, and the same demo has to open the same
  /// file in both. Inherited, the guest would run wherever the GUI does — for
  /// a built binary that is the `app/` directory, and nothing of the project
  /// is there.
  final String? workingDirectory;

  /// Added to the guest process's environment — how a world hands one
  /// person's app its knobs, its home and its locales without a build.
  final Map<String, String>? environment;

  /// Answers the platform messages a guest forwards — one started with
  /// `FW_FORWARD_PLATFORM=1` in [environment] — standing in for the platform
  /// a plugin's native half would have run on. Null bytes are "no
  /// implementation". Unset, every forwarded message is answered that way.
  final Future<Uint8List?> Function(String channel, Uint8List bytes)? platform;

  /// Sends a message into the app on [channel] — an event channel's event, a
  /// lifecycle change — with no reply.
  void sendPlatform(String channel, Uint8List bytes) =>
      _send(PlatformSendMessage(channel, bytes));

  /// The guest process, once it has started — what a handle announcing it to
  /// Run names as its launcher.
  int? get guestPid => _guest?.pid;

  static const _channel = MethodChannel('flutterware/embedder_texture');

  /// Every engine currently backing a texture, by the id the host gave it.
  ///
  /// Static, and worth defending. A window capture finds its guests by
  /// walking the render tree for `TextureBox`, which yields texture ids and
  /// nothing else — the widget that built one is long out of reach by then.
  /// Something has to turn an id back into the engine that owns it, and a
  /// texture id is already a process-wide identifier issued by the platform
  /// side, so a process-wide map is the same scope rather than a wider one.
  static final _byTextureId = <int, EmbeddedEngine>{};

  /// The engine behind [textureId], or null when nothing here owns it.
  static EmbeddedEngine? withTexture(int textureId) => _byTextureId[textureId];

  @override
  EmbeddedEnginePhase phase = EmbeddedEnginePhase.building;
  String? errorMessage;
  int? textureId;
  int textureWidth = 0;
  int textureHeight = 0;

  /// Whether the guest has delivered a frame for the surfaces the texture
  /// holds *now*.
  ///
  /// A texture exists from the moment the ring is mapped, which is well before
  /// anything has been drawn into it — and an unpainted ring is black. So this
  /// is the question anything photographing the panel has to ask, and
  /// `EmbeddedEnginePhase.running` is not it: that says the plumbing is up.
  ///
  /// Per generation rather than ever, because a resize allocates a new ring and
  /// the old frame does not come with it. It goes false the moment the guest
  /// announces the new surfaces and true again on the first frame composited
  /// against them.
  @override
  bool get hasPainted => _paintedGeneration == _currentGeneration;

  /// The generation of the last frame the guest announced. Starts apart from
  /// [_currentGeneration] so that "nothing has painted" is the initial state
  /// rather than a coincidence of two -1s.
  int _paintedGeneration = -2;

  ServerSocket? _server;
  Socket? _conn;
  Process? _guest;
  final FrameReader _reader = FrameReader();
  // Socket messages must be handled strictly in arrival order; each handler is
  // chained after the previous one completes rather than run concurrently.
  Future<void> _handleChain = Future.value();
  int _currentGeneration = -1;
  bool _disposed = false;
  final Completer<String> _vmServiceUri = Completer<String>();

  /// The guest's VM-service URI, which it prints on stdout at startup. Needed
  /// to hot-reload the live guest.
  Future<String> get vmServiceUri => _vmServiceUri.future;

  /// Photographs the guest — the same exchange the headless pipeline uses.
  ///
  /// Worth having on the *live* engine specifically: this frame is the demo as
  /// the person driving it left it, which nothing rendered fresh can reproduce.
  /// It is also the only way to get one from here, since the texture belongs to
  /// the compositor rather than to Flutter and `toImage` cannot read it.
  late final _capture = FrameCapture(
    send: (message) async {
      var conn = _conn;
      if (conn == null || phase != EmbeddedEnginePhase.running) {
        throw StateError('the guest is not running');
      }
      conn.add(encodeMessage(message));
      await conn.flush();
    },
    // Per engine, so two panels capturing at once do not write one path.
    workDir: p.join(flutterwareRunDir(), 'cap-$name'),
  );

  String get _dartExecutable => p.join(flutterSdkRoot, 'bin', 'dart');

  /// Builds and launches the guest. Call once.
  Future<void> start({int width = 800, int height = 600}) async {
    try {
      var build = await (buildGuest ?? _runBuild)();
      if (_disposed) return;

      // Not under the build directory: the CLI installs the GUI at
      // `~/.flutterware/<sha1>/app/`, and a socket below that overflows the
      // 104-byte cap on a unix socket path.
      var socketPath = checkSocketPath(
        p.join(flutterwareRunDir(), 'g-$name.sock'),
      );
      var socketFile = File(socketPath);
      if (socketFile.existsSync()) socketFile.deleteSync();
      _server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );

      _guest = await Process.start(
        build.hostPath,
        [build.assetsDir, build.icuData, socketPath, '$width', '$height'],
        workingDirectory: workingDirectory,
        environment: environment,
        mode: ProcessStartMode.normal,
      );
      _guest!.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
            debugPrint('[guest] $line');
            _rememberGuestOutput(line);
            var match = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
            if (match != null && !_vmServiceUri.isCompleted) {
              _vmServiceUri.complete(match.group(1));
            }
          });
      _guest!.stderr.transform(const SystemEncoding().decoder).listen((line) {
        debugPrint('[guest:err] $line');
        _rememberGuestOutput(line);
      });

      // Accept the guest's connection, but don't hang forever if the guest
      // dies before connecting — race the accept against the process exit.
      Socket? connected;
      var accepted = _server!.first.then((c) => connected = c);
      await Future.any([accepted, _guest!.exitCode]);
      if (connected == null) {
        throw StateError('the embedder guest exited before connecting');
      }
      _conn = connected;
      _conn!.listen(_onSocketData, onDone: _onSocketClosed);
      // Every failure path completes the URI through [_fail] — except a guest
      // that runs happily without ever printing the line the scrape above
      // expects. Bound that one too, or `await vmServiceUri` waits forever
      // and a panel sits on "building".
      _uriDeadline = Timer(const Duration(seconds: 30), () {
        if (_vmServiceUri.isCompleted) return;
        // Not [_fail]: the engine may be rendering fine — only inspection is
        // lost — and a consumer that never asks for the VM service should not
        // see an error for it. The pre-attached listener keeps the error off
        // the zone for exactly that consumer.
        unawaited(_vmServiceUri.future.catchError((_) => ''));
        _vmServiceUri.completeError(
          StateError('the guest connected but never announced its VM service'),
        );
      });
    } catch (e) {
      _fail('$e');
    }
  }

  Timer? _uriDeadline;

  Future<GuestBuild> _runBuild() async {
    var result = await Process.run(_dartExecutable, [
      'run',
      p.join('tool', 'embedder', 'build_guest.dart'),
    ], workingDirectory: appPackageRoot);
    if (result.exitCode != 0) {
      throw StateError('build_guest.dart failed:\n${result.stderr}');
    }
    String? extract(String key) {
      for (var line in (result.stdout as String).split('\n')) {
        if (line.startsWith('$key=')) return line.substring(key.length + 1);
      }
      return null;
    }

    var hostPath = extract('HOST_PATH');
    var assetsDir = extract('ASSETS_DIR');
    var icuData = extract('ICU_DATA');
    if (hostPath == null || assetsDir == null || icuData == null) {
      throw StateError('build_guest.dart did not print the expected paths');
    }
    return (hostPath: hostPath, assetsDir: assetsDir, icuData: icuData);
  }

  void _onSocketData(Uint8List chunk) {
    for (var message in _reader.addBytes(chunk)) {
      _handleChain = _handleChain
          .then((_) => _handle(message))
          .catchError((Object e) => _fail('$e'));
    }
  }

  /// One message from the guest, as the socket would have delivered it.
  ///
  /// The seam a test drives [hasPainted] through: the states that matter — a
  /// ring mapped but never drawn into, a resize that drops the picture — are
  /// two protocol messages apart and need neither a guest process nor a GPU.
  @visibleForTesting
  Future<void> handleMessage(EmbedderMessage message) => _handle(message);

  Future<void> _handle(EmbedderMessage message) async {
    switch (message) {
      case ReadyMessage():
        break;
      case SurfacesAllocatedMessage():
        await _onSurfaces(message);
      case FrameReadyMessage():
        // Discard frames composited against superseded surfaces; their ring
        // slots no longer match the texture the plugin currently holds.
        if (textureId != null && message.generation == _currentGeneration) {
          await _channel.invokeMethod('markFrameAvailable', {
            'textureId': textureId,
            'ringIndex': message.ringIndex,
          });
          // Only the first frame of a generation is news — the rest are the
          // guest animating, and notifying on each of those would rebuild
          // every listener at the guest's frame rate.
          if (!hasPainted) {
            _paintedGeneration = message.generation;
            if (!_disposed) notifyListeners();
          }
        }
      case ErrorMessage():
        // Before failing the engine: a guest that has errored will not finish
        // writing a frame, and a caller left on the capture timeout learns
        // thirty seconds later, in less detail, what this already says.
        _capture.failAll(StateError(message.message));
        _fail(message.message);
      case CapturedMessage():
        _capture.acknowledge(message);
      case GuestPlatformMessage(:var id, :var channel, :var bytes):
        // Not awaited: a handler that takes its time must not hold up the
        // frames queued behind it.
        unawaited(_answerPlatform(id, channel, bytes));
      case ResizeMessage():
      case PointerEventMessage():
      case KeyEventMessage():
      case ShutdownMessage():
      case CaptureMessage():
      case PlatformReplyMessage():
      case PlatformSendMessage():
        break; // GUI-to-guest messages; never received here.
    }
  }

  Future<void> _answerPlatform(int id, String channel, Uint8List bytes) async {
    Uint8List? reply;
    try {
      reply = await platform?.call(channel, bytes);
    } catch (e) {
      debugPrint('[guest platform] $channel: $e');
    }
    if (id != 0) _send(PlatformReplyMessage(id, reply ?? Uint8List(0)));
  }

  Future<void> _onSurfaces(SurfacesAllocatedMessage message) async {
    textureWidth = message.width;
    textureHeight = message.height;
    if (textureId == null) {
      textureId = await _channel.invokeMethod<int>(
        'createTexture',
        _surfaceArguments(message),
      );
      if (textureId case var id?) _byTextureId[id] = this;
      phase = EmbeddedEnginePhase.running;
    } else if (message.generation != _currentGeneration) {
      var mapped = await _channel.invokeMethod<bool>('updateSurfaces', {
        'textureId': textureId,
        ..._surfaceArguments(message),
      });
      // A refused ring is not an error the panel can act on — the previous one
      // is still mapped, so the guest's picture freezes at the old size until
      // the next generation lands, and it does land. But it is invisible from
      // here otherwise, and a panel that has quietly stopped following a drag
      // is worth a line in the log rather than a puzzle.
      if (mapped == false) {
        debugPrint(
          '[guest] the platform could not map ring generation '
          '${message.generation} (${message.width}x${message.height}); '
          'holding the previous frame',
        );
      }
    }
    _currentGeneration = message.generation;
    notifyListeners();
  }

  /// What the platform side needs to resolve a ring.
  ///
  /// The geometry rides along with the handles because a shared-memory name
  /// does not carry its own: an `IOSurface` knows how big it is and a mapping
  /// has to be told. Sending it on both hosts rather than only where it is read
  /// keeps this one message rather than two.
  Map<String, Object?> _surfaceArguments(SurfacesAllocatedMessage message) => {
    'surfaces': message.surfaces,
    'width': message.width,
    'height': message.height,
    'rowBytes': message.rowBytes,
  };

  void _onSocketClosed() {
    if (phase != EmbeddedEnginePhase.error && !_disposed) {
      // With what it last said. "the embedder guest exited" on its own names
      // the symptom and nothing else, and the guest is the only thing that
      // knows why it went.
      var tail = _guestLog.isEmpty
          ? ' (it printed nothing)'
          : ':\n${_guestLog.join('\n')}';
      _fail('the embedder guest exited$tail');
    }
  }

  /// The guest's last few lines, kept for the message above.
  final _guestLog = <String>[];

  /// What the guest has printed lately, for a caller diagnosing one that came
  /// up wrong. The same lines [_onSocketClosed] quotes, and for the same
  /// reason: the guest is the only thing that knows why it is not working.
  String get guestOutput => _guestLog.join('\n');

  void _rememberGuestOutput(String line) {
    _guestLog.add(line);
    if (_guestLog.length > 20) _guestLog.removeAt(0);
  }

  void _fail(String message) {
    if (!_vmServiceUri.isCompleted) {
      _vmServiceUri.completeError(StateError(message));
    }
    // Notifying after dispose throws, and every socket error routes here —
    // including the ones a teardown causes.
    if (_disposed) return;
    errorMessage = message;
    phase = EmbeddedEnginePhase.error;
    notifyListeners();
  }

  void _send(EmbedderMessage message) {
    var conn = _conn;
    if (conn != null && phase == EmbeddedEnginePhase.running) {
      conn.add(encodeMessage(message));
    }
  }

  /// The ratio the guest is rendering at — the last [resize]'s, 1 before any.
  ///
  /// This is the number that turns a node's logical rect into pixels of the
  /// captured frame, and it is **not** always a staged device's: with no device
  /// the guest renders at the panel's ratio, 2 on any retina display. The crop
  /// used to guess from the device and fall back to 1, which cut the wrong
  /// quarter of every capture in the default staging.
  @override
  double get pixelRatio => _pixelRatio;
  var _pixelRatio = 1.0;

  /// Forwards a new physical-pixel size to the guest.
  @override
  void resize(
    int width,
    int height,
    double pixelRatio, {
    EdgeInsets insets = EdgeInsets.zero,
  }) {
    _pixelRatio = pixelRatio;
    _send(
      ResizeMessage(
        width: width,
        height: height,
        pixelRatio: pixelRatio,
        insetTop: insets.top,
        insetRight: insets.right,
        insetBottom: insets.bottom,
        insetLeft: insets.left,
      ),
    );
  }

  void sendPointer({
    required PointerPhase phaseKind,
    required double x,
    required double y,
    int buttons = 0,
    double scrollDeltaX = 0,
    double scrollDeltaY = 0,
    double panX = 0,
    double panY = 0,
    double scale = 1,
    double rotation = 0,
    bool touch = false,
  }) {
    _send(
      PointerEventMessage(
        phase: phaseKind,
        x: x,
        y: y,
        buttons: buttons,
        scrollDeltaX: scrollDeltaX,
        scrollDeltaY: scrollDeltaY,
        timestampMicros: DateTime.now().microsecondsSinceEpoch,
        panX: panX,
        panY: panY,
        scale: scale,
        rotation: rotation,
        touch: touch,
      ),
    );
  }

  void sendKey({
    required KeyEventKind kind,
    required int physicalKey,
    required int logicalKey,
    String? character,
  }) {
    _send(
      KeyEventMessage(
        kind: kind,
        physicalKey: physicalKey,
        logicalKey: logicalKey,
        modifiers: 0,
        timestampMicros: DateTime.now().microsecondsSinceEpoch,
        character: character,
      ),
    );
  }

  /// The frame the guest draws next, as PNG bytes.
  ///
  /// PNG rather than an image, because both callers — the clipboard and the
  /// save dialog — want encoded bytes, and the one that does not is welcome to
  /// decode them.
  ///
  /// Pass [crop] to cut it to a node's box, in the guest's logical coordinates:
  /// the space [InspectLayout] reports, which is why a node's rect from the
  /// inspect panel crops its own picture with no transform.
  @override
  Future<Uint8List> capturePng({
    InspectLayout? crop,
    List<InspectNode> annotate = const [],
    double pixelRatio = 1,
  }) async => img.encodePng(
    framePicture(
      await captureImage(),
      framing: PictureFraming(crop: crop, boxes: annotate),
      pixelRatio: pixelRatio,
    ),
  );

  /// The same frame, undecoded and unframed.
  ///
  /// For the one caller that is going to draw with it rather than write it out:
  /// a window capture pastes this into the hole the guest's texture leaves in
  /// the host's raster, and encoding a PNG just to decode it again would be the
  /// only step in that path that did nothing.
  Future<img.Image> captureImage() => _capture.capture();

  @override
  void cancelPointer() =>
      sendPointer(phaseKind: PointerPhase.cancel, x: 0, y: 0);

  @override
  Widget picture() => switch (textureId) {
    var id? => GuestTexture(textureId: id),
    null => const SizedBox.expand(),
  };

  @override
  Widget input({
    required Widget child,
    required FocusNode focusNode,
    required bool touch,
    bool Function(KeyEvent event)? shouldIgnoreKey,
    bool Function(PointerEvent event)? shouldIgnorePointer,
  }) => EmbedderInputRegion(
    engine: this,
    focusNode: focusNode,
    touch: touch,
    shouldIgnoreKey: shouldIgnoreKey,
    shouldIgnorePointer: shouldIgnorePointer,
    child: child,
  );

  @override
  void dispose() {
    _disposed = true;
    _uriDeadline?.cancel();
    // Nothing outstanding survives the guest, and a caller waiting on the
    // 30-second timeout would otherwise outlive the panel it belongs to.
    _capture.failAll(StateError('the panel was closed'));
    if (_conn != null && phase == EmbeddedEnginePhase.running) {
      _conn!.add(encodeMessage(const ShutdownMessage()));
    }
    if (textureId case var id?) {
      _byTextureId.remove(id);
      unawaited(
        _channel
            .invokeMethod('disposeTexture', {'textureId': id})
            .catchError((_) {}),
      );
    }
    unawaited(_conn?.close());
    unawaited(_server?.close());
    _guest?.kill();
    // Frames delete themselves as they are read; this picks up the scratch
    // directory itself, which would otherwise accumulate one per session id.
    // The run-dir sweep ages out what a crash skips.
    try {
      Directory(p.join(flutterwareRunDir(), 'cap-$name'))
          .deleteSync(recursive: true);
    } on FileSystemException {
      // Housekeeping only.
    }
    super.dispose();
  }
}
