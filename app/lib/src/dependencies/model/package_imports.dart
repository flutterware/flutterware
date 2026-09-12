import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// Where in the package a reference lives.
///
/// The distinction is the actionable one: a package referenced only from [test]
/// but declared in `dependencies:` belongs in `dev_dependencies:`, and one
/// referenced from [lib] while declared as a dev dependency is a build waiting
/// to break.
enum ImportScope {
  lib,
  test,
  tool,
  other;

  static ImportScope of(String relativePath) =>
      switch (p.split(relativePath).first) {
        'lib' => lib,
        'test' || 'integration_test' || 'test_driver' => test,
        'tool' || 'bin' || 'example' => tool,
        _ => other,
      };

  String get label => name;
}

/// One `import` or `export` of a package, and where it was written.
class PackageImport {
  PackageImport({
    required this.path,
    required this.uri,
    required this.scope,
    required this.isExport,
    this.condition,
  });

  /// Package-relative, so it reads the way you would type it.
  final String path;

  /// The URI as written — `package:collection/collection.dart`.
  final String uri;

  /// The part after the package name, which says *which* library of a
  /// multi-library package is actually being used.
  String get library {
    var segments = Uri.parse(uri).pathSegments;
    return segments.length > 1 ? segments.skip(1).join('/') : '';
  }

  final ImportScope scope;
  final bool isExport;

  /// The environment this URI is chosen for — `dart.library.io` — or null when
  /// it is the directive's default URI.
  ///
  /// A conditional import names two or three packages, and only one of them is
  /// the default. Reading the default alone reports a dependency used solely on
  /// the web as never referenced.
  final String? condition;

  Map<String, Object?> toJson() => {
    'path': path,
    'uri': uri,
    'scope': scope.name,
    if (isExport) 'export': true,
    'condition': ?condition,
  };

  static PackageImport fromJson(Map<String, Object?> json) => PackageImport(
    path: json['path']! as String,
    uri: json['uri']! as String,
    scope: ImportScope.values.asNameMap()[json['scope']] ?? ImportScope.other,
    isExport: json['export'] == true,
    condition: json['condition'] as String?,
  );

  @override
  String toString() =>
      condition == null ? '$path → $uri' : '$path → $uri if ($condition)';
}

/// A `packages/<name>/…` path in the `flutter:` section of a pubspec.
///
/// An asset-only package — a font, an icon set — is depended on and shipped
/// without a single Dart file ever importing it.
class PackageAssetReference {
  PackageAssetReference({required this.path, required this.isFont});

  /// As written: `packages/my_icons/fonts/icons.ttf`.
  final String path;

  final bool isFont;

  Map<String, Object?> toJson() => {'path': path, if (isFont) 'font': true};

  static PackageAssetReference fromJson(Map<String, Object?> json) =>
      PackageAssetReference(
        path: json['path']! as String,
        isFont: json['font'] == true,
      );

  @override
  String toString() => path;
}

/// Which packages the source of one package refers to, and from where.
class PackageImports {
  PackageImports(this.byPackage, {this.assetsByPackage = const {}});

  final Map<String, List<PackageImport>> byPackage;

  /// Asset and font paths reaching into another package, by package name.
  final Map<String, List<PackageAssetReference>> assetsByPackage;

  Map<String, Object?> toJson() => {
    'imports': {
      for (var entry in byPackage.entries)
        entry.key: [for (var import in entry.value) import.toJson()],
    },
    'assets': {
      for (var entry in assetsByPackage.entries)
        entry.key: [for (var asset in entry.value) asset.toJson()],
    },
  };

  static PackageImports fromJson(Map<String, Object?> json) => PackageImports(
    {
      for (var entry
          in (json['imports'] as Map<String, Object?>? ?? const {}).entries)
        entry.key: [
          for (var import in entry.value as List? ?? const [])
            PackageImport.fromJson((import as Map).cast<String, Object?>()),
        ],
    },
    assetsByPackage: {
      for (var entry
          in (json['assets'] as Map<String, Object?>? ?? const {}).entries)
        entry.key: [
          for (var asset in entry.value as List? ?? const [])
            PackageAssetReference.fromJson(
              (asset as Map).cast<String, Object?>(),
            ),
        ],
    },
  );

  List<PackageImport> operator [](String packageName) =>
      byPackage[packageName] ?? const [];

