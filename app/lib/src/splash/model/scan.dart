/// Reading one package's splash setup off disk.
///
/// The budget here is the plugin-core budget: read files, parse them, `stat`
/// them, cache the result (`PluginCore.computeAll`). Nothing in this file
/// compiles, spawns or resolves — running the real generator is an action,
/// where a caller chose it by name.
///
/// It stays on the calling isolate deliberately. The asset inspector hands its
/// scan to `Isolate.run` because a real project is a few thousand `stat`s; a
/// splash config references about a dozen files, and the cost of shipping a
/// closure to another isolate would exceed the work.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'composition.dart';
import 'config.dart';
import 'files.dart';
import 'generated.dart';
import 'image_facts.dart';
import 'recompose.dart';
import 'surface.dart';
import 'validation.dart';

/// What a `flutter_native_splash-<flavor>.yaml` is called.
///
/// Public because the fingerprint has to find the same files this scan does —
/// a flavor file that one of them recognises and the other does not is a config
/// whose edits never reach the panel.
final splashFlavorFilePattern = RegExp(r'^flutter_native_splash-(.+)\.yaml$');

/// Everything one package's splash setup turned out to be.
class SplashScan {
  SplashScan({
    required this.packagePath,
    required this.configs,
    this.configErrors = const [],
    this.hasDevDependency = true,
  });

  /// Workspace-relative — `.`, `fixtures/probe_app`.
  final String packagePath;

  /// The default config first, then one per flavor file. Empty when the project
  /// has no splash config at all, which is not an error: it is what a project
  /// that has not set one up looks like.
  final List<SplashConfigScan> configs;

  /// Files that look like a config but the generator would refuse. Kept apart
  /// from [SplashConfigScan.problems] because there is no config to attach them
  /// to — that is the whole complaint.
  final List<String> configErrors;

  final bool hasDevDependency;

  bool get isConfigured => configs.isNotEmpty;

  SplashConfigScan? get main => configs.isEmpty ? null : configs.first;

  /// The config for [flavor], or the default one when null.
  SplashConfigScan? forFlavor(String? flavor) {
    if (flavor == null) return main;
    for (var scan in configs) {
      if (scan.config.flavor == flavor) return scan;
    }
    return null;
  }

  List<String> get flavors => [
    for (var scan in configs)
      if (scan.config.flavor != null) scan.config.flavor!,
  ];
}

/// One cell's picture, and where it came from.
///
/// The provenance is not a footnote, it is the confidence. A picture read
/// back from the generated files is what the device will show. A picture
/// derived from the config is our reading of a third-party generator's rules,
/// and this plugin has already shipped that reading backwards once. The two
/// must never look alike on screen, so every consumer takes them together.
class SplashPicture {
  const SplashPicture.generated(this.composition)
    : isGenerated = true,
      reason = null;

  const SplashPicture.predicted(this.composition, {required this.reason})
    : isGenerated = false;

  final SplashComposition composition;

  /// Read back from the files `create` wrote, rather than derived from config.
  final bool isGenerated;

  /// Why there was nothing to read back. Null when [isGenerated].
  final String? reason;

  /// Short enough for a matrix cell, where the full [reason] would not fit and
  /// eight copies of it would drown the pictures.
  String get label => isGenerated ? 'From the generated files' : 'Prediction';
}

/// One config file, everything it references, and everything wrong with it.
class SplashConfigScan {
  SplashConfigScan({
    required this.config,
    required this.images,
    required this.artifacts,
    required this.problems,
    required this.stale,
    this.launcherIcon,
    this.recompositions = const {},
  });

  final SplashConfig config;

  /// What the generated files say each cell looks like, read once when the scan
  /// ran. Missing for a cell that had nothing to read back.
  ///
  /// Read here rather than on demand. Recomposing parses `web/index.html`
  /// and a stack of drawable XML off disk, and it used to happen inside
  /// [pictureFor] — which the panel calls nine times per build. That was 5.8ms
  /// of synchronous I/O on the UI isolate every time anything rebuilt, on a
  /// project with 66 artifacts. Everything else here is computed once by
  /// `_scanConfig` and kept; this was the one exception, and it was the
  /// expensive one.
  final Map<(SplashSurface, SplashTheme), SplashComposition> recompositions;

  /// Keyed by the path the config wrote, so a lookup needs nothing but the
  /// config value.
  final Map<String, SplashImageFacts> images;

