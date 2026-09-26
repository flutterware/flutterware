import 'dart:async';

import 'package:flutterware/channels.dart' show PanelDescriptor, panelsChannel;
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_client.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/protocol.dart'
    show ServerHandle, scanServerHandles;
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
import 'package:logging/logging.dart';

import '../run/channel_client.dart' show RunAttachment;
import '../run/handle.dart';
import '../run/panel_client.dart';
import '../run/run_sources.dart';
import '../utils/run_dir.dart';

final _logger = Logger('world_trace');

/// One gesture on a person's app, and everything the world saw it cause.
class TraceStep {
  TraceStep(this.id, this.person);

  /// The guest's name for it: `ben.3`.
  final String id;
  final String person;

  /// When the gesture ended — where the offsets of what it caused start.
  DateTime? at;

  /// `tap`, `longPress` or `drag`.
  String? verb;

  /// What it landed on, spelled as the drive targets are: `"Order"`.
  String? target;

  /// What it did, in the journal's words: `tap "Order"`.
  String get did => '${verb ?? 'step'} ${target ?? ''}'.trim();
}

/// One thing a step caused, somewhere in the world.
class TraceBeat {
  const TraceBeat(
    this.at,
    this.what, {
    this.person,
    this.node,
    this.line,
    this.inbound = false,
  });

  final DateTime at;

  /// Where and what, in a line: `Ben → lab  POST /orders  201 in 12 ms`.
  final String what;

  /// The person at the device end of it: who sent the request, who was
  /// reached, whose phone the record arrived on.
  final String? person;

  /// The part of the system it touched — a [SystemServer] node id, or
  /// [syncNode] — or null for what happened on a device alone.
  final String? node;

  /// The words on a line between [person] and [node], for a beat that
  /// crossed from one to the other; null for one that did not.
  final String? line;

  /// Whether it ran from [node] to [person] — a reach, an arrival — rather
  /// than from the person's app to the system.
  final bool inbound;
}

/// The node every synced record arrives from: the sync engine's service,
/// which is not Dart and reports nothing but what the apps' databases show.
const syncNode = 'sync';

/// What one server has reported since the world opened, as the canvas draws
/// it: the parts of its API, the tables it wrote, what it sent outside.
class SystemServer {
  SystemServer(this.name);

  /// As it announces itself: `lab`.
  final String name;

  /// Each part of its API — `POST /orders/:id/advance` — and how many times
  /// it was asked. The adapter's `part` when it names one, the path when not.
  final parts = <String, int>{};

  /// Each table it wrote, and the records.
  final tables = <String, Set<String>>{};

  /// What it sent outside — `sms`, `push` — and how many.
  final sent = <String, int>{};

  /// How many times it reached someone on a connection they held open.
  var reached = 0;

  String partNode(String part) => '$name/part/$part';
  String tableNode(String table) => '$name/table/$table';
  String sentNode(String channel) => '$name/sent/$channel';
}

/// A step and what it caused, in the order it happened.
typedef TracedStep = ({TraceStep step, List<TraceBeat> beats});

/// Everything the world has heard since it opened, joined into steps.
///
/// Three kinds of source, each joined its own way:
///
/// - **a person's app** names its steps and the requests it stamped with
///   one ([worldStepsChannel], [worldRequestsChannel]);
/// - **a server** reports its events, each carrying the step of the request
///   it happened under — the `step` its adapter read from the header;
/// - **a synced database** reports records, by key: written locally, or
///   arrived with a sync. A record joins the step whose write it carries —
///   the server's write of that key, which the upload's step names.
///
/// Pure: [WorldTracer] feeds it, a test can too.
class WorldTrace {
  WorldTrace({required this.since});

  /// When this opening started. A server outlives a restart, and its ring
  /// still holds the last opening's steps under the same names.
  final DateTime since;

  final _steps = <String, TraceStep>{};
  final _owners = <String, String>{};
  final _requests = <_Request>[];
  final _server = <_ServerEvent>[];
  final _records = <_Record>[];
  final _users = <String, String>{};
  final _declared = <String>{};
  final _phones = <String, String>{};
  final _hosts = <String, String>{};
  final _servers = <String, SystemServer>{};
  final _parts = <String, String>{};
  final _changed = StreamController<void>.broadcast(sync: true);

  /// What each server has reported, in the order they first did.
  Iterable<SystemServer> get servers => _servers.values;

