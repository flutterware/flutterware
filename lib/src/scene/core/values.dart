// The scene core's own value vocabulary: the grammar's allowlist as real
// types, so the model and both grammars stay pure Dart and the whole
// headless surface (fw scene check, MCP tools, codemods) needs no Flutter.
// The *file* spellings (`Color(0xFF…)`, `FontWeight.w700`) are the grammar's
// canon and unchanged; these are the values they parse into. The Flutter
// half converts at the edge (lib/src/scene/flutter_bridge.dart), where a
// test holds every enum's order to Flutter's.

/// An ARGB color. Files spell it `Color(0xAARRGGBB)` — the only accepted
/// color spelling; the mirror carries exactly that.
class SceneColor {
  const SceneColor(this.argb);

  final int argb;

  int get alpha => (argb >> 24) & 0xFF;
  int get red => (argb >> 16) & 0xFF;
  int get green => (argb >> 8) & 0xFF;
  int get blue => argb & 0xFF;

  static SceneColor lerp(SceneColor a, SceneColor b, double t) {
    int ch(int x, int y) => (x + (y - x) * t).round().clamp(0, 255);
    return SceneColor(
      (ch(a.alpha, b.alpha) << 24) |
          (ch(a.red, b.red) << 16) |
          (ch(a.green, b.green) << 8) |
          ch(a.blue, b.blue),
    );
  }

  @override
  bool operator ==(Object other) => other is SceneColor && other.argb == argb;

  @override
  int get hashCode => argb.hashCode;

  @override
  String toString() =>
      'Color(0x${argb.toRadixString(16).padLeft(8, '0').toUpperCase()})';
}

/// The nine weights, file-spelled `FontWeight.w<value>`.
class SceneFontWeight {
  const SceneFontWeight._(this.index, this.value);

  /// Position in [values] — the wire carries this, and the bridge test pins
  /// it to Flutter's `FontWeight.values` order.
  final int index;

  /// The numeric weight (100–900) the file spells.
  final int value;

  static const w100 = SceneFontWeight._(0, 100);
  static const w200 = SceneFontWeight._(1, 200);
  static const w300 = SceneFontWeight._(2, 300);
  static const w400 = SceneFontWeight._(3, 400);
  static const w500 = SceneFontWeight._(4, 500);
  static const w600 = SceneFontWeight._(5, 600);
  static const w700 = SceneFontWeight._(6, 700);
  static const w800 = SceneFontWeight._(7, 800);
  static const w900 = SceneFontWeight._(8, 900);

  static const values = [w100, w200, w300, w400, w500, w600, w700, w800, w900];

  @override
  String toString() => 'FontWeight.w$value';
}

/// File-spelled `CrossAxisAlignment.<name>`; declaration order matches
/// Flutter's, because the wire carries the index.
enum SceneCrossAxisAlignment { start, end, center, stretch, baseline }

/// How a text sits in the box it was given. Flutter's own names, because
/// that is what the file spells and what it becomes.
enum SceneTextAlign { left, right, center, justify }

/// How a text's case is forced, whatever the string says. Not a Flutter
/// property — the renderer applies it to the string — but a design tool's,
/// and the reason a kicker can be typed in the language it reads in and
/// still be drawn in caps.
enum SceneTextCase {
  none,
  upper,
  lower,
  title;

  /// [text] as this case draws it. The string in the file is left alone —
  /// a kicker is typed in the language it reads in and drawn in caps, and
  /// what an importer or a translator sees is still the sentence.
  String apply(String text) => switch (this) {
    none => text,
    upper => text.toUpperCase(),
    lower => text.toLowerCase(),
    title =>
      text
          .split(' ')
          .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
          .join(' '),
  };
}

/// The line a text carries. Flutter's `TextDecoration` is a set rather than
/// an enum, so the bridge switches rather than indexing; one line is what a
/// design tool offers and what an import brings.
enum SceneTextDecoration { none, underline, overline, lineThrough }

/// How that line is drawn; declaration order matches Flutter's, because the
/// bridge indexes it.
enum SceneTextDecorationStyle { solid, double, dotted, dashed, wavy }

/// A number off the wire, or [fallback] when it is missing or not a number,
/// so a payload that is present but the wrong shape does not throw.
/// [ScenePaint.fromWire] (a radial's radius, a sweep's angles) and
/// [TextLayer.fromWire] read their numbers through it; the decoders that take
/// a list or a word where a number may be — [SceneAlignment.fromWire],
/// [SceneEdges.fromWire], [SceneCorners.fromWire], a gradient's colours and
/// stops, [sizeFromWire] — match `num` in patterns of their own, to the same
/// effect.
double _wireDouble(Object? v, double fallback) =>
    v is num ? v.toDouble() : fallback;

/// A point in a box, in the -1..1 space Flutter's `Alignment` uses — where a
/// gradient starts and ends.
class SceneAlignment {
  const SceneAlignment(this.x, this.y);

  final double x;
  final double y;

  static const topLeft = SceneAlignment(-1, -1);
  static const topCenter = SceneAlignment(0, -1);
  static const topRight = SceneAlignment(1, -1);
  static const centerLeft = SceneAlignment(-1, 0);
  static const center = SceneAlignment(0, 0);
  static const centerRight = SceneAlignment(1, 0);
  static const bottomLeft = SceneAlignment(-1, 1);
  static const bottomCenter = SceneAlignment(0, 1);
  static const bottomRight = SceneAlignment(1, 1);

