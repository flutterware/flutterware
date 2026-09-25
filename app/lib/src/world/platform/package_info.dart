import 'dart:io';

import '../guest_platform.dart';

/// `package_info_plus` — the app's own name and version — answered from the
/// package's pubspec. The version has to be the true one: a server that
/// refuses outdated apps checks it, and a guest reporting `1.0.0` was refused
/// (`2026-09-25-worlds-guest-phase1-findings.md`, finding 8).
void answerPackageInfo(GuestPlatform platform, {required String package}) {
  var pubspec = File('$package/pubspec.yaml').readAsStringSync();
  String? field(String name) => RegExp(
    '^$name:\\s*(\\S+)',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);
  var name = field('name') ?? 'app';
  var version = (field('version') ?? '1.0.0+1').split('+');
  platform.methods('dev.fluttercommunity.plus/package_info', {
    'getAll': (_) => {
      'appName': name,
      'packageName': 'dev.flutterware.guest.$name',
      'version': version.first,
      'buildNumber': version.length > 1 ? version[1] : '',
      'buildSignature': '',
    },
  });
}
