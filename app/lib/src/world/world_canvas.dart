import 'dart:async';

// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../inspect/inspect_dock.dart';
import '../plugins/native/run_core.dart' show RunCore;
import '../ui/empty_state.dart';
import '../ui/theme.dart';
import '../ui/zoom_buttons.dart';
import 'live_guest.dart';
import 'open_world.dart';
import 'world_focus.dart';
import 'world_person.dart';
import 'world_stage.dart';
import 'world_toolbar.dart';
import 'world_trace.dart';

/// The open world under its header: one toolbar — the world's knobs and
/// actions, and who is in view — above everyone's devices side by side on
/// the stage, or one person in focus beside their panel; and along the
/// bottom, the dock whose first tab is the world's own log.
///
/// The devices sit on a [WorldStage], which gives every scroll, drag and
/// pinch to exactly one of the stage and an app.
class WorldCanvas extends StatefulWidget {
  const WorldCanvas({super.key, required this.world, this.run});

  final OpenWorld world;

  /// Run's core, whose views the focus shows of a person's app; null where
  /// the project declares no run plugin.
  final RunCore? run;

  @override
  State<WorldCanvas> createState() => _WorldCanvasState();
}

class _WorldCanvasState extends State<WorldCanvas> {
  final _view = StageView();
  Timer? _sharpen;
  WorldTracer? _tracer;
  StreamSubscription<void>? _heard;
  Timer? _redraw;

  /// The person in focus; null shows everyone.
  String? _focus;

  /// A mail open to read, by its message id.
  String? _reading;

  var _dockTab = 'log';
  var _dockCollapsed = true;

  /// Where Esc is heard: it closes a mail, then leaves the focus.
  final _keys = FocusNode(debugLabel: 'world canvas');

  @override
  void initState() {
    super.initState();
    _follow();
  }

  /// Once a zoom settles, each app renders for the size it is now drawn at.
  /// Not on every frame of a pinch: each is a new surface for the guest.
  void _magnify(Iterable<WorldPerson> people, double scale) {
    _sharpen?.cancel();
    _sharpen = Timer(const Duration(milliseconds: 200), () {
      for (var person in people) {
        if (person.guest case LiveWorldGuest live) live.magnify(scale);
      }
    });
  }

  @override
  void didUpdateWidget(WorldCanvas old) {
    super.didUpdateWidget(old);
    _follow();
  }

