import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/channels_ui.dart';

import 'shell.dart';

/// The descriptor renderers, against fixtures.
///
/// These are the only place the renderers can be looked at without an app.
/// A panel normally arrives over a VM service from something running on a
/// phone; here the descriptor is written by hand, so every shape it can take —
/// a feed with nothing in it, a knob nobody has touched, an action mid-flight,
/// a state that has never been read — is one entry away instead of one
/// launch, one navigation and one lucky moment away.
///
/// One renderer serves the cockpit and the in-app devbar overlay, so what these
/// show is what both surfaces show
/// (`docs/superpowers/specs/2026-08-11-devbar-run-bridge-design.md`, § Decision
/// 1). Colours come from the ambient theme — flip the shell's axes and these
/// follow.

const _networkFields = [
  FieldDescriptor('path', 'Path', primary: true),
  FieldDescriptor('status', 'Status'),
  FieldDescriptor('size', 'Size', kind: FieldKind.bytes),
];

PanelDescriptor _network({List<KnobDescriptor> knobs = const []}) =>
    PanelDescriptor(
      'network',
      'Network',
      description: 'Every request this app made',
      feeds: const [
        FeedDescriptor(
          'requests',
          'Requests',
          fields: _networkFields,
          durationKey: 'ms',
          itemActions: [
            PluginAction('curl', 'Copy as curl'),
            PluginAction('replay', 'Replay'),
          ],
        ),
      ],
      states: const [
        StateDescriptor(
          'config',
          'Client',
          fields: [
            FieldDescriptor('baseUrl', 'Base URL'),
            FieldDescriptor('timeout', 'Timeout', kind: FieldKind.duration),
          ],
        ),
      ],
      knobs: knobs,
      actions: const [
        PluginAction('clear', 'Clear the log', danger: true),
        PluginAction(
          'notify',
          'Send a notification',
          description: 'Fires a local notification on the device',
          parameters: [
            ActionParameter('title', 'Title'),
            ActionParameter('link', 'Deep link', required: false),
            ActionParameter(
              'channel',
              'Channel',
              kind: ActionParameterKind.choice,
              options: [ActionOption('default'), ActionOption('urgent')],
            ),
            ActionParameter(
              'silent',
              'Silent',
              kind: ActionParameterKind.boolean,
              required: false,
            ),
          ],
        ),
      ],
    );

List<InspectorEvent> _requests() => [
  for (var (index, row) in const [
    ('/v1/session', 200, 1_240, 18.2),
    (
      '/v1/products?page=1&sort=price&direction=descending',
      200,
      184_320,
      412.5,
    ),
    (
      '/v1/products/9f3a-2b71-childrens-waterproof-jacket-navy',
      200,
      9_211,
      64.0,
    ),
    ('/v1/cart', 201, 512, 1_180.3),
    ('/v1/checkout', 500, 96, 240.7),
  ].indexed)
    InspectorEvent(
      channel: 'network/requests',
      id: index + 1,
      time: DateTime.utc(2026, 8, 11, 9, 15, index * 7),
      rid: index.isEven ? 'req-${index + 1}' : null,
      isReplay: false,
      payload: {
        'path': row.$1,
        'status': row.$2,
        'size': row.$3,
        'ms': row.$4,
        'method': index == 3 ? 'POST' : 'GET',
      },
    ),
];

const _flags = [
  KnobDescriptor(
    name: 'newCheckout',
    kind: KnobKind.boolean,
    value: true,
    defaultValue: false,
    description: 'The rewritten checkout flow',
  ),
  KnobDescriptor(
    name: 'apiBaseUrl',
    kind: KnobKind.string,
    value: 'https://staging.example.com',
    defaultValue: 'https://api.example.com',
  ),
  KnobDescriptor(
    name: 'retries',
    kind: KnobKind.integer,
    value: 3,
    defaultValue: 3,
    min: 0,
    max: 10,
    step: 1,
    description: 'Bounded, so it draws as a slider',
  ),
  KnobDescriptor(
    name: 'jitter',
    kind: KnobKind.number,
    value: 0.35,
    defaultValue: 0.35,
    min: 0,
    max: 1,
  ),
  KnobDescriptor(
    name: 'timeoutSeconds',
    kind: KnobKind.integer,
    value: 30,
    defaultValue: 30,
    description: 'Unbounded, so it draws as a field',
  ),
  KnobDescriptor(
    name: 'environment',
    kind: KnobKind.picker,
    value: 'staging',
    defaultValue: 'production',
    options: ['production', 'staging', 'local'],
  ),
];

@Preview(name: 'Panel · everything', group: 'Panels', wrapper: wrapInApp)
Widget panelEverything() => _Frame(
  height: 460,
  child: _LivePanel(
    descriptor: _network(knobs: _flags),
    events: _requests(),
  ),
);

/// The state a first draft forgets: a panel that is up and has nothing to say
/// yet. Every tab has to hold its shape empty, or the panel jumps around the
/// first time an event lands.
@Preview(name: 'Panel · nothing yet', group: 'Panels', wrapper: wrapInApp)
Widget panelEmpty() => _Frame(
  height: 300,
  child: PanelView(
    descriptor: _network(knobs: _flags),
    events: const {'requests': []},
  ),
);

