// The 3D view and what it draws — the first kinds described as data.
//
// A `View3DNode` is a rectangle on the artboard with an orbit camera; its
// children are placed assets. A `ModelNode` is one such asset with a
// transform and a clip parked at a time. A `SurfaceNode` is the same
// placement with a slot: the first child under it is drawn by the view the
// way it draws any node, and the picture lands on the asset's named mesh —
// a phone, a laptop, a billboard, differing only in which mesh the modeller
// named — or, with no asset at all, on a plain quad floating in the view.
// The renderer that turns them into pixels is registered on the view by the
// app (it needs a 3D engine the core never imports); without one the view
// draws a named placeholder, the way an external node does.
//
// Every row is a number or a string, so the file, the wire and the timeline
// need nothing new: the camera and the transforms are keyed like opacity.
// The model and the surface share their placement rows by name — a row
// name is per kind, which is what `scenePropNamed` reads — so a motion
// keys `positionX` on either the same way.
library;

import 'kind.dart';
import 'model.dart';
import 'motion_model.dart';
import 'props.dart';
import 'values.dart';

const _view3dName = 'View3D';
const _modelName = 'Model';
const _surfaceName = 'Surface';

double _n(Object? v) => (v! as num).toDouble();

/// A 3D view: an orbit camera around a target, drawing its model children.
final SceneKind view3dKind = SceneKind(
  _view3dName,
  constructor: 'View3DNode',
  children: true,
  help:
      'With the Orbit tool (O), drag the window to turn the camera and '
      'scroll to bring it closer. Add a model or a screen from the tree.',
  props: [
    SceneProp.value(
      'yaw',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 0.0,
      animatable: true,
      unit: '°',
      angular: true,
      softMin: -180,
      softMax: 180,
    ),
    SceneProp.value(
      'pitch',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 10.0,
      animatable: true,
      unit: '°',
      angular: true,
      softMin: -89,
      softMax: 89,
    ),
    SceneProp.value(
      'distance',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 5.0,
      animatable: true,
      softMin: 0.1,
      softMax: 500,
    ),
    SceneProp.value(
      'fov',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 45.0,
      animatable: true,
      unit: '°',
      softMin: 10,
      softMax: 120,
    ),
    SceneProp.value(
      'targetX',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 0.0,
      animatable: true,
    ),
    SceneProp.value(
      'targetY',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 0.0,
      animatable: true,
    ),
    SceneProp.value(
      'targetZ',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 0.0,
      animatable: true,
    ),
    SceneProp.value(
      'exposure',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 1.0,
      animatable: true,
      softMin: 0,
      softMax: 4,
    ),
    // The light. `ambient` scales the engine's own studio environment,
    // which is what lights a model with nothing else said; `light` adds a
    // sun — a directional light aimed by yaw and pitch, pitch up from the
    // horizon — and is off at zero.
    SceneProp.value(
      'ambient',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 1.0,
      animatable: true,
      softMin: 0,
      softMax: 4,
    ),
    SceneProp.value(
      'light',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 0.0,
      animatable: true,
      softMin: 0,
      softMax: 10,
    ),
    SceneProp.value(
      'lightYaw',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: -45.0,
      animatable: true,
      unit: '°',
      angular: true,
      softMin: -180,
      softMax: 180,
    ),
    SceneProp.value(
      'lightPitch',
      ScenePropKind.number,
      of: _view3dName,
      defaultValue: 50.0,
      animatable: true,
      unit: '°',
      angular: true,
      softMin: -89,
      softMax: 89,
    ),
    SceneProp.value(
      'lightColor',
      ScenePropKind.color,
      of: _view3dName,
      defaultValue: const SceneColor(0xFFFFFFFF),
      animatable: true,
    ),
  ],
);

