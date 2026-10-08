// A scene group's declaration — `scenes.dart` — read without resolving
// anything.
//
// A group is a folder with this file in it. The file says what the scenes
// below may use: the app's widgets, the app's own values by name (the
// exports), and which token libraries the scenes read. It is the app's own
// code — it compiles, and the one closure per widget lives in it — so the
// tool only ever READS it, the way it read the externals file before: as
// text, skipping every closure, refusing with a line number anything
// outside the shape rather than half-reading it.
//
// `libraries: [brandTokens]` is the one thing here that reaches another
// file. A library is a `*.tokens.dart` whose list symbol is derived from its
// name, so the reference is resolved by walking this file's imports to the
// marker file that declares that symbol — import URIs, not an analyzer.
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:path/path.dart' as p;

import 'externals_file.dart';
import 'scene_file.dart';
import 'tokens_file.dart';

/// What a group's declaration file is called. Its folder is the group.
const sceneGroupFileName = 'scenes.dart';

/// The symbol the declaration must be called — what the generated entries
/// beside it mount.
const sceneGroupSymbol = 'scenes';

/// The first line of a declaration file: how discovery tells a group's
/// `scenes.dart` from any other file of that name.
const sceneGroupFileMarker = '//@flutterware:scenes=1';

/// Whether [source] declares a group: the marker is on its first line.
bool isGroupFile(String source) {
  var end = source.indexOf('\n');
  var first = end < 0 ? source : source.substring(0, end);
  return first.contains('@flutterware:scenes');
}

/// One `libraries:` entry: the symbol as written, and the file it resolved
/// to — null when no import of the declaration provides it.
class GroupLibraryRef {
  GroupLibraryRef(this.symbol, this.path);

  final String symbol;
  final String? path;
}

/// What a read of a declaration produced.
class GroupParse {
  GroupParse({
    required this.widgets,
    required this.exports,
    required this.libraries,
    required this.refusals,
    this.imports = const [],
  });

  final List<ExternalWidgetDecl> widgets;

  /// The app's values by name and type. Read with the token grammar: a
  /// value type is read as a value for now, any other type is opaque.
  final List<SceneTokenDecl> exports;

  final List<GroupLibraryRef> libraries;
  final List<SceneRefusal> refusals;

  /// The file's imports other than the authoring one, verbatim — what an
  /// opaque type is spelled with, so the generated class spells it too.
  final List<String> imports;

  bool get ok => refusals.isEmpty;

  static GroupParse refused(List<SceneRefusal> refusals) => GroupParse(
    widgets: const [],
    exports: const [],
    libraries: const [],
    refusals: refusals,
  );
}

/// Resolves an import URI as written in the declaration to a file path, or
/// null when the tool cannot: the caller knows where the file sits and what
/// `package:` names mean.
typedef ImportResolver = String? Function(String uri);

/// The resolver for a declaration at [declarationPath]: a relative URI
/// against its folder, a `package:` URI of the enclosing package against
/// that package's `lib/`, anything else unresolved. The package is the
/// nearest `pubspec.yaml` above the file, read for its `name:` line.
ImportResolver importResolverFor(String declarationPath) {
  var directory = p.dirname(declarationPath);
  String? packageName;
  String? packageRoot;
  for (var dir = directory; p.dirname(dir) != dir; dir = p.dirname(dir)) {
    var pubspec = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspec.existsSync()) continue;
    packageRoot = dir;
    for (var line in pubspec.readAsLinesSync()) {
      var match = RegExp(r'^name:\s*([A-Za-z0-9_]+)').firstMatch(line);
      if (match != null) {
        packageName = match.group(1);
        break;
      }
    }
    break;
  }
  return (uri) {
    if (uri.startsWith('package:')) {
      var rest = uri.substring('package:'.length);
      var slash = rest.indexOf('/');
      if (slash < 0 || packageName == null || packageRoot == null) return null;
      if (rest.substring(0, slash) != packageName) return null;
      return p.normalize(p.join(packageRoot, 'lib', rest.substring(slash + 1)));
    }
    if (uri.contains(':')) return null;
    return p.normalize(p.join(directory, uri));
  };
}

