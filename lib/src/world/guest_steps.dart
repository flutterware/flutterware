import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';

import '../drive/human_actions.dart' show describeHit;
import '../server/vm_transport.dart' show GuestChannels;
import 'step_names.dart';

/// The zone key a step travels under inside the app.
const worldStepKey = #fwStep;

/// A world guest's steps. Each gesture on the app — a person's or an agent's,
/// both arrive through the binding — is one step with an id of its own,
/// `ben.3`, and what its callbacks start runs in a zone naming it. Every HTTP
/// request the app opens carries the id in [worldStepHeader], so a server
/// whose adapter reads it can say which tap each of its events came from,
/// and the world can join the two.
///
/// A request started outside the tap's callbacks — a fetch a rebuild began, a
/// sync engine's upload loop — is given the last step instead, while that
/// ended under [window] ago. Each request says which way it joined.
///
/// The one thing an app can undo: setting `HttpOverrides.global` itself
/// replaces this, and its requests go unstamped.
class WorldSteps {
  WorldSteps({
    required String person,
    this.window = const Duration(milliseconds: 1500),
    void Function(String channel, Map<String, Object?> payload)? report,
  }) : _prefix = worldStepPrefix(person),
       _report = report ?? _toChannels;

  /// How long after a step ends a request with no step of its own still
  /// belongs to it.
  final Duration window;

  final String _prefix;
  final void Function(String channel, Map<String, Object?> payload) _report;
  var _count = 0;
  _Gesture? _gesture;
  String? _last;
  DateTime? _lastAt;

  /// Stamps every request the app opens from now on.
  void install() => HttpOverrides.global = _StepOverrides(this);

  /// Dispatches [event] through [next] — the binding's own
  /// `handlePointerEvent` — inside its gesture's step.
  ///
  /// A gesture is every pointer from the first down to the last up, so a
  /// second finger belongs to the step the first began.
  void dispatch(PointerEvent event, void Function(PointerEvent event) next) {
    if (event is PointerDownEvent) {
      (_gesture ??= _Gesture(
        '$_prefix.${++_count}',
        event,
      )).down.add(event.pointer);
    }
    var gesture = _gesture;
    if (gesture == null) return next(event);
    runZoned(() => next(event), zoneValues: {worldStepKey: gesture.id});
    if (event is PointerMoveEvent &&
        (event.position - gesture.first.position).distance > kTouchSlop) {
      gesture.moved = true;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      gesture.down.remove(event.pointer);
      if (gesture.down.isNotEmpty) return;
      _gesture = null;
      _last = gesture.id;
      _lastAt = DateTime.now();
      var held = event.timeStamp - gesture.first.timeStamp;
      _report(worldStepsChannel, {
        'step': gesture.id,
        'verb': gesture.moved
            ? 'drag'
            : held >= kLongPressTimeout
            ? 'longPress'
            : 'tap',
        'target': describeHit(
          gesture.first.position,
          viewId: gesture.first.viewId,
        ),
      });
    }
  }

  /// The step a request opened now belongs to, and how it was found.
  (String step, String how)? stepFor() {
    if (Zone.current[worldStepKey] case String step) return (step, 'zone');
    var at = _lastAt;
    if (_last case var step? when at != null) {
      if (DateTime.now().difference(at) < window) return (step, 'window');
    }
    return null;
  }

  void _stamped(String step, String how, String method, Uri url) =>
      _report(worldRequestsChannel, {
        'step': step,
        'method': method,
        'url': '${url.host}:${url.port}${url.path}',
        'how': how,
      });

  static void _toChannels(String channel, Map<String, Object?> payload) =>
      GuestChannels.core.addEvent(channel, payload);
}

class _Gesture {
  _Gesture(this.id, this.first);

  final String id;
  final PointerDownEvent first;
  final down = <int>{};
  var moved = false;
}

class _StepOverrides extends HttpOverrides {
  _StepOverrides(this.steps);

  final WorldSteps steps;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _StepClient(super.createHttpClient(context), steps);
}

/// Stamps [worldStepHeader] on every request it opens; the rest is the real
/// client's.
class _StepClient implements HttpClient {
  _StepClient(this._inner, this._steps);

  final HttpClient _inner;
  final WorldSteps _steps;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    var found = _steps.stepFor();
    var request = await _inner.openUrl(method, url);
    if (found case (var step, var how)) {
      request.headers.set(worldStepHeader, step);
      _steps._stamped(step, how, method, url);
    }
    return request;
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  void close({bool force = false}) => _inner.close(force: force);
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? value) =>
      _inner.authenticate = value;
  @override
  set authenticateProxy(
    Future<bool> Function(String, int, String, String?)? value,
  ) => _inner.authenticateProxy = value;
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? value,
  ) => _inner.badCertificateCallback = value;
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value,
  ) => _inner.connectionFactory = value;
  @override
  set findProxy(String Function(Uri)? value) => _inner.findProxy = value;
  @override
  set keyLog(void Function(String)? value) => _inner.keyLog = value;
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);
}
