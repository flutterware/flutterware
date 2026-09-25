import 'dart:async';
import 'dart:math';

import 'package:flutterware/world.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/action_button.dart';
import '../../ui/code_block.dart';
import '../../ui/empty_state.dart';
import '../../ui/panel_header.dart';
import '../../ui/picker.dart';
import '../../ui/theme.dart';
import '../../world/live_guest.dart';
import '../../world/open_world.dart';
import '../../world/world_files.dart';
import '../../world/world_views.dart';
import '../native_plugin.dart';
import 'worlds_core.dart';

export 'worlds_core.dart' show WorldsCore, worldsPluginId;

/// The studio's Worlds panel: the worlds a project declares, and the one
/// open here — its people side by side, each app live and taking the mouse
/// and keyboard when it is clicked.
///
/// A plain row rather than the canvas the design draws, which is slice 2:
/// what this has to show is that a world opens, that its people are real
/// apps against the real server, and that it restarts and closes.
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
            child: Text(
              '${elsewhere.world} is open in another process (pid '
              '${elsewhere.pid}), which owns it. Its people are Run apps, '
              'in pictures; only that process can restart or close it.',
              style: context.type.bodyMuted,
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
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // Every phone at one scale, the tallest filling the
                    // height: a world is looked at whole, and a phone cut off
                    // at the bottom of the panel hides what its app is saying.
                    var tallest = world.people.values
                        .map((person) => _deviceOf(person).height)
                        .fold(0.0, max);
                    var room =
                        constraints.maxHeight -
                        FwSpacing.md -
                        FwSpacing.lg -
                        _PersonView.labelHeight;
                    var scale = tallest == 0 ? 1.0 : min(1.0, room / tallest);
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(
                        panelGutter,
                        FwSpacing.md,
                        panelGutter,
                        FwSpacing.lg,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var person in world.people.values)
                            Padding(
                              padding: const EdgeInsets.only(
                                right: FwSpacing.xxl,
                              ),
                              child: _PersonView(person: person, scale: scale),
                            ),
                        ],
                      ),
                    );
                  },
                ),
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

/// One person: who they are, their app, and what it did through the
/// platform the studio answers.
class _PersonView extends StatelessWidget {
  const _PersonView({required this.person, required this.scale});

  final WorldPerson person;

  /// How much smaller than the device the phone is drawn — its logical size
  /// is the device's whatever this is, so its layout is the one the device
  /// would have.
  final double scale;

  /// The name and identity above the phone.
  static const labelHeight = 72.0;

  @override
  Widget build(BuildContext context) {
    var spec = person.spec;
    var device = _deviceOf(person);
    var size = Size(device.width, device.height);
    var identity = [?spec.email, ?spec.phone].join(' · ');
    var guest = person.guest;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(person.name, style: context.type.bodyStrong),
            SelectableText(
              [
                if (identity.isNotEmpty) identity,
                if (spec.app case var app?)
                  '${app.entrypoint} · ${device.label}',
              ].join('\n'),
              style: context.type.bodyMuted,
            ),
            const SizedBox(height: FwSpacing.sm),
            _Scaled(
              size: size,
              scale: scale,
              child: switch ((person.phase, guest)) {
                (PersonPhase.headless, _) => _Placeholder(
                  size: size,
                  text: 'No app: the script acts for ${person.name}.',
                ),
                (PersonPhase.failed, _) => _Placeholder(
                  size: size,
                  text: person.problem ?? 'Failed',
                  error: true,
                ),
                (_, LiveWorldGuest live) when live.engine != null => WorldPhone(
                  guest: live,
                  size: size,
                  platform: person.platform,
                ),
                (PersonPhase.building, _) => _Placeholder(
                  size: size,
                  text: 'Building ${spec.app?.entrypoint}',
                ),
                _ => _Placeholder(size: size, text: 'Starting'),
              },
            ),
          ],
        ),
        if (person.platform case var platform? when person.running) ...[
          const SizedBox(width: FwSpacing.lg),
          Padding(
            padding: const EdgeInsets.only(top: 44),
            child: SizedBox(
              width: 220,
              child: WorldPlatformPanel(
                person: person.name,
                platform: platform,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

Device _deviceOf(WorldPerson person) => switch (person.spec.on) {
  Studio(:var device) => device,
};

/// [child] laid out at [size] and drawn [scale] times as large. A pointer
/// over it still lands where it should: hit testing undoes the same
/// transform, so the guest's input region reads positions in its own size.
class _Scaled extends StatelessWidget {
  const _Scaled({required this.size, required this.scale, required this.child});

  final Size size;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size.width * scale,
    height: size.height * scale,
    child: FittedBox(
      child: SizedBox.fromSize(size: size, child: child),
    ),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.size,
    required this.text,
    this.error = false,
  });

  final Size size;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    width: size.width,
    height: size.height,
    decoration: BoxDecoration(
      color: context.colors.panel,
      borderRadius: BorderRadius.circular(context.radii.radiusLarge),
      border: Border.all(color: context.colors.line, width: 2),
    ),
    child: WorldPhoneNote(text, error: error),
  );
}
