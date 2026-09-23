// The app's end of the scene editor: one widget that draws whatever the
// editor sends, through whatever view it asks for, and reports back what the
// layout measured.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'core/json.dart';
import 'core/model.dart';
import 'core/motion_runtime.dart';
import 'core/values.dart';
import 'shader_programs.dart';
import 'view.dart';

/// What one folder of scenes may use, declared once in that folder's
/// `scenes.dart` — the app's widgets, the app's own values by name, the
/// token libraries the scenes read, and what wraps the canvas.
///
/// A scene group is a folder with a `scenes.dart` in it; the scenes are the
/// `.scene.dart` files below. The tool reads this declaration as text (the
/// closures are skipped), generates `scene_args.dart` beside it, and boots
/// the guest from the entries that file declares. The app compiles it, so
/// every expression here is the app's own.
///
/// ```dart
/// //@flutterware:scenes
/// final scenes = SceneGroup(
///   libraries: [brandTokens],
///   widgets: [ExternalWidget('OrderButton', args: […], build: (a) => …)],
///   exports: [Token<Color>('shopBrand', AppColors.brand)],
///   renderers: scene3dRenderers,
///   wrap: (child) => MaterialApp(theme: appTheme, home: child),
/// );
/// ```
class SceneGroup {
  const SceneGroup({
    this.libraries = const [],
    this.widgets = const [],
    this.exports = const [],
    this.renderers = const {},
    this.wrap,
  });

  /// The token libraries these scenes read — each a `*.tokens.dart` the
  /// editor owns, imported here so the compiler checks the reference.
  final List<List<Token<Object?>>> libraries;

  /// The widgets a scene may place.
  final List<ExternalWidget> widgets;

  /// The app's own values, named for the scenes: any type, any expression.
  /// The editor offers each where its type fits and never sees inside;
  /// the canvas — this process — resolves it.
  final List<Token<Object?>> exports;

  /// How a registered node kind (a `SceneKind`) is drawn, by the kind's name
  /// — a 3D view's engine, say — for every view this group mounts. The
  /// door a renderer the core never imports comes through; a kind with no
  /// renderer draws a named placeholder.
  final Map<String, SceneKindRenderer> renderers;

  /// What the canvas is mounted under: the app's theme, its localizations,
  /// whatever the scenes' widgets expect above them. A bare [MaterialApp]
  /// when null.
  final Widget Function(Widget child)? wrap;

  /// Every token the scenes may name: the libraries' tokens, then the
  /// exports.
  List<Token<Object?>> get tokens => [
    for (var library in libraries) ...library,
    ...exports,
  ];

  Widget _wrapped(Widget child) =>
      wrap?.call(child) ??
      MaterialApp(debugShowCheckedModeBanner: false, home: child);
}

/// A scene and its motion, played from the file the editor wrote — the
/// shape an export walks. The generated `scenePlayer` entry mounts this
/// with the `pair` knob's path.
///
/// The knob carries a path rather than the document itself: a scene is
/// kilobytes of JSON, and a walk asks for it once. Mounting [SceneView]
/// with a bound motion is what registers the playhead the harness drives,
/// so every stop of the clip is `evaluate(t)` and nothing else.
class ScenePlayerHost extends StatelessWidget {
  const ScenePlayerHost(
    this.group, {
    super.key,
    required this.pairPath,
    this.nested = const {},
  });

  final SceneGroup group;
  final String pairPath;

  /// The group's own scenes by class name, as their generated arguments
  /// classes — what a nested scene in the pair is instantiated through.
  /// The pair carries a `SceneRefNode` as its class name and arguments,
  /// never the child's document; the generated entry hands this in, since
  /// only generated code may name a generated class.
  final Map<String, SceneRefArgs> nested;

  @override
  Widget build(BuildContext context) {
    if (pairPath.isEmpty) {
      return _waiting(context, 'scene player — no pair given');
    }
    var file = File(pairPath);
    if (!file.existsSync()) return _waiting(context, 'no such pair: $pairPath');
    var pair = sceneFileFromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
    var motion = pair.motions.values.firstOrNull;
    // The pair came off disk as data, so its external nodes carry a label
    // and no generated class. This is what turns the label back into a
    // widget; a scene the app COMPILED needs none of it.
    bindExternals(pair.scene, group.widgets, tokens: group.tokens);
    for (var (node, _) in pair.scene.walk()) {
      if (node is! SceneRefNode) continue;
      var args = nested[node.sceneClassName];
      if (args == null) continue;
      node.declared = args;
      node.syncInstance();
    }
    return group._wrapped(
      Align(
        alignment: Alignment.topLeft,
        child: SceneView.document(
          pair.scene,
          motion: motion == null ? null : BoundMotion.bind(motion, pair.scene),
          renderers: group.renderers,
        ),
      ),
    );
  }

