// Disposable spike: the motion class grammar, its parser and its emitter —
// the scene grammar's discipline applied to the motion rewrite.
//
// THE GRAMMAR, on a page. A motion is a class in the SCENE file, beside
// the scene it animates (grammar 0.5 folded the two files into one, so
// there is no marker and no file of its own here — scene_file.dart is the
// door). A motion class is:
//       class <Name>(super.scene, {final double p = 24, …})
//           extends SceneMotion<SceneClass> { … }
//     — the primary constructor's first formal is `super.scene`; each other
//     formal is a motion parameter (`final <double|String|Color> <name> =
//     <literal>`, exactly the scene's parameter spelling); the extends
//     clause names the scene this motion animates
//   - group fields: `late final <name> = scene.<node>.animate(…)` — THE
//     FIELD NAME IS THE GROUP'S IDENTITY, the target is the scene node's
//     own field name (typed in real Dart, resolved against the scene here),
//     and the named arguments are that node kind's animatable properties,
//     each a `MotionTrack([MotionKey(…), …])`; an external node takes
//     `args: {'<arg>': Track(…)}` — the grammar's one stringly boundary
//   - a Key is `Key(at: <int>.ms, value: <literal or parameter name>,
//     curve: SceneCurves.<allowlisted>)` — keys time-sorted, times unique,
//     tracks non-empty (Save writes no empty tracks)
//   - a mandatory `@override late final timeline = <arrangement>` — ParExpr
//     and SeqExpr lists,
//     At(<int>.ms, …), Speed(<number>, …), Repeat(<int>, …) over group
//     names; a group placed at most once; an UNPLACED group is a library
//     asset (independently playable, no autoplay), not an orphan
//   - a derived `copy` member the tool maintains:
//       <Name> copy(<SceneClass> scene) =>
//           copyStateInto(<Name>(scene, p: p, …));
//     a missing or stale copy is tolerated and converged on the next emit;
//     any other shape is refused
//   - nothing else — same refusal policy as the scene: collected,
//     all-or-nothing, with a line number, never silently dropped.
//
// Invariants the tests hold: parse(emit(model)) succeeds and re-emits
// identically; emit ∘ parse is the identity on canonical files; accepted
// non-canonical spellings (`final` for `late final`, `SceneCurves.linear`,
// a missing or stale `copy`, a type-less parameter formal) converge in one
// emit; every hostile construct is refused with an offset and a name.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:flutterware/scene_authoring.dart' hide Token;

import 'scene_file.dart' show SceneRefusal;

/// The curves a key may name — canonical spelling `SceneCurves.<name>`; `linear`
/// is accepted and converges to no curve at all.
const motionCurves = [
  'linear',
  'ease',
  'easeIn',
  'easeOut',
  'easeInOut',
  'easeInBack',
  'easeOutBack',
  'easeInCubic',
  'easeOutCubic',
  'decelerate',
  'fastOutSlowIn',
  'bounceOut',
  'elasticOut',
];

class MotionParse {
  MotionParse(this.doc, this.className, this.refusals);

  final MotionDocument? doc;
  final String? className;
  final List<SceneRefusal> refusals;

