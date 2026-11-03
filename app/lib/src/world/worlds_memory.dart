import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/run_dir.dart';

/// How the studio last left its worlds on this machine, whichever world and
/// checkout: kept in `~/.flutterware/worlds.json`, so the next world opens
/// the same way.
class WorldsMemory {
  WorldsMemory({String? directory})
    : _path = p.join(directory ?? flutterwareDir(), 'worlds.json');

  final String _path;

  /// Whether the person in focus has their panel beside them. Shown until
  /// someone hides it.
  bool get panel => _read()['panel'] != false;

  set panel(bool shown) => _write({..._read(), 'panel': shown});

  Map<String, Object?> _read() {
    try {
      var decoded = jsonDecode(File(_path).readAsStringSync());
      return decoded is Map ? decoded.cast<String, Object?>() : {};
    } on Object {
      // Absent or torn: the studio as it starts.
      return {};
    }
  }

  void _write(Map<String, Object?> all) {
    try {
      File(_path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(all));
    } on FileSystemException {
      // The view still changes; the next studio starts as this one did.
    }
  }
}
