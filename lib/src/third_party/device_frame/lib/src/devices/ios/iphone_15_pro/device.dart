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
    'iphone-15-pro',
  ),
  name: 'iPhone 15 Pro',
  pixelRatio: 3,
  frameSize: const Size(873, 1792),
  screenSize: const Size(393, 852),
  safeAreas: const EdgeInsets.only(top: 59, bottom: 34),
  rotatedSafeAreas: const EdgeInsets.only(left: 59, right: 59, bottom: 21),
  framePainter: const _FramePainter(),
  screenPath: _screenPath,
);
