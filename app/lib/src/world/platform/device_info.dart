import 'package:flutterware/devices.dart';

import '../guest_platform.dart';

/// `device_info_plus` — what device this is — answered as the device the
/// person is on: an iPhone 16 says it is one. It is not a physical device,
/// which is true, so an app that treats simulators differently sees that.
///
/// **One answer, two shapes.** The plugin's channel is the same on iOS and on
/// macOS; which fields it reads depends on which of `iosInfo` and `macOsInfo`
/// the app asks for — and an app asks by `dart:io`'s `Platform`, which in a
/// guest says macOS whatever the look. A real app did exactly that. So the
/// answer carries the iOS fields and the macOS ones, both describing the
/// person's device, and whichever the app parses is there.
void answerDeviceInfo(
  GuestPlatform platform, {
  required Device device,
  required String person,
}) {
  var family = device.kind == DeviceKind.tablet ? 'iPad' : 'iPhone';
  platform.methods('dev.fluttercommunity.plus/device_info', {
    'getDeviceInfo': (_) => {
      // Both.
      'model': family,
      'modelName': device.label,
      // iOS.
      'name': "$person's ${device.label}",
      'systemName': 'iOS',
      'systemVersion': '26.0',
      'localizedModel': family,
      // Stable per person, as the real one is per app and device.
      'identifierForVendor': _uuidOf(person),
      'freeDiskSize': 64 << 30,
      'totalDiskSize': 128 << 30,
      'isPhysicalDevice': false,
      'physicalRamSize': 8192,
      'availableRamSize': 4096,
      'isiOSAppOnMac': false,
      'isiOSAppOnVision': false,
      'utsname': {
        'sysname': 'Darwin',
        'nodename': person,
        'release': '25.0.0',
        'version': 'Darwin Kernel Version 25.0.0',
        'machine': device.id,
      },
      // macOS.
      'computerName': "$person's ${device.label}",
      'hostName': person.toLowerCase(),
      'arch': 'arm64',
      'kernelVersion': 'Darwin Kernel Version 25.0.0',
      'osRelease': '26.0',
      'majorVersion': 26,
      'minorVersion': 0,
      'patchVersion': 0,
      'activeCPUs': 6,
      'memorySize': 8 << 30,
      'cpuFrequency': 0,
      'systemGUID': _uuidOf(person),
    },
  });
}

String _uuidOf(String person) {
  var hex = person.codeUnits
      .fold(
        0x811c9dc5,
        (hash, unit) => ((hash ^ unit) * 0x01000193) & 0xffffffff,
      )
      .toRadixString(16)
      .padLeft(8, '0');
  return '$hex-0000-4000-8000-${hex.padRight(12, '0')}'.toUpperCase();
}
