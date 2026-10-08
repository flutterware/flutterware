// What a scene's shader inspector draws a control from: the package's
// declared shaders, and each one's uniforms as `impellerc`'s reflection JSON
// and the shader's own `// @range`/`// @color`/`// @default` comments
// describe them. Pure parsers first — reflection JSON and GLSL comments in,
// [SceneShaderUniform]s out — then the library that keeps them warm per
// package, compiling through [compileProjectShader] as a shader's content
// changes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutterware/scene_authoring.dart' show ShaderPaint;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../embedder/flutter_cache.dart';
import '../previews/project_shaders.dart';

/// One uniform a shader declares, as the reflection and the source's own
/// comments describe it.
class SceneShaderUniform {
  const SceneShaderUniform({
    required this.name,
    required this.size,
    required this.location,
    this.range,
    this.isColor = false,
    this.defaults,
  });

  final String name;

  /// 1..4 floats — `float`, `vec2`, `vec3`, `vec4`.
  final int size;

  /// Declaration order, as `impellerc` numbers it — not the reflection
  /// array's own order.
  final int location;

  /// `// @range a b` on the declaration line, when it parsed.
  final (double, double)? range;

  /// `// @color`, honoured only on a `vec3`/`vec4`.
  final bool isColor;

  /// `// @default …`, honoured only when it gave exactly [size] numbers.
  final List<double>? defaults;

  /// Whether this is one of [ShaderPaint.rendererUniforms]' names, so the
  /// inspector leaves it to the renderer rather than drawing a control for
  /// it. By name alone: the renderer skips a stored value under that name
  /// whatever size the shader declares it at, so a control for it would
  /// edit nothing.
  bool get rendererOwned => ShaderPaint.rendererUniforms.containsKey(name);
}

/// What is known about one shader: its uniforms, or why they could not be
/// read.
class SceneShaderInfo {
  const SceneShaderInfo({
    required this.key,
    this.uniforms = const [],
    this.error,
  });

  /// The pubspec's `shaders:` entry — a path relative to the package root.
  final String key;

  /// In declaration order.
  final List<SceneShaderUniform> uniforms;

  /// Why the uniforms above are incomplete or absent, or why nothing could
  /// be read at all. A shader that read cleanly carries none.
  final String? error;

  /// Every non-renderer uniform's `@default`, by name — the inspector's
  /// starting values for a layer that has not set any of its own yet.
  Map<String, List<double>> get defaults => {
    for (var u in uniforms)
      if (!u.rendererOwned && u.defaults != null) u.name: u.defaults!,
  };
}

final _declaration = RegExp(
  r'^\s*uniform\s+(?:(?:lowp|mediump|highp)\s+)?(float|vec2|vec3|vec4)\s+(\w+)\s*;(.*)$',
  multiLine: true,
);

final _tag = RegExp(r'@(\w+)([^@]*)');

class _Annotation {
  (double, double)? range;
  var isColor = false;
  List<double>? defaults;
}

/// One uniform's `// @...` tags, by name — read off its declaration line,
/// wherever [source] puts it.
Map<String, _Annotation> _readAnnotations(String source) {
  var out = <String, _Annotation>{};
  for (var match in _declaration.allMatches(source)) {
    var name = match[2]!;
    var tail = match[3] ?? '';
    var slash = tail.indexOf('//');
    if (slash < 0) continue;
    var annotation = _Annotation();
    for (var tag in _tag.allMatches(tail.substring(slash + 2))) {
      var rest = (tag[2] ?? '').trim();
      switch (tag[1]) {
        case 'range':
          var parts = rest.isEmpty
              ? const <String>[]
              : rest.split(RegExp(r'\s+'));
          if (parts.length == 2) {
            var a = double.tryParse(parts[0]);
            var b = double.tryParse(parts[1]);
            if (a != null && b != null) annotation.range = (a, b);
          }
        case 'color':
          annotation.isColor = true;
        case 'default':
          if (rest.isEmpty) break;
          var numbers = rest
              .split(RegExp(r'\s+'))
              .map(double.tryParse)
              .toList();
          if (!numbers.contains(null)) annotation.defaults = numbers.cast();
      }
    }
    out[name] = annotation;
  }
  return out;
}

