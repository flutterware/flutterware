import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'refusal.dart';
import 'run_files.dart';

/// The `--flavor` a package builds with when nobody says otherwise, from its
/// pubspec's `flutter: default-flavor:`.
///
/// This is Flutter's own field, not ours — `FlutterManifest.defaultFlavor`,
/// applied by every flavour-taking command as `flavor = cliFlavor ??
/// defaultFlavor`. So a project that set it is a project where `flutter run`
/// with no `--flavor` already works, and a cockpit that offered an empty field
/// there was asking for something the project had written down two files away.
///
/// Read rather than inferred, and only this one key: the *list* of flavors a
/// project has lives in Gradle and in Xcode schemes, which is a different job
/// with two parsers in it. This is the one that costs a `loadYaml`.
String? defaultFlavorOf(
  String packageRoot, {
  RunFiles files = const DiskRunFiles(),
}) {
  try {
    var text = files.readString(p.join(packageRoot, 'pubspec.yaml'));
    if (text == null) return null;
    var yaml = loadYaml(text);
    if (yaml is! Map) return null;
    var flutter = yaml['flutter'];
    if (flutter is! Map) return null;
    var flavor = flutter['default-flavor'];
    return flavor is String && flavor.isNotEmpty ? flavor : null;
  } on Object {
    // A pubspec that will not parse is a problem the dependencies plugin
    // reports properly. Here it means one less field filled in.
    return null;
  }
}

/// Where the `--flavor` about to be built came from.
///
/// Carried rather than reduced to a string because the New run page shows the
/// flavor as a line of text instead of a field to fill, and a value with no
/// provenance is indistinguishable from a guess.
enum FlavorSource {
  /// `Entrypoint(flavor: 'dev')` — the pairing that motivated the field.
  entrypoint,

  /// The package's `flutter: default-flavor:`.
  pubspec,

  /// Nothing declared one, and none will be passed.
  none,
}

/// The flavor to build [entrypointFlavor]'s entry point with, and why.
///
/// Deliberately not given the caller's per-launch override: an override is the
/// answer to a different question — what *this* run does — and folding it in
/// here would make the panel unable to say what the project declares once the
/// user had typed over it.
///
/// [byPlatform] is the entry point's per-platform pairing and wins where it
/// names the platform launched onto, described by [platformType] and
/// [category] — the two strings `flutter daemon` reports about a device, both
/// optional there, which is why this takes them rather than an enum a caller
/// would have to derive. A device that says nothing about itself resolves as
/// if the map were empty: falling back to the plain declaration is the safe
/// direction, and the platforms it could mis-serve are the desktop ones,
/// which always name themselves.
({String? flavor, FlavorSource source}) resolveFlavor({
  required String? entrypointFlavor,
  required String? packageDefault,
  Map<RunPlatform, String> byPlatform = const {},
  String? platformType,
  String? category,
}) {
  var paired = lookupByPlatform(
    byPlatform,
    platformType: platformType,
    category: category,
  );
  if (paired != null && paired.isNotEmpty) {
    return (flavor: paired, source: FlavorSource.entrypoint);
  }
  if (entrypointFlavor != null && entrypointFlavor.isNotEmpty) {
    return (flavor: entrypointFlavor, source: FlavorSource.entrypoint);
  }
  if (packageDefault != null && packageDefault.isNotEmpty) {
    return (flavor: packageDefault, source: FlavorSource.pubspec);
  }
  return (flavor: null, source: FlavorSource.none);
}

/// [map]'s entry for the platform a device describes, or null for a platform
/// it does not name.
///
/// A concrete key beats a shorthand — `ios:` wins over `mobile:` for an
/// iPhone — and the two shorthands cannot overlap each other, so this is the
/// whole precedence. A device reporting no `platformType` can still match a
/// shorthand key through its daemon `category`, which groups devices the same
/// way the shorthands do.
T? lookupByPlatform<T>(
  Map<RunPlatform, T> map, {
  String? platformType,
  String? category,
}) {
  if (map.isEmpty) return null;
  var platform = RunPlatform.byName(platformType ?? '');
  if (platform != null) {
    if (map[platform] case var direct?) return direct;
    for (var entry in map.entries) {
      if (entry.key.expanded.contains(platform) && entry.key != platform) {
        return entry.value;
      }
    }
    return null;
  }
  var shorthand = RunPlatform.byName(category ?? '');
  return shorthand != null ? map[shorthand] : null;
}

/// The flavors a package's config declares per platform, from the raw
/// `flavors` map — `RunPackage.flavors` on the wire.
///
/// Same forgiving posture as the other config decoders: a platform name this
/// build has no member for is dropped rather than refused, and a value that
/// is not a list of strings likewise. An **empty list survives** — it is a
/// declaration ("this platform has no flavors"), not an absence.
Map<RunPlatform, List<String>> declaredFlavors(Object? raw) => {
  for (var entry in (raw is Map ? raw.entries : const <MapEntry>[]))
    if (entry.key case String name)
      if (entry.value case List values)
        ?RunPlatform.byName(name): [
          for (var value in values)
            if (value is String) value,
        ],
};

/// [flavor], as [vocabulary] allows it — the declared list for the platform
/// being launched onto, or null where the package declared none.
///
/// Three of the four vocabulary rules live here (the fourth — no declaration
/// — is [vocabulary] arriving null): an unknown platform passes [flavor]
/// through unchecked, an empty list drops it the way web drops its flag, and
/// a list that does not contain it refuses **before anything is built** —
/// the alternative is a Gradle failure minutes later, or worse, a Linux
/// build that quietly runs under a meaningless `FLUTTER_APP_FLAVOR` because
/// nothing on that platform gates the name.
///
/// Refusing the caller's own word too, not only a declaration, follows the
/// knob-name check: a declared vocabulary is authority the way a declared
/// signature is, and the refusal names both the list and the way out.
String? applyFlavorVocabulary({
  required String? flavor,
  required List<String>? vocabulary,
  required String package,
  required String platformLabel,
}) {
  if (flavor == null || vocabulary == null) return flavor;
  if (vocabulary.isEmpty) return null;
  if (vocabulary.contains(flavor)) return flavor;
  throw RunRefusal(
    '"$flavor" is not a flavor $package declares for $platformLabel — it has '
    '${vocabulary.join(', ')}. Pass one of those, an empty `flavor` to build '
    'without one, or add it to the `flavors:` list in tool/flutterware.dart.',
  );
}