  /// The app icon Android 12 shows when `android_12.image` resolves nothing.
  /// Null when the package has no Android folder or no mipmaps.
  final SplashImageFacts? launcherIcon;

  /// What the generator has already produced. Empty until `generate` runs.
  final List<SplashArtifact> artifacts;

  final List<SplashProblem> problems;

  /// The config is newer than the newest generated file.
  final bool stale;

  bool get isGenerated => artifacts.isNotEmpty;

  SplashImageFacts? factsFor(String path) => images[path];

  /// The resolution for one cell — pure, so it is safe to call per build.
  SplashResolution resolutionFor(SplashSurface surface, SplashTheme theme) =>
      resolveSplash(config, surface, theme);

  /// The composition for one cell — what the panel draws and what the guest is
  /// handed.
  SplashComposition compositionFor(SplashSurface surface, SplashTheme theme) =>
      composeSplash(
        resolutionFor(surface, theme),
        facts: factsFor,
        launcherIcon: launcherIcon,
      );

  /// What one cell looks like, and whether that is a fact or a guess.
  ///
  /// The generated files win wherever they exist. iOS is the one surface where
  /// they never can — `LaunchScreen.storyboard` is constraints, which is a
  /// layout engine rather than a recipe — so it is predicted permanently, and
  /// the [SplashPicture.reason] says so rather than leaving it to be inferred.
  SplashPicture pictureFor(SplashSurface surface, SplashTheme theme) {
    var generated = recomposedFor(surface, theme);
    if (generated != null) return SplashPicture.generated(generated);
    return SplashPicture.predicted(
      compositionFor(surface, theme),
      reason: !isGenerated
          ? 'Nothing has been generated yet, so this is what the config will '
                'produce — not what any device shows. Run '
                'flutter_native_splash:create in this package to make it real.'
          : surface == SplashSurface.ios
          // Not "nothing was generated": there is plenty on disk, we simply
          // cannot read a storyboard back into a picture.
          ? 'Predicted from the config. iOS cannot be read back — '
                'LaunchScreen.storyboard describes constraints, not the '
                'finished image.'
          : 'Predicted from the config. Nothing was generated for this surface.',
    );
  }

  /// What the *generated files* say this cell looks like, or null when there was
  /// nothing to read — see `recompose.dart`. Most callers want [pictureFor],
  /// which pairs this with the fallback and says which one it handed back.
  SplashComposition? recomposedFor(SplashSurface surface, SplashTheme theme) =>
      recompositions[(surface, theme)];

  /// The problems that belong to one cell, plus the config-wide ones.
  List<SplashProblem> problemsFor(SplashSurface surface, SplashTheme theme) => [
    for (var problem in problems)
      if ((problem.surface == null || problem.surface == surface) &&
          (problem.theme == null || problem.theme == theme))
        problem,
  ];
}

/// Scans [packageRoot], which must be absolute.
///
/// [packagePath] is the workspace-relative path the result is labelled with.
///
/// [files] is where the reads go — the disk unless a recording is standing in
/// for one; see `files.dart`.
SplashScan scanSplash({
  required String packageRoot,
  required String packagePath,
  SplashFiles files = const LiveSplashFiles(),
}) {
  var search = _findConfigs(files, packageRoot);
  return SplashScan(
    packagePath: packagePath,
    configs: [
      for (var config in search.configs)
        _scanConfig(files, packageRoot, config),
    ],
    configErrors: search.errors,
    hasDevDependency: _hasDevDependency(files, packageRoot),
  );
}

