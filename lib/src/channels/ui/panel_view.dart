/// A whole [PanelDescriptor], rendered: a tab strip over one body per feed,
/// one per state, and one for the controls.
///
/// A View, not a Screen. It takes the descriptor, the events and the
/// snapshots as plain data and hands every interaction back as a callback. It
/// fetches nothing and holds no channel — which is what lets it be exercised
/// against fixtures in a preview, with no app running, and what lets the same
/// widget serve the cockpit and the in-app overlay.
library;

import 'package:material_ui/material_ui.dart';

import '../../server/attach_session.dart';
import '../descriptor.dart';
import 'controls_view.dart';
import 'feed_view.dart';
import 'style.dart';

class PanelView extends StatefulWidget {
  const PanelView({
    super.key,
    required this.descriptor,
    this.events = const {},
    this.states = const {},
    this.busy = const {},
    this.results = const {},
    this.onKnob,
    this.onAction,
    this.onItemAction,
    this.onReadState,
  });

  final PanelDescriptor descriptor;

  /// Events per feed id, oldest first. A feed absent from the map has not been
  /// read; one present and empty genuinely has nothing.
  final Map<String, List<InspectorEvent>> events;

  /// Snapshots per state id. Absent means "not read yet" and draws a prompt
  /// rather than an empty table — the difference matters when a state is
  /// expensive to produce.
  final Map<String, Map<String, Object?>> states;

  final Set<String> busy;
  final Map<String, String> results;

  final void Function(String name, Object? value)? onKnob;
  final void Function(String actionId, Map<String, Object?> args)? onAction;
  final void Function(String actionId, int eventId)? onItemAction;
  final void Function(String stateId)? onReadState;

  @override
  State<PanelView> createState() => _PanelViewState();
}

class _PanelViewState extends State<PanelView> {
  String? _tab;
  final _selected = <String, int>{};

  List<_Tab> get _tabs => [
    for (var feed in widget.descriptor.feeds)
      _Tab('feed:${feed.id}', feed.label, widget.events[feed.id]?.length ?? 0),
    for (var state in widget.descriptor.states)
      _Tab('state:${state.id}', state.label, 0),
    if (widget.descriptor.knobs.isNotEmpty ||
        widget.descriptor.actions.isNotEmpty)
      _Tab('controls', 'Controls', 0),
  ];

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    var tabs = _tabs;
    if (tabs.isEmpty) {
      return PanelSurface(
        child: Center(
          child: Text(
            '${widget.descriptor.label} declares nothing yet',
            style: style.body.copyWith(color: style.muted),
          ),
        ),
      );
    }
    // An unknown tab falls back to the first, the way the cockpit's address
    // does: a panel whose shape changed under a saved selection should show
    // something rather than nothing.
    var current = tabs.any((t) => t.id == _tab) ? _tab! : tabs.first.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Strip(
          tabs: tabs,
          current: current,
          onSelect: (id) => setState(() => _tab = id),
          style: style,
        ),
        Container(height: 1, color: style.line),
        Expanded(child: _body(current)),
      ],
    );
  }

  Widget _body(String tab) {
    if (tab == 'controls') {
      return ControlsView(
        knobs: widget.descriptor.knobs,
        actions: widget.descriptor.actions,
        busy: widget.busy,
        results: widget.results,
        onKnob: widget.onKnob,
        onAction: widget.onAction,
      );
    }
    if (tab.startsWith('feed:')) {
      var feed = widget.descriptor.feeds.firstWhere(
        (f) => f.id == tab.substring('feed:'.length),
      );
      return FeedView(
        feed: feed,
        events: widget.events[feed.id] ?? const [],
        selected: _selected[feed.id],
        onSelect: (id) => setState(() {
          if (id < 0) {
            _selected.remove(feed.id);
          } else {
            _selected[feed.id] = id;
          }
        }),
        onItemAction: widget.onItemAction,
      );
    }
    var state = widget.descriptor.states.firstWhere(
      (s) => s.id == tab.substring('state:'.length),
    );
    return StateView(
      state: state,
      snapshot: widget.states[state.id],
      onRead: widget.onReadState == null
          ? null
          : () => widget.onReadState!(state.id),
    );
  }
}

/// A state snapshot as a field table.
class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.state,
    required this.snapshot,
    this.onRead,
  });

  final StateDescriptor state;
  final Map<String, Object?>? snapshot;
  final VoidCallback? onRead;

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    var values = snapshot;
    if (values == null) {
      return PanelSurface(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Not read yet',
                style: style.body.copyWith(color: style.muted),
              ),
              if (onRead != null) ...[
                const PanelGap(PanelStyle.md),
                OutlinedButton(onPressed: onRead, child: const Text('Read')),
              ],
            ],
          ),
        ),
      );
    }
    // No declared fields means "show whatever comes back" — the honest answer
    // for something like package info that a renderer has no business
    // curating.
    var fields = state.fields.isNotEmpty
        ? state.fields
        : [for (var key in values.keys) FieldDescriptor(key, key)];
    return PanelSurface(
      child: ListView(
        padding: const EdgeInsets.all(PanelStyle.lg),
        children: [
          if (onRead != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRead,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Refresh'),
              ),
            ),
          if (values.isEmpty)
            Text(
              'Nothing to report',
              style: style.body.copyWith(color: style.muted),
            ),
          for (var field in fields)
            Padding(
              padding: const EdgeInsets.only(bottom: PanelStyle.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: Text(field.label, style: style.micro),
                  ),
                  const PanelGap(PanelStyle.md),
                  Expanded(
                    child: SelectableText(
                      formatFieldValue(field, values[field.key]),
                      style: style.mono,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Tab {
  const _Tab(this.id, this.label, this.badge);

  final String id;
  final String label;
  final int badge;
}

/// `InspectTabStrip`'s shape, rebuilt on the ambient theme: 34 high, tabs
/// underlined in the accent, horizontally scrolling rather than overflowing.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.tabs,
    required this.current,
    required this.onSelect,
    required this.style,
  });

  final List<_Tab> tabs;
  final String current;
  final ValueChanged<String> onSelect;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        height: PanelStyle.stripHeight,
        color: style.raised,
        padding: const EdgeInsets.symmetric(horizontal: PanelStyle.sm),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var tab in tabs)
                InkWell(
                  onTap: () => onSelect(tab.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PanelStyle.lg,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: tab.id == current
                              ? style.accent
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tab.label,
                          style: style.caption.copyWith(
                            color: tab.id == current ? style.ink : style.muted,
                          ),
                        ),
                        if (tab.badge > 0) ...[
                          const PanelGap(PanelStyle.sm),
                          Text('${tab.badge}', style: style.micro),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
