/// A toy HTTP server, instrumented for flutterware's server inspection.
///
/// Run it any way you like — `dart run bin/example_server.dart`, the IDE's run
/// button, an agent — then `curl localhost:8080/users`. No flutterware launch
/// step: the library announces itself in `~/.flutterware/run` on first use,
/// and the GUI / `fw` / MCP attach to that.
///
/// **Filling the panel.** Working on the Server panel means needing one of
/// everything it draws, and curling for it by hand gets you a list of eleven
/// `GET /health`s. So the server can drive itself: `--seed` fires the whole
/// matrix at boot, and `GET /demo/seed` fires it again — it is published as a
/// link, so it is one click from the panel's own Details popover. Between them
/// [_seed] produces every method, every status band, every log level, a query
/// of every shape, bodies that fold and bodies that cannot be captured, and an
/// event on a channel the GUI has never heard of.
///
/// The `_inspect` middleware and `_query` wrapper below are the copy-paste
/// adapters the design doc describes (spec decision 5): a project pastes and
/// adapts them, only the primitives live in `package:flutterware/server.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/server.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

final _log = Logger('example_server');

/// Two more, so the panel's logger column has something to distinguish and a
/// filter has more than one name to narrow to. A real server's log is never
/// one logger's.
final _audit = Logger('example_server.audit');
final _cache = Logger('example_server.cache');

/// Where this process is listening, once it is. The seeder calls itself.
String? _base;

/// Whether a seed run is already in flight.
///
/// `/demo/seed` is a link, and a link gets clicked twice, reloaded, and
/// prefetched by the browser. Two overlapping runs would interleave their
/// requests, which is exactly the property [_seed] spaces its calls out to
/// protect: a request list is read as a timeline.
var _seeding = false;

Future<void> main(List<String> args) async {
  // Launched in the background — by `tool/stack.dart up`, which is what the
  // `DevStack` plugin runs — this process has no terminal to print into, so the
  // launcher names a file to append to as well. Started by hand, the variable
  // is absent and stdout is the only destination.
  var logFile = Platform.environment['EXAMPLE_SERVER_LOG'];

  // Adapter: forward `package:logging` to the `log` channel. The listener
  // runs in whatever zone called `listen`, so correlation must come from
  // `record.zone` — the zone the log call happened in.
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    stdout.writeln(record);
    if (logFile != null) {
      // Written through rather than buffered: `tool/stack.dart logs` reads this
      // file from another process, and a line still sitting in an IOSink is a
      // line that log command cannot see.
      File(logFile)
          .writeAsStringSync('$record\n', mode: FileMode.append, flush: true);
    }
    (record.zone ?? Zone.current).run(() {
      FlutterwareServer.event('log', {
        'level': record.level.name,
        'logger': record.loggerName,
        'message': record.message,
        if (record.error != null) 'error': '${record.error}',
      });
    });
  });

  // Command handlers run *inside* this process, against its own "database" —
  // which is why the GUI can explain and re-run queries with no DB config.
  // A command is invoked with the chosen occurrence's `params` beside its
  // `query`, because the query is reported with its placeholders intact and so
  // will not run on its own. A real adapter binds them; this toy database has
  // no placeholders to bind, so it shows what it was handed.
  FlutterwareServer.handle('sql', 'explain', (params) {
    var bound = params['params'];
    return {
      'plan': 'SCAN ${params['query']} (toy database, toy plan)',
      'boundTo': ?bound,
    };
  });
  FlutterwareServer.handle('sql', 'requery', (params) {
    return {'rows': _database.execute(params['query']?.toString() ?? '')};
  });

  var handler = const Pipeline().addMiddleware(_inspect()).addHandler(_route);
  var server = await shelf_io.serve(
    handler,
    InternetAddress.loopbackIPv4,
    8080,
  );
  _log.info('listening on http://localhost:${server.port}');
  _base = 'http://localhost:${server.port}';

  // `--seed` is opt-in, because this file is also the copy-paste adapter demo
  // and a demo that fires forty requests at itself on boot is a demo that
  // buries the one you sent by hand. Working *on* the panel, it is what you
  // want, and `GET /demo/seed` is the same thing from a link.
  if (args.contains('--seed')) unawaited(_seed());

  // The self-description — published after `serve` so the port is real.
  // Sections merge per publish: calling `info` again later with only
  // `config:` set would update config and leave the links alone.
  FlutterwareServer.info(
    ServerInfo(
      baseUrl: 'http://localhost:${server.port}',
      environment: 'dev',
      links: [
        // First, because it is the one anybody working on the panel wants:
        // a click here refills every list behind it.
        ServerLink(
          'Seed traffic',
          '/demo/seed',
          description: 'one of everything the panel draws',
        ),
        ServerLink('Health', '/health', description: 'liveness probe'),
        ServerLink('Users', '/users', description: 'the N+1 demo'),
        ServerLink('Report', '/report', description: 'a JSON body that folds'),
        ServerLink('flutterware', 'https://pub.dev/packages/flutterware'),
      ],
      connections: [
        // The password is fake, and shows up masked in the GUI anyway —
        // attachers mask password-shaped parts of a DSN for display.
        ServerConnection('toy', 'toy://app:s3cret@memory/toydb', label: 'main'),
        // A second kind, so the panel's kind chips are seen next to each
        // other, and one with nothing to mask so the reveal control is seen
        // both present and absent.
        ServerConnection('redis', 'redis://memory:6379/0', label: 'cache'),
      ],
      config: {
        'Feature flags': {'newCheckout': true, 'betaBanner': false},
        'Toy database': {'queryLatencyMs': 2, 'apiKey': 'not-a-real-key'},
        // Structured values, which the panel folds into a `JsonView` rather
        // than printing on one line. Nothing else here exercises that branch.
        'Limits': {
          'rate': {'perMinute': 600, 'burst': 50, 'scope': 'ip'},
          'regions': ['eu-west', 'us-east', 'ap-south'],
          'secretToken': 'also-not-real',
        },
      },
    ),
  );
}