/// Finds every config the project has, and every file that looks like one but
/// is not usable.
///
/// Every config lives under a top-level `flutter_native_splash:` key,
/// including a standalone `flutter_native_splash.yaml` — the generator reads
/// `yamlMap['flutter_native_splash']` whichever file it opened, and throws when
/// that section is missing. A file whose keys sit at the root is therefore not
/// a config with odd indentation; it is a file the generator refuses outright,
/// which is why [_ConfigSearch.errors] reports it instead of the scan quietly
/// finding nothing.
///
/// The default config follows the generator's own order: `flutter_native_splash.
/// yaml` if it exists, otherwise the pubspec. Flavor files are **not** higher
/// precedence — they are alternatives the generator reads only when asked with
/// `--flavor` — so they are listed beside the default rather than in front of
/// it.
_ConfigSearch _findConfigs(SplashFiles files, String packageRoot) {
  var found = <SplashConfig>[];
  var errors = <String>[];

  /// The `flutter_native_splash:` section of the file at [path], or null with
  /// a recorded reason.
  Map<String, Object?>? section(String path, {required bool required}) {
    var raw = _readYamlMap(files, path);
    var name = p.basename(path);
    if (raw == null) {
      if (required) errors.add('"$name" is empty or malformed.');
      return null;
    }
    var value = raw['flutter_native_splash'];
    if (value is! Map) {
      if (required) {
        errors.add(
          '"$name" has no `flutter_native_splash:` section. The generator '
          'throws rather than reading the keys at the root.',
        );
      }
      return null;
    }
    return value.cast<String, Object?>();
  }

  var yaml = p.join(packageRoot, 'flutter_native_splash.yaml');
  if (files.exists(yaml)) {
    var raw = section(yaml, required: true);
    if (raw != null) {
      found.add(
        SplashConfig(
          raw: raw,
          kind: SplashConfigKind.file,
          path: 'flutter_native_splash.yaml',
        ),
      );
    }
  } else {
    // No section in the pubspec is the ordinary state of a project that has not
    // set a splash up, so it is not an error.
    var raw = section(p.join(packageRoot, 'pubspec.yaml'), required: false);
    if (raw != null) {
      found.add(
        SplashConfig(
          raw: raw,
          kind: SplashConfigKind.pubspec,
          path: 'pubspec.yaml',
        ),
      );
    }
  }

  if (files.isDirectory(packageRoot)) {
    for (var file in files.list(packageRoot)) {
      if (files.isDirectory(file)) continue;
      var match = splashFlavorFilePattern.firstMatch(p.basename(file));
      if (match == null) continue;
      var raw = section(file, required: true);
      if (raw == null) continue;
      found.add(
        SplashConfig(
          raw: raw,
          kind: SplashConfigKind.flavorFile,
          path: p.basename(file),
          flavor: match.group(1),
        ),
      );
    }
  }

  return _ConfigSearch(found, errors);
}

class _ConfigSearch {
  _ConfigSearch(this.configs, this.errors);

  final List<SplashConfig> configs;

  /// Files that look like a config and are not one. Reported rather than
  /// skipped: a `flutter_native_splash.yaml` sitting there doing nothing is
  /// exactly the state someone needs told about.
  final List<String> errors;
}

/// The launcher icon Android 12 falls back to, at the best density it has.
///
/// Not referenced by the config, and that is the point. When
/// `android_12.image` resolves nothing the generator writes no
/// `windowSplashScreenAnimatedIcon`, and Android draws the app icon instead — so
/// the honest preview of that cell is this file, not an empty rectangle.
///
/// Read straight from the mipmaps rather than through the icon tool's
/// `AppIcons`, which loads and resizes every icon on every platform for a
/// screen this scan is not drawing. If a third reader ever appears, hoist it.
///
/// Two approximations, both of which draw something truer than nothing:
/// `android:icon` in the manifest is assumed to be `@mipmap/ic_launcher`, and an
/// adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml`, two layers composed and
/// masked by the OS) is stood in for by the flat PNG beside it.
SplashImageFacts? _findLauncherIcon(SplashFiles files, String packageRoot) {
  var res = p.join(packageRoot, 'android', 'app', 'src', 'main', 'res');
  if (!files.isDirectory(res)) return null;

  // Densest first, so the preview scales down rather than up.
  const densities = ['xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi'];
  for (var density in densities) {
    for (var name in ['ic_launcher.png', 'ic_launcher_foreground.png']) {
      var file = p.join(res, 'mipmap-$density', name);
      if (files.exists(file)) {
        return _measure(
          files,
          packageRoot,
          p.relative(file, from: packageRoot),
        );
      }
    }
  }
  return null;
}

SplashConfigScan _scanConfig(
  SplashFiles files,
  String packageRoot,
  SplashConfig config,
) {
  var images = <String, SplashImageFacts>{};
  for (var path in _referencedPaths(config)) {
    images.putIfAbsent(path, () => _measure(files, packageRoot, path));
  }

  // Keyed by its own path like any other, so `composeSplash` reaches it through
  // the same `facts` lookup and needs no second channel.
  var launcherIcon = _findLauncherIcon(files, packageRoot);
  if (launcherIcon != null) {
    images.putIfAbsent(launcherIcon.path, () => launcherIcon);
  }

  var artifacts = findSplashArtifacts(
    packageRoot,
    flavor: config.flavor,
    files: files,
  );
  var stale = splashIsStale(
    configPath: p.join(packageRoot, config.path),
    artifacts: artifacts,
    files: files,
  );

  return SplashConfigScan(
    config: config,
    images: images,
    launcherIcon: launcherIcon,
    artifacts: artifacts,
    stale: stale,
    recompositions: {
      for (var surface in SplashSurface.values)
        for (var theme in SplashTheme.values)
          (surface, theme): ?recomposeSplash(
            packageRoot: packageRoot,
            surface: surface,
            theme: theme,
            artifacts: artifacts,
            flavor: config.flavor,
            files: files,
          ),
    },
    problems: validateSplash(
      config,
      facts: (path) => images[path],
      hasDevDependency: _hasDevDependency(files, packageRoot),
      generatedIsStale: stale,
    ),
  );
}

