import 'dart:async';

import '../guest_platform.dart';

/// `url_launcher` — a Pigeon API on macOS and another on iOS — answered by
/// the studio: every URL
/// the app opens lands in [opened] rather than in the Mac's browser, where a
/// world can show it, or follow it itself.
class GuestUrls {
  GuestUrls(GuestPlatform platform) {
    // `UrlLauncherBoolResult`, the API's own class: tag 130, `[value, error]`.
    PigeonValue result(bool value) => PigeonValue(130, [value, null]);
    platform.pigeon('dev.flutter.pigeon.url_launcher_macos.UrlLauncherApi', {
      'canLaunchUrl': (a) => result(true),
      'launchUrl': (a) => result(_open(a[0]! as String)),
    });
    // The iOS half, for a guest with the iOS look: enums rather than a class
    // — `LaunchResult` is tag 129, `InAppLoadResult` 130, and 0 is success.
    const success = PigeonValue(129, 0);
    platform.pigeon('dev.flutter.pigeon.url_launcher_ios.UrlLauncherApi', {
      'canLaunchUrl': (a) => success,
      'launchUrl': (a) => _open(a[0]! as String) ? success : null,
      'openUrlInSafariViewController': (a) {
        _open(a[0]! as String);
        return const PigeonValue(130, 0);
      },
      'closeSafariViewController': (a) => null,
    });
  }

  bool _open(String url) {
    opened.add(url);
    _opens.add(url);
    return true;
  }

  final opened = <String>[];
  final _opens = StreamController<String>.broadcast();

  /// Each URL as the app opens it.
  Stream<String> get opens => _opens.stream;
}
