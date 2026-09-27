import 'dart:async';
import 'dart:math';

// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;
import 'package:flutterware/world.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../previews/stage_zoom.dart';
import '../ui/panel_header.dart' show panelGutter;
import '../ui/tappable.dart';
import '../ui/theme.dart';
import '../ui/zoom_buttons.dart';
import 'live_guest.dart';
import 'open_world.dart';
import 'world_trace.dart';
import 'world_views.dart';

/// The open world as the design draws it: its people's phones on a stage,
/// the system they use in a band beneath them, and the steps taken on the
/// phones in a column beside — the chosen one numbered through the system
/// and drawn as lines between each phone and the part it touched.
///
/// Everything drawn is what the world recorded (`WorldTrace`): the servers'
/// parts are the ones they reported, a line is a request, a reach or a record
/// that arrived. Nothing is declared or guessed.
///
/// Until a step is chosen the stage follows the newest one that caused
/// something, so a tap on a phone lights what it caused as it happens. A
/// part of the system opens, in the column, on what it holds.
///
/// At rest the stage fits every phone and the whole system; a pinch or a
/// ⌘-scroll zooms into it, and a drag pans it once zoomed — the previews'
/// [ZoomableStage], whose rule for which gestures are the stage's the
/// phones follow too, so a scroll over a phone still scrolls its app.
class WorldCanvas extends StatefulWidget {
  const WorldCanvas({super.key, required this.world});

  final OpenWorld world;

  @override
  State<WorldCanvas> createState() => _WorldCanvasState();
}

class _WorldCanvasState extends State<WorldCanvas> {
  final _ends = TraceAnchors();
  final _scroll = ScrollController();
  final _zoom = TransformationController();

  /// True while a drag is moving the zoomed stage, which the phones under it
  /// must then not take as a drag of their own.
  final _panning = ValueNotifier(false);

  /// How much smaller than life the phones are drawn to fit the stage, as
  /// its last layout worked out; the zoom multiplies it.
  var _fit = 1.0;
  Timer? _sharpen;
  WorldTracer? _tracer;
  StreamSubscription<void>? _heard;
  Timer? _redraw;

  /// The step chosen in the column; null follows the newest.
  String? _chosen;

  /// The person whose drawer the column shows.
  String? _drawer;

  /// The node of the system whose contents the column shows.
  String? _opened;

  /// Whether the step chosen was chosen from [_opened]'s contents, and shows
  /// over them until its back goes to them again.
  var _overContents = false;

  @override
  void initState() {
    super.initState();
    _follow();
    _zoom.addListener(_zoomed);
  }

  /// Once a zoom settles, each phone renders for the size it is now drawn
  /// at. Not on every frame of a pinch: each is a new surface for the guest.
  void _zoomed() {
    _sharpen?.cancel();
    _sharpen = Timer(const Duration(milliseconds: 200), () {
      var onScreen = _fit * _zoom.value.getMaxScaleOnAxis();
      for (var person in widget.world.people.values) {
        if (person.guest case LiveWorldGuest live) live.magnify(onScreen);
      }
    });
  }

  @override
  void didUpdateWidget(WorldCanvas old) {
    super.didUpdateWidget(old);
    _follow();
  }

