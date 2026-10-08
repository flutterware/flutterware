// The property table: every authorable property of every node kind, as
// data — its name, its kind, its default, and how to read and write it on
// a node.
//
// One organ, several hosts. The wire and the authored JSON encode and
// decode by walking it; the file emitter and parser spell and read by it;
// the read plane gets, sets and types a property by it; a copy and an undo
// restore move values by it; a motion composes over the base it reads here.
// What it cannot derive is the constructor — a scene file IS a call to it,
// so the named parameters stay hand-written Dart — and the renderer, which
// is what a property MEANS. A test pins the table to the constructors;
// adding a property is a row here, a field, a renderer case, and a named
// parameter on `animate()` if it animates. Four places pinned to each other,
// instead of twenty-five pinned by nothing.
//
// The STYLE rows are the subset a [SceneTextStyle] carries, and they are
// pinned to `sceneTextStyleFields` in both directions, so a row added there
// without a field here would be authorable and unshareable. A text's other
// rows are its own, spelled beside the style.
import 'kind.dart';
import 'model.dart';
import 'values.dart';

/// The kinds a property's value can take. Each has one wire spelling here
/// and one file spelling in the tool; a property's kind is what a parameter
/// binding is checked against.
enum ScenePropKind {
  /// A double.
  number,

  /// A whole number, or null for "no limit".
  integer,

  /// A string.
  string,

  /// True or false.
  boolean,

  /// A [SceneColor], nullable where the property can be absent.
  color,

  /// A size: null for hug, infinity for fill, or a number.
  size,

  /// A list of sizes — a table's column tracks.
  sizes,

  /// A list of [TextLayer]s — a text's paint stack.
  layers,

  /// A variable font's axes, as a four-letter tag to a number. Its PARTS are
  /// the tags, which is what makes one axis a key of its own: `axes.wght` is
  /// a number a parameter can fill and a motion can animate, where the map
  /// as a whole is neither.
  axes,

  /// [SceneEdges]: one number when uniform, four named sides when not.
  edges,

  /// One of a fixed set — an enum, spelled `Type.member`.
  choice,

  /// A [SceneTextStyle] — a text's whole typographic treatment, which is a
  /// value like any other even though the node stores it as its resolved
  /// fields rather than as an object.
  style,

  /// The arguments of whatever the node stands for, as a map. The only
  /// property whose PARTS are not known here: their names come from the
  /// child scene's parameters or the widget's declaration.
  args,
}

/// Where the editor finds the choices for a string row — see
/// [SceneProp.pick]. Each names something in the project, and the two that
/// depend on a model read the same node's `asset` row for which one.
enum ScenePick {
  /// A model file under the package's `assets/` — a `.glb` or `.gltf`.
  modelAsset,

  /// A mesh in the node's `asset`, by the name the modeller gave it.
  modelMesh,

  /// A clip in the node's `asset`, by name.
  modelClip,
}

/// The members a [ScenePropKind.choice] property can take and how the file
/// spells them: `NodeLayout.row`, `SceneFontWeight.w700`.
class SceneChoices {
  const SceneChoices(this.typeName, this.values, {required this.nameOf});

  final String typeName;
  final List<Object> values;
  final String Function(Object value) nameOf;

  List<String> get names => [for (var v in values) nameOf(v)];

  Object? valueOf(String name) {
    for (var v in values) {
      if (nameOf(v) == name) return v;
    }
    return null;
  }

  /// Wire and authored JSON carry the member's name — one spelling, the
  /// file's own, rather than an index that means nothing off the wire.
  String toWire(Object value) => nameOf(value);
}

/// Which node kinds carry a property.
enum ScenePropOwner {
  any,
  frame,
  text,
  shape,

  /// The two node kinds that stand for something else and pass it arguments.
  takesArgs;

  bool has(SceneNode node) => switch (this) {
    any => true,
    frame => node is FrameNode,
    text => node is TextNode,
    shape => node is ShapeNode,
    takesArgs => node is SceneRefNode || node is ExternalNode,
  };
}

/// One authorable property.
class SceneProp {
  const SceneProp(
    this.name,
    this.kind, {
    required this.read,
    required this.write,
    this.defaultValue,
    this.wireKey,
    this.owner = ScenePropOwner.any,
    this.animatable = false,
    this.choices,
    this.sides,
    this.quad,
    this.byHand = false,
    this.kindName,
    this.unit,
    this.softMin,
    this.softMax,
    this.angular = false,
    this.identity,
    this.pick,
  });

