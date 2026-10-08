import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

// The knob types, not the umbrella `ui_catalog.dart`: that one exports the
// demo annotations, which reach `package:flutter/widgets.dart` and would make
// `fw` unlinkable. `knob.dart` is plain Dart by design and says so.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/error.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/log.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/axis.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';

import '../embedder/frame_capture.dart';
import '../embedder/protocol.dart';
import 'catalog_picture.dart';
import 'catalog_render.dart';
import 'catalog_values.dart';
import 'debug_flags.dart';
import 'devices.dart';
import 'catalog_entry.dart';
import 'inspect_client.dart';
import '../embedder/guest_vm_service.dart';
import '../utils/run_dir.dart';
import 'compiler_daemon_client.dart';
import 'protocol.dart';

/// The catalog pipeline with no GUI involved: render an entry, ask what builds,
/// ask what knobs an entry declares.
///
/// **The embedder backend of [CatalogRenderer]** — a real engine drawing a real
/// frame, which is what the panel shows and therefore what a picture meant to
/// agree with the panel comes from. The same pipeline the GUI drives, invoked
/// by whoever asks — a button, `fw`, or an agent. Nothing here touches Flutter,
/// so it runs anywhere the daemon does.
///
/// The guest is spawned with `--capture-raw`, which writes the composited frame
/// the user would have seen rather than re-rasterising it.
class HeadlessCatalog extends CatalogRenderer {
  HeadlessCatalog({required this.dartExecutable, required this.config});

  /// A real Dart VM — the Flutter SDK's `dart`, never the running executable
  /// when that is a Flutter app.
  final String dartExecutable;

  final DaemonConfig config;

  /// Connects, compiles [entryId], launches one guest and hands it to [body].
  ///
  /// Everything that needs a *running* entry goes through here — a capture with
  /// knobs turned, and reading what knobs there are — so the daemon handshake,
  /// the entry check and the teardown exist once.
  Future<T> _withGuest<T>(
    Future<T> Function(_GuestSession guest) body, {
    required String entryId,
    required CaptureViewport viewport,
  }) async {
    var (daemon, ready) = await CompilerDaemonClient.connect(
      dartExecutable: dartExecutable,
      config: config,
    );
    _GuestSession? guest;
    try {
      // The quarantine counts as known, and the difference matters to whoever
      // reads the error: an entry that does not compile exists, and selecting
      // it is how the daemon retries it — so letting it through produces the
      // compiler's own diagnostics below, where refusing here produced "no such
      // entry" for a file the caller is looking at.
      var known = {
        for (var entry in ready.entries) entry.id,
        for (var broken in ready.quarantined) broken.entry.id,
      };
      if (!known.contains(entryId)) {
        throw ArgumentError.value(
          entryId,
          'entryId',
          'no such entry. Known ids: ${(known.toList()..sort()).join(', ')}',
        );
      }
      // A whole kernel, not a delta: the guest loads it from disk at launch.
      var compiled = await daemon.select(entryId, full: true);
      if (!compiled.ok) {
        throw StateError('$entryId did not compile:\n${compiled.error}');
      }
      guest = await _GuestSession.start(
        hostPath: await daemon.hostPath(),
        assetsDir: ready.assetsDir,
        icuData: ready.icuData,
        name: ready.sessionId,
        viewport: viewport,
        workingDirectory: config.projectRoot,
      );
      return await body(guest);
    } finally {
      await guest?.close();
      await daemon.close();
    }
  }

  /// Which entries the compiler can actually build, and why the rest cannot.
  ///
  /// Needs no guest: the daemon compiles every wrapper into one program while
  /// it prepares, and quarantines the ones that fail. So the answer is already
  /// in the handshake, and this is one connection rather than one compile per
  /// entry.
  ///
  /// The scan cannot answer this. It parses and finds an entry; whether the
  /// entry *compiles* is a fact only the compiler holds, which is why nothing
  /// but the panel could ask before now.
  Future<CatalogCheck> check() async {
    var (daemon, ready) = await CompilerDaemonClient.connect(
      dartExecutable: dartExecutable,
      config: config,
    );
    try {
      return CatalogCheck(
        servable: ready.entries,
        quarantined: ready.quarantined,
      );
    } finally {
      await daemon.close();
    }
  }

