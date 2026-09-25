import 'dart:async';
import 'dart:typed_data';

import 'package:flutterware/devices.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/protocol.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/world.dart';
import 'package:path/path.dart' as p;

import '../embedder/flutter_cache.dart';
import '../run/entrypoint_knobs.dart';
import '../run/handle.dart';
import '../session/job.dart';
import 'app_guest.dart';
import 'guest_launcher.dart';
import 'guest_log.dart';
import 'guest_process.dart';
import 'platform/studio_platform.dart';
import 'world_files.dart';
import 'world_script.dart';

/// A world while it is open, from its owner's side: the script, one build per
/// app its people use, and a guest per person — announced to Run as that
/// person's device, and reloaded and restarted by this, standing in for the
/// `flutter run` a guest does not have.
///
/// Flutter-free, so `fw` and the MCP server own a world the way the studio
/// does. What differs is only where a guest draws: [WorldGuest] is headless
/// for them and a live texture in the studio.
class OpenWorld {
  OpenWorld({
    required this.file,
    required this.worktree,
    required this.flutterSdkRoot,
    required this.appRoot,
    required this.entrypoints,
    required this.guests,
    this.onChanged,
    this.buildRoot,
  });

  final WorldFile file;

  /// The worktree's absolute path — [WorldFile.package] and every entry
  /// point's package are relative to it.
  final String worktree;
  final String flutterSdkRoot;

  /// The `flutterware_app` package root, where the guest host is built.
  final String appRoot;

  /// Run's entry points, every package's — what a person's `Launch` names.
  final List<WorldEntrypoint> entrypoints;

  /// A new, not yet started guest for a person.
  final WorldGuest Function(String person) guests;

  /// Called whenever anything below changes.
  final void Function()? onChanged;

  /// Where each app's guest build goes; its package's own `build/` when null.
  final String? buildRoot;

  WorldPhase phase = WorldPhase.opening;

  /// Why the world is [WorldPhase.failed].
  String? problem;

  /// This opening's id, from the script.
  String? id;

  /// What it was last opened with.
  Map<String, Object?> knobValues = const {};

  final people = <String, WorldPerson>{};
  final actions = <String, String?>{};
  final knobs = <String, WorldKnob>{};
  final runs = <int, WorldActionRun>{};

  /// The script's progress and what it printed, newest last.
  final log = <String>[];

  /// Each line of [log] as it is said.
  Stream<String> get lines => _lines.stream;
  final _lines = StreamController<String>.broadcast(sync: true);

  late final _cache = FlutterCache(p.join(flutterSdkRoot, 'bin', 'cache'));
  late final Future<String> _host = ensureGuestHost(_cache, appRoot);
  final _builds = <String, _Build>{};
  WorldScriptProcess? _script;
  var _nextRun = 1;
  Completer<void>? _settled;
  var _seeded = false;

  /// Opens the world with [knobs] and answers once every person's app is up,
  /// or has failed, or the script has.
  Future<void> open([Map<String, Object?> knobs = const {}]) async {
    phase = WorldPhase.opening;
    await _run(knobs);
  }

  /// Closes the script and runs it again — new people, new knobs — and
  /// restarts each person's app in place with what the script now says.
  /// People it no longer declares go; new ones start.
  Future<void> restart([Map<String, Object?>? knobs]) async {
    phase = WorldPhase.restarting;
    _changed();
    await _script?.close();
    await _run(knobs ?? knobValues);
  }

  /// Runs [action] and answers when it ends, or after [wait] with it still
  /// running.
  Future<WorldActionRun> invoke(
    String action, {
    Duration wait = const Duration(seconds: 30),
  }) async {
    var script = _script;
    if (script == null || phase != WorldPhase.open) {
      throw WorldRefusal(
        '${file.name} is ${phase.name}; its actions run once it is open.',
      );
    }
    if (!actions.containsKey(action)) {
      throw WorldRefusal(
        '${file.name} has no action "$action". '
        '${actions.isEmpty ? 'It declares none.' : 'It has: ${actions.keys.join(', ')}.'}',
      );
    }
    var run = WorldActionRun(_nextRun++, action);
    runs[run.id] = run;
    script.send(WorldMessage.invoke, {'action': action, 'run': run.id});
    _changed();
    await run._ended.future.timeout(wait, onTimeout: () {});
    return run;
  }

  /// Stops an action that is still running.
  void cancel(int run) => _script?.send(WorldMessage.cancel, {'run': run});