  Widget _waiting(BuildContext context, String message) => group._wrapped(
    ColoredBox(
      color: const Color(0xFF26282C),
      child: Center(
        child: Text(
          message,
          style: const TextStyle(color: Color(0x8AFFFFFF)),
          textDirection: TextDirection.ltr,
        ),
      ),
    ),
  );
}

/// The scene editor's canvas, hosted by the app whose theme and widgets the
/// scenes use.
///
/// The generated `sceneCanvasHost` entry beside a group's `scenes.dart`
/// mounts this through [SceneCanvasHost.of], under the group's own wrapper,
/// and the editor composites it: it sends the scene as *data* over a
/// VM-service extension, this draws it with [SceneView], and answers with
/// what the layout measured — which is where the editor's selection
/// rectangles and drag targets come from.
///
/// The editor also sends its **view** — how the canvas is scaled and panned —
/// and this draws the artboard through it. The window this renders into is
/// the size of the editor's canvas pane, so a zoomed-in artboard is
/// rasterised at the zoom, crisp at any magnification, and the picture never
/// costs more than the pane's pixels.
class SceneCanvasHost extends StatefulWidget {
  const SceneCanvasHost({
    super.key,
    this.externals = const [],
    this.tokens = const [],
    this.renderers = const {},
    this.ground = const Color(0x00000000),
  });

  /// The canvas for one group, under the group's wrapper — what the
  /// generated entry mounts.
  static Widget of(SceneGroup group) => group._wrapped(
    SceneCanvasHost(
      externals: group.widgets,
      tokens: group.tokens,
      renderers: group.renderers,
    ),
  );

  /// Renderers for registered kinds, handed to every view this host mounts.
  final Map<String, SceneKindRenderer> renderers;

  /// The widgets a scene may place, as the app declares them.
  ///
  /// The editor sends a scene as DATA, and a generated arguments class is
  /// not data — it cannot travel, and the wire carries the `entry` label
  /// instead. So the app hands over the same declaration list the generator
  /// read, and the label finds its widget here.
  ///
  /// A widget the app forgets to declare shows as its label rather than
  /// blank.
  final List<ExternalWidget> externals;

  /// The tokens the app declares — for the opaque ones, whose objects only
  /// this process holds; see `bindExternals`.
  final List<Token<Object?>> tokens;

  /// What shows around the artboard. Transparent by default, so the editor's
  /// own ground shows through.
  final Color ground;

  @override
  State<SceneCanvasHost> createState() => _SceneCanvasHostState();
}

class _SceneCanvasHostState extends State<SceneCanvasHost> {
  /// The scene the editor sent, as a live document — the same model the
  /// editor holds, so what draws here is what it authored.
  SceneDocument? _scene;
  var _selected = <String>{};
  var _rects = <String, SceneRect>{};

  /// Artboard to window, as the editor's canvas has it: a scale and a pan.
  var _view = Matrix4.identity();

  /// The box the artboard is drawn in, as the editor's canvas decided it.
  ///
  /// A root that fills has no size of its own — that is the point of it —
  /// so somebody has to say how big the page being authored is. The editor
  /// does, and sends it; without one there is nothing to lay out against
  /// and Flutter says so with an infinite-constraint error.
  Size? _artboard;

  /// The editor's playhead. The scene arrives with the motion already
  /// composed into it, but a shader pass is drawn by the clock itself, and
  /// the clock is not in the picture.
  final _time = ValueNotifier(Duration.zero);

  /// Once per isolate: a re-mounted widget must not re-register.
  static var _registered = false;
  static _SceneCanvasHostState? _instance;

  @override
  void initState() {
    super.initState();
    if (!_registered) {
      _registered = true;
      dev.registerExtension('ext.fw.scene.apply', _applyStatic);
    }
    _instance = this;
  }

  @override
  void dispose() {
    if (identical(_instance, this)) _instance = null;
    _time.dispose();
    super.dispose();
  }

  static Future<dev.ServiceExtensionResponse> _applyStatic(
    String method,
    Map<String, String> params,
  ) async {
    var instance = _instance;
    if (instance == null) {
      return dev.ServiceExtensionResponse.result(
        jsonEncode({'error': 'no scene host mounted'}),
      );
    }
    return instance._apply(params);
  }