/// The rows a placed asset carries, for [of]: which asset, where it sits,
/// how it turns, how big, and which clip is parked at what time.
List<SceneProp> _placement(String of) => [
  SceneProp.value(
    'asset',
    ScenePropKind.string,
    of: of,
    defaultValue: '',
    pick: ScenePick.modelAsset,
  ),
  SceneProp.value(
    'positionX',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
  ),
  SceneProp.value(
    'positionY',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
  ),
  SceneProp.value(
    'positionZ',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
  ),
  SceneProp.value(
    'rotationX',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
    unit: '°',
    angular: true,
    softMin: -180,
    softMax: 180,
  ),
  SceneProp.value(
    'rotationY',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
    unit: '°',
    angular: true,
    softMin: -180,
    softMax: 180,
  ),
  SceneProp.value(
    'rotationZ',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
    unit: '°',
    angular: true,
    softMin: -180,
    softMax: 180,
  ),
  SceneProp.value(
    'size',
    ScenePropKind.number,
    of: of,
    defaultValue: 1.0,
    animatable: true,
    softMin: 0,
    softMax: 4,
  ),
  SceneProp.value(
    'animation',
    ScenePropKind.string,
    of: of,
    defaultValue: '',
    pick: ScenePick.modelClip,
  ),
  SceneProp.value(
    'animationTime',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
    unit: 's',
    softMin: 0,
    softMax: 10,
  ),
  // A time past the clip's end wraps round rather than freezing on the
  // last pose: a run keyed over three seconds keeps running. Off, the
  // engine's own clamp holds the end.
  SceneProp.value('loop', ScenePropKind.boolean, of: of, defaultValue: true),
  // A second clip, and how much of it: what a crossfade on the timeline
  // hands the placement while two blocks overlap. Written by the motion,
  // mostly, though nothing stops a file parking a blend.
  SceneProp.value(
    'animation2',
    ScenePropKind.string,
    of: of,
    defaultValue: '',
    pick: ScenePick.modelClip,
  ),
  SceneProp.value(
    'animationTime2',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
    unit: 's',
    softMin: 0,
    softMax: 10,
  ),
  SceneProp.value(
    'blend',
    ScenePropKind.number,
    of: of,
    defaultValue: 0.0,
    animatable: true,
    softMin: 0,
    softMax: 1,
  ),
  // A colour multiplied into every material of the asset — white leaves
  // the modeller's colours alone. A placement's own copy of its materials,
  // so two placements of one asset can differ.
  SceneProp.value(
    'tint',
    ScenePropKind.color,
    of: of,
    defaultValue: const SceneColor(0xFFFFFFFF),
    animatable: true,
  ),
];

/// One placed asset inside a 3D view.
final SceneKind modelKind = SceneKind(
  _modelName,
  constructor: 'ModelNode',
  props: _placement(_modelName),
);

/// A placed asset with a slot: its first child is drawn onto the mesh named
/// by `mesh` — or, with no asset, onto a quad one unit tall (times `size`)
/// whose width follows the child's box.
final SceneKind surfaceKind = SceneKind(
  _surfaceName,
  constructor: 'SurfaceNode',
  children: true,
  props: [
    ..._placement(_surfaceName),
    SceneProp.value(
      'mesh',
      ScenePropKind.string,
      of: _surfaceName,
      defaultValue: '',
      pick: ScenePick.modelMesh,
    ),
  ],
);

/// What a scene file calls. The named parameters are the rows, and the
/// common ones are every node's; the body is one map.
class View3DNode extends KindNode {
  View3DNode({
    super.name,
    super.x,
    super.y,
    super.width,
    super.height,
    super.fill,
    super.borderColor,
    super.borderWidth,
    super.corner,
    super.cornerTopLeft,
    super.cornerTopRight,
    super.cornerBottomRight,
    super.cornerBottomLeft,
    super.opacity,
    super.minWidth,
    super.maxWidth,
    super.minHeight,
    super.maxHeight,
    super.visible,
    double yaw = 0,
    double pitch = 10,
    double distance = 5,
    double fov = 45,
    double targetX = 0,
    double targetY = 0,
    double targetZ = 0,
    double exposure = 1,
    double ambient = 1,
    double light = 0,
    double lightYaw = -45,
    double lightPitch = 50,
    SceneColor lightColor = const SceneColor(0xFFFFFFFF),
    List<SceneNode> children = const [],
  }) : super(
         view3dKind,
         values: {
           'yaw': yaw,
           'pitch': pitch,
           'distance': distance,
           'fov': fov,
           'targetX': targetX,
           'targetY': targetY,
           'targetZ': targetZ,
           'exposure': exposure,
           'ambient': ambient,
           'light': light,
           'lightYaw': lightYaw,
           'lightPitch': lightPitch,
           'lightColor': lightColor,
         },
       ) {
    this.children.addAll(children);
  }

  double get yaw => _n(fxRendered('yaw'));
  double get pitch => _n(fxRendered('pitch'));
  double get distance => _n(fxRendered('distance'));
  double get fov => _n(fxRendered('fov'));
  double get targetX => _n(fxRendered('targetX'));
  double get targetY => _n(fxRendered('targetY'));
  double get targetZ => _n(fxRendered('targetZ'));
  double get exposure => _n(fxRendered('exposure'));
  double get ambient => _n(fxRendered('ambient'));
  double get light => _n(fxRendered('light'));
  double get lightYaw => _n(fxRendered('lightYaw'));
  double get lightPitch => _n(fxRendered('lightPitch'));
  SceneColor get lightColor => fxRendered('lightColor') as SceneColor;

