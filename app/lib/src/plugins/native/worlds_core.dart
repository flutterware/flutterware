import 'dart:async';
import 'dart:io';

import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;

import '../../run/entrypoints.dart';
import '../../world/open_world.dart';
import '../../world/world_files.dart';
import '../../world/world_owner.dart';
import '../../world/world_trace.dart' show TraceLevel;
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'run_core.dart' show runPluginId;
import 'worlds_results.dart';

const worldsPluginId = 'flutterware.worlds';

/// Worlds: several people on your real server, set up by a script
/// (`docs/superpowers/specs/2026-09-25-worlds-design.md`).
///
/// **Whoever opens a world owns it,** as with a Run launch. The script, the
/// compiler and every person's guest live in the process that opened it —
/// the studio, `fw` or the MCP server — and go when it closes the world or
/// ends. So one world at a time per worktree: two would give two people the
/// same device, `studio-<name>`, in Run. Every other process forwards
/// `status`, `trace`, `contents`, `outbox`, `deliver`, `show`, `invoke`,
/// `restart` and `close` to the owner, which leaves a `WorldHandle` saying
/// where to ask.
///
/// **The studio opens what others are asked to.** `fw` and the MCP server
/// draw a person's app nowhere; the studio draws it live. So while the
/// studio has the worktree it takes openings ([takeOpenings]), and an `open`
/// anywhere else is sent there — unless it is held, which asks for this
/// process by name.
class WorldsCore extends PluginCore {
  WorldsCore(super.host) {
    if (_handedOver.remove(host.worktree.path) case var open?) {
      _open = open..onChanged = notifyChanged;
      unawaited(_serveElsewhere(open));
    }
  }

  /// A world whose core a config edit disposed, for the core built in its
  /// place. Saving `tool/flutterware.dart` rebuilds every core, and adding a
  /// world to it is no reason to close the one open, its people mid-flow.
  /// The shell builds the new cores in the same turn it disposes the old, so
  /// a world nobody has taken by the next microtask — the worktree closed,
  /// or the config stopped declaring worlds — closes as it always did.
  static final _handedOver = <String, OpenWorld>{};

  /// Where a person's app draws: nowhere, unless a surface that can show a
  /// guest says otherwise — the studio's panel sets a live one.
  WorldGuest Function(String person) guests = (_) => HeadlessWorldGuest();

  /// Why no world opens here — [worldsUnsupported] — shown on every world.
  String? unsupported = worldsUnsupported();

  var _worlds = <WorldFile>[];
  OpenWorld? _open;

  /// The worlds the project declares, as the last scan found them.
  List<WorldFile> get worlds => _worlds;

  /// The world this process has open, if any — closed ones are forgotten.
  OpenWorld? get open => _open;

  @override
  Future<void> computeAll() async {
    _worlds = [
      for (var config in host.packageConfigs)
        if (config['path'] case String path when host.workspace.exists(path))
          ...declaredWorlds(
            config: config,
            packageRoot: host.workspace.absolutePathOf(path),
            unsupported: unsupported,
          ),
    ];
    notifyChanged();
  }

  @override
  PluginReport get report => PluginReport(
    id: id,
    label: label,
    description:
        'Several people on your real server, set up by a script. Opening a '
        "world runs it; each person's app starts in an embedded guest, "
        'signed in as whoever the script made, and is a Run app like any '
        'other — `flutterware_act` reaches it by its device, `studio-<name>`.',
    status: switch (_open) {
      null => Status.none,
      var open => switch (open.phase) {
        WorldPhase.open => const Status.good('open'),
        WorldPhase.failed => const Status.error('failed'),
        WorldPhase.closed => Status.none,
        var phase => Status.info(phase.name),
      },
    },
    actions: _actions,
    children: [
      for (var world in _worlds)
        PluginChild(
          id: world.id,
          label: world.name,
          status: _open?.file.id == world.id
              ? switch (_open!.phase) {
                  WorldPhase.open => const Status.good('open'),
                  WorldPhase.failed => const Status.error('failed'),
                  WorldPhase.closed => Status.none,
                  var phase => Status.info(phase.name),
                }
              : Status.none,
        ),
    ],
    view: _view,
  );

