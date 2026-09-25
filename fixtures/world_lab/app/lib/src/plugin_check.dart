import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// How one plugin answered.
class PluginResult {
  PluginResult(
    this.name, {
    required this.ok,
    required this.ms,
    required this.detail,
  });

  final String name;
  final bool ok;
  final int ms;
  final String detail;

  @override
  String toString() => '${ok ? 'ok    ' : 'FAILED'} $name ${ms}ms — $detail';
}

/// Touches every plugin the app depends on, once, and says how each went.
///
/// This is the lab's measuring stick. The guest experiment runs this app
/// where some plugins have no platform behind them, and needs to know which
/// ones answered, how fast, and what with. So each check is timed and caught
/// on its own, and a timeout stands in for an answer that never comes — a
/// platform call nothing answers hangs rather than throwing.
///
/// Several details are there to show *sharing*: two instances of the app that
/// report the same install id, or a launch count that jumps by two, are
/// sharing their preferences, which is the question isolation per person
/// asks.
Future<List<PluginResult>> checkPlugins(Api api) async {
  var results = <PluginResult>[];
  Future<void> check(String name, Future<String> Function() touch) async {
    var watch = Stopwatch()..start();
    PluginResult result;
    try {
      var detail = await touch().timeout(const Duration(seconds: 5));
      result = PluginResult(
        name,
        ok: true,
        ms: watch.elapsedMilliseconds,
        detail: detail,
      );
    } on TimeoutException {
      result = PluginResult(
        name,
        ok: false,
        ms: watch.elapsedMilliseconds,
        detail: 'no answer in 5s',
      );
    } catch (e) {
      result = PluginResult(
        name,
        ok: false,
        ms: watch.elapsedMilliseconds,
        detail: '$e'.split('\n').first,
      );
    }
    print('world_lab: plugin $result');
    results.add(result);
  }

  String? support;
  await check('path_provider', () async {
    support = (await getApplicationSupportDirectory()).path;
    return support!;
  });

  await check('shared_preferences', () async {
    var prefs = SharedPreferencesAsync();
    var launches = (await prefs.getInt('launches') ?? 0) + 1;
    await prefs.setInt('launches', launches);
    var install = await prefs.getString('installId');
    if (install == null) {
      install = base64Url.encode(
        List.generate(6, (_) => Random().nextInt(256)),
      );
      await prefs.setString('installId', install);
    }
    return 'install $install, launch $launches';
  });

  await check('flutter_secure_storage', () async {
    var previous = await secureStorage.read(key: 'probe');
    await secureStorage.write(
      key: 'probe',
      value: DateTime.now().toIso8601String(),
    );
    return 'wrote; last write ${previous ?? 'none'}';
  });

  await check('package_info_plus', () async {
    var info = await PackageInfo.fromPlatform();
    return '${info.packageName} ${info.version}';
  });

  await check('sqlite3', () async {
    var path = p.join(support ?? '.', 'world_lab.db');
    var db = sqlite3.open(path);
    try {
      db.execute('CREATE TABLE IF NOT EXISTS launches (at TEXT)');
      db.execute('INSERT INTO launches VALUES (?)', [
        DateTime.now().toIso8601String(),
      ]);
      var rows = db.select('SELECT count(*) AS n FROM launches').first['n'];
      return 'sqlite ${sqlite3.version.libVersion}, $rows launches in $path';
    } finally {
      db.close();
    }
  });

  await check('app_links', () async {
    var initial = await AppLinks().getInitialLink();
    return 'initial link: ${initial ?? 'none'}';
  });

  await check('flutter_local_notifications', () async {
    var darwin = DarwinInitializationSettings(
      // Asked for when an order is ready, not at boot: a permission dialog
      // at boot would stand between every launch and its first screen.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    var ok = await notifications.initialize(
      settings: InitializationSettings(macOS: darwin, iOS: darwin),
      // A tapped notification opens the link it carries, the way the app
      // opens one the OS hands it.
      onDidReceiveNotificationResponse: (response) {
        if (response.payload case var link? when link.isNotEmpty) {
          notificationLinks.add(Uri.parse(link));
        }
      },
    );
    return 'initialized: $ok';
  });

  await check('url_launcher', () async {
    var can = await canLaunchUrl(Uri.parse('https://flutterware.dev'));
    return 'can open https: $can';
  });

  await check('http', () async {
    await api.health();
    return 'GET ${api.base.resolve('/health')}';
  });

  await check('web_socket', () async {
    var channel = Api(api.base).live();
    var first = await channel.stream.first;
    await channel.sink.close();
    return 'greeted: $first';
  });

  var failed = results.where((r) => !r.ok).length;
  print(
    'world_lab: plugins checked, ${results.length - failed} ok, $failed failed',
  );
  return results;
}

final notifications = FlutterLocalNotificationsPlugin();

/// The links carried by notifications the person tapped.
final notificationLinks = StreamController<Uri>.broadcast();

/// The app's secure storage, left at the plugin's defaults on purpose.
///
/// In a macOS window with no signing team it cannot work either way, and the
/// lab records that rather than hiding it (measured 2026-09-25):
/// - the default, the data-protection keychain, needs a
///   `keychain-access-groups` entitlement that only a provisioning profile
///   grants, so every call fails at once with -34018;
/// - `MacOsOptions(usesDataProtectionKeychain: false)`, the file keychain,
///   works once — then binds the item to the app's ad-hoc signature, which
///   every rebuild changes, so the next launch after an edit stops on a
///   system prompt for the login password.
///
/// Failing fast is the one of the two a world can live with: the app still
/// signs in through its `session` knob.
final secureStorage = FlutterSecureStorage();
