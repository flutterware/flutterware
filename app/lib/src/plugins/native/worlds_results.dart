import 'package:flutterware/plugins.dart';

import '../../world/open_world.dart';
import '../../world/world_files.dart';
import '../../world/web_snapshot.dart';
import '../../world/world_trace.dart';

/// What `worlds list` answers: every world the project declares, and which
/// one is open here.
class WorldListResult implements PluginResult {
  const WorldListResult({required this.worlds, this.open});

  final List<WorldListEntry> worlds;

  /// The id of the world open in this process, if one is.
  final String? open;

  @override
  Map<String, Object?> toJson() => {
    'worlds': [for (var world in worlds) world.toJson()],
    'open': ?open,
  };
}

class WorldListEntry {
  const WorldListEntry({
    required this.id,
    required this.name,
    required this.package,
    required this.path,
    this.description,
  });

  WorldListEntry.of(WorldFile file)
    : this(
        id: file.id,
        name: file.name,
        package: file.package,
        path: file.path,
        description: file.description,
      );

  /// What `worlds open` takes.
  final String id;
  final String name;
  final String package;
  final String path;
  final String? description;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'package': package,
    'path': path,
    'description': ?description,
  };
}

/// A world as it stands: its people and where their apps are, what it can
/// do, and what its script said last. What `open`, `restart`, `status` and
/// `close` answer.
class WorldStateResult implements PluginResult, ReportsFailure {
  const WorldStateResult({
    required this.world,
    required this.name,
    required this.phase,
    this.id,
    this.problem,
    this.people = const [],
    this.actions = const [],
    this.knobs = const [],
    this.log = const [],
    this.note,
  });

  factory WorldStateResult.of(OpenWorld world, {String? note}) =>
      WorldStateResult(
        world: world.file.id,
        name: world.file.name,
        phase: world.phase.name,
        id: world.id,
        problem: world.problem,
        people: [
          for (var person in world.people.values)
            WorldPersonEntry.of(
              person,
              sync: world.tracer?.syncOf(person.name),
            ),
        ],
        actions: [
          for (var MapEntry(:key, :value) in world.actions.entries)
            WorldActionEntry(key, description: value),
        ],
        knobs: [
          for (var knob in world.knobs.values)
            WorldKnobEntry(knob.name, knob.value, options: knob.options),
        ],
        log: world.log.length > 20
            ? world.log.sublist(world.log.length - 20)
            : [...world.log],
        note: note,
      );

  /// [toJson] read back: the answer of a world another process owns.
  factory WorldStateResult.fromJson(
    Map<String, Object?> json, {
    String? note,
  }) => WorldStateResult(
    world: json['world']! as String,
    name: json['name']! as String,
    phase: json['phase']! as String,
    id: json['id'] as String?,
    problem: json['problem'] as String?,
    people: [
      for (var person in json['people'] as List? ?? const [])
        WorldPersonEntry.fromJson((person as Map).cast()),
    ],
    actions: [
      for (var action in json['actions'] as List? ?? const [])
        if (action case {'name': String name})
          WorldActionEntry(name, description: action['description'] as String?),
    ],
    knobs: [
      for (var knob in json['knobs'] as List? ?? const [])
        if (knob case {'name': String name, 'value': String value})
          WorldKnobEntry(
            name,
            value,
            options: [...(knob['options'] as List? ?? const []).cast<String>()],
          ),
    ],
    log: [...(json['log'] as List? ?? const []).cast<String>()],
    note: note ?? json['note'] as String?,
  );

  /// The world's id, what `worlds open` took.
  final String world;
  final String name;

  /// `opening`, `open`, `restarting`, `failed`, `closing` or `closed`.
  final String phase;

  /// This opening's id — what the script's emails and names carry.
  final String? id;

  /// Why it failed.
  final String? problem;
  final List<WorldPersonEntry> people;
  final List<WorldActionEntry> actions;
  final List<WorldKnobEntry> knobs;