  List<PluginAction> get _actions => [
    const PluginAction(
      'list',
      'List',
      returns: WorldListResult,
      description:
          'Every world the project declares in `tool/flutterware.dart` — a '
          'script whose `main` calls `World.run` — with what it sets up.',
    ),
    PluginAction(
      'open',
      'Open',
      returns: WorldStateResult,
      description:
          'Runs the world script in its package and starts every person it '
          'declares, each app in an embedded guest; answers once they are all '
          'up. Each is then a Run app on the device `studio-<name>`, so '
          '`flutterware_act` with that `device` drives it. When the studio '
          "has this worktree open, the world opens there, its people's apps "
          'live on screen, and the studio owns it; otherwise it lives in this '
          'process and closes when this process does. Every other process '
          'reaches it: `status`, `invoke`, `restart` and `close` are answered '
          'by whichever process owns it.',
      parameters: [
        ActionParameter(
          'world',
          'World',
          kind: ActionParameterKind.choice,
          description: 'Which world, by its file name',
          options: [
            for (var world in _worlds)
              ActionOption(world.id, label: world.name),
          ],
        ),
        _knobsParameter,
        const ActionParameter(
          'hold',
          'Hold',
          kind: ActionParameterKind.boolean,
          required: false,
          description:
              'Open the world in this process, even with the studio open, and '
              'keep both until it is interrupted. For `fw`, whose process '
              'would otherwise end — and close the world — as soon as the '
              'world is open',
        ),
      ],
    ),
    const PluginAction(
      'status',
      'Status',
      returns: WorldStateResult,
      description:
          'The open world: its people and their devices, its actions and '
          "knobs, and its script's last lines.",
      parameters: [_worldParameter],
    ),
    const PluginAction(
      'trace',
      'Trace',
      returns: WorldTraceResult,
      description:
          "The newest steps taken on the people's apps — each tap, a "
          "person's or an agent's — with what each one caused: the requests "
          'it sent, what the servers did under them and whom they reached, '
          'and where the records it wrote arrived. A server takes part by '
          'reading the `x-fw-step` header into `FlutterwareServer.stepKey`; '
          'a synced database, by its database panel reading the engine.',
      parameters: [
        ActionParameter(
          'person',
          'Person',
          required: false,
          description:
              "Only this person's steps; `world` for the world's own "
              'actions',
        ),
        ActionParameter(
          'step',
          'Step',
          required: false,
          description: 'Only this step, by its name: `ben.3`',
        ),
        ActionParameter(
          'limit',
          'Limit',
          kind: ActionParameterKind.integer,
          required: false,
          description: 'How many of the newest steps, 10 by default',
        ),
        ActionParameter(
          'statements',
          'Statements',
          kind: ActionParameterKind.boolean,
          required: false,
          defaultValue: 'false',
          description:
              'What each line counts, beneath it: the SQL statements a '
              'request or a job ran, its writes to a table in a layer, each '
              "of a record's updates in a row. Without it a line says how "
              'many.',
        ),
        ActionParameter(
          'level',
          'Level',
          kind: ActionParameterKind.choice,
          required: false,
          defaultValue: 'wire',
          description:
              'How far into the system to go. `product`: what people did '
              'and what reached someone else — messages sent outside, '
              "updates and records arriving on another person's app. "
              '`system` adds the calls and jobs; `wire`, the writes, '
              'statements and sync. What a hidden line caused still shows, '
              'in its place',
          options: [
            ActionOption('product', label: 'Product'),
            ActionOption('system', label: 'System'),
            ActionOption('wire', label: 'Wire'),
          ],
        ),
        _worldParameter,
      ],
    ),
    const PluginAction(
      'outbox',
      'Outbox',
      returns: WorldOutboxResult,
      description:
          'The messages the servers sent outside — SMS, push, mail — newest '
          'first, each with whom it reached, the code or link it carries, '
          'and the step that sent it. A server takes part by reporting '
          '`sms`, `push` or `mail` events with their recipient.',
      parameters: [
        ActionParameter(
          'person',
          'Person',
          required: false,
          description: 'Only what reached this person',
        ),
        ActionParameter(
          'limit',
          'Limit',
          kind: ActionParameterKind.integer,
          required: false,
          description: 'How many of the newest, 20 by default',
        ),
        _worldParameter,
      ],
    ),
    const PluginAction(
      'deliver',
      'Deliver',
      returns: WorldDeliveryResult,
      description:
          "Hands a message to its recipient's app as a person would take it: "
          'its code typed into the field that has focus, the way an autofill '
          'offers one, or its link opened where the OS would deliver it. '
          'Focus the field first — tap it — for a code. Each delivery is a '
          "step on the person's app, and the answer is what it caused in the "
          'moments after: nothing, for a link the app ignored.',
      parameters: [
        ActionParameter(
          'message',
          'Message',
          description: 'Its id, from `worlds outbox`: `lab/42`',
        ),
        ActionParameter(
          'how',
          'How',
          required: false,
          description:
              '`type` its code or `open` its link; the code when it '
              'carries one',
        ),
        ActionParameter(
          'link',
          'Link',
          required: false,
          description:
              'Which of its links to open, when not the first: one '
              '`worlds outbox` lists',
        ),
        _worldParameter,
      ],
    ),
    const PluginAction(
      'show',
      'Show',
      returns: WorldShowResult,
      description:
          "Draws a message as its recipient would see it — a mail's HTML "
          'rendered by WebKit to a PNG — with the box of each link on it. '
          "Read the picture to see the mail; open a link in the person's "
          'app with `worlds deliver`.',
      parameters: [
        ActionParameter(
          'message',
          'Message',
          description: 'Its id, from `worlds outbox`: `lab/42`',
        ),
        _worldParameter,
      ],
    ),
    const PluginAction(
      'contents',
      'Contents',
      returns: WorldContentsResult,
      description:
          'What one part of the system holds, as the world heard it since '
          'it opened: every call a route answered and who asked, every '
          'record a table was written with its whole life — each write and '
          'each phone it reached — every message sent outside and whom it '
          'reached, every record the sync engine carried. Each names the '
          'step that caused it. With no part, lists the parts there are.',
      parameters: [
        ActionParameter(
          'part',
          'Part',
          required: false,
          description:
              'As the canvas shows it: a route (`POST /orders`), a table '
              '(`orders`), `sms` or `push`, or `sync`',
        ),
        ActionParameter(
          'limit',
          'Limit',
          kind: ActionParameterKind.integer,
          required: false,
          description: 'How many of the newest, 20 by default',
        ),
        _worldParameter,
      ],
    ),
    const PluginAction(
      'reload',
      'Reload',
      returns: WorldReloadResult,
      description:
          'Brings the open world to the code on disk without new people: '
          "the script's process hot-reloaded — the server it hosts, what its "
          'actions call — and every app reloaded, in well under a second. '
          "The people, their sessions and the server's data stay. The "
          "script's body does not run again: a person, action or knob it now "
          'declares, or an edit inside a closure it handed to `w.action`, '
          'waits for a restart. One reload runs at a time; one asked for '
          'meanwhile runs after it. The answer splits the time between the '
          "script's code, its onReassemble callbacks and the apps.",
      parameters: [_worldParameter],
    ),
    PluginAction(
      'restart',
      'Restart',
      returns: WorldStateResult,
      description:
          'Runs the script again — its `onClose` first — so the people are '
          'new, and starts each app afresh with the knobs the script now '
          'gives it: a new process over the program already compiled, in an '
          'emptied home, so nothing of the last people opens as them. The '
          "script's own edits apply too.",
      parameters: [_knobsParameter, _worldParameter],
    ),
    const PluginAction(
      'invoke',
      'Invoke',
      returns: WorldActionResult,
      description:
          'Runs one of the actions the world script declares, and answers '
          'when it ends — or after 30 s, still running, for one that takes '
          'longer.',
      parameters: [
        ActionParameter(
          'action',
          'Action',
          description: 'The action, by its name',
        ),
        _worldParameter,
      ],
    ),
    const PluginAction(
      'close',
      'Close',
      returns: WorldStateResult,
      description:
          "Closes the open world: its script's `onClose` runs, and every "
          "person's app stops.",
      parameters: [_worldParameter],
    ),
  ];

