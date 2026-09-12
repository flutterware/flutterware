/// Where `flutter_native_splash:create` puts what it makes, and whether what is
/// there is still current.
///
/// This is the half of the plugin that looks at **ground truth** rather than at
/// the config. It is what makes `artifacts` able to hand an agent the real PNG
/// instead of a simulation, and what makes the drift check possible without
/// running anything: a `stat` on these against a `stat` on the config answers
/// "have you regenerated since you last edited?".
///
/// Paths are transcribed from the package's `flavor_helper.dart` and
/// `android.dart`. Discovery is glob-ish rather than an exact manifest on
/// purpose — the generator's exact density set varies with `android_min_sdk`
/// and the platforms present, and a hard list would report a missing file every
/// time it changed.
library;

import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'files.dart';
import 'surface.dart';

/// Which layer of the splash a generated file is.
///
/// The splash is a stack, not a picture: `launch_background.xml` is a layer-list
/// of a background, an image and a branding bitmap. Without the role, a
/// comparison against the prediction has no way to know which of three PNGs in
/// one folder is the one it should be looking at.
enum SplashArtifactRole {
  /// `splash.png` / `LaunchImage.png` / `light-1x.png` — the logo layer.
  image,

  /// `background.png`. **A PNG, not a colour drawable** — the generator renders
  /// the configured colour to a bitmap, which is what makes recomposing the
  /// real splash from disk a matter of stacking files.
  background,

  /// `branding.png` / `android12branding.png`.
  branding,

  /// `android12splash.png` — the masked Android 12 icon, which is a different
  /// slot from [image] rather than a variant of it.
  icon,
}

/// One file the generator produced.
class SplashArtifact {
  const SplashArtifact({
    required this.path,
    required this.surface,
    required this.theme,
    required this.role,
    required this.modified,
    this.density,
    this.pixelWidth,
    this.pixelHeight,
  });

  /// Package-relative, so it reads the same on another machine.
  final String path;

  final SplashSurface surface;
  final SplashTheme theme;
  final SplashArtifactRole role;

  /// `xxhdpi`, `@3x`, `4x` — whatever the platform calls it. Null when the
  /// platform has only one.
  final String? density;

  /// Read from the PNG header, not by decoding — see [readPngHeaderSize].
  final int? pixelWidth;
  final int? pixelHeight;

  final DateTime modified;

  /// The size this file occupies on screen, in logical pixels.
  ///
  /// Android only, and deliberately. The rule is verified against the
  /// generator: it writes each density at `source * pixelDensity ~/ 4`, and
  /// Android draws an `xxxhdpi` drawable at a quarter of its pixels. So every
  /// density of one image should report the *same* dp — a mismatch means the
  /// generated set was edited by hand. iOS and web get null rather than an
  /// unchecked number.
  double? get logicalWidth {
    var scale = splashDensityScale(density);
    if (scale == null || pixelWidth == null) return null;
    if (surface == SplashSurface.ios || surface == SplashSurface.web) {
      return null;
    }
    return pixelWidth! / scale;
  }
}

/// What one Android density bucket multiplies a dp by.
///
/// Null for anything that is not a density — `v21`, `v31` and a bare `drawable`
/// are API-level and default buckets, not sizes, and treating them as one would
/// invent numbers.
///
/// A qualifier may carry **both**: the Android 12 branding lands in
/// `drawable-xxxhdpi-v31`, which is a density *and* an API level. Reading that
/// as "not a density" made every one of those artifacts score the same, so the
/// readback named `drawable-hdpi-v31` — the first and lowest — as the file that
/// shipped, and reported a dp width computed from the wrong bucket.
double? splashDensityScale(String? density) => switch (_bucket(density)) {
  'mdpi' => 1,
  'hdpi' => 1.5,
  'xhdpi' => 2,
  'xxhdpi' => 3,
  'xxxhdpi' => 4,
  _ => null,
};

/// The density part of a qualifier, with any trailing API level removed.
String? _bucket(String? density) {
  if (density == null) return null;
  var parts = density.split('-');
  for (var part in parts) {
    if (part.endsWith('dpi')) return part;
  }
  return null;
}