  /// A row of a registered kind ([SceneKind]), backed by the [KindNode]'s
  /// value map rather than a field: the one place a name meets a key.
  ///
  /// The editing hints — [unit], the soft range, [angular] — are what the
  /// motion side's spec carried for the hand-written kinds; here they ride
  /// the row, so the timeline and the inspector read one table.
  factory SceneProp.value(
    String name,
    ScenePropKind kind, {
    required String of,
    Object? defaultValue,
    bool animatable = false,
    SceneChoices? choices,
    String? unit,
    double? softMin,
    double? softMax,
    bool angular = false,
    double? identity,
    ScenePick? pick,
  }) => SceneProp(
    name,
    kind,
    kindName: of,
    defaultValue: defaultValue,
    animatable: animatable,
    choices: choices,
    unit: unit,
    softMin: softMin,
    softMax: softMax,
    angular: angular,
    identity: identity,
    pick: pick,
    read: (n) => (n as KindNode).values[name] ?? defaultValue,
    write: (n, v) => (n as KindNode).values[name] = v,
  );

  /// The file's named argument, the read plane's key, the motion's track
  /// name when it animates.
  final String name;

  /// The file and the wire spell this one themselves, so the walks that
  /// emit, parse and encode by the table skip it.
  ///
  /// A row is here to be a KEY — something a binding files under, the read
  /// plane gets and sets, and the editor offers. Whether the file happens to
  /// spell it positionally (`text`), as a whole sublanguage (`style`) or by
  /// its parts (`args`) is a separate question, and this is the answer to
  /// it. Without the distinction those three could not be rows at all, and
  /// each got an ad-hoc key of its own instead — which is how a key space
  /// grew four kinds of thing in it.
  final bool byHand;
  final ScenePropKind kind;

  /// What a node holds when the file says nothing. A property at its
  /// default is not written — to the file, to the JSON, to the wire.
  final Object? defaultValue;

  /// The key on the wire when it is not [name] — `w` for width.
  final String? wireKey;
  final ScenePropOwner owner;

  /// Whether a motion track can write it — which also decides whether the
  /// wire carries the composed value rather than the authored one.
  final bool animatable;

  /// For a [ScenePropKind.choice].
  final SceneChoices? choices;

  /// For a [ScenePropKind.edges]: the four file names of the parts, in the
  /// quad's own order — `paddingLeft`, `paddingTop`…; `cornerTopLeft`…
  final List<String>? sides;

  /// For a [ScenePropKind.edges]: which quad it is, off the wire.
  final SceneQuad Function(Object? wire)? quad;

  final Object? Function(SceneNode node) read;
  final void Function(SceneNode node, Object? value) write;

  /// For a row of a registered kind: the kind's name. Null for the rows
  /// the hand-written kinds carry, which [owner] places.
  final String? kindName;

  /// Editing hints, when the row animates or is scrubbed: shown beside the
  /// number, where a slider should sit, whether it is a dial, and where a
  /// track should land.
  final String? unit;
  final double? softMin;
  final double? softMax;
  final bool angular;
  final double? identity;

  /// What the editor offers for a string row that names something in the
  /// project — a model file, a mesh in it, a clip in it. The row's value
  /// stays a plain string; this says where the choices come from.
  final ScenePick? pick;

  String get key => wireKey ?? name;

  bool appliesTo(SceneNode node) => switch (kindName) {
    var k? => node is KindNode && node.kind.name == k,
    null => owner.has(node),
  };

  /// The parameter kind a binding to this property must have, or null when
  /// no parameter can fill it — a choice, a list of sizes.
  SceneParamKind? get paramKind => switch (kind) {
    ScenePropKind.number ||
    ScenePropKind.size ||
    ScenePropKind.edges => SceneParamKind.number,
    ScenePropKind.string => SceneParamKind.string,
    ScenePropKind.boolean => SceneParamKind.bool,
    ScenePropKind.color => SceneParamKind.color,
    // No parameter can hold one of these. That is not the same as "nothing
    // can": a token holds a text style, and `sceneBindSources` is where the
    // two questions are asked apart.
    ScenePropKind.integer ||
    ScenePropKind.sizes ||
    ScenePropKind.layers ||
    ScenePropKind.axes ||
    ScenePropKind.choice ||
    ScenePropKind.style ||
    ScenePropKind.args => null,
  };

