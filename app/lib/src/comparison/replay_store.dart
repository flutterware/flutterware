import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterware/comparison_report.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

import 'scenario_alignment.dart';
import 'scenario_diff.dart';
import 'shot_cache.dart';

/// One side's replay of one scenario, filed by what made it.
///
/// The scenario twin of what [ShotCache] already is for previews, and inside
/// it: a replay is a pure function of the scenario's sources, its pixel
/// inputs, the SDK and the settings it ran under, which is exactly what a
/// `ShotKey` hashes. Filed that way, a base is replayed once per commit however
/// many branches compare against it, and a push whose inputs did not move
/// replays nothing at all.
///
/// Before this, nothing was filed. Measured on a consumer's second push with
/// identical inputs: previews came from the store in 8.5s where they had taken
/// 119s, and all 135 scenarios replayed again on both sides, for 262s — the
/// whole cost of a run with findings.
///
/// **One key per side, and the frames filed by what they are.** The list of
/// steps is filed under the side's key as `<key>.replay.json`; each frame is an
/// ordinary shot keyed by its own bytes, and each step's tree a shot keyed by
/// the step. Content-addressed because most of a scenario's frames are copies —
/// a step that changed nothing on screen, the same screen on both sides of a
/// comparison whose change did not reach it — and raw frames are a megabyte or
/// more each: filed per step, one 135-scenario suite came to more than the
/// whole store's size budget, and the sweep would have evicted the run it had
/// just filed. They share the store's sweep and so can be swept apart from the
/// list; [read] treats a list whose frames are gone as absent, and the side is
/// replayed.
class ReplayStore {
  ReplayStore(this.cache);

  final ShotCache cache;

  /// Whether a replay is filed under [key]. A stat, so a plan can ask it of
  /// every scenario before deciding to start a harness; [read] is the answer
  /// that counts.
  bool has(String key) => File(_listOf(key)).existsSync();

  /// The steps filed under [key], with frames pointing into the store, or
  /// null when the replay — or any frame or tree it names — is not there.
  List<ScenarioStepShot>? read(String key) => readReplay(key)?.steps;