  /// Closes the script — its `onClose` runs — and stops every person's app.
  Future<void> close() async {
    phase = WorldPhase.closing;
    _changed();
    await _script?.close();
    _script = null;
    await Future.wait([for (var person in people.values) person._stop()]);
    people.clear();
    await Future.wait([for (var build in _builds.values) build.app.dispose()]);
    _builds.clear();
    phase = WorldPhase.closed;
    _changed();
    await _lines.close();
  }

  Future<void> _run(Map<String, Object?> knobs) async {
    knobValues = knobs;
    problem = null;
    id = null;
    actions.clear();
    this.knobs.clear();
    runs.clear();
    var declared = <String>{};
    var settled = _settled = Completer<void>();
    var setUp = false;
    var clock = Stopwatch()..start();

    void settle() {
      if (!setUp || settled.isCompleted) return;
      if (people.values.any((person) => person.phase.isMoving)) return;
      _script?.send(WorldMessage.ready);
      if (phase != WorldPhase.failed) phase = WorldPhase.open;
      _say(
        '${phase == WorldPhase.open ? 'Open' : 'Settled'} in '
        '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
      );
      settled.complete();
      _changed();
      // Once, with the world up: the shared half of each app's program, left
      // for the next checkout's first open. Not before — it queues on the
      // compiler every reload goes through.
      if (!_seeded) {
        _seeded = true;
        for (var build in _builds.values) {
          unawaited(build.app.writeSeed().catchError((Object _) => null));
        }
      }
    }

    _say('Starting ${file.path}');
    WorldScriptProcess script;
    try {
      script = _script = await WorldScriptProcess.start(
        dart: p.join(flutterSdkRoot, 'bin', 'dart'),
        packageRoot: p.join(worktree, file.package),
        file: file.path,
        knobs: knobs,
        onOutput: _say,
      );
    } on Object catch (error) {
      _fail('$error');
      return;
    }
    unawaited(
      script.process.exitCode.then((code) {
        // Gone on its own, not closed: whatever it was hosting went with it.
        if (_script == script &&
            phase != WorldPhase.closing &&
            phase != WorldPhase.restarting) {
          _fail('The world script exited ($code).');
          if (!settled.isCompleted) settled.complete();
        }
      }),
    );
    script.messages.listen((message) {
      switch (message['type']) {
        case WorldMessage.hello:
          if (message['protocol'] != worldProtocolVersion) {
            _fail(
              'The script speaks world protocol ${message['protocol']}, and '
              'this flutterware speaks $worldProtocolVersion. Upgrade '
              'whichever is older.',
            );
          }
          id = message['id'] as String?;
        case WorldMessage.progress:
          _say('${message['message']}');
        case WorldMessage.person:
          var spec = personFromJson(message);
          declared.add(spec.name);
          unawaited(_declare(spec).whenComplete(settle));
        case WorldMessage.action:
          actions[message['name']! as String] =
              message['description'] as String?;
        case WorldMessage.knob:
          var knob = WorldKnob(
            message['name']! as String,
            message['value'] as String? ?? '',
            options: [
              for (var option in message['options'] as List? ?? const [])
                '$option',
            ],
            description: message['description'] as String?,
          );
          this.knobs[knob.name] = knob;
        case WorldMessage.setUp || WorldMessage.failed:
          if (message['type'] == WorldMessage.failed) {
            _fail('${message['error']}');
            _say('${message['stack']}');
          }
          setUp = true;
          // Whoever the script no longer declares has left the world.
          for (var name in [...people.keys]) {
            if (!declared.contains(name)) {
              unawaited(people.remove(name)!._stop());
            }
          }
          settle();
        case WorldMessage.actionProgress:
          runs[message['run']]
            ?..progress = message['message'] as String?
            ..fraction = (message['fraction'] as num?)?.toDouble();
        case WorldMessage.actionEnded:
          var run = runs[message['run']];
          if (run != null) {
            run.error = message['error'] as String?;
            run.running = false;
            run._ended.complete();
          }
      }
      _changed();
    });
    await settled.future;
  }

