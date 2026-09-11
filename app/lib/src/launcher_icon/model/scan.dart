/// Reading one package's launcher icons off disk.
///
/// The budget here is the plugin-core budget: list directories, read a few
/// image headers, parse three small XML files, cache the result. Nothing here
/// decodes an image — dimensions and alpha come out of the PNG header, for the
/// same reason the splash scan reads IHDR directly, and the panel decodes only
/// what it is about to draw.
///
/// Discovery is deliberately **broad, then classified**. Globbing for
/// `ic_launcher_foreground.png` by name would only find icons a particular
/// generator wrote; listing every PNG in `mipmap-*` and `drawable-*` and then
/// asking the project's own wiring what each one is finds them whoever wrote
/// them — and, more usefully, finds the ones nothing references at all.
///
/// Asking the wiring means asking it for a whole reference, type and all. A
/// launcher icon lives under whichever of the two directory families its own
/// project put it in, and `@drawable/x` answers only for `drawable*`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware/plugins.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;

import 'role.dart';
import 'wiring.dart';

part 'scan.g.dart';

/// A role on the wire is its [IconRole.id] — the same spelling an address
/// carries and the inventory action reports — rather than the enum constant,
/// so a recorded scan reads the same after a constant is renamed.
IconRole _roleFromJson(String id) =>
    IconRole.byId(id) ??
    (throw FormatException('Unknown launcher icon role "$id"'));

String _roleToJson(IconRole role) => role.id;

IconRole? _roleOrNullFromJson(String? id) =>
    id == null ? null : _roleFromJson(id);

String? _roleOrNullToJson(IconRole? role) => role?.id;

/// One icon file, and what its header says about it.
///
/// Serialisable, like every type below it, so a scan can be **recorded**: the
/// studio's own catalog demos, its scenario tests and the web demo all draw the
/// panel from a scan the real reader produced once, off a real project. The
/// inventory action's JSON is a different, deliberately narrower thing — see
/// `IconInventoryResult` — and could not stand in for this: it drops
/// [inherited] and [absolutePath] and re-roots every path, all of which the
/// panel draws.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IconFile {
  const IconFile({
    required this.path,
    required this.absolutePath,
    required this.modified,
    this.width,
    this.height,
    this.hasAlpha = false,
    this.density,
    this.resourceType,
    this.icoFrames = const [],
    this.declaredSize,
    this.inherited = false,
  });

  /// Package-relative, so it reads the same on another machine.
  final String path;

  /// Where to actually load it from. The panel needs this; every reported path
  /// stays relative.
  final String absolutePath;

  final DateTime modified;

  /// Null when the header could not be read — a truncated file, or a format
  /// with no cheap header. Reported as unknown rather than guessed.
  final int? width;
  final int? height;

  /// Whether the pixels can be transparent. The App Store rejects an iOS icon
  /// that can.
  final bool hasAlpha;

  /// `xxhdpi`, `@3x`, `192` — whatever the platform calls this variant. Null
  /// when the platform has only one.
  final String? density;

  /// The Android resource type this was found under — `mipmap`, `drawable`.
  /// Null off Android, where nothing addresses a file by type.
  ///
  /// Carried because a name is only half of what a reference names, and the
  /// half that does not distinguish `@drawable/ic_launcher_foreground` from
  /// `@mipmap/ic_launcher_foreground`.
  final String? resourceType;

  /// The sizes an `.ico` packs, largest last. Empty for every other format.
  final List<int> icoFrames;

  /// What an Apple asset catalog says this file's pixel size should be.
  ///
  /// Kept beside the real [width] so the two can disagree out loud: a catalog
  /// promising 1024×1024 over a 512×512 file is a fact about the files, needing
  /// no opinion about how they were made.
  final int? declaredSize;

  /// Under a flavor, whether this file came from the unflavored set because
  /// the flavor overrides nothing here.
  ///
  /// Carried rather than hidden because both ways of hiding it are a lie the
  /// panel has already told. Showing only the flavor's own folder says a
  /// flavor with one bitmap has no adaptive icon; showing the merge without
  /// saying so credits the flavor with art it does not own — which is the bug
  /// the flavored iOS read had before it was given the flavor at all.
  final bool inherited;

  factory IconFile.fromJson(Map<String, Object?> json) =>
      _$IconFileFromJson(json);

  Map<String, Object?> toJson() => _$IconFileToJson(this);

  String get name => p.basenameWithoutExtension(path);

  bool get sizeMismatch =>
      declaredSize != null && width != null && width != declaredSize;
}

/// Everything found for one role.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IconRoleScan {
  const IconRoleScan({
    required this.role,
    required this.files,
    this.color,
    this.referenced,
  });

  factory IconRoleScan.fromJson(Map<String, Object?> json) =>
      _$IconRoleScanFromJson(json);

  Map<String, Object?> toJson() => _$IconRoleScanToJson(this);

  @JsonKey(fromJson: _roleFromJson, toJson: _roleToJson)
  final IconRole role;

  /// Sorted smallest first.
  final List<IconFile> files;

  /// The adaptive background when it is a colour rather than an image.
  final String? color;

  /// Whether the project's wiring points at this. Null off Android, where
  /// there is no wiring to read and presence is the whole answer.
  final bool? referenced;

  bool get isEmpty => files.isEmpty && color == null;
  bool get isNotEmpty => !isEmpty;

  /// The largest file, which is the one worth drawing.
  IconFile? get largest => files.isEmpty ? null : files.last;

  /// Under a flavor, whether every file here came from the unflavored set —
  /// the flavor overrides nothing for this role, and what a build ships is
  /// main's art.
  bool get allInherited =>
      files.isNotEmpty && files.every((file) => file.inherited);
}

