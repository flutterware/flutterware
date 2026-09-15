import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

// ignore: implementation_imports
import 'package:flutterware/src/scenarios/network_store.dart'
    show defaultScenarioNetworkStore;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../previews/project_shaders.dart';
import 'closure.dart';
import 'lock_inputs.dart';

/// The pixel inputs no compile ever names, for the package at [packagePath].
///
/// The Dart closure knows every import; it knows nothing about the bytes of
/// an asset, a project shader and the includes it pulls in, the resolution in
/// a lockfile or an `.arb` bundle, and all of them decide pixels. Until these
/// were passed, a worktree that changed only an asset computed the same shot
/// key as its base and the comparison served the base's picture back as
/// "same" — a regression reported as clean, which is the outcome the cache's
/// own doc calls worse than no comparison.
///
/// Returned as root-relative paths whose *content* is hashed per side; a path
/// absent on one side hashes as [SourceClosure.missing], so a deleted asset
/// reads as a change the same way an edited one does. Directory assets and
/// bundle directories are listed in **every** root and unioned, because a
/// file only one side has is by definition missing from the other side's
/// listing — a single-side listing would let an added or deleted file slip
/// through unhashed.
///
/// `package_config.json` is deliberately *not* here even though resolution
/// lives in it: pub stamps it with a generation time, so its bytes differ
/// between two checkouts whose resolution is identical, and hashing it would
/// turn every skip into a render. The lockfiles carry the same information
/// with stable bytes.
///
/// **The lockfiles are not here either, and that is the one exception to
/// "everything here decides every entry".** They decide every entry that
/// *reaches* the package that moved and no others, so they are read per
/// package by [LockInputs] and folded in per entry rather than once per
/// checkout. Everything else in this list — the asset tree, the manifest, the
/// `.arb` bundles — really is the same answer for all of them.
List<String> pixelInputsOf({
  required String packagePath,
  required List<String> roots,
}) {
  var paths = <String>{
    p.join(packagePath, 'pubspec.yaml'),
    p.join(packagePath, 'l10n.yaml'),
  };
  for (var root in roots) {
    paths.addAll(_declaredAssets(root, packagePath));
    paths.addAll(_l10nBundles(root, packagePath));
  }
  return paths.toList()..sort();
}

/// What [pixelInputsOf] listed, hashed **once per checkout**.
///
/// A constant of the plan, exactly as the SDK key is. The same lockfiles,
/// the same asset tree and the same `.arb` bundles decide every entry, so
/// there is one answer per checkout and not one per entry.
///
/// It used to be passed around as the path list and re-hashed by each entry's
/// [SkipDecision] and by both of its shot keys. Measured on a catalog of 90
/// previews and 46 scenarios: 452 passes over the same 254 files — 18.5 MB,
/// a 9.9 MB emoji font among them — for an answer that was identical every
/// time. It ran on the UI isolate, so the window was dead for four minutes
/// whenever the Changes panel was opened.
class PixelInputs {
  PixelInputs(this.paths);

  /// Lists what decides pixels for [packagePath] across [roots], then holds it.
  factory PixelInputs.of({
    required String packagePath,
    required List<String> roots,
  }) => PixelInputs(pixelInputsOf(packagePath: packagePath, roots: roots));

  /// [PixelInputs.of] for scenarios: the same list, and the recording a
  /// `replay` scenario answers its requests from.
  ///
  /// The recording is committed, read at run time, and imported by nothing —
  /// so a re-recorded endpoint changed what a scenario drew while every file
  /// the skip rule watched stayed the same, and the scenario was skipped. The
  /// package's default store only: one moved elsewhere by `FW_NETWORK_STORE`
  /// or a define is named where nothing here can read it.
  factory PixelInputs.ofScenarios({
    required String packagePath,
    required List<String> roots,
  }) => PixelInputs(
    {
      ...pixelInputsOf(packagePath: packagePath, roots: roots),
      for (var root in roots)
        ..._filesIn(
          root,
          p.join(packagePath, defaultScenarioNetworkStore),
          (_) => true,
        ),
    }.toList()..sort(),
  );

  /// Root-relative, and the same list for every checkout: a path only one side
  /// has still has to be looked for on the other, where it reads as missing.
  final List<String> paths;

  final _byRoot = <String, SourceClosure>{};