  /// Listens to the world's tracer — a new one with every opening — for the
  /// messages each person was sent.
  void _follow() {
    var tracer = widget.world.tracer;
    if (identical(tracer, _tracer)) return;
    _tracer = tracer;
    _reading = null;
    unawaited(_heard?.cancel());
    // A burst of events — a tap's dozen — is one redraw.
    _heard = tracer?.trace.changed.listen((_) {
      _redraw ??= Timer(const Duration(milliseconds: 150), () {
        _redraw = null;
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    unawaited(_heard?.cancel());
    _redraw?.cancel();
    _sharpen?.cancel();
    _view.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _escape() => setState(() {
    if (_reading == null) _focus = null;
    _reading = null;
  });

  void _focusOn(String? person) {
    setState(() {
      _focus = person;
      // A mail is someone's; it goes with them.
      _reading = null;
    });
    _keys.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    var world = widget.world;
    var people = world.people.keys.toList();
    Color colorOf(String? person) => switch (person) {
      worldActionsOwner => context.colors.ink2,
      var name? when people.contains(name) => context.colors.person(
        people.indexOf(name),
      ),
      _ => context.colors.mut2,
    };
    // Someone who left the world at a restart is no longer anyone to show.
    var focused = world.people[_focus];
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _escape},
      child: Focus(
        focusNode: _keys,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WorldToolbar(
              world: world,
              enabled: !world.phase.isMoving,
              focus: focused?.name,
              colorOf: colorOf,
              onFocus: _focusOn,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: switch (focused) {
                        _ when people.isEmpty => const EmptyState(
                          icon: Icons.person_outline,
                          title: 'Nobody yet',
                          message: 'People appear as the script declares them.',
                        ),
                        null => _stage(context, colorOf),
                        var person => PersonFocus(
                          key: ValueKey(person.name),
                          world: world,
                          person: person,
                          color: colorOf(person.name),
                          run: widget.run,
                          reading: _reading,
                          onRead: (id) {
                            setState(() => _reading = id);
                            _keys.requestFocus();
                          },
                          onScale: (scale) => _magnify([person], scale),
                        ),
                      },
                    ),
                    InspectDock(
                      tabs: [
                        InspectDockTab(
                          id: 'log',
                          label: 'World log',
                          icon: Icons.terminal,
                          body: (context) => _WorldLog(lines: world.logLines),
                        ),
                      ],
                      current: _dockTab,
                      collapsed: _dockCollapsed,
                      available: constraints.maxHeight,
                      onChanged: (current, collapsed) => setState(() {
                        _dockTab = current;
                        _dockCollapsed = collapsed;
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Everyone, on the stage, with the zoom on its corner.
  Widget _stage(BuildContext context, Color Function(String?) colorOf) {
    var world = widget.world;
    var trace = world.tracer?.trace;
    Map<String, int> countsOf(String person) {
      var counts = <String, int>{};
      for (var message
          in trace?.outbox(person: person, limit: 1 << 30) ??
              const <OutboxMessage>[]) {
        counts[message.kind] = (counts[message.kind] ?? 0) + 1;
      }
      return counts;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: WorldStage(
            people: world.people.keys.toList(),
            sizeOf: (name) => personSize(world.people[name]!),
            scales: (name) => hasApp(world.people[name]!),
            labelHeight: _tagHeight,
            view: _view,
            onScale: (scale) => _magnify(world.people.values, scale),
            onGround: _keys.requestFocus,
            person: (name, scale, ignores) {
              var person = world.people[name]!;
              return Column(
                children: [
                  SizedBox(
                    height: PersonTag.height,
                    child: Center(
                      // A tag wider than a device drawn small yields, rather
                      // than reaching over its neighbour's.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: PersonTag(
                          name: name,
                          color: colorOf(name),
                          counts: countsOf(name),
                          onTap: () => _focusOn(name),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: _tagHeight - PersonTag.height),
                  if (hasApp(person))
                    ScaledBox(
                      size: personSize(person),
                      scale: scale,
                      child: PersonDevice(
                        person: person,
                        scale: scale,
                        ignores: ignores,
                      ),
                    )
                  else
                    HeadlessCard(
                      name: name,
                      actions: actionsFor(name, world.actions.keys),
                    ),
                ],
              );
            },
          ),
        ),
        Positioned(
          right: FwSpacing.lg,
          bottom: FwSpacing.lg,
          child: ListenableBuilder(
            listenable: _view,
            builder: (context, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: context.colors.bg,
                borderRadius: BorderRadius.circular(context.radii.radius),
                boxShadow: context.elevation.sm,
              ),
              child: ZoomButtons(
                value: _view.zoom,
                onScale: _view.zoomBy,
                onFit: _view.reset,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// A person's tag and the room under it, above their device.
  static const _tagHeight = PersonTag.height + FwSpacing.md;
}

/// The world's own log — its script, its server, each app's build — in the
/// dock, the newest at the foot.
class _WorldLog extends StatelessWidget {
  const _WorldLog({required this.lines});

  /// Oldest first.
  final List<WorldLogLine> lines;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          'The world has logged nothing yet.',
          style: context.type.bodyMuted,
        ),
      );
    }
    var mono = context.type.mono;
    return SelectionArea(
      child: ListView.builder(
        // The newest at the foot, where a log is read from.
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
        itemCount: lines.length,
        itemBuilder: (context, i) {
          var line = lines[lines.length - 1 - i];
          return Container(
            color: i.isOdd ? colors.panel2 : null,
            padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    line.stamp,
                    textAlign: TextAlign.right,
                    style: mono.copyWith(color: colors.mut2),
                  ),
                ),
                const SizedBox(width: FwSpacing.lg),
                SizedBox(
                  width: 72,
                  child: Tooltip(
                    message: line.source,
                    // `world_lab.edges` is its logger's full name; the last
                    // part is what tells two apart.
                    child: Text(
                      line.source.split('.').last,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(color: colors.mut),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line.text,
                    style: mono.copyWith(color: colors.ink2),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