/// Which shape the iOS asset situation is in.
///
/// Three states rather than a bool because a modern project can legitimately
/// have **no per-size PNGs at all**: Xcode 26 generates every variant from a
/// single Icon Composer `.icon` bundle at build time. Reporting "no iOS icons"
/// there would be wrong, and would be the first thing anyone noticed.
enum IosCatalog {
  /// Nothing found.
  none,

  /// The classic `AppIcon.appiconset` with a PNG per size.
  appIconSet,

  /// An Icon Composer `.icon` bundle. Xcode expands it during the build.
  iconComposer,

  /// Both present, which Apple's own forums are full of people getting
  /// submission failures from.
  both,
}

/// One thing worth saying about what was found.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IconFinding {
  const IconFinding(this.tone, this.message, {this.role});

  factory IconFinding.fromJson(Map<String, Object?> json) =>
      _$IconFindingFromJson(json);

  Map<String, Object?> toJson() => _$IconFindingToJson(this);

  final Tone tone;
  final String message;

  @JsonKey(fromJson: _roleOrNullFromJson, toJson: _roleOrNullToJson)
  final IconRole? role;
}

/// Everything one package's icons turned out to be.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IconScan {
  const IconScan({
    required this.packagePath,
    required this.roles,
    required this.findings,
    this.flavor,
    this.flavors = const [],
    this.android,
    this.ios = IosCatalog.none,
    this.iconBundles = const [],
  });

  factory IconScan.fromJson(Map<String, Object?> json) =>
      _$IconScanFromJson(json);

  Map<String, Object?> toJson() => _$IconScanToJson(this);

  /// Workspace-relative — `.`, `fixtures/probe_app`.
  final String packagePath;

  /// The flavor this scan read, or null for the default.
  final String? flavor;

  /// The other flavors that exist, so the panel can offer them.
  final List<IconFlavor> flavors;

  final List<IconRoleScan> roles;
  final List<IconFinding> findings;

  final AndroidWiring? android;
  final IosCatalog ios;

  /// Package-relative paths of any Icon Composer bundles.
  final List<String> iconBundles;

  IconRoleScan? forRole(IconRole role) {
    for (var scan in roles) {
      if (scan.role == role) return scan;
    }
    return null;
  }

  List<IconRoleScan> forPlatform(IconPlatform platform) => [
    for (var scan in roles)
      if (scan.role.platform == platform) scan,
  ];

  /// The platforms that turned up anything at all.
  List<IconPlatform> get platforms => [
    for (var platform in IconPlatform.values)
      if (forPlatform(platform).any((s) => s.isNotEmpty)) platform,
  ];

  int get fileCount {
    var total = 0;
    for (var scan in roles) {
      total += scan.files.length;
    }
    return total;
  }

  bool get isEmpty => roles.every((r) => r.isEmpty) && ios == IosCatalog.none;
}

/// Where a package's scan comes from — [scanIcons], or a recording of one.
///
/// [packageRoot] is a thunk rather than a path: a live reader needs the
/// absolute root and a recorded one must not ask for it, since resolving a
/// path to an absolute one is a filesystem question that has no answer where
/// a recording is drawn from.
typedef IconScanner = FutureOr<IconScan> Function({
  required String Function() packageRoot,
  required String packagePath,
  String? flavor,
});

/// Scans [packageRoot], which must be absolute.
IconScan scanIcons({
  required String packageRoot,
  required String packagePath,
  String? flavor,
}) {
  var roles = <IconRole, IconRoleScan>{};
  var findings = <IconFinding>[];
  var resources = <_Resource>[];

  var android = _scanAndroid(packageRoot, flavor, roles, resources);
  var (ios, bundles) = _scanApple(packageRoot, flavor, roles);
  _scanWeb(packageRoot, roles);
  _scanDesktop(packageRoot, roles);

  var scan = IconScan(
    packagePath: packagePath,
    flavor: flavor,
    flavors: discoverIconFlavors(packageRoot),
    roles: [
      for (var role in IconRole.values)
        roles[role] ?? IconRoleScan(role: role, files: const []),
    ],
    findings: findings,
    android: android,
    ios: ios,
    iconBundles: bundles,
  );

  findings.addAll(_findings(scan, resources));
  return scan;
}

/// The one file that best stands for the app — what a surface outside the
/// launcher-icon panel shows when it needs "the app's icon" and not a role:
/// the scenario flow's notification banner. Absolute path, or null when the
/// project has nothing usable.
///
/// Built on [scanIcons] rather than its own directory walk, so the flavor
/// union and every platform quirk stay discovered in exactly one place.
/// Preference order is "full artwork, squarest, biggest": the iOS icon is
/// complete art with no transparency, where an adaptive foreground is a logo
/// floating on nothing. Formats Flutter cannot decode (`.ico`, `.svg`) are
/// skipped rather than handed to an `Image` that would throw.
String? representativeIconPath({required String packageRoot, String? flavor}) {
  const preferred = [
    IconRole.iosApp,
    IconRole.macosApp,
    IconRole.androidPlayStore,
    IconRole.androidLegacy,
    IconRole.androidRound,
    IconRole.webIcon,
    IconRole.webMaskable,
  ];
  var scan = scanIcons(
    packageRoot: packageRoot,
    packagePath: '',
    flavor: flavor,
  );
  bool decodable(IconFile file) => switch (p.extension(file.path)) {
    '.png' || '.jpg' || '.jpeg' || '.webp' => true,
    _ => false,
  };
  for (var role in preferred) {
    var files = scan.forRole(role)?.files.where(decodable);
    if (files != null && files.isNotEmpty) return files.last.absolutePath;
  }
  return null;
}

