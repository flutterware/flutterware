import 'package:flutter/foundation.dart';

import 'devices.dart';

/// The one place our platform enum meets Flutter's.
///
/// `devices.dart` cannot say this itself — it is pure Dart, so a project's
/// `tool/flutterware.dart` can name a device without importing Flutter — and
/// every lane that stages a device needs it: the previews harness, the
/// scenario binding and the frame drawn around a screen.
extension DevicePlatformTarget on DevicePlatform {
  TargetPlatform get targetPlatform => switch (this) {
    DevicePlatform.ios => TargetPlatform.iOS,
    DevicePlatform.android => TargetPlatform.android,
    DevicePlatform.macos => TargetPlatform.macOS,
    DevicePlatform.windows => TargetPlatform.windows,
    DevicePlatform.linux => TargetPlatform.linux,
  };
}