  /// The knobs [entryId] declares, read from a live guest.
  ///
  /// A knob is a runtime fact — a demo declares one by *asking* for it while it
  /// builds — so no amount of parsing finds them. The guest registers
  /// `ext.flutterware.knobs` and answers with what its last build
  /// declared.
  ///
  /// Empty when the entry declares none, or when the guest is old enough not to
  /// register the extension. That is an answer, not a failure.
  Future<KnobReport> knobs({
    required String entryId,
    CaptureViewport viewport = CaptureViewport.panel,
  }) => _withGuest(
    entryId: entryId,
    viewport: viewport,
    (guest) => guest.settledKnobs(entryId),
  );

  /// The axes the shell around [entryId] offers, read from a live guest.
  ///
  /// Like [knobs], and runtime for the same reason: a shell declares an axis by
  /// *asking* for it while it builds.
  Future<AxisReport> axes({
    required String entryId,
    CaptureViewport viewport = CaptureViewport.panel,
  }) => _withGuest(
    entryId: entryId,
    viewport: viewport,
    (guest) => guest.settledAxes(entryId),
  );

  /// One entry, in a guest of its own: start a daemon, compile the entry,
  /// render one frame, tear it all down.
  ///
  /// Fine for one entry, which is the shape of every caller left here.
  /// Catalog-wide batches — the audit, the comparison, the thumbnails — render
  /// under `flutter_tester` instead, where a demo that animates for ever costs
  /// fake clock rather than real seconds.
  ///
  /// Order matters and is not arbitrary: axes before knobs because a shell
  /// rebuild changes what the demo is handed; debug before any read because
  /// `platform` and `brightness` change what the demo *builds*; the tree before
  /// the hit test because a hit is only meaningful against a particular tree;
  /// and the capture last, because a picture should be of the state everything
  /// else described.
  ///
  /// A knob name the entry does not declare is an error naming the ones it
  /// does: a silently ignored knob produces a picture that looks right and is
  /// not.
  @override
  Future<CatalogObservation> render(CatalogRender request) {
    // Refused by name rather than dropped: a picture of the entry at rest,
    // handed back for a call that asked for three taps first — or for the
    // whole of its list — looks right.
    if (request.steps.isNotEmpty) {
      throw ArgumentError.value(
        request.steps,
        'steps',
        'the guest engine does not run steps yet; the harness does. Drop '
            '`engine: guest`, and `logs`, which only the guest collects.',
      );
    }
    if (request.full) {
      throw ArgumentError.value(
        request.full,
        'full',
        'the guest engine does not grow its screen yet; the harness does. '
            'Drop `engine: guest`, and `logs`, which only the guest collects.',
      );
    }
    return _render(request);
  }