  /// Listens to the world's tracer — a new one with every opening, whose
  /// steps are the new people's, so a step chosen from the last is let go.
  void _follow() {
    var tracer = widget.world.tracer;
    if (identical(tracer, _tracer)) return;
    _tracer = tracer;
    _chosen = null;
    _opened = null;
    _overContents = false;
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
    _scroll.dispose();
    _zoom.dispose();
    _panning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var world = widget.world;
    var trace = world.tracer?.trace;
    var people = world.people.keys.toList();
    // The world's own actions light the system in ink: nobody's colour, and
    // still plainly lit.
    Color colorOf(String? person) => switch (person) {
      worldActionsOwner => context.colors.ink2,
      var name? when people.contains(name) => context.colors.person(
        people.indexOf(name),
      ),
      _ => context.colors.mut2,
    };

    var steps = trace?.steps(limit: 60) ?? const <TracedStep>[];
    // Followed, the newest step that did something: a tap that changed
    // nothing but the phone would otherwise wipe what the last one caused.
    var shown = _chosen == null
        ? steps.lastWhere(
            (traced) => traced.beats.isNotEmpty,
            orElse: () => steps.lastOrNull ?? _none,
          )
        : steps.where((traced) => traced.step.id == _chosen).firstOrNull ??
              // Chosen from a part's contents, older than the column lists.
              trace?.steps(step: _chosen, limit: 1).firstOrNull;
    if (identical(shown, _none)) shown = null;
    var numbers = shown == null ? const <String, int>{} : numberNodes(shown);

    var drawer = _drawer == null ? null : world.people[_drawer];
    var contents = switch (_opened) {
      var node? => trace?.contentsOf(node),
      null => null,
    };
    var engine = world.people.keys
        .map((person) => world.tracer?.syncOf(person)?['engine'])
        .nonNulls
        .firstOrNull;
    var label = contents == null
        ? null
        : contentsLabel(contents, engine: engine?.toString());
    void choose(String step) => setState(() {
      _chosen = step;
      _overContents = true;
    });
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, viewport) => Stack(
              children: [
                ZoomableStage(
                  controller: _zoom,
                  onInteracting: (panning) => _panning.value = panning,
                  child: _stage(
                    context,
                    trace: trace,
                    people: people,
                    colorOf: colorOf,
                    shown: shown,
                    numbers: numbers,
                  ),
                ),
                Positioned(
                  right: FwSpacing.md,
                  top: FwSpacing.sm,
                  child: ListenableBuilder(
                    listenable: _zoom,
                    builder: (context, _) => ZoomButtons(
                      value: _zoom.value.getMaxScaleOnAxis(),
                      onScale: (factor) => _zoomAbout(
                        factor,
                        viewport.biggest.center(Offset.zero),
                      ),
                      onFit: () => _zoom.value = Matrix4.identity(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: context.colors.line),
        SizedBox(
          width: 340,
          // What was opened last is on top: a step over the contents it was
          // chosen from, the contents over a step held before them.
          child: switch ((drawer, _chosen, contents)) {
            (var person?, _, _) => _Drawer(
              person: person,
              color: colorOf(person.name),
              sync: world.tracer?.syncOf(person.name),
              onClose: () => setState(() => _drawer = null),
            ),
            (null, var chosen?, var contents)
                when shown?.step.id == chosen &&
                    (contents == null || _overContents) =>
              TraceDetail(
                traced: shown!,
                numbers: numbers,
                colorOf: colorOf,
                back: label ?? 'Steps',
                onBack: () => setState(() {
                  if (contents != null) {
                    _overContents = false;
                  } else {
                    _chosen = null;
                  }
                }),
              ),
            (null, _, var contents?) => NodeContentsView(
              contents: contents,
              label: label!,
              colorOf: colorOf,
              shown: shown?.step.id,
              markColor: colorOf(shown?.step.person),
              onBack: () => setState(() => _opened = null),
              onChoose: choose,
            ),
            _ => TraceList(
              steps: steps.reversed.toList(),
              colorOf: colorOf,
              following: shown?.step.id,
              onChoose: (id) => setState(() => _chosen = id),
            ),
          },
        ),
      ],
    );
  }

  /// The phones, the system beneath them and the lines between — one
  /// picture, which the stage above zooms as one.
  Widget _stage(
    BuildContext context, {
    required WorldTrace? trace,
    required List<String> people,
    required Color Function(String? person) colorOf,
    required TracedStep? shown,
    required Map<String, int> numbers,
  }) {
    var world = widget.world;
    return _ends.stage(
      Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _People(
                  world: world,
                  scroll: _scroll,
                  colorOf: colorOf,
                  anchors: _ends,
                  // What the stage keeps for itself, the phones leave alone:
                  // the same rule the stage applies, so the two agree.
                  ignores: (event) => _panning.value || stageOwnsPointer(event),
                  onFit: (fit) => _fit = fit,
                  onOpen: (person) => setState(() => _drawer = person),
                ),
              ),
              if (trace != null)
                SystemBand(
                  servers: trace.servers.toList(),
                  sync: {
                    for (var person in people)
                      person: ?world.tracer?.syncOf(person),
                  },
                  numbers: numbers,
                  litColor: colorOf(shown?.step.person),
                  colorOf: colorOf,
                  anchors: _ends,
                  opened: _opened,
                  onOpen: (node) => setState(() {
                    _opened = _opened == node ? null : node;
                    _overContents = false;
                  }),
                ),
            ],
          ),
          if (shown != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: TraceLinesPainter(
                    beats: shown.beats,
                    anchors: _ends,
                    colorOf: colorOf,
                    label: context.type.micro.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    pill: context.colors.bg,
                    pillBorder: context.colors.line,
                    repaint: _scroll,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Zooms by [factor] about [focal], a point of the viewport — the buttons'
  /// way in, where a gesture's is [ZoomableStage]'s own. Back at life-size
  /// the stage is at rest again: everything fitted.
  void _zoomAbout(double factor, Offset focal) {
    var matrix = _zoom.value.clone();
    var current = matrix.getMaxScaleOnAxis();
    var next = (current * factor).clamp(1.0, 8.0);
    if (next <= zoomFloor) {
      _zoom.value = Matrix4.identity();
      return;
    }
    Offset scene(Matrix4 m) =>
        MatrixUtils.transformPoint(Matrix4.inverted(m), focal);
    var before = scene(matrix);
    matrix.scaleByDouble(next / current, next / current, 1, 1);
    var after = scene(matrix);
    matrix.translateByDouble(after.dx - before.dx, after.dy - before.dy, 0, 1);
    _zoom.value = matrix;
  }
}

/// No step: what [List.lastWhere] falls back to on an empty list.
final TracedStep _none = (step: TraceStep('', ''), beats: const []);

/// Each node [traced] touched, numbered in the order it first did — the
/// numbers the band shows on the parts and the column beside the beats.
Map<String, int> numberNodes(TracedStep traced) {
  var numbers = <String, int>{};
  for (var beat in traced.beats) {
    if (beat.node case var node?) {
      numbers.putIfAbsent(node, () => numbers.length + 1);
    }
  }
  return numbers;
}

/// The people's phones side by side, at one scale, the tallest filling the
/// height: a world is looked at whole, and a phone cut off at the bottom of
/// the stage hides what its app is saying.
class _People extends StatelessWidget {
  const _People({
    required this.world,
    required this.scroll,
    required this.colorOf,
    required this.anchors,
    required this.ignores,
    required this.onFit,
    required this.onOpen,
  });

  final OpenWorld world;
  final ScrollController scroll;
  final Color Function(String? person) colorOf;
  final TraceAnchors anchors;

  /// Pointer events the stage keeps, which no phone acts on.
  final bool Function(PointerEvent event) ignores;

  /// Told the scale the phones are drawn at, each layout.
  final void Function(double fit) onFit;
  final void Function(String person) onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      var tallest = world.people.values
          .map((person) => deviceOf(person).height)
          .fold(0.0, max);
      var room =
          constraints.maxHeight -
          FwSpacing.md -
          wireGap -
          _PersonView.labelHeight;
      var scale = tallest == 0 ? 1.0 : min(1.0, room / tallest);
      onFit(scale);
      return SingleChildScrollView(
        controller: scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          panelGutter,
          FwSpacing.md,
          panelGutter,
          wireGap,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var person in world.people.values)
              Padding(
                padding: const EdgeInsets.only(right: FwSpacing.xxl),
                child: _PersonView(
                  person: person,
                  scale: scale,
                  color: colorOf(person.name),
                  anchors: anchors,
                  ignores: ignores,
                  onOpen: () => onOpen(person.name),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// The room between the phones and the system, where the words on the lines
/// are written: a label on a part of the system would hide the part.
const wireGap = 56.0;

/// The anchor id of [person]'s phone, beside the system's node ids.
String personAnchor(String person) => 'person/$person';

/// One person: who they are, above their app. Their name opens their drawer:
/// what their app did through the platform, and where its data stands.
class _PersonView extends StatelessWidget {
  const _PersonView({
    required this.person,
    required this.scale,
    required this.color,
    required this.anchors,
    required this.ignores,
    required this.onOpen,
  });

  final WorldPerson person;

  /// How much smaller than the device the phone is drawn — its logical size
  /// is the device's whatever this is, so its layout is the one the device
  /// would have.
  final double scale;
  final Color color;
  final TraceAnchors anchors;
  final bool Function(PointerEvent event) ignores;
  final VoidCallback onOpen;

  /// The name and identity above the phone.
  static const labelHeight = 72.0;

  @override
  Widget build(BuildContext context) {
    var spec = person.spec;
    var device = deviceOf(person);
    var size = Size(device.width, device.height);
    var identity = [?spec.email, ?spec.phone].join(' · ');
    var shown = person.platform?.notifications.shown.length ?? 0;
    var guest = person.guest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: labelHeight - FwSpacing.sm,
          width: size.width * scale,
          child: Tappable(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(context.radii.radius),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Dot(color),
                    const SizedBox(width: FwSpacing.xs),
                    Flexible(
                      child: Text(
                        person.name,
                        style: context.type.bodyStrong,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (shown > 0) ...[
                      const SizedBox(width: FwSpacing.sm),
                      Text(
                        shown == 1 ? '1 notification' : '$shown notifications',
                        style: context.type.caption.copyWith(color: color),
                      ),
                    ],
                  ],
                ),
                for (var line in [
                  if (identity.isNotEmpty) identity,
                  if (spec.app case var app?)
                    '${app.entrypoint} · ${device.label}',
                ])
                  Text(
                    line,
                    style: context.type.bodyMuted,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: FwSpacing.sm),
        anchors.wrap(
          personAnchor(person.name),
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
                shouldIgnorePointer: ignores,
              ),
              (PersonPhase.building, _) => _Placeholder(
                size: size,
                text: 'Building ${spec.app?.entrypoint}',
              ),
              _ => _Placeholder(size: size, text: 'Starting'),
            },
          ),
        ),
      ],
    );
  }
}

Device deviceOf(WorldPerson person) => switch (person.spec.on) {
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

/// The system the people use, as its servers reported it since the world
/// opened: each server with the parts of its API, the tables it wrote and
/// what it sent outside; beside them the sync engine, when the apps' own
/// databases say one keeps them in step.
///
/// [numbers] marks what the shown step touched, in the order it did.
class SystemBand extends StatelessWidget {
  const SystemBand({
    super.key,
    required this.servers,
    required this.sync,
    required this.numbers,
    required this.litColor,
    required this.colorOf,
    required this.anchors,
    this.opened,
    this.onOpen,
  });

  final List<SystemServer> servers;

  /// Each person's sync state, for those whose app reads one.
  final Map<String, Map<String, Object?>> sync;
  final Map<String, int> numbers;
  final Color litColor;
  final Color Function(String? person) colorOf;

  /// Where each part registers, for the lines to find it.
  final TraceAnchors anchors;

  /// The node whose contents the column shows.
  final String? opened;

  /// Shows what a node holds; null draws the band for looking at only.
  final void Function(String node)? onOpen;

  @override
  Widget build(BuildContext context) {
    var onOpen = this.onOpen ?? (_) {};
    var engine = sync.values
        .map((state) => state['engine'])
        .nonNulls
        .firstOrNull;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        panelGutter,
        0,
        panelGutter,
        panelGutter,
      ),
      padding: const EdgeInsets.all(FwSpacing.md),
      decoration: BoxDecoration(
        color: context.colors.panel,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
      ),
      constraints: const BoxConstraints(maxHeight: 340),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Clear of the first channel, which runs down the band's left.
            Padding(
              padding: const EdgeInsets.only(left: channelWidth),
              child: Text('The system', style: context.type.sectionLabel),
            ),
            const SizedBox(height: FwSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: servers.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(left: channelWidth),
                          child: Text(
                            'No server has reported yet. A Dart server takes '
                            'part through its inspection adapter.',
                            style: context.type.bodyMuted,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var (i, server) in servers.indexed)
                              Padding(
                                padding: EdgeInsets.only(
                                  top: i == 0 ? 0 : FwSpacing.md,
                                ),
                                child: _ServerCard(
                                  server: server,
                                  numbers: numbers,
                                  litColor: litColor,
                                  anchors: anchors,
                                  opened: opened,
                                  onOpen: onOpen,
                                ),
                              ),
                          ],
                        ),
                ),
                if (engine != null) ...[
                  const SizedBox(width: channelWidth),
                  anchors.wrap(
                    syncNode,
                    _SyncCard(
                      engine: '$engine',
                      sync: sync,
                      number: numbers[syncNode],
                      litColor: litColor,
                      colorOf: colorOf,
                      open: opened == syncNode,
                      onOpen: () => onOpen(syncNode),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The room between two columns of parts, where the lines run down to the
/// part they reach, so that no line crosses a part on its way.
const channelWidth = 16.0;

/// One server — a process — and its parts, grouped by kind.
class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.numbers,
    required this.litColor,
    required this.anchors,
    required this.opened,
    required this.onOpen,
  });

  final SystemServer server;
  final Map<String, int> numbers;
  final Color litColor;
  final TraceAnchors anchors;
  final String? opened;
  final void Function(String node) onOpen;

  @override
  Widget build(BuildContext context) {
    var requests = server.parts.values.fold(0, (sum, n) => sum + n);
    Widget chip(String node, Widget label, String count) => anchors.wrap(
      node,
      _Part(
        number: numbers[node],
        litColor: litColor,
        count: count,
        open: opened == node,
        onOpen: () => onOpen(node),
        child: label,
      ),
    );
    var api = [
      for (var MapEntry(key: part, value: n) in server.parts.entries)
        chip(server.partNode(part), _PartLabel(part), '×$n'),
    ];
    var sides = [
      if (server.tables.isNotEmpty)
        (
          'Data',
          [
            for (var MapEntry(key: table, value: keys) in server.tables.entries)
              chip(
                server.tableNode(table),
                Text(table, style: context.type.mono),
                keys.length == 1 ? '1 record' : '${keys.length} records',
              ),
          ],
        ),
      if (server.sent.isNotEmpty)
        (
          'Outside',
          [
            for (var MapEntry(key: channel, value: n) in server.sent.entries)
              chip(
                server.sentNode(channel),
                Text(switch (channel) {
                  'sms' => 'SMS',
                  'push' => 'Push',
                  var other => other,
                }, style: context.type.body),
                '$n sent',
              ),
          ],
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(FwSpacing.sm),
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radii.radius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // As many columns as the width holds, and the data and what went
          // outside in a column of their own beside them when two fit.
          const column = _Part.width + channelWidth;
          var width = constraints.maxWidth;
          var beside =
              api.isNotEmpty &&
              sides.isNotEmpty &&
              width >= 3 * column - channelWidth;
          var columns = max(
            1,
            ((width - (beside ? column : 0) + channelWidth) / column).floor(),
          );
          Widget grid(List<Widget> chips, int columns) => SizedBox(
            width: columns * column - channelWidth,
            child: Wrap(spacing: channelWidth, runSpacing: 6, children: chips),
          );
          var side = [
            for (var (label, chips) in sides)
              _Group(label, child: grid(chips, beside ? 1 : columns)),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: FwIconSize.sm,
                    color: context.colors.ink2,
                  ),
                  const SizedBox(width: FwSpacing.xs),
                  Text(server.name, style: context.type.bodyStrong),
                  const SizedBox(width: FwSpacing.sm),
                  Text(
                    requests == 1 ? '1 request' : '$requests requests',
                    style: context.type.bodyMuted,
                  ),
                ],
              ),
              if (beside)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Group('API', child: grid(api, columns)),
                    const SizedBox(width: channelWidth),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: side,
                    ),
                  ],
                )
              else ...[
                if (api.isNotEmpty) _Group('API', child: grid(api, columns)),
                ...side,
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A route as the adapter names it: the method, then the path with its ids
/// folded — `POST /orders/:id/advance`.
class _PartLabel extends StatelessWidget {
  const _PartLabel(this.part);

  final String part;

  @override
  Widget build(BuildContext context) {
    var space = part.indexOf(' ');
    var (method, route) = space < 0
        ? ('', part)
        : (part.substring(0, space), part.substring(space + 1));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          child: Text(
            method,
            style: context.type.mono.copyWith(color: context.colors.mut),
          ),
        ),
        Flexible(
          child: Text(
            route,
            style: context.type.mono,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.label, {required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: FwSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: context.type.fieldLabel),
        const SizedBox(height: FwSpacing.xs),
        child,
      ],
    ),
  );
}

/// One part of a server — a route, a table, an outside service — and how
/// much it saw; lit, with its number, when the shown step touched it.
class _Part extends StatelessWidget {
  const _Part({
    required this.child,
    required this.count,
    required this.number,
    required this.litColor,
    required this.open,
    required this.onOpen,
  });

