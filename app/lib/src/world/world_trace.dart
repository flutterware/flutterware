import 'dart:async';
import 'dart:math';

import 'package:flutterware/channels.dart' show PanelDescriptor, panelsChannel;
// ignore: implementation_imports
import 'package:flutterware/src/app_events/events.dart' show foldSql;
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
import 'declared_links.dart';

final _logger = Logger('world_trace');

/// One gesture on a person's app — or one run of the world's own action —
/// and everything the world saw it cause.
class TraceStep {
  TraceStep(this.id, this.person);

  /// The guest's name for it: `ben.3`; the owner's, for an action: `world.2`.
  final String id;

  /// Whose phone it was taken on, or [worldActionsOwner].
  final String person;

  /// When the gesture ended — where the offsets of what it caused start.
  DateTime? at;

  /// `tap`, `longPress` or `drag`; `type` or `open` for a delivery;
  /// `action` for a world's own.
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
    this.folded = const [],
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

  /// What [what] counts rather than says: the statements a request ran, one
  /// line each, for whoever opens them. A request that ran 23 of them is
  /// still one line, and the writes among them are beats of their own.
  final List<String> folded;
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

  /// The layer a table's writes said it belongs to — `jobs` for a job
  /// queue's tables — when not the records people act on. Drawn in a group
  /// of its own, beneath them.
  final layers = <String, String>{};

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

/// Which kind of node of the system a [NodeContents] is.
enum NodeKind { route, table, sent, sync }

/// What one node of the system holds, as the world heard it: every call a
/// route answered, every record a table was written, every message sent
/// outside, every record the sync engine carried — since the world opened,
/// whoever caused it, the script's own seeding included.
class NodeContents {
  const NodeContents({
    required this.node,
    required this.kind,
    required this.title,
    required this.server,
    required this.items,
    this.earlier = 0,
    this.unwritten = 0,
  });

  final String node;
  final NodeKind kind;

  /// `POST /orders/:id/advance`, `orders`, `sms`; empty for the sync engine.
  final String title;

  /// The server it is part of; empty for the sync engine.
  final String server;

  /// Newest first.
  final List<TraceItem> items;

  /// How many more it saw than [items] holds: older than the world keeps.
  final int earlier;

  /// For the sync engine, how many more records the phones received that no
  /// server here reported writing: a first sync brings everything written
  /// before the world opened, and a write no adapter reports looks the same
  /// — as does one reported without its key ([unwrittenNote]).
  final int unwritten;
}

/// What [NodeContents.unwritten] means, said where it is counted: the three
/// ways a record arrives with no write to join it.
String unwrittenNote(int count) =>
    '${count == 1 ? '1 more record' : '$count more records'} arrived that no '
    'server here reported writing under that key: written before the world '
    'opened, where no adapter reports, or reported without the key — one the '
    'database generated and the adapter never read back.';

/// One thing a node holds — a call, a record, a message — or, in a record's
/// [life], one moment of it.
class TraceItem {
  const TraceItem(
    this.at,
    this.title, {
    this.detail,
    this.person,
    this.step,
    this.life = const [],
    this.message,
  });

  /// When it happened; for a record, when it last changed.
  final DateTime at;

  /// What it is: the path asked, the record's key, whom a message went to.
  final String title;

  /// What came of it: `200 in 5.6 ms`, `update · status ready`, the message.
  final String? detail;

  /// Whom it is about: who asked, who wrote it last, whom it reached, whose
  /// phone.
  final String? person;

  /// The step that caused it; null for what no person's step did — the
  /// script's seeding, an app's own polling.
  final String? step;

  /// For a record, each write the server reported and each phone that wrote
  /// or received it, oldest first.
  final List<TraceItem> life;

  /// For a message sent outside, the message — what its recipient's app can
  /// be handed.
  final OutboxMessage? message;
}

/// A message a server sent outside — an SMS, a push, a mail — as its adapter
/// reported it, with what a delivery hands its recipient's app: the code it
/// carries to type, the link to open.
class OutboxMessage {
  const OutboxMessage({
    required this.id,
    required this.at,
    required this.kind,
    required this.to,
    required this.text,
    this.person,
    this.step,
    this.code,
    this.link,
    this.links = const [],
    this.body,
    this.html,
    this.sender,
    this.byTime = false,
  });

