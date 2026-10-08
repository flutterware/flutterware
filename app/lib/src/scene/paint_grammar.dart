// How a style's structured values — a paint stack, a face's axes — are
// spelled in a file and read back out of one.
//
// Its own organ because TWO grammars carry them: a scene file spells a text's
// own, and a token library spells what a shared style declares. One copy each
// is two dialects a month later.
//
// The vocabulary is the model's own class names, like the rest of the
// grammar — `StrokeLayer(width: 14, paint: SolidPaint(SceneColor(0xFF…)))` —
// because a spelling that differs from the type is a spelling the compiler
// cannot check. Every default is omitted, so the common layer is short.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutterware/scene_authoring.dart';

/// What a refusal needs: where it is, what was found, and what to do instead.
typedef Refuse = void Function(int offset, String construct, String message);

/// `[StrokeLayer(width: 14), FillLayer(paint: …)]`, back to front.
String emitSceneLayers(List<TextLayer> layers) =>
    '[${layers.map(_layer).join(', ')}]';

String _layer(TextLayer l) {
  var args = <String>[];
  if (l case StrokeLayer(:var width, :var join)) {
    args.add('width: ${_num(width)}');
    if (join != SceneStrokeJoin.round) {
      args.add('join: SceneStrokeJoin.${join.name}');
    }
  }
  if (l.paint case var p?) args.add('paint: ${_paint(p)}');
  if (l.blur != 0) args.add('blur: ${_num(l.blur)}');
  if (l.dx != 0) args.add('dx: ${_num(l.dx)}');
  if (l.dy != 0) args.add('dy: ${_num(l.dy)}');
  if (l.opacity != 1) args.add('opacity: ${_num(l.opacity)}');
  if (l.box != SceneLayerBox.text) {
    args.add('box: SceneLayerBox.${l.box.name}');
  }
  if (l.blend != SceneBlendMode.normal) {
    args.add('blend: SceneBlendMode.${l.blend.name}');
  }
  return '${l is StrokeLayer ? 'StrokeLayer' : 'FillLayer'}(${args.join(', ')})';
}

String _paint(ScenePaint p) => switch (p) {
  SolidPaint(:var color) => 'SolidPaint(${_color(color)})',
  LinearPaint(:var colors, :var stops, :var begin, :var end) => [
    'LinearPaint(colors: [${colors.map(_color).join(', ')}]',
    if (stops != null) ', stops: [${stops.map(_num).join(', ')}]',
    if (begin != SceneAlignment.topCenter) ', begin: ${_alignment(begin)}',
    if (end != SceneAlignment.bottomCenter) ', end: ${_alignment(end)}',
    ')',
  ].join(),
  RadialPaint(:var colors, :var stops, :var center, :var radius) => [
    'RadialPaint(colors: [${colors.map(_color).join(', ')}]',
    if (stops != null) ', stops: [${stops.map(_num).join(', ')}]',
    if (center != SceneAlignment.center) ', center: ${_alignment(center)}',
    if (radius != 1) ', radius: ${_num(radius)}',
    ')',
  ].join(),
  SweepPaint(
    :var colors,
    :var stops,
    :var center,
    :var startAngle,
    :var endAngle,
  ) =>
    [
      'SweepPaint(colors: [${colors.map(_color).join(', ')}]',
      if (stops != null) ', stops: [${stops.map(_num).join(', ')}]',
      if (center != SceneAlignment.center) ', center: ${_alignment(center)}',
      if (startAngle != 0) ', startAngle: ${_num(startAngle)}',
      if (endAngle != 360) ', endAngle: ${_num(endAngle)}',
      ')',
    ].join(),
  ShaderPaint(:var asset, :var uniforms) => [
    'ShaderPaint(${_string(asset)}',
    if (uniforms.isNotEmpty)
      ', uniforms: {${[for (var e in uniforms.entries) '${_string(e.key)}: [${e.value.map(_num).join(', ')}]'].join(', ')}}',
    ')',
  ].join(),
};

