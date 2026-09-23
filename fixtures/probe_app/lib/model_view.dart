// A 3D view as an external widget: version zero of the scene plugin's 3D
// offer, with no change to the scene model.
//
// The spec (`docs/superpowers/specs/2026-09-05-scene-3d-view-design.md` § 3)
// describes a view node with placements, an orbit camera and surfaces. This
// is the part of it an external widget can carry today: one asset, the orbit
// camera, and one clip scrubbed by a number — every argument a `double` or a
// `String`, so the timeline keyframes the orbit and the clip time the way it
// keyframes any external argument, the canvas shows it live, and the video
// action walks it. What it cannot carry is a surface slot, because content
// is not an argument; that is the node kind's reason to exist.
//
// Loading goes through `RealWork.run`, so a walk waits for the model, and
// the asset is the build-time `.fsceneb` the app's hook wrote.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutterware/real_work.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'root_zone_scene.dart';

class ModelView extends StatefulWidget {
  const ModelView({
    super.key,
    required this.asset,
    this.yaw = 0,
    this.pitch = 10,
    this.distance = 5,
    this.fov = 45,
    this.clip = '',
    this.clipTime = 0,
  });

  /// The model's source path under `assets/`, as the asset pipeline names it.
  final String asset;

  /// Orbit angles in degrees around the model's centre, and the camera's
  /// distance from it, in the model's own units.
  final double yaw;
  final double pitch;
  final double distance;

  /// Vertical field of view, degrees.
  final double fov;

  /// A clip baked into the asset, by name, and where it is parked, in seconds.
  /// Empty means no clip.
  final String clip;
  final double clipTime;

  @override
  State<ModelView> createState() => _ModelViewState();
}

class _ModelViewState extends State<ModelView> {
  final _scene = rootZoneScene();
  fs.Node? _model;

  /// Where the orbit looks: the model's bounds centre once it is loaded, so
  /// an asset whose origin is at its feet still sits in the middle.
  var _target = vm.Vector3.zero();
  fs.AnimationClip? _clip;
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
    if (_started) return;
    _started = true;
    _load(DefaultAssetBundle.of(context));
  }

  @override
  void didUpdateWidget(ModelView old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset) {
      // A different asset is a different view; the simplest honest answer.
      if (_model case var model?) _scene.remove(model);
      _model = null;
      _clip = null;
      _started = false;
      didChangeDependencies();
      return;
    }
    if (old.clip != widget.clip) _bindClip();
    _clip?.seek(widget.clipTime);
  }

  Future<void> _load(AssetBundle bundle) async {
    try {
      var model = await RealWork.run(() async {
        if (!fs.Scene.isReadyToRender) {
          await fs.loadBaseShaderLibrary();
          await fs.Scene.initializeStaticResources();
        }
        return fs.loadScene(widget.asset, bundle: bundle);
      });
      if (!mounted) return;
      _scene.add(model);
      _target = model.combinedLocalBounds?.center ?? vm.Vector3.zero();
      setState(() => _model = model);
      _bindClip();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _bindClip() {
    var model = _model;
    if (model == null) return;
    if (_clip case var clip?) {
      model.removeAnimationClip(clip);
      _clip = null;
    }
    if (widget.clip.isEmpty) return;
    var animation = model.findAnimationByName(widget.clip);
    if (animation == null) {
      setState(() => _error = StateError('no clip named ${widget.clip}'));
      return;
    }
    _clip = model.createAnimationClip(animation)..seek(widget.clipTime);
  }

  fs.PerspectiveCamera _camera() {
    var yaw = widget.yaw * math.pi / 180;
    var pitch = widget.pitch * math.pi / 180;
    var d = widget.distance;
    return fs.PerspectiveCamera(
      fovRadiansY: widget.fov * math.pi / 180,
      position:
          _target +
          vm.Vector3(
            d * math.cos(pitch) * math.sin(yaw),
            d * math.sin(pitch),
            -d * math.cos(pitch) * math.cos(yaw),
          ),
      target: _target.clone(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error case var error?) {
      return ColoredBox(
        color: const Color(0x33FF0000),
        child: Center(child: Text('ModelView: $error')),
      );
    }
    if (_model == null) return const SizedBox.expand();
    return fs.SceneView(_scene, camera: _camera(), autoTick: false);
  }
}
