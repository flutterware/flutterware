import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/devices.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/protocol.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/world.dart';
import 'package:path/path.dart' as p;

import '../embedder/flutter_cache.dart';
import '../run/entrypoint_knobs.dart';
import '../run/handle.dart';
import '../run/journal.dart';
import '../session/job.dart';
import 'app_guest.dart';
import 'declared_links.dart';
import 'guest_launcher.dart';
import 'guest_log.dart';
import 'guest_platform.dart';
import 'guest_process.dart';
import 'platform/studio_platform.dart';
import 'world_files.dart';
import 'world_script.dart';
import 'web_snapshot.dart';
import 'world_trace.dart';

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
    this.runDir,
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

  /// Called whenever anything below changes. Moves with the world when a
  /// config edit hands it to a new core.
  void Function()? onChanged;

  /// Where each app's guest build goes; its package's own `build/` when null.
  final String? buildRoot;

  /// Where the servers the world traces announce themselves; the machine's
  /// run dir when null. A test names an empty one, or its world attaches to
  /// every real server under the worktree.
  final String Function()? runDir;

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

  /// The script's progress and what it printed, newest last, each line
  /// stamped with the time since this opening started.
  final logLines = <WorldLogLine>[];

  /// [logLines] as text, each stamped: `12.4s  Built Shop`.
  List<String> get log => [for (var line in logLines) line.line];

  /// What this opening's people did and what it caused — each step on an
  /// app, joined to the requests, server events and synced records that
  /// followed. New with every opening, as the people are.
  WorldTracer? tracer;

  /// Mail as pictures, drawn once each.
  late final snapshots = WebSnapshots(appRoot: appRoot);

  /// Each line of [log] as it is said.
  Stream<String> get lines => _lines.stream;
  final _lines = StreamController<String>.broadcast(sync: true);

  late final _cache = FlutterCache(p.join(flutterSdkRoot, 'bin', 'cache'));
  late final Future<String> _host = ensureGuestHost(_cache, appRoot);
  late final _dart = p.join(flutterSdkRoot, 'bin', 'dart');
  late final _compiler = WorldCompiler(_dart);
  final _clock = Stopwatch();

  /// How long since this opening — or restart — began.
  Duration get sinceOpening => _clock.elapsed;
  final _builds = <String, _Build>{};
  WorldScriptProcess? _script;
  var _nextRun = 1;
  Completer<void>? _settled;
  var _seeded = false;
  var _restarts = 0;

  /// Opens the world with [knobs] and answers once every person's app is up,
  /// or has failed, or the script has.
  Future<void> open([Map<String, Object?> knobs = const {}]) async {
    phase = WorldPhase.opening;
    unawaited(WorldCompiler.sweep(_dart));
    _prebuild();
    await _run(knobs);
  }

  /// Closes the script and runs it again — new people, new knobs — and
  /// starts each person's app afresh: a new process over the program already
  /// compiled, in an emptied home. The people are new; nothing of the last
  /// ones — a session, a local database — may open as them.
  Future<void> restart([Map<String, Object?>? knobs]) async {
    phase = WorldPhase.restarting;
    _restarts++;
    _changed();
    await _script?.close();
    await _run(knobs ?? knobValues);
  }

  /// Starts [person]'s app again in place, as Run's restart does — the same
  /// person, and what their app keeps on disk still there — and says so in
  /// the log, where a failure is said too. A browser's reload.
  Future<void> restartApp(String person) async {
    var who = people[person];
    var build = who?._build;
    if (who == null || build == null || !who.running) {
      throw WorldRefusal('$person has no app running to start again.');
    }
    var watch = Stopwatch()..start();
    try {
      await build.restart(who);
    } on Object catch (error) {
      _say('$person: the app did not start again. $error');
      rethrow;
    }
    _say(
      '$person: app started again in '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
    );
  }

  /// Brings the open world to the code on disk without new people: the
  /// script's process hot-reloaded — the server it hosts, what its actions
  /// call — and every app reloaded as Run reloads one. What they all hold
  /// stays: the people, their sessions, the server's data.
  ///
  /// The script's body does not run again, so a person, an action or a knob
  /// it now declares waits for a [restart], as does an edit inside a closure
  /// it handed to `w.action`. Source that does not compile is refused with
  /// the compiler's words, and what was running runs on.
  ///
  /// One at a time: a reload asked for while one runs waits for it, then
  /// reloads what changed since. Two at once, and the VM refuses one.
  Future<WorldReload> reload() async {
    for (var running = _reloading; running != null; running = _reloading) {
      await running;
    }
    var done = Completer<void>();
    _reloading = done.future;
    _changed();
    try {
      return await _reload();
    } finally {
      _reloading = null;
      done.complete();
      _changed();
    }
  }

  /// The reload running, which the next one waits for.
  Future<void>? _reloading;

  /// Whether a [reload] is running.
  bool get reloading => _reloading != null;

  Future<WorldReload> _reload() async {
    var script = _script;
    if (script == null || phase != WorldPhase.open) {
      throw WorldRefusal(
        '${file.name} is ${phase.name}; it reloads once it is open.',
      );
    }
    var watch = Stopwatch()..start();
    // Said in the log as well: the studio's button has nowhere else to say
    // it.
    Never refuse(String why) {
      _say(why);
      throw WorldRefusal(why);
    }

    ({Duration code, Duration reassemble, String? compiler}) took;
    DateTime reloadedAt;
    try {
      took = await script.reload();
      // From here the script runs the new code: where the moment goes.
      reloadedAt = DateTime.now();
    } on WorldScriptReloadFailed catch (failure) {
      refuse(
        failure.exited != null
            ? '${failure.message}\nNothing was reloaded, and what it hosted '
                  'went with it. Two reloads at once — a hot reloader of your '
                  'own inside the script, say — can take it down. Restart '
                  'starts it again.'
            : failure.reloaded
            ? 'The script reloaded, but a reassemble callback failed; what '
                  'it was rebuilding serves as it was.\n${failure.message}'
            : failure.refused
            ? 'Nothing was reloaded: the VM would not reload the world '
                  'script, though nothing in it failed to compile. Restart '
                  'starts it afresh.\n${failure.message}'
            : 'The world script did not compile; nothing was reloaded.\n'
                  '${failure.message}',
      );
    }
    var apps = [
      for (var build in _builds.values)
        if (build.people.any((person) => person.running)) build,
    ];
    var appsWatch = Stopwatch()..start();
    try {
      await Future.wait([for (var build in apps) build.reload()]);
    } on StateError catch (error) {
      refuse(
        'The script reloaded, but an app did not compile.\n${error.message}',
      );
    }
    String secs(Duration took) =>
        '${(took.inMilliseconds / 1000).toStringAsFixed(2)} s';
    var elapsed = watch.elapsed;
    var parts =
        'the script in ${secs(took.code)}, its onReassemble in '
        '${secs(took.reassemble)}'
        '${apps.isEmpty ? '' : ', ${[for (var build in apps) build.label].join(', ')} in ${secs(appsWatch.elapsed)}'}';
    var step = tracer?.trace.addReload(
      reloadedAt,
      note: 'Reloaded in ${secs(elapsed)}: $parts',
    );
    if (took.compiler case var compiler?) _say('$compiler.');
    _say(
      'Reloaded in ${secs(elapsed)}${step == null ? '' : ' ($step)'}: '
      '$parts',
    );
    return WorldReload(
      elapsed: elapsed,
      script: took.code,
      reassemble: took.reassemble,
      appsTook: appsWatch.elapsed,
      apps: [for (var build in apps) build.label],
      step: step,
      note: took.compiler,
    );
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
    var id = _nextRun++;
    // A step, as a tap is: what the action sends is traced under it.
    var run = WorldActionRun(id, action, step: '$worldActionsOwner.$id');
    runs[run.id] = run;
    tracer?.trace.addActionStep(run.step, action, DateTime.now());
    script.send(WorldMessage.invoke, {
      'action': action,
      'run': run.id,
      'step': run.step,
    });
    _changed();
    await run._ended.future.timeout(wait, onTimeout: () {});
    return run;
  }

  /// Hands [messageId] — an SMS, a push, a mail a server sent — to its
  /// recipient's app, as a person would take it: its code typed into the
  /// field that has focus, the way an autofill offers one, or its link
  /// opened where the OS would deliver it. [how] is `type` or `open`; by
  /// default the code, when the message carries one. [link] opens one of
  /// its links other than the first — a mail's second button. What it did
  /// lands in the person's Run journal as [actor]'s step.
  Future<WorldDelivery> deliver(
    String messageId, {
    String? how,
    String? link,
    String actor = 'agent',
  }) async {
    var tracer = this.tracer;
    var message = tracer?.trace.messageById(messageId);
    if (tracer == null || message == null) {
      var recent = [
        for (var message
            in tracer?.trace.outbox(limit: 5) ?? const <OutboxMessage>[])
          message.id,
      ];
      throw WorldRefusal(
        'No message $messageId in ${file.name}. '
        '${recent.isEmpty ? 'No server has sent one yet.' : 'The newest: ${recent.join(', ')}.'}',
      );
    }
    var name = message.person;
    var person = name == null ? null : people[name];
    if (name == null || person == null) {
      throw WorldRefusal(
        'The ${message.kind} to ${message.to} reached nobody in '
        '${file.name}: no person was declared with that '
        '${message.kind == 'sms'
            ? 'phone number'
            : message.kind == 'mail'
            ? 'address'
            : 'user id'}.',
      );
    }
    if (!person.running) throw WorldRefusal("$name's app is not running.");
    if (link != null) {
      // As the message spells it: a page's own reading of a link can add
      // the slash an origin implies.
      String bare(String link) =>
          link.endsWith('/') ? link.substring(0, link.length - 1) : link;
      var carried = message.links.where((l) => bare(l) == bare(link!));
      if (carried.isEmpty) {
        throw WorldRefusal(
          'The ${message.kind} carries no link $link. '
          '${message.links.isEmpty ? 'It carries none.' : 'It carries: ${message.links.join(', ')}.'}',
        );
      }
      link = carried.first;
    }
    how ??= link != null || message.code == null ? 'open' : 'type';
    // What the step is called: `Leo typed the code from the SMS`.
    var from = switch (message.kind) {
      'sms' => 'the SMS',
      var kind => 'the $kind',
    };
    String what;
    String? step;
    switch (how) {
      case 'type':
        var code = message.code;
        if (code == null) {
          throw WorldRefusal('It carries no code: "${message.text}".');
        }
        Map<String, Object?> answer;
        try {
          answer = await tracer.ask(name, worldInputChannel, 'type', {
            'text': code,
            'target': 'the code from $from',
          });
        } on Object catch (error) {
          throw WorldRefusal("$name's app did not take it: $error");
        }
        if (answer['typed'] != true) {
          throw WorldRefusal(
            "Nothing in $name's app has focus: tap the field the code goes "
            'in, then deliver it again.',
          );
        }
        what = code;
        step = answer['step'] as String?;
        _journal(person, 'enterText', actor, '"$code" into the focused field');
      case 'open':
        link ??= message.link;
        if (link == null) {
          throw WorldRefusal('It carries no link: "${message.text}".');
        }
        var links = person.platform?.links;
        if (links == null || !links.listening) {
          throw WorldRefusal(
            "$name's app is not listening for links: it registers no "
            'handler with app_links, or has not started it yet.',
          );
        }
        // The step first, so what the link starts has one to join.
        try {
          var answer = await tracer.ask(name, worldInputChannel, 'open', {
            'target': 'the link from $from',
          });
          step = answer['step'] as String?;
        } on Object {
          // A guest built before deliveries were steps: the link still goes.
        }
        if (!links.open(link)) {
          throw WorldRefusal(
            "$name's app is not listening for links: it registers no "
            'handler with app_links, or has not started it yet.',
          );
        }
        what = link;
        _journal(person, 'openLink', actor, link);
      default:
        throw WorldRefusal('A message is delivered by `type` or `open`.');
    }
    var delivery = WorldDelivery(
      message: message.id,
      person: name,
      how: how,
      what: what,
      step: step,
      at: DateTime.now(),
    );
    (deliveries[message.id] ??= []).add(delivery);
    _changed();
    return delivery;
  }

  /// What each message was delivered as, by its id, oldest first: the codes
  /// typed and the links opened from it, for as long as this opening lasts.
  final deliveries = <String, List<WorldDelivery>>{};

  void _journal(WorldPerson person, String verb, String actor, String target) {
    var handle = person.handle;
    if (handle == null) return;
    appendJournal(
      handle,
      JournalEntry(
        at: DateTime.now().toUtc().toIso8601String(),
        verb: verb,
        actor: actor,
        target: target,
      ),
    );
  }

  /// Stops an action that is still running.
  void cancel(int run) => _script?.send(WorldMessage.cancel, {'run': run});

  /// Closes the script — its `onClose` runs — and stops every person's app.
  Future<void> close() async {
    phase = WorldPhase.closing;
    _changed();
    await _script?.close();
    _script = null;
    await Future.wait([
      for (var person in people.values) person._stop(),
      _compiler.shutdown(),
      ?tracer?.close(),
    ]);
    tracer = null;
    people.clear();
    await Future.wait([for (var build in _builds.values) build.app.dispose()]);
    _builds.clear();
    phase = WorldPhase.closed;
    _changed();
    await _lines.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  /// Completes once the world has closed, whoever closed it.
  Future<void> get whenClosed => _closed.future;
  final _closed = Completer<void>();

  Future<void> _run(Map<String, Object?> knobs) async {
    knobValues = knobs;
    problem = null;
    id = null;
    actions.clear();
    this.knobs.clear();
    // The trace starts afresh, and the people's steps start again at `.1`:
    // so do the world's own.
    runs.clear();
    deliveries.clear();
    _nextRun = 1;
    var declared = <String>{};
    var settled = _settled = Completer<void>();
    var setUp = false;
    _clock
      ..reset()
      ..start();
    // The stamps start again at 0.0; a long log says which opening it is.
    if (_restarts > 0) _say('Restart $_restarts');
    unawaited(tracer?.close());
    tracer = WorldTracer(worktree: worktree, runDir: runDir)..onSync = _changed;

    void settle() {
      if (!setUp || settled.isCompleted) return;
      if (people.values.any((person) => person.phase.isMoving)) return;
      _script?.send(WorldMessage.ready);
      if (phase != WorldPhase.failed) phase = WorldPhase.open;
      _say(
        '${phase == WorldPhase.open ? 'Open' : 'Settled'} in '
        '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
      );
      settled.complete();
      _changed();
      _rememberApps();
      unawaited(tracer?.scanServers());
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
      script = _script = await _startScript(knobs);
    } on Object catch (error) {
      _fail('$error');
      // The people of the last opening belong to a world that is gone: left
      // up, they would look alive and answer as nobody.
      await Future.wait([for (var person in people.values) person._stop()]);
      people.clear();
      _changed();
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

  /// Starts the script, once more with a fresh compiler if it died on the
  /// compiler's socket before connecting: `dart run --resident` can find a
  /// compiler whose idle timer — fired late, after the Mac slept — is taking
  /// it down, and the script then dies with the connection reset.
  Future<WorldScriptProcess> _startScript(Map<String, Object?> knobs) async {
    for (var attempt = 1; ; attempt++) {
      var starting = true;
      var said = <String>[];
      try {
        var script = await WorldScriptProcess.start(
          dart: _dart,
          packageRoot: p.join(worktree, file.package),
          file: file.path,
          knobs: knobs,
          compiler: _compiler,
          onOutput: (line) {
            if (starting) said.add(line);
            _say(line, printed: true);
          },
        );
        starting = false;
        return script;
      } on WorldScriptExited {
        if (attempt > 1 || !said.any((l) => l.contains('SocketException'))) {
          rethrow;
        }
        _say('The resident compiler was gone; starting a fresh one');
        await _compiler.shutdown();
      }
    }
  }

  /// Where this world remembers the apps its people used, so the next
  /// opening builds them while the script is still starting its server —
  /// rather than from the first `w.person`, after the stack and the seeding.
  String get _appsFile => p.join(
    buildRoot ?? p.join(worktree, file.package, 'build'),
    'flutterware_worlds',
    '${file.id}.apps.json',
  );

  void _prebuild() {
    unawaited(_host.then<void>((_) {}, onError: (Object _) {}));
    List<Object?> apps;
    try {
      apps = jsonDecode(File(_appsFile).readAsStringSync()) as List;
    } on Object {
      return; // Nothing remembered: the first opening builds as people come.
    }
    for (var app in apps.whereType<Map>()) {
      var entry = entrypoints
          .where((e) => e.package == app['package'] && e.path == app['path'])
          .firstOrNull;
      var device = app['device'];
      if (entry == null || device is! Map) continue;
      _buildFor(entry, deviceFromJson(device.cast()));
    }
  }

  void _rememberApps() {
    var apps = {
      for (var person in people.values)
        if (person.entry case var entry? when person.spec.on is Studio)
          '${entry.package}|${entry.path}|${(person.spec.on as Studio).device.id}':
              {
                'package': entry.package,
                'path': entry.path,
                'device': deviceToJson((person.spec.on as Studio).device),
              },
    };
    try {
      File(_appsFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(apps.values.toList()));
    } on FileSystemException {
      // Only a head start is lost.
    }
  }

  /// Brings [spec]'s app up, a fresh process in an emptied home — for a
  /// newcomer and for someone the last opening had alike, since a world's
  /// people are new every time it runs.
  ///
  /// Everything up to the person's entry in [people] happens before the first
  /// `await`, and must: a `set-up` in the same read as this `person` is
  /// handled before any continuation runs, and a person not yet in [people]
  /// then would not be waited for.
  Future<void> _declare(Person spec) async {
    var previous = people[spec.name];
    // Everyone the script names, app or not: what the world does as a
    // headless person reaches the servers under their user id alone.
    tracer?.trace.addPerson(
      spec.name,
      userId: spec.userId,
      phone: spec.phone,
      email: spec.email,
    );
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
      person = people[spec.name] = WorldPerson(spec)
        ..entry = entry
        ..knobs = knobs
        .._build = build;
      _changed();
      await previous?._stop();
      await build.ready;
      await build.freshKernel();
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
    // Said once a plugin, the first time the app asks it: the call has
    // already failed in the app, and the fix is the project's.
    platform.platform.onUnanswered = (channel, method) => _say(
      "$name's app called ${GuestPlatform.describe(channel, method)}, which "
      'nothing answers in a world. Fake the plugin in the entry point, '
      'behind a knob.',
    );
    var guest = person.guest = guests(name);
    platform.platform.send = guest.sendPlatform;
    await guest.start(
      WorldGuestStart(
        person: name,
        hostPath: await _host,
        assetsDir: build.app.assetsDir,
        icuData: _cache.icuData,
        // The person's own, as their device's would be: an app that writes
        // relative to where it runs — a dev entry point's local database —
        // keeps each person's apart. Nothing a guest needs is found from it.
        workingDirectory: home.path,
        environment: guestEnvironment(
          person: name,
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
    unawaited(tracer?.follow(name, person.handle!, links: build.links));
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
      // Built ahead, it may serve nobody this time; its failure is then
      // nobody's to handle.
      build.ready = build.prepare(_host)..ignore();
      return build;
    });
  }

  void _fail(String why) {
    phase = WorldPhase.failed;
    problem = why;
    _say(why);
  }

  /// Says [said] in the log: the world's own words, or a line the script
  /// [printed].
  /// Says [line] in the log, as the world's own.
  void say(String line) => _say(line);

  void _say(String said, {bool printed = false}) {
    var line = WorldLogLine.of(_clock.elapsed, said, printed: printed);
    _lines.add(line.line);
    logLines.add(line);
    if (logLines.length > 500) {
      logLines.removeRange(0, logLines.length - 500);
    }
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

  /// The links the app says it opens: what a delivery prefers among a
  /// message's.
  late final links = DeclaredLinks.read(app.package);
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

  /// Whether the running guests are ahead of the kernel on disk — a reload
  /// or a restart applied code a new process would not read.
  var _stale = false;

  /// Recompiles what changed and reloads everyone on this app from it.
  Future<void> reload() => _serial(() async {
    if (await _reloadEveryone() > 0) _stale = true;
  });

  /// Reloads the running guests from what changed; answers how many files.
  Future<int> _reloadEveryone() async {
    var (changed, delta) = await app.recompile();
    if (!delta.ok) throw StateError(delta.output.join('\n'));
    await Future.wait([
      for (var person in people)
        if (person.launcher case var launcher? when person.running)
          launcher.reloadFrom(delta.dillOutput!),
    ]);
    return changed;
  }

  /// Leaves the program as it is now where a new guest reads it. Nothing
  /// when nothing changed since the kernel was written, which is the usual
  /// restart; otherwise the whole program, once.
  Future<void> freshKernel() => _serial(() async {
    if (await _reloadEveryone() > 0) _stale = true;
    if (!_stale) return;
    var (_, whole) = await app.recompileWhole();
    if (!whole.ok) throw StateError(whole.output.join('\n'));
    File(whole.dillOutput!).copySync(app.kernel);
    _stale = false;
  });

  /// Starts [person]'s app again in place, with the knobs they have now — the
  /// others brought to the same code first, since the whole program this
  /// compiles is what every later delta builds on.
  Future<void> restart(WorldPerson person) => _serial(() async {
    app.writeKnobs(person.name, person.knobs);
    await _reloadEveryone();
    _stale = true;
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

/// What [OpenWorld.deliver] did: [what] — the code typed, the link opened —
/// in [person]'s app.
/// What [OpenWorld.reload] did.
class WorldReload {
  const WorldReload({
    required this.elapsed,
    required this.apps,
    this.script = Duration.zero,
    this.reassemble = Duration.zero,
    this.appsTook = Duration.zero,
    this.step,
    this.note,
  });

  /// Its moment in the trace, `reload.2`: what came after it ran the new
  /// code, but for work already running.
  final String? step;

  /// What it had to do first, and why: a fresh compiler, for one.
  final String? note;

  /// The whole of it: [script], [reassemble], then [appsTook].
  final Duration elapsed;

  /// The script's code reloading in its VM.
  final Duration script;

  /// Its `FlutterwareServer.onReassemble` callbacks rebuilding on the new
  /// code.
  final Duration reassemble;

  /// The apps reloading, side by side.
  final Duration appsTook;

  /// The apps reloaded with the script, by their entry points' names.
  final List<String> apps;
}

/// How long after a delivery what the app does still joins its step: the
/// guest's window, and a little for the report to arrive.
const deliveryWindow = Duration(milliseconds: 1700);

class WorldDelivery {
  const WorldDelivery({
    required this.message,
    required this.person,
    required this.how,
    required this.what,
    this.step,
    this.at,
  });

  /// When it was delivered.
  final DateTime? at;

  final String message;
  final String person;

  /// `type` or `open`.
  final String how;
  final String what;

  /// The step it was, on the person's app — `leo.13` — whose trace is what
  /// it caused; null from a guest built before deliveries were steps.
  final String? step;
}

class WorldActionRun {
  WorldActionRun(this.id, this.action, {required this.step});

  final int id;
  final String action;

  /// The step it runs as: `world.3`.
  final String step;
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

  /// Spike: the process, so a harness can send input as a person would.
  GuestProcess? get process => _process;

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

/// One line of an [OpenWorld]'s log: when, who said it, and what.
class WorldLogLine {
  const WorldLogLine(this.at, this.source, this.text, [this._said]);

  /// A line the world said is its own; one the script printed is the
  /// script's, or — printed the way `package:logging` records usually are,
  /// `edges: mail to …` — the logger's that wrote it.
  factory WorldLogLine.of(Duration at, String said, {required bool printed}) {
    if (!printed) return WorldLogLine(at, 'world', said);
    var logger = _logger.firstMatch(said);
    return logger == null
        ? WorldLogLine(at, 'script', said)
        : WorldLogLine(at, logger[1]!, said.substring(logger.end), said);
  }

  static final _logger = RegExp(r'^([a-z][\w.-]{0,23}): ');

  /// Since the opening started.
  final Duration at;

  /// `world`, `script`, or a logger's name.
  final String source;
  final String text;

  /// What was said, the logger's name still on it.
  final String? _said;

  /// `12.4s`.
  String get stamp => '${(at.inMilliseconds / 1000).toStringAsFixed(1)}s';

  /// The line as text: `12.4s  edges: mail to …`.
  String get line => '$stamp  ${_said ?? text}';
}