/// Adapter: the shelf middleware. One `runZoned` is the whole correlation
/// story — every query and log line emitted below it carries this request's id.
///
/// Headers and small textual bodies go into the event's `details` (spec
/// decision 11). Only the delivery is on demand: the map is built here on
/// every request and encoded as the event is reported, then held server-side
/// until somebody opens the Request/Response tab — which is why bodies are
/// capped. Redaction happens *here*, in code you own, before anything leaves
/// your handler's reach.
Middleware _inspect() {
  var nextRequestId = 1;
  return (inner) => (request) {
    var id = 'req-${nextRequestId++}';
    return runZoned(() async {
      var watch = Stopwatch()..start();
      var (request2, requestBody) = await _captureRequestBody(request);
      try {
        var response = await inner(request2);
        var (response2, responseBody) = await _captureResponseBody(response);
        FlutterwareServer.event(
          'http',
          {
            'method': request.method,
            'path': '/${request.url.path}',
            'status': response.statusCode,
            'ms': watch.elapsedMicroseconds / 1000,
          },
          details: {
            'requestHeaders': _redact(request.headers),
            'responseHeaders': _redact(response.headers),
            'requestBody': ?requestBody,
            'responseBody': ?responseBody,
          },
        );
        return response2;
      } on HijackException {
        // Shelf signals a hijack — a websocket upgrade, an SSE stream taking
        // the socket — by *throwing* past the middleware. It is the success
        // path, and caught below it would post a phantom 500 for every
        // websocket connection that worked.
        rethrow;
      } catch (e) {
        FlutterwareServer.event(
          'http',
          {
            'method': request.method,
            'path': '/${request.url.path}',
            'status': 500,
            'ms': watch.elapsedMicroseconds / 1000,
            'error': '$e',
          },
          details: {'requestHeaders': _redact(request.headers)},
        );
        rethrow;
      }
    }, zoneValues: {FlutterwareServer.requestIdKey: id});
  };
}

/// The capture cut (spec decision 11): textual content types with a known
/// length under the cap are buffered; streams and everything else are
/// recorded as size only. Reading a shelf body consumes it, so a captured
/// message is rebuilt around the bytes just read.
const _bodyCap = 32 * 1024;

bool _textual(String? contentType) =>
    contentType != null &&
    (contentType.contains('json') ||
        contentType.startsWith('text/') ||
        contentType.contains('xml') ||
        contentType.contains('form-urlencoded'));

Future<(Request, String?)> _captureRequestBody(Request request) async {
  if (request.contentLength == null ||
      request.contentLength == 0 ||
      request.contentLength! > _bodyCap ||
      !_textual(request.headers['content-type'])) {
    return (request, null);
  }
  var body = await request.readAsString();
  return (request.change(body: body), body);
}

