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
fs.Scene rootZoneScene() => Zone.root.run(fs.Scene.new);