  List<double> toWire() => [x, y];

  // A non-number element makes the whole value fall back — a point is
  // meaningless with only one of its two numbers.
  static SceneAlignment fromWire(Object? raw, SceneAlignment fallback) =>
      switch (raw) {
        List l when l.length == 2 && l[0] is num && l[1] is num =>
          SceneAlignment((l[0] as num).toDouble(), (l[1] as num).toDouble()),
        _ => fallback,
      };

  @override
  bool operator ==(Object other) =>
      other is SceneAlignment && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'SceneAlignment($x, $y)';
}

/// What a pass paints with: one colour, a gradient across the box, or one of
/// the project's own fragment shaders.
///
/// Built for text layers, and shaped for `fill` to adopt the day a frame's
/// fill becomes a list of paints — a second notion of paint
/// is the thing to avoid, not a second user of this one. Linear, radial and
/// sweep share [SceneGradient]; the wire tags the kind, so a new one is
/// additive.
sealed class ScenePaint {
  const ScenePaint();

  Object toWire();

  /// Total, like every `fromWire` here: an unreadable payload is null rather
  /// than a throw, and null means "the text's own colour".
  static ScenePaint? fromWire(Object? raw) => switch (raw) {
    // A bare number is a solid colour — the cheapest spelling, and what a
    // colour already travels as everywhere else.
    num argb => SolidPaint(SceneColor(argb.toInt())),
    Map m when m['k'] == 'linear' => LinearPaint(
      colors: _wireColors(m),
      stops: _wireStops(m),
      begin: SceneAlignment.fromWire(m['begin'], SceneAlignment.topCenter),
      end: SceneAlignment.fromWire(m['end'], SceneAlignment.bottomCenter),
    ),
    Map m when m['k'] == 'radial' => RadialPaint(
      colors: _wireColors(m),
      stops: _wireStops(m),
      center: SceneAlignment.fromWire(m['center'], SceneAlignment.center),
      radius: _wireDouble(m['r'], 1),
    ),
    Map m when m['k'] == 'sweep' => SweepPaint(
      colors: _wireColors(m),
      stops: _wireStops(m),
      center: SceneAlignment.fromWire(m['center'], SceneAlignment.center),
      startAngle: _wireDouble(m['a0'], 0),
      endAngle: _wireDouble(m['a1'], 360),
    ),
    Map m when m['k'] == 'shader' => switch (m['asset']) {
      String asset => ShaderPaint(asset, uniforms: _wireUniforms(m['u'])),
      _ => null,
    },
    _ => null,
  };
}

class SolidPaint extends ScenePaint {
  const SolidPaint(this.color);

  final SceneColor color;

  @override
  Object toWire() => color.argb;

  @override
  bool operator ==(Object other) => other is SolidPaint && other.color == color;

  @override
  int get hashCode => color.hashCode;

  @override
  String toString() => 'SolidPaint($color)';
}

// A non-number element is SKIPPED rather than failing the whole list — a
// gradient with one bad colour still has the rest of its colours.
List<SceneColor> _wireColors(Map m) => [
  for (var c in switch (m['colors']) {
    List l => l,
    _ => const [],
  })
    if (c is num) SceneColor(c.toInt()),
];

// Same rule as colours: a bad stop is skipped. A stops list left shorter
// than colors falls back to the even spread through SceneGradient.resolvedStops.
List<double>? _wireStops(Map m) => switch (m['stops']) {
  List l => [
    for (var s in l)
      if (s is num) s.toDouble(),
  ],
  _ => null,
};

/// The three gradients, and what they share: colours, where each one sits,
/// and the even spread a missing position means.
sealed class SceneGradient extends ScenePaint {
  const SceneGradient({required this.colors, this.stops});

  final List<SceneColor> colors;

  /// One position per colour, 0..1 along the gradient. Null spreads the
  /// colours evenly — what the file omits, and what the editor writes out
  /// the first time a stop is moved.
  final List<double>? stops;

  /// [stops] when they give one position per colour, otherwise the even
  /// spread. The engine refuses any other shape, so this is what reaches it.
  List<double> get resolvedStops {
    if (stops case var s? when s.length == colors.length) return s;
    var n = colors.length;
    return [for (var i = 0; i < n; i++) n == 1 ? 0.0 : i / (n - 1)];
  }

  /// This gradient with other colours at other positions, its shape kept —
  /// what every stop edit is.
  SceneGradient withStops(List<SceneColor> colors, List<double>? stops);

  Map<String, Object?> get _stopsWire => {
    'colors': [for (var c in colors) c.argb],
    'stops': ?stops,
  };

  bool _sameStops(SceneGradient other) =>
      _sameList(other.colors, colors) && _sameList(other.stops, stops);

  int get _stopsHash =>
      Object.hash(Object.hashAll(colors), Object.hashAll(stops ?? const []));
}

/// A gradient down the box by default, which is what a metal or a sunset
/// face wants.
class LinearPaint extends SceneGradient {
  const LinearPaint({
    required super.colors,
    super.stops,
    this.begin = SceneAlignment.topCenter,
    this.end = SceneAlignment.bottomCenter,
  });

  final SceneAlignment begin;
  final SceneAlignment end;

  @override
  LinearPaint withStops(List<SceneColor> colors, List<double>? stops) =>
      LinearPaint(colors: colors, stops: stops, begin: begin, end: end);

