import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/world/plugin_registrant.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('registrant_'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// An app depending on `shared_preferences_foundation`, whose generated API
  /// is [generated] and whose other sources are [sources].
  Future<List<PluginRegistration>> appWith(
    String generated, {
    Map<String, String> sources = const {},
  }) {
    write('app/pubspec.yaml', 'name: app\n');
    for (var MapEntry(key: file, value: source) in sources.entries) {
      write('prefs/$file', source);
    }
    write('prefs/pubspec.yaml', '''
name: shared_preferences_foundation
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: SharedPreferencesPlugin
        dartPluginClass: SharedPreferencesFoundation
''');
    write('prefs/lib/src/messages.g.dart', generated);
    write(
      'app/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
          {
            'name': 'shared_preferences_foundation',
            'rootUri': '../../prefs/',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    write(
      'app/.dart_tool/package_graph.json',
      jsonEncode({
        'packages': [
          {
            'name': 'app',
            'dependencies': ['shared_preferences_foundation'],
          },
          {'name': 'shared_preferences_foundation', 'dependencies': []},
        ],
      }),
    );
    return dartPluginRegistrations(
      packageConfig: p.join(root.path, 'app/.dart_tool/package_config.json'),
      package: p.join(root.path, 'app'),
      platform: 'ios',
    );
  }

  test('registers a plugin as flutter run does', () async {
    var plugin = (await appWith('class LegacyUserDefaultsApi {}')).single;
    expect(plugin.overChannels, isFalse);
    var source = registrationSource(plugin, 'plugin0');
    expect(
      source.imports.single,
      "import 'package:shared_preferences_foundation/"
      "shared_preferences_foundation.dart' as plugin0;",
    );
    expect(source.statements, [
      'plugin0.SharedPreferencesFoundation.registerWith();',
    ]);
  });

  test('registers shared_preferences over its channels once it calls its '
      'native half through FFI', () async {
    var plugin = (await appWith(
      _ffiWithChannels,
      sources: _foundations,
    )).single;
    expect(plugin.overChannels, isTrue);
    var source = registrationSource(plugin, 'plugin0');
    expect(
      source.imports,
      contains(
        "import 'package:shared_preferences_foundation/src/messages.g.dart' "
        'as plugin0_0;',
      ),
    );
    var (store, async) = (source.statements[0], source.statements[1]);
    expect(source.statements, hasLength(2));
    expect(
      store,
      'plugin0_1.SharedPreferencesStorePlatform.instance = '
      'plugin0.SharedPreferencesFoundation(api: '
      'plugin0_0.LegacyUserDefaultsApi());',
    );
    expect(
      async,
      'plugin0_2.SharedPreferencesAsyncPlatform.instance = '
      'plugin0.SharedPreferencesAsyncFoundation(api: '
      'plugin0_0.UserDefaultsApi());',
    );
  });

  test('registers shared_preferences as flutter run does once its channels '
      'are gone', () async {
    // Registered over channels, it would not compile; this way the app fails
    // as it starts and the world says to fake the plugin.
    var withoutChannels = _ffiWithChannels.replaceAll(
      'dev.flutter.pigeon.',
      'unused.',
    );
    var plugin = (await appWith(withoutChannels, sources: _foundations)).single;
    expect(plugin.overChannels, isFalse);
    expect(registrationSource(plugin, 'plugin0').statements, [
      'plugin0.SharedPreferencesFoundation.registerWith();',
    ]);
  });

  test('registers shared_preferences as flutter run does once it no longer '
      'takes an API to talk through', () async {
    var plugin = (await appWith(
      _ffiWithChannels,
      sources: {
        ..._foundations,
        'lib/src/shared_preferences_foundation.dart': '',
      },
    )).single;
    expect(plugin.overChannels, isFalse);
  });
}

/// The generated API of a version that calls its native half through FFI and
/// still has the channels, as 2.6 does.
const _ffiWithChannels = '''
class LegacyUserDefaultsApi {
  LegacyUserDefaultsApi({BinaryMessenger? binaryMessenger});
  factory LegacyUserDefaultsApi.createWithNativeInteropApi() => throw 0;
  final remove = 'dev.flutter.pigeon.shared_preferences_foundation.LegacyUserDefaultsApi.remove';
}
class UserDefaultsApi {
  UserDefaultsApi({BinaryMessenger? binaryMessenger});
  factory UserDefaultsApi.createWithNativeInteropApi() => throw 0;
  final getValue = 'dev.flutter.pigeon.shared_preferences_foundation.UserDefaultsApi.getValue';
}
''';

/// The two classes the registration constructs, each taking the API to talk
/// through.
const _foundations = {
  'lib/src/shared_preferences_foundation.dart': 'SharedPreferencesFoundation({@visibleForTesting LegacyUserDefaultsApi? api});',
  'lib/src/shared_preferences_async_foundation.dart': 'SharedPreferencesAsyncFoundation({@visibleForTesting UserDefaultsApi? api});',
};
