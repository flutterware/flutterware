import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Every asset key a package's bundle resolves to, and the file behind each one.
///
/// This is Flutter's asset resolution written in plain Dart — no Flutter, no
/// `flutter_tools`, no build. It answers the only question that matters about
/// an asset: **what will `Image.asset('…')` find at run time**, which is not the
/// same question as what is on disk.
///
/// Two consumers, and that is the point. `AssetBundleBuilder` turns this
/// into the manifests the embedder guest reads; the asset inspector turns it
/// into what the panel, `fw` and MCP show. A second implementation would be a
/// second set of answers to "does this key resolve", and the one the user reads
/// would be the one nothing verifies. Here, the inspector is right exactly when
/// the guest renders.
///
/// What it deliberately does not do: [resolve] reads and parses, and nothing
/// else. No decoding, no hashing, no `flutter pub get` — that keeps it inside
/// `PluginCore.computeAll`'s budget, so every surface can call it freely.
///
/// `transformers:` are read here and **run** by `AssetBundleBuilder`, which
/// serves their output — see [AssetTransformer] and the 2026-08-17 design. This
/// class only records the chain: running one spawns a process, and [resolve]
/// reads and parses.
///
/// Not yet handled, and absent rather than half-done: `flavors:` on an asset
/// entry and `.lottie` archives.
class AssetCatalog {
  AssetCatalog._({
    required this.assets,
    required this.declarations,
    required this.fonts,
    required this.shaders,
    required this.usesMaterialDesign,
    required this.problems,
  });

  /// Resolved keys, in the order the engine's manifest lists them: the root
  /// package first — its keys are unprefixed — then each package in the config,
  /// and within a package its assets before its fonts.
  ///
  /// The order is load-bearing. `AssetManifest.bin` is an encoded map, and a
  /// reordering would rewrite every byte of it for no reason.
  final List<ResolvedAsset> assets;

  /// Every `assets:` entry that was read, resolved or not.
  ///
  /// Kept because the assets alone cannot answer "what did this project ask
  /// for": a directory declaration whose files all sit one level deeper
  /// produces no assets at all, and that is precisely the case worth reporting.
  final List<AssetDeclaration> declarations;

  final List<FontFamily> fonts;

  /// Every `shaders:` entry that resolved to a file on disk.
  ///
  /// Not in [assets]: a shader's bundle bytes are what `impellerc` compiles
  /// it to, not the `.frag` source, and `FragmentProgram.fromAsset` does not
  /// consult `AssetManifest.bin` at all — so anything that walks [assets]
  /// (the manifest, byte totals, the asset tree) must not see one.
  final List<ResolvedShader> shaders;

  /// True when *any* package in the bundle asks for it, which is what pulls
  /// `MaterialIcons-Regular.otf` in.
  final bool usesMaterialDesign;

  /// What was declared and could not be resolved.
  ///
  /// Collected rather than skipped: a declaration that silently resolves to
  /// nothing is the single most common asset bug, and the old code's `return`
  /// on a missing file is exactly why nothing could report it. Includes
  /// problems found in dependencies — whose pubspecs are not the project's
  /// fault, which is why each one records the package it came from.
  final List<AssetProblem> problems;

  late final Map<String, ResolvedAsset> byKey = {
    for (var asset in assets) asset.key: asset,
  };