  /// Optional, since a worktree has one world open at a time: named, it is
  /// checked against that one, so a script's `--world` cannot act on another.
  static const _worldParameter = ActionParameter(
    'world',
    'World',
    required: false,
    description:
        'The world it is for, by its file name — checked against the one open',
  );

  static const _knobsParameter = ActionParameter(
    'knobs',
    'Knobs',
    required: false,
    description:
        "The world's knob values, `name=value` pairs split by `;`: "
        '`language=fr;network=offline`',
  );

  PluginView get _view {
    var open = _open;
    return PluginView([
      if (open == null)
        ViewText(
          _worlds.isEmpty
              ? 'No worlds yet: a world is a script whose `main` calls '
                    '`World.run`, declared with `WorldScript` in '
                    '`tool/flutterware.dart`.'
              : 'None open.',
        )
      else ...[
        ViewField('Open', open.file.name),
        ViewField('Phase', open.phase.name),
        if (open.problem case var problem?) ViewText(problem, tone: Tone.error),
        if (open.people.isNotEmpty)
          ViewSection('People', [
            ViewItems([
              for (var person in open.people.values)
                ViewItem(
                  person.name,
                  detail: [
                    person.phase.name,
                    ?person.handle?.device,
                    ?person.problem,
                    if (open.tracer?.syncOf(person.name) case var sync?)
                      syncLine(sync),
                  ].join(' · '),
                  tone: switch (person.phase) {
                    PersonPhase.running => Tone.good,
                    PersonPhase.failed => Tone.error,
                    _ => Tone.neutral,
                  },
                ),
            ]),
          ]),
      ],
    ]);
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    if (arguments['world'] case String named
        when actionId != 'open' && actionId != 'list') {
      var open = _open?.file.id ?? openElsewhere()?.world;
      if (open == null) {
        throw WorldRefusal('No world is open, so not $named either.');
      }
      if (open != named) {
        throw WorldRefusal(
          '$open is the world open on this worktree, not $named.',
        );
      }
    }
    return _invoke(actionId, arguments);
  }

