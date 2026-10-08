// The app's declaration of the widgets a scene may place, read without
// resolving anything.
//
// This file is the tool's stand-in for the analyzer. Resolving the app
// package to learn that `DrinkBadge` takes a `double size` costs a full
// element model; declaring it costs one list the app writes once. What the
// declaration buys is everything downstream: the generated arguments class
// a scene file spells, the types the inspector shows, and the refusal for
// an argument the widget does not have.
//
// The tool only ever READS this file — it is the author's own code, with
// the one closure in the system in it — so there is no emit half and no
// opaque span to preserve.
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutterware/scene_authoring.dart';

import 'scene_file.dart';
import 'tokens_file.dart';

/// The symbol the declaration list must be called. One name, so nothing has
/// to be configured and a file either declares scene externals or does not.
const sceneExternalsSymbol = 'sceneExternals';

/// One argument of one declared widget, as written.
class ExternalArgDecl {
  ExternalArgDecl(this.name, this.typeName, this.defaultSource);

  final String name;

  /// `double`, `String`, `bool` or `SceneColor` — the type argument on
  /// `Arg<…>`, which is also what survives to runtime as `Arg.type`.
  final String typeName;

  /// The fallback, as source text, or null when the declaration gave none.
  /// Source text rather than a value because it goes straight back out as
  /// the generated field's default.
  final String? defaultSource;
}

/// One `ExternalWidget(…)` from the declaration list.
class ExternalWidgetDecl {
  ExternalWidgetDecl(this.entry, this.args);

  final String entry;
  final List<ExternalArgDecl> args;
}

/// What a read of a declaration file produced.
class ExternalsParse {
  ExternalsParse(this.widgets, this.refusals, [this.imports = const []]);

  final List<ExternalWidgetDecl> widgets;
  final List<SceneRefusal> refusals;

  /// The file's imports other than the authoring one, verbatim — what an
  /// opaque argument's type is spelled with, so the generated class can
  /// spell it too.
  final List<String> imports;

  bool get ok => refusals.isEmpty;
}

/// The same declarations, as the tool describes them.
///
/// The editor reads a declaration file as TEXT — it never compiles the app —
/// so a default reaches it as source. Anything that already holds the real
/// objects (a demo, a test) comes through here instead of writing the text
/// out just to have it read back.
List<ExternalWidgetDecl> describeExternals(List<ExternalWidget> widgets) => [
  for (var w in widgets)
    ExternalWidgetDecl(w.entry, [
      for (var a in w.args)
        ExternalArgDecl(a.name, '${a.type}', switch (a.fallback) {
          null => null,
          String s => "'$s'",
          var v => '$v',
        }),
    ]),
];

/// The VALUE types an argument may take — the four a [SceneArgs] reader
/// answers for, since a generated `merge` is written in terms of them. Any
/// other type is an OPAQUE argument: the app's own object, which a scene can
/// only fill with an opaque token of that type (`style: tokens.cta`), and
/// which the widget reads back with [SceneArgs.raw].
const externalArgTypes = {'double', 'String', 'bool', 'SceneColor'};

/// Whether a declared type is one the editor holds a value of.
bool isValueArgType(String typeName) => externalArgTypes.contains(typeName);

/// Reads `final sceneExternals = [ExternalWidget(…), …]`.
///
/// Everything outside that shape is refused with a line number rather than
/// skipped: a declaration silently half-read is a scene file that silently
/// loses an argument.
ExternalsParse parseExternalsFile(String source) {
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
  if (refusals.isNotEmpty) return ExternalsParse(const [], refusals);
  var unit = result;
  var imports = declarationImports(unit.unit, source);

  ListLiteral? list;
  for (var decl in unit.unit.declarations) {
    if (decl is! TopLevelVariableDeclaration) continue;
    for (var v in decl.variables.variables) {
      if (v.name.lexeme != sceneExternalsSymbol) continue;
      if (v.initializer case ListLiteral l) {
        list = l;
      } else {
        refuse(
          v.offset,
          'declaration',
          '$sceneExternalsSymbol is a list literal of ExternalWidget(…)',
        );
      }
    }
  }
  if (list == null) {
    if (refusals.isEmpty) {
      refuse(
        0,
        'no declarations',
        'a declaration file holds `final $sceneExternalsSymbol = '
            '[ExternalWidget(…), …]`',
      );
    }
    return ExternalsParse(const [], refusals);
  }

  return ExternalsParse(
    parseExternalWidgetElements(list, refuse),
    refusals,
    imports,
  );
}

