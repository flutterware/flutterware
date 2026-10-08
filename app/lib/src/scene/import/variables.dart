// A design file's variables, as saved JSON, becoming tokens — merged into a
// library by [TokensLibrary.merge].
//
// The smallest slice of the importer, built first: variables need no node
// import at all, and they put real data against the token declaration before
// styles are built on it. Built on the JSON the design tool's REST API
// answers for a file's local variables — saved to disk, never fetched here,
// so CI needs no credential and a network fetch can wrap this later.
//
// The rules for every import apply: a variable that cannot be a token is
// REFUSED, by name and with the reason, never approximated. What is refused
// is the list of what to build next.
//
// A library is a design system, so only COLOR and FLOAT variables become
// tokens. A STRING is copy and a BOOLEAN is a flag; both are refused by
// name, saying where they belong instead.
//
// The shape read (the variables endpoint's `meta`):
//
//   variableCollections: { id: { name, modes: [{modeId, name}],
//                                defaultModeId, variableIds } }
//   variables: { id: { name, resolvedType: COLOR|FLOAT|STRING|BOOLEAN,
//                      variableCollectionId, valuesByMode: { modeId: value },
//                      deletedButReferenced?, hiddenFromPublishing? } }
//
// A value is `{r, g, b, a}` in 0..1, a number, a string, a bool, or an
// alias `{type: 'VARIABLE_ALIAS', id}` to another variable — resolved in
// that variable's collection's default mode.
//
// ONE MODE IS READ: the collection's default. A library holds one value per
// token, so a collection's other modes have nowhere to land — and a design
// tool's `dark` is a whole second set, which the app builds as another
// `SceneTokens` and hands to a scene. Each one is refused by name rather
// than flattened into the default, so what was left behind is on the
// report.
import 'dart:convert';

import 'package:flutterware/scene_authoring.dart';

import '../tokens_file.dart';

/// One variable that became a token: the identifier it got, where it came
/// from, its kind and its value in the collection's default mode.
class ImportedToken {
  ImportedToken({
    required this.name,
    required this.source,
    required this.kind,
    required this.value,
  });

  /// The Dart identifier — `brandPrimary` from `Brand/Primary`.
  final String name;

  /// `Collection · Variable/Name`, as the design file spells it.
  final String source;

  final SceneParamKind kind;
  final Object value;

  SceneTokenDecl get decl => SceneTokenDecl(name, kind, value);
}

/// A variable that was not imported, and why.
class ImportRefusal {
  ImportRefusal(this.what, this.reason);

  /// The variable, as the design file names it.
  final String what;
  final String reason;

  @override
  String toString() => '$what: $reason';
}

/// What a read of the variables produced: the tokens, in the design file's
/// order, and every refusal.
class VariablesImport {
  VariablesImport(this.tokens, this.refusals);

  final List<ImportedToken> tokens;
  final List<ImportRefusal> refusals;
}

/// Reads the variables JSON — the endpoint's whole response or its `meta`.
VariablesImport importVariables(String json) {
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (e) {
    return VariablesImport(const [], [
      ImportRefusal('the file', 'not JSON: ${e.message}'),
    ]);
  }
  if (decoded is! Map) {
    return VariablesImport(const [], [
      ImportRefusal('the file', 'not a JSON object'),
    ]);
  }
  var meta = switch (decoded['meta']) {
    Map m => m,
    _ => decoded,
  };
  var collections = (meta['variableCollections'] as Map?) ?? const {};
  var variables = (meta['variables'] as Map?) ?? const {};
  if (collections.isEmpty || variables.isEmpty) {
    return VariablesImport(const [], [
      ImportRefusal(
        'the file',
        'no variableCollections and variables: this is not the variables '
            "endpoint's answer",
      ),
    ]);
  }
  return _Importer(
    collections.cast<String, Object?>(),
    variables.cast<String, Object?>(),
  ).run();
}

class _Importer {
  _Importer(this.collections, this.variables);

  final Map<String, Object?> collections;
  final Map<String, Object?> variables;
  final refusals = <ImportRefusal>[];

