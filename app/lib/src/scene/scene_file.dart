// Disposable spike: the scene file grammar, its parser and its emitter — the
// tier-2 round-trip bet measured on the touched model instead of a predicted
// one.
//
// THE GRAMMAR, on a page. A scene file is:
//   - a `//@flutterware:scene=…` marker in its first line
//   - the authoring import, which every scene file has, and ANY OTHER
//     IMPORT the file needs — preserved verbatim and written back, because
//     the tool owns this file and a dropped import is the shredder this
//     grammar exists to prevent. Prefixes are the author's (`as app`).
//     Nothing else at file level: no part, no export, no library
//   - one SCENE class, and after it any number of MOTION classes that
//     animate it (`class X(super.scene) extends SceneMotion<Scene>`) — the
//     pair is one file, one marker, one round trip. The motion grammar is
//     in motion_file.dart. Its parameters — typed holes whose
//     default is the mockup — are the class's PRIMARY CONSTRUCTOR: each is
//     `final <String|double|Color> <name> = <literal>` in the class header,
//     which is one spelling for the formal, the field and the default at
//     once, and puts the name in scope for every node below
//   - the class members are node fields: `late final <name> = <Node>(…);`
//     — THE FIELD NAME IS THE NODE'S IDENTITY (unique by Dart's own rules,
//     shared namespace with the parameters), and one field must be `root`,
//     a Frame
//   - a node is a constructor invocation: Frame, Text, Shape, Ext or Scene,
//     with named arguments from that node's fixed vocabulary; Text takes its
//     content as one positional string, Ext takes its registration entry as
//     one positional identifier, Scene takes another scene file's class
//     name the same way (its `args:` override that scene's parameters)
//   - an ExternalNode additionally takes `build:`, a closure returning the
//     app's widget — `build: (a) => app.DrinkBadge(a.number('size'))`. THE
//     TOOL DOES NOT READ IT: it keeps the span exactly as written and puts
//     it back, because it cannot author app code and must not lose it
//     either. The arg names inside are the grammar's stringly boundary
//   - `children: [ … ]` lists nodes BY FIELD NAME — every node is declared
//     as its own field and placed exactly once (forward references are fine;
//     `late` is what makes sibling references legal Dart)
//   - values are: int/double literals (optionally negated), single string
//     literals with no interpolation, bool literals, `Color(0x…)`,
//     allowlisted enum references, `args: {'k': literal}` maps, and — where
//     the types agree — A PARAMETER'S NAME, which binds the property to the
//     typed hole
//   - a parameter may also be a LIST of records — `final List<({String
//     item, String qty})> lines = const [(item: '…', qty: '12')]`. A frame
//     drawn once per item is `FrameNode.repeating(over: lines, row: (line)
//     => [ … ])`, and inside that closure — THE GRAMMAR'S ONE PLACE WHERE
//     NODES ARE WRITTEN INLINE — a cell reads a field as `line.item`. The
//     cells of a repeated row are not fields, so they have no names and
//     cannot be selected: which cell of which row would it be
//   - a Frame with `layout: NodeLayout.table` takes `columns: [ … ]` — one
//     size per column, in the same `null`/number/`double.infinity`
//     vocabulary a node's size uses — and `cellPadding`. Its children are
//     rows and their children are cells
//   - nothing else: no comments inside the class body, no loops, no
//     conditionals, no method calls, no arithmetic, no identifiers off the
//     allowlist, no inline nodes in children, no class that is neither the
//     scene nor a motion, no orphan fields (an
//     undeclared drop on the next save is the shredder this grammar exists
//     to prevent). Refused with a line number, never dropped.
//
// Invariants the tests hold:
//   - parse(emit(model)) succeeds and re-emits identically (model identity)
//   - emit ∘ parse is the identity on canonical files
//   - accepted non-canonical spellings (`final` for `late final`, forward
//     references, `1024.0`, lowercase hex, a quoted Ext entry, a
//     `final`-less or type-less header formal) converge to canonical in
//     one emit
//   - every hostile construct is refused with an offset and a name, and
//     nothing ever throws.
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:dart_style/dart_style.dart';
import 'package:flutterware/scene_authoring.dart' hide Token;

import 'group_file.dart';
import 'paint_grammar.dart';
import 'motion_file.dart';
import 'tokens_file.dart';

const sceneFileMarker = '//@flutterware:scene=0.9';

/// A scene file's name from its class: `PromoBadge` → `promo_badge.scene.dart`.
///
/// The class is the scene's identity everywhere else, so the file name is
/// derived from it rather than asked for — one name to type, and no way for
/// the two to disagree.
String sceneFileNameFor(String className) =>
    '${className.replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}').toLowerCase()}.scene.dart';

/// The one library a scene file imports. Its vocabulary IS the model's own
/// class names — `FrameNode`, `TextNode`, `SceneColor` — because a spelling
/// that differs from the type is a spelling the compiler cannot check.
const sceneAuthoringUri = 'package:flutterware/scene_authoring.dart';
const sceneAuthoringImport = "import '$sceneAuthoringUri';";

/// The generated arguments file, which lives beside the scenes it serves.
/// One name, so a scene file's import of it never has to be worked out.
const sceneArgsFileName = 'scene_args.dart';

/// One refused construct: where it is and what to do instead.
class SceneRefusal {
  SceneRefusal(this.offset, this.line, this.construct, this.message);

  final int offset;
  final int line;

  /// A short name for what was found — `for element`, `interpolation`,
  /// `unknown property` — stable enough to test against.
  final String construct;

  final String message;

  @override
  String toString() => 'line $line, $construct: $message';
}

/// What a parse produced: a document, or the complete list of reasons there
/// is none. All-or-nothing by design — a partially loaded scene is the lie
/// the editor must never tell — but the refusals are *collected*, so one
/// hostile edit does not hide the next.
class SceneParse {
  SceneParse(
    this.doc,
    this.className,
    this.refusals, [
    this.motions = const {},
    this.imports = const [],
  ]);

  final SceneDocument? doc;
  final String? className;
  final List<SceneRefusal> refusals;

  /// Every import but the authoring one, verbatim and in the order they
  /// should be written back. The tool cannot invent these — an Ext names an
  /// app widget, and only the author knows where it lives — so it keeps
  /// them instead.
  final List<String> imports;

  /// The motion classes declared beside the scene, by class name, in file
  /// order — a scene may carry several (an intro, an outro) or none.
  final Map<String, MotionDocument> motions;

  bool get ok => doc != null;
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

final _formatter = DartFormatter(
  languageVersion: DartFormatter.latestLanguageVersion,
);

String emitSceneFile(
  SceneDocument doc, {
  String className = 'SceneFile',
  Map<String, MotionDocument> motions = const {},
  List<String> imports = const [],
}) {
  if (doc.root.name != 'root') {
    throw ArgumentError(
      'the root node is the `root` field, so its name '
      'must be "root", got "${doc.root.name}"',
    );
  }
  // The tokens formal is written when the scene reads a token, or when the
  // author declared one; its name is the author's, else `tokens`.
  var readsTokens = _readsTokens(doc);
  var tokensFormal = doc.tokensFormal ?? _freeFormal(doc, 'tokens');
  var hasTokensFormal = readsTokens || doc.tokensFormal != null;
  // The marker and nothing else. The paragraph that used to sit here
  // explained the grammar to somebody who was, by definition, already
  // reading a file written in it — and it was retyped into every scene in
  // the project. What a reader needs from a file is the file.
  var out = StringBuffer('''
$sceneFileMarker
$sceneAuthoringImport
${_imports(imports, needsArgs: _placesSomething(doc) || hasTokensFormal)}
''');
  var seen = <String>{};
  var params = <String, SceneParamDecl>{};
  for (var p in doc.params) {
    if (!isValidNodeName(p.name) || !seen.add(p.name)) {
      throw ArgumentError('"${p.name}" is not a usable parameter name');
    }
    params[p.name] = p;
  }
  if (hasTokensFormal && !seen.add(tokensFormal)) {
    throw ArgumentError('"$tokensFormal" is not a usable tokens formal name');
  }
  var scope = _Scope(params, {
    for (var t in doc.tokens) t.name: t,
  }, tokensFormal);
  if (doc.params.isEmpty && !hasTokensFormal) {
    out.writeln('class $className extends SceneDefinition {');
  } else {
    // The primary constructor: formal, field and default in one spelling,
    // in scope for every node initializer below. The tokens formal comes
    // last, recognised by its type rather than its name.
    out.write('class $className({');
    for (var p in doc.params) {
      out.write('final ${p.typeName} ${p.name} = ${_paramDefault(p)}, ');
    }
    if (hasTokensFormal) {
      out.write(
        'final $sceneTokensClassName $tokensFormal = '
        'const $sceneTokensClassName(), ',
      );
    }
    out.writeln('}) extends SceneDefinition {');
  }
  void field(SceneNode n) {
    // A repeated row's cells are written inside its closure, not beside it:
    // they are not fields, so the walk stops here.
    var repeated = n is FrameNode && (n.repeated?.source.isNotEmpty ?? false);
    if (!repeated) {
      for (var c in n.children) {
        field(c);
      }
    }
    if (!isValidNodeName(n.name) || !seen.add(n.name)) {
      throw ArgumentError(
        '"${n.name}" is not a usable node name. Names are '
        'field names: valid Dart identifiers, unique in the scene',
      );
    }
    // `root` implements SceneDefinition's abstract getter, so it is an
    // override like any other member that does.
    if (n.name == 'root') out.writeln('  @override');
    out.write('  late final ${n.name} = ');
    _emitNode(out, n, scope);
    out.writeln(';');
  }

  field(doc.root);
  out.writeln('}');
  // The motions of the pair live in the same file, after the scene they
  // animate — one document, one marker, one round trip (grammar 0.5).
  for (var entry in motions.entries) {
    out.writeln();
    emitMotionClass(out, entry.value, doc, className: entry.key);
  }
  return _formatter.format(out.toString());
}

/// Whether the scene places anything whose arguments are generated — an
/// external widget or a nested scene. Both spell a `…Args` class, and both
/// therefore need the generated vocabulary in scope.
bool _placesSomething(SceneDocument doc) {
  for (var (node, _) in doc.walk()) {
    if (node is ExternalNode || node is SceneRefNode) return true;
  }
  return false;
}

/// Whether any property reads a declared token, or a nested instance is
/// handed the set — what puts the tokens formal in the header and the
/// generated vocabulary in scope.
bool _readsTokens(SceneDocument doc) {
  for (var (node, _) in doc.walk()) {
    if (node is SceneRefNode && node.tokensArg != null) return true;
    for (var b in node.bindings.values) {
      if (b case TokenRef(:var name) || StyleRef(:var name)
          when doc.tokenNamed(name) != null) {
        return true;
      }
    }
  }
  return false;
}

/// [base], or the first `base2`, `base3`… no parameter or node already has.
String _freeFormal(SceneDocument doc, String base) {
  var taken = {
    for (var p in doc.params) p.name,
    for (var (n, _) in doc.walk()) n.name,
  };
  if (!taken.contains(base)) return base;
  for (var i = 2; ; i++) {
    if (!taken.contains('$base$i')) return '$base$i';
  }
}

/// What a node initializer may name: the parameters, the tokens and what
/// the tokens formal is called.
class _Scope {
  _Scope(this.params, this.tokens, this.tokensFormal);