  Future<CatalogObservation> _render(CatalogRender request) => _withGuest(
    entryId: request.entryId,
    viewport: request.viewport,
    (guest) async {
      var entryId = request.entryId;
      // **The device's identity, which the resize cannot carry.** The
      // embedder's window-metrics event has a size, a ratio and four insets
      // and nothing else, so everything beyond geometry travels over the VM
      // service — and until now only the *panel* sent this one
      // (`catalog_view.dart`'s `stageAs`). Headless, a preview asked for on an
      // iPhone was given a phone's screen and left running as whatever
      // platform the bare embedder reports: Cupertino widgets picked the wrong
      // branch, and a `ThemeData` computing `materialTapTargetSize` from
      // `defaultTargetPlatform` sized its buttons for the wrong machine.
      // `CaptureViewport.platform` has always existed to say this; nothing
      // outside the panel said it.
      await guest.stageAs(request.viewport.platform);
      if (request.axes.isNotEmpty) await guest.applyAxes(entryId, request.axes);
      if (request.knobs.isNotEmpty) {
        await guest.applyKnobs(entryId, request.knobs);
      }
      await guest.applyDebug(request.debug);
      // A playhead is walked on the flutter_tester lane, which is where a
      // seek can be exact (`walk_determinism_test`); this guest has no door to
      // one, and answering with the wrong frame would be worse than refusing.
      if (request.motionT case var t?) {
        throw ArgumentError.value(
          t,
          'motionT',
          'the guest engine cannot stop at a point in a motion. Render with '
              'the harness instead.',
        );
      }

      // **One frame, then every read off it.** This is the actual content of
      // "one render", and it was not true before: each `settled*` drew its own
      // scratch frame, so an observation asking five questions drew five or six
      // — and `settledHitTest` read a *second* tree to resolve against, which
      // is the assumption collapsing the actions was supposed to remove rather
      // than preserve.
      //
      // When a picture is wanted and nothing has to be read *before* it is
      // taken, the picture **is** the settling frame. That is not a
      // micro-optimisation: a plain `screenshot` is the commonest call there
      // is, and every frame here writes a PNG to disk and deletes it again. A
      // crop or an annotation needs the tree first, so those still settle
      // separately.
      File? picture;
      if (request.screenshot case var output? when !request.framed) {
        picture = await guest.capture(
          output,
          pixelRatio: request.viewport.pixelRatio,
        );
      } else {
        await guest.settle();
      }

      var tree = request.needsTree ? await guest.readTree(entryId) : null;

      // Against the tree above, by argument rather than by luck.
      var hits = request.at == null || tree == null
          ? null
          : await guest.readHitTest(tree, request.at!.$1, request.at!.$2);

      var errors = await guest.readErrors(entryId);
      var logs = request.wantLogs ? await guest.readLogs(entryId) : null;
      var applied = request.wantKnobs ? await guest.readKnobs(entryId) : null;
      var axes = request.wantAxes ? await guest.readAxes(entryId) : null;

      if (request.screenshot case var output? when picture == null) {
        var framing = PictureFraming.of(
          // `framed` is what put us here, and `needsTree` covers it, so the
          // tree has been read.
          tree!,
          node: request.cropNode,
          annotate: request.annotate,
          entryId: entryId,
        );
        picture = await guest.capture(
          output,
          framing: framing,
          pixelRatio: request.viewport.pixelRatio,
        );
      }

      return CatalogObservation(
        tree: tree,
        errors: errors,
        logs: logs,
        knobs: applied,
        axes: axes,
        hits: hits,
        screenshot: picture,
      );
    },
  );
}

/// What the compiler could and could not build.
class CatalogCheck {
  CatalogCheck({required this.servable, required this.quarantined});

  final List<CatalogEntry> servable;

  /// Entries the compiler refused, each with its diagnostics verbatim.
  final List<QuarantinedEntry> quarantined;

  bool get ok => quarantined.isEmpty;
}

/// What a settle counts as quiet, across every entry one guest renders.
///
/// `pendingImageCount` is the whole cache's, and the guest outlives every
/// entry rendered against it. One demo asking for an image that never
/// resolves — a missing asset, a provider that neither completes nor errors —
/// leaves the count above zero for the life of the process. A rule that waits
/// for zero then waits the *full deadline on every entry after it*, including
/// the static ones, and reports each of them as never having settled.
///
/// Measured on this repo's own catalog before this existed: entries 1–4
/// settled in 61–142ms, entry 5 left one load pending, and all 94 after it
/// cost ~3045ms each — **282 seconds of a 324-second audit**, spent waiting on
/// an image no later entry had asked for.
///
/// So the bar is learned rather than assumed. It only rises after a deadline
/// has actually expired with the count stuck above it — never on a guess — and
/// it drops back the moment a settle sees a clean cache, so a stuck completer
/// that is later evicted does not leave it raised behind it.
///
/// Images only. `transientCallbackCount` is tied to mounted tickers and an
/// entry switch remounts, so it returns to zero on its own; giving an
/// animation the same allowance would report a demo that genuinely never stops
/// moving as a settled picture, which is the one thing the count is read for.
class SettleFloor {
  /// How many loads this guest has been shown not to finish.
  int get stuck => _stuck;
  var _stuck = 0;

