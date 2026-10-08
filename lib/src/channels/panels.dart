/// Serving a [PanelDescriptor]: the app-side half that turns a declaration
/// into channels, handlers and events on an [InspectorCore].
///
/// A panel is built, not implemented. There is no interface with four
/// methods to override and no way to declare a knob whose value nobody can
/// read: every `feed`/`state`/`knob`/`action` call takes the declaration and
/// the code that serves it together, and the descriptor is derived from what
/// was registered. A panel that describes something it cannot answer is not
/// expressible.
library;

import 'dart:async';

import '../plugins/action.dart';
import '../server/inspector_core.dart';
import '../ui_catalog/knob.dart';
import 'descriptor.dart';

/// Where the list of panels lives. `panels/list` answers with every
/// descriptor; an event on the same channel means the list changed.
const panelsChannel = 'panels';
const panelsList = 'list';

/// Methods reserved on a panel's own channel.
///
/// Prefixed, so a plugin may name an action `state` or `knob` without
/// colliding with the protocol — an action id is otherwise used verbatim as
/// the method, which is what keeps `sql/explain` reading the way it does.
const panelStateMethod = 'fw:state';
const panelKnobsMethod = 'fw:knobs';
const panelSetKnobMethod = 'fw:knob';

typedef PanelActionHandler = FutureOr<Object?> Function(
  Map<String, Object?> args,
);
typedef PanelStateReader = FutureOr<Map<String, Object?>> Function();
typedef KnobReader = Object? Function();
typedef KnobWriter = FutureOr<void> Function(Object? value);

/// One panel being served. Obtained from [Panels.add], never constructed.
class Panel {
  Panel._(this._panels, this.id, this.label, {this.description});

  final Panels _panels;

  /// Unique in the app, and the channel this panel's requests arrive on.
  final String id;

  final String label;
  final String? description;

  final _feeds = <String, FeedDescriptor>{};
  final _states = <String, (StateDescriptor, PanelStateReader)>{};
  final _knobs = <String, (KnobDescriptor, KnobReader, KnobWriter)>{};
  final _actions = <String, PluginAction>{};

  /// Every action's code, panel actions and feed item actions alike — what
  /// [run] dispatches on, so an in-app renderer reaches the same handler the
  /// wire does.
  final _handlers = <String, PanelActionHandler>{};

  InspectorCore get _core => _panels.core;

  /// Declares an append-only feed. Its events go on
  /// [PanelDescriptor.feedChannel].
  void feed(
    String feedId,
    String feedLabel, {
    String? description,
    List<FieldDescriptor> fields = const [],
    String? durationKey,
  }) {
    _feeds[feedId] = FeedDescriptor(
      feedId,
      feedLabel,
      description: description,
      fields: fields,
      durationKey: durationKey,
    );
    _panels._changed();
  }

  /// Declares a command offered on one event of [feedId] rather than on the
  /// panel — `explain` on the query the user clicked.
  ///
  /// The event's id arrives in the arguments as `event`, which is what lets a
  /// handler reach the details the ring is holding for it.
  void itemAction(
    String feedId,
    PluginAction declaration,
    PanelActionHandler run,
  ) {
    var feed = _feeds[feedId];
    if (feed == null) {
      throw ArgumentError(
        'panel $id has no feed "$feedId". Declare the feed before its '
        'actions. Declared: ${_feeds.keys.toList()}',
      );
    }
    _claimMethod(declaration.id);
    _feeds[feedId] = FeedDescriptor(
      feed.id,
      feed.label,
      description: feed.description,
      fields: feed.fields,
      durationKey: feed.durationKey,
      itemActions: [...feed.itemActions, declaration],
    );
    _handlers[declaration.id] = run;
    _core.registerHandler(id, declaration.id, run);
    _panels._changed();
  }

  /// Reports one event on [feedId], and returns **the event's id**.
  ///
  /// Keep that id if the feed has item actions: an item action is invoked with
  /// `event: <id>` and nothing else, so the id is the only thing tying the row
  /// the user clicked back to whatever the plugin was reporting on. Discovered
  /// by the first plugin to declare one — before this returned anything, an
  /// `itemAction` handler had no way to know which of its own objects it had
  /// been called about.
  ///
  /// Refuses an undeclared feed rather than dropping the event on a channel
  /// nothing renders — an undeclared feed is a typo, and a silent one costs an
  /// afternoon.
  int emit(
    String feedId,
    Map<String, Object?> payload, {
    String? rid,
    Map<String, Object?>? details,
  }) {
    if (!_feeds.containsKey(feedId)) {
      throw ArgumentError(
        'panel $id has no feed "$feedId". Declared: ${_feeds.keys.toList()}',
      );
    }
    return _core.addEvent(
      panelFeedChannel(id, feedId),
      payload,
      rid: rid,
      details: details,
    );
  }

  /// Declares a snapshot the host can ask for.
  void state(
    String stateId,
    String stateLabel, {
    String? description,
    List<FieldDescriptor> fields = const [],
    required PanelStateReader read,
  }) {
    _states[stateId] = (
      StateDescriptor(
        stateId,
        stateLabel,
        description: description,
        fields: fields,
      ),
      read,
    );
    _panels._changed();
  }

  /// Declares a read-write value.
  ///
  /// [declaration]'s own `value` is ignored — what crosses the wire is always
  /// `declaration.withValue(read())`, so a knob cannot report a value that has
  /// gone stale since it was declared. A feature flag registered by a widget
  /// that has since rebuilt is exactly that case.
  void knob(
    KnobDescriptor declaration, {
    required KnobReader read,
    required KnobWriter write,
  }) {
    _knobs[declaration.name] = (declaration, read, write);
    _panels._changed();
  }

