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
  /// is [generated].
  Future<List<PluginRegistration>> appWith(String generated) {
    write('app/pubspec.yaml', 'name: app\n');
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
    var plugin = (await appWith('''
class LegacyUserDefaultsApi {
  factory LegacyUserDefaultsApi.createWithNativeInteropApi() => throw 0;
}
''')).single;
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
}
