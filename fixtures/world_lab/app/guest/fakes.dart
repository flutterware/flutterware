/// The lab app's plugins, replaced at their platform interfaces for the
/// embedded guest.
///
/// A guest has no platform behind it: a plugin's platform call is answered
/// empty and throws `MissingPluginException`. This is candidate 1 of the guest
/// experiment — the app's own plugins replaced in Dart, from a guest-only file,
/// the way its tests would replace them — and every line here is a
/// project-side line on the experiment's scorecard.
///
/// What is not here runs for real: `sqlite3` through its build hook, HTTP and
/// sockets through `dart:io`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:app_links_platform_interface/app_links_platform_interface.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Installs every fake. [home] is this person's own directory, which is what
/// keeps two people's files apart without the app knowing there are two.
///
/// [answerChannel] answers a channel a plugin calls directly, for a plugin
/// with no platform interface to replace. Every plugin here has one.
void installGuestFakes({
  required Directory home,
  required void Function(
    String channel,
    Future<Object?> Function(MethodCall call) answer,
  )
  answerChannel,
}) {
  PathProviderPlatform.instance = _Paths(home);
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  // Meant for tests, and a guest is exactly where a test's replacement belongs.
  // ignore: invalid_use_of_visible_for_testing_member
  PackageInfo.setMockInitialValues(
    appName: 'Pickup',
    packageName: 'dev.flutterware.worldlab.worldLabApp',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );
  AppLinksPlatform.instance = _Links();
  FlutterLocalNotificationsPlatform.instance = _Notifications();
  UrlLauncherPlatform.instance = _Urls();
}

class _Paths extends PathProviderPlatform {
  _Paths(this.home);

  final Directory home;

  Future<String> _dir(String name) async {
    var dir = Directory('${home.path}/$name');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getTemporaryPath() => _dir('tmp');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');

  @override
  Future<String?> getLibraryPath() => _dir('library');

  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');

  @override
  Future<String?> getDownloadsPath() => _dir('downloads');
}

/// No link opened the app, and none arrives: the world has no way to deliver
/// one yet.
class _Links extends AppLinksPlatform {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Future<String?> getInitialLinkString() async => null;

  @override
  Future<Uri?> getLatestLink() async => null;

  @override
  Future<String?> getLatestLinkString() async => null;

  @override
  Stream<Uri> get uriLinkStream => const Stream.empty();

  @override
  Stream<String> get stringLinkStream => const Stream.empty();
}

/// Not the macOS implementation, so the plugin's every call finds no
/// implementation for the platform and does nothing.
class _Notifications extends FlutterLocalNotificationsPlatform {}

class _Urls extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    print('world_lab: would open $url');
    return true;
  }
}
