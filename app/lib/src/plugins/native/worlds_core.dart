import 'dart:async';
import 'dart:io';

import 'package:flutterware/plugins.dart';

import '../../run/entrypoints.dart';
import '../../run/handle.dart';
import '../../utils/run_dir.dart';
import '../../world/open_world.dart';
import '../../world/world_files.dart';
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
/// same device, `studio-<name>`, in Run.
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
          'this process: it closes when this process does.',
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
    'list' => WorldListResult(
      worlds: [for (var world in _worlds) WorldListEntry.of(world)],
      open: _open?.file.id,
    ),
    'open' => await _openAction(
      '${arguments['world']}',
      knobs: parseWorldKnobs(arguments['knobs'] as String?),
      hold: arguments['hold'] == true,
    ),
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
        '$other is open in another process on this worktree — the studio, '
        '`fw` or the MCP server that opened it. Close it there first: its '
        'people hold their devices.',
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
    await opened.open(knobs);
    return opened;
  }

  /// Closes the world open here.
  Future<void> closeWorld() async {
    var open = _open;
    if (open == null) return;
    await open.close();
    if (_open == open) _open = null;
    notifyChanged();
  }

  /// A world another process opened on this worktree, as its people's Run
  /// handles say — whoever opened it owns it, so this one cannot.
  ///
  /// The handles name the world but not its owner: each is announced by the
  /// guest it describes, so the pid on it is one person's app.
  String? openElsewhere() {
    var own = {
      for (var person in _open?.people.values ?? const <WorldPerson>[])
        ?person.guest?.pid,
    };
    for (var handle in scanRunHandles(flutterwareRunDir())) {
      if (handle.world case var world?
          when handle.worktree == host.worktree.path &&
              !own.contains(handle.launcherPid) &&
              isProcessAlive(handle.launcherPid)) {
        return world;
      }
    }
    return null;
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
      await ProcessSignal.sigint.watch().first;
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
    if (openElsewhere() case var other?) {
      throw WorldRefusal(
        '$other is open in another process — the studio, `fw` or the MCP '
        'server that opened it — which owns it: its people are Run apps you '
        'can drive, but only that process can restart or close it.',
      );
    }
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