Future<(Response, String?)> _captureResponseBody(Response response) async {
  if (response.contentLength == null ||
      response.contentLength == 0 ||
      response.contentLength! > _bodyCap ||
      !_textual(response.headers['content-type'])) {
    return (response, null);
  }
  var body = await response.readAsString();
  return (response.change(body: body), body);
}

/// What must not leave the process, dropped before reporting.
///
/// This list is a starting point and is wrong for your server. The way to
/// get it right is not to lengthen it from memory but to grep your handlers
/// for the headers they actually read: a project accepting `x-authorization`
/// as a fallback for `authorization` is a line nobody outside it would guess,
/// and a `x-publishable-key` is *publishable* — redacting it costs you the
/// answer to which integrator a request came from, which is half of why the
/// panel gets opened.
Map<String, String> _redact(Map<String, String> headers) => {
  for (var entry in headers.entries)
    entry.key:
        const {
          'authorization',
          'cookie',
          'set-cookie',
        }.contains(entry.key.toLowerCase())
        ? '<redacted>'
        : entry.value,
};

/// Adapter: a query wrapper — what a drift `QueryInterceptor` or a thin
/// sqlite3/postgres wrapper reduces to. Parameters and the row count ride
/// along, which is what the query views show per occurrence.
List<Map<String, Object?>> _query(String sql, [List<Object?>? params]) {
  var watch = Stopwatch()..start();
  var rows = _database.execute(sql);
  FlutterwareServer.event('sql', {
    'query': sql,
    'params': ?params,
    'rows': rows.length,
    'ms': watch.elapsedMicroseconds / 1000,
  });
  return rows;
}

Future<Response> _route(Request request) async {
  var path = '/${request.url.path}';
  var method = request.method;

  // The `/users/<id>` family, so the list has a verb per colour and the
  // status column has something other than 200 in it.
  if (RegExp(r'^/users/\d+$').hasMatch(path)) {
    var id = int.parse(path.split('/').last);
    switch (method) {
      case 'GET':
        var rows = _query('select id, name from users where id = ?', [id]);
        if (rows.isEmpty) return _problem(404, 'no user $id');
        return _json({'user': rows.first});
      case 'PUT':
        _query('update users set name = ? where id = ?', ['renamed', id]);
        _audit.info('replaced user $id');
        return _json({
          'user': {'id': id, 'name': 'renamed'},
        });
      case 'PATCH':
        _query('update users set seen_at = ? where id = ?', ['now', id]);
        return _json({'patched': id});
      case 'DELETE':
        _query('delete from users where id = ?', [id]);
        _audit.warning('deleted user $id');
        // 204 has no body at all, which is its own case for the Response tab.
        return Response(204);
    }
  }

  switch (path) {
    case '/':
      return Response.ok('example server\n');
    case '/health':
      return Response.ok('ok\n');
    case '/users' when method == 'POST':
      _query('insert into users (name) values (?)', ['newcomer']);
      _audit.info('created a user');
      // 201 with a Location header, so the Response tab has a header worth
      // reading rather than three the framework set.
      return _json(
        {
          'user': {'id': 4, 'name': 'newcomer'},
        },
        status: 201,
        headers: {'location': '/users/4'},
      );
    case '/users':
      var users = _query('select id, name from users');
      // Deliberately N+1: one query per user, inside one request — the shape
      // the GUI's correlation view exists to make visible.
      for (var user in users) {
        _query('select count(*) from posts where user_id = ${user['id']}');
      }
      _log.info('listed ${users.length} users');
      return Response.ok('${users.map((u) => u['name']).join('\n')}\n');
    case '/slow':
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Parameterized, so the query detail pane has params to show.
      _query(
        'select * from posts where author = ? order by created_at '
        'desc limit ?',
        ['ada', 50],
      );
      _cache.info('warmed the slow path');
      return Response.ok('done being slow\n');
    case '/echo' when method == 'POST':
      // A request with a body, so the Request tab has one to show.
      var body = await request.readAsString();
      return Response.ok(
        body.toUpperCase(),
        headers: {'content-type': 'text/plain'},
      );
    case '/report':
      // A deep JSON response: the Response tab folds this into a `JsonView`
      // rather than printing it, which nothing else here reaches.
      _query(
        'select region, count(*) as n, sum(amount) as total from orders '
        'where created_at > ? group by region order by total desc',
        ['2026-08-01'],
      );
      return _json(_report);
    case '/report.xml':
      // Textual and captured, but not JSON — the plain-text branch.
      return Response.ok(
        _reportXml,
        headers: {'content-type': 'application/xml'},
      );
    case '/avatar.png':
      // Binary: the middleware declines to capture it, and the Response tab
      // says so rather than showing mojibake.
      return Response.ok(_pixel, headers: {'content-type': 'image/png'});
    case '/huge':
      // Textual but over the capture cap — the other "not captured" reason,
      // and a different sentence in the panel.
      return Response.ok(
        'x' * (48 * 1024),
        headers: {'content-type': 'text/plain'},
      );
    case '/cache':
      // A channel the GUI has never heard of. It has a fallback colour and a
      // fallback summary for exactly this, and nothing was exercising it.
      FlutterwareServer.event('cache', {
        'op': 'get',
        'key': 'users:all',
        'hit': true,
        'ms': 0.4,
      });
      return Response.ok('cached\n');
    case '/demo/seed':
      if (_seeding) return Response.ok('already seeding\n');
      // Fire-and-forget: the click that starts this should come back at once
      // and let the lists fill behind it, rather than reporting itself as the
      // longest request in the panel.
      unawaited(_seed());
      return Response.ok('seeding — watch the panel\n');
    // One route per status band, because a status column with only 200 and
    // 500 in it never shows the amber one.
    case '/unauthorized':
      _log.warning('rejected a request with no credentials');
      return _problem(401, 'who are you');
    case '/forbidden':
      return _problem(403, 'not yours');
    case '/bad-request':
      return _problem(400, 'that is not a number');
    case '/teapot':
      return _problem(418, 'short and stout');
    case '/rate-limited':
      _log.warning('rate limit hit');
      return _problem(429, 'slow down');
    case '/maintenance':
      _log.shout('serving maintenance page');
      return _problem(503, 'back shortly');
    case '/moved':
      return Response(302, headers: {'location': '/'});
    case '/error':
      _log.severe(
        'about to fail on purpose',
        StateError('deliberate failure for the errors view'),
      );
      throw StateError('deliberate failure for the errors view');
    default:
      return Response.notFound('nothing at ${request.url.path}\n');
  }
}

