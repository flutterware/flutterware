# Server inspection

Watch the requests your Dart server handles as they happen. Open one to see the
queries and outgoing calls it made on a waterfall, and the lines it logged. A
query that runs once per row is flagged as an N+1. The studio shows all this in
the **Server** panel, and the command line and agents read the same data.

![The Server panel: the demo's requests, one open on its waterfall, with the
query it runs once per row flagged as an N+1](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/server.webp)

This works only for servers written in Dart. A server takes part by importing
`package:flutterware/server.dart` and calling it from its own process. A
backend in another language, such as a .NET or Go API next to your Flutter
app, can't take part: there is no agent or log format to point at it, and none
is planned. In a repository with both, inspect the Dart services here and the
others with the tools you already use.

`package:flutterware/server.dart` has the building blocks only: `event`,
`span`/`spanSync`, `handle`, and correlation through zones. The code that
connects them to a framework or a database driver is a snippet on this page,
which you paste into your server and adapt. That keeps the package free of
dependencies, and keeps the redaction and capture rules in code you can read
and change.

[`fixtures/probe_app/bin/example_server.dart`](../fixtures/probe_app/bin/example_server.dart)
is a server you can run with the shelf and logging snippets in place.

Everything below does nothing in release builds (`dart compile`, `dart build`)
or on a machine without `~/.flutterware/run`. There is no init call: the
server announces itself with the first event it reports.

## Describe the server: `FlutterwareServer.info`

This part is an API rather than a snippet. It tells the studio where the server
listens, which environment it runs in, what it connects to, and which of its
pages are worth opening. The studio shows the environment and base URL beside
the panel's title and the rest under **Details** in the panel header, whichever
tab is open. An agent gets the same through the `info` action of
`flutterware_invoke`.

```dart
var server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 8080);

FlutterwareServer.info(ServerInfo(
  baseUrl: 'http://localhost:${server.port}',   // after serve: the real port
  environment: 'dev',
  links: [
    ServerLink('Health', '/health'),            // relative to baseUrl
    ServerLink('API docs', '/docs', description: 'OpenAPI UI'),
  ],
  connections: [
    ServerConnection('postgres', connectionString, label: 'main'),
  ],
  config: {
    'Feature flags': {'newCheckout': true},
  },
));
```

You can call it again at any time. Each call replaces only the sections it
names, so publishing `config:` again after a flag changes leaves the links as
they were. Passwords in a connection string and config keys that look like
secrets (`apiKey`, `token`, …) are masked wherever they are shown, and the
studio has a **Reveal** button for each. Still, publish only what you are happy
to have on a developer's screen.

`baseUrl` and `environment` are also saved where `fw status` and the studio's
sidebar can read them without connecting to the server, so they show
`pid 4242 · http://localhost:8080 · dev`. With a `baseUrl`, each request in the
studio also gets a **Copy as curl** button, built from the base URL and the
captured headers and body.

## HTTP in: shelf middleware

The middleware runs each request in a zone that carries the request's id. Every
query and log line reported inside that zone is tagged with the id, which is
how the studio builds the request's waterfall and spots an N+1.

```dart
import 'dart:async';
import 'package:flutterware/server.dart';
import 'package:shelf/shelf.dart';

Middleware inspect() {
  var nextRequestId = 1;
  return (inner) => (request) {
    var id = 'req-${nextRequestId++}';
    return runZoned(() async {
      var watch = Stopwatch()..start();
      try {
        var response = await inner(request);
        FlutterwareServer.event('http', {
          'method': request.method,
          'path': '/${request.url.path}',
          'status': response.statusCode,
          'ms': watch.elapsedMicroseconds / 1000,
        });
        return response;
      } on HijackException {
        // Shelf signals a hijack (a websocket upgrade, an SSE stream taking
        // the socket) by throwing past the middleware, and it means success.
        // Caught below as an error, every websocket connection would show up
        // as a 500.
        rethrow;
      } catch (e) {
        FlutterwareServer.event('http', {
          'method': request.method,
          'path': '/${request.url.path}',
          'status': 500,
          'ms': watch.elapsedMicroseconds / 1000,
          'error': '$e',
        });
        rethrow;
      }
    }, zoneValues: {
      FlutterwareServer.requestIdKey: id,
      // In a world, the tap that sent this request.
      FlutterwareServer.stepKey: ?request.headers['x-fw-step'],
    });
  };
}

// var handler = const Pipeline().addMiddleware(inspect()).addHandler(router);
```

When a world hosts the server, **Reload** hot-reloads it. A hot reload gives
every function its new code, but a closure made before the reload keeps its old
body, and a router's handlers are closures made when the router was built. So
rebuild the router after each reload with `FlutterwareServer.onReassemble`,
which the world calls once the new code is loaded. The state you build it from
stays as it is:

```dart
late App app;
await shelf_io.serve((request) => app.handler(request), 'localhost', 8080);
app = App(database);
FlutterwareServer.onReassemble(() {
  unawaited(app.dispose());
  app = App(database);
});
```

