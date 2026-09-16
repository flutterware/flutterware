import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../app_events/events.dart';
import 'network_mode.dart';
import 'network_store.dart';

export 'network_mode.dart';
export 'network_store.dart'
    show
        ScenarioNetworkStore,
        ScenarioRecording,
        defaultScenarioNetworkStore,
        scenarioNetworkStorePath;

/// What the project's `fw.network(...)` declared, or null when it declared
/// nothing.
///
/// The **lowest** altitude: a folder, a run and a scenario all beat it. Set by
/// the harness from the manifest the host read; null under a bare
/// `flutter test`, which reads no manifest — that lane says it with
/// `FW_NETWORK`, exactly as it says the clock with `FW_CLOCK`.
ScenarioNetwork? scenarioProjectNetwork;

/// Live requests opened through the funnel whose response headers are not in
/// yet. Announced work on the real clock: a `FutureBuilder` over an API call
/// schedules no frame while the call is out, so a settle that follows frames
/// alone photographs the spinner. `landRealWork` waits on this the way it
/// waits on a decode, for as long as the request takes — the app's own
/// promise, bounded by the scenario's deadline rather than a guess.
int scenarioLiveRequestsInFlight = 0;

/// Every mode a scenario in this run actually ran under.
///
/// Filled as each body starts, read by the harness when the walk is over, and
/// cleared by it before the next one. A mode is only worth anything while it
/// is *stated*: a screen photographed with the network open and the same
/// screen photographed with it shut are not the same evidence, and nothing on
/// the picture says which — the same argument that puts the clock origin in
/// the report beside it.
final scenarioNetworkModesRun = <ScenarioNetwork>{};

/// The answers one scenario has stated, and the log of what it actually asked
/// for.
///
/// Reached as `s.network`. A stub is a fact about *this* scenario — the empty
/// inbox, the 503, the train — and no recording of a real server can be asked
/// to produce one on demand, which is why stating them is a separate door from
/// [ScenarioNetwork.live] rather than a mode of it.
///
/// ```dart
/// scenario('the inbox is empty', (s) async {
///   s.network.get('/api/messages', json: []);
///   await s.pumpWidget(const App());
///   await s.screen('the empty state');
/// });
/// ```
class ScenarioNetworkPolicy {
  ScenarioNetworkPolicy(this.mode, {ScenarioNetworkStore? store})
    : store = store ?? ScenarioNetworkStore(resolvedScenarioNetworkStore());

  /// What answers a request no stub claimed.
  final ScenarioNetwork mode;

  /// Where [ScenarioNetwork.replay] reads and [ScenarioNetwork.record]
  /// writes. Untouched by the other two modes.
  final ScenarioNetworkStore store;

  /// Every exchange this scenario has made, in order — the same list the
  /// step's Events pane is built from, for a body that wants to assert on it.
  ///
  /// ```dart
  /// await s.tap('Place order');
  /// expect(s.network.requests.last.url.path, '/api/orders');
  /// ```
  ///
  /// Emptied between the branches of a `split` — see [resetForReplay] — so it
  /// answers "what did *this path* ask for". [requestsEver] is the other
  /// question.
  final requests = <ScenarioRequest>[];

  /// How many exchanges this scenario has made across **every** branch of its
  /// splits.
  ///
  /// [requests] cannot answer this: each replay states its own answers from
  /// the top and its log is dropped with them, so after the last branch it
  /// holds only that branch's. A reader asking "did this scenario ever open a
  /// request at all" — which is what a mode claiming to reach the network is
  /// judged against — would otherwise get the last path's answer and take it
  /// for the scenario's.
  int get requestsEver => _requestsEver;
  var _requestsEver = 0;

  /// Stated answers, most recent first — so re-stating a url mid-flow changes
  /// what it answers from there on, which is how "and now the list has the new
  /// item in it" is written.
  final _stubs = <_Stub>[];

  /// The fallback, which is one slot rather than a stub at the end of the
  /// list. A catch-all that competed with the others on order would swallow
  /// every stub registered after it, and a rule you have to remember the order
  /// for is a rule that will be got wrong.
  _Stub? _fallback;

