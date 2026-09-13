/// The dependencies plugin over a recording: the live core, service and
/// panel, handed a [DependencySource] that answers from what
/// `tool/demo/record.dart` kept rather than from the project, its resolution,
/// the pub cache and pub.dev.
///
/// One file holds every read the service makes — see
/// `recordedDependenciesPath` — and it is fetched once, on the first read,
/// then answered from. The resolution's inputs are kept as the tools wrote
/// them and parsed by the same parsers; the per-package facts the live source
/// computes from the pub cache are kept as the source computed them, under
/// the root each package pretends to be at. Nothing here names a real
/// directory, spawns anything or reaches the network.
library;

import 'dart:convert';

import 'package:package_config/package_config.dart';
import 'package:pub_scores/pub_scores.dart';
import 'package:pubspec_parse/pubspec_parse.dart' show Pubspec;

import '../dependencies/model/package_imports.dart';
import '../dependencies/model/pub_deps.dart';
import '../dependencies/model/pub_dev_api.dart';
import '../dependencies/model/pubspec_lock.dart';
import '../dependencies/model/service.dart' show SizeReport;
import '../dependencies/model/source.dart';
import '../utils/cloc/cloc.dart';
import '../utils/flutter_sdk.dart';
import 'recording.dart';

/// Where the dependencies plugin reads from when the project is a recording —
/// `DependenciesCore(source: …)`.
class RecordedDependencySource extends DependencySource {
  RecordedDependencySource(this.recording);

  final Recording recording;

  Future<Map<String, Object?>>? _loading;

  /// The one file, read once. Every read below awaits it; the synchronous one,
  /// [dependencyPubspec], is only ever asked after [packageConfig] was.
  Future<Map<String, Object?>> _load() => _loading ??= () async {
    // Through `Future.value`, for the reason `recordedIconScanner` gives: a
    // synchronous end must still resume this function on a microtask.
    var text = await Future.value(
      recording.readString(recordedDependenciesPath('.')),
    );
    if (text == null) {
      throw StateError(
        'This recording has no dependencies '
        '(looked for ${recordedDependenciesPath('.')}).',
      );
    }
    var json = jsonDecode(text) as Map<String, Object?>;
    _packages = (json['packages'] as Map? ?? const {}).cast<String, Object?>();
    return json;
  }();

  /// Per-package facts, by the root each package pretends to be at.
  Map<String, Object?> _packages = const {};

  Map<String, Object?>? _packageAt(String rootPath) =>
      (_packages[_normalise(rootPath)] as Map?)?.cast<String, Object?>();

  /// The package config spells a root with a trailing slash and Windows with
  /// backslashes; the recording files each package under its plain path.
  static String _normalise(String rootPath) {
    var path = rootPath.replaceAll(r'\', '/');
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  @override
  Future<String> pubspecText(String packagePath) async =>
      (await _load())['pubspec']! as String;

  @override
  Future<PubDeps> pubDeps({
    required FlutterSdkPath flutterSdk,
    required String packagePath,
  }) async => PubDeps.parse((await _load())['pubDeps']! as String);

  @override
  Future<PubspecLock?> lock(String packagePath) async =>
      switch ((await _load())['lock']) {
        String text => PubspecLock.parse(text),
        _ => null,
      };

  @override
  Future<PackageConfig?> packageConfig(String packagePath) async =>
      PackageConfig.parseJson(
        (await _load())['packageConfig'],
        Uri.parse('file://$recordedProjectRoot/.dart_tool/'),
      );

  @override
  Pubspec? dependencyPubspec(String rootPath) {
    var text = _packageAt(rootPath)?['pubspec'];
    if (text is! String) return null;
    try {
      return Pubspec.parse(text);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PubScores> pubScores() async => PubScores.fromJson(
    ((await _load())['pubScores']! as Map).cast<String, dynamic>(),
  );

  @override
  Future<PackageImports> packageImports(String packagePath) async =>
      PackageImports.fromJson(
        ((await _load())['imports'] as Map? ?? const {})
            .cast<String, Object?>(),
      );

  @override
  Future<PubDevPackage?> pubDev(String name) async {
    await _load();
    for (var package in _packages.values) {
      var entry = (package! as Map).cast<String, Object?>();
      if (entry['name'] != name) continue;
      return switch (entry['pubDev']) {
        Map json => PubDevPackage.fromJson(json.cast<String, Object?>()),
        _ => null,
      };
    }
    return null;
  }

  @override
  Future<ClocReport> cloc(String rootPath) async {
    await _load();
    return switch (_packageAt(rootPath)?['cloc']) {
      Map json => ClocReport.fromJson(json.cast<String, Object?>()),
      _ => ClocReport(ClocResult.zero, const {}),
    };
  }

  @override
  Future<SizeReport> size(String rootPath) async {
    await _load();
    return switch (_packageAt(rootPath)?['size']) {
      Map json => SizeReport.fromJson(json.cast<String, Object?>()),
      _ => SizeReport(fileCount: 0, totalBytes: 0),
    };
  }

  @override
  Future<({String name, String text})?> document(
    String rootPath,
    List<String> candidates,
  ) async {
    await _load();
    var documents = (_packageAt(rootPath)?['documents'] as Map? ?? const {})
        .cast<String, Object?>();
    for (var candidate in candidates) {
      if (documents[candidate] case String text) {
        return (name: candidate, text: text);
      }
    }
    return null;
  }
}
