import 'dart:async';

import 'package:device_frame/device_frame.dart' hide Devices;
import 'package:flutterware/previews_guest.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../address/address_scope.dart';
// A leaf module with no imports of its own — the address grammar this panel
// both reads and writes. See `catalogPlace`.
import '../plugins/native/previews_address.dart';
import '../capture/capture_mode.dart';
import '../embedder/embedded_engine.dart' show EmbeddedEnginePhase;
import '../embedder/guest_surface.dart';
import '../inspect/node_highlight.dart';
import '../inspect/pick_region.dart';
import '../inspect/semantics_node.dart';
import '../ui/aside.dart';
import '../ui/empty_state.dart';
import '../ui/loading_state.dart';
import '../ui/capture_button.dart';
import '../ui/design/design.dart';
import '../ui/popover.dart' as ui;
import '../ui/popover_menu.dart';
import '../ui/startup_progress.dart';
import '../ui/tappable.dart';
import 'daemon_phase.dart';
import 'protocol.dart';
import '../ui/tree_row.dart';
import 'app_chords.dart';
import 'catalog_params.dart';
import 'catalog_devices.dart';
import 'catalog_entry.dart';
import 'catalog_session.dart';
import 'preview_popover.dart';
import 'preview_sheet.dart';
import 'staged_device.dart';
import '../ui/stage.dart';
import 'stage_ground.dart';
import 'stage_zoom.dart';
import 'zoom_control.dart';
import 'thumbnails.dart';
import '../delta/branch_delta.dart';
import '../delta/change_marks.dart';
import 'catalog_tree.dart';
import 'inspect_panel.dart';

/// The namespace covering the canvas and the panel below it — see where it is
/// installed in [_CatalogViewState._buildBody] for why it stops there.
///
/// Named once because both sides of that boundary have to agree: what is
/// written under it is `inspect.*`, and a reader on the other side has to say
/// so. Two of them did not, in opposite directions — see [_deviceOf] and
/// [_croppedNode].
const _inspectNamespace = 'inspect';

/// The catalog loop: entries on the left, the live guest on the right.
/// Selecting an entry hot-reloads the running guest rather than restarting it.
///
/// Mounted by the `flutterware.previews` plugin as its panel, and by
/// `main_catalog_dev.dart` for working on the loop itself.
///
/// It **renders** a [CatalogSession]; it does not own one. The owner outlives
/// the widget, which is what lets a cold compile keep running — and keep
/// reporting into the sidebar — while you are looking at another plugin.
class CatalogView extends StatefulWidget {
  const CatalogView({
    super.key,
    required this.session,
    this.thumbnails,
    this.zoom,
    this.entryChanges,
    this.onLookAgain,
  });

  final CatalogSession session;

  /// How the branch touched each entry, for the tree's tint and its
  /// changed-only filter. Null until the delta lands, and for a session with
  /// no core behind it — the standalone catalog — where nothing is tinted.
  final EntryChanges? entryChanges;

  /// Called when the panel looks again at the disk — on mount, on the window
  /// regaining focus — so what the tint is read from can be asked to as well.
  final VoidCallback? onLookAgain;

  /// The stage's pan and zoom, when something above wants it to outlive this
  /// widget.
  ///
  /// The panel is keyed on the session and a package is a session, so moving
  /// between two packages remounts everything here, and a magnification that
  /// evaporated on the way would be a zoom you cannot use while comparing the
  /// same control in two places. Null means no caller needs it — the standalone
  /// catalog entry point — and one is made and disposed here.
  final TransformationController? zoom;

  /// This package's photographed previews, for the popover the list shows on
  /// hover. Null where nothing is keeping them — the standalone catalog entry
  /// point and the motion panel, both of which build a session of their own.
  final PreviewThumbnails? thumbnails;

  @override
  State<CatalogView> createState() => _CatalogViewState();
}

class _CatalogViewState extends State<CatalogView> {
  /// How often the panel asks whether entries have appeared or disappeared.
  ///
  /// Cheap enough not to think about — the daemon compares a listing of the
  /// roots, a few milliseconds, and answers nothing at all when it matches.
  /// It exists because the other triggers are all things *you* do, and files
  /// arrive without you: an agent writing a demo while you watch the panel
  /// would otherwise go unnoticed until you touched something.
  static const _pollInterval = Duration(seconds: 3);

  /// When the panel looks again after coming back to the window.
  ///
  /// An editor that saves as it loses focus is racing the window that gains it:
  /// IntelliJ writes the file at about the moment this panel sweeps for edits,
  /// and often a beat after — so a single check on resume misses the very edit
  /// you switched over to look at, and you have to reload by hand or save
  /// again. Looking twice more costs nothing when nothing moved, which is the
  /// same property the whole focus trigger rests on.
  static const _afterFocus = [
    Duration(milliseconds: 200),
    Duration(milliseconds: 600),
    Duration(milliseconds: 1500),
  ];

  /// The node the pointer is over, drawn on the preview and nowhere else.
  ///
  /// A notifier rather than session state or a `setState`, and the granularity
  /// is the reason: this changes on every mouse move across a tree row, and
  /// rebuilding the entry list and the top bar sixty times a second to move one
  /// rectangle would be absurd. Only the overlay listens.
  final _highlight = ValueNotifier<String?>(null);

  /// The Semantics tab's hover — its own notifier, as on the step page: the
  /// id spaces differ, and only the elements one round-trips through the
  /// picker and the watch.
  final _semanticsHighlight = ValueNotifier<SemanticsSnapshotNode?>(null);

  /// Whether a click on the preview picks a widget instead of reaching the demo.
  final _picking = ValueNotifier<bool>(false);

  /// The top bar's capture button, so ⌘⇧C is that button pressed rather than
  /// a second copy path — see [_copyPreview].
  final _captureButton = GlobalKey<CaptureButtonState>();

  final FocusNode _focusNode = FocusNode();
  Timer? _poll;
  final _settling = <Timer>[];
  (int, int, double, EdgeInsets)? _lastReported;
  late final AppLifecycleListener _lifecycle;

  CatalogSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_followZoom);
    // Coming back to the window after editing elsewhere. `onResume` is
    // documented as "a view in the application gains input focus", which on
    // desktop is exactly the alt-tab back from the editor.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _reloadAfterFocus();
        _startPolling();
      },
      // Nothing arrives on screen while the window is behind another one, and
      // coming back runs a full check anyway.
      onInactive: _stopPolling,
    );
    _startPolling();

    // The one thing on screen whose rect has to keep up with a demo that is
    // moving. Everything else the tree says goes slightly stale and looks
    // slightly wrong; a rectangle drawn over the wrong place looks *broken*,
    // and it is the reason the watch exists at all.
    _highlight.addListener(_trackHighlighted);

    // And coming back to the *panel*: the shell rebuilds it from scratch when
    // you switch plugins, so a mount is the other half of the same signal.
    // After the frame, because this runs during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reloadIfChanged());
  }

  void _trackHighlighted() => _session.watchedNode = _highlight.value;

  @override
  void dispose() {
    _stopPolling();
    _stopSettling();
    _lifecycle.dispose();
    _focusNode.dispose();
    _highlight
      ..removeListener(_trackHighlighted)
      ..dispose();
    _semanticsHighlight.dispose();
    _picking.dispose();
    _resizeSettle?.cancel();
    _zoom.removeListener(_followZoom);
    _ownedZoom?.dispose();
    _panning.dispose();
    super.dispose();
  }

  /// Checks now, then again over the next second and a half — see [_afterFocus].
  void _reloadAfterFocus() {
    _reloadIfChanged();
    _stopSettling();
    _settling.addAll([
      for (var delay in _afterFocus) Timer(delay, _reloadIfChanged),
    ]);
  }

  void _stopSettling() {
    for (var timer in _settling) {
      timer.cancel();
    }
    _settling.clear();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) {
      _session.refresh();
      // Errors are not a fact about the build, they are a stream. A read fired
      // once after a reload gets a 300ms window, and a cold start can spend
      // seconds getting to its first frame — so the answer was "waiting for
      // the entry to render…" for ever, on a demo that was visibly painting
      // Flutter's overflow stripes. Worse, an error thrown from `paint`
      // arrives *whenever it is painted*, which can be long after any build
      // this could have hung a read on.
      //
      // Cheap: a handful of deduped errors over a connection that is already
      // open, and only while somebody has the panel on screen.
      unawaited(_session.readErrors());
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The guest is told what the address asks of the shell's axes, from here
    // rather than from the panel above: this widget is what renders a session,
    // and the standalone harness mounts it without a panel. One place, so the
    // two cannot drift.
    _session.axisSelections = AddressScope.params(context, namespace: 'axis');
    _session.knobSelections = AddressScope.params(context, namespace: 'knob');
  }

  /// The stage's pan and zoom — see [ZoomableStage].
  ///
  /// Held above the stage so it survives what the stage does not: a compile
  /// error replaces the canvas outright, and a magnified preview that reset
  /// itself every time you broke the build would be a zoom you could not work
  /// with. Handed in from higher still when it has to outlive this widget too.
  late final _zoom = widget.zoom ?? (_ownedZoom = TransformationController());
  TransformationController? _ownedZoom;

  /// Whether a pan is currently moving the stage — see [_demoInput].
  final _panning = ValueNotifier(false);

  /// Back to life-size, and back to the middle.
  void _resetZoom() => _zoom.value = Matrix4.identity();

  /// The stage has taken the drag, or given it back.
  ///
  /// The cancel is the point. The demo was told about a finger going down
  /// and is holding whatever that pressed; simply withholding the rest of the
  /// gesture leaves it pressed for ever — a button lit, an ink ripple that
  /// never settles, a `Draggable` stuck to nothing. Cancel is what a framework
  /// sends when a recognizer loses an arena, and losing an arena is exactly
  /// what has happened here.
  void _setPanning(GuestSurface surface, bool panning) {
    if (panning == _panning.value) return;
    _panning.value = panning;
    if (panning) {
      surface.cancelPointer();
    }
  }

  /// Cheap by construction: the daemon answers `unchanged` when nothing on disk
  /// moved, so this fires as often as it likes without touching the guest.
  void _reloadIfChanged() {
    widget.onLookAgain?.call();
    if (mounted) unawaited(_session.reloadIfChanged());
  }

  void _maybeResize(
    GuestSurface surface,
    Size size,
    double dpr, {
    EdgeInsets safeAreas = EdgeInsets.zero,
  }) {
    var width = (size.width * dpr).round();
    var height = (size.height * dpr).round();
    if (width < 1 || height < 1) return;
    // Keyed on the ratio and the safe areas as well as the size: two devices
    // can share a logical size at different ratios or different notches, and
    // comparing only the size would leave the guest rendering as the old one.
    var next = (width, height, dpr, safeAreas);
    if (next == _lastReported) return;
    // **A resize is a new surface, and a new surface mid-gesture is a jolt.**
    // The logical size moves when a device is picked or the panel is dragged —
    // rare, and wanted at once. The ratio moves continuously through a pinch,
    // and reallocating the guest sixty times a second is what a smooth gesture
    // was being spent on. So a ratio-only change waits for the fingers to
    // stop, including the first one: a leading-edge resize is still a jolt,
    // and it lands at the moment the gesture is least ready for it.
    //
    // What that costs in between is a texture briefly sampled — soft while
    // moving, exact once still, which is what every viewer does and what the
    // eye is expecting anyway.
    var sized =
        _lastReported == null ||
        width != _lastReported!.$1 ||
        height != _lastReported!.$2 ||
        safeAreas != _lastReported!.$4;
    _resizeSettle?.cancel();
    _resizeSettle = null;
    if (!sized) {
      _resizeSettle = Timer(
        const Duration(milliseconds: 150),
        () => _applyResize(surface, next),
      );
      return;
    }
    _applyResize(surface, next);
  }

  void _applyResize(GuestSurface surface, (int, int, double, EdgeInsets) next) {
    _resizeSettle = null;
    _lastReported = next;
    var (width, height, dpr, safeAreas) = next;
    // Physical pixels, like the size — the guest turns them back into logical
    // padding on the other side.
    surface.resize(width, height, dpr, insets: safeAreas * dpr);
  }

  /// The trailing edge waiting to resize the guest — see [_maybeResize].
  Timer? _resizeSettle;

  bool _isAppChord(KeyEvent event) =>
      isReservedAppChord(event, HardwareKeyboard.instance);

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _reload,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): _reload,
        // Shifted, because plain ⌘C belongs to whatever text has the selection.
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true):
            _copyPreview,
        const SingleActivator(
          LogicalKeyboardKey.keyC,
          control: true,
          shift: true,
        ): _copyPreview,
      },
      child: _buildBody(context),
    );
  }

  /// The same thing the top bar's copy button does — routed *through* the
  /// button so the shortcut shows the same tick a click would, instead of
  /// being a second implementation that happens to agree.
  void _copyPreview() {
    unawaited(_captureButton.currentState?.copy());
  }

  void _reload() {
    if (_session.phase == CatalogSessionPhase.ready) {
      unawaited(_session.reload());
    }
  }

  Widget _buildBody(BuildContext context) {
    return Material(
      child: AnimatedBuilder(
        // All three, named here rather than relied on being forwarded. The
        // session does forward them, but it wires that up in its constructor —
        // which a hot reload never re-runs, so an existing session ends up with
        // a staging nobody listens to and a top bar that only catches up when
        // something else happens to rebuild it.
        animation: Listenable.merge([
          _session,
          _session.browsing,
          _session.staging,
        ]),
        builder: (context, _) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AsidePane(
                width: 260,
                child: _EntryList(
                  session: _session,
                  changes: widget.entryChanges,
                  thumbnails: widget.thumbnails,
                  onGoTo: (scope) => _goTo(context, _session, scope),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The bar belongs to the stage, and comes down with it —
                    // the same rule as the inspection dock below.
                    //
                    // Every control on it acts on the guest: the device it is
                    // staged as, the axes the *entry on screen* declared while
                    // it built, the stage's zoom, and a button that photographs
                    // the live frame. On the catalog there is no entry on
                    // screen, so all four were the last demo's — a flavor
                    // switch that changed nothing visible, a zoom for a page
                    // that does not zoom, and a copy button that quietly
                    // handed you a picture of a demo you had left.
                    if (_session.selected != null) ...[
                      _TopBar(
                        session: _session,
                        captureButton: _captureButton,
                        highlight: _highlight,
                        zoom: _zoom,
                        onResetZoom: _resetZoom,
                      ),
                      const Divider(height: 1),
                    ],
                    // Wrapped so the panel can be told how much room there is,
                    // and wrapped *here* rather than higher so the number is
                    // the canvas and the panel and nothing else — a reserve
                    // that had to guess at the bars above and below would be
                    // wrong the moment either changed height.
                    //
                    // It cannot measure this itself: a `Column` hands a
                    // non-flex child an unbounded main axis, so a
                    // `LayoutBuilder` down there reads infinity and clamps
                    // against nothing.
                    Expanded(
                      // `inspect` covers the canvas and the panel and
                      // nothing else, because those are its two writers: the
                      // tree writes a selection when you click a row, the
                      // picker writes one when you click the *preview*.
                      // Wrapped any higher and it would swallow the top
                      // bar's writes too — a device picked from up there
                      // would land as `inspect.device`, which is nobody's
                      // parameter.
                      //
                      // Which cuts both ways, and the read is the half that
                      // is easy to miss: `device` is the top bar's,
                      // un-namespaced, so it is resolved *here* — above the
                      // scope — and handed down. Read from inside, it asked
                      // for `inspect.device` and got nothing, and the canvas
                      // framed every entry as the panel however the picker
                      // was set.
                      child: Builder(
                        builder: (context) {
                          // Both halves, resolved here and here only: the
                          // device as the table holds it, and which way up it
                          // is being shown. The canvas turns the numbers itself
                          // and leaves the body upright, because a hand-drawn
                          // silhouette is artwork — `DeviceFrame` rotates it,
                          // and there is no sideways version of it to hand
                          // over.
                          var device = _deviceOf(context, _session);
                          var orientation = _orientationOf(context, _session);
                          var keyboard = _keyboardOf(context, _session);
                          // **Built here, above the namespace.** Pressing the
                          // dismiss key on a keyboard somebody *held* up has
                          // to clear the address, not only tell the guest: the
                          // canvas re-pushes what the address says after every
                          // frame, so a mode left at `up` puts the keyboard
                          // straight back — measured, and it made the key look
                          // dead. `keyboard` is un-namespaced like `device`,
                          // so the writer has to be taken from a context no
                          // `AddressScope` below has renamed.
                          void dismissKeyboard() {
                            if (keyboard == KeyboardMode.up) {
                              AddressScope.write(context)
                                  .setParam('keyboard', null);
                            }
                            _session.dismissKeyboard();
                          }

                          return AddressScope(
                            namespace: _inspectNamespace,
                            child: LayoutBuilder(
                              builder: (context, constraints) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: _buildCanvas(
                                      context,
                                      device,
                                      orientation,
                                      keyboard,
                                      dismissKeyboard,
                                    ),
                                  ),
                                  // Mounted for as long as there is a demo to
                                  // inspect, and only for that long.
                                  //
                                  // Within a demo it is always there, unlike
                                  // the knob drawer it replaced: that one was
                                  // absent rather than empty when an entry
                                  // declared no knobs, so anybody who had not
                                  // happened to open a demo with knobs never
                                  // learned the feature existed. The tab is
                                  // there now and says so.
                                  //
                                  // On the catalog there is no demo, and the
                                  // panel reads the *live guest* — so it went
                                  // on showing the tree, the knobs and the
                                  // console of whichever demo was visited last,
                                  // an inspector attached to something that is
                                  // not on the screen. Nothing it could say
                                  // there is true, and the page of pictures
                                  // wants the room.
                                  if (_session.selected != null)
                                    InspectPanel(
                                      session: _session,
                                      available: constraints.maxHeight,
                                      highlight: _highlight,
                                      semanticsHighlight: _semanticsHighlight,
                                      picking: _picking,
                                      controls: (context) =>
                                          _KnobPanel(session: _session),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    _StatusBar(session: _session, onReload: _reload),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCanvas(
    BuildContext context,
    Device? device,
    ScreenOrientation? orientation,
    KeyboardMode keyboard,
    VoidCallback onDismissKeyboard,
  ) {
    // **Before the phase**, because with nothing selected the phase is about
    // work nobody asked for: the guest warms on the first entry so that the
    // click that follows costs ~49ms instead of ~12.5s, and counting the
    // seconds of that on the stage would be progress towards a demo the stage
    // is not going to show. The error phase still wins — a session that cannot
    // start is worth saying whether or not a demo was picked.
    // **Answered before anything returns**, including the paths that do not
    // draw the stage at all: it is a running answer, and a build that skipped
    // it would leave "the stage is holding a demo" true across a trip to the
    // catalog — which is exactly the trip it exists to catch.
    _holdsGuest = stageHoldsGuest(
      guestEntryId: _session.active?.id,
      selectedEntryId: _session.selected?.id,
      alreadyHolding: _holdsGuest,
    );
    if (_session.phase != CatalogSessionPhase.error &&
        _session.selected == null) {
      // **The catalog as pictures, which is what you are here to look at.**
      // A stage that says "pick a demo" over blank space is polite and useless:
      // the question at this moment is *which* one, and a list of names answers
      // it only for someone who already knows what the names mean.
      //
      // It is not a mode and there is no button for it. Nothing selected is
      // exactly when a page of pictures is worth the room, and picking one
      // replaces it with the thing that was picked.
      if (widget.thumbnails case var thumbnails?) {
        return _catalog(thumbnails);
      }
      // The words, for a session photographing nothing — the standalone entry
      // point, and the motion panel's borrowed catalog.
      return const EmptyState(
        icon: Icons.widgets_outlined,
        title: 'Pick a demo',
        message: 'Opening one renders it here.',
      );
    }
    switch (_session.phase) {
      case CatalogSessionPhase.starting:
        // The seconds are the message rather than the title: a cold start is
        // ~11s here, and a count that is climbing is the only thing on screen
        // that distinguishes "slow" from "hung".
        //
        // **The daemon's own phase when there is one**, which since it started
        // reporting them there usually is. What this used to say was true and
        // uninformative: every second of the wait reads "Compiling <demo>",
        // where the demo is the last two percent of it and the surface
        // framework, the host build and the whole-catalog compile are the rest.
        // The entry is still named — it is what is being waited *for* — and the
        // phase is what is being waited *on*.
        return LoadingState(
          title: 'Building the guest…',
          // Named, because it is reachable only with a selection — the guard
          // above takes every unselected session — and by then the demo being
          // waited for is a better word than "the first entry", which since the
          // list stopped picking one is not even true.
          message: [
            if (_session.startup.task case var task?)
              task.label
            else
              'Compiling ${_session.selected!.name}',
            '${_session.busyFor.inSeconds}s',
          ].join(' — '),
        );
      case CatalogSessionPhase.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.xxl),
            child: SingleChildScrollView(
              child: SelectableText(
                _session.errorMessage ?? 'unknown error',
                style: context.type.caption.copyWith(color: context.colors.red),
              ),
            ),
          ),
        );
      case CatalogSessionPhase.ready:
        // **The catalog stays up until the guest has caught up.** The stage is
        // a texture the guest paints into, and for the ~35–70ms a warm switch
        // takes it still holds the demo that was on it before. Coming off the
        // catalog that is a demo you did not ask for and were not looking at,
        // which arrives and is replaced — a flash of the wrong thing on every
        // click. Coming off *another demo* the same stale frame is the demo you
        // were just looking at, so it is the right thing to hold: hence the
        // rule in [stageHoldsGuest] rather than a blanket "hide it".
        //
        // The tile you clicked is marked while this lasts, so the click is not
        // silent, and a switch slow enough to need saying so still gets
        // [_SwitchingOverlay] over the top.
        // The error goes where the widget would have been. The guest is still
        // rendering the last entry that loaded, and showing that under a
        // selection it does not belong to is how you end up wondering why your
        // edit did nothing.
        //
        // **And it is answered before the wait**, because it is not the guest's
        // picture: an entry that will not compile has nothing to wait for, and
        // holding the catalog up in front of the compiler's complaint would
        // hide the one thing worth reading.
        Widget canvas;
        if (_session.selectedError case var error?) {
          canvas = _CompileError(
            entry: _session.selected!,
            error: error,
            onRetry: _session.busyWith == null ? _reload : null,
          );
        } else if (!_holdsGuest && widget.thumbnails != null) {
          canvas = _catalog(widget.thumbnails!);
        } else if (!_holdsGuest && _session.selected == null) {
          // No landing pictures — a host that cannot render them — and
          // nothing picked: say so, rather than draw whichever entry the
          // guest happens to hold, which is a demo nobody asked for.
          canvas = const EmptyState(
            icon: Icons.grid_view_outlined,
            title: 'Pick a demo',
            message: 'Opening one draws it here.',
          );
        } else {
          canvas = _buildTexture(
            context,
            _session.surface!,
            device,
            orientation,
            keyboard,
            onDismissKeyboard,
          );
        }
        // Over whichever of the two it is: both are a picture of where you
        // were, and a switch that has to compile obscures both the same way.
        if (_session.compilingSwitch case var entry?) {
          return _SwitchingOverlay(entry: entry, child: canvas);
        }
        return canvas;
    }
  }

  /// Whether the stage is currently drawing the guest's picture — the input
  /// [stageHoldsGuest] needs, and a cache of what the last build decided rather
  /// than state anything else may read.
  var _holdsGuest = false;

  /// The catalog as pictures. Drawn with nothing selected, and again while a
  /// switch off it is in flight.
  Widget _catalog(PreviewThumbnails thumbnails) =>
      _Landing(session: _session, thumbnails: thumbnails);

  /// The guest, sized either to the panel or to a device.
  ///
  /// A device is not a frame drawn around the same picture: the guest's window
  /// *is* the device screen, at the device's own pixel ratio, so what the demo
  /// reads from `MediaQuery` is what it would read on the phone. Rendering at
  /// the device's resolution and scaling the result down is also the only way
  /// the texture stays sharp.
  Widget _buildTexture(
    BuildContext context,
    GuestSurface surface,
    Device? device,
    ScreenOrientation? orientation,
    KeyboardMode keyboard,
    VoidCallback onDismissKeyboard,
  ) {
    if (device == null) {
      var hostRatio = MediaQuery.of(context).devicePixelRatio;
      return StageGround(
        child: ZoomableStage(
          controller: _zoom,
          onInteracting: (panning) => _setPanning(surface, panning),
          // Above the `LayoutBuilder`, so what the guest is told to render is
          // already the inset size — a fitted canvas that measured the whole
          // pane and then got padded would be one inset too wide in each
          // direction, and would be told to render a surface it cannot fill.
          child: Padding(
            padding: const EdgeInsets.all(stageInset),
            child: LayoutBuilder(
              builder: (context, constraints) {
                _stage = (
                  surface,
                  constraints.biggest,
                  hostRatio,
                  EdgeInsets.zero,
                );
                _resizeAfterFrame();
                _stageAfterFrame(null);
                // Zero, whatever the bar asks for. `Fit` is not a device, so
                // there is no measured keyboard to raise — and inventing one
                // is the thing the whole table exists not to do. The mode
                // still travels, so the guest reports the request rather than
                // silently discarding it.
                _keyboardAfterFrame(keyboard, 0, null);
                return _staged(
                  _guestInput(surface, const SizedBox.expand(), touch: false),
                );
              },
            ),
          ),
        ),
      );
    }

    // The numbers are the turned device's; the body below is the upright one's.
    // Every measurement the guest meets comes from here — the window it renders
    // into, its ratio, the insets it lays out against — so a landscape run is
    // one device, read sideways, and not a second entry in the table.
    var effective = device.oriented(orientation);
    var screen = Size(effective.width, effective.height);
    _stage = (
      surface,
      screen,
      effective.pixelRatio,
      // What the frame draws around the screen, told to the thing rendering
      // inside it — otherwise the notch is decoration and an AppBar sits under
      // it.
      EdgeInsets.fromLTRB(
        effective.insetLeft,
        effective.insetTop,
        effective.insetRight,
        effective.insetBottom,
      ),
    );
    _resizeAfterFrame();
    // The identity, where everything above was the geometry — the guest renders
    // as this platform, not as the machine the studio is running on.
    _stageAfterFrame(effective.platform);
    // And how much of it a keyboard would take, already turned — a phone's
    // landscape keyboard is shorter than its portrait one, and a tablet's is
    // taller.
    _keyboardAfterFrame(keyboard, effective.keyboard, effective.keypadKeyboard);
    // The one thing `device_frame` is here for, and the only place it is
    // touched: the silhouette. Everything above came from our own measurements.
    // Null for a desktop size, which gets none.
    var chrome = deviceFrameFor(device);
    var guest = StageKeyboardDismiss(
      // The guest's own number, not the device's: what is on screen is what
      // the *app* asked for through the mode, and a key drawn from the table
      // would sit over a keyboard that is not up.
      band: _session.keyboard?.height ?? 0,
      onDismiss: onDismissKeyboard,
      child: _guestInput(
        surface,
        SizedBox.fromSize(size: screen),
        touch: deviceIsTouched(effective),
      ),
    );
    // **The body is inside the zoom, not around it.** Zooming a framed preview
    // ought to look like leaning towards the phone; a stage that magnified the
    // screen while the body stayed put would look like neither. So the
    // transform goes above both, and the artwork re-rasterizes through it for
    // the same reason the guest's own picture does.
    return StageGround(
      child: ZoomableStage(
        controller: _zoom,
        onInteracting: (panning) => _setPanning(surface, panning),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.xl),
            // scaleDown, never up: at rest the texture is the device's own
            // resolution, and enlarging that is just a blurrier phone. Past rest
            // it is the transform above that enlarges, with the pixels behind it
            // to make that honest.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: chrome == null || !_session.staging.frameVisible
                  // The body already *is* the edge, so only the bodyless
                  // stagings get one drawn.
                  ? _staged(SizedBox.fromSize(size: screen, child: guest))
                  // Told which way up, because the body it is holding is not: a
                  // hand-drawn phone is drawn portrait and turned here, and the
                  // screen box handed to it has already traded its width for its
                  // height.
                  : DeviceFrame(
                      device: chrome,
                      screen: guest,
                      orientation: orientation == ScreenOrientation.landscape
                          ? Orientation.landscape
                          : Orientation.portrait,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// The guest's picture with the edge that marks where it ends.
  Widget _staged(Widget picture) =>
      StageSpecimen(focus: _focusNode, child: picture);

  /// What the stage last laid out, so the zoom listener can work out what to
  /// render at without a rebuild.
  (GuestSurface, Size, double, EdgeInsets)? _stage;

  /// The guest's ratio follows the magnification — see [guestRatioFor].
  ///
  /// A listener rather than a rebuild: what magnifying changes is one number on
  /// a wire, and rebuilding the body and the texture to deliver it is what made
  /// a pinch stutter. Nothing under [ZoomableStage] is built again by a zoom.
  void _followZoom() => _resizeAfterFrame();

  /// Tells the guest what it is being rendered *as*, after the frame that
  /// worked it out.
  ///
  /// Post-frame like [_resizeAfterFrame] and for the same reason: this is a
  /// call out of a build, and the build is what knows the device. The session
  /// swallows the repeats — every rebuild computes the same platform, and only
  /// a change or a fresh guest is worth a round trip.
  void _stageAfterFrame(DevicePlatform? platform) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _session.stageAs(platform);
    });
  }

  /// And how tall its keyboard is. Post-frame and deduped for the reasons
  /// [_stageAfterFrame] is.
  void _keyboardAfterFrame(
    KeyboardMode mode,
    double height,
    double? keypadHeight,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _session.keyboardAs(mode, height, keypadHeight);
    });
  }

  void _resizeAfterFrame() {
    if (_stage case (var surface, var logical, var deviceRatio, var insets)) {
      var ratio = guestRatioFor(
        logical,
        deviceRatio,
        _zoom.value.getMaxScaleOnAxis(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeResize(surface, logical, ratio, safeAreas: insets);
      });
    }
  }

  /// Picks the widget under a point instead of letting the demo have the click.
  ///
  /// Two hit tests, and the split is deliberate. The highlight has already
  /// followed the mouse here from [InspectTree.nodeAtPoint], which knows only
  /// rectangles; the commit asks the guest, which runs the framework's own
  /// hit test and therefore knows about transforms, clips and `IgnorePointer`.
  /// So the box you were shown is a guess and the node you get is not — and
  /// when they disagree, the tree jumps to the right one.
  Future<void> _pick(BuildContext context, Offset point) async {
    var handle = AddressScope.write(context);
    var id = await _session.nodeUnder(point.dx, point.dy);
    if (!mounted) return;
    // Nothing under the point is a miss, not a selection to clear: you clicked
    // the margin, and losing what you had chosen for that would be a punishment
    // for a slip. (Disarming is [InspectPickRegion]'s, already done by the
    // time this answer lands.)
    if (id != null) handle.setParam('node', id);
  }

  /// Everything the guest needs to be driven — see [EmbedderInputRegion] — in
  /// [dpr]: the panel's when it fills the panel, the device's when it is one.
  ///
  /// While [_picking] the guest is given **nothing**: not the click, which
  /// would tap the button you were trying to inspect, and not the hover, which
  /// would light the demo's own hover states underneath the thing you are
  /// trying to see.
  Widget _guestInput(
    GuestSurface surface,
    Widget sizedBox, {
    required bool touch,
  }) {
    // The guest's picture, built once and handed to whichever mode is on. Built
    // per-mode it is easy to pass the placeholder to one of them, which is what
    // happened: arming the picker replaced the demo with an empty box, so the
    // preview vanished the moment you went to point at it.
    var picture = surface.picture();
    return ValueListenableBuilder(
      valueListenable: _picking,
      builder: (context, picking, _) => picking
          ? _pickerInput(context, picture)
          : _demoInput(surface, picture, touch: touch),
    );
  }

  Widget _pickerInput(BuildContext context, Widget picture) {
    return InspectPickRegion(
      // Local coordinates are the guest's own: the box is sized to the guest's
      // logical size in both staging modes, so a point here needs no transform
      // — and neither does the rect that comes back.
      onSweep: (point) => _highlight.value = _session.treeForSelection
          ?.nodeAtPoint(point.dx, point.dy)
          ?.id,
      onClear: () => _highlight.value = null,
      onPick: (point) => unawaited(_pick(context, point)),
      onDisarm: () => _picking.value = false,
      child: _withOverlay(picture),
    );
  }

  Widget _demoInput(
    GuestSurface surface,
    Widget picture, {
    required bool touch,
  }) {
    return ValueListenableBuilder(
      valueListenable: _panning,
      builder: (context, panning, child) => surface.input(
        focusNode: _focusNode,
        touch: touch,
        // Ignored, not handled: an app chord carries on up to whichever
        // `CallbackShortcuts` claims it — this panel's, or the shell's.
        shouldIgnoreKey: _isAppChord,
        // Two things are the stage's and nothing else is. A ⌘-scroll and a pinch
        // magnify, so the demo must not also scroll under them; and a drag that
        // is moving the stage must not also drag in the demo, which it otherwise
        // would — a `Listener` is not a gesture recognizer and never loses an
        // arena, so without this every pan scrolls whatever list it passes over.
        // Everything else still arrives, including the click: a tap moves the
        // stage nowhere, so it never reaches [_PanFlag] at all.
        shouldIgnorePointer: (event) => panning || stageOwnsPointer(event),
        child: child!,
      ),
      child: _withOverlay(picture),
    );
  }

  /// The guest's picture with the highlight drawn over it.
  ///
  /// Inside the texture's own box, which is the whole trick: node rects
  /// are in the guest's logical coordinates and this box *is* the guest's
  /// logical size, so the painter needs no transform — and it inherits the
  /// `FittedBox` and the `DeviceFrame` above it, so the highlight stays put
  /// when the preview is staged as a phone. Drawn over the canvas instead, it
  /// would need the scale, the offset and the frame's own inset, and would be
  /// wrong on every device change until each was found again.
  Widget _withOverlay(Widget picture) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        picture,
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder(
              valueListenable: _highlight,
              builder: (context, hovered, _) {
                // **Hover only, never the selection.** A box that stayed put
                // after you chose something is a box you then have to find a
                // way to dismiss — which is the state this was in, with no way
                // out at all. Chrome draws it while you point and stops when
                // you stop; what a selection leaves behind is a row in the
                // tree, not a rectangle on the picture.
                var node = hovered == null
                    ? null
                    : _session.treeForSelection?.nodeAt(hovered);
                // An offstage node's rect is stale — where it was, the last
                // time it was on a screen — so hovering its row lights the
                // row and leaves the picture alone.
                if (node?.offstage ?? false) node = null;
                return ValueListenableBuilder(
                  valueListenable: _semanticsHighlight,
                  builder: (context, semanticsLit, _) => ValueListenableBuilder(
                    valueListenable: _session.watchedBox,
                    builder: (context, live, _) {
                      // The guest's own last frame, when it is about this
                      // node. The tree's rect is of the build it was read
                      // from, which on anything animating is already wrong —
                      // and a rectangle in the wrong place does not read as
                      // slightly stale, it reads as broken. The node is still
                      // what names the box: a live rect with no node behind
                      // it would be a rectangle labelled nothing. The
                      // elements highlight wins over the semantics one — it
                      // is the one the picker writes, and the two tabs cannot
                      // be hovered at once.
                      var box = live?.id == hovered ? live : null;
                      var (rect, label) = switch ((node, box, semanticsLit)) {
                        (var n?, var b?, _) => (
                          Rect.fromLTWH(b.x, b.y, b.width, b.height),
                          n.type,
                        ),
                        (var n?, null, _) when n.layout != null => (
                          Rect.fromLTWH(
                            n.layout!.x,
                            n.layout!.y,
                            n.layout!.width,
                            n.layout!.height,
                          ),
                          n.type,
                        ),
                        (null, _, var s?) => (s.rect, s.headline),
                        _ => (null, null),
                      };
                      return CustomPaint(
                        painter: NodeHighlightPainter(
                          rect: rect,
                          label: label,
                          color: context.colors.accent,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The controls the entry declared while it built.
///
/// Absent, not empty, when there are none: most demos have no knobs, and a
/// permanent empty drawer is a permanent reminder of a feature you are not
/// using.
class _KnobPanel extends StatelessWidget {
  const _KnobPanel({required this.session});

  final CatalogSession session;

  @override
  Widget build(BuildContext context) {
    if (session.knobs.knobs.isEmpty) {
      return Container(
        color: context.colors.panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          // Says what a knob *is*, because this is the state most entries are
          // in and it is the only moment anybody reads this pane.
          'This entry declares no knobs.\nA demo gets one by asking while it '
          'builds — context.knobs.string("label", "Hello").',
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: context.colors.mut),
        ),
      );
    }
    return Container(
      color: context.colors.panel,
      width: double.infinity,
      // The entry's knobs own `knob.*`, and only this panel. Nested below the
      // level that owns the entry segment, which is what says a knob dies with
      // the entry while an axis does not.
      child: AddressScope(
        namespace: 'knob',
        child: Builder(
          builder: (context) {
            var selections = AddressScope.params(context);
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.md,
              ),
              child: Wrap(
                spacing: FwSpacing.xxl,
                runSpacing: FwSpacing.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var knob in session.knobs.knobs)
                    _Knob(
                      // Keyed by name, so a field keeps its cursor when the
                      // report is read back and the list is rebuilt around it.
                      key: ValueKey(knob.name),
                      knob: knob,
                      selections: selections,
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Knob extends StatelessWidget {
  const _Knob({super.key, required this.knob, required this.selections});

  final KnobDescriptor knob;

  /// What the address asked for. Wins over the guest's confirmation while the
  /// two disagree, which is the whole of the optimistic update — see
  /// [paramDisplayValue]. Nothing is mutated to achieve it.
  final Map<String, String> selections;

  Object? get _value => paramDisplayValue(knob, selections);

  /// Writes the choice into the address, and stops there. The demo is told
  /// because the session is watching the address, not because this told it.
  void _choose(BuildContext context, Object? value) =>
      AddressScope.write(context)
          .setParam(paramKeyFor(knob), paramValueSlug(knob, value));

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.md,
      children: [
        Text(
          knob.name,
          style: context.type.caption.copyWith(
            // Bright when it has been moved, so what you have changed is
            // legible at a glance against what you have not.
            color: _value == knob.defaultValue
                ? context.colors.mut
                : context.colors.ink,
          ),
        ),
        _control(context),
      ],
    );
  }

  Widget _control(BuildContext context) {
    switch (knob.kind) {
      case KnobKind.boolean:
        return _Toggle(
          value: _value == true,
          onChanged: (v) => _choose(context, v),
        );
      case KnobKind.picker:
        return Popover<String?>(
          selected: _value as String?,
          onSelected: (v) => _choose(context, v),
          groups: [
            (
              heading: null,
              items: [
                for (var option in knob.options)
                  (value: option, label: option, detail: ''),
              ],
            ),
          ],
          child: _Field(
            child: Text(
              (_value ?? '—').toString(),
              style: context.type.caption.copyWith(color: context.colors.ink),
            ),
          ),
        );
      case KnobKind.integer || KnobKind.number:
        if (knob.min case var min?) {
          if (knob.max case var max?) return _slider(context, min, max);
        }
        return _NumberField(
          knob: knob,
          value: _value,
          onChanged: (v) => _choose(context, v),
        );
      case KnobKind.string:
        return _StringField(
          knob: knob,
          value: _value,
          onChanged: (v) => _choose(context, v),
        );
    }
  }

  Widget _slider(BuildContext context, num min, num max) {
    var value = (_value as num? ?? min).toDouble().clamp(
      min.toDouble(),
      max.toDouble(),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 132,
          // Without this the slider reserves room for a touch target on each
          // side, and the value beside it reads as belonging to the next knob.
          child: SliderTheme(
            data: const SliderThemeData(padding: EdgeInsets.zero),
            child: Slider(
              value: value,
              min: min.toDouble(),
              max: max.toDouble(),
              // Whole steps for a whole number, so dragging cannot land between
              // two of them.
              divisions: knob.kind == KnobKind.integer
                  ? (max - min).round().clamp(1, 1000)
                  : null,
              onChanged: (v) => _choose(
                context,
                knob.kind == KnobKind.integer ? v.round() : v,
              ),
            ),
          ),
        ),
        const Gap(FwSpacing.md),
        SizedBox(
          width: 26,
          child: Text(
            knob.kind == KnobKind.integer
                ? '${value.round()}'
                : value.toStringAsFixed(1),
            textAlign: TextAlign.right,
            style: context.type.caption.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

/// A boolean, drawn to the same scale as the fields beside it.
///
/// Hand-rolled rather than a [Switch]: the stock one is 52 by 32 and coloured
/// from the Material theme, so in a 36-pixel bar of 24-pixel fields it was both
/// the largest thing on the row and the only thing not using the palette.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Semantics(
      container: true,
      toggled: value,
      // A [Switch] carries these for free; a hand-rolled one has to say so, or
      // the control becomes invisible to everything that is not a pair of eyes.
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          // The visible track is 14 tall; the target is the whole row height,
          // so it can be hit without aiming.
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: SizedBox(
            height: 24,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                width: 26,
                height: 14,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: value ? colors.accent : colors.bg,
                  border: Border.all(
                    color: value ? colors.accent : colors.line,
                  ),
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: value ? colors.panel : colors.mut,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The box every knob control sits in, so a field, a picker and a number all
/// line up.
class _Field extends StatelessWidget {
  const _Field({required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 24,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: child,
    );
  }
}

/// A text knob, applied as you stop typing rather than as you type.
///
/// Every keystroke would be a round trip to the guest and a rebuild of the
/// demo, which is both wasteful and jumpy to read.
class _StringField extends StatefulWidget {
  const _StringField({
    required this.knob,
    required this.value,
    required this.onChanged,
  });

  final KnobDescriptor knob;

  /// What the address asks for, not what the guest last confirmed.
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  State<_StringField> createState() => _StringFieldState();
}

class _StringFieldState extends State<_StringField> {
  late final _controller = TextEditingController(text: '${widget.value ?? ''}');
  final _focus = FocusNode();
  Timer? _debounce;

  @override
  void didUpdateWidget(_StringField old) {
    super.didUpdateWidget(old);
    // Only when the change came from somewhere else — writing back into a field
    // that has the caret would fight the cursor. Focus rather than the debounce
    // timer: between a debounce firing and the guest answering there is a
    // stretch where no timer is pending and the user is still typing.
    var value = '${widget.value ?? ''}';
    if (!_focus.hasFocus && value != _controller.text) {
      _controller.text = value;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Field(
      width: 140,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        style: context.type.caption.copyWith(color: context.colors.ink),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
        onChanged: (value) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), () {
            _debounce = null;
            widget.onChanged(value);
          });
        },
      ),
    );
  }
}

/// A number without bounds, which is a field rather than a slider — there is
/// nothing to slide between.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.knob,
    required this.value,
    required this.onChanged,
  });

  final KnobDescriptor knob;

  /// What the address asks for, not what the guest last confirmed.
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  // Owned rather than built: a controller made in `build` is a new one on every
  // rebuild, and the panel rebuilds whenever any knob moves — so typing here
  // while a slider elsewhere settles would lose what you had typed.
  late final _controller = TextEditingController(text: '${widget.value ?? ''}');
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // Never while it has the caret: the value on screen is then the user's,
    // and the guest's is what they are in the middle of replacing.
    var value = '${widget.value ?? ''}';
    if (!_focus.hasFocus && value != _controller.text) {
      _controller.text = value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Field(
      width: 80,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        style: context.type.caption.copyWith(color: context.colors.ink),
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: _apply,
        // Also on the way out, so clicking away from a number you have typed
        // applies it rather than quietly reverting it on the next rebuild.
        onTapOutside: (_) {
          _focus.unfocus();
          _apply(_controller.text);
        },
      ),
    );
  }

  void _apply(String text) {
    var parsed = num.tryParse(text);
    if (parsed == null) return;
    widget.onChanged(
      widget.knob.kind == KnobKind.integer ? parsed.round() : parsed,
    );
  }
}

/// What the guest is being rendered as, and nothing about which entry it is —
/// that is the list's job, and the status bar's.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.session,
    required this.captureButton,
    required this.highlight,
    required this.zoom,
    required this.onResetZoom,
  });

  final CatalogSession session;

  /// Owned by the page, which routes ⌘⇧C through it.
  final GlobalKey<CaptureButtonState> captureButton;

  /// The overlay's hover notifier — the capture menu lights the node its
  /// cropped entries would photograph.
  final ValueNotifier<String?> highlight;

  /// The stage's transform, read for its scale — owned by the page, because it
  /// has to outlive a compile error replacing the canvas under it.
  final TransformationController zoom;

  final VoidCallback onResetZoom;

  @override
  Widget build(BuildContext context) {
    var staging = session.staging;
    // Upright: the picker finds its selection by identity in its own list, and
    // a turned device is a different object that matches nothing there.
    var device = _deviceOf(context, session);
    var orientation = _orientationOf(context, session);
    return Container(
      color: context.colors.panel,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
      height: 36,
      child: Row(
        spacing: FwSpacing.md,
        children: [
          StagedDevice(
            device: device,
            orientation: orientation,
            declared: _canvasOf(session)?.devices ?? const [],
            staging: staging,
            keyboard: _keyboardOf(context, session),
            // The guest's own answer, not the mode's: in `auto` the app is
            // what decides, and the bar saying otherwise would be a control
            // describing its own setting rather than the picture.
            keyboardUp: session.keyboard?.up ?? false,
          ),
          if (device != null)
            Text(
              // The *turned* size: the one number on the bar that says whether
              // the axis took, and the cheapest possible proof of it.
              describeDevice(device.oriented(orientation)),
              style: context.type.caption.copyWith(fontFamily: 'monospace'),
            ),
          // The shell's own switches, after what the guest is *staged* as. A
          // different order would read as if the flavor were a property of the
          // phone rather than of the app inside it.
          //
          // Scrolling rather than wrapping or shrinking: the bar is one row
          // tall by design, a project may declare more axes than fit beside a
          // device name, and the alternative is that the last one silently
          // pushes the capture button off the end.
          Expanded(
            // The shell's axes own `axis.*`, and only this subtree. Nested
            // rather than written as a full key so the controls below say
            // `theme`, not `axis.theme` — and so the device picker beside them
            // keeps reading flutterware's own un-namespaced parameters.
            child: AddressScope(
              namespace: 'axis',
              // Below the scope, so `params` is `axis.*` rather than
              // flutterware's own un-namespaced ones.
              child: Builder(
                builder: (context) {
                  var selections = AddressScope.params(context);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      spacing: FwSpacing.lg,
                      children: [
                        for (var axis in session.axes.axes)
                          _Axis(
                            // Keyed by name so a picker keeps its place when
                            // the report is read back and the row is rebuilt
                            // around it.
                            key: ValueKey(axis.name),
                            axis: axis,
                            selections: selections,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: zoom,
            builder: (context, matrix, _) => ZoomControl(
              scale: matrix.getMaxScaleOnAxis(),
              atRest: isAtRest(matrix),
              onReset: onResetZoom,
            ),
          ),
          _CaptureButtons(
            session: session,
            captureButton: captureButton,
            highlight: highlight,
          ),
        ],
      ),
    );
  }
}

/// The live guest's next frame, cropped to [node]'s box when one is passed.
///
/// Null when there is no guest to ask — the panel is compiling, or the last
/// build failed — which is a refusal rather than an error: there is nothing on
/// screen to be a picture of.
Future<Uint8List?> _capturePreview(
  CatalogSession session, {
  InspectNode? node,
}) async {
  var surface = session.surface;
  if (surface == null || surface.phase != EmbeddedEnginePhase.running) {
    return null;
  }
  return surface.capturePng(
    crop: node?.layout,
    // A crop arrives in the guest's logical coordinates; its pixels are in
    // whatever ratio the guest is rendering at — the surface's, not a staged
    // device's, because with no device staged the guest renders at the
    // panel's ratio and a retina display makes that 2.
    pixelRatio: surface.pixelRatio,
  );
}

/// The node the Elements tab has selected, when its tree still describes what
/// is on screen — a rect read before the last switch would crop this frame to a
/// box measured in another one.
///
/// `node` is named as `inspect`'s rather than read plainly, because every caller
/// is in the top bar: one level *above* the scope that owns it, where a plain
/// read asks for an un-namespaced `node` nobody writes. The buttons then
/// photographed the whole frame however the tree was set — the same boundary
/// [_deviceOf] falls off in the other direction.
InspectNode? _croppedNode(BuildContext context, CatalogSession session) {
  var id = AddressScope.params(context, namespace: _inspectNamespace)['node'];
  return id == null ? null : session.treeForSelection?.nodeAt(id);
}

/// Copy the preview to the clipboard, or save it to a file.
///
/// These photograph the **live** guest, which is why they are here rather than
/// being the `screenshot` action with a button on it. What they capture is the
/// demo as you left it — the dropdown you opened, the tab you switched to, the
/// row you scrolled to — and no fresh render performs your clicks. `fw` cannot
/// offer the same thing and deliberately refuses to pretend otherwise: an
/// attached session gives it a VM service and no frames. The panel is the only
/// place that holds the socket the picture comes over.
///
/// The click always takes the whole frame. Capturing the node selected in the
/// Elements tab is the *menu's* — an entry named after the widget it would
/// crop to, lighting that node's box on the preview while you point at it.
/// It used to be a silent mode: with a node selected, the same-looking button
/// photographed the crop, and the only tell was the tooltip.
class _CaptureButtons extends StatelessWidget {
  const _CaptureButtons({
    required this.session,
    required this.captureButton,
    required this.highlight,
  });

  final CatalogSession session;
  final GlobalKey<CaptureButtonState> captureButton;
  final ValueNotifier<String?> highlight;

  /// Named after what it is a picture *of*, so a directory of these is still
  /// readable a week later. Matches what the `screenshot` action derives.
  String _suggestedName({InspectNode? node}) {
    var entry = session.selected ?? session.active;
    var base = entry == null
        ? 'catalog'
        : entry.id.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
    return node == null ? '$base.png' : '$base-${node.type}.png';
  }

  @override
  Widget build(BuildContext context) {
    // A running guest is not enough: with nothing selected it is holding the
    // entry it was warmed on, which the stage is deliberately not showing, and
    // a capture would hand back a correct picture of something that was never
    // on screen.
    var running =
        session.surface?.phase == EmbeddedEnginePhase.running &&
        session.selected != null;
    var node = _croppedNode(context, session);
    return CaptureButton(
      key: captureButton,
      enabled: running,
      shortcutHint: '⌘⇧C',
      primary: CaptureTarget(
        label: 'the preview',
        capture: () => _capturePreview(session),
        suggestedName: _suggestedName,
      ),
      secondary: [
        if (node != null)
          CaptureTarget(
            // The widget's own name, because the entry is the explanation:
            // "just Card" says what the feature does better than "the
            // selected node" ever did.
            label: 'just ${node.type}',
            capture: () => _capturePreview(session, node: node),
            suggestedName: () => _suggestedName(node: node),
            // Cropped out of the real composited frame rather than
            // re-rendered alone — the widget among its surroundings. The
            // hover shows exactly which box that will be.
            onHover: (hovered) {
              if (hovered) {
                highlight.value = node.id;
              } else if (highlight.value == node.id) {
                highlight.value = null;
              }
            },
          ),
      ],
    );
  }
}

/// One of the shell's axes, in the top bar.
///
/// Labelled unconditionally, unlike a knob, which is written as
/// `name  [control]` in a panel of its own. Up here an axis sits beside a
/// device picker and a frame toggle, and an unlabelled `staging` would read as
/// something about the phone.
class _Axis extends StatelessWidget {
  const _Axis({super.key, required this.axis, required this.selections});

  final KnobDescriptor axis;

  /// What the address asked for, which wins over the guest's own report while
  /// the two disagree — see [axisDisplayValue]. That is all the optimistic
  /// update amounts to, and it mutates nothing.
  final Map<String, String> selections;

  /// Writes the choice into the address, and stops there. The guest is told
  /// because the session is watching the address, not because this told it.
  void _choose(BuildContext context, Object? value) =>
      AddressScope.write(context)
          .setParam(paramKeyFor(axis), paramValueSlug(axis, value));

  @override
  Widget build(BuildContext context) {
    var value = paramDisplayValue(axis, selections);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.sm,
      children: [
        Text(
          axis.name,
          style: context.type.caption.copyWith(
            // Bright once it is off its default, so what you have changed
            // about the whole catalog is legible without reading the values.
            color: value == axis.defaultValue
                ? context.colors.mut
                : context.colors.ink,
          ),
        ),
        if (axis.kind == KnobKind.boolean)
          _Toggle(value: value == true, onChanged: (v) => _choose(context, v))
        else
          Popover<String?>(
            selected: value as String?,
            onSelected: (v) => _choose(context, v),
            groups: [
              (
                heading: null,
                items: [
                  for (var option in axis.options)
                    (
                      value: option,
                      label: option,
                      detail: option == axis.defaultValue ? 'default' : '',
                    ),
                ],
              ),
            ],
            child: _Field(
              child: Text(
                (value ?? '—').toString(),
                style: context.type.caption.copyWith(color: context.colors.ink),
              ),
            ),
          ),
      ],
    );
  }
}

/// The entry browser: a filter, then the tree.
class _EntryList extends StatefulWidget {
  const _EntryList({
    required this.session,
    required this.thumbnails,
    required this.onGoTo,
    this.changes,
  });

  final CatalogSession session;
  final PreviewThumbnails? thumbnails;

  /// What the branch changed, for the tint — see [CatalogView.entryChanges].
  final EntryChanges? changes;

  /// Show this much of the catalog — a folder's path, or null for all of it.
  final void Function(String? scope) onGoTo;

  @override
  State<_EntryList> createState() => _EntryListState();
}

class _EntryListState extends State<_EntryList> {
  /// The popover, in the **root** overlay: it has to be able to leave the
  /// 260-pixel column it is anchored in, which is the whole point of it.
  final _popover = OverlayPortalController();

  /// What the popover is showing, which lags [CatalogBrowsing.hovering] by
  /// nothing — it is set from the same notification.
  CatalogEntry? _showing;

  CatalogSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.browsing.addListener(_onBrowsing);
  }

  @override
  void dispose() {
    session.browsing.removeListener(_onBrowsing);
    super.dispose();
  }

  /// A folder row: show that folder, and open it in the tree.
  ///
  /// **Selecting, not toggling.** The row and the chevron do one thing each —
  /// the row picks what the pane shows, the chevron folds — because a row that
  /// did both meant one click with two results and no way to ask for either
  /// alone. Opening the branch is not the toggle in disguise: it is a
  /// consequence of arriving somewhere, clicking the same folder again does not
  /// undo it, and it is what keeps switching between a demo's siblings to one
  /// click while the stage has one of them up.
  void _showBranch(CatalogBranch branch) {
    session.browsing.reveal([branch.id]);
    widget.onGoTo(branch.scopePath);
  }

  /// Toggled from the notification rather than read during a build: showing an
  /// overlay is a side effect, and a build is not allowed to have one.
  void _onBrowsing() {
    var hovering = session.browsing.hovering;
    if (hovering?.id == _showing?.id) return;
    setState(() => _showing = hovering);
    if (hovering == null) {
      _popover.hide();
      return;
    }
    widget.thumbnails?.want(hovering);
    _popover.show();
  }

  @override
  Widget build(BuildContext context) {
    var browsing = session.browsing;
    // Built from everything discovered, broken included: an entry you are
    // midway through fixing keeps its place, and selecting it is the retry.
    var whole = buildCatalogTree(session.allEntries);
    // Whether this catalog is one you arrive scrolling, answered once — from
    // the whole tree, never the filtered one, since a filter is a question
    // rather than the shape of the catalog.
    if (browsing.needsFoldDecision) {
      browsing.foldIfCrowded(catalogTreeRows(whole), allBranches(whole));
    }
    var changes = widget.changes;
    // The changed-only restriction first, then the text filter over what is
    // left. Off — or with nothing to restrict to, since the toggle disables
    // itself then — the tree is the whole one.
    // Two different questions, kept apart: narrowing is a browsing mode that
    // leaves folding to the person browsing, filtering is a typed query
    // whose answer is held open for as long as it is typed.
    var narrowing = browsing.changedOnly && changes != null && !changes.isEmpty;
    var narrowed = narrowing
        ? restrictCatalogTree(whole, changes.ids.toSet())
        : whole;
    var tree = filterCatalogTree(narrowed, browsing.filter);
    var filtering = browsing.filter.trim().isNotEmpty;
    // Whatever is selected is *made* visible, once, when it arrives — rather
    // than held open for as long as it is selected, which is what made the
    // folder around it refuse to close. See [CatalogBrowsing.revealSelection].
    // After the frame, because opening a folder notifies and this is a build.
    var selectedId = session.selected?.id;
    if (browsing.needsReveal(selectedId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          browsing.revealSelection(selectedId, branchesTo(whole, selectedId));
        }
      });
    }
    var rows = <Widget>[];
    void walk(List<CatalogNode> nodes, int depth) {
      for (var node in nodes) {
        switch (node) {
          case CatalogLeaf(:var entry):
            rows.add(
              _LeafRow(
                entry: entry,
                depth: depth,
                broken: session.compileErrorFor(entry),
                change: changes?[entry.id],
                selected: entry.id == session.selected?.id,
                highlight: browsing.filter.trim(),
                // **Live before the guest is.** The list now arrives off the
                // plugin's scan rather than off the daemon, which is seconds
                // earlier — and a row you can read but not click, with nothing
                // saying why, is worse than no row. So a click during the boot
                // is recorded as a *request*, which is what [wantedEntryId]
                // exists for and what a search hit has always done: the session
                // picks it up when it lands, and if the click beat the daemon
                // the guest boots straight onto it.
                onTap: () {
                  // Before the switch, so the card is gone by the frame the
                  // selection moves in.
                  browsing.endHover();
                  if (session.phase == CatalogSessionPhase.ready) {
                    unawaited(session.switchTo(entry));
                  } else {
                    session.wantedEntryId = entry.id;
                  }
                },
                // The popover carries the file and the symbol now, and two
                // things arriving on one hover is one too many. The selected
                // row shows no popover, so it keeps its tooltip.
                describe:
                    !browsing.previewOnHover ||
                    entry.id == session.selected?.id,
                onHover: browsing.hover,
              ),
            );
          case CatalogBranch(:var children):
            // A filtered tree is already the answer to a question; folding
            // part of it away would only hide what was asked for.
            var open = filtering || browsing.isOpen(node.id);
            rows.add(
              _BranchRow(
                branch: node,
                depth: depth,
                open: open,
                highlight: browsing.filter.trim(),
                changedBelow: open
                    ? null
                    : strongestChange(
                        changes,
                        node.entries.map((entry) => entry.id),
                      ),
                // Marked when the pane beside it is this folder — never while
                // a demo is up, where the row worth marking is the entry's.
                showing:
                    session.selected == null &&
                    browsing.scope != null &&
                    node.scopePath == browsing.scope,
                onTap: () => _showBranch(node),
                // A filtered tree is already the answer to a question; folding
                // part of it away would only hide what was asked for.
                onToggleFold: filtering ? null : () => browsing.toggle(node.id),
              ),
            );
            if (open) walk(children, depth + 1);
        }
      }
    }

    walk(tree, 0);

    return MouseRegion(
      // The harness is started when the hand arrives rather than when it
      // settles: a cold catalog is a compile of every entry, and those seconds
      // are the difference between a popover that is there and one you wait
      // for.
      onEnter: (_) => widget.thumbnails?.warmUp(session.selected),
      // A backstop for the rows' own exits: a pointer that leaves fast, or
      // over a row that scrolled out from under it, can leave the list without
      // any row seeing it go — and a popover nobody closed hangs over the
      // canvas until something else moves.
      onExit: (_) => browsing.hover(null),
      child: OverlayPortal(
        controller: _popover,
        // The root one: a 260-pixel column is exactly what this has to be able
        // to leave.
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: (context) {
          var entry = _showing;
          var at = browsing.hoveringAt;
          var thumbnails = widget.thumbnails;
          if (entry == null || at == null || thumbnails == null) {
            return const SizedBox.shrink();
          }
          // Rebuilt when the store answers, which for a cold catalog is tens
          // of seconds after the popover opened — the wait is the popover's to
          // show, not a reason to withhold it.
          return ListenableBuilder(
            listenable: thumbnails,
            builder: (context, _) => PreviewPopover(
              entry: entry,
              anchor: at,
              thumbnail: thumbnails.of(entry),
              change: widget.changes?[entry.id],
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FilterField(
              session: session,
              browsing: browsing,
              tree: tree,
              changes: changes,
            ),
            const Divider(height: 1),
            // **The way out, and the only row that never scrolls away.** It is
            // above the list rather than the first thing in it because an
            // unfolded catalog is hundreds of rows long, and a way out you have
            // to scroll to find is the state narrowing had the first time
            // round: something you could get into and then had to work out how
            // to leave. It carries the total for the same reason a folded
            // folder carries its count.
            //
            // It is also the whole of the way back off a demo, along with the
            // folder rows below it. There is no separate back control: every
            // destination is one of these rows, so leaving a demo is choosing
            // where to go rather than undoing something.
            _AllRow(
              count: session.allEntries.length,
              selected: session.selected == null && browsing.scope == null,
              onTap: () => widget.onGoTo(null),
            ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? _nothingToList(
                      session,
                      filtering: filtering,
                      narrowing: narrowing,
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(
                        vertical: FwSpacing.xs,
                      ),
                      children: rows,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether the stage may draw the guest's picture this frame.
///
/// The guest paints one texture and switches which demo is in it, so between
/// the click and the guest's next frame that texture holds the *previous*
/// demo. Whether showing it is right depends on where you came from, and only
/// on that:
///
/// - Coming off the catalog it is a demo you were not looking at and did not
///   ask for. It appears for ~35–70ms and is replaced, which reads as a
///   glitch. Hold the catalog instead.
/// - Coming off another demo it is the demo you *were* looking at, and holding
///   it is what makes a warm switch look like one frame rather than a blink.
///   Hiding it here would be a flash on every click — the same reason
///   `CatalogSession.compilingSwitch` covers only the slow path.
///
/// So the answer is not about the delay, which is why nothing here is timed.
bool stageHoldsGuest({
  required String? guestEntryId,
  required String? selectedEntryId,
  required bool alreadyHolding,
}) {
  // Nothing selected: the catalog is what is on the stage, whatever the guest
  // happens to be holding.
  if (selectedEntryId == null) return false;
  // The guest is showing what was asked for. Always drawable, and this is what
  // ends the wait.
  if (guestEntryId == selectedEntryId) return true;
  // Stale, so it comes down to what the stage was already doing.
  return alreadyHolding;
}

/// Shows [scope] — a folder's path, or null for the whole index.
///
/// Through the address rather than by setting the field, so that a folder is a
/// place you can link to, come back to and go up from, and so the panel's own
/// reader stays the single thing deciding what the state is. Writing a scope
/// also gives up the stage: an address names one place, and this one names a
/// part of the catalog rather than a demo.
void _goTo(BuildContext context, CatalogSession session, String? scope) {
  var package = catalogPlace(AddressScope.segments(context))?.package;
  if (package == null) return;
  AddressScope.of(context).setSegments(catalogSegments(package, scope));
}

/// The catalog as pictures, for a stage with nothing on it.
///
/// **The tree picks what this shows.** They are not two lists of the same thing:
/// one is the selector, the other is what was selected — the folder, or all of
/// them. Nothing here scrolls itself and nothing tracks the scroll, because
/// moving around the catalog is a click in the tree rather than a journey down
/// a page.
///
/// Which is also why the sheet has no filter of its own — it draws the same
/// filtered tree the list beside it does, so typing in one place narrows both.
///
/// **A page filling in says so with its own tiles, and with nothing else.** The
/// strip above the sheet is for the work that has to happen before a picture
/// can exist at all — the harness compile, which is tens of seconds of a blank
/// page. Rendering is not that: every tile that is waiting already shimmers,
/// and a counted "Rendering the previews · 1 / 55" over the top of a hundred
/// and fifty of them says the same thing a second time, in chrome that appears
/// and disappears on every hover.
class _Landing extends StatelessWidget {
  const _Landing({required this.session, required this.thumbnails});

  final CatalogSession session;
  final PreviewThumbnails thumbnails;

  /// The screen an entry opens on, which is what its tile reserves room for.
  ///
  /// A desktop canvas stages nothing — `PreviewCanvas.defaultDevice` is null
  /// for one, because a window has no true size — so those entries get the
  /// plain rectangle the harness actually frames them at rather than a guess.
  Size _screenOf(CatalogEntry entry) {
    var device = session.canvasOf(entry)?.defaultDevice;
    var screen = device == null
        ? CaptureViewport.panel
        : CaptureViewport.of(device);
    return Size(screen.width.toDouble(), screen.height.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    var browsing = session.browsing;
    return ListenableBuilder(
      listenable: Listenable.merge([thumbnails, browsing]),
      builder: (context, _) {
        var scope = browsing.scope;
        var tree = filterCatalogTree(
          buildCatalogTree([
            for (var entry in session.allEntries)
              if (scopeCovers(scope, entry.path)) entry,
          ]),
          browsing.filter,
        );
        var sections = previewSheetSections(
          tree,
          screenOf: _screenOf,
          rootLabel: scopeHeading(scope),
        );
        if (sections.isEmpty) {
          return _nothingToList(
            session,
            filtering: browsing.filter.trim().isNotEmpty,
          );
        }
        return Column(
          children: [
            // **Above the sheet, never over it.** The sheet filling in is the
            // thing being waited for, and covering it to report on itself is
            // the one arrangement that makes the filling invisible.
            StartupStrip(progress: session.startup),
            Expanded(child: _sheet(sections)),
          ],
        );
      },
    );
  }

  Widget _sheet(List<PreviewSheetSection> sections) {
    return PreviewSheet(
      sections: sections,
      screenOf: _screenOf,
      bytesOf: thumbnails.bytesOf,
      // Marked while a switch off the catalog is in flight, so the click
      // is not silent for the frames the guest takes to catch up. A live
      // selection, not a memory of one.
      selectedId: session.selected?.id,
      problemOf: (entry) => switch (thumbnails.of(entry)) {
        ThumbnailFailed(:var reason) => reason,
        _ => session.compileErrorFor(entry),
      },
      // The page renders itself in the order it is read: the grid builds
      // the tiles near the viewport and this hands exactly those back, so
      // scrolling changes what is being rendered rather than queueing
      // behind a hundred and fifty entries nobody is looking at.
      onVisible: thumbnails.wantAll,
      onUndecodable: thumbnails.discard,
      // One ticker for the sheet, and it runs only while something is being
      // rendered — see [PreviewSheet.animate].
      animate: thumbnails.busy,
      waitOf: _waitOf,
      onTap: (entry) {
        session.browsing.endHover();
        if (session.phase == CatalogSessionPhase.ready) {
          unawaited(session.switchTo(entry));
        } else {
          session.wantedEntryId = entry.id;
        }
      },
    );
  }

  /// What a tile with no picture is waiting for.
  ///
  /// The store already tells the two waits apart, and they are not the same
  /// wait: a cold harness compiles the whole catalog and takes tens of seconds,
  /// where a warm one is a message and a frame.
  PreviewTileWait? _waitOf(CatalogEntry entry) {
    if (thumbnails.rendering == entry.id) return PreviewTileWait.rendering;
    return switch (thumbnails.of(entry)) {
      ThumbnailPending(:var compiling) =>
        compiling ? PreviewTileWait.compiling : PreviewTileWait.queued,
      _ => null,
    };
  }
}

/// What stands in for the tree when it has no rows.
///
/// Three answers, and the third is the one that used to be missing: "No
/// entries" is a claim about the package, so it waits until something has
/// actually looked. A session seeded with its plugin's scan has the list before
/// its first frame; one that was not — the standalone entry point, the motion
/// panel — is still waiting on the daemon, and used to spend that waiting
/// saying nobody had written a demo.
Widget _nothingToList(
  CatalogSession session, {
  required bool filtering,
  bool narrowing = false,
}) {
  if (filtering) {
    return EmptyState(
      icon: Icons.search_off_outlined,
      title: 'Nothing matches',
      message: narrowing
          ? 'No demo this branch changed has a name like that.'
          : 'No demo in this package has a name like that.',
    );
  }
  if (narrowing) {
    return const EmptyState(
      icon: Icons.difference_outlined,
      title: 'Nothing changed here',
      message: 'No demo in this package changed on this branch.',
    );
  }
  if (session.phase == CatalogSessionPhase.starting) {
    return const LoadingState(title: 'Looking for demos…');
  }
  return const EmptyState(
    icon: Icons.widgets_outlined,
    title: 'No entries',
    message: 'A demo is a top-level function marked @Preview.',
  );
}

/// Indent for [depth], plus the width a branch spends on its chevron so that
/// leaves and folders at the same level start at the same place.
EdgeInsets _rowPadding(int depth) =>
    EdgeInsets.only(left: FwSpacing.md + depth * 14.0, right: FwSpacing.md);

/// The whole catalog, and the way out of a folder.
class _AllRow extends StatelessWidget {
  const _AllRow({
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? colors.accentSoft : null,
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.md,
          FwSpacing.xs,
          FwSpacing.md,
          FwSpacing.xs,
        ),
        child: SizedBox(
          height: 26,
          child: Row(
            children: [
              Icon(
                Icons.grid_view_outlined,
                size: FwIconSize.sm,
                color: selected ? colors.accentDark : colors.mut,
              ),
              const Gap(FwSpacing.xs),
              Expanded(
                child: Text(
                  'All demos',
                  style: context.type.caption.copyWith(
                    color: selected ? colors.accentDark : colors.ink2,
                  ),
                ),
              ),
              Text(
                '$count',
                style: context.type.micro.copyWith(color: colors.mut2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BranchRow extends StatelessWidget {
  const _BranchRow({
    required this.branch,
    required this.depth,
    required this.open,
    required this.highlight,
    required this.showing,
    required this.onTap,
    required this.onToggleFold,
    this.changedBelow,
  });

  final CatalogBranch branch;
  final int depth;
  final bool open;

  /// The strongest change folded away under this row, or null. Only asked
  /// for while closed: open, the rows themselves say it.
  final EntryChangeKind? changedBelow;

  /// Whether this folder is what the pane beside the tree is showing.
  final bool showing;

  /// What the filter is showing this row for, marked in the label.
  final String highlight;

  /// Show this folder. The row's own job, and the reason folding had to move
  /// off it.
  final VoidCallback? onTap;

  /// Fold this folder away, or open it. The chevron's job and nothing else's.
  ///
  /// A smaller target than the row it used to have, which is the price of the
  /// row meaning one thing. It is affordable because folding stopped being how
  /// you look inside a folder: the pane does that, and the filter finds by name
  /// — what is left for the chevron is tidying a tree you are done with.
  final VoidCallback? onToggleFold;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // [FwTreeRow] rather than a row of its own. What is shared is the contract
    // the two comments above state — the row selects, the chevron folds — and
    // it is shared because the asset tree needed the same rule and got it
    // wrong by writing it a second time. The metrics stay this rail's: a
    // catalog holds hundreds of entries and is read by scanning.
    return FwTreeRow(
      depth: depth,
      density: TreeRowDensity.dense,
      open: open,
      selected: showing,
      onTap: onTap,
      onToggleFold: onToggleFold,
      label: _Marked(
        text: branch.label,
        mark: highlight,
        style: context.type.caption.copyWith(
          color: showing ? colors.accentDark : colors.ink2,
        ),
      ),
      trailing: [
        if (changedBelow case var kind?) ...[
          const Gap(FwSpacing.xs),
          ChangeDot(kind),
        ],
        if (!open) ...[
          const Gap(FwSpacing.xs),
          Text(
            '${branch.entries.length}',
            style: context.type.micro.copyWith(color: colors.mut2),
          ),
        ],
      ],
    );
  }
}

class _LeafRow extends StatelessWidget {
  const _LeafRow({
    required this.entry,
    required this.depth,
    required this.broken,
    required this.selected,
    required this.highlight,
    required this.onTap,
    required this.describe,
    required this.onHover,
    this.change,
  });

  final CatalogEntry entry;
  final int depth;

  /// How the branch touched this entry, or null. Tints the name — a broken
  /// entry's red still wins, since it is the thing to act on.
  final EntryChange? change;

  /// What the filter is showing this row for, marked in the name.
  final String highlight;

  /// The compiler's complaint, or null when the entry builds.
  final String? broken;
  final bool selected;

  final VoidCallback? onTap;

  /// Whether the row still says what it is in a tooltip. Off while the popover
  /// is doing it, which it does better and sooner.
  final bool describe;

  /// The pointer arriving on this row — with where the row is, so a popover
  /// can point at it — and leaving it.
  final void Function(CatalogEntry?, {Rect? at}) onHover;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = broken != null
        ? colors.red
        : changeInk(context, change?.kind) ?? colors.ink;
    return MouseRegion(
      // Its own box, read here rather than tracked: this fires once when the
      // pointer arrives, and a row that reported its rectangle on every build
      // would be doing it forty times for a list nobody is pointing at.
      //
      // **Nothing for the row already selected.** Its picture is the canvas,
      // full size, a few hundred pixels away — a second copy of it under the
      // pointer says nothing and covers something. Reported as *leaving*
      // rather than ignored, so arriving here from a neighbouring row closes
      // that row's card instead of stranding it.
      onEnter: (_) => onHover(selected ? null : entry, at: _boxOf(context)),
      onExit: (_) => onHover(null),
      child: Tooltip(
        // One line per entry leaves no room for the file, and the file is often
        // what you remember it by. Empty is a tooltip that never shows.
        // The change sentence rides along with the file: when the popover
        // is doing the describing it carries the sentence too, so the row
        // never grows a second surface for it.
        message: describe
            ? [
                '${entry.path} · ${entry.symbol}',
                if (change case var it?) it.why,
              ].join('\n')
            : '',
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          onTap: onTap,
          // A line down the leading edge rather than a second fill: a peek is
          // transient, and a fill that came and went under the pointer would
          // be the list flickering as you read it. Outside the row's own
          child: Container(
            color: selected ? colors.accentSoft : null,
            padding: _rowPadding(depth),
            child: SizedBox(
              height: 26,
              child: Row(
                children: [
                  // The chevron column a branch occupies, so a leaf beside a
                  // folder is indented to match rather than sitting under it.
                  const SizedBox(width: 14 + FwSpacing.xs),
                  Expanded(
                    child: _Marked(
                      text: entry.name,
                      mark: highlight,
                      style: context.type.bodySmall.copyWith(color: color),
                    ),
                  ),
                  if (change?.kind == EntryChangeKind.reached) ...[
                    const Gap(FwSpacing.xs),
                    const ChangeDot(EntryChangeKind.reached),
                  ],
                  if (broken != null) ...[
                    const Gap(FwSpacing.xs),
                    Icon(
                      Icons.error_outline,
                      size: FwIconSize.sm,
                      color: colors.red,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where [context]'s render object is on screen, or null before it has one.
Rect? _boxOf(BuildContext context) {
  var box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// [text], with every occurrence of [mark] struck through with a highlighter.
///
/// A filtered list otherwise makes you find, in every row, the thing you just
/// typed. A row with no mark on it has answered too: it matched on its file or
/// its symbol, neither of which fits on the row.
class _Marked extends StatelessWidget {
  const _Marked({required this.text, required this.mark, required this.style});

  final String text;
  final String mark;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    var haystack = text.toLowerCase();
    var needle = mark.toLowerCase();
    if (needle.isEmpty || !haystack.contains(needle)) {
      return Text(text, overflow: TextOverflow.ellipsis, style: style);
    }

    var marked = style.copyWith(
      // Amber rather than a raw yellow, and see-through, so it reads as a
      // highlighter over the row instead of a second background colour.
      backgroundColor: context.colors.amber.withValues(alpha: 0.35),
      color: context.colors.ink,
    );
    var spans = <TextSpan>[];
    var at = 0;
    while (true) {
      var found = haystack.indexOf(needle, at);
      if (found < 0) {
        spans.add(TextSpan(text: text.substring(at)));
        break;
      }
      if (found > at) spans.add(TextSpan(text: text.substring(at, found)));
      at = found + needle.length;
      spans.add(TextSpan(text: text.substring(found, at), style: marked));
    }
    return Text.rich(
      TextSpan(children: spans),
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

class _FilterField extends StatefulWidget {
  const _FilterField({
    required this.session,
    required this.browsing,
    required this.tree,
    this.changes,
  });

  /// What the branch changed, for the changed-only toggle.
  final EntryChanges? changes;

  /// Only for the hover-preview switch, which has to be able to put back what
  /// a peek replaced when it is turned off.
  final CatalogSession session;

  final CatalogBrowsing browsing;

  /// What "collapse all" would have to name.
  final List<CatalogNode> tree;

  @override
  State<_FilterField> createState() => _FilterFieldState();
}

/// One size for both of the field's icon slots, filled or not.
const _iconSlot = BoxConstraints.tightFor(width: 24, height: 22);

/// Says work is happening, but only once that is news.
///
/// A switch is 90ms. Anything that appears and disappears inside that is a
/// flash on every click, which reads as a fault rather than as progress — so
/// the dot waits out the common case and fades in only for the work you would
/// otherwise wonder about. Its slot is always there, so nothing moves either
/// way.
class BusyDot extends StatefulWidget {
  const BusyDot({super.key, required this.busy});

  /// What the session is doing, or null when it is idle.
  final String? busy;

  /// Longer than a warm switch, shorter than a noticeable wait.
  ///
  /// The session's own floor, not a second one that happens to agree with it:
  /// two clocks over the same event drift the moment either is tuned.
  static const appearsAfter = CatalogSession.busyAppearsAfter;

  @override
  State<BusyDot> createState() => _BusyDotState();
}

class _BusyDotState extends State<BusyDot> {
  Timer? _timer;
  var _shown = false;

  @override
  void didUpdateWidget(BusyDot old) {
    super.didUpdateWidget(old);
    if (widget.busy == old.busy) return;
    _timer?.cancel();
    if (widget.busy == null) {
      setState(() => _shown = false);
    } else {
      _timer = Timer(BusyDot.appearsAfter, () {
        if (mounted) setState(() => _shown = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var dot = AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
    return SizedBox(
      width: 8,
      height: 8,
      child: widget.busy == null
          ? dot
          : Tooltip(message: widget.busy!, child: dot),
    );
  }
}

class _FilterFieldState extends State<_FilterField> {
  late final _controller = TextEditingController(
    // Seeded rather than empty: the panel is rebuilt from scratch every time
    // you come back to it, and a filter that clears itself is a filter you
    // stop trusting.
    text: widget.browsing.filter,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 28,
              child: TextField(
                controller: _controller,
                style: context.type.caption.copyWith(color: colors.ink),
                onChanged: (value) => widget.browsing.filter = value,
                decoration: InputDecoration(
                  hintText: 'Filter',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: FwSpacing.md,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: FwIconSize.sm,
                    color: colors.mut2,
                  ),
                  // Both slots are the same size whether or not they hold
                  // anything. An `InputDecorator` sizes itself around its
                  // icons, so a clear button that comes and goes with the text
                  // takes the field's height with it.
                  prefixIconConstraints: _iconSlot,
                  suffixIconConstraints: _iconSlot,
                  suffixIcon: _controller.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          icon: Icon(
                            Icons.close,
                            size: FwIconSize.sm,
                            color: colors.mut2,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: _iconSlot,
                          onPressed: () {
                            _controller.clear();
                            widget.browsing.filter = '';
                          },
                        ),
                ),
              ),
            ),
          ),
          const Gap(FwSpacing.xs),
          ChangedOnlyButton(
            changes: widget.changes,
            on: widget.browsing.changedOnly,
            onChanged: (value) => widget.browsing.changedOnly = value,
          ),
          IconButton(
            icon: Icon(
              widget.browsing.previewOnHover
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: FwIconSize.md,
              color: widget.browsing.previewOnHover ? colors.accent : null,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            tooltip: widget.browsing.previewOnHover
                ? 'Previewing on hover'
                : 'Preview on hover',
            onPressed: () {
              widget.browsing.previewOnHover = !widget.browsing.previewOnHover;
            },
          ),
          // One button for both directions: with nothing folded away the only
          // useful thing it can do is fold, and after that, unfold.
          IconButton(
            icon: Icon(
              widget.browsing.anyClosed ? Icons.unfold_more : Icons.unfold_less,
              size: FwIconSize.md,
              // Set, because an `IconButton` that names no colour takes
              // Material's pure black — which is not a token this app has, and
              // left this the one icon in the window darker than every other.
              color: colors.mut,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            tooltip: widget.browsing.anyClosed ? 'Expand all' : 'Collapse all',
            onPressed: () => widget.browsing.anyClosed
                ? widget.browsing.openAll()
                : widget.browsing.closeAll(allBranches(widget.tree)),
          ),
          // Folds the rail with it. Hiding the list is something you do when
          // you have stopped choosing and started looking, and at that moment
          // the rail is the same kind of noise — ⌘B brings it back on its own
          // if it was not.
          const AsideExpandButton(),
        ],
      ),
    );
  }
}

/// The entry you asked for, on its way, over the one you were looking at.
///
/// Only ever the slow path — see [CatalogSession.compilingSwitch]. The
/// guest switches most entries by itself in a frame and this never appears for
/// those; what is left is a first compile, a demo whose sources have moved, and
/// a quarantined entry being retried, none of them quick enough to leave the
/// previous demo standing there looking like the answer. That is also why it
/// needs no appearance delay: by the time this is built we already know.
///
/// What is underneath stays there rather than being blanked — the demo you
/// were looking at, or the error the entry you are retrying last gave. It is
/// the right size and in the right place, so the eye stays where the new
/// picture will appear; a canvas that emptied itself on every switch would
/// flash a hole in the middle of the window. Withdrawn, not gone — and opaque
/// to the pointer, because a click meant for the demo you asked for must not
/// land on the one being replaced.
class _SwitchingOverlay extends StatelessWidget {
  const _SwitchingOverlay({required this.entry, required this.child});

  final CatalogEntry entry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: ColoredBox(
            color: context.colors.bg.withValues(alpha: 0.82),
            child: LoadingState(title: entry.name, message: 'Compiling…'),
          ),
        ),
      ],
    );
  }
}

/// Why the selected entry is not on screen, where it would have been.
///
/// Deliberately not a red page. The compiler's own words are the content, and
/// they are long, dense and monospaced: they need a calm surface and real
/// contrast, not a wash that fights them.
class _CompileError extends StatelessWidget {
  const _CompileError({
    required this.entry,
    required this.error,
    required this.onRetry,
  });

  final CatalogEntry entry;
  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.error_outline,
                    size: FwIconSize.lg,
                    color: colors.red,
                  ),
                ),
                const Gap(FwSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.name} doesn’t compile',
                        style: context.type.bodyStrong.copyWith(
                          color: colors.red,
                        ),
                      ),
                      const Gap(FwSpacing.xxs),
                      // Where to go and fix it.
                      Text(
                        '${entry.path} · ${entry.symbol}',
                        style: context.type.caption,
                      ),
                    ],
                  ),
                ),
                const Gap(FwSpacing.lg),
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: FwIconSize.md),
                  label: const Text('Retry'),
                ),
              ],
            ),
            const Gap(FwSpacing.lg),
            // Loose, not expanded: the block is as tall as the diagnostic and
            // no taller. Five lines of error stretched down a 900px panel
            // reads as an empty page with a caption.
            Flexible(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: colors.panel,
                  border: Border.all(color: colors.line),
                  borderRadius: BorderRadius.circular(context.radii.radius),
                ),
                clipBehavior: Clip.antiAlias,
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(FwSpacing.lg),
                    // Horizontal too, and never wrapped: a diagnostic puts a
                    // caret line under the offending column, and a wrapped line
                    // points the caret at the wrong character.
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        error,
                        style: context.type.caption.copyWith(
                          fontFamily: 'monospace',
                          color: colors.ink2,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.session, required this.onReload});

  final CatalogSession session;
  final VoidCallback onReload;

  /// Right-aligned in a fixed column, so a number that gains a digit pushes
  /// nothing along with it.
  static String _ms(Duration d) => '${'${d.inMilliseconds}'.padLeft(4)}ms';

  @override
  Widget build(BuildContext context) {
    // Everything this bar draws about *timing* is a fact about this run rather
    // than about the catalog, so a picture leaves it out — otherwise a
    // committed screenshot changes every time the compiler is a little faster.
    // What is kept is what a reader of the picture would want: which entry, and
    // whether it built.
    var photographed = CaptureMode.isCapturing(context);
    var parts = <String>[];
    if (session.lastSwitch case var report?) {
      parts.add(switch ((report.ok, photographed, report.direct)) {
        (false, _, _) => '${report.entry.name}: did not compile',
        (true, true, _) => report.entry.name,
        // One number, because there was only one thing: the guest already held
        // the entry and moved to it. Naming a compile of 0ms and a reload that
        // was not one would read as a suspiciously fast build rather than as
        // the build that never happened.
        (true, false, true) =>
          '${report.entry.name}: switch ${_ms(report.reload)}',
        (true, false, false) =>
          '${report.entry.name}: compile ${_ms(report.compile)} '
              '· reload ${_ms(report.reload)} '
              // What the reload was *made of*: edited files on a reload,
              // added libraries on a first visit. Both are zero when the
              // guest is showing what it already had.
              '· ${report.reloaded ? '${report.editedCount} edited' : '+${report.newSourceCount} libs'}',
      });
    }
    var failed = session.lastSwitch?.ok == false;
    var ready = session.phase == CatalogSessionPhase.ready;
    var busy = session.busyWith;
    var colors = context.colors;
    var mono = context.type.caption.copyWith(fontFamily: 'monospace');
    return Container(
      // No red bar. A failure has a whole panel explaining it now, and a status
      // line that changes colour as well as content is one more thing moving.
      color: colors.panel,
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
      // Every slot below is fixed, and the bar with them. A row that reflows
      // each time the compiler is asked something is a row nobody can read
      // while it works — which is the only time it has anything to say.
      height: 32,
      child: Row(
        spacing: FwSpacing.lg,
        children: [
          // **The one number with a story behind it**, so it is the one thing
          // in this bar you can open. Everything else here is a fact about the
          // last click; this is a fact about a wait that may have been a
          // minute, and "where did it go" is the question it raises.
          if (session.coldCompile case var cold? when !photographed)
            _ColdCompileReadout(session: session, label: 'cold ${_ms(cold)}'),
          Expanded(
            child: Text(
              parts.join('   '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: failed ? mono.copyWith(color: colors.red) : mono,
            ),
          ),
          // Activity sits by the button that starts it, not in front of the
          // report — an empty slot at the head of the line reads as an indent.
          BusyDot(busy: busy),
          IconButton(
            onPressed: ready && busy == null ? onReload : null,
            icon: const Icon(Icons.refresh, size: FwIconSize.md),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            tooltip:
                'Reload (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘R' : 'Ctrl+R'})',
          ),
        ],
      ),
    );
  }
}

/// The cold-compile number, and what it was made of.
///
/// **The surface whose absence produced the design this implements.** The
/// daemon has reported its phases on the wire since it had any — the doc
/// comment on the field says it is reported rather than logged precisely so a
/// GUI can show it without scraping a log — and nothing read it. A start that
/// took a minute and a start that took twelve seconds looked identical
/// afterwards, so the only way to find out where the difference went was to
/// open the daemon's log by hand.
class _ColdCompileReadout extends StatelessWidget {
  const _ColdCompileReadout({required this.session, required this.label});

  final CatalogSession session;
  final String label;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.caption.copyWith(fontFamily: 'monospace');
    // Prefixed: this file already has a `Popover`, which is the *picker* in
    // `staged_device.dart` — a list with a selection — where this one is the
    // primitive it is built on.
    return ui.Popover(
      // Read-only, so the caller keeps its focus: this opens under a status
      // bar, and taking focus off whatever was being typed to show a table of
      // numbers is not a trade anybody would make.
      autofocus: false,
      side: ui.PopoverSide.top,
      anchor: (context, controller) => Tappable(
        onTap: controller.toggle,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
          child: Text(label, style: mono.copyWith(color: colors.mut)),
        ),
      ),
      content: (context, controller) => PopoverMenuSurface(
        width: 320,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(FwSpacing.lg),
          child: _StartupBreakdown(session: session),
        ),
      ),
    );
  }
}

/// Where a start's time went, and what it began from.
class _StartupBreakdown extends StatelessWidget {
  const _StartupBreakdown({required this.session});

  final CatalogSession session;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    // Longest first. A phase table in the daemon's own order buries the one
    // that mattered among six that took a millisecond each.
    var phases = session.timings.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Where the start went', style: type.bodyStrong),
        const Gap(FwSpacing.xs),
        Text(
          session.reusedDaemon
              // The honest answer for the common case, and the one a table of
              // numbers would actively mislead about: these are somebody
              // else's phases. This session attached to a compiler that was
              // already up and paid for none of them.
              ? 'This panel attached to a compiler that was already running. '
                    'The phases below were paid by whoever started it.'
              : session.warmStart
              ? 'The compiler started from the kernel the last run left, so '
                    'nothing below is a compile from scratch.'
              : 'The compiler had no kernel to start from.',
          style: type.bodyMuted,
        ),
        const Gap(FwSpacing.md),
        _SeedLine(seed: session.seed),
        if (phases.isNotEmpty) ...[
          const Gap(FwSpacing.md),
          Divider(height: 1, color: colors.line),
          const Gap(FwSpacing.sm),
          for (var phase in phases)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                spacing: FwSpacing.md,
                children: [
                  Expanded(
                    child: Text(
                      daemonPhaseLabel(phase.key),
                      style: type.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${phase.value}ms',
                    style: type.caption.copyWith(
                      color: colors.mut,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// **The one fact worth a line of its own.** Two starts that both paid a full
/// cold compile look identical in the table above, and they are not the same
/// thing: one found no shared half to begin from, and the other found one built
/// for a program that reaches a fraction of what this one does. The package
/// count is what separates them on sight.
class _SeedLine extends StatelessWidget {
  const _SeedLine({required this.seed});

  final SeedReport? seed;

  @override
  Widget build(BuildContext context) {
    var seed = this.seed;
    return Row(
      spacing: FwSpacing.xs,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          seed == null ? Icons.info_outline : Icons.bolt_outlined,
          size: FwIconSize.sm,
          color: context.colors.mut2,
        ),
        Expanded(
          child: Text(
            seed == null
                ? 'No shared kernel to start from. One is written on the way '
                      'out, so the next checkout of this resolution starts '
                      'ahead.'
                : 'Started from a shared kernel holding '
                      '${seed.packages} package'
                      '${seed.packages == 1 ? '' : 's'}.',
            style: context.type.caption.copyWith(color: context.colors.mut),
          ),
        ),
      ],
    );
  }
}

/// What the guest is staged as: whatever the address names, else what the entry
/// on screen declares.
///
/// Read at every point of use rather than stored anywhere. Subscribes to the
/// one parameter, so choosing a device rebuilds what draws the frame and
/// nothing above it.
///
/// `device` is un-namespaced, so [context] has to be one no [AddressScope] has
/// given a namespace to — from under `inspect` this asks for `inspect.device`
/// and quietly gets nothing.
///
/// Asserted rather than left to be noticed, because the failure is a picture
/// that is wrong without looking wrong: the canvas framed every entry as the
/// panel while the picker beside it named a phone. `write` rather than `of` —
/// this is a check, and a check that subscribed would rebuild on every address
/// change in debug and on none in release.
Device? _deviceOf(BuildContext context, CatalogSession session) {
  assert(
    AddressScope.write(context).view.namespace == null,
    'device is un-namespaced: read it above any namespaced scope, or it asks '
    'for <namespace>.device and nobody writes that.',
  );
  var param = AddressScope.param(context, 'device');
  // The declaration only when the address says nothing at all. `fit` is
  // something the address *says* — it is how somebody asks for the plain
  // rectangle back — so it must not be overridden by the default it is
  // countermanding.
  //
  // The *entry's* declaration, which is why this reads the selection rather
  // than a field: one package may hold a phone app and a desktop dashboard, and
  // moving between them has to move the canvas with them.
  if (param == null) return _canvasOf(session)?.defaultDevice;
  return resolveDevice(param);
}

/// What the entry on screen is declared to be framed as.
///
/// [CatalogSession.selected] rather than `active`: the canvas belongs to what
/// was asked for, and an entry that will not compile stays selected while the
/// guest goes on showing whatever it last managed to load. Framing the *old*
/// entry's picture as the new one would be a canvas that lags a compile.
PreviewCanvas? _canvasOf(CatalogSession session) =>
    session.canvasOf(session.selected);

/// Which way up the picked device is, read from the same un-namespaced level as
/// [_deviceOf] and for the same reason.
///
/// Kept out of [_deviceOf] because the two consumers want opposite things: the
/// canvas wants the device already turned, and the picker wants the upright one
/// it can find in its own list.
ScreenOrientation? _orientationOf(
  BuildContext context,
  CatalogSession session,
) {
  var param = AddressScope.param(context, 'orientation');
  if (param != null) return resolveOrientation(param);
  // Only with the declared device, matching the headless rule: an orientation
  // turns the device it was declared for, and a person who has picked a phone
  // should not inherit the landscape the project declared for its tablet.
  //
  // A peek that fell back to the entry's own device falls back with it: the
  // declaration is one sentence, and half of it applied is a device on its
  // side for no reason.
  return AddressScope.param(context, 'device') == null
      ? _canvasOf(session)?.defaultOrientation
      : null;
}

/// Whether the keyboard is following the demo or the person looking at it,
/// read from the same un-namespaced level as [_deviceOf].
///
/// A staging axis, so it is on the address, which is what makes a link, a
/// screenshot and the panel agree about a picture with a keyboard in it.
///
/// Falls back to what the canvas declared with no condition attached, unlike
/// [_orientationOf]: a keyboard is a property of the *entries* — these are the
/// form screens — rather than of the device they were declared with, so
/// picking a different phone should not take it away.
KeyboardMode _keyboardOf(BuildContext context, CatalogSession session) {
  var param = AddressScope.param(context, 'keyboard');
  if (param != null) return keyboardModeById(param) ?? KeyboardMode.auto;
  return _canvasOf(session)?.defaultKeyboard ?? KeyboardMode.auto;
}
