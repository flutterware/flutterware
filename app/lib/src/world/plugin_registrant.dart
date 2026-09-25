import 'dart:convert';
import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One plugin's Dart half, as `flutter run` registers it.
typedef PluginRegistration = ({String package, String file, String type});

/// The Dart halves of [package]'s plugins on [platform]: every package it
/// depends on — transitively, dev dependencies aside — whose pubspec names a
/// `dartPluginClass` for the platform.
///
/// `flutter run` writes these into a generated registrant and calls each
/// `registerWith()` before `main`, which is what points a plugin's platform
/// interface at its macOS implementation rather than at the method-channel
/// default. A guest never runs `flutter run`, so it builds the same list
/// itself — from the package graph `pub get` leaves beside the package
/// config, which is what makes it work in a worktree that has never been
/// built.
Future<List<PluginRegistration>> dartPluginRegistrations({
  required String packageConfig,
  required String package,
  String platform = 'macos',
}) async {
  var config = await loadPackageConfigUri(Uri.file(packageConfig));
  var graph = jsonDecode(
    File(p.join(p.dirname(packageConfig), 'package_graph.json'))
        .readAsStringSync(),
  ) as Map;
  var dependencies = {
    for (var node in (graph['packages']! as List).cast<Map>())
      node['name']! as String: (node['dependencies'] as List? ?? [])
          .cast<String>(),
  };
  var root =
      _at(loadYaml(File(p.join(package, 'pubspec.yaml')).readAsStringSync()), [
            'name',
          ])!
          as String;
  var reached = <String>{};
  void visit(String name) {
    if (!reached.add(name)) return;
    dependencies[name]?.forEach(visit);
  }

  visit(root);

  var registrations = <PluginRegistration>[];
  for (var name in reached) {
    var dir = config[name]?.root;
    if (dir == null) continue;
    var pubspec = File.fromUri(dir.resolve('pubspec.yaml'));
    if (!pubspec.existsSync()) continue;
    var declared = _at(loadYaml(pubspec.readAsStringSync()), [
      'flutter',
      'plugin',
      'platforms',
      platform,
    ]);
    if (declared is! YamlMap) continue;
    var type = declared['dartPluginClass'];
    if (type is! String || type == 'none') continue;
    registrations.add((
      package: name,
      file:
          declared['dartPluginFile'] as String? ??
          declared['fileName'] as String? ??
          '$name.dart',
      type: type,
    ));
  }
  registrations.sort((a, b) => a.package.compareTo(b.package));
  return registrations;
}

/// The value at [path] in a YAML document, or null where any step is missing.
Object? _at(Object? node, List<String> path) {
  for (var key in path) {
    if (node is! YamlMap) return null;
    node = node[key];
  }
  return node;
}
