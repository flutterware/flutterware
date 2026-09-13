import 'package:package_config/package_config.dart';
import 'package:pubspec_parse/pubspec_parse.dart' show Pubspec;
import 'package:pub_scores/pub_scores.dart';

import '../../package_ref.dart';
import '../../utils/async_value.dart';
import '../../utils/cloc/cloc.dart';
import 'dependency_graph.dart';
import 'package_imports.dart';
import 'package_origin.dart';
import 'pub_deps.dart';
import 'pub_deps_store.dart';
import 'pub_dev_api.dart';
import 'pubspec_lock.dart';
import 'source.dart';

class DependenciesService {
  final PackageRef package;
  late final dependencies = AsyncValue<Dependencies>(loader: _load);
  late final pubScores = AsyncValue<PubScores>(loader: source.pubScores);
  late final packageImports = AsyncValue<PackageImports>(
    loader: () => source.packageImports(package.absolutePath),
  );

  /// Where every read goes — the project and pub.dev, unless a recording is
  /// standing in for them. See [DependencySource].
  final DependencySource source;

  /// Whether [source] was built here, and so is disposed here.
  final bool _ownsSource;

  /// pub.dev metadata, one [AsyncValue] per package, built on first look.
  ///
  /// Per package and lazy because the detail page is the only thing that wants
  /// it: fetching for all 170 on the way into the list would be 170 requests
  /// nobody asked for.
  final _pubDev = <String, AsyncValue<PubDevPackage>>{};

  /// [source] is the door. The other three build a [LiveDependencySource]
  /// for a caller that has none — a test answering with a captured `pub deps
  /// --json`, or `DependenciesCore` sharing one [PubDepsStore] across the
  /// packages it declares — and cannot be passed beside it.
  DependenciesService(
    this.package, {
    DependencySource? source,
    RunProcess? runProcess,
    PubDevApi? pubDevApi,
    PubDepsStore? pubDepsStore,
  }) : assert(
         source == null ||
             (runProcess == null && pubDevApi == null && pubDepsStore == null),
         'A source answers every read; the other parameters build one.',
       ),
       source =
           source ??
           LiveDependencySource(
             runProcess: runProcess,
             pubDevApi: pubDevApi,
             pubDepsStore: pubDepsStore,
           ),
       _ownsSource = source == null;

  /// What pub.dev says about [name]. Starts the fetch on first subscription.
  ///
  /// The value is nullable inside the snapshot: a git-only or private package
  /// is simply not on pub.dev, which is an answer rather than a failure.
  AsyncValue<PubDevPackage> pubDevFor(String name) => _pubDev.putIfAbsent(
    name,
    () => AsyncValue<PubDevPackage>(
      loader: () async {
        var result = await source.pubDev(name);
        if (result == null) throw const NotOnPubDev();
        return result;
      },
    ),
  );

  Future<Dependencies> _load() async {
    var path = package.absolutePath;
    var pubspec = Pubspec.parse(await source.pubspecText(path));

    // The three sources, each asked only what it alone knows: pub deps for the
    // resolution and the declared constraints, the lockfile for where each
    // package came from, the package config for where each one is on disk.
    var pubDeps = await source.pubDeps(
      flutterSdk: package.flutterSdkPath,
      packagePath: path,
    );
    var lock = await source.lock(path);
    var packageConfig = await source.packageConfig(path);

    return Dependencies.resolve(
      pubspec: pubspec,
      pubDeps: pubDeps,
      lock: lock,
      packageConfig: packageConfig,
      readPubspec: source.dependencyPubspec,
      source: source,
    );
  }

  void dispose() {
    dependencies.dispose();
    pubScores.dispose();
    packageImports.dispose();
    for (var value in _pubDev.values) {
      value.dispose();
    }
    _pubDev.clear();
    if (_ownsSource && source is LiveDependencySource) {
      (source as LiveDependencySource).dispose();
    }
  }
}

/// Not published to pub.dev — a git, path or private package. Carried as an
/// error so the panel can say so rather than showing an empty card forever.
class NotOnPubDev implements Exception {
  const NotOnPubDev();

  @override
  String toString() => 'Not published on pub.dev';
}

/// How one package declares another.
///
/// Per-member, deliberately. `pub deps` reports a workspace-wide
/// `kind` that folds every member's answer into one value, so a package that is
/// direct for `app` reads as direct while you are looking at
/// `fixtures/probe_app`, which may not depend on it at all.
enum DependencyKind {
  /// In this package's `dependencies:`.
  direct,

  /// In this package's `dev_dependencies:`.
  dev,

  /// Reached through something else.
  transitive,
}