  /// The script's last lines: its progress, and what it printed.
  final List<String> log;

  /// A word about what to do next.
  final String? note;

  @override
  bool get ok =>
      phase != WorldPhase.failed.name &&
      people.every((person) => person.phase != PersonPhase.failed.name);

  @override
  Map<String, Object?> toJson() => {
    'world': world,
    'name': name,
    'phase': phase,
    'id': ?id,
    'problem': ?problem,
    'people': [for (var person in people) person.toJson()],
    if (actions.isNotEmpty)
      'actions': [for (var action in actions) action.toJson()],
    if (knobs.isNotEmpty) 'knobs': [for (var knob in knobs) knob.toJson()],
    if (log.isNotEmpty) 'log': log,
    'note': ?note,
  };
}

/// One person, and how to reach their app.
class WorldPersonEntry {
  const WorldPersonEntry({
    required this.name,
    required this.phase,
    this.device,
    this.run,
    this.app,
    this.email,
    this.phone,
    this.userId,
    this.password,
    this.knobs = const {},
    this.problem,
    this.sync,
  });

  factory WorldPersonEntry.of(
    WorldPerson person, {
    Map<String, Object?>? sync,
  }) => WorldPersonEntry(
    name: person.name,
    phase: person.phase.name,
    device: person.spec.app == null ? null : person.handle?.device,
    run: person.runKey,
    app: person.spec.app?.entrypoint,
    email: person.spec.email,
    phone: person.spec.phone,
    userId: person.spec.userId,
    password: person.spec.password,
    knobs: person.knobs,
    problem: person.problem,
    sync: sync == null ? null : syncLine(sync),
  );

  factory WorldPersonEntry.fromJson(Map<String, Object?> json) =>
      WorldPersonEntry(
        name: json['name']! as String,
        phase: json['phase']! as String,
        device: json['device'] as String?,
        run: json['run'] as String?,
        app: json['app'] as String?,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        userId: json['userId'] as String?,
        password: json['password'] as String?,
        knobs: (json['knobs'] as Map? ?? const {}).cast(),
        problem: json['problem'] as String?,
        sync: json['sync'] as String?,
      );

  final String name;

  /// `building`, `starting`, `running`, `headless` or `failed`.
  final String phase;

  /// Their app's device to Run — `studio-ana` — which `flutterware_act`
  /// takes as `device`.
  final String? device;

  /// Their app's run key.
  final String? run;

  /// The entry point their app is.
  final String? app;
  final String? email;
  final String? phone;
  final String? userId;
  final String? password;

  /// What their app was started with.
  final Map<String, Object?> knobs;

  /// Why they are `failed`.
  final String? problem;

  /// Where their app's synced database stands — `PowerSync: synced 2 s ago,
  /// 1 to upload` — for an app whose database panel reads one.
  final String? sync;

  Map<String, Object?> toJson() => {
    'name': name,
    'phase': phase,
    'device': ?device,
    'run': ?run,
    'app': ?app,
    'email': ?email,
    'phone': ?phone,
    'userId': ?userId,
    'password': ?password,
    if (knobs.isNotEmpty) 'knobs': knobs,
    'problem': ?problem,
    'sync': ?sync,
  };
}

/// A database panel's `sync` state in a line: `PowerSync: synced 2 s ago,
/// 1 to upload`.
String syncLine(Map<String, Object?> state, {DateTime? now}) {
  var engine = switch (state['engine']) {
    'powersync' => 'PowerSync',
    var other => '${other ?? 'Sync'}',
  };
  var synced = switch (state['lastSyncedAt']) {
    String at when DateTime.tryParse(at) != null =>
      'synced ${_ago((now ?? DateTime.now()).difference(DateTime.parse(at)))}',
    _ => 'not synced yet',
  };
  var pending = state['pendingUploads'];
  return '$engine: $synced'
      '${pending is int && pending > 0 ? ', $pending to upload' : ''}';
}