If the handler is all your server rebuilds, `FlutterwareServer.reloadable` is a
shorter way to write the same thing:

```dart
var handler = FlutterwareServer.reloadable(() => routes(store));
await shelf_io.serve(handler, 'localhost', 8080);

// A named function: a closure made before a reload keeps its old body.
Handler routes(Store store) => const Pipeline()
    .addMiddleware(inspect())
    .addHandler((Router()..get('/orders', store.list)).call);
```

Keep counters and caches in the state or in a top-level variable, outside what
is rebuilt: a rebuilt middleware starts from nothing. If your entry point has a
hot reload of its own, such as a file watcher that rebuilds the app, it can
pass the same callback to `onReassemble`.

The step (the tap a request came from) is known only inside the request's
zone. Work the request hands off, such as a job a worker runs later or a
storage callback, keeps the step only if you pass it along. Store
`FlutterwareServer.step` with the work. Run a job through
`FlutterwareServer.job(name, body, step:, id:)`, which also reports it as a
request of its own, with when it started and ended, and run anything else
under `FlutterwareServer.inStep(step, body)`. The [worlds
guide](worlds.md#see-what-a-tap-caused) has the pattern.

Nothing here reports a hijacked request: there is no response, and the socket
no longer belongs to the handler. To see that an upgrade happened, report an
`event` of your own before the hijack, while you are still in the request's
zone.

To fill the **Request** and **Response** tabs, copy the version in
`example_server.dart` instead. It adds the request and response headers,
redacted, and small text bodies to the event's `details:`. The studio fetches
them only when you open the tab, but your server builds and JSON-encodes them
on every request and keeps them in a store with a byte limit, so every request
pays for the capture. To keep that cost small, a body is captured only when its
content type is text and its length is known and under 32 KB. For streams and
everything else, only the size is recorded. The library redacts nothing; the
snippet does, in code you own.

## Logs: package:logging

The listener runs in the zone that called `listen`, so report each record from
`record.zone`, the zone the log call was made in. Otherwise log lines lose
their request id.

```dart
Logger.root.onRecord.listen((record) {
  (record.zone ?? Zone.current).run(() {
    FlutterwareServer.event('log', {
      'level': record.level.name,
      'logger': record.loggerName,
      'message': record.message,
      if (record.error != null) 'error': '${record.error}',
    });
  });
});
```

## Uncaught errors, outside any request

The middleware already reports a handler that throws. For errors anywhere else,
such as timers, queue consumers and futures nobody awaits, wrap the body of
`main`:

```dart
Future<void> main() async {
  await runZonedGuarded(() async {
    // ... start the server ...
  }, (error, stackTrace) {
    FlutterwareServer.event('log', {
      'level': 'SEVERE',
      'message': 'uncaught: $error',
      'error': '$stackTrace',
    });
  });
}
```

### What counts as an error

The `errors` action reports three kinds of event, and only the first is about
the response:

- an `http` event whose `status` is **500 or more**;
- a `log` event at **`SEVERE`** or **`SHOUT`**;
- **any event carrying an `error` key**, on any channel.

So what it reports depends on how your project logs as well as on what it
answered. A 403 whose handler logs with `error:` attached shows up, through the
third rule. A 4xx whose handler logs at `INFO` with no error attached doesn't
show up at all, although the request failed. Most 404s are ordinary traffic,
and only your code knows which of its 4xx answers are faults: attach `error:`
to the log line for those.

To ask about the status alone, pass `minStatus` to `errors`. It replaces the
three rules with that one comparison, so `minStatus: 400` returns every request
that failed, whatever was logged.

In the studio, the **Errors** filter of the request list shows every request
that answered 400 or more, or that carries an `error`.

## SQL: drift

Drift's `QueryInterceptor` sees every statement. The `explain` and `requery`
handlers run inside your server, on your own connection, so the studio needs no
driver and no credentials to show a real query plan.

Report the statement as the driver received it, with its parameters beside it.
Don't substitute the values into the text: the **SQL** tab groups queries by
their shape, and an N+1 is a set of queries that differ only in their values.
The placeholders (`$1`, `@name`, `?`) stay in the text, so the text alone will
not run, and `EXPLAIN` on it fails. That is why `explain` and `requery` receive
`params` as well as `query`: the parameters of the occurrence you picked, as
your `span` reported them. Every handler below binds them instead of pasting
them into the SQL. A statement that took no parameters arrives without
`params`.

Report the parameters in the shape your driver binds: a list for positional
placeholders, a **map for named ones**. `parameters.values.toList()` on a named
query loses the names, and the handler needs them to bind the values again.

```dart
import 'package:drift/drift.dart';
import 'package:flutterware/server.dart';

class InspectingInterceptor extends QueryInterceptor {
  @override
  Future<T> _run<T>(String sql, List<Object?> args, Future<T> Function() body) {
    return FlutterwareServer.span('sql', {
      'query': sql,
      if (args.isNotEmpty) 'params': args,
    }, body);
    // For selects, report the row count too; the SQL tab shows it on each
    // occurrence. Run the body yourself, then
    // FlutterwareServer.event('sql', {..., 'rows': result.length, 'ms': …}).
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(statement, args, () => executor.runSelect(statement, args));

  // Override runInsert / runUpdate / runDelete / runCustom the same way.
}

// db = MyDatabase(executor.interceptWith(InspectingInterceptor()));

void registerSqlCommands(MyDatabase db) {
  FlutterwareServer.handle('sql', 'explain', (params) async {
    var rows = await db
        .customSelect(
          'EXPLAIN QUERY PLAN ${params['query']}',
          variables: _bind(params['params']),
        )
        .get();
    return {'plan': [for (var row in rows) row.data]};
  });
  FlutterwareServer.handle('sql', 'requery', (params) async {
    var rows = await db
        .customSelect(
          params['query']! as String,
          variables: _bind(params['params']),
        )
        .get();
    return {'rows': [for (var row in rows.take(50)) row.data]};
  });
}

/// The reported parameters, back as drift variables. They arrive as JSON, so a
/// `DateTime` is the string that was reported: good enough for a plan, and one
/// more reason to keep `requery` to dev databases.
List<Variable> _bind(Object? reported) => [
  for (var value in reported as List? ?? const []) Variable(value),
];
```

## SQL: package:postgres

```dart
import 'package:flutterware/server.dart';
import 'package:postgres/postgres.dart';

Future<Result> query(
  Connection connection,
  String sql, {
  Map<String, Object?>? parameters,
}) {
  return FlutterwareServer.span('sql', {
    'query': sql,
    // The map itself: this query uses named parameters, and a list of the
    // values could not be bound back.
    if (parameters != null) 'params': parameters,
  }, () => connection.execute(Sql.named(sql), parameters: parameters));
}

void registerSqlCommands(Connection connection) {
  FlutterwareServer.handle('sql', 'explain', (params) async {
    var rows = await connection.execute(
      Sql.named('EXPLAIN ANALYZE ${params['query']}'),
      parameters: (params['params'] as Map?)?.cast<String, Object?>(),
    );
    return {'plan': [for (var row in rows) row.first]};
  });
  FlutterwareServer.handle('sql', 'requery', (params) async {
    var rows = await connection.execute(
      Sql.named(params['query']! as String),
      parameters: (params['params'] as Map?)?.cast<String, Object?>(),
    );
    return {'rows': [for (var row in rows.take(50)) row.toColumnMap()]};
  });
}
```

`EXPLAIN ANALYZE` **executes** the query. For statements with side effects,
or on data you care about, use plain `EXPLAIN` instead.

## SQL: package:sqlite3

```dart
import 'package:flutterware/server.dart';
import 'package:sqlite3/sqlite3.dart';

ResultSet query(Database db, String sql, [List<Object?> params = const []]) {
  return FlutterwareServer.spanSync('sql', {
    'query': sql,
    if (params.isNotEmpty) 'params': params,
  }, () => db.select(sql, params));
}

void registerSqlCommands(Database db) {
  FlutterwareServer.handle('sql', 'explain', (params) {
    var rows = db.select(
      'EXPLAIN QUERY PLAN ${params['query']}',
      _bind(params['params']),
    );
    return {'plan': [for (var row in rows) row['detail']]};
  });
  FlutterwareServer.handle('sql', 'requery', (params) {
    var rows = db.select(params['query']! as String, _bind(params['params']));
    return {'rows': rows.take(50).toList()};
  });
}

List<Object?> _bind(Object? reported) => [...?reported as List?];
```

## HTTP out: package:http

Report the calls your handlers make to other services, and they appear on the
same waterfall as the request's queries:

```dart
import 'package:http/http.dart' as http;
import 'package:flutterware/server.dart';

class InspectingClient extends http.BaseClient {
  InspectingClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return FlutterwareServer.span('http-out', {
      'method': request.method,
      'url': '${request.url}',
    }, () => _inner.send(request));
  }
}
```

## Notes that apply to every snippet

- **Redaction is up to you.** Before you report headers or parameters, drop
  anything that must not leave the process. That is why the snippets above
  report no headers; add them knowing what they carry.

  Build the list of headers to redact by searching your handlers for the
  headers they read. `Authorization`, `Cookie` and password fields are a
  start, but a server that accepts `x-authorization` as a fallback for
  `authorization` has a credential no generic list would name. The same search
  shows what to keep: an `x-publishable-key` is not a secret, and it tells you
  which client sent a request. Redact what your code treats as a secret, and
  keep what it uses to identify the caller.
- **`requery` runs the statement again.** That is handy on a local dev
  database; think twice before registering it against a shared one.
- What a handler returns must be JSON-encodable. Cap the rows it returns
  (`take(50)` above) so a big table doesn't flood the answer.