/// The dependencies of **one** package, scoped to what that package can reach.
///
/// In a workspace the resolution is shared: `pub deps` reports 174 packages and
/// three roots for this repo whichever member you run it in. Everything here is
/// filtered down to the subgraph reachable from one member, because the
/// alternative — which is what shipped — is `fixtures/probe_app` claiming its
/// siblings' dependencies as its own and reporting 170 direct, 0 transitive
/// where the answer is 14 and 4.
class Dependencies implements Disposable {
  /// [packages] is sorted by name on the way in, so every list this hands out
  /// is stable. Reachability is computed by traversal, and traversal order is
  /// an implementation detail that must not show up in a table.
  Dependencies({
    required this.rootPubspec,
    required this.memberName,
    required Map<String, Dependency> packages,
  }) : _allPackages = {
         for (var name in packages.keys.toList()..sort()) name: packages[name]!,
       } {
    for (var dependency in _allPackages.values) {
      dependency._parent = this;
    }
  }

  /// The pubspec of the package being looked at.
  final Pubspec rootPubspec;

  /// Its name as the resolution knows it.
  final String memberName;

  final Map<String, Dependency> _allPackages;

  Dependency? operator [](String packageName) => _allPackages[packageName];

  Iterable<Dependency> get dependencies => _allPackages.values;

  List<Dependency>? _directs;
  List<Dependency> get directs => _directs ??= _ofKind(DependencyKind.direct);

  List<Dependency>? _devs;

  /// Split out from [directs] because the distinction is actionable — a package
  /// in the wrong one of these two lists is a real bug — while the old model
  /// merged them and could not tell you.
  List<Dependency> get devs => _devs ??= _ofKind(DependencyKind.dev);

  List<Dependency>? _transitives;
  List<Dependency> get transitives =>
      _transitives ??= _ofKind(DependencyKind.transitive);

  List<Dependency> _ofKind(DependencyKind kind) =>
      dependencies.where((e) => e.kind == kind).toList();

  /// Builds the scoped view from the three sources.
  ///
  /// [readPubspec] is passed in rather than called directly so this stays
  /// testable against a fixture with no packages on disk.
  ///
  /// [source] is what each [Dependency] weighs and reads itself with; a
  /// fixture that never asks for that leaves it to the live one.
  static Dependencies resolve({
    required Pubspec pubspec,
    required PubDeps pubDeps,
    required PubspecLock? lock,
    required PackageConfig? packageConfig,
    required Pubspec? Function(String path) readPubspec,
    DependencySource? source,
  }) {
    var member = _member(pubspec.name, pubDeps);
    source ??= LiveDependencySource();

    // Seeded with both, then following only regular dependencies: pub does not
    // resolve a dependency's dev_dependencies, so propagating them would invent
    // edges the resolution does not have.
    var reachable = <String>{};
    var queue = [...member.directDependencies, ...member.devDependencies];
    while (queue.isNotEmpty) {
      var name = queue.removeLast();
      if (name == member.name || !reachable.add(name)) continue;
      queue.addAll(pubDeps[name]?.directDependencies ?? const []);
    }

    var directNames = member.directDependencies.toSet();
    var devNames = member.devDependencies.toSet();

    var packages = <String, Dependency>{};
    for (var name in reachable) {
      var node = pubDeps[name];
      if (node == null) continue;
      var lockEntry = lock?[name];
      var root = packageConfig?[name]?.root.toFilePath();

      packages[name] = Dependency(
        name: name,
        kind: directNames.contains(name)
            ? DependencyKind.direct
            : devNames.contains(name)
            ? DependencyKind.dev
            : DependencyKind.transitive,
        node: node,
        lock: lockEntry,
        origin: lockEntry == null
            ? PackageOrigin.fromSourceName(node.source)
            : PackageOrigin.fromLock(lockEntry),
        constraint: member.dependencyConstraints[name],
        rootPath: root,
        pubspec: root == null ? null : readPubspec(root),
        source: source,
      );
    }

    var dependencies = Dependencies(
      rootPubspec: pubspec,
      memberName: member.name,
      packages: packages,
    );
    dependencies._computeDependants(member);
    return dependencies;
  }

  /// The entry in the resolution that *is* this package.
  ///
  /// By name, not by position: `pub deps` reports `root` as the workspace root
  /// package regardless of which member it ran in, so trusting that field is
  /// how you end up describing the wrong package.
  static PubDepsPackage _member(String name, PubDeps pubDeps) {
    var byName = pubDeps.memberNamed(name);
    if (byName != null) return byName;

    // A standalone project has exactly one member and it is the project, so a
    // name that does not match (a rename between `pub get` and now) is still
    // unambiguous.
    var members = pubDeps.members.toList();
    if (members.length == 1) return members.first;

    throw StateError(
      'Package "$name" is not one of the workspace members in the resolution '
      '(${members.map((e) => e.name).join(', ')}). Run `flutter pub get`.',
    );
  }