String _ago(Duration age) => switch (age.inSeconds) {
  < 1 => 'just now',
  < 60 => '${age.inSeconds} s ago',
  < 3600 => '${age.inMinutes} min ago',
  _ => '${age.inHours} h ago',
};

class WorldActionEntry {
  const WorldActionEntry(this.name, {this.description});

  final String name;
  final String? description;

  Map<String, Object?> toJson() => {'name': name, 'description': ?description};
}

class WorldKnobEntry {
  const WorldKnobEntry(this.name, this.value, {this.options = const []});

  final String name;
  final String value;
  final List<String> options;

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    if (options.isNotEmpty) 'options': options,
  };
}

/// What `worlds invoke` answers: the action, ended or still running.
class WorldActionResult implements PluginResult, ReportsFailure {
  const WorldActionResult({
    required this.action,
    required this.run,
    required this.running,
    this.step,
    this.progress,
    this.error,
  });

  factory WorldActionResult.of(WorldActionRun run) => WorldActionResult(
    action: run.action,
    run: run.id,
    running: run.running,
    step: run.step,
    progress: run.progress,
    error: run.error,
  );

  factory WorldActionResult.fromJson(Map<String, Object?> json) =>
      WorldActionResult(
        action: json['action']! as String,
        run: json['run']! as int,
        running: json['running']! as bool,
        step: json['step'] as String?,
        progress: json['progress'] as String?,
        error: json['error'] as String?,
      );

  final String action;
  final int run;

  /// Still going when the wait ran out; `worlds status` shows how far.
  final bool running;

  /// The step it ran as — `world.2` — what `worlds trace` takes as `step`
  /// for what it caused.
  final String? step;

  /// The last thing it said about how far it is.
  final String? progress;
  final String? error;

  @override
  bool get ok => error == null;

  @override
  Map<String, Object?> toJson() => {
    'action': action,
    'run': run,
    'running': running,
    'step': ?step,
    'progress': ?progress,
    'error': ?error,
  };
}

/// What `worlds trace` answers: the newest steps taken on the people's apps,
/// each with what it caused — the requests it sent, what the servers did
/// under them, and where the records it wrote arrived.
class WorldTraceResult implements PluginResult {
  const WorldTraceResult({required this.steps, this.note});

  factory WorldTraceResult.of(
    List<TracedStep> traced, {
    String? note,
  }) => WorldTraceResult(
    steps: [
      for (var (:step, :beats) in traced)
        WorldTraceStep(
          step: step.id,
          person: step.person,
          at: step.at!,
          did: step.did,
          then: [
            for (var beat in beats)
              '+${beat.at.difference(step.at!).inMilliseconds} ms  ${beat.what}',
          ],
        ),
    ],
    note: note,
  );

  factory WorldTraceResult.fromJson(Map<String, Object?> json) =>
      WorldTraceResult(
        steps: [
          for (var step in json['steps'] as List? ?? const [])
            WorldTraceStep.fromJson((step as Map).cast()),
        ],
        note: json['note'] as String?,
      );

  /// Oldest first.
  final List<WorldTraceStep> steps;
  final String? note;

  @override
  Map<String, Object?> toJson() => {
    'steps': [for (var step in steps) step.toJson()],
    'note': ?note,
  };
}

class WorldTraceStep {
  const WorldTraceStep({
    required this.step,
    required this.person,
    required this.at,
    required this.did,
    this.then = const [],
  });

  factory WorldTraceStep.fromJson(Map<String, Object?> json) => WorldTraceStep(
    step: json['step']! as String,
    person: json['person']! as String,
    at: DateTime.parse(json['at']! as String),
    did: json['did']! as String,
    then: [...(json['then'] as List? ?? const []).cast<String>()],
  );

