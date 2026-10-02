import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart' show mergeSort;
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
  /// `start` for the app starting, its `.0`; `action` for a world's own;
  /// `reload` for the world brought to the code on disk.
  String? verb;

  /// What it landed on, spelled as the drive targets are: `"Order"`.
  String? target;

  /// What the world says of it beyond what it did: a reload's times.
  String? note;

  /// What it did, in the journal's words: `tap "Order"`.
  String get did => '${verb ?? 'step'} ${target ?? ''}'.trim();
}

/// How far into the system a line of a trace goes. Watching a world, the
/// question is rarely what a part did, and more often whether someone got
/// something — which is [product]. Each level shows the ones above it too.
enum TraceLevel {
  /// What people do and what reaches someone else: a message sent outside,
  /// an update pushed to another person's app, a record arriving on it.
  product,

  /// The parts and the work passed between them: calls, jobs, an update
  /// pushed back to the app that asked for it.
  system,

  /// The plumbing: writes, statements, which user a request is, a record
  /// the sync engine confirmed to the phone that wrote it.
  wire;

  /// Whether a line at [other] is seen at this level.
  bool shows(TraceLevel other) => other.index <= index;
}

/// What a [TraceBeat] is, for a view that draws each kind its own way.
enum BeatKind {
  /// A request: one a person's app sent, or one a server answered for
  /// someone no app here is — the world's script, a callback.
  call,

  /// A job a server ran, and what it did within it.
  job,

  /// A write to a table, or a record's updates in a row.
  write,

  /// Statements, and writes to a table in a layer, run under no request:
  /// counted, a burst to a line.
  statements,

  /// A server learning which user a request is.
  identify,

  /// An update a server sent down a connection someone held open.
  reach,
  sms,
  mail,
  push,

  /// A synced record on a phone: written there, arrived, or confirmed.
  record,

  /// A phone subscribing to a sync bucket, or letting one go: the records
  /// written to it before arrive after it, however old.
  subscription,

  /// The world brought to the code on disk while the step was going: what
  /// was running then finishes on the old code. Its own step, `reload.2`,
  /// is where a view draws it.
  reload,
  log,
  error,

  /// A channel the trace has no words for.
  other,
}

/// One thing a step caused, somewhere in the world.
class TraceBeat {
  const TraceBeat(
    this.at,
    this.what, {
    required this.level,
    required this.kind,
    required this.said,
    this.server,
    this.data = const {},
    this.event,
    this.alone,
    this.person,
    this.node,
    this.line,
    this.inbound = false,
    this.folded = const [],
    this.children = const [],
  });

  final DateTime at;

  /// Where and what, in a line: `Ben → lab  POST /orders  201 in 12 ms`.
  final String what;

  /// What it says on a line of its own, where [what] leans on the line it
  /// is beneath to name the server: `lab → Cleo  order o3 · ready` for
  /// `→ Cleo  order o3 · ready`. Null when [what] says it all.
  final String? alone;

  /// The coarsest [TraceLevel] it is seen at.
  final TraceLevel level;
  final BeatKind kind;

  /// [what] without whom it passed between, which a timeline's columns
  /// draw: `POST /orders  201 in 12 ms`, `order o3 · ready`. A recipient
  /// the world does not know stays in it: no column is theirs.
  final String said;

  /// The server it happened on, that answered it or that sent it — `lab`,
  /// a service that mailed on its own, or the host of a request no server
  /// here answered; null for what happened on a phone alone.
  final String? server;

  /// What it was reported with, for whoever opens it: the server's event —
  /// a write's fields, a job's name — a request's method and address with
  /// the server's answer, a record's change as the phone reported it.
  final Map<String, Object?> data;

  /// The server's event it is, by the id `worlds deliver` takes: `lab/42`.
  /// Null for what no server reported alone — a request no server answered,
  /// a record on a phone, a line counting many.
  final String? event;

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

  /// What [what] counts rather than says, one line each, for whoever opens
  /// them: the statements a request ran, its writes to a table in a layer
  /// of its own, each write of a record updated many times in a row. A
  /// request that ran 23 statements is still one line.
  final List<String> folded;

  /// What happened within it — a request's or a job's writes, the messages
  /// it sent, whom it reached — each a beat of its own, beneath it.
  final List<TraceBeat> children;

  /// This line beneath one naming [server], which it then leaves out:
  /// [what] is `server  said` or `server → said`, and says `said` or
  /// `→ said`.
  TraceBeat _beneath(String server) => what.startsWith(server)
      ? _copy(what: what.substring(server.length).trimLeft(), alone: what)
      : this;

  TraceBeat _copy({
    String? what,
    String? alone,
    String? said,
    List<TraceBeat>? children,
  }) => TraceBeat(
    at,
    what ?? this.what,
    level: level,
    kind: kind,
    said: said ?? this.said,
    server: server,
    data: data,
    event: event,
    alone: alone,
    person: person,
    node: node,
    line: line,
    inbound: inbound,
    folded: folded,
    children: children ?? this.children,
  );
}

/// [beats] as seen at [level]: a line finer than it is left out, and what
/// happened within it rises into its place, in time with the rest, saying
/// what it leaned on that line for. At [TraceLevel.product] the SMS a
/// request sent is still seen, where the request is not, and names the
/// server itself; a record's arrival says what its hidden write brought.
List<TraceBeat> atLevel(List<TraceBeat> beats, TraceLevel level) => [
  for (var beat in _seenAt(beats, level))
    beat.alone == null ? beat : beat._copy(what: beat.alone),
];

