import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../address/address_scope.dart';
import '../../ui/action_button.dart';
import '../../ui/code_block.dart';
import '../../ui/empty_state.dart';
import '../../ui/panel_header.dart';
import '../../ui/theme.dart';
import '../../world/live_guest.dart';
import '../../world/open_world.dart';
import '../../world/world_canvas.dart';
import '../../world/world_files.dart';
import '../native_plugin.dart';
import 'run_core.dart' show RunCore, runPluginId;
import 'run_plugin.dart' show RunPlugin;
import 'worlds_core.dart';

export 'worlds_core.dart' show WorldsCore, worldsPluginId;

/// The studio's Worlds panel: the worlds a project declares, and the one
/// open here — its people's apps live, side by side, taking the mouse and
/// keyboard when clicked, and each one's messages and Run's views of it a
/// click away ([WorldCanvas]).
class WorldsPlugin extends NativePlugin<WorldsCore> {
  WorldsPlugin(super.core) {
    // Opened here, a person's app draws here: so the worlds `fw` and the
    // MCP server are asked to open, the studio opens instead.
    unawaited(core.takeOpenings());
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

  /// A config edit gives the panel a new plugin under the same state, whose
  /// core nothing has read yet.
  @override
  void didUpdateWidget(_WorldsPanel old) {
    super.didUpdateWidget(old);
    if (old.plugin != widget.plugin) unawaited(plugin.core.computeAll());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: plugin,
    builder: (context, _) {
      var core = plugin.core;
      // The rail names a world by its address; the one open is the only
      // one a checkout has, and the address must not claim another.
      var asked = AddressScope.maybeOf(context) == null
          ? null
          : AddressScope.segments(context).firstOrNull;
      var other = core.worlds
          .where((world) => world.id == asked && world.id != core.open?.file.id)
          .firstOrNull;
      return switch ((core.open, other)) {
        (var open?, var other?) => _AnotherOpen(
          core: core,
          open: open,
          asked: other,
        ),
        (var open?, null) => _OpenWorldView(
          core: core,
          world: open,
          // Run's, for its views of each person's app.
          run: switch (plugin.peer(runPluginId)) {
            RunPlugin run => run.core,
            _ => null,
          },
        ),
        (null, _) => _WorldList(core: core),
      };
    },
  );
}

/// A world asked for by its address while another is open: a checkout has
/// one world at a time, so this says which is open and offers both ways on.
class _AnotherOpen extends StatelessWidget {
  const _AnotherOpen({
    required this.core,
    required this.open,
    required this.asked,
  });

  final WorldsCore core;
  final OpenWorld open;
  final WorldFile asked;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.public_outlined,
    title: '${asked.name} is not open',
    message:
        '${open.file.name} is, and a checkout opens one world at a time: two '
        'would give two people the same device in Run.',
    action: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FwActionButton(
          label: 'Back to ${open.file.name}',
          acknowledges: false,
          onPressed: () async =>
              AddressScope.write(context).setSegments([open.file.id]),
        ),
        const SizedBox(width: FwSpacing.sm),
        FwActionButton(
          label: 'Close it and open ${asked.name}',
          primary: true,
          onPressed: () async {
            await core.closeWorld();
            await core.openWorld(asked.id);
          },
        ),
      ],
    ),
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
  const _OpenWorldView({
    required this.core,
    required this.world,
    required this.run,
  });

  final WorldsCore core;
  final OpenWorld world;
  final RunCore? run;

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
          badge: _PhaseBadge(world.phase),
          subtitle: ['${world.file.package}/${world.file.path}'],
          selectableSubtitle: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FwActionButton(
                label: 'Reload',
                icon: Icons.refresh,
                plain: true,
                tooltip: world.reloading
                    ? 'Reloading…'
                    : 'Bring the script, its server and every app to the '
                          'code on disk: same people',
                onPressed: world.phase == WorldPhase.open && !world.reloading
                    ? _reload
                    : null,
              ),
              const SizedBox(width: FwSpacing.xs),
              FwActionButton(
                label: 'Restart',
                icon: Icons.restart_alt,
                plain: true,
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
        Expanded(
          child: WorldCanvas(world: world, run: run),
        ),
      ],
    );
  }
}

/// Where the world is, beside its name: `● Open`.
class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge(this.phase);

  final WorldPhase phase;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var color = switch (phase) {
      WorldPhase.open => colors.grn,
      WorldPhase.failed => colors.red,
      _ => colors.mut,
    };
    var word = switch (phase) {
      WorldPhase.opening => 'Opening',
      WorldPhase.open => 'Open',
      WorldPhase.restarting => 'Restarting',
      WorldPhase.failed => 'Failed',
      WorldPhase.closing => 'Closing',
      WorldPhase.closed => 'Closed',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: FwSpacing.xs),
        Text(
          word,
          style: context.type.caption.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
