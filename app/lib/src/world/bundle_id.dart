import 'dart:io';

import 'package:path/path.dart' as p;

/// The bundle identifier the iOS app in [packageRoot] is built with under
/// [flavor] — the Runner target's `Debug-<flavor>` configuration, or `Debug`
/// without one — or null when the project does not say it in a way that can
/// be read without Xcode.
///
/// What a guest reports as its package name: an app that picks its options by
/// bundle id, a push service's or a sign-in provider's, finds the same ones it
/// would on a simulator. Read from `project.pbxproj`, and from the
/// configuration's base `.xcconfig` for what the target leaves out. A value
/// that names a setting neither defines — one an Xcode scheme or the build
/// passes in — is not guessed at.
String? iosBundleId(String packageRoot, {String? flavor}) {
  var ios = p.join(packageRoot, 'ios');
  var project = File(p.join(ios, 'Runner.xcodeproj', 'project.pbxproj'));
  if (!project.existsSync()) return null;
  try {
    var root = parseOpenStepPlist(project.readAsStringSync());
    if (root is! Map) return null;
    var objects = root['objects'];
    if (objects is! Map) return null;
    Map? object(Object? id) => switch (objects[id]) {
      Map found => found,
      _ => null,
    };
    var targets = [
      for (var value in objects.values)
        if (value is Map &&
            value['isa'] == 'PBXNativeTarget' &&
            value['productType'] == 'com.apple.product-type.application')
          value,
    ];
    var target =
        targets.where((t) => t['name'] == 'Runner').firstOrNull ??
        targets.firstOrNull;
    var ids = object(target?['buildConfigurationList'])?['buildConfigurations'];
    if (ids is! List) return null;
    var wanted = flavor == null ? 'debug' : 'debug-${flavor.toLowerCase()}';
    var config = ids
        .map(object)
        .where((c) => '${c?['name']}'.toLowerCase() == wanted)
        .firstOrNull;
    if (config == null) return null;
    var settings = <String, String>{};
    var base = object(config['baseConfigurationReference']);
    if (base?['path'] case String path) {
      _readXcconfig(_find(ios, path), settings, depth: 0);
    }
    if (config['buildSettings'] case Map own) {
      for (var MapEntry(:key, :value) in own.entries) {
        if (value is String) settings['$key'] = value;
      }
    }
    return _resolve(settings['PRODUCT_BUNDLE_IDENTIFIER'], settings);
  } on FormatException {
    return null;
  }
}

/// [value] with every `$(NAME)` and `${NAME}` in it replaced from
/// [settings], or null when one is not there.
String? _resolve(String? value, Map<String, String> settings, [int depth = 0]) {
  if (value == null || value.isEmpty || depth > 8) return null;
  var unresolved = false;
  var resolved = value.replaceAllMapped(
    RegExp(r'\$[({]([A-Za-z_][A-Za-z0-9_]*)(?::[^)}]*)?[)}]'),
    (match) {
      var named = _resolve(settings[match[1]], settings, depth + 1);
      if (named == null) unresolved = true;
      return named ?? '';
    },
  );
  return unresolved || resolved.isEmpty ? null : resolved;
}

/// [path] as a file reference names it: relative to its group, which is
/// almost always a folder under `ios/` of the same name.
File? _find(String ios, String path) {
  var direct = File(p.join(ios, path));
  if (direct.existsSync()) return direct;
  for (var dir in ['Flutter', 'Runner', 'Configs', 'Config']) {
    var candidate = File(p.join(ios, dir, p.basename(path)));
    if (candidate.existsSync()) return candidate;
  }
  return null;
}

/// The plain `NAME = value` lines of an `.xcconfig` and what it includes,
/// later lines winning. A setting conditioned on an SDK or an architecture is
/// left out.
void _readXcconfig(File? file, Map<String, String> into, {required int depth}) {
  if (file == null || !file.existsSync() || depth > 4) return;
  for (var line in file.readAsLinesSync()) {
    var text = line.replaceFirst(RegExp(r'//.*$'), '').trim();
    var include = RegExp(r'^#include\??\s+"([^"]+)"').firstMatch(text);
    if (include != null) {
      var included = File(p.join(file.parent.path, include[1]!));
      _readXcconfig(included, into, depth: depth + 1);
      continue;
    }
    var setting = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?);?$')
        .firstMatch(text);
    if (setting != null) into[setting[1]!] = setting[2]!.trim();
  }
}

/// An old-style property list — what `project.pbxproj` is written in: `{ key
/// = value; }`, `( value, )`, strings quoted or bare, and C comments.
Object? parseOpenStepPlist(String text) => _OpenStep(text).parse();

class _OpenStep {
  _OpenStep(this.text);

  final String text;
  var _at = 0;

  Object? parse() {
    var value = _value();
    _skip();
    return value;
  }

  Object? _value() {
    _skip();
    if (_at >= text.length) throw const FormatException('Unexpected end');
    switch (text[_at]) {
      case '{':
        _at++;
        var map = <String, Object?>{};
        while (true) {
          _skip();
          if (_peek('}')) {
            _at++;
            return map;
          }
          var key = '${_value()}';
          _expect('=');
          map[key] = _value();
          _expect(';');
        }
      case '(':
        _at++;
        var list = <Object?>[];
        while (true) {
          _skip();
          if (_peek(')')) {
            _at++;
            return list;
          }
          list.add(_value());
          _skip();
          if (_peek(',')) _at++;
        }
      case '"':
        return _quoted();
      default:
        var start = _at;
        while (_at < text.length && !_ends.hasMatch(text[_at])) {
          _at++;
        }
        if (_at == start) {
          throw FormatException('Unexpected ${text[_at]}', text, _at);
        }
        return text.substring(start, _at);
    }
  }

  static final _ends = RegExp(r'[\s;,=(){}"]');

  String _quoted() {
    _at++;
    var out = StringBuffer();
    while (_at < text.length && text[_at] != '"') {
      if (text[_at] == r'\' && _at + 1 < text.length) {
        _at++;
        out.write(switch (text[_at]) {
          'n' => '\n',
          't' => '\t',
          var other => other,
        });
      } else {
        out.write(text[_at]);
      }
      _at++;
    }
    _at++;
    return out.toString();
  }

  bool _peek(String char) => _at < text.length && text[_at] == char;

  void _expect(String char) {
    _skip();
    if (!_peek(char)) throw FormatException('Expected $char', text, _at);
    _at++;
  }

  void _skip() {
    while (_at < text.length) {
      if (text.startsWith('/*', _at)) {
        var end = text.indexOf('*/', _at + 2);
        _at = end < 0 ? text.length : end + 2;
      } else if (text.startsWith('//', _at)) {
        var end = text.indexOf('\n', _at);
        _at = end < 0 ? text.length : end + 1;
      } else if (text[_at].trim().isEmpty) {
        _at++;
      } else {
        return;
      }
    }
  }
}