  Future<Object?> _invoke(
    String actionId,
    Map<String, Object?> arguments,
  ) async => switch (actionId) {
    'list' => await _listAction(),
    'open' => await _openAction(
      '${arguments['world']}',
      knobs: parseWorldKnobs(arguments['knobs'] as String?),
      hold: arguments['hold'] == true,
    ),
    // A world another process owns is asked there, in its own words.
    'status' ||
    'trace' ||
    'contents' ||
    'outbox' ||
    'deliver' ||
    'show' ||
    'reload' ||
    'restart' ||
    'invoke' ||
    'close' when _open == null && openElsewhere() != null => await _forward(
      openElsewhere()!,
      actionId,
      arguments,
    ),
    'status' => WorldStateResult.of(_required),
    'trace' => _traceAction(arguments),
    'contents' => _contentsAction(arguments),
    'outbox' => _outboxAction(arguments),
    'deliver' => await _deliverAction(arguments),
    'show' => await _showAction(arguments),
    'reload' => WorldReloadResult.of(await _required.reload()),
    'restart' => await _restartAction(
      arguments['knobs'] == null
          ? null
          : parseWorldKnobs(arguments['knobs'] as String?),
    ),
    'invoke' => WorldActionResult.of(
      await _required.invoke('${arguments['action']}'),
    ),
    'close' => await _closeAction(),
    _ => await super.invoke(actionId, arguments: arguments),
  };