// ---- Flavors ---------------------------------------------------------------

/// Where the evidence for a flavor came from.
///
/// Kept rather than reduced to a name because the three are not equivalent and
/// the difference is the useful part. A flavor with a config and no output has
/// never been generated; one with Android output and no iOS output is a project
/// that generates half of itself, which is a real and quiet misconfiguration.
enum IconFlavorSource {
  /// `flutter_launcher_icons-<name>.yaml`. This is the generator's own list —
  /// `getFlavors()` globs exactly this — so it is the closest thing to an
  /// authority that costs no parser.
  config,

  /// `android/app/src/<name>/`.
  androidSourceSet,

  /// `ios/Runner/Assets.xcassets/AppIcon-<name>.appiconset`.
  iosCatalog,
}

/// A flavor, and every file on disk that declares it.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class IconFlavor {
  const IconFlavor(this.name, this.sources);

  factory IconFlavor.fromJson(Map<String, Object?> json) =>
      _$IconFlavorFromJson(json);

  Map<String, Object?> toJson() => _$IconFlavorToJson(this);

  final String name;

  /// Never empty — a flavor exists because something pointed at it.
  final Set<IconFlavorSource> sources;

  bool has(IconFlavorSource source) => sources.contains(source);

  /// Configured but never generated: the chip is worth showing, and the panel
  /// behind it will be empty for a reason the user can act on.
  bool get isUnbuilt =>
      sources.length == 1 && sources.first == IconFlavorSource.config;

  @override
  String toString() => name;
}

/// Every flavor this package appears to have, from the three sources that cost
/// a directory listing.
///
/// Gradle and Xcode are the real authorities and are deliberately not read.
/// `productFlavors` needs a Groovy parser and a Kotlin one, and the scheme list
/// needs a third; `lib/src/run/flavors.dart` declined the same job for the same
/// reason. What is here instead is the union of what the generator was told to
/// make and what it actually made — which is all a viewer can show anyway. The
/// only flavor it misses is one with no config and no output, and for such a
/// flavor there is nothing to display.
List<IconFlavor> discoverIconFlavors(String packageRoot) {
  var sources = <String, Set<IconFlavorSource>>{};

  void note(String name, IconFlavorSource source) {
    if (name.isEmpty) return;
    sources.putIfAbsent(name, () => {}).add(source);
  }

  for (var name in _flavorConfigs(packageRoot)) {
    note(name, IconFlavorSource.config);
  }
  for (var name in _androidSourceSets(packageRoot)) {
    note(name, IconFlavorSource.androidSourceSet);
  }
  for (var name in _flavoredAppIconSets(packageRoot)) {
    note(name, IconFlavorSource.iosCatalog);
  }

  var names = sources.keys.toList()..sort();
  return [for (var name in names) IconFlavor(name, sources[name]!)];
}

/// `flutter_launcher_icons-<flavor>.yaml`, the generator's own spelling.
///
/// Matched but not opened: a malformed config is still a declared flavor, and
/// the panel behind the chip is what reports the state of the files.
List<String> _flavorConfigs(String packageRoot) {
  var dir = Directory(packageRoot);
  if (!dir.existsSync()) return const [];
  var found = <String>[];
  try {
    for (var entry in dir.listSync().whereType<File>()) {
      var match = _flavorConfigPattern.firstMatch(p.basename(entry.path));
      if (match != null) found.add(match.group(1)!);
    }
  } on FileSystemException {
    return const [];
  }
  return found;
}

/// `flutter_launcher_icons/lib/main.dart`'s own `flavorConfigFilePattern`.
final _flavorConfigPattern = RegExp(r'^flutter_launcher_icons-(.*)\.yaml$');

/// The flavored asset catalogs, whose names give the flavor back verbatim.
///
/// Unlike the splash generator — which capitalises, and therefore cannot be
/// read backwards — `flutter_launcher_icons` writes `AppIcon-$flavor` with the
/// flavor untouched, so this direction is lossless.
List<String> _flavoredAppIconSets(String packageRoot) {
  var catalog = Directory(
    p.join(packageRoot, 'ios', 'Runner', 'Assets.xcassets'),
  );
  if (!catalog.existsSync()) return const [];
  var found = <String>[];
  for (var entry in catalog.listSync().whereType<Directory>()) {
    var match = _appIconSetPattern.firstMatch(p.basename(entry.path));
    if (match != null) found.add(match.group(1)!);
  }
  return found;
}

final _appIconSetPattern = RegExp(r'^AppIcon-(.+)\.appiconset$');

// ---- Android ---------------------------------------------------------------

/// The Android source sets that are not build types, in listing order.
List<String> _androidSourceSets(String packageRoot) {
  var dir = Directory(p.join(packageRoot, 'android', 'app', 'src'));
  if (!dir.existsSync()) return const [];

  const reserved = {
    'main',
    'debug',
    'profile',
    'release',
    'test',
    'androidTest',
  };
  return [
    for (var entry in dir.listSync().whereType<Directory>())
      if (!reserved.contains(p.basename(entry.path))) p.basename(entry.path),
  ]..sort();
}

