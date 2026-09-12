/// Where the dependencies plugin reads from.
///
/// [DependenciesService] composes the picture — the resolution scoped to one
/// member, what pub.dev says, what each package weighs — and this is every
/// read it makes, behind one interface. [LiveDependencySource] is the
/// project's own files, its resolution, the pub cache and pub.dev, which is
/// the plugin as it always was. The recorded project hands the service a
/// source that answers from a recording instead — see
/// `demo/recorded_dependencies.dart` — and nothing above this line knows the
/// difference, which is what lets the live panel run where there is no
/// filesystem, no process and no network.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:pub_scores/pub_scores.dart';
import 'package:pubspec_parse/pubspec_parse.dart' show Pubspec;

import '../../utils/cloc/cloc.dart';
import '../../utils/flutter_sdk.dart';
import '../../utils/list_files.dart';
import 'package_imports.dart';
import 'pub_deps.dart';
import 'pub_deps_store.dart';
import 'pub_dev_api.dart';
import 'pubspec_lock.dart';
import 'service.dart' show SizeReport;

abstract class DependencySource {
  const DependencySource();

  /// The text of the package's own `pubspec.yaml`.
  Future<String> pubspecText(String packagePath);

  /// The resolution governing the package, as `pub deps --json` reports it.
  ///
  /// The SDK rather than its executable, because naming the executable reads
  /// the platform, and a source that spawns nothing runs where there is none.
  Future<PubDeps> pubDeps({
    required FlutterSdkPath flutterSdk,
    required String packagePath,
  });

  /// The lockfile governing the package, or null when it was never resolved.
  Future<PubspecLock?> lock(String packagePath);

  /// Where each package of the resolution is, or null when there is no
  /// package config to say.
  Future<PackageConfig?> packageConfig(String packagePath);

  /// A dependency's own pubspec at [rootPath], or null when it cannot be read.
  /// Synchronous, because the join that asks for it is.
  Pubspec? dependencyPubspec(String rootPath);

  /// The pub.dev scores table, for every package it knows.
  Future<PubScores> pubScores();

  /// Which packages the source under [packagePath] refers to, and from where.
  Future<PackageImports> packageImports(String packagePath);

  /// What pub.dev says about [name] — null when it is not there.
  Future<PubDevPackage?> pubDev(String name);

  Future<ClocReport> cloc(String rootPath);

  Future<SizeReport> size(String rootPath);

  /// The first of [candidates] under [rootPath] — its name and its text — or
  /// null when none is there.
  Future<({String name, String text})?> document(
    String rootPath,
    List<String> candidates,
  );
}

/// The project's files, its resolution, the pub cache and pub.dev.
class LiveDependencySource extends DependencySource {
  LiveDependencySource({
    this.runProcess,
    PubDevApi? pubDevApi,
    PubDepsStore? pubDepsStore,
  }) : assert(
         pubDepsStore == null || runProcess == null,
         'A shared store has its own runner; passing both would silently '
         'ignore this one.',
       ),
       // ignore: prefer_initializing_formals
       _pubDevApi = pubDevApi,
       pubDepsStore = pubDepsStore ?? PubDepsStore(runProcess: runProcess);

  /// Injectable so tests can answer with a captured `pub deps --json` instead
  /// of needing a resolved project and an SDK on the machine running them.
  final RunProcess? runProcess;

  /// Injectable for the same reason as [runProcess] — so a test never reaches
  /// the network.
  final PubDevApi? _pubDevApi;
  late final PubDevApi pubDevApi = _pubDevApi ?? PubDevApi();

  /// Where the resolution comes from.
  ///
  /// Handed in by `DependenciesCore` so that every package it declares shares
  /// one: `pub deps` answers about the whole resolution, so a service per
  /// package asking separately is the same subprocess run once per member. A
  /// source built on its own gets its own store, which still earns the disk
  /// half of the cache.
  final PubDepsStore pubDepsStore;

  @override
  Future<String> pubspecText(String packagePath) =>
      File(p.join(packagePath, 'pubspec.yaml')).readAsString();

  @override
  Future<PubDeps> pubDeps({
    required FlutterSdkPath flutterSdk,
    required String packagePath,
  }) => pubDepsStore.load(
    flutterExecutable: flutterSdk.flutter,
    directory: packagePath,
  );

  @override
  Future<PubspecLock?> lock(String packagePath) =>
      PubspecLock.load(packagePath);

  @override
  Future<PackageConfig?> packageConfig(String packagePath) =>
      findPackageConfig(Directory(packagePath));

  /// A dependency whose pubspec will not parse is not worth failing the whole
  /// listing over — everything else about it still reads.
  @override
  Pubspec? dependencyPubspec(String rootPath) {
    try {
      return Pubspec.parse(
        File(p.join(rootPath, 'pubspec.yaml')).readAsStringSync(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PubScores> pubScores() async {
    //TODO(xha): we should download a fresh copy of this file as it can change
    // very frequently.
    var appDirectory = Directory.current;
    var appPackageConfig = await findPackageConfig(appDirectory);
    if (appPackageConfig == null) {
      throw Exception(
        'Cannot resolve [package_config] of ${appDirectory.path}',
      );
    }
    var pubScorePackage = appPackageConfig['pub_scores'];
    if (pubScorePackage == null) {
      throw Exception('Cannot find package [pub_scores]');
    }

    var dataPath = p.join(
      pubScorePackage.root.toFilePath(),
      'lib/data/all_packages.json',
    );

    return Isolate.run(() {
      //TODO(xha): consider a lighter parsing as the file is big
      var content = File(dataPath).readAsStringSync();
      var json = jsonDecode(content) as Map<String, dynamic>;
      return PubScores.fromJson(json);
    });
  }

  @override
  Future<PackageImports> packageImports(String packagePath) {
    var flutterSection = dependencyPubspec(packagePath)?.flutter;
    return Isolate.run(() {
      return PackageImports.gather(
        packagePath,
        // Its own ignore root: a dependency is a self-contained package, and
        // whichever repository it happens to sit under — the pub cache below a
        // home directory kept in git is the ordinary case — has no say in what
        // it contains. Its own `.gitignore` still applies.
        listFilesInDirectory(
          packagePath,
          ignoreRoot: packagePath,
        ).where((f) => f.path.endsWith('.dart')),
        flutterSection: flutterSection,
      );
    });
  }

  @override
  Future<PubDevPackage?> pubDev(String name) => pubDevApi.fetch(name);

  @override
  Future<ClocReport> cloc(String rootPath) =>
      // Its own ignore root — see [packageImports].
      Isolate.run(
        () => countLinesOfCode(
          listFilesInDirectory(rootPath, ignoreRoot: rootPath),
        ),
      );

  @override
  Future<SizeReport> size(String rootPath) => Isolate.run(() {
    var files = listFilesInDirectory(rootPath, ignoreRoot: rootPath);
    var count = 0;
    var size = 0;
    for (var file in files) {
      ++count;
      size += file.lengthSync();
    }
    return SizeReport(fileCount: count, totalBytes: size);
  });

  @override
  Future<({String name, String text})?> document(
    String rootPath,
    List<String> candidates,
  ) async {
    for (var candidate in candidates) {
      var file = File(p.join(rootPath, candidate));
      if (file.existsSync()) {
        return (name: candidate, text: await file.readAsString());
      }
    }
    return null;
  }

  void dispose() {
    if (_pubDevApi == null) pubDevApi.dispose();
  }
}
