import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware/server.dart';
import 'package:meta/meta.dart';

import '../../session/job.dart';
import '../../utils/run_dir.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'server_address.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const serverPluginId = 'flutterware.server';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'The dev servers announcing themselves under this worktree, with the '
    'requests, errors and SQL each one has seen.';

/// The servers currently announcing themselves under this worktree.
///
/// Discovery is a run-dir scan for `srv-*.json` handles whose project root
/// sits inside the worktree — file reads, nothing else, so it fits
/// [computeAll]'s budget and `fw status` can call it freely. *Attaching* —
/// opening the socket, replaying the ring — happens on subscription
/// ([track], called when the panel mounts) or inside an action, per the
/// no-sockets rule in [PluginCore.computeAll].
class ServerCore extends PluginCore {
  ServerCore(super.host, {ServerSource? source})
    : source = source ?? const LiveServerSource();

  /// Where handles and attachments come from: the run dir and a unix socket,
  /// or a recording. Everything above it reads a [TrackedServer] and cannot
  /// tell which.
  final ServerSource source;

  /// Where discovery looks. A seam for tests, which point it at a temp dir
  /// instead of the developer's real run dir.
  @visibleForTesting
  static String Function() runDirProvider = flutterwareRunDir;

  final _servers = <String, TrackedServer>{};
  var _scanned = false;
  var _tracking = false;
  StreamSubscription<void>? _dirWatch;
  Timer? _rescanDebounce;

  /// Servers, newest first — what the panel draws.
  List<TrackedServer> get servers =>
      _servers.values.toList()
        ..sort((a, b) => b.handle.startedAt.compareTo(a.handle.startedAt));