  final Map<String, SceneParamDecl> params;
  final Map<String, SceneTokenDecl> tokens;
  final String tokensFormal;
}

/// The file's other imports, canonically: package ones first, each group
/// sorted, so the order a hand edit put them in converges in one emit.
///
/// The tool cannot invent an import — only the author knows where a widget
/// lives — with one exception: the generated arguments file, whose name is
/// fixed and whose absence would make a scene that places anything stop
/// compiling the moment the editor added the node.
String _imports(List<String> imports, {bool needsArgs = false}) {
  var all = [
    ...imports,
    if (needsArgs && !imports.any((i) => i.contains("'$sceneArgsFileName'")))
      "import '$sceneArgsFileName';",
  ];
  if (all.isEmpty) return '';
  imports = all;
  var packages = [
    for (var i in imports)
      if (i.contains("'package:")) i,
  ]..sort();
  var relative = [
    for (var i in imports)
      if (!i.contains("'package:")) i,
  ]..sort();
  return '${[...packages, ...relative].join('\n')}\n';
}

String _paramDefault(SceneParamDecl p) => switch (p.kind) {
  SceneParamKind.string => sceneStringLiteral(p.defaultValue as String),
  SceneParamKind.number => _num(p.defaultValue as double),
  SceneParamKind.color => 'const ${_color(p.defaultValue as SceneColor)}',
  SceneParamKind.bool => '${p.defaultValue}',
  SceneParamKind.list => 'const [${p.items.map(_item).join(', ')}]',
};

/// One item, as a record literal — the shape that gives `line.item` a type.
String _item(SceneItem item) =>
    '(${[for (var e in item.entries) '${e.key}: ${_argValue(e.value)}'].join(', ')})';

void _emitNode(
  StringBuffer out,
  SceneNode n,
  _Scope scope, {
  String? list,
  bool inline = false,
}) {
  var props = <String>[];
  var scopeList = list;
  var ps = scope.params;

  /// A bound property is spelled as its reference, always: the binding is
  /// the stronger of the two, and an edit reached the parameter's default
  /// before this ran ([reconcileBindings]), so the reference IS the value.
  /// The only reason to write a literal instead is a binding with nothing
  /// behind it — a parameter not declared, an item reference outside the
  /// closure that gives it a name — and [reconcileBindings] removes those
  /// too, so here it is a guard, not a rule.
  String? ref(String key) {
    switch (n.bindings[key]) {
      case null:
        return null;
      case ParamRef(:var name):
        var p = ps[name];
        return p == null || p.kind == SceneParamKind.list ? null : name;
      case TokenRef(:var name):
        return scope.tokens.containsKey(name)
            ? '${scope.tokensFormal}.$name'
            : null;
      case StyleRef():
        // A style is spelled by hand, under its own key, before the table.
        return null;
      case ItemRef(:var list, :var field):
        // Spelled with the closure's own parameter rather than the list's
        // name, and only inside the closure.
        if (scopeList != list) return null;
        var decl = ps[list];
        if (decl == null || decl.kind != SceneParamKind.list) return null;
        var items = decl.items;
        if (items.isEmpty || !items.first.containsKey(field)) return null;
        return '$_rowParam.$field';
    }
  }

  void add(String key, Object? current, String Function() spell) {
    props.add('$key: ${ref(key) ?? spell()}');
  }

  /// The shared style [n] takes, when it names one that is declared — the
  /// baseline the text properties are compared against instead of the
  /// table's defaults: equal to the style is inherited and not written.
  var style = switch (n.bindings[styleBindingKey]) {
    StyleRef(:var name) => scope.tokens[name]?.style,
    _ => null,
  };

  /// Every table property of [n] off its default, or bound — a binding is
  /// written whatever the value, because the reference IS the value. The
  /// text and the arguments are positional and spelled by hand; children and
  /// a repeat are structure, not values.
  void table({Set<String> skip = const {}}) {
    for (var p in scenePropsOf(n)) {
      if (p.byHand) continue;
      if (skip.contains(p.name)) continue;
      var v = p.read(n);
      var bound =
          n.bindings.containsKey(p.name) ||
          (p.sides ?? const []).any(n.bindings.containsKey);
      var inherited = style != null && style.sets(p.name)
          ? sceneValuesEqual(v, style.values[p.name])
          : isSceneDefault(p, v);
      if (inherited && !bound) continue;
      switch (p.kind) {
        // Never reached here: the two byHand rows are skipped above, and
        // `axes` is a style field, spelled inside the style argument. Named
        // so the switch stays exhaustive and a new kind has to be thought
        // about rather than silently dropped.
        case ScenePropKind.style:
        case ScenePropKind.args:
        case ScenePropKind.axes:
          break;
        case ScenePropKind.edges:
          // One number while one number says it, four names when it does
          // not. A frame that only ever wanted `padding: 16` keeps writing
          // that.
          var quad = v! as SceneQuad;
          if (quad.isUniform) {
            var one = quad.sides.first;
            add(p.name, one, () => _num(one));
          } else {
            for (var (k, value) in quad.sides.indexed) {
              var side = p.sides![k];
              if (value != 0 || n.bindings.containsKey(side)) {
                add(side, value, () => _num(value));
              }
            }
          }
        case ScenePropKind.sizes:
          props.add(
            '${p.name}: [${(v! as List<double?>).map(_track).join(', ')}]',
          );
        case ScenePropKind.layers:
          props.add('${p.name}: ${emitSceneLayers(v! as List<TextLayer>)}');
        case ScenePropKind.choice:
          props.add(
            '${p.name}: ${p.choices!.typeName}.${p.choices!.nameOf(v!)}',
          );
        case ScenePropKind.number:
          add(p.name, v, () => _num(v! as double));
        case ScenePropKind.integer:
          add(p.name, (v! as int).toDouble(), () => '$v');
        case ScenePropKind.size:
          add(p.name, v, () => _size(v! as double));
        case ScenePropKind.color:
          add(p.name, v, () => _color(v! as SceneColor));
        case ScenePropKind.string:
          add(p.name, v, () => sceneStringLiteral(v! as String));
        case ScenePropKind.boolean:
          add(p.name, v, () => '$v');
      }
    }
  }

  switch (n) {
    case FrameNode f:
      table();
      // A repeat writes its cells INLINE, inside the closure that binds
      // them — they are not fields, because there is no one row for them to
      // belong to.
      if (f.repeated?.source case var list? when list.isNotEmpty) {
        var cells = [for (var c in f.children) _emitCell(c, scope, list)];
        out.write(
          'FrameNode.repeating(over: $list, '
          'row: ($_rowParam) => [${cells.join(', ')}], '
          '${props.join(', ')})',
        );
        return;
      }
      if (f.children.isNotEmpty) {
        props.add(
          inline
              ? 'children: [${[for (var c in f.children) _emitCell(c, scope, list!)].join(', ')}]'
              : 'children: [${f.children.map((c) => c.name).join(', ')}]',
        );
      }
      out.write('FrameNode(${props.join(', ')})');
    case TextNode t:
      // One run keeps the short spelling — `TextNode('Hello')` — and several
      // take the rich one, the way `Text` and `Text.rich` divide. A bound
      // text is one run by definition: a parameter fills the whole string.
      var rich = t.runs.length > 1 && ref('text') == null;
      props.add(
        rich
            ? '[${t.runs.map(_run).join(', ')}]'
            : ref('text') ?? sceneStringLiteral(t.text),
      );
      // Every property of the TREATMENT is spelled inside the one style
      // argument, so the table skips the style subset here; align and
      // maxLines are the paragraph's and stay the node's own arguments.
      if (_styleArg(t, scope, ref) case var arg?) props.add(arg);
      table(skip: _styleArgNames);
      out.write('TextNode${rich ? '.rich' : ''}(${props.join(', ')})');
    case ShapeNode _:
      table();
      out.write('ShapeNode(${props.join(', ')})');
    case KindNode k:
      table();
      if (k.kind.children && k.children.isNotEmpty) {
        props.add('children: [${k.children.map((c) => c.name).join(', ')}]');
      }
      out.write('${k.kind.constructor}(${props.join(', ')})');
    case ExternalNode e:
      props.add(
        _argsLiteral(e.entry, e.args, 'a registration entry name', ref: ref),
      );
      table();
      out.write('ExternalNode(${props.join(', ')})');
    case SceneRefNode r:
      props.add(
        _argsLiteral(
          r.sceneClassName,
          r.args,
          'a scene class name',
          ref: ref,
          // The parent's set, under the child's own name for its formal.
          extra: r.tokensArg == null
              ? null
              : '${r.tokensArg}: ${scope.tokensFormal}',
        ),
      );
      table();
      out.write('SceneRefNode(${props.join(', ')})');
  }
}

/// `TextRun('coffee', style: SceneTextStyle(weight: SceneFontWeight.w700))`
/// — a stretch of the paragraph and what it differs by. A run with no delta
/// is just its string, which is most of them.
String _run(TextRun r) => r.style == null
    ? 'TextRun(${sceneStringLiteral(r.text)})'
    : 'TextRun(${sceneStringLiteral(r.text)}, style: ${sceneStyleLiteral(r.style!)})';

/// Every property a style sets, spelled by the table — so a property added
/// to the style subset is written here without this function knowing its
/// name. Shared with the token library's emitter, so a style reads the same
/// in a scene file and in the file that declares one.
String sceneStyleLiteral(SceneTextStyle s) {
  var values = s.values;
  return 'SceneTextStyle(${[for (var p in sceneStyleProps)
    if (values[p.name] case var v?) '${p.name}: ${scenePropLiteral(p, v)}'].join(', ')})';
}

