import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../guest_platform.dart';

/// The route an app reports as it navigates — what a browser's address bar
/// shows — and what a browser does to it: goes back, and goes where it is
/// told.
///
/// Flutter's `Router`, and the root `Navigator` of a `MaterialApp`, report
/// every route they settle on over `flutter/navigation` on every platform;
/// only a browser listens, and here the studio does. The channel speaks JSON,
/// not the standard codec.
class GuestNavigation {
  GuestNavigation(this._platform) {
    _platform.bytes(_channel, (message) async {
      var call = jsonDecode(utf8.decode(message));
      if (call is Map && call['method'] == 'routeInformationUpdated') {
        var arguments = call['args'];
        var location = arguments is Map
            ? arguments['uri'] ?? arguments['location']
            : null;
        if (location is String) {
          route = location;
          _routes.add(location);
        }
      }
      // `selectSingleEntryHistory` and `selectMultiEntryHistory` shape a
      // browser's history, which the studio does not keep.
      return _encode([null]);
    });
  }

  static const _channel = 'flutter/navigation';
  final GuestPlatform _platform;

  /// The route the app reported last — `/orders/o3` — or null until it
  /// reports one.
  String? route;
  final _routes = StreamController<String>.broadcast();

  /// Each route as the app reports it.
  Stream<String> get routes => _routes.stream;

  /// The browser's back button: the app pops a route, as it would for the
  /// system's back.
  void back() => _call('popRoute');

  /// The address typed into a browser: the app is asked to show [location]
  /// — a path, `/orders/o3` — as a routed app on the web is.
  void go(String location) =>
      _call('pushRouteInformation', {'location': location, 'state': null});

  void _call(String method, [Object? arguments]) =>
      _platform.raw(_channel, _encode({'method': method, 'args': arguments}));

  static Uint8List _encode(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