  /// Where one server's overview is — the same segments the panel reads back.
  ///
  /// A server is named rather than pid-qualified, for the reason
  /// `server_address.dart` gives: an address a person pastes tomorrow should
  /// survive tonight's restart.
  Address addressFor(String server) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: serverSegments(server),
  );

  @override
  Future<void> computeAll() async {
    _scan();
  }

  /// Starts live tracking: attach to every announced server, watch the run
  /// dir for handles appearing and disappearing. Idempotent; called by the
  /// panel on mount.
  void track() {
    if (_tracking || isDisposed) return;
    _tracking = true;
    _scan();
    _dirWatch = source.watch()?.listen((_) {
      // Coalesce bursts: a restart is a delete + two creates.
      _rescanDebounce?.cancel();
      _rescanDebounce = Timer(const Duration(milliseconds: 100), _scan);
    });
  }

  void _scan() => unawaited(_scanAsync());

  Future<void> _scanAsync() async {
    if (isDisposed) return;
    var handles = await source.scan(underRoot: host.worktree.path);
    if (isDisposed) return;
    _scanned = true;
    var seen = <String>{};
    for (var handle in handles) {
      var key = '${handle.name}-${handle.pid}';
      seen.add(key);
      var tracked = _servers.putIfAbsent(key, () => TrackedServer(handle));
      // Same process, fresher file: the inspector rewrites its handle when
      // the server publishes a base URL, and the row should say so.
      tracked.handle = handle;
      if (_tracking) _attach(tracked);
    }
    // A vanished handle is a stopped server: keep it on screen, greyed out,
    // only if we were attached and hold its history; drop it otherwise.
    _servers.removeWhere(
      (key, tracked) => !seen.contains(key) && tracked.events.isEmpty,
    );
    for (var entry in _servers.entries) {
      if (!seen.contains(entry.key)) entry.value.markStopped();
    }
    notifyChanged();
  }

  void _attach(TrackedServer tracked) {
    if (tracked.connected || tracked.stopped || tracked.attaching) return;
    tracked.attaching = true;
    unawaited(() async {
      var handleDeleted = false;
      var client = await source.attach(
        tracked.handle,
        onFailure: (_, {required bool deleted}) => handleDeleted = deleted,
      );
      tracked.attaching = false;
      if (isDisposed) {
        await client?.close();
        return;
      }
      if (client == null) {
        if (handleDeleted) {
          // Dead handle — attachToServer deleted it; reflect that.
          tracked.markStopped();
        } else {
          // Alive but slow — a busy server that missed the handshake window.
          // Marking it stopped here would be permanent (`_attach` never
          // retries a stopped row); leaving it disconnected lets the next
          // scan try again.
          _scheduleRescan();
        }
        notifyChanged();
        return;
      }
      tracked.adopt(client, onEvent: notifyChanged);
      unawaited(
        client.done.then((_) {
          if (isDisposed || tracked.client != client) return;
          // A drop, not a death: the handle decides which on the next scan —
          // still there means reattach (decision 10), and the re-replay
          // dedupes against what this core already holds. Gone means the
          // scan marks it stopped.
          tracked.dropConnection();
          notifyChanged();
          _scheduleRescan();
        }),
      );
      notifyChanged();
    }());
  }

  void _scheduleRescan() {
    if (!_tracking || isDisposed) return;
    _rescanDebounce?.cancel();
    _rescanDebounce = Timer(const Duration(seconds: 1), _scan);
  }

  @override
  PluginReport get report {
    var servers = this.servers;
    var live = servers.where((s) => !s.stopped).length;
    // Nothing running is the resting state, not news — the row only speaks
    // when servers are actually up.
    var status = !_scanned || live == 0
        ? Status.none
        : Status.good('$live running');
    return PluginReport(
      id: host.id,
      label: host.label,
      description: _pluginDescription,
      status: status,
      badge: live > 0
          ? StatusBadge.count(live, tone: Tone.good)
          : StatusBadge.none,
      children: [
        for (var server in servers)
          PluginChild(
            id: server.handle.name,
            label: server.handle.name,
            status: server.stopped
                ? Status.neutral('stopped')
                : Status.good(_where(server)),
          ),
      ],
      actions: [
        PluginAction(
          'requests',
          'Recent requests',
          description:
              'The latest HTTP requests a running server reported, each with '
              'the SQL queries and log lines it caused. Narrow with path, '
              'minStatus and since rather than reading everything and '
              'filtering — a server up for an hour holds far more than the '
              'question usually wants.',
          parameters: [
            _serverParameter,
            _lastParameter,
            ActionParameter(
              'path',
              'Path contains',
              required: false,
              description:
                  'Only requests whose path contains this — "/api/cases". '
                  'Matched case-insensitively on the path alone, without the '
                  'query string.',
            ),
            _minStatusParameter,
            _sinceParameter,
            _detailsParameter,
          ],
        ),
        PluginAction(
          'errors',
          'Recent errors',
          description:
              'Failed requests (5xx or thrown), severe log lines, and any '
              'event carrying an error — each with the request it happened '
              'under. What counts as an error is deliberately broader than '
              'the status: pass minStatus to ask the status question alone.',
          parameters: [
            _serverParameter,
            _lastParameter,
            _minStatusParameter,
            _sinceParameter,
            _detailsParameter,
          ],
        ),
        PluginAction(
          'info',
          'Server info',
          description:
              'What a running server published about itself: base URL, '
              'environment, pages worth opening, connections (passwords '
              'masked) and config groups.',
          parameters: [_serverParameter],
        ),
        PluginAction(
          'sql',
          'Query statistics',
          description:
              'Every recorded query grouped by its normalized shape — count, '
              'total, average and max duration — heaviest first. The same '
              'aggregation the SQL panel shows.',
          parameters: [
            _serverParameter,
            ActionParameter(
              'top',
              'Shapes',
              kind: ActionParameterKind.integer,
              required: false,
              defaultValue: '20',
            ),
          ],
        ),
      ],
      view: PluginView([
        if (!_scanned)
          ViewText('Not scanned yet.')
        else if (servers.isEmpty)
          ViewText(
            'No servers are announcing themselves under this worktree.\n'
            'Report from one with package:flutterware/server.dart.',
          )
        else
          ViewItems([
            for (var server in servers)
              ViewItem(
                server.handle.name,
                // The overview the panel already reads back — see
                // `server_address.dart`. Without it a row names a server the
                // shell can open and the palette cannot reach, which is the
                // one gap `searchReport` cannot close on a plugin's behalf.
                address: addressFor(server.handle.name),
                detail: switch (server) {
                  _ when server.stopped => 'stopped',
                  _ when server.connected =>
                    '${_where(server)}, ${server.events.length} events',
                  _ when server.wasConnected =>
                    '${_where(server)}, reconnecting',
                  // The event count is only honest once attached — `fw`
                  // reads this without ever opening the socket.
                  _ => _where(server),
                },
              ),
          ]),
      ]),
    );
  }

  /// `pid 4242 · http://localhost:8080 · dev`, from the scan-only mirror —
  /// what both the child rows and the view items say about a live server.
  static String _where(TrackedServer server) => [
    'pid ${server.handle.pid}',
    ?server.handle.baseUrl,
    ?server.handle.environment,
  ].join(' · ');

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    var name = arguments['name'] as String?;
    var last = _intArgument(arguments['last'], 20);
    var minStatus = _intArgument(arguments['minStatus'], null);
    var since = _sinceArgument(arguments['since']);
    var details = arguments['details'] == true;
    return switch (actionId) {
      'requests' => _collect(name, (client) async {
        var matched = [
          for (var event in client.received)
            if (event.channel == 'http' &&
                _within(event, since) &&
                _pathMatches(event, arguments['path'] as String?) &&
                _atLeast(event, minStatus))
              event,
        ];
        return _page(
          client,
          matched,
          last: last,
          details: details,
          key: 'requests',
          shape: (kept) => _shapeRequests(kept, client.received),
        );
      }),
      'errors' => _collect(name, (client) async {
        var matched = [
          for (var event in client.received)
            if (_within(event, since) &&
                (minStatus == null
                    ? _isError(event)
                    : _atLeast(event, minStatus)))
              event,
        ];
        return _page(
          client,
          matched,
          last: last,
          details: details,
          key: 'errors',
          shape: (kept) => _shapeErrors(kept, client.received),
        );
      }),
      'sql' => _collect(name, (client) async {
        return {
          'queries': _shapeSqlStats(
            client.received,
            _intArgument(arguments['top'], 20)!,
          ),
        };
      }),
      'info' => _collect(name, (client) async {
        return {'info': _shapeInfo(ServerInfo.fromEvents(client.received))};
      }),
      _ => super.invoke(actionId),
    };
  }

  /// The newest [last] of [matched], shaped, and — when asked — each with its
  /// captured headers and bodies hung off it.
  ///
  /// The details budget is here rather than in a smaller default `last`.
  /// One captured body can be 32 KB and most are a few hundred bytes, so a
  /// count cannot bound the answer, and a count small enough to try would make
  /// the common case useless. Newest first until the budget is gone, and then
  /// the reply says how many went without: an unreported truncation reads as
  /// "there was nothing there".
  static Future<Map<String, Object?>> _page(
    ServerAttachment client,
    List<ServerEvent> matched, {
    required int? last,
    required bool details,
    required String key,
    required List<Map<String, Object?>> Function(List<ServerEvent> kept) shape,
  }) async {
    // Newest first from here down, so a row and the event it came from share
    // an index and the budget spends on the newest.
    var kept =
        (last != null && matched.length > last
                ? matched.sublist(matched.length - last)
                : matched)
            .reversed
            .toList();
    var rows = shape(kept);
    var withheld = 0;
    if (details) {
      var budget = _detailsByteBudget;
      for (var i = 0; i < rows.length; i++) {
        var fetched = budget <= 0 ? null : await client.details(kept[i].id);
        if (fetched == null) {
          // Never captured, evicted, or past the budget — and only the last
          // is something the caller can do anything about.
          if (budget <= 0) withheld++;
          continue;
        }
        var encoded = jsonEncode(fetched);
        // The first row is allowed to overrun: an answer that spends its whole
        // budget on the one request asked about is the answer that was wanted.
        if (encoded.length > budget && i > 0) {
          withheld++;
          continue;
        }
        budget -= encoded.length;
        rows[i]['details'] = fetched;
      }
    }
    return {
      key: rows,
      if (matched.length > kept.length) 'more': matched.length - kept.length,
      if (withheld > 0)
        'note':
            '$withheld of these have details that did not fit one reply. Ask '
            'again for fewer — a narrower path, a higher minStatus, a shorter '
            'since, or a smaller last.',
    };
  }

  /// What one reply will spend on captured headers and bodies.
  static const _detailsByteBudget = 48 * 1024;

  /// One ephemeral attachment per matching server: replay the ring, let
  /// [shape] reduce it, leave. What all three read actions share.
  Future<Object?> _collect(
    String? name,
    Future<Map<String, Object?>> Function(ServerAttachment client) shape,
  ) async {
    var handles = await source.scan(underRoot: host.worktree.path);
    if (name != null) {
      handles = [
        for (var handle in handles)
          if (handle.name == name) handle,
      ];
    }
    if (handles.isEmpty) {
      return {
        'servers': <Object>[],
        'note': name == null
            ? 'No servers are announcing themselves under this worktree.'
            : 'No server named "$name" is announcing itself.',
      };
    }

    var out = <Map<String, Object?>>[];
    // A skipped server must say why it is missing from the answer. Without
    // this, "every attach failed" and "no traffic yet" were the same empty
    // list — an agent reading it debugged the wrong thing.
    var failures = <String>[];
    for (var handle in handles) {
      var client = await source.attach(
        handle,
        onFailure: (error, {required bool deleted}) {
          failures.add(
            deleted
                ? '"${handle.name}" (pid ${handle.pid}) is gone; its stale '
                      'handle was removed.'
                : '"${handle.name}" (pid ${handle.pid}) did not answer the '
                      'attach in time: $error. It is still listed — retry.',
          );
        },
      );
      if (client == null) continue;
      try {
        await _replayed(client);
        out.add({
          'name': handle.name,
          'pid': handle.pid,
          ...await shape(client),
        });
      } finally {
        await client.close();
      }
    }
    return {
      'servers': out,
      if (failures.isNotEmpty) 'note': failures.join(' '),
    };
  }

  static int? _intArgument(Object? value, [int? fallback]) => switch (value) {
    int n => n,
    String s => int.tryParse(s) ?? fallback,
    _ => fallback,
  };

  /// `30s`, `10m`, `2h`, `1d`, or an ISO-8601 instant, as the moment to count
  /// from. Null for an absent argument.
  ///
  /// Anything else is refused. A `since` that silently did nothing would
  /// hand back the whole ring wearing the shape of a filtered answer, which is
  /// the same failure the undeclared-parameter refusal exists for.
  static DateTime? _sinceArgument(Object? value) {
    if (value == null) return null;
    var text = '$value'.trim();
    if (text.isEmpty) return null;
    var relative = RegExp(r'^(\d+)\s*([smhd])$').firstMatch(text);
    if (relative != null) {
      var n = int.parse(relative.group(1)!);
      return DateTime.now().subtract(switch (relative.group(2)!) {
        's' => Duration(seconds: n),
        'm' => Duration(minutes: n),
        'h' => Duration(hours: n),
        _ => Duration(days: n),
      });
    }
    var instant = DateTime.tryParse(text);
    if (instant != null) return instant;
    throw ArgumentError.value(
      value,
      'since',
      'must be a duration back from now — "30s", "10m", "2h", "1d" — or an '
          'ISO-8601 instant like "2026-08-17T09:00:00Z"',
    );
  }

  static bool _within(ServerEvent event, DateTime? since) =>
      since == null || !event.time.isBefore(since);

  /// The path alone, case-insensitively. The query string is excluded because
  /// `?` and `&` in an argument are a shell's problem, and a path is what the
  /// panel and the timeline both name a request by.
  static bool _pathMatches(ServerEvent event, String? needle) {
    if (needle == null || needle.isEmpty) return true;
    var path = event.payload['path'];
    if (path is! String) return false;
    var withoutQuery = path.split('?').first;
    return withoutQuery.toLowerCase().contains(needle.toLowerCase());
  }

  static bool _atLeast(ServerEvent event, int? minStatus) {
    if (minStatus == null) return true;
    return switch (event.payload['status']) {
      int status => status >= minStatus,
      _ => false,
    };
  }

  static Future<void> _replayed(ServerAttachment client) async {
    var deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!client.replayComplete && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// One entry per request in [requests], with everything sharing its
  /// correlation id nested under it — the agent-readable waterfall.
  ///
  /// [all] is the whole attachment, because the events a request caused are
  /// found by correlation and survive any filter applied to the requests.
  static List<Map<String, Object?>> _shapeRequests(
    List<ServerEvent> requests,
    List<ServerEvent> all,
  ) {
    var byRid = <String, List<ServerEvent>>{};
    for (var event in all) {
      if (event.rid != null && event.channel != 'http') {
        byRid.putIfAbsent(event.rid!, () => []).add(event);
      }
    }
    return [
      for (var request in requests)
        {
          // The handle a follow-up names. Absent before, which left `details`
          // reachable only by asking for the same page again.
          'id': request.id,
          'time': request.time.toIso8601String(),
          ...request.payload,
          if (request.rid != null && byRid[request.rid] != null)
            'caused': [
              for (var event in byRid[request.rid]!)
                {'channel': event.channel, ...event.payload},
            ],
        },
    ];
  }

  /// Everything in [errors], with the request it happened under, because
  /// "what broke" is only half the question. [all] is the whole attachment,
  /// which is where the causing request is looked up.
  static List<Map<String, Object?>> _shapeErrors(
    List<ServerEvent> errors,
    List<ServerEvent> all,
  ) {
    var requestsByRid = <String, ServerEvent>{};
    for (var event in all) {
      if (event.channel == 'http' && event.rid != null) {
        requestsByRid[event.rid!] = event;
      }
    }
    return [
      for (var event in errors)
        {
          'id': event.id,
          'time': event.time.toIso8601String(),
          'channel': event.channel,
          ...event.payload,
          if (event.channel != 'http' &&
              event.rid != null &&
              requestsByRid[event.rid] != null)
            'request': {
              'method': requestsByRid[event.rid]!.payload['method'],
              'path': requestsByRid[event.rid]!.payload['path'],
              'status': requestsByRid[event.rid]!.payload['status'],
            },
        },
    ];
  }

  static bool _isError(ServerEvent event) {
    if (event.payload['error'] != null) return true;
    if (event.channel == 'http') {
      return switch (event.payload['status']) {
        int status => status >= 500,
        _ => false,
      };
    }
    if (event.channel == 'log') {
      return const {'SEVERE', 'SHOUT'}.contains(event.payload['level']);
    }
    return false;
  }

  /// The published self-description, for eyes that are not the panel's: links
  /// resolved to absolute URLs where possible, DSN passwords and secret-like
  /// config values masked — action output ends up in terminals and agent
  /// transcripts, where there is no reveal click.
  static Map<String, Object?> _shapeInfo(ServerInfo info) {
    if (info.isEmpty) {
      return {
        'note':
            'Nothing published. The server can describe itself with '
            'FlutterwareServer.info (package:flutterware/server.dart).',
      };
    }
    return {
      if (info.baseUrl != null) 'baseUrl': info.baseUrl,
      if (info.environment != null) 'environment': info.environment,
      if (info.links != null)
        'links': [
          for (var link in info.links!)
            {
              'label': link.label,
              'url':
                  resolveLinkUrl(link.url, baseUrl: info.baseUrl) ?? link.url,
              'description': ?link.description,
            },
        ],
      if (info.connections != null)
        'connections': [
          for (var connection in info.connections!)
            {
              'kind': connection.kind,
              'label': ?connection.label,
              'dsn': maskDsn(connection.dsn),
            },
        ],
      if (info.config != null)
        'config': {
          for (var group in info.config!.entries)
            group.key: {
              for (var entry in group.value.entries)
                entry.key: isSecretLikeKey(entry.key) ? '••••' : entry.value,
            },
        },
    };
  }

  /// [sqlStats], flattened for the wire — same aggregation the panel shows.
  static List<Map<String, Object?>> _shapeSqlStats(
    List<ServerEvent> events,
    int top,
  ) => [
    for (var shape in sqlStats(events).take(top))
      {
        'query': shape.normalized,
        'count': shape.count,
        'totalMs': double.parse(shape.totalMs.toStringAsFixed(1)),
        'avgMs': double.parse(shape.averageMs.toStringAsFixed(1)),
        'maxMs': double.parse(shape.maxMs.toStringAsFixed(1)),
      },
  ];

  @override
  void dispose() {
    _rescanDebounce?.cancel();
    unawaited(_dirWatch?.cancel());
    for (var tracked in _servers.values) {
      tracked.dispose();
    }
    super.dispose();
  }
}

