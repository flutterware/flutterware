import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Where a package keeps what its scenarios recorded, unless it says otherwise.
///
/// Package-relative and committed. Both lanes run with the package root as
/// their working directory — `flutter test` does, and the runner spawns
/// `flutter_tester` with `workingDirectory: packageRoot` — so this resolves
/// the same in both without anybody passing a path.
///
/// Under `test/` rather than under `build/` because it is an **input**. A
/// recording that is not committed makes a fresh clone need a network to
/// reproduce yesterday's screenshots, which is the whole thing this exists to
/// avoid.
const defaultScenarioNetworkStore = 'test/scenarios/network';

/// Where the recording is, when something says so: a `fw.network.store`
/// dart-define, then `FW_NETWORK_STORE`, then [defaultScenarioNetworkStore].
///
/// The same pair every other "the host tells the test process something"
/// setting reads. A monorepo whose packages share one API is the case it is
/// for — and a test that needs a temporary one sets [scenarioNetworkStorePath]
/// directly.
String resolvedScenarioNetworkStore() {
  if (scenarioNetworkStorePath case var path?) return path;
  const define = String.fromEnvironment('fw.network.store');
  if (define.isNotEmpty) return define;
  var env = Platform.environment['FW_NETWORK_STORE'];
  return env == null || env.isEmpty ? defaultScenarioNetworkStore : env;
}

/// Set by the harness, or by a test that keeps its recording in a temporary
/// directory; null everywhere else.
String? scenarioNetworkStorePath;

/// One recorded exchange.
class ScenarioRecording {
  ScenarioRecording({
    required this.method,
    required this.url,
    required this.status,
    required this.body,
    this.contentType,
    this.headers = const {},
  });

  final String method;
  final Uri url;
  final int status;
  final Uint8List body;

  /// Its own field rather than an entry in [headers], because the extension a
  /// body file gets is picked from it.
  final String? contentType;

  /// Every other response header worth keeping, lowercased. See
  /// [ScenarioNetworkStore.keptHeader] for what is dropped and why.
  final Map<String, List<String>> headers;

  /// What identifies this exchange: the method and the whole url, query
  /// included.
  ///
  /// Exact, and no normalisation. A store that quietly answered
  /// `?page=1` with what it recorded for `?page=2` would be worse than no
  /// store at all, and a request carrying a nonce is better served by a stub
  /// that says so than by a matcher guessing which parts of a url matter.
  String get key => '$method $url';
}

/// What the scenarios of one package recorded, on disk.
///
/// **One file per exchange, and no index.** `flutter test` runs test files
/// concurrently, in separate processes, so a single index would be a
/// read-modify-write race between them — and a recording that loses entries
/// depending on how the runner scheduled the suite is not a recording. Two
/// processes writing the same exchange write the same path, which is a
/// last-writer-wins on identical bytes.
///
/// The body is a **sibling file with the right extension**, never a string
/// inside the metadata. A committed recording is read in a diff, and a 5KB
/// JSON response escaped into one line of a `.json` field is a recording
/// nobody reviews.
class ScenarioNetworkStore {
  ScenarioNetworkStore(this.directory);

  /// Where the files live. Absolute, or relative to the working directory —
  /// which both lanes set to the package root.
  final String directory;

  /// What [method] [url] was recorded as, or null when nothing was.
  ScenarioRecording? read(String method, Uri url) =>
      _readAs(_name(method, url), method, url) ??
      _readAs(_legacyName(method, url), method, url);

  ScenarioRecording? _readAs(String name, String method, Uri url) {
    var file = File(p.join(directory, '$name.json'));
    if (!file.existsSync()) return null;
    var json = jsonDecode(file.readAsStringSync());
    if (json is! Map<String, Object?>) return null;
    // The url is read back off the file rather than trusted from the caller:
    // a digest collision, or a hand-edited file, must answer for what it
    // actually holds or refuse — never for what was asked.
    if (json['method'] != method || json['url'] != '$url') return null;
    return ScenarioRecording(
      method: method,
      url: url,
      status: switch (json['status']) {
        int code => code,
        _ => 200,
      },
      contentType: json['contentType'] as String?,
      headers: switch (json['headers']) {
        Map<String, Object?> raw => {
          for (var MapEntry(:key, :value) in raw.entries)
            if (value is List) key: [for (var item in value) '$item'],
        },
        _ => const {},
      },
      body: switch (json['body']) {
        String name => _readBody(p.join(directory, name)),
        _ => Uint8List(0),
      },
    );
  }