  /// Resolves the bundle for [rootPackageRoot] — its own assets, plus those of
  /// every package it actually depends on.
  ///
  /// Depends on, not "is in the package config". A config resolves imports,
  /// and in a pub workspace it resolves them for every member at once, so
  /// walking it would put a sibling app's assets in this app's bundle. It would
  /// pull in dev-dependencies too. `flutter_tools` filters the same way and
  /// says why in the same words — see `computeTransitiveDependencies` at
  /// `asset.dart:423` in 3.47.0-0.1.pre.
  ///
  /// Dev-dependencies are excluded outright, which is what a build does; the
  /// tool keeps a flag to include them when building a test bundle, and nothing
  /// here has asked for one.
  static Future<AssetCatalog> resolve({
    required String rootPackageRoot,
    required String packageConfigPath,
  }) async {
    var config = await loadPackageConfig(File(packageConfigPath));
    var builder = _Resolver(rootPackageRoot, config);

    // The root package first: its asset keys are unprefixed.
    builder.readPubspec(rootPackageRoot, packageName: null);

    var reachable = builder.dependenciesOf(rootPackageRoot);
    // Config order rather than discovery order, so the manifest a bundle writes
    // stays stable as dependencies are added and removed.
    for (var package in config.packages) {
      if (!package.root.isScheme('file')) continue;
      if (!reachable.contains(package.name)) continue;
      // Normalised because a package config's root always ends in a slash, and
      // this path is handed out on every asset as `ResolvedAsset.packageRoot`.
      var root = p.normalize(p.fromUri(package.root));
      if (p.equals(root, rootPackageRoot)) continue;
      builder.readPubspec(root, packageName: package.name);
    }

    return AssetCatalog._(
      assets: builder.assets.values.toList(),
      declarations: builder.declarations,
      fonts: builder.fonts,
      shaders: builder.shaders,
      usesMaterialDesign: builder.usesMaterialDesign,
      problems: builder.problems,
    );
  }

  /// `assets/2.0x/foo.png` -> 2.0. Null when the path has no density segment.
  static double? parseScale(String path) {
    for (var segment in p.split(path)) {
      var match = _densityDirectory.firstMatch(segment);
      if (match != null) return double.tryParse(match.group(1)!);
    }
    return null;
  }
}

/// A density directory: `2.0x`, and equally `3x` or `2.7x`. **Not** `dark` —
/// there is no such thing as a theme variant, whatever a directory beside an
/// asset happens to be called.
///
/// `flutter_tools` spells this `RegExp(r'/?(\d+(\.\d*)?)x$')`
/// (`asset.dart:111` and `:935` in 3.47.0-0.1.pre, whose own comment offers
/// `plants/3x` as a match), and this must keep agreeing with it — a disagreement
/// here is a bundle whose `dpr` values differ from the tool's.
///
/// Two deliberate differences, both narrowing:
///
/// - anchored, so a directory named `foo2x` is not a variant directory here
///   while `flutter_tools`' suffix match accepts it;
/// - matched against every path segment rather than only the key's immediate
///   parent, which is what `_createAssetManifestBinary` inspects.
final _densityDirectory = RegExp(r'^(\d+(\.\d*)?)x$');

/// One asset key, and every file that serves it.
class ResolvedAsset {
  ResolvedAsset({
    required this.key,
    required this.package,
    required this.packageRoot,
    required this.declaration,
    required this.files,
    this.transformers = const [],
  });

  /// What `Image.asset` is given: `assets/logo.png` for the root package,
  /// `packages/<name>/assets/logo.png` for anything else.
  final String key;

  /// The package that declared it, or null for the root package — whose assets
  /// are the only unprefixed ones.
  final String? package;

  /// Absolute path to the root [files] sit under, so a reader can make them
  /// relative to something a human recognises.
  ///
  /// Usually [package]'s root. For a `packages/<name>/…` declaration it is
  /// `<name>`'s root instead — the declarer does not have the file, which is
  /// the entire point of that form.
  final String packageRoot;

  /// The pubspec entry that pulled this in — `assets/images/` for a directory
  /// declaration, the path itself for a file one.
  ///
  /// Kept because "why is this in my bundle" is a question about the
  /// declaration, not the file, and a directory declaration is answerable no
  /// other way.
  final String declaration;

  /// The main asset and its density variants, in manifest order.
  final List<AssetFile> files;

  /// The chain the declaration attached, applied to every file here.
  ///
  /// Carried onto the asset rather than left on the declaration because the
  /// bundle builder walks assets: it has to reach the chain from the file it is
  /// about to link, and looking the declaration back up by its string is a join
  /// that can miss.
  final List<AssetTransformer> transformers;

