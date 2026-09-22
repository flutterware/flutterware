import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';
import 'package:flutterware/real_work.dart';

import '../../capture/settle.dart';
import '../shot_store.dart';

export '../shot_store.dart' show Shot;

/// Loads and holds the two frames a stage is showing.
///
/// One of these per stage, not per image: a stage shows two frames and wants
/// them together — a slider that arrives with only the head loaded shows a
/// comparison against nothing for one frame, which reads as a change.
class ShotPair extends ChangeNotifier implements SettleSource {
  ShotPair(this.store);

  final ShotStore store;

  Shot? base;
  Shot? head;

  /// What is currently loaded, so re-selecting the same row costs nothing.
  String? _baseId;
  String? _headId;

  var _disposed = false;
  var _pending = 0;

  /// True once a load has finished, whatever it found.
  ///
  /// Distinct from having an image, and the distinction is a message: a
  /// step that failed on both sides has no frames and never will, and a pane
  /// that said "Loading…" over it said so forever.
  var settled = false;

  bool get hasFrames => base != null || head != null;

  /// A capture must not photograph a stage mid-decode: the frames are the
  /// subject, and an empty stage looks exactly like a comparison of two blank
  /// screens.
  @override
  String? get busyWith => _pending > 0 ? 'loading frames' : null;

  /// Two frames the renderer filed, by `ShotCache` key.
  ///
  /// [width] is the decode size — see [ShotStore.byKey]. A stage leaves it
  /// null and gets the frame; a thumbnail names its own width and gets one.
  Future<void> load({String? baseKey, String? headKey, int? width}) => _replace(
    baseId: baseKey,
    headId: headKey,
    decode: () => Future.wait([
      baseKey == null ? Future.value(null) : store.byKey(baseKey, width: width),
      headKey == null ? Future.value(null) : store.byKey(headKey, width: width),
    ]),
  );

  /// Two frames the replay wrote, by path — see [FrameRef].
  Future<void> loadFrames({FrameRef? base, FrameRef? head, int? width}) =>
      _replace(
        baseId: base?.path,
        headId: head?.path,
        decode: () => Future.wait([
          base == null ? Future.value(null) : store.byRef(base, width: width),
          head == null ? Future.value(null) : store.byRef(head, width: width),
        ]),
      );

  Future<void> _replace({
    required String? baseId,
    required String? headId,
    required Future<List<Shot?>> Function() decode,
  }) async {
    if (settled && baseId == _baseId && headId == _headId) return;
    _baseId = baseId;
    _headId = headId;
    _pending++;
    // Announced as well as counted: [busyWith] is what the studio's own
    // capture waits on, and a scenario waits on neither — a decode lands on
    // the engine's threads and schedules no frame, so without this a step
    // photographs the frames half drawn, and a different half every run.
    var loaded = await RealWork.track(decode(), label: 'comparison frames');
    _pending--;
    if (_disposed || baseId != _baseId || headId != _headId) {
      // Superseded by a later selection. Disposed here rather than left to fall
      // out of scope: a `ui.Image` holds GPU memory a garbage collector is in
      // no hurry about, and a fast walk down a list of two hundred entries is
      // four hundred of them.
      for (var shot in loaded) {
        shot?.image.dispose();
      }
      return;
    }
    base?.image.dispose();
    head?.image.dispose();
    base = loaded[0];
    head = loaded[1];
    settled = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    base?.image.dispose();
    head?.image.dispose();
    super.dispose();
  }
}

/// A decoded frame, drawn to fit.
class ShotView extends StatelessWidget {
  const ShotView(this.shot, {super.key, this.opacity = 1.0});

  final Shot shot;
  final double opacity;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity,
    // Not `RawImage`'s own alignment: the stage lays the two frames on top of
    // each other and they have to land on the same rect even when their sizes
    // differ, which is exactly the case a size change produces.
    child: RawImage(
      image: shot.image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    ),
  );
}
