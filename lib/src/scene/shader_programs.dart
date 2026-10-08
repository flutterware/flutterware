// A project's fragment programs, loaded once per process, and the shaders a
// text pass draws them with.
//
// A program paints nothing until it has loaded: a blank pass is an honest
// "not yet", where a stand-in colour is a wrong frame that looks right. Every
// load is real work (`RealWork`), so each flutter_tester lane waits for it
// with no plumbing of its own; a plain `flutter test` has no such wait, and
// loads them with [precacheSceneShaders] instead — inside `tester.runAsync`
// in a `testWidgets`, whose fake clock never lets a load land.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../real_work/tracker.dart';
import 'core/model.dart';
import 'core/values.dart';

typedef SceneProgramLoader = Future<ui.FragmentProgram> Function(String asset);

class SceneShaderPrograms extends ChangeNotifier {
  SceneShaderPrograms({SceneProgramLoader? loader})
    : _loader = loader ?? ui.FragmentProgram.fromAsset;

  static final instance = SceneShaderPrograms();

  final SceneProgramLoader _loader;
  final _loaded = <String, ui.FragmentProgram>{};
  final _failed = <String, Object>{};
  final _loading = <String, Future<void>>{};
  final _reported = <(String, String)>{};

  /// The program for [asset] if it has loaded; otherwise null, and the load
  /// is started. Listeners hear when it lands.
  ui.FragmentProgram? program(String asset) {
    if (_loaded[asset] case var p?) return p;
    unawaited(load(asset));
    return null;
  }

  /// Completes when [asset] has loaded or failed; never throws. A failed
  /// asset is not asked for again until [forgetFailures].
  ///
  /// The load itself is built in the root zone, through [RealWork.run]: this
  /// cache outlives any one test or scenario, and a load whose bookkeeping
  /// lived in the zone that first asked would be stranded when that zone's
  /// fake clock stopped. Each call is announced on its own, so a caller
  /// joining a load already in flight has its harness wait for it too.
  Future<void> load(String asset) {
    if (_loaded.containsKey(asset) || _failed.containsKey(asset)) {
      return Future.value();
    }
    return RealWork.run(
      () => _loading[asset] ??= _start(asset),
      label: 'shader $asset',
    );
  }

  Future<void> _start(String asset) =>
      Future.sync(() => _loader(asset))
          .then<void>(
            (program) => _loaded[asset] = program,
            onError: (Object error, StackTrace _) {
              _failed[asset] = error;
              debugPrint('flutterware: shader $asset did not load — $error');
            },
          )
          .whenComplete(() {
            _loading.remove(asset);
            notifyListeners();
          });

  /// The assets whose load is in flight, as they stand now.
  List<String> get pending => _loading.keys.toList();

  Object? errorFor(String asset) => _failed[asset];

  /// Forgets every asset that failed, so the next [program] asks for it
  /// again — after a reload, a shader first seen broken may be fixed.
  void forgetFailures() {
    if (_failed.isEmpty) return;
    _failed.clear();
    notifyListeners();
  }

  /// Waits up to [timeout] for every load in flight, loads started meanwhile
  /// included, and returns the assets still pending.
  ///
  /// [timeout] is measured on the caller's clock: under fake time it never
  /// runs out, so call this from a zone with a real one.
  Future<List<String>> settle({required Duration timeout}) async {
    var deadline = DateTime.now().add(timeout);
    while (_loading.isNotEmpty) {
      var left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      try {
        await Future.wait(_loading.values.toList()).timeout(left);
      } on TimeoutException {
        break;
      }
    }
    return _loading.keys.toList();
  }

  /// Says once per [asset] and [uniform] that a value was skipped: a paint
  /// runs every frame, and the same line sixty times a second is noise.
  void reportSkipped(String asset, String uniform, int floats) {
    if (!_reported.add((asset, uniform))) return;
    debugPrint(
      'flutterware: $asset has no uniform "$uniform" of $floats '
      'float${floats == 1 ? '' : 's'}, so its value is skipped',
    );
  }

  @visibleForTesting
  void reset() {
    _loaded.clear();
    _failed.clear();
    _loading.clear();
    _reported.clear();
  }
}