/// Every path the config points at, deduplicated.
Set<String> _referencedPaths(SplashConfig config) {
  var paths = <String>{};
  for (var base in ['image', 'background_image', 'branding']) {
    for (var key in [
      base,
      '${base}_dark',
      for (var suffix in ['android', 'ios', 'web']) ...[
        '${base}_$suffix',
        '${base}_dark_$suffix',
      ],
    ]) {
      var value = SplashConfig.stringify(config.raw[key]);
      if (value != null) paths.add(value);
    }
  }
  for (var key in ['image', 'image_dark', 'branding', 'branding_dark']) {
    var value = SplashConfig.stringify(config.android12Section[key]);
    if (value != null) paths.add(value);
  }
  return paths;
}

/// Reads a referenced image's dimensions.
///
/// PNG is parsed straight out of the IHDR header rather than decoded, because
/// the only questions asked of it are "how big" and "does it match the Android
/// 12 canvas" — decoding a 1152×1152 image to answer them would cost more than
/// the whole rest of the scan. Anything else falls back to `package:image`,
/// which the generator itself uses, so the formats agree by construction.
SplashImageFacts _measure(SplashFiles files, String packageRoot, String path) {
  var file = p.isAbsolute(path) ? path : p.join(packageRoot, path);
  if (!files.exists(file)) return SplashImageFacts.missing(path);

  var bytes = files.readBytes(file);
  if (bytes == null) {
    return SplashImageFacts(path: path, exists: true, absolutePath: file);
  }

  var size = _pngSize(bytes) ?? _decodedSize(bytes);
  return SplashImageFacts(
    path: path,
    exists: true,
    absolutePath: file,
    pixelWidth: size?.$1,
    pixelHeight: size?.$2,
    isPng: _isPng(bytes),
  );
}

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

bool _isPng(Uint8List bytes) {
  if (bytes.length < 8) return false;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// Width and height out of the IHDR chunk, which a valid PNG always puts first:
/// 8-byte signature, 4-byte length, `IHDR`, then two big-endian 32-bit values.
(int, int)? _pngSize(Uint8List bytes) {
  if (!_isPng(bytes) || bytes.length < 24) return null;
  var data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

(int, int)? _decodedSize(Uint8List bytes) {
  try {
    var decoder = img.findDecoderForData(bytes);
    var info = decoder?.startDecode(bytes);
    if (info == null) return null;
    return (info.width, info.height);
  } catch (_) {
    return null;
  }
}

/// Whether the package can actually run the generator.
bool _hasDevDependency(SplashFiles files, String packageRoot) {
  var raw = _readYamlMap(files, p.join(packageRoot, 'pubspec.yaml'));
  if (raw == null) return false;
  for (var key in ['dev_dependencies', 'dependencies']) {
    var section = raw[key];
    if (section is Map && section.containsKey('flutter_native_splash')) {
      return true;
    }
  }
  return false;
}

/// Decodes a YAML file to a plain map, or null when it is missing, empty or not
/// a map. A malformed file is null rather than a throw: a config being edited is
/// briefly unparseable, and the panel redrawing an error is better than the
/// scan failing.
Map<String, Object?>? _readYamlMap(SplashFiles files, String path) {
  var text = files.readString(path);
  if (text == null) return null;
  try {
    var plain = _plain(loadYaml(text));
    return plain is Map<String, Object?> ? plain : null;
  } catch (_) {
    return null;
  }
}

/// `YamlMap`/`YamlList` are `Map`/`List` but not the mutable, castable kinds the
/// rest of the model expects, and they leak into anything that stores them.
Object? _plain(Object? value) => switch (value) {
  Map map => {
    for (var entry in map.entries) '${entry.key}': _plain(entry.value),
  },
  List list => [for (var item in list) _plain(item)],
  _ => value,
};
