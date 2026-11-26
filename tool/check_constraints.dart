/// Fails when a pubspec that is resolved outside this repository stops short
/// of a dependency's latest release, or no longer resolves on the oldest
/// Flutter a project on flutterware builds with.
///
/// ```
/// fvm dart tool/check_constraints.dart
/// ```
///
/// On every pubspec in [resolvedElsewhere]:
///
/// - Each hosted dependency admits its latest release, unless [heldBack] says
///   why not. A project resolves these constraints with its own, so one that
///   stops short of a release holds every project on flutterware below it
///   too, along with whatever that release pins.
/// - Each `environment:` floor admits [oldestFlutter] and the Dart it ships.
///   `.fvmrc` moves to every new beta; the floors stay where the projects
///   are.
/// - Each hosted dependency admits a release that resolves on [oldestFlutter].
///   A constraint widened under a newer beta can start at a release that
///   needs that beta, which raises the floor as surely as editing it would.
///
/// It needs the network: pub.dev and the Flutter release index answer the
/// lookups. When either cannot be reached it says so and passes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// The oldest Flutter a project on flutterware builds with.
///
/// Raise it when no project builds with it any more, never because `.fvmrc`
/// moved: the pin is what CI runs, this is what the projects run.
const oldestFlutter = '3.50.0-0.4.pre';

/// The pubspecs resolved by everyone who uses flutterware, with their SDK.
///
/// The root and `render/` are dependencies of their projects. `app/` is the
/// studio: a hosted install resolves it on the user's machine as one
/// workspace with the root and `render/`, dev dependencies included.
/// `examples/brewline` is the demo a stranger clones.
const resolvedElsewhere = [
  'pubspec.yaml',
  'app/pubspec.yaml',
  'render/pubspec.yaml',
  'examples/brewline/pubspec.yaml',
];

/// Dependencies allowed to exclude their latest release, each with the
/// reason. `tool/upgrade.dart` leaves their constraints alone.
const heldBack = <String, String>{};

/// Dependencies pinned to the version a pubspec inside the Flutter SDK pins,
/// each with that pubspec's path under the SDK. `tool/upgrade.dart` copies
/// the SDK's pin, and a test holds them equal, so they are never behind.
const pinnedBySdk = <String, String>{
  // A build hook and its runner negotiate a protocol version, so the studio
  // runs the one the SDK's own tools run (app/test/assets/build_hooks_test.dart).
  'hooks_runner': 'packages/flutter_tools/pubspec.yaml',
};