  /// The file used at 1× — the one the key names directly.
  AssetFile get main =>
      files.firstWhere((f) => f.scale == null, orElse: () => files.first);

  /// The density variants found beside [main].
  Iterable<AssetFile> get variants => files.where((f) => f.scale != null);

  bool get isFont => _fontExtensions.contains(p.extension(key).toLowerCase());

  int get totalBytes {
    var total = 0;
    for (var file in files) {
      total += file.length;
    }
    return total;
  }

  @override
  String toString() => 'ResolvedAsset($key, ${files.length} file(s))';
}

const _fontExtensions = {'.ttf', '.otf', '.ttc', '.woff', '.woff2'};

/// One `assets:` entry, as the pubspec wrote it.
class AssetDeclaration {
  AssetDeclaration({
    required this.package,
    required this.packageRoot,
    required this.path,
    this.transformers = const [],
  });

  /// The package that declared it; null for the root package.
  final String? package;

  final String packageRoot;

  /// Verbatim, trailing slash included — which is the part that decides whether
  /// this names one file or the files directly inside a directory.
  final String path;

  /// What a build runs over every file this declaration reaches, in order.
  ///
  /// Empty for the ordinary declaration. Kept rather than reported: the bundle
  /// builder runs these, so what is here decides which bytes the guest gets —
  /// see [AssetTransformer].
  final List<AssetTransformer> transformers;

  bool get isDirectory => path.endsWith('/');
}

/// One `transformers:` entry — a package to run, and what to pass it.
///
/// A build spawns `dart run <package> --input=<tmp> --output=<tmp> <args>` and
/// ships the output, chaining each transformer's output into the next
/// (`asset_transformer.dart` in flutter_tools). Reproduced rather than
/// approximated: the catalog's bundle serves the *output*, so an argument
/// dropped here is a preview rendering bytes the app will never see.
class AssetTransformer {
  const AssetTransformer({required this.package, this.args = const []});

  /// The package name, as `dart run` takes it.
  final String package;

  final List<String> args;

  /// Every distinguishing input as one line, for a cache key and for a reader.
  @override
  String toString() => [package, ...args].join(' ');
}

/// One file behind an asset key.
class AssetFile {
  AssetFile({
    required this.path,
    required this.key,
    required this.scale,
    int? length,
    // Not an initializing formal: the field is the lazy cache behind `length`,
    // and a named parameter cannot be spelled `_length`.
    // ignore: prefer_initializing_formals
  }) : _length = length;

  /// Absolute path on disk.
  final String path;

  /// This file's own manifest key. Equal to the asset's key for the main file;
  /// a variant splices its density directory back in.
  final String key;

  /// The density this file serves, or null for the main asset.
  final double? scale;

  /// Size in bytes, `stat`ed on first ask and remembered.
  ///
  /// Can be supplied instead, which is what lets a catalog demo build an asset
  /// that never existed. The resolver never passes it: a file it registered is
  /// a file it found, so the stat cannot fail.
  int get length => _length ??= File(path).lengthSync();
  int? _length;

  @override
  String toString() => 'AssetFile($key${scale == null ? '' : ' @${scale}x'})';
}

/// A font family, as the engine's `FontManifest.json` describes it.
class FontFamily {
  FontFamily({
    required this.family,
    required this.package,
    required this.fonts,
  });

  /// Already package-prefixed, the way the manifest carries it.
  final String family;

  final String? package;
  final List<FontAsset> fonts;

  @override
  String toString() => 'FontFamily($family, ${fonts.length} font(s))';
}

class FontAsset {
  FontAsset({
    required this.key,
    required this.path,
    required this.weight,
    required this.style,
  });

  /// The asset key of the font file — fonts are assets too, and appear in
  /// [AssetCatalog.assets] under this key.
  final String key;

  /// Absolute path on disk.
  final String path;

  /// What the pubspec *claims*. Whether the file agrees is a different
  /// question, and not one this class asks.
  final int? weight;
  final String? style;
}