  /// The one real client, made on first use and closed by the harness.
  ///
  /// Never by the app: `flutter_test` asserts no timer is pending when a body
  /// ends, and a live keepalive connection holds one — so a client the app
  /// closes must not be this, and this must be closed before the invariants
  /// are checked.
  HttpClient? _real;

  HttpClient get _client => _real ??= _newRealClient();

  /// Applies a setting the app made on "its" client to the shared one — but
  /// only where there is a network for it to mean anything.
  ///
  /// The funnel hands every caller the same pool, so a per-client setting is
  /// last-writer-wins across the whole process. That is the price of one pool
  /// and one thing to close, and it is the right price: everything an app
  /// actually sets here — a proxy, a bad-certificate callback for a
  /// self-signed dev API, a user agent, a connection timeout — is pool-shaped
  /// anyway. Under the two modes that open no socket it is dropped rather
  /// than remembered, because dropping it changes nothing — and it is dropped
  /// under **exactly** those two: `record` reaches the network as surely as
  /// `live` does, and an app pointed at a self-signed staging API would
  /// otherwise record fine and fail to record at all.
  void _configure(void Function(HttpClient client) apply) {
    if (mode == ScenarioNetwork.live || mode == ScenarioNetwork.record) {
      apply(_client);
    }
  }