/// A JSON response, which is most of them.
Response _json(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => Response(
  status,
  body: const JsonEncoder.withIndent('  ').convert(body),
  headers: {'content-type': 'application/json', ...headers},
);

/// An error with a JSON body — what a real API returns, and what the Response
/// tab should be showing for a failure rather than an empty pane.
Response _problem(int status, String detail) =>
    _json({'status': status, 'detail': detail}, status: status);

/// A "database" with predictable latency, so timings in the GUI mean something.
final _database = _ToyDatabase();

class _ToyDatabase {
  final _users = [
    {'id': 1, 'name': 'ada'},
    {'id': 2, 'name': 'grace'},
    {'id': 3, 'name': 'edsger'},
  ];

  List<Map<String, Object?>> execute(String sql) {
    var until = DateTime.now().add(const Duration(milliseconds: 2));
    while (DateTime.now().isBefore(until)) {
      // Busy-wait: a sync "query" that visibly costs something.
    }
    if (sql.contains('from users')) return _users;
    return [
      {'count': sql.length},
    ];
  }
}

/// One of everything the panel draws, fired at this process by this process.
///
/// The point is not load. It is *coverage*: every method so the verb column
/// has each of its colours, every status band so the code column does, a slow
/// one and an N+1 one so the waterfall and its warning have subjects, bodies
/// that fold and bodies that cannot be captured, and headers worth reading —
/// including an `authorization`, which is the only way to see the middleware's
/// redaction actually happen.
///
/// Sequential rather than concurrent, and that is deliberate: the request list
/// is read as a timeline, and forty requests sharing a millisecond is a
/// timeline that says nothing. The whole run takes about a second.
Future<void> _seed() async {
  if (_base == null || _seeding) return;
  _seeding = true;
  // In a `finally`, so a throw anywhere below cannot leave the flag latched —
  // that would make `/demo/seed` permanently dead, which is a worse fault than
  // the overlapping runs it is here to prevent.
  try {
    await _seedRun();
  } finally {
    _seeding = false;
  }
}

/// The run itself. Split from [_seed] only so the in-flight flag has a
/// `finally` to be cleared in.
Future<void> _seedRun() async {
  var base = _base!;
  var client = HttpClient();
  _log.info('seeding the panel');

  Future<void> hit(
    String method,
    String path, {
    Object? body,
    bool auth = false,
  }) async {
    try {
      var request = await client.openUrl(method, Uri.parse('$base$path'));
      request.headers.set('user-agent', 'example-server-seed/1');
      request.headers.set('x-request-source', 'seed');
      // Redacted by `_redact` before it is reported — the panel should show
      // `<redacted>`, and it cannot show that for a header nobody sends.
      if (auth) request.headers.set('authorization', 'Bearer not-a-real-token');
      if (body != null) {
        // The length is set explicitly, and that is not tidiness: without it
        // `HttpClient` sends chunked, shelf reports `contentLength == null`,
        // and the middleware's capture cut declines a body it cannot size —
        // so the Request tab would say "not captured" for every seeded POST
        // and the one branch this is here to show would never be reached.
        var bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      var response = await request.close();
      await response.drain<void>();
    } on Object catch (e) {
      // A seeded request that fails is a data point, not a crash: `/error`
      // is *supposed* to 500, and the connection may drop under it.
      _log.fine('seed $method $path: $e');
    }
    // Enough to keep the timestamps distinct at millisecond resolution.
    await Future<void>.delayed(const Duration(milliseconds: 12));
  }

  // Levels, first and all at once, so the log filter has one of each to
  // narrow to before any request noise arrives.
  _log.finest('finest: the loop ran');
  _log.finer('finer: cache lookup');
  _log.fine('fine: resolved 3 users from the pool');
  _log.config('config: pool size 8, timeout 30s');
  _audit.info('info: seed run started');
  _cache.warning('warning: cache miss rate above 40%');
  _audit.severe(
    'severe: could not write the audit trail',
    const FileSystemException('read-only file system', '/var/log/audit'),
  );
  _log.shout('shout: this is the loudest level there is');

  for (var (method, path) in const [
    ('GET', '/'),
    ('GET', '/health'),
    ('GET', '/users'),
    ('GET', '/users/1'),
    ('GET', '/users/2'),
    ('GET', '/users/99'),
    ('GET', '/report'),
    ('GET', '/report.xml'),
    ('GET', '/avatar.png'),
    ('GET', '/huge'),
    ('GET', '/cache'),
    ('GET', '/slow'),
    ('GET', '/moved'),
    ('GET', '/bad-request'),
    ('GET', '/unauthorized'),
    ('GET', '/forbidden'),
    ('GET', '/teapot'),
    ('GET', '/rate-limited'),
    ('GET', '/maintenance'),
    ('GET', '/nowhere'),
    ('GET', '/error'),
    ('HEAD', '/health'),
    ('PUT', '/users/1'),
    ('PATCH', '/users/2'),
    ('DELETE', '/users/3'),
  ]) {
    await hit(method, path, auth: path.startsWith('/users'));
  }

  await hit('POST', '/users', body: {'name': 'newcomer'}, auth: true);
  await hit('POST', '/echo', body: {'hello': 'world', 'n': 3});

  // A second pass over the N+1 route, so its shape has a count worth reading
  // and the SQL aggregate is not a list of 1×.
  for (var i = 0; i < 3; i++) {
    await hit('GET', '/users');
  }

  client.close();
  _audit.info('seed run finished');
}

/// A response deep enough that the Response tab has something to fold.
const _report = {
  'generatedAt': '2026-08-24T12:00:00Z',
  'window': {'from': '2026-08-01', 'to': '2026-08-24'},
  'totals': {'orders': 1284, 'revenue': 91240.55, 'currency': 'EUR'},
  'regions': [
    {
      'region': 'eu-west',
      'orders': 702,
      'revenue': 51002.10,
      'top': [
        {'sku': 'kit-01', 'units': 210},
        {'sku': 'kit-02', 'units': 118},
      ],
    },
    {
      'region': 'us-east',
      'orders': 401,
      'revenue': 29988.45,
      'top': [
        {'sku': 'kit-01', 'units': 143},
      ],
    },
    {'region': 'ap-south', 'orders': 181, 'revenue': 10250.00, 'top': []},
  ],
  'warnings': ['3 orders had no region and were dropped'],
};

/// The same thing as XML — textual, captured, and not folded.
const _reportXml =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<report generatedAt="2026-08-24T12:00:00Z">\n'
    '  <totals orders="1284" revenue="91240.55" currency="EUR"/>\n'
    '  <region name="eu-west" orders="702"/>\n'
    '  <region name="us-east" orders="401"/>\n'
    '  <region name="ap-south" orders="181"/>\n'
    '</report>\n';

/// A 1×1 PNG. Small enough to inline, binary enough that the middleware
/// declines to capture it — which is the case being demonstrated.
final _pixel = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  ),
);
