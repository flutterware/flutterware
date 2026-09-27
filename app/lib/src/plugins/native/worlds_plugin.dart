import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../ui/action_button.dart';
import '../../ui/code_block.dart';
import '../../ui/empty_state.dart';
import '../../ui/panel_header.dart';
import '../../ui/picker.dart';
import '../../ui/theme.dart';
import '../../world/live_guest.dart';
import '../../world/open_world.dart';
import '../../world/world_canvas.dart';
import '../../world/world_files.dart';
import '../native_plugin.dart';
import 'worlds_core.dart';

export 'worlds_core.dart' show WorldsCore, worldsPluginId;

/// The studio's Worlds panel: the worlds a project declares, and the one
/// open here on its canvas — its people's apps live, taking the mouse and
/// keyboard when clicked, above the system they use, with each step taken
/// on them traced through it ([WorldCanvas]).
class WorldsPlugin extends NativePlugin<WorldsCore> {
  WorldsPlugin(super.core) {
    // Opened here, a person's app draws here.
    core.guests = (person) => LiveWorldGuest(
      appRoot: host.workspace.appContext.appToolDirectory.path,
      flutterSdkRoot: host.workspace.flutterSdk.root,
      pixelRatio: () => WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .devicePixelRatio,
    );
  }

  @override
  String? get busyWith => switch (core.open?.phase) {
    WorldPhase.opening => 'opening ${core.open!.file.name}',
    WorldPhase.restarting => 'restarting ${core.open!.file.name}',
    WorldPhase.closing => 'closing ${core.open!.file.name}',
    _ => null,
  };

  /// The panel is the list and the open world; no child is a place of its
  /// own yet.
  @override
  List<String>? get railLanding => const [];

  @override
  Widget buildPanel(BuildContext context) => _WorldsPanel(plugin: this);
}

class _WorldsPanel extends StatefulWidget {
  const _WorldsPanel({required this.plugin});

  final WorldsPlugin plugin;

  @override
  State<_WorldsPanel> createState() => _WorldsPanelState();
}

class _WorldsPanelState extends State<_WorldsPanel> {
  WorldsPlugin get plugin => widget.plugin;

  /// Read again whenever the panel is shown: a folder listing, cheap enough
  /// that a world written a moment ago never needs a refresh button.
  @override
  void initState() {
    super.initState();
    unawaited(plugin.core.computeAll());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: plugin,
    builder: (context, _) {
      var core = plugin.core;
      return switch (core.open) {
        var open? => _OpenWorldView(core: core, world: open),
        null => _WorldList(core: core),
      };
    },
  );
}

/// Every world the project declares, each with a way to open it.
class _WorldList extends StatelessWidget {
  const _WorldList({required this.core});

  final WorldsCore core;

  @override
  Widget build(BuildContext context) {
    var elsewhere = core.openElsewhere();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FwPanelHeader(
          'No world open',
          subtitle: ['Several people on your real server, set up by a script'],
        ),
        if (elsewhere != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              panelGutter,
              0,
              panelGutter,
              FwSpacing.lg,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${elsewhere.name} is open in another process (pid '
                    '${elsewhere.pid}), `fw` or the MCP server, which owns it. '
                    'Its people are Run apps, in pictures.',
                    style: context.type.bodyMuted,
                  ),
                ),
                const SizedBox(width: FwSpacing.md),
                FwActionButton(
                  label: 'Close it',
                  tooltip: 'Ask the process that owns it to close it',
                  onPressed: () async {
                    try {
                      await core.invoke('close');
                    } on Object {
                      // It went on its own; the list says so either way.
                    }
                  },
                ),
              ],
            ),
          ),
        Expanded(
          child: core.worlds.isEmpty
              ? const _NoWorlds()
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: panelGutter),
                  children: [
                    for (var world in core.worlds)
                      _WorldRow(
                        world: world,
                        onOpen: elsewhere == null && world.problem == null
                            ? () => core.openWorld(world.id)
                            : null,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _WorldRow extends StatelessWidget {
  const _WorldRow({required this.world, required this.onOpen});

  final WorldFile world;
  final Future<void> Function()? onOpen;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.lg),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(world.name, style: context.type.bodyStrong),
              if (world.description case var description?)
                Text(description, style: context.type.body),
              Text(
                '${world.package}/${world.path}',
                style: context.type.bodyMuted,
              ),
              if (world.problem case var problem?)
                Text(
                  problem,
                  style: context.type.body.copyWith(color: context.colors.red),
                ),
            ],
          ),
        ),
        const SizedBox(width: FwSpacing.lg),
        FwActionButton(label: 'Open', primary: true, onPressed: onOpen),
      ],
    ),
  );
}