  static const width = 210.0;

  final Widget child;
  final String count;
  final int? number;
  final Color litColor;

  /// Whether the column shows what it holds.
  final bool open;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    var lit = number != null;
    return Tappable(
      onTap: onOpen,
      feedback: TapFeedback.none,
      child: Container(
        width: width,
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
        decoration: BoxDecoration(
          color: open ? context.colors.accentSoft : context.colors.bg,
          border: Border.all(
            color: lit ? litColor : context.colors.line,
            width: lit ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Row(
          children: [
            Expanded(child: child),
            const SizedBox(width: FwSpacing.xs),
            Text(count, style: context.type.caption),
            if (number case var n?) ...[
              const SizedBox(width: FwSpacing.xs),
              NodeNumber(n, color: litColor),
            ],
          ],
        ),
      ),
    );
  }
}

/// The sync engine's service: not Dart and silent itself, known by the
/// clients the apps' databases name.
class _SyncCard extends StatelessWidget {
  const _SyncCard({
    required this.engine,
    required this.sync,
    required this.number,
    required this.litColor,
    required this.colorOf,
    required this.open,
    required this.onOpen,
  });

  final String engine;
  final Map<String, Map<String, Object?>> sync;
  final int? number;
  final Color litColor;
  final Color Function(String? person) colorOf;
  final bool open;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    var lit = number != null;
    return Tappable(
      onTap: onOpen,
      feedback: TapFeedback.none,
      child: Container(
        width: _Part.width,
        padding: const EdgeInsets.all(FwSpacing.sm),
        decoration: BoxDecoration(
          color: open ? context.colors.accentSoft : context.colors.bg,
          border: Border.all(
            color: lit ? litColor : context.colors.line,
            width: lit ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(context.radii.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sync,
                  size: FwIconSize.sm,
                  color: context.colors.ink2,
                ),
                const SizedBox(width: FwSpacing.xs),
                Expanded(
                  child: Text(
                    engine == 'powersync' ? 'PowerSync' : engine,
                    style: context.type.bodyStrong,
                  ),
                ),
                if (number case var n?) NodeNumber(n, color: litColor),
              ],
            ),
            const SizedBox(height: FwSpacing.xs),
            for (var MapEntry(key: person, value: state) in sync.entries)
              Row(
                children: [
                  _Dot(colorOf(person)),
                  const SizedBox(width: FwSpacing.xs),
                  Text(person, style: context.type.body),
                  const SizedBox(width: FwSpacing.xs),
                  Expanded(
                    child: Text(
                      switch (state['clientId']) {
                        String id => 'client ${id.split('-').first}',
                        _ => 'no client yet',
                      },
                      style: context.type.bodyMuted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Where each end of a line is. Every phone and every part of the system
/// registers its render box here while it is attached, under its id, and the
/// lines read them at paint time relative to the stage.
///
/// Boxes rather than `GlobalKey`s: a paint runs before the build owner
/// finalizes the tree, so an element replaced by that frame's build is still
/// registered under its key, and asking it for its render object asserts.
class TraceAnchors {
  final _boxes = <String, RenderBox>{};
  static const _stageId = '';

  /// [child], known to the lines as [id].
  Widget wrap(String id, Widget child) =>
      _Anchor(id: id, anchors: this, child: child);

  /// [child] as the stage: what every rect is measured from, and what the
  /// lines are painted over.
  Widget stage(Widget child) => wrap(_stageId, child);

  /// Where [id] is on the stage, or null while it is not laid out there.
  Rect? rectOf(String id) {
    var stage = _live(_stageId);
    var box = _live(id);
    if (stage == null || box == null) return null;
    return box.localToGlobal(Offset.zero, ancestor: stage) & box.size;
  }

  RenderBox? _live(String id) => switch (_boxes[id]) {
    var box? when box.attached && box.hasSize => box,
    _ => null,
  };
}

class _Anchor extends SingleChildRenderObjectWidget {
  const _Anchor({required this.id, required this.anchors, super.child});

  final String id;
  final TraceAnchors anchors;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAnchor(id, anchors);

  @override
  void updateRenderObject(BuildContext context, _RenderAnchor renderObject) =>
      renderObject.rename(id, anchors);
}

class _RenderAnchor extends RenderProxyBox {
  _RenderAnchor(this._id, this._anchors);

  String _id;
  TraceAnchors _anchors;

  void rename(String id, TraceAnchors anchors) {
    if (id == _id && identical(anchors, _anchors)) return;
    _leave();
    _id = id;
    _anchors = anchors;
    if (attached) _anchors._boxes[_id] = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _anchors._boxes[_id] = this;
  }

  @override
  void detach() {
    _leave();
    super.detach();
  }

  void _leave() {
    if (identical(_anchors._boxes[_id], this)) _anchors._boxes.remove(_id);
  }
}

/// The order a step touched a node in, on the node and beside its beat.
class NodeNumber extends StatelessWidget {
  const NodeNumber(this.number, {super.key, required this.color});

  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      '$number',
      style: context.type.micro.copyWith(
        color: context.colors.bg,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Every step taken on the phones, newest first. The stage follows the
/// newest until one is chosen.
class TraceList extends StatelessWidget {
  const TraceList({
    super.key,
    required this.steps,
    required this.colorOf,
    required this.following,
    required this.onChoose,
  });

  /// Newest first.
  final List<TracedStep> steps;
  final Color Function(String? person) colorOf;

  /// The step the stage shows while none is chosen.
  final String? following;
  final void Function(String step) onChoose;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.lg,
          FwSpacing.md,
          FwSpacing.lg,
          FwSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Steps', style: context.type.sectionLabel),
            Text(
              "Each tap on a phone and each of the world's actions, and what "
              'it caused. The stage shows the newest that caused something; '
              'choose one to hold it.',
              style: context.type.bodyMuted,
            ),
          ],
        ),
      ),
      Expanded(
        child: steps.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(FwSpacing.lg),
                child: Text(
                  'Nothing yet. Tap something on a phone, or drive one with '
                  '`flutterware_act`.',
                  style: context.type.bodyMuted,
                ),
              )
            : ListView(
                children: [
                  for (var (:step, :beats) in steps)
                    Tappable(
                      onTap: () => onChoose(step.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FwSpacing.lg,
                          vertical: FwSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: step.id == following
                              ? context.colors.accentSoft2
                              : null,
                          border: Border(
                            bottom: BorderSide(color: context.colors.line2),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: _Dot(colorOf(step.person)),
                            ),
                            const SizedBox(width: FwSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    stepTitle(step),
                                    style: context.type.body,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    [
                                      clockOf(step.at!),
                                      step.id,
                                      beats.isEmpty
                                          ? step.verb == 'action'
                                                ? 'nothing heard yet'
                                                : 'nothing left the phone'
                                          : beats.length == 1
                                          ? '1 thing'
                                          : '${beats.length} things',
                                    ].join(' · '),
                                    style: context.type.bodyMuted,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ],
  );
}

/// One step, as a waterfall: what it caused, in order, each beat with its
/// offset from the tap and the number of the node it touched.
class TraceDetail extends StatelessWidget {
  const TraceDetail({
    super.key,
    required this.traced,
    required this.numbers,
    required this.colorOf,
    required this.onBack,
    this.back = 'Steps',
  });

  final TracedStep traced;
  final Map<String, int> numbers;
  final Color Function(String? person) colorOf;
  final VoidCallback onBack;

  /// Where [onBack] goes: the steps, or the contents it was chosen from.
  final String back;

  @override
  Widget build(BuildContext context) {
    var (:step, :beats) = traced;
    var color = colorOf(step.person);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Back(back, onBack: onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            0,
            FwSpacing.lg,
            FwSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Dot(color),
                  const SizedBox(width: FwSpacing.sm),
                  Expanded(
                    child: Text(stepTitle(step), style: context.type.heading),
                  ),
                ],
              ),
              Text(
                '${clockOf(step.at!)} · ${step.id}',
                style: context.type.bodyMuted,
              ),
            ],
          ),
        ),
        Container(height: 1, color: context.colors.line),
        Expanded(
          child: beats.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(FwSpacing.lg),
                  child: Text(
                    step.verb == 'action'
                        ? 'Nothing heard: no server reported a request '
                              'carrying this step.'
                        : 'Nothing left the phone: no request, and no record '
                              'written.',
                    style: context.type.bodyMuted,
                  ),
                )
              : ListView(
                  children: [
                    for (var beat in beats)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FwSpacing.lg,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: context.colors.line2),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 60,
                              child: Text(
                                '+${beat.at.difference(step.at!).inMilliseconds} ms',
                                style: context.type.mono.copyWith(
                                  color: context.colors.mut,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 26,
                              child: switch (numbers[beat.node]) {
                                var n? => Align(
                                  alignment: Alignment.topLeft,
                                  child: NodeNumber(n, color: color),
                                ),
                                null => Padding(
                                  padding: const EdgeInsets.only(
                                    top: 5,
                                    left: 5,
                                  ),
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: _Dot(colorOf(beat.person)),
                                  ),
                                ),
                              },
                            ),
                            Expanded(
                              child: SelectableText(
                                beat.what,
                                style: context.type.body,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// `POST /orders/:id/advance`, `orders`, `SMS`, `PowerSync`: what the column
/// calls a node whose contents it shows.
String contentsLabel(NodeContents contents, {String? engine}) =>
    switch (contents.kind) {
      NodeKind.sent => switch (contents.title) {
        'sms' => 'SMS',
        'push' => 'Push',
        var other => other,
      },
      NodeKind.sync => engine == 'powersync' ? 'PowerSync' : engine ?? 'Sync',
      _ => contents.title,
    };

/// What one part of the system holds — its calls, its records, what it sent
/// — newest first, each with the step that caused it. A record carries its
/// life: every write the server reported and every phone it reached.
///
/// What the shown step touched is marked in its person's colour, so the
/// record a tap changed stands out among the rest.
class NodeContentsView extends StatelessWidget {
  const NodeContentsView({
    super.key,
    required this.contents,
    required this.label,
    required this.colorOf,
    required this.shown,
    required this.markColor,
    required this.onBack,
    required this.onChoose,
  });

  final NodeContents contents;

  /// [contentsLabel]'s.
  final String label;
  final Color Function(String? person) colorOf;

  /// The step the stage shows.
  final String? shown;
  final Color markColor;
  final VoidCallback onBack;
  final void Function(String step) onChoose;

  @override
  Widget build(BuildContext context) {
    var kind = contents.kind;
    var total = contents.items.length + contents.earlier + contents.unwritten;
    String count(String one, String many) =>
        total == 1 ? '1 $one' : '$total $many';
    var where = [
      if (contents.server.isNotEmpty) contents.server,
      switch (kind) {
        NodeKind.route => 'API',
        NodeKind.table => 'Data',
        NodeKind.sent => 'Outside',
        NodeKind.sync => 'Sync',
      },
      switch (kind) {
        NodeKind.route => count('call', 'calls'),
        NodeKind.table => count('record', 'records'),
        NodeKind.sent => '$total sent',
        NodeKind.sync => '${count('record', 'records')} carried',
      },
    ].join(' · ');
    var named = kind == NodeKind.route || kind == NodeKind.table;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Back('Steps', onBack: onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            0,
            FwSpacing.lg,
            FwSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    switch (kind) {
                      NodeKind.route => Icons.alt_route,
                      NodeKind.table => Icons.table_rows_outlined,
                      NodeKind.sent when contents.title == 'push' =>
                        Icons.notifications_none,
                      NodeKind.sent => Icons.sms_outlined,
                      NodeKind.sync => Icons.sync,
                    },
                    size: FwIconSize.md,
                    color: context.colors.ink2,
                  ),
                  const SizedBox(width: FwSpacing.sm),
                  Expanded(
                    child: SelectableText(
                      label,
                      style: named
                          ? context.type.mono.copyWith(
                              fontSize: context.type.heading.fontSize,
                              fontWeight: context.type.heading.fontWeight,
                            )
                          : context.type.heading,
                    ),
                  ),
                ],
              ),
              Text(where, style: context.type.bodyMuted),
            ],
          ),
        ),
        Container(height: 1, color: context.colors.line),
        Expanded(
          child: total == 0
              ? Padding(
                  padding: const EdgeInsets.all(FwSpacing.lg),
                  child: Text('Nothing yet.', style: context.type.bodyMuted),
                )
              : ListView(
                  children: [
                    for (var item in contents.items) _item(context, item),
                    if (contents.earlier > 0)
                      Padding(
                        padding: const EdgeInsets.all(FwSpacing.lg),
                        child: Text(
                          '${contents.earlier} earlier, no longer kept.',
                          style: context.type.bodyMuted,
                        ),
                      ),
                    if (contents.unwritten case var n when n > 0)
                      Padding(
                        padding: const EdgeInsets.all(FwSpacing.lg),
                        child: Text(
                          '${n == 1 ? '1 more record' : '$n more records'} '
                          'arrived that no server here reported writing: '
                          'older than the world, or written where no '
                          'adapter reports.',
                          style: context.type.bodyMuted,
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _item(BuildContext context, TraceItem item) {
    var kind = contents.kind;
    var touched =
        shown != null &&
        (item.step == shown || item.life.any((moment) => moment.step == shown));
    var mono = kind != NodeKind.sent;
    var title = Text(
      item.title,
      style: mono ? context.type.mono : context.type.body,
      overflow: TextOverflow.ellipsis,
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.lg,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: touched ? markColor.withValues(alpha: 0.08) : null,
        border: Border(bottom: BorderSide(color: context.colors.line2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _Dot(colorOf(item.person)),
          ),
          const SizedBox(width: FwSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A call's answer is short and sits beside it; anything else
                // said about an item gets a line of its own.
                if (kind == NodeKind.route)
                  Row(
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: FwSpacing.sm),
                      Text(item.detail ?? '', style: context.type.caption),
                    ],
                  )
                else ...[
                  title,
                  if (item.detail case var detail? when detail.isNotEmpty)
                    Text(detail, style: context.type.bodyMuted, maxLines: 3),
                ],
                _meta(context, item.at, item.step),
                if (item.life.isNotEmpty) ...[
                  const SizedBox(height: FwSpacing.xs),
                  for (var moment in item.life)
                    _moment(context, moment, item.life.first.at),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `22:46:13 · ben.3`, the step a link to its waterfall.
  Widget _meta(BuildContext context, DateTime at, String? step) => Row(
    children: [
      Text(clockOf(at), style: context.type.caption),
      if (step != null) ...[
        Text(' · ', style: context.type.caption),
        Tappable(
          onTap: () => onChoose(step),
          feedback: TapFeedback.link,
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          child: Text(
            step,
            style: context.type.caption.copyWith(color: context.colors.accent),
          ),
        ),
      ],
    ],
  );

  /// One moment of a record's life, timed from its first.
  Widget _moment(BuildContext context, TraceItem moment, DateTime first) {
    var offset = moment.at.difference(first);
    var marked = shown != null && moment.step == shown;
    var row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              offset.inMilliseconds < 1000
                  ? '+${offset.inMilliseconds} ms'
                  : '+${(offset.inMilliseconds / 1000).toStringAsFixed(1)} s',
              style: context.type.caption.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 5, right: FwSpacing.xs),
            child: _Dot(colorOf(moment.person)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: moment.title,
                    style: marked
                        ? context.type.bodySmall.copyWith(
                            fontWeight: context.type.bodyStrong.fontWeight,
                          )
                        : context.type.bodySmall,
                  ),
                  if (moment.detail case var detail?)
                    TextSpan(text: '  $detail', style: context.type.caption),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return switch (moment.step) {
      var step? => Tappable(
        onTap: () => onChoose(step),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: row,
      ),
      null => row,
    };
  }
}

/// A person's drawer: their platform — what their app showed and opened —
/// and where its synced data stands.
class _Drawer extends StatelessWidget {
  const _Drawer({
    required this.person,
    required this.color,
    required this.sync,
    required this.onClose,
  });

  final WorldPerson person;
  final Color color;
  final Map<String, Object?>? sync;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    var spec = person.spec;
    var identity = [?spec.email, ?spec.phone, ?spec.userId].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Back('Steps', onBack: onClose),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            0,
            FwSpacing.lg,
            FwSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Dot(color),
                  const SizedBox(width: FwSpacing.sm),
                  Text(person.name, style: context.type.heading),
                ],
              ),
              if (identity.isNotEmpty)
                SelectableText(identity, style: context.type.bodyMuted),
            ],
          ),
        ),
        Container(height: 1, color: context.colors.line),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(FwSpacing.lg),
            child: switch (person.platform) {
              var platform? when person.running => WorldPlatformPanel(
                person: person.name,
                platform: platform,
                sync: sync,
              ),
              _ => Text(
                'Their app is not running.',
                style: context.type.bodyMuted,
              ),
            },
          ),
        ),
      ],
    );
  }
}

class _Back extends StatelessWidget {
  const _Back(this.label, {required this.onBack});

  final String label;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.sm,
      FwSpacing.sm,
      FwSpacing.sm,
      FwSpacing.xs,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Tappable(
        onTap: onBack,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.sm,
            vertical: FwSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_back,
                size: FwIconSize.sm,
                color: context.colors.mut,
              ),
              const SizedBox(width: FwSpacing.xs),
              Text(label, style: context.type.bodyMuted),
            ],
          ),
        ),
      ),
    ),
  );
}