  /// Brings [spec]'s app up — or, for someone already here on the same app,
  /// restarts it with the knobs the script now gives them.
  ///
  /// Everything up to the person's entry in [people] happens before the first
  /// `await`, and must: a `set-up` in the same read as this `person` is
  /// handled before any continuation runs, and a person not yet in [people]
  /// then would not be waited for.
  Future<void> _declare(Person spec) async {
    var previous = people[spec.name];
    var app = spec.app;
    if (app == null) {
      people[spec.name] = WorldPerson(spec)..phase = PersonPhase.headless;
      await previous?._stop();
      return;
    }
    WorldPerson? person;
    try {
      var (entry, knobs) = _resolve(spec.name, app);
      var device = switch (spec.on) {
        Studio(:var device) => device,
      };
      var build = _buildFor(entry, device);
      if (previous != null && previous._build == build && previous.running) {
        person = previous
          ..spec = spec
          ..knobs = knobs
          ..phase = PersonPhase.starting;
        _changed();
        await build.restart(person);
        person.phase = PersonPhase.running;
        return;
      }
      person = people[spec.name] = WorldPerson(spec)
        ..entry = entry
        ..knobs = knobs
        .._build = build;
      _changed();
      await previous?._stop();
      await build.ready;
      await _start(person, build, device);
    } on Object catch (error) {
      if (person == null) {
        person = people[spec.name] = WorldPerson(spec);
        unawaited(previous?._stop());
      }
      person
        ..phase = PersonPhase.failed
        ..problem = error is WorldRefusal ? error.message : '$error';
      _say('${spec.name}: ${person.problem}');
    } finally {
      _changed();
    }
  }

  Future<void> _start(WorldPerson person, _Build build, Device device) async {
    person.phase = PersonPhase.starting;
    _changed();
    var name = person.name;
    var home = emptyGuestHome(build.app.homeOf(name));
    var platform = person.platform = StudioPlatform(
      person: name,
      home: home,
      package: build.app.package,
      device: device,
    );
    var log = person.log = GuestLog(
      p.join(build.app.buildDir, 'logs', '$name.log'),
    );
    var guest = person.guest = guests(name);
    platform.platform.send = guest.sendPlatform;
    await guest.start(
      WorldGuestStart(
        person: name,
        hostPath: await _host,
        assetsDir: build.app.assetsDir,
        icuData: _cache.icuData,
        workingDirectory: build.app.package,
        environment: guestEnvironment(
          home: home.path,
          knobsFile: build.app.writeKnobs(name, person.knobs),
        ),
        device: device,
        platform: platform.platform.answer,
        onOutput: log.line,
      ),
    );
    var vmService = await guest.vmService;
    person.handle = await announceGuest(
      person: name,
      pid: guest.pid!,
      vmService: vmService,
      packageRoot: build.app.package,
      entrypoint: person.entry!.path,
      package: person.entry!.package,
      world: file.name,
      knobs: person.knobs,
      log: log,
    );
    var launcher = person.launcher = await GuestLauncher.connect(vmService);
    await launcher.serve(
      reload: build.reload,
      restart: () => build.restart(person),
    );
    build.people.add(person);
    person.phase = PersonPhase.running;
  }

  /// The entry point [app] names, and its knobs as its `main` takes them.
  (WorldEntrypoint, Map<String, Object?>) _resolve(String person, Launch app) {
    var matches = [
      for (var entry in entrypoints)
        if (entry.name == app.entrypoint) entry,
    ];
    if (matches.isEmpty) {
      throw WorldRefusal(
        "$person's app is ${app.entrypoint}, which is not one of Run's entry "
        'points. Declared: ${entrypoints.map((e) => e.name).join(', ')}.',
      );
    }
    if (matches.length > 1) {
      throw WorldRefusal(
        '${app.entrypoint} names an entry point in '
        '${matches.map((e) => e.package).join(' and ')}. Give one of them '
        'another name.',
      );
    }
    var entry = matches.single;
    var scan = scanEntrypointKnobs(
      packageRoot: p.join(worktree, entry.package),
      entrypoint: entry.path,
    );
    return (entry, knobsForMain(person, entry.name, app.knobs, scan));
  }

  _Build _buildFor(WorldEntrypoint entry, Device device) {
    var look = switch (device.platform) {
      DevicePlatform.ios => 'iOS',
      DevicePlatform.android => 'android',
      DevicePlatform.windows => 'windows',
      DevicePlatform.linux => 'linux',
      DevicePlatform.macos => null,
    };
    var key = '${entry.package}|${entry.path}|$look';
    return _builds.putIfAbsent(key, () {
      var package = p.join(worktree, entry.package);
      var stem = p.posix.basenameWithoutExtension(entry.path);
      var build = _Build(
        AppGuestBuild(
          package: package,
          cache: _cache,
          entrypoint: entry.path,
          platform: look,
          seeds: true,
          buildDir: p.join(
            buildRoot ?? p.join(package, 'build'),
            'flutterware_worlds',
            p.basename(package),
            look == null ? stem : '$stem-${look.toLowerCase()}',
          ),
        ),
        _say,
        label: entry.name,
      );
      build.ready = build.prepare(_host);
      return build;
    });
  }

