import 'dart:ui' as ui;

import '../../../info/device_type.dart';
import '../../../info/identifier.dart';
import '../../../info/info.dart';

import 'package:material_ui/material_ui.dart';

part 'frame.g.dart';
part 'screen.g.dart';

final info = DeviceInfo(
  identifier: const DeviceIdentifier(
    TargetPlatform.android,
    DeviceType.phone,
    'samsung-galaxy-s25',
  ),
  name: 'Samsung Galaxy S25',
  pixelRatio: 3,
  frameSize: const Size(872, 1805),
  screenSize: const Size(360, 780),
  safeAreas: const EdgeInsets.only(top: 32, bottom: 24),
  rotatedSafeAreas: const EdgeInsets.only(left: 32, top: 24, bottom: 24),
  framePainter: const _FramePainter(),
  screenPath: _screenPath,
);