/// One file in a `mipmap*` or `drawable*` directory, named the way a reference
/// would name it.
///
/// Collected beside the icons because a reference resolves against *this*, not
/// against the bitmaps the scan classified. The two are not the same set: a
/// `<foreground>` naming a vector drawable is wired perfectly and has no PNG
/// anywhere, which is a different thing from a reference pointing at nothing.
typedef _Resource = ({String type, String name, String path});

AndroidWiring? _scanAndroid(
  String packageRoot,
  String? flavor,
  Map<IconRole, IconRoleScan> roles,
  List<_Resource> resources,
) {
  String sourceSet(String name) =>
      p.join(packageRoot, 'android', 'app', 'src', name);

  // What Gradle would merge, base first. A flavor source set does not replace
  // `main`, it overlays it: a flavor carrying one bitmap ships with all of
  // main's other densities, main's adaptive XML and main's background colour.
  // Reading the flavor's folder alone reported a project that had none of
  // them — silently, and inverted, since "has an adaptive icon" is most of
  // what this panel is for.
  var layers = [
    (dir: sourceSet('main'), own: flavor == null),
    if (flavor != null) (dir: sourceSet(flavor), own: true),
  ];
  var resFolders = [
    for (var layer in layers)
      if (Directory(p.join(layer.dir, 'res')).existsSync())
        p.join(layer.dir, 'res'),
  ];
  if (resFolders.isEmpty) return null;

  // A flavour source set may carry its own manifest; the icon attributes
  // usually stay in main, so that is the fallback rather than the only look.
  var manifest =
      File(p.join(layers.last.dir, 'AndroidManifest.xml')).existsSync()
      ? p.join(layers.last.dir, 'AndroidManifest.xml')
      : p.join(sourceSet('main'), 'AndroidManifest.xml');

  var wiring = readAndroidWiring(
    packageRoot: packageRoot,
    resFolders: resFolders,
    manifestPath: manifest,
  );

  var byRole = <IconRole, List<IconFile>>{};

  // The roles the wiring itself pointed at, as opposed to the ones a naming
  // convention guessed. Collected as the files are classified rather than
  // compared again afterwards: asking "what is this file?" and then,
  // separately, "does anything point at it?" is two resolutions that can
  // disagree, and they did.
  var wired = <IconRole>{};

  // A file resource is overridden whole, and the qualified directory is half
  // its identity: `mipmap-xxxhdpi/ic_launcher.png` in a flavor replaces main's
  // `mipmap-xxxhdpi/ic_launcher.png` and leaves `mipmap-hdpi/` alone. Keyed by
  // exactly that pair, so the overlay lands where Gradle lands it.
  var byPath = <String, ({File file, bool own})>{};

  for (var layer in layers) {
    var resFolder = Directory(p.join(layer.dir, 'res'));
    if (!resFolder.existsSync()) continue;
    for (var dir in resFolder.listSync().whereType<Directory>()) {
      var dirName = p.basename(dir.path);
      for (var file in dir.listSync().whereType<File>()) {
        byPath['$dirName/${p.basename(file.path)}'] = (
          file: file,
          own: layer.own,
        );
      }
    }
  }

  for (var entry in byPath.entries) {
    var dirName = entry.key.substring(0, entry.key.indexOf('/'));
    var isMipmap = dirName.startsWith('mipmap-') || dirName == 'mipmap';
    var isDrawable = dirName.startsWith('drawable-') || dirName == 'drawable';
    if (!isMipmap && !isDrawable) continue;

    var type = isMipmap ? 'mipmap' : 'drawable';
    // The adaptive XML is wiring, not an image; `wiring.dart` has it. It is
    // still a resource, though, and something may point at it.
    var classifies = dirName != 'mipmap-anydpi-v26';
    var density = dirName.contains('-')
        ? dirName.substring(dirName.indexOf('-') + 1)
        : null;

    var file = entry.value.file;
    var name = p.basenameWithoutExtension(file.path);
    resources.add((
      type: type,
      name: name,
      path: p.relative(file.path, from: packageRoot),
    ));

    if (!classifies) continue;
    if (p.extension(file.path).toLowerCase() != '.png') continue;
    var classified = _classify(type, name, wiring);
    if (classified == null) continue;
    var (role, pointedAt) = classified;
    if (pointedAt) wired.add(role);
    byRole
        .putIfAbsent(role, () => [])
        .add(
          _pngFile(
            packageRoot,
            file,
            density: density,
            resourceType: type,
            inherited: !entry.value.own,
          ),
        );
  }

  for (var layer in layers.reversed) {
    var playStore = File(p.join(layer.dir, 'ic_launcher-playstore.png'));
    if (!playStore.existsSync()) continue;
    byRole
        .putIfAbsent(IconRole.androidPlayStore, () => [])
        .add(_pngFile(packageRoot, playStore, inherited: !layer.own));
    break;
  }

  // Only meaningful once something was actually read: with an unreadable
  // manifest and no adaptive XML, every file would look unreferenced and the
  // panel would cry wolf about all of them.
  var wiringIsKnown = wiring.referencedNames.isNotEmpty;

  for (var entry in byRole.entries) {
    roles[entry.key] = IconRoleScan(
      role: entry.key,
      files: entry.value..sort(_bySize),
      color: entry.key == IconRole.androidAdaptiveBackground
          ? wiring.backgroundColor
          : null,
      referenced: wiringIsKnown ? wired.contains(entry.key) : null,
    );
  }

  // A colour background has no files at all, so it needs its own row.
  if (wiring.backgroundColor != null &&
      !roles.containsKey(IconRole.androidAdaptiveBackground)) {
    roles[IconRole.androidAdaptiveBackground] = IconRoleScan(
      role: IconRole.androidAdaptiveBackground,
      files: const [],
      color: wiring.backgroundColor,
      referenced: true,
    );
  }

  return wiring;
}

