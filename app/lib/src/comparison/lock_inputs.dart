import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A checkout's resolution, **per package** rather than as one file.
///
/// `pubspec.lock` used to be a pixel input like any other: one path, one
/// digest, folded into every entry's fingerprint. That is correct and blunt —
/// one changed byte anywhere in it re-renders and re-replays the whole
/// project. Measured on this repository against a base five commits back:
///
/// ```
/// 217 entries, 430 rendered, 0 skipped in 47060ms
///   because pubspec.lock differs — 168 entries
/// ```
///
/// In CI that is every dependency bump and every merge that touches a lock,
/// which is exactly where a comparison is most expensive and least useful.
///
/// So the lock is split. Each package's own entry is hashed on its own, and an
/// entry's fingerprint carries only the packages its closure **reaches** — see
/// `ImportGraph.packagesOf` and [ReachableLock]. A bump to a package nothing
/// in the entry names costs nothing; a bump to one it does costs exactly what
/// it always cost.
///
/// The bias is unchanged and the argument for it is the same: a package
/// wrongly included costs one render, a package wrongly left out reports a
/// regression as clean. So the reach is over-approximated at every step — both
/// branches of a conditional import, unused imports, packages named only in a
/// string, and then the whole transitive closure of what those depend on — and
/// anything this cannot answer falls back to [whole], which is the old
/// behaviour exactly.
class LockInputs {
  const LockInputs._({
    required this.byPackage,
    required this.shared,
    required this.whole,
    required this.splittable,
  });

  /// Package name → a digest of that package's lines in the lockfile.
  final Map<String, String> byPackage;

  /// What no package owns.
  ///
  /// Empty, and the empty is the finding. The obvious candidate was the
  /// lock's `sdks:` constraint — it belongs to no package, so "when in doubt,
  /// include" said every entry should carry it. Measured against a base whose
  /// Dart floor had moved, that one line put **145 of 244 entries** back into
  /// the render pass the split had just taken them out of.
  ///
  /// And it cannot decide a pixel. A constraint is not a resolution: both
  /// sides of a comparison render with the *same* SDK — the one the
  /// invocation named, which `ShotKey` already carries — so two checkouts
  /// that disagree about which SDKs they would *accept* still draw with one.
  /// What a raised floor really changes is the package's own language
  /// version, and that is declared in `pubspec.yaml`, which is a pixel input
  /// and stays one.
  final Map<String, String> shared;

  /// The lockfiles hashed whole, as one path→digest map.
  ///
  /// The fallback, and the only thing used when [byPackage] cannot be trusted
  /// — an unparseable lock, or a checkout with no package graph to close the
  /// reach over. Byte-identical to what the pixel inputs produced before the
  /// split, so falling back costs renders and never correctness.
  final Map<String, String> whole;

  /// Whether the split can be used at all.
  ///
  /// False for a checkout whose lockfiles would not parse, or one with no
  /// `.dart_tool/package_graph.json` — without the graph a reached package's
  /// own dependencies are invisible, and narrowing to a set that stops at the
  /// first hop would miss the very bump it was asked about.
  final bool splittable;

  /// Reads [root]'s lockfiles and dependency graph.
  ///
  /// [packagePath] is the package being compared, relative to the checkout:
  /// its own lock is read as well as the workspace's, because a workspace
  /// member resolves at the top and a standalone package resolves beside
  /// itself.
  factory LockInputs.of({required String root, required String packagePath}) {
    // Normalised, because a package at `.` joins to `./pubspec.lock` and the
    // workspace's is `pubspec.lock` — two spellings of one file, which would
    // otherwise be hashed twice and reported as two files differing.
    var paths = {
      p.normalize(p.join(packagePath, 'pubspec.lock')),
      'pubspec.lock',
    }.toList()..sort();

    var whole = <String, String>{};
    var byPackage = <String, String>{};
    var shared = <String, String>{};
    var parsed = true;
    var found = false;

    for (var relative in paths) {
      var file = File(p.join(root, relative));
      if (!file.existsSync()) {
        whole[relative] = _missing;
        continue;
      }
      found = true;
      var text = file.readAsStringSync();
      whole[relative] = _digest(text);
      Object? yaml;
      try {
        yaml = loadYaml(text);
      } on Object {
        parsed = false;
        continue;
      }
      if (yaml is! Map) {
        parsed = false;
        continue;
      }
      if (yaml['packages'] case Map packages) {
        for (var entry in packages.entries) {
          var name = '${entry.key}';
          // Two lockfiles naming one package agree, or the resolution is
          // broken; either way the pair of digests travels rather than one
          // silently winning.
          var key = '$relative#$name';
          byPackage[name] = _digest(
            '${byPackage[name] ?? ''}$key\x00${canonical(_resolution(entry.value))}',
          );
        }
      } else {
        parsed = false;
      }
    }

    return LockInputs._(
      byPackage: byPackage,
      shared: shared,
      whole: whole,
      splittable:
          parsed &&
          found &&
          packageGraphFile(root: root, packagePath: packagePath) != null,
    );
  }

