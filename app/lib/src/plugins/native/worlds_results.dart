import 'package:flutterware/plugins.dart';

import '../../world/open_world.dart';
import '../../world/world_files.dart';

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
          for (var person in world.people.values) WorldPersonEntry.of(person),
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
  });

  factory WorldPersonEntry.of(WorldPerson person) => WorldPersonEntry(
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
  };
}

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
    this.progress,
    this.error,
  });

  factory WorldActionResult.of(WorldActionRun run) => WorldActionResult(
    action: run.action,
    run: run.id,
    running: run.running,
    progress: run.progress,
    error: run.error,
  );

  factory WorldActionResult.fromJson(Map<String, Object?> json) =>
      WorldActionResult(
        action: json['action']! as String,
        run: json['run']! as int,
        running: json['running']! as bool,
        progress: json['progress'] as String?,
        error: json['error'] as String?,
      );

  final String action;
  final int run;

  /// Still going when the wait ran out; `worlds status` shows how far.
  final bool running;

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
    'progress': ?progress,
    'error': ?error,
  };
}