  /// The bar this pass is judged against, frozen at [begin] so that what the
  /// pass learns cannot move it while it runs.
  var _bar = 0;

  /// The fewest pending loads seen this pass, or -1 before the first poll.
  var _lowest = -1;

  /// Opens one settle.
  void begin() {
    _bar = _stuck;
    _lowest = -1;
  }

  /// Whether this poll looks like a finished frame.
  bool quiet(int pending, int transient) {
    if (_lowest < 0 || pending < _lowest) _lowest = pending;
    return pending <= _bar && transient == 0;
  }

  /// The pass settled, with [pending] loads outstanding.
  void settled(int pending) {
    if (pending == 0) _stuck = 0;
  }

  /// The pass ran out of time.
  ///
  /// When the count never came back down past [_lowest], that many loads are
  /// not coming — remember it, so the next entry waits for its own images
  /// rather than for this one's. A pass that timed out on an *animation*
  /// instead arrives here with [_lowest] at or under the bar and moves it
  /// nowhere.
  void gaveUp() {
    if (_lowest > _bar) _stuck = _lowest;
  }
}

/// One embedder guest, kept alive across captures.
class _GuestSession {
  _GuestSession._(
    this._guest,
    this._connection,
    this._server,
    this._reader,
    this._vmService,
    this._workDir,
  );

  final Process _guest;
  final Socket _connection;
  final ServerSocket _server;
  final FrameReader _reader;
  final GuestVmService _vmService;
  final String _workDir;

  /// The inspection reads, shared with the panel — see [InspectClient]. Patient
  /// here because this guest has just been handed a kernel and has to build,
  /// lay out and paint before it can describe the entry it was asked about.
  late final _inspect = InspectClient(
    _vmService,
    patience: InspectPatience.headless,
  );

  /// The capture exchange, shared with the GUI's live engine — see
  /// [FrameCapture].
  late final _capture = FrameCapture(
    send: (message) async {
      _connection.add(encodeMessage(message));
      await _connection.flush();
    },
    workDir: _workDir,
  );