  /// [paths] as they are in [root] — hashed on the first ask, kept after.
  ///
  /// A package's `pubspec.yaml` is hashed as [pubspecPixelDigest] rather than
  /// as bytes, under its own path, so a reason still reads `pubspec.yaml
  /// differs` when a part of it that decides pixels moved.
  SourceClosure inRoot(String root) => _byRoot.putIfAbsent(root, () {
    var closure = SourceClosure.of(paths, root: root);
    return SourceClosure({
      for (var MapEntry(key: path, value: digest) in closure.digests.entries)
        path:
            p.basename(path) == 'pubspec.yaml' &&
                digest != SourceClosure.missing
            ? pubspecPixelDigest(p.join(root, path))
            : digest,
    });
  });
}

/// A digest of the parts of the `pubspec.yaml` at [path] that can change a
/// pixel.
///
/// The whole file was a pixel input for every entry of its package, so any
/// byte decided every picture. Measured on a consumer's merge request that
/// removed one dependency from one package and added a `flutter: config:` flag
/// to another: 420 preview renders and 258 scenario replays, on a CI runner
/// that was already the heaviest job on its host — and not one pixel in them
/// could have moved.
///
/// What is left out, and what covers it instead:
///
/// - `dependencies`, `dev_dependencies`, `dependency_overrides`: what they
///   resolve to is in the lockfile, read per reached package by [LockInputs],
///   and what an entry imports is in its closure. A dependency nothing reaches
///   decides nothing.
/// - `flutter: config:`: feature flags the `flutter` tool passes to an app it
///   builds. No lane here builds through the tool, so none reaches a render.
///   The day one does, this line is where it has to come back.
/// - `description`, `version`, `homepage`, `repository`, `issue_tracker`,
///   `documentation`, `publish_to`, `funding`, `topics`, `screenshots`,
///   `false_secrets`, `executables`, `platforms`: what pub.dev reads.
///
/// Everything else stays, **including what this does not recognise**: the
/// bias is the lockfile's — a key wrongly kept costs a render, a key wrongly
/// dropped reports a regression as clean. That keeps `environment` (the SDK
/// floor sets the language version), `name`, `hooks` (build-hook user
/// defines), and every other `flutter:` key: assets, fonts, shaders,
/// `generate`, `uses-material-design`, `deferred-components`, flavors.
///
/// A file that will not parse is hashed as bytes.
String pubspecPixelDigest(String path) {
  String text;
  try {
    text = File(path).readAsStringSync();
  } on FileSystemException {
    return SourceClosure.missing;
  }
  Object? yaml;
  try {
    yaml = loadYaml(text);
  } on Object {
    yaml = null;
  }
  if (yaml is! Map) return sha1.convert(utf8.encode(text)).toString();
  var kept = <String, Object?>{
    for (var entry in yaml.entries)
      if (!_pubspecMetadata.contains('${entry.key}'))
        '${entry.key}': entry.key == 'flutter' && entry.value is Map
            ? {
                for (var flutter in (entry.value as Map).entries)
                  if (flutter.key != 'config') '${flutter.key}': flutter.value,
              }
            : entry.value,
  };
  return sha1
      .convert(utf8.encode('pubspec-pixels\x00${LockInputs.canonical(kept)}'))
      .toString();
}

const _pubspecMetadata = {
  'dependencies',
  'dev_dependencies',
  'dependency_overrides',
  'description',
  'version',
  'homepage',
  'repository',
  'issue_tracker',
  'documentation',
  'publish_to',
  'funding',
  'topics',
  'screenshots',
  'false_secrets',
  'executables',
  'platforms',
};

Iterable<String> _declaredAssets(String root, String packagePath) sync* {
  var flutter = _yamlMap(p.join(root, packagePath, 'pubspec.yaml'))?['flutter'];
  if (flutter is! Map) return;
  if (flutter['assets'] case List assets) {
    for (var entry in assets) {
      // An entry is a path, or since flavors a map carrying one.
      var asset = entry is Map ? entry['path'] : entry;
      if (asset is! String) continue;
      if (!asset.endsWith('/')) {
        yield p.join(packagePath, asset);
        continue;
      }
      // A directory asset bundles its direct files.
      yield* _filesIn(root, p.join(packagePath, asset), (_) => true);
    }
  }
  if (flutter['fonts'] case List families) {
    for (var family in families) {
      if (family is! Map) continue;
      if (family['fonts'] case List fonts) {
        for (var font in fonts) {
          if (font is Map && font['asset'] is String) {
            yield p.join(packagePath, font['asset'] as String);
          }
        }
      }
    }
  }
  if (flutter['shaders'] case List shaders) {
    for (var shader in shaders) {
      if (shader is String) yield* _shaderFiles(root, packagePath, shader);
    }
  }
}