  /// [action] run by [owner], its answer read back into this process's
  /// result type.
  Future<PluginResult> _forward(
    WorldHandle owner,
    String action,
    Map<String, Object?> arguments,
  ) async {
    Map<String, Object?> json;
    try {
      json = await askWorldOwner(owner.socket, action, arguments: arguments);
    } on WorldOwnerRefusal catch (refusal) {
      throw WorldRefusal(refusal.message);
    } finally {
      // Whatever it did there changes what this process shows.
      notifyChanged();
    }
    return switch (action) {
      'invoke' => WorldActionResult.fromJson(json),
      'trace' => WorldTraceResult.fromJson(json),
      'contents' => WorldContentsResult.fromJson(json),
      'outbox' => WorldOutboxResult.fromJson(json),
      'deliver' => WorldDeliveryResult.fromJson(json),
      'show' => WorldShowResult.fromJson(json),
      'reload' => WorldReloadResult.fromJson(json),
      _ => WorldStateResult.fromJson(
        json,
        note: action == 'close'
            ? 'Closed by the process that owned it (pid ${owner.pid}).'
            : '${owner.name} is open in another process (pid '
                  '${owner.pid}), which answered this.',
      ),
    };
  }

  /// What another process asks of the world open here.
  Future<Map<String, Object?>> _answerElsewhere(
    String action,
    Map<String, Object?> arguments,
  ) async {
    if (!const {
      'status',
      'trace',
      'contents',
      'outbox',
      'deliver',
      'show',
      'reload',
      'restart',
      'invoke',
      'close',
    }.contains(action)) {
      throw WorldRefusal('"$action" is not asked of a world across processes.');
    }
    var result = await invoke(action, arguments: arguments);
    return (result! as PluginResult).toJson();
  }

  /// Opens [world] here. What the panel and every surface call.
  ///
  /// [onCreated] is handed the world before it starts opening, for a caller
  /// that wants every line of it.
  Future<OpenWorld> openWorld(
    String world, {
    Map<String, Object?> knobs = const {},
    void Function(OpenWorld world)? onCreated,
  }) async {
    var open = _open;
    if (open != null) {
      if (open.file.id == world) return open;
      throw WorldRefusal(
        '${open.file.name} is open. Close it first: one world at a time, '
        'since two would give two people the same device in Run.',
      );
    }
    if (_worlds.isEmpty) await computeAll();
    var file = _worlds.where((w) => w.id == world).firstOrNull;
    if (file == null) {
      throw WorldRefusal(
        'No world is called "$world". '
        '${_worlds.isEmpty ? 'This project declares none.' : 'Declared: ${_worlds.map((w) => w.id).join(', ')}.'}',
      );
    }
    if (file.problem case var problem?) throw WorldRefusal(problem);
    if (openElsewhere() case var other?) {
      throw WorldRefusal(
        '${other.name} is open in another process on this worktree (pid '
        '${other.pid}), and one world at a time is open on a worktree: its '
        'people hold their devices. `worlds status`, `invoke`, `restart` and '
        '`close` reach it from here.',
      );
    }
    var opened = _open = OpenWorld(
      file: file,
      worktree: host.worktree.path,
      flutterSdkRoot: host.workspace.flutterSdk.root,
      appRoot: host.workspace.appContext.appToolDirectory.path,
      entrypoints: _entrypoints(),
      guests: guests,
      onChanged: notifyChanged,
    );
    onCreated?.call(opened);
    notifyChanged();
    await _serveElsewhere(opened);
    await opened.open(knobs);
    return opened;
  }

  WorldOwnerServer? _owner;
  WorldHandle? _handle;
  var _disposed = false;

  /// Leaves [opened]'s handle for other processes, and answers them.
  Future<void> _serveElsewhere(OpenWorld opened) async {
    var owner = _owner = await WorldOwnerServer.start(_answerElsewhere);
    (_handle = WorldHandle(
      worktree: host.worktree.path,
      world: opened.file.id,
      name: opened.file.name,
      pid: pid,
      socket: owner.socket,
    )).write();
  }

  Future<void> _stopServingElsewhere() async {
    _handle?.delete();
    _handle = null;
    await _owner?.close();
    _owner = null;
  }