/// What the style argument spells, by name — what the node's own argument
/// list skips. `text` rides with them because it is the positional.
final _styleArgNames = {'text', for (var p in sceneStyleProps) p.name};

/// What a style literal or a `copyWith` may name — every text property but
/// the positional, which is WIDER than what a style carries. `align` and
/// `maxLines` moved out to the node's own arguments, and a file that still
/// spells them inside the style is read rather than refused: they land on
/// the node, and the next save writes them where they belong. Same courtesy
/// the 0.8 files get.
final _styleFieldNames = {
  for (var p in sceneTextProps)
    if (p.name != 'text') p.name,
};

/// `style: tokens.title`, `style: tokens.title.copyWith(fontSize: 60)` or
/// `style: SceneTextStyle(fontSize: 180)` — a text node's whole typographic
/// treatment, in one argument.
///
/// The base is the style token the node is bound to, when it is bound to
/// one; the delta is every text property that differs from what that style
/// says, or from the table's default where it says nothing — plus every one
/// that is BOUND, because a reference is written whatever its value. Equal
/// to the style drops out and follows the style: there is no override flag,
/// by decision.
///
/// Null when there is nothing to say: no style, and every text property at
/// its default.
String? _styleArg(TextNode t, _Scope scope, String? Function(String prop) ref) {
  var bound = switch (t.bindings[styleBindingKey]) {
    StyleRef(:var name) => name,
    _ => null,
  };
  // An EXPORT's style is the app's own object, laid under the node's values
  // by the guest — the editor never holds its fields, so it can compare
  // against nothing and the delta is measured from the table's defaults.
  var style = bound == null ? null : scope.tokens[bound]?.style;
  var deltas = <String>[];
  for (var p in sceneStyleProps) {
    var v = p.read(t);
    var inherited = style != null && style.sets(p.name)
        ? sceneValuesEqual(v, style.values[p.name])
        : isSceneDefault(p, v);
    if (inherited && !t.bindings.containsKey(p.name)) continue;
    deltas.add('${p.name}: ${ref(p.name) ?? scenePropLiteral(p, v)}');
  }
  if (bound != null) {
    var base = '${scope.tokensFormal}.$bound';
    return deltas.isEmpty
        ? '$styleBindingKey: $base'
        : '$styleBindingKey: $base.copyWith(${deltas.join(', ')})';
  }
  if (deltas.isEmpty) return null;
  return '$styleBindingKey: SceneTextStyle(${deltas.join(', ')})';
}

/// One scalar property as the file spells it — shared with the token
/// library's emitter, so a style spells its fields the same way in a scene
/// file and in the file that declares it. The kinds a text property can
/// take; a quad or a list of sizes is spelled where it is written, because
/// it has more than one spelling.
String scenePropLiteral(SceneProp p, Object? v) => switch (p.kind) {
  // Spelled by hand, never through here.
  ScenePropKind.style || ScenePropKind.args => '$v',
  ScenePropKind.axes => emitSceneAxes(v! as Map<String, double>),
  ScenePropKind.number => _num(v! as double),
  ScenePropKind.integer => '$v',
  ScenePropKind.string => sceneStringLiteral(v! as String),
  ScenePropKind.boolean => '$v',
  ScenePropKind.color => _color(v! as SceneColor),
  ScenePropKind.choice => '${p.choices!.typeName}.${p.choices!.nameOf(v!)}',
  ScenePropKind.layers => emitSceneLayers(v! as List<TextLayer>),
  ScenePropKind.size ||
  ScenePropKind.sizes ||
  ScenePropKind.edges => throw ArgumentError('${p.name} has no one spelling'),
};

/// `const DrinkBadgeArgs(size: 140)` — the whole of an external node's
/// identity and arguments, and the reason a scene file spells no strings.
///
/// The class is generated from the app's declaration of that widget (or,
/// for a nested scene, from the child's own parameter list), so a name that
/// is not a declared argument does not compile. Every argument the node
/// carries is written; what a caller left at the declared default was never
/// read into the node in the first place.
/// `const PromoBadgeArgs(label: 'New')` — or, when an argument reads one of
/// this scene's parameters, `PromoBadgeArgs(label: title)`: a reference is
/// not a constant, so the `const` goes the moment one appears.
String _argsLiteral(
  String entry,
  Map<String, Object?> args,
  String what, {
  required String? Function(String prop) ref,
  String? extra,
}) {
  if (!isValidNodeName(entry)) {
    throw ArgumentError('"$entry" is not $what');
  }
  for (var name in args.keys) {
    if (!isValidNodeName(name)) {
      throw ArgumentError('"$name" is not an argument name');
    }
  }
  var bound = extra != null;
  var named = [
    for (var e in args.entries)
      // An opaque token's marker with no binding behind it has nothing to
      // spell — the token is gone — so the argument is left out.
      if (ref('args.${e.key}') != null || tokenMarkerName(e.value) == null)
        '${e.key}: ${() {
          var r = ref('args.${e.key}');
          if (r != null) bound = true;
          return r ?? _argValue(e.value);
        }()}',
    ?extra,
  ].join(', ');
  return '${bound ? '' : 'const '}${entry}Args($named)';
}

/// What the closure's parameter is called. One name, because the cells it
/// binds are unnamed too and a second convention would only be a second
/// thing to remember.
const _rowParam = 'line';

/// One cell of a repeated row, written inline. Its own children are written
/// inline too — the whole subtree is anonymous.
String _emitCell(SceneNode cell, _Scope scope, String list) {
  var out = StringBuffer();
  _emitNode(out, cell, scope, list: list, inline: true);
  return '$out';
}

/// Canonical number spelling: an integral double is an int literal, anything
/// else is Dart's own round-trippable `toString`. One spelling per value is
/// what makes emit ∘ parse an identity.
String _num(double v) =>
    v == v.roundToDouble() && v.abs() < 1e15 ? '${v.round()}' : '$v';

/// A size, which is a number or the word for "as much as the parent gives".
/// Spelled the way Flutter spells it, because that is what it means.
String _size(double v) => v.isInfinite ? 'double.infinity' : _num(v);

/// A column track: a size, or the word for "as wide as the widest cell".
String _track(double? v) => v == null ? 'null' : _size(v);

String _color(SceneColor c) =>
    'SceneColor(0x${c.argb.toRadixString(16).padLeft(8, '0').toUpperCase()})';