/// A declared shader and every local `#include` it reaches in [root].
///
/// The program a pass paints with is compiled from all of them, so an edit
/// to an include alone is a new picture. The walk is
/// [projectShaderHashWithFiles]'s — the one the compile cache keys on, which
/// looks where `impellerc` looks — so this names exactly the files a compile
/// read. The declared path is listed even when it is not there, like any
/// asset: missing on one side is a change.
Iterable<String> _shaderFiles(
  String root,
  String packagePath,
  String shader,
) sync* {
  var declared = p.join(packagePath, shader);
  yield declared;
  var source = p.join(root, declared);
  if (!File(source).existsSync()) return;
  List<String> files;
  try {
    files = projectShaderHashWithFiles(source).files;
  } on FileSystemException {
    // A file that went while it was walked; the declared path still reads.
    return;
  }
  var absoluteRoot = p.normalize(p.absolute(root));
  for (var file in files) {
    yield p.relative(file, from: absoluteRoot);
  }
}

Iterable<String> _l10nBundles(String root, String packagePath) sync* {
  var arbDir = _yamlMap(p.join(root, packagePath, 'l10n.yaml'))?['arb-dir'];
  if (arbDir is! String) return;
  yield* _filesIn(
    root,
    p.join(packagePath, arbDir),
    (name) => name.endsWith('.arb'),
  );
}

/// The root-relative paths of [relativeDir]'s direct files, or nothing when
/// the directory is not there in this root.
Iterable<String> _filesIn(
  String root,
  String relativeDir,
  bool Function(String name) wanted,
) sync* {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(p.join(root, relativeDir)).listSync();
  } on FileSystemException {
    return;
  }
  for (var entity in entries) {
    var name = p.basename(entity.path);
    // Finder drops one into any directory somebody has opened, `.gitignore`
    // hides it by convention — so it exists in the worktree and never in a
    // base checkout made from git, and every closure that folds the directory
    // in differs forever. It cannot affect a pixel, and the cost of hashing it
    // is a silent 20× with slowness as the only symptom: measured on a real
    // 51-scenario suite, deleting two of these took a no-change comparison
    // from 2m52s to 8s.
    if (name == '.DS_Store') continue;
    if (entity is File && wanted(name)) {
      yield p.join(relativeDir, name);
    }
  }
}

Map<Object?, Object?>? _yamlMap(String path) {
  try {
    var doc = loadYaml(File(path).readAsStringSync());
    return doc is Map ? doc : null;
  } on Object {
    // Absent, unreadable, or not yaml — nothing to declare assets from.
    return null;
  }
}

/// Whether an entry has to be rendered at all.
///
/// The skip rule, and the reason a comparison of a 213-entry catalog takes
/// seconds: if nothing an entry reads differs between the two checkouts, the
/// entry cannot have changed, so neither side is rendered and the row is
/// reported `same`.
///
/// Its second-order effect is the one that shows: deciding this is *only*
/// hashing, so the verdict for every entry lands before the first render
/// starts. The screen knows its full shape immediately and the pictures fill
/// in behind it.
class SkipDecision {
  const SkipDecision({
    required this.skip,
    required this.changed,
    required this.reason,
  });

  final bool skip;

  /// The paths that differ, when any do — the long form of [reason].
  final List<String> changed;

  /// Why it could not be skipped, or null when it was.
  ///
  /// Phrased as one clause naming a path, because a plan's reasons are folded
  /// into [foldReasons] and shown as they are. It is the only thing that can
  /// answer "why did a branch that touched no widget render all ninety
  /// entries", and until it was shown, nothing could: a consumer measured
  /// 141 of 141 entries rendered against an empty diff and had no way to
  /// learn which path the two checkouts disagreed about.
  final String? reason;

