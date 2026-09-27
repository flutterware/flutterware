import 'dart:async';
import 'dart:io';

import 'step_names.dart';

/// Stamps [worldStepHeader] on every HTTP request the process opens, with the
/// step [stepFor] says it belongs to — a world guest's, around its gestures,
/// and a world script's, around its actions.
///
/// Installed as `HttpOverrides.global`; code that sets its own replaces it,
/// and its requests then go unstamped.
class StepStamping extends HttpOverrides {
  StepStamping(this.stepFor, {this.onStamped});

  /// The step a request opened now belongs to, and how it was found — `zone`
  /// or `window` — or null for one that belongs to none.
  final (String step, String how)? Function() stepFor;

  /// Told of each request stamped.
  final void Function(String step, String how, String method, Uri url)?
  onStamped;

  /// A [stepFor] that knows only the zone's step: [worldStepKey].
  static (String, String)? zoneStep() => switch (Zone.current[worldStepKey]) {
    String step => (step, 'zone'),
    _ => null,
  };

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _StepClient(super.createHttpClient(context), this);
}

/// Stamps [worldStepHeader] on every request it opens; the rest is the real
/// client's.
class _StepClient implements HttpClient {
  _StepClient(this._inner, this._stamping);

  final HttpClient _inner;
  final StepStamping _stamping;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    var found = _stamping.stepFor();
    var request = await _inner.openUrl(method, url);
    if (found case (var step, var how)) {
      request.headers.set(worldStepHeader, step);
      _stamping.onStamped?.call(step, how, method, url);
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