  /// `lab/42`: the server that reported it and the event it arrived as —
  /// what `worlds deliver` takes.
  final String id;

  /// Who sent it: the server, or the service it says it came `from`.
  final String? sender;

  /// Whether [step] was joined by time: a service that is not Dart sent it,
  /// and carried none.
  final bool byTime;
  final DateTime at;

  /// `sms`, `push` or `mail`.
  final String kind;

  /// As the server addressed it: a phone number, a user id, an address.
  final String to;

  /// What it says: an SMS's body, a push's title, a mail's subject.
  final String text;

  /// Whom it reached, when the world knows whose [to] is.
  final String? person;

  /// The step that sent it.
  final String? step;

  /// The one-time code in it — the first run of four to eight digits, in a
  /// message that speaks of a code.
  final String? code;

  /// The link to hand over: the one the adapter named, else the first the
  /// recipient's app declares it opens, else the first on a scheme of an
  /// app's own, else the first.
  final String? link;

  /// Every link in it, [link] first: what a delivery may open.
  final List<String> links;

  /// All it says, where [text] is only its headline: a push's body, a
  /// mail's text.
  final String? body;

  /// A mail's HTML, as its adapter reported it.
  final String? html;

  /// What a phone shows under [text]: a push's body. A push titled with its
  /// sender's name says nothing without it.
  String? get subtitle =>
      kind == 'push' && body != null && body != text ? body : null;

  /// [text] and [subtitle] on one line.
  String get said => switch (subtitle) {
    var subtitle? => '$text — $subtitle',
    null => text,
  };
}

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
  final _emails = <String, String>{};
  final _links = <String, DeclaredLinks>{};
  final _hosts = <String, String>{};
  final _servers = <String, SystemServer>{};
  final _parts = <String, String>{};

  /// Who each request was, by `server/rid`, as the server identified it.
  final _callers = <String, String>{};
  final _changed = StreamController<void>.broadcast(sync: true);

  /// What each server has reported, in the order they first did.
  Iterable<SystemServer> get servers => _servers.values;

  /// Fires after anything new was heard. Synchronous and frequent: a
  /// surface that draws this throttles it.
  Stream<void> get changed => _changed.stream;

  /// How much is kept of each kind: a world left open all day is not a leak.
  static const cap = 5000;

  /// [person] is in the world: their steps are named after them, and a
  /// server naming [userId], [phone] or [email] means them. [links] are what
  /// their app says it opens.
  void addPerson(
    String person, {
    String? userId,
    String? phone,
    String? email,
    DeclaredLinks? links,
  }) {
    _owners[worldStepPrefix(person)] = person;
    if (links != null) _links[person] = links;
    if (userId != null) {
      _users[userId] = person;
      _declared.add(userId);
    }
    if (phone != null) _phones[phone] = person;
    if (email != null) _emails[email.toLowerCase()] = person;
  }

  /// Whose [userId] is, as the world knows by now.
  String? personOfUser(String userId) => _users[userId];

