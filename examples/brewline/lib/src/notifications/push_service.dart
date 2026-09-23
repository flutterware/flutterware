/// Brewline's push notifications — the *app's* half, with nothing developer-
/// facing in it.
///
/// This is ordinary product code: the thing a real app would write around
/// Firebase Messaging or APNs, minus the platform plumbing. A message arrives
/// from somewhere the app does not control, the app decides whether it is
/// allowed to show it, shows it, and routes somewhere when it is tapped.
///
/// The devbar plugin next door (`../devbar/notifications_panel.dart`) does not
/// implement any of that. It only *drives* it — which is the point of the
/// whole exercise: the plugin's job is to reach a code path that otherwise
/// needs a backend, a device token and somebody willing to send you a push.
library;

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

/// What the OS has told the app about showing notifications.
enum PushPermission {
  notDetermined('Not determined'),
  granted('Granted'),
  denied('Denied');

  const PushPermission(this.label);

  /// Also what crosses the wire as a knob value — a picker knob travels by
  /// label, matching the rest of flutterware's catalog vocabulary.
  final String label;

  static PushPermission? byLabel(Object? label) =>
      values.firstWhereOrNull((value) => value.label == label);
}

/// One notification the app believes it received.
class PushMessage {
  PushMessage({
    required this.id,
    required this.title,
    required this.receivedAt,
    this.body,
    this.link,
  });

  final String id;
  final String title;
  final String? body;

  /// Where tapping it goes — one of [PushService.links], or null for a
  /// notification that is only an announcement.
  final String? link;

  final DateTime receivedAt;

  var opened = false;
}

/// The app declining to deliver, for a reason worth reading.
///
/// Thrown rather than swallowed: a push that quietly does nothing because the
/// user never granted permission is the single most confusing thing this
/// feature can do, and it is just as confusing to whatever asked for it from
/// outside the app.
class PushRefused implements Exception {
  PushRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One place a notification may point at.
class PushLink {
  const PushLink(this.path, this.label, this.screen);

  /// What a message's `link` holds — `/cart`, `/drink/matcha`.
  final String path;

  final String label;
  final WidgetBuilder screen;
}

/// The app's notification centre: permission, the inbox, and the banner.
class PushService extends ChangeNotifier {
  PushService({required this.navigatorKey, required this.links});

  /// How a notification tapped from outside the widget tree finds the
  /// navigator. A real app needs this for exactly the same reason: the
  /// platform hands the tap to a callback, not to a widget.
  final GlobalKey<NavigatorState> navigatorKey;

  /// Every destination this app understands. A link outside the list is
  /// refused — a deep link that silently lands nowhere is worse than an error.
  final List<PushLink> links;

  /// The registration token the app would have got from the push service.
  /// Fixed, because a demo that prints a different one every launch teaches
  /// nobody anything.
  static const token = 'brewline-demo:f3c8-1d20-9a44';

  var _permission = PushPermission.notDetermined;

  PushPermission get permission => _permission;

  set permission(PushPermission value) {
    if (_permission == value) return;
    _permission = value;
    notifyListeners();
  }

  /// Everything delivered this run, oldest first.
  List<PushMessage> get inbox => List.unmodifiable(_inbox);
  final _inbox = <PushMessage>[];

  /// The one showing over the app, if any.
  PushMessage? get banner => _banner;
  PushMessage? _banner;

  var _nextId = 1;

  PushLink? linkFor(String path) =>
      links.firstWhereOrNull((link) => link.path == path);

  /// Hands the app a notification, exactly as the platform would.
  PushMessage deliver({required String title, String? body, String? link}) {
    if (_permission != PushPermission.granted) {
      throw PushRefused(
        'notifications are ${_permission.label.toLowerCase()} — this app will '
        'not show one until permission is granted',
      );
    }
    if (link != null && linkFor(link) == null) {
      throw PushRefused(
        'nothing is registered for "$link" — this app knows '
        '${links.map((l) => l.path).join(', ')}',
      );
    }
    var message = PushMessage(
      id: 'push-${_nextId++}',
      title: title,
      body: body,
      link: link,
      receivedAt: DateTime.now(),
    );
    _inbox.add(message);
    _banner = message;
    notifyListeners();
    return message;
  }

  /// Follows a notification — what tapping the banner does, and what tapping
  /// the real thing on a lock screen would do.
  PushMessage open(String id) {
    var message = _inbox.firstWhereOrNull((message) => message.id == id);
    if (message == null) {
      throw PushRefused(
        'no notification "$id" is in the inbox — nothing delivered it, or the '
        'inbox has been cleared since',
      );
    }
    message.opened = true;
    if (identical(_banner, message)) _banner = null;
    notifyListeners();

    var path = message.link;
    if (path == null) return message;
    var link = linkFor(path)!;
    var navigator = navigatorKey.currentState;
    if (navigator == null) {
      throw PushRefused('the app has no navigator yet — is it still starting?');
    }
    navigator.push(MaterialPageRoute<void>(builder: link.screen));
    return message;
  }

  void dismiss() {
    if (_banner == null) return;
    _banner = null;
    notifyListeners();
  }

  void clear() {
    if (_inbox.isEmpty && _banner == null) return;
    _inbox.clear();
    _banner = null;
    // [_nextId] is deliberately *not* reset. An id outlives the inbox: it is
    // in the panel's feed, in the run's journal, and in whatever a host wrote
    // down. Restarting the count made `push-1` name two different
    // notifications in one run, and the cockpit's `open` on the first row
    // followed the second one's link — found by driving it, 2026-08-11.
    notifyListeners();
  }
}