List<TraceBeat> _seenAt(List<TraceBeat> beats, TraceLevel level) {
  var seen = [
    for (var beat in beats)
      if (level.shows(beat.level))
        beat._copy(
          what: beat.what,
          alone: beat.alone,
          children: _seenAt(beat.children, level),
        )
      else
        for (var risen in _seenAt(beat.children, level))
          risen.alone == null
              ? risen
              : risen._copy(what: risen.alone, alone: risen.alone),
  ];
  mergeSort(seen, compare: byMoment);
  return seen;
}

/// The order lines are read in: by when each happened, and at one moment a
/// subscription before the records it brought — the reason before what it
/// is the reason for — and otherwise as they were.
int byMoment(TraceBeat a, TraceBeat b) {
  var at = a.at.compareTo(b.at);
  if (at != 0) return at;
  int first(TraceBeat beat) => beat.kind == BeatKind.subscription ? 0 : 1;
  return first(a) - first(b);
}

/// [beats] and every beat beneath them, each after the one it is beneath.
Iterable<TraceBeat> everyBeat(Iterable<TraceBeat> beats) =>
    beatsByDepth(beats).map((entry) => entry.$1);

/// [beats] and every beat beneath them, with how deep each sits: 0 for a
/// step's own, 1 for what happened within one of those.
Iterable<(TraceBeat, int)> beatsByDepth(
  Iterable<TraceBeat> beats, [
  int depth = 0,
]) sync* {
  for (var beat in beats) {
    yield (beat, depth);
    yield* beatsByDepth(beat.children, depth + 1);
  }
}

/// [beats] as `worlds trace` prints them, offset from [since]: a line each,
/// what happened within one indented beneath it, and — with [folded] — what
/// a line counts, beneath it too.
List<String> traceLines(
  List<TraceBeat> beats,
  DateTime since, {
  bool folded = false,
  String indent = '',
}) => [
  for (var beat in beats) ...[
    '$indent+${beat.at.difference(since).inMilliseconds} ms  ${beat.what}',
    if (folded)
      for (var line in beat.folded) '$indent      $line',
    ...traceLines(beat.children, since, folded: folded, indent: '$indent  '),
  ],
];

/// How a wait for steps to settle ended: whether they did, how long it took,
/// and — when they did not — each job still running in them.
typedef TraceSettled = ({bool settled, Duration waited, List<String> running});

