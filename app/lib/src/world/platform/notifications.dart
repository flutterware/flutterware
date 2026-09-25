import 'dart:async';

import '../guest_platform.dart';

/// A notification an app showed, as the studio holds it.
class GuestNotification {
  GuestNotification(this.id, this.title, this.body, this.payload);

  final int id;
  final String? title;
  final String? body;
  final String? payload;

  @override
  String toString() => '$title — $body';
}

/// `flutter_local_notifications` on macOS, answered by the studio: what the
/// app shows lands in [shown] — where a canvas can draw it — and [tap] is a
/// person tapping one, sent back on the plugin's own channel the way the OS
/// reports it.
class GuestNotifications {
  GuestNotifications(this._platform) {
    _platform.methods(_channel, {
      'initialize': (_) => true,
      'requestPermissions': (_) => _allowed = true,
      'checkPermissions': (_) => {
        'isEnabled': _allowed,
        'isAlertEnabled': _allowed,
        'isBadgeEnabled': _allowed,
        'isSoundEnabled': _allowed,
      },
      'show': (a) {
        var map = a! as Map;
        var notification = GuestNotification(
          map['id']! as int,
          map['title'] as String?,
          map['body'] as String?,
          map['payload'] as String?,
        );
        shown.add(notification);
        _shows.add(notification);
        return null;
      },
      'cancel': (a) {
        shown.removeWhere((n) => n.id == (a! as Map)['id']);
        return null;
      },
      'cancelAll': (_) {
        shown.clear();
        return null;
      },
      'pendingNotificationRequests': (_) => <Object?>[],
      'getActiveNotifications': (_) => [
        for (var n in shown) {'id': n.id, 'title': n.title, 'body': n.body},
      ],
      'getNotificationAppLaunchDetails': (_) => null,
    });
  }

  static const _channel = 'dexterous.com/flutter/local_notifications';
  final GuestPlatform _platform;
  var _allowed = false;

  final shown = <GuestNotification>[];
  final _shows = StreamController<GuestNotification>.broadcast();

  /// Each notification as the app shows it.
  Stream<GuestNotification> get shows => _shows.stream;

  /// A person tapping [notification], reported as the OS would.
  void tap(GuestNotification notification) =>
      _platform.call(_channel, 'didReceiveNotificationResponse', {
        'notificationId': notification.id,
        'payload': notification.payload,
        'notificationResponseType': 0,
      });
}