Future<void> main() async {
  Directory.current = repoRoot();
  var members = workspacePackages();

  var dependencies = <({String pubspec, String name, VersionConstraint at})>[];
  var floors = <({String pubspec, String sdk, VersionConstraint at})>[];
  for (var pubspec in resolvedElsewhere) {
    var yaml = loadYaml(File(pubspec).readAsStringSync()) as YamlMap;
    var environment = yaml['environment'] as YamlMap? ?? YamlMap();
    for (var sdk in ['sdk', 'flutter']) {
      if (environment[sdk] case String text) {
        floors.add((
          pubspec: pubspec,
          sdk: sdk,
          at: VersionConstraint.parse(text),
        ));
      }
    }
    for (var MapEntry(:key, :value) in hostedDependencies(yaml).entries) {
      if (members.contains(key)) continue;
      dependencies.add((
        pubspec: pubspec,
        name: key,
        at: VersionConstraint.parse(value ?? 'any'),
      ));
    }
  }

  var names = {for (var d in dependencies) d.name}.toList()..sort();
  var client = http.Client();
  Version oldestDart;
  Map<String, _Package> packages;
  try {
    oldestDart = await dartOf(client, oldestFlutter);
    packages = Map.fromIterables(
      names,
      await Future.wait([for (var name in names) _package(client, name)]),
    );
  } on _Unreachable catch (e) {
    print('${e.host} cannot be reached, so nothing was checked: ${e.cause}');
    return;
  } finally {
    client.close();
  }
  var oldest = (dart: oldestDart, flutter: Version.parse(oldestFlutter));

  var raised = <String>[];
  for (var floor in floors) {
    var (version, label) = floor.sdk == 'sdk'
        ? (oldest.dart, 'Dart ${oldest.dart}')
        : (oldest.flutter, 'Flutter $oldestFlutter');
    if (!floor.at.allows(version)) {
      raised.add('${floor.pubspec}: ${floor.sdk}: ${floor.at} excludes $label');
    }
  }

  var behind = <String>[];
  var stranded = <String>[];
  for (var dependency in dependencies) {
    var package = packages[dependency.name]!;
    if (!dependency.at.allows(package.latest) &&
        !heldBack.containsKey(dependency.name) &&
        !pinnedBySdk.containsKey(dependency.name)) {
      behind.add(
        '${dependency.pubspec}: ${dependency.name} ${dependency.at} '
        'excludes ${package.latest}',
      );
    }
    if (!package.releases.any(
      (r) => dependency.at.allows(r.version) && r.resolvesOn(oldest),
    )) {
      stranded.add(
        '${dependency.pubspec}: ${dependency.name} ${dependency.at} admits '
        'no release that resolves on Flutter $oldestFlutter',
      );
    }
  }

  var stale = [
    for (var name in heldBack.keys)
      if (dependencies.where((d) => d.name == name).toList() case var held)
        if (held.isEmpty)
          '$name: not a dependency'
        else if (held.every((d) => d.at.allows(packages[name]!.latest)))
          '$name: ${held.first.at} now admits ${packages[name]!.latest}',
  ];

  void report(String heading, List<String> lines) {
    if (lines.isEmpty) return;
    print('$heading\n  ${lines.join('\n  ')}');
  }

  report(
    'These floors exclude the oldest Flutter a project builds with. Lower '
    'them, or raise oldestFlutter once no project builds with it:',
    raised,
  );
  report(
    'Widen these to the latest release, or add them to heldBack with the '
    'reason:',
    behind,
  );
  report(
    'Lower these so they admit a release that resolves on Flutter '
    '$oldestFlutter (Dart ${oldest.dart}):',
    stranded,
  );
  report('Remove these from heldBack:', stale);
  if ([raised, behind, stranded, stale].any((l) => l.isNotEmpty)) {
    exitCode = 1;
  } else {
    print(
      'Every constraint admits its latest release, and everything resolves '
      'on Flutter $oldestFlutter (Dart ${oldest.dart}).',
    );
  }
}

/// Every hosted dependency of [pubspec], with its constraint; null is none.
/// An SDK, path or git dependency has no release to fall behind.
Map<String, String?> hostedDependencies(YamlMap pubspec) => {
  for (var section in ['dependencies', 'dev_dependencies'])
    for (var MapEntry(:key, :value)
        in (pubspec[section] as YamlMap? ?? YamlMap()).entries)
      if (value is String?) key as String: value,
};

/// The names of the root package and of every workspace member. Their hosted
/// constraints on each other resolve inside the workspace, never on pub.dev.
Set<String> workspacePackages() {
  var root = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  return {
    root['name'] as String,
    for (var member in root['workspace'] as YamlList? ?? YamlList())
      (loadYaml(File('$member/pubspec.yaml').readAsStringSync())
              as YamlMap)['name']
          as String,
  };
}

/// The Dart that [flutter] ships, from the index fvm installs from.
Future<Version> dartOf(http.Client client, String flutter) async {
  var index = await _getJson(
    client,
    Uri.https(
      'storage.googleapis.com',
      '/flutter_infra_release/releases/releases_macos.json',
    ),
  );
  for (var release in (index['releases']! as List).cast<Map>()) {
    if (release['version'] == flutter) {
      // "3.14.0 (build 3.14.0-315.3.beta)": the build is the one a floor
      // compares against.
      var raw = release['dart_sdk_version'] as String;
      var build = RegExp(r'\(build ([^)]+)\)').firstMatch(raw)?.group(1);
      return Version.parse(build ?? raw.split(' ').first);
    }
  }
  throw StateError('Flutter $flutter is not in the release index.');
}