/// What one Android resource is, and whether the wiring is what said so.
///
/// The wiring first is what makes this generator-agnostic: a project whose
/// manifest says `android:icon="@mipmap/launcher"` gets its launcher icon
/// recognised, where a list of `icons_launcher`'s output names would miss it
/// entirely.
///
/// [type] is where the file was found — `mipmap` or `drawable` — and it is half
/// the question, because a reference names a type too. The same questions are
/// asked of both: an adaptive foreground under `drawable-<dpi>/`, which is what
/// `flutter_launcher_icons` writes by default, is an adaptive foreground.
///
/// The second half of the answer travels with the first because it is the same
/// resolution. A file the wiring named is one the OS reaches; a file only a
/// naming convention recognised is one nothing points at yet, which is worth
/// saying out loud.
(IconRole, bool)? _classify(String type, String name, AndroidWiring wiring) {
  bool pointsHere(String? reference) =>
      reference != null && _resolves(reference, type, name);

  if (pointsHere(wiring.manifestIcon)) return (IconRole.androidLegacy, true);
  if (pointsHere(wiring.manifestRoundIcon)) {
    return (IconRole.androidRound, true);
  }
  for (var xml in [wiring.launcher, wiring.launcherRound]) {
    if (xml == null) continue;
    if (pointsHere(xml.foreground)) {
      return (IconRole.androidAdaptiveForeground, true);
    }
    if (pointsHere(xml.background)) {
      return (IconRole.androidAdaptiveBackground, true);
    }
    if (pointsHere(xml.monochrome)) return (IconRole.androidMonochrome, true);
  }

  // Notification icons are recognised by name alone, and only as drawables.
  // Unlike the launcher icon they are referenced from application code or from
  // a `<meta-data>` element naming a library's convention, so there is no
  // single place to read. `ic_notification` and `ic_stat_*` are what the
  // Android and Firebase docs use.
  if (type == 'drawable' &&
      (name == 'ic_notification' || name.startsWith('ic_stat'))) {
    return (IconRole.androidNotification, false);
  }

  var byConvention = switch (name) {
    'ic_launcher' => IconRole.androidLegacy,
    'ic_launcher_round' => IconRole.androidRound,
    'ic_launcher_foreground' => IconRole.androidAdaptiveForeground,
    'ic_launcher_background' => IconRole.androidAdaptiveBackground,
    'ic_launcher_monochrome' => IconRole.androidMonochrome,
    _ => null,
  };
  return byConvention == null ? null : (byConvention, false);
}

/// Whether [reference] resolves to the resource [type]/[name].
///
/// A reference carrying no type at all is matched on the name, which is what a
/// malformed manifest gets rather than a silent miss.
bool _resolves(String reference, String? type, String name) {
  if (resourceName(reference) != name) return false;
  var referencedType = resourceType(reference);
  return referencedType == null || referencedType == type;
}

/// The file [reference] resolves to, whatever its format, or null when nothing
/// on disk answers it.
///
/// Asked through [_resolves] rather than a second rule of its own, so what
/// counts as a match cannot drift from what the classifier believed.
String? _resolvedFile(String reference, List<_Resource> resources) {
  for (var resource in resources) {
    if (_resolves(reference, resource.type, resource.name)) {
      return resource.path;
    }
  }
  return null;
}

// ---- Apple -----------------------------------------------------------------

/// [flavor] reaches iOS and stops there: `createIconsFromConfig` hands the
/// flavor to the Android and iOS generators only, and the macOS, web and
/// Windows ones take no flavor at all and write to the one fixed place. So a
/// flavored scan reports the flavor's Android and iOS icons beside the single
/// set of desktop and web ones, which is what the project actually ships.
(IosCatalog, List<String>) _scanApple(
  String packageRoot,
  String? flavor,
  Map<IconRole, IconRoleScan> roles,
) {
  _scanAssetCatalog(
    packageRoot,
    p.join(packageRoot, 'ios', 'Runner', 'Assets.xcassets'),
    roles,
    flavor: flavor,
    light: IconRole.iosApp,
    dark: IconRole.iosDark,
    tinted: IconRole.iosTinted,
  );
  _scanAssetCatalog(
    packageRoot,
    p.join(packageRoot, 'macos', 'Runner', 'Assets.xcassets'),
    roles,
    light: IconRole.macosApp,
  );

  var bundles = _iconBundles(packageRoot);
  var hasSet = roles[IconRole.iosApp]?.files.isNotEmpty ?? false;

  return (
    switch ((hasSet, bundles.isNotEmpty)) {
      (true, true) => IosCatalog.both,
      (true, false) => IosCatalog.appIconSet,
      (false, true) => IosCatalog.iconComposer,
      (false, false) => IosCatalog.none,
    },
    bundles,
  );
}