  /// Whether this row's value has named parts the table cannot list, so a
  /// key reaches one through the row's own name: `args.headline`, `axes.wght`.
  bool get hasNamedParts =>
      kind == ScenePropKind.args || kind == ScenePropKind.axes;

  /// Whether the wire and the authored JSON carry this row.
  ///
  /// A style and an args map do not: the wire already carries a style as its
  /// own fields and a node's arguments as their own map, and neither has a
  /// JSON spelling of its own. They are rows to be KEYS, not to be encoded.
  bool get onWire => kind != ScenePropKind.style && kind != ScenePropKind.args;

  /// The value as the wire and the authored JSON carry it.
  Object? toWire(Object? value) => switch (kind) {
    ScenePropKind.color => (value as SceneColor?)?.argb,
    ScenePropKind.size => sizeToWire(value as double?),
    ScenePropKind.sizes => [
      for (var c in value! as List<double?>) sizeToWire(c),
    ],
    ScenePropKind.layers => [
      for (var l in value! as List<TextLayer>) l.toWire(),
    ],
    ScenePropKind.axes => {...value! as Map<String, double>},
    ScenePropKind.edges => (value! as SceneQuad).toWire(),
    ScenePropKind.choice => value == null ? null : choices!.toWire(value),
    _ => value,
  };

  /// The inverse of [toWire]; a missing or unreadable value is the default.
  ///
  /// A [byHand] row never reaches either direction — the wire carries a
  /// style as its own fields and a node's arguments as their own map — so
  /// both switches leave those two kinds alone.
  Object? fromWire(Object? raw) => switch (kind) {
    ScenePropKind.style || ScenePropKind.args => raw,
    ScenePropKind.number => raw is num ? raw.toDouble() : defaultValue,
    ScenePropKind.integer => raw is num ? raw.toInt() : null,
    ScenePropKind.string => raw is String ? raw : defaultValue,
    ScenePropKind.boolean => raw is bool ? raw : defaultValue,
    ScenePropKind.color => raw is num ? SceneColor(raw.toInt()) : defaultValue,
    ScenePropKind.size => sizeFromWire(raw),
    ScenePropKind.sizes => switch (raw) {
      List l => [for (var c in l) sizeFromWire(c)],
      _ => <double?>[],
    },
    ScenePropKind.layers => switch (raw) {
      List l => [for (var e in l) ?TextLayer.fromWire(e)],
      _ => <TextLayer>[],
    },
    ScenePropKind.axes => switch (raw) {
      Map m => {
        for (var e in m.entries)
          if (e.value case num v) '${e.key}': v.toDouble(),
      },
      _ => <String, double>{},
    },
    ScenePropKind.edges => quad!(raw),
    ScenePropKind.choice => switch (raw) {
      String name => choices!.valueOf(name) ?? defaultValue,
      // Older payloads carried the index.
      num i when i >= 0 && i < choices!.values.length =>
        choices!.values[i.toInt()],
      _ => defaultValue,
    },
  };
}

// ── the table ──────────────────────────────────────────────────────────────

const _weights = SceneChoices(
  'SceneFontWeight',
  SceneFontWeight.values,
  nameOf: _weightName,
);
String _weightName(Object v) => 'w${(v as SceneFontWeight).value}';

const _layouts = SceneChoices(
  'NodeLayout',
  NodeLayout.values,
  nameOf: _enumName,
);
const _mainAligns = SceneChoices(
  'SceneMainAxisAlignment',
  SceneMainAxisAlignment.values,
  nameOf: _enumName,
);
const _crossAligns = SceneChoices(
  'SceneCrossAxisAlignment',
  SceneCrossAxisAlignment.values,
  nameOf: _enumName,
);
const _aligns = SceneChoices(
  'SceneTextAlign',
  SceneTextAlign.values,
  nameOf: _enumName,
);
const _cases = SceneChoices(
  'SceneTextCase',
  SceneTextCase.values,
  nameOf: _enumName,
);
const _decorations = SceneChoices(
  'SceneTextDecoration',
  SceneTextDecoration.values,
  nameOf: _enumName,
);
const _decorationStyles = SceneChoices(
  'SceneTextDecorationStyle',
  SceneTextDecorationStyle.values,
  nameOf: _enumName,
);
String _enumName(Object v) => (v as Enum).name;