/// The repository root, found from this script rather than from the
/// directory it was started in.
Directory repoRoot() {
  var dir = File.fromUri(Platform.script).parent;
  while (!File('${dir.path}/.fvmrc').existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('No .fvmrc above ${Platform.script}.');
    }
    dir = dir.parent;
  }
  return dir;
}

final class _Package {
  _Package(this.latest, this.releases);

  /// What pub.dev calls the latest: the newest stable release, or the newest
  /// prerelease of a package that has no stable one.
  final Version latest;
  final List<_Release> releases;
}

final class _Release {
  _Release(this.version, {required this.dart, required this.flutter});

  factory _Release.of(Map<String, Object?> json) {
    var pubspec = json['pubspec'] as Map<String, Object?>? ?? const {};
    var environment = pubspec['environment'] as Map? ?? const {};
    return _Release(
      Version.parse(json['version']! as String),
      dart: switch (environment['sdk']) {
        String text => _dartConstraint(text),
        // pub reads no SDK constraint as one below Dart 2.
        _ => VersionConstraint.empty,
      },
      flutter: switch (environment['flutter']) {
        String text => VersionConstraint.parse(text),
        _ => VersionConstraint.any,
      },
    );
  }

  final Version version;
  final VersionConstraint dart;
  final VersionConstraint flutter;

  bool resolvesOn(({Version dart, Version flutter}) sdk) =>
      dart.allows(sdk.dart) && flutter.allows(sdk.flutter);
}

/// An SDK constraint as pub reads it: Dart 3 resolves a package whose
/// language is 2.12 or later even though it says `<3.0.0`.
VersionConstraint _dartConstraint(String text) {
  var constraint = VersionConstraint.parse(text);
  // pub_semver reads `<3.0.0` as `<3.0.0-0`, and the language of
  // `>=2.12.0-0` is 2.12.
  if (constraint
      case VersionRange(
        :var min?,
        :var max?,
        :var includeMin,
        includeMax: false,
      )
      when max.major == 3 &&
          max.minor == 0 &&
          max.patch == 0 &&
          Version(min.major, min.minor, 0) >= Version(2, 12, 0)) {
    return VersionRange(
      min: min,
      includeMin: includeMin,
      max: Version(4, 0, 0),
    );
  }
  return constraint;
}

/// [package]'s releases on pub.dev, retracted ones left out.
Future<_Package> _package(http.Client client, String package) async {
  var json = await _getJson(
    client,
    Uri.https('pub.dev', '/api/packages/$package'),
    accept: 'application/vnd.pub.v2+json',
  );
  var latest = json['latest']! as Map<String, Object?>;
  return _Package(Version.parse(latest['version']! as String), [
    for (var release
        in (json['versions']! as List).cast<Map<String, Object?>>())
      if (release['retracted'] != true) _Release.of(release),
  ]);
}

Future<Map<String, Object?>> _getJson(
  http.Client client,
  Uri uri, {
  String accept = 'application/json',
}) async {
  http.Response response;
  try {
    response = await client
        .get(uri, headers: {'accept': accept})
        .timeout(const Duration(seconds: 30));
  } on SocketException catch (e) {
    throw _Unreachable(uri.host, e);
  } on http.ClientException catch (e) {
    throw _Unreachable(uri.host, e);
  } on TimeoutException catch (e) {
    throw _Unreachable(uri.host, e);
  }
  if (response.statusCode >= 500) {
    throw _Unreachable(uri.host, 'HTTP ${response.statusCode} for $uri');
  }
  if (response.statusCode != 200) {
    throw StateError('$uri answered ${response.statusCode}.');
  }
  return jsonDecode(response.body) as Map<String, Object?>;
}

final class _Unreachable implements Exception {
  _Unreachable(this.host, this.cause);

  final String host;
  final Object cause;
}
