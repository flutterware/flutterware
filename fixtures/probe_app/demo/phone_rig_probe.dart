// A 3D phone rig with a live widget on its screen, driven by a playhead.
//
// The probe behind the scene plugin's 3D question: can the export walk
// photograph a flutter_scene view at a playhead position and get the picture
// of *that* moment — camera and screen content both — forwards, backwards
// and twice? Two things it asks, and neither depends on the mesh:
//
//   * **Lag.** flutter_scene captures the hosted widget asynchronously
//     (`layer.toImage`, then a GPU wrap), and the walk waits only for work
//     that announces itself. The screen shows the playhead's time as a colour
//     and as a number, so a frame photographed with the *previous* stop's
//     screen is visible in the picture and measurable from its centre pixel.
//   * **Determinism.** Auto-exposure stays off, nothing has a random phase,
//     and the camera is a function of `t`. The walk test compares pixels.
//
// The body is a box on purpose. The rig for the product is an imported model
// with a named screen mesh; nothing here changes when it is swapped in.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_scene/scene.dart' as fs;
// ignore: implementation_imports
import 'package:flutterware/src/previews/playhead.dart';
import 'package:flutterware/real_work.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'shell.dart';

import 'package:flutterware_probes/root_zone_scene.dart';

@Preview(name: 'Phone rig probe', wrapper: wrapInApp)
Widget phoneRigProbe() => const PhoneRigProbe();

/// How long the rig's motion runs.
const phoneRigDuration = Duration(seconds: 2);

/// The hue the screen shows at playhead position [p] (0..1), in degrees.
double phoneRigHueAt(double p) => 300 * p;

class PhoneRigProbe extends StatefulWidget {
  const PhoneRigProbe({super.key});

  @override
  State<PhoneRigProbe> createState() => _PhoneRigProbeState();
}

class _PhoneRigProbeState extends State<PhoneRigProbe> {
  final _t = ValueNotifier(Duration.zero);
  late final _playhead = _RigPlayhead(phoneRigDuration, _t);
  late final String _playheadId;
  final _scene = rootZoneScene();
  fs.WidgetComponent? _screen;
  Object? _error;
  var _ready = false;

  @override
  void initState() {
    super.initState();
    _playheadId = PlayheadRegistry.instance.attach(_playhead);
    _t.addListener(_repaint);
    _scene.autoExposure.enabled = false;
    _initialize();
  }

  /// `initializeStaticResources` swallows its own failure into a
  /// `dart:developer` log the tester never forwards, so the shader load is
  /// tried by hand first — its exception says which of the three ways it can
  /// fail (no bundle, wrong target, unreadable) this is.
  Future<void> _initialize() async {
    try {
      // Skipped once ready. The memoized future behind it would strand a
      // later mount if it belonged to an earlier entry's fake-async zone —
      // the trap `ScenarioAssetBundle` exists for, arriving through a
      // dependency's static cache — which is why every `Scene` here is built
      // by `rootZoneScene`, and the gate alone is not enough.
      if (!fs.Scene.isReadyToRender) {
        // Tracked, so a walk waits for the engine rather than photographing
        // the frame before it — see `RealWork`.
        await RealWork.run(() async {
          await fs.loadBaseShaderLibrary();
          await fs.Scene.initializeStaticResources();
        });
      }
      if (!fs.Scene.isReadyToRender) {
        throw StateError('static resources did not become ready');
      }
      if (!mounted) return;
      _build();
      setState(() => _ready = true);
    } catch (e, stack) {
      debugPrint('phone rig: failed: $e\n$stack');
      if (mounted) setState(() => _error = e);
    }
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

  void _build() {
    var body = fs.Node(
      mesh: fs.Mesh(
        fs.CuboidGeometry(vm.Vector3(0.78, 1.6, 0.08)),
        fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.08, 0.08, 0.09, 1),
      ),
    );
    _scene.add(body);
    // Which way the quad faces is settled by looking: the camera orbits on
    // the -Z side, where the engine's default camera sits, and the screen is
    // a hair in front of that face.
    var screen = fs.WidgetComponent(
      // Flipped, because the capture arrives on the quad mirrored left to
      // right on this lane (flutter_tester, Metal) — from either side of it,
      // with the projection's handedness checked against the orbit. Not
      // diagnosed; a product rig owns its screen mesh and its UVs, so the
      // fix lives there rather than in the widget.
      child: Transform.flip(flipX: true, child: _Screen(t: _t)),
      size: const Size(360, 780),
      pixelRatio: 2,
      worldHeight: 1.5,
    );
    screen.controller.addListener(_repaint);
    var screenNode = fs.Node(
      localTransform: vm.Matrix4.translationValues(0, 0, 0.041)
        ..rotateY(math.pi),
    )..addComponent(screen);
    _scene.add(screenNode);
    _screen = screen;
  }

  /// Orbit and dolly as a function of the playhead: 100° of yaw and 2.5 units
  /// closer over the motion.
  fs.PerspectiveCamera _camera() {
    var p = _t.value.inMicroseconds / phoneRigDuration.inMicroseconds;
    var yaw = (-50 + 100 * p) * math.pi / 180;
    var d = 5.5 - 2.5 * p;
    return fs.PerspectiveCamera(
      position: vm.Vector3(d * math.sin(yaw), 0.3, d * math.cos(yaw)),
      target: vm.Vector3.zero(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error case var error?) {
      return Center(child: Text('phone rig: $error'));
    }
    if (!_ready) return const SizedBox.expand();
    return ColoredBox(
      color: const Color(0xFF1C1F26),
      child: fs.SceneView(_scene, camera: _camera(), autoTick: false),
    );
  }
}

/// The screen: the playhead's position as a hue and as a number, so a frame
/// carrying the wrong moment says so in the picture.
class _Screen extends StatelessWidget {
  const _Screen({required this.t});

  final ValueListenable<Duration> t;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: t,
      builder: (context, t, _) {
        var p = t.inMicroseconds / phoneRigDuration.inMicroseconds;
        var color = HSVColor.fromAHSV(
          1,
          phoneRigHueAt(p),
          0.75,
          0.95,
        ).toColor();
        // A Material, because the hosted subtree is its own tree: nothing
        // above the capture supplies one, and a Text without it draws the
        // debug underline — the studio's two-renderers lesson, in a texture.
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

class _RigPlayhead implements Playhead {
  _RigPlayhead(this.duration, this._t);

  @override
  final Duration duration;
  final ValueNotifier<Duration> _t;

  @override
  void seek(Duration position) => _t.value = position;
}