  /// Stops offering a knob — a devbar variable whose widget unmounted.
  void removeKnob(String name) {
    if (_knobs.remove(name) != null) _panels._changed();
  }

  /// Says the panel's values moved, without the shape having changed.
  ///
  /// A knob's value is read live, so a host that re-lists always sees the
  /// truth — but nothing would have told it to look. This is what a slider
  /// being dragged inside the app posts. Coalesced by the transport's nudge,
  /// so a drag costs one wakeup rather than one per frame.
  void announce() => _panels._changed();

  /// Declares a command that runs inside the app.
  void action(PluginAction declaration, PanelActionHandler run) {
    _claimMethod(declaration.id);
    _actions[declaration.id] = declaration;
    _handlers[declaration.id] = run;
    _core.registerHandler(id, declaration.id, run);
    _panels._changed();
  }

  /// Runs one of this panel's commands **in process**, without a wire.
  ///
  /// The three methods below are what an *in-app* renderer calls — an overlay
  /// drawing this panel from its own [descriptor]. They are deliberately the
  /// same code the wire handlers run, because a second surface that
  /// re-implements the first is a second surface that can disagree with it:
  /// add a state, and the copy silently keeps serving the old shape.
  FutureOr<Object?> run(
    String actionId, [
    Map<String, Object?> args = const {},
  ]) {
    var handler = _handlers[actionId];
    if (handler == null) {
      throw ArgumentError(
        'panel $id has no action "$actionId". Declared: '
        '${_handlers.keys.toList()}',
      );
    }
    return handler(args);
  }

  /// Produces one declared snapshot.
  FutureOr<Map<String, Object?>> readState(String stateId) {
    var entry = _states[stateId];
    if (entry == null) {
      throw ArgumentError(
        'panel $id has no state "$stateId". Declared: '
        '${_states.keys.toList()}',
      );
    }
    return entry.$2();
  }

  /// Writes one declared knob, and answers with what the app kept — which is
  /// not always what was asked for.
  Future<List<KnobDescriptor>> writeKnob(String name, Object? value) async {
    var entry = _knobs[name];
    if (entry == null) {
      throw ArgumentError(
        'panel $id has no knob "$name". Declared: ${_knobs.keys.toList()}',
      );
    }
    await entry.$3(value);
    return knobs;
  }

  /// An action id is used verbatim as the request method, so two actions
  /// cannot share one — including a panel action and a feed's item action.
  /// Caught here rather than letting the second silently replace the first.
  void _claimMethod(String actionId) {
    var taken =
        _actions.containsKey(actionId) ||
        _feeds.values.any((f) => f.itemActions.any((a) => a.id == actionId));
    if (taken) {
      throw ArgumentError('panel $id already has an action "$actionId"');
    }
  }

  /// The knobs as they stand right now.
  List<KnobDescriptor> get knobs => [
    for (var (declaration, read, _) in _knobs.values)
      declaration.withValue(read()),
  ];

  PanelDescriptor get descriptor => PanelDescriptor(
    id,
    label,
    description: description,
    feeds: _feeds.values.toList(),
    states: [for (var (declaration, _) in _states.values) declaration],
    knobs: knobs,
    actions: _actions.values.toList(),
  );

  void _install() {
    _core.registerHandler(
      id,
      panelStateMethod,
      (params) => readState('${params['id']}'),
    );
    _core.registerHandler(id, panelKnobsMethod, (_) => _knobsReply(knobs));
    // Read back rather than echo: the app is allowed to clamp, round or
    // refuse, and the host must see what it actually holds.
    _core.registerHandler(
      id,
      panelSetKnobMethod,
      (params) async =>
          _knobsReply(await writeKnob('${params['id']}', params['value'])),
    );
  }

  Map<String, Object?> _knobsReply(List<KnobDescriptor> knobs) => {
    'knobs': [for (var knob in knobs) knob.toJson()],
  };
}

/// Every panel one app is serving, over one [InspectorCore].
class Panels {
  Panels(this.core) {
    core.registerHandler(
      panelsChannel,
      panelsList,
      (_) => {
        'panels': [for (var panel in _panels.values) panel.descriptor.toJson()],
      },
    );
  }

  final InspectorCore core;
  final _panels = <String, Panel>{};

  List<PanelDescriptor> get descriptors => [
    for (var panel in _panels.values) panel.descriptor,
  ];

  Panel? operator [](String id) => _panels[id];

  /// Starts serving a panel. Adding a second one under the same id replaces
  /// the first — a hot reload re-running a plugin's constructor is the case,
  /// and two half-installed panels would be worse than the newer one winning.
  Panel add(String id, String label, {String? description}) {
    _remove(id);
    var panel = Panel._(this, id, label, description: description);
    _panels[id] = panel;
    panel._install();
    _changed();
    return panel;
  }

  void remove(String id) {
    if (_remove(id)) _changed();
  }

  bool _remove(String id) {
    if (_panels.remove(id) == null) return false;
    core.unregisterHandlers(id);
    return true;
  }

  /// Tells attached hosts the list moved. Payload-free: the host re-lists,
  /// which is one round trip and always right, rather than trying to apply a
  /// diff it might have missed the start of.
  void _changed() => core.addEvent(panelsChannel, {
    'type': 'changed',
    'count': _panels.length,
  });
}