  /// Answers `GET [url]`. See [stub] for the parameters.
  void get(
    Pattern url, {
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) => stub(
    'GET',
    url,
    json: json,
    body: body,
    contentType: contentType,
    status: status,
    headers: headers,
    throws: throws,
  );

  /// Answers `POST [url]`. See [stub].
  void post(
    Pattern url, {
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) => stub(
    'POST',
    url,
    json: json,
    body: body,
    contentType: contentType,
    status: status,
    headers: headers,
    throws: throws,
  );

  /// Answers `PUT [url]`. See [stub].
  void put(
    Pattern url, {
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) => stub(
    'PUT',
    url,
    json: json,
    body: body,
    contentType: contentType,
    status: status,
    headers: headers,
    throws: throws,
  );

  /// Answers `PATCH [url]`. See [stub].
  void patch(
    Pattern url, {
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) => stub(
    'PATCH',
    url,
    json: json,
    body: body,
    contentType: contentType,
    status: status,
    headers: headers,
    throws: throws,
  );

  /// Answers `DELETE [url]`. See [stub].
  void delete(
    Pattern url, {
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) => stub(
    'DELETE',
    url,
    json: json,
    body: body,
    contentType: contentType,
    status: status,
    headers: headers,
    throws: throws,
  );

  /// Answers an image request with real bytes — a PNG a fixture already holds,
  /// or one [scenarioPlaceholderPng] made.
  ///
  /// Sugar over [stub] with the content type filled in, because an image is
  /// the request a scenario stubs most often and getting the type wrong is a
  /// decode failure two layers away from the line that caused it.
  void image(Pattern url, List<int> png) =>
      stub('GET', url, body: png, contentType: 'image/png');

  /// Answers everything no other stub claimed, whatever the method.
  ///
  /// The offline test is this one:
  ///
  /// ```dart
  /// s.network.any(throws: const SocketException('Network is unreachable'));
  /// ```
  void any({
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) => _fallback = _Stub(
    method: null,
    url: null,
    status: status,
    body: _bodyOf(json, body),
    contentType: contentType ?? (json == null ? null : 'application/json'),
    headers: {
      for (var e in headers.entries) e.key: [e.value],
    },
    throws: throws,
  );

  /// States what [method] [url] answers.
  ///
  /// [url] matches on the request's **path** when it is a plain string with no
  /// scheme — `'/api/messages'` — and on the whole url when it has one.
  /// Neither is a substring match: a stub that fires for a url nobody meant it
  /// to is the failure this whole surface exists to avoid, and a [RegExp] is
  /// how anything looser is said out loud.
  ///
  /// Exactly one of [json], [body] and [throws] is the answer; [status] alone
  /// is an empty response with that code. [throws] is the shape an app's error
  /// handling is tested with — a `SocketException`, a `TimeoutException`, or
  /// anything else the app catches.
  void stub(
    String method,
    Pattern url, {
    Object? json,
    List<int>? body,
    String? contentType,
    int status = 200,
    Map<String, String> headers = const {},
    Object? throws,
  }) {
    if ([json, body, throws].where((v) => v != null).length > 1) {
      throw ArgumentError(
        'A stub answers with one of json:, body: or throws:, not several.',
      );
    }
    _stubs.insert(
      0,
      _Stub(
        method: method.toUpperCase(),
        url: url,
        status: status,
        body: _bodyOf(json, body),
        contentType: contentType ?? (json == null ? null : 'application/json'),
        headers: {
          for (var e in headers.entries) e.key: [e.value],
        },
        throws: throws,
      ),
    );
  }

  /// Drops every stated answer, for the next replay of a `split`.
  ///
  /// A body runs once per path through its splits, and each path states its
  /// own answers from the top. The [requests] log is dropped with them, for
  /// the same reason: a branch asserting on what it asked for must not see
  /// what the branch before it asked for.
  void resetForReplay() {
    _stubs.clear();
    _fallback = null;
    requests.clear();
  }

  /// Closes the real client, if one was ever made. Called by the harness at
  /// the end of the body — see [_real].
  void dispose() {
    _real?.close(force: true);
    _real = null;
  }

  _Stub? _match(String method, Uri url) {
    for (var stub in _stubs) {
      if (stub.matches(method, url)) return stub;
    }
    return _fallback;
  }

  void _record(ScenarioRequest request) {
    requests.add(request);
    _requestsEver++;
    recordAppEvent(
      request.status == null
          // Nothing answered it, so there is no status to show — the second
          // column carries why instead, and the whole message is the body.
          ? AppEvent.custom(
              channel: AppChannel.network,
              title: '${request.method} ${request.url}',
              detail: request.summary,
              data: {'answered': request.outcome},
              body: request.refusal,
              error: true,
            )
          : AppEvent.request(
              method: request.method,
              url: '${request.url}',
              status: request.status,
              data: {'answered': request.outcome},
            ),
    );
  }

  static Uint8List? _bodyOf(Object? json, List<int>? body) =>
      switch ((json, body)) {
        (null, null) => null,
        (null, var bytes?) => Uint8List.fromList(bytes),
        (var value, _) => Uint8List.fromList(utf8.encode(jsonEncode(value))),
      };
}

/// One exchange, as the scenario saw it.
class ScenarioRequest {
  ScenarioRequest({
    required this.method,
    required this.url,
    required this.outcome,
    this.status,
    this.refusal,
  });

  final String method;
  final Uri url;

  /// What answered it — `stub`, `live`, or `off`.
  final String outcome;

  /// The status it came back with, or null when nothing answered it.
  final int? status;

  /// Why nothing answered it, spelled out. Null on an exchange that happened.
  final String? refusal;

  /// The one-line version of [refusal] — what a list of events has room for.
  ///
  /// A refusal's own message is several paragraphs, because it is written to
  /// be read by somebody who has just been surprised. A column in a table is
  /// not that reader.
  String get summary => switch (refusal) {
    null => '$status',
    var text => _firstLine(text),
  };

  @override
  String toString() => '$method $url → ${status ?? summary}';
}

String _firstLine(String text) {
  var line = text.split('\n').first.trim();
  return line.length <= 80 ? line : '${line.substring(0, 79)}…';
}

/// A stated answer.
class _Stub {
  _Stub({
    required this.method,
    required this.url,
    required this.status,
    required this.body,
    required this.contentType,
    required this.headers,
    required this.throws,
  });

  /// Null on the fallback, which answers whatever it is asked.
  final String? method;
  final Pattern? url;
  final int status;
  final Uint8List? body;
  final String? contentType;
  final Map<String, List<String>> headers;
  final Object? throws;

  /// A recording, as the thing that answers a request.
  factory _Stub.of(ScenarioRecording recording) => _Stub(
    method: recording.method,
    url: null,
    status: recording.status,
    body: recording.body,
    contentType: recording.contentType,
    headers: recording.headers,
    throws: null,
  );

  bool matches(String requestMethod, Uri requestUrl) {
    if (method != null && method != requestMethod) return false;
    return switch (url) {
      null => true,
      RegExp pattern => pattern.hasMatch('$requestUrl'),
      // A string with a scheme is the whole url; one without is the path, and
      // the query too when the stub bothered to write one.
      String text when text.contains('://') => text == '$requestUrl',
      String text when text.contains('?') =>
        text == '${requestUrl.path}?${requestUrl.query}',
      String text => text == requestUrl.path,
      // `Pattern` is open — anything else is asked whether it matches the
      // whole url, which is what a custom one would mean by it.
      var pattern => pattern.allMatches('$requestUrl').isNotEmpty,
    };
  }
}

/// Installs [policy] as the answer to every `HttpClient` this process makes,
/// and returns the call that puts back what was there.
///
/// Three doors, one funnel. `HttpOverrides.global` catches an `HttpClient()`
/// the app builds and everything on top of it — `package:http`, `dio` —
/// while `NetworkImage` needs [debugNetworkImageHttpClientProvider] as well:
/// its client is a `static final` made once for the life of the *process*, so
/// a body that runs after anything has touched it inherits a client no later
/// override can dislodge.
///
/// Both are put back **inside** the body rather than in a `tearDown`. The
/// binding checks its painting debug variables at the end of the body, before
/// tearDowns run, and reports a provider still set as "the value of a painting
/// debug variable was changed by the test".
void Function() installScenarioNetwork(ScenarioNetworkPolicy policy) {
  var priorOverrides = HttpOverrides.current;
  var priorProvider = debugNetworkImageHttpClientProvider;
  HttpOverrides.global = _ScenarioHttpOverrides(policy);
  debugNetworkImageHttpClientProvider = () => _FunnelClient(policy);
  return () {
    debugNetworkImageHttpClientProvider = priorProvider;
    HttpOverrides.global = priorOverrides;
    policy.dispose();
  };
}

/// The real client, built with the overrides out of the way and in the root
/// zone.
///
/// **The root zone is not a detail.** `dart:io` arms a connection's timers in
/// the zone that opened it, and everything a widget tree does happens under
/// FakeAsync — where nothing in a settle or a landing advances the clock, so
/// those timers never fire. Plain http survives it; a TLS handshake does not,
/// and an `https://` image opened from the fake zone never completes at all.
/// Measured 2026-08-27: a remote https image never lands from the fake zone
/// and lands in 239ms from the root one, and a local plain-http request is 4×
/// faster besides. See
/// `docs/superpowers/specs/2026-08-27-scenario-http-findings.md`.
HttpClient _newRealClient() {
  var saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    // `autoUncompress` **on**, unlike `NetworkImage`'s own client, which
    // turns it off so `Content-Length` counts the bytes that arrive. What is
    // worth more here is that a body is always plain: a recording of gzipped
    // bytes replayed without the `Content-Encoding` that explained them is a
    // body nothing can decode, and the alternative — keeping that header, and
    // only that one — is a second thing the store has to be right about.
    // `consolidateHttpClientResponseBytes` reads `compressionState` and skips
    // its length check accordingly, so nothing downstream is worse off.
    return Zone.root.run(() => HttpClient()..autoUncompress = true);
  } finally {
    HttpOverrides.global = saved;
  }
}

class _ScenarioHttpOverrides extends HttpOverrides {
  _ScenarioHttpOverrides(this.policy);

  final ScenarioNetworkPolicy policy;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FunnelClient(policy);
}

/// What every `HttpClient()` in the process is, for the length of one body.
///
/// It routes rather than connects: a stub answers, else the mode does. The one
/// state it holds is a reference to the policy — the real client underneath is
/// the policy's and is shared, so an app that builds four clients still opens
/// one pool and the harness still has one thing to close.
class _FunnelClient implements HttpClient {
  _FunnelClient(this.policy);

  final ScenarioNetworkPolicy policy;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    var verb = method.toUpperCase();
    if (policy._match(verb, url) case var stub?) {
      return _StubRequest(policy, verb, url, stub);
    }
    switch (policy.mode) {
      case ScenarioNetwork.off:
        return _refusal(verb, url, ScenarioNetworkRefusal.off(verb, url));
      case ScenarioNetwork.replay:
        var recorded = policy.store.read(verb, url);
        if (recorded == null) {
          return _refusal(
            verb,
            url,
            ScenarioNetworkRefusal.notRecorded(verb, url, policy.store),
          );
        }
        return _StubRequest(policy, verb, url, _Stub.of(recorded), 'replay');
      case ScenarioNetwork.live:
      case ScenarioNetwork.record:
        // Root zone, and the whole reason this file exists — see
        // [_newRealClient]. The sink is the caller's to close, which is what
        // `close_sinks` cannot see from here.
        // ignore: close_sinks
        // Announced from here until the response's headers are in, so a
        // settle on the real clock waits for the request the way it waits
        // for an image decode — see `landRealWork`.
        scenarioLiveRequestsInFlight++;
        try {
          return _LiveRequest(
            policy,
            verb,
            url,
            await Zone.root.run(() => policy._client.openUrl(method, url)),
          );
        } catch (_) {
          scenarioLiveRequestsInFlight--;
          rethrow;
        }
    }
  }

  _StubRequest _refusal(String method, Uri url, ScenarioNetworkRefusal why) =>
      _StubRequest(
        policy,
        method,
        url,
        _Stub(
          method: method,
          url: null,
          status: 0,
          body: null,
          contentType: null,
          headers: const {},
          throws: why,
        ),
        why.outcome,
      );

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
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));
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

  /// A no-op, deliberately: the app closing "its" client must not close the
  /// pool every other client in the process is sharing, and the pending-timer
  /// invariant means somebody has to close it exactly once. That somebody is
  /// [ScenarioNetworkPolicy.dispose].
  @override
  void close({bool force = false}) {}

  // Everything below is the app configuring "its" client. It reaches the
  // shared one — see [ScenarioNetworkPolicy._configure] for why that is one
  // pool's worth of setting rather than one client's.

  /// Always true, and a setter that says so by not moving.
  ///
  /// The one setting here that is **not** forwarded, because forwarding it
  /// would break the two modes that write bodies down: a recording of gzipped
  /// bytes is a body nothing can replay, since the `Content-Encoding` that
  /// explained them describes a transfer this store does not keep. So the
  /// shared client uncompresses, always — see [_newRealClient].
  ///
  /// The getter reports what is true rather than what it was handed, which is
  /// the difference between a setting that is documented as fixed and one that
  /// is silently ignored. Code that sets it false and then trusts
  /// `contentLength` to size a buffer reads `true` back and can say so.
  @override
  bool get autoUncompress => true;
  @override
  set autoUncompress(bool value) {}
  @override
  Duration? get connectionTimeout => _connectionTimeout;
  @override
  set connectionTimeout(Duration? value) {
    _connectionTimeout = value;
    policy._configure((client) => client.connectionTimeout = value);
  }

  Duration? _connectionTimeout;

  @override
  Duration get idleTimeout => _idleTimeout;
  @override
  set idleTimeout(Duration value) {
    _idleTimeout = value;
    policy._configure((client) => client.idleTimeout = value);
  }

  Duration _idleTimeout = const Duration(seconds: 15);

  @override
  int? get maxConnectionsPerHost => _maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) {
    _maxConnectionsPerHost = value;
    policy._configure((client) => client.maxConnectionsPerHost = value);
  }

  int? _maxConnectionsPerHost;

  @override
  String? get userAgent => _userAgent;
  @override
  set userAgent(String? value) {
    _userAgent = value;
    policy._configure((client) => client.userAgent = value);
  }

  String? _userAgent;

  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? value) =>
      policy._configure((client) => client.authenticate = value);
  @override
  set authenticateProxy(
    Future<bool> Function(String, int, String, String?)? value,
  ) => policy._configure((client) => client.authenticateProxy = value);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate, String, int)? value,
  ) => policy._configure((client) => client.badCertificateCallback = value);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value,
  ) => policy._configure((client) => client.connectionFactory = value);
  @override
  set findProxy(String Function(Uri)? value) =>
      policy._configure((client) => client.findProxy = value);
  @override
  set keyLog(void Function(String)? value) =>
      policy._configure((client) => client.keyLog = value);
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials c) =>
      policy._configure((client) => client.addCredentials(url, realm, c));
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials c,
  ) => policy._configure(
    (client) => client.addProxyCredentials(host, port, realm, c),
  );
}