/// One announced server: its handle, the live attachment when tracking, and
/// the events seen so far — which outlive both the connection and the
/// server, so a drop or a crash never loses history mid-investigation.
class TrackedServer {
  TrackedServer(this.handle);

  /// Refreshed on every scan — the same process rewrites its handle file
  /// when it learns its base URL, and the identity key (`name-pid`) is
  /// what stays fixed.
  ServerHandle handle;
  ServerAttachment? client;
  StreamSubscription<ServerEvent>? _eventSubscription;
  var attaching = false;
  var stopped = false;

  /// Distinguishes "dropped, reattaching" from "never attached" — `fw`, which
  /// only scans, must not report a server it never touched as reconnecting.
  var wasConnected = false;

  bool get connected => client != null;

  /// This core's own copy, merged across attachments and deduped by event id
  /// (monotonic per server process — decision 10). A reattach replays the
  /// whole ring; everything already here collapses to a no-op.
  List<ServerEvent> get events => List.unmodifiable(_events);
  final _events = <ServerEvent>[];
  var _lastEventId = 0;

  /// The latest self-description this server published — computed from the
  /// events like [sqlStats], so it survives drops and restarts with them.
  ServerInfo get info => ServerInfo.fromEvents(_events);

  /// Takes ownership of a fresh attachment. Subscribes before draining
  /// [ServerAttachment.received] so nothing can slip between the two; the
  /// id check makes the overlap harmless.
  void adopt(ServerAttachment attached, {required void Function() onEvent}) {
    client = attached;
    wasConnected = true;
    _eventSubscription = attached.events.listen((event) {
      _absorb(event);
      onEvent();
    });
    for (var event in attached.received) {
      _absorb(event);
    }
  }