/// One `shaders:` entry, resolved to a file.
///
/// Deliberately thin next to [ResolvedAsset]: a shader is a flat list of
/// paths — no directories, no maps, no transformers, no density variants — so
/// there is nothing here for a build to chain onto.
class ResolvedShader {
  ResolvedShader({
    required this.key,
    required this.package,
    required this.packageRoot,
    required this.declaration,
    required this.source,
  });

  /// What a build names it: `shaders/glow.frag` for the root package,
  /// `packages/<name>/shaders/glow.frag` for anything else, and the
  /// declaration itself when it reaches into a package's `lib/` through
  /// `packages/<name>/…`.
  final String key;

  /// The package that declared it, or null for the root package.
  final String? package;

  /// Absolute path to the root [source] sits under — the declarer's, or for a
  /// `packages/…` reach the package it reaches into.
  final String packageRoot;

  /// The pubspec entry as written.
  final String declaration;

  /// Absolute path of the `.frag` file on disk.
  final String source;

  @override
  String toString() => 'ResolvedShader($key)';
}

/// What a scan is willing to call a problem.
///
/// Three, where there were six. The three that went are the ones `flutter
/// analyze` already reports against the pubspec, with a line and a column this
/// panel has never had — a missing file (`asset_does_not_exist`), a missing
/// directory (`asset_directory_does_not_exist`), an entry with no path
/// (`asset_missing_path`) — plus a malformed font entry, which no flutter
/// command will run past at all: it stops with "Please correct the
/// pubspec.yaml file" before anything else happens.
///
/// Repeating them cost more than it looked. Every problem here becomes a
/// `declared-missing` finding in `audit`, whose verdict makes `fw` exit 1, and
/// puts an amber badge on the plugin's row — so a finding that only echoes the
/// analyzer teaches a reader to skim past the two that nothing else says.
/// Measured against `flutter analyze` on a real project (2026-08-26), the
/// two below are exactly what it stays silent about.
enum AssetProblemKind {
  /// A `packages/<name>/…` declaration that resolves to nothing — either no
  /// package answers to the prefix, or the one that does has no such file.
  /// The analyzer says nothing about either.
  unreachablePackageFile('Declared through packages/…, and not found.'),

  /// The analyzer does not look at `fonts:` at all, and a font's main file is
  /// the one asset Flutter will not build without: `asset.dart` accepts an
  /// absent 1× file when variants exist, and never for a font.
  missingFontFile('Font file declared, and not on disk.'),

  /// Neither does it look at `shaders:`.
  missingShaderFile('Shader declared, and not on disk.'),

  /// Kept for the root package only. In a dependency it says our YAML parser
  /// disagreed with the one pub resolved the package with, about a file the
  /// reader does not own and cannot edit.
  unreadablePubspec('The pubspec could not be parsed.');

  const AssetProblemKind(this.summary);

  final String summary;
}

/// Something declared that resolves to nothing.
class AssetProblem {
  AssetProblem({
    required this.kind,
    required this.package,
    required this.packageRoot,
    required this.declaration,
    this.detail,
  });

  final AssetProblemKind kind;

  /// The package whose pubspec declared it; null for the root package.
  final String? package;

  final String packageRoot;

  /// What the pubspec said — the path, or the family for a font problem.
  final String declaration;

  /// The underlying error, where there was one.
  final String? detail;

  @override
  String toString() =>
      '${kind.summary} ${package == null ? '' : '[$package] '}$declaration';
}

/// Accumulates one bundle's resolution.
///
/// Separate from [AssetCatalog] so the catalog itself is immutable, and so the
/// map semantics stay visible: a re-registered key **overwrites in place**
/// (keeping its original position), while a font file already registered as an
/// asset keeps the registration it had. Both match what the engine's manifest
/// used to be built from, and both are why this is a map rather than a list.
class _Resolver {
  _Resolver(this.rootPackageRoot, this.config);

  final String rootPackageRoot;
  final PackageConfig config;

  final assets = <String, ResolvedAsset>{};
  final declarations = <AssetDeclaration>[];
  final fonts = <FontFamily>[];
  final shaders = <ResolvedShader>[];
  final problems = <AssetProblem>[];
  var usesMaterialDesign = false;