  /// The app's name for it — `ben.3` — what `worlds trace` takes as `step`.
  final String step;
  final String person;
  final DateTime at;

  /// `tap "Order"`.
  final String did;

  /// What it caused, each line its offset from the step and where it
  /// happened: `+29 ms  Ben → lab  POST /orders  201 in 3 ms`.
  final List<String> then;

  Map<String, Object?> toJson() => {
    'step': step,
    'person': person,
    'at': at.toIso8601String(),
    'did': did,
    if (then.isNotEmpty) 'then': then,
  };
}

/// What `worlds contents` answers: what one part of the system holds, as the
/// world heard it — or, asked for none, every part there is to ask about.
class WorldContentsResult implements PluginResult {
  const WorldContentsResult({
    this.part,
    this.items = const [],
    this.more = 0,
    this.parts = const [],
    this.note,
  });

  factory WorldContentsResult.of(
    NodeContents contents, {
    required String part,
  }) => WorldContentsResult(
    part: part,
    items: [
      for (var item in contents.items)
        WorldContentsItem(
          at: item.at,
          title: item.title,
          detail: item.detail,
          person: item.person,
          step: item.step,
          life: [
            for (var moment in item.life)
              [
                '+${moment.at.difference(item.life.first.at).inMilliseconds} ms',
                moment.title,
                ?moment.detail,
                if (moment.step case var step?) '($step)',
              ].join('  '),
          ],
        ),
    ],
    more: contents.earlier + contents.unwritten,
    note: switch (contents.unwritten) {
      0 => null,
      var n =>
        '$n more records arrived that no server here reported writing: '
            'older than the world, or written where no adapter reports.',
    },
  );

  factory WorldContentsResult.fromJson(Map<String, Object?> json) =>
      WorldContentsResult(
        part: json['part'] as String?,
        items: [
          for (var item in json['items'] as List? ?? const [])
            WorldContentsItem.fromJson((item as Map).cast()),
        ],
        more: json['more'] as int? ?? 0,
        parts: [...(json['parts'] as List? ?? const []).cast<String>()],
        note: json['note'] as String?,
      );

  /// The part asked about, as `part` named it.
  final String? part;

  /// Newest first.
  final List<WorldContentsItem> items;

  /// How many more it holds than [items] lists.
  final int more;

  /// Asked for no part: every part there is, as `part` takes it.
  final List<String> parts;
  final String? note;

  @override
  Map<String, Object?> toJson() => {
    'part': ?part,
    if (items.isNotEmpty) 'items': [for (var item in items) item.toJson()],
    if (more > 0) 'more': more,
    if (parts.isNotEmpty) 'parts': parts,
    'note': ?note,
  };
}

/// One call, record or message a part holds.
class WorldContentsItem {
  const WorldContentsItem({
    required this.at,
    required this.title,
    this.detail,
    this.person,
    this.step,
    this.life = const [],
  });

  factory WorldContentsItem.fromJson(Map<String, Object?> json) =>
      WorldContentsItem(
        at: DateTime.parse(json['at']! as String),
        title: json['title']! as String,
        detail: json['detail'] as String?,
        person: json['person'] as String?,
        step: json['step'] as String?,
        life: [...(json['life'] as List? ?? const []).cast<String>()],
      );

  final DateTime at;

  /// The path asked, the record's key, whom a message went to.
  final String title;

  /// `200 in 5.6 ms`, `update · status ready`, the message.
  final String? detail;

  /// Who asked, who wrote it last, whom it reached.
  final String? person;

  /// The step that caused it — what `worlds trace` takes as `step`.
  final String? step;

  /// A record's life, oldest first, each line its offset from the first:
  /// `+21 ms  arrived on Cleo's phone  op 38  (ben.1)`.
  final List<String> life;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'title': title,
    'detail': ?detail,
    'person': ?person,
    'step': ?step,
    if (life.isNotEmpty) 'life': life,
  };
}

