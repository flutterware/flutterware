import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

import 'import_walker.dart' show vmEnvironment;

/// What an [EnumLookup] found for one type name, or why it found nothing.
///
/// Never both: a lookup that cannot say with certainty which declaration a name
/// refers to reports the problem rather than picking. The caller's move on a
/// problem is to leave the knob out and say so — `KnobKind`'s own rule, that a
/// knob rendered as the wrong control is worse than one the panel admits it
/// cannot show.
class EnumValues {
  const EnumValues.found(this.values, this.declaredIn) : problem = null;

  const EnumValues.problem(this.problem) : values = const [], declaredIn = null;

  /// The constants, in declaration order — `['dev', 'staging', 'prod']`.
  ///
  /// Names only. A value with arguments (`low(1)`) is still just `low` here,
  /// because the name is all a picker offers and all the wrapper needs to write.
  final List<String> values;

  /// Absolute path of the file declaring the enum. Null when [problem] is set.
  final String? declaredIn;

  /// Why there are no [values], in a sentence that says what to do.
  final String? problem;

  bool get found => problem == null;
}

/// Finds an `enum`'s constants by parsing, without resolving the program.
///
/// Why not the analyzer. Asking for a resolved unit answers this perfectly
/// and costs 5.5s on an entry point that imports Flutter, 9.9s on this GUI's own
/// (measured 2026-08-12, `2026-08-12-run-knobs-design.md` § E4). A launch form
/// cannot pay that, and neither can a catalog scan that has deliberately stayed
/// syntactic.
///
/// The bound is what makes it honest. The search covers the file itself and
/// the *exported namespace* of each of its direct imports — `export` followed
/// transitively, because a barrel (`export 'src/backend.dart';`) is what people
/// actually write, but `import` chains never. A name that is not there is
/// reported as not found rather than hunted for, so the cost of a lookup is
/// bounded by the file's own import list.
///
/// An import is followed when it names a file this checkout holds: a relative
/// path, or a `package:` URI belonging to a package of the same workspace —
/// see [firstPartyPackages]. A dependency it fetched is not, which is a bound
/// and not an oversight: parsing the export closure of
/// `package:material_ui/material_ui.dart` to answer one name would cost a form
/// that has to open now, and an enum nobody in the checkout can edit is not
/// the one somebody is trying to put a knob on.
///
/// Shared deliberately: entry-point knobs and catalog demos ask the identical
/// question of the identical AST, and
/// `docs/superpowers/specs/2026-07-27-knobs-static-and-runtime.md` left it open
/// for demos before entry points existed. Two answers would be two behaviours
/// for one word.
class EnumLookup {
  EnumLookup({this.packageConfig, this.selfPackage, this.selfPackageRoot});

  /// Resolves `package:` URIs. Read from [selfPackageRoot]'s checkout when not
  /// given, and null only when there is nothing to read it from — then relative
  /// imports and [selfPackage] are all that is followed, and everything else
  /// reports honestly.
  final PackageConfig? packageConfig;

  /// The name of the package being scanned, so `package:myapp/src/models.dart`
  /// resolves without a config at all.
  ///
  /// Worth its own field because a package importing *itself* by `package:` URI
  /// is the common case in real code, and loading a `PackageConfig` is async
  /// while both scanners that need this are not.
  final String? selfPackage;

  /// [selfPackage]'s directory — the one holding its `lib/`.
  final String? selfPackageRoot;

  /// [packageConfig], or the checkout's own packages, worked out on first need.
  ///
  /// Lazy because it is a file read that most lookups never want: a type
  /// declared in the file or beside it is answered before any `package:` URI
  /// has to mean anything.
  late final PackageConfig? _packages =
      packageConfig ?? firstPartyPackages(selfPackageRoot);

  final _libraries = <String, _Library>{};