  @override
  Object toWire() => {
    'k': 'linear',
    ..._stopsWire,
    'begin': begin.toWire(),
    'end': end.toWire(),
  };

  @override
  bool operator ==(Object other) =>
      other is LinearPaint &&
      _sameStops(other) &&
      other.begin == begin &&
      other.end == end;

  @override
  int get hashCode => Object.hash(_stopsHash, begin, end);

  @override
  String toString() => 'LinearPaint($colors)';
}

/// A gradient out from a point, STRETCHED TO THE BOX: at [radius] 1 it
/// reaches the edges on both axes, so on a wide headline it is an ellipse.
/// Flutter's `RadialGradient` measures its radius against the shortest side
/// instead, and on a 600×80 title that is a dot in the middle.
class RadialPaint extends SceneGradient {
  const RadialPaint({
    required super.colors,
    super.stops,
    this.center = SceneAlignment.center,
    this.radius = 1,
  });

  final SceneAlignment center;

  /// In half-box units: 1 reaches the edge from the middle, on each axis.
  final double radius;

  @override
  RadialPaint withStops(List<SceneColor> colors, List<double>? stops) =>
      RadialPaint(colors: colors, stops: stops, center: center, radius: radius);

  RadialPaint copyWith({SceneAlignment? center, double? radius}) => RadialPaint(
    colors: colors,
    stops: stops,
    center: center ?? this.center,
    radius: radius ?? this.radius,
  );

  @override
  Object toWire() => {
    'k': 'radial',
    ..._stopsWire,
    if (center != SceneAlignment.center) 'center': center.toWire(),
    if (radius != 1) 'r': radius,
  };

  @override
  bool operator ==(Object other) =>
      other is RadialPaint &&
      _sameStops(other) &&
      other.center == center &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(_stopsHash, center, radius);

  @override
  String toString() => 'RadialPaint($colors)';
}

/// A gradient around a point, the way a clock hand sweeps: 0° is twelve
/// o'clock and angles run clockwise, in degrees — the unit `rotate` uses.
/// Flutter's `SweepGradient` starts at three o'clock in radians; the
/// renderer turns it, so the file never has to.
///
/// Not stretched to the box the way [RadialPaint] is: an angle in a
/// stretched box is not the angle that was typed.
class SweepPaint extends SceneGradient {
  const SweepPaint({
    required super.colors,
    super.stops,
    this.center = SceneAlignment.center,
    this.startAngle = 0,
    this.endAngle = 360,
  });

  final SceneAlignment center;

  /// Where the first colour sits.
  final double startAngle;

  /// Where the last colour sits; past it the last colour holds. 360 more
  /// than [startAngle] is a full turn.
  final double endAngle;

  @override
  SweepPaint withStops(List<SceneColor> colors, List<double>? stops) =>
      SweepPaint(
        colors: colors,
        stops: stops,
        center: center,
        startAngle: startAngle,
        endAngle: endAngle,
      );

  SweepPaint copyWith({
    SceneAlignment? center,
    double? startAngle,
    double? endAngle,
  }) => SweepPaint(
    colors: colors,
    stops: stops,
    center: center ?? this.center,
    startAngle: startAngle ?? this.startAngle,
    endAngle: endAngle ?? this.endAngle,
  );

  @override
  Object toWire() => {
    'k': 'sweep',
    ..._stopsWire,
    if (center != SceneAlignment.center) 'center': center.toWire(),
    if (startAngle != 0) 'a0': startAngle,
    if (endAngle != 360) 'a1': endAngle,
  };

  @override
  bool operator ==(Object other) =>
      other is SweepPaint &&
      _sameStops(other) &&
      other.center == center &&
      other.startAngle == startAngle &&
      other.endAngle == endAngle;

  @override
  int get hashCode => Object.hash(_stopsHash, center, startAngle, endAngle);

  @override
  String toString() => 'SweepPaint($colors)';
}

/// A pass painted by one of the project's own fragment shaders.
///
/// [asset] is the shader's key in the bundle — the path its pubspec declares
/// under `flutter: shaders:`, and what `FragmentProgram.fromAsset` takes.
/// [uniforms] are the author's values by name, one to four floats each (a
/// float, a vec2, a vec3, a vec4). The renderer sets [rendererUniforms]
/// itself, and a name the shader does not declare is skipped, never thrown.
class ShaderPaint extends ScenePaint {
  const ShaderPaint(this.asset, {this.uniforms = const {}});

  final String asset;
  final Map<String, List<double>> uniforms;

  /// What the renderer sets, by name and float count, when the shader
  /// declares it at that size: the box's logical size (the whole text, or
  /// one line), the text's own colour as straight RGBA 0–1, and scene
  /// seconds. A shader that does not declare one simply does not get it.
  static const rendererUniforms = {'uSize': 2, 'uColor': 4, 'uTime': 1};

  @override
  Object toWire() => {
    'k': 'shader',
    'asset': asset,
    if (uniforms.isNotEmpty)
      'u': {
        for (var e in uniforms.entries) e.key: [...e.value],
      },
  };

  @override
  bool operator ==(Object other) =>
      other is ShaderPaint &&
      other.asset == asset &&
      _sameUniforms(other.uniforms, uniforms);

