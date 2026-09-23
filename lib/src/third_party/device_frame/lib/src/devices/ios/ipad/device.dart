import 'package:material_ui/material_ui.dart';

import '../../../info/device_type.dart';
import '../../../info/identifier.dart';
import '../../../info/info.dart';

part 'frame.g.dart';
part 'screen.g.dart';

final info = DeviceInfo(
  identifier: const DeviceIdentifier(
    TargetPlatform.iOS,
    DeviceType.tablet,
    'ipad',
  ),
  name: 'iPad',
  pixelRatio: 2.0,
  frameSize: const Size(1673, 2409),
  screenSize: const Size(810.0, 1080.0),
  safeAreas: const EdgeInsets.only(
    left: 0.0,
    top: 20.0,
    right: 0.0,
    bottom: 0.0,
  ),
  rotatedSafeAreas: const EdgeInsets.only(
    left: 0.0,
    top: 20.0,
    right: 0.0,
    bottom: 0.0,
  ),
  framePainter: const _FramePainter(),
  screenPath: _screenPath,
);