  /// The constants of [name], as referred to from [file].
  ///
  /// [prefix] is the import prefix the type was written with — `m` in
  /// `m.Backend`, null for a bare `Backend`. It narrows the search rather than
  /// decorating it: a prefixed name can only come from the import carrying that
  /// prefix, and an unprefixed one can never come from a prefixed import.
  EnumValues lookup({
    required String file,
    required String name,
    String? prefix,
  }) {
    var root = _libraryAt(p.normalize(p.absolute(file)));
    if (root == null) {
      return EnumValues.problem('$file could not be read');
    }

    // A declaration in the file itself shadows anything imported, so finding it
    // here is an answer rather than a candidate.
    if (prefix == null) {
      if (root.enums[name] case var values?) {
        return EnumValues.found(values, root.path);
      }
    }

    // Keyed by the file that declares it: one enum reached through both a
    // barrel and its own file is one enum, not an ambiguity. That shape is
    // common enough that treating it as a conflict would refuse ordinary code.
    var hits = <String, List<String>>{};
    for (var import in root.imports) {
      if (import.prefix != prefix) continue;
      if (!import.combinators.allows(name)) continue;
      var target = _resolve(import.uri, from: root.path);
      if (target == null) continue;
      var found = _searchExports(target, name, {});
      if (found != null) hits[found.path] = found.values;
    }

    return switch (hits.length) {
      1 => EnumValues.found(hits.values.single, hits.keys.single),
      0 => EnumValues.problem(
        'no enum $name in ${p.basename(root.path)} or its direct imports. '
        'Declare it there, or export it from a file that entry point already '
        'imports.',
      ),
      _ => EnumValues.problem(
        'enum $name is reachable from ${p.basename(root.path)} through '
        '${hits.length} different declarations '
        '(${hits.keys.map(p.basename).join(', ')}). Import one of them, or '
        'name it with a prefix.',
      ),
    };
  }

  /// The enum called [name] in [path]'s exported namespace, or null.
  ///
  /// Follows `export` and honours its combinators, so a barrel that re-exports
  /// half of a file offers exactly that half. [seen] guards the cycle a pair of
  /// mutually exporting libraries would otherwise make.
  ({String path, List<String> values})? _searchExports(
    String path,
    String name,
    Set<String> seen,
  ) {
    if (!seen.add(path)) return null;
    var library = _libraryAt(path);
    if (library == null) return null;
    if (library.enums[name] case var values?) {
      return (path: library.path, values: values);
    }
    for (var export in library.exports) {
      if (!export.combinators.allows(name)) continue;
      var target = _resolve(export.uri, from: library.path);
      if (target == null) continue;
      if (_searchExports(target, name, seen) case var found?) return found;
    }
    return null;
  }