String _string(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

const _namedAlignments = {
  'topLeft': SceneAlignment.topLeft,
  'topCenter': SceneAlignment.topCenter,
  'topRight': SceneAlignment.topRight,
  'centerLeft': SceneAlignment.centerLeft,
  'center': SceneAlignment.center,
  'centerRight': SceneAlignment.centerRight,
  'bottomLeft': SceneAlignment.bottomLeft,
  'bottomCenter': SceneAlignment.bottomCenter,
  'bottomRight': SceneAlignment.bottomRight,
};

String _alignment(SceneAlignment a) {
  for (var e in _namedAlignments.entries) {
    if (e.value == a) return 'SceneAlignment.${e.key}';
  }
  return 'SceneAlignment(${_num(a.x)}, ${_num(a.y)})';
}

String _color(SceneColor c) =>
    'SceneColor(0x${c.argb.toRadixString(16).toUpperCase().padLeft(8, '0')})';

String _num(double v) =>
    v == v.roundToDouble() && v.abs() < 1e15 ? '${v.round()}' : '$v';

// ── reading ────────────────────────────────────────────────────────────────

/// The paint stack out of a `[…]` literal, or null when [e] is not one.
/// Refuses per element, so one bad layer does not lose the rest.
List<TextLayer>? readSceneLayers(Expression e, Refuse refuse) {
  if (e is! ListLiteral) {
    refuse(
      e.offset,
      'layers',
      'a paint stack is a list, back to front: '
          'layers: [StrokeLayer(width: 14), FillLayer()]',
    );
    return null;
  }
  var out = <TextLayer>[];
  for (var element in e.elements) {
    if (element is! Expression) {
      refuse(element.offset, 'layers', 'a stack lists its passes one by one');
      continue;
    }
    var layer = _readLayer(element, refuse);
    if (layer != null) out.add(layer);
  }
  return out;
}

TextLayer? _readLayer(Expression e, Refuse refuse) {
  var read = _call(e);
  if (read == null || (read.$1 != 'FillLayer' && read.$1 != 'StrokeLayer')) {
    refuse(
      e.offset,
      'layers',
      'a pass is FillLayer(…) or StrokeLayer(width: …): nothing else is '
          'on the allowlist',
    );
    return null;
  }
  var (name, args) = read;
  var named = _named(args, 'a pass', refuse);
  if (named == null) return null;

  ScenePaint? paint;
  if (named.remove('paint') case var p?) {
    paint = _readPaint(p, refuse);
    if (paint == null) return null;
  }
  var blur = _take(named, 'blur', refuse) ?? 0;
  var dx = _take(named, 'dx', refuse) ?? 0;
  var dy = _take(named, 'dy', refuse) ?? 0;
  var opacity = _take(named, 'opacity', refuse) ?? 1;
  var box = SceneLayerBox.text;
  if (named.remove('box') case var b?) {
    var read = _enumMember(
      b,
      'SceneLayerBox',
      SceneLayerBox.values.map((v) => v.name),
    );
    if (read == null) {
      refuse(
        b.offset,
        'layers',
        'a box is SceneLayerBox.text or SceneLayerBox.line',
      );
      return null;
    }
    box = SceneLayerBox.values.byName(read);
  }
  var blend = SceneBlendMode.normal;
  if (named.remove('blend') case var m?) {
    var read = _enumMember(
      m,
      'SceneBlendMode',
      SceneBlendMode.values.map((v) => v.name),
    );
    if (read == null) {
      refuse(
        m.offset,
        'layers',
        'a blend is SceneBlendMode.multiply, .screen, .overlay or another '
            'of the sixteen SceneBlendMode names',
      );
      return null;
    }
    blend = SceneBlendMode.values.byName(read);
  }

  if (name == 'FillLayer') {
    if (!_rest(named, 'FillLayer', refuse)) return null;
    return FillLayer(
      paint: paint,
      blur: blur,
      dx: dx,
      dy: dy,
      opacity: opacity,
      box: box,
      blend: blend,
    );
  }
  var width = _take(named, 'width', refuse) ?? 1;
  var join = SceneStrokeJoin.round;
  if (named.remove('join') case var j?) {
    var read = _enumMember(
      j,
      'SceneStrokeJoin',
      SceneStrokeJoin.values.map((v) => v.name),
    );
    if (read == null) {
      refuse(
        j.offset,
        'layers',
        'a join is SceneStrokeJoin.miter, .round or .bevel',
      );
      return null;
    }
    join = SceneStrokeJoin.values.firstWhere((v) => v.name == read);
  }
  if (!_rest(named, 'StrokeLayer', refuse)) return null;
  return StrokeLayer(
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
}

ScenePaint? _readPaint(Expression e, Refuse refuse) {
  var read = _call(e);
  switch (read) {
    case ('SolidPaint', var args) when args.arguments.length == 1:
      var color = _readColor(args.arguments.single.argumentExpression, refuse);
      return color == null ? null : SolidPaint(color);
    case ('LinearPaint', var args):
      var named = _named(args, 'a gradient', refuse);
      if (named == null) return null;
      var read = _readStops(e, named, 'LinearPaint', refuse);
      if (read == null) return null;
      var begin = _readAlignment(named.remove('begin'), refuse);
      var end = _readAlignment(named.remove('end'), refuse);
      if (!_rest(named, 'LinearPaint', refuse)) return null;
      return LinearPaint(
        colors: read.colors,
        stops: read.stops,
        begin: begin ?? SceneAlignment.topCenter,
        end: end ?? SceneAlignment.bottomCenter,
      );
    case ('RadialPaint', var args):
      var named = _named(args, 'a gradient', refuse);
      if (named == null) return null;
      var read = _readStops(e, named, 'RadialPaint', refuse);
      if (read == null) return null;
      var center = _readAlignment(named.remove('center'), refuse);
      var radius = _take(named, 'radius', refuse);
      if (!_rest(named, 'RadialPaint', refuse)) return null;
      return RadialPaint(
        colors: read.colors,
        stops: read.stops,
        center: center ?? SceneAlignment.center,
        radius: radius ?? 1,
      );
    case ('SweepPaint', var args):
      var named = _named(args, 'a gradient', refuse);
      if (named == null) return null;
      var read = _readStops(e, named, 'SweepPaint', refuse);
      if (read == null) return null;
      var center = _readAlignment(named.remove('center'), refuse);
      var start = _take(named, 'startAngle', refuse);
      var end = _take(named, 'endAngle', refuse);
      if (!_rest(named, 'SweepPaint', refuse)) return null;
      return SweepPaint(
        colors: read.colors,
        stops: read.stops,
        center: center ?? SceneAlignment.center,
        startAngle: start ?? 0,
        endAngle: end ?? 360,
      );
    case ('ShaderPaint', var args):
      return _readShader(e, args, refuse);
    default:
      refuse(
        e.offset,
        'paint',
        'a paint is SolidPaint(SceneColor(0x…)); LinearPaint, RadialPaint or '
            "SweepPaint(colors: […]); or ShaderPaint('shaders/….frag'). "
            'Nothing else is on the allowlist',
      );
      return null;
  }
}

ScenePaint? _readShader(Expression at, ArgumentList args, Refuse refuse) {
  var positional = [
    for (var a in args.arguments)
      if (a is! NamedArgument) a,
  ];
  if (positional.length != 1 || positional.single is! SimpleStringLiteral) {
    refuse(
      at.offset,
      'paint',
      'a shader paint names its asset first, as the pubspec declares it: '
          "ShaderPaint('shaders/foil.frag')",
    );
    return null;
  }
  var asset = (positional.single as SimpleStringLiteral).value;
  var named = <String, Expression>{
    for (var a in args.arguments)
      if (a is NamedArgument) a.name.lexeme: a.argumentExpression,
  };
  var uniforms = const <String, List<double>>{};
  if (named.remove('uniforms') case var u?) {
    var read = _readUniforms(u, refuse);
    if (read == null) return null;
    uniforms = read;
  }
  if (!_rest(named, 'ShaderPaint', refuse)) return null;
  return ShaderPaint(asset, uniforms: uniforms);
}

Map<String, List<double>>? _readUniforms(Expression e, Refuse refuse) {
  if (e is! SetOrMapLiteral) {
    refuse(
      e.offset,
      'uniforms',
      "a map of uniform names to values: {'uAngle': [0.4], 'uTint': [1, 0.8, 0.2]}",
    );
    return null;
  }
  var out = <String, List<double>>{};
  for (var entry in e.elements) {
    if (entry is! MapLiteralEntry || entry.key is! SimpleStringLiteral) {
      refuse(
        entry.offset,
        'uniforms',
        "a uniform's name in quotes, like 'uAngle'",
      );
      return null;
    }
    var name = (entry.key as SimpleStringLiteral).value;
    var value = _uniformValue(entry.value);
    if (value == null) {
      refuse(
        entry.value.offset,
        "uniform '$name'",
        'a list of one to four numbers, one per component: [0.4] for a '
            'float, [1, 0.8, 0.2] for a vec3',
      );
      return null;
    }
    out[name] = value;
  }
  return out;
}

// Every value is a list, a float's too: the file is Dart, and a uniform is a
// List<double> there — a bare number would not compile.
List<double>? _uniformValue(Expression e) {
  if (e is! ListLiteral || e.elements.isEmpty || e.elements.length > 4) {
    return null;
  }
  var out = <double>[];
  for (var x in e.elements) {
    if (x is! Expression) return null;
    var v = _number(x);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

/// A gradient's colours and where they sit, taken out of [named].
///
/// Shared by the gradients, and where the engine's rules are refused in
/// words instead of thrown mid-paint: two colours at least — one colour is a
/// SolidPaint — and, when positions are given, one per colour.
({List<SceneColor> colors, List<double>? stops})? _readStops(
  Expression at,
  Map<String, Expression> named,
  String kind,
  Refuse refuse,
) {
  var colorList = named.remove('colors');
  if (colorList is! ListLiteral) {
    refuse(
      at.offset,
      'paint',
      'a gradient names its colours: '
          '$kind(colors: [SceneColor(0x…), SceneColor(0x…)])',
    );
    return null;
  }
  var colors = <SceneColor>[];
  for (var c in colorList.elements) {
    if (c is! Expression) {
      refuse(
        c.offset,
        'paint',
        'a gradient lists its colours one by one as SceneColor(0x…) '
            'literals',
      );
      return null;
    }
    var color = _readColor(c, refuse);
    if (color == null) return null;
    colors.add(color);
  }
  if (colors.length < 2) {
    refuse(
      colorList.offset,
      'paint',
      'a gradient has two colours at least: one colour is '
          'SolidPaint(SceneColor(0x…))',
    );
    return null;
  }
  List<double>? stops;
  if (named.remove('stops') case var s?) {
    var read = s is ListLiteral
        ? [
            for (var e in s.elements)
              if (e is Expression) _number(e),
          ]
        : null;
    if (read == null || read.length != colors.length || read.contains(null)) {
      refuse(
        s.offset,
        'paint',
        'a gradient has one stop per colour, or no stops, which spreads '
            'the colours evenly',
      );
      return null;
    }
    stops = [for (var v in read) v!];
  }
  return (colors: colors, stops: stops);
}

SceneAlignment? _readAlignment(Expression? e, Refuse refuse) {
  if (e == null) return null;
  if (_enumMember(e, 'SceneAlignment', _namedAlignments.keys) case var name?) {
    return _namedAlignments[name];
  }
  if (_call(e) case ('SceneAlignment', var args)
      when args.arguments.length == 2) {
    var x = _number(args.arguments[0].argumentExpression);
    var y = _number(args.arguments[1].argumentExpression);
    if (x != null && y != null) return SceneAlignment(x, y);
  }
  refuse(
    e.offset,
    'paint',
    'a point in the box is SceneAlignment.center or SceneAlignment(0, -1)',
  );
  return null;
}

/// A colour inside a stack is a LITERAL, and this says why when somebody
/// tries otherwise: a binding is keyed by property NAME, and a pass has no
/// name — it is an anonymous element of a list, by decision. So a parameter
/// cannot reach into a stack. What a stack does share is the style token that
/// carries the whole of it.
SceneColor? _readColor(Expression e, Refuse refuse) {
  if (_call(e) case ('SceneColor', var args) when args.arguments.length == 1) {
    var v = args.arguments.single;
    if (v is IntegerLiteral && v.value != null) return SceneColor(v.value!);
  }
  refuse(
    e.offset,
    'paint',
    e is Identifier
        ? 'a pass has no name for "$e" to bind to, so its colour is a '
              'literal: SceneColor(0xAARRGGBB). Share the whole stack as a '
              "style token, or leave the pass no paint and bind the text's "
              'own colour, which is what it then takes.'
        : 'expected a color, spelled SceneColor(0xAARRGGBB)',
  );
  return null;
}

/// A constructor call, `const` or not, as a name and its arguments.
(String, ArgumentList)? _call(Expression e) => switch (e) {
  InstanceCreationExpression(:var constructorName, :var argumentList) => (
    constructorName.type.name.lexeme,
    argumentList,
  ),
  MethodInvocation(:var methodName, target: null, :var argumentList) => (
    methodName.name,
    argumentList,
  ),
  _ => null,
};

String? _enumMember(Expression e, String prefix, Iterable<String> names) =>
    e is PrefixedIdentifier &&
        e.prefix.name == prefix &&
        names.contains(e.identifier.name)
    ? e.identifier.name
    : null;

Map<String, Expression>? _named(ArgumentList args, String what, Refuse refuse) {
  var named = <String, Expression>{};
  for (var arg in args.arguments) {
    if (arg is NamedArgument) {
      named[arg.name.lexeme] = arg.argumentExpression;
    } else {
      refuse(arg.offset, 'layers', '$what names each of its values');
      return null;
    }
  }
  return named;
}

double? _take(Map<String, Expression> named, String key, Refuse refuse) {
  var e = named.remove(key);
  if (e == null) return null;
  var v = _number(e);
  if (v == null) refuse(e.offset, 'layers', '$key is a number');
  return v;
}

double? _number(Expression e) => switch (e) {
  IntegerLiteral(:var value?) => value.toDouble(),
  DoubleLiteral(:var value) => value,
  PrefixExpression(operator: var op, operand: var inner)
      when op.lexeme == '-' =>
    switch (_number(inner)) {
      var v? => -v,
      null => null,
    },
  _ => null,
};

bool _rest(Map<String, Expression> named, String what, Refuse refuse) {
  for (var e in named.entries) {
    refuse(e.value.offset, 'layers', '$what has no "${e.key}"');
  }
  return named.isEmpty;
}

/// `{'wght': 700, 'wdth': 85}` — a variable face's axes.
String emitSceneAxes(Map<String, double> axes) =>
    '{${[for (var e in axes.entries) "'${e.key}': ${_num(e.value)}"].join(', ')}}';

/// The inverse, refused rather than half-read.
///
/// A tag the font does not have and a tag that is not four letters both draw
/// nothing and say nothing, and a map literal is where a typo hides best.
Map<String, double>? readSceneAxes(Expression e, Refuse refuse) {
  if (e is! SetOrMapLiteral) {
    refuse(e.offset, 'axes', "a map of tags to numbers, like {'wght': 700}");
    return null;
  }
  var out = <String, double>{};
  for (var entry in e.elements) {
    if (entry is! MapLiteralEntry) {
      refuse(entry.offset, 'axes', 'a tag and a number');
      return null;
    }
    if (_axisTag(entry.key) case var tag?) {
      if (_axisValue(entry.value) case var v?) {
        out[tag] = v;
        continue;
      }
      refuse(entry.value.offset, "axis '$tag'", 'a number');
      return null;
    }
    refuse(
      entry.key.offset,
      'axis tag',
      "a four-letter tag in quotes, like 'wght'",
    );
    return null;
  }
  return out;
}

String? _axisTag(Expression e) => switch (e) {
  SimpleStringLiteral(:var value) when value.length == 4 => value,
  _ => null,
};

double? _axisValue(Expression e) => switch (e) {
  IntegerLiteral(:var value?) => value.toDouble(),
  DoubleLiteral(:var value) => value,
  PrefixExpression(:var operator, :var operand) when operator.lexeme == '-' =>
    switch (_axisValue(operand)) {
      var v? => -v,
      null => null,
    },
  _ => null,
};