/// Every node's properties, in the order the file writes them.
const sceneCommonProps = <SceneProp>[
  SceneProp(
    'x',
    ScenePropKind.number,
    defaultValue: 0.0,
    read: _x,
    write: _setX,
  ),
  SceneProp(
    'y',
    ScenePropKind.number,
    defaultValue: 0.0,
    read: _y,
    write: _setY,
  ),
  SceneProp(
    'width',
    ScenePropKind.size,
    wireKey: 'w',
    read: _width,
    write: _setWidth,
  ),
  SceneProp(
    'height',
    ScenePropKind.size,
    wireKey: 'h',
    read: _height,
    write: _setHeight,
  ),
  SceneProp(
    'fill',
    ScenePropKind.color,
    animatable: true,
    read: _fill,
    write: _setFill,
  ),
  SceneProp(
    'borderColor',
    ScenePropKind.color,
    read: _borderColor,
    write: _setBorderColor,
  ),
  SceneProp(
    'borderWidth',
    ScenePropKind.number,
    defaultValue: 1.0,
    read: _borderWidth,
    write: _setBorderWidth,
  ),
  SceneProp(
    'corner',
    ScenePropKind.edges,
    defaultValue: SceneCorners.zero,
    sides: [
      'cornerTopLeft',
      'cornerTopRight',
      'cornerBottomRight',
      'cornerBottomLeft',
    ],
    quad: SceneCorners.fromWire,
    read: _corners,
    write: _setCorners,
  ),
  SceneProp(
    'opacity',
    ScenePropKind.number,
    defaultValue: 1.0,
    animatable: true,
    read: _opacity,
    write: _setOpacity,
  ),
  SceneProp(
    'visible',
    ScenePropKind.boolean,
    defaultValue: true,
    read: _visible,
    write: _setVisible,
  ),
  SceneProp(
    'minWidth',
    ScenePropKind.number,
    read: _minWidth,
    write: _setMinWidth,
  ),
  SceneProp(
    'maxWidth',
    ScenePropKind.number,
    read: _maxWidth,
    write: _setMaxWidth,
  ),
  SceneProp(
    'minHeight',
    ScenePropKind.number,
    read: _minHeight,
    write: _setMinHeight,
  ),
  SceneProp(
    'maxHeight',
    ScenePropKind.number,
    read: _maxHeight,
    write: _setMaxHeight,
  ),
];

/// A frame's own properties, after the common ones. `children` and the
/// repeat are not here: they are structure, not values.
const sceneFrameProps = <SceneProp>[
  SceneProp(
    'layout',
    ScenePropKind.choice,
    owner: ScenePropOwner.frame,
    defaultValue: NodeLayout.absolute,
    choices: _layouts,
    read: _layout,
    write: _setLayout,
  ),
  SceneProp(
    'clip',
    ScenePropKind.boolean,
    owner: ScenePropOwner.frame,
    defaultValue: false,
    read: _clip,
    write: _setClip,
  ),
  SceneProp(
    'gap',
    ScenePropKind.number,
    owner: ScenePropOwner.frame,
    defaultValue: 8.0,
    animatable: true,
    read: _gap,
    write: _setGap,
  ),
  SceneProp(
    'padding',
    ScenePropKind.edges,
    owner: ScenePropOwner.frame,
    defaultValue: SceneEdges.zero,
    sides: ['paddingLeft', 'paddingTop', 'paddingRight', 'paddingBottom'],
    quad: SceneEdges.fromWire,
    read: _padding,
    write: _setPadding,
  ),
  SceneProp(
    'columns',
    ScenePropKind.sizes,
    owner: ScenePropOwner.frame,
    defaultValue: <double?>[],
    read: _columns,
    write: _setColumns,
  ),
  SceneProp(
    'cellPadding',
    ScenePropKind.edges,
    owner: ScenePropOwner.frame,
    defaultValue: SceneEdges.zero,
    sides: [
      'cellPaddingLeft',
      'cellPaddingTop',
      'cellPaddingRight',
      'cellPaddingBottom',
    ],
    quad: SceneEdges.fromWire,
    read: _cellPadding,
    write: _setCellPadding,
  ),
  SceneProp(
    'mainAlign',
    ScenePropKind.choice,
    owner: ScenePropOwner.frame,
    defaultValue: SceneMainAxisAlignment.start,
    choices: _mainAligns,
    read: _mainAlign,
    write: _setMainAlign,
  ),
  SceneProp(
    'crossAlign',
    ScenePropKind.choice,
    owner: ScenePropOwner.frame,
    defaultValue: SceneCrossAxisAlignment.center,
    choices: _crossAligns,
    read: _crossAlign,
    write: _setCrossAlign,
  ),
];

