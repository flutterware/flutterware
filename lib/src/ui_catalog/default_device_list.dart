import 'package:flutter/widgets.dart';

import '../device_frames.dart';
import '../device_platform.dart';
import '../devices.dart';

/// The previews web page's phones and tablets: the studio's table, in the
/// studio's frames, so an entry exported to the web is staged on the same
/// screens it was checked on in the panel.
final defaultMobileDevices = {
  for (var device in Devices.all)
    if (device.kind != DeviceKind.desktop)
      deviceFrameFor(device)!: device.label,
};

/// The table's desktop windows, each shown on a laptop.
///
/// The studio draws no silhouette around a window — its panel is already
/// desktop-shaped — but this page frames whatever it shows, so a window sits
/// on `device_frame`'s generic laptop at exactly the table's size, with a
/// margin of desktop around it.
final defaultDesktopDevices = {
  for (var device in Devices.all)
    if (device.kind == DeviceKind.desktop) _onLaptop(device): device.label,
};

/// [Devices.defaultPhone], as the page frames it.
DeviceInfo get defaultMobileDevice =>
    _framed(defaultMobileDevices, Devices.defaultPhone);

/// The table's standard window, as the page frames it.
DeviceInfo get defaultDesktopDevice =>
    _framed(defaultDesktopDevices, Devices.window);

/// The key [device] is filed under — looked up rather than built again, because
/// a frame whose screen path is a fresh `Path` is a different value, and the
/// page's choice is compared against these keys. By label, which every frame
/// carries as its name: a borrowed body keeps its own artwork's identifier.
DeviceInfo _framed(Map<DeviceInfo, String> frames, Device device) =>
    frames.entries.firstWhere((entry) => entry.value == device.label).key;

DeviceInfo _onLaptop(Device device) {
  var desktop = Size(device.width + 300, device.height + 300);
  return DeviceInfo.genericLaptop(
    platform: device.platform.targetPlatform,
    id: device.id,
    name: device.label,
    screenSize: desktop,
    windowPosition: Rect.fromCenter(
      center: desktop.center(Offset.zero),
      width: device.width,
      height: device.height,
    ),
    pixelRatio: device.pixelRatio,
  );
}
