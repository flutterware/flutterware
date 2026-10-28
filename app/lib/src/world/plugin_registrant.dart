import 'dart:convert';
import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One plugin's Dart half, as `flutter run` registers it — or, when
/// [overChannels], as a guest has to (see [registrationSource]).
typedef PluginRegistration = ({
  String package,
  String file,
  String type,
  bool overChannels,
});

/// What registers [plugin], imported as [alias]: the imports, and the
/// statements the guest's `main` runs before the app's own.
({List<String> imports, List<String> statements}) registrationSource(
  PluginRegistration plugin,
  String alias,
) {
  var own = "import 'package:${plugin.package}/${plugin.file}' as $alias;";
  if (!plugin.overChannels) {
    return (
      imports: [own],
      statements: ['$alias.${plugin.type}.registerWith();'],
    );
  }
  var channels = _overChannels[plugin.package]!;
  return (
    imports: [
      own,
      for (var (i, library) in channels.imports.indexed)
        "import 'package:$library' as ${alias}_$i;",
    ],
    statements: channels.statements(alias),
  );
}

/// Plugins whose Dart half calls its Swift half through FFI, from a version
/// on. A guest builds nothing native, so that version fails as it starts, with
/// `FailedToLoadClassException`. Each still carries the Pigeon channels its
/// earlier versions used, which the studio answers, so a guest registers it
/// over them.
///
/// The FFI versions are told apart by the factory they added to the generated
/// API, in [_OverChannels.generated]. A version that no longer has what the
/// registration uses, in [_OverChannels.uses], is registered as `flutter run`
/// registers it, and fails as any plugin that calls its native code does.
final _overChannels = {
  // `alias_0` is the generated API, `alias_1` and `alias_2` the platform
  // interfaces it registers with.
  'shared_preferences_foundation': _OverChannels(
    generated: 'lib/src/messages.g.dart',
    uses: {
      // The channels the studio answers, and the constructors that reach them.
      'lib/src/messages.g.dart': [
        'pigeon.shared_preferences_foundation.LegacyUserDefaultsApi.',
        'pigeon.shared_preferences_foundation.UserDefaultsApi.',
        RegExp(r'\bLegacyUserDefaultsApi\(\{'),
        RegExp(r'\bUserDefaultsApi\(\{'),
      ],
      'lib/src/shared_preferences_foundation.dart': [
        RegExp(r'\bLegacyUserDefaultsApi\? api\b'),
      ],
      'lib/src/shared_preferences_async_foundation.dart': [
        RegExp(r'\bUserDefaultsApi\? api\b'),
      ],
    },
    imports: [
      'shared_preferences_foundation/src/messages.g.dart',
      'shared_preferences_platform_interface/shared_preferences_platform_interface.dart',
      'shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart',
    ],
    statements: (alias) => [
      '${alias}_1.SharedPreferencesStorePlatform.instance = $alias.SharedPreferencesFoundation(api: ${alias}_0.LegacyUserDefaultsApi());',
      '${alias}_2.SharedPreferencesAsyncPlatform.instance = $alias.SharedPreferencesAsyncFoundation(api: ${alias}_0.UserDefaultsApi());',
    ],
  ),
};

class _OverChannels {
  const _OverChannels({
    required this.generated,
    required this.uses,
    required this.imports,
    required this.statements,
  });

  /// The package's generated Pigeon API, relative to its root.
  final String generated;

  /// What each of the package's files, relative to its root, has to contain
  /// for [statements] to compile and reach the studio.
  final Map<String, List<Pattern>> uses;
  final List<String> imports;
  final List<String> Function(String alias) statements;

  /// Whether the version at [root] reaches its native half through FFI and
  /// can still be registered over its channels.
  bool fits(Uri root) {
    String read(String file) {
      var source = File.fromUri(root.resolve(file));
      return source.existsSync() ? source.readAsStringSync() : '';
    }

    if (!read(generated).contains('createWithNativeInteropApi')) return false;
    return uses.entries.every(
      (entry) => entry.value.every(read(entry.key).contains),
    );
  }
}

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
      overChannels: _overChannels[name]?.fits(dir) ?? false,
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
