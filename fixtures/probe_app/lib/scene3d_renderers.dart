// The renderers for the scene's registered 3D kinds, in the app — the
// half the core does not import.
//
// A `View3DNode` is drawn by [scene3dRenderers]: one flutter_scene scene per
// view, one loaded asset per `ModelNode` or `SurfaceNode` child, the orbit
// camera and every transform read off the nodes' rows *as rendered*, so a
// motion's tracks reach the picture. Loading goes through `RealWork.run`
// (the export walk waits for it), and the asset is the build-time
// `.fsceneb` the app's hook wrote. Register with
// `SceneView(renderers: scene3dRenderers)` or the canvas host's
// `renderers:`.
//
// A surface is a placement with a slot. Its first child is drawn by the
// view — handed in through the renderer's child callback, live — and
// captured by flutter_scene onto the material of the mesh the surface
// names, or onto a quad of this file's own when the surface names no asset.
// The capture is asynchronous; the component's controller says when a new
// texture landed, and the view repaints on it so the frame that carries it
// gets drawn — which is what keeps a walk's photograph at the playhead's
// moment rather than one capture behind.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware/real_work.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'root_zone_scene.dart';

/// What the app hands every scene view.
final Map<String, SceneKindRenderer> scene3dRenderers = {
  view3dKind.name: (context, node, child) => _View3D(node, child),
};

/// A row of a registered kind, as rendered — composed with any motion
/// track on it. Read by name rather than through the typed subclass: a
/// node that arrived over the wire or from JSON is the plain [KindNode],
/// and the typed class exists for the file and the motion signature.
double _row(KindNode node, String name) =>
    (node.fxRendered(name) as num).toDouble();

String _text(KindNode node, String name) =>
    scenePropNamed(node, name)?.read(node) as String? ?? '';

/// The pixel box a slot's content is captured at: the child's own size,
/// or the size of the scene it references, or a phone's worth.
Size _slotSize(SceneNode slot) {
  double? finite(double? v) => v != null && v.isFinite && v > 0 ? v : null;
  var w = finite(slot.width);
  var h = finite(slot.height);
  if (slot is SceneRefNode) {
    var inst = slot.instance;
    if (inst != null) {
      w ??= finite(inst.root.width);
      h ??= finite(inst.root.height);
    }
  }
  return Size(w ?? 360, h ?? 640);
}

class _View3D extends StatefulWidget {
  const _View3D(this.node, this.child);

  final KindNode node;

  /// The view's own picture of a child, for a surface's slot.
  final SceneChildRenderer child;

  @override
  State<_View3D> createState() => _View3DState();
}

/// One loaded placement, keyed by its scene node's NAME. Not the node:
/// every push from the editor decodes a fresh document, so the node objects
/// change on every edit while the names are the identity the whole editor
/// keys on. Keyed by object, each keystroke in the inspector dropped every
/// asset and loaded it again (measured 2026-09-07: a blank frame logged per
/// push, and the models blinking out).
class _Placed {
  _Placed(this.asset, this.root);

  final String asset;
  final fs.Node root;

  /// Every clip of the asset ever asked for, by name, kept for the life of
  /// the placement and driven by weight: the engine leaves the skeleton
  /// wrong after a clip is removed and another created in its place
  /// (measured 2026-09-07: a fox swapped from Walk to Run stood upright),
  /// so nothing is ever removed — a clip not playing weighs zero.
  final clips = <String, (fs.AnimationClip, double)>{};

  /// The placement's own materials with the colour they came with, made
  /// the first time a tint is not white — the asset's materials are shared
  /// between its loads, so a tint on shared ones would tint every load.
  List<(fs.Material, vm.Vector4)>? tinted;

  /// A surface's binding: the slot it shows, on which mesh, at what size.
  fs.WidgetComponent? surface;
  fs.Node? surfaceHost;

  /// The material of this surface's own, on the named mesh — what the
  /// captures bind onto.
  fs.UnlitMaterial? material;
  SceneNode? slot;
  String mesh = '';
  Size slotSize = Size.zero;
}

class _View3DState extends State<_View3D> {
  final _scene = rootZoneScene();

  /// The window's sun, in the scene while `light` is above zero.
  fs.Node? _sun;
  fs.DirectionalLight? _sunLight;
  final _placed = <Object, _Placed>{};
  final _loading = <Object>{};