  @override
  int get hashCode => Object.hash(
    asset,
    Object.hashAllUnordered([
      for (var e in uniforms.entries)
        Object.hash(e.key, Object.hashAll(e.value)),
    ]),
  );

  @override
  String toString() => 'ShaderPaint($asset, $uniforms)';
}

bool _sameUniforms(Map<String, List<double>> a, Map<String, List<double>> b) {
  if (a.length != b.length) return false;
  for (var e in a.entries) {
    if (!_sameList(e.value, b[e.key])) return false;
  }
  return true;
}

// A uniform that is not one to four numbers is SKIPPED, like a bad colour:
// the rest of the shader's values still reach it.
Map<String, List<double>> _wireUniforms(Object? raw) => switch (raw) {
  Map u => {
    for (var MapEntry(:key, :value) in u.entries)
      if (key is String) key: ?_wireFloats(value),
  },
  _ => const {},
};

List<double>? _wireFloats(Object? raw) => switch (raw) {
  num n => [n.toDouble()],
  List l when l.isNotEmpty && l.length <= 4 && l.every((x) => x is num) => [
    for (var x in l) (x as num).toDouble(),
  ],
  _ => null,
};

/// Whether two property values are the same value.
///
/// `==` is not enough, because two property kinds are COLLECTIONS and two
/// lists — or two maps — with the same contents are not `==` each other.
/// Every place that asks "is this what the style says" or "is this still the
/// default" goes through here, or an inherited paint stack reads as an
/// override — which is exactly what it did before this existed.
bool sceneValuesEqual(Object? a, Object? b) => switch ((a, b)) {
  (List x, List y) => _sameList(x, y),
  (Map x, Map y) => _sameMap(x, y),
  _ => a == b,
};

bool _sameMap(Map? a, Map? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}

