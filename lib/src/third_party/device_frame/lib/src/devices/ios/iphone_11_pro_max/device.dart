import 'dart:ui' as ui;

import '../../../info/device_type.dart';
import '../../../info/identifier.dart';
import '../../../info/info.dart';

import 'package:material_ui/material_ui.dart';

part 'frame.g.dart';
part 'screen.g.dart';

final info = DeviceInfo(
  identifier: const DeviceIdentifier(
    TargetPlatform.iOS,
    DeviceType.phone,
    'iphone-11-pro-max',
  ),
  name: 'iPhone 11 Pro Max',
  pixelRatio: 3,
  frameSize: const Size(873, 1756),
  screenSize: const Size(414, 896),
  safeAreas: const EdgeInsets.only(top: 44, bottom: 34),
  rotatedSafeAreas: const EdgeInsets.only(left: 44, right: 44, bottom: 21),
  framePainter: const _FramePainter(),
  screenPath: _screenPath,
);