  /// A directive's URI as an absolute file path, or null for anything this
  /// cannot follow — `dart:` libraries, and the packages this checkout fetched
  /// rather than holds.
  String? _resolve(String uri, {required String from}) {
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      var parsed = Uri.parse(uri);
      if (parsed.pathSegments.firstOrNull == selfPackage &&
          selfPackageRoot != null) {
        return p.normalize(
          p.joinAll([selfPackageRoot!, 'lib', ...parsed.pathSegments.skip(1)]),
        );
      }
      var resolved = _packages?.resolve(parsed);
      return resolved == null ? null : p.normalize(resolved.toFilePath());
    }
    return p.normalize(p.join(p.dirname(from), uri));
  }

  _Library? _libraryAt(String path) {
    if (_libraries[path] case var cached?) return cached;
    var unit = _parse(path);
    if (unit == null) return null;

    var library = _Library(path);
    _collect(unit, library);
    // A `part` is the same library, so its declarations are this library's.
    // Worth the extra reads: generator output routinely lands in one.
    for (var directive in unit.directives.whereType<PartDirective>()) {
      var target = _uriOf(directive);
      if (target == null) continue;
      var partPath = _resolve(target, from: path);
      if (partPath == null) continue;
      var part = _parse(partPath);
      if (part != null) _collect(part, library, directivesToo: false);
    }
    return _libraries[path] = library;
  }

  void _collect(
    CompilationUnit unit,
    _Library into, {
    bool directivesToo = true,
  }) {
    for (var declaration in unit.declarations.whereType<EnumDeclaration>()) {
      // `namePart` / `body.constants` rather than `name` / `constants`: the
      // analyzer moved both behind those in 13.x, and a primary constructor is
      // now one of the shapes a name part can take.
      into.enums[declaration.namePart.typeName.lexeme] = [
        for (var constant in declaration.body.constants)
          // Dropped rather than offered: the parser recovers `enum X { a,,, }`
          // into constants with empty names, and a picker with blank options is
          // worse than a shorter one. Measured — recovery is why a broken file
          // still answers at all.
          if (constant.name.lexeme.isNotEmpty) constant.name.lexeme,
      ];
    }
    if (!directivesToo) return;
    for (var directive in unit.directives) {
      var uri = _uriOf(directive);
      if (uri == null) continue;
      switch (directive) {
        case ImportDirective():
          into.imports.add(
            _Directive(
              uri,
              prefix: directive.prefix?.name,
              combinators: _Combinators.of(directive.combinators),
            ),
          );
        case ExportDirective():
          into.exports.add(
            _Directive(
              uri,
              combinators: _Combinators.of(directive.combinators),
            ),
          );
        default:
          break;
      }
    }
  }

  /// The URI a directive names, resolving a conditional one the way the VM
  /// target would — the rule [ImportWalker] already follows, kept identical so
  /// two walks of the same program cannot disagree about which branch is real.
  String? _uriOf(Directive directive) {
    if (directive is! NamespaceDirective) {
      return directive is PartDirective ? directive.uri.stringValue : null;
    }
    for (var configuration in directive.configurations) {
      var expected = configuration.value?.stringValue ?? 'true';
      if (vmEnvironment['${configuration.name}'] == expected) {
        return configuration.uri.stringValue ?? directive.uri.stringValue;
      }
    }
    return directive.uri.stringValue;
  }

  CompilationUnit? _parse(String path) {
    try {
      return parseString(
        content: File(path).readAsStringSync(),
        throwIfDiagnostics: false,
      ).unit;
    } on Object {
      // Absent, or a file that will not parse — which cannot be built either,
      // and the compiler says so better than a scan can.
      return null;
    }
  }
}

/// The packages whose source is in [packageRoot]'s checkout, as a resolver for
/// `package:` URIs — and nothing that was fetched.
///
/// Why not simply the whole config. A shared package is where a first-party
/// enum hides — one `Backend` in one place, so two apps cannot disagree about
/// what `staging` means — and following `path:` dependencies to reach it is a
/// handful of small packages. Following everything else is not: an entry point
/// imports `package:material_ui/material_ui.dart`, whose export closure is
/// hundreds of files to parse before a missing name can be called missing, on
/// the path that draws a launch form. So the resolver carries the checkout and
/// stops there.
///
/// The two lines are drawn where the config itself draws them: pub names the
/// cache it fetched into and the SDK it resolved against, and writes a relative
/// `rootUri` for exactly the packages that live beside the file — a workspace
/// member, a `path:` dependency. Both are required, so the odd layout (a cache
/// inside the project, a dependency on another drive) is refused rather than
/// guessed at, which is the behaviour there was before any of this.
///
/// Read here rather than through `loadPackageConfig`, which is async while both
/// scanners that need this are not. The walk up is what a workspace requires:
/// `pub get` writes one `.dart_tool/package_config.json` at the root and none
/// in the members.
PackageConfig? firstPartyPackages(String? packageRoot) {
  if (packageRoot == null) return null;
  var file = _packageConfigAbove(p.normalize(p.absolute(packageRoot)));
  if (file == null) return null;
  Map<String, Object?> json;
  Uri base;
  try {
    json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    // `rootUri` is relative to the directory holding the file, not to the file.
    base = Uri.directory(file.parent.path);
  } on Object {
    return null;
  }
  var fetched = [
    for (var key in const ['pubCache', 'flutterRoot'])
      if (json[key] case String uri) ?_pathOf(base.resolve(uri)),
  ];
  var packages = [
    for (var entry in json['packages'] as List? ?? const [])
      if (entry is Map) ?_packageOf(entry, base: base, fetched: fetched),
  ];
  if (packages.isEmpty) return null;
  try {
    return PackageConfig(packages);
  } on Object {
    return null;
  }
}