  List<PackageAssetReference> assetsOf(String packageName) =>
      assetsByPackage[packageName] ?? const [];

  /// Whether anything at all points at [packageName] — an import, an export, or
  /// an asset declaration.
  bool isReferenced(String packageName) =>
      this[packageName].isNotEmpty || assetsOf(packageName).isNotEmpty;

  /// Distinct files referring to [packageName] — the honest denominator, since
  /// one file can import two libraries of the same package.
  int fileCount(String packageName) =>
      this[packageName].map((e) => e.path).toSet().length;

  /// The scopes [packageName] is referenced from, in enum order.
  List<ImportScope> scopesOf(String packageName) {
    var scopes = this[packageName].map((e) => e.scope).toSet();
    return [
      for (var scope in ImportScope.values)
        if (scopes.contains(scope)) scope,
    ];
  }

  /// Whether the only references are from test code — the signal that a
  /// package sitting in `dependencies:` should be a dev dependency.
  ///
  /// An asset declaration ships with the app, so a package named by one is
  /// never test-only however its Dart libraries are imported.
  bool isTestOnly(String packageName) {
    if (assetsOf(packageName).isNotEmpty) return false;
    var scopes = scopesOf(packageName);
    return scopes.isNotEmpty && scopes.every((s) => s == ImportScope.test);
  }

  /// Parses the `.dart` files under [root] and records their package
  /// references.
  ///
  /// Directives only: an unresolved `parseString` is enough to read an import
  /// URI, and resolving would mean a full analysis session per package.
  ///
  /// [flutterSection] is the `flutter:` map of [root]'s own pubspec, when it
  /// has one, so assets are counted alongside imports.
  static PackageImports gather(
    String root,
    Iterable<File> dartFiles, {
    Map<String, Object?>? flutterSection,
  }) {
    var results = <String, List<PackageImport>>{};
    for (var file in dartFiles) {
      String content;
      try {
        content = file.readAsStringSync();
      } catch (_) {
        continue;
      }
      var result = parseString(
        content: content,
        path: file.path,
        throwIfDiagnostics: false,
      );
      if (result.errors.isNotEmpty) continue;

      var relative = p.relative(file.path, from: root);
      var scope = ImportScope.of(relative);

      for (var directive in result.unit.directives) {
        if (directive is! NamespaceDirective) continue;

        void record(String? uri, String? condition) {
          if (uri == null || !uri.startsWith('package:')) return;
          var parsed = Uri.tryParse(uri);
          if (parsed == null || parsed.pathSegments.isEmpty) return;

          (results[parsed.pathSegments.first] ??= []).add(
            PackageImport(
              path: relative,
              uri: uri,
              scope: scope,
              isExport: directive is ExportDirective,
              condition: condition,
            ),
          );
        }

        record(directive.uri.stringValue, null);
        for (var configuration in directive.configurations) {
          record(configuration.uri.stringValue, configuration.name.toSource());
        }
      }
    }
    return PackageImports(results, assetsByPackage: _assets(flutterSection));
  }

  /// Reads `packages/<name>/…` out of `flutter: assets:` and `flutter: fonts:`.
  ///
  /// Tolerant by design: this walks user-written YAML of a shape Flutter keeps
  /// extending — an asset entry is a bare path today and a map with `path:` and
  /// `flavors:` since 3.19 — and a shape it does not recognise is one missing
  /// reference, not an exception on the way into the panel.
  static Map<String, List<PackageAssetReference>> _assets(
    Map<String, Object?>? flutter,
  ) {
    if (flutter == null) return const {};
    var results = <String, List<PackageAssetReference>>{};

    void record(Object? path, {required bool isFont}) {
      if (path is! String) return;
      var segments = p.url.split(path);
      if (segments.length < 2 || segments.first != 'packages') return;
      (results[segments[1]] ??= []).add(
        PackageAssetReference(path: path, isFont: isFont),
      );
    }

    for (var asset in _list(flutter['assets'])) {
      record(asset is Map ? asset['path'] : asset, isFont: false);
    }
    for (var family in _list(flutter['fonts'])) {
      if (family is! Map) continue;
      for (var font in _list(family['fonts'])) {
        record(font is Map ? font['asset'] : null, isFont: true);
      }
    }

    return results;
  }

  /// `as List?` would throw on the scalar someone eventually writes there.
  static List<Object?> _list(Object? value) => value is List ? value : const [];
}