/// Icon Composer bundles under `ios/`.
///
/// Looked for one level into `ios/` and inside `ios/Runner/`, which is where
/// Xcode puts one when you drag it in. Not a full walk: a recursive search of
/// `ios/` would wander into Pods.
List<String> _iconBundles(String packageRoot) {
  var found = <String>[];
  for (var relative in [p.join('ios'), p.join('ios', 'Runner')]) {
    var dir = Directory(p.join(packageRoot, relative));
    if (!dir.existsSync()) continue;
    for (var entry in dir.listSync()) {
      if (p.extension(entry.path).toLowerCase() == '.icon') {
        found.add(p.relative(entry.path, from: packageRoot));
      }
    }
  }
  return found..sort();
}

/// Reads every `*AppIcon.appiconset` in [catalogPath] — or, under a [flavor],
/// the one set that belongs to it.
///
/// `Contents.json` is the authority rather than the filenames: it is what Xcode
/// reads, it is written the same way whoever generated it, and it is the only
/// place that says which file is the dark one. Guessing from `Icon-App-…@2x`
/// naming would bind this to one generator's spelling.
///
/// A flavor gets one exact set, `AppIcon-<flavor>.appiconset`, because that is
/// the whole of what `createIcons` writes for it — dark and tinted are entries
/// *inside* it, told apart by their `appearances`, not catalogs of their own.
/// The default keeps the loose `*AppIcon.appiconset` match it has always had,
/// which already excludes a flavored set: `AppIcon-dev.appiconset` does not end
/// in `AppIcon.appiconset`. That accident is why the default was right while
/// every flavor silently reported the default's files.
///
/// **A flavor with no set of its own falls back to the default**, marked
/// [IconFile.inherited], because that is what Xcode does: the icon is chosen by
/// `ASSETCATALOG_COMPILER_APPICON_NAME`, which defaults to `AppIcon` for every
/// configuration nobody changed. Reporting no iOS icons for such a flavor said
/// the app ships without one.
void _scanAssetCatalog(
  String packageRoot,
  String catalogPath,
  Map<IconRole, IconRoleScan> roles, {
  required IconRole light,
  String? flavor,
  IconRole? dark,
  IconRole? tinted,
}) {
  var catalog = Directory(catalogPath);
  if (!catalog.existsSync()) return;

  var byRole = <IconRole, List<IconFile>>{};

  // One file backs several catalog entries: 20x20@2x and 40x40@1x are the same
  // 40px square, and Xcode lists both. Counting per entry would report 19 files
  // where 15 exist, and — worse — say "19 icons carry an alpha channel" about
  // 15 files. Keyed by resolved path so two sets cannot collide.
  var seen = <String>{};

  var wanted = flavor == null || flavor.isEmpty
      ? null
      : 'AppIcon-$flavor.appiconset';
  var sets = catalog.listSync().whereType<Directory>().toList();
  var inherited =
      wanted != null && !sets.any((set) => p.basename(set.path) == wanted);

  for (var set in sets) {
    var name = p.basename(set.path);
    if (wanted == null || inherited
        ? !name.endsWith('AppIcon.appiconset')
        : name != wanted) {
      continue;
    }

    var contents = File(p.join(set.path, 'Contents.json'));
    if (!contents.existsSync()) continue;

    List<Object?> images;
    try {
      var decoded = jsonDecode(contents.readAsStringSync());
      images =
          (decoded is Map ? decoded['images'] : null) as List<Object?>? ??
          const [];
    } catch (_) {
      continue;
    }

    for (var entry in images) {
      if (entry is! Map) continue;
      var filename = entry['filename'];
      if (filename is! String || filename.isEmpty) continue;

      var file = File(p.join(set.path, filename));
      if (!file.existsSync()) continue;
      if (!seen.add(file.path)) continue;

      var role = switch (_appearance(entry['appearances'])) {
        'dark' => dark ?? light,
        'tinted' => tinted ?? light,
        _ => light,
      };

      var scale = '${entry['scale'] ?? ''}';
      byRole
          .putIfAbsent(role, () => [])
          .add(
            _pngFile(
              packageRoot,
              file,
              density: scale.isEmpty ? null : scale,
              declaredSize: _declaredSize(entry),
              inherited: inherited,
            ),
          );
    }
  }

  for (var entry in byRole.entries) {
    roles[entry.key] = IconRoleScan(
      role: entry.key,
      files: entry.value..sort(_bySize),
    );
  }
}

/// The `luminosity` appearance of a catalog entry — `dark`, `tinted`, or null
/// for the default.
String? _appearance(Object? appearances) {
  if (appearances is! List) return null;
  for (var appearance in appearances) {
    if (appearance is Map && appearance['appearance'] == 'luminosity') {
      return '${appearance['value']}';
    }
  }
  return null;
}

/// `size: "83.5x83.5"` × `scale: "2x"` in pixels, or null when either is
/// missing or unparseable.
int? _declaredSize(Map<Object?, Object?> entry) {
  var size = entry['size'];
  var scale = entry['scale'];
  if (size is! String) return null;

  var points = double.tryParse(size.split('x').first);
  if (points == null) return null;

  var multiplier = scale is String
      ? double.tryParse(scale.replaceAll('x', '')) ?? 1
      : 1;
  return (points * multiplier).round();
}

// ---- Web and desktop -------------------------------------------------------