/// Reads `final scenes = SceneGroup(widgets: […], exports: […], libraries:
/// […], wrap: …)`.
///
/// [resolveImport] turns each import directive's URI into a path;
/// [librarySymbolAt] says which library symbol a path declares (null when
/// it is not a library file). Together they resolve `libraries:` without an
/// analyzer: a symbol is provided by the imported library file whose
/// derived symbol matches. A symbol nobody imports, or two imports
/// provide, is refused by name.
GroupParse parseGroupFile(
  String source, {
  ImportResolver? resolveImport,
  String? Function(String path)? librarySymbolAt,
}) {
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
  if (refusals.isNotEmpty) return GroupParse.refused(refusals);
  var unit = result.unit;
  var imports = declarationImports(unit, source);

  ArgumentList? args;
  for (var decl in unit.declarations) {
    if (decl is! TopLevelVariableDeclaration) continue;
    for (var v in decl.variables.variables) {
      if (v.name.lexeme != sceneGroupSymbol) continue;
      switch (v.initializer) {
        case InstanceCreationExpression(:var constructorName, :var argumentList)
            when constructorName.type.name.lexeme == 'SceneGroup':
          args = argumentList;
        case MethodInvocation(:var methodName, :var argumentList)
            when methodName.name == 'SceneGroup':
          args = argumentList;
        default:
          refuse(
            v.offset,
            'declaration',
            '$sceneGroupSymbol is a SceneGroup(widgets: […], exports: […], '
                'libraries: […])',
          );
      }
    }
  }
  if (args == null) {
    if (refusals.isEmpty) {
      refuse(
        0,
        'no declaration',
        'a group file holds `final $sceneGroupSymbol = SceneGroup(…)`',
      );
    }
    return GroupParse.refused(refusals);
  }

  var widgets = <ExternalWidgetDecl>[];
  var exports = <SceneTokenDecl>[];
  var libraryNames = <(String, int)>[];
  for (var arg in args.arguments) {
    if (arg is! NamedArgument) {
      refuse(arg.offset, 'argument', 'a SceneGroup names every argument');
      continue;
    }
    var name = arg.name.lexeme;
    var value = arg.argumentExpression;
    switch (name) {
      // Both are the app's own code — a closure, a map of renderers — and
      // the editor never sees inside either.
      case 'wrap' || 'renderers':
        continue;
      case 'widgets':
        if (value is ListLiteral) {
          widgets = parseExternalWidgetElements(value, refuse);
        } else {
          refuse(
            value.offset,
            'widgets',
            'widgets is a list of ExternalWidget(…)',
          );
        }
      case 'exports':
        if (value is ListLiteral) {
          exports = parseTokenElements(value, refuse, exports: true);
        } else {
          refuse(value.offset, 'exports', 'exports is a list of Token<…>(…)');
        }
      case 'libraries':
        if (value is! ListLiteral) {
          refuse(value.offset, 'libraries', 'libraries is a list of symbols');
          continue;
        }
        for (var element in value.elements) {
          if (element case SimpleIdentifier(:var name)) {
            libraryNames.add((name, element.offset));
          } else {
            refuse(
              element.offset,
              'library',
              'a library is named by its list symbol: libraries: '
                  '[brandTokens], imported from brand.tokens.dart',
            );
          }
        }
      default:
        refuse(
          arg.offset,
          'unknown property',
          'a SceneGroup takes widgets:, exports:, libraries:, renderers: and wrap:',
        );
    }
  }

  // Which imported file provides which library symbol.
  var provided = <String, List<String>>{};
  if (resolveImport != null && librarySymbolAt != null) {
    for (var d in unit.directives) {
      if (d is! ImportDirective) continue;
      var uri = d.uri.stringValue;
      if (uri == null) continue;
      var path = resolveImport(uri);
      if (path == null) continue;
      var symbol = librarySymbolAt(path);
      if (symbol != null) (provided[symbol] ??= []).add(path);
    }
  }
  var libraries = <GroupLibraryRef>[];
  var seen = <String>{};
  for (var (symbol, offset) in libraryNames) {
    if (!seen.add(symbol)) {
      refuse(offset, 'library', '$symbol is listed twice');
      continue;
    }
    var paths = provided[symbol] ?? const [];
    if (resolveImport == null || librarySymbolAt == null) {
      libraries.add(GroupLibraryRef(symbol, null));
    } else if (paths.isEmpty) {
      refuse(
        offset,
        'library',
        'no import of this file declares $symbol: a library is a '
            "'*$sceneTokensFileSuffix' whose first line is "
            '$sceneTokensFileMarker, imported here',
      );
    } else if (paths.length > 1) {
      refuse(
        offset,
        'library',
        '$symbol is declared by ${paths.join(' and ')}',
      );
    } else {
      libraries.add(GroupLibraryRef(symbol, paths.single));
    }
  }
  return GroupParse(
    widgets: widgets,
    exports: exports,
    libraries: libraries,
    refusals: refusals,
    imports: imports,
  );
}