  /// The models under this view, in order.
  Iterable<ModelNode> get models => children.whereType<ModelNode>();

  /// The surfaces under this view, in order.
  Iterable<SurfaceNode> get surfaces => children.whereType<SurfaceNode>();
}

class ModelNode extends KindNode {
  ModelNode({
    super.name,
    super.x,
    super.y,
    super.width,
    super.height,
    super.fill,
    super.borderColor,
    super.borderWidth,
    super.corner,
    super.cornerTopLeft,
    super.cornerTopRight,
    super.cornerBottomRight,
    super.cornerBottomLeft,
    super.opacity,
    super.minWidth,
    super.maxWidth,
    super.minHeight,
    super.maxHeight,
    super.visible,
    String asset = '',
    double positionX = 0,
    double positionY = 0,
    double positionZ = 0,
    double rotationX = 0,
    double rotationY = 0,
    double rotationZ = 0,
    double size = 1,
    String animation = '',
    double animationTime = 0,
    bool loop = true,
    String animation2 = '',
    double animationTime2 = 0,
    double blend = 0,
    SceneColor tint = const SceneColor(0xFFFFFFFF),
  }) : super(
         modelKind,
         values: {
           'asset': asset,
           'positionX': positionX,
           'positionY': positionY,
           'positionZ': positionZ,
           'rotationX': rotationX,
           'rotationY': rotationY,
           'rotationZ': rotationZ,
           'size': size,
           'animation': animation,
           'animationTime': animationTime,
           'loop': loop,
           'animation2': animation2,
           'animationTime2': animationTime2,
           'blend': blend,
           'tint': tint,
         },
       );

  String get asset => values['asset'] as String? ?? '';
  double get positionX => _n(fxRendered('positionX'));
  double get positionY => _n(fxRendered('positionY'));
  double get positionZ => _n(fxRendered('positionZ'));
  double get rotationX => _n(fxRendered('rotationX'));
  double get rotationY => _n(fxRendered('rotationY'));
  double get rotationZ => _n(fxRendered('rotationZ'));
  double get size => _n(fxRendered('size'));
  String get animation => values['animation'] as String? ?? '';
  double get animationTime => _n(fxRendered('animationTime'));
  bool get loop => values['loop'] as bool? ?? true;
  String get animation2 => values['animation2'] as String? ?? '';
  double get animationTime2 => _n(fxRendered('animationTime2'));
  double get blend => _n(fxRendered('blend'));
  SceneColor get tint => fxRendered('tint') as SceneColor;
}

/// A placed asset whose named mesh shows the node's first child.
class SurfaceNode extends KindNode {
  SurfaceNode({
    super.name,
    super.x,
    super.y,
    super.width,
    super.height,
    super.fill,
    super.borderColor,
    super.borderWidth,
    super.corner,
    super.cornerTopLeft,
    super.cornerTopRight,
    super.cornerBottomRight,
    super.cornerBottomLeft,
    super.opacity,
    super.minWidth,
    super.maxWidth,
    super.minHeight,
    super.maxHeight,
    super.visible,
    String asset = '',
    String mesh = '',
    double positionX = 0,
    double positionY = 0,
    double positionZ = 0,
    double rotationX = 0,
    double rotationY = 0,
    double rotationZ = 0,
    double size = 1,
    String animation = '',
    double animationTime = 0,
    bool loop = true,
    String animation2 = '',
    double animationTime2 = 0,
    double blend = 0,
    SceneColor tint = const SceneColor(0xFFFFFFFF),
    List<SceneNode> children = const [],
  }) : super(
         surfaceKind,
         values: {
           'asset': asset,
           'mesh': mesh,
           'positionX': positionX,
           'positionY': positionY,
           'positionZ': positionZ,
           'rotationX': rotationX,
           'rotationY': rotationY,
           'rotationZ': rotationZ,
           'size': size,
           'animation': animation,
           'animationTime': animationTime,
           'loop': loop,
           'animation2': animation2,
           'animationTime2': animationTime2,
           'blend': blend,
           'tint': tint,
         },
       ) {
    this.children.addAll(children);
  }