  /// The replay filed under [key] — its steps and what it failed on — or null
  /// when it, or any frame or tree it names, is not there.
  ///
  /// Also null for a failed replay filed before failures had to reproduce to
  /// be filed: nothing vouches that it would fail again, and serving it is how
  /// one bad minute on one host became every later comparison's finding
  /// against that base.
  ScenarioReplay? readReplay(String key) {
    var list = File(_listOf(key));
    Object? json;
    try {
      json = jsonDecode(list.readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    if (json is! Map || json['steps'] is! List) return null;
    var errors = [
      for (var error in json['errors'] as List? ?? const []) '$error',
    ];
    var failed =
        errors.isNotEmpty ||
        (json['steps'] as List).any(
          (step) => step is Map && step['failure'] != null,
        );
    if (failed && json['confirmed'] != true) return null;
    var steps = <ScenarioStepShot>[];
    for (var entry in json['steps'] as List) {
      if (entry is! Map) return null;
      var step = entry.cast<String, Object?>();
      var index = step['index'] as int? ?? 0;
      var width = step['width'] as int? ?? 0;
      var height = step['height'] as int? ?? 0;
      var frameKey = step['frame'] as String?;
      var rgba = frameKey == null ? null : cache.read(frameKey);
      if (frameKey != null && rgba == null) return null;
      var tree = step['tree'] == true
          ? cache.readTree(_stepKey(key, index))
          : null;
      // The same rule as a frame. A step's tree is an entry of its own, swept
      // on its own, and a step served without the tree it was filed with is
      // diffed against nothing: every node of the other side reads as added.
      if (step['tree'] == true && tree == null) return null;
      steps.add(
        ScenarioStepShot(
          step: AlignableStep(
            index: index,
            position: step['position'] as String? ?? '',
            parent: step['parent'] as int?,
            branch: step['branch'] as String?,
            name: step['name'] as String?,
            verb: step['verb'] as String?,
            target: step['target'] as String?,
            failure: step['failure'] as String?,
          ),
          rgba: rgba,
          width: width,
          height: height,
          tree: tree == null ? null : InspectNode.fromJson(tree),
          treeFormat: step['treeFormat'] as int?,
          texts: [for (var text in step['texts'] as List? ?? const []) '$text'],
          events: [
            for (var event in step['events'] as List? ?? const [])
              if (event is Map) event.cast<String, Object?>(),
          ],
          failure: step['failure'] as String?,
          frame: frameKey == null
              ? null
              : FrameRef(
                  path: cache.pathOf(frameKey),
                  width: width,
                  height: height,
                ),
        ),
      );
    }
    // Touched, for the reason `ShotCache.read` touches: an LRU rather than a
    // first-in-first-out, since a base's replays are written once and read by
    // every comparison against it for weeks.
    try {
      list.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // Read-only, or swept a moment ago. The steps are in hand.
    }
    return ScenarioReplay(steps, errors: errors);
  }

  /// Files [steps] under [key], and hands them back pointing into the store.
  ///
  /// A frame the replay left on disk is moved in rather than copied — see
  /// [ShotCache.adopt] — so filing a replay costs no second copy of it; one the
  /// store already holds is deleted instead, and costs nothing.
  ///
  /// The list is written **last**, and renamed into place: [has] answers off
  /// it, so a comparison killed halfway through filing leaves frames nothing
  /// names, which the sweep collects, rather than a list naming frames that
  /// were never written.
  ///
  /// Filing is the caller vouching that this is a *result*: a replay that
  /// failed is filed only once its failure has reproduced, and one filed with
  /// a failure is stamped so [readReplay] can tell it from one filed before
  /// that was the rule. [errors] are the outcome's own — a failure that is not
  /// on any step still has to come back with the steps.
  List<ScenarioStepShot> write(
    String key,
    List<ScenarioStepShot> steps, {
    List<String> errors = const [],
  }) {
    var filed = <ScenarioStepShot>[];
    var listed = <Map<String, Object?>>[];
    for (var shot in steps) {
      var step = shot.step;
      var rgba = shot.rgba;
      var frameKey = rgba == null
          ? null
          : _frameKey(rgba, shot.width, shot.height);
      if (frameKey != null) {
        var left = switch (shot.frame?.path) {
          var path? when File(path).existsSync() => File(path),
          _ => null,
        };
        if (cache.has(frameKey)) {
          // Already filed, by another step or another side or another push.
          // The run's own copy is litter now.
          try {
            left?.deleteSync();
          } on FileSystemException {
            // Left for the comparison directory's own sweep.
          }
        } else {
          var record = ShotRecord(
            format: 'raw',
            width: shot.width,
            height: shot.height,
            entryId: step.label,
          );
          if (left != null) {
            cache.adopt(frameKey, left, rgba!, record);
          } else {
            cache.write(frameKey, rgba!, record);
          }
        }
      }
      if (shot.tree case var tree?) {
        cache.writeTree(_stepKey(key, step.index), tree.toJson());
      }
      listed.add({
        'index': step.index,
        'position': step.position,
        'parent': ?step.parent,
        'branch': ?step.branch,
        'name': ?step.name,
        'verb': ?step.verb,
        'target': ?step.target,
        'width': shot.width,
        'height': shot.height,
        'frame': ?frameKey,
        if (shot.tree != null) 'tree': true,
        'treeFormat': ?shot.treeFormat,
        if (shot.texts.isNotEmpty) 'texts': shot.texts,
        if (shot.events.isNotEmpty) 'events': shot.events,
        'failure': ?shot.failure,
      });
      filed.add(
        ScenarioStepShot(
          step: step,
          rgba: rgba,
          width: shot.width,
          height: shot.height,
          tree: shot.tree,
          treeFormat: shot.treeFormat,
          texts: shot.texts,
          events: shot.events,
          failure: shot.failure,
          frame: frameKey == null
              ? shot.frame
              : FrameRef(
                  path: cache.pathOf(frameKey),
                  width: shot.width,
                  height: shot.height,
                ),
        ),
      );
    }
    var list = File(_listOf(key));
    list.parent.createSync(recursive: true);
    var staging = File('${list.path}.part');
    var failed = errors.isNotEmpty || steps.any((shot) => shot.failure != null);
    staging.writeAsStringSync(
      jsonEncode({
        'steps': listed,
        if (errors.isNotEmpty) 'errors': errors,
        if (failed) 'confirmed': true,
      }),
      flush: true,
    );
    staging.renameSync(list.path);
    return filed;
  }

  String _listOf(String key) => '${cache.pathOf(key)}.replay.json';

  /// A step's own key, for its tree: the side's key and the step's index,
  /// hashed, so it fans out across the store like any other shot.
  static String _stepKey(String key, int index) =>
      sha1.convert(utf8.encode('$key/step/$index')).toString();

  /// A frame's key: its bytes and its shape. The shape because the same
  /// bytes are a different picture at another width.
  static String _frameKey(List<int> rgba, int width, int height) {
    var sink = _DigestSink();
    sha1.startChunkedConversion(sink)
      ..add(utf8.encode('frame/${width}x$height/'))
      ..add(rgba)
      ..close();
    return '${sink.value}';
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