/// [declarationSource] with the library at [libraryPath] attached: its
/// symbol added to `libraries:` and its file imported, relative to
/// [declarationPath]. The one edit the tool makes to a hand-written file,
/// done through the parser with offsets and touching nothing else. Null,
/// with the reason in [refuse], when the file does not parse or has no
/// `SceneGroup(…)` to attach to. Already attached is a no-op.
String? attachLibraryIn(
  String declarationSource,
  String declarationPath,
  String libraryPath, {
  required void Function(String reason) refuse,
}) {
  var result = parseString(
    content: declarationSource,
    throwIfDiagnostics: false,
  );
  if (result.errors.isNotEmpty) {
    refuse(
      '${p.basename(declarationPath)} does not parse: '
      '${result.errors.first.message}',
    );
    return null;
  }
  var symbol = tokensSymbolFor(libraryPath);
  var unit = result.unit;
  ArgumentList? args;
  for (var decl in unit.declarations) {
    if (decl is! TopLevelVariableDeclaration) continue;
    for (var v in decl.variables.variables) {
      if (v.name.lexeme != sceneGroupSymbol) continue;
      args = switch (v.initializer) {
        InstanceCreationExpression(:var argumentList) => argumentList,
        MethodInvocation(:var argumentList) => argumentList,
        _ => null,
      };
    }
  }
  if (args == null) {
    refuse(
      '${p.basename(declarationPath)} declares no `$sceneGroupSymbol = '
      'SceneGroup(…)`',
    );
    return null;
  }
  var uri = p.url.joinAll(
    p.split(p.relative(libraryPath, from: p.dirname(declarationPath))),
  );
  var edits = <(int, String)>[];
  var imported = unit.directives.any(
    (d) => d is ImportDirective && d.uri.stringValue == uri,
  );
  if (!imported) {
    var lastImport = unit.directives.whereType<ImportDirective>().lastOrNull;
    var at = lastImport?.end ?? 0;
    edits.add((
      at,
      lastImport == null ? "import '$uri';\n" : "\nimport '$uri';",
    ));
  }
  ListLiteral? libraries;
  for (var arg in args.arguments) {
    if (arg is NamedArgument && arg.name.lexeme == 'libraries') {
      if (arg.argumentExpression case ListLiteral l) libraries = l;
    }
  }
  if (libraries == null) {
    // No `libraries:` yet: first argument, so it reads before the rest.
    var at = args.arguments.isEmpty
        ? args.leftParenthesis.end
        : args.arguments.first.offset;
    edits.add((
      at,
      args.arguments.isEmpty
          ? 'libraries: [$symbol]'
          : 'libraries: [$symbol], ',
    ));
  } else {
    var already = libraries.elements.any(
      (e) => e is SimpleIdentifier && e.name == symbol,
    );
    if (!already) {
      var at = libraries.rightBracket.offset;
      edits.add((at, libraries.elements.isEmpty ? symbol : ', $symbol'));
    }
  }
  return _applyEdits(declarationSource, edits);
}

/// The reverse of [attachLibraryIn]: the symbol out of `libraries:` and the
/// import gone. Null when the file does not parse.
String? detachLibraryIn(
  String declarationSource,
  String declarationPath,
  String libraryPath, {
  required void Function(String reason) refuse,
}) {
  var result = parseString(
    content: declarationSource,
    throwIfDiagnostics: false,
  );
  if (result.errors.isNotEmpty) {
    refuse(
      '${p.basename(declarationPath)} does not parse: '
      '${result.errors.first.message}',
    );
    return null;
  }
  var symbol = tokensSymbolFor(libraryPath);
  var uri = p.url.joinAll(
    p.split(p.relative(libraryPath, from: p.dirname(declarationPath))),
  );
  var unit = result.unit;
  var removals = <(int, int)>[];
  for (var d in unit.directives) {
    if (d is ImportDirective && d.uri.stringValue == uri) {
      var end = d.end;
      if (end < declarationSource.length && declarationSource[end] == '\n') {
        end++;
      }
      removals.add((d.offset, end));
    }
  }
  for (var decl in unit.declarations) {
    if (decl is! TopLevelVariableDeclaration) continue;
    for (var v in decl.variables.variables) {
      if (v.name.lexeme != sceneGroupSymbol) continue;
      var args = switch (v.initializer) {
        InstanceCreationExpression(:var argumentList) => argumentList,
        MethodInvocation(:var argumentList) => argumentList,
        _ => null,
      };
      for (var arg in args?.arguments ?? const <Expression>[]) {
        if (arg is! NamedArgument || arg.name.lexeme != 'libraries') continue;
        if (arg.argumentExpression case ListLiteral l) {
          var elements = l.elements;
          for (var (i, e) in elements.indexed) {
            if (e is! SimpleIdentifier || e.name != symbol) continue;
            // Take the separator with it: the comma after, else before.
            if (i + 1 < elements.length) {
              removals.add((e.offset, elements[i + 1].offset));
            } else if (i > 0) {
              removals.add((elements[i - 1].end, e.end));
            } else {
              removals.add((e.offset, e.end));
            }
          }
        }
      }
    }
  }
  removals.sort((a, b) => b.$1.compareTo(a.$1));
  var out = declarationSource;
  for (var (start, end) in removals) {
    out = out.substring(0, start) + out.substring(end);
  }
  return out;
}

String _applyEdits(String source, List<(int, String)> edits) {
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  var out = source;
  for (var (at, text) in edits) {
    out = out.substring(0, at) + text + out.substring(at);
  }
  return out;
}