/// The uniforms `impellerc` reflected in [reflectionJson], in declaration
/// order, each carrying whatever [source]'s own comments add.
///
/// A uniform that is not a plain float vector — a matrix, a sampler, an
/// integer — is left out; the inspector has nothing to draw for it, and it
/// has no [SceneShaderUniform.location] worth sorting by. Malformed JSON, or
/// one without a `uniforms` array, is an empty list rather than a throw: a
/// `.frag` mid-edit fails to compile far more often than it fails to
/// reflect, and this must degrade the same way that does.
List<SceneShaderUniform> readShaderUniforms(
  String reflectionJson,
  String source,
) => _uniformsFromReflection(_decodeReflection(reflectionJson), source);

/// [reflectionJson] decoded once, or null for anything that does not parse —
/// the seam [readShaderUniforms] and [_sampledImageNames] share so a caller
/// holding both a shader's uniforms and its samplers pays for one decode,
/// not two.
Object? _decodeReflection(String reflectionJson) {
  try {
    return jsonDecode(reflectionJson);
  } on FormatException {
    return null;
  }
}

List<SceneShaderUniform> _uniformsFromReflection(
  Object? decoded,
  String source,
) {
  var raw = decoded is Map ? decoded['uniforms'] : null;
  if (raw is! List) return const [];
  var entries = [
    for (var item in raw)
      if (item is Map && _isFloatVector(item))
        (
          name: item['name'] as String,
          size: (item['type'] as Map)['vec_size'] as int,
          location: item['location'] as int,
        ),
  ]..sort((a, b) => a.location.compareTo(b.location));

  var annotations = _readAnnotations(source);
  return [
    for (var e in entries)
      SceneShaderUniform(
        name: e.name,
        size: e.size,
        location: e.location,
        range: annotations[e.name]?.range,
        isColor: e.size >= 3 && (annotations[e.name]?.isColor ?? false),
        defaults: switch (annotations[e.name]?.defaults) {
          var d? when d.length == e.size => d,
          _ => null,
        },
      ),
  ];
}

bool _isFloatVector(Map item) {
  if (item['name'] is! String || item['location'] is! int) return false;
  var type = item['type'];
  if (type is! Map || type['type_name'] != 'ShaderType::kFloat') return false;
  var columns = type['columns'];
  if (columns != null && columns != 1) return false;
  var vecSize = type['vec_size'];
  return vecSize is int && vecSize >= 1 && vecSize <= 4;
}

List<String> _sampledImageNames(Object? decoded) {
  var raw = decoded is Map ? decoded['sampled_images'] : null;
  if (raw is! List) return const [];
  return [
    for (var item in raw)
      if (item is Map && item['name'] is String) item['name'] as String,
  ];
}

/// The package's own `flutter: shaders:` entries, in the order the pubspec
/// lists them. A dependency's shaders are never offered — a scene reaches a
/// shader the same way `FragmentProgram.fromAsset` does, by an asset key
/// that must resolve in the root package's own bundle.
///
/// An unreadable or absent pubspec, or one with no `shaders:` list, is an
/// empty list; a non-string entry is dropped rather than failing the rest.
List<String> declaredShaders(String packageRoot) {
  String text;
  try {
    text = File(p.join(packageRoot, 'pubspec.yaml')).readAsStringSync();
  } on FileSystemException {
    return const [];
  }
  try {
    var doc = loadYaml(text);
    var flutter = doc is Map ? doc['flutter'] : null;
    var shaders = flutter is Map ? flutter['shaders'] : null;
    if (shaders is! List) return const [];
    return [
      for (var s in shaders)
        if (s is String) s,
    ];
  } on YamlException {
    return const [];
  }
}