  /// A run of the world's own [action], as the step [id] — `world.3` — which
  /// the script sends its requests under, from [at].
  void addActionStep(String id, String action, DateTime at) {
    _owners[worldStepOwner(id) ?? worldActionsOwner] = worldActionsOwner;
    _stepOf(id, worldActionsOwner)
      ..at = at
      ..verb = 'action'
      ..target = '"$action"';
    _changed.add(null);
  }

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
            bucket: payload['bucket'] as String?,
          ),
        );
      default:
        return;
    }
    _changed.add(null);
  }

  /// Takes every event since the world opened: one under a person's step
  /// joins it, and the rest — the script's seeding, an app's own polling —
  /// are still what the system holds.
  void addServerEvent(String reporter, InspectorEvent event) {
    if (event.time.isBefore(since)) return;
    // A message another service sent — the mail an identity provider sends
    // itself, reported by whatever caught it — is drawn as that service's.
    var from = _sentChannels.contains(event.channel)
        ? event.payload['from']
        : null;
    var server = from is String && from.isNotEmpty ? from : reporter;
    _summarize(server, event);
    String? step;
    if (event.payload['step'] case String id) {
      if (_owners[worldStepOwner(id)] case var owner?) {
        step = id;
        _stepOf(id, owner);
        // Whom an action signs in as is somebody, not the world.
        if (event.payload['user'] case String user
            when event.channel == 'identify' && owner != worldActionsOwner) {
          _users.putIfAbsent(user, () => owner);
        }
      }
    }
    // A service that is not Dart carries no step: what it sent joins the
    // newest step heard just before, and says it joined by time.
    var byTime = false;
    if (step == null && server != reporter) {
      step = _stepBefore(event.time);
      byTime = step != null;
    }
    var served = _ServerEvent(
      server,
      step,
      event,
      reporter: reporter,
      byTime: byTime,
    );
    _add(_server, served);
    if (step != null && event.channel == 'http') {
      for (var request in _recent(_requests)) {
        _learnHost(request, served);
      }
    }
    _changed.add(null);
  }

  /// How long before a message from a service that carries no step the step
  /// that caused it may have been heard.
  static const byTimeWindow = Duration(seconds: 3);

  /// The newest step, or request or server event of one, in the
  /// [byTimeWindow] before [time].
  String? _stepBefore(DateTime time) {
    (DateTime, String)? newest;
    void consider(DateTime at, String? step) {
      if (step == null || at.isAfter(time)) return;
      if (time.difference(at) > byTimeWindow) return;
      if (newest == null || at.isAfter(newest!.$1)) newest = (at, step);
    }

    for (var step in _steps.values) {
      if (step.at case var at?) consider(at, step.id);
    }
    for (var request in _recent(_requests)) {
      consider(request.at, request.step);
    }
    for (var event in _recent(_server)) {
      consider(event.time, event.step);
    }
    return newest?.$2;
  }

  /// Counts [event] into its server's summary — every event since the world
  /// opened, whoever caused it: the script's seeding is part of the system
  /// too.
  void _summarize(String name, InspectorEvent event) {
    var server = _servers.putIfAbsent(name, () => SystemServer(name));
    var payload = event.payload;
    switch (event.channel) {
      case 'http':
        var part = _partOf(payload);
        server.parts[part] = (server.parts[part] ?? 0) + 1;
        if (event.rid case var rid?) _parts['$name/$rid'] = part;
      case 'identify':
        if ((event.rid, payload['user']) case (var rid?, String user)) {
          _callers['$name/$rid'] = user;
        }
      case 'write':
        var table = '${payload['table']}';
        server.tables.putIfAbsent(table, () => {}).add('${payload['key']}');
        if (payload['layer'] case String layer when layer.isNotEmpty) {
          server.layers[table] = layer;
        }
      case 'sms' || 'push' || 'mail':
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

  /// Every node of the system, by the name the band shows it under — a
  /// route, a table, `sms`, [syncNode] — and each with its server's name in
  /// front (`lab/orders`) once there are two servers to tell apart.
  Map<String, String> get nodeNames {
    var several = _servers.length > 1;
    var names = <String, String>{};
    for (var server in _servers.values) {
      String name(String part) => several ? '${server.name}/$part' : part;
      for (var part in server.parts.keys) {
        names[name(part)] = server.partNode(part);
      }
      for (var table in server.tables.keys) {
        names[name(table)] = server.tableNode(table);
      }
      for (var channel in server.sent.keys) {
        names[name(channel)] = server.sentNode(channel);
      }
    }
    if (_records.any((record) => record.change == 'synced')) {
      names[syncNode] = syncNode;
    }
    return names;
  }

  /// What [node] — a [SystemServer] node or [syncNode] — holds, newest
  /// first, at most [limit] of it; null for a node nothing reported.
  NodeContents? contentsOf(String node, {int limit = 200}) {
    if (node == syncNode) return _synced(limit);
    for (var server in _servers.values) {
      var name = server.name;
      String? after(String kind) => node.startsWith('$name/$kind/')
          ? node.substring('$name/$kind/'.length)
          : null;
      NodeContents contents(
        NodeKind kind,
        String title,
        List<TraceItem> items, {
        required int total,
      }) => NodeContents(
        node: node,
        kind: kind,
        title: title,
        server: name,
        items: items.take(limit).toList(),
        earlier: total - min(items.length, limit),
      );
      if (after('part') case var part?) {
        var calls = [
          for (var event in _server.reversed)
            if (event.server == name &&
                event.channel == 'http' &&
                _partOf(event.payload) == part)
              TraceItem(
                event.time,
                _shortPath('${event.payload['path']}'),
                detail: _answer(event.payload),
                person: _callerOf(event),
                step: event.step,
              ),
        ];
        return contents(
          NodeKind.route,
          part,
          calls,
          total: server.parts[part] ?? calls.length,
        );
      }
      if (after('table') case var table?) {
        var writes = <String, List<_ServerEvent>>{};
        for (var event in _server) {
          if (event.server == name &&
              event.channel == 'write' &&
              '${event.payload['table']}' == table) {
            writes.putIfAbsent('${event.payload['key']}', () => []).add(event);
          }
        }
        var records = [
          for (var MapEntry(:key, value: written) in writes.entries)
            TraceItem(
              written.last.time,
              _short(key),
              detail: _written(written.last.payload),
              person: _callerOf(written.last),
              step: written.last.step,
              life: _lifeOf(key),
            ),
        ]..sort((a, b) => b.at.compareTo(a.at));
        return contents(
          NodeKind.table,
          table,
          records,
          total: server.tables[table]?.length ?? records.length,
        );
      }
      if (after('sent') case var channel?) {
        var messages = [
          for (var event in _server.reversed)
            if (event.server == name && event.channel == channel)
              _message(event),
        ];
        return contents(
          NodeKind.sent,
          channel,
          messages,
          total: server.sent[channel] ?? messages.length,
        );
      }
    }
    return null;
  }

  /// Every record a phone received through the sync engine, by key — the
  /// ones a server here wrote; the rest are only counted.
  NodeContents _synced(int limit) {
    var latest = <String, _Record>{};
    for (var record in _records) {
      if (record.change == 'synced') latest[record.key] = record;
    }
    var written = {
      for (var event in _server)
        if (event.channel == 'write') '${event.payload['key']}',
    };
    var records = [
      for (var MapEntry(:key, value: record) in latest.entries)
        if (written.contains(key))
          TraceItem(
            record.at,
            record.table.isEmpty
                ? _short(key)
                : '${record.table}/${_short(key)}',
            detail: _holders(key),
            step: _causeOf(record),
            life: _lifeOf(key),
          ),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return NodeContents(
      node: syncNode,
      kind: NodeKind.sync,
      title: '',
      server: '',
      items: records.take(limit).toList(),
      earlier: max(0, records.length - limit),
      unwritten: latest.keys.where((key) => !written.contains(key)).length,
    );
  }

  /// `on Cleo's and Ben's phones`: whose phones a record reached.
  String _holders(String key) {
    var people = {
      for (var record in _records)
        if (record.key == key && record.change == 'synced') record.person,
    }.toList();
    var names = people.map((person) => "$person's").toList();
    var spelled = names.length <= 1
        ? names.join()
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    return 'on $spelled ${people.length == 1 ? 'phone' : 'phones'}';
  }

  /// A record's whole life, by its key: each write the server reported, and
  /// each phone that wrote it itself or received it — oldest first.
  List<TraceItem> _lifeOf(String key) => [
    for (var event in _server)
      if (event.channel == 'write' && event.payload['key'] == key)
        TraceItem(
          event.time,
          '${event.server} wrote it',
          detail: _written(event.payload),
          step: event.step,
        ),
    for (var record in _records)
      if (record.key == key) _moment(record),
  ]..sort((a, b) => a.at.compareTo(b.at));

  /// One phone's part in a record's life.
  TraceItem _moment(_Record record) {
    var step = _causeOf(record);
    var phone = "${record.person}'s phone";
    if (record.change.startsWith('local ')) {
      return TraceItem(
        record.at,
        'written on $phone',
        detail: record.change.substring('local '.length),
        person: record.person,
        step: step,
      );
    }
    var own = step != null && _steps[step]?.person == record.person;
    return TraceItem(
      record.at,
      own ? 'back on $phone' : 'arrived on $phone',
      detail: switch ((record.op, record.bucket)) {
        (null, null) => null,
        (var op, var bucket) => [
          if (op != null) 'op $op',
          if (bucket != null) 'in $bucket',
        ].join(' · '),
      },
      person: record.person,
      step: step,
    );
  }

  TraceItem _message(_ServerEvent event) {
    var message = _outboxMessage(event);
    return TraceItem(
      message.at,
      'to ${message.person ?? message.to}',
      detail: message.said,
      person: message.person,
      step: message.step,
      message: message,
    );
  }

  /// Every message the servers sent outside since the world opened — to
  /// [person] only, when named — newest first.
  List<OutboxMessage> outbox({String? person, int limit = 50}) =>
      [
            for (var event in _server.reversed)
              if (_sentChannels.contains(event.channel)) _outboxMessage(event),
          ]
          .where((message) => person == null || message.person == person)
          .take(limit)
          .toList();

  /// The message [id] names, if the world still holds it.
  OutboxMessage? messageById(String id) {
    for (var event in _server.reversed) {
      if (_sentChannels.contains(event.channel) && event.id == id) {
        return _outboxMessage(event);
      }
    }
    return null;
  }

  static const _sentChannels = {'sms', 'push', 'mail'};

  OutboxMessage _outboxMessage(_ServerEvent event) {
    var payload = event.payload;
    var to = '${payload['to'] ?? payload['user'] ?? ''}';
    var said = switch (event.channel) {
      'sms' => '${payload['body'] ?? ''}',
      'mail' => '${payload['subject'] ?? payload['text'] ?? ''}',
      _ => '${payload['title'] ?? payload['body'] ?? ''}',
    };
    var html = payload['html'] is String ? payload['html']! as String : null;
    // Where a code or a link may be: everything the message says, a mail's
    // HTML read as the text it shows.
    var words = [
      for (var key in const ['body', 'title', 'subject', 'text'])
        if (payload[key] case String text) text,
      if (html != null) html.replaceAll(_hidden, ' ').replaceAll(_tag, ' '),
    ].join('\n');
    var person = switch (event.channel) {
      'sms' => _phones[to],
      'mail' => _emails[to.toLowerCase()],
      _ => _users[to],
    };
    var found = {
      for (var match in _link.allMatches(words)) match[0]!,
      if (html != null)
        for (var match in _href.allMatches(html)) _unescape(match[1]!),
    };
    // The one to hand over is the one the app takes: the adapter's, or one
    // the app declares — a mail can list two store badges before it — or,
    // when it declares nothing readable, one on a scheme of its own.
    var declared = _links[person];
    var link = switch (payload['link']) {
      String named => named,
      _ =>
        found.where((link) => declared?.claims(link) ?? false).firstOrNull ??
            found.where(_ownScheme).firstOrNull ??
            found.firstOrNull,
    };
    var links = [?link, ...found.where((other) => other != link)];
    return OutboxMessage(
      id: event.id,
      sender: event.server,
      byTime: event.byTime,
      at: event.time,
      kind: event.channel,
      to: to,
      text: said,
      person: person,
      step: event.step,
      code: _saysCode.hasMatch(words)
          ? _code.firstMatch(words)?.group(0)
          : null,
      link: link,
      links: links,
      body: switch (event.channel) {
        'mail' => payload['text'] as String?,
        _ => payload['body'] as String?,
      },
      html: html,
    );
  }

  /// A link no browser opens — `shop://orders/7` — which only an app can;
  /// not a `mailto:` or a `tel:`, which the phone's own apps take.
  static bool _ownScheme(String link) =>
      link.contains('://') &&
      !link.startsWith('http://') &&
      !link.startsWith('https://');

  static final _tag = RegExp('<[^>]*>');

  /// What a mail's HTML holds that it never shows: its styles and scripts.
  static final _hidden = RegExp(
    r'<(style|script|head)\b[^>]*>.*?</\1>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _href = RegExp(
    r"""href\s*=\s*["']([^"']+)["']""",
    caseSensitive: false,
  );

  /// An attribute's value as the page means it: `&amp;` back to `&`.
  static String _unescape(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  static final _code = RegExp(r'(?<!\d)\d{4,8}(?!\d)');

  /// A message carries a code only when it says so: a receipt's order number
  /// is not something to type.
  static final _saysCode = RegExp(
    r'\b(code|pin|otp|passcode|verif\w*|one-time)\b',
    caseSensitive: false,
  );
  static final _link = RegExp(r'[a-z][a-z0-9+.-]*://[^\s<>"]+');

  /// Who asked for what [event] happened under: the person whose step it
  /// was, or the one the server identified the request as.
  String? _callerOf(_ServerEvent event) {
    if (event.step case var step?) return _steps[step]?.person;
    var user = _callers['${event.server}/${event.event.rid}'];
    return user == null ? null : _users[user];
  }

  /// `update · status ready · customer Ben`: what a write said beyond its
  /// table and key, a user the world knows by the person's name.
  String _written(Map<String, Object?> payload) => [
    '${payload['op']}',
    for (var MapEntry(:key, :value) in payload.entries)
      if (!const {'table', 'key', 'op', 'step'}.contains(key))
        '$key ${value is String ? _users[value] ?? _short(value) : value}',
  ].join(' · ');

  void _add<T>(List<T> list, T item) {
    list.add(item);
    if (list.length > cap) list.removeRange(0, list.length - cap);
  }

  List<TraceBeat> _beatsOf(TraceStep step) {
    var beats = <TraceBeat>[];
    var answered = <_ServerEvent>{};
    // Statements fold into the request they ran under — or, run outside
    // one (a job, an action's own), into one line per server.
    var statements = <String, List<_ServerEvent>>{};
    for (var event in _server) {
      if (event.step == step.id && event.channel == 'sql') {
        statements
            .putIfAbsent('${event.server}/${event.event.rid}', () => [])
            .add(event);
      }
    }
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
      var ran = served.event.rid == null
          ? null
          : statements.remove('${served.server}/${served.event.rid}');
      beats.add(
        TraceBeat(
          request.at,
          '${request.person} → ${served.server}  ${request.method} '
          '${request.path}  ${_answer(served.payload)}'
          '${ran == null ? '' : ', ${_ran(ran)}'}$how',
          person: request.person,
          node: _partNode(served),
          line: '${request.method} ${request.path}',
          folded: ran == null ? const [] : _statements(ran),
        ),
      );
    }
    for (var ran in statements.values) {
      var first = ran.first;
      beats.add(
        TraceBeat(
          first.time,
          '${first.server}  ${_ran(ran)}',
          node: _partNode(first),
          folded: _statements(ran),
        ),
      );
    }
    for (var event in _server) {
      if (event.step != step.id ||
          event.channel == 'sql' ||
          answered.contains(event)) {
        continue;
      }
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
    var how = event.byTime ? ', joined by time' : '';
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
          '$server → ${person ?? to} by SMS  ${payload['body']}$how',
          person: person,
          node: system?.sentNode('sms'),
          line: 'SMS',
          inbound: true,
        );
      case 'mail':
        var to = '${payload['to'] ?? ''}';
        var person = _emails[to.toLowerCase()];
        return TraceBeat(
          at,
          '$server → ${person ?? to} by mail  ${payload['subject']}$how',
          person: person,
          node: system?.sentNode('mail'),
          line: 'Mail',
          inbound: true,
        );
      case 'push':
        var to = payload['to'] ?? payload['user'];
        var person = personOf(to);
        var said = [?payload['title'], ?payload['body']].join(' — ');
        return TraceBeat(
          at,
          '$server → ${person ?? to} by push  $said$how',
          person: person,
          node: system?.sentNode('push'),
          line: '${payload['title'] ?? payload['body']}',
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
        return TraceBeat(
          at,
          '$server  $channel  ${_gist(payload)}',
          node: node,
        );
    }
  }

  /// What an event of a channel the trace has no words for said: a few of
  /// its fields, never a bare channel name.
  static String _gist(Map<String, Object?> payload) => [
    for (var MapEntry(:key, :value) in payload.entries)
      if (key != 'step' && (value is String || value is num || value is bool))
        '$key ${value is String ? foldSql(value) : value}',
  ].take(3).join(' · ');

  /// Whether a step before [event]'s already identified its user.
  bool _identifiedBefore(_ServerEvent event) => _server.any(
    (other) =>
        other.step != null &&
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

  /// A path with each UUID in it shortened as [_short] does.
  static String _shortPath(String path) =>
      path.replaceAllMapped(_uuidIn, (match) => match[0]!.substring(0, 8));

  static final _uuidIn = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  );

  /// The part of the API a request asked: its method, and the route the
  /// adapter named — `POST /orders/:id/advance` — or its path.
  static String _partOf(Map<String, Object?> payload) =>
      '${payload['method']} ${payload['part'] ?? payload['path']}';

  /// `12 statements, 9 ms`: what [ran] cost together.
  static String _ran(List<_ServerEvent> ran) {
    var ms = 0.0;
    for (var event in ran) {
      if (event.payload['ms'] case num spent) ms += spent;
    }
    var failed = ran.where((event) => event.payload['error'] != null).length;
    return [
      ran.length == 1 ? '1 statement' : '${ran.length} statements',
      if (ms > 0) '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms',
      if (failed > 0) '$failed failed',
    ].join(', ');
  }

  /// Each of [ran] on a line: its time, the statement, what it answered.
  static List<String> _statements(List<_ServerEvent> ran) => [
    for (var event in ran)
      [
        if (event.payload['ms'] case num ms)
          '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms',
        foldSql('${event.payload['query'] ?? event.payload['sql'] ?? ''}'),
        if (event.payload['rows'] case int rows)
          rows == 1 ? '1 row' : '$rows rows',
        if (event.payload['error'] case var error?) 'error: $error',
      ].join('  '),
  ];

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
  _ServerEvent(
    this.server,
    this.step,
    this.event, {
    String? reporter,
    this.byTime = false,
  }) : reporter = reporter ?? server;

  /// Whose it is on the canvas: the server that reported it, or the
  /// service a message says it came `from`.
  final String server;

  /// The process that reported it, whose ids [event]'s are.
  final String reporter;

  /// The step of a person in this world it happened under, if one.
  final String? step;

  /// Whether [step] was joined by time rather than carried.
  final bool byTime;
  final InspectorEvent event;

  /// `lab/42`: unique across the servers, whoever it is drawn as.
  String get id => '$reporter/${event.id}';

  String get channel => event.channel;
  Map<String, Object?> get payload => event.payload;
  DateTime get time => event.time;
}

class _Record {
  _Record(
    this.person,
    this.at,
    this.key,
    this.table,
    this.change, {
    this.op,
    this.bucket,
  });

  final String person;
  final DateTime at;
  final String key;
  final String table;
  final String change;
  final int? op;

  /// The sync engine's bucket it arrived in, when it says.
  final String? bucket;
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
    String? email,
    DeclaredLinks? links,
  }) async {
    trace.addPerson(
      person,
      userId: userId,
      phone: phone,
      email: email,
      links: links,
    );
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

  /// Asks [person]'s app [method] on [channel], over the connection the world
  /// already holds to it. Throws a [StateError] when there is none — their
  /// app is not running, or not answering yet.
  Future<Map<String, Object?>> ask(
    String person,
    String channel,
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    var app = _apps[person];
    if (app == null) {
      throw StateError("The world is not connected to $person's app.");
    }
    return app.client.request(channel, method, params);
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
