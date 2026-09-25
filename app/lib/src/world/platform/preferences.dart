import 'dart:convert';
import 'dart:io';

import '../guest_platform.dart';

/// `shared_preferences` on macOS — `UserDefaults` behind two Pigeon APIs, the
/// legacy one `SharedPreferences` uses and the one `SharedPreferencesAsync`
/// does — answered from a JSON file in the person's home.
void answerPreferences(GuestPlatform platform) {
  var file = File('${platform.home.path}/preferences.json');
  Map<String, Object?> read() => file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as Map).cast()
      : {};
  void write(Map<String, Object?> values) =>
      file.writeAsStringSync(jsonEncode(values));
  bool keeps(String key, String prefix, Object? allow) =>
      key.startsWith(prefix) &&
      (allow == null || (allow as List).contains(key));
  Map<String, Object?> matching(String prefix, Object? allow) => {
    for (var MapEntry(:key, :value) in read().entries)
      if (keeps(key, prefix, allow)) key: value,
  };
  Object? set(String key, Object? value) {
    write(read()..[key] = value);
    return null;
  }

  bool clear(String prefix, Object? allow) {
    write(read()..removeWhere((key, _) => keeps(key, prefix, allow)));
    return true;
  }

  const prefix = 'dev.flutter.pigeon.shared_preferences_foundation';
  platform.pigeon('$prefix.LegacyUserDefaultsApi', {
    'remove': (a) {
      write(read()..remove(a[0]));
      return null;
    },
    'setBool': (a) => set(a[0]! as String, a[1]),
    'setDouble': (a) => set(a[0]! as String, a[1]),
    'setValue': (a) => set(a[0]! as String, a[1]),
    'getAll': (a) => matching(a[0]! as String, a[1]),
    'clear': (a) => clear(a[0]! as String, a[1]),
  });
  platform.pigeon('$prefix.UserDefaultsApi', {
    'set': (a) => set(a[0]! as String, a[1]),
    'getValue': (a) => read()[a[0]],
    'getAll': (a) => matching('', a[0]),
    'getKeys': (a) => matching('', a[0]).keys.toList(),
    'clear': (a) {
      clear('', a[0]);
      return null;
    },
  });
}
