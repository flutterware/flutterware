// The app's declaration of the values its scenes share, read without
// resolving anything.
//
// The same shape as the externals file, for the same reason: the editor
// never compiles the app, so a token's name, type and value are told to it
// here, in one list the app writes once — and everything downstream follows.
// The generated `SceneTokens` class a scene file spells `tokens.brand`
// against, the value the canvas renders for it, the picker the inspector
// offers, and the refusal for a token nobody declared.
//
// The tool only ever READS this file. That is what makes a token different
// from a parameter: a parameter's default moves when a bound property is
// edited, because the file is the tool's; a token is shared by every scene
// of the package and written by hand, so a property edited off its token
// detaches instead.
//
// A token typed anything but the four value types is OPAQUE: the editor
// records its name and its type and never its value — `Token<ButtonStyle>
// ('cta', FilledButton.styleFrom(…))` is the app's object, reachable only
// by an external widget's argument, and only the app that compiled this
// file can hand it over. The file's own imports are kept for the generated
// class, which has to spell `ButtonStyle` too.
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutterware/scene_authoring.dart';

import 'paint_grammar.dart';

import 'group_file.dart';
import 'scene_file.dart';

/// The symbol a library's list is called when nothing derives one — the
/// default for a source parsed without a file name (a test, a demo).
const sceneTokensSymbol = 'sceneTokens';

/// The symbol a library once declared its modes with — `brandTokens` →
/// `brandTokensModes`. Modes are gone; the name is kept so a file that
/// still carries one is refused by name rather than read as a stray
/// declaration.
String modesSymbolFor(String symbol) => '${symbol}Modes';

/// The kinds a LIBRARY may declare. A library is a design system — the
/// colours, the sizes and the type styles a package's scenes share — and
/// decided 2026-09-09, that is the whole of it.
///
/// A `String` or a `bool` is not a design decision. Shared copy is content:
/// a scene parameter when one scene uses it, the app's when several do. A
/// flag is configuration. Both were only ever here because a token reused
/// the *parameter* kinds, and because a design tool's variables have STRING
/// and BOOLEAN types — neither of which is a reason.
///
/// An EXPORT is unaffected: it is the app's own value of any type at all,
/// and the editor never draws it.
const libraryTokenKinds = {SceneParamKind.color, SceneParamKind.number};

/// Those two in the order the library's page lays them out and its file is
/// written in: the palette first, then the scale, then — outside this list,
/// because a style is not a kind — the type.
const libraryTokenOrder = [SceneParamKind.color, SceneParamKind.number];

/// The type a declaration spells for [kind], for a refusal that names it.
String paramKindTypeName(SceneParamKind kind) => switch (kind) {
  SceneParamKind.string => 'String',
  SceneParamKind.number => 'double',
  SceneParamKind.color => 'SceneColor',
  SceneParamKind.bool => 'bool',
  SceneParamKind.list => 'List',
};

/// What a library carrying a value it may not hold is told.
String notADesignValue(String typeName) =>
    'a library holds a design system: a colour, a number or a text style. '
    "A $typeName is content or configuration: make it this scene's "
    "parameter, or export it from the group's $sceneGroupFileName as the "
    "app's own.";

/// What a file carrying a removed mode declaration is told. A set that
/// differs is a `SceneTokens` the app constructs and passes to a scene's
/// tokens formal — the editor no longer holds one.
const modesRemovedReason =
    'modes are gone from a library: build the other set in your app as '
    'SceneTokens(…) and pass it to the scene, which the generated class '
    'already takes';

/// What a library file ends with: `brand.tokens.dart`.
const sceneTokensFileSuffix = '.tokens.dart';

/// The first line of a library file — how discovery tells one from any
/// other Dart file, the way a scene file declares itself.
const sceneTokensFileMarker = '//@flutterware:tokens=1';

/// Whether [source] is a library file: the marker is on its first line.
bool isTokensFile(String source) {
  var end = source.indexOf('\n');
  var first = end < 0 ? source : source.substring(0, end);
  return first.contains('@flutterware:tokens');
}