/// A project that declares no world yet: what one is, and the line that
/// declares it.
class _NoWorlds extends StatelessWidget {
  const _NoWorlds();

  static const _declaration = """
fw.use(Worlds(packages: [
  .new(server, worlds: [
    WorldScript('tool/worlds/pickup_order.dart', name: 'Pickup order'),
  ]),
]));""";

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No worlds yet', style: context.type.bodyStrong),
          const SizedBox(height: FwSpacing.sm),
          Text(
            'A world is a script whose main calls World.run, in the package '
            "that can start your server — for a Dart server, the server's "
            'own. Declare each one in tool/flutterware.dart:',
            style: context.type.body,
          ),
          const SizedBox(height: FwSpacing.md),
          const FwCodeBlock(_declaration, language: 'dart'),
        ],
      ),
    ),
  );
}

/// The open world: what it is doing, what can be done to it, and its people.
class _OpenWorldView extends StatelessWidget {
  const _OpenWorldView({required this.core, required this.world});

  final WorldsCore core;
  final OpenWorld world;

  Future<void> _reload() async {
    try {
      await world.reload();
    } on WorldRefusal {
      // Said in the world's log, where it shows.
    }
  }

  @override
  Widget build(BuildContext context) {
    var moving = world.phase.isMoving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwPanelHeader(
          world.file.name,
          subtitle: [
            world.phase.name,
            '${world.file.package}/${world.file.path}',
          ],
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FwActionButton(
                label: 'Reload',
                tooltip:
                    'Bring the script, its server and every app to the code '
                    'on disk: same people',
                onPressed: world.phase == WorldPhase.open ? _reload : null,
              ),
              const SizedBox(width: FwSpacing.sm),
              FwActionButton(
                label: 'Restart',
                tooltip: 'Run the script again: new people, same apps',
                onPressed: moving ? null : () => world.restart(),
              ),
              const SizedBox(width: FwSpacing.sm),
              FwActionButton(
                label: 'Close',
                onPressed: world.phase == WorldPhase.closing
                    ? null
                    : core.closeWorld,
              ),
            ],
          ),
          below: _Controls(world: world, enabled: !moving),
        ),
        if (world.problem case var problem?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              panelGutter,
              0,
              panelGutter,
              FwSpacing.md,
            ),
            child: SelectableText(
              problem,
              style: context.type.body.copyWith(color: context.colors.red),
            ),
          ),
        _Log(lines: world.log),
        Expanded(
          child: world.people.isEmpty
              ? const EmptyState(
                  icon: Icons.person_outline,
                  title: 'Nobody yet',
                  message: 'People appear as the script declares them.',
                )
              : WorldCanvas(world: world),
        ),
      ],
    );
  }
}

/// The world's knobs, each a restart with a new value, and its actions.
class _Controls extends StatelessWidget {
  const _Controls({required this.world, required this.enabled});

  final OpenWorld world;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (world.knobs.isEmpty && world.actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: FwSpacing.lg,
      runSpacing: FwSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var knob in world.knobs.values)
          if (knob.options.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(knob.name, style: context.type.bodyMuted),
                const SizedBox(width: FwSpacing.sm),
                SizedBox(
                  width: 160,
                  child: FwPicker<String>(
                    choices: [
                      for (var option in knob.options)
                        FwChoice(value: option, label: option),
                    ],
                    selected: knob.value,
                    onChanged: (value) {
                      if (!enabled || value == knob.value) return;
                      unawaited(
                        world.restart({...world.knobValues, knob.name: value}),
                      );
                    },
                  ),
                ),
              ],
            ),
        for (var MapEntry(key: action, value: description)
            in world.actions.entries)
          // A button fills the width it is given, and a Wrap gives it the
          // whole row; a Row asks it for its own.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FwActionButton(
                label: action,
                tooltip: description,
                onPressed: enabled ? () async => world.invoke(action) : null,
              ),
            ],
          ),
      ],
    );
  }
}

/// The script's last lines — its progress, and what its server printed.
class _Log extends StatelessWidget {
  const _Log({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    var last = lines.length > 4 ? lines.sublist(lines.length - 4) : lines;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: panelGutter),
      child: SelectableText(
        last.join('\n'),
        maxLines: 4,
        style: context.type.mono.copyWith(color: context.colors.mut2),
      ),
    );
  }
}