  /// Fires after anything new was heard. Synchronous and frequent: a
  /// surface that draws this throttles it.
  Stream<void> get changed => _changed.stream;

  /// How much is kept of each kind: a world left open all day is not a leak.
  static const cap = 5000;

  /// [person] is in the world: their steps are named after them, and a
  /// server naming [userId] or [phone] means them.
  void addPerson(String person, {String? userId, String? phone}) {
    _owners[worldStepPrefix(person)] = person;
    if (userId != null) {
      _users[userId] = person;
      _declared.add(userId);
    }
    if (phone != null) _phones[phone] = person;
  }

  /// Whose [userId] is, as the world knows by now.
  String? personOfUser(String userId) => _users[userId];

  void addGuestEvent(String person, InspectorEvent event) {
    var payload = event.payload;
    switch (event.channel) {
      case worldStepsChannel:
        if (payload['step'] case String id) {
          _stepOf(id, person)
            ..at = event.time
            ..verb = payload['verb'] as String?
            ..target = payload['target'] as String?;
        }
      case worldRequestsChannel:
        if (payload['step'] case String id) {
          _stepOf(id, person);
          var request = _Request(
            id,
            person,
            event.time,
            '${payload['method']}',
            '${payload['url']}',
            window: payload['how'] == 'window',
          );
          _add(_requests, request);
          for (var served in _recent(_server)) {
            _learnHost(request, served);
          }
        }
      case var channel when channel.endsWith('/records'):
        var key = payload['key'];
        var change = payload['change'];
        if (key is! String || change is! String || change == 'present') break;
        _add(
          _records,
          _Record(
            person,
            event.time,
            key,
            '${payload['table'] ?? ''}',
            change,
            op: payload['op'] as int?,
          ),
        );
      default:
        return;
    }
    _changed.add(null);
  }

  void addServerEvent(String server, InspectorEvent event) {
    if (event.time.isBefore(since)) return;
    _summarize(server, event);
    _changed.add(null);
    var step = event.payload['step'];
    if (step is! String) return;
    var owner = _owners[worldStepOwner(step)];
    if (owner == null) return;
    _stepOf(step, owner);
    if (event.payload['user'] case String user
        when event.channel == 'identify') {
      _users.putIfAbsent(user, () => owner);
    }
    var served = _ServerEvent(server, step, event);
    _add(_server, served);
    if (event.channel == 'http') {
      for (var request in _recent(_requests)) {
        _learnHost(request, served);
      }
    }
  }

  /// Counts [event] into its server's summary — every event since the world
  /// opened, whoever caused it: the script's seeding is part of the system
  /// too.
  void _summarize(String name, InspectorEvent event) {
    var server = _servers.putIfAbsent(name, () => SystemServer(name));
    var payload = event.payload;
    switch (event.channel) {
      case 'http':
        var part = '${payload['method']} ${payload['part'] ?? payload['path']}';
        server.parts[part] = (server.parts[part] ?? 0) + 1;
        if (event.rid case var rid?) _parts['$name/$rid'] = part;
      case 'write':
        server.tables
            .putIfAbsent('${payload['table']}', () => {})
            .add('${payload['key']}');
      case 'sms' || 'push':
        server.sent[event.channel] = (server.sent[event.channel] ?? 0) + 1;
      case 'reach':
        server.reached++;
    }
  }

  /// The node of the request [event] happened under, once its `http` event —
  /// reported when the response is — has arrived.
  String? _partNode(_ServerEvent event) {
    var part = _parts['${event.server}/${event.event.rid}'];
    return part == null ? null : _servers[event.server]?.partNode(part);
  }

  /// The newest of [list] — where the other half of something that just
  /// arrived is, since the two halves of a request arrive together.
  static Iterable<T> _recent<T>(List<T> list) =>
      list.length <= 200 ? list : list.sublist(list.length - 200);

  /// Which server answers at [request]'s host, once one of them reported a
  /// request the app stamped.
  void _learnHost(_Request request, _ServerEvent served) {
    if (served.channel == 'http' &&
        served.step == request.step &&
        served.payload['method'] == request.method &&
        served.payload['path'] == request.path) {
      _hosts[request.host] = served.server;
    }
  }

