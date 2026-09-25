import 'dart:async';
import 'dart:convert';

import '../guest_platform.dart';

/// What the framework itself asks of the platform, answered by the studio:
/// the mouse cursor the app wants over what it draws, and the app's
/// lifecycle, which only the platform can change.
class GuestSystem {
  GuestSystem(this._platform) {
    _platform.methods('flutter/mousecursor', {
      'activateSystemCursor': (a) {
        cursor = (a! as Map)['kind']! as String;
        _cursors.add(cursor);
        return null;
      },
    });
  }

  final GuestPlatform _platform;

  /// The system cursor the app asked for last, by the framework's name for
  /// it — `basic`, `click`, `text`.
  String cursor = 'basic';
  final _cursors = StreamController<String>.broadcast();
  Stream<String> get cursors => _cursors.stream;

  /// Moves the app to a lifecycle state — `resumed`, `inactive`, `hidden`,
  /// `paused` — as the OS would when it is sent to the background.
  void lifecycle(String state) => _platform.raw(
    'flutter/lifecycle',
    utf8.encode('AppLifecycleState.$state'),
  );
}