/// The exception a request gets when the network is [ScenarioNetwork.off] and
/// nothing stated an answer.
///
/// Thrown rather than answered with a 400, because a 400 is a thing a server
/// said and this is not — an app that retries on 4xx would retry this, under
/// fake time, forever. And named rather than silent: a blank avatar with no
/// explanation is the state this whole feature exists to end.
class ScenarioNetworkRefusal implements Exception {
  ScenarioNetworkRefusal._({
    required this.method,
    required this.url,
    required this.outcome,
    required this.short,
    required this.rest,
  });

  /// Nothing stated an answer and the network is [ScenarioNetwork.off].
  factory ScenarioNetworkRefusal.off(String method, Uri url) =>
      ScenarioNetworkRefusal._(
        method: method,
        url: url,
        outcome: 'off',
        short: 'refused — the network is off for this scenario',
        rest:
            '$method $url was not made.\n'
            '\n'
            '${_answerIt(url)}'
            '\n'
            'Or record it once and commit what comes back:\n'
            '  fw run scenarios run --network=record\n'
            '\n'
            'Or let this scenario reach the network every time:\n'
            '  scenario(…, network: ScenarioNetwork.live, (s) async { … });',
      );

  /// [ScenarioNetwork.replay], and the store has nothing for this exchange.
  ///
  /// The most-read sentence in this file: it is what a suite meets the first
  /// time an endpoint moves. So it says what the store *does* hold for that
  /// host, and when it was written — because "the url changed" and "the
  /// recording is a year old" are the two things it is, and the store knows
  /// both.
  factory ScenarioNetworkRefusal.notRecorded(
    String method,
    Uri url,
    ScenarioNetworkStore store,
  ) {
    var keys = store.keys();
    var sameHost = [
      for (var key in keys)
        if (key.contains('://${url.host}')) key,
    ];
    return ScenarioNetworkRefusal._(
      method: method,
      url: url,
      outcome: 'not-recorded',
      short: 'no recording for this request',
      rest:
          'The recording holds nothing for $method $url.\n'
          '\n'
          '${_whatItHolds(keys, sameHost, url)}'
          '\n'
          'Record it:\n'
          '  fw run scenarios run --network=record\n'
          '\n'
          '${_answerIt(url)}',
    );
  }