void _scanWeb(String packageRoot, Map<IconRole, IconRoleScan> roles) {
  var byRole = <IconRole, List<IconFile>>{};

  var icons = Directory(p.join(packageRoot, 'web', 'icons'));
  if (icons.existsSync()) {
    for (var file in icons.listSync().whereType<File>()) {
      if (p.extension(file.path).toLowerCase() != '.png') continue;
      var role = p.basename(file.path).toLowerCase().contains('maskable')
          ? IconRole.webMaskable
          : IconRole.webIcon;
      byRole.putIfAbsent(role, () => []).add(_pngFile(packageRoot, file));
    }
  }

  for (var name in ['favicon.png', 'favicon.ico']) {
    var file = File(p.join(packageRoot, 'web', name));
    if (!file.existsSync()) continue;
    byRole
        .putIfAbsent(IconRole.webFavicon, () => [])
        .add(_imageFile(packageRoot, file));
  }

  for (var entry in byRole.entries) {
    roles[entry.key] = IconRoleScan(
      role: entry.key,
      files: entry.value..sort(_bySize),
    );
  }
}

void _scanDesktop(String packageRoot, Map<IconRole, IconRoleScan> roles) {
  var windows = Directory(
    p.join(packageRoot, 'windows', 'runner', 'resources'),
  );
  if (windows.existsSync()) {
    var files = [
      for (var file in windows.listSync().whereType<File>())
        if (p.extension(file.path).toLowerCase() == '.ico')
          _imageFile(packageRoot, file),
    ]..sort(_bySize);
    if (files.isNotEmpty) {
      roles[IconRole.windowsIco] = IconRoleScan(
        role: IconRole.windowsIco,
        files: files,
      );
    }
  }

  var snap = Directory(p.join(packageRoot, 'snap', 'gui'));
  if (snap.existsSync()) {
    var files = [
      for (var file in snap.listSync().whereType<File>())
        if (p.extension(file.path).toLowerCase() == '.png')
          _pngFile(packageRoot, file),
    ]..sort(_bySize);
    if (files.isNotEmpty) {
      roles[IconRole.linuxSnap] = IconRoleScan(
        role: IconRole.linuxSnap,
        files: files,
      );
    }
  }
}

// ---- Findings --------------------------------------------------------------

/// What is worth saying about what was found.
///
/// Every rule here is a **fact about the files**, never an opinion about how
/// they were made: nothing reads a generator's config, so nothing can complain
/// about one.
List<IconFinding> _findings(IconScan scan, List<_Resource> resources) {
  var findings = <IconFinding>[];
  var wiring = scan.android;

  if (wiring != null) {
    // Roles a specific rule below already explains. The generic
    // nothing-points-at-this sweep runs last and skips them, so a themed icon
    // with no <monochrome> layer is reported once, in the words that say what
    // to do about it, rather than twice.
    var explained = <IconRole>{};

    var monochrome = scan.forRole(IconRole.androidMonochrome);
    if (monochrome != null &&
        monochrome.files.isNotEmpty &&
        wiring.launcher != null &&
        !wiring.launcher!.hasMonochrome) {
      findings.add(
        IconFinding(
          Tone.warn,
          'A themed icon exists, but ${wiring.launcher!.path} declares no '
          '<monochrome> layer, so Android 13+ falls back to the full-colour '
          'icon.',
          role: IconRole.androidMonochrome,
        ),
      );
      explained.add(IconRole.androidMonochrome);
    }

    for (var xml in [wiring.launcher, wiring.launcherRound]) {
      if (xml == null) continue;
      for (var reference in [xml.foreground, xml.background, xml.monochrome]) {
        if (reference == null) continue;
        // A `@color/…` background resolves in colors.xml, not to a file.
        if (reference.startsWith('@color/')) continue;
        var bitmap = scan.roles.any(
          (role) => role.files.any(
            (file) => _resolves(reference, file.resourceType, file.name),
          ),
        );
        if (bitmap) continue;

        // Nothing was classified, which is two different situations. The
        // reference may answer to a file this scan does not read — a vector
        // drawable, a WebP — and then it is wired and simply not drawable
        // here. Only a reference nothing on disk answers is a broken one.
        var resource = _resolvedFile(reference, resources);
        findings.add(
          resource == null
              ? IconFinding(
                  Tone.error,
                  '${xml.path} points at $reference, and no such image is on '
                  'disk.',
                )
              : IconFinding(
                  Tone.info,
                  '${xml.path} points at $reference, which resolves to '
                  '$resource. It is wired; PNG is the only format previewed '
                  'here.',
                ),
        );
      }
    }

    // Only meaningful once something was actually read: with an unreadable
    // manifest and no adaptive XML nothing is referenced, and saying so about
    // every file would be crying wolf.
    if (wiring.referencedNames.isNotEmpty) {
      for (var role in scan.roles) {
        if (role.role.platform != IconPlatform.android) continue;
        if (role.files.isEmpty || role.referenced != false) continue;
        if (explained.contains(role.role)) continue;
        // The Play Store icon is uploaded rather than referenced, and a
        // notification icon is named from application code the scan cannot see.
        if (role.role == IconRole.androidPlayStore) continue;
        if (role.role == IconRole.androidNotification) continue;
        findings.add(
          IconFinding(
            Tone.warn,
            '${role.files.length} file${role.files.length == 1 ? '' : 's'} on '
            'disk, but no adaptive icon XML or manifest attribute points at '
            '${role.files.first.name} — Android never draws it.',
            role: role.role,
          ),
        );
      }
    }
  }

  for (var role in [IconRole.iosApp, IconRole.iosDark, IconRole.iosTinted]) {
    var scanned = scan.forRole(role);
    if (scanned == null) continue;
    var withAlpha = scanned.files.where((f) => f.hasAlpha).toList();
    if (withAlpha.isNotEmpty) {
      findings.add(
        IconFinding(
          Tone.error,
          '${withAlpha.length} iOS icon${withAlpha.length == 1 ? '' : 's'} '
          'carr${withAlpha.length == 1 ? 'ies' : 'y'} an alpha channel. App '
          'Store Connect rejects a build whose icon does.',
          role: role,
        ),
      );
    }
  }

  if (scan.ios == IosCatalog.both) {
    findings.add(
      IconFinding(
        Tone.warn,
        'Both an Icon Composer bundle (${scan.iconBundles.join(', ')}) and a '
        'classic AppIcon.appiconset are present. Xcode uses one; which is '
        'decided by the target settings, not by what is on disk.',
      ),
    );
  }

  for (var role in scan.roles) {
    for (var file in role.files) {
      if (file.sizeMismatch) {
        findings.add(
          IconFinding(
            Tone.warn,
            '${file.path} is ${file.width}×${file.height}, where the asset '
            'catalog declares ${file.declaredSize}×${file.declaredSize}.',
            role: role.role,
          ),
        );
      }
    }
  }

  return findings;
}