  /// The entries a set of reached packages contributes to a closure.
  ///
  /// Root-relative keys, so they read in a report the way a path does:
  /// `pubspec.lock#flutter_svg differs` says which dependency moved, where
  /// `pubspec.lock differs` said only that something did.
  Map<String, String> forPackages(Set<String> packages) {
    if (!splittable) return whole;
    return {
      ...shared,
      for (var name in packages) 'pubspec.lock#$name': ?byPackage[name],
    };
  }

  static const _missing = '-';

  static String _digest(String text) =>
      sha1.convert(utf8.encode(text)).toString();

  /// A package's lock entry without `dependency:` — whether the package is a
  /// direct dependency or a transitive one.
  ///
  /// That is a fact about the pubspec, not about what was resolved, and it
  /// moved on its own: removing a direct dependency that something else still
  /// pulls in flips it from `direct main` to `transitive` with the same
  /// source and version, and every entry reaching it re-rendered for a change
  /// no picture can show.
  static Object? _resolution(Object? entry) => entry is Map
      ? {
          for (var field in entry.entries)
            if (field.key != 'dependency') field.key: field.value,
        }
      : entry;

  /// A YAML node as text that does not depend on how it was written.
  ///
  /// Keys sorted, because two checkouts whose resolution is identical must
  /// hash identically and nothing promises pub writes a map in one order
  /// forever.
  static String canonical(Object? node) {
    if (node is Map) {
      var keys = node.keys.map((key) => '$key').toList()..sort();
      return '{${[for (var key in keys) '$key:${canonical(node[key])}'].join(',')}}';
    }
    if (node is List) {
      return '[${[for (var value in node) canonical(value)].join(',')}]';
    }
    return '$node';
  }
}

/// The `package_graph.json` that describes [packagePath]'s resolution, or
/// null where there is none.
///
/// Beside the package first, then at the checkout's top. A pub workspace
/// resolves once at the top and its members have no `.dart_tool` of their
/// own; a package resolved on its own — a monorepo that is not a workspace —
/// has its graph beside it and nothing at the top. Looking only at the top
/// found nothing for the second layout, refused the split for every one of
/// its packages, and quietly fell back to the whole lockfile for exactly the
/// repositories with the most packages.
String? packageGraphFile({required String root, required String packagePath}) {
  for (var candidate in {
    p.normalize(p.join(root, packagePath, '.dart_tool', 'package_graph.json')),
    p.join(root, '.dart_tool', 'package_graph.json'),
  }) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Which packages an entry reaches, closed over what those depend on.
///
/// The import graph answers the first hop: the packages an entry's own
/// closure names. This answers the rest — a bump to `vector_math` matters to
/// an entry that imports `flutter_svg` and has never heard of it.
///
/// Read from `.dart_tool/package_graph.json`, which pub writes beside the
/// package config and which is the only file on disk that records what
/// depends on what. Dev dependencies are followed too: a scenario harness is
/// built out of them.
class ReachableLock {
  ReachableLock._(this._dependencies);

  final Map<String, List<String>> _dependencies;

  /// Reads the graph for [packagePath] inside [root] — see
  /// [packageGraphFile] — or an empty one where there is none, which makes
  /// every reach its own first hop and is why [LockInputs.splittable] refuses
  /// the split in that case rather than trusting it.
  factory ReachableLock.of(String root, {required String packagePath}) {
    var path = packageGraphFile(root: root, packagePath: packagePath);
    if (path == null) return ReachableLock._(const {});
    var file = File(path);
    try {
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return ReachableLock._(const {});
      return ReachableLock._({
        for (var package in json['packages'] as List? ?? const [])
          if (package is Map && package['name'] != null)
            '${package['name']}': [
              for (var name in [
                ...?package['dependencies'] as List?,
                ...?package['devDependencies'] as List?,
              ])
                '$name',
            ],
      });
    } on Object {
      return ReachableLock._(const {});
    }
  }

  /// [named] and everything they depend on, transitively.
  Set<String> from(Set<String> named) {
    var seen = <String>{};
    var queue = [...named];
    while (queue.isNotEmpty) {
      var current = queue.removeLast();
      if (!seen.add(current)) continue;
      queue.addAll(_dependencies[current] ?? const []);
    }
    return seen;
  }
}