bool _sameList<T>(List<T>? a, List<T>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// How a stroke turns a corner. Declaration order matches Flutter's, because
/// the bridge indexes it.
enum SceneStrokeJoin { miter, round, bevel }

/// What a pass's paint is laid across. A solid colour is the same either
/// way; a gradient is not — a two-line title in gold wants the gold to run
/// down EACH line, not once down the paragraph with the second line in its
/// darker half.
///
/// On the pass rather than on the paint, because a paint is shaped to be a
/// frame's fill one day, and a frame has no lines.
enum SceneLayerBox { text, line }

/// How a pass lands on what is already there — the modes a design tool
/// offers on a layer, by Flutter's names. `normal` is the engine's
/// `srcOver`; the rest are spelled the same on both sides, which the bridge
/// test pins name by name.
enum SceneBlendMode {
  normal,
  multiply,
  screen,
  overlay,
  darken,
  lighten,
  colorDodge,
  colorBurn,
  hardLight,
  softLight,
  difference,
  exclusion,
  hue,
  saturation,
  color,
  luminosity,
}

/// One pass over a laid-out paragraph.
///
/// A text's paint stack is an ordered list of these, painted back to front,
/// and the effect space is what combining them reaches: a drop shadow is a
/// blurred offset fill, an outline is a stroke beneath the fill, sticker type
/// is stroke-stroke-fill, extruded type is a dozen offset fills under a
/// gradient one. None of those is a code path.
///
/// Layers are ANONYMOUS and immutable, and they live on the style rather than
/// the node: a named per-node stack is a treatment nothing else can share,
/// which defeats the point of a style. They must be immutable to sit inside a
/// `const Token<SceneTextStyle>`, so an edit replaces the list and an
/// animation composes a value rather than mutating one.
///
/// **A pass may change paint, never layout.** Every field here is paint; a
/// metric one would give the passes two layouts to register against, and
/// every effect would drift by a subpixel that grows along the line.
sealed class TextLayer {
  const TextLayer({
    this.paint,
    this.blur = 0,
    this.dx = 0,
    this.dy = 0,
    this.opacity = 1,
    this.box = SceneLayerBox.text,
    this.blend = SceneBlendMode.normal,
  });

  /// Null paints the text's own colour — which is what lets one stack serve
  /// several colours, and what a run's own colour reaches through.
  final ScenePaint? paint;

  /// The glyph outline blurred, through a mask filter on this pass's own
  /// paint. Not the pass composited and blurred: that is a layer save per
  /// pass, and a different performance story.
  final double blur;
  final double dx;
  final double dy;
  final double opacity;

  /// What [paint] is measured against: the whole text, or each line.
  final SceneLayerBox box;

  /// How this pass lands on the passes beneath it and on what is behind the
  /// text.
  final SceneBlendMode blend;

  Map<String, Object?> toWire();

  /// This pass painted with [paint] instead — null included, which is "the
  /// text's own colour" and the one value [copyWith] cannot say, because
  /// there a null means "not given".
  TextLayer withPaint(ScenePaint? paint);

  /// This pass with the fields given changed and the rest kept. Every edit
  /// and every rescale goes through here, so a field added to a pass is
  /// carried by all of them rather than dropped by whichever call site
  /// respelled the constructor and forgot it.
  TextLayer copyWith({
    double? blur,
    double? dx,
    double? dy,
    double? opacity,
    SceneLayerBox? box,
    SceneBlendMode? blend,
  });

  Map<String, Object?> get _common => {
    'paint': ?paint?.toWire(),
    if (blur != 0) 'blur': blur,
    if (dx != 0) 'dx': dx,
    if (dy != 0) 'dy': dy,
    if (opacity != 1) 'o': opacity,
    if (box != SceneLayerBox.text) 'box': box.name,
    if (blend != SceneBlendMode.normal) 'blend': blend.name,
  };

  static TextLayer? fromWire(Object? raw) {
    if (raw is! Map) return null;
    var paint = ScenePaint.fromWire(raw['paint']);
    var blur = _wireDouble(raw['blur'], 0);
    var dx = _wireDouble(raw['dx'], 0);
    var dy = _wireDouble(raw['dy'], 0);
    var opacity = _wireDouble(raw['o'], 1);
    var box =
        SceneLayerBox.values.asNameMap()[raw['box']] ?? SceneLayerBox.text;
    var blend =
        SceneBlendMode.values.asNameMap()[raw['blend']] ??
        SceneBlendMode.normal;
    return switch (raw['k']) {
      'stroke' => StrokeLayer(
        width: _wireDouble(raw['w'], 1),
        join: switch (raw['j']) {
          num i when i >= 0 && i < SceneStrokeJoin.values.length =>
            SceneStrokeJoin.values[i.toInt()],
          _ => SceneStrokeJoin.round,
        },
        paint: paint,
        blur: blur,
        dx: dx,
        dy: dy,
        opacity: opacity,
        box: box,
        blend: blend,
      ),
      _ => FillLayer(
        paint: paint,
        blur: blur,
        dx: dx,
        dy: dy,
        opacity: opacity,
        box: box,
        blend: blend,
      ),
    };
  }
}

class FillLayer extends TextLayer {
  const FillLayer({
    super.paint,
    super.blur,
    super.dx,
    super.dy,
    super.opacity,
    super.box,
    super.blend,
  });

  @override
  Map<String, Object?> toWire() => {'k': 'fill', ..._common};

  @override
  FillLayer withPaint(ScenePaint? paint) => FillLayer(
    paint: paint,
    blur: blur,
    dx: dx,
    dy: dy,
    opacity: opacity,
    box: box,
    blend: blend,
  );

  @override
  FillLayer copyWith({
    double? blur,
    double? dx,
    double? dy,
    double? opacity,
    SceneLayerBox? box,
    SceneBlendMode? blend,
  }) => FillLayer(
    paint: paint,
    blur: blur ?? this.blur,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    opacity: opacity ?? this.opacity,
    box: box ?? this.box,
    blend: blend ?? this.blend,
  );

  @override
  bool operator ==(Object other) =>
      other is FillLayer &&
      other.paint == paint &&
      other.blur == blur &&
      other.dx == dx &&
      other.dy == dy &&
      other.opacity == opacity &&
      other.box == box &&
      other.blend == blend;

  @override
  int get hashCode => Object.hash(paint, blur, dx, dy, opacity, box, blend);

  @override
  String toString() => 'FillLayer($paint)';
}

/// A stroke *around* the glyph outline. It widens the mark without touching
/// the metrics, which is the whole reason several passes stay registered.
class StrokeLayer extends TextLayer {
  const StrokeLayer({
    this.width = 1,
    this.join = SceneStrokeJoin.round,
    super.paint,
    super.blur,
    super.dx,
    super.dy,
    super.opacity,
    super.box,
    super.blend,
  });

  final double width;
  final SceneStrokeJoin join;

  @override
  Map<String, Object?> toWire() => {
    'k': 'stroke',
    'w': width,
    if (join != SceneStrokeJoin.round) 'j': join.index,
    ..._common,
  };

  @override
  StrokeLayer withPaint(ScenePaint? paint) => StrokeLayer(
    width: width,
    join: join,
    paint: paint,
    blur: blur,
    dx: dx,
    dy: dy,
    opacity: opacity,
    box: box,
    blend: blend,
  );

  @override
  StrokeLayer copyWith({
    double? blur,
    double? dx,
    double? dy,
    double? opacity,
    SceneLayerBox? box,
    SceneBlendMode? blend,
    double? width,
    SceneStrokeJoin? join,
  }) => StrokeLayer(
    width: width ?? this.width,
    join: join ?? this.join,
    paint: paint,
    blur: blur ?? this.blur,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    opacity: opacity ?? this.opacity,
    box: box ?? this.box,
    blend: blend ?? this.blend,
  );

  @override
  bool operator ==(Object other) =>
      other is StrokeLayer &&
      other.width == width &&
      other.join == join &&
      other.paint == paint &&
      other.blur == blur &&
      other.dx == dx &&
      other.dy == dy &&
      other.opacity == opacity &&
      other.box == box &&
      other.blend == blend;

  @override
  int get hashCode =>
      Object.hash(width, join, paint, blur, dx, dy, opacity, box, blend);

  @override
  String toString() => 'StrokeLayer($width, $paint)';
}

/// One property a [SceneTextStyle] may set: the property table's name for
/// it, and how to read it off a style.
///
/// [SceneTextStyle.values], equality and the emitter's inherit test all walk
/// this list, so a field missing from it does not exist as far as sharing is
/// concerned — which is why `scene_props_test.dart` pins it to the table's
/// text rows in both directions. A const object cannot compute a map from
/// its own parameters, so the fields stay fields and this is what makes them
/// one organ anyway.
class SceneStyleField {
  const SceneStyleField(this.name, this.read);

  final String name;
  final Object? Function(SceneTextStyle style) read;
}

const sceneTextStyleFields = <SceneStyleField>[
  SceneStyleField('fontFamily', _sFamily),
  SceneStyleField('fontSize', _sSize),
  SceneStyleField('weight', _sWeight),
  SceneStyleField('italic', _sItalic),
  SceneStyleField('letterSpacing', _sLetterSpacing),
  SceneStyleField('wordSpacing', _sWordSpacing),
  SceneStyleField('lineHeight', _sLineHeight),
  SceneStyleField('color', _sColor),
  SceneStyleField('textCase', _sCase),
  SceneStyleField('decoration', _sDecoration),
  SceneStyleField('decorationColor', _sDecorationColor),
  SceneStyleField('decorationThickness', _sDecorationThickness),
  SceneStyleField('decorationStyle', _sDecorationStyle),
  SceneStyleField('layers', _sLayers),
  SceneStyleField('axes', _sAxes),
];

Object? _sFamily(SceneTextStyle s) => s.fontFamily;
Object? _sSize(SceneTextStyle s) => s.fontSize;
Object? _sWeight(SceneTextStyle s) => s.weight;
Object? _sItalic(SceneTextStyle s) => s.italic;
Object? _sLetterSpacing(SceneTextStyle s) => s.letterSpacing;
Object? _sWordSpacing(SceneTextStyle s) => s.wordSpacing;
Object? _sLineHeight(SceneTextStyle s) => s.lineHeight;
Object? _sColor(SceneTextStyle s) => s.color;
Object? _sCase(SceneTextStyle s) => s.textCase;
Object? _sDecoration(SceneTextStyle s) => s.decoration;
Object? _sDecorationColor(SceneTextStyle s) => s.decorationColor;
Object? _sDecorationThickness(SceneTextStyle s) => s.decorationThickness;
Object? _sDecorationStyle(SceneTextStyle s) => s.decorationStyle;
Object? _sLayers(SceneTextStyle s) => s.layers;
Object? _sAxes(SceneTextStyle s) => s.axes;

/// A text style: the text subset of the property table, as one value — what
/// a token names and a `TextNode` takes as `style:`, so a whole typographic
/// treatment is shared in one move.
///
/// Every field is nullable, because a style sets what it sets: a style that
/// says only `weight` leaves size and colour to the table's defaults. A node
/// spells ONE of these and nothing else — an override is
/// `tokens.title.copyWith(fontSize: 60)`, a delta on the style rather than a
/// property beside it. A property written equal to the
/// style's is indistinguishable from an inherited one and follows the style;
/// there is no override flag, by decision.
class SceneTextStyle {
  const SceneTextStyle({
    this.fontFamily,
    this.fontSize,
    this.weight,
    this.italic,
    this.letterSpacing,
    this.wordSpacing,
    this.lineHeight,
    this.color,
    this.textCase,
    this.decoration,
    this.decorationColor,
    this.decorationThickness,
    this.decorationStyle,
    this.layers,
    this.axes,
  });

  /// The family name as the app declares it in its pubspec, or null to take
  /// whatever the surrounding `DefaultTextStyle` gives.
  final String? fontFamily;
  final double? fontSize;
  final SceneFontWeight? weight;
  final bool? italic;

  /// Tracking, in logical pixels — negative tightens, which is what a
  /// display size almost always wants.
  final double? letterSpacing;
  final double? wordSpacing;

  /// Leading, as a multiple of the font size.
  final double? lineHeight;
  final SceneColor? color;
  final SceneTextCase? textCase;
  final SceneTextDecoration? decoration;

  /// Null means the line takes the text's own colour.
  final SceneColor? decorationColor;
  final double? decorationThickness;
  final SceneTextDecorationStyle? decorationStyle;

  /// The paint stack, back to front. Null is "this style says nothing about
  /// paint"; an EMPTY list is a style that says the text is painted once,
  /// with its own colour — which is how a style clears a stack it inherited.
  final List<TextLayer>? layers;

  /// A variable face's axes, by their four-letter tags — `wght`, `wdth`,
  /// `slnt`, and whatever else the font declares. Null is "this style says
  /// nothing about them"; an EMPTY map is a style that puts every axis back
  /// at the font's own default, which is how a style clears axes it
  /// inherited.
  final Map<String, double>? axes;

  /// A style from the table's own names — what a reader builds when it has
  /// values by name rather than by field, and the inverse of [values].
  ///
  /// Hand-written for the same reason [copyWith] is: a const object cannot
  /// build itself out of a map, so this is the constructor the table cannot
  /// derive and `scene_props_test.dart` pins instead.
  factory SceneTextStyle.fromValues(Map<String, Object?> v) => SceneTextStyle(
    fontFamily: v['fontFamily'] as String?,
    fontSize: v['fontSize'] as double?,
    weight: v['weight'] as SceneFontWeight?,
    italic: v['italic'] as bool?,
    letterSpacing: v['letterSpacing'] as double?,
    wordSpacing: v['wordSpacing'] as double?,
    lineHeight: v['lineHeight'] as double?,
    color: v['color'] as SceneColor?,
    textCase: v['textCase'] as SceneTextCase?,
    decoration: v['decoration'] as SceneTextDecoration?,
    decorationColor: v['decorationColor'] as SceneColor?,
    decorationThickness: v['decorationThickness'] as double?,
    decorationStyle: v['decorationStyle'] as SceneTextDecorationStyle?,
    layers: (v['layers'] as List?)?.cast<TextLayer>(),
    axes: (v['axes'] as Map?)?.cast<String, double>(),
  );

  /// The properties this style sets, by the table's name — what an emitter
  /// compares a node against, and what an inspector marks as inherited.
  Map<String, Object> get values => {
    for (var f in sceneTextStyleFields) f.name: ?f.read(this),
  };

  bool sets(String prop) => values.containsKey(prop);

  /// This style with [values] laid over it — the delta spelling a node uses,
  /// and the one place the file says "that treatment, but bigger". A null
  /// argument is "not given": a style cannot unset a property, because
  /// resetting to the style is what the editor does instead.
  SceneTextStyle copyWith({
    String? fontFamily,
    double? fontSize,
    SceneFontWeight? weight,
    bool? italic,
    double? letterSpacing,
    double? wordSpacing,
    double? lineHeight,
    SceneColor? color,
    SceneTextCase? textCase,
    SceneTextDecoration? decoration,
    SceneColor? decorationColor,
    double? decorationThickness,
    SceneTextDecorationStyle? decorationStyle,
    List<TextLayer>? layers,
    Map<String, double>? axes,
  }) => SceneTextStyle(
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    weight: weight ?? this.weight,
    italic: italic ?? this.italic,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    wordSpacing: wordSpacing ?? this.wordSpacing,
    lineHeight: lineHeight ?? this.lineHeight,
    color: color ?? this.color,
    textCase: textCase ?? this.textCase,
    decoration: decoration ?? this.decoration,
    decorationColor: decorationColor ?? this.decorationColor,
    decorationThickness: decorationThickness ?? this.decorationThickness,
    decorationStyle: decorationStyle ?? this.decorationStyle,
    layers: layers ?? this.layers,
    axes: axes ?? this.axes,
  );

  @override
  bool operator ==(Object other) =>
      other is SceneTextStyle &&
      sceneTextStyleFields.every(
        // One field is a list, and a list is not `==` another with the same
        // contents — so the comparison is by contents wherever it finds one.
        (f) => switch ((f.read(this), f.read(other))) {
          (List a, List b) => _sameList(a, b),
          (Map a, Map b) => _sameMap(a, b),
          var pair => pair.$1 == pair.$2,
        },
      );

  @override
  int get hashCode => Object.hashAll([
    for (var f in sceneTextStyleFields)
      if (f.read(this) case var v)
        switch (v) {
          List l => Object.hashAll(l),
          Map m => Object.hashAll([
            for (var e in m.entries) Object.hash(e.key, e.value),
          ]),
          _ => v,
        },
  ]);

  @override
  String toString() =>
      'SceneTextStyle(${values.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
}

/// One stretch of a paragraph, and what it differs by.
///
/// A text is a LIST of these, and the list is the paragraph: it is laid out
/// and wrapped as one, which is the whole reason a bold word cannot be a
/// second node beside the first. [style] is a DELTA over the node's own —
/// only what this run changes — and the same [SceneTextStyle] type says it,
/// because "unset means take what is underneath" is already what a style's
/// nulls mean.
///
/// A run carries no [SceneTextStyle.layers]: the paint stack paints a whole
/// laid-out paragraph once per pass, and a stack that applied to a stretch
/// of one would have to lay that stretch out alone — which is the law a
/// stack exists under (a pass may change paint, never layout). The grammar
/// refuses it rather than dropping it.
///
/// Anonymous, like a paint pass and for the same reason: a run named as a
/// field of one scene is a run no other scene can have, and a style that
/// carries its runs can be shared whole.
class TextRun {
  const TextRun(this.text, {this.style});

  final String text;

  /// What this run changes about the node's style — null where it changes
  /// nothing, which is the ordinary run.
  final SceneTextStyle? style;

  TextRun copyWith({String? text, SceneTextStyle? style}) =>
      TextRun(text ?? this.text, style: style ?? this.style);

  @override
  bool operator ==(Object other) =>
      other is TextRun && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'TextRun(${_quoted(text)}${style == null ? '' : ', …'})';
}

String _quoted(String s) => s.length > 24 ? "'${s.substring(0, 23)}…'" : "'$s'";

/// Four numbers that are one when they agree: edges, corners. What the
/// property table needs to spell either as one number or four named parts.
abstract interface class SceneQuad {
  /// The four parts, in the order the file names them.
  List<double> get sides;
  bool get isUniform;
  bool get isZero;
  SceneQuad withSide(int index, double value);

  /// The one number when they agree, the four otherwise.
  Object toWire();
}

/// Space inside a frame, per side.
///
/// One value where there used to be a number, because the number could only
/// ever be uniform and the renderer was quietly making the vertical inset
/// six tenths of the horizontal one — a guess that looked deliberate and was
/// not. A cell in a table wants a different top from its left.
class SceneEdges implements SceneQuad {
  const SceneEdges({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  const SceneEdges.all(double value)
    : left = value,
      top = value,
      right = value,
      bottom = value;

  static const zero = SceneEdges();

  final double left;
  final double top;
  final double right;
  final double bottom;

  @override
  bool get isZero => left == 0 && top == 0 && right == 0 && bottom == 0;

  /// Whether one number says all of it — what the file and the inspector
  /// offer first, because it is what most frames want.
  @override
  bool get isUniform => left == top && top == right && right == bottom;

  @override
  List<double> get sides => [left, top, right, bottom];

  @override
  SceneEdges withSide(int index, double value) => switch (index) {
    0 => copyWith(left: value),
    1 => copyWith(top: value),
    2 => copyWith(right: value),
    _ => copyWith(bottom: value),
  };

  SceneEdges copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) => SceneEdges(
    left: left ?? this.left,
    top: top ?? this.top,
    right: right ?? this.right,
    bottom: bottom ?? this.bottom,
  );

  /// `[l, t, r, b]`, or the one number when they agree.
  @override
  Object toWire() => isUniform ? left : [left, top, right, bottom];

  /// Reads [toWire], and the plain number older payloads carried. A list
  /// with a non-number element falls back to [zero] — the whole value, the
  /// same rule [SceneAlignment.fromWire] uses.
  static SceneEdges fromWire(Object? value) => switch (value) {
    num n => SceneEdges.all(n.toDouble()),
    List l when l.length == 4 && l.every((e) => e is num) => SceneEdges(
      left: (l[0] as num).toDouble(),
      top: (l[1] as num).toDouble(),
      right: (l[2] as num).toDouble(),
      bottom: (l[3] as num).toDouble(),
    ),
    _ => zero,
  };

  @override
  bool operator ==(Object other) =>
      other is SceneEdges &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'SceneEdges($left, $top, $right, $bottom)';
}

/// A node's corner radii, one per corner, clockwise from the top left.
///
/// `corner: 16` is still what most nodes want and still what the file
/// spells for them; a tab that is square along its bottom names its
/// corners, the way a padding names its sides.
class SceneCorners implements SceneQuad {
  const SceneCorners({
    this.topLeft = 0,
    this.topRight = 0,
    this.bottomRight = 0,
    this.bottomLeft = 0,
  });

  const SceneCorners.all(double value)
    : topLeft = value,
      topRight = value,
      bottomRight = value,
      bottomLeft = value;

  static const zero = SceneCorners();

  final double topLeft;
  final double topRight;
  final double bottomRight;
  final double bottomLeft;

  @override
  bool get isZero =>
      topLeft == 0 && topRight == 0 && bottomRight == 0 && bottomLeft == 0;

  @override
  bool get isUniform =>
      topLeft == topRight &&
      topRight == bottomRight &&
      bottomRight == bottomLeft;

  @override
  List<double> get sides => [topLeft, topRight, bottomRight, bottomLeft];

  SceneCorners copyWith({
    double? topLeft,
    double? topRight,
    double? bottomRight,
    double? bottomLeft,
  }) => SceneCorners(
    topLeft: topLeft ?? this.topLeft,
    topRight: topRight ?? this.topRight,
    bottomRight: bottomRight ?? this.bottomRight,
    bottomLeft: bottomLeft ?? this.bottomLeft,
  );

  @override
  SceneCorners withSide(int index, double value) => switch (index) {
    0 => copyWith(topLeft: value),
    1 => copyWith(topRight: value),
    2 => copyWith(bottomRight: value),
    _ => copyWith(bottomLeft: value),
  };

  @override
  Object toWire() =>
      isUniform ? topLeft : [topLeft, topRight, bottomRight, bottomLeft];

  // A list with a non-number element falls back to zero — same rule as
  // SceneEdges.fromWire.
  static SceneCorners fromWire(Object? value) => switch (value) {
    num n => SceneCorners.all(n.toDouble()),
    List l when l.length == 4 && l.every((e) => e is num) => SceneCorners(
      topLeft: (l[0] as num).toDouble(),
      topRight: (l[1] as num).toDouble(),
      bottomRight: (l[2] as num).toDouble(),
      bottomLeft: (l[3] as num).toDouble(),
    ),
    _ => zero,
  };

  @override
  bool operator ==(Object other) =>
      other is SceneCorners &&
      other.topLeft == topLeft &&
      other.topRight == topRight &&
      other.bottomRight == bottomRight &&
      other.bottomLeft == bottomLeft;

  @override
  int get hashCode => Object.hash(topLeft, topRight, bottomRight, bottomLeft);

  @override
  String toString() =>
      'SceneCorners($topLeft, $topRight, $bottomRight, $bottomLeft)';
}

/// A size on its way out to the wire or a file.
///
/// Fill is [double.infinity] in the model, and `jsonEncode` refuses a
/// non-finite double, so it travels as a word. Hug is still null and a fixed
/// size is still its number.
Object? sizeToWire(double? size) =>
    size != null && size.isInfinite ? 'fill' : size;

/// The inverse of [sizeToWire].
double? sizeFromWire(Object? value) => switch (value) {
  'fill' => double.infinity,
  num n => n.toDouble(),
  _ => null,
};

/// Same contract as [SceneCrossAxisAlignment], for the main axis.
enum SceneMainAxisAlignment {
  start,
  end,
  center,
  spaceBetween,
  spaceAround,
  spaceEvenly,
}

/// A laid-out rectangle in artboard coordinates — what the renderer measured,
/// never something a file spells.
class SceneRect {
  const SceneRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  bool contains(double x, double y) =>
      x >= left && x < right && y >= top && y < bottom;

  bool overlaps(SceneRect other) =>
      other.left < right &&
      other.right > left &&
      other.top < bottom &&
      other.bottom > top;

  @override
  bool operator ==(Object other) =>
      other is SceneRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'SceneRect($left, $top, $width, $height)';
}