/// A PNG's dimensions, read from its header rather than by decoding it.
///
/// 24 bytes off the front of the file, because the alternative is reading
/// every generated PNG whole — an `xxxhdpi` splash is comfortably a megabyte,
/// there are dozens of them, and this runs on the UI isolate every time the
/// fingerprint moves. A valid PNG always puts IHDR first: 8-byte signature,
/// 4-byte length, `IHDR`, then two big-endian 32-bit values.
(int, int)? readPngHeaderSize(SplashFiles files, String path) {
  var bytes = files.readHead(path, 24);
  if (bytes == null || bytes.length < 24) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }
  var data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// The Android resource root, which moves when the project uses flavors.
///
/// `android/app/src/<flavor>/res/` when there is one, `android/app/src/main/res/`
/// otherwise — the package's own `_androidResFolder`.
String androidResFolder(String? flavor) =>
    p.join('android', 'app', 'src', flavor ?? 'main', 'res');

/// What a flavor is spelled as inside the iOS asset catalog.
///
/// The generator's `_FlavorHelper` builds every iOS name as
/// `LaunchImage$_iOSFlavorName`, and `_iOSFlavorName` is `flavor.capitalize()` —
/// its own extension, which upper-cases the first character and **lower-cases
/// the rest**. So `devQA` writes `LaunchImageDevqa.imageset`.
///
/// That last part is why this only ever runs forwards. The transform is lossy,
/// so a directory listing cannot be read back into the flavor that produced it;
/// the flavor has to come from the config file, which is where the splash scan
/// already gets it.
String iosFlavorName(String? flavor) => flavor == null || flavor.isEmpty
    ? ''
    : '${flavor[0].toUpperCase()}${flavor.substring(1).toLowerCase()}';