  /// Every package [packageRoot] depends on, transitively, by name.
  ///
  /// `dependencies:` only. A dev-dependency reached no other way is not in the
  /// bundle, and the walk is what keeps a pub workspace's other members out of
  /// it — they are in the config, and they are not dependencies.
  Set<String> dependenciesOf(String packageRoot) {
    var seen = <String>{};
    var queue = [..._declaredDependencies(packageRoot)];
    while (queue.isNotEmpty) {
      var name = queue.removeLast();
      if (!seen.add(name)) continue;
      var package = config[name];
      if (package == null || !package.root.isScheme('file')) continue;
      queue.addAll(_declaredDependencies(p.normalize(p.fromUri(package.root))));
    }
    return seen;
  }

  Iterable<String> _declaredDependencies(String packageRoot) {
    var declared = _pubspecAt(packageRoot)?['dependencies'];
    if (declared is! YamlMap) return const [];
    return [
      for (var name in declared.keys)
        if (name is String) name,
    ];
  }

  /// Parsed once per package: the dependency walk and the asset read both want
  /// it, and a pubspec is read for every package in the bundle.
  YamlMap? _pubspecAt(String packageRoot) {
    if (_pubspecs.containsKey(packageRoot)) return _pubspecs[packageRoot];

    YamlMap? parsed;
    var file = File(p.join(packageRoot, 'pubspec.yaml'));
    if (file.existsSync()) {
      try {
        parsed = loadYaml(file.readAsStringSync()) as YamlMap?;
      } catch (e) {
        _unreadable[packageRoot] = '$e';
      }
    }
    return _pubspecs[packageRoot] = parsed;
  }

  final _pubspecs = <String, YamlMap?>{};
  final _unreadable = <String, String>{};

  void readPubspec(String packageRoot, {required String? packageName}) {
    var pubspec = _pubspecAt(packageRoot);
    if (_unreadable[packageRoot] case var error?) {
      // The root package only. A dependency's pubspec that we cannot parse but
      // pub could is a disagreement between two YAML readers about a file the
      // reader of this panel does not own — reporting it badges their project
      // for someone else's formatting, and offers nothing to do about it.
      if (packageName == null) {
        problems.add(
          AssetProblem(
            kind: AssetProblemKind.unreadablePubspec,
            package: packageName,
            packageRoot: packageRoot,
            declaration: 'pubspec.yaml',
            detail: error,
          ),
        );
      }
      return;
    }
    if (pubspec == null) return;

    var flutter = pubspec['flutter'];
    if (flutter is! YamlMap) return;

    if (flutter['uses-material-design'] == true) usesMaterialDesign = true;

    var declared = flutter['assets'];
    if (declared is YamlList) {
      for (var entry in declared) {
        if (entry is String) {
          _addAsset(packageRoot, entry, packageName);
        } else if (entry is YamlMap && entry['path'] is String) {
          _addAsset(
            packageRoot,
            entry['path'] as String,
            packageName,
            transformers: _transformersOf(entry['transformers']),
          );
        }
        // An entry that is neither is left alone: `flutter analyze` reports it
        // as `asset_missing_path`, at the line it is on.
      }
    }

    var declaredFonts = flutter['fonts'];
    if (declaredFonts is YamlList) {
      _addFonts(packageRoot, declaredFonts, packageName);
    }

    var declaredShaders = flutter['shaders'];
    if (declaredShaders is YamlList) {
      _addShaders(packageRoot, declaredShaders, packageName);
    }
  }

  /// The `transformers:` list of one asset entry, in the order a build runs it.
  ///
  /// `{package: name, args: […]}` in the manifest, or a bare string. An entry
  /// naming no package is dropped rather than reported: there is nothing to
  /// run, and a build reads the same list the same way.
  static List<AssetTransformer> _transformersOf(Object? declared) {
    if (declared is! YamlList) return const [];
    return [
      for (var transformer in declared)
        switch (transformer) {
          YamlMap map when map['package'] is String => AssetTransformer(
            package: map['package'] as String,
            args: [
              // Stringified rather than cast: a `--font-size: 14` in the
              // pubspec parses as an int, and the process takes text.
              for (var arg in (map['args'] as YamlList?) ?? const []) '$arg',
            ],
          ),
          String package => AssetTransformer(package: package),
          _ => null,
        },
    ].nonNulls.toList();
  }