/// What a text spells for itself, beside its style.
///
/// The line the two lists are drawn on is whether the property describes the
/// TYPE or the PARAGRAPH. A face, a size, a tracking, a stack of paint
/// passes are the treatment, and sharing them across a poster and a card is
/// the point of a style. Where the lines break and how they sit in the box
/// are the box's business: two texts in one display face routinely differ on
/// both, and a shared style that decided them would be one nobody could
/// share. Flutter draws the same line — `align` and `maxLines` are `Text`'s
/// arguments, not `TextStyle`'s.
///
/// The text itself is the positional argument, read and written through the
/// table like the rest but spelled by hand.
const sceneTextOwnProps = <SceneProp>[
  SceneProp(
    'text',
    ScenePropKind.string,
    owner: ScenePropOwner.text,
    defaultValue: '',
    byHand: true,
    read: _text,
    write: _setText,
  ),
  // The treatment, whole. A node stores it as its resolved fields rather
  // than as an object, which is what `read` and `write` are for; as a key it
  // is an ordinary property whose type happens to be a text style.
  SceneProp(
    'style',
    ScenePropKind.style,
    owner: ScenePropOwner.text,
    byHand: true,
    read: _style,
    write: _setStyle,
  ),
  SceneProp(
    'align',
    ScenePropKind.choice,
    owner: ScenePropOwner.text,
    defaultValue: SceneTextAlign.left,
    choices: _aligns,
    read: _align,
    write: _setAlign,
  ),
  SceneProp(
    'maxLines',
    ScenePropKind.integer,
    owner: ScenePropOwner.text,
    read: _maxLines,
    write: _setMaxLines,
  ),
];

/// The table's STYLE SUBSET: exactly what a [SceneTextStyle] carries, and
/// exactly what `sceneTextStyleFields` names — pinned both ways, so a row
/// added here without a field there would be authorable and unshareable.
/// Every one of these is spelled inside the node's one `style:` argument.
const sceneStyleProps = <SceneProp>[
  SceneProp(
    'fontFamily',
    ScenePropKind.string,
    owner: ScenePropOwner.text,
    read: _fontFamily,
    write: _setFontFamily,
  ),
  SceneProp(
    'fontSize',
    ScenePropKind.number,
    owner: ScenePropOwner.text,
    defaultValue: 16.0,
    animatable: true,
    read: _fontSize,
    write: _setFontSize,
  ),
  SceneProp(
    'weight',
    ScenePropKind.choice,
    owner: ScenePropOwner.text,
    defaultValue: SceneFontWeight.w400,
    choices: _weights,
    read: _weight,
    write: _setWeight,
  ),
  SceneProp(
    'italic',
    ScenePropKind.boolean,
    owner: ScenePropOwner.text,
    defaultValue: false,
    read: _italic,
    write: _setItalic,
  ),
  SceneProp(
    'letterSpacing',
    ScenePropKind.number,
    owner: ScenePropOwner.text,
    defaultValue: 0.0,
    animatable: true,
    read: _letterSpacing,
    write: _setLetterSpacing,
  ),
  SceneProp(
    'wordSpacing',
    ScenePropKind.number,
    owner: ScenePropOwner.text,
    defaultValue: 0.0,
    animatable: true,
    read: _wordSpacing,
    write: _setWordSpacing,
  ),
  // A multiple of the font size, and 1.15 because that is what the renderer
  // used to hardcode: the default moves nothing, and now a file can reach it.
  SceneProp(
    'lineHeight',
    ScenePropKind.number,
    owner: ScenePropOwner.text,
    defaultValue: 1.15,
    animatable: true,
    read: _lineHeight,
    write: _setLineHeight,
  ),
  SceneProp(
    'color',
    ScenePropKind.color,
    owner: ScenePropOwner.text,
    defaultValue: SceneColor(0xFF1A1A1A),
    animatable: true,
    read: _color,
    write: _setColor,
  ),
  SceneProp(
    'textCase',
    ScenePropKind.choice,
    owner: ScenePropOwner.text,
    defaultValue: SceneTextCase.none,
    choices: _cases,
    read: _textCase,
    write: _setTextCase,
  ),
  SceneProp(
    'decoration',
    ScenePropKind.choice,
    owner: ScenePropOwner.text,
    defaultValue: SceneTextDecoration.none,
    choices: _decorations,
    read: _decoration,
    write: _setDecoration,
  ),
  SceneProp(
    'decorationColor',
    ScenePropKind.color,
    owner: ScenePropOwner.text,
    read: _decorationColor,
    write: _setDecorationColor,
  ),
  SceneProp(
    'decorationThickness',
    ScenePropKind.number,
    owner: ScenePropOwner.text,
    defaultValue: 1.0,
    animatable: true,
    read: _decorationThickness,
    write: _setDecorationThickness,
  ),
  SceneProp(
    'decorationStyle',
    ScenePropKind.choice,
    owner: ScenePropOwner.text,
    defaultValue: SceneTextDecorationStyle.solid,
    choices: _decorationStyles,
    read: _decorationStyle,
    write: _setDecorationStyle,
  ),
  SceneProp(
    'layers',
    ScenePropKind.layers,
    owner: ScenePropOwner.text,
    defaultValue: <TextLayer>[],
    read: _layers,
    write: _setLayers,
  ),
  // The face's own dials. The map is one property; each axis is a part of
  // it, so `axes.wght` binds and animates while the map does neither.
  SceneProp(
    'axes',
    ScenePropKind.axes,
    owner: ScenePropOwner.text,
    defaultValue: <String, double>{},
    read: _axes,
    write: _setAxes,
  ),
];