/// Everything the generator wrote under [packageRoot], newest information
/// first.
///
/// Returns an empty list when nothing has been generated, which is a real and
/// common state — it is what "run `generate` first" is based on.
List<SplashArtifact> findSplashArtifacts(
  String packageRoot, {
  String? flavor,
  SplashFiles files = const LiveSplashFiles(),
}) {
  var found = <SplashArtifact>[];

  void add(
    String file,
    SplashSurface surface,
    SplashTheme theme,
    String? density,
    SplashArtifactRole role,
  ) {
    var size = readPngHeaderSize(files, file);
    found.add(
      SplashArtifact(
        path: p.relative(file, from: packageRoot),
        surface: surface,
        theme: theme,
        role: role,
        density: density,
        pixelWidth: size?.$1,
        pixelHeight: size?.$2,
        modified:
            files.stat(file)?.modified ??
            DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
  }

  // ---- Android ----------------------------------------------------------
  // One `splash.png` per density folder, plus `android12splash.png` for the
  // Android 12 path and `branding.png` beside them. `-night` in the folder name
  // is what makes a resource the dark one.
  var res = p.join(packageRoot, androidResFolder(flavor));
  if (files.isDirectory(res)) {
    for (var entry in files.list(res)) {
      if (!files.isDirectory(entry)) continue;
      var folder = p.basename(entry);
      if (!folder.startsWith('drawable')) continue;
      var theme = folder.contains('night')
          ? SplashTheme.dark
          : SplashTheme.light;
      var density = folder
          .replaceFirst('drawable-', '')
          .replaceFirst('night-', '');
      for (var file in files.list(entry)) {
        if (files.isDirectory(file)) continue;
        var name = p.basename(file);
        // `background.png` matters as much as the rest: it is the *colour*,
        // rendered to a bitmap, and it is the bottom layer of
        // `launch_background.xml`. Skipping it made the browser show a splash
        // with no background in it.
        var (surface, role) = switch (name) {
          'android12splash.png' => (
            SplashSurface.android12,
            SplashArtifactRole.icon,
          ),
          'android12branding.png' => (
            SplashSurface.android12,
            SplashArtifactRole.branding,
          ),
          'splash.png' => (SplashSurface.android, SplashArtifactRole.image),
          'branding.png' => (
            SplashSurface.android,
            SplashArtifactRole.branding,
          ),
          'background.png' => (
            SplashSurface.android,
            SplashArtifactRole.background,
          ),
          _ => (null, SplashArtifactRole.image),
        };
        if (surface != null) {
          add(file, surface, theme, density == folder ? null : density, role);
        }
      }
    }
  }

  // ---- iOS --------------------------------------------------------------
  // **`LaunchImage.imageset` is not evidence of anything.** Every Flutter
  // project ships one, with `LaunchImage.png`, `@2x` and `@3x` already in it,
  // from `flutter create` onwards. Counting it made a project that had never
  // run the generator report three generated files — and then report them as
  // stale, which is a drift warning about work that never happened.
  //
  // `LaunchBackground.imageset` is the honest marker: `_createiOSSplash` writes
  // its `Contents.json` unconditionally, and nothing else creates it.
  //
  // Under a flavor every one of these three moves — `LaunchImageDev.imageset`
  // and so on — and the stock set stays where it is. Reading the unsuffixed
  // names for a flavor therefore did not come back empty, which would at least
  // have been visible: it came back with the *default* flavor's files, reported
  // as the flavor's own.
  var iosAssets = p.join(packageRoot, 'ios', 'Runner', 'Assets.xcassets');
  var suffix = iosFlavorName(flavor);
  var iosGenerated = files.isDirectory(
    p.join(iosAssets, 'LaunchBackground$suffix.imageset'),
  );

  for (var set in ['LaunchImage', 'BrandingImage', 'LaunchBackground']) {
    if (!iosGenerated) break;
    var dir = p.join(iosAssets, '$set$suffix.imageset');
    if (!files.isDirectory(dir)) continue;
    for (var file in files.list(dir)) {
      if (files.isDirectory(file) || p.extension(file) != '.png') continue;
      var name = p.basenameWithoutExtension(file);
      var density = switch (name) {
        _ when name.endsWith('@3x') => '@3x',
        _ when name.endsWith('@2x') => '@2x',
        _ => null,
      };
      var theme = name.toLowerCase().contains('dark')
          ? SplashTheme.dark
          : SplashTheme.light;
      var role = switch (set) {
        'BrandingImage' => SplashArtifactRole.branding,
        'LaunchBackground' => SplashArtifactRole.background,
        _ => SplashArtifactRole.image,
      };
      add(file, SplashSurface.ios, theme, density, role);
    }
  }

  // ---- Web --------------------------------------------------------------
  var web = p.join(packageRoot, 'web', 'splash', 'img');
  if (files.isDirectory(web)) {
    for (var file in files.list(web)) {
      if (files.isDirectory(file) || p.extension(file) != '.png') continue;
      var name = p.basenameWithoutExtension(file);
      var theme = name.contains('dark') ? SplashTheme.dark : SplashTheme.light;
      var density = RegExp(r'(\dx)$').firstMatch(name)?.group(1);
      var role = switch (name) {
        _ when name.startsWith('branding') => SplashArtifactRole.branding,
        _ when name.contains('background') => SplashArtifactRole.background,
        _ => SplashArtifactRole.image,
      };
      add(file, SplashSurface.web, theme, density, role);
    }
  }

  found.sort((a, b) => a.path.compareTo(b.path));
  return found;
}

/// Whether the config has been edited since the splash was last generated.
///
/// False when nothing has been generated at all — "you have never run it" is a
/// different thing from "what you have is out of date", and reporting the
/// second when the first is true reads as a problem with the output rather than
/// its absence.
bool splashIsStale({
  required String configPath,
  required List<SplashArtifact> artifacts,
  SplashFiles files = const LiveSplashFiles(),
}) {
  if (artifacts.isEmpty) return false;
  var configTime = files.stat(configPath)?.modified;
  if (configTime == null) return false;
  var newest = artifacts
      .map((a) => a.modified)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  return configTime.isAfter(newest);
}
