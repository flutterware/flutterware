import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../guest_platform.dart';

/// What the framework itself asks of the platform, answered by the studio:
/// the mouse cursor the app wants over what it draws, the title it gives its
/// window, and the app's lifecycle, which only the platform can change.
class GuestSystem {
  GuestSystem(this._platform) {
    _platform
      ..methods('flutter/mousecursor', {
        'activateSystemCursor': (a) {
          cursor = (a! as Map)['kind']! as String;
          _cursors.add(cursor);
          return null;
        },
      })
      // JSON, not the standard codec. Only the title is kept; every other
      // `SystemChrome` and `HapticFeedback` call is answered as not
      // implemented, as it always was.
      ..bytes('flutter/platform', (message) async {
        var call = jsonDecode(utf8.decode(message));
        if (call is! Map ||
            call['method'] !=
                'SystemChrome.setApplicationSwitcherDescription') {
          return null;
        }
        var arguments = call['args'];
        if (arguments is Map) {
          title = arguments['label'] as String?;
          titleColor = arguments['primaryColor'] as int?;
          _titles.add(title);
        }
        return Uint8List.fromList(utf8.encode(jsonEncode([null])));
      });
  }

  final GuestPlatform _platform;

  /// The system cursor the app asked for last, by the framework's name for
  /// it — `basic`, `click`, `text`.
  String cursor = 'basic';
  final _cursors = StreamController<String>.broadcast();
  Stream<String> get cursors => _cursors.stream;

  /// What the app calls its window — a `MaterialApp`'s `title`, or a
  /// `Title` widget's — as a browser shows it on the tab; null until it says.
  String? title;

  /// The colour it gives beside [title], as ARGB.
  int? titleColor;
  final _titles = StreamController<String?>.broadcast();
  Stream<String?> get titles => _titles.stream;

  /// Moves the app to a lifecycle state — `resumed`, `inactive`, `hidden`,
  /// `paused` — as the OS would when it is sent to the background.
  void lifecycle(String state) {
    lifecycleState = state;
    _platform.raw('flutter/lifecycle', utf8.encode('AppLifecycleState.$state'));
  }

  /// The state [lifecycle] moved the app to last: `resumed` until it did.
  String lifecycleState = 'resumed';
}