  /// A declaration is either a file or, when it ends in `/`, every file
  /// **directly** inside that directory.
  ///
  /// Not recursive, and that is Flutter's rule rather than a shortcut here:
  /// declaring `assets/` leaves `assets/icons/star.png` out of the bundle while
  /// leaving it plainly visible on disk. `fixtures/probe_app` carries a fixture
  /// for it.
  void _addAsset(
    String packageRoot,
    String declaration,
    String? packageName, {
    List<AssetTransformer> transformers = const [],
  }) {
    declarations.add(
      AssetDeclaration(
        package: packageName,
        packageRoot: packageRoot,
        path: declaration,
        transformers: transformers,
      ),
    );

    String key(String relative) =>
        packageName == null ? relative : 'packages/$packageName/$relative';

    if (declaration.endsWith('/')) {
      // No `packages/…` reach for a directory: `_parseAssetsFromFolder`
      // resolves the path literally and errors when it is absent
      // (asset.dart:1168 in 3.47.0-0.1.pre), so a reach here would put files
      // in this bundle that no build would carry.
      var directory = Directory(p.join(packageRoot, declaration));
      // Absent is not reported: `flutter analyze` says
      // `asset_directory_does_not_exist` with the line it is declared on.
      if (!directory.existsSync()) return;
      for (var entity in directory.listSync()) {
        if (entity is! File) continue;
        var relative = p
            .split(p.relative(entity.path, from: packageRoot))
            .join('/');
        _register(
          key(relative),
          entity.path,
          packageRoot,
          relative,
          packageName,
          declaration,
          transformers,
        );
      }
    } else {
      var file = File(p.join(packageRoot, declaration));
      // Not `existsSync` first: a declaration whose 1× file is absent still
      // resolves on the strength of its density variants, which is what
      // `asset.dart:535` means by `!assetFile.existsSync() && variants.isEmpty`
      // — and what `flutter analyze` is quietly right about when it stays
      // silent on such a declaration. Registering on the variants is why the
      // asset appears at all; checking existence here made it vanish *and*
      // filed a problem against a bundle Flutter ships.
      if (_register(
        key(declaration),
        file.path,
        packageRoot,
        declaration,
        packageName,
        declaration,
        transformers,
      )) {
        return;
      }
      if (_packageReach(declaration) case var reach?) {
        // The key is the declaration verbatim — already `packages/…`, and
        // never re-prefixed with the declarer's name.
        if (_register(
          declaration,
          p.join(reach.root, reach.relative),
          reach.root,
          reach.relative,
          packageName,
          declaration,
          transformers,
        )) {
          return;
        }
        problems.add(
          AssetProblem(
            kind: AssetProblemKind.unreachablePackageFile,
            package: packageName,
            packageRoot: packageRoot,
            declaration: declaration,
            detail:
                'Reaches into package "${reach.name}", and '
                '${reach.relative} is not there.',
          ),
        );
        return;
      }
      // A plain path that resolved to nothing is left to `flutter analyze`,
      // which reports it as `asset_does_not_exist` with its line and column.
      // Only the `packages/…` form is ours: nothing else in the toolchain
      // looks at it.
      if (declaration.startsWith('packages/')) {
        problems.add(
          AssetProblem(
            kind: AssetProblemKind.unreachablePackageFile,
            package: packageName,
            packageRoot: packageRoot,
            declaration: declaration,
            detail: 'No package in the config answers to this prefix.',
          ),
        );
      }
    }
  }

