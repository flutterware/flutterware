/// One control a catalog entry offers, and the value it currently has.
///
/// Deliberately plain Dart with no Flutter in it, and deliberately in the
/// published package rather than in the app: this is the shape a panel renders
/// *whatever produced it*. Today that is the guest, which learns the knobs by
/// running the demo and reports them over the VM service. A declaration read
/// straight off a demo's parameter list would produce the same descriptors
/// without running anything — see
/// `docs/superpowers/specs/2026-07-27-knobs-static-and-runtime.md`. The panel
/// should not be able to tell the difference.
library;

/// What kind of control a knob is, which is what a panel switches on.
///
/// Kinds a producer cannot describe are left out of a report rather than
/// guessed at: a knob rendered as the wrong control is worse than a knob the
/// panel admits it cannot show.
enum KnobKind {
  string,
  boolean,
  integer,
  number,

  /// A choice between named options. Only the labels cross the wire — the
  /// values behind them are whatever the demo said they are, and only the demo
  /// can turn a label back into one.
  picker;

  static KnobKind? byName(String name) {
    for (var kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// How a picker asks to be drawn — a knob's, or a shell's axis in the top bar.
///
/// Presentation only. It changes nothing about what the picker holds or how a
/// value is set: `--knobs=theme=Dark` reads the same either way, and so does
/// the address. That is what makes it safe for a host to fall back on
/// [dropdown] — for a style it does not know, which a newer guest can send an
/// older host, and for more options than [segmented] shows.
enum PickerStyle {
  /// The chosen option in a field that opens onto the rest. Right for any
  /// number of options, which is why it is the default.
  dropdown,

  /// Every option on show, the chosen one raised: for a choice between two or
  /// three, like Light and Dark, where seeing the alternative is the point.
  ///
  /// Up to five options. A picker offering more is drawn as a [dropdown]
  /// anyway, because past that a row of segments stops reading at a glance,
  /// and in a one-row toolbar it pushes everything after it out of sight.
  segmented,
}

/// The most options a [PickerStyle.segmented] picker lays out inline.
const maxSegments = 5;

/// Whether a picker declared with [style] and offering [options] choices is
/// drawn as segments.
///
/// Decided here rather than by each renderer, so that the studio and a
/// catalog page cannot draw the same picker two different ways.
bool drawsSegments(PickerStyle style, int options) =>
    style == PickerStyle.segmented && options <= maxSegments;

class KnobDescriptor {
  const KnobDescriptor({
    required this.name,
    required this.kind,
    required this.value,
    required this.defaultValue,
    this.min,
    this.max,
    this.step,
    this.description,
    this.options = const [],
    this.style = PickerStyle.dropdown,
  });

  factory KnobDescriptor.fromJson(Map<String, Object?> json) => KnobDescriptor(
    name: json['name']! as String,
    kind: KnobKind.byName(json['kind'] as String? ?? '') ?? KnobKind.string,
    value: json['value'],
    defaultValue: json['default'],
    min: json['min'] as num?,
    max: json['max'] as num?,
    step: json['step'] as num?,
    description: json['description'] as String?,
    options: [
      for (var option in json['options'] as List? ?? const []) option as String,
    ],
    style:
        PickerStyle.values.asNameMap()[json['style']] ?? PickerStyle.dropdown,
  );

  /// Unique within an entry, and how a value is addressed.
  final String name;

  final KnobKind kind;

  /// What the entry is currently being rendered with.
  final Object? value;

  /// What it renders with when nothing has been set — the value written in the
  /// demo, which is also what it shows outside the catalog.
  final Object? defaultValue;

  /// Bounds for [KnobKind.integer] and [KnobKind.number], when the demo gave
  /// any. A knob with both is a slider; a knob with neither is a field.
  final num? min;
  final num? max;

  /// The granularity a slider moves in, when the producer declared one. Absent
  /// means continuous — a devbar variable declares this, a catalog demo does
  /// not.
  final num? step;

  /// What this knob is for, when the producer said. Shown beside the control.
  final String? description;

  /// The labels of a [KnobKind.picker], in the order the demo declared them.
  final List<String> options;

  /// How a [KnobKind.picker] asked to be drawn. Written to JSON only when it
  /// is not the default, so a report from a guest that predates it reads the
  /// same as one from a picker that never asked.
  final PickerStyle style;

  bool get isDefault => value == defaultValue;

  /// The same knob showing [value], for a panel that wants to draw the value a
  /// user is choosing before the guest has confirmed it.
  KnobDescriptor withValue(Object? value) => KnobDescriptor(
    name: name,
    kind: kind,
    value: value,
    defaultValue: defaultValue,
    min: min,
    max: max,
    step: step,
    description: description,
    options: options,
    style: style,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind.name,
    'value': value,
    'default': defaultValue,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (step != null) 'step': step,
    if (description != null) 'description': description,
    if (options.isNotEmpty) 'options': options,
    if (style != PickerStyle.dropdown) 'style': style.name,
  };
}

/// Every knob one entry offers, as of one build of it.
class KnobReport {
  const KnobReport({
    required this.entryId,
    required this.knobs,
    this.declared = 0,
    this.revision = 0,
  });

  factory KnobReport.fromJson(Map<String, Object?> json) => KnobReport(
    entryId: json['entry'] as String?,
    declared: json['declared'] as int? ?? 0,
    revision: json['revision'] as int? ?? 0,
    knobs: [
      for (var knob in json['parameters'] as List? ?? const [])
        KnobDescriptor.fromJson((knob as Map).cast<String, Object?>()),
    ],
  );

  static const empty = KnobReport(entryId: null, knobs: []);

  /// Which entry declared these. A report for another entry is a report from
  /// before the switch landed, not an empty catalog — the difference matters
  /// to a panel deciding whether to show nothing or to ask again.
  final String? entryId;

  final List<KnobDescriptor> knobs;

  /// How many times knobs have been declared, which changes when a demo's
  /// build takes a different path and offers a different set.
  final int declared;

  /// How many times a value has changed.
  final int revision;

  Map<String, Object?> toJson() => {
    'entry': entryId,
    'declared': declared,
    'revision': revision,
    'parameters': [for (var knob in knobs) knob.toJson()],
  };
}