/// Waits until what [read] answers has not changed for [quiet], and no job in
/// it is still running — or until [timeout], whichever comes first.
///
/// What settles is the answer, not the world. A line, a count or a duration
/// changing in it starts the quiet again, and a step heard during the wait is
/// part of the answer, so a person's newest step arriving late is waited for
/// too. A job that began and has not ended keeps it open. What comes after
/// the quiet is not waited for, because nothing says it is coming: a sync
/// engine's next checkpoint, an app's debounce, a job queued for later.
Future<TraceSettled> settle(
  List<TracedStep> Function() read, {
  required Duration quiet,
  Duration timeout = const Duration(seconds: 30),
  Duration poll = const Duration(milliseconds: 200),
}) async {
  var watch = Stopwatch()..start();
  String? said;
  var changedAt = Duration.zero;
  while (true) {
    var traced = read();
    var now = [
      for (var (:step, :beats) in traced) ...[
        step.id,
        ...traceLines(beats, step.at!, folded: true),
      ],
    ].join('\n');
    var running = [
      for (var (:step, :beats) in traced)
        for (var beat in everyBeat(beats))
          if (beat.kind == BeatKind.job && beat.data['ms'] is! num)
            '${step.id}: ${beat.alone ?? beat.what}',
    ];
    if (now != said) {
      said = now;
      changedAt = watch.elapsed;
    } else if (running.isEmpty && watch.elapsed - changedAt >= quiet) {
      return (settled: true, waited: watch.elapsed, running: const <String>[]);
    }
    if (watch.elapsed >= timeout) {
      return (settled: false, waited: watch.elapsed, running: running);
    }
    await Future<void>.delayed(poll);
  }
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
  final _subscriptions = <_Subscription>[];
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

  /// Whether [person]'s app says it opens [link]: a scheme of its own, or a
  /// web host it claims — where a phone would send the link.
  bool claims(String person, String link) =>
      _links[person]?.claims(link) ?? false;

  /// The step [id] names — `leo.3`, `world.2` — if the world heard of it.
  TraceStep? step(String id) => _steps[id];

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

  /// The world brought to the code on disk at [at], as a step of its own —
  /// `reload.2` — which [note] says more of. A line after it ran the new
  /// code, but for work already running when it came, which finishes on the
  /// old: a moment in the trace says that where a mark on every line would
  /// be wrong. Answers the step's name.
  String addReload(DateTime at, {String? note}) {
    _owners[worldReloadPrefix] = worldActionsOwner;
    var id = '$worldReloadPrefix.${++_reloads}';
    _stepOf(id, worldActionsOwner)
      ..at = at
      ..verb = 'reload'
      ..target = 'the code'
      ..note = note;
    _changed.add(null);
    return id;
  }

  var _reloads = 0;

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
        if (payload['change'] case 'subscribed' || 'unsubscribed') {
          if (payload['bucket'] case String bucket) {
            _add(
              _subscriptions,
              _Subscription(
                person,
                event.time,
                bucket,
                subscribed: payload['change'] == 'subscribed',
              ),
            );
          }
          break;
        }
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
            newBucket: payload['newBucket'] == true,
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
    // A user the server knows by the phone or address a person was declared
    // with is them: an account a step made, whose own requests — a sync
    // engine's — carry no step to say whose.
    if (event.channel == 'identify' && event.payload['user'] is String) {
      var phone = event.payload['phone'];
      var email = event.payload['email'];
      var person =
          (phone is String ? _phones[phone] : null) ??
          (email is String ? _emails[email.toLowerCase()] : null);
      if (person != null) {
        _users.putIfAbsent(event.payload['user']! as String, () => person);
      }
    }
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

  /// The person a message went to, when the world knows whose its address
  /// is.
  String? _recipientOf(_ServerEvent event) {
    var to = '${event.payload['to'] ?? event.payload['user'] ?? ''}';
    return switch (event.channel) {
      'sms' => _phones[to],
      'mail' => _emails[to.toLowerCase()],
      _ => _users[to],
    };
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
              life: _lifeOf(table, key),
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

  /// Every record a phone received through the sync engine, by table and
  /// key — the ones a server here wrote; the rest are only counted.
  NodeContents _synced(int limit) {
    var latest = <String, _Record>{};
    for (var record in _records) {
      if (record.change == 'synced') {
        latest['${record.table}/${record.key}'] = record;
      }
    }
    bool written(_Record record) => _server.any(
      (event) => event.channel == 'write' && _sameRecord(event, record),
    );
    var unwritten = 0;
    var records = <TraceItem>[];
    for (var record in latest.values) {
      if (!written(record)) {
        unwritten++;
        continue;
      }
      records.add(
        TraceItem(
          record.at,
          record.table.isEmpty
              ? _short(record.key)
              : '${record.table}/${_short(record.key)}',
          detail: _holders(record.table, record.key),
          step: _causeOf(record),
          life: _lifeOf(record.table, record.key),
        ),
      );
    }
    records.sort((a, b) => b.at.compareTo(a.at));
    return NodeContents(
      node: syncNode,
      kind: NodeKind.sync,
      title: '',
      server: '',
      items: records.take(limit).toList(),
      earlier: max(0, records.length - limit),
      unwritten: unwritten,
    );
  }

  /// Whether some server here writes [table]: a phone table no server has
  /// is one the phone keeps under a name of its own.
  bool _serverHas(String table) =>
      _servers.values.any((server) => server.tables.containsKey(table));

  /// Whether [write], a server's, and [record], a phone's, are one record:
  /// the same key in the same table — or, for a phone table no server here
  /// has (`user_profiles` for the server's `users`), the same key in any.
  /// A side table whose rows take their parent's id is on both, and stays
  /// apart from its parent.
  bool _sameRecord(_ServerEvent write, _Record record) =>
      '${write.payload['key']}' == record.key &&
      (record.table.isEmpty ||
          '${write.payload['table']}' == record.table ||
          !_serverHas(record.table));

  /// Whether a phone's [record] belongs to the record [table]/[key], as
  /// [_sameRecord] joins them.
  bool _ofRecord(_Record record, String table, String key) =>
      record.key == key &&
      (record.table.isEmpty ||
          record.table == table ||
          !_serverHas(record.table) ||
          !_serverHas(table));

  /// `on Cleo's and Ben's phones`: whose phones a record reached.
  String _holders(String table, String key) {
    var people = {
      for (var record in _records)
        if (record.change == 'synced' && _ofRecord(record, table, key))
          record.person,
    }.toList();
    var names = people.map((person) => "$person's").toList();
    var spelled = names.length <= 1
        ? names.join()
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    return 'on $spelled ${people.length == 1 ? 'phone' : 'phones'}';
  }

  /// A record's whole life, by its table and key: each write the server
  /// reported, and each phone that wrote it itself or received it — oldest
  /// first. [table] is the server's or the phone's; a phone table no server
  /// has joins by key alone.
  List<TraceItem> _lifeOf(String table, String key) => [
    for (var event in _server)
      if (event.channel == 'write' &&
          '${event.payload['key']}' == key &&
          ('${event.payload['table']}' == table || !_serverHas(table)))
        TraceItem(
          event.time,
          '${event.server} wrote it',
          detail: _written(event.payload),
          step: event.step,
        ),
    for (var record in _records)
      if (_ofRecord(record, table, key)) _moment(record),
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
          if (bucket != null)
            record.newBucket ? 'in $bucket, new to this phone' : 'in $bucket',
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
    var person = _recipientOf(event);
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
      if (!_notWritten.contains(key))
        '$key ${value is String ? _users[value] ?? _short(value) : value}',
  ].join(' · ');

  /// What a write event says of itself rather than of its record.
  static const _notWritten = {'table', 'key', 'op', 'step', 'layer', 'level'};

  void _add<T>(List<T> list, T item) {
    list.add(item);
    if (list.length > cap) list.removeRange(0, list.length - cap);
  }

  List<TraceBeat> _beatsOf(TraceStep step) {
    var beats = <TraceBeat>[];
    // What each request and each job did, by its request id: beneath its
    // line. What ran under none — an action's own work between requests —
    // stays a line of its own.
    var groups = <String, List<_ServerEvent>>{};
    var loose = <_ServerEvent>[];
    for (var event in _server) {
      if (event.step != step.id) continue;
      if (event.group case var group?) {
        groups.putIfAbsent(group, () => []).add(event);
      } else {
        loose.add(event);
      }
    }
    // What an app sent from where the guest stamps nothing — another
    // isolate's HTTP client, a sync engine's streams — its start takes, by
    // who the server says asked and when.
    var claimed = step.verb == 'start'
        ? _startedBy(step)
        : const <String, List<_ServerEvent>>{};
    groups.addAll(claimed);
    var answered = <_ServerEvent>{};
    for (var request in _requests) {
      if (request.step != step.id) continue;
      var served = _served(request, answered);
      var how = request.window ? ', joined by time' : '';
      if (served == null) {
        // Unreported — a WebSocket upgrade, which shelf hands over by
        // throwing, or a server with no adapter — but named, when another
        // request to the same host was answered by a server that reports.
        var server = _hosts[request.host] ?? request.host;
        var said = '${request.method} ${request.path}$how';
        beats.add(
          TraceBeat(
            request.at,
            '${request.person} → $server  $said',
            level: TraceLevel.system,
            kind: BeatKind.call,
            said: said,
            server: server,
            data: request.data,
            person: request.person,
          ),
        );
        continue;
      }
      answered.add(served);
      beats.add(
        _grouped(
          request.at,
          '${request.person} → ${served.server}',
          '${request.method} ${request.path}  ${_answer(served.payload)}',
          groups.remove(served.group) ?? [served],
          kind: BeatKind.call,
          server: served.server,
          data: {...served.payload, ...request.data},
          event: served.id,
          how: how,
          person: request.person,
          node: _partNode(served),
          line: '${request.method} ${request.path}',
        ),
      );
    }
    for (var MapEntry(key: id, value: group) in groups.entries) {
      var theirs = claimed.containsKey(id);
      if (_serverGroup(
            group,
            person: theirs ? step.person : null,
            how: theirs ? ', joined by who and when' : '',
          )
          case var beat?) {
        beats.add(beat);
      }
    }
    beats.addAll(
      _looseBeats([
        for (var event in loose)
          if (!answered.contains(event)) event,
      ]),
    );
    // What a phone received sits beneath the write that sent it, where that
    // write is a line: the record's key and op say which. A write folded
    // into a count, or none found, leaves it a line of the step's own.
    var received = <(TraceBeat, _ServerEvent)>[];
    for (var record in _records) {
      if (_causeOf(record) != step.id) continue;
      var key = _short(record.key);
      var name = record.table.isEmpty ? key : '${record.table}/$key';
      var op = record.op == null ? '' : ' (op ${record.op})';
      var local = record.change.startsWith('local ');
      var confirmed = !local && record.person == step.person;
      var said = local
          ? 'wrote $name locally'
          : confirmed
          ? '$name confirmed$op'
          : '$name arrived$op';
      var write = local ? null : _writeOf(record);
      var beat = TraceBeat(
        record.at,
        '${record.person}  $said',
        // Beneath its write it says no more than which record: the write
        // says what it brought, until a level hides it.
        alone: write == null
            ? null
            : '${record.person}  $said · ${_written(write.payload)}',
        // Arriving on someone else's phone is what the step was for; the
        // writer's own copy coming back is the engine at work.
        level: local || confirmed ? TraceLevel.wire : TraceLevel.product,
        kind: BeatKind.record,
        said: said,
        data: {
          'table': record.table,
          'key': record.key,
          'change': record.change,
          'op': ?record.op,
          'bucket': ?record.bucket,
          if (record.newBucket) 'newBucket': true,
        },
        person: record.person,
        node: local ? null : syncNode,
        line: local ? null : '$name$op',
        inbound: !local,
      );
      if (write == null) {
        beats.add(beat);
      } else {
        received.add((beat, write));
      }
    }
    // A bucket is the step's whose write brought it its first record — the
    // join its records make, by key — and sits beneath that write. One no
    // such write explains is the person's step just before it, and says so.
    for (var subscription in _subscriptions) {
      var write = _subscribedBy(subscription);
      var byTime = write?.step == null;
      if (byTime
          ? _stepBy(subscription.person, subscription.at)?.id != step.id
          : write!.step != step.id) {
        continue;
      }
      var said =
          '${subscription.subscribed ? 'subscribed to' : 'let go of'} '
          '${subscription.bucket}${byTime ? ', joined by time' : ''}';
      var beat = TraceBeat(
        subscription.at,
        '${subscription.person}  $said',
        level: TraceLevel.system,
        kind: BeatKind.subscription,
        said: said,
        data: {
          'bucket': subscription.bucket,
          'change': subscription.subscribed ? 'subscribed' : 'unsubscribed',
          if (byTime) 'byTime': true,
        },
        person: subscription.person,
      );
      if (byTime) {
        beats.add(beat);
      } else {
        received.add((beat, write!));
      }
    }
    return _withReloads(step, _byTime(_beneathWrites(beats, received)));
  }

  /// The write that gave [subscription]'s bucket its first record on the
  /// phone — of the records the watch read with the bucket, the first by
  /// operation whose write a server reported — when one did.
  ///
  /// By operation, not by when each was heard: the watch reports a read's
  /// records at one moment, in table order, and the bucket's first record —
  /// the one a step wrote — may be the last of them, after side rows no
  /// server reports.
  _ServerEvent? _subscribedBy(_Subscription subscription) {
    if (!subscription.subscribed) return null;
    var read = [
      for (var record in _records)
        if (record.person == subscription.person &&
            record.bucket == subscription.bucket &&
            !record.change.startsWith('local ') &&
            !record.at.isBefore(subscription.at) &&
            record.at.difference(subscription.at) <= _sameRead)
          record,
    ];
    mergeSort(
      read,
      compare: (a, b) => switch ((a.op, b.op)) {
        (var x?, var y?) when x != y => x.compareTo(y),
        (_?, null) => -1,
        (null, _?) => 1,
        _ => a.at.compareTo(b.at),
      },
    );
    for (var record in read) {
      if (_writeOf(record) case var write?) return write;
    }
    return null;
  }

  /// How far apart the watch reports what it read at once.
  static const _sameRead = Duration(seconds: 2);

  /// [beats] with each reload that came while [step] was going — after it,
  /// before the last of what it caused ended — as a line in its place, and
  /// each line that was running when it came saying so: `done in 30.1 s,
  /// across reload.4`. What ran across a reload began on the old code.
  List<TraceBeat> _withReloads(TraceStep step, List<TraceBeat> beats) {
    var began = step.at;
    if (began == null || beats.isEmpty || step.verb == 'reload') return beats;
    DateTime endOf(TraceBeat beat) => switch (beat.data['ms']) {
      num ms => beat.at.add(Duration(microseconds: (ms * 1000).round())),
      _ => beat.at,
    };
    var ended = began;
    for (var beat in everyBeat(beats)) {
      if (endOf(beat).isAfter(ended)) ended = endOf(beat);
    }
    var reloads = [
      for (var reload in _steps.values)
        if (reload.verb == 'reload' &&
            reload.at != null &&
            reload.at!.isAfter(began) &&
            !reload.at!.isAfter(ended))
          reload,
    ];
    if (reloads.isEmpty) return beats;
    TraceBeat across(TraceBeat beat) {
      var children = [for (var child in beat.children) across(child)];
      var spanned = [
        for (var reload in reloads)
          if (reload.at!.isAfter(beat.at) && reload.at!.isBefore(endOf(beat)))
            reload.id,
      ];
      var mark = spanned.isEmpty ? '' : ', across ${spanned.join(', ')}';
      return beat._copy(
        what: '${beat.what}$mark',
        alone: beat.alone == null ? null : '${beat.alone}$mark',
        said: '${beat.said}$mark',
        children: children,
      );
    }

    return _byTime([
      for (var beat in beats) across(beat),
      for (var reload in reloads)
        TraceBeat(
          reload.at!,
          '${reload.id}  the code reloaded',
          // A moment of the whole world's, seen at every level.
          level: TraceLevel.product,
          kind: BeatKind.reload,
          said: 'the code reloaded',
          data: {'step': reload.id, 'note': ?reload.note},
        ),
    ]);
  }

  /// [person]'s newest step at or before [at]: what a phone did on its own
  /// after it — subscribing to a stream once signed in — is theirs.
  TraceStep? _stepBy(String person, DateTime at) {
    TraceStep? latest;
    for (var step in _steps.values) {
      var began = step.at;
      if (step.person != person || began == null || began.isAfter(at)) {
        continue;
      }
      if (latest == null || began.isAfter(latest.at!)) latest = step;
    }
    return latest;
  }

  /// [beats] in the order they happened ([byMoment]).
  static List<TraceBeat> _byTime(List<TraceBeat> beats) {
    mergeSort(beats, compare: byMoment);
    return beats;
  }

  /// [beats] with each of [received] beneath the line of the write that
  /// sent it — the last line writing its table and key at or before that
  /// write, which is its own or its record's run of updates — or beside
  /// them when no line is.
  List<TraceBeat> _beneathWrites(
    List<TraceBeat> beats,
    List<(TraceBeat, _ServerEvent)> received,
  ) {
    var writes = [
      for (var beat in everyBeat(beats))
        if (beat.kind == BeatKind.write) beat,
    ];
    var beneath = <TraceBeat, List<TraceBeat>>{};
    var beside = <TraceBeat>[];
    for (var (arrival, write) in received) {
      TraceBeat? line;
      for (var candidate in writes) {
        if (candidate.data['table'] == write.payload['table'] &&
            candidate.data['key'] == write.payload['key'] &&
            !candidate.at.isAfter(write.time) &&
            (line == null || candidate.at.isAfter(line.at))) {
          line = candidate;
        }
      }
      if (line == null) {
        beside.add(arrival);
      } else {
        beneath.putIfAbsent(line, () => []).add(arrival);
      }
    }
    if (beneath.isEmpty) return [...beats, ...beside];
    List<TraceBeat> place(List<TraceBeat> beats) => [
      for (var beat in beats)
        beat._copy(
          what: beat.what,
          alone: beat.alone,
          children: _byTime([...place(beat.children), ...?beneath[beat]]),
        ),
    ];
    return [...place(beats), ...beside];
  }

  /// A request or a job no app recorded — an action's request, a storage
  /// callback, a worker's job — as its [group] shows it: its own `http` or
  /// `job` event heads it, or its first event does. Null for one headed by
  /// neither that did nothing worth a line: the server's side of a live
  /// connection opening, whose only news is a user it already knew.
  ///
  /// A [person] it is known to be from — an app's request no guest stamped
  /// — is drawn as theirs, and [how] says how that is known.
  TraceBeat? _serverGroup(
    List<_ServerEvent> group, {
    String? person,
    String how = '',
  }) {
    var first = group.first;
    var server = first.server;
    // When it started: its report comes at its end, less how long it took —
    // never after what happened within it.
    DateTime began(_ServerEvent end, num? ms) {
      if (ms == null) return first.time;
      var start = end.time.subtract(
        Duration(microseconds: (ms * 1000).round()),
      );
      return start.isBefore(first.time) ? start : first.time;
    }

    for (var event in group) {
      if (event.channel == 'http') {
        var ms = event.payload['ms'];
        return _grouped(
          began(event, ms is num ? ms : null),
          person == null ? server : '$person → $server',
          '${event.payload['method']} ${event.payload['path']}  '
          '${_answer(event.payload)}',
          group,
          kind: BeatKind.call,
          server: server,
          data: event.payload,
          event: event.id,
          how: how,
          person: person,
          node: _partNode(event),
        );
      }
    }
    var jobs = [
      for (var event in group)
        if (event.channel == 'job') event,
    ];
    if (jobs.isNotEmpty) {
      var ended = jobs.where((job) => job.payload['ms'] is num).firstOrNull;
      var ms = ended?.payload['ms'] as num?;
      var error = ended?.payload['error'];
      return _grouped(
        ended == null || jobs.length > 1 ? jobs.first.time : began(ended, ms),
        server,
        [
          'job ${_jobName(jobs.first.payload)}',
          if (error != null)
            'failed after ${_duration(ms!)}: $error'
          else if (ms != null)
            'done in ${_duration(ms)}'
          else
            'running',
        ].join(', '),
        group,
        kind: BeatKind.job,
        server: server,
        data: {...jobs.first.payload, ...?ended?.payload},
        event: (ended ?? jobs.first).id,
        node: _partNode(first),
      );
    }
    var beat = _grouped(
      first.time,
      server,
      '',
      group,
      kind: BeatKind.call,
      server: server,
      node: _partNode(first),
    );
    return beat.children.isEmpty && beat.folded.isEmpty ? null : beat;
  }

  /// The requests and jobs no step claimed that [start] — an app's start,
  /// `ana.0` — takes, by their request id: each one its server said was
  /// [start]'s person asking (`identify`), begun while the start lasted —
  /// [worldStartWindow], or until that person's first gesture. What the
  /// guest stamps is in the app's own isolate; a sync engine's streams,
  /// opened from another, reach the server with the person's token and no
  /// step.
  Map<String, List<_ServerEvent>> _startedBy(TraceStep start) {
    var from = start.at;
    if (from == null) return const {};
    var until = from.add(worldStartWindow);
    for (var other in _steps.values) {
      var at = other.at;
      if (other.person == start.person &&
          at != null &&
          at.isAfter(from) &&
          at.isBefore(until)) {
        until = at;
      }
    }
    var stepless = <String, List<_ServerEvent>>{};
    for (var event in _server) {
      if (event.step != null) continue;
      if (event.group case var group?) {
        stepless.putIfAbsent(group, () => []).add(event);
      }
    }
    return {
      for (var MapEntry(key: group, value: events) in stepless.entries)
        if (!events.first.time.isBefore(from) &&
            events.first.time.isBefore(until) &&
            events.any(
              (event) =>
                  event.channel == 'identify' &&
                  _users['${event.payload['user']}'] == start.person,
            ))
          group: events,
    };
  }

  /// What a job is called: its name, and the queue it came off.
  static String _jobName(Map<String, Object?> payload) => [
    '${payload['name'] ?? payload['kind'] ?? payload['function'] ?? ''}',
    if (payload['queue'] case var queue?) 'on $queue',
  ].join(' ');

  static String _duration(num ms) => ms < 1000
      ? '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms'
      : '${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)} s';

  /// A line of [who] and what they [said], with what [group] did beneath
  /// it: its writes, the messages it sent, whom it reached. Its statements,
  /// and its writes to a table in a layer of its own — a job queue's — are
  /// counted on the line and folded behind it.
  TraceBeat _grouped(
    DateTime at,
    String who,
    String said,
    List<_ServerEvent> group, {
    required BeatKind kind,
    required String server,
    Map<String, Object?> data = const {},
    String? event,
    String how = '',
    String? person,
    String? node,
    String? line,
  }) {
    var statements = <_ServerEvent>[];
    var layered = <_ServerEvent>[];
    var beneath = <_ServerEvent>[];
    for (var event in group) {
      switch (event.channel) {
        case 'http' || 'job':
          break;
        case 'sql':
          statements.add(event);
        case 'write' when _layerOf(event) != null:
          layered.add(event);
        default:
          beneath.add(event);
      }
    }
    var counted = _counted(statements, layered);
    var all = [if (said.isNotEmpty) said, ?counted].join(', ') + how;
    return TraceBeat(
      at,
      all.isEmpty ? who : '$who  $all',
      level: TraceLevel.system,
      kind: kind,
      said: all,
      server: server,
      data: data,
      event: event,
      person: person,
      node: node,
      line: line,
      folded: [..._statements(statements), ..._writeLines(layered)],
      children: _merged(beneath),
    );
  }

  /// What ran under no request, as lines: its messages and writes each, and
  /// its statements and layered writes folded into one line for each burst
  /// of them — not one line for everything a server did over the step.
  List<TraceBeat> _looseBeats(List<_ServerEvent> loose) {
    var beats = <TraceBeat>[];
    var folding = <_ServerEvent>[];
    void flush() {
      if (folding.isEmpty) return;
      var statements = [
        for (var event in folding)
          if (event.channel == 'sql') event,
      ];
      var layered = [
        for (var event in folding)
          if (event.channel == 'write') event,
      ];
      var first = folding.first;
      var counted = _counted(statements, layered)!;
      beats.add(
        TraceBeat(
          first.time,
          '${first.server}  $counted',
          level: TraceLevel.wire,
          kind: BeatKind.statements,
          said: counted,
          server: first.server,
          node: _partNode(first),
          folded: [..._statements(statements), ..._writeLines(layered)],
        ),
      );
      folding = [];
    }

    var rest = <_ServerEvent>[];
    for (var event in loose) {
      var folds =
          event.channel == 'sql' ||
          (event.channel == 'write' && _layerOf(event) != null);
      if (!folds) {
        rest.add(event);
        continue;
      }
      if (folding.isNotEmpty &&
          (folding.last.reporter != event.reporter ||
              event.time.difference(folding.last.time) > _burst)) {
        flush();
      }
      folding.add(event);
    }
    flush();
    return beats..addAll(_merged(rest));
  }

  /// How far apart two statements run under no request can be and still
  /// count as one burst of work.
  static const _burst = Duration(seconds: 1);

  /// `12 statements, 6.1 ms, 4 writes in jobs`, or null for nothing.
  String? _counted(List<_ServerEvent> statements, List<_ServerEvent> layered) {
    var layers = <String, int>{};
    for (var write in layered) {
      var layer = _layerOf(write)!;
      layers[layer] = (layers[layer] ?? 0) + 1;
    }
    var counted = [
      if (statements.isNotEmpty) _ran(statements),
      for (var MapEntry(key: layer, value: n) in layers.entries)
        '${n == 1 ? '1 write' : '$n writes'} in $layer',
    ].join(', ');
    return counted.isEmpty ? null : counted;
  }

  String? _layerOf(_ServerEvent write) =>
      _servers[write.server]?.layers['${write.payload['table']}'];

  List<String> _writeLines(List<_ServerEvent> writes) => [
    for (var write in writes) _writeLine(write.payload),
  ];

  String _writeLine(Map<String, Object?> payload) =>
      'wrote ${payload['table']}/${_short(payload['key'])} '
      '(${_written(payload)})';

  /// [events] as lines, a record's updates in a row one line: a status
  /// moving through a queue is one record changing, not sixteen writes.
  List<TraceBeat> _merged(List<_ServerEvent> events) {
    var beats = <TraceBeat>[];
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var run = [event];
      while (_isUpdate(event) &&
          i + 1 < events.length &&
          _isUpdate(events[i + 1]) &&
          events[i + 1].payload['table'] == event.payload['table'] &&
          events[i + 1].payload['key'] == event.payload['key']) {
        run.add(events[++i]);
      }
      if (run.length == 1) {
        if (_serverBeat(event, nested: event.group != null) case var beat?) {
          beats.add(beat);
        }
        continue;
      }
      var table = '${event.payload['table']}';
      var said = [
        'updated $table/${_short(event.payload['key'])} ×${run.length}',
        if (_changes(run) case var changes when changes.isNotEmpty) changes,
      ].join(' · ');
      var updated = TraceBeat(
        event.time,
        '${event.server}  $said',
        level: _levelOf(run.last.payload),
        kind: BeatKind.write,
        said: said,
        server: event.server,
        data: run.last.payload,
        node: _servers[event.server]?.tableNode(table),
        folded: _writeLines(run),
      );
      beats.add(event.group == null ? updated : updated._beneath(event.server));
    }
    return beats;
  }

  /// The level a write says it is seen at — `level: system` for a row whose
  /// status is what a pipeline decided at each hand-off — or the wire's.
  static TraceLevel _levelOf(Map<String, Object?> write) =>
      TraceLevel.values.asNameMap()[write['level']] ?? TraceLevel.wire;

  static bool _isUpdate(_ServerEvent event) =>
      event.channel == 'write' && event.payload['op'] == 'update';

  /// What [writes] of one record changed, field by field: `status queued →
  /// building → ready`, a long run by its ends — `status queued → … → ready`.
  String _changes(List<_ServerEvent> writes) {
    var values = <String, List<String>>{};
    for (var write in writes) {
      for (var MapEntry(:key, :value) in write.payload.entries) {
        if (_notWritten.contains(key)) continue;
        var said =
            '${value is String ? _users[value] ?? _short(value) : value}';
        var seen = values.putIfAbsent(key, () => []);
        if (seen.isEmpty || seen.last != said) seen.add(said);
      }
    }
    return [
      for (var MapEntry(key: field, value: seen) in values.entries)
        switch (seen.length) {
          1 => '$field ${seen.single}',
          2 || 3 => '$field ${seen.join(' → ')}',
          _ => '$field ${seen.first} → … → ${seen.last}',
        },
    ].join(' · ');
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
    return _writeOf(record)?.step;
  }

  /// The server's write a record that arrived on a phone carries: the last
  /// of its table and key before it arrived.
  _ServerEvent? _writeOf(_Record record) {
    _ServerEvent? write;
    for (var event in _server) {
      if (event.channel != 'write' || !_sameRecord(event, record)) continue;
      if (event.time.isAfter(record.at)) continue;
      if (write == null || event.time.isAfter(write.time)) write = event;
    }
    return write;
  }

  /// [event] as a line of a step. [nested] beneath the request or job it
  /// happened in, which already names the server.
  TraceBeat? _serverBeat(_ServerEvent event, {bool nested = false}) {
    var beat = _serverLine(event);
    return nested ? beat?._beneath(event.server) : beat;
  }

  TraceBeat? _serverLine(_ServerEvent event) {
    var server = event.server;
    var payload = event.payload;
    var node = _partNode(event);
    var system = _servers[server];
    String? personOf(Object? user) => user is String ? _users[user] : null;
    var how = event.byTime ? ', joined by time' : '';
    // What the server did: `lab  wrote orders/o1 (insert)`.
    TraceBeat by(
      String said, {
      required BeatKind kind,
      required TraceLevel level,
      String? node,
    }) => TraceBeat(
      event.time,
      '$server  $said',
      level: level,
      kind: kind,
      said: said,
      server: server,
      data: payload,
      event: event.id,
      node: node,
    );
    // What reached [to], who is [person] if the world knows whose it is:
    // `lab → Leo by SMS  Your code is 1234`.
    TraceBeat toward(
      Object? to,
      String? person,
      String said, {
      required BeatKind kind,
      required String line,
      String via = '',
      TraceLevel level = TraceLevel.product,
      String? node,
    }) => TraceBeat(
      event.time,
      '$server → ${person ?? to}$via  $said',
      level: level,
      kind: kind,
      said: person == null ? '$to: $said' : said,
      server: server,
      data: payload,
      event: event.id,
      person: person,
      node: node,
      line: line,
      inbound: true,
    );
    switch (event.channel) {
      case 'http':
        return by(
          '${payload['method']} ${payload['path']}  ${_answer(payload)}',
          kind: BeatKind.call,
          level: TraceLevel.system,
          node: node,
        );
      case 'job':
        return by(
          'job ${_jobName(payload)}',
          kind: BeatKind.job,
          level: TraceLevel.system,
          node: node,
        );
      case 'identify':
        // Every request says who it is; only the first says something new,
        // and only of a user the script did not name — except under the
        // world's own action, whose step names nobody: there it says, once a
        // step, whom the action acted as.
        var user = '${payload['user']}';
        var acted = _steps[event.step]?.person == worldActionsOwner;
        if ((_declared.contains(user) && !acted) || _identifiedBefore(event)) {
          return null;
        }
        return by(
          'knows ${personOf(user) ?? 'someone'} as $user',
          kind: BeatKind.identify,
          level: TraceLevel.wire,
          node: node,
        );
      case 'reach':
        var user = payload['user'];
        var person = personOf(user);
        return toward(
          user,
          person,
          '${payload['what']}',
          kind: BeatKind.reach,
          line: '${payload['what']}',
          // An update back to whoever acted is their own app catching up;
          // one to anybody else is the step reaching them.
          level: person != null && person == _steps[event.step]?.person
              ? TraceLevel.system
              : TraceLevel.product,
          node: node,
        );
      case 'write':
        return by(
          _writeLine(payload),
          kind: BeatKind.write,
          level: _levelOf(payload),
          node: system?.tableNode('${payload['table']}'),
        );
      case 'sms':
        var to = payload['to'];
        return toward(
          to,
          _phones[to],
          '${payload['body']}$how',
          kind: BeatKind.sms,
          via: ' by SMS',
          line: 'SMS',
          node: system?.sentNode('sms'),
        );
      case 'mail':
        var to = '${payload['to'] ?? ''}';
        return toward(
          to,
          _emails[to.toLowerCase()],
          '${payload['subject']}$how',
          kind: BeatKind.mail,
          via: ' by mail',
          line: 'Mail',
          node: system?.sentNode('mail'),
        );
      case 'push':
        var to = payload['to'] ?? payload['user'];
        var said = [?payload['title'], ?payload['body']].join(' — ');
        return toward(
          to,
          personOf(to),
          '$said$how',
          kind: BeatKind.push,
          via: ' by push',
          line: '${payload['title'] ?? payload['body']}',
          node: system?.sentNode('push'),
        );
      case 'log':
        return by(
          '${payload['message']}',
          kind: BeatKind.log,
          level: TraceLevel.wire,
          node: node,
        );
      case 'error':
        return by(
          'error: ${payload['message'] ?? payload['error']}',
          kind: BeatKind.error,
          level: TraceLevel.system,
          node: node,
        );
      case 'info':
        return null;
      case var channel:
        // Words the trace has none for, so no level it could vouch for:
        // the middle one, rather than buried at the wire.
        return by(
          '$channel  ${_gist(payload)}',
          kind: BeatKind.other,
          level: TraceLevel.system,
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

  /// Whether a step before [event]'s already identified its user — or, for
  /// the world's own action, the same step did.
  bool _identifiedBefore(_ServerEvent event) {
    var acted = _steps[event.step]?.person == worldActionsOwner;
    return _server.any(
      (other) =>
          other.step != null &&
          (!acted || other.step == event.step) &&
          other.channel == 'identify' &&
          other.payload['user'] == event.payload['user'] &&
          other.time.isBefore(event.time),
    );
  }

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

  /// What a line of it is reported with.
  Map<String, Object?> get data => {
    'method': method,
    'path': path,
    'url': url,
    'how': window ? 'window' : 'zone',
  };

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

  /// `lab/42`: by whoever it is drawn as, and unique across the servers —
  /// a message another service sent names that service and the process
  /// that reported it, `identity/server-27`.
  String get id => server == reporter
      ? '$reporter/${event.id}'
      : '$server/$reporter-${event.id}';

  /// The request or job it happened in, across the servers — what gathers
  /// it beneath that request's line — or null outside one.
  String? get group => switch (event.rid) {
    var rid? => '$reporter/$rid',
    null => null,
  };

  String get channel => event.channel;
  Map<String, Object?> get payload => event.payload;
  DateTime get time => event.time;
}

/// A phone subscribing to a sync bucket, or letting one go.
class _Subscription {
  _Subscription(this.person, this.at, this.bucket, {required this.subscribed});

  final String person;
  final DateTime at;
  final String bucket;
  final bool subscribed;
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
    this.newBucket = false,
  });

  final String person;
  final DateTime at;
  final String key;
  final String table;
  final String change;
  final int? op;

  /// The sync engine's bucket it arrived in, when it says.
  final String? bucket;

  /// Whether [bucket] was new to the phone: a stream the app had just
  /// subscribed to, which is why a record written long ago arrives now.
  final bool newBucket;
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

  /// Starts hearing [person]'s app, which says it opens [links]. Who they
  /// are is [WorldTrace.addPerson]'s, from when the script declared them:
  /// a person with no app is never followed.
  Future<void> follow(
    String person,
    RunHandle handle, {
    DeclaredLinks? links,
  }) async {
    if (links != null) trace.addPerson(person, links: links);
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