  void _absorb(ServerEvent event) {
    if (event.id <= _lastEventId) return;
    _lastEventId = event.id;
    _events.add(event);
  }

  /// One event's lazy details — headers, bodies — fetched once and kept.
  ///
  /// Null means the server never captured them, evicted them, or is gone;
  /// the panel words those the same way ("not captured"), because the
  /// difference is not actionable from here. Cached including the nulls: a
  /// detail that was evicted once will not un-evict.
  Future<Map<String, Object?>?> detailsFor(ServerEvent event) {
    return _detailsCache.putIfAbsent(event.id, () async {
      var client = this.client;
      if (client == null) return null;
      try {
        return await client.details(event.id);
      } on Object {
        return null;
      }
    });
  }

  final _detailsCache = <int, Future<Map<String, Object?>?>>{};

  /// The connection is gone; the server may not be. Keeps the history and
  /// [wasConnected], so the next scan can reattach or conclude "stopped".
  void dropConnection() {
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    var dropped = client;
    client = null;
    if (dropped != null) unawaited(dropped.close());
  }

  void markStopped() {
    stopped = true;
    dropConnection();
  }

  void dispose() => markStopped();
}

/// The absolute URL [request] was made to, or null when the server never
/// published a base to resolve its path against.
///
/// The derivation [curlCommand] was doing inline. Split out because the panel
/// wants the URL on its own — a path pasted into a browser is the other thing
/// people do with a request row — and two copies of "which URL was this" is
/// one too many.
String? requestUrl(ServerInfo info, ServerEvent request) {
  var path = request.payload['path'];
  if (path is! String || info.baseUrl == null) return null;
  return resolveLinkUrl(path, baseUrl: info.baseUrl);
}