/// A package's shaders, as the inspector reads them: what is declared, and
/// what is known about each one so far.
abstract interface class SceneShaders implements Listenable {
  List<String> get declared;

  /// null while [key] has never been read, or is being (re)compiled.
  SceneShaderInfo? info(String key);
}

/// Reads a project's declared shaders on demand, compiling each one through
/// [compileProjectShader] (or [compile], for a test) and caching the result
/// by content — the same key [compileProjectShader] itself caches by, so a
/// warm read costs a hash and nothing else.
class SceneShaderLibrary extends ChangeNotifier {
  SceneShaderLibrary({required this.cache, @visibleForTesting this.compile});

  final FlutterCache? cache;

  @visibleForTesting
  final Future<CompiledShader> Function(String source)? compile;

  final _packages = <String, _PackageShaders>{};

  /// The view onto one package's shaders. Cached per [packageRoot], so a
  /// caller that holds onto it sees the same compiles land as any other.
  ///
  /// Making it starts every declared shader compiling in the background, so
  /// a shader picked a moment later already has its defaults to start from.
  SceneShaders forPackage(String packageRoot) {
    var key = p.normalize(p.absolute(packageRoot));
    return _packages.putIfAbsent(key, () => _PackageShaders(this, key));
  }

  Future<CompiledShader> _runCompile(String source) {
    if (compile case var override?) return override(source);
    var flutterCache = cache;
    if (flutterCache == null) {
      return Future.error(StateError('no Flutter SDK to compile with'));
    }
    return compileProjectShader(cache: flutterCache, source: source);
  }
}

/// A fixed set of shaders — a test double, or a scene rendered somewhere
/// [SceneShaderLibrary]'s live compiling has no home, such as a store-asset
/// render.
class FixedSceneShaders extends ChangeNotifier implements SceneShaders {
  FixedSceneShaders(this.infos);

  final Map<String, SceneShaderInfo> infos;

  @override
  List<String> get declared => infos.keys.toList();

  @override
  SceneShaderInfo? info(String key) => infos[key];
}

class _PackageShaders extends ChangeNotifier implements SceneShaders {
  _PackageShaders(this._library, this.packageRoot) {
    _readDeclared();
  }

  final SceneShaderLibrary _library;
  final String packageRoot;

  List<String>? _declared;
  DateTime? _declaredAt;

  @override
  List<String> get declared {
    if (_declared == null || _pubspecModified() != _declaredAt) {
      _readDeclared();
    }
    return _declared!;
  }

  /// Reads the pubspec's `shaders:` again, and warms every entry: one already
  /// read answers from a stat, and anything else starts compiling now rather
  /// than on its first pick.
  void _readDeclared() {
    _declaredAt = _pubspecModified();
    var declared = _declared = declaredShaders(packageRoot);
    declared.forEach(info);
  }

  DateTime? _pubspecModified() {
    try {
      return File(p.join(packageRoot, 'pubspec.yaml')).statSync().modified;
    } on FileSystemException {
      return null;
    }
  }

  final _infos = <String, SceneShaderInfo>{};
  final _hashes = <String, String>{};

  /// The files (source plus every local `#include`) and mtimes the hash in
  /// [_hashes] covered, as of the last time it was computed — [info]'s cheap
  /// check before it pays for another [projectShaderHashWithFiles]. An
  /// include that was not there is watched too, at a null mtime: its
  /// appearing is a move, since the hash named it as missing.
  final _watched = <String, Map<String, DateTime?>>{};

  final _inFlight = <String>{};

  /// How often a view somebody listens to looks at its shaders' files.
  static const recheckInterval = Duration(seconds: 1);