  final String method;
  final Uri url;

  /// The machine-readable word for what happened, as the step reports it.
  final String outcome;

  /// The column-width version, for an events list. See
  /// [ScenarioRequest.summary].
  final String short;

  /// Everything under the first line.
  final String rest;

  @override
  String toString() => '$short\n\n$rest';

  static String _answerIt(Uri url) =>
      'Answer it here:\n'
      "  s.network.get('${url.path}', json: {…});\n";

  static String _whatItHolds(
    List<String> keys,
    List<String> sameHost,
    Uri url,
  ) {
    if (keys.isEmpty) {
      return 'Nothing has been recorded yet — the store at '
          '`$defaultScenarioNetworkStore` is empty.\n';
    }
    if (sameHost.isEmpty) {
      return 'It holds ${_count(keys.length)}, none of them for '
          '${url.host}.\n';
    }
    var listed = sameHost.take(8);
    return 'It holds ${_count(sameHost.length)} for ${url.host}:\n'
        '${listed.map((key) => '  $key\n').join()}'
        '${sameHost.length > listed.length ? '  … and ${sameHost.length - listed.length} more\n' : ''}';
  }

  static String _count(int n) => n == 1 ? '1 request' : '$n requests';
}

/// A request whose answer was decided before it was opened.
class _StubRequest implements HttpClientRequest {
  _StubRequest(
    this._policy,
    this.method,
    this.uri,
    this._stub, [
    this._outcome = 'stub',
  ]);