  String get asset => values['asset'] as String? ?? '';
  String get mesh => values['mesh'] as String? ?? '';
  double get positionX => _n(fxRendered('positionX'));
  double get positionY => _n(fxRendered('positionY'));
  double get positionZ => _n(fxRendered('positionZ'));
  double get rotationX => _n(fxRendered('rotationX'));
  double get rotationY => _n(fxRendered('rotationY'));
  double get rotationZ => _n(fxRendered('rotationZ'));
  double get size => _n(fxRendered('size'));
  String get animation => values['animation'] as String? ?? '';
  double get animationTime => _n(fxRendered('animationTime'));
  bool get loop => values['loop'] as bool? ?? true;
  String get animation2 => values['animation2'] as String? ?? '';
  double get animationTime2 => _n(fxRendered('animationTime2'));
  double get blend => _n(fxRendered('blend'));
  SceneColor get tint => fxRendered('tint') as SceneColor;

  /// What the surface shows: its first child, if any.
  SceneNode? get slot => children.isEmpty ? null : children.first;
}

/// The typed `animate()` a motion file spells — the one place per kind the
/// table cannot write, because it is a Dart signature.
extension View3DNodeAnimate on View3DNode {
  AnimateGroup animate({
    MotionTrack? opacity,
    MotionTrack? translateX,
    MotionTrack? translateY,
    MotionTrack? scale,
    MotionTrack? rotate,
    MotionTrack? yaw,
    MotionTrack? pitch,
    MotionTrack? distance,
    MotionTrack? fov,
    MotionTrack? targetX,
    MotionTrack? targetY,
    MotionTrack? targetZ,
    MotionTrack? exposure,
    MotionTrack? ambient,
    MotionTrack? light,
    MotionTrack? lightYaw,
    MotionTrack? lightPitch,
    MotionTrack? lightColor,
  }) => animateNode(this, {
    'opacity': opacity,
    'translateX': translateX,
    'translateY': translateY,
    'scale': scale,
    'rotate': rotate,
    'yaw': yaw,
    'pitch': pitch,
    'distance': distance,
    'fov': fov,
    'targetX': targetX,
    'targetY': targetY,
    'targetZ': targetZ,
    'exposure': exposure,
    'ambient': ambient,
    'light': light,
    'lightYaw': lightYaw,
    'lightPitch': lightPitch,
    'lightColor': lightColor,
  });
}

extension ModelNodeAnimate on ModelNode {
  AnimateGroup animate({
    MotionTrack? opacity,
    MotionTrack? translateX,
    MotionTrack? translateY,
    MotionTrack? scale,
    MotionTrack? rotate,
    MotionTrack? positionX,
    MotionTrack? positionY,
    MotionTrack? positionZ,
    MotionTrack? rotationX,
    MotionTrack? rotationY,
    MotionTrack? rotationZ,
    MotionTrack? size,
    MotionTrack? animationTime,
    MotionTrack? animationTime2,
    MotionTrack? blend,
    MotionTrack? tint,
  }) => animateNode(this, {
    'opacity': opacity,
    'translateX': translateX,
    'translateY': translateY,
    'scale': scale,
    'rotate': rotate,
    'positionX': positionX,
    'positionY': positionY,
    'positionZ': positionZ,
    'rotationX': rotationX,
    'rotationY': rotationY,
    'rotationZ': rotationZ,
    'size': size,
    'animationTime': animationTime,
    'animationTime2': animationTime2,
    'blend': blend,
    'tint': tint,
  });
}

extension SurfaceNodeAnimate on SurfaceNode {
  AnimateGroup animate({
    MotionTrack? opacity,
    MotionTrack? translateX,
    MotionTrack? translateY,
    MotionTrack? scale,
    MotionTrack? rotate,
    MotionTrack? positionX,
    MotionTrack? positionY,
    MotionTrack? positionZ,
    MotionTrack? rotationX,
    MotionTrack? rotationY,
    MotionTrack? rotationZ,
    MotionTrack? size,
    MotionTrack? animationTime,
    MotionTrack? animationTime2,
    MotionTrack? blend,
    MotionTrack? tint,
  }) => animateNode(this, {
    'opacity': opacity,
    'translateX': translateX,
    'translateY': translateY,
    'scale': scale,
    'rotate': rotate,
    'positionX': positionX,
    'positionY': positionY,
    'positionZ': positionZ,
    'rotationX': rotationX,
    'rotationY': rotationY,
    'rotationZ': rotationZ,
    'size': size,
    'animationTime': animationTime,
    'animationTime2': animationTime2,
    'blend': blend,
    'tint': tint,
  });
}