  static Future<_GuestSession> start({
    required String hostPath,
    required String assetsDir,
    required String icuData,
    required String name,
    required CaptureViewport viewport,
    required String workingDirectory,
  }) async {
    // Keyed by the daemon session, like the GUI's `g-<name>.sock` — the run
    // directory is shared by every project on the machine, so anything less
    // unique means one capture deletes another's socket mid-launch. An earlier
    // version hashed the work directory, which is the *same* directory for
    // every capture on the machine. Not under the build directory: a unix
    // socket path is capped at 104 bytes, and a build directory inside a
    // worktree already spends most of that.
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'shot-$name.sock'),
    );
    // The frame scratch gets the same key for the same reason: every capture
    // used to write one shared `screenshot.rawframe`, and two concurrent
    // captures swapped frames.
    var workDir = p.join(flutterwareRunDir(), 'cap-$name');
    var socket = File(socketPath);
    if (socket.existsSync()) socket.deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );

    Process? guest;
    try {
      guest = await Process.start(hostPath, [
        assetsDir,
        icuData,
        socketPath,
        '${viewport.width}',
        '${viewport.height}',
        // Nothing watches this guest, so nothing is served by pacing it to a
        // display — see `--free-vsync` in `native/host.c`. Measured at 4.4x
        // on a render.
        '--free-vsync',
        // The package root, like the tester lane and `flutter test`: a demo
        // that opens a fixture at a relative path finds it in all three.
        // Inherited, this would be wherever `fw` was started from.
      ], workingDirectory: workingDirectory);
      var vmServiceUri = Completer<String>();
      // The guest's last few lines, kept rather than drained: an engine that
      // cannot run its kernel says so here and nowhere else, and the connect
      // below is what asks for them.
      var printed = <String>[];
      void remember(String line) {
        printed.add(line);
        if (printed.length > 20) printed.removeAt(0);
      }

      guest.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) {
            remember(line);
            var match = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
            if (match != null && !vmServiceUri.isCompleted) {
              vmServiceUri.complete(match.group(1));
            }
          });
      guest.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen(remember);

      var connected = await Future.any<Object?>([server.first, guest.exitCode]);
      if (connected is! Socket) {
        throw StateError('the guest exited before connecting');
      }

      // Raced and bounded like the connect above: a guest that binds its
      // socket and then dies — or whose stdout stops matching the scrape —
      // would otherwise hang this await forever with the process orphaned.
      var announced = await Future.any<Object?>([
        vmServiceUri.future,
        guest.exitCode,
      ]).timeout(const Duration(seconds: 30));
      if (announced is! String) {
        throw StateError('the guest exited before announcing its VM service');
      }

      var session = _GuestSession._(
        guest,
        connected,
        server,
        FrameReader(),
        await GuestVmService.connect(
          announced,
          describeGuest: () => printed.join('\n'),
        ),
        workDir,
      );
      connected.listen(session._onData);
      // Argv carried the buffer size; this carries what the buffer *means*. The
      // ratio and the safe areas have no other way in, and without them a phone
      // capture is a correctly-sized picture of the wrong layout.
      session._resize(viewport);
      // And what the buffer is a picture *of*. Awaited, unlike the resize:
      // this one is a round trip over the VM service, and a capture that
      // started before it landed would photograph the demo rendering as this
      // machine. The first frame has not been asked for yet, so nothing is
      // remounted by it — the guest simply builds staged.
      await session._inspect.setStaging(viewport.platform);
      // And how much of that screen a keyboard would take. Awaited for the
      // same reason: a capture that started before it landed would photograph
      // the full screen and file it as the picture of a raised keyboard.
      await session._inspect.setKeyboard(
        mode: viewport.keyboardMode,
        height: viewport.keyboard,
        keypadHeight: viewport.keypadKeyboard,
      );
      return session;
    } catch (_) {
      // Whatever failed above, nothing owns the guest yet.
      guest?.kill();
      await server.close();
      rethrow;
    }
  }

  /// **The insets are scaled and the size is not, and that asymmetry is the
  /// message's.** `ResizeMessage` is physical throughout —
  /// `physical_view_inset_*` is what the engine reads — and
  /// `CaptureViewport` carries a physical size beside *logical* insets,
  /// because those are the space `EdgeInsets` and `MediaQuery.padding` are
  /// written in everywhere else.
  ///
  /// Unscaled, a phone's safe areas came out divided by its pixel ratio: an
  /// iPhone 16 was staged with a 19.67pt cutout instead of 59, and an iPhone
  /// SE with 10 instead of 20. Nothing failed and every picture looked
  /// plausible — an `AppBar` merely sat too high, under the notch a phone
  /// frame exists to catch. The panel had it right all along
  /// (`catalog_view.dart`'s `insets: safeAreas * dpr`); this path did not, and
  /// `lane_parity_test.dart` is what noticed.
  void _resize(CaptureViewport viewport) => _connection.add(
    encodeMessage(
      ResizeMessage(
        width: viewport.width,
        height: viewport.height,
        pixelRatio: viewport.pixelRatio,
        insetTop: viewport.insetTop * viewport.pixelRatio,
        insetRight: viewport.insetRight * viewport.pixelRatio,
        insetBottom: viewport.insetBottom * viewport.pixelRatio,
        insetLeft: viewport.insetLeft * viewport.pixelRatio,
      ),
    ),
  );

  void _onData(List<int> chunk) {
    for (var message in _reader.addBytes(chunk)) {
      if (_capture.acknowledge(message)) continue;
      if (message is ErrorMessage) {
        _capture.failAll(StateError(message.message));
      }
    }
  }

  Future<void> reload(String dill) => _vmService.reload(dill);

  /// Puts [entryId] on screen without recompiling or reloading anything — see
  /// [InspectClient.showEntry], which the panel switches through as well.
  Future<bool> showEntry(String entryId) => _inspect.showEntry(entryId);

  /// What [entryId] declares, once the guest has actually built it.
  ///
  /// Renders a frame first, and throws it away. A knob is declared while
  /// the demo builds, and a headless host draws nothing until a frame is asked
  /// for — so without this the answer is always "no knobs". The panel never
  /// meets this because it drives frames continuously; measured here by
  /// getting an empty report from a demo that plainly has three.
  ///
  /// Then [InspectClient] retries while the report names another entry.
  Future<KnobReport> settledKnobs(String entryId) async {
    await settle();
    return readKnobs(entryId);
  }

  /// The knobs the last frame declared. Reads only — see [settle].
  Future<KnobReport> readKnobs(String entryId) async =>
      await _inspect.knobs(entryId) ?? KnobReport.empty;

  /// The tree [entryId] built, once it has actually built.
  ///
  /// Frame-first for the same reason [settledKnobs] is.
  Future<InspectTree> settledTree(String entryId) async {
    await settle();
    return readTree(entryId);
  }

  /// The tree the last frame built. Reads only — see [settle].
  Future<InspectTree> readTree(String entryId) async =>
      await _inspect.tree(entryId) ?? InspectTree.empty;

  /// The node ids under a point, outermost first.
  ///
  /// Reads the tree first so the hit is resolved against the build the caller
  /// is shown, rather than against a second reading of it.
  Future<List<String>> settledHitTest(
    String entryId,
    double x,
    double y,
  ) async {
    await settle();
    return readHitTest(await readTree(entryId), x, y);
  }

  /// The node ids under a point of [tree].
  ///
  /// Takes the tree rather than reading one, deliberately: an id names a
  /// position in a particular tree, so a hit resolved against a second reading
  /// answers about a tree the caller was never shown.
  Future<List<String>> readHitTest(
    InspectTree tree,
    double x,
    double y,
  ) async => tree.root == null ? const [] : _inspect.hitTest(x, y);

  /// What the shell around [entryId] offers, once it has built.
  ///
  /// Empty when the entry's wrapper is not a shell — an answer, not something
  /// to keep waiting for, which is why [InspectClient.axes] settles on the
  /// *entry* rather than on a shell ever appearing.
  Future<AxisReport> settledAxes(String entryId) async {
    await settle();
    return readAxes(entryId);
  }

  /// The axes the last frame's shell declared. Reads only — see [settle].
  Future<AxisReport> readAxes(String entryId) async =>
      await _inspect.axes(entryId) ?? AxisReport.empty;

  /// Turns the shell's axes, and reports what it says afterwards.
  ///
  /// The mirror of [applyKnobs], down to the whole-state rule — but filed under
  /// the shell rather than the entry, because that is the lifetime an axis has:
  /// a knob belongs to the entry and goes with it, an axis belongs to the shell
  /// and does not.
  ///
  /// Values arrive as text and are resolved against what the shell *declared*,
  /// so `theme=dark` works whether the shell spelled the option `dark` or
  /// `Dark` — a slug and a label both land, and a name the shell does not offer
  /// is an error naming the ones it does.
  Future<AxisReport> applyAxes(
    String entryId,
    Map<String, String> values,
  ) async {
    var declared = await settledAxes(entryId);
    var payload = axisPayloadFor(declared, values);
    if (payload == null) return declared;
    return await _inspect.setAxes(jsonEncode(payload)) ?? declared;
  }

  /// What [entryId] reported while building and painting.
  ///
  /// Frame-first like every other runtime read, and here it is the whole point
  /// rather than a precondition: a build error needs a build, and a layout
  /// overflow is reported from `paint`, so an entry nobody has drawn has
  /// nothing to confess.
  Future<InspectErrors> settledErrors(String entryId) async {
    await settle();
    return readErrors(entryId);
  }

  /// What the frames so far reported. Reads only — see [settle].
  Future<InspectErrors> readErrors(String entryId) async =>
      await _inspect.errors(entryId) ?? InspectErrors.empty;

  /// What [entryId] printed while building and painting.
  ///
  /// Frame-first for exactly the reason [settledErrors] is: a demo prints from
  /// `build`, so an entry nobody has drawn has said nothing.
  Future<InspectLogs> settledLogs(String entryId) async {
    await settle();
    return readLogs(entryId);
  }

  /// What the frames so far printed. Reads only — see [settle].
  Future<InspectLogs> readLogs(String entryId) async =>
      await _inspect.logs(entryId) ?? InspectLogs.empty;

  /// Sets the framework's debug switches, once the guest can hear them.
  ///
  /// Renders a frame first, and it is not the usual reason. Knobs and the
  /// tree need a frame because a demo declares them by building; these are
  /// registered by the binding whether anything builds or not — but the *VM
  /// service* learns about them asynchronously, and a call that lands between
  /// connect and registration comes back "method not found". Measured: every
  /// flag failed that way until a frame went first.
  /// Tells the guest which device it *is*, where the resize told it how big.
  Future<void> stageAs(DevicePlatform? platform) async {
    await _renderScratchFrame();
    await _inspect.setStaging(platform);
  }

  Future<void> applyDebug(Map<String, String> values) async {
    if (values.isEmpty) return;
    await _renderScratchFrame();
    await applyDebugFlags(_vmService, values);
  }

  Future<void> settle() => _renderScratchFrame();

  Future<void> _renderScratchFrame() async {
    var scratch = p.join(_workDir, 'knobs.scratch.png');
    await capture(scratch);
    var file = File(scratch);
    if (file.existsSync()) file.deleteSync();
  }

  /// Turns [values] on [entryId], and reports what the entry says afterwards.
  ///
  /// Coerced to the kind the preview declared, because everything arrives as text:
  /// a shell flag has no types and a JSON object from an agent may disagree
  /// with the demo about int versus double.
  Future<KnobReport> applyKnobs(
    String entryId,
    Map<String, String> values,
  ) async {
    var declared = await settledKnobs(entryId);
    await _inspect.setKnobs(
      jsonEncode(knobPayloadFor(declared, values, entryId: entryId)),
    );

    // Read once at the end: a demo's build decides what knobs exist, so
    // turning one can reveal or retire another, and only the settled set is
    // worth reporting.
    return values.isEmpty ? declared : await settledKnobs(entryId);
  }

  /// The guest's next frame, decoded and not written anywhere.
  ///
  /// What [capture] does minus the PNG: a batch comparing pixels never wants
  /// the file, and the encoder it skips costs ~7.5ms a picture — measured on
  /// `ScenarioRunArgs.captureRaw`, along with what it costs in bytes.
  /// The frame, and what the guest could say about it having stopped moving.
  Future<(img.Image, ({bool settled, bool seesAnimations}))>
  captureImage() async {
    var settled = await _settle();
    return (await _capture.capture(), settled);
  }

  /// Asks the guest to write its next frame, waits for the ack, and files it.
  ///
  /// The framing and the encoding are `catalog_picture.dart`'s: what is this
  /// session's is getting a frame out of a guest, and what a `--node` means
  /// against a tree is the same question whichever engine drew it.
  Future<File> capture(
    String output, {
    PictureFraming framing = const PictureFraming(),

    /// Logical-to-physical, for turning a layout rect into pixels.
    double pixelRatio = 1,
  }) async {
    await _settle();
    return writePicture(
      await _capture.capture(),
      output,
      framing: framing,
      pixelRatio: pixelRatio,
    );
  }

  final _floor = SettleFloor();

  /// Waits until the guest has no image loads in flight, bounded.
  ///
  /// A demo's images arrive after its layout: `Image.asset` registers the load
  /// during build and the decode lands asynchronously, so a frame photographed
  /// in between shows the layout without the pixels — measured on
  /// `asset_smoke.dart`, where both images were simply absent from an otherwise
  /// perfect capture. Every call to the extension renders a frame, which is
  /// what starts the loads on a fresh guest and paints whatever has been
  /// delivered since; see [GuestImages].
  ///
  /// Zero twice in a row, because one asynchronous hop can separate a
  /// build from the `Image` it creates — a `FutureBuilder` over
  /// `rootBundle.load` reads zero pending while its future is still in flight,
  /// and by the next frame the image it built is either delivered or counted.
  ///
  /// Bounded, never a hang: a demo that streams images forever costs a
  /// slightly-early picture, the same trade [SettleRegistry] makes for busy
  /// plugins.
  ///
  /// [GuestVmService.requireExtension] rather than the tolerant form, which is
  /// this bug's whole history: the first capture of a fresh
  /// guest lands before `main` has registered anything, and a call that treats
  /// "not registered yet" as "no answer needed" skips the wait on exactly the
  /// capture most likely to race the decode — intermittently, which is how the
  /// missing images stayed invisible in the first place.
  ///
  /// Draws frames until nothing is still moving, or until the deadline.
  ///
  /// Returns false when it gave up — a looping animation never drains, and a
  /// picture taken in the middle of one is worth having *and* worth labelling.
  ///
  /// `transient` is absent from an older guest's reply and reads as zero, which
  /// is the old behaviour: images only. That is the graceful half of a version
  /// skew — the base side of a comparison against a checkout that predates the
  /// field settles for images alone rather than failing to answer at all.
  ///
  /// What counts as quiet is [SettleFloor]'s, because one guest renders every
  /// entry of a catalog-wide run and a stuck load is not that run's to wait
  /// for twice.
  Future<({bool settled, bool seesAnimations})> _settle() async {
    var deadline = Stopwatch()..start();
    var zeros = 0;
    var seesAnimations = true;
    _floor.begin();
    while (deadline.elapsed < const Duration(seconds: 3)) {
      var report = await _vmService.requireExtension(
        'ext.flutterware.imagesSettled',
      );
      if (report == null) return (settled: true, seesAnimations: true);
      // Absent from a guest built before the field existed. Reported rather
      // than silently treated as zero: that guest settles for images alone, so
      // its frames can be taken mid-transition — and a comparison whose two
      // sides settle by different rules differs for a reason that is not the
      // branch's.
      seesAnimations = report.containsKey('transient');
      var pending = (report['pending'] as num? ?? 0).toInt();
      var transient = (report['transient'] as num? ?? 0).toInt();
      if (_floor.quiet(pending, transient)) {
        // Twice, because one quiet frame is what the frame *before* an
        // animation starts also looks like.
        if (++zeros >= 2) {
          _floor.settled(pending);
          return (settled: true, seesAnimations: seesAnimations);
        }
      } else {
        zeros = 0;
      }
    }
    _floor.gaveUp();
    return (settled: false, seesAnimations: seesAnimations);
  }

  Future<void> close() async {
    await _vmService.close();
    _connection.add(encodeMessage(const ShutdownMessage()));
    await _connection.flush();
    await _connection.close();
    _guest.kill();
    await _server.close();
    // Frames delete themselves as they are read; this picks up the directory,
    // which would otherwise accumulate one empty `cap-<session>` per capture.
    try {
      Directory(_workDir).deleteSync(recursive: true);
    } on FileSystemException {
      // Housekeeping only — a frame still being written wins, and loses
      // nothing but an empty directory.
    }
  }
}