  final ScenarioNetworkPolicy _policy;
  final _Stub _stub;

  /// What answered it — `stub`, `replay`, `off`, or `not-recorded`.
  final String _outcome;
  final _sent = BytesBuilder();

  @override
  final String method;
  @override
  final Uri uri;

  /// Answered once, however many of [close] and [done] the caller awaits.
  ///
  /// `package:http` closes; other code awaits `done`; some does both. Each of
  /// those must not be a second exchange on the step, and a stub that throws
  /// must not throw twice from one request.
  late final Future<HttpClientResponse> _answer = _answered();

  Future<HttpClientResponse> _answered() async {
    if (_stub.throws case var error?) {
      _policy._record(
        ScenarioRequest(
          method: method,
          url: uri,
          outcome: _outcome,
          refusal: '$error',
        ),
      );
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    _policy._record(
      ScenarioRequest(
        method: method,
        url: uri,
        outcome: _outcome,
        status: _stub.status,
      ),
    );
    return _StubResponse(_stub);
  }

  @override
  Future<HttpClientResponse> close() => _answer;

  /// The bytes the caller wrote — a POST body a stub may want to read back.
  Uint8List get sent => _sent.toBytes();

  @override
  Future<HttpClientResponse> get done => _answer;

  @override
  void add(List<int> data) => _sent.add(data);
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(_sent.add);
  @override
  void write(Object? object) => add(encoding.encode('$object'));
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> flush() async {}
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  bool bufferOutput = true;
  @override
  int contentLength = -1;
  @override
  Encoding encoding = utf8;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  final HttpHeaders headers = _StubHeaders();
  @override
  List<Cookie> get cookies => <Cookie>[];
  @override
  HttpConnectionInfo? get connectionInfo => null;
}

class _StubResponse extends Stream<List<int>> implements HttpClientResponse {
  _StubResponse(this._stub);