  VariablesImport run() {
    // The other modes, said once each: a whole second set the library has
    // no room for, named so it is clear what was not taken.
    for (var c in collections.values) {
      var collection = c! as Map;
      var defaultId = '${collection['defaultModeId']}';
      for (var m in (collection['modes'] as List?) ?? const []) {
        var mode = m as Map;
        if ('${mode['modeId']}' == defaultId) continue;
        refusals.add(
          ImportRefusal(
            '${collection['name']} · ${mode['name']}',
            'only the default mode is imported: a library holds one value '
                'per token; build the other set in your app as '
                'SceneTokens(…) and pass it to the scene',
          ),
        );
      }
    }

    var tokens = <ImportedToken>[];
    var taken = <String, String>{};
    // The file's own order, by collection then by the collection's list.
    for (var c in collections.values) {
      var collection = c! as Map;
      var modeId = '${collection['defaultModeId']}';
      for (var id in (collection['variableIds'] as List?) ?? const []) {
        var raw = variables['$id'];
        if (raw is! Map) continue;
        var source = '${collection['name']} · ${raw['name']}';
        if (raw['deletedButReferenced'] == true) continue;
        var kind = _kind('${raw['resolvedType']}');
        if (kind == null) {
          refusals.add(
            ImportRefusal(
              source,
              'a ${raw['resolvedType']} is not a token kind',
            ),
          );
          continue;
        }
        // A design tool's variables carry copy and flags beside the design;
        // a library holds the design. Refused by name, with where it goes.
        if (!libraryTokenKinds.contains(kind)) {
          refusals.add(
            ImportRefusal(source, notADesignValue(paramKindTypeName(kind))),
          );
          continue;
        }
        var name = _identifier('${raw['name']}');
        if (name == null) {
          refusals.add(ImportRefusal(source, 'its name makes no identifier'));
          continue;
        }
        if (taken[name] case var other?) {
          refusals.add(
            ImportRefusal(
              source,
              'its name becomes "$name", which $other already took: rename '
              'one of them in the design file',
            ),
          );
          continue;
        }
        var value = _resolve(raw, modeId, kind, const {});
        if (value == null) {
          refusals.add(
            ImportRefusal(
              source,
              'its value in the default mode could not '
              'be read',
            ),
          );
          continue;
        }
        taken[name] = source;
        tokens.add(
          ImportedToken(name: name, source: source, kind: kind, value: value),
        );
      }
    }
    return VariablesImport(tokens, refusals);
  }

  static SceneParamKind? _kind(String resolvedType) => switch (resolvedType) {
    'COLOR' => SceneParamKind.color,
    'FLOAT' => SceneParamKind.number,
    'STRING' => SceneParamKind.string,
    'BOOLEAN' => SceneParamKind.bool,
    _ => null,
  };

  /// The value of [variable] in [modeId], following aliases. An alias into
  /// another collection is read in that collection's default mode, which is
  /// the only mode this import reads.
  Object? _resolve(
    Map variable,
    String modeId,
    SceneParamKind kind,
    Set<String> seen,
  ) {
    var values = (variable['valuesByMode'] as Map?) ?? const {};
    var raw = values[modeId];
    if (raw is Map && raw['type'] == 'VARIABLE_ALIAS') {
      var target = variables['${raw['id']}'];
      if (target is! Map || seen.contains('${raw['id']}')) return null;
      var collection = collections['${target['variableCollectionId']}'];
      if (collection is! Map) return null;
      var targetMode = '${collection['defaultModeId']}';
      return _resolve(target, targetMode, kind, {...seen, '${raw['id']}'});
    }
    return switch ((kind, raw)) {
      (SceneParamKind.color, Map c) => _color(c),
      (SceneParamKind.number, num n) => n.toDouble(),
      (SceneParamKind.string, String s) => s,
      (SceneParamKind.bool, bool b) => b,
      _ => null,
    };
  }

  static SceneColor? _color(Map c) {
    int channel(Object? v) => switch (v) {
      num n => (n.clamp(0, 1) * 255).round(),
      _ => -1,
    };
    var r = channel(c['r']), g = channel(c['g']), b = channel(c['b']);
    var a = c.containsKey('a') ? channel(c['a']) : 255;
    if (r < 0 || g < 0 || b < 0 || a < 0) return null;
    return SceneColor((a << 24) | (r << 16) | (g << 8) | b);
  }

  /// `Brand/Primary` → `brandPrimary`, `Spacing - 2x` → `spacing2x`; null
  /// when nothing usable is left, or the result is a Dart keyword.
  static String? _identifier(String raw) {
    var words = raw
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;
    var out = StringBuffer();
    for (var (i, w) in words.indexed) {
      if (i == 0) {
        out.write(w[0].toLowerCase() + w.substring(1));
      } else {
        out.write(w[0].toUpperCase() + w.substring(1));
      }
    }
    var name = '$out';
    if (!isValidNodeName(name) || _keywords.contains(name)) return null;
    return name;
  }

  static const _keywords = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'base',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'of',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'sealed',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'when',
    'while',
    'with',
    'yield',
  };
}