  /// Decides for one entry, given the paths it was last compiled from.
  ///
  /// [pixels] are the inputs the compiler's own list does not name and that
  /// still decide pixels: the asset manifest and every asset it points at,
  /// the l10n bundles. [lock] is the resolution of the packages *this* entry
  /// reaches — see [LockInputs], which is why it is per entry where [pixels]
  /// is per checkout. **The bias is deliberate.** A path
  /// wrongly included costs one render; a path wrongly left out reports a
  /// regression as clean, and nothing downstream can detect it. When in
  /// doubt, include.
  ///
  /// It arrives already hashed because it is the same answer for every entry —
  /// see [PixelInputs].
  ///
  /// [digests] is the pass's [DigestCache]. Every entry in a catalog is
  /// decided against the same two checkouts and their closures overlap almost
  /// entirely, so passing one across the loop is the difference between
  /// reading a file once and reading it once per entry.
  static SkipDecision of({
    required String entryId,
    required ClosureMemo memo,
    required String baseRoot,
    required String headRoot,
    PixelInputs? pixels,
    DigestCache? digests,
    LockReach? lock,
  }) {
    var remembered = memo.recall(entryId);
    if (remembered == null) {
      // Nothing has compiled this entry here, so nothing knows what it reads.
      // The first comparison against a base pays full price and teaches the
      // memo; every later one is cheap.
      return const SkipDecision(
        skip: false,
        changed: [],
        reason:
            'nothing has compiled this entry yet, so what it reads is '
            'unknown',
      );
    }
    var base = SourceClosure.of(
      remembered,
      root: baseRoot,
      digests: digests,
    ).merge(pixels?.inRoot(baseRoot)).merge(lock?.inRoot(baseRoot));
    var head = SourceClosure.of(
      remembered,
      root: headRoot,
      digests: digests,
    ).merge(pixels?.inRoot(headRoot)).merge(lock?.inRoot(headRoot));
    if (base.fingerprint == head.fingerprint) {
      return const SkipDecision(skip: true, changed: [], reason: null);
    }
    var changed = head.changedAgainst(base);
    return SkipDecision(
      skip: false,
      changed: changed,
      reason: switch (changed.length) {
        1 => '${changed.single} differs',
        var n => '$n files differ, including ${changed.first}',
      },
    );
  }
}

/// The reasons a plan rendered what it rendered, folded — reason → how many
/// entries carried it, commonest first.
///
/// Folded because a plan's reasons are overwhelmingly the *same* reason: one
/// file both checkouts disagree about is in every entry's closure, so ninety
/// entries produce one line rather than ninety. That is also the shape of the
/// failure this exists to name — a skip rule that answers nothing does it to
/// every entry at once, for one cause.
/// Several halves' folded reasons, folded again — the same shape, ordered the
/// same way, with each package's count added to whatever the others said.
///
/// A comparison spanning four packages produces four `because` maps naming
/// mostly the same paths, and a reader wants one list of causes rather than
/// four to read in turn.
Map<String, int> mergeBecause(Iterable<Map<String, int>> maps) {
  var counts = <String, int>{};
  for (var map in maps) {
    map.forEach(
      (reason, count) => counts[reason] = (counts[reason] ?? 0) + count,
    );
  }
  return Map.fromEntries(
    counts.entries.toList()..sort((a, b) {
      var byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    }),
  );
}

Map<String, int> foldReasons(Iterable<String> reasons) {
  var counts = <String, int>{};
  for (var reason in reasons) {
    counts[reason] = (counts[reason] ?? 0) + 1;
  }
  return Map.fromEntries(
    counts.entries.toList()..sort((a, b) {
      var byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    }),
  );
}

/// One entry's slice of both checkouts' lockfiles.
///
/// The per-entry half of [LockInputs]: the packages the entry reaches, closed
/// over their own dependencies, resolved against whichever side is being
/// hashed. Built once per entry and asked twice, because the reach is a fact
/// about the entry and the digests are facts about the checkouts.
class LockReach {
  const LockReach(this._byRoot, this._packages);

  final Map<String, LockInputs> _byRoot;
  final Set<String> _packages;

  /// What this entry's reach contributes to a closure read from [root].
  SourceClosure? inRoot(String root) {
    var inputs = _byRoot[root];
    return inputs == null ? null : SourceClosure(inputs.forPackages(_packages));
  }
}

/// Both checkouts' lockfiles and their dependency graphs, read once.
///
/// The twin of [PixelInputs] and split for the same reason: a lockfile is the
/// same file for every entry, and only the *slice* of it an entry carries
/// differs. Reading it per entry would be one YAML parse of a thousand-line
/// file per row.
class LockSides {
  LockSides({required this.packagePath, required List<String> roots})
    : _inputs = {
        for (var root in roots)
          root: LockInputs.of(root: root, packagePath: packagePath),
      },
      // The reach is closed over the **head** graph, like every other shape
      // the plan takes from one side: a branch that added a dependency should
      // have the entry that uses it rendered, and the base has never heard of
      // it.
      _reach = ReachableLock.of(roots.first, packagePath: packagePath);

  final String packagePath;
  final Map<String, LockInputs> _inputs;
  final ReachableLock _reach;

  /// The slice an entry naming [packages] carries.
  LockReach forPackages(Set<String> packages) =>
      LockReach(_inputs, _reach.from(packages));
}