/// `Cleo tapped "Advance"`; a world's action, `Ran "Mia orders a flat
/// white"`.
String stepTitle(TraceStep step) {
  if (step.verb == 'action') return 'Ran ${step.target ?? 'an action'}';
  var did = switch (step.verb) {
    'tap' => 'tapped',
    'longPress' => 'long-pressed',
    'drag' => 'dragged',
    _ => 'did',
  };
  return '${step.person} $did ${step.target ?? ''}'.trim();
}

/// `22:46:13`, local.
String clockOf(DateTime at) {
  var local = at.toLocal();
  return [
    local.hour,
    local.minute,
    local.second,
  ].map((part) => '$part'.padLeft(2, '0')).join(':');
}

/// The lines of one step: between each phone and the part of the system it
/// touched, in the colour of the person at the phone's end, with what
/// crossed written on it. Only between a device and the system — what
/// happened inside the system is the numbers on its parts.
///
/// Routed rather than straight, so that no line crosses a part: down from
/// the phone into the gap, along the gap on a row of its own, down the
/// channel left of the part ([channelWidth]), and into the part's side.
///
/// Where each end is, is read at paint time from the anchors' own boxes, so
/// a phone scrolled sideways or a band that wrapped anew is followed without
/// the stage having to say so.
class TraceLinesPainter extends CustomPainter {
  TraceLinesPainter({
    required this.beats,
    required this.anchors,
    required this.colorOf,
    required this.label,
    required this.pill,
    required this.pillBorder,
    super.repaint,
  });