/// One `packages` entry, or null when the checkout does not hold it.
Package? _packageOf(
  Map<Object?, Object?> entry, {
  required Uri base,
  required List<String> fetched,
}) {
  if (entry['name'] is! String) return null;
  if (entry['rootUri'] is! String) return null;
  var rootUri = entry['rootUri']! as String;
  // Absolute is how pub spells "I fetched this", so it is refused before the
  // directories are compared — and a package on another drive, which has no
  // relative spelling, is left alone rather than followed.
  if (Uri.parse(rootUri).hasScheme) return null;
  var root = base.resolve(_directory(rootUri));
  var path = _pathOf(root);
  if (path == null) return null;
  if (fetched.any((from) => p.isWithin(from, path))) return null;
  var lib = entry['packageUri'];
  try {
    return Package(
      entry['name']! as String,
      root,
      packageUriRoot: root.resolve(_directory(lib is String ? lib : 'lib/')),
    );
  } on Object {
    // One entry this cannot make sense of costs that entry, never the rest of
    // the checkout.
    return null;
  }
}

/// The nearest `.dart_tool/package_config.json` at [from] or above it.
File? _packageConfigAbove(String from) {
  for (var directory = from; ; directory = p.dirname(directory)) {
    var file = File(p.join(directory, '.dart_tool', 'package_config.json'));
    if (file.existsSync()) return file;
    if (p.dirname(directory) == directory) return null;
  }
}

/// [uri] as a local path, or null when it does not name one.
String? _pathOf(Uri uri) {
  if (!uri.isScheme('file')) return null;
  try {
    return p.normalize(uri.toFilePath());
  } on Object {
    return null;
  }
}

/// [uri] with the trailing slash a directory needs.
///
/// Pub writes `../shared`, and both `Uri.resolve` and [Package] read a URI
/// without one as a file — so the last segment would be dropped and the package
/// would resolve one directory too high.
String _directory(String uri) => uri.endsWith('/') ? uri : '$uri/';

class _Library {
  _Library(this.path);

  final String path;
  final enums = <String, List<String>>{};
  final imports = <_Directive>[];
  final exports = <_Directive>[];
}

class _Directive {
  _Directive(this.uri, {this.prefix, required this.combinators});

  final String uri;
  final String? prefix;
  final _Combinators combinators;
}

/// A directive's `show` / `hide`.
///
/// Honoured rather than ignored, and cheaply — they are syntax. Ignoring them
/// would be safe for correctness but not for temper: a name hidden on one route
/// and shown on another would look like two declarations and be refused as
/// ambiguous, in a program that compiles perfectly.
class _Combinators {
  _Combinators(this.shown, this.hidden);

  factory _Combinators.of(List<Combinator> combinators) {
    Set<String>? shown;
    var hidden = <String>{};
    for (var combinator in combinators) {
      switch (combinator) {
        case ShowCombinator():
          (shown ??= {}).addAll(combinator.shownNames.map((name) => name.name));
        case HideCombinator():
          hidden.addAll(combinator.hiddenNames.map((name) => name.name));
      }
    }
    return _Combinators(shown, hidden);
  }

  final Set<String>? shown;
  final Set<String> hidden;

  bool allows(String name) =>
      (shown?.contains(name) ?? true) && !hidden.contains(name);
}