  WorldOwnerServer? _door;

  /// Opens the worlds other processes are asked to open — `fw`, the MCP
  /// server — here, until this core goes: called by the studio, where a
  /// person's app draws live ([guests]) rather than nowhere.
  Future<void> takeOpenings() async {
    if (_door != null || unsupported != null) return;
    var door = _door = await WorldOwnerServer.start(_openForElsewhere);
    if (_disposed) {
      await door.close();
      return;
    }
    WorldDoor(
      worktree: host.worktree.path,
      pid: pid,
      socket: door.socket,
    ).write();
  }

  Future<Map<String, Object?>> _openForElsewhere(
    String action,
    Map<String, Object?> arguments,
  ) async {
    if (action != 'open') {
      throw WorldRefusal('The studio takes openings here, not "$action".');
    }
    var asker = arguments['from'];
    var opened = await openWorld(
      '${arguments['world']}',
      knobs: parseWorldKnobs(arguments['knobs'] as String?),
      onCreated: (open) => open.say(
        'Opened for another process${asker == null ? '' : ' (pid $asker)'} '
        '— `fw` or the MCP server — which reaches it from there',
      ),
    );
    return WorldStateResult.of(opened).toJson();
  }

  /// The studio taking this worktree's openings, when it is another process.
  WorldDoor? openingElsewhere() {
    var door = WorldDoor.read(host.worktree.path);
    return door == null || door.pid == pid ? null : door;
  }

  Future<void> _closeDoor() async {
    var door = _door;
    if (door == null) return;
    _door = null;
    WorldDoor(
      worktree: host.worktree.path,
      pid: pid,
      socket: door.socket,
    ).delete();
    await door.close();
  }

  /// Closes the world open here.
  Future<void> closeWorld() async {
    var open = _open;
    if (open == null) return;
    await _stopServingElsewhere();
    await open.close();
    if (_open == open) _open = null;
    notifyChanged();
  }

  /// A world another process opened on this worktree, and how to ask it —
  /// whoever opened it owns it, so this one forwards rather than opens.
  WorldHandle? openElsewhere() {
    var handle = WorldHandle.read(host.worktree.path);
    return handle == null || handle.pid == pid ? null : handle;
  }

  /// Read afresh: a new process — `fw`, one call — has read nothing yet, and
  /// the declarations may have changed since the studio last did.
  Future<WorldListResult> _listAction() async {
    await computeAll();
    return WorldListResult(
      worlds: [for (var world in _worlds) WorldListEntry.of(world)],
      open: _open?.file.id,
    );
  }

