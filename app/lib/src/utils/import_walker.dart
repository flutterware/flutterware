import 'dart:collection';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

/// Build environment values for resolving conditional imports/exports as the
/// Dart VM target would.
const vmEnvironment = <String, String>{
  'dart.library.io': 'true',
  'dart.library.async': 'true',
  'dart.library.ffi': 'true',
};

/// Build environment values for resolving conditional imports/exports as the
/// Dart web target would.
const webEnvironment = <String, String>{
  'dart.library.js_interop': 'true',
  'dart.library.html': 'true',
  'dart.library.async': 'true',
};

/// Walks the transitive `import`/`export` graph of a Dart entry point,
/// resolving conditional URIs against a simulated build [environment].
///
/// What this is for here: purity is a property of the entry point's import
/// closure, and the `dart compile exe` failure is the guardrail. That guardrail
/// only fires at distribution time, and only for the entry points that are
/// actually compiled. This walks the same graph in a unit test, so a
/// `package:flutter` import that would fill the machine with a compiler fork
/// bomb fails in seconds with the chain that pulled it in.
///
/// Ported from a sibling project (`packages/server/lib/src/tools/import_walker/`).
class ImportWalker {
  ImportWalker(this.packageConfig, {this.environment = vmEnvironment});

  final PackageConfig packageConfig;
  final Map<String, String> environment;

  /// Walks every reachable import/export from [entryPoint] (a file URI or a
  /// `package:` URI) and returns the result, including a BFS parent map so a
  /// failure can print the chain rather than just the offender.
  WalkResult walk(Uri entryPoint) {
    var root = entryPoint.scheme == 'package'
        ? packageConfig.resolve(entryPoint)!
        : entryPoint;
    var queue = Queue<Uri>()..add(root);
    var parents = <Uri, Uri?>{root: null};

    while (queue.isNotEmpty) {
      var parent = queue.removeFirst();
      for (var import in _importsFor(parent)) {
        if (parents.containsKey(import)) continue;
        parents[import] = parent;
        queue.add(import);
      }
    }
    return WalkResult._(root, parents);
  }

  static final _generatedDir = p.join('.dart_tool/build/generated');

  File _fileForUri(Uri uri) => File(
    (uri.scheme == 'package' ? packageConfig.resolve(uri) : uri)!.toFilePath(),
  );

  List<Uri> _importsFor(Uri uri) {
    if (uri.scheme == 'dart') return const [];

    var file = _fileForUri(uri);
    if (!file.existsSync()) {
      // Fall back to package:build's generated output (e.g. .g.dart files).
      var package = uri.scheme == 'package'
          ? packageConfig[uri.pathSegments.first]
          : packageConfig.packageOf(uri);
      if (package == null) return const [];
      var path = uri.scheme == 'package'
          ? p.joinAll(uri.pathSegments.skip(1))
          : p.relative(uri.path, from: package.root.path);
      file = File(p.join(_generatedDir, package.name, path));
      if (!file.existsSync()) return const [];
    }
    var parsed = parseString(
      content: file.readAsStringSync(),
      throwIfDiagnostics: false,
    );

    var result = <Uri>[];
    for (var directive
        in parsed.unit.directives.whereType<NamespaceDirective>()) {
      // Mirror Dart's conditional-uri resolution: walk configurations in
      // declaration order and take the first whose condition matches the
      // simulated [environment]; otherwise fall back to the default URI.
      String? chosen;
      for (var config in directive.configurations) {
        var name = config.name.toString();
        var expected = config.value?.stringValue ?? 'true';
        if (environment[name] == expected) {
          chosen = config.uri.stringValue;
          break;
        }
      }
      chosen ??= directive.uri.stringValue;
      if (chosen != null) result.add(uri.resolve(chosen));
    }
    return result;
  }
}

/// The reachable URIs from an [ImportWalker.walk], plus the chain that pulled
/// each one in.
class WalkResult {
  WalkResult._(this.root, this._parents);

  /// The fully-resolved root the walk started from.
  final Uri root;

  final Map<Uri, Uri?> _parents;

  /// Every URI reachable from [root], inclusive.
  Iterable<Uri> get reachable => _parents.keys;

  /// Every reachable URI that equals [target] or sits under it.
  ///
  /// The `/` in the prefix is load-bearing: `package:flutter` must match
  /// `package:flutter/foundation.dart` and **not** `package:flutterware`.
  Iterable<Uri> findReachable(String target) => _parents.keys.where((uri) {
    var s = uri.toString();
    return s == target || s.startsWith('$target/');
  });

  /// The import chain from [root] down to [uri], inclusive.
  List<Uri> chainTo(Uri uri) {
    var path = <Uri>[];
    Uri? next = uri;
    while (next != null) {
      path.add(next);
      next = _parents[next];
    }
    return path.reversed.toList();
  }
}