/// Every property a text carries, its own and its style's.
const sceneTextProps = <SceneProp>[...sceneTextOwnProps, ...sceneStyleProps];

/// What a node that stands for something else passes it. One row, whose
/// PARTS are the child's own parameter names — the only property whose parts
/// this table cannot list, which is why they carry a prefix.
const sceneArgsProps = <SceneProp>[
  SceneProp(
    'args',
    ScenePropKind.args,
    owner: ScenePropOwner.takesArgs,
    byHand: true,
    read: _args,
    write: _setArgs,
  ),
];

const sceneShapeProps = <SceneProp>[
  SceneProp(
    'circle',
    ScenePropKind.boolean,
    owner: ScenePropOwner.shape,
    defaultValue: false,
    read: _circle,
    write: _setCircle,
  ),
];

/// The table, whole — the hand-written kinds' rows, plus every registered
/// kind's.
List<SceneProp> get sceneProps => [
  ...sceneCommonProps,
  ...sceneFrameProps,
  ...sceneTextProps,
  ...sceneArgsProps,
  ...sceneShapeProps,
  for (var k in sceneKinds) ...k.props,
];

/// The properties [node] carries, in file order: its kind's own after the
/// common ones.
List<SceneProp> scenePropsOf(SceneNode node) => [
  for (var p in sceneCommonProps)
    if (p.appliesTo(node)) p,
  ...switch (node) {
    KindNode k => k.kind.props,
    _ => [
      for (var p in sceneProps)
        if (p.kindName == null && p.owner != ScenePropOwner.any)
          if (p.appliesTo(node)) p,
    ],
  },
];

/// One property by name, when [node] carries it.
SceneProp? scenePropNamed(SceneNode node, String name) {
  for (var p in scenePropsOf(node)) {
    if (p.name == name) return p;
  }
  return null;
}

/// Whether [value] is what the property holds by default — the test that
/// decides whether it is written at all.
bool isSceneDefault(SceneProp p, Object? value) => switch (p.kind) {
  // A list is never `==` another list with the same contents, so the test is
  // emptiness — which is what every list property's default is.
  ScenePropKind.sizes || ScenePropKind.layers =>
    (value! as List).isEmpty && (p.defaultValue! as List).isEmpty,
  // A map is not `==` another with the same entries either.
  ScenePropKind.axes => (value! as Map).isEmpty,
  _ => value == p.defaultValue,
};