  /// The newest [limit] steps — [person]'s only, or just [step] — each with
  /// what it caused. A drag that caused nothing is left out: it was a scroll.
  List<TracedStep> steps({String? person, String? step, int limit = 10}) {
    var chosen = [
      for (var candidate in _steps.values)
        if (candidate.at != null &&
            (person == null || candidate.person == person) &&
            (step == null || candidate.id == step))
          candidate,
    ]..sort((a, b) => a.at!.compareTo(b.at!));
    var traced = <TracedStep>[];
    for (var candidate in chosen.reversed) {
      var beats = _beatsOf(candidate);
      if (beats.isEmpty && candidate.verb == 'drag') continue;
      traced.add((step: candidate, beats: beats));
      if (traced.length >= limit) break;
    }
    return traced.reversed.toList();
  }

  TraceStep _stepOf(String id, String person) =>
      _steps.putIfAbsent(id, () => TraceStep(id, person));

  void _add<T>(List<T> list, T item) {
    list.add(item);
    if (list.length > cap) list.removeRange(0, list.length - cap);
  }

  List<TraceBeat> _beatsOf(TraceStep step) {
    var beats = <TraceBeat>[];
    var answered = <_ServerEvent>{};
    for (var request in _requests) {
      if (request.step != step.id) continue;
      var served = _served(request, answered);
      var how = request.window ? ', joined by time' : '';
      if (served == null) {
        // Unreported — a WebSocket upgrade, which shelf hands over by
        // throwing, or a server with no adapter — but named, when another
        // request to the same host was answered by a server that reports.
        beats.add(
          TraceBeat(
            request.at,
            '${request.person} → ${_hosts[request.host] ?? request.host}  '
            '${request.method} ${request.path}$how',
            person: request.person,
          ),
        );
        continue;
      }
      answered.add(served);
      beats.add(
        TraceBeat(
          request.at,
          '${request.person} → ${served.server}  ${request.method} '
          '${request.path}  ${_answer(served.payload)}$how',
          person: request.person,
          node: _partNode(served),
          line: '${request.method} ${request.path}',
        ),
      );
    }
    for (var event in _server) {
      if (event.step != step.id || answered.contains(event)) continue;
      if (_serverBeat(event) case var beat?) beats.add(beat);
    }
    for (var record in _records) {
      if (_causeOf(record) != step.id) continue;
      var key = _short(record.key);
      var name = record.table.isEmpty ? key : '${record.table}/$key';
      var op = record.op == null ? '' : ' (op ${record.op})';
      var local = record.change.startsWith('local ');
      beats.add(
        TraceBeat(
          record.at,
          local
              ? '${record.person}  wrote $name locally'
              : record.person == step.person
              ? '${record.person}  $name confirmed$op'
              : '${record.person}  $name arrived$op',
          person: record.person,
          node: local ? null : syncNode,
          line: local ? null : '$name$op',
          inbound: !local,
        ),
      );
    }
    return beats..sort((a, b) => a.at.compareTo(b.at));
  }

  /// The server's report of [request]: same step, method and path.
  _ServerEvent? _served(_Request request, Set<_ServerEvent> answered) {
    for (var event in _server) {
      if (event.step == request.step &&
          event.channel == 'http' &&
          !answered.contains(event) &&
          event.payload['method'] == request.method &&
          event.payload['path'] == request.path) {
        return event;
      }
    }
    return null;
  }

  /// The step whose write [record] is: for a local write, the person's own
  /// step just before it; for an arrival, the last server write of its key
  /// before it arrived.
  String? _causeOf(_Record record) {
    if (record.change.startsWith('local ')) {
      TraceStep? latest;
      for (var step in _steps.values) {
        var at = step.at;
        if (step.person != record.person || at == null) continue;
        if (at.isAfter(record.at) ||
            record.at.difference(at) > const Duration(seconds: 5)) {
          continue;
        }
        if (latest == null || at.isAfter(latest.at!)) latest = step;
      }
      return latest?.id;
    }
    _ServerEvent? write;
    for (var event in _server) {
      if (event.channel != 'write' || event.payload['key'] != record.key) {
        continue;
      }
      if (event.time.isAfter(record.at)) continue;
      if (write == null || event.time.isAfter(write.time)) write = event;
    }
    return write?.step;
  }