  Future<WorldStateResult> _openAction(
    String world, {
    required Map<String, Object?> knobs,
    required bool hold,
  }) async {
    var elsewhere = _open == null ? openElsewhere() : null;
    if (elsewhere != null && elsewhere.world == world) {
      // Open already, somewhere: an opening asked twice is the one there.
      return await _forward(elsewhere, 'status', const {}) as WorldStateResult;
    }
    if (!hold && _open == null && elsewhere == null) {
      if (openingElsewhere() case var studio?) {
        try {
          return WorldStateResult.fromJson(
            await askWorldOwner(
              studio.socket,
              'open',
              arguments: {
                'world': world,
                'knobs': [
                  for (var MapEntry(:key, :value) in knobs.entries)
                    '$key=$value',
                ].join(';'),
                'from': pid,
              },
            ),
            note:
                'Opened in the studio (pid ${studio.pid}), which owns it: '
                "its people's apps are live there. Each is a Run app: "
                '`flutterware_act` with `device: "studio-<name>"` drives it, '
                'and every other action reaches the world from here.',
          );
        } on WorldOwnerGone {
          // A studio that left its door and stopped answering: this process
          // opens the world, as it would with no studio at all.
        } on WorldOwnerRefusal catch (refusal) {
          throw WorldRefusal(refusal.message);
        } finally {
          notifyChanged();
        }
      }
    }
    // Held, `fw` is the world's only window: what the script says — its
    // server's log, the code it texted — is printed as it is said.
    StreamSubscription<String>? printing;
    var opened = await openWorld(
      world,
      knobs: knobs,
      onCreated: hold
          ? (open) => printing = open.lines.listen(stdout.writeln)
          : null,
    );
    var result = WorldStateResult.of(
      opened,
      note: opened.phase == WorldPhase.open
          ? "Each person's app is a Run app: `flutterware_act` with "
                '`device: "studio-<name>"` drives it.'
          : null,
    );
    if (hold) {
      stdout.writeln('${opened.file.name} is open. Ctrl-C closes it.');
      for (var person in result.people) {
        var identity = [?person.email, ?person.phone].join(', ');
        stdout.writeln(
          '  ${person.name}${identity.isEmpty ? '' : ' ($identity)'}: '
          '${person.phase}${person.device == null ? '' : ' on ${person.device}'}'
          '${person.problem == null ? '' : ' — ${person.problem}'}',
        );
      }
      // Ctrl-C, or a `worlds close` from another process. The signal is
      // listened to, not awaited with `first`: a watch left open keeps the
      // process alive after a close from elsewhere.
      var interrupted = Completer<void>();
      var sigint = ProcessSignal.sigint.watch().listen((_) {
        if (!interrupted.isCompleted) interrupted.complete();
      });
      await Future.any([interrupted.future, opened.whenClosed]);
      await sigint.cancel();
      await closeWorld();
      await printing?.cancel();
      return WorldStateResult.of(opened);
    }
    return result;
  }

  WorldTraceResult _traceAction(Map<String, Object?> arguments) {
    var open = _required;
    var person = arguments['person'] as String?;
    if (person != null &&
        person != worldActionsOwner &&
        !open.people.containsKey(person)) {
      throw WorldRefusal(
        'Nobody in ${open.file.name} is called $person: '
        '${open.people.keys.join(', ')}.',
      );
    }
    var limit = switch (arguments['limit']) {
      int value => value,
      String value => int.tryParse(value) ?? 10,
      _ => 10,
    };
    var traced =
        open.tracer?.trace.steps(
          person: person,
          step: arguments['step'] as String?,
          limit: limit,
        ) ??
        const [];
    return WorldTraceResult.of(
      traced,
      statements: arguments['statements'] == true,
      level: switch (arguments['level']) {
        String named =>
          TraceLevel.values.asNameMap()[named] ??
              (throw WorldRefusal(
                'There is no level $named: product, system or wire.',
              )),
        _ => TraceLevel.wire,
      },
      note: traced.isEmpty
          ? 'No step yet: a step is a tap on one of the apps, by a person or '
                'through `flutterware_act`.'
          : null,
    );
  }

  /// A delivery, answered with what its step caused: the app's answer to a
  /// link comes through its own stream, so it is given the step's window
  /// to act before the trace is read.
  Future<WorldDeliveryResult> _deliverAction(
    Map<String, Object?> arguments,
  ) async {
    var open = _required;
    var delivery = await open.deliver(
      '${arguments['message']}',
      how: arguments['how'] as String?,
      link: arguments['link'] as String?,
    );
    var step = delivery.step;
    if (step == null) return WorldDeliveryResult.of(delivery);
    await Future<void>.delayed(deliveryWindow);
    var traced = open.tracer?.trace.steps(step: step, limit: 1);
    return WorldDeliveryResult.of(delivery, caused: traced?.firstOrNull);
  }

  WorldOutboxResult _outboxAction(Map<String, Object?> arguments) {
    var open = _required;
    var person = arguments['person'] as String?;
    if (person != null && !open.people.containsKey(person)) {
      throw WorldRefusal(
        'Nobody in ${open.file.name} is called $person: '
        '${open.people.keys.join(', ')}.',
      );
    }
    var limit = switch (arguments['limit']) {
      int value => value,
      String value => int.tryParse(value) ?? 20,
      _ => 20,
    };
    var messages =
        open.tracer?.trace.outbox(person: person, limit: limit) ?? const [];
    return WorldOutboxResult.of(
      messages,
      note: messages.isEmpty
          ? 'Nothing sent yet. A server takes part by reporting `sms`, '
                '`push` or `mail` events that name their recipient.'
          : null,
    );
  }

