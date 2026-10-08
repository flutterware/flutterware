// The guest half of the editor: the app's own process, rendering the scene
// from data, composited back as a texture.
//
// The scene v1 decision the whole editor rests on is that the GUEST IS THE
// ONLY RENDERER — the app's theme, its real external widgets, its measured
// geometry — so this class is what every scene surface mounts: it boots the
// session, pushes the document as JSON on every change, and hands the
// measured rects back to the editor, which is where selection and handles
// read their geometry from.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/painting.dart' show Size;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:vector_math/vector_math_64.dart' show Matrix4;
import 'package:flutterware/scene_authoring.dart';
// ignore: implementation_imports
import 'package:flutterware/src/scene/shader_programs.dart'
    show sceneShaderAssets;

import '../previews/catalog_session.dart';
import 'args_codegen.dart';
import 'editor.dart';
import 'scene_file.dart';

/// The preview entry a group's generated file declares to host its scenes
/// — the registration, per the scene v1 decision that a preview entry *is*
/// the registration. One per group, told apart by the folder it sits in.
const sceneHostEntrySymbol = sceneCanvasHostSymbol;

/// Pushes one editor's document to one guest, coalescing while a push is in
/// flight, and applies the rects it measures back onto the nodes.
///
/// [groupDirectory] is the folder of the group the editor's file belongs
/// to, relative to the session's project root: the entry booted is the
/// host declared in THAT folder's `scene_args.dart`, since every group has
/// one and they all share the symbol.
class SceneGuest {
  SceneGuest(this.session, this.editor, {required this.groupDirectory}) {
    _paintsWithClock = sceneShaderAssets(editor.doc).isNotEmpty;
    _shown = _isShown(WidgetsBinding.instance.lifecycleState);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _pollAssets();
    editor.doc.addListener(_push);
    editor.addListener(_onEditor);
    editor.playheadClock.addListener(_onPlayhead);
    session.addListener(_onSession);
    // A session that is already up notifies nobody about it: ask now, or a
    // guest created over a running session shows what it was showing.
    _onSession();
    // Until the guest's extension is registered (entry selected, first
    // build), pushes fail; retry until the first one lands.
    _retry = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_everApplied) {
        _retry?.cancel();
      } else {
        _push();
      }
    });
  }

  final CatalogSession session;
  final SceneEditor editor;

  /// What the toolbar shows: the round trip, or what went wrong.
  final status = ValueNotifier('guest: booting…');

  /// The view the host was last told to draw through — artboard to pane,
  /// as `[scale, tx, ty]`. What the texture on screen shows; a canvas that
  /// has moved since draws the texture through the difference until the
  /// next push lands.
  final rendered = ValueNotifier(Matrix4.identity());

  var _view = Matrix4.identity();
  Timer? _viewSettle;

  /// The canvas moved: tell the host after the gesture settles, so a pinch is
  /// one render rather than sixty.
  /// The box the canvas is drawing the artboard in. A root that fills has
  /// no size of its own, so the editor's preview size is what the guest
  /// lays out against.
  Size? artboard;

  void setView(Matrix4 artboardToPane, {Size? artboard}) {
    if (_view == artboardToPane && this.artboard == artboard) return;
    this.artboard = artboard ?? this.artboard;
    _view = artboardToPane.clone();
    _viewSettle?.cancel();
    _viewSettle = Timer(const Duration(milliseconds: 80), _push);
  }

  var _inflight = false;
  var _dirty = false;
  var _everApplied = false;
  Timer? _retry;

  /// Whether the guest has ever rendered — until then the canvas shows the
  /// booting state rather than a blank artboard.
  bool get isLive => _everApplied;

  /// The shader programs the canvas's last answer was still loading. A pass
  /// paints nothing until its program lands, so while this is not empty the
  /// texture is an honest picture of the wrong thing.
  var _pendingShaders = const <String>[];

  /// Asks again while [_pendingShaders] is not empty: the host answers once
  /// per push, and a program that lands later says so to nobody.
  Timer? _shaderRetry;
  var _disposed = false;

  /// Whether the host has answered a push at all, with a picture or with
  /// why not.
  var _answered = false;

  /// Why no host is going to answer: it does not compile, the switch to it
  /// failed, or the group declares none. What [_onSession] last found.
  String? _hostProblem;

  /// What the canvas is still waiting on, or null when what it shows is
  /// what the document says — read by the plugin's settle source.
  ///
  /// Busy from the start until the host first answers, not only while a
  /// push is out: before its first draw the guest retries every 500ms, and
  /// the quiet between two failed pushes was long enough for a capture to
  /// photograph the booting canvas. Not when nothing is coming — a host that
  /// cannot answer would hold every capture to its timeout.
  String? get busyWith {
    if (_inflight) return 'drawing the scene';
    if (!_answered &&
        _hostProblem == null &&
        session.phase != CatalogSessionPhase.error) {
      return 'drawing the scene';
    }
    return _pendingShaders.isEmpty
        ? null
        : 'loading ${_pendingShaders.join(', ')}';
  }

  /// Puts the scene host on the guest whenever it is not already there —
  /// including over whatever the session picked for itself while booting,
  /// which is how a rebooted session came up showing the catalog's first
  /// entry under the scene panel.
  /// The engine last seen: a new one is a host that has forgotten the scene.
  Object? _engine;

  void _onSession() {
    if (session.phase != CatalogSessionPhase.ready) return;
    _hostProblem = null;
    if (!identical(session.engine, _engine)) {
      _engine = session.engine;
      // A guest that restarted or reloaded holds no scene until it is sent
      // one, and nothing else sends it before the next edit.
      if (_everApplied) _push();
    }
    for (var entry in session.entries) {
      if (entry.symbol != sceneHostEntrySymbol) continue;
      if (!isGroupHostEntry(entry.path, groupDirectory)) continue;
      if (session.wantedEntryId != entry.id) session.wantedEntryId = entry.id;
      // A host that does not compile is a guest showing its last good
      // build, silently — the status line is where that has to be said.
      if (session.compileErrorFor(entry) case var error?) {
        _hostProblem = error;
        status.value = 'guest: the host does not compile. $error';
      } else if (session.lastSwitch?.error case var error?) {
        _hostProblem = error;
        status.value = 'guest: $error';
      }
      return;
    }
    _hostProblem = 'no scene host';
    status.value =
        'guest: no scene host in $groupDirectory/. The generated '
        '$sceneArgsFileName declares it; rescan the group.';
  }

  final String groupDirectory;

  /// Sends the document now — after a guest reload, which remounts the host
  /// with no scene, and otherwise only when the document or the selection
  /// changes.
  void push() => _push();

  /// Whether a shader paints the document, which then changes with the
  /// playhead alone: a motion that animates nothing but `uTime` writes no
  /// fx, so no document flush ever pushes it.
  ///
  /// Asked when the EDITOR notifies — every edit, undo and redo does —
  /// rather than when the document does, which is every fx flush and so
  /// every tick of a playing motion.
  var _paintsWithClock = false;

  void _onEditor() {
    _paintsWithClock = sceneShaderAssets(editor.doc).isNotEmpty;
    _pollAssets();
    _push();
  }

  /// How often the daemon is asked to look at the assets while a shader
  /// paints the document.
  static const assetPollInterval = Duration(seconds: 1);

  /// The daemon has no watcher: it rebuilds the bundle — and tells the guest
  /// which shaders to reload — only when a client asks it something. The
  /// previews panel polls while it is on screen; nothing asked on the scene
  /// editor's behalf, so a `.frag` saved beside an open scene reached the
  /// canvas only at the next restart. Polled only while a shader paints the
  /// document, since that is the edit loop it is for.
  Timer? _assetPoll;

  /// Whether the studio is on screen, which the poll also waits for: a
  /// window left minimised over a shader document would otherwise have the
  /// daemon rebundle once a second for as long as it stays down. Not
  /// `inactive` — a studio beside the editor the `.frag` is saved in has
  /// lost focus, and is the loop the poll is for.
  var _shown = true;
  late final AppLifecycleListener _lifecycle;

  static bool _isShown(AppLifecycleState? state) =>
      state != AppLifecycleState.hidden && state != AppLifecycleState.paused;

  /// Back on screen, the daemon is asked at once rather than a second later:
  /// whatever was saved while the window was down is what the user is
  /// coming back to see.
  void _onLifecycle(AppLifecycleState state) {
    var shown = _isShown(state);
    if (shown == _shown) return;
    _shown = shown;
    if (shown &&
        _paintsWithClock &&
        session.phase == CatalogSessionPhase.ready) {
      session.refresh();
    }
    _pollAssets();
  }

  void _pollAssets() {
    if (!_paintsWithClock || !_shown) {
      _assetPoll?.cancel();
      _assetPoll = null;
      return;
    }
    _assetPoll ??= Timer.periodic(assetPollInterval, (_) {
      if (session.phase == CatalogSessionPhase.ready) session.refresh();
    });
  }

  void _onPlayhead() {
    if (_paintsWithClock) _push();
  }

  void _push() {
    if (_disposed) return;
    _shaderRetry?.cancel();
    if (_inflight) {
      _dirty = true;
      return;
    }
    _inflight = true;
    _viewSettle?.cancel();
    var clock = Stopwatch()..start();
    var view = _view.clone();
    unawaited(
      session
          .callGuestExtension(
            'ext.fw.scene.apply',
            args: {
              'scene': jsonEncode(
                editor.doc.toWire(selected: editor.selectionNames),
              ),
              'view': jsonEncode([
                view.storage[0],
                view.storage[12],
                view.storage[13],
              ]),
              if (artboard case var size?)
                'artboard': jsonEncode([size.width, size.height]),
              'time':
                  '${editor.playhead.inMicroseconds / Duration.microsecondsPerSecond}',
            },
          )
          // A call that never answers would hold `_inflight` for good, and a
          // canvas that stops following edits is indistinguishable from a
          // frozen editor. Measured round trips are 10–300ms; a second is
          // already a guest in trouble, and the status line should say so.
          // The host's wait for shader programs is bounded at 2s, inside this.
          .timeout(const Duration(seconds: 3))
          .then((reply) {
            if (_disposed) return;
            if (reply != null) _answered = true;
            _pendingShaders = _pendingIn(reply);
            if (_pendingShaders.isNotEmpty) {
              _shaderRetry = Timer(const Duration(milliseconds: 250), _push);
            }
            var rtt = clock.elapsedMicroseconds / 1000;
            if (reply != null && reply['error'] == null) {
              _everApplied = true;
              rendered.value = view;
              var frameMs = (reply['frameMs'] as num?)?.toDouble();
              _applyRects((reply['rects'] as Map?)?.cast<String, dynamic>());
              // A host that answers without a window predates the view: it
              // draws the artboard at its origin whatever the canvas does.
              var stale = reply['window'] == null;
              status.value =
                  'guest ✓ ${rtt.toStringAsFixed(1)}ms rtt'
                  ' · ${frameMs?.toStringAsFixed(1)}ms frame'
                  ' · ×${view.storage[0].toStringAsFixed(2)}'
                  '${stale ? ' · host predates the view' : ''}';
            } else if (reply != null) {
              status.value = 'guest: ${reply['error']}';
            }
          })
          .catchError((Object e) {
            if (_disposed) return;
            // No re-push follows a failure, so a list kept from the last
            // answer would hold a capture until the next edit.
            _pendingShaders = const [];
            if (_everApplied) {
              status.value = e is TimeoutException
                  ? 'guest: no answer in 3s; the host may be stuck'
                  : 'guest: push failed';
            }
          })
          .whenComplete(() {
            _inflight = false;
            if (_dirty) {
              _dirty = false;
              _push();
            }
          }),
    );
  }

  /// The asset keys a reply names as still loading; anything unreadable is
  /// none, since a host that predates the list is one that never waits.
  static List<String> _pendingIn(Map<String, dynamic>? reply) =>
      switch (reply?['pendingShaders']) {
        List names => [
          for (var n in names)
            if (n is String) n,
        ],
        _ => const [],
      };

  /// The guest is the only renderer, so its laid-out rects are the editor's
  /// geometry: selection, hit targets and handles all read what it measured.
  void _applyRects(Map<String, dynamic>? rects) {
    if (rects == null) return;
    var changed = false;
    for (var (node, _) in editor.doc.walk()) {
      var raw = rects[node.name];
      if (raw is List && raw.length == 4) {
        var rect = SceneRect(
          (raw[0] as num).toDouble(),
          (raw[1] as num).toDouble(),
          (raw[2] as num).toDouble(),
          (raw[3] as num).toDouble(),
        );
        if (node.measured != rect) {
          node.measured = rect;
          changed = true;
        }
      }
    }
    if (changed) editor.doc.geometryEpoch.value++;
  }

  void dispose() {
    _disposed = true;
    _lifecycle.dispose();
    _assetPoll?.cancel();
    _shaderRetry?.cancel();
    _viewSettle?.cancel();
    rendered.dispose();
    _retry?.cancel();
    editor.doc.removeListener(_push);
    editor.removeListener(_onEditor);
    editor.playheadClock.removeListener(_onPlayhead);
    session.removeListener(_onSession);
    status.dispose();
  }
}