/// What `worlds outbox` answers: the messages the servers sent outside,
/// newest first, each with what a delivery would hand its recipient's app.
class WorldOutboxResult implements PluginResult {
  const WorldOutboxResult({required this.messages, this.note});

  factory WorldOutboxResult.of(List<OutboxMessage> messages, {String? note}) =>
      WorldOutboxResult(
        messages: [
          for (var message in messages)
            {
              'id': message.id,
              'at': message.at.toIso8601String(),
              'kind': message.kind,
              'to': message.to,
              'person': ?message.person,
              'text': message.text,
              'code': ?message.code,
              'link': ?message.link,
              if (message.links.length > 1) 'links': message.links,
              if (message.html != null) 'html': true,
              'step': ?message.step,
            },
        ],
        note: note,
      );

  factory WorldOutboxResult.fromJson(Map<String, Object?> json) =>
      WorldOutboxResult(
        messages: [
          for (var message in json['messages'] as List? ?? const [])
            (message as Map).cast<String, Object?>(),
        ],
        note: json['note'] as String?,
      );

  /// `{id, at, kind, to, person?, text, code?, link?, links?, html?, step?}` —
  /// `id` is what `worlds deliver` and `worlds show` take; `html: true` says
  /// `worlds show` draws it as its recipient would see it.
  final List<Map<String, Object?>> messages;
  final String? note;

  @override
  Map<String, Object?> toJson() => {'messages': messages, 'note': ?note};
}

/// What `worlds deliver` answers: what it handed to whose app.
class WorldDeliveryResult implements PluginResult {
  const WorldDeliveryResult({
    required this.message,
    required this.person,
    required this.how,
    required this.what,
  });

  factory WorldDeliveryResult.of(WorldDelivery delivery) => WorldDeliveryResult(
    message: delivery.message,
    person: delivery.person,
    how: delivery.how,
    what: delivery.what,
  );

  factory WorldDeliveryResult.fromJson(Map<String, Object?> json) =>
      WorldDeliveryResult(
        message: json['message']! as String,
        person: json['person']! as String,
        how: json['how']! as String,
        what: json['what']! as String,
      );

  final String message;
  final String person;

  /// `type` — the code went into the field that had focus — or `open`.
  final String how;

  /// The code typed, or the link opened.
  final String what;

  @override
  Map<String, Object?> toJson() => {
    'message': message,
    'person': person,
    'how': how,
    'what': what,
  };
}

/// What `worlds show` answers: a message drawn as its recipient would see it
/// — a PNG to read — and where each of its links is on it.
class WorldShowResult implements PluginResult {
  const WorldShowResult({
    required this.message,
    required this.picture,
    required this.width,
    required this.height,
    this.links = const [],
  });

  factory WorldShowResult.of(String message, WebSnapshot page) =>
      WorldShowResult(
        message: message,
        picture: page.picture,
        width: page.width,
        height: page.height,
        links: [
          for (var link in page.links)
            {
              'href': link.href,
              'text': link.text,
              'box': [link.left, link.top, link.width, link.height],
            },
        ],
      );

  factory WorldShowResult.fromJson(Map<String, Object?> json) =>
      WorldShowResult(
        message: json['message']! as String,
        picture: json['picture']! as String,
        width: (json['width']! as num).toDouble(),
        height: (json['height']! as num).toDouble(),
        links: [
          for (var link in json['links'] as List? ?? const [])
            (link as Map).cast<String, Object?>(),
        ],
      );

  final String message;

  /// The PNG, at twice the page's size.
  final String picture;

  /// The page's size in points, the space [links] are in.
  final double width;
  final double height;

  /// `{href, text, box: [x, y, width, height]}`.
  final List<Map<String, Object?>> links;

  @override
  Map<String, Object?> toJson() => {
    'message': message,
    'picture': picture,
    'width': width,
    'height': height,
    if (links.isNotEmpty) 'links': links,
  };
}
