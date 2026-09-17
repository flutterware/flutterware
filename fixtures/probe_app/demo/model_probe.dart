// The second 3D probe: an imported asset with named parts and a baked clip.
//
// `assets/models/probe_rig.glb` (written by `tool/make_probe_rig_glb.dart`)
// is a device with a `Body`, a `Screen` whose texture coordinates we authored,
// and a `Lid` with one clip, `Open`. The probe asks what the design spec
// (`docs/superpowers/specs/2026-09-05-scene-3d-view-design.md` § 7.2) lists:
//
//   * the asset loads at run time with no build hook;
//   * a surface is found by name and a live widget bound to its material;
//   * the clip is scrubbed by the playhead — clip time is a number track;
//   * forwards, again and backwards walks are byte-identical;
//   * text on a surface whose UVs we own reads the right way round.
//
// The camera orbits and dollies as in the first probe; the lid opens over
// the same two seconds. Loading goes through `RealWork.run`, which is
// what lets the walk wait for a model unpacked on an isolate instead of
// photographing the empty frame before it — the readiness door of § 5 — and
// what keeps a dependency's memoized futures from stranding a later mount.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_scene/scene.dart' as fs;
// ignore: implementation_imports
import 'package:flutterware/src/previews/playhead.dart';
import 'package:flutterware/real_work.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'shell.dart';

import 'package:flutterware_probes/root_zone_scene.dart';

@Preview(name: 'Model probe', wrapper: wrapInApp)
Widget modelProbe() => const ModelProbe();

/// The same asset through the build-time path (spec § 7.6): the example's
/// `hook/build.dart` converted it, and `loadScene` reads the `.fsceneb`.
@Preview(name: 'Model probe, built', wrapper: wrapInApp)
Widget modelProbeBuilt() => const ModelProbe(built: true);

/// The same rig built in Blender and exported by Blender's own glTF exporter
/// (`tool/make_probe_rig_blender.py`, spec § 7.5): names, axes, UVs and the
/// clip as a modeller's file carries them.
@Preview(name: 'Model probe, Blender export', wrapper: wrapInApp)
Widget modelProbeBlender() =>
    const ModelProbe(built: true, asset: 'assets/models/probe_rig_blender.glb');

const modelProbeDuration = Duration(seconds: 2);

/// The hue the screen shows at playhead position [p] (0..1), in degrees.
double modelProbeHueAt(double p) => 300 * p;

class ModelProbe extends StatefulWidget {
  const ModelProbe({
    super.key,
    this.built = false,
    this.asset = 'assets/models/probe_rig.glb',
  });

  /// Load the hook's `.fsceneb` through `loadScene` instead of importing the
  /// glTF at run time.
  final bool built;

  /// The rig's source path under `assets/`.
  final String asset;

  @override
  State<ModelProbe> createState() => _ModelProbeState();
}

class _ModelProbeState extends State<ModelProbe> {
  final _t = ValueNotifier(Duration.zero);
  late final _playhead = _ModelPlayhead(this);
  late final String _playheadId;
  final _scene = rootZoneScene();
  fs.WidgetComponent? _screen;
  fs.AnimationClip? _open;
  Object? _error;
  var _ready = false;
  var _started = false;

  @override
  void initState() {
    super.initState();
    _playheadId = PlayheadRegistry.instance.attach(_playhead);
    _t.addListener(_repaint);
    _scene.autoExposure.enabled = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Read through the bundle the tree provides, not `rootBundle`: the
    // harness counts reads on its own bundle as work in flight; a
    // `rootBundle` read is invisible to the walk.
    _initialize(DefaultAssetBundle.of(context));
  }

  Future<void> _initialize(AssetBundle bundle) async {
    try {
      var model = await RealWork.run(
        () => _load(bundle, widget.asset, built: widget.built),
      );
      if (!mounted) return;
      _mount(model);
      setState(() => _ready = true);
    } catch (e, stack) {
      debugPrint('model probe: failed: $e\n$stack');
      if (mounted) setState(() => _error = e);
    }
  }

  static Future<fs.Node> _load(
    AssetBundle bundle,
    String asset, {
    required bool built,
  }) async {
    // Skipped once ready. The memoized futures behind it belong to the root
    // zone, because every `Scene` here is built by `rootZoneScene`.
    if (!fs.Scene.isReadyToRender) {
      await fs.loadBaseShaderLibrary();
      await fs.Scene.initializeStaticResources();
    }
    if (built) return fs.loadScene(asset, bundle: bundle);
    var bytes = await bundle.load(asset);
    return fs.Node.fromGlbBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  void _mount(fs.Node model) {
    _scene.add(model);

    // The surface, by the name the modeller gave it.
    var screenNode = model.getChildByName('Screen');
    if (screenNode == null) {
      throw StateError('no mesh named Screen in the asset');
    }
    var material = screenNode.mesh!.primitives.first.material;
    if (material is! fs.PhysicallyBasedMaterial) {
      throw StateError('Screen material is ${material.runtimeType}');
    }
    var screen = fs.WidgetComponent.bindOnly(
      child: _Screen(t: _t),
      size: const Size(360, 780),
      pixelRatio: 2,
      bind: (texture) =>
          material.baseColorTexture = fs.GpuTextureSource(texture),
    );
    screen.controller.addListener(_repaint);
    screenNode.addComponent(screen);
    _screen = screen;

    // The clip, by name, parked — the playhead moves it.
    var animation = model.findAnimationByName('Open');
    if (animation == null) throw StateError('no clip named Open');
    _open = model.createAnimationClip(animation)
      ..seek(_t.value.inMicroseconds / 1e6);
  }

  @override
  void dispose() {
    PlayheadRegistry.instance.detach(_playheadId);
    _t.removeListener(_repaint);
    _screen?.controller.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _seek(Duration position) {
    _t.value = position;
    _open?.seek(position.inMicroseconds / 1e6);
  }

  /// The engine's default camera sits on -Z looking at the origin; the asset's
  /// +Z face lands there after the importer's handedness flip.
  fs.PerspectiveCamera _camera() {
    var p = _t.value.inMicroseconds / modelProbeDuration.inMicroseconds;
    var yaw = (-50 + 100 * p) * math.pi / 180;
    var d = 5.5 - 2.5 * p;
    return fs.PerspectiveCamera(
      position: vm.Vector3(d * math.sin(yaw), 0.6, -d * math.cos(yaw)),
      target: vm.Vector3.zero(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error case var error?) {
      return Center(child: Text('model probe: $error'));
    }
    if (!_ready) return const SizedBox.expand();
    return ColoredBox(
      color: const Color(0xFF1C1F26),
      child: fs.SceneView(_scene, camera: _camera(), autoTick: false),
    );
  }
}

class _Screen extends StatelessWidget {
  const _Screen({required this.t});

  final ValueListenable<Duration> t;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: t,
      builder: (context, t, _) {
        var p = t.inMicroseconds / modelProbeDuration.inMicroseconds;
        var color = HSVColor.fromAHSV(
          1,
          modelProbeHueAt(p),
          0.75,
          0.95,
        ).toColor();
        return Material(
          color: color,
          child: Column(
            children: [
              const SizedBox(height: 160),
              Text(
                '${t.inMilliseconds} ms',
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 40),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: p,
                    child: Container(height: 24, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModelPlayhead implements Playhead {
  _ModelPlayhead(this._state);

  final _ModelProbeState _state;

  @override
  Duration get duration => modelProbeDuration;

  @override
  void seek(Duration position) => _state._seek(position);
}