  /// Where a `packages/<name>/…` declaration reaches when the literal path is
  /// absent: into `<name>`'s `lib/`.
  ///
  /// The literal path winning first is `flutter_tools`' rule, not a
  /// convenience — `_resolveAsset` at asset.dart:1402 in 3.47.0-0.1.pre tries
  /// the declarer's own tree before `_resolvePackageAsset` reaches out, so a
  /// project with a real `packages/` directory keeps meaning its own files.
  ///
  /// Null when the shape does not match or the config has no such package,
  /// which the caller reports rather than swallows: the tool prints "Could not
  /// resolve package for asset" and fails the build on the same input.
  ({String name, String root, String relative})? _packageReach(
    String declaration,
  ) {
    var segments = declaration.split('/');
    if (segments.length < 3 || segments.first != 'packages') return null;
    var package = config[segments[1]];
    if (package == null || !package.root.isScheme('file')) return null;
    var root = p.normalize(p.fromUri(package.root));
    var lib = p.normalize(p.fromUri(package.packageUriRoot));
    return (
      name: segments[1],
      root: root,
      relative: p
          .split(
            p.join(p.relative(lib, from: root), p.joinAll(segments.sublist(2))),
          )
          .join('/'),
    );
  }

  /// Registers an asset plus any `2.0x/`-style density variants beside it.
  ///
  /// [packageRoot] is the root [relative] sits under — the declarer's, or for
  /// a `packages/…` reach the package it reaches into, so a reader making the
  /// path relative gets `lib/images/logo.png` under a root a human knows.
  /// Whether the declaration resolved to anything.
  ///
  /// False for a key with no file behind it at any density, which is what lets
  /// the caller try the next resolution — and, for a `packages/…` form, file
  /// the one problem nothing else in the toolchain reports.
  bool _register(
    String manifestKey,
    String absolute,
    String packageRoot,
    String relative,
    String? packageName,
    String declaration,
    List<AssetTransformer> transformers,
  ) {
    // A variant directory is itself listed when a whole directory is declared;
    // it must not become an entry of its own.
    if (AssetCatalog.parseScale(relative) != null) return false;

    // The 1× file only if it is there. An image whose main entry is absent but
    // whose `2.0x/` sibling is not is a bundle Flutter builds — the manifest
    // carries the variants and the engine picks among them.
    var paths = [if (File(absolute).existsSync()) absolute];
    var directory = p.dirname(p.join(packageRoot, relative));
    var name = p.basename(relative);
    var parent = Directory(directory);
    if (parent.existsSync()) {
      for (var entity in parent.listSync().whereType<Directory>()) {
        if (AssetCatalog.parseScale('${p.basename(entity.path)}/') == null) {
          continue;
        }
        var candidate = File(p.join(entity.path, name));
        if (candidate.existsSync()) paths.add(candidate.path);
      }
    }
    if (paths.isEmpty) return false;
    paths.sort();

    assets[manifestKey] = ResolvedAsset(
      key: manifestKey,
      package: packageName,
      packageRoot: packageRoot,
      declaration: declaration,
      transformers: transformers,
      files: [
        for (var path in paths)
          AssetFile(
            path: path,
            key: _keyFor(manifestKey, path),
            scale: AssetCatalog.parseScale(_keyFor(manifestKey, path)),
          ),
      ],
    );
    return true;
  }