  /// The inspector reads [info] when it builds, and nothing rebuilt it when a
  /// `.frag` was saved: an edit, a break or its fix stayed off the panel
  /// until something else redrew it. So while anybody listens, the files each
  /// answer covered are statted once a second, and a move is announced — the
  /// build that follows asks [info], which starts the compile and says so.
  Timer? _recheck;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _recheck ??= Timer.periodic(recheckInterval, (_) => _recheckFiles());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _recheck?.cancel();
      _recheck = null;
    }
  }

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  void _recheckFiles() {
    var moved = false;
    for (var key in _infos.keys.toList()) {
      if (_inFlight.any((token) => token.startsWith('$key@'))) continue;
      var watched = _watched[key];
      // An answer with nothing watched was about a file that was not there:
      // it has moved once the file is back.
      if (watched == null
          ? File(p.join(packageRoot, key)).existsSync()
          : !_unchanged(watched)) {
        info(key);
        moved = true;
      }
    }
    if (moved) notifyListeners();
  }

  @override
  SceneShaderInfo? info(String key) {
    var source = p.join(packageRoot, key);
    if (!File(source).existsSync()) {
      _watched.remove(key);
      _hashes.remove(key);
      return _infos[key] = SceneShaderInfo(
        key: key,
        error: "'$key' is not on disk",
      );
    }

    if (_hashes.containsKey(key) && _unchanged(_watched[key])) {
      return _infos[key];
    }

    var (:hash, :files, :missing) = projectShaderHashWithFiles(source);
    if (_hashes[key] == hash) {
      _watched[key] = _stat(files, missing);
      return _infos[key];
    }

    var token = '$key@$hash';
    if (_inFlight.add(token)) {
      unawaited(_load(key, source, hash, files, missing, token));
    }
    return null;
  }

  Future<void> _load(
    String key,
    String source,
    String hash,
    List<String> files,
    List<String> missing,
    String token,
  ) async {
    SceneShaderInfo info;
    try {
      var compiled = await _library._runCompile(source);
      var reflectionText = File(compiled.reflection).readAsStringSync();
      var decoded = _decodeReflection(reflectionText);
      var uniforms = _uniformsFromReflection(
        decoded,
        File(source).readAsStringSync(),
      );
      var samplers = _sampledImageNames(decoded);
      info = SceneShaderInfo(
        key: key,
        uniforms: uniforms,
        error: samplers.isEmpty
            ? null
            : 'uses a sampler (${samplers.join(', ')}): a scene cannot feed '
                  'one yet',
      );
    } on Object catch (error) {
      info = SceneShaderInfo(key: key, error: _describe(error));
    }
    _infos[key] = info;
    _hashes[key] = hash;
    _watched[key] = _stat(files, missing);
    _inFlight.remove(token);
    notifyListeners();
  }
}

Map<String, DateTime?> _stat(List<String> files, List<String> missing) => {
  for (var path in missing) path: null,
  for (var file in files) file: File(file).statSync().modified,
};

/// Whether every file [watched] covers still stats to the mtime it did when
/// it was last hashed — a vanished file (deleted, or a stat error) counts as
/// changed, and so does one watched at a null mtime that is there now.
bool _unchanged(Map<String, DateTime?>? watched) {
  if (watched == null) return false;
  for (var MapEntry(key: file, value: modified) in watched.entries) {
    var stat = File(file).statSync();
    var gone = stat.type == FileSystemEntityType.notFound;
    if (modified == null) {
      if (!gone) return false;
      continue;
    }
    if (gone) return false;
    if (stat.modified != modified) return false;
  }
  return true;
}

/// [error]'s message, trimmed to a few lines and with any scratch path a
/// compile staged its work under collapsed to a basename — the detail that
/// tells nobody anything, in the one spot it could otherwise leak into the
/// inspector.
String _describe(Object error) {
  var message = error is StateError ? error.message : '$error';
  var head = message.split('\n').take(4).join('\n');
  return head.replaceAllMapped(
    RegExp(r'\S*[/\\]staging[/\\]\S*'),
    (m) => p.basename(m[0]!),
  );
}
