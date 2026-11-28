import 'dart:async';

import 'package:flutter_scene/scene.dart' as fs;

/// A flutter_scene [fs.Scene], constructed in the root zone.
///
/// The constructor starts flutter_scene's one-time initialisation, and that
/// memoizes futures process-wide — the shader library, and the physical
/// material assets. A future belongs to the zone that created it, and a
/// completed one wakes a later `await` through that zone. A harness runs each
/// entry in a fake-time zone of its own, so a `Scene` built in a field
/// initializer hands every later entry futures of a zone that has finished.
///
/// Gating on `Scene.isReadyToRender` does not avoid it: the importer awaits
/// the material assets itself, unconditionally, in
/// `PhysicallyBasedMaterial.fromDescriptor`. Measured on this app's own audit:
/// the fox probe built the first `Scene`, and the model probe's runtime import
/// waited out the whole real-work ceiling on that await, entry after entry.
/// Built here, the futures belong to the root zone, whose microtasks run on
/// the real event loop every entry shares.
///
/// It also draws every frame it is asked for. From flutter_scene 0.24 a scene
/// shows its previous image again while the GPU is still busy with an earlier
/// frame: two frames may be in flight on macOS, one on Linux and Windows. A
/// walk paints each stop once and photographs that paint, so a held frame is
/// the previous stop's picture. On CI's Linux and Windows runners the first
/// stop of a walk showed the screen from before its seek.
fs.Scene rootZoneScene() =>
    Zone.root.run(fs.Scene.new)..maxGpuFramesInFlight = 0;

/// Loads what a scene here needs before its first frame: flutter_scene's
/// shaders and static resources, and the radiance of its default
/// environment.
///
/// That radiance is prefiltered a band at a time over the frames after the
/// environment is built, and reflections sharpen as each band lands. A frame
/// captured before the last one shows the environment still sharpening, so a
/// walk that starts there differs from every walk after it. Run it inside
/// `RealWork.run`, so a walk waits for it.
Future<void> loadSceneResources() async {
  // Skipped once ready. The memoized futures behind it belong to the root
  // zone, because every `Scene` here is built by `rootZoneScene`.
  if (!fs.Scene.isReadyToRender) {
    await fs.loadBaseShaderLibrary();
    await fs.Scene.initializeStaticResources();
  }
  await fs.Material.getDefaultEnvironmentMap().radianceComplete;
}