  void _addFonts(String packageRoot, YamlList declared, String? packageName) {
    for (var family in declared) {
      if (family is! YamlMap) continue;
      var name = family['family'];
      var declaredFonts = family['fonts'];
      if (name is! String || declaredFonts is! YamlList) continue;

      var entries = <FontAsset>[];
      for (var font in declaredFonts) {
        if (font is! YamlMap) continue;
        var asset = font['asset'];
        if (asset is! String) continue;
        // The same resolution an asset declaration gets, with the same
        // precedence: the literal path under the declarer wins, and only in
        // its absence does `packages/<name>/…` reach into <name>'s lib/.
        // `_parsePackageFonts` (asset.dart:976 in 3.47.0-0.1.pre) applies the
        // rule to the keys and the bundle add at asset.dart:1141 to the files.
        var file = File(p.join(packageRoot, asset));
        var fileRoot = packageRoot;
        String manifestKey;
        if (file.existsSync()) {
          manifestKey = packageName == null
              ? asset
              : 'packages/$packageName/$asset';
        } else {
          var reach = _packageReach(asset);
          var reached = reach == null
              ? null
              : File(p.join(reach.root, reach.relative));
          if (reached == null || !reached.existsSync()) {
            problems.add(
              AssetProblem(
                kind: AssetProblemKind.missingFontFile,
                package: packageName,
                packageRoot: packageRoot,
                declaration: asset,
                detail: 'Declared by family "$name".',
              ),
            );
            continue;
          }
          file = reached;
          fileRoot = reach!.root;
          manifestKey = asset;
        }
        // A font file already registered as an asset keeps that registration:
        // it carries the declaration that pulled it in, and this one would say
        // only that a font pointed at it.
        assets.putIfAbsent(
          manifestKey,
          () => ResolvedAsset(
            key: manifestKey,
            package: packageName,
            packageRoot: fileRoot,
            declaration: asset,
            files: [AssetFile(path: file.path, key: manifestKey, scale: null)],
          ),
        );

        // `weight` and `style` are dropped rather than passed through when the
        // pubspec gives them a type the manifest cannot carry. Dropped and not
        // reported: such a pubspec stops every flutter command before it
        // starts — "Invalid value … for font -> weight", then "Please correct
        // the pubspec.yaml file" — so nobody reaches this panel holding one.
        // Flutter is stricter still, taking only 100–900 and only
        // normal/italic, which is a second reason not to paraphrase it here.
        var weight = font['weight'];
        var style = font['style'];
        entries.add(
          FontAsset(
            key: manifestKey,
            path: file.path,
            weight: weight is int ? weight : null,
            style: style is String ? style : null,
          ),
        );
      }
      if (entries.isEmpty) continue;
      fonts.add(
        FontFamily(
          family: packageName == null ? name : 'packages/$packageName/$name',
          package: packageName,
          fonts: entries,
        ),
      );
    }
  }

  /// `flutter: shaders:` is a flat list of file paths — no directories, no
  /// maps, no transformers — each resolved the way `flutter_tools` resolves an
  /// asset file, because that is the code it runs through (`_parseAssetFromFile`
  /// with `AssetKind.shader`): the declarer's own path first, then a
  /// `packages/<name>/…` reach into `<name>`'s `lib/`, keyed by the declaration
  /// as written. `material_ui` declares its ink-sparkle program that way and
  /// loads it by that key, so a bundle without the reach has no Material
  /// ripple in it.
  void _addShaders(String packageRoot, YamlList declared, String? packageName) {
    for (var entry in declared) {
      if (entry is! String) continue;
      var source = p.normalize(p.join(packageRoot, entry));
      if (File(source).existsSync()) {
        shaders.add(
          ResolvedShader(
            key: packageName == null ? entry : 'packages/$packageName/$entry',
            package: packageName,
            packageRoot: packageRoot,
            declaration: entry,
            source: source,
          ),
        );
        continue;
      }
      if (_packageReach(entry) case var reach?) {
        var reached = p.normalize(p.join(reach.root, reach.relative));
        if (File(reached).existsSync()) {
          shaders.add(
            ResolvedShader(
              key: entry,
              package: packageName,
              packageRoot: reach.root,
              declaration: entry,
              source: reached,
            ),
          );
          continue;
        }
      }
      problems.add(
        AssetProblem(
          kind: AssetProblemKind.missingShaderFile,
          package: packageName,
          packageRoot: packageRoot,
          declaration: entry,
        ),
      );
    }
  }

  /// The manifest key of one variant of [key] — the main asset keeps the key,
  /// a variant gets its density directory spliced back in.
  String _keyFor(String key, String absolute) {
    var scaleDir = p.basename(p.dirname(absolute));
    if (AssetCatalog.parseScale('$scaleDir/') == null) return key;
    return '${p.dirname(key)}/$scaleDir/${p.basename(key)}';
  }
}