/// A panel whose plugin declared no shape at all — legal, and it must not read
/// as broken.
@Preview(name: 'Panel · declares nothing', group: 'Panels', wrapper: wrapInApp)
Widget panelBare() => _Frame(
  height: 160,
  child: const PanelView(descriptor: PanelDescriptor('empty', 'Empty')),
);

/// Overflow, and a feed that declared no fields. Both are the ordinary case
/// for a plugin somebody wrote in five minutes, and both have to survive.
@Preview(
  name: 'Feed · undeclared and long',
  group: 'Panels',
  wrapper: wrapInApp,
)
Widget feedUndeclared() => _Frame(
  height: 340,
  child: PanelView(
    descriptor: const PanelDescriptor(
      'sql',
      'SQL',
      feeds: [FeedDescriptor('queries', 'Queries')],
    ),
    events: {
      'queries': [
        for (var (index, sql) in const [
          'SELECT * FROM todos WHERE list_id = ? AND completed = 0 ORDER BY updated_at DESC LIMIT 50',
          'INSERT INTO ps_crud (tx_id, data) VALUES (?, ?)',
          'PRAGMA wal_checkpoint(TRUNCATE)',
        ].indexed)
          InspectorEvent(
            channel: 'sql/queries',
            id: index + 1,
            time: DateTime.utc(2026, 8, 11, 9, 20, index),
            isReplay: false,
            payload: {'sql': sql, 'rows': index * 17},
          ),
      ],
    },
  ),
);

@Preview(name: 'Controls · knobs', group: 'Panels', wrapper: wrapInApp)
Widget controlsKnobs() =>
    _Frame(height: 520, child: _LiveControls(knobs: _flags));

/// An action in each of the states it passes through. Stacked rather than
/// behind a control, so a broken one shows itself on open.
@Preview(name: 'Controls · actions', group: 'Panels', wrapper: wrapInApp)
Widget controlsActions() => _Frame(
  height: 520,
  child: ControlsView(
    knobs: const [],
    actions: _network().actions,
    busy: const {'clear'},
    results: const {'notify': '{"delivered": true, "id": "n-4471"}'},
    onAction: (_, _) {},
  ),
);

@Preview(name: 'State · read and unread', group: 'Panels', wrapper: wrapInApp)
Widget stateViews() => _Frame(
  height: 420,
  child: Column(
    children: [
      Expanded(
        child: StateView(
          state: _network().states.single,
          snapshot: null,
          onRead: () {},
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: StateView(
          state: _network().states.single,
          snapshot: const {
            'baseUrl': 'https://staging.example.com',
            'timeout': 30000,
          },
          onRead: () {},
        ),
      ),
    ],
  ),
);

/// The renderer takes its colours from the ambient theme and nothing else —
/// which is the whole reason it can live in the published package and still
/// look native inside the cockpit. This is that claim, visible.
@Preview(name: 'Panel · dark', group: 'Panels', wrapper: wrapInApp)
Widget panelDark() => Theme(
  data: ThemeData.dark(),
  child: Builder(
    builder: (context) => ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: _Frame(
        height: 460,
        child: _LivePanel(
          descriptor: _network(knobs: _flags),
          events: _requests(),
        ),
      ),
    ),
  ),
);

/// Bounds the panel, which otherwise fills whatever it is given — several
/// variants on one page need a height each.
class _Frame extends StatelessWidget {
  const _Frame({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: child);
}

/// Knobs and actions that actually move, because a control that only ever
/// renders one value hides the half of the bug that lives in the transition.
class _LivePanel extends StatefulWidget {
  const _LivePanel({required this.descriptor, required this.events});

  final PanelDescriptor descriptor;
  final List<InspectorEvent> events;

  @override
  State<_LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<_LivePanel> {
  final _values = <String, Object?>{};
  final _states = <String, Map<String, Object?>>{};
  final _results = <String, String>{};

  @override
  Widget build(BuildContext context) {
    return PanelView(
      descriptor: PanelDescriptor(
        widget.descriptor.id,
        widget.descriptor.label,
        description: widget.descriptor.description,
        feeds: widget.descriptor.feeds,
        states: widget.descriptor.states,
        actions: widget.descriptor.actions,
        knobs: [
          for (var knob in widget.descriptor.knobs)
            _values.containsKey(knob.name)
                ? knob.withValue(_values[knob.name])
                : knob,
        ],
      ),
      events: {widget.descriptor.feeds.first.id: widget.events},
      states: _states,
      results: _results,
      onKnob: (name, value) => setState(() => _values[name] = value),
      onAction: (id, args) => setState(() => _results[id] = 'ran with $args'),
      onItemAction: (id, event) =>
          setState(() => _results[id] = '$id on event $event'),
      onReadState: (id) => setState(
        () => _states[id] = const {
          'baseUrl': 'https://staging.example.com',
          'timeout': 30000,
        },
      ),
    );
  }
}

class _LiveControls extends StatefulWidget {
  const _LiveControls({required this.knobs});

  final List<KnobDescriptor> knobs;

  @override
  State<_LiveControls> createState() => _LiveControlsState();
}

class _LiveControlsState extends State<_LiveControls> {
  final _values = <String, Object?>{};

  @override
  Widget build(BuildContext context) {
    return ControlsView(
      actions: const [],
      knobs: [
        for (var knob in widget.knobs)
          _values.containsKey(knob.name)
              ? knob.withValue(_values[knob.name])
              : knob,
      ],
      onKnob: (name, value) => setState(() => _values[name] = value),
    );
  }
}