/// A Dart single-quoted string literal for [s] — the one spelling, shared
/// with the token library's emitter and with the args generator.
///
/// It escapes what makes a literal *wrong* rather than merely ugly: the
/// backslash, the quote, the `$` that would otherwise start an interpolation,
/// and the three whitespace controls that cannot sit inside single quotes at
/// all. A partial copy of this — quote and backslash only —
/// is how a headline reading "Your coffee,\nready before you are" emitted
/// source with a raw newline in the middle of a literal.
String sceneStringLiteral(String s) {
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

String _argValue(Object? v) => switch (v) {
  num n => n is double ? _num(n) : '$n',
  String s => sceneStringLiteral(s),
  bool b => '$b',
  // A colour argument is what a nested scene's colour parameter takes.
  SceneColor c => _color(c),
  _ => sceneStringLiteral('$v'),
};

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

SceneParse parseSceneFile(
  String source, {
  Map<String, Set<String>> declaredArgs = const {},
  List<SceneTokenDecl> tokens = const [],
}) {
  var p = _Parser(source, declaredArgs, {for (var t in tokens) t.name: t});
  var doc = p.parse();
  var motions = <String, MotionDocument>{};
  // A motion is half a pair and resolves its targets against the scene, so
  // the motions of the file are read only once the scene is in hand.
  if (doc != null && p.refusals.isEmpty) {
    for (var decl in p.motionClasses) {
      var parsed = parseMotionClass(
        decl,
        source,
        scene: doc,
        sceneClassName: p.className!,
      );
      p.refusals.addAll(parsed.refusals);
      if (parsed.doc case var motion?) motions[parsed.className!] = motion;
    }
  }
  return SceneParse(
    p.refusals.isEmpty ? doc : null,
    p.className,
    p.refusals,
    motions,
    p.imports,
  );
}

class _Parser {
  _Parser(this.source, this.declaredArgs, this._tokens);

  final String source;

  /// The package's tokens, by name — the declaration file, read before any
  /// scene file. What `tokens.brand` is checked against; a scene that reads
  /// a token nobody declared is refused, the way the compiler would refuse
  /// the generated class's missing field.
  final Map<String, SceneTokenDecl> _tokens;

  /// The header formal typed [sceneTokensClassName], if any — the author's
  /// name for it, kept so the emitter writes it back.
  String? _tokensFormal;

  /// Entry label to the argument names that widget declares — the app's
  /// declaration file, read before any scene file. An entry that is absent
  /// is not checked: a package with no declarations still parses, it just
  /// gets no second grader.
  final Map<String, Set<String>> declaredArgs;
  final refusals = <SceneRefusal>[];
  String? className;

  /// Classes carrying `extends SceneMotion<…>` — parsed after the scene.
  final motionClasses = <ClassDeclaration>[];

  /// Imports other than the authoring one, verbatim.
  final imports = <String>[];

  late final _lines = source.split('\n');

  /// Declared parameters, filled from the class header before any field is
  /// parsed.
  final _params = <String, SceneParamDecl>{};

  /// While a `row:` closure is being read: the closure's parameter name and
  /// the list it draws from. This is the ONLY place an item reference is
  /// legal, which is why it is a scope rather than a check afterwards.
  ({String param, String list})? _itemScope;

  /// Names for the cells of a repeated row. They are not fields — the file
  /// writes them inline — so they get a derived name the editor can key its
  /// tree and its rects on, and the emitter never writes it.
  var _cellSeq = 0;

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

  SceneDocument? parse() {
    if (!_lines.first.contains('@flutterware:scene')) {
      refuse(
        0,
        'missing marker',
        'a scene file starts with "$sceneFileMarker"',
      );
    }
    var result = parseString(content: source, throwIfDiagnostics: false);
    for (var error in result.errors) {
      refuse(error.offset, 'syntax error', error.message);
    }
    if (refusals.isNotEmpty && result.errors.isNotEmpty) return null;
    _readDirectives(result.unit, source);

    ClassDeclaration? found;
    for (var decl in result.unit.declarations) {
      if (decl is ClassDeclaration) {
        // The pair shares one file: the scene class, and the motion classes
        // that animate it — told apart by the extends clause they must have.
        if (decl.extendsClause?.superclass.name.lexeme == 'SceneMotion') {
          motionClasses.add(decl);
        } else if (found != null) {
          // The file holds the pair: the scene, and the motions animating
          // it. A second class with no extends clause is a motion missing
          // the one thing that makes it one.
          refuse(
            decl.offset,
            'extends',
            'a scene file holds one scene class and its motions: a motion '
                'is `class ${decl.namePart.typeName.lexeme}(super.scene) '
                'extends SceneMotion<${found.namePart.typeName.lexeme}>`',
          );
        } else {
          found = decl;
        }
      } else {
        refuse(
          decl.offset,
          'declaration',
          'only the scene class and its motions may be declared here',
        );
      }
    }
    if (found == null) {
      refuse(0, 'no class', 'a scene file holds exactly one scene class');
      return null;
    }
    className = found.namePart.typeName.lexeme;
    _refuseComments(found);

    // Phase 0: the class header's primary constructor, if any, declares
    // the parameters — read before any field, so every node initializer
    // may reference them.
    var declared = <String, int>{};
    if (found.namePart case PrimaryConstructorDeclaration pc) {
      _readParams(pc, declared);
    }

    // Phase 1: every member is a node field. The field name is the node's
    // identity; children lists are collected as references and linked
    // after every declaration is known, which is what makes forward
    // references (ordinary under `late final`) free.
    var nodes = <String, SceneNode>{};
    var childRefs = <String, List<(String, int)>>{};
    for (var member in found.body.members) {
      if (member is ConstructorDeclaration) {
        refuse(
          member.offset,
          'constructor',
          'parameters live in the class header: '
              "`class ${className!}({final String title = '…'})`",
        );
        continue;
      }
      if (member is! FieldDeclaration || member.fields.variables.length != 1) {
        refuse(
          member.offset,
          'member',
          'the scene class holds only node fields: '
              '`late final <name> = <Node>(…);`',
        );
        continue;
      }
      var variable = member.fields.variables.single;
      var name = variable.name.lexeme;
      var initializer = variable.initializer;
      if (initializer == null) {
        refuse(
          member.offset,
          'no initializer',
          _params.containsKey(name)
              ? '"$name" is a parameter: the header already declares its '
                    'field; there is nothing to add below'
              : '`$name` must be initialized with a node',
        );
        continue;
      }
      if (declared.containsKey(name)) {
        refuse(
          variable.offset,
          'duplicate name',
          '"$name" is already declared: parameters and nodes share one '
              'namespace, and a name is an identity',
        );
        continue;
      }
      declared[name] = variable.offset;
      var node = _node(name, initializer, childRefs);
      if (node != null) nodes[name] = node;
    }

    var root = nodes['root'];
    if (root == null) {
      if (refusals.isEmpty) {
        refuse(
          found.offset,
          'no root',
          'the scene class declares `late final root = Frame(…)`',
        );
      }
      return null;
    }
    if (root is! FrameNode) {
      refuse(declared['root']!, 'root kind', '`root` must be a Frame(…)');
      return null;
    }

    // Phase 2: link. Every reference resolves, every node has one parent,
    // and everything hangs off root — a placed-but-unreachable node (a
    // cycle, or a child of an orphan) would be silently dropped by the next
    // save, which is exactly the shredder this parser exists to refuse.
    var placed = <String>{};
    for (var entry in childRefs.entries) {
      var frame = nodes[entry.key];
      for (var (ref, offset) in entry.value) {
        if (ref == 'root') {
          refuse(
            offset,
            'root as child',
            '`root` is the tree: it cannot be placed inside itself',
          );
          continue;
        }
        var child = nodes[ref];
        if (child == null) {
          refuse(
            offset,
            'unknown reference',
            '"$ref" is not a node declared in this scene',
          );
          continue;
        }
        if (!placed.add(ref)) {
          refuse(
            offset,
            'placed twice',
            '"$ref" is already placed: a node has exactly one parent',
          );
          continue;
        }
        if (frame is FrameNode || frame is KindNode) {
          frame!.children.add(child);
        }
      }
    }
    var reachable = <SceneNode>{};
    void reach(SceneNode n) {
      if (!reachable.add(n)) return;
      n.children.forEach(reach);
    }

    reach(root);
    for (var entry in nodes.entries) {
      if (entry.key == 'root') continue;
      if (!placed.contains(entry.key)) {
        refuse(
          declared[entry.key]!,
          'orphan node',
          '"${entry.key}" is declared but never placed in a children list, '
              'so the next save would drop it',
        );
      } else if (!reachable.contains(entry.value)) {
        refuse(
          declared[entry.key]!,
          'unreachable node',
          '"${entry.key}" is placed, but its parent chain never reaches '
              '`root`, so the next save would drop it',
        );
      }
    }
    var doc = SceneDocument(root);
    doc.params.addAll(_params.values);
    doc.tokens.addAll(_tokens.values);
    doc.tokensFormal = _tokensFormal;
    // An item reference cannot escape its closure — the grammar has no way
    // to write one outside a `row:` — so there is nothing to check here any
    // more. What is left is turning each recorded binding into the closure
    // everything draws through.
    bindRepeats(doc);
    return doc;
  }

  /// The file level: the authoring import, which must be there, and every
  /// other import, kept exactly as written. A `part`, an `export` or a
  /// `library` is refused — the tool rewrites this whole file, and those
  /// change what that means.
  void _readDirectives(CompilationUnit unit, String source) {
    var hasAuthoring = false;
    for (var directive in unit.directives) {
      if (directive is! ImportDirective) {
        refuse(
          directive.offset,
          'directive',
          'a scene file imports and nothing else: no part, export or '
              'library declaration',
        );
        continue;
      }
      var text = source.substring(directive.offset, directive.end);
      if (directive.uri.stringValue == sceneAuthoringUri) {
        if (directive.prefix != null || directive.combinators.isNotEmpty) {
          refuse(
            directive.offset,
            'authoring import',
            'the authoring import is written plain: $sceneAuthoringImport',
          );
          continue;
        }
        hasAuthoring = true;
        continue;
      }
      imports.add(text);
    }
    if (!hasAuthoring) {
      refuse(
        0,
        'missing import',
        'a scene file is Dart, so it imports its vocabulary: '
            '$sceneAuthoringImport',
      );
    }
  }

  /// The header's formals are the parameter table: each is a named
  /// `final <Type> <name> = <literal>` — one spelling for the formal, the
  /// field and the default, and the default IS the mockup.
  void _readParams(
    PrimaryConstructorDeclaration pc,
    Map<String, int> declared,
  ) {
    if (pc.constKeyword != null) {
      refuse(
        pc.constKeyword!.offset,
        'const',
        'a scene is never const: its nodes are late finals',
      );
    }
    for (var p in pc.formalParameters.parameters) {
      var name = p.name?.lexeme;
      if (p is FieldFormalParameter) {
        refuse(
          p.offset,
          'parameter',
          'a scene parameter is spelled in full in the header, as '
              "`final String $name = '…'`, never with `this.`",
        );
        continue;
      }
      if (!p.isNamed || name == null) {
        refuse(
          p.offset,
          'parameter',
          'a scene parameter is a named header formal with a default: '
              "`final String title = '…'`",
        );
        continue;
      }
      var dflt = p.defaultClause?.value;
      if (dflt == null) {
        refuse(
          p.offset,
          'no default',
          'a parameter carries its mockup as the default value',
        );
        continue;
      }
      if (_params.containsKey(name) || name == _tokensFormal) {
        refuse(p.offset, 'duplicate name', '"$name" is declared twice');
        continue;
      }
      // The tokens formal: recognised by its TYPE, never by its name, so
      // the author may call it what they like and the framework claims no
      // identifier. Its default is the declared set.
      if (p is RegularFormalParameter && '${p.type}' == sceneTokensClassName) {
        if (_tokensFormal != null) {
          refuse(
            p.offset,
            'tokens formal',
            'a scene takes one $sceneTokensClassName: "$_tokensFormal" '
                'already does',
          );
          continue;
        }
        if (_tokens.isEmpty) {
          refuse(
            p.type!.offset,
            'tokens formal',
            "this scene's group lists no token library: create one in the "
                "editor, or attach one in the group's $sceneGroupFileName",
          );
          continue;
        }
        if (_invocation(dflt) case (sceneTokensClassName, var args)
            when args.arguments.isEmpty) {
          _tokensFormal = name;
          declared[name] = p.offset;
        } else {
          refuse(
            dflt.offset,
            'tokens default',
            'the tokens formal defaults to the declared set: '
                '`final $sceneTokensClassName $name = const $sceneTokensClassName()`',
          );
        }
        continue;
      }
      var parsed = _paramDefaultOf(dflt);
      if (parsed == null) {
        refuse(
          dflt.offset,
          'parameter default',
          'a default is a string, number, bool or SceneColor(0x…) literal',
        );
        continue;
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
        continue;
      }
      _params[name] = decl;
      declared[name] = p.offset;
    }
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
      case BooleanLiteral(:var value):
        return (SceneParamKind.bool, value);
      case IntegerLiteral(:var value?):
        return (SceneParamKind.number, (negate ? -value : value).toDouble());
      case DoubleLiteral(:var value):
        return (SceneParamKind.number, negate ? -value : value);
      case ListLiteral list:
        return (SceneParamKind.list, _items(list));
      default:
        if (_invocation(inner) case ('SceneColor', var args)
            when args.arguments.length == 1) {
          var v = args.arguments.single.argumentExpression;
          if (v is IntegerLiteral && v.value != null) {
            return (SceneParamKind.color, SceneColor(v.value!));
          }
        }
        return null;
    }
  }

  /// A list parameter's mockup: items, each a RECORD of named fields whose
  /// values are strings or numbers. A record rather than a map because the
  /// field names are then a TYPE, and `line.item` inside a repeat's closure
  /// is checked against it.
  List<SceneItem> _items(ListLiteral list) {
    var items = <SceneItem>[];
    for (var element in list.elements) {
      if (element is! RecordLiteral) {
        refuse(
          element.offset,
          element is Expression ? _kind(element) : _elementKind(element),
          "an item is a record literal: (item: 'Espresso beans', qty: '12')",
        );
        continue;
      }
      var item = <String, Object>{};
      for (var field in element.fields) {
        if (field is! RecordLiteralNamedField) {
          refuse(
            field.offset,
            'positional field',
            "an item's fields are named: (item: '…', qty: '…')",
          );
          continue;
        }
        var value = _itemValue(field.fieldExpression);
        if (value != null) item[field.name.lexeme] = value;
      }
      items.add(item);
    }
    return items;
  }

  Object? _itemValue(Expression e) {
    var inner = e;
    var negate = false;
    if (inner is PrefixExpression && inner.operator.lexeme == '-') {
      negate = true;
      inner = inner.operand;
    }
    switch (inner) {
      case SimpleStringLiteral(:var value):
        return value;
      case IntegerLiteral(:var value?):
        return (negate ? -value : value).toDouble();
      case DoubleLiteral(:var value):
        return negate ? -value : value;
      default:
        refuse(
          e.offset,
          _kind(e),
          "an item's field is a string or a number literal",
        );
        return null;
    }
  }

  /// No comment survives an emit, so none may enter: a comment inside the
  /// class body is refused rather than silently shredded on the next save.
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
            'comments inside the scene are not preserved by the editor, so '
                'they are refused rather than silently lost on the next save',
          );
        }
      }
      if (token.offset >= end) break;
    }
  }

  SceneNode? _node(
    String name,
    Expression expr,
    Map<String, List<(String, int)>> childRefs,
  ) {
    var (kind, args) = _invocation(expr) ?? (null, null);
    if (kind == null || args == null) {
      refuse(
        expr.offset,
        'expression',
        'a node is a FrameNode, TextNode, ShapeNode or ExternalNode '
            'constructor call',
      );
      return null;
    }
    var positional = <Expression>[];
    var named = <String, Expression>{};
    for (var arg in args.arguments) {
      if (arg is NamedArgument) {
        named[arg.name.lexeme] = arg.argumentExpression;
      } else {
        positional.add(arg.argumentExpression);
      }
    }
    switch (kind) {
      case 'FrameNode.repeating':
        return _repeating(name, named, positional, args, childRefs);
      case 'FrameNode':
        var node = FrameNode(name: name);
        _applyProps(node, named);
        _readChildren(name, node, childRefs: childRefs, named: named);
        _refuseRest('FrameNode', named);
        _checkPositionals(positional, 0);
        return node;
      case 'TextNode' || 'TextNode.rich':
        var node = TextNode('', name: name);
        if (kind == 'TextNode.rich') {
          node.runs = _runsOf(positional, args);
        } else {
          node.text = _contentOf(positional, args, node) ?? '';
        }
        _take(named, styleBindingKey, (e) => _styleArgument(e, node));
        // A 0.8 file spelled its text properties beside the style. They are
        // still read here, so an old file opens and converges to the one
        // style argument on its next save.
        _applyProps(node, named, skip: const {'text'});
        _refuseRest(kind, named);
        _checkPositionals(positional, 1);
        return node;
      case 'ShapeNode':
        var node = ShapeNode(name: name);
        _applyProps(node, named);
        _refuseRest('ShapeNode', named);
        _checkPositionals(positional, 0);
        return node;
      case 'ExternalNode' || 'SceneRefNode':
        var read = _typedArgs(
          positional,
          args,
          kind == 'ExternalNode'
              ? 'an ExternalNode takes the generated arguments of the widget '
                    'it places: ExternalNode(const DrinkBadgeArgs(size: 140))'
              : 'a SceneRefNode takes the generated arguments of the scene it '
                    "instantiates: SceneRefNode(const PromoBadgeArgs(label: 'New'))",
        );
        var (target, nodeArgs, argRefs, tokensArg) =
            read ?? ('', <String, Object?>{}, <String, SceneBinding>{}, null);
        if (declaredArgs[target] case var declared?) {
          for (var name in nodeArgs.keys) {
            if (declared.contains(name)) continue;
            refuse(
              positional[0].offset,
              'unknown argument',
              '$target declares no "$name": it takes '
                  '${declared.isEmpty ? 'no arguments' : declared.join(', ')}',
            );
          }
        }
        if (tokensArg != null && kind == 'ExternalNode') {
          refuse(
            positional[0].offset,
            'tokens argument',
            'a widget takes no tokens set: a nested scene does',
          );
        }
        var node = kind == 'ExternalNode'
            ? ExternalNode.read(target, name: name, args: nodeArgs)
            : (SceneRefNode.read(target, name: name, args: nodeArgs)
                ..tokensArg = tokensArg);
        for (var e in argRefs.entries) {
          node.bindings['args.${e.key}'] = e.value;
        }
        _applyProps(node, named);
        _refuseRest(kind, named);
        _checkPositionals(positional, 1);
        return node;
      default:
        // A registered kind: its rows through the table, its children by
        // name like a frame's, its constructor's name from the descriptor.
        if (sceneKindByConstructor(kind) case var described?) {
          var node = KindNode(described, name: name);
          _applyProps(node, named);
          if (described.children) {
            _readChildren(name, node, childRefs: childRefs, named: named);
          }
          _refuseRest(described.constructor, named);
          _checkPositionals(positional, 0);
          return node;
        }
        refuse(
          expr.offset,
          'unknown node',
          '"$kind" is not a scene node: FrameNode, TextNode, ShapeNode, '
              'ExternalNode, SceneRefNode'
              '${[for (var k in sceneKinds) ', ${k.constructor}'].join()}',
        );
        return null;
    }
  }

  /// `children: [a, b]` — nodes placed by their field names, resolved once
  /// every field has been read. A frame's and a registered kind's alike.
  void _readChildren(
    String name,
    SceneNode node, {
    required Map<String, Expression> named,
    required Map<String, List<(String, int)>> childRefs,
  }) {
    _take(named, 'children', (e) {
      if (e is! ListLiteral) {
        refuse(e.offset, 'children', 'children takes a list literal');
        return;
      }
      // Inside a repeat's closure a cell IS written here: it has no one
      // row to be a field of. Everywhere else a child is placed by name.
      if (_itemScope != null) {
        node.children.addAll(_inlineCells(e, childRefs));
        return;
      }
      var refs = childRefs.putIfAbsent(name, () => []);
      for (var element in e.elements) {
        switch (element) {
          case SimpleIdentifier id when _params.containsKey(id.name):
            refuse(
              id.offset,
              'parameter as child',
              '"${id.name}" is a parameter: children list nodes',
            );
          case SimpleIdentifier id:
            refs.add((id.name, id.offset));
          case Expression x when _invocation(x) != null:
            refuse(
              element.offset,
              'inline node',
              'a node is declared as its own field and placed here by '
                  'name: `children: [headline]`, with '
                  '`late final headline = …` beside it',
            );
          case Expression x:
            refuse(
              x.offset,
              _kind(x),
              'children lists nodes by their field names',
            );
          default:
            refuse(
              element.offset,
              _elementKind(element),
              'a scene lists its children one by one: the editor cannot '
              'read a computed list',
            );
        }
      }
    });
  }

  /// `FrameNode.repeating(over: lines, row: (line) => [ … ], …)`.
  ///
  /// Read in one pass rather than routed through the plain frame reader,
  /// because the closure has to be OPEN while its cells are read — that is
  /// what makes `line.item` mean something there and nowhere else.
  SceneNode? _repeating(
    String name,
    Map<String, Expression> named,
    List<Expression> positional,
    ArgumentList args,
    Map<String, List<(String, int)>> childRefs,
  ) {
    var node = FrameNode(name: name);
    String? list;
    _take(named, 'over', (e) {
      if (e is! SimpleIdentifier) {
        refuse(e.offset, _kind(e), 'over names a list parameter');
        return;
      }
      var decl = _params[e.name];
      if (decl == null || decl.kind != SceneParamKind.list) {
        refuse(
          e.offset,
          'over',
          decl == null
              ? '"${e.name}" is not a parameter of this scene'
              : '"${e.name}" is a ${decl.typeName}: a repeat draws one row '
                    'per item of a list parameter',
        );
        return;
      }
      list = e.name;
    });
    if (list == null) {
      if (!named.containsKey('over')) {
        refuse(
          args.offset,
          'over',
          'a repeat says what it draws: `over: lines`',
        );
      }
      return null;
    }
    var rowArg = named.remove('row');
    if (rowArg == null) {
      refuse(
        args.offset,
        'row',
        'a repeat says how to draw one item: `row: (line) => [ … ]`',
      );
      return null;
    }
    if (rowArg is! FunctionExpression) {
      refuse(rowArg.offset, _kind(rowArg), 'row is `(line) => [ … ]`');
      return null;
    }
    var formals = rowArg.parameters?.parameters ?? const <FormalParameter>[];
    var item = formals.length == 1 ? formals.single.name : null;
    if (item == null) {
      refuse(
        rowArg.offset,
        'row',
        'row takes one parameter: the item it is drawing',
      );
      return null;
    }
    var body = rowArg.body;
    if (body is! ExpressionFunctionBody || body.expression is! ListLiteral) {
      refuse(
        rowArg.offset,
        'row',
        "row returns the row's cells: `(line) => [TextNode(line.item)]`",
      );
      return null;
    }
    var outer = _itemScope;
    _itemScope = (param: item.lexeme, list: list!);
    // Common properties are read INSIDE the scope too: a row's own fill or
    // border may read the item like any cell.
    _applyProps(node, named);
    node.children.addAll(
      _inlineCells(body.expression as ListLiteral, childRefs),
    );
    _itemScope = outer;
    _refuseRest('FrameNode.repeating', named);
    _checkPositionals(positional, 0);
    recordRepeat(node, list!);
    return node;
  }

  /// The cells of a repeated row, each written inline. Named from the
  /// sequence rather than from the file, because the file gives them none.
  List<SceneNode> _inlineCells(
    ListLiteral list,
    Map<String, List<(String, int)>> childRefs,
  ) {
    var out = <SceneNode>[];
    for (var element in list.elements) {
      if (element is! Expression) {
        refuse(
          element.offset,
          _elementKind(element),
          'a row lists its cells one by one',
        );
        continue;
      }
      if (element is SimpleIdentifier) {
        refuse(
          element.offset,
          'named cell',
          'a repeated row writes its cells inline: they are not fields, '
              'because there is no one row for them to belong to',
        );
        continue;
      }
      var cell = _node('cell${++_cellSeq}', element, childRefs);
      if (cell != null) out.add(cell);
    }
    return out;
  }

  void _checkPositionals(List<Expression> positional, int count) {
    if (positional.length > count) {
      refuse(
        positional[count].offset,
        'positional argument',
        'this node takes $count positional argument(s)',
      );
    }
  }

  /// Every table property [n] carries, taken off [named] by kind — a
  /// number, size, colour, string or bool may also be a parameter's name,
  /// which binds the property; a choice is `Type.member`; edges are one
  /// number or four named sides; sizes are a list. Whatever is left in
  /// [named] afterwards is not a property, and the caller refuses it.
  void _applyProps(
    SceneNode n,
    Map<String, Expression> named, {
    Set<String> skip = const {},
    Set<String>? only,
  }) {
    for (var p in scenePropsOf(n)) {
      // The file spells `text`, `style` and `args` itself.
      if (p.byHand) continue;
      if (skip.contains(p.name)) continue;
      if (only != null && !only.contains(p.name)) continue;
      switch (p.kind) {
        // Never reached: a byHand row is skipped above.
        case ScenePropKind.style:
        case ScenePropKind.args:
          break;
        case ScenePropKind.axes:
          _take(named, p.name, (e) {
            var axes = readSceneAxes(e, refuse);
            if (axes != null) p.write(n, axes);
          });
        case ScenePropKind.number:
          _take(named, p.name, (e) {
            var v = _doubleV(e, n, p.name);
            if (v != null) p.write(n, v);
          });
        case ScenePropKind.size:
          _take(named, p.name, (e) => p.write(n, _sizeV(e, n, p.name)));
        case ScenePropKind.color:
          _take(named, p.name, (e) {
            var v = _colorV(e, n, p.name);
            if (v != null || p.defaultValue == null) p.write(n, v);
          });
        case ScenePropKind.string:
          _take(named, p.name, (e) {
            var v = _stringV(e, n, p.name);
            if (v != null) p.write(n, v);
          });
        case ScenePropKind.boolean:
          _take(named, p.name, (e) {
            var v = _boolV(e, n, p.name);
            if (v != null) p.write(n, v);
          });
        case ScenePropKind.integer:
          _take(named, p.name, (e) {
            var v = _double(e);
            if (v != null) p.write(n, v.round());
          });
        case ScenePropKind.choice:
          _take(named, p.name, (e) {
            var v = _enum(e, p.choices!.typeName, p.choices!.names);
            if (v != null) p.write(n, p.choices!.valueOf(v));
          });
        case ScenePropKind.edges:
          _take(named, p.name, (e) {
            var v = _doubleV(e, n, p.name);
            if (v != null) p.write(n, p.quad!(v));
          });
          for (var (k, side) in p.sides!.indexed) {
            _take(named, side, (e) {
              var v = _doubleV(e, n, side);
              if (v == null) return;
              p.write(n, (p.read(n)! as SceneQuad).withSide(k, v));
            });
          }
        case ScenePropKind.layers:
          _take(named, p.name, (e) {
            var layers = readSceneLayers(e, refuse);
            if (layers != null) p.write(n, layers);
          });
        case ScenePropKind.sizes:
          _take(named, p.name, (e) {
            if (e is! ListLiteral) {
              refuse(
                e.offset,
                p.name,
                '${p.name} takes a list of sizes: '
                '[double.infinity, 48, null]',
              );
              return;
            }
            var tracks = <double?>[];
            for (var element in e.elements) {
              if (element is! Expression) {
                refuse(
                  element.offset,
                  _elementKind(element),
                  'a table names its columns one by one',
                );
                continue;
              }
              tracks.add(element is NullLiteral ? null : _size(element));
            }
            p.write(n, tracks);
          });
      }
    }
  }

  void _take(
    Map<String, Expression> named,
    String key,
    void Function(Expression) apply,
  ) {
    var e = named.remove(key);
    if (e != null) apply(e);
  }

  void _refuseRest(String node, Map<String, Expression> named) {
    for (var entry in named.entries) {
      refuse(
        entry.value.offset,
        'unknown property',
        '$node has no property "${entry.key}"',
      );
    }
  }

  String? _contentOf(
    List<Expression> positional,
    ArgumentList args,
    TextNode node,
  ) {
    if (positional.isEmpty) {
      refuse(
        args.offset,
        'missing argument',
        'a string literal is required here',
      );
      return null;
    }
    return _stringV(positional[0], node, 'text');
  }

  /// `[TextRun('Fresh '), TextRun('coffee', style: …)]` — the runs of one
  /// paragraph.
  ///
  /// A run's style is a DELTA, read through the same table and the same
  /// value readers as any other style literal, minus the paint stack: a
  /// stack paints a whole laid-out paragraph once per pass, and one that
  /// applied to a stretch of one would have to lay that stretch out alone.
  /// Refused with a line number rather than dropped.
  List<TextRun> _runsOf(List<Expression> positional, ArgumentList args) {
    if (positional.isEmpty) {
      refuse(args.offset, 'missing argument', 'a list of runs is required');
      return [];
    }
    var list = positional[0];
    if (list is! ListLiteral) {
      refuse(
        list.offset,
        _kind(list),
        "a rich text is a list of runs: TextNode.rich([TextRun('a'), …])",
      );
      return [];
    }
    var runs = <TextRun>[];
    for (var element in list.elements) {
      var call = element is Expression ? _invocation(element) : null;
      if (call == null || call.$1 != 'TextRun') {
        refuse(
          element.offset,
          _elementKind(element),
          "every element is a run: TextRun('a')",
        );
        continue;
      }
      if (_run(call.$2) case var run?) runs.add(run);
    }
    return runs;
  }

  TextRun? _run(ArgumentList args) {
    String? text;
    SceneTextStyle? style;
    for (var arg in args.arguments) {
      if (arg is NamedArgument) {
        if (arg.name.lexeme != 'style') {
          refuse(arg.offset, arg.name.lexeme, 'a run takes only a style');
          return null;
        }
        style = _runStyle(arg.argumentExpression);
        continue;
      }
      if (text != null) {
        refuse(arg.offset, 'extra argument', 'a run is one string');
        return null;
      }
      var value = arg.argumentExpression;
      if (value is SimpleStringLiteral) {
        text = value.value;
      } else {
        refuse(value.offset, _kind(value), "a run's text is a string literal");
        return null;
      }
    }
    if (text == null) {
      refuse(args.offset, 'missing argument', "a run's text is required");
      return null;
    }
    return TextRun(text, style: style);
  }

  SceneTextStyle? _runStyle(Expression e) {
    var call = _invocation(e);
    if (call == null || call.$1 != 'SceneTextStyle') {
      refuse(
        e.offset,
        'run style',
        "a run's style is its own delta: style: SceneTextStyle(weight: "
            'SceneFontWeight.w700)',
      );
      return null;
    }
    var probe = TextNode('', name: '');
    var named = <String, Expression>{};
    for (var arg in call.$2.arguments) {
      if (arg is! NamedArgument) {
        refuse(arg.offset, 'positional argument', 'a style takes named fields');
        return null;
      }
      if (arg.name.lexeme == 'layers') {
        refuse(
          arg.offset,
          'layers on a run',
          'a paint stack paints the whole paragraph, so it belongs on the '
              'text rather than on one stretch of it',
        );
        return null;
      }
      named[arg.name.lexeme] = arg.argumentExpression;
    }
    // Read the names before applying: `_applyProps` CONSUMES the map as it
    // takes each field.
    var set = named.keys.toSet();
    _applyProps(probe, named, only: _styleFieldNames);
    _refuseRest('SceneTextStyle', named);
    // Only what the run SAYS: the probe resolved every other field to the
    // table's default, and a delta that carried those would override the
    // node's on every one of them.
    return SceneTextStyle.fromValues({
      for (var p in sceneStyleProps)
        if (set.contains(p.name)) p.name: p.read(probe),
    });
  }

  /// `const DrinkBadgeArgs(size: 140)` — an external node's whole identity
  /// and arguments, as one typed constructor call.
  ///
  /// Three cheap things make it readable without resolving anything: the
  /// class name gives the entry (`…Args` stripped), the named arguments
  /// give the values, and the app's declaration of that widget — which the
  /// generator wrote this class from — gives their types. An argument the
  /// widget does not declare therefore fails twice: it does not compile,
  /// and it is refused here with a line number.
  /// The typed arguments a node is given, and which of them read one of
  /// this scene's parameters — `PromoBadgeArgs(label: title)` yields
  /// `title`'s default as the value and records the reference.
  (String, Map<String, Object?>, Map<String, SceneBinding>, String?)?
  _typedArgs(List<Expression> positional, ArgumentList args, String missing) {
    if (positional.isEmpty) {
      refuse(args.offset, 'missing argument', missing);
      return null;
    }
    var e = positional[0];
    var call = _invocation(e);
    if (call == null || !call.$1.endsWith('Args') || call.$1.length < 5) {
      refuse(e.offset, _kind(e), missing);
      return null;
    }
    var entry = call.$1.substring(0, call.$1.length - 'Args'.length);
    if (!isValidNodeName(entry)) {
      refuse(e.offset, call.$1, missing);
      return null;
    }
    var out = <String, Object?>{};
    var refs = <String, SceneBinding>{};
    String? tokensArg;
    for (var arg in call.$2.arguments) {
      if (arg is! NamedArgument) {
        refuse(
          arg.offset,
          _kind(arg.argumentExpression),
          'every argument is named: ${call.$1}(size: 140)',
        );
        continue;
      }
      var v = arg.argumentExpression;
      // The parent's whole set, handed to a nested scene under the child's
      // formal name: `PromoBadgeArgs(label: title, tokens: tokens)`.
      if (v is SimpleIdentifier &&
          _tokensFormal != null &&
          v.name == _tokensFormal) {
        tokensArg = arg.name.lexeme;
        continue;
      }
      var decl = v is SimpleIdentifier ? _params[v.name] : null;
      if (v is SimpleIdentifier && decl != null) {
        if (decl.kind == SceneParamKind.list) {
          refuse(v.offset, 'parameter type', 'a list cannot be an argument');
          continue;
        }
        out[arg.name.lexeme] = decl.defaultValue;
        refs[arg.name.lexeme] = ParamRef(v.name);
        continue;
      }
      if (v is PrefixedIdentifier && v.prefix.name == _tokensFormal) {
        var token = _tokens[v.identifier.name];
        if (token == null) {
          _refuseUnknownToken(v);
          continue;
        }
        // An export has no value here: the argument carries the NAME, and
        // the guest that compiled the declaration resolves it.
        out[arg.name.lexeme] = token.isExport
            ? tokenMarker(token.name)
            : token.value;
        refs[arg.name.lexeme] = TokenRef(token.name);
        continue;
      }
      out[arg.name.lexeme] = _literal(v);
    }
    return (entry, out, refs, tokensArg);
  }

  // -- value parsers, each refusing with the construct it actually found.
  // -- The V variants additionally accept a declared parameter's name,
  // -- binding the property to the typed hole and yielding its default.

  /// A parameter reference at a value position, or null when [e] is not
  /// one (the plain parser then runs). A declared parameter of the wrong
  /// kind is refused here, with both types named.
  Object? _paramRef(
    Expression e,
    SceneParamKind kind,
    SceneNode n,
    String prop,
  ) {
    if (e is PrefixedIdentifier) {
      return e.prefix.name == _tokensFormal
          ? _tokenRef(e, kind, n, prop)
          : _itemRef(e, kind, n, prop);
    }
    if (e is! SimpleIdentifier) return null;
    var decl = _params[e.name];
    if (decl == null) return null;
    if (decl.kind != kind) {
      var wanted = switch (kind) {
        SceneParamKind.string => 'String',
        SceneParamKind.number => 'double',
        SceneParamKind.color => 'SceneColor',
        SceneParamKind.bool => 'bool',
        SceneParamKind.list => 'List<Map<String, Object>>',
      };
      refuse(
        e.offset,
        'parameter type',
        '"${e.name}" is a ${decl.typeName} parameter: this property takes '
            'a $wanted',
      );
      return _refused;
    }
    n.bindings[prop] = ParamRef(e.name);
    return decl.defaultValue;
  }

  /// `lines.item` — one field of the item a repeat is drawing. The value
  /// it yields is the FIRST item's, which is what the file holds and what
  /// the editor shows; the rest are drawn as copies at render time.
  Object? _itemRef(
    PrefixedIdentifier e,
    SceneParamKind kind,
    SceneNode n,
    String prop,
  ) {
    var scope = _itemScope;
    if (scope == null || e.prefix.name != scope.param) return null;
    var decl = _params[scope.list];
    if (decl == null || decl.kind != SceneParamKind.list) return null;
    var field = e.identifier.name;
    var items = decl.items;
    if (items.isEmpty || !items.first.containsKey(field)) {
      refuse(
        e.offset,
        'unknown field',
        items.isEmpty
            ? '"${scope.list}" has no items, so there is no "$field" to read'
            : '"${scope.list}" items carry '
                  '${items.first.keys.map((k) => '"$k"').join(', ')}, '
                  'not "$field"',
      );
      return _refused;
    }
    var value = items.first[field]!;
    var converted = switch (kind) {
      // A number reads as the text it becomes, which is what a quantity in
      // a table cell is.
      SceneParamKind.string => value is String ? value : _num(value as double),
      SceneParamKind.number => value is double ? value : null,
      _ => null,
    };
    if (converted == null) {
      refuse(
        e.offset,
        'field type',
        '"${e.prefix.name}.$field" is a ${value is String ? 'string' : 'number'}'
            ': this property takes a '
            '${kind == SceneParamKind.number ? 'number' : 'value of another kind'}',
      );
      return _refused;
    }
    // Recorded against the LIST, not the closure's parameter: the parameter
    // is a local name and the binding has to outlive it.
    n.bindings[prop] = ItemRef(scope.list, field);
    return converted;
  }

  /// `tokens.brand` — one of the package's shared values, through the
  /// scene's tokens formal. Yields the declared value; the property is
  /// bound so the emitter writes the reference back.
  Object? _tokenRef(
    PrefixedIdentifier e,
    SceneParamKind kind,
    SceneNode n,
    String prop,
  ) {
    var decl = _tokens[e.identifier.name];
    if (decl == null) {
      _refuseUnknownToken(e);
      return _refused;
    }
    if (decl.isOpaque) {
      refuse(
        e.offset,
        'token type',
        '"${e.identifier.name}" is a ${decl.typeName}: the app\'s own '
            "object, which only an external widget's argument can take",
      );
      return _refused;
    }
    if (decl.kind != kind) {
      refuse(
        e.offset,
        'token type',
        '"${e.identifier.name}" is a ${decl.typeName} token: this property '
            'takes a ${SceneTokenDecl('', kind, '').typeName}',
      );
      return _refused;
    }
    n.bindings[prop] = TokenRef(decl.name);
    // An export: the binding is the whole of it. The property keeps a
    // stand-in of its kind; the guest draws the app's own value over it.
    if (decl.isExport) return getSceneProperty(n, prop) ?? _standIn(kind);
    return decl.value;
  }

  static Object _standIn(SceneParamKind kind) => switch (kind) {
    SceneParamKind.color => const SceneColor(0x00000000),
    SceneParamKind.number => 0.0,
    SceneParamKind.string => '',
    SceneParamKind.bool => false,
    SceneParamKind.list => const <Object?>[],
  };

  /// A text node's one style argument, in its three spellings: the shared
  /// style whole (`tokens.title`), the shared style with a delta over it
  /// (`tokens.title.copyWith(fontSize: 60)`), and a node's own type with
  /// nothing shared (`SceneTextStyle(fontSize: 180)`).
  ///
  /// A delta is read exactly like a node's own arguments used to be, through
  /// the same table and the same value readers — so a property inside
  /// `copyWith` may still name a parameter, and binds.
  void _styleArgument(Expression e, TextNode n) {
    switch (e) {
      case MethodInvocation(:var methodName, :var target?, :var argumentList)
          when methodName.name == 'copyWith':
        _styleRef(target, n);
        _styleFields(argumentList, n, 'copyWith');
      case InstanceCreationExpression(:var constructorName, :var argumentList)
          when constructorName.type.name.lexeme == 'SceneTextStyle':
        _styleFields(argumentList, n, 'SceneTextStyle');
      case MethodInvocation(:var methodName, target: null, :var argumentList)
          when methodName.name == 'SceneTextStyle':
        _styleFields(argumentList, n, 'SceneTextStyle');
      default:
        _styleRef(e, n);
    }
  }

  /// The named arguments of a style literal or a `copyWith`, onto [n].
  void _styleFields(ArgumentList args, TextNode n, String what) {
    var named = <String, Expression>{};
    for (var arg in args.arguments) {
      if (arg is NamedArgument) {
        named[arg.name.lexeme] = arg.argumentExpression;
      } else {
        refuse(
          arg.offset,
          'positional argument',
          '$what takes named properties only',
        );
      }
    }
    _applyProps(n, named, only: _styleFieldNames);
    _refuseRest(what, named);
  }

  /// `style: tokens.title` — a shared text style, applied whole: every
  /// property it sets lands on the node, and a delta beside it overrides.
  void _styleRef(Expression e, TextNode n) {
    if (e is! PrefixedIdentifier || e.prefix.name != _tokensFormal) {
      refuse(
        e.offset,
        styleBindingKey,
        "a text's style is a shared token (style: tokens.title), that token "
        'with a delta over it (style: tokens.title.copyWith(fontSize: '
        '60)), or its own (style: SceneTextStyle(fontSize: 60))',
      );
      return;
    }
    var decl = _tokens[e.identifier.name];
    if (decl == null) {
      _refuseUnknownToken(e);
      return;
    }
    if (!decl.isStyle) {
      refuse(
        e.offset,
        'token type',
        '"${e.identifier.name}" is a ${decl.typeName}: a style is a '
            'SceneTextStyle token, or a TextStyle the app exports',
      );
      return;
    }
    n.bindings[styleBindingKey] = StyleRef(decl.name);
    // An export's style is laid under the node's values by the guest; the
    // file spells only what the node sets itself.
    if (decl.style case var style?) writeStyle(n, style);
  }

  void _refuseUnknownToken(PrefixedIdentifier e) {
    refuse(
      e.identifier.offset,
      'unknown token',
      "no library of this scene's group declares "
          '"${e.identifier.name}"; they have '
          '${_tokens.keys.map((k) => '"$k"').join(', ')}',
    );
  }

  static final _refused = Object();

  /// A size: `double.infinity` for fill, otherwise a number or a parameter.
  double? _sizeV(Expression e, SceneNode n, String prop) {
    if (_infinity(e)) return double.infinity;
    return _doubleV(e, n, prop);
  }

  /// A size with no property behind it — a table's column track, which
  /// belongs to the frame rather than to any one node.
  double? _size(Expression e) => _infinity(e) ? double.infinity : _double(e);

  bool _infinity(Expression e) =>
      e is PrefixedIdentifier &&
      e.prefix.name == 'double' &&
      e.identifier.name == 'infinity';

  double? _doubleV(Expression e, SceneNode n, String prop) {
    var v = _paramRef(e, SceneParamKind.number, n, prop);
    if (identical(v, _refused)) return null;
    if (v != null) return v as double;
    return _double(e);
  }

  bool? _boolV(Expression e, SceneNode n, String prop) {
    var v = _paramRef(e, SceneParamKind.bool, n, prop);
    if (identical(v, _refused)) return null;
    if (v != null) return v as bool;
    return _bool(e);
  }

  String? _stringV(Expression e, SceneNode n, String prop) {
    var v = _paramRef(e, SceneParamKind.string, n, prop);
    if (identical(v, _refused)) return null;
    if (v != null) return v as String;
    return _string(e);
  }

  SceneColor? _colorV(Expression e, SceneNode n, String prop) {
    var v = _paramRef(e, SceneParamKind.color, n, prop);
    if (identical(v, _refused)) return null;
    if (v != null) return v as SceneColor;
    return _colorOf(e);
  }

  (String, ArgumentList)? _invocation(Expression e) => switch (e) {
    MethodInvocation(:var methodName, :var target, :var argumentList)
        when target == null =>
      (methodName.name, argumentList),
    // `FrameNode.repeating(…)` — a static, because the rule it takes is
    // generic in the item type and a constructor cannot be.
    MethodInvocation(
      :var methodName,
      target: SimpleIdentifier t,
      :var argumentList,
    ) =>
      ('${t.name}.${methodName.name}', argumentList),
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

  String? _string(Expression e) {
    if (e is SimpleStringLiteral) return e.value;
    refuse(
      e.offset,
      _kind(e),
      'expected a single string literal: the editor cannot evaluate '
      '${_kind(e) == 'interpolation' ? 'an interpolation' : 'this'}',
    );
    return null;
  }

  bool? _bool(Expression e) {
    if (e is BooleanLiteral) return e.value;
    refuse(e.offset, _kind(e), 'expected true or false');
    return null;
  }

  SceneColor? _colorOf(Expression e) {
    if (_invocation(e) case ('SceneColor', var args)
        when args.arguments.length == 1) {
      var v = args.arguments.single.argumentExpression;
      if (v is IntegerLiteral && v.value != null) return SceneColor(v.value!);
    }
    refuse(
      e.offset,
      _kind(e),
      'expected a color, spelled SceneColor(0xAARRGGBB)',
    );
    return null;
  }

  String? _enum(Expression e, String prefix, Iterable<String> values) {
    if (e is PrefixedIdentifier &&
        e.prefix.name == prefix &&
        values.contains(e.identifier.name)) {
      return e.identifier.name;
    }
    refuse(
      e.offset,
      _kind(e),
      'expected $prefix.<${values.take(4).join('|')}…>: nothing else is '
      'on the allowlist',
    );
    return null;
  }

  Object? _literal(Expression e) {
    var inner = e;
    var negate = false;
    if (e is PrefixExpression && e.operator.lexeme == '-') {
      negate = true;
      inner = e.operand;
    }
    return switch (inner) {
      IntegerLiteral(:var value) =>
        value == null ? null : (negate ? -value : value),
      DoubleLiteral(:var value) => negate ? -value : value,
      BooleanLiteral(:var value) => value,
      SimpleStringLiteral(:var value) => value,
      _ when _invocation(inner)?.$1 == 'SceneColor' => _colorOf(inner),
      _ => () {
        refuse(
          e.offset,
          _kind(e),
          'expected a number, string, bool or SceneColor(0x…) literal',
        );
        return null;
      }(),
    };
  }

  /// Names what the hand actually wrote, so the refusal teaches.
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

  String _elementKind(CollectionElement e) => switch (e) {
    ForElement() => 'for element',
    IfElement() => 'if element',
    SpreadElement() => 'spread',
    _ => e.runtimeType.toString(),
  };
}
