/// What a panel inside a running app declares to everything outside it.
///
/// A panel that renders its own widgets (widget mode) is invisible here by
/// construction. A panel that declares *this* is
/// rendered by the cockpit, by `fw` and by MCP from one description, and by
/// the in-app overlay from the same one, so the two surfaces cannot drift.
///
/// Almost none of this vocabulary is new, and that is deliberate. Commands
/// are [PluginAction] — the same objects a host-side flutterware plugin
/// declares, already rendered as a form by the GUI, as flags by `fw` and as a
/// schema by MCP. Knobs are [KnobDescriptor] — the same objects the ui_catalog
/// guest reports for a demo's parameters, already rendered by a panel that
/// switches on [KnobKind]. What is added here is the two shapes neither
/// covered: an append-only **feed**, and a **state** snapshot.
library;

import '../plugins/action.dart';
import '../ui_catalog/knob.dart';

/// How a renderer should read one value out of a payload.
///
/// Small on purpose. A kind exists when knowing it changes the rendering —
/// right-aligning a number, writing `1.4 MB` instead of `1468006`, drawing a
/// bar for a duration. Anything else is [text], and a renderer that meets a
/// kind it does not know falls back to [text] rather than refusing the row.
enum FieldKind {
  text,
  number,

  /// Milliseconds. A feed with one of these can be drawn as a waterfall.
  duration,

  /// A byte count, rendered in human units.
  bytes,

  /// Milliseconds since the epoch.
  timestamp,

  /// A nested structure, rendered by a JSON viewer rather than a cell.
  json;

  static FieldKind byName(String name) =>
      values.firstWhere((v) => v.name == name, orElse: () => text);
}

/// One value inside a feed event or a state snapshot.
class FieldDescriptor {
  const FieldDescriptor(
    this.key,
    this.label, {
    this.kind = FieldKind.text,
    this.primary = false,
  });

  /// The key in the payload map.
  final String key;

  final String label;
  final FieldKind kind;

  /// The column that identifies a row — a request's path, a query's SQL. A
  /// narrow renderer shows this one and drops the rest.
  final bool primary;

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    if (kind != FieldKind.text) 'kind': kind.name,
    if (primary) 'primary': true,
  };

  static FieldDescriptor fromJson(Map<String, Object?> json) => FieldDescriptor(
    json['key']! as String,
    json['label']! as String,
    kind: FieldKind.byName(json['kind'] as String? ?? 'text'),
    primary: json['primary'] == true,
  );
}

/// An append-only stream of events — requests, queries, log lines.
///
/// The events themselves do not travel with this: they are already in the
/// core's ring, on [PanelDescriptor.feedChannel], with replay and lazy detail
/// fetch for free. This says only how to read them.
class FeedDescriptor {
  const FeedDescriptor(
    this.id,
    this.label, {
    this.description,
    this.fields = const [],
    this.durationKey,
    this.itemActions = const [],
  });

  /// Unique within its panel.
  final String id;

  final String label;
  final String? description;
  final List<FieldDescriptor> fields;

  /// The payload key holding a duration in milliseconds, when the feed has
  /// one — what a waterfall measures.
  final String? durationKey;

  /// Offered on one event rather than on the feed. The event's id is passed as
  /// `event`, so a handler can reach the details the ring is holding for it —
  /// which is how `explain` runs against the query the user clicked.
  final List<PluginAction> itemActions;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (fields.isNotEmpty) 'fields': [for (var f in fields) f.toJson()],
    if (durationKey != null) 'durationKey': durationKey,
    if (itemActions.isNotEmpty)
      'itemActions': [for (var a in itemActions) a.toJson()],
  };

  static FeedDescriptor fromJson(Map<String, Object?> json) => FeedDescriptor(
    json['id']! as String,
    json['label']! as String,
    description: json['description'] as String?,
    fields: [
      for (var f in json['fields'] as List? ?? const [])
        FieldDescriptor.fromJson((f as Map).cast<String, Object?>()),
    ],
    durationKey: json['durationKey'] as String?,
    itemActions: [
      for (var a in json['itemActions'] as List? ?? const [])
        PluginAction.fromJson((a as Map).cast<String, Object?>()),
    ],
  );
}

/// A snapshot the app can be asked for — permissions held, package info, the
/// device's own account of itself. State, not timeline.
class StateDescriptor {
  const StateDescriptor(
    this.id,
    this.label, {
    this.description,
    this.fields = const [],
  });

  final String id;
  final String label;
  final String? description;

  /// The keys worth showing, in order. Empty means "show whatever comes back",
  /// which is the right answer for something like package info that a renderer
  /// should not curate.
  final List<FieldDescriptor> fields;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (fields.isNotEmpty) 'fields': [for (var f in fields) f.toJson()],
  };

  static StateDescriptor fromJson(Map<String, Object?> json) => StateDescriptor(
    json['id']! as String,
    json['label']! as String,
    description: json['description'] as String?,
    fields: [
      for (var f in json['fields'] as List? ?? const [])
        FieldDescriptor.fromJson((f as Map).cast<String, Object?>()),
    ],
  );
}

/// Everything one panel offers.
class PanelDescriptor {
  const PanelDescriptor(
    this.id,
    this.label, {
    this.description,
    this.feeds = const [],
    this.states = const [],
    this.knobs = const [],
    this.actions = const [],
  });

  /// Unique in the app, and the channel its requests travel on.
  final String id;

  final String label;
  final String? description;

  final List<FeedDescriptor> feeds;
  final List<StateDescriptor> states;

  /// Read-write values, carrying what they currently are. A feature flag is
  /// one of these.
  final List<KnobDescriptor> knobs;

  /// Commands that run inside the app.
  final List<PluginAction> actions;

  /// Where a feed's events live in the core's ring.
  ///
  /// Qualified by the panel, so two plugins can both call a feed `requests`
  /// without one shadowing the other.
  String feedChannel(String feedId) => panelFeedChannel(id, feedId);

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (feeds.isNotEmpty) 'feeds': [for (var f in feeds) f.toJson()],
    if (states.isNotEmpty) 'states': [for (var s in states) s.toJson()],
    if (knobs.isNotEmpty) 'knobs': [for (var k in knobs) k.toJson()],
    if (actions.isNotEmpty) 'actions': [for (var a in actions) a.toJson()],
  };

  static PanelDescriptor fromJson(Map<String, Object?> json) => PanelDescriptor(
    json['id']! as String,
    json['label']! as String,
    description: json['description'] as String?,
    feeds: [
      for (var f in json['feeds'] as List? ?? const [])
        FeedDescriptor.fromJson((f as Map).cast<String, Object?>()),
    ],
    states: [
      for (var s in json['states'] as List? ?? const [])
        StateDescriptor.fromJson((s as Map).cast<String, Object?>()),
    ],
    knobs: [
      for (var k in json['knobs'] as List? ?? const [])
        KnobDescriptor.fromJson((k as Map).cast<String, Object?>()),
    ],
    actions: [
      for (var a in json['actions'] as List? ?? const [])
        PluginAction.fromJson((a as Map).cast<String, Object?>()),
    ],
  );
}

/// The ring channel a panel's feed reports on.
String panelFeedChannel(String panelId, String feedId) => '$panelId/$feedId';