/// The `ExternalWidget(…)` elements of one list literal — the `widgets:`
/// of a group declaration, or the whole list of a legacy externals file.
List<ExternalWidgetDecl> parseExternalWidgetElements(
  ListLiteral list,
  void Function(int offset, String construct, String message) refuse,
) {
  var widgets = <ExternalWidgetDecl>[];
  for (var element in list.elements) {
    if (element is! Expression) {
      refuse(element.offset, 'element', 'expected an ExternalWidget(…)');
      continue;
    }
    var call = _invocation(element);
    if (call == null || call.$1 != 'ExternalWidget') {
      refuse(element.offset, 'element', 'expected an ExternalWidget(…)');
      continue;
    }
    String? entry;
    var args = <ExternalArgDecl>[];
    for (var arg in call.$2.arguments) {
      if (arg is NamedArgument) {
        if (arg.name.lexeme == 'build') continue;
        if (arg.name.lexeme != 'args') {
          refuse(
            arg.offset,
            'unknown property',
            'an ExternalWidget takes args: and build:',
          );
          continue;
        }
        if (arg.argumentExpression case ListLiteral items) {
          for (var item in items.elements) {
            if (item is Expression) {
              var decl = _arg(item, refuse);
              if (decl != null) args.add(decl);
            } else {
              refuse(item.offset, 'element', 'expected an Arg<…>(…)');
            }
          }
        } else {
          refuse(arg.offset, 'args', 'args takes a list of Arg<…>(…)');
        }
        continue;
      }
      if (arg.argumentExpression case SimpleStringLiteral s
          when entry == null) {
        if (isValidNodeName(s.value)) {
          entry = s.value;
        } else {
          refuse(s.offset, 'entry', '"${s.value}" is not an entry name');
        }
        continue;
      }
      refuse(
        arg.offset,
        'argument',
        "an ExternalWidget names its entry first: ExternalWidget('DrinkBadge', …)",
      );
    }
    if (entry == null) {
      refuse(
        element.offset,
        'missing argument',
        "an ExternalWidget names its entry first: ExternalWidget('DrinkBadge', …)",
      );
      continue;
    }
    widgets.add(ExternalWidgetDecl(entry, args));
  }
  return widgets;
}

ExternalArgDecl? _arg(Expression e, void Function(int, String, String) refuse) {
  String? typeName;
  ArgumentList? args;
  switch (e) {
    case InstanceCreationExpression(:var constructorName, :var argumentList):
      typeName = _typeArgument(constructorName.type.typeArguments);
      args = argumentList;
    case MethodInvocation(
          :var methodName,
          :var typeArguments,
          :var argumentList,
        )
        when methodName.name == 'Arg':
      typeName = _typeArgument(typeArguments);
      args = argumentList;
    default:
  }
  if (args == null) {
    refuse(e.offset, 'element', 'expected an Arg<…>(…)');
    return null;
  }
  if (typeName == null) {
    refuse(
      e.offset,
      'argument type',
      'an argument is typed by its type argument: '
          "Arg<double>('size', 56); one of ${externalArgTypes.join(', ')}, "
          "or the app's own type for an argument only a token can fill",
    );
    return null;
  }
  String? name;
  String? fallback;
  for (var arg in args.arguments) {
    if (arg is NamedArgument) {
      refuse(arg.offset, 'named argument', "an Arg is Arg<double>('size', 56)");
      continue;
    }
    if (name == null) {
      if (arg.argumentExpression case SimpleStringLiteral s
          when isValidNodeName(s.value)) {
        name = s.value;
      } else {
        refuse(
          arg.offset,
          'argument name',
          'an argument name is an identifier',
        );
      }
      continue;
    }
    fallback ??= arg.argumentExpression.toSource();
  }
  if (name == null) {
    refuse(e.offset, 'missing argument', "an Arg is Arg<double>('size', 56)");
    return null;
  }
  if (!isValueArgType(typeName) && fallback != null) {
    // The generated class is const and imports nothing of the app's values;
    // the widget's own `build` is where an absent object falls back.
    refuse(
      e.offset,
      'opaque default',
      "an $typeName argument takes no default here: Arg<$typeName>('$name'), "
          'and fall back in build when the scene passes none',
    );
    return null;
  }
  return ExternalArgDecl(name, typeName, fallback);
}

String? _typeArgument(TypeArgumentList? types) =>
    types != null && types.arguments.length == 1
    ? types.arguments.single.toSource()
    : null;

(String, ArgumentList)? _invocation(Expression e) => switch (e) {
  MethodInvocation(:var methodName, :var target, :var argumentList)
      when target == null =>
    (methodName.name, argumentList),
  InstanceCreationExpression(:var constructorName, :var argumentList)
      when constructorName.name == null =>
    (constructorName.type.name.lexeme, argumentList),
  _ => null,
};