// ---- File facts ------------------------------------------------------------

int _bySize(IconFile a, IconFile b) => (a.width ?? 0).compareTo(b.width ?? 0);

IconFile _pngFile(
  String packageRoot,
  File file, {
  String? density,
  String? resourceType,
  int? declaredSize,
  bool inherited = false,
}) {
  Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } catch (_) {
    return IconFile(
      path: p.relative(file.path, from: packageRoot),
      absolutePath: file.path,
      modified: _modified(file),
      density: density,
      resourceType: resourceType,
      declaredSize: declaredSize,
      inherited: inherited,
    );
  }

  var header = readPngHeader(bytes);
  return IconFile(
    path: p.relative(file.path, from: packageRoot),
    absolutePath: file.path,
    modified: _modified(file),
    width: header?.width,
    height: header?.height,
    hasAlpha: header?.hasAlpha ?? false,
    density: density,
    resourceType: resourceType,
    declaredSize: declaredSize,
    inherited: inherited,
  );
}

/// A PNG or an `.ico`, decided by extension.
IconFile _imageFile(String packageRoot, File file) {
  if (p.extension(file.path).toLowerCase() != '.ico') {
    return _pngFile(packageRoot, file);
  }

  Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } catch (_) {
    return IconFile(
      path: p.relative(file.path, from: packageRoot),
      absolutePath: file.path,
      modified: _modified(file),
    );
  }

  var frames = readIcoFrames(bytes);
  return IconFile(
    path: p.relative(file.path, from: packageRoot),
    absolutePath: file.path,
    modified: _modified(file),
    width: frames.isEmpty ? null : frames.last,
    height: frames.isEmpty ? null : frames.last,
    // Every `.ico` frame can carry alpha; it says nothing about the artwork.
    icoFrames: frames,
  );
}

DateTime _modified(File file) {
  try {
    return file.lastModifiedSync();
  } catch (_) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// What a PNG's IHDR chunk says.
class PngHeader {
  const PngHeader({
    required this.width,
    required this.height,
    required this.colorType,
    required this.hasTransparencyChunk,
  });

  final int width;
  final int height;

  /// 0 grey, 2 RGB, 3 palette, 4 grey+alpha, 6 RGBA.
  final int colorType;

  /// A `tRNS` chunk, which is how a palette image carries transparency.
  final bool hasTransparencyChunk;

  bool get hasAlpha => colorType == 4 || colorType == 6 || hasTransparencyChunk;
}

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Reads dimensions and colour type straight out of the header.
///
/// A valid PNG always puts IHDR first: 8-byte signature, 4-byte length, `IHDR`,
/// then width and height as big-endian 32-bit values, then bit depth and colour
/// type. Decoding a 1024×1024 image to learn how big it is would cost more than
/// the entire rest of the scan.
PngHeader? readPngHeader(Uint8List bytes) {
  if (bytes.length < 26) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }

  var data = ByteData.sublistView(bytes);
  return PngHeader(
    width: data.getUint32(16),
    height: data.getUint32(20),
    colorType: bytes[25],
    hasTransparencyChunk: _hasChunk(bytes, 'tRNS'),
  );
}

/// Walks the chunk list looking for [type].
///
/// Bounded by the header scan it is used for: it stops at `IDAT`, because
/// everything that describes the image rather than carrying it comes first.
bool _hasChunk(Uint8List bytes, String type) {
  var data = ByteData.sublistView(bytes);
  var offset = 8;
  while (offset + 8 <= bytes.length) {
    var length = data.getUint32(offset);
    var name = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (name == type) return true;
    if (name == 'IDAT') return false;
    offset += 12 + length;
  }
  return false;
}

/// The pixel sizes an `.ico` packs, ascending.
///
/// ICONDIR is a 6-byte header — reserved, type, count — then one 16-byte entry
/// per image, whose first byte is the width with zero meaning 256.
List<int> readIcoFrames(Uint8List bytes) {
  if (bytes.length < 6) return const [];
  var data = ByteData.sublistView(bytes);
  if (data.getUint16(0, Endian.little) != 0) return const [];
  if (data.getUint16(2, Endian.little) != 1) return const [];

  var count = data.getUint16(4, Endian.little);
  var frames = <int>[];
  for (var i = 0; i < count; i++) {
    var offset = 6 + i * 16;
    if (offset + 16 > bytes.length) break;
    var width = bytes[offset];
    frames.add(width == 0 ? 256 : width);
  }
  return frames..sort();
}
