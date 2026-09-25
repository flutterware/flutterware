import 'dart:async';
import 'dart:io';

import 'package:flutterware/plugins.dart';

import '../../run/entrypoints.dart';
import '../../world/open_world.dart';
import '../../world/world_files.dart';
import '../../world/world_owner.dart';
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
/// `status`, `invoke`, `restart` and `close` to the owner, which leaves a
/// `WorldHandle` saying where to ask.
class WorldsCore extends PluginCore {
  WorldsCore(super.host);

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
          '`flutterware_act` with that `device` drives it. The world lives in '
          'this process: it closes when this process does. Every other process '
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
              'Keep this process, and the world, until it is interrupted. '
              'For `fw`, whose process would otherwise end — and close the '
              'world — as soon as the world is open',
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
    ),
    PluginAction(
      'restart',
      'Restart',
      returns: WorldStateResult,
      description:
          'Runs the script again — its `onClose` first — so the people are '
          'new, and restarts each app in place with the knobs the script now '
          "gives it. Nothing rebuilds. The script's own edits apply too.",
      parameters: [_knobsParameter],
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
      ],
    ),
    const PluginAction(
      'close',
      'Close',
      returns: WorldStateResult,
      description:
          "Closes the open world: its script's `onClose` runs, and every "
          "person's app stops.",
    ),
  ];

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
  }) async => switch (actionId) {
    'list' => await _listAction(),
    'open' => await _openAction(
      '${arguments['world']}',
      knobs: parseWorldKnobs(arguments['knobs'] as String?),
      hold: arguments['hold'] == true,
    ),
    // A world another process owns is asked there, in its own words.
    'status' || 'restart' || 'invoke' || 'close'
        when _open == null && openElsewhere() != null =>
      await _forward(openElsewhere()!, actionId, arguments),
    'status' => WorldStateResult.of(_required),
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
    return action == 'invoke'
        ? WorldActionResult.fromJson(json)
        : WorldStateResult.fromJson(
            json,
            note: action == 'close'
                ? 'Closed by the process that owned it (pid ${owner.pid}).'
                : '${owner.name} is open in another process (pid '
                      '${owner.pid}), which answered this.',
          );
  }

  /// What another process asks of the world open here.
  Future<Map<String, Object?>> _answerElsewhere(
    String action,
    Map<String, Object?> arguments,
  ) async {
    if (!const {'status', 'restart', 'invoke', 'close'}.contains(action)) {
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
    unawaited(_stopServingElsewhere());
    unawaited(_open?.close());
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