  final List<TraceBeat> beats;
  final TraceAnchors anchors;
  final Color Function(String? person) colorOf;
  final TextStyle label;
  final Color pill;
  final Color pillBorder;

  @override
  void paint(Canvas canvas, Size size) {
    // One line per person and part, whichever way it ran: a request and
    // the reach it sent back to the same phone are one line with a head at
    // each end, not two lines side by side that read as one. Each way is
    // labelled by its first beat.
    var lines = <String, _Line>{};
    for (var beat in beats) {
      var (person, node, words) = (beat.person, beat.node, beat.line);
      if (person == null || node == null || words == null) continue;
      var line = lines.putIfAbsent('$person|$node', () => _Line(person, node));
      if (beat.inbound) {
        line.back ??= words;
      } else {
        line.out ??= words;
      }
    }
    var perPerson = <String, int>{};
    var perNode = <String, int>{};
    for (var line in lines.values) {
      perPerson[line.person] = (perPerson[line.person] ?? 0) + 1;
      perNode[line.node] = (perNode[line.node] ?? 0) + 1;
    }
    // Several lines at one end fan out along it rather than overlap.
    double spread(int index, int count, double step) =>
        (index - (count - 1) / 2) * step;
    var fromPerson = <String, int>{};
    var toNode = <String, int>{};
    var routes = <_Route>[];
    for (var line in lines.values) {
      var phone = anchors.rectOf(personAnchor(line.person));
      var node = anchors.rectOf(line.node);
      if (phone == null || node == null) continue;
      var i = fromPerson[line.person] = (fromPerson[line.person] ?? -1) + 1;
      var j = toNode[line.node] = (toNode[line.node] ?? -1) + 1;
      var count = perNode[line.node]!;
      routes.add(
        _Route(
          line: line,
          phone: phone,
          start: Offset(
            phone.center.dx + spread(i, perPerson[line.person]!, 16),
            phone.bottom + 1,
          ),
          channel: node.left - channelWidth / 2 + spread(j, count, 5),
          entry: Offset(node.left - 1, node.center.dy + spread(j, count, 6)),
        ),
      );
    }
    // Each line crosses the gap on a row of its own where it would run
    // alongside another; the rows are where the labels go too.
    const rows = [10.0, 28.0, 46.0];
    var taken = [for (var _ in rows) <(double, double)>[]];
    for (var route in routes) {
      var span = (
        min(route.start.dx, route.channel) - 8,
        max(route.start.dx, route.channel) + 8,
      );
      var row = 0;
      for (var r = 0; r < rows.length; r++) {
        if (!taken[r].any(
          (other) => other.$1 < span.$2 && span.$1 < other.$2,
        )) {
          row = r;
          break;
        }
        if (taken[r].length < taken[row].length) row = r;
      }
      taken[row].add(span);
      route.track = route.phone.bottom + rows[row];
    }
    // Every line before any label, so no line runs over a label's words.
    var runs = <(_Route, Offset, Offset)>[];
    for (var route in routes) {
      var color = colorOf(route.line.person);
      var points = [
        route.start,
        Offset(route.start.dx, route.track),
        Offset(route.channel, route.track),
        Offset(route.channel, route.entry.dy),
        route.entry,
      ];
      canvas.drawPath(
        _rounded(points, 6),
        Paint()
          ..color = color
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      if (route.line.back != null) _arrow(canvas, points[1], points[0], color);
      if (route.line.out != null) _arrow(canvas, points[3], points[4], color);
      runs.add((route, points[1], points[2]));
    }
    var labels = <Rect>[];
    for (var (route, from, to) in runs) {
      var color = colorOf(route.line.person);
      // Both ways in one pill, the answer under the request and marked ←:
      // two pills on one short run push each other off it.
      var words = switch ((route.line.out, route.line.back)) {
        (var out?, var back?) => '$out\n← $back',
        (var out?, null) => out,
        (null, var back?) => back,
        (null, null) => '',
      };
      labels.add(_label(canvas, words, from, to, color, labels));
    }
  }

  /// [points] joined by straight runs, each corner rounded to [radius].
  static Path _rounded(List<Offset> points, double radius) {
    var kept = <Offset>[points.first];
    for (var point in points.skip(1)) {
      if ((point - kept.last).distance > 0.5) kept.add(point);
    }
    var path = Path()..moveTo(kept.first.dx, kept.first.dy);
    for (var i = 1; i < kept.length - 1; i++) {
      var (before, at, after) = (kept[i - 1], kept[i], kept[i + 1]);
      var r = min(
        radius,
        min((at - before).distance, (after - at).distance) / 2,
      );
      var into = (at - before) / (at - before).distance;
      var out = (after - at) / (after - at).distance;
      var from = at - into * r;
      var to = at + out * r;
      path
        ..lineTo(from.dx, from.dy)
        ..quadraticBezierTo(at.dx, at.dy, to.dx, to.dy);
    }
    return path..lineTo(kept.last.dx, kept.last.dy);
  }

  /// A head at [to], pointing away from [from].
  void _arrow(Canvas canvas, Offset from, Offset to, Color color) {
    var angle = atan2(to.dy - from.dy, to.dx - from.dx);
    const length = 7.0;
    Offset wing(double turn) => Offset(
      to.dx - length * cos(angle + turn),
      to.dy - length * sin(angle + turn),
    );
    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(wing(0.45).dx, wing(0.45).dy)
        ..lineTo(wing(-0.45).dx, wing(-0.45).dy)
        ..close(),
      Paint()..color = color,
    );
  }