// ── accessors: the one place a name meets a field ─────────────────────────

Object? _x(SceneNode n) => n.x;
void _setX(SceneNode n, Object? v) => n.x = (v! as num).toDouble();
Object? _y(SceneNode n) => n.y;
void _setY(SceneNode n, Object? v) => n.y = (v! as num).toDouble();
Object? _width(SceneNode n) => n.width;
void _setWidth(SceneNode n, Object? v) => n.width = v as double?;
Object? _height(SceneNode n) => n.height;
void _setHeight(SceneNode n, Object? v) => n.height = v as double?;
Object? _fill(SceneNode n) => n.fill;
void _setFill(SceneNode n, Object? v) => n.fill = v as SceneColor?;
Object? _borderColor(SceneNode n) => n.borderColor;
void _setBorderColor(SceneNode n, Object? v) =>
    n.borderColor = v as SceneColor?;
Object? _borderWidth(SceneNode n) => n.borderWidth;
void _setBorderWidth(SceneNode n, Object? v) =>
    n.borderWidth = (v! as num).toDouble();
Object? _corners(SceneNode n) => n.corners;
void _setCorners(SceneNode n, Object? v) => n.corners = v! as SceneCorners;
Object? _minWidth(SceneNode n) => n.minWidth;
void _setMinWidth(SceneNode n, Object? v) =>
    n.minWidth = (v as num?)?.toDouble();
Object? _maxWidth(SceneNode n) => n.maxWidth;
void _setMaxWidth(SceneNode n, Object? v) =>
    n.maxWidth = (v as num?)?.toDouble();
Object? _minHeight(SceneNode n) => n.minHeight;
void _setMinHeight(SceneNode n, Object? v) =>
    n.minHeight = (v as num?)?.toDouble();
Object? _maxHeight(SceneNode n) => n.maxHeight;
void _setMaxHeight(SceneNode n, Object? v) =>
    n.maxHeight = (v as num?)?.toDouble();
Object? _opacity(SceneNode n) => n.opacity;
void _setOpacity(SceneNode n, Object? v) => n.opacity = (v! as num).toDouble();
Object? _visible(SceneNode n) => n.visible;
void _setVisible(SceneNode n, Object? v) => n.visible = v! as bool;

Object? _clip(SceneNode n) => (n as FrameNode).clip;
void _setClip(SceneNode n, Object? v) => (n as FrameNode).clip = v! as bool;
Object? _layout(SceneNode n) => (n as FrameNode).layout;
void _setLayout(SceneNode n, Object? v) =>
    (n as FrameNode).layout = v! as NodeLayout;
Object? _gap(SceneNode n) => (n as FrameNode).gap;
void _setGap(SceneNode n, Object? v) =>
    (n as FrameNode).gap = (v! as num).toDouble();
Object? _padding(SceneNode n) => (n as FrameNode).padding;
void _setPadding(SceneNode n, Object? v) =>
    (n as FrameNode).padding = v! as SceneEdges;
Object? _columns(SceneNode n) => (n as FrameNode).columns;
void _setColumns(SceneNode n, Object? v) =>
    (n as FrameNode).columns = [...v! as List<double?>];
Object? _cellPadding(SceneNode n) => (n as FrameNode).cellPadding;
void _setCellPadding(SceneNode n, Object? v) =>
    (n as FrameNode).cellPadding = v! as SceneEdges;
Object? _mainAlign(SceneNode n) => (n as FrameNode).mainAlign;
void _setMainAlign(SceneNode n, Object? v) =>
    (n as FrameNode).mainAlign = v! as SceneMainAxisAlignment;
Object? _crossAlign(SceneNode n) => (n as FrameNode).crossAlign;
void _setCrossAlign(SceneNode n, Object? v) =>
    (n as FrameNode).crossAlign = v! as SceneCrossAxisAlignment;

Object? _text(SceneNode n) => (n as TextNode).text;
void _setText(SceneNode n, Object? v) => (n as TextNode).text = v! as String;
Object? _fontFamily(SceneNode n) => (n as TextNode).fontFamily;
void _setFontFamily(SceneNode n, Object? v) =>
    (n as TextNode).fontFamily = v as String?;