  final _Stub _stub;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_stub.body ?? Uint8List(0)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int get statusCode => _stub.status;
  @override
  String get reasonPhrase => _reasons[_stub.status] ?? 'Stubbed';
  @override
  int get contentLength => _stub.body?.length ?? 0;
  @override
  late final HttpHeaders headers = _headersOf(_stub);

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  bool get isRedirect => _stub.status >= 300 && _stub.status < 400;
  @override
  bool get persistentConnection => false;
  @override
  List<Cookie> get cookies => <Cookie>[];
  @override
  List<RedirectInfo> get redirects => <RedirectInfo>[];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => Future<HttpClientResponse>.error(
    UnsupportedError('A stubbed response does not redirect.'),
  );
  @override
  Future<Socket> detachSocket() => Future<Socket>.error(
    UnsupportedError('A stubbed response has no socket.'),
  );
}

const _reasons = {
  200: 'OK',
  201: 'Created',
  204: 'No Content',
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  500: 'Internal Server Error',
  503: 'Service Unavailable',
};

/// A live request, wrapped only so the exchange reaches the step.
///
/// Everything is the real object's; [close] is the one member with anything of
/// its own to do, because the status is not knowable until the response is.
class _LiveRequest implements HttpClientRequest {
  _LiveRequest(this._policy, this.method, this.uri, this._inner);

  final ScenarioNetworkPolicy _policy;
  final HttpClientRequest _inner;

  /// Whether the response's headers are in — the point this request stops
  /// being announced work.
  var _closed = false;

  @override
  final String method;
  @override
  final Uri uri;

  @override
  Future<HttpClientResponse> close() async {
    try {
      var response = await Zone.root.run(_inner.close);
      _closed = true;
      scenarioLiveRequestsInFlight--;
      if (_policy.mode != ScenarioNetwork.record) {
        _policy._record(
          ScenarioRequest(
            method: method,
            url: uri,
            outcome: 'live',
            status: response.statusCode,
          ),
        );
        return response;
      }
      // Drained here rather than by the caller, because a body cannot be
      // written down and also handed over as a stream — and in the root zone,
      // for the reason every other socket read here is.
      var recording = ScenarioRecording(
        method: method,
        url: uri,
        status: response.statusCode,
        contentType: response.headers.contentType?.toString(),
        headers: _keptHeadersOf(response),
        body: await Zone.root.run(() => _drain(response)),
      );
      // Whatever came back, error status included: a 500 a scenario is *about*
      // is worth recording. A transient one is not, and the way that is caught
      // is that the recording is a file in a diff.
      _policy.store.write(recording);
      _policy._record(
        ScenarioRequest(
          method: method,
          url: uri,
          outcome: 'record',
          status: response.statusCode,
        ),
      );
      // The bytes that were written, not the ones off the wire — so a record
      // run and every replay after it draw the same picture.
      return _StubResponse(_Stub.of(recording));
    } on Object catch (error) {
      // Counted down once, whichever line above threw: a refused connect
      // never reached the decrement, a failed drain already did.
      if (!_closed) scenarioLiveRequestsInFlight--;
      _policy._record(
        ScenarioRequest(
          method: method,
          url: uri,
          outcome: _policy.mode.name,
          refusal: '$error',
        ),
      );
      rethrow;
    }
  }