/// A curl invocation reproducing [request], or null when one cannot be built
/// — no published `baseUrl` to make the URL absolute, or no recorded path.
///
/// Headers and body come from the event's lazy details when captured. `host`
/// and `content-length` are dropped because curl derives them; values the
/// middleware redacted come through as `<redacted>` — a placeholder the user
/// edits, deliberately visible rather than silently missing.
String? curlCommand(
  ServerInfo info,
  ServerEvent request, {
  Map<String, Object?>? details,
}) {
  var url = requestUrl(info, request);
  if (url == null) return null;
  var method = request.payload['method'];
  var methodFlag = method is String && method != 'GET' ? ' -X $method' : '';
  var lines = ['curl$methodFlag ${_shellQuote(url)}'];
  var headers = details?['requestHeaders'];
  if (headers is Map) {
    for (var entry in headers.entries) {
      var name = '${entry.key}'.toLowerCase();
      if (name == 'host' || name == 'content-length') continue;
      lines.add('-H ${_shellQuote('${entry.key}: ${entry.value}')}');
    }
  }
  var body = details?['requestBody'];
  if (body is String && body.isNotEmpty) {
    lines.add('--data-raw ${_shellQuote(body)}');
  }
  return lines.join(' \\\n  ');
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Sends a `sql` command — `explain`, `requery` — into a live server, which
/// runs it on its own connection and answers. Throws [ActionRefusal] when not
/// attached and [ServerRequestException] when the server has no such handler
/// or the handler failed; the panel shows both as text, not as crashes.
///
/// Takes the occurrence, not the query text, because the text alone does not
/// run. A bound statement is reported as the driver received it — `$1`,
/// `@name`, `?` still in place — and that is deliberate: [normalizeSql] groups
/// by shape, and an N+1 is precisely a set of queries differing only in their
/// literals. But `EXPLAIN` on such a text fails, because a parameter has no
/// meaning outside a prepared statement. So the occurrence's own `params` ride
/// along and the handler binds them, which is also the only spelling of this
/// that does not ask a project to interpolate values into SQL.
Future<Map<String, Object?>> sqlCommand(
  TrackedServer server,
  String method,
  ServerEvent occurrence,
) {
  var client = server.client;
  if (client == null) {
    throw ActionRefusal('Not attached to ${server.handle.name}.');
  }
  return client.request('sql', method, {
    'query': occurrence.payload['query'],
    // Absent rather than empty when the statement took none: a handler reads
    // `params['params'] ?? const []` and an absent key is the simpler read.
    if (occurrence.payload['params'] != null)
      'params': occurrence.payload['params'],
  });
}

/// One normalized query shape, aggregated across everything a server
/// reported — the row of the SQL view.
class QueryStats {
  QueryStats(this.normalized) : key = queryShapeKey(normalized);

  final String normalized;

  /// The address segment naming this shape — see `server_address.dart`.
  final String key;

  final occurrences = <ServerEvent>[];
  var totalMs = 0.0;
  var maxMs = 0.0;

  int get count => occurrences.length;
  double get averageMs => count == 0 ? 0 : totalMs / count;

  /// The most recent raw occurrence — what explain and requery act on: a
  /// real query the database has actually seen, not the `?`-shape.
  ServerEvent get latest => occurrences.last;
}

/// The stable identity of a normalized shape, short enough for a segment.
String queryShapeKey(String normalized) =>
    sha1.convert(utf8.encode(normalized)).toString().substring(0, 8);

/// Every `sql` event grouped by shape, heaviest total time first — the whole
/// SQL view, computed rather than stored, so it is always the events' truth.
/// On the core side so the panel and whatever `fw` reports later agree.
List<QueryStats> sqlStats(Iterable<ServerEvent> events) {
  var byShape = <String, QueryStats>{};
  for (var event in events) {
    if (event.channel != 'sql') continue;
    var query = event.payload['query'];
    if (query is! String) continue;
    var stats = byShape.putIfAbsent(
      normalizeSql(query),
      () => QueryStats(normalizeSql(query)),
    );
    stats.occurrences.add(event);
    var ms = event.payload['ms'];
    if (ms is num) {
      stats.totalMs += ms.toDouble();
      if (ms > stats.maxMs) stats.maxMs = ms.toDouble();
    }
  }
  return byShape.values.toList()
    ..sort((a, b) => b.totalMs.compareTo(a.totalMs));
}

/// Normalized query → occurrence count, for queries repeated at least
/// [threshold] times within one request's correlated events — the N+1 shape.
///
/// Counts on [normalizeSql]'s output because the N+1 queries differ precisely
/// in their literals (spec decision 12). Lives on the core side so the badge
/// the panel draws and whatever `fw` reports later are the same computation.
Map<String, int> repeatedQueries(
  Iterable<ServerEvent> caused, {
  int threshold = 3,
}) {
  var counts = <String, int>{};
  for (var event in caused) {
    if (event.channel != 'sql') continue;
    var query = event.payload['query'];
    if (query is! String) continue;
    counts.update(normalizeSql(query), (n) => n + 1, ifAbsent: () => 1);
  }
  counts.removeWhere((_, count) => count < threshold);
  return counts;
}

const _serverParameter = ActionParameter(
  'name',
  'Server',
  required: false,
  description: 'Which server, when several are running.',
);

const _lastParameter = ActionParameter(
  'last',
  'Count',
  kind: ActionParameterKind.integer,
  required: false,
  defaultValue: '20',
  description: 'How many to return, newest first. Applied after the filters.',
);

const _minStatusParameter = ActionParameter(
  'minStatus',
  'Minimum status',
  kind: ActionParameterKind.integer,
  required: false,
  description:
      'Only requests whose status is at least this — 400 for everything that '
      "failed, 500 for the server's own faults. On `errors`, this replaces "
      'the default rule rather than adding to it: it asks about the status '
      'and nothing else.',
);

const _sinceParameter = ActionParameter(
  'since',
  'Since',
  required: false,
  description:
      'Only what happened within this window, as a duration back from now — '
      '"30s", "10m", "2h" — or an ISO-8601 instant. Anything else is refused '
      'rather than ignored.',
);

const _detailsParameter = ActionParameter(
  'details',
  'With details',
  kind: ActionParameterKind.boolean,
  required: false,
  description:
      "Attach each event's captured headers and bodies — the half a 500 is "
      'usually opened for, and the expensive half. Held server-side and '
      'fetched per event, so narrow the answer with the filters first; the '
      'reply says so when a byte budget cut the rest short.',
);

PluginCore serverCoreFactory(PluginHost host) => ServerCore(host);

/// Where a [ServerCore] finds servers and attaches to them.
///
/// The live one is the run dir and a unix socket. A recording is the other
/// one: the same handles and the same events, read from files, so the core
/// and the panel above it do not know which they are on — the launcher-icon
/// plugin's `scan` seam, for servers.
abstract class ServerSource {
  /// The handles announced under [underRoot], newest first or not: the core
  /// sorts.
  Future<List<ServerHandle>> scan({required String underRoot});

  /// Fires when the set of handles may have changed, or null when it cannot —
  /// a recording never changes.
  Stream<void>? watch();

  /// Attaches, or returns null after telling [onFailure] whether the handle
  /// turned out to be dead (and was removed) or merely slow.
  Future<ServerAttachment?> attach(
    ServerHandle handle, {
    required void Function(Object error, {required bool deleted}) onFailure,
  });
}

/// One attachment to one server: the hello, the ring, the live tail, and the
/// two questions the panel asks back. [ServerAttachClient] wearing an
/// interface, so a recording can stand where a socket does.
abstract class ServerAttachment {
  ServerHello get hello;
  List<ServerEvent> get received;
  Stream<ServerEvent> get events;
  bool get replayComplete;
  Future<void> get done;
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]);
  Future<Map<String, Object?>?> details(int eventId);
  Future<void> close();
}