  TraceBeat? _serverBeat(_ServerEvent event) {
    var server = event.server;
    var payload = event.payload;
    var at = event.time;
    var node = _partNode(event);
    var system = _servers[server];
    String? personOf(Object? user) => user is String ? _users[user] : null;
    switch (event.channel) {
      case 'http':
        return TraceBeat(
          at,
          '$server  ${payload['method']} ${payload['path']}  '
          '${_answer(payload)}',
          node: node,
        );
      case 'identify':
        // Every request says who it is; only the first says something new,
        // and only of a user the script did not name.
        var user = '${payload['user']}';
        if (_declared.contains(user) || _identifiedBefore(event)) return null;
        return TraceBeat(
          at,
          '$server  knows ${personOf(user) ?? 'someone'} as $user',
          node: node,
        );
      case 'reach':
        var user = payload['user'];
        var person = personOf(user);
        return TraceBeat(
          at,
          '$server → ${person ?? user}  ${payload['what']}',
          person: person,
          node: node,
          line: '${payload['what']}',
          inbound: true,
        );
      case 'write':
        return TraceBeat(
          at,
          '$server  wrote ${payload['table']}/${_short(payload['key'])} '
          '(${payload['op']})',
          node: system?.tableNode('${payload['table']}'),
        );
      case 'sms':
        var to = payload['to'];
        var person = _phones[to];
        return TraceBeat(
          at,
          '$server → ${person ?? to} by SMS  ${payload['body']}',
          person: person,
          node: system?.sentNode('sms'),
          line: 'SMS',
          inbound: true,
        );
      case 'push':
        var to = payload['to'] ?? payload['user'];
        var person = personOf(to);
        return TraceBeat(
          at,
          '$server → ${person ?? to} by push  ${payload['title']}',
          person: person,
          node: system?.sentNode('push'),
          line: '${payload['title']}',
          inbound: true,
        );
      case 'log':
        return TraceBeat(at, '$server  ${payload['message']}', node: node);
      case 'error':
        return TraceBeat(
          at,
          '$server  error: ${payload['message'] ?? payload['error']}',
          node: node,
        );
      case 'info':
        return null;
      case var channel:
        return TraceBeat(at, '$server  $channel', node: node);
    }
  }

  /// Whether a step before [event]'s already identified its user.
  bool _identifiedBefore(_ServerEvent event) => _server.any(
    (other) =>
        other.channel == 'identify' &&
        other.payload['user'] == event.payload['user'] &&
        other.time.isBefore(event.time),
  );

  /// A UUID by its first eight digits, as a commit is by its hash's: enough
  /// to tell the records of one world apart, and a line stays a line.
  static String _short(Object? key) => switch (key) {
    String uuid when _uuid.hasMatch(uuid) => uuid.substring(0, 8),
    var other => '$other',
  };

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-');

  static String _answer(Map<String, Object?> payload) {
    var ms = payload['ms'];
    return '${payload['status']}'
        '${ms is num ? ' in ${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms' : ''}';
  }
}

class _Request {
  _Request(
    this.step,
    this.person,
    this.at,
    this.method,
    this.url, {
    required this.window,
  });

  final String step;
  final String person;
  final DateTime at;
  final String method;

  /// `localhost:5040/orders`: host, port and path, as the guest reported it.
  final String url;
  final bool window;

  String get host =>
      url.contains('/') ? url.substring(0, url.indexOf('/')) : url;
  String get path => url.contains('/') ? url.substring(url.indexOf('/')) : '/';
}

class _ServerEvent {
  _ServerEvent(this.server, this.step, this.event);

  final String server;
  final String step;
  final InspectorEvent event;

  String get channel => event.channel;
  Map<String, Object?> get payload => event.payload;
  DateTime get time => event.time;
}

class _Record {
  _Record(this.person, this.at, this.key, this.table, this.change, {this.op});

  final String person;
  final DateTime at;
  final String key;
  final String table;
  final String change;
  final int? op;
}

/// Feeds a [WorldTrace] from the live world: an attachment to each person's
/// app, and one to each server announcing itself under the worktree.
///
/// Servers are looked for when the world has opened and again whenever an
/// app sends a request — a server announces itself on its first event, so
/// the one a request reaches is there by then.
class WorldTracer {
  WorldTracer({
    required this.worktree,
    DateTime? since,
    this.channels = const LiveRunChannels(),
    String Function()? runDir,
  }) : trace = WorldTrace(since: since ?? DateTime.now()),
       _runDir = runDir ?? flutterwareRunDir;

  final String worktree;
  final WorldTrace trace;
  final RunChannels channels;
  final String Function() _runDir;