/// The shaders one text stack draws with, one per pass and line.
///
/// Not one shared shader: the vector capture keeps each draw's live shader
/// object and replays it later, so a shader shared across draws would replay
/// every one of them with the last uniforms set — and per-line bands set a
/// different `uSize` within one pass. A slot is reused frame after frame.
class SceneShaderSlots {
  final _slots = <(int, int), SceneShaderSlot>{};

  /// The slot for [pass] and [line], replaced when its program changed.
  SceneShaderSlot slot(
    ui.FragmentProgram program,
    String asset,
    int pass,
    int line,
  ) {
    var existing = _slots[(pass, line)];
    if (existing != null && identical(existing._program, program)) {
      return existing;
    }
    return _slots[(pass, line)] = SceneShaderSlot._(program, asset);
  }

  /// After a reassemble — which follows a shader reload — every cached
  /// uniform handle may point at a uniform the reload dropped. Forgotten, not
  /// disposed: a capture taken before may still hold the shaders.
  void clear() => _slots.clear();

  void dispose() {
    for (var s in _slots.values) {
      s.shader.dispose();
    }
    _slots.clear();
  }
}

class SceneShaderSlot {
  SceneShaderSlot._(this._program, this._asset)
    : shader = _program.fragmentShader();

  final ui.FragmentProgram _program;
  final String _asset;
  final ui.FragmentShader shader;

  // Null: not declared, or declared at another size. Asked once per name.
  final _handles = <(String, int), void Function(List<double>)?>{};

  /// Sets the renderer's uniforms the shader declares, then the author's;
  /// returns the author's names that were skipped.
  ///
  /// An author value under a renderer name is not the author's to set, and
  /// is neither applied nor reported.
  List<String> setUniforms(
    ShaderPaint paint, {
    required ui.Size size,
    required ui.Color color,
    required double seconds,
  }) {
    _set('uSize', [size.width, size.height]);
    _set('uColor', [color.r, color.g, color.b, color.a]);
    _set('uTime', [seconds]);
    var skipped = <String>[];
    for (var MapEntry(:key, :value) in paint.uniforms.entries) {
      if (ShaderPaint.rendererUniforms.containsKey(key)) continue;
      if (!_set(key, value)) {
        skipped.add(key);
        SceneShaderPrograms.instance.reportSkipped(_asset, key, value.length);
      }
    }
    return skipped;
  }

  bool _set(String name, List<double> v) {
    var key = (name, v.length);
    var set = _handles.putIfAbsent(key, () => _handle(name, v.length));
    set?.call(v);
    return set != null;
  }

  void Function(List<double>)? _handle(String name, int floats) {
    try {
      switch (floats) {
        case 1:
          var slot = shader.getUniformFloat(name);
          // getUniformFloat checks the name, not the size: a vec2 answers at
          // index 0. Index 1 existing means it is wider than a float.
          try {
            shader.getUniformFloat(name, 1);
            return null;
          } on ArgumentError {
            return (v) => slot.set(v[0]);
          }
        case 2:
          var slot = shader.getUniformVec2(name);
          return (v) => slot.set(v[0], v[1]);
        case 3:
          var slot = shader.getUniformVec3(name);
          return (v) => slot.set(v[0], v[1], v[2]);
        case 4:
          var slot = shader.getUniformVec4(name);
          return (v) => slot.set(v[0], v[1], v[2], v[3]);
      }
    } on ArgumentError {
      return null;
    }
    return null;
  }
}

/// Every shader a scene's text paints with.
Set<String> sceneShaderAssets(SceneDocument scene) => {
  for (var (node, _) in scene.walk())
    if (node is TextNode)
      for (var layer in node.layers)
        if (layer.paint case ShaderPaint(:var asset) when asset.isNotEmpty)
          asset,
};

/// Loads every fragment program [scene] paints with.
///
/// A flutterware lane waits for these loads by itself. A plain `flutter
/// test` does not — `pumpAndSettle` never asks — so a test that pumps a scene
/// with a shader pass loads them first, or the pass is blank. In a
/// `testWidgets` that is on the real clock, because a program's load never
/// completes under the fake one and awaiting it directly hangs the test:
///
/// ```dart
/// await tester.runAsync(() => precacheSceneShaders(scene));
/// ```
///
/// A plain `test()` runs on the real clock already, and awaits it directly.
Future<void> precacheSceneShaders(SceneDocument scene) => Future.wait([
  for (var asset in sceneShaderAssets(scene))
    SceneShaderPrograms.instance.load(asset),
]);