  /// Writes [recording], replacing whatever was there for the same exchange.
  ///
  /// **No request headers at all.** They are not part of the key, so keeping
  /// them would be writing an `Authorization` into a committed file for
  /// nothing.
  ///
  /// Response headers are kept **except** the ones [keptHeader] refuses, which
  /// is a deny-list and deliberately not an allow-list. An allow-list is the
  /// safer-sounding of the two and the wrong one here: what it drops it drops
  /// *silently*, and the first thing it drops is `Link` — so a screen that
  /// paginates works under `live`, is recorded, and quietly renders one page
  /// forever after, with the recording looking correct in the diff. A
  /// deny-list can only be wrong about a header nobody thought of, and it is
  /// wrong about it in a file somebody reads before committing.
  ///
  /// A response *body* is on the same footing: an endpoint that answers with a
  /// token answers with a token. That is true of any fixture, and there is
  /// nothing this can do about it beyond writing it somewhere reviewable.
  ///
  /// **Unchanged is untouched.** When the store already holds the same
  /// status, content type, kept headers and body under the current name,
  /// nothing is written — so re-recording an API that did not move leaves
  /// `git status` clean, and a reviewer reading the diff of a record run reads
  /// only what moved. That is also why no file carries the time it was
  /// fetched: git already knows when the bytes last changed, and a stamp
  /// rewritten on every run would put every file in every diff.
  void write(ScenarioRecording recording) {
    var name = _name(recording.method, recording.url);
    var legacy = _legacyName(recording.method, recording.url);
    if (_readAs(name, recording.method, recording.url) case var held?
        when _sameExchange(held, recording)) {
      return;
    }
    Directory(directory).createSync(recursive: true);
    // A recording made before names kept the end of the path is moved to the
    // current name rather than left beside it.
    if (legacy != name) {
      var file = File(p.join(directory, '$legacy.json'));
      if (file.existsSync()) file.deleteSync();
      _deleteBodies(legacy);
    }
    // Unconditionally, and before the new one is written: a body recorded as
    // JSON and re-recorded as an error page changes extension, and the old
    // file would otherwise sit in the store forever with nothing left naming
    // it.
    _deleteBodies(name);
    var body = recording.body.isEmpty
        ? null
        : '$name.body.${_extensionFor(recording.contentType)}';
    if (body != null) {
      File(p.join(directory, body)).writeAsBytesSync(recording.body);
    }
    File(p.join(directory, '$name.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'method': recording.method,
        'url': '${recording.url}',
        'status': recording.status,
        'contentType': ?recording.contentType,
        if (recording.headers.isNotEmpty) 'headers': {for (var key in recording.headers.keys.toList()..sort()) key: recording.headers[key]},
        'bytes': recording.body.length,
        'body': ?body,
      })}\n',
    );
  }

  static bool _sameExchange(ScenarioRecording a, ScenarioRecording b) {
    if (a.status != b.status || a.contentType != b.contentType) return false;
    if (!_sameBytes(a.body, b.body)) return false;
    if (a.headers.length != b.headers.length) return false;
    for (var MapEntry(:key, :value) in a.headers.entries) {
      var other = b.headers[key];
      if (other == null || other.length != value.length) return false;
      for (var i = 0; i < value.length; i++) {
        if (value[i] != other[i]) return false;
      }
    }
    return true;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Every exchange the store holds, as `METHOD url`, in file order.
  ///
  /// Read by a refusal rather than by the funnel: a miss is worth answering
  /// with what the store *does* have for that host, and the walk is only paid
  /// for on the step that already failed.
  List<String> keys() {
    var dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    var keys = <String>[];
    for (var entry in dir.listSync().whereType<File>()) {
      // `.body.json` is a recorded *body*, not a recording. Parsed as one, an
      // API that answers `{"method": …, "url": …}` — a webhook or audit-log
      // endpoint — would list an exchange the store does not hold, and the
      // refusal would be lying to whoever is reading it.
      var name = p.basename(entry.path);
      if (!name.endsWith('.json') || name.contains('.body.')) continue;
      try {
        var json = jsonDecode(entry.readAsStringSync());
        if (json case {'method': String method, 'url': String url}) {
          keys.add('$method $url');
        }
      } on FormatException {
        // A file somebody hand-edited into invalid JSON is not a reason for a
        // refusal to fail instead of explaining itself.
        continue;
      }
    }
    return keys..sort();
  }

  Uint8List _readBody(String path) {
    var file = File(path);
    return file.existsSync() ? file.readAsBytesSync() : Uint8List(0);
  }

  void _deleteBodies(String name) {
    var dir = Directory(directory);
    if (!dir.existsSync()) return;
    for (var entry in dir.listSync().whereType<File>()) {
      if (p.basename(entry.path).startsWith('$name.body.')) {
        entry.deleteSync();
      }
    }
  }

  /// Whether a response header of this name belongs in a committed recording.
  ///
  /// Three kinds are refused. **Credentials**, because a recording is a file in
  /// a repository and a session is not: `Set-Cookie` is the one that would
  /// actually leak, and its neighbours are here so the rule reads as a rule.
  /// And **the transfer's own description** — `Content-Encoding`,
  /// `Content-Length`, `Transfer-Encoding` and the connection pair — because
  /// what is stored is the body *after* decoding, so a header saying it is
  /// gzipped and 812 bytes long would be a header about bytes that are
  /// neither. `Content-Type` is not here because it has a field of its own.
  /// And **what differs on every fetch of the same bytes** — the date, a
  /// cache's age and hit counters, the request and trace ids servers and CDNs
  /// stamp — because a header that changes when nothing else did turns every
  /// re-record into a diff on every file, and a reviewer can no longer see
  /// which ones moved.
  static bool keptHeader(String name) => !_dropped.contains(name.toLowerCase());

  static const _dropped = {
    // Credentials.
    'set-cookie',
    'set-cookie2',
    'authorization',
    'proxy-authorization',
    'www-authenticate',
    'proxy-authenticate',
    // About a transfer whose bytes are not what is stored.
    'content-encoding',
    'content-length',
    'transfer-encoding',
    'connection',
    'keep-alive',
    // Held as a field of its own.
    'content-type',
    // Different on every fetch of the same bytes.
    'date',
    'expires',
    'age',
    'via',
    'server-timing',
    'x-request-id',
    'x-correlation-id',
    'x-amz-request-id',
    'x-amz-id-2',
    'x-amz-cf-id',
    'x-amz-cf-pop',
    'x-amzn-requestid',
    'x-amzn-trace-id',
    'cf-ray',
    'cf-cache-status',
    'x-cache',
    'x-cache-hits',
    'x-served-by',
    'x-timer',
  };

  /// A file name that is readable in a diff and unique by construction.
  ///
  /// The slug is for the human reading `git status`; the digest is what makes
  /// it an identity. Neither alone would do: two urls slug to the same thing
  /// often (`/users/1` and `/users/2` once the digits are stripped is a design
  /// nobody wants, and keeping them still collides on length), and a bare
  /// digest is a folder of hex nobody can review.
  static String _name(String method, Uri url) =>
      '${_slug(method, url)}-${_digest(method, url)}';

  /// What [_name] was before a long url kept the end of its path. Still read,
  /// so a store recorded then replays now; [write] moves it on.
  static String _legacyName(String method, Uri url) {
    var slug = _slugOf('$method ${url.host}${url.path}');
    if (slug.length > _slugLength) slug = slug.substring(0, _slugLength);
    return '$slug-${_digest(method, url)}';
  }

  static String _digest(String method, Uri url) =>
      sha1.convert(utf8.encode('$method $url')).toString().substring(0, 8);

  static const _slugLength = 60;

  /// The method, host and path, whole when they fit and otherwise cut so the
  /// end of the path survives.
  ///
  /// What tells two recordings of one service apart is almost never the host —
  /// they share it — but the last few segments of the path. Cut from the
  /// start, a store of one CDN folder is a column of identical names; so a
  /// long one keeps a shortened host, then as many trailing segments as fit,
  /// each capped so a content hash for a file name cannot crowd out the folder
  /// it sits in.
  static String _slug(String method, Uri url) {
    var whole = _slugOf('$method ${url.host}${url.path}');
    if (whole.length <= _slugLength) return whole;
    var head = _cutAtWord(_slugOf('$method ${url.host}'), 28);
    var budget = _slugLength - head.length - 1;
    var tail = <String>[];
    var used = 0;
    for (var segment in url.pathSegments.reversed) {
      var part = _slugOf(segment);
      if (part.isEmpty) continue;
      if (part.length > 16) part = _trimDashes(part.substring(0, 16));
      var cost = part.length + (tail.isEmpty ? 0 : 1);
      if (used + cost > budget) break;
      tail.insert(0, part);
      used += cost;
    }
    return tail.isEmpty ? head : '$head-${tail.join('-')}';
  }

  static String _slugOf(String text) =>
      _trimDashes(text.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-'));

  static String _trimDashes(String text) =>
      text.replaceAll(RegExp(r'^-+|-+$'), '');

  /// [slug] at most [length] long, cut after a whole word when one ends past
  /// half of it.
  static String _cutAtWord(String slug, int length) {
    if (slug.length <= length) return slug;
    var cut = slug.substring(0, length);
    if (slug[length] == '-') return cut;
    var dash = cut.lastIndexOf('-');
    return _trimDashes(dash > length ~/ 2 ? cut.substring(0, dash) : cut);
  }

  /// What a body file is called, so an editor opens it as what it is.
  static String _extensionFor(String? contentType) {
    var type = (contentType ?? '').split(';').first.trim().toLowerCase();
    return switch (type) {
      'application/json' || 'text/json' => 'json',
      'image/png' => 'png',
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/svg+xml' => 'svg',
      'text/html' => 'html',
      'text/css' => 'css',
      'text/csv' => 'csv',
      'application/xml' || 'text/xml' => 'xml',
      _ when type.startsWith('text/') => 'txt',
      _ when type.endsWith('+json') => 'json',
      _ => 'bin',
    };
  }
}
