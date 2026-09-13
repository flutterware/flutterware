/// What the project itself says about which icons the OS should reach.
///
/// This is the half that makes the viewer more than a file browser. A PNG in
/// `mipmap-xxhdpi/` proves nothing: whether Android ever draws it depends on
/// `mipmap-anydpi-v26/ic_launcher.xml` and on `android:icon` in the manifest.
/// Reading those two answers "is this file dead?", which nothing else in the
/// toolchain will tell you.
///
/// These are reads of the project, not of a generator's config. Nothing here
/// opens `icons_launcher.yaml` or `flutter_launcher_icons.yaml` — the whole
/// point is that the answer is the same however the files got there.
///
/// Parsed rather than pattern-matched, which is not merely tidier. The manifest
/// carries `android:icon` in several places — on `<application>`, and on any
/// `<activity>` that overrides it — and only the one on `<application>` is the
/// launcher icon. `icons_launcher` rewrites *every* line containing the
/// attribute (`android.dart`, `_updateAndroidManifestIconLauncher`), which is
/// the bug that regex invites. Reading `manifest > application` by name cannot
/// make that mistake.
library;

import 'dart:io';

import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

part 'wiring.g.dart';

/// An `<adaptive-icon>` file and the layers it declares.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class AdaptiveXml {
  const AdaptiveXml({
    required this.path,
    this.background,
    this.foreground,
    this.monochrome,
  });

  factory AdaptiveXml.fromJson(Map<String, Object?> json) =>
      _$AdaptiveXmlFromJson(json);

  Map<String, Object?> toJson() => _$AdaptiveXmlToJson(this);

  /// Package-relative.
  final String path;

  /// The resource each layer points at — `@mipmap/ic_launcher_foreground`,
  /// `@color/ic_launcher_background` — or null when the element is absent.
  ///
  /// Absent is the interesting value: a `<monochrome>` that is not there is why
  /// a themed-icon PNG on disk never appears on a device.
  final String? background;
  final String? foreground;
  final String? monochrome;

  bool get hasMonochrome => monochrome != null;

  /// The resource names this file references, without their `@type/` prefix.
  Set<String> get referencedNames => {
    for (var value in [background, foreground, monochrome])
      if (value != null) resourceName(value),
  };
}

/// Everything the Android project says about its own icons.
@JsonSerializable(explicitToJson: true, includeIfNull: false)
class AndroidWiring {
  const AndroidWiring({
    this.manifestIcon,
    this.manifestRoundIcon,
    this.launcher,
    this.launcherRound,
    this.backgroundColor,
  });

  factory AndroidWiring.fromJson(Map<String, Object?> json) =>
      _$AndroidWiringFromJson(json);

  Map<String, Object?> toJson() => _$AndroidWiringToJson(this);

  /// `android:icon` and `android:roundIcon` from `<application>` — not from any
  /// `<activity>` that overrides them, which is a different icon for a
  /// different purpose.
  final String? manifestIcon;
  final String? manifestRoundIcon;

  final AdaptiveXml? launcher;
  final AdaptiveXml? launcherRound;

  /// `ic_launcher_background` from `values/colors.xml`, when the adaptive
  /// background is a colour rather than an image.
  final String? backgroundColor;

  /// Every resource name the OS is told to reach, from any of the three
  /// sources. What a file has to appear in to be something other than dead.
  Set<String> get referencedNames => {
    for (var value in [manifestIcon, manifestRoundIcon])
      if (value != null) resourceName(value),
    ...?launcher?.referencedNames,
    ...?launcherRound?.referencedNames,
  };
}

/// `@mipmap/ic_launcher` → `ic_launcher`.
String resourceName(String reference) => reference.split('/').last;

/// `@mipmap/ic_launcher` → `mipmap`, or null when the reference names no type.
///
/// The type is the other half of a reference, and it is what decides where
/// Android looks: `@drawable/x` resolves against `drawable*` and `@mipmap/x`
/// against `mipmap*`. Compare names alone and the two become the same
/// resource — which is how a foreground sitting in `drawable-xxhdpi/`, where
/// `flutter_launcher_icons` writes it by default, gets reported as missing.
String? resourceType(String reference) {
  var slash = reference.indexOf('/');
  if (slash <= 0) return null;
  return reference.substring(0, slash).replaceFirst('@', '');
}