  /// Edges, confined to the reachable subgraph.
  ///
  /// The old version walked every package in the workspace's package config, so
  /// a chain shown for one member could route through packages only a sibling
  /// pulls in — an explanation of "why is this here" naming a package that is
  /// not there.
  void _computeDependants(PubDepsPackage member) {
    for (var dependency in _allPackages.values) {
      for (var sub in dependency.node.directDependencies) {
        _allPackages[sub]?.dependants.add(dependency.name);
      }
    }
    for (var name in [
      ...member.directDependencies,
      ...member.devDependencies,
    ]) {
      _allPackages[name]?.dependants.add(member.name);
    }
  }

  @override
  void dispose() {
    for (var dependency in _allPackages.values) {
      dependency.dispose();
    }
  }
}

class Dependency implements Disposable {
  Dependency({
    required this.name,
    required this.kind,
    required this.node,
    required this.lock,
    required this.origin,
    required this.constraint,
    required this.rootPath,
    required this.pubspec,
    required this.source,
  });

  late final Dependencies _parent;

  /// What this package is weighed and read with.
  final DependencySource source;

  final String name;

  final DependencyKind kind;

  /// This package's entry in the resolution.
  final PubDepsPackage node;

  final LockDependency? lock;

  /// Where it came from, with the git ref or relative path filled in. Never
  /// null: an unrecognised source still reports itself, rather than rendering
  /// as the blank cell every workspace member used to get.
  final PackageOrigin origin;

  /// What this package's consumer declared, as written — `^1.2.0`, `any`. Null
  /// for a transitive dependency, which nothing here declared.
  final String? constraint;

  /// Where the package is on disk, or null when the package config does not
  /// place it. Everything that reads files guards on this.
  final String? rootPath;

  /// The dependency's own pubspec, for its description. Null when it could not
  /// be located or parsed.
  final Pubspec? pubspec;

  final dependants = <String>{};

  late final cloc = AsyncValue<ClocReport>(loader: _loadCloc);
  late final size = AsyncValue<SizeReport>(loader: _loadSize);

  /// The version actually resolved — from the lockfile, falling back to what
  /// the resolution reported.
  ///
  /// Not the version in the package's own pubspec, which is what the table used
  /// to print: for a path or git dependency that is whatever the checked-out
  /// file happens to say, and it is unrelated to what pub picked.
  String get resolvedVersion => lock?.version ?? node.version;

  /// SDK packages resolve as `0.0.0`, which is not a version anyone wants
  /// printed. Ask this before showing [resolvedVersion].
  bool get hasMeaningfulVersion => origin is! SdkOrigin;

  String? get description => pubspec?.description;

  /// Declared by this package, in `dependencies:` or `dev_dependencies:`.
  bool get isDirect => kind != DependencyKind.transitive;

  bool get isDev => kind == DependencyKind.dev;

  bool get isTransitive => kind == DependencyKind.transitive;

  Future<ClocReport> _loadCloc() async {
    var path = rootPath;
    if (path == null) return ClocReport(ClocResult.zero, const {});
    return source.cloc(path);
  }

  Future<SizeReport> _loadSize() async {
    var path = rootPath;
    if (path == null) return SizeReport(fileCount: 0, totalBytes: 0);
    return source.size(path);
  }

  /// The first of [candidates] in the package — a readme, a changelog — or
  /// null when the package is not on disk or has none of them.
  Future<({String name, String text})?> document(List<String> candidates) {
    var path = rootPath;
    if (path == null) return Future.value();
    return source.document(path, candidates);
  }

  List<List<String>>? _dependencyPaths;

  /// Why this package is here, shortest chain first.
  ///
  /// Genuinely cached. The field was previously assigned and then never read,
  /// so every access re-ran an unbounded path enumeration — from inside a
  /// `Tooltip`'s build, once per transitive row.
  List<List<String>> get dependencyPaths => _dependencyPaths ??=
      shortestDependencyPaths(name, (e) => _parent[e]?.dependants ?? const {});

  @override
  String toString() => 'Dependency($name)';

  @override
  void dispose() {
    cloc.dispose();
    size.dispose();
  }
}

class SizeReport {
  final int fileCount;
  final int totalBytes;

  SizeReport({required this.fileCount, required this.totalBytes});

  Map<String, Object?> toJson() => {'files': fileCount, 'bytes': totalBytes};

  static SizeReport fromJson(Map<String, Object?> json) => SizeReport(
    fileCount: json['files'] as int? ?? 0,
    totalBytes: json['bytes'] as int? ?? 0,
  );
}