  /// The words on a line, in a pill on its run across the gap between the
  /// phones and the system ([wireGap]) — moved along the run until it clears
  /// the pills already drawn.
  Rect _label(
    Canvas canvas,
    String text,
    Offset a,
    Offset b,
    Color color,
    List<Rect> taken,
  ) {
    var painter = TextPainter(
      text: TextSpan(
        text: text,
        style: label.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 220);
    var pad = const EdgeInsets.symmetric(horizontal: 7, vertical: 2);
    Rect rectAt(double t) => Rect.fromCenter(
      center: Offset.lerp(a, b, t)!,
      width: painter.width + pad.horizontal,
      height: painter.height + pad.vertical,
    );
    var rect = rectAt(0.5);
    for (var t in [0.5, 0.3, 0.7, 0.15, 0.85, 0.0, 1.0]) {
      rect = rectAt(t);
      if (!taken.any((other) => other.inflate(2).overlaps(rect))) break;
    }
    var shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(min(rect.height / 2, 9)),
    );
    canvas
      ..drawRRect(shape, Paint()..color = pill)
      ..drawRRect(
        shape,
        Paint()
          ..color = pillBorder
          ..style = PaintingStyle.stroke,
      );
    painter.paint(canvas, rect.topLeft + Offset(pad.left, pad.top));
    return rect;
  }

  @override
  bool shouldRepaint(TraceLinesPainter old) => true;
}

/// One line's way from a phone to a part: down into the gap, along it on
/// its [track], down the channel beside the part, and into the part's side.
/// What passed between one phone and one part, each way.
class _Line {
  _Line(this.person, this.node);

  final String person;
  final String node;

  /// The words on the way out — the request — if there was one.
  String? out;

  /// The words on the way back — a reach, an arrival — if there was one.
  String? back;
}

class _Route {
  _Route({
    required this.line,
    required this.phone,
    required this.start,
    required this.channel,
    required this.entry,
  });

  final _Line line;
  final Rect phone;
  final Offset start;

  /// The x of the channel it runs down.
  final double channel;

  /// Where it meets the part.
  final Offset entry;

  /// The y it crosses the gap at.
  late double track;
}