/// The list symbol a library file declares, from its name:
/// `brand.tokens.dart` → `brandTokens`, `store_front.tokens.dart` →
/// `storeFrontTokens`. Derived rather than declared so a group can name the
/// library it imports and the tool can check the name without resolving.
String tokensSymbolFor(String path) {
  var base = path.replaceAll(r'\', '/');
  base = base.substring(base.lastIndexOf('/') + 1);
  if (base.endsWith(sceneTokensFileSuffix)) {
    base = base.substring(0, base.length - sceneTokensFileSuffix.length);
  } else if (base.endsWith('.dart')) {
    base = base.substring(0, base.length - '.dart'.length);
  }
  var parts = base.split(RegExp('[^A-Za-z0-9]+')).where((s) => s.isNotEmpty);
  var camel = StringBuffer();
  for (var (i, part) in parts.indexed) {
    camel.write(i == 0 ? part : part[0].toUpperCase() + part.substring(1));
  }
  var name = '$camel';
  if (name.isEmpty || RegExp('^[0-9]').hasMatch(name)) name = 'lib$name';
  return '${name}Tokens';
}

/// A library file's name from a library name the user typed: `Brand` →
/// `brand.tokens.dart`, `Store front` → `store_front.tokens.dart`.
String tokensFileNameFor(String libraryName) {
  var snake = libraryName
      .trim()
      .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .replaceAll(RegExp('[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '')
      .toLowerCase();
  return '${snake.isEmpty ? 'tokens' : snake}$sceneTokensFileSuffix';
}

/// What the generated class is called, and therefore the TYPE a scene's
/// tokens formal is recognised by: `class Banner({final SceneTokens tokens =
/// const SceneTokens()})`. The formal's name is the author's own.
const sceneTokensClassName = 'SceneTokens';

/// What a read of a declaration file produced.
class TokensParse {
  TokensParse(this.tokens, this.refusals, [this.imports = const []]);

  final List<SceneTokenDecl> tokens;
  final List<SceneRefusal> refusals;

  /// The file's imports other than the authoring one, verbatim — what an
  /// opaque token's type is spelled with, so the generated class imports the
  /// same.
  final List<String> imports;

  bool get ok => refusals.isEmpty;
}

/// The same declarations, as the tool describes them — for a demo or a test
/// that already holds the real objects.
List<SceneTokenDecl> describeTokens(List<Token<Object>> tokens) => [
  for (var t in tokens)
    if (t.value case SceneTextStyle style)
      SceneTokenDecl.style(t.name, style)
    else
      SceneTokenDecl(t.name, switch (t.value) {
        String() => SceneParamKind.string,
        bool() => SceneParamKind.bool,
        SceneColor() => SceneParamKind.color,
        num() => SceneParamKind.number,
        var v => throw ArgumentError(
          'a token is a String, double, bool or SceneColor: '
          '"${t.name}" is a ${v.runtimeType}',
        ),
      }, _number(t.value)),
];

Object _number(Object v) => v is num ? v.toDouble() : v;

/// The kinds a token may have, by the type argument the declaration spells.
const _tokenKinds = {
  'double': SceneParamKind.number,
  'String': SceneParamKind.string,
  'bool': SceneParamKind.bool,
  'SceneColor': SceneParamKind.color,
};

/// Reads `final brandTokens = [Token<SceneColor>('brand', SceneColor(…)), …]`
/// — [symbol] being the list's name, derived from the file's own name by
/// [tokensSymbolFor].
///
/// Everything outside that shape is refused with a line number rather than
/// skipped, the externals rule: a token silently half-read is a scene that
/// silently loses a colour.
TokensParse parseTokensFile(
  String source, {
  String symbol = sceneTokensSymbol,
}) {
  var sceneTokensSymbol = symbol;
  var refusals = <SceneRefusal>[];
  var lines = source.split('\n');
  void refuse(int offset, String construct, String message) {
    var line = 1;
    var seen = 0;
    for (var l in lines) {
      if (offset <= seen + l.length) break;
      seen += l.length + 1;
      line++;
    }
    refusals.add(SceneRefusal(offset, line, construct, message));
  }

  var result = parseString(content: source, throwIfDiagnostics: false);
  for (var error in result.errors) {
    refuse(error.offset, 'syntax error', error.message);
  }
  if (refusals.isNotEmpty) return TokensParse(const [], refusals);
  var imports = declarationImports(result.unit, source);

  ListLiteral? list;
  for (var decl in result.unit.declarations) {
    if (decl is! TopLevelVariableDeclaration) continue;
    for (var v in decl.variables.variables) {
      if (v.name.lexeme == modesSymbolFor(sceneTokensSymbol)) {
        refuse(v.offset, 'declaration', modesRemovedReason);
        continue;
      }
      if (v.name.lexeme != sceneTokensSymbol) continue;
      if (v.initializer case ListLiteral l) {
        list = l;
      } else {
        refuse(
          v.offset,
          'declaration',
          '$sceneTokensSymbol is a list literal of Token<…>(…)',
        );
      }
    }
  }
  if (list == null) {
    if (refusals.isEmpty) {
      refuse(
        0,
        'no declarations',
        'a token file holds `final $sceneTokensSymbol = '
            "[Token<SceneColor>('brand', SceneColor(0xFF…)), …]`",
      );
    }
    return TokensParse(const [], refusals);
  }

  return TokensParse(parseTokenElements(list, refuse), refusals, imports);
}

/// The `Token<…>(…)` elements of one list literal — a library's list, or,
/// with [exports], the `exports:` of a group declaration. A name declared
/// twice in the same list is refused.
///
/// A library holds VALUES: literals of the four kinds and text styles,
/// which the editor draws and compares against. An export is the app's
/// own — a name and a type, the expression never read — so there the type
/// argument is all that is recorded, and any type is welcome.
List<SceneTokenDecl> parseTokenElements(
  ListLiteral list,
  void Function(int offset, String construct, String message) refuse, {
  bool exports = false,
}) {
  var tokens = <SceneTokenDecl>[];
  var names = <String>{};
  for (var element in list.elements) {
    if (element is! Expression) {
      refuse(element.offset, 'element', 'expected a Token<…>(…)');
      continue;
    }
    var decl = _token(element, refuse, exports: exports);
    if (decl == null) continue;
    if (!names.add(decl.name)) {
      refuse(
        element.offset,
        'duplicate name',
        '"${decl.name}" is declared twice',
      );
      continue;
    }
    tokens.add(decl);
  }
  return tokens;
}

/// A declaration file's imports other than the authoring one, as written.
List<String> declarationImports(CompilationUnit unit, String source) => [
  for (var d in unit.directives)
    if (d is ImportDirective && d.uri.stringValue != sceneAuthoringUri)
      source.substring(d.offset, d.end),
];

SceneTokenDecl? _token(
  Expression e,
  void Function(int, String, String) refuse, {
  bool exports = false,
}) {
  String? typeName;
  ArgumentList? args;
  switch (e) {
    case InstanceCreationExpression(:var constructorName, :var argumentList)
        when constructorName.type.name.lexeme == 'Token':
      typeName = _typeArgument(constructorName.type.typeArguments);
      args = argumentList;
    case MethodInvocation(
          :var methodName,
          :var typeArguments,
          :var argumentList,
        )
        when methodName.name == 'Token':
      typeName = _typeArgument(typeArguments);
      args = argumentList;
    default:
  }
  if (args == null) {
    refuse(e.offset, 'element', 'expected a Token<…>(…)');
    return null;
  }
  if (typeName == null) {
    refuse(
      e.offset,
      'token type',
      'a token is typed by its type argument: '
          "Token<SceneColor>('brand', SceneColor(0xFF…)) for a value the "
          "editor renders, Token<ButtonStyle>('cta', …) for one it only names",
    );
    return null;
  }
  var positional = [
    for (var a in args.arguments)
      if (a is! NamedArgument) a,
  ];
  var named = [
    for (var a in args.arguments)
      if (a is NamedArgument) a,
  ];
  if (positional.length != 2) {
    refuse(
      e.offset,
      'arguments',
      "a token is Token<double>('radius', 16): a name and its value",
    );
    return null;
  }
  if (named.isNotEmpty) {
    refuse(
      named.first.offset,
      named.first.name.lexeme == 'modes' ? 'modes' : 'arguments',
      named.first.name.lexeme == 'modes'
          ? modesRemovedReason
          : "a token is Token<double>('radius', 16): a name and its value",
    );
    return null;
  }
  var nameArg = positional[0].argumentExpression;
  if (nameArg is! SimpleStringLiteral || !isValidNodeName(nameArg.value)) {
    refuse(nameArg.offset, 'token name', 'a token name is an identifier');
    return null;
  }
  if (exports) return SceneTokenDecl.export(nameArg.value, typeName);
  var kind = _tokenKinds[typeName];
  // A text style: a bundle the editor renders, applied whole to a text.
  if (typeName == 'SceneTextStyle') {
    var style = _style(positional[1].argumentExpression, refuse);
    if (style == null) return null;
    return SceneTokenDecl.style(nameArg.value, style);
  }
  // Not a value type: the app's own object, which a library cannot hold —
  // the editor writes a library, and it cannot write what it cannot see.
  if (kind == null) {
    refuse(
      e.offset,
      'token type',
      "a $typeName is the app's own: a library holds values the editor "
          "draws; export it from the group's $sceneGroupFileName instead",
    );
    return null;
  }
  // A value type the editor draws, but not a design one.
  if (!libraryTokenKinds.contains(kind)) {
    refuse(e.offset, 'token type', notADesignValue(typeName));
    return null;
  }
  var value = _value(positional[1].argumentExpression, kind);
  if (value == null) {
    refuse(
      positional[1].offset,
      'token value',
      "a $typeName token's value is a $typeName literal",
    );
    return null;
  }
  return SceneTokenDecl(nameArg.value, kind, value);
}

Object? _value(Expression e, SceneParamKind kind) {
  var inner = e;
  var negate = false;
  if (inner is PrefixExpression && inner.operator.lexeme == '-') {
    negate = true;
    inner = inner.operand;
  }
  switch ((kind, inner)) {
    case (SceneParamKind.string, SimpleStringLiteral(:var value)):
      return value;
    case (SceneParamKind.bool, BooleanLiteral(:var value)):
      return value;
    case (SceneParamKind.number, IntegerLiteral(:var value?)):
      return (negate ? -value : value).toDouble();
    case (SceneParamKind.number, DoubleLiteral(:var value)):
      return negate ? -value : value;
    case (SceneParamKind.color, _):
      ArgumentList? args;
      switch (inner) {
        case InstanceCreationExpression(:var constructorName, :var argumentList)
            when constructorName.type.name.lexeme == 'SceneColor':
          args = argumentList;
        case MethodInvocation(:var methodName, :var argumentList)
            when methodName.name == 'SceneColor':
          args = argumentList;
        default:
      }
      if (args != null && args.arguments.length == 1) {
        if (args.arguments.single.argumentExpression case IntegerLiteral(
          :var value?,
        )) {
          return SceneColor(value);
        }
      }
      return null;
    default:
      return null;
  }
}

/// `SceneTextStyle(fontFamily: 'Recursive', fontSize: 54, weight:
/// SceneFontWeight.w700, letterSpacing: -2, color: SceneColor(0xFF…))` —
/// each field a literal of its kind, any of them absent.
///
/// Read by the property table's text subset, so a property added there is
/// accepted here without this function naming it.
SceneTextStyle? _style(
  Expression e,
  void Function(int, String, String) refuse,
) {
  ArgumentList? args;
  switch (e) {
    case InstanceCreationExpression(:var constructorName, :var argumentList)
        when constructorName.type.name.lexeme == 'SceneTextStyle':
      args = argumentList;
    case MethodInvocation(:var methodName, :var argumentList)
        when methodName.name == 'SceneTextStyle':
      args = argumentList;
    default:
  }
  if (args == null) {
    refuse(e.offset, 'token value', 'a style is SceneTextStyle(fontSize: …)');
    return null;
  }
  var fields = {for (var p in sceneTextProps) p.name: p}..remove('text');
  var values = <String, Object?>{};
  for (var arg in args.arguments) {
    if (arg is! NamedArgument) {
      refuse(arg.offset, 'style', 'a style names each field: fontSize: 54');
      return null;
    }
    var v = arg.argumentExpression;
    var name = arg.name.lexeme;
    var read = switch (fields[name]) {
      var p? => _styleField(p, v, refuse),
      null => null,
    };
    if (read == null) {
      refuse(
        v.offset,
        'style',
        'a style sets ${fields.keys.join(', ')}: "$name" is not one of '
            'them, or not a literal of its kind',
      );
      return null;
    }
    values[name] = read;
  }
  return SceneTextStyle.fromValues(values);
}

/// One field of a style literal, by the kind the table gives it. A choice is
/// `Type.member` — the file's own spelling, checked against the type the
/// table names.
Object? _styleField(SceneProp p, Expression v, Refuse refuse) =>
    switch (p.kind) {
      ScenePropKind.style || ScenePropKind.args => null,
      ScenePropKind.axes => readSceneAxes(v, refuse),
      ScenePropKind.number => _value(v, SceneParamKind.number),
      ScenePropKind.integer => switch (_value(v, SceneParamKind.number)) {
        double d => d.round(),
        _ => null,
      },
      ScenePropKind.string => _value(v, SceneParamKind.string),
      ScenePropKind.boolean => _value(v, SceneParamKind.bool),
      ScenePropKind.color => _value(v, SceneParamKind.color),
      ScenePropKind.choice => switch (v) {
        PrefixedIdentifier(:var prefix, :var identifier)
            when prefix.name == p.choices!.typeName =>
          p.choices!.valueOf(identifier.name),
        _ => null,
      },
      ScenePropKind.layers => readSceneLayers(v, refuse),
      ScenePropKind.size || ScenePropKind.sizes || ScenePropKind.edges => null,
    };

String? _typeArgument(TypeArgumentList? types) =>
    types != null && types.arguments.length == 1
    ? types.arguments.single.toSource()
    : null;