  Future<WorldShowResult> _showAction(Map<String, Object?> arguments) async {
    var open = _required;
    var id = '${arguments['message']}';
    var message = open.tracer?.trace.messageById(id);
    if (message == null) {
      throw WorldRefusal('No message $id in ${open.file.name}.');
    }
    var html = message.html;
    if (html == null) {
      throw WorldRefusal(
        'The ${message.kind} has no page to draw; its words are all of it: '
        '"${message.body ?? message.text}".',
      );
    }
    try {
      return WorldShowResult.of(id, await open.snapshots.of(html));
    } on UnsupportedError catch (error) {
      throw WorldRefusal('${error.message}');
    } on StateError catch (error) {
      throw WorldRefusal('Could not draw it: ${error.message}');
    }
  }

  WorldContentsResult _contentsAction(Map<String, Object?> arguments) {
    var open = _required;
    var names = open.tracer?.trace.nodeNames ?? const <String, String>{};
    var part = arguments['part'] as String?;
    if (part == null) {
      return WorldContentsResult(
        parts: names.keys.toList(),
        note: names.isEmpty
            ? 'Nothing has reported yet. A Dart server takes part through '
                  'its inspection adapter; a synced database, through its '
                  'database panel.'
            : 'Name one as `part` for what it holds.',
      );
    }
    var node = names[part];
    if (node == null) {
      throw WorldRefusal(
        names.isEmpty
            ? 'Nothing in ${open.file.name} has reported yet.'
            : 'No part of the system is called "$part": '
                  '${names.keys.join(', ')}.',
      );
    }
    var limit = switch (arguments['limit']) {
      int value => value,
      String value => int.tryParse(value) ?? 20,
      _ => 20,
    };
    return WorldContentsResult.of(
      open.tracer!.trace.contentsOf(node, limit: limit)!,
      part: part,
    );
  }

  Future<WorldStateResult> _restartAction(Map<String, Object?>? knobs) async {
    var open = _required;
    await open.restart(knobs);
    return WorldStateResult.of(open);
  }

  Future<WorldStateResult> _closeAction() async {
    var open = _required;
    await closeWorld();
    return WorldStateResult.of(open);
  }

  OpenWorld get _required {
    if (_open case var open?) return open;
    throw WorldRefusal('No world is open. `worlds open` opens one.');
  }

  /// Run's entry points, every declared package's — declared ones, or what a
  /// scan finds where a package declares none, as Run itself does.
  List<WorldEntrypoint> _entrypoints() => [
    for (var config in host.packageConfigsOf(runPluginId))
      if (config['path'] case String path when host.workspace.exists(path))
        for (var entry
            in declaredEntrypoints(config).isNotEmpty
                ? declaredEntrypoints(config)
                : scanEntrypoints(host.workspace.absolutePathOf(path)))
          WorldEntrypoint(package: path, path: entry.path, name: entry.name),
  ];

  @override
  void dispose() {
    _disposed = true;
    unawaited(_closeDoor());
    unawaited(_stopServingElsewhere());
    if (_open case var open?) {
      var worktree = host.worktree.path;
      _handedOver[worktree] = open..onChanged = null;
      scheduleMicrotask(() {
        if (_handedOver[worktree] != open) return;
        _handedOver.remove(worktree);
        unawaited(open.close());
      });
    }
    _open = null;
    super.dispose();
  }
}

/// `language=fr;network=offline` as knob values. Values stay strings: a
/// world's knobs are words the script reads.
Map<String, Object?> parseWorldKnobs(String? pairs) => {
  for (var pair in (pairs ?? '').split(';'))
    if (pair.contains('='))
      pair.substring(0, pair.indexOf('=')).trim(): pair.substring(
        pair.indexOf('=') + 1,
      ),
};

PluginCore worldsCoreFactory(PluginHost host) => WorldsCore(host);
