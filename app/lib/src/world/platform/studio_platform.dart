import 'dart:io';

import 'package:flutterware/devices.dart';

import '../guest_platform.dart';
import 'device_info.dart';
import 'firebase.dart';
import 'links.dart';
import 'notifications.dart';
import 'package_info.dart';
import 'permissions.dart';
import 'preferences.dart';
import 'secure_storage.dart';
import 'system.dart';
import 'timezone.dart';
import 'urls.dart';

export 'links.dart' show GuestLinks;
export 'notifications.dart' show GuestNotification, GuestNotifications;
export 'system.dart' show GuestSystem;
export 'urls.dart' show GuestUrls;

/// Everything the studio answers for one person's app, and the handles a
/// world acts through: links to open, notifications shown, URLs opened, the
/// cursor and the lifecycle.
///
/// `path_provider` is not here: on macOS its Swift half became a direct call
/// into Foundation, which runs inside the guest. Isolation for it comes from
/// the guest's environment instead — see `guestEnvironment`.
class StudioPlatform {
  StudioPlatform({
    required String person,
    required Directory home,
    required String package,
    Device device = Devices.iphone16,
  }) : platform = GuestPlatform(person: person, home: home) {
    answerPreferences(platform);
    answerSecureStorage(platform);
    answerPackageInfo(platform, package: package);
    answerFirebaseCore(platform);
    answerDeviceInfo(platform, device: device, person: person);
    answerTimezone(platform);
    answerPermissions(platform);
    links = GuestLinks(platform);
    notifications = GuestNotifications(platform);
    urls = GuestUrls(platform);
    system = GuestSystem(platform);
  }

  final GuestPlatform platform;
  late final GuestLinks links;
  late final GuestNotifications notifications;
  late final GuestUrls urls;
  late final GuestSystem system;
}