  void _fail(String why) {
    phase = WorldPhase.failed;
    problem = why;
    _say(why);
  }

  void _say(String line) {
    _lines.add(line);
    log.add(line);
    if (log.length > 500) log.removeRange(0, log.length - 500);
    _changed();
  }

  void _changed() => onChanged?.call();

  /// Completes once the current opening has settled — for a caller that
  /// started [open] without awaiting it.
  Future<void> get settled => _settled?.future ?? Future.value();
}

/// [given] as [entry]'s `main` takes them — by the names it declares and in
/// the types it declares — or a refusal saying which knob and why.
Map<String, Object?> knobsForMain(
  String person,
  String entry,
  Map<String, Object?> given,
  EntrypointKnobs scan,
) {
  if (scan.required.isNotEmpty) {
    throw WorldRefusal(
      "$entry's main requires ${scan.required.join(', ')}, and a required "
      'parameter is not a knob: give it a default.',
    );
  }
  var byName = {for (var knob in scan.knobs) knob.name: knob.knob};
  return {
    for (var MapEntry(:key, :value) in given.entries)
      key: switch (byName[key]) {
        null => throw WorldRefusal(
          scan.undrawable.any((u) => u.name == key)
              ? "$person's knob $key is a parameter of $entry's main whose "
                    'type a knob cannot carry.'
              : "$person's knob $key is not a parameter of $entry's main. It "
                    'takes ${byName.keys.isEmpty ? 'none' : byName.keys.join(', ')}.',
        ),
        var knob => _asKind(person, key, value, knob.kind),
      },
  };
}

Object? _asKind(String person, String name, Object? value, KnobKind kind) {
  if (value == null) return null;
  Never wrong() => throw WorldRefusal(
    "$person's knob $name is ${value is String ? '"$value"' : value}, and "
    '`main` takes a ${kind.name} there.',
  );
  return switch (kind) {
    KnobKind.string => value is String ? value : '$value',
    KnobKind.boolean => switch (value) {
      bool() => value,
      'true' => true,
      'false' => false,
      _ => wrong(),
    },
    KnobKind.integer => switch (value) {
      int() => value,
      double() when value == value.roundToDouble() => value.toInt(),
      String() => int.tryParse(value) ?? wrong(),
      _ => wrong(),
    },
    KnobKind.number => switch (value) {
      num() => value.toDouble(),
      String() => double.tryParse(value) ?? wrong(),
      _ => wrong(),
    },
    KnobKind.picker => throw WorldRefusal(
      "$person's knob $name is an enum, which a person's app cannot be "
      'started with yet. Take a String and look the value up in `main`.',
    ),
  };
}

/// One app a world's people share: its kernel, and the edits every guest on
/// it takes together — a reload is one compile for all of them, and a delta
/// is only right for guests that took every delta before it.
class _Build {
  _Build(this.app, this._say, {required this.label});

  final AppGuestBuild app;
  final void Function(String) _say;

  /// The entry point, as the world named it.
  final String label;
  late final Future<void> ready;
  final people = <WorldPerson>[];
  var _edits = Future<void>.value();

  Future<void> prepare(Future<String> host) async {
    _say('Building $label');
    await host;
    await app.assets();
    var outcome = await app.compile();
    if (!outcome.ok) {
      throw WorldRefusal(
        'The app did not compile:\n${outcome.output.join('\n')}',
      );
    }
    _say('Built $label');
  }

  /// Recompiles what changed and reloads everyone on this app from it.
  Future<void> reload() => _serial(_reloadEveryone);

  Future<void> _reloadEveryone() async {
    var (_, delta) = await app.recompile();
    if (!delta.ok) throw StateError(delta.output.join('\n'));
    await Future.wait([
      for (var person in people)
        if (person.launcher case var launcher? when person.running)
          launcher.reloadFrom(delta.dillOutput!),
    ]);
  }

  /// Starts [person]'s app again in place, with the knobs they have now — the
  /// others brought to the same code first, since the whole program this
  /// compiles is what every later delta builds on.
  Future<void> restart(WorldPerson person) => _serial(() async {
    app.writeKnobs(person.name, person.knobs);
    await _reloadEveryone();
    var (_, whole) = await app.recompileWhole();
    if (!whole.ok) throw StateError(whole.output.join('\n'));
    await person.launcher!.restartFrom(
      whole.dillOutput!,
      assets: app.assetsDir,
    );
    person.handle = person.handle?.withKnobs({
      for (var MapEntry(:key, :value) in person.knobs.entries) key: '$value',
    })?..save();
  });