  /// One push from the editor: any of the scene, the view, the artboard and
  /// the time, in seconds.
  Future<dev.ServiceExtensionResponse> _apply(
    Map<String, String> params,
  ) async {
    var frame = Stopwatch()..start();
    var window = View.of(context);
    setState(() {
      if (params['scene'] case var raw?) {
        var decoded = jsonDecode(raw) as Map<String, dynamic>;
        // The wire is a picture: values already composed with the motion's
        // fx, so the host draws what it is given rather than evaluating
        // anything.
        var doc = sceneFromWire(decoded['root'] as Map<String, dynamic>);
        bindExternals(doc, widget.externals, tokens: widget.tokens);
        _scene = doc;
        _selected = switch (decoded['selected']) {
          List names => {for (var n in names) '$n'},
          String name => {name},
          _ => const {},
        };
      }
      if (params['artboard'] case var raw?) {
        if (jsonDecode(raw) case [num w, num h]) {
          _artboard = Size(w.toDouble(), h.toDouble());
        }
      }
      if (params['view'] case var raw?) {
        if (jsonDecode(raw) case [num scale, num tx, num ty]) {
          _view = Matrix4.identity()
            ..translateByDouble(tx.toDouble(), ty.toDouble(), 0, 1)
            ..scaleByDouble(scale.toDouble(), scale.toDouble(), 1, 1);
        }
      }
    });
    // Outside the rebuild: the painters listen to the time, so a time that
    // moved repaints them and costs this tree nothing.
    if (double.tryParse(params['time'] ?? '') case var seconds?
        when seconds.isFinite) {
      _time.value = Duration(microseconds: (seconds * 1e6).round());
    }
    // A shader pass paints nothing until its program loads, so a picture
    // taken before is honest and wrong. Wait for the loads — bounded, a broken
    // shader must not hang the editor — then draw.
    var shaders = const <String>{};
    if (_scene case var scene?) {
      shaders = sceneShaderAssets(scene);
      try {
        await precacheSceneShaders(scene).timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // What is still loading is named in the reply.
      }
    }
    // A hidden window pumps no ordinary frames; a forced frame paints even
    // when the compositor thinks nothing is visible — the drive layer's trick.
    SchedulerBinding.instance.scheduleForcedFrame();
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 500),
      );
    } on TimeoutException {
      return dev.ServiceExtensionResponse.result(
        jsonEncode({'error': 'no frame within 500ms (window hidden?)'}),
      );
    }
    return dev.ServiceExtensionResponse.result(
      jsonEncode({
        'rects': {
          for (var e in _rects.entries)
            e.key: [e.value.left, e.value.top, e.value.width, e.value.height],
        },
        'frameMs': frame.elapsedMicroseconds / 1000,
        // What this end drew through and into — the editor's status line
        // shows it, which is how a host that is not this one is told apart.
        'view': [_view.storage[0], _view.storage[12], _view.storage[13]],
        'window': [
          window.physicalSize.width,
          window.physicalSize.height,
          window.devicePixelRatio,
        ],
        // This scene's own: a load another document started is not what
        // this picture is missing.
        'pendingShaders': [
          for (var asset in SceneShaderPrograms.instance.pending)
            if (shaders.contains(asset)) asset,
        ],
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    var scene = _scene;
    return ColoredBox(
      color: widget.ground,
      child: scene == null
          ? const SizedBox.expand()
          // The artboard keeps its own size whatever the window's — an
          // OverflowBox, since a zoomed artboard is larger than the pane —
          // and is drawn through the editor's view. No filter quality: the
          // transform must rasterise at its scale, not sample a 1× picture.
          : Transform(
              transform: _view,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                // The window until the editor says otherwise: the first
                // push can land before the canvas has laid out and sent an
                // artboard, and a root that fills would meet the
                // OverflowBox's infinity and throw.
                child: SizedBox(
                  width: (_artboard ?? MediaQuery.sizeOf(context)).width,
                  height: (_artboard ?? MediaQuery.sizeOf(context)).height,
                  child: SceneView.document(
                    scene,
                    time: _time,
                    selected: _selected,
                    renderers: widget.renderers,
                    // Named here, at the edge the names exist on: the
                    // document arrived over the wire carrying them, and
                    // the editor asks for its rects the same way.
                    onMeasured: (rects) => _rects = namedRects(rects),
                  ),
                ),
              ),
            ),
    );
  }
}