  /// What a placement is remembered by.
  ///
  /// The node's name where it has one, and the node OBJECT where it does not.
  /// A document the editor pushed arrives as fresh objects every time, so
  /// identity cannot survive a push and the name has to carry it; a scene the
  /// app COMPILED has no names at all — `SceneNode.name` is only filled in by
  /// the parser, from the field name — so keying on the name alone collapsed
  /// every placement of a compiled scene into one, and a banner with two
  /// phones on it drew one phone. Same rule the view already uses for its
  /// GlobalKeys.
  static Object _keyOf(KindNode n) => n.name.isNotEmpty ? n.name : n;
  Object? _error;
  var _started = false;

  @override
  void initState() {
    super.initState();
    _scene.autoExposure.enabled = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _sync(DefaultAssetBundle.of(context));
    }
  }

  @override
  void didUpdateWidget(_View3D old) {
    super.didUpdateWidget(old);
    _sync(DefaultAssetBundle.of(context));
  }

  @override
  void dispose() {
    for (var placed in _placed.values) {
      placed.surface?.controller.removeListener(_repaint);
    }
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  static bool _isPlacement(SceneNode c) =>
      c is KindNode && (c.kind == modelKind || c.kind == surfaceKind);

  /// Brings the engine's scene up to date with the node's children: loads
  /// what is new, drops what is gone, and applies every transform, clip
  /// time and slot from the rows. Cheap when nothing structural changed.
  void _sync(AssetBundle bundle) {
    var placements = [
      for (var c in widget.node.children)
        if (_isPlacement(c)) c as KindNode,
    ];
    var keys = {for (var n in placements) _keyOf(n)};
    for (var gone in _placed.keys.where((k) => !keys.contains(k)).toList()) {
      _drop(gone);
    }
    for (var node in placements) {
      var placed = _placed[_keyOf(node)];
      var asset = _text(node, 'asset');
      // A model with no asset is nothing to draw; a surface with none is a
      // quad. The quad is keyed by the empty asset like any other load.
      if (placed != null &&
          (placed.asset != asset ||
              (node.kind == surfaceKind &&
                  placed.mesh != _text(node, 'mesh')))) {
        _drop(_keyOf(node));
        placed = null;
      }
      if (placed == null) {
        if ((asset.isNotEmpty || node.kind == surfaceKind) &&
            _loading.add(_keyOf(node))) {
          _load(bundle, node);
        }
        continue;
      }
      _apply(node, placed);
    }
  }

  void _drop(Object key) {
    var placed = _placed.remove(key);
    if (placed == null) return;
    _unbind(placed);
    _scene.remove(placed.root);
  }

  /// The placement [key] names as the node holds it NOW — a load that was
  /// out while the editor pushed a new document lands on the new one.
  KindNode? _current(Object key) {
    for (var c in widget.node.children) {
      if (_isPlacement(c) && _keyOf(c as KindNode) == key) return c;
    }
    return null;
  }

  Future<void> _load(AssetBundle bundle, KindNode node) async {
    var asset = _text(node, 'asset');
    var mesh = _text(node, 'mesh');
    try {
      var root = await RealWork.run<fs.Node>(() async {
        if (!fs.Scene.isReadyToRender) {
          await fs.loadBaseShaderLibrary();
          await fs.Scene.initializeStaticResources();
        }
        if (asset.isEmpty) return _quad();
        return fs.loadScene(asset, bundle: bundle);
      });
      if (!mounted) return;
      _loading.remove(_keyOf(node));
      // The node may have moved on while the load was out.
      var now = _current(_keyOf(node));
      if (now == null ||
          _text(now, 'asset') != asset ||
          _text(now, 'mesh') != mesh) {
        return;
      }
      var placed = _Placed(asset, root)..mesh = mesh;
      // Every clip registered now, at the rest pose and weighing nothing:
      // the engine records a node's bind pose when the first clip that
      // drives it is made, from the node's transform at that moment — a
      // clip made later, while another has posed the skeleton, records
      // the pose as rest and doubles it from then on.
      for (var animation in root.parsedAnimations) {
        placed.clips[animation.name] = (
          root.createAnimationClip(animation)..weight = 0,
          animation.endTime,
        );
      }
      _placed[_keyOf(now)] = placed;
      // The mesh gets its material BEFORE the root joins the scene, and the
      // capture component AFTER: a mesh swapped on a node the scene already
      // held was drawn with the old one in two runs out of three, and a
      // component added to a node the scene does not hold yet is never
      // registered for capture (both 2026-09-07).
      if (now.kind == surfaceKind) _prepareSurface(placed);
      _scene.add(root);
      _apply(now, placed);
      setState(() {});
    } catch (e) {
      _loading.remove(_keyOf(node));
      if (mounted) setState(() => _error = e);
    }
  }

  void _apply(KindNode node, _Placed placed) {
    // The slot first: the quad's width follows the slot's box.
    if (node.kind == surfaceKind) _bind(node, placed);
    var rad = math.pi / 180;
    var t = vm.Matrix4.translationValues(
      _row(node, 'positionX'),
      _row(node, 'positionY'),
      _row(node, 'positionZ'),
    );
    t.rotateY(_row(node, 'rotationY') * rad);
    t.rotateX(_row(node, 'rotationX') * rad);
    t.rotateZ(_row(node, 'rotationZ') * rad);
    var size = _row(node, 'size');
    if (placed.asset.isEmpty && placed.slot != null) {
      // The quad is one unit tall; its width follows the slot's box.
      var aspect = placed.slotSize.width / placed.slotSize.height;
      t.scaleByVector3(vm.Vector3(size * aspect, size, size));
    } else {
      t.scaleByDouble(size, size, size, 1);
    }
    placed.root.localTransform = t;
    // Which clips play, as rendered: a motion's block writes the name,
    // and a crossfade writes the second with its weight. Every clip keeps
    // its place; the two named ones take the weight, the rest weigh zero.
    var loop = scenePropNamed(node, 'loop')?.read(node) != false;
    var first = _clipNamed(placed, _fxText(node, 'animation'));
    var second = _clipNamed(placed, _fxText(node, 'animation2'));
    var blend = second == null ? 0.0 : _row(node, 'blend').clamp(0.0, 1.0);
    for (var (clip, _) in placed.clips.values) {
      clip.weight = 0;
    }
    if (first case (var clip, var end)) {
      // The engine's seek clamps at the clip's end; the wrap is ours, so a
      // time keyed past the end keeps the clip going when the row says so.
      clip
        ..seek(_wrap(_row(node, 'animationTime'), end, loop))
        ..weight = 1 - blend;
    }
    if (second case (var clip, var end)) {
      clip
        ..seek(_wrap(_row(node, 'animationTime2'), end, loop))
        ..weight = blend;
    }
    _tint(placed, node.fxRendered('tint') as SceneColor);
  }

  /// Multiplies [tint] into the placement's materials. White on a
  /// placement never tinted costs nothing; the first other colour gives the
  /// placement its own materials, copied from the asset's with the fields
  /// a tint has to keep.
  void _tint(_Placed placed, SceneColor tint) {
    var white = tint.argb == 0xFFFFFFFF;
    if (white && placed.tinted == null) return;
    if (placed.tinted == null) {
      var own = <(fs.Material, vm.Vector4)>[];
      void visit(fs.Node n) {
        if (n.mesh case var mesh?) {
          var clone = mesh.clone();
          for (var p in clone.primitives) {
            // The surface's own screen material is already this
            // placement's, and the captures bind onto it: tinted in
            // place, below, never copied away from them.
            if (identical(p.material, placed.material)) continue;
            switch (p.material) {
              case fs.PhysicallyBasedMaterial m:
                var copy =
                    fs.PhysicallyBasedMaterial(
                        baseColorTexture: m.baseColorTexture,
                        metallicRoughnessTexture: m.metallicRoughnessTexture,
                        normalTexture: m.normalTexture,
                        emissiveTexture: m.emissiveTexture,
                        occlusionTexture: m.occlusionTexture,
                      )
                      ..baseColorFactor = m.baseColorFactor.clone()
                      ..metallicFactor = m.metallicFactor
                      ..roughnessFactor = m.roughnessFactor;
                p.material = copy;
                own.add((copy, m.baseColorFactor.clone()));
              case fs.UnlitMaterial m:
                var copy = fs.UnlitMaterial(colorTexture: m.baseColorTexture)
                  ..baseColorFactor = m.baseColorFactor.clone();
                p.material = copy;
                own.add((copy, m.baseColorFactor.clone()));
            }
          }
          n.mesh = clone;
        }
        for (var c in n.children) {
          visit(c);
        }
      }

      // The surface's own screen material keeps its texture binding: it is
      // already this placement's, so it is tinted in place.
      visit(placed.root);
      if (placed.material case var screen?) {
        own.add((screen, screen.baseColorFactor.clone()));
      }
      placed.tinted = own;
    }
    var f = vm.Vector4(tint.red / 255, tint.green / 255, tint.blue / 255, 1);
    for (var (material, original) in placed.tinted!) {
      var factor = vm.Vector4(
        original.x * f.x,
        original.y * f.y,
        original.z * f.z,
        original.w,
      );
      switch (material) {
        case fs.PhysicallyBasedMaterial m:
          m.baseColorFactor = factor;
        case fs.UnlitMaterial m:
          m.baseColorFactor = factor;
      }
    }
  }

  /// Finds the mesh the surface names and gives it a material of this
  /// surface's own, on a clone of the mesh: two loads of one asset share
  /// their materials (measured 2026-09-06: two rigs bound in turn both
  /// showed the second slot), and the clone is the seam flutter_scene
  /// provides for reskinning one instance. Unlit, because a screen is
  /// self-lit: the slot's colours arrive as authored rather than shaded by
  /// the environment. Before the root joins the scene — see [_load].
  void _prepareSurface(_Placed placed) {
    var host = placed.asset.isEmpty
        ? placed.root
        : placed.mesh.isEmpty
        ? _firstMesh(placed.root)
        : placed.root.getChildByName(placed.mesh);
    var mesh = host?.mesh;
    if (host == null || mesh == null) {
      _error = StateError(
        'no mesh named "${placed.mesh}" in ${placed.asset}; '
        'the meshes there: ${_meshNames(placed.root).join(', ')}',
      );
      return;
    }
    var material = fs.UnlitMaterial();
    host.mesh = mesh.clone()..primitives.forEach((p) => p.material = material);
    placed.surfaceHost = host;
    placed.material = material;
  }

  /// Puts the surface's slot on its mesh, when the slot, the mesh or the
  /// capture size changed since the last binding.
  void _bind(KindNode node, _Placed placed) {
    var slot = node.children.isEmpty ? null : node.children.first;
    var size = slot == null ? Size.zero : _slotSize(slot);
    // By name and size, for the same reason the placements are: the slot
    // node is a fresh object on every push, and its picture is live anyway.
    if (slot?.name == placed.slot?.name &&
        (slot == null) == (placed.slot == null) &&
        size == placed.slotSize) {
      placed.slot = slot;
      return;
    }
    _unbind(placed);
    placed.slot = slot;
    placed.slotSize = size;
    if (slot == null) return;

    var host = placed.surfaceHost;
    var material = placed.material;
    if (host == null || material == null) return;

    // Twice the density of the artboard, as the probes were: a screen a
    // camera comes close to is read at more than its own pixel size.
    var component = fs.WidgetComponent.bindOnly(
      child: widget.child(slot),
      size: size,
      pixelRatio: 2,
      input: fs.WidgetInput.manual,
      bind: (texture) =>
          material.baseColorTexture = fs.GpuTextureSource(texture),
    );
    component.controller.addListener(_repaint);
    // The first capture is work no frame announces: the slot is drawn,
    // rasterised and wrapped after the frame, and a walk that photographed
    // the frame before it landed showed a bare mesh — one run in two on
    // the static probe (2026-09-07). Announced, the harness waits for it.
    var landed = Completer<void>();
    void onFirst() {
      if (!landed.isCompleted) landed.complete();
    }

    component.controller.addListener(onFirst);
    unawaited(
      RealWork.track(
        landed.future.timeout(const Duration(seconds: 10), onTimeout: () {}),
        label: 'surface "${node.name}" first capture',
      ),
    );
    host.addComponent(component);
    placed.surface = component;
    placed.surfaceHost = host;
  }

  void _unbind(_Placed placed) {
    if (placed.surface case var component?) {
      component.controller.removeListener(_repaint);
      placed.surfaceHost?.removeComponent(component);
    }
    placed.surface = null;
  }

  static fs.Node? _firstMesh(fs.Node node) {
    if (node.mesh != null) return node;
    for (var child in node.children) {
      if (_firstMesh(child) case var found?) return found;
    }
    return null;
  }

  static List<String> _meshNames(fs.Node node) => [
    if (node.mesh != null) node.name,
    for (var child in node.children) ..._meshNames(child),
  ];

  /// A quad one unit square, facing the side the engine's default camera
  /// sits on, with texture coordinates read from the top-left as glTF has
  /// them — the plane the probe rig carries, built here instead of
  /// imported. Which way is front was settled by looking (2026-09-06):
  /// with the other winding the quad is culled at rotation 0 and reads
  /// mirrored at 180.
  static fs.Node _quad() {
    var geometry = fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList([
        -0.5, 0.5, 0, // top-left
        -0.5, -0.5, 0, // bottom-left
        0.5, -0.5, 0, // bottom-right
        0.5, 0.5, 0, // top-right
      ]),
      normals: Float32List.fromList([0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1]),
      texCoords: Float32List.fromList([0, 0, 0, 1, 1, 1, 1, 0]),
      indices: [0, 2, 1, 0, 3, 2],
    );
    return fs.Node(name: 'quad', mesh: fs.Mesh(geometry, fs.UnlitMaterial()));
  }

  /// The placement's engine clip for [name] and its length, made on first
  /// ask and kept; null for no name or a name the asset does not have.
  static (fs.AnimationClip, double)? _clipNamed(_Placed placed, String name) =>
      name.isEmpty ? null : placed.clips[name];

  static double _wrap(double time, double end, bool loop) =>
      loop && end > 0 ? time % end : time;

  /// A string row as rendered — a motion's block writes the clip names.
  static String _fxText(KindNode node, String name) =>
      '${node.fxRendered(name)}';

  /// The window's sun: a directional light aimed by yaw and pitch, in the
  /// scene only while its intensity is above zero.
  void _sunlight() {
    var view = widget.node;
    var intensity = _row(view, 'light');
    if (intensity <= 0) {
      if (_sun case var sun?) {
        _scene.remove(sun);
        _sun = null;
        _sunLight = null;
      }
      return;
    }
    var color = view.fxRendered('lightColor') as SceneColor;
    var light = _sunLight ??= fs.DirectionalLight(intensity: intensity);
    light
      ..intensity = intensity
      ..color = vm.Vector3(
        color.red / 255,
        color.green / 255,
        color.blue / 255,
      );
    var rad = math.pi / 180;
    var yaw = _row(view, 'lightYaw') * rad;
    var pitch = _row(view, 'lightPitch') * rad;
    // Aimed down its local -Z; the node turns it by yaw about Y and pitch
    // up from the horizon, so pitch 90 is straight down.
    var t = vm.Matrix4.identity()
      ..rotateY(yaw)
      ..rotateX(-pitch);
    var sun = _sun;
    if (sun == null) {
      sun = fs.Node(name: 'sun')
        ..addComponent(
          fs.DirectionalLightComponent.aimed(light, vm.Vector3(0, 0, -1)),
        );
      _scene.add(sun);
      _sun = sun;
    }
    sun.localTransform = t;
  }

  fs.PerspectiveCamera _camera() {
    var view = widget.node;
    double row(String name) => _row(view, name);
    var yaw = row('yaw') * math.pi / 180;
    var pitch = row('pitch') * math.pi / 180;
    var d = row('distance');
    var target = vm.Vector3(row('targetX'), row('targetY'), row('targetZ'));
    // The depth range follows the distance: with the engine's fixed 0.1 to
    // 1000 a screen 1.8 units in front of its body, seen face-on from 260
    // units away, lost the fight for depth to the body behind it
    // (measured 2026-09-07: the phone's screen dimmed at yaw 0 and not at
    // ±70). Near at a hundredth of the distance keeps the precision where
    // the placements are.
    var near = math.max(0.05, d / 100);
    return fs.PerspectiveCamera(
      fovRadiansY: row('fov') * math.pi / 180,
      fovNear: near,
      fovFar: math.max(near * 1000, d * 20),
      position:
          target +
          vm.Vector3(
            d * math.cos(pitch) * math.sin(yaw),
            d * math.sin(pitch),
            -d * math.cos(pitch) * math.cos(yaw),
          ),
      target: target,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error case var error?) {
      return ColoredBox(
        color: const Color(0x33FF0000),
        child: Center(child: Text('3D view: $error')),
      );
    }
    _scene.exposure = _row(widget.node, 'exposure');
    _scene.environmentIntensity = _row(widget.node, 'ambient');
    _sunlight();
    return fs.SceneView(_scene, camera: _camera(), autoTick: false);
  }
}
