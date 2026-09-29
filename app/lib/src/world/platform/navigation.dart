import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../guest_platform.dart';

/// The route an app reports as it navigates — what a browser's address bar
/// shows — and what a browser does to it: goes back and forward, reloads,
/// and goes where it is told.
///
/// Flutter's `Router`, and the root `Navigator` of a `MaterialApp`, report
/// every route they settle on over `flutter/navigation` on every platform;
/// only a browser listens, and here the studio does. The channel speaks JSON,
/// not the standard codec.
///
/// The two report differently, and a browser treats them differently, so
/// this does too. A `Router` asks for a history of many entries: each route
/// it reports is one, and back and forward take the app to the entry before
/// or after, as a browser's buttons do for a Flutter web app. A `Navigator`
/// asks for a single entry: back pops a route, as the system's back does,
/// and there is never anything to go forward to.
class GuestNavigation {
  GuestNavigation(this._platform) {
    _platform.bytes(_channel, (message) async {
      var call = jsonDecode(utf8.decode(message));
      if (call is Map) {
        var arguments = call['args'];
        switch (call['method']) {
          case 'selectMultiEntryHistory':
            _entries = true;
          case 'selectSingleEntryHistory':
            _entries = false;
          case 'routeInformationUpdated' when arguments is Map:
            var location = arguments['uri'] ?? arguments['location'];
            if (location is String) {
              _heard(location, replace: arguments['replace'] == true);
            }
        }
      }
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

  /// Whether the app keeps a history of many entries — a `Router` — rather
  /// than the single one a `Navigator` asks for.
  var _entries = false;

  /// The routes a `Router` app has been on, oldest first, and which of them
  /// it is on: a new one drops whatever was ahead of it, as in a browser.
  final _history = <String>[];
  var _at = -1;

  /// The entry back or forward is taking the app to; the report that lands
  /// there moves along the history rather than adding to it.
  int? _moving;

  /// Whether the next report is an address typed in: a new entry, although
  /// a `Router` reports a route it was told to show as a replacement.
  var _typed = false;

  /// Where a reloaded app is taken back to once it says where it started,
  /// until it has or the time is up.
  ({String route, DateTime until})? _returning;

  bool get canBack => !_entries || _at > 0;
  bool get canForward => _entries && _at < _history.length - 1;

  /// The browser's back button.
  void back() {
    if (!_entries) return _call('popRoute');
    if (_at <= 0) return;
    _moving = _at - 1;
    _show(_history[_at - 1]);
  }

  /// The browser's forward button: nothing unless back was pressed since
  /// the app last went somewhere new.
  void forward() {
    if (!canForward) return;
    _moving = _at + 1;
    _show(_history[_at + 1]);
  }

  /// The address typed into a browser: the app is asked to show [location]
  /// — a path, `/orders/o3` — as a routed app on the web is.
  void go(String location) {
    _typed = true;
    _show(location);
  }

  void _show(String location) =>
      _call('pushRouteInformation', {'location': location, 'state': null});

  /// Starts the app again with [restart] and takes it back to the route it
  /// is on now, as a browser's reload keeps its address — an app started
  /// again starts where its code starts it. The history stays as it was.
  Future<void> reload(Future<void> Function() restart) async {
    var route = this.route;
    await restart();
    // Armed once the restart is done, not before: until then a report is
    // the old app's — redrawn by the reload of everyone's code that comes
    // first — and the new one reports only after its first frame.
    if (route != null) {
      _returning = (
        route: route,
        until: DateTime.now().add(const Duration(seconds: 10)),
      );
    }
  }

  void _heard(String location, {required bool replace}) {
    if (_returning case (:var route, :var until)) {
      _returning = null;
      // Where it starts is on the way back, not somewhere it went.
      if (location != route && DateTime.now().isBefore(until)) {
        _show(route);
        return;
      }
    }
    route = location;
    var (moving, typed) = (_moving, _typed);
    _moving = null;
    _typed = false;
    if (moving != null && _history[moving] == location) {
      _at = moving;
    } else if (_at >= 0 && _history[_at] == location) {
      // The same route again: a rebuild reporting it.
    } else if (((replace && !typed) || !_entries) && _at >= 0) {
      _history[_at] = location;
    } else {
      _history
        ..removeRange(_at + 1, _history.length)
        ..add(location);
      _at = _history.length - 1;
    }
    _routes.add(location);
  }

  void _call(String method, [Object? arguments]) =>
      _platform.raw(_channel, _encode({'method': method, 'args': arguments}));

  static Uint8List _encode(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