  Future<void> _serial(Future<void> Function() edit) {
    var next = _edits.then((_) => edit());
    _edits = next.then((_) {}, onError: (Object _) {});
    return next;
  }
}

/// One of Run's entry points, as a world's `Launch` names it.
class WorldEntrypoint {
  const WorldEntrypoint({
    required this.package,
    required this.path,
    required this.name,
  });

  /// Relative to the worktree.
  final String package;

  /// Package-relative: `lib/main.dart`.
  final String path;

  final String name;
}

enum WorldPhase {
  opening,
  open,
  restarting,
  failed,
  closing,
  closed;

  bool get isMoving => this == opening || this == restarting || this == closing;
}

enum PersonPhase {
  building,
  starting,
  running,
  headless,
  failed;

  bool get isMoving => this == building || this == starting;
}

/// Someone in an open world, and their app.
class WorldPerson {
  WorldPerson(this.spec);

  Person spec;
  PersonPhase phase = PersonPhase.building;

  /// Why they are [PersonPhase.failed].
  String? problem;

  /// What their app was last started with, as `main` takes it.
  Map<String, Object?> knobs = const {};

  WorldEntrypoint? entry;
  WorldGuest? guest;
  StudioPlatform? platform;
  GuestLog? log;
  RunHandle? handle;
  GuestLauncher? launcher;
  _Build? _build;

  String get name => spec.name;
  bool get running => phase == PersonPhase.running;

  /// Their app's run key, once it is up — what `flutterware_act` reaches it
  /// by, beside the device `studio-<name>`.
  String? get runKey => handle?.key;

  Future<void> _stop() async {
    _build?.people.remove(this);
    handle?.delete();
    handle = null;
    await launcher?.dispose();
    await guest?.stop();
  }
}

class WorldKnob {
  const WorldKnob(
    this.name,
    this.value, {
    this.options = const [],
    this.description,
  });

  final String name;
  final String value;
  final List<String> options;
  final String? description;
}

class WorldActionRun {
  WorldActionRun(this.id, this.action);

  final int id;
  final String action;
  bool running = true;
  String? progress;
  double? fraction;
  String? error;
  final _ended = Completer<void>();
}

/// A world that cannot do what it was asked, in a sentence for whoever asked
/// — printed as it is, with no stack.
class WorldRefusal extends ActionRefusal {
  WorldRefusal(super.message);
}

/// What a person's guest starts from.
class WorldGuestStart {
  const WorldGuestStart({
    required this.person,
    required this.hostPath,
    required this.assetsDir,
    required this.icuData,
    required this.workingDirectory,
    required this.environment,
    required this.device,
    required this.platform,
    required this.onOutput,
  });

  final String person;
  final String hostPath;
  final String assetsDir;
  final String icuData;
  final String workingDirectory;
  final Map<String, String> environment;
  final Device device;
  final Future<Uint8List?> Function(String channel, Uint8List bytes) platform;
  final void Function(String line) onOutput;
}

/// Where a person's app draws. Headless for `fw` and the MCP server; a live
/// texture in the studio.
abstract class WorldGuest {
  /// Starts the guest and completes once it has drawn.
  Future<void> start(WorldGuestStart start);

  int? get pid;

  /// Its VM service, the `http://` page the guest prints.
  Future<String> get vmService;

  void sendPlatform(String channel, Uint8List bytes);

  Future<void> stop();
}

/// A guest nobody looks at: the process, drawing into a surface no one
/// shows. Run's screenshots and the drive layer still see it.
class HeadlessWorldGuest implements WorldGuest {
  GuestProcess? _process;

  @override
  Future<void> start(WorldGuestStart start) async {
    var device = start.device;
    var ratio = device.pixelRatio;
    _process = await GuestProcess.start(
      person: start.person,
      hostPath: start.hostPath,
      assetsDir: start.assetsDir,
      icuData: start.icuData,
      workingDirectory: start.workingDirectory,
      environment: start.environment,
      size: (
        (device.width * ratio).round(),
        (device.height * ratio).round(),
        ratio,
      ),
      insets: (
        device.insetTop,
        device.insetRight,
        device.insetBottom,
        device.insetLeft,
      ),
      platform: start.platform,
      onOutput: start.onOutput,
    );
  }

  @override
  int? get pid => _process?.process.pid;

  @override
  Future<String> get vmService => _process!.vmService.future;

  @override
  void sendPlatform(String channel, Uint8List bytes) =>
      _process?.sendPlatform(channel, bytes);

  @override
  Future<void> stop() async => _process?.shutdown();
}