  bool get ok => doc != null;
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

/// Write one motion class into the scene file being emitted — a motion is
/// half a pair and has no file of its own (grammar 0.5).
void emitMotionClass(
  StringBuffer out,
  MotionDocument doc,
  SceneDocument scene, {
  required String className,
}) {
  var seen = <String>{...motionReservedNames};
  var params = <String, SceneParamDecl>{};
  for (var p in doc.params) {
    if (!isValidNodeName(p.name) || !seen.add(p.name)) {
      throw ArgumentError('"${p.name}" is not a usable parameter name');
    }
    params[p.name] = p;
  }
  out.write('class $className(super.scene');
  if (doc.params.isNotEmpty) {
    out.write(', {');
    for (var p in doc.params) {
      out.write('final ${p.typeName} ${p.name} = ${_paramDefault(p)}, ');
    }
    out.write('}');
  }
  out.writeln(') extends SceneMotion<${doc.sceneClassName}> {');
  for (var g in doc.groups) {
    if (!isValidNodeName(g.name) || !seen.add(g.name)) {
      throw ArgumentError(
        '"${g.name}" is not a usable group name. Names are field names: '
        'valid identifiers, unique in the class, off the reserved list',
      );
    }
    var target = g.node;
    if (scene.nodeNamed(target.name) != target) {
      throw ArgumentError('"${target.name}" is not a node in this scene');
    }
    out.write('  late final ${g.name} = scene.${target.name}.animate(');
    for (var ScenePropSpec(name: prop, :kind) in animatableProps(target)) {
      var track = g.tracks[prop];
      if (track == null) continue;
      out.write('$prop: ${_track(track, kind, params)}, ');
    }
    // The two kinds of track a named argument cannot spell, each in a map
    // of its own: an argument's name comes from the widget's declaration, an
    // axis's tag from the font, and neither is an identifier this file may
    // invent.
    var args = _partsOf(g, sceneArgsPrefix);
    if (args.isNotEmpty) {
      // The generated tracks class of whatever this animates: one slot per
      // animatable argument, so the name is checked by the compiler as
      // well as here.
      out.write('args: ${_entryOf(target)}Tracks(');
      for (var key in args.keys.toList()..sort()) {
        if (!isValidNodeName(key)) {
          throw ArgumentError('"$key" is not an argument name');
        }
        out.write('$key: ${_track(args[key]!, TrackKind.number, params)}, ');
      }
      out.write('), ');
    }
    var axes = _partsOf(g, sceneAxesPrefix);
    if (axes.isNotEmpty) {
      out.write('axes: {');
      for (var tag in axes.keys.toList()..sort()) {
        if (tag.length != 4) {
          throw ArgumentError('"$tag" is not a four-letter axis tag');
        }
        out.write("'$tag': ${_track(axes[tag]!, TrackKind.number, params)}, ");
      }
      out.write('}, ');
    }
    out.writeln(');');
  }
  // SceneMotion declares `timeline`, so the field that supplies it is an
  // override like the scene's `root`.
  out.writeln('  @override');
  out.writeln('  late final timeline = ${_expr(doc.timeline)};');
  out.write('  $className copy(${doc.sceneClassName} scene) => ');
  out.write('copyStateInto($className(scene');
  for (var p in doc.params) {
    out.write(', ${p.name}: ${p.name}');
  }
  out.writeln('));');
  out.writeln('}');
}

String _track(MotionTrack t, TrackKind kind, Map<String, SceneParamDecl> ps) {
  if (t.clips.isNotEmpty) {
    if (kind != TrackKind.number) {
      throw ArgumentError('a clip block stands on a number track');
    }
    List<String> parts(MotionClip c) => [
      if (c.clip.isNotEmpty) 'clip: ${_str(c.clip)}',
      'at: ${_dur(c.at)}',
      'length: ${_dur(c.length)}',
      if (c.speed != 1) 'speed: ${_num(c.speed)}',
      if (c.offset != Duration.zero) 'offset: ${_dur(c.offset)}',
      if (c.reverse) 'reverse: true',
    ];
    if (t.clips.length == 1) {
      return 'ClipTrack(${parts(t.clips.single).join(', ')})';
    }
    var blocks = t.clips.map((c) => 'ClipBlock(${parts(c).join(', ')})');
    return 'ClipBlocks([${blocks.join(', ')}])';
  }
  if (t.keys.isEmpty) {
    throw ArgumentError(
      'a track with no keys is not written: Save writes non-empty tracks '
      'only; remove the property instead',
    );
  }
  if (t.kind != kind) {
    throw ArgumentError('this property takes a ${kind.name} track');
  }
  var keys = t.keys.map((k) {
    var parts = ['at: ${_dur(k.at)}'];

    // A key that reads a parameter is spelled as the reference, always —
    // the edit reached the default before this ran
    // ([reconcileMotionBindings]). A reference to nothing declared is the
    // one case written as a literal, and reconcile removes those too.
    var p = k.paramRef == null ? null : ps[k.paramRef];
    if (p != null) {
      parts.add('value: ${k.paramRef}');
    } else {
      parts.add(
        'value: ${kind == TrackKind.color ? _color(k.value as SceneColor) : _num((k.value as num).toDouble())}',
      );
    }
    if (k.curve case var curve? when curve.name != 'linear') {
      if (!motionCurves.contains(curve.name)) {
        throw ArgumentError('"${curve.name}" is not an allowlisted curve');
      }
      parts.add('curve: SceneCurves.${curve.name}');
    }
    return 'MotionKey(${parts.join(', ')})';
  });
  return 'MotionTrack([${keys.join(', ')}])';
}

String _expr(TimelineExpr e) => switch (e) {
  // A placed group is written as the FIELD it is declared under, which is
  // what makes the arrangement a set of typed references.
  AnimateGroup g => g.name,
  ParExpr p => 'ParExpr([${p.children.map(_expr).join(', ')}])',
  SeqExpr s => 'SeqExpr([${s.children.map(_expr).join(', ')}])',
  AtExpr a => 'AtExpr(${_dur(a.offset)}, ${_expr(a.child)})',
  SpeedExpr s => 'SpeedExpr(${_num(s.factor)}, ${_expr(s.child)})',
  RepeatExpr r => 'RepeatExpr(${r.times}, ${_expr(r.child)})',
};

String _dur(Duration d) {
  if (d.isNegative || d.inMicroseconds % 1000 != 0) {
    throw ArgumentError(
      'a motion time is a whole, non-negative millisecond '
      'count, got $d',
    );
  }
  return '${d.inMilliseconds}.ms';
}

String _paramDefault(SceneParamDecl p) => switch (p.kind) {
  SceneParamKind.string => _str(p.defaultValue as String),
  SceneParamKind.number => _num(p.defaultValue as double),
  SceneParamKind.color => 'const ${_color(p.defaultValue as SceneColor)}',
  SceneParamKind.bool => '${p.defaultValue}',
  // A track interpolates between two values; a list is not one.
  SceneParamKind.list => throw ArgumentError(
    'a motion parameter cannot be a list: "${p.name}"',
  ),
};

String _num(double v) =>
    v == v.roundToDouble() && v.abs() < 1e15 ? '${v.round()}' : '$v';

String _color(SceneColor c) =>
    'Color(0x${c.argb.toRadixString(16).padLeft(8, '0').toUpperCase()})';

/// What a node's generated classes are named after: an external widget's
/// registration entry, a nested scene's class. Empty for anything else,
/// which is refused before it gets here.
String _entryOf(SceneNode node) => switch (node) {
  ExternalNode e => e.entry,
  SceneRefNode r => r.sceneClassName,
  _ => '',
};

String _str(String s) {
  var out = StringBuffer("'");
  for (var rune in s.runes) {
    switch (rune) {
      case 0x5C:
        out.write(r'\\');
      case 0x27:
        out.write(r"\'");
      case 0x24:
        out.write(r'\$');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        out.writeCharCode(rune);
    }
  }
  out.write("'");
  return '$out';
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

/// Parses [source] against the scene it animates: targets resolve to
/// [scene]'s nodes, and the extends clause must name [sceneClassName] —
/// a motion is one half of a pair, never read alone.
/// Read one motion class out of the scene file the door already parsed —
/// targets resolve against [scene], which the door parsed first.
MotionParse parseMotionClass(
  ClassDeclaration decl,
  String source, {
  required SceneDocument scene,
  required String sceneClassName,
}) {
  var p = _Parser(source, scene, sceneClassName);
  var doc = p.parseClass(decl);
  return MotionParse(p.refusals.isEmpty ? doc : null, p.className, p.refusals);
}

class _Parser {
  _Parser(this.source, this.scene, this.sceneClassName);

  final String source;
  final SceneDocument scene;
  final String sceneClassName;
  final refusals = <SceneRefusal>[];
  String? className;
  late final _lines = source.split('\n');

  final _params = <String, SceneParamDecl>{};

  void refuse(int offset, String construct, String message) {
    var line = 1;
    var seen = 0;
    for (var l in _lines) {
      if (offset <= seen + l.length) break;
      seen += l.length + 1;
      line++;
    }
    refusals.add(SceneRefusal(offset, line, construct, message));
  }

  MotionDocument? parseClass(ClassDeclaration found) {
    className = found.namePart.typeName.lexeme;
    _refuseComments(found);
    _readHeader(found);

    // Phase 1: members. Groups collect; the timeline is read as an
    // expression tree of references, linked after every group is known
    // (forward references are ordinary under `late final`).
    var doc = MotionDocument(sceneClassName: sceneClassName);
    var declared = <String, int>{
      for (var n in motionReservedNames) n: -1,
      for (var p in _params.keys) p: -1,
    };
    (TimelineExpr, int)? timeline;
    var refOffsets = <AnimateGroup, int>{};
    for (var member in found.body.members) {
      if (member is ConstructorDeclaration) {
        refuse(
          member.offset,
          'constructor',
          'parameters live in the class header: '
              '`class ${className!}(super.scene, {final double p = 1})`',
        );
        continue;
      }
      if (member is MethodDeclaration && member.name.lexeme == 'copy') {
        _checkCopy(member);
        continue;
      }
      if (member is! FieldDeclaration || member.fields.variables.length != 1) {
        refuse(
          member.offset,
          'member',
          'the motion class holds only group fields, the timeline and the '
              'derived copy',
        );
        continue;
      }
      var variable = member.fields.variables.single;
      var name = variable.name.lexeme;
      var initializer = variable.initializer;
      if (initializer == null) {
        refuse(member.offset, 'no initializer', '`$name` must be initialized');
        continue;
      }
      if (name == 'timeline') {
        if (timeline != null) {
          refuse(
            variable.offset,
            'duplicate name',
            'timeline is declared twice',
          );
          continue;
        }
        var expr = _timeline(initializer, refOffsets);
        if (expr != null) timeline = (expr, variable.offset);
        continue;
      }
      if (declared.containsKey(name)) {
        refuse(
          variable.offset,
          'duplicate name',
          motionReservedNames.contains(name)
              ? '"$name" is reserved in a motion class'
              : '"$name" is already declared: parameters and groups share '
                    'one namespace, and a name is an identity',
        );
        continue;
      }
      declared[name] = variable.offset;
      var group = _group(name, initializer);
      if (group != null) doc.groups.add(group);
    }

    // Phase 2: link. The timeline is mandatory; every reference resolves to
    // a declared group and appears at most once. An UNPLACED group is a
    // library asset by decision — playable on events, no autoplay — so
    // there is no orphan refusal here.
    if (timeline == null) {
      if (refusals.isEmpty) {
        refuse(
          found.offset,
          'no timeline',
          'the motion class declares '
              '`@override late final timeline = ParExpr([…])`: '
              'the timeline is what plays',
        );
      }
      return null;
    }
    var placed = <String>{};
    for (var entry in refOffsets.entries) {
      var name = entry.key.name;
      if (_params.containsKey(name)) {
        refuse(
          entry.value,
          'parameter in timeline',
          '"$name" is a parameter: the timeline plays groups',
        );
        continue;
      }
      if (doc.groupNamed(name) == null) {
        refuse(
          entry.value,
          'unknown reference',
          '"$name" is not a group declared in this motion',
        );
        continue;
      }
      if (!placed.add(name)) {
        refuse(
          entry.value,
          'placed twice',
          '"$name" is already in the timeline: a group plays from one '
              'place; wrap it in Repeat or split the group instead',
        );
      }
    }
    doc.timeline = _resolveRefs(timeline.$1, doc);
    doc.params.addAll(_params.values);
    return doc;
  }

  /// Swap every placeholder in [expr] for the group it names. A name that
  /// resolves to nothing was already refused; the placeholder stays so the
  /// tree keeps its shape for whatever reports the refusal.
  static TimelineExpr _resolveRefs(TimelineExpr expr, MotionDocument doc) =>
      switch (expr) {
        AnimateGroup g => doc.groupNamed(g.name) ?? g,
        ParExpr p => ParExpr([for (var c in p.children) _resolveRefs(c, doc)]),
        SeqExpr s => SeqExpr([for (var c in s.children) _resolveRefs(c, doc)]),
        AtExpr a => AtExpr(a.offset, _resolveRefs(a.child, doc)),
        SpeedExpr s => SpeedExpr(s.factor, _resolveRefs(s.child, doc)),
        RepeatExpr r => RepeatExpr(r.times, _resolveRefs(r.child, doc)),
      };

  /// The class header: `(super.scene, {…params})` and
  /// `extends SceneMotion<Scene>`.
  void _readHeader(ClassDeclaration decl) {
    var extendsClause = decl.extendsClause;
    var superType = extendsClause?.superclass;
    if (superType == null || superType.name.lexeme != 'SceneMotion') {
      refuse(
        decl.offset,
        'extends',
        'a motion class extends SceneMotion<$sceneClassName>',
      );
    } else {
      var args = superType.typeArguments?.arguments;
      var arg = args?.length == 1 ? args!.single : null;
      var named = arg is NamedType ? arg.name.lexeme : null;
      if (named != sceneClassName) {
        refuse(
          superType.offset,
          'scene class',
          'this motion extends SceneMotion<${named ?? '…'}> but the scene '
              'beside it is $sceneClassName',
        );
      }
    }
    if (decl.withClause != null || decl.implementsClause != null) {
      refuse(
        (decl.withClause ?? decl.implementsClause)!.offset,
        'clause',
        'a motion class only extends SceneMotion',
      );
    }
    if (decl.namePart case PrimaryConstructorDeclaration pc) {
      if (pc.constKeyword != null) {
        refuse(
          pc.constKeyword!.offset,
          'const',
          'a motion is never const: its groups are late finals',
        );
      }
      var sawScene = false;
      for (var p in pc.formalParameters.parameters) {
        if (p is SuperFormalParameter && p.name.lexeme == 'scene') {
          sawScene = true;
          continue;
        }
        _readParam(p);
      }
      if (!sawScene) {
        refuse(
          pc.formalParameters.offset,
          'scene formal',
          'the first formal is `super.scene`: the motion holds the scene '
              'it animates',
        );
      }
    } else {
      refuse(
        decl.offset,
        'no constructor',
        'a motion class takes its scene in the header: '
            '`class ${className!}(super.scene) extends '
            'SceneMotion<$sceneClassName>`',
      );
    }
  }

  void _readParam(FormalParameter p) {
    var name = p.name?.lexeme;
    if (p is FieldFormalParameter) {
      refuse(
        p.offset,
        'parameter',
        'a motion parameter is spelled in full in the header, as '
            '`final double $name = 24`, never with `this.`',
      );
      return;
    }
    if (!p.isNamed || name == null) {
      refuse(
        p.offset,
        'parameter',
        'after `super.scene`, a parameter is a named header formal with a '
            'default: `final double slideFrom = 24`',
      );
      return;
    }
    var dflt = p.defaultClause?.value;
    if (dflt == null) {
      refuse(p.offset, 'no default', 'a parameter carries a default value');
      return;
    }
    if (_params.containsKey(name) || motionReservedNames.contains(name)) {
      refuse(
        p.offset,
        'duplicate name',
        motionReservedNames.contains(name)
            ? '"$name" is reserved in a motion class'
            : '"$name" is declared twice',
      );
      return;
    }
    var parsed = _paramDefaultOf(dflt);
    if (parsed == null) {
      refuse(
        dflt.offset,
        'parameter default',
        'a default is a string, number or Color(0x…) literal',
      );
      return;
    }
    var decl = SceneParamDecl(name, parsed.$1, parsed.$2);
    if (p is RegularFormalParameter &&
        p.type != null &&
        '${p.type}' != decl.typeName) {
      refuse(
        p.type!.offset,
        'parameter type',
        'this default makes "$name" a ${decl.typeName}: spell it '
            '`final ${decl.typeName} $name`',
      );
      return;
    }
    _params[name] = decl;
  }

  (SceneParamKind, Object)? _paramDefaultOf(Expression e) {
    var inner = e;
    var negate = false;
    if (inner is PrefixExpression && inner.operator.lexeme == '-') {
      negate = true;
      inner = inner.operand;
    }
    switch (inner) {
      case SimpleStringLiteral(:var value):
        return (SceneParamKind.string, value);
      case IntegerLiteral(:var value?):
        return (SceneParamKind.number, (negate ? -value : value).toDouble());
      case DoubleLiteral(:var value):
        return (SceneParamKind.number, negate ? -value : value);
      default:
        if (_invocation(inner) case ('Color', var args)
            when args.arguments.length == 1) {
          var v = args.arguments.single.argumentExpression;
          if (v is IntegerLiteral && v.value != null) {
            return (SceneParamKind.color, SceneColor(v.value!));
          }
        }
        return null;
    }
  }

  /// `copy` is derived: a stale parameter list inside is tolerated (the
  /// next emit converges it), but the shape must be the canonical single
  /// expression, or the member is refused.
  void _checkCopy(MethodDeclaration m) {
    var body = m.body;
    var ok = false;
    if (body is ExpressionFunctionBody) {
      if (_invocation(body.expression) case ('copyStateInto', var args)
          when args.arguments.length == 1) {
        var inner = args.arguments.single.argumentExpression;
        if (_invocation(inner) case (var name, _) when name == className) {
          ok = true;
        }
      }
    }
    if (!ok) {
      refuse(
        m.offset,
        'copy',
        'copy is derived: the editor rewrites it as '
            '`${className!} copy($sceneClassName scene) => '
            'copyStateInto(${className!}(scene, …));`; leave it out or keep '
            'that shape',
      );
    }
  }

  void _refuseComments(ClassDeclaration decl) {
    var body = decl.body;
    if (body is! BlockClassBody) return;
    var start = body.leftBracket.offset;
    var end = decl.endToken.offset;
    for (
      Token? token = body.leftBracket;
      token != null && token.offset <= end;
      token = token.next
    ) {
      for (
        Token? comment = token.precedingComments;
        comment != null;
        comment = comment.next
      ) {
        if (comment.offset > start) {
          refuse(
            comment.offset,
            'comment',
            'comments inside the motion are not preserved by the editor, so '
                'they are refused rather than silently lost on the next save',
          );
        }
      }
      if (token.offset >= end) break;
    }
  }

  /// One group field: `scene.<node>.animate(<props…>)`.
  AnimateGroup? _group(String name, Expression expr) {
    String? targetName;
    ArgumentList? args;
    if (expr
        case MethodInvocation(:var methodName, :var target, :var argumentList)
        when methodName.name == 'animate') {
      if (target case PrefixedIdentifier(:var prefix, :var identifier)
          when prefix.name == 'scene') {
        targetName = identifier.name;
        args = argumentList;
      }
    }
    if (targetName == null || args == null) {
      refuse(
        expr.offset,
        'expression',
        'a group animates one scene node: '
            '`late final $name = scene.<node>.animate(…)`',
      );
      return null;
    }
    var target = scene.nodeNamed(targetName);
    if (target == null) {
      refuse(
        expr.offset,
        'unknown target',
        '"$targetName" is not a node in $sceneClassName',
      );
      return null;
    }
    var group = AnimateGroup(target, name: name);
    var allowed = {
      for (var spec in animatableProps(target)) spec.name: spec.kind,
    };
    for (var arg in args.arguments) {
      if (arg is! NamedArgument) {
        refuse(
          arg.offset,
          'positional argument',
          'a group takes only named track properties',
        );
        continue;
      }
      var prop = arg.name.lexeme;
      var value = arg.argumentExpression;
      if (prop == 'args') {
        if (target is! ExternalNode && target is! SceneRefNode) {
          refuse(
            value.offset,
            'args',
            'only an external widget or a nested scene takes args: '
                '"$targetName" is a ${target.typeName}',
          );
          continue;
        }
        _extArgs(group, value, _entryOf(target));
        continue;
      }
      if (prop == 'axes') {
        if (target is! TextNode) {
          refuse(
            value.offset,
            'axes',
            'only a text has a face to move: '
                '"$targetName" is a ${target.typeName}',
          );
          continue;
        }
        _axisTracks(group, value);
        continue;
      }
      var kind = allowed[prop];
      if (kind == null) {
        refuse(
          value.offset,
          'unknown property',
          '"$prop" is not animatable on a ${target.typeName}: '
              '${allowed.keys.join(', ')}',
        );
        continue;
      }
      var track = _trackOf(value, kind);
      if (track != null) group.tracks[prop] = track;
    }
    return group;
  }

  /// `args: DrinkBadgeTracks(size: MotionTrack([…]))`.
  ///
  /// The class is generated from the same declaration the scene file's
  /// arguments came from, and it carries a slot only for what has in-between
  /// values — so a track aimed at a label, or at a parameter the widget does
  /// not have, does not compile. This is the second grader saying the same
  /// thing with a line number.
  void _extArgs(AnimateGroup group, Expression e, String entry) {
    var expected = '${entry}Tracks';
    var call = _invocation(e);
    if (call == null || call.$1 != expected) {
      refuse(
        e.offset,
        'args',
        'args takes the tracks of what it animates: '
            'args: $expected(size: MotionTrack([…]))',
      );
      return;
    }
    for (var arg in call.$2.arguments) {
      if (arg is! NamedArgument) {
        refuse(
          arg.offset,
          'positional argument',
          'every track is named: $expected(size: MotionTrack([…]))',
        );
        continue;
      }
      var track = _trackOf(arg.argumentExpression, TrackKind.number);
      if (track != null) {
        group.tracks['$sceneArgsPrefix${arg.name.lexeme}'] = track;
      }
    }
  }

  /// `axes: {'wght': MotionTrack([…])}` — a map because the tags come from
  /// the font rather than from the table, so no named argument could name
  /// one. Every axis is a number; a tag that is not four letters is refused
  /// rather than animated into nothing.
  void _axisTracks(AnimateGroup group, Expression e) {
    if (e is! SetOrMapLiteral) {
      refuse(
        e.offset,
        'axes',
        'axes takes a map of tags to tracks: '
            "axes: {'wght': MotionTrack([…])}",
      );
      return;
    }
    for (var entry in e.elements) {
      if (entry is! MapLiteralEntry) {
        refuse(entry.offset, 'axes', 'a tag and a track');
        continue;
      }
      var key = entry.key;
      if (key is! SimpleStringLiteral || key.value.length != 4) {
        refuse(
          key.offset,
          'axis tag',
          "a four-letter tag in quotes, like 'wght'",
        );
        continue;
      }
      var track = _trackOf(entry.value, TrackKind.number);
      if (track != null) {
        group.tracks['$sceneAxesPrefix${key.value}'] = track;
      }
    }
  }

  MotionTrack? _trackOf(Expression e, TrackKind kind) {
    if (_invocation(e) case ('ClipTrack', var args)) {
      if (kind != TrackKind.number) {
        refuse(e.offset, 'clip block', 'a clip block stands on a number track');
        return null;
      }
      var block = _clipBlockOf(e, args);
      return block == null
          ? null
          : (MotionTrack([], kind: kind)..clips.add(block));
    }
    if (_invocation(e) case ('ClipBlocks', var args)
        when args.arguments.length == 1 &&
            args.arguments.single.argumentExpression is ListLiteral) {
      if (kind != TrackKind.number) {
        refuse(e.offset, 'clip block', 'a clip block stands on a number track');
        return null;
      }
      var track = MotionTrack([], kind: kind);
      var items = args.arguments.single.argumentExpression as ListLiteral;
      for (var element in items.elements) {
        var call = element is Expression ? _invocation(element) : null;
        if (call == null || call.$1 != 'ClipBlock') {
          refuse(element.offset, 'element', 'expected a ClipBlock(…)');
          continue;
        }
        var block = _clipBlockOf(element as Expression, call.$2);
        if (block != null) track.clips.add(block);
      }
      if (track.clips.isEmpty) {
        refuse(e.offset, 'clip blocks', 'ClipBlocks lists at least one block');
        return null;
      }
      track.sortClips();
      return track;
    }
    ListLiteral? list;
    if (_invocation(e) case ('MotionTrack', var args)
        when args.arguments.length == 1) {
      var only = args.arguments.single.argumentExpression;
      if (only is ListLiteral) list = only;
    }
    if (list == null) {
      refuse(
        e.offset,
        _kind(e),
        'a property is a MotionTrack([MotionKey(…), …])',
      );
      return null;
    }
    if (list.elements.isEmpty) {
      refuse(
        list.offset,
        'empty track',
        'a track with no keys contributes nothing and is never written: '
            'remove the property instead',
      );
      return null;
    }
    var track = MotionTrack([], kind: kind);
    Duration? last;
    for (var element in list.elements) {
      if (element is! Expression) {
        refuse(element.offset, 'element', 'a track lists its keys one by one');
        continue;
      }
      var key = _keyOf(element, kind);
      if (key == null) continue;
      if (last != null && key.at < last) {
        refuse(
          element.offset,
          'keys out of order',
          'keys are listed in time order: the hold rule reads them sorted',
        );
        continue;
      }
      if (key.at == last) {
        refuse(
          element.offset,
          'duplicate key time',
          'two keys at ${key.at.inMilliseconds}.ms: one value per time',
        );
        continue;
      }
      last = key.at;
      track.keys.add(key);
    }
    return track.keys.isEmpty ? null : track;
  }

  /// `ClipTrack(clip: …, at: …, length: …, speed: …, offset: …, reverse:
  /// …)`, or a `ClipBlock(…)` with the same arguments — one block; see
  /// [MotionClip].
  MotionClip? _clipBlockOf(Expression e, ArgumentList args) {
    Duration? at;
    Duration? length;
    var clip = '';
    var speed = 1.0;
    var offset = Duration.zero;
    var reverse = false;
    for (var arg in args.arguments) {
      if (arg is! NamedArgument) {
        refuse(
          arg.offset,
          'positional argument',
          'ClipTrack takes named arguments',
        );
        continue;
      }
      var v = arg.argumentExpression;
      switch (arg.name.lexeme) {
        case 'clip':
          if (v is SimpleStringLiteral) {
            clip = v.value;
          } else {
            refuse(v.offset, 'clip', 'clip is the name of a clip, as a string');
          }
        case 'at':
          at = _durOf(v);
        case 'length':
          length = _durOf(v);
        case 'offset':
          offset = _durOf(v) ?? Duration.zero;
        case 'speed':
          if (_valueOf(v, TrackKind.number) case (double s, null)) {
            speed = s;
          } else {
            refuse(v.offset, 'speed', 'speed is a number');
          }
        case 'reverse':
          if (v is BooleanLiteral) {
            reverse = v.value;
          } else {
            refuse(v.offset, 'reverse', 'reverse is true or false');
          }
        default:
          refuse(
            v.offset,
            'unknown property',
            'a clip block has no property "${arg.name.lexeme}"',
          );
      }
    }
    if (at == null || length == null) {
      refuse(e.offset, 'clip block', 'a clip block needs `at:` and `length:`');
      return null;
    }
    return MotionClip(
      at: at,
      length: length,
      clip: clip,
      speed: speed,
      offset: offset,
      reverse: reverse,
    );
  }

  MotionKey? _keyOf(Expression e, TrackKind kind) {
    ArgumentList? args;
    if (_invocation(e) case ('MotionKey', var a)) args = a;
    if (args == null) {
      refuse(e.offset, _kind(e), 'expected Key(at: …, value: …)');
      return null;
    }
    Duration? at;
    Object? value;
    String? paramRef;
    SceneCurve? curve;
    var before = refusals.length;
    for (var arg in args.arguments) {
      if (arg is! NamedArgument) {
        refuse(arg.offset, 'positional argument', 'Key takes named arguments');
        continue;
      }
      var v = arg.argumentExpression;
      switch (arg.name.lexeme) {
        case 'at':
          at = _durOf(v);
        case 'value':
          (value, paramRef) = _valueOf(v, kind) ?? (null, null);
        case 'curve':
          curve = _curveOf(v);
        default:
          refuse(
            v.offset,
            'unknown property',
            'Key has no property "${arg.name.lexeme}"',
          );
      }
    }
    if (at == null || value == null) {
      // A refusal inside an argument already told the story; only a key
      // with the arguments simply absent needs its own.
      if (refusals.length == before) {
        refuse(e.offset, 'key', 'a MotionKey needs `at:` and `value:`');
      }
      return null;
    }
    return MotionKey(at: at, value: value, curve: curve, paramRef: paramRef);
  }

  Duration? _durOf(Expression e) {
    if (e case PropertyAccess(:var target, :var propertyName)
        when propertyName.name == 'ms' &&
            target is IntegerLiteral &&
            target.value != null) {
      return Duration(milliseconds: target.value!);
    }
    refuse(e.offset, _kind(e), 'a time is spelled `<int>.ms`');
    return null;
  }

  /// A value literal of the track's kind, or a declared parameter's name —
  /// which binds the key to the parameter and yields its default.
  (Object, String?)? _valueOf(Expression e, TrackKind kind) {
    if (e is SimpleIdentifier) {
      var decl = _params[e.name];
      if (decl == null) {
        refuse(
          e.offset,
          'identifier',
          '"${e.name}" is not a declared parameter',
        );
        return null;
      }
      var wanted = switch (kind) {
        TrackKind.number => SceneParamKind.number,
        TrackKind.color => SceneParamKind.color,
      };
      if (decl.kind != wanted) {
        refuse(
          e.offset,
          'parameter type',
          '"${e.name}" is a ${decl.typeName} parameter: this track holds '
              '${kind.name}s',
        );
        return null;
      }
      return (decl.defaultValue, e.name);
    }
    switch (kind) {
      case TrackKind.number:
        var v = _double(e);
        return v == null ? null : (v, null);
      case TrackKind.color:
        var v = _colorOf(e);
        return v == null ? null : (v, null);
    }
  }

  SceneCurve? _curveOf(Expression e) {
    if (e is PrefixedIdentifier &&
        e.prefix.name == 'SceneCurves' &&
        motionCurves.contains(e.identifier.name)) {
      var name = e.identifier.name;
      // Linear is the default, so the file writes no curve at all for it.
      return name == 'linear' ? null : sceneCurvesByName[name];
    }
    refuse(
      e.offset,
      'unknown curve',
      'expected SceneCurves.<${motionCurves.take(4).join('|')}…>: nothing else '
          'is on the allowlist',
    );
    return null;
  }

  /// The arrangement tree. References are collected with their offsets and
  /// validated after every group is known.
  TimelineExpr? _timeline(Expression e, Map<AnimateGroup, int> refOffsets) {
    if (e is SimpleIdentifier) {
      // A placeholder: the arrangement holds group OBJECTS, and the field it
      // names may be declared further down. Swapped for the real one once
      // every group is known.
      var ref = AnimateGroup(ShapeNode(), name: e.name);
      refOffsets[ref] = e.offset;
      return ref;
    }
    var (name, args) = _invocation(e) ?? (null, null);
    if (name == null || args == null) {
      refuse(
        e.offset,
        _kind(e),
        'the timeline arranges groups with ParExpr, SeqExpr, AtExpr, '
        'SpeedExpr and RepeatExpr',
      );
      return null;
    }
    List<TimelineExpr>? children(int index) {
      var arg = args.arguments[index].argumentExpression;
      if (arg is! ListLiteral) {
        refuse(arg.offset, _kind(arg), '$name takes a list of arrangements');
        return null;
      }
      var out = <TimelineExpr>[];
      for (var element in arg.elements) {
        if (element is! Expression) {
          refuse(
            element.offset,
            'element',
            'arrangements are listed one by '
                'one',
          );
          continue;
        }
        var child = _timeline(element, refOffsets);
        if (child != null) out.add(child);
      }
      return out;
    }

    switch (name) {
      case 'ParExpr' || 'SeqExpr' when args.arguments.length == 1:
        var kids = children(0);
        if (kids == null) return null;
        return name == 'ParExpr' ? ParExpr(kids) : SeqExpr(kids);
      case 'AtExpr' when args.arguments.length == 2:
        var offset = _durOf(args.arguments[0].argumentExpression);
        var child = _timeline(args.arguments[1].argumentExpression, refOffsets);
        if (offset == null || child == null) return null;
        return AtExpr(offset, child);
      case 'SpeedExpr' when args.arguments.length == 2:
        var factor = _double(args.arguments[0].argumentExpression);
        var child = _timeline(args.arguments[1].argumentExpression, refOffsets);
        if (factor == null || child == null) return null;
        if (factor <= 0) {
          refuse(
            args.arguments[0].offset,
            'speed factor',
            "a speed factor is positive: reversing is the player's job",
          );
          return null;
        }
        return SpeedExpr(factor, child);
      case 'RepeatExpr' when args.arguments.length == 2:
        var timesExpr = args.arguments[0].argumentExpression;
        var times = timesExpr is IntegerLiteral ? timesExpr.value : null;
        var child = _timeline(args.arguments[1].argumentExpression, refOffsets);
        if (times == null) {
          refuse(
            timesExpr.offset,
            _kind(timesExpr),
            'Repeat counts with an '
            'int literal',
          );
          return null;
        }
        if (child == null) return null;
        if (times < 1) {
          refuse(
            timesExpr.offset,
            'repeat count',
            'Repeat plays at least '
                'once',
          );
          return null;
        }
        return RepeatExpr(times, child);
      case 'ParExpr' || 'SeqExpr' || 'AtExpr' || 'SpeedExpr' || 'RepeatExpr':
        refuse(
          e.offset,
          'arguments',
          '$name takes '
              '${name == 'ParExpr' || name == 'SeqExpr' ? 'one list' : 'two arguments'}',
        );
        return null;
      default:
        refuse(
          e.offset,
          'unknown combinator',
          '"$name" is not an arrangement: ParExpr, SeqExpr, AtExpr, '
              'SpeedExpr or RepeatExpr',
        );
        return null;
    }
  }

  (String, ArgumentList)? _invocation(Expression e) => switch (e) {
    MethodInvocation(:var methodName, :var target, :var argumentList)
        when target == null =>
      (methodName.name, argumentList),
    InstanceCreationExpression(:var constructorName, :var argumentList)
        when constructorName.name == null =>
      (constructorName.type.name.lexeme, argumentList),
    _ => null,
  };

  double? _double(Expression e) {
    var negate = false;
    var inner = e;
    if (inner is PrefixExpression && inner.operator.lexeme == '-') {
      negate = true;
      inner = inner.operand;
    }
    var value = switch (inner) {
      IntegerLiteral(:var value) => value?.toDouble(),
      DoubleLiteral(:var value) => value,
      _ => null,
    };
    if (value == null) {
      refuse(e.offset, _kind(e), 'expected a number literal');
      return null;
    }
    return negate ? -value : value;
  }

  SceneColor? _colorOf(Expression e) {
    if (_invocation(e) case ('Color', var args)
        when args.arguments.length == 1) {
      var v = args.arguments.single.argumentExpression;
      if (v is IntegerLiteral && v.value != null) return SceneColor(v.value!);
    }
    refuse(e.offset, _kind(e), 'expected a color, spelled Color(0xAARRGGBB)');
    return null;
  }

  String _kind(Expression e) => switch (e) {
    ConditionalExpression() => 'conditional',
    BinaryExpression() => 'arithmetic',
    MethodInvocation() => 'method call',
    StringInterpolation() => 'interpolation',
    AdjacentStrings() => 'adjacent strings',
    SimpleIdentifier() => 'identifier',
    PrefixedIdentifier() => 'identifier',
    _ => e.runtimeType.toString(),
  };
}

/// The group's tracks filed under [prefix], by the part's own name.
Map<String, MotionTrack> _partsOf(AnimateGroup g, String prefix) => {
  for (var e in g.tracks.entries)
    if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
};
