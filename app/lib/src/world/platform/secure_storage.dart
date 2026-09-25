import 'dart:convert';
import 'dart:io';

import '../guest_platform.dart';

/// `flutter_secure_storage` — the keychain, behind a method channel —
/// answered from a JSON file in the person's home. A person's keychain is
/// theirs alone, which is the point: the real one is shared by every copy of
/// the app on the machine, and needs a signing team besides.
void answerSecureStorage(GuestPlatform platform) {
  var file = File('${platform.home.path}/keychain.json');
  Map<String, String> read() => file.existsSync()
      ? (jsonDecode(file.readAsStringSync()) as Map).cast()
      : {};
  void write(Map<String, String> values) =>
      file.writeAsStringSync(jsonEncode(values));
  String key(Object? arguments) => (arguments! as Map)['key']! as String;

  platform.methods('plugins.it_nomads.com/flutter_secure_storage', {
    'isProtectedDataAvailable': (_) => true,
    'read': (a) => read()[key(a)],
    'readAll': (_) => read(),
    'containsKey': (a) => read().containsKey(key(a)),
    'write': (a) {
      write(read()..[key(a)] = (a! as Map)['value']! as String);
      return null;
    },
    'delete': (a) {
      write(read()..remove(key(a)));
      return null;
    },
    'deleteAll': (_) {
      write({});
      return null;
    },
  });
}
