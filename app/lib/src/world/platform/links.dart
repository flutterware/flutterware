import '../guest_platform.dart';

/// `app_links` — the links an app is opened with — answered by the studio,
/// which is also how a world delivers one: [GuestLinks.open] sends it on the
/// plugin's own event channel, exactly where a link the OS routed would
/// arrive.
class GuestLinks {
  GuestLinks(this._platform, {this.initial}) {
    _platform
      ..methods('$_channel/messages', {
        'getInitialLink': (_) => initial,
        'getLatestLink': (_) => latest ?? initial,
      })
      ..methods('$_channel/events', {
        'listen': (_) {
          _listening = true;
          return null;
        },
        'cancel': (_) {
          _listening = false;
          return null;
        },
      });
  }

  static const _channel = 'com.llfbandit.app_links';
  final GuestPlatform _platform;

  /// The link the app was opened with, if a world opened it with one.
  final String? initial;

  /// The last link delivered.
  String? latest;

  var _listening = false;

  /// Opens [link] in the running app. Answers false when the app is not
  /// listening for links, so the caller can say so rather than drop it.
  bool open(String link) {
    latest = link;
    if (!_listening) return false;
    _platform.emit('$_channel/events', link);
    return true;
  }
}