Object? _italic(SceneNode n) => (n as TextNode).italic;
void _setItalic(SceneNode n, Object? v) => (n as TextNode).italic = v! as bool;
Object? _letterSpacing(SceneNode n) => (n as TextNode).letterSpacing;
void _setLetterSpacing(SceneNode n, Object? v) =>
    (n as TextNode).letterSpacing = (v! as num).toDouble();
Object? _wordSpacing(SceneNode n) => (n as TextNode).wordSpacing;
void _setWordSpacing(SceneNode n, Object? v) =>
    (n as TextNode).wordSpacing = (v! as num).toDouble();
Object? _lineHeight(SceneNode n) => (n as TextNode).lineHeight;
void _setLineHeight(SceneNode n, Object? v) =>
    (n as TextNode).lineHeight = (v! as num).toDouble();
Object? _textCase(SceneNode n) => (n as TextNode).textCase;
void _setTextCase(SceneNode n, Object? v) =>
    (n as TextNode).textCase = v! as SceneTextCase;
Object? _decoration(SceneNode n) => (n as TextNode).decoration;
void _setDecoration(SceneNode n, Object? v) =>
    (n as TextNode).decoration = v! as SceneTextDecoration;
Object? _decorationColor(SceneNode n) => (n as TextNode).decorationColor;
void _setDecorationColor(SceneNode n, Object? v) =>
    (n as TextNode).decorationColor = v as SceneColor?;
Object? _decorationThickness(SceneNode n) =>
    (n as TextNode).decorationThickness;
void _setDecorationThickness(SceneNode n, Object? v) =>
    (n as TextNode).decorationThickness = (v! as num).toDouble();
Object? _decorationStyle(SceneNode n) => (n as TextNode).decorationStyle;
void _setDecorationStyle(SceneNode n, Object? v) =>
    (n as TextNode).decorationStyle = v! as SceneTextDecorationStyle;
Object? _fontSize(SceneNode n) => (n as TextNode).fontSize;
void _setFontSize(SceneNode n, Object? v) =>
    (n as TextNode).fontSize = (v! as num).toDouble();
Object? _weight(SceneNode n) => (n as TextNode).weight;
void _setWeight(SceneNode n, Object? v) =>
    (n as TextNode).weight = v! as SceneFontWeight;
Object? _color(SceneNode n) => (n as TextNode).color;
void _setColor(SceneNode n, Object? v) =>
    (n as TextNode).color = v! as SceneColor;
Object? _align(SceneNode n) => (n as TextNode).align;
void _setAlign(SceneNode n, Object? v) =>
    (n as TextNode).align = v! as SceneTextAlign;
Object? _layers(SceneNode n) => (n as TextNode).layers;
// Copied, so the row's const empty default is never handed out as a node's
// own mutable list — the trap `columns` already answers this way.
void _setLayers(SceneNode n, Object? v) =>
    (n as TextNode).layers = [...v! as List<TextLayer>];
Object? _axes(SceneNode n) => (n as TextNode).axes;
// Copied, for the same reason `layers` is.
void _setAxes(SceneNode n, Object? v) =>
    (n as TextNode).axes = {...v! as Map<String, double>};
Object? _maxLines(SceneNode n) => (n as TextNode).maxLines;
void _setMaxLines(SceneNode n, Object? v) =>
    (n as TextNode).maxLines = v as int?;

Object? _circle(SceneNode n) => (n as ShapeNode).circle;
void _setCircle(SceneNode n, Object? v) => (n as ShapeNode).circle = v! as bool;

/// A text's whole style, built from the rows that make one. The node keeps
/// the resolved fields, not the object, so this is where the object is.
Object? _style(SceneNode n) => SceneTextStyle.fromValues({
  for (var p in sceneStyleProps) p.name: p.read(n),
});

void _setStyle(SceneNode n, Object? v) {
  if (v is! SceneTextStyle) return;
  for (var e in v.values.entries) {
    scenePropNamed(n, e.key)?.write(n, e.value);
  }
}

Object? _args(SceneNode n) => switch (n) {
  SceneRefNode r => r.args,
  ExternalNode e => e.args,
  _ => null,
};

void _setArgs(SceneNode n, Object? v) {
  if (v is! Map<String, Object?>) return;
  switch (n) {
    case SceneRefNode r:
      r.args
        ..clear()
        ..addAll(v);
    case ExternalNode e:
      e.args
        ..clear()
        ..addAll(v);
    default:
      break;
  }
}