  /// Called when a person's sync state was read anew — the one thing here a
  /// surface draws as it changes. Everything else is read when asked.
  void Function()? onSync;

  final _apps = <String, _App>{};
  final _servers = <String, ServerAttachClient>{};
  var _closed = false;
  DateTime? _lastScan;

  /// Each person's sync state, as their app's database panel last read it —
  /// `{engine, clientId, pendingUploads, lastSyncedAt, buckets}` — for those
  /// whose app declares one.
  Map<String, Object?>? syncOf(String person) => _apps[person]?.sync;

  /// How many times [follow] tries an app that is not answering yet, a
  /// quarter second apart.
  static const attachAttempts = 40;

  /// Starts hearing [person]'s app.
  Future<void> follow(
    String person,
    RunHandle handle, {
    String? userId,
    String? phone,
  }) async {
    trace.addPerson(person, userId: userId, phone: phone);
    // The guest's process answers before its app does: the channels are
    // registered once the app's `main` has run, which a fast attach beats.
    RunAttachment? client;
    for (var attempt = 0; client == null; attempt++) {
      try {
        client = await channels.attach(handle, peer: 'world');
      } on Object catch (error) {
        if (_closed) return;
        if (attempt == attachAttempts) {
          _logger.fine('Not tracing $person: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (_closed) return unawaited(client.close());
    var app = _App(person, client);
    await _apps.remove(person)?.close();
    _apps[person] = app;
    app.subscription = client.events.listen((event) => _heard(app, event));
    for (var event in client.received) {
      _heard(app, event);
    }
    await _findSync(app);
  }

  /// Looks for servers not attached yet — at most once a second.
  Future<void> scanServers() async {
    var now = DateTime.now();
    if (_lastScan case var last? when now.difference(last).inSeconds < 1) {
      return;
    }
    _lastScan = now;
    List<ServerHandle> handles;
    try {
      handles = scanServerHandles(_runDir(), underRoot: worktree);
    } on Object {
      return;
    }
    for (var handle in handles) {
      var key = '${handle.name}-${handle.pid}';
      if (_servers.containsKey(key) || _closed) continue;
      var client = await attachToServer(handle);
      if (client == null) continue;
      if (_closed) {
        await client.close();
        return;
      }
      _servers[key] = client;
      var seen = -1;
      void hear(InspectorEvent event) {
        if (event.id <= seen) return;
        seen = event.id;
        trace.addServerEvent(handle.name, event);
      }

      client.events.listen(hear);
      client.received.forEach(hear);
    }
  }

  void _heard(_App app, InspectorEvent event) {
    if (event.id <= app.seen) return;
    app.seen = event.id;
    trace.addGuestEvent(app.person, event);
    if (event.channel == worldRequestsChannel) unawaited(scanServers());
    // A devbar declares its panels once it is mounted — after the attach,
    // as often as not — and says so.
    if (event.channel == panelsChannel && app.syncPanel == null) {
      unawaited(_findSync(app));
    }
    if (app.syncPanel != null && event.channel.endsWith('/records')) {
      app.readSyncSoon(onSync);
    }
  }

  Future<void> _findSync(_App app) async {
    List<PanelDescriptor> panels;
    try {
      panels = await RunPanels(app.client).list();
    } on Object {
      return;
    }
    for (var panel in panels) {
      if (panel.states.any((state) => state.id == 'sync')) {
        app.syncPanel = panel.id;
        await app.readSync();
        onSync?.call();
        return;
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait([for (var app in _apps.values) app.close()]);
    _apps.clear();
    await Future.wait([for (var server in _servers.values) server.close()]);
    _servers.clear();
  }
}

class _App {
  _App(this.person, this.client);

  final String person;
  final RunAttachment client;
  StreamSubscription<InspectorEvent>? subscription;
  var seen = -1;
  String? syncPanel;
  Map<String, Object?>? sync;
  Timer? _syncSoon;

  Future<void> readSync() async {
    try {
      sync = await RunPanels(client).state(syncPanel!, 'sync');
    } on Object {
      // Not open yet: the next record reads it again.
    }
  }

  /// A burst of records is one read.
  void readSyncSoon(void Function()? then) {
    _syncSoon?.cancel();
    _syncSoon = Timer(const Duration(milliseconds: 300), () async {
      await readSync();
      then?.call();
    });
  }

  Future<void> close() async {
    _syncSoon?.cancel();
    await subscription?.cancel();
    await client.close();
  }
}