/// The run dir and the socket, as before this seam existed.
class LiveServerSource implements ServerSource {
  const LiveServerSource();

  @override
  Future<List<ServerHandle>> scan({required String underRoot}) async =>
      scanServerHandles(ServerCore.runDirProvider(), underRoot: underRoot);

  @override
  Stream<void>? watch() =>
      Directory(ServerCore.runDirProvider())
          .watch()
          .where((event) => event.path.contains('srv-'));

  @override
  Future<ServerAttachment?> attach(
    ServerHandle handle, {
    required void Function(Object error, {required bool deleted}) onFailure,
  }) async {
    var client = await attachToServer(handle, onFailure: onFailure);
    return client == null ? null : _LiveAttachment(client);
  }
}

class _LiveAttachment implements ServerAttachment {
  _LiveAttachment(this._client);

  final ServerAttachClient _client;

  @override
  ServerHello get hello => _client.hello;
  @override
  List<ServerEvent> get received => _client.received;
  @override
  Stream<ServerEvent> get events => _client.events;
  @override
  bool get replayComplete => _client.replayComplete;
  @override
  Future<void> get done => _client.done;
  @override
  Future<Map<String, Object?>> request(
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) => _client.request(channel, method, params);
  @override
  Future<Map<String, Object?>?> details(int eventId) =>
      _client.details(eventId);
  @override
  Future<void> close() => _client.close();
}