  /// The response's headers, minus the ones a committed file may not hold and
  /// the ones that describe a transfer whose bytes are not what is stored —
  /// see [ScenarioNetworkStore.keptHeader].
  ///
  /// Kept at all because an app reads them: `Link` is how a list paginates,
  /// and a screen that worked under `live` and lost its second page the moment
  /// somebody recorded it is the failure this exists to avoid.
  static Map<String, List<String>> _keptHeadersOf(HttpClientResponse response) {
    var kept = <String, List<String>>{};
    response.headers.forEach((name, values) {
      if (ScenarioNetworkStore.keptHeader(name)) {
        kept[name.toLowerCase()] = List.of(values);
      }
    });
    return kept;
  }

  static Future<Uint8List> _drain(HttpClientResponse response) async {
    var bytes = BytesBuilder(copy: false);
    await for (var chunk in response) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  Future<HttpClientResponse> get done => _inner.done;
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> flush() => _inner.flush();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
}

class _StubHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) => this[name]?.firstOrNull;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values.putIfAbsent(name.toLowerCase(), () => []).add('$value');

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = ['$value'];

  @override
  void remove(String name, Object value) =>
      _values[name.toLowerCase()]?.remove('$value');

  @override
  void removeAll(String name) => _values.remove(name.toLowerCase());

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  void clear() => _values.clear();

  @override
  void noFolding(String name) {}

  @override
  ContentType? get contentType => switch (value('content-type')) {
    null => null,
    var raw => ContentType.parse(raw),
  };
  @override
  set contentType(ContentType? value) =>
      value == null ? removeAll('content-type') : set('content-type', value);

  @override
  int get contentLength => int.tryParse(value('content-length') ?? '') ?? -1;
  @override
  set contentLength(int value) => set('content-length', value);

  @override
  DateTime? get date => null;
  @override
  set date(DateTime? value) {}
  @override
  DateTime? get expires => null;
  @override
  set expires(DateTime? value) {}
  @override
  DateTime? get ifModifiedSince => null;
  @override
  set ifModifiedSince(DateTime? value) {}
  @override
  String? get host => null;
  @override
  set host(String? value) {}
  @override
  int? get port => null;
  @override
  set port(int? value) {}
  @override
  bool get chunkedTransferEncoding => false;
  @override
  set chunkedTransferEncoding(bool value) {}
  @override
  bool get persistentConnection => false;
  @override
  set persistentConnection(bool value) {}
}

_StubHeaders _headersOf(_Stub stub) {
  var headers = _StubHeaders();
  if (stub.contentType case var type?) headers.set('content-type', type);
  for (var MapEntry(:key, :value) in stub.headers.entries) {
    for (var entry in value) {
      headers.add(key, entry);
    }
  }
  // Last, and set rather than added: what is handed back is the whole body, so
  // a recorded length that described a compressed transfer would be a lie the
  // caller could act on.
  headers.set('content-length', stub.body?.length ?? 0);
  return headers;
}

/// A solid PNG, for a scenario that needs an image to be *there* and does not
/// care what it is.
///
/// The alternative in a test file is a base64 blob nobody can read or change,
/// pasted once and copied forever.
Uint8List scenarioPlaceholderPng({
  int width = 1,
  int height = 1,
  int red = 0x9E,
  int green = 0x9E,
  int blue = 0x9E,
}) {
  var raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    for (var x = 0; x < width; x++) {
      raw.add([red, green, blue]);
    }
  }
  var ihdr = BytesBuilder()
    ..add(_be32(width))
    ..add(_be32(height))
    ..add([8, 2, 0, 0, 0]);
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ..._chunk('IHDR', ihdr.toBytes()),
    ..._chunk('IDAT', ZLibEncoder().convert(raw.toBytes())),
    ..._chunk('IEND', const []),
  ]);
}

List<int> _chunk(String type, List<int> data) {
  var body = [...ascii.encode(type), ...data];
  return [..._be32(data.length), ...body, ..._be32(_crc32(body))];
}

List<int> _be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (var byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