/// Parses an Android resource colour to ARGB, or null when it is not one.
///
/// The platform accepts `#RGB`, `#ARGB`, `#RRGGBB` and `#AARRGGBB`, and the
/// short forms expand by doubling each digit. Kept apart from the splash
/// plugin's `parseSplashColor`, which is a transcription of one generator's
/// stricter rule — six digits only, no alpha — and would reject values Android
/// itself accepts.
int? parseResourceColor(String? value) {
  if (value == null) return null;
  var digits = value.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(digits)) return null;

  var expanded = switch (digits.length) {
    3 || 4 => digits.split('').map((d) => '$d$d').join(),
    6 || 8 => digits,
    _ => null,
  };
  if (expanded == null) return null;

  var parsed = int.tryParse(expanded, radix: 16);
  if (parsed == null) return null;
  return expanded.length == 6 ? 0xFF000000 | parsed : parsed;
}

/// Reads the wiring for one Android variant.
///
/// [resFolders] are the source sets Gradle would merge, **base first**: a
/// flavored build is `[main/res, <flavor>/res]`, an unflavored one is
/// `[main/res]` alone. Merged rather than replaced because that is what the
/// build does — a flavor overriding one bitmap still gets main's adaptive XML
/// and main's background colour, and reading the flavor's folder alone reports
/// a project that has neither.
///
/// The two kinds of resource merge differently and are read that way. A
/// *file* resource is overridden whole, so the last folder that has
/// `mipmap-anydpi-v26/ic_launcher.xml` wins outright; a *values* resource
/// merges by name, so `ic_launcher_background` is taken from the last folder
/// that declares that colour, whatever else its `colors.xml` does or does not
/// say.
///
/// [resFolders] and [manifestPath] are absolute; paths in the result are made
/// relative to [packageRoot].
AndroidWiring readAndroidWiring({
  required String packageRoot,
  required List<String> resFolders,
  required String manifestPath,
}) {
  var application = _parse(File(manifestPath))?.rootElement
      .getElement('application');

  return AndroidWiring(
    manifestIcon: application?.getAttribute('android:icon'),
    manifestRoundIcon: application?.getAttribute('android:roundIcon'),
    launcher: _readAdaptive(packageRoot, resFolders, 'ic_launcher.xml'),
    launcherRound: _readAdaptive(
      packageRoot,
      resFolders,
      'ic_launcher_round.xml',
    ),
    backgroundColor: _readBackgroundColor(resFolders),
  );
}

AdaptiveXml? _readAdaptive(
  String packageRoot,
  List<String> resFolders,
  String fileName,
) {
  File? found;
  XmlDocument? document;
  for (var resFolder in resFolders) {
    var file = File(p.join(resFolder, 'mipmap-anydpi-v26', fileName));
    var parsed = _parse(file);
    if (parsed == null) continue;
    found = file;
    document = parsed;
  }
  if (found == null || document == null) return null;
  var file = found;

  return AdaptiveXml(
    path: p.relative(file.path, from: packageRoot),
    background: _layerDrawable(document.rootElement, 'background'),
    foreground: _layerDrawable(document.rootElement, 'foreground'),
    monochrome: _layerDrawable(document.rootElement, 'monochrome'),
  );
}

/// The drawable one adaptive-icon layer points at.
///
/// Both spellings resolve: the attribute on the layer element itself, and the
/// wrapper form where an `<inset>` or `<layer-list>` child carries it, which is
/// what Android Studio's Image Asset tool emits.
String? _layerDrawable(XmlElement root, String layer) {
  var element = root.getElement(layer);
  if (element == null) return null;

  var onElement = element.getAttribute('android:drawable');
  if (onElement != null) return onElement;

  for (var descendant in element.descendantElements) {
    var drawable = descendant.getAttribute('android:drawable');
    if (drawable != null) return drawable;
  }
  return null;
}

String? _readBackgroundColor(List<String> resFolders) {
  String? found;
  for (var resFolder in resFolders) {
    var document = _parse(File(p.join(resFolder, 'values', 'colors.xml')));
    if (document == null) continue;
    for (var color in document.rootElement.findElements('color')) {
      if (color.getAttribute('name') == 'ic_launcher_background') {
        found = color.innerText.trim();
      }
    }
  }
  return found;
}

/// Parses [file], or null when it is absent, unreadable or malformed.
///
/// Malformed is null rather than a throw for the reason the splash scan gives
/// about YAML: a file being edited is briefly unparseable, and a panel that
/// redraws without it beats a scan that fails.
XmlDocument? _parse(File file) {
  if (!file.existsSync()) return null;
  try {
    return XmlDocument.parse(file.readAsStringSync());
  } catch (_) {
    return null;
  }
}
